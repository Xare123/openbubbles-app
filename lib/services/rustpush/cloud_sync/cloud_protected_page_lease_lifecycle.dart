import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';

/// Coordinates the native protected-file lease with the durable ObjectBox
/// adoption marker.
///
/// The static identity map coalesces startup recovery within an isolate. The
/// native local lifecycle lease excludes concurrent receive adoption in other
/// engines/processes. A failed recovery is removed so a later run may retry.
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

  Future<T> _runMaintenanceExclusive<T>(Future<T> Function() action) {
    final transport = _transport;
    return runProtectedStoreExclusive(
      () => transport is CloudProtectedLocalLifecycleTransport
          ? (transport as CloudProtectedLocalLifecycleTransport)
                .runLocalProtectedStoreExclusive(action)
          : action(),
    ); // non-native/in-memory transports
  }

  /// Fetches may proceed when an outbound owner still names a native lease
  /// receipt that is already absent. The complete protected-reference
  /// snapshot remains authoritative for blob liveness, and this recovery path
  /// never releases an outbound owner. A later write always performs a fresh,
  /// strict recovery pass with optional exact local mutation receipt repair.
  Future<void> ensureRecoveredBeforeFetch() {
    final existing = _recoveries[_recoveryIdentity];
    if (existing != null) return existing;
    return _startRecovery(allowMissingOutboundReceipts: true);
  }

  /// Writes need a fresh recovery pass even when startup recovery succeeded.
  /// A native lease commit can fail later in the same process, leaving a new
  /// durable outbound adoption marker that the cached startup pass never saw.
  Future<void> ensureRecoveredBeforeWrite() =>
      _startRecovery(allowMissingOutboundReceipts: false);

  Future<void> _startRecovery({required bool allowMissingOutboundReceipts}) {
    final recovery = _recover(
      allowMissingOutboundReceipts: allowMissingOutboundReceipts,
    );
    _recoveries[_recoveryIdentity] = recovery;
    recovery.catchError((Object _) {
      if (identical(_recoveries[_recoveryIdentity], recovery)) {
        _recoveries.remove(_recoveryIdentity);
      }
    });
    return recovery;
  }

  Future<void> _recover({required bool allowMissingOutboundReceipts}) =>
      _runMaintenanceExclusive(
        () => _recoverWhileStoreExclusive(
          allowMissingOutboundReceipts: allowMissingOutboundReceipts,
        ),
      );

  Future<void> _recoverWhileStoreExclusive({
    required bool allowMissingOutboundReceipts,
  }) async {
    final adoptedPages = await _store.readAdoptedProtectedPageLeaseReferences(
      maximumCount: maximumAdoptedLeases,
    );
    final outboundStore = _store;
    final adoptedOutbound =
        outboundStore is CloudProtectedOutboundLeaseAdoptionStore
        ? await (outboundStore as CloudProtectedOutboundLeaseAdoptionStore)
              .readLiveProtectedOutboundLeaseReferences(
                maximumCount: maximumAdoptedLeases,
              )
        : const <String>{};
    if (adoptedPages.intersection(adoptedOutbound).isNotEmpty) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'protected_lease_namespace_collision',
      );
    }
    final adopted = {...adoptedPages, ...adoptedOutbound};
    if (adopted.length > maximumAdoptedLeases) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'protected_lease_recovery_bound_exceeded',
      );
    }
    final live = await _readCompleteLivenessSnapshot();
    final remaining = adopted.toSet();
    var passes = 0;
    var repairAttempted = false;
    final repairedAwaitingRecovery = <String>{};
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
      final absentOutbound = result.absentAdoptedLeaseReferences.intersection(
        adoptedOutbound,
      );
      if (absentOutbound.isNotEmpty && !allowMissingOutboundReceipts) {
        if (repairAttempted) throw _missingOutboundReceipt();
        repairAttempted = true;
        await _repairMissingMutationReceipts(absentOutbound, live);
        repairedAwaitingRecovery.addAll(absentOutbound);
        // Do not consume any result from the pre-repair pass. Native recovery
        // must observe the reconstructed receipts before recovery can proceed.
        continue;
      }
      if (resolved.isNotEmpty) {
        final resolvedPages = resolved.intersection(adoptedPages);
        if (resolvedPages.isNotEmpty) {
          try {
            await _store.releaseAdoptedProtectedPageLeaseReferences(
              resolvedPages,
            );
          } catch (_) {
            _recoveries.remove(_recoveryIdentity);
            rethrow;
          }
          for (final leaseReference in resolvedPages) {
            try {
              await _transport.acknowledgeCommittedPageLease(leaseReference);
            } catch (_) {
              // The receipt contains only opaque references and is safe to
              // leak. Outbound receipts are never acknowledged here.
              _recoveries.remove(_recoveryIdentity);
            }
          }
        }
        remaining.removeAll(resolved);
      }
      repairedAwaitingRecovery.removeAll(
        result.finalizedAdoptedLeaseReferences,
      );
      if (!result.hasMore) {
        if (repairedAwaitingRecovery.isNotEmpty) {
          throw _missingOutboundReceipt();
        }
        return;
      }
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

  Future<void> _repairMissingMutationReceipts(
    Set<String> missing,
    CloudProtectedReferenceSnapshot live,
  ) async {
    final store = _store;
    final transport = _transport;
    if (store is! CloudProtectedMutationLeaseRepairStore ||
        transport is! CloudProtectedMutationLeaseRepairTransport) {
      throw _missingOutboundReceipt();
    }
    try {
      final claims = List<CloudProtectedMutationLeaseRepairClaim>.unmodifiable(
        await (store as CloudProtectedMutationLeaseRepairStore)
            .readProtectedMutationLeaseRepairClaims(
              Set.unmodifiable(missing),
              maximumCount: maximumAdoptedLeases,
            ),
      );
      final leases = <String>{};
      final references = <String>{};
      // Validate the entire batch before repairing even one receipt. The
      // native implementation still must prove every exact source field.
      if (claims.length != missing.length) throw _missingOutboundReceipt();
      for (final claim in claims) {
        final source = claim.source;
        if (!missing.contains(source.leaseReference) ||
            !leases.add(source.leaseReference) ||
            !references.add(source.protectedReference) ||
            source.protectedStoreIdentity != _recoveryIdentity ||
            !live.references.contains(source.protectedReference)) {
          throw _missingOutboundReceipt();
        }
      }
      for (final claim in claims) {
        await (transport as CloudProtectedMutationLeaseRepairTransport)
            .repairProtectedMutationLeaseReceipt(claim);
      }
    } catch (_) {
      // Partial local repair is safe and idempotent. Preserve every durable
      // owner and the original failure code; never promote/retry a mutation.
      throw _missingOutboundReceipt();
    }
  }

  CloudSyncFailure _missingOutboundReceipt() => CloudSyncFailure(
    category: CloudFailureCategory.localStorage,
    safeCode: 'protected_outbound_lease_missing',
  );

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
    // App-level sync/account admission belongs to
    // CloudProtectedPageLeaseMaintenanceCaller. This primitive only owns the
    // protected-store recovery, liveness snapshot, and native store lock.
    await ensureRecoveredBeforeFetch();
    return _runMaintenanceExclusive(
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
