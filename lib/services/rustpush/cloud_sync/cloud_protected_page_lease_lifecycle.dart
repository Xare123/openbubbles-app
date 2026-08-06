import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';

/// Coordinates the native protected-file lease with the durable ObjectBox
/// adoption marker.
///
/// The static identity map serializes startup recovery across engines sharing
/// one store. A failed recovery is removed so a later run may retry. A
/// successful recovery is process-wide and precedes every subsequent fetch.
final class CloudProtectedPageLeaseLifecycle {
  CloudProtectedPageLeaseLifecycle({
    required this._store,
    required CloudProtectedPageLeaseTransport transport,
  }) : _transport = transport,
       _recoveryIdentity = transport.protectedPageLeaseRecoveryIdentity {
    if (!_nativeStoreIdentityPattern.hasMatch(_recoveryIdentity)) {
      throw ArgumentError('protected_page_lease_recovery_identity_invalid');
    }
  }

  static const int maximumAdoptedLeases = 4096;
  static const int maximumLiveProtectedReferences = 131072;
  static final RegExp _nativeStoreIdentityPattern = RegExp(
    r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
  );
  static final Map<String, Future<void>> _recoveries = {};

  final CloudProtectedPageLeaseAdoptionStore _store;
  final CloudProtectedPageLeaseTransport _transport;
  final String _recoveryIdentity;

  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      _transport.runProtectedStoreExclusive(action);

  Future<void> ensureRecoveredBeforeFetch() {
    final existing = _recoveries[_recoveryIdentity];
    if (existing != null) return existing;
    final recovery = _recover();
    _recoveries[_recoveryIdentity] = recovery;
    recovery.catchError((Object _) {
      if (identical(_recoveries[_recoveryIdentity], recovery)) {
        _recoveries.remove(_recoveryIdentity);
      }
    });
    return recovery;
  }

  Future<void> _recover() =>
      runProtectedStoreExclusive(_recoverWhileStoreExclusive);

  Future<void> _recoverWhileStoreExclusive() async {
    final adopted = await _store.readAdoptedProtectedPageLeaseReferences(
      maximumCount: maximumAdoptedLeases,
    );
    final live = await _readCompleteLivenessSnapshot();
    final remaining = adopted.toSet();
    var passes = 0;
    while (true) {
      if (passes++ >= maximumAdoptedLeases) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'protected_page_lease_recovery_pass_bound_exceeded',
        );
      }
      final result = await _transport.recoverProtectedPageLeases(
        Set.unmodifiable(remaining),
        live,
      );
      if (result.rolledBackCount < 0 ||
          result.rolledBackCount > 64 ||
          result.removedTemporaryFilesCount < 0 ||
          result.removedTemporaryFilesCount > 64) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'protected_page_lease_recovery_result_invalid',
        );
      }
      final resolved = {
        ...result.finalizedAdoptedLeaseReferences,
        ...result.absentAdoptedLeaseReferences,
      };
      if (!remaining.containsAll(resolved) ||
          (result.hasMore && result.absentAdoptedLeaseReferences.isNotEmpty)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'protected_page_lease_recovery_result_invalid',
        );
      }
      if (resolved.isNotEmpty) {
        try {
          await _store.releaseAdoptedProtectedPageLeaseReferences(resolved);
        } catch (_) {
          _recoveries.remove(_recoveryIdentity);
          rethrow;
        }
        for (final leaseReference in resolved) {
          try {
            await _transport.acknowledgeCommittedPageLease(leaseReference);
          } catch (_) {
            // The receipt contains only opaque references and is safe to leak.
            // Invalidate the process cache so the next fetch runs bounded
            // recovery and removes receipts with no adoption marker.
            _recoveries.remove(_recoveryIdentity);
          }
        }
        remaining.removeAll(resolved);
      }
      if (!result.hasMore) return;
      if (resolved.isEmpty &&
          result.rolledBackCount == 0 &&
          result.removedTemporaryFilesCount == 0) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'protected_page_lease_recovery_no_progress',
        );
      }
    }
  }

  Future<void> commitJournaledPage(
    CloudFetchBatch batch, {
    required String? previousCheckpointReference,
  }) => runProtectedStoreExclusive(
    () => _commitJournaledPageWhileStoreExclusive(
      batch,
      previousCheckpointReference: previousCheckpointReference,
    ),
  );

  Future<void> _commitJournaledPageWhileStoreExclusive(
    CloudFetchBatch batch, {
    required String? previousCheckpointReference,
  }) async {
    final leaseReference = batch.protectedPageLeaseReference;
    if (leaseReference == null) return;
    final live = await _readCompleteLivenessSnapshot();
    final retained = _pageProtectedReferences(
      batch,
    ).where(live.references.contains).toSet();
    try {
      await _transport.commitProtectedPageLease(leaseReference, retained);
    } catch (_) {
      // The durable adoption marker remains. Force the next fetch attempt to
      // retry native recovery even when startup recovery already succeeded in
      // this process.
      _recoveries.remove(_recoveryIdentity);
      rethrow;
    }
    try {
      await _store.releaseAdoptedProtectedPageLeaseReferences({leaseReference});
    } catch (_) {
      // Native commit is durable and idempotent. Force the next fetch through
      // recovery so it can finalize the retained adoption/receipt pair.
      _recoveries.remove(_recoveryIdentity);
      rethrow;
    }
    try {
      await _transport.acknowledgeCommittedPageLease(leaseReference);
    } catch (_) {
      // The adoption marker is already gone. Invalidate the process cache so
      // the next fetch runs bounded recovery and removes the safe receipt leak.
      _recoveries.remove(_recoveryIdentity);
    }
    if (previousCheckpointReference != null &&
        previousCheckpointReference != batch.nextToken &&
        !live.references.contains(previousCheckpointReference)) {
      try {
        await _transport.retireProtectedReferences({
          previousCheckpointReference,
        });
      } catch (_) {
        // The ObjectBox transaction already replaced this checkpoint. A
        // retirement failure is a bounded leak and mark-sweep will retry it.
      }
    }
  }

  Future<void> rollbackUnjournaledPage(CloudFetchBatch batch) =>
      runProtectedStoreExclusive(
        () => _rollbackUnjournaledPageWhileStoreExclusive(batch),
      );

  Future<void> _rollbackUnjournaledPageWhileStoreExclusive(
    CloudFetchBatch batch,
  ) async {
    final leaseReference = batch.protectedPageLeaseReference;
    if (leaseReference == null) return;
    try {
      await _transport.rollbackProtectedPageLease(leaseReference);
    } catch (_) {
      // An unadopted manifest may remain. Invalidate the successful recovery
      // cache so the next fetch performs bounded rollback recovery first.
      _recoveries.remove(_recoveryIdentity);
      rethrow;
    }
  }

  Future<CloudProtectedGarbageCollectionResult>
  collectOneProtectedGarbagePage() async {
    await ensureRecoveredBeforeFetch();
    return runProtectedStoreExclusive(
      () async => _transport.collectProtectedGarbage(
        await _readCompleteLivenessSnapshot(),
      ),
    );
  }

  Future<CloudProtectedReferenceSnapshot>
  _readCompleteLivenessSnapshot() async {
    final snapshot = await _store.readLiveProtectedReferences(
      maximumCount: maximumLiveProtectedReferences,
    );
    if (!snapshot.isComplete) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'protected_reference_enumeration_incomplete',
      );
    }
    return snapshot;
  }

  Set<String> _pageProtectedReferences(CloudFetchBatch batch) {
    final references = <String>{};
    void add(String? value) {
      if (value == null) return;
      if (!_protectedReferencePattern.hasMatch(value)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'protected_page_reference_invalid',
        );
      }
      references.add(value);
    }

    for (final change in batch.changes) {
      add(change.encryptedServerRecordId);
      add(change.protectedSystemFieldsReference);
      add(change.encryptedPayloadReference);
    }
    add(batch.nextToken);
    return references;
  }

  static void resetRecoveryStateForTests() {
    _recoveries.clear();
  }

  static final RegExp _protectedReferencePattern = RegExp(
    r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
  );
}
