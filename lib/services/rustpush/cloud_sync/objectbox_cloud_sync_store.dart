import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_operation_identity.dart';
import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_store.dart';

/// Durable ObjectBox implementation of the Cloud Sync V2 journal and outbox.
///
/// Every state transition that changes a checkpoint, lease, journal entry, or
/// outbox operation is synchronous inside one ObjectBox transaction. Network
/// and platform-keystore work always happen outside the transaction.
class ObjectBoxCloudSyncStore
    implements
        CloudSyncStore,
        CloudSyncUnknownOutcomeLeasingStore,
        CloudProtectedPageLeaseAdoptionStore,
        CloudProtectedOutboundLeaseAdoptionStore {
  ObjectBoxCloudSyncStore({
    required Store store,
    required this._protector,
    DateTime Function()? clock,
  }) : _store = store,
       _clock = clock ?? DateTime.now,
       _checkpoints = store.box<CloudSyncCheckpointEntity>(),
       _inbox = store.box<CloudInboxChangeEntity>(),
       _leases = store.box<CloudSyncLeaseEntity>(),
       _protectedPageLeases = store.box<CloudProtectedPageLeaseEntity>(),
       _outbox = store.box<CloudOutboxOperationEntity>(),
       _recordMaps = store.box<CloudRecordMapEntity>(),
       _attachmentMaterializations = store
           .box<CloudAttachmentMaterializationEntity>(),
       _runs = store.box<CloudSyncRunEntity>();

  factory ObjectBoxCloudSyncStore.fromDatabase({
    required CloudSyncProtector protector,
  }) {
    return ObjectBoxCloudSyncStore(store: Database.store, protector: protector);
  }

  static const int _maximumRetainedRunsPerScope = 256;

  final Store _store;
  final CloudSyncProtector _protector;
  final DateTime Function() _clock;
  final Box<CloudSyncCheckpointEntity> _checkpoints;
  final Box<CloudInboxChangeEntity> _inbox;
  final Box<CloudSyncLeaseEntity> _leases;
  final Box<CloudProtectedPageLeaseEntity> _protectedPageLeases;
  final Box<CloudOutboxOperationEntity> _outbox;
  final Box<CloudRecordMapEntity> _recordMaps;
  final Box<CloudAttachmentMaterializationEntity> _attachmentMaterializations;
  final Box<CloudSyncRunEntity> _runs;

  @override
  Future<CloudSyncCheckpoint> readCheckpoint(CloudSyncScope scope) async {
    final captured = _store.runInTransaction(TxMode.write, () {
      final entity = _checkpointLocked(scope, nowMs: _nowMs());
      return (
        entity: entity,
        hasUnmarkedPendingInbox: _hasUnmarkedPendingInboxLocked(scope, entity),
      );
    });
    final entity = captured.entity;
    final ciphertext = entity.fetchedTokenCiphertext;
    String? token;
    if (ciphertext != null) {
      try {
        token = await _protector.unprotect(
          scope: scope,
          kind: CloudSyncProtectedValueKind.checkpointToken,
          ciphertext: ciphertext,
        );
      } catch (_) {
        throw _storageFailure('checkpoint_unprotect_failed');
      }
    }
    return _checkpointFromEntity(
      scope,
      entity,
      fetchedToken: token,
      hasUnmarkedPendingInbox: captured.hasUnmarkedPendingInbox,
    );
  }

  @override
  Future<int> journalFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  }) async {
    final preflightNowMs = _nowMs();
    final leaseKey = _scopedDigest(batch.scope, 'coordinator-lease', 'v1');
    final ownerIdHash = _digest('coordinator-owner\u001f${leaseFence.ownerId}');
    final checkpointCiphertextSnapshot = _store.runInTransaction(
      TxMode.read,
      () {
        final lease = _findLeaseByKeyLocked(leaseKey);
        if (lease == null ||
            lease.scopeKey != _scopeKey(batch.scope) ||
            lease.ownerIdHash != ownerIdHash ||
            lease.generation != leaseFence.generation ||
            lease.expiresAtMs <= preflightNowMs) {
          throw _storageFailure('coordinator_lease_fence_lost');
        }
        final checkpoint = _findCheckpointByKeyLocked(_scopeKey(batch.scope));
        if (checkpoint == null) return null;
        _validateCheckpointScope(checkpoint, batch.scope);
        if (checkpoint.pendingBatchId != null ||
            _hasUnmarkedPendingInboxLocked(batch.scope, checkpoint)) {
          throw _storageFailure('checkpoint_pending_page_unresolved');
        }
        return checkpoint.fetchedTokenCiphertext;
      },
    );
    String? currentFetchedToken;
    if (checkpointCiphertextSnapshot != null) {
      try {
        currentFetchedToken = await _protector.unprotect(
          scope: batch.scope,
          kind: CloudSyncProtectedValueKind.checkpointToken,
          ciphertext: checkpointCiphertextSnapshot,
        );
      } catch (_) {
        throw _storageFailure('checkpoint_unprotect_failed');
      }
    }
    if (currentFetchedToken != expectedFetchedToken) {
      throw _storageFailure('checkpoint_compare_and_swap_failed');
    }

    final tokenCiphertext = await _protectCheckpointToken(
      batch.scope,
      batch.nextToken,
    );
    return _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      final checkpoint = _checkpointLocked(
        batch.scope,
        nowMs: transactionNowMs,
      );
      final lease = _findLeaseByKeyLocked(leaseKey);
      if (lease == null ||
          lease.scopeKey != _scopeKey(batch.scope) ||
          lease.ownerIdHash != ownerIdHash ||
          lease.generation != leaseFence.generation ||
          lease.expiresAtMs <= transactionNowMs) {
        throw _storageFailure('coordinator_lease_fence_lost');
      }
      if (checkpoint.generation != expectedGeneration ||
          checkpoint.fetchedTokenCiphertext != checkpointCiphertextSnapshot) {
        throw _storageFailure('checkpoint_compare_and_swap_failed');
      }
      if (checkpoint.generation != batch.generation) {
        throw _storageFailure('generation_mismatch');
      }
      if (checkpoint.pendingBatchId != null ||
          _hasUnmarkedPendingInboxLocked(batch.scope, checkpoint)) {
        throw _storageFailure('checkpoint_pending_page_unresolved');
      }

      var nextSequence = checkpoint.fetchedSequence + 1;
      var inserted = 0;
      for (final change in batch.changes) {
        final changeKey = _changeKey(
          batch.scope,
          batch.generation,
          change.changeId,
        );
        if (_findInboxByChangeKeyLocked(changeKey) != null) continue;
        _inbox.put(
          CloudInboxChangeEntity(
            changeKey: changeKey,
            changeIdHash: change.changeId,
            scopeKey: _scopeKey(batch.scope),
            accountFingerprint: batch.scope.accountFingerprint,
            zone: batch.scope.zone,
            serverRecordIdHash: change.recordIdHash,
            etagHash: change.etagHash,
            changeType: change.type.name,
            encryptedServerRecordId: change.encryptedServerRecordId,
            protectedSystemFieldsRef: change.protectedSystemFieldsReference,
            encryptedPayloadRef: change.encryptedPayloadReference,
            payloadSha256: change.payloadSha256,
            batchId: batch.batchId,
            generation: batch.generation,
            fetchSequence: nextSequence,
            status: _inboxStatusToInt(CloudInboxStatus.pending),
            isTombstone: change.isTombstone,
            preflightCategory: change.preflightFailure?.name,
            failureCategory: change.preflightFailure?.name,
            preflightCode: change.preflightCode?.name,
            serverModifiedAtMs:
                change.serverModifiedAt?.millisecondsSinceEpoch ?? 0,
            createdAtMs: transactionNowMs,
            updatedAtMs: transactionNowMs,
          ),
        );
        nextSequence++;
        inserted++;
      }

      checkpoint
        ..generation = batch.generation
        ..lastBatchId = batch.batchId
        ..fetchedSequence = nextSequence - 1
        ..lastAttemptAtMs = transactionNowMs
        ..updatedAtMs = transactionNowMs;
      if (inserted == 0) {
        // A page with no unseen rows is already terminal. This also makes a
        // harmless refetch after a crash idempotently advance its token.
        checkpoint
          ..fetchedTokenCiphertext = tokenCiphertext
          ..pendingFetchedTokenCiphertext = null
          ..pendingBatchId = null;
      } else {
        checkpoint
          ..pendingFetchedTokenCiphertext = tokenCiphertext
          ..pendingBatchId = batch.batchId;
      }
      _checkpoints.put(checkpoint);
      _adoptProtectedPageLeaseLocked(batch, nowMs: transactionNowMs);
      return inserted;
    });
  }

  @override
  Future<CloudShadowJournalUsage> readShadowJournalUsage(
    CloudSyncScope scope, {
    required CloudShadowJournalBudget budget,
  }) async {
    budget.validate();
    return _store.runInTransaction(
      TxMode.read,
      () => _shadowJournalUsageLocked(scope, budget),
    );
  }

  @override
  Future<CloudShadowJournalAdmission> journalShadowFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudShadowJournalBudget budget,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  }) async {
    budget.validate();
    // Avoid touching the keystore if a migrated/pre-existing journal is
    // already blocked. The write transaction below repeats this check to make
    // admission race-safe across engines and processes.
    final preliminary = _store.runInTransaction(
      TxMode.read,
      () => _shadowJournalUsageLocked(batch.scope, budget),
    );
    final preliminaryNow = _clock().toUtc();
    final preliminaryReason = budget.blockReasonForCurrentUsage(
      preliminary,
      now: preliminaryNow,
    );
    if (preliminaryReason != null) {
      return CloudShadowJournalAdmission(
        insertedEntries: 0,
        rejectedEntries: 0,
        usage: preliminary,
        blockReason: preliminaryReason,
      );
    }

    final preflightNowMs = preliminaryNow.millisecondsSinceEpoch;
    final leaseKey = _scopedDigest(batch.scope, 'coordinator-lease', 'v1');
    final ownerIdHash = _digest('coordinator-owner\u001f${leaseFence.ownerId}');
    final leaseMatches = _store.runInTransaction(TxMode.read, () {
      final lease = _findLeaseByKeyLocked(leaseKey);
      return lease != null &&
          lease.scopeKey == _scopeKey(batch.scope) &&
          lease.ownerIdHash == ownerIdHash &&
          lease.generation == leaseFence.generation &&
          lease.expiresAtMs > preflightNowMs;
    });
    if (!leaseMatches) {
      throw _storageFailure('coordinator_lease_fence_lost');
    }

    final checkpointCiphertextSnapshot = _store.runInTransaction(
      TxMode.read,
      () {
        final checkpoint = _findCheckpointByKeyLocked(_scopeKey(batch.scope));
        if (checkpoint == null) return null;
        _validateCheckpointScope(checkpoint, batch.scope);
        return checkpoint.fetchedTokenCiphertext;
      },
    );
    String? currentFetchedToken;
    if (checkpointCiphertextSnapshot != null) {
      try {
        currentFetchedToken = await _protector.unprotect(
          scope: batch.scope,
          kind: CloudSyncProtectedValueKind.checkpointToken,
          ciphertext: checkpointCiphertextSnapshot,
        );
      } catch (_) {
        throw _storageFailure('checkpoint_unprotect_failed');
      }
    }
    if (currentFetchedToken != expectedFetchedToken) {
      throw _storageFailure('checkpoint_compare_and_swap_failed');
    }

    // Protection happens before the ObjectBox transaction. A keystore fault
    // therefore cannot partially commit rows or a continuation token.
    final tokenCiphertext = await _protectCheckpointToken(
      batch.scope,
      batch.nextToken,
    );
    return _store.runInTransaction(TxMode.write, () {
      final transactionNow = _clock().toUtc();
      final transactionNowMs = transactionNow.millisecondsSinceEpoch;
      final checkpoint = _checkpointLocked(
        batch.scope,
        nowMs: transactionNowMs,
      );
      final lease = _findLeaseByKeyLocked(leaseKey);
      if (lease == null ||
          lease.scopeKey != _scopeKey(batch.scope) ||
          lease.ownerIdHash != ownerIdHash ||
          lease.generation != leaseFence.generation ||
          lease.expiresAtMs <= transactionNowMs) {
        throw _storageFailure('coordinator_lease_fence_lost');
      }
      if (checkpoint.generation != expectedGeneration ||
          checkpoint.generation != batch.generation ||
          checkpoint.fetchedTokenCiphertext != checkpointCiphertextSnapshot) {
        throw _storageFailure('checkpoint_compare_and_swap_failed');
      }

      final current = _shadowJournalUsageLocked(batch.scope, budget);
      final currentReason = budget.blockReasonForCurrentUsage(
        current,
        now: transactionNow,
      );
      if (currentReason != null) {
        return CloudShadowJournalAdmission(
          insertedEntries: 0,
          rejectedEntries: 0,
          usage: current,
          blockReason: currentReason,
        );
      }

      final unseen = <CloudFetchedChange>[];
      final pageKeys = <String>{};
      for (final change in batch.changes) {
        final changeKey = _changeKey(
          batch.scope,
          batch.generation,
          change.changeId,
        );
        if (!pageKeys.add(changeKey) ||
            _findInboxByChangeKeyLocked(changeKey) != null) {
          continue;
        }
        unseen.add(change);
      }
      final incomingBytes = unseen.fold<int>(
        0,
        (total, change) =>
            total +
            budget.estimateEntryBytes(
              scope: batch.scope,
              batchId: batch.batchId,
              change: change,
            ),
      );
      final projected = current.add(
        entries: unseen.length,
        bytes: incomingBytes,
        oldestAt: unseen.isEmpty ? null : transactionNow,
      );
      final projectedReason = budget.blockReasonForProjectedUsage(
        projected,
        now: transactionNow,
      );
      if (projectedReason != null) {
        return CloudShadowJournalAdmission(
          insertedEntries: 0,
          rejectedEntries: unseen.length,
          usage: current,
          blockReason: projectedReason,
        );
      }

      var nextSequence = checkpoint.fetchedSequence + 1;
      for (final change in unseen) {
        final changeKey = _changeKey(
          batch.scope,
          batch.generation,
          change.changeId,
        );
        _inbox.put(
          CloudInboxChangeEntity(
            changeKey: changeKey,
            changeIdHash: change.changeId,
            scopeKey: _scopeKey(batch.scope),
            accountFingerprint: batch.scope.accountFingerprint,
            zone: batch.scope.zone,
            serverRecordIdHash: change.recordIdHash,
            etagHash: change.etagHash,
            changeType: change.type.name,
            encryptedServerRecordId: change.encryptedServerRecordId,
            protectedSystemFieldsRef: change.protectedSystemFieldsReference,
            encryptedPayloadRef: change.encryptedPayloadReference,
            payloadSha256: change.payloadSha256,
            batchId: batch.batchId,
            generation: batch.generation,
            fetchSequence: nextSequence,
            status: _inboxStatusToInt(CloudInboxStatus.pending),
            isTombstone: change.isTombstone,
            preflightCategory: change.preflightFailure?.name,
            failureCategory: change.preflightFailure?.name,
            preflightCode: change.preflightCode?.name,
            serverModifiedAtMs:
                change.serverModifiedAt?.millisecondsSinceEpoch ?? 0,
            createdAtMs: transactionNowMs,
            updatedAtMs: transactionNowMs,
          ),
        );
        nextSequence++;
      }

      checkpoint
        ..fetchedTokenCiphertext = tokenCiphertext
        ..generation = batch.generation
        ..lastBatchId = batch.batchId
        ..fetchedSequence = nextSequence - 1
        ..lastAttemptAtMs = transactionNowMs
        ..updatedAtMs = transactionNowMs;
      _checkpoints.put(checkpoint);
      _adoptProtectedPageLeaseLocked(batch, nowMs: transactionNowMs);
      return CloudShadowJournalAdmission(
        insertedEntries: unseen.length,
        rejectedEntries: 0,
        usage: projected,
      );
    });
  }

  @override
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  }) async {
    if (maximumCount <= 0 || maximumCount > 4096) {
      throw ArgumentError.value(maximumCount, 'maximumCount');
    }
    return _store.runInTransaction(TxMode.read, () {
      final count = _protectedPageLeases.count();
      if (count > maximumCount) {
        throw _storageFailure('protected_page_lease_recovery_bound_exceeded');
      }
      final references = _protectedPageLeases
          .getAll()
          .map((entity) => entity.leaseReference)
          .toSet();
      if (references.length != count ||
          references.any((reference) => !_isProtectedPageLease(reference))) {
        throw _storageFailure('protected_page_lease_adoption_corrupt');
      }
      return Set<String>.unmodifiable(references);
    });
  }

  /// Returns protected outbound lease references adopted by non-terminal
  /// outbox rows.
  ///
  /// These references are intentionally returned separately from page leases:
  /// page-lease cleanup must not acknowledge or release an outbound receipt.
  /// Existing rows without the not-yet-generated schema property are treated
  /// as having no outbound lease reference.
  @override
  Future<Set<String>> readNonterminalProtectedOutboundLeaseReferences({
    required int maximumCount,
  }) async {
    if (maximumCount <= 0 || maximumCount > 4096) {
      throw ArgumentError.value(maximumCount, 'maximumCount');
    }
    return _store.runInTransaction(TxMode.read, () {
      final references = <String>{};
      for (final entity in _outbox.getAll()) {
        if (!_isBlockingOutboxStatus(_outboxStatusFromInt(entity.state))) {
          continue;
        }
        final reference = entity.protectedLeaseReference;
        if (reference == null) continue;
        if (!_isProtectedPageLease(reference)) {
          throw _storageFailure('protected_outbound_lease_corrupt');
        }
        references.add(reference);
        if (references.length > maximumCount) {
          throw _storageFailure(
            'protected_outbound_lease_recovery_bound_exceeded',
          );
        }
      }
      return Set<String>.unmodifiable(references);
    });
  }

  @override
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  }) async {
    if (maximumCount <= 0 || maximumCount > 131072) {
      throw ArgumentError.value(maximumCount, 'maximumCount');
    }
    final captured = _store.runInTransaction(TxMode.read, () {
      final upperBound =
          (_checkpoints.count() * 2) +
          (_inbox.count() * 3) +
          _outbox.count() +
          (_recordMaps.count() * 2) +
          (_attachmentMaterializations.count() * 4);
      if (upperBound > maximumCount) {
        return const _ProtectedReferenceCapture.incomplete();
      }
      final references = <String>{};
      void capture(String? value) {
        if (value == null) return;
        if (_isNativeProtectedReference(value)) {
          references.add(value);
          return;
        }
        if (value.startsWith('obcs2.')) {
          throw _storageFailure('protected_reference_corrupt');
        }
      }

      void scanPaged<T>(Query<T> query, void Function(T entry) visit) {
        const pageSize = 1024;
        var offset = 0;
        try {
          while (true) {
            query
              ..offset = offset
              ..limit = pageSize;
            final page = query.find();
            for (final entry in page) {
              visit(entry);
            }
            if (page.length < pageSize) return;
            offset += page.length;
          }
        } finally {
          query.close();
        }
      }

      scanPaged((_inbox.query()..order(CloudInboxChangeEntity_.id)).build(), (
        entry,
      ) {
        // Deliberately include pending, applied, and quarantined rows. There is
        // no reviewed terminal-inbox compaction policy yet.
        capture(entry.encryptedServerRecordId);
        capture(entry.protectedSystemFieldsRef);
        capture(entry.encryptedPayloadRef);
      });
      scanPaged(
        (_outbox.query()..order(CloudOutboxOperationEntity_.id)).build(),
        (entry) => capture(entry.encryptedPayloadRef),
      );
      scanPaged(
        (_recordMaps.query()..order(CloudRecordMapEntity_.id)).build(),
        (entry) {
          capture(entry.encryptedServerRecordId);
          capture(entry.encryptedRawRecordRef);
        },
      );
      scanPaged(
        (_attachmentMaterializations.query()
              ..order(CloudAttachmentMaterializationEntity_.id))
            .build(),
        (entry) {
          capture(entry.protectedTempReference);
          capture(entry.protectedResumeManifestReference);
          capture(entry.protectedContentVerificationReference);
          capture(entry.protectedFinalReference);
        },
      );

      final checkpoints = <_ProtectedCheckpointCapture>[];
      scanPaged(
        (_checkpoints.query()..order(CloudSyncCheckpointEntity_.id)).build(),
        (entry) {
          final scope = _scopeFromCheckpointEntity(entry);
          for (final ciphertext in [
            entry.fetchedTokenCiphertext,
            entry.pendingFetchedTokenCiphertext,
          ]) {
            if (ciphertext == null) continue;
            checkpoints.add(
              _ProtectedCheckpointCapture(scope: scope, ciphertext: ciphertext),
            );
          }
        },
      );
      return _ProtectedReferenceCapture(
        references: references,
        checkpoints: checkpoints,
        isComplete: true,
      );
    });
    if (!captured.isComplete) {
      return CloudProtectedReferenceSnapshot(
        references: const {},
        isComplete: false,
      );
    }

    final references = captured.references.toSet();
    for (final checkpoint in captured.checkpoints) {
      final value = await _protector
          .unprotect(
            scope: checkpoint.scope,
            kind: CloudSyncProtectedValueKind.checkpointToken,
            ciphertext: checkpoint.ciphertext,
          )
          .catchError((Object _) {
            throw _storageFailure('checkpoint_unprotect_failed');
          });
      if (_isNativeProtectedReference(value)) {
        references.add(value);
      } else if (value.startsWith('obcs2.')) {
        throw _storageFailure('protected_reference_corrupt');
      }
      if (references.length > maximumCount) {
        return CloudProtectedReferenceSnapshot(
          references: const {},
          isComplete: false,
        );
      }
    }
    return CloudProtectedReferenceSnapshot(
      references: references,
      isComplete: true,
    );
  }

  @override
  Future<void> releaseAdoptedProtectedPageLeaseReferences(
    Iterable<String> leaseReferences,
  ) async {
    final references = leaseReferences.toSet();
    if (references.any((reference) => !_isProtectedPageLease(reference))) {
      throw _storageFailure('protected_page_lease_reference_invalid');
    }
    if (references.isEmpty) return;
    _store.runInTransaction(TxMode.write, () {
      for (final reference in references) {
        final entity = _findProtectedPageLeaseLocked(reference);
        if (entity != null) {
          _protectedPageLeases.remove(entity.id);
        }
      }
    });
  }

  @override
  Future<void> recordPullFailure(
    CloudSyncScope scope, {
    required CloudFailureCategory category,
    required DateTime nextEligibleAt,
  }) async {
    final nowMs = _nowMs();
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      checkpoint
        ..lastAttemptAtMs = nowMs
        ..lastErrorCategory = category.name
        ..backoffAttempt += 1
        ..nextEligibleAtMs = nextEligibleAt.millisecondsSinceEpoch
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);
    });
  }

  @override
  Future<void> recordPullSuccess(
    CloudSyncScope scope, {
    required DateTime now,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      checkpoint
        ..lastSuccessfulAtMs = nowMs
        ..lastAttemptAtMs = nowMs
        ..lastErrorCategory = null
        ..backoffAttempt = 0
        ..nextEligibleAtMs = 0
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);
    });
  }

  @override
  Future<List<CloudInboxEntry>> readEligibleInbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
  }) async {
    _requirePositiveLimit(limit);
    final scopeKey = _scopeKey(scope);
    final nowMs = now.millisecondsSinceEpoch;
    final checkpoint = _findCheckpointByKeyLocked(scopeKey);
    if (checkpoint != null) _validateCheckpointScope(checkpoint, scope);
    final nextSequence = (checkpoint?.appliedSequence ?? 0) + 1;
    final entity = _findInboxBySequenceLocked(scope, nextSequence);
    if (entity == null ||
        _inboxStatusFromInt(entity.status) != CloudInboxStatus.pending ||
        entity.nextEligibleAtMs > nowMs) {
      return const <CloudInboxEntry>[];
    }
    return <CloudInboxEntry>[_inboxFromEntity(scope, entity)];
  }

  @override
  Future<void> markInboxApplied(
    CloudSyncScope scope, {
    required int sequence,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final entity = _requireInboxLocked(scope, sequence);
      final status = _inboxStatusFromInt(entity.status);
      if (status == CloudInboxStatus.applied) {
        _promotePendingFetchedTokenIfTerminalLocked(scope, transactionNowMs);
        return;
      }
      if (status != CloudInboxStatus.pending) {
        throw _storageFailure('inbox_transition_not_pending');
      }
      entity
        ..status = _inboxStatusToInt(CloudInboxStatus.applied)
        ..failureCategory = null
        ..nextEligibleAtMs = 0
        ..completedAtMs = transactionNowMs
        ..updatedAtMs = transactionNowMs;
      _inbox.put(entity);
      _advanceContiguousAppliedLocked(scope, transactionNowMs);
    });
  }

  @override
  Future<void> markInboxRetryable(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory category,
    required DateTime now,
    required DateTime nextEligibleAt,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final entity = _requireInboxLocked(scope, sequence);
      if (_inboxStatusFromInt(entity.status) != CloudInboxStatus.pending) {
        throw _storageFailure('inbox_transition_not_pending');
      }
      final nextEligibleAtMs = nextEligibleAt.millisecondsSinceEpoch;
      if (entity.failureCategory == category.name &&
          entity.nextEligibleAtMs >= nextEligibleAtMs) {
        return;
      }
      entity
        ..status = _inboxStatusToInt(CloudInboxStatus.pending)
        ..retryCount += 1
        ..failureCategory = category.name
        ..nextEligibleAtMs = entity.nextEligibleAtMs > nextEligibleAtMs
            ? entity.nextEligibleAtMs
            : nextEligibleAtMs
        ..updatedAtMs = transactionNowMs;
      _inbox.put(entity);
    });
  }

  @override
  Future<void> quarantineInbox(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory category,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final entity = _requireInboxLocked(scope, sequence);
      final status = _inboxStatusFromInt(entity.status);
      if (status == CloudInboxStatus.quarantined &&
          entity.failureCategory == category.name) {
        return;
      }
      if (status != CloudInboxStatus.pending) {
        throw _storageFailure('inbox_transition_not_pending');
      }
      entity
        ..status = _inboxStatusToInt(CloudInboxStatus.quarantined)
        ..retryCount += 1
        ..failureCategory = category.name
        ..nextEligibleAtMs = 0
        ..completedAtMs = transactionNowMs
        ..updatedAtMs = transactionNowMs;
      _inbox.put(entity);
    });
  }

  @override
  Future<void> enqueueOutbox(CloudOutboxOperation operation) async {
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(
        operation.scope,
        nowMs: operation.createdAt.millisecondsSinceEpoch,
      );
      _fenceStaleOutboxLocked(
        operation.scope,
        checkpoint: checkpoint,
        nowMs: operation.createdAt.millisecondsSinceEpoch,
      );
      if (operation.checkpointGeneration != checkpoint.generation) {
        throw _storageFailure('outbox_generation_mismatch');
      }
      if (operation.mutationRevision > checkpoint.mutationRevisionCounter) {
        checkpoint
          ..mutationRevisionCounter = operation.mutationRevision
          ..updatedAtMs = operation.createdAt.millisecondsSinceEpoch;
        _checkpoints.put(checkpoint);
      }
      _enqueueOutboxLocked(operation);
    });
  }

  @override
  Future<CloudOutboxOperation> enqueueOutboxMutation(
    CloudOutboxDraft draft,
  ) async {
    return _store.runInTransaction(TxMode.write, () {
      final nowMs = draft.createdAt.millisecondsSinceEpoch;
      final checkpoint = _checkpointLocked(draft.scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(
        draft.scope,
        checkpoint: checkpoint,
        nowMs: nowMs,
      );
      final revision = checkpoint.mutationRevisionCounter + 1;
      checkpoint
        ..mutationRevisionCounter = revision
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);

      final operation = CloudOutboxOperation(
        scope: draft.scope,
        operationId: CloudOperationIdentity.forMutation(
          scope: draft.scope,
          logicalEntityKeyHash: draft.logicalEntityKeyHash,
          action: draft.action,
          payloadVersion: draft.payloadVersion,
          mutationRevision: revision,
          payloadSha256: draft.payloadSha256,
        ),
        logicalEntityKeyHash: draft.logicalEntityKeyHash,
        action: draft.action,
        payloadVersion: draft.payloadVersion,
        mutationRevision: revision,
        checkpointGeneration: checkpoint.generation,
        encryptedPayloadReference: draft.encryptedPayloadReference,
        payloadSha256: draft.payloadSha256,
        serverRecordIdHash: draft.serverRecordIdHash,
        protectedLeaseReference: draft.protectedLeaseReference,
        dependencyOperationIds: draft.dependencyOperationIds,
        createdAt: draft.createdAt,
      );
      _enqueueOutboxLocked(operation);
      return operation;
    });
  }

  /// Atomically adopts one protected create envelope into both the outbox and
  /// its stable server-record mapping. Native lease commit happens only after
  /// this transaction returns successfully.
  Future<CloudOutboxOperation> admitProtectedOutboundCreate({
    required CloudOutboxDraft draft,
    required CloudRecordMapEntry recordMapping,
  }) async {
    if (draft.action != CloudOutboxAction.save ||
        draft.payloadVersion != 1 ||
        draft.dependencyOperationIds.isNotEmpty ||
        draft.protectedLeaseReference == null ||
        !_isProtectedPageLease(draft.protectedLeaseReference!) ||
        draft.encryptedPayloadReference == null ||
        !_isNativeProtectedReference(draft.encryptedPayloadReference!) ||
        draft.payloadSha256 == null ||
        !_isContentDigest(draft.payloadSha256!) ||
        draft.serverRecordIdHash == null ||
        !_isNativeDigest(draft.logicalEntityKeyHash) ||
        !_isNativeDigest(draft.serverRecordIdHash!) ||
        recordMapping.scope != draft.scope ||
        recordMapping.logicalEntityKeyHash != draft.logicalEntityKeyHash ||
        recordMapping.serverRecordIdHash != draft.serverRecordIdHash ||
        recordMapping.encryptedServerRecordId !=
            draft.encryptedPayloadReference ||
        recordMapping.etagHash != null ||
        recordMapping.encryptedRawRecordReference != null) {
      throw _storageFailure('protected_outbound_admission_invalid');
    }
    return _store.runInTransaction(TxMode.write, () {
      final nowMs = draft.createdAt.millisecondsSinceEpoch;
      final checkpoint = _checkpointLocked(draft.scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(
        draft.scope,
        checkpoint: checkpoint,
        nowMs: nowMs,
      );
      final operationId = CloudOperationIdentity.forInitialCreate(
        scope: draft.scope,
        logicalEntityKeyHash: draft.logicalEntityKeyHash,
        payloadVersion: draft.payloadVersion,
      );
      final existingOperation = _findOutboxByOperationIdLocked(operationId);
      if (existingOperation != null) {
        final existing = _outboxFromEntity(draft.scope, existingOperation);
        if (existing.scope != draft.scope ||
            existing.logicalEntityKeyHash != draft.logicalEntityKeyHash ||
            existing.action != CloudOutboxAction.save ||
            existing.payloadVersion != draft.payloadVersion ||
            existing.payloadSha256 != draft.payloadSha256) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'protected_outbound_retry_payload_changed',
          );
        }
        return existing;
      }

      final mapKey = _scopedDigest(
        draft.scope,
        'record-map',
        draft.logicalEntityKeyHash,
      );
      final existingMapping = _findRecordMapByKeyLocked(mapKey);
      if (existingMapping != null &&
          existingMapping.generation == checkpoint.generation &&
          existingMapping.serverRecordIdHash !=
              recordMapping.serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      final reverseCollision = _findRecordMapsForScopeLocked(draft.scope).any(
        (entity) =>
            entity.generation == checkpoint.generation &&
            entity.serverRecordIdHash == recordMapping.serverRecordIdHash &&
            entity.logicalEntityKeyHash != draft.logicalEntityKeyHash,
      );
      if (reverseCollision) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_reverse_collision',
        );
      }

      final revision = checkpoint.mutationRevisionCounter + 1;
      checkpoint
        ..mutationRevisionCounter = revision
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);
      final operation = CloudOutboxOperation(
        scope: draft.scope,
        operationId: operationId,
        logicalEntityKeyHash: draft.logicalEntityKeyHash,
        action: CloudOutboxAction.save,
        payloadVersion: draft.payloadVersion,
        mutationRevision: revision,
        checkpointGeneration: checkpoint.generation,
        encryptedPayloadReference: draft.encryptedPayloadReference,
        payloadSha256: draft.payloadSha256,
        serverRecordIdHash: draft.serverRecordIdHash,
        protectedLeaseReference: draft.protectedLeaseReference,
        dependencyOperationIds: draft.dependencyOperationIds,
        createdAt: draft.createdAt,
      );
      _enqueueOutboxLocked(operation);
      _recordMaps.put(
        CloudRecordMapEntity(
          id: existingMapping?.id ?? 0,
          mapKey: mapKey,
          scopeKey: _scopeKey(draft.scope),
          accountFingerprint: draft.scope.accountFingerprint,
          zone: draft.scope.zone,
          logicalEntityKeyHash: draft.logicalEntityKeyHash,
          serverRecordIdHash: recordMapping.serverRecordIdHash,
          generation: checkpoint.generation,
          encryptedServerRecordId: recordMapping.encryptedServerRecordId,
          etagHash: recordMapping.etagHash,
          encryptedRawRecordRef: recordMapping.encryptedRawRecordReference,
          updatedAtMs: nowMs,
        ),
      );
      return operation;
    });
  }

  @override
  Future<CloudSyncResetCompletionProof> rebootstrapAfterReset(
    CloudSyncResetRebootstrapRequest request, {
    required DateTime now,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    late int previousGeneration;
    late int nextGeneration;
    _store.runInTransaction(TxMode.write, () {
      final leaseKey = _scopedDigest(request.scope, 'coordinator-lease', 'v1');
      final activeLease = _findLeaseByKeyLocked(leaseKey);
      if (activeLease != null && activeLease.expiresAtMs > nowMs) {
        throw _storageFailure('reset_rebootstrap_coordinator_active');
      }

      final checkpoint = _checkpointLocked(request.scope, nowMs: nowMs);
      if (checkpoint.generation != request.expectedGeneration) {
        throw _storageFailure('reset_rebootstrap_generation_mismatch');
      }
      previousGeneration = checkpoint.generation;
      nextGeneration = previousGeneration + 1;
      checkpoint
        ..generation = nextGeneration
        ..fetchedTokenCiphertext = null
        ..pendingFetchedTokenCiphertext = null
        ..pendingBatchId = null
        ..lastBatchId = null
        ..fetchedSequence = 0
        ..appliedSequence = 0
        ..lastSuccessfulAtMs = 0
        ..lastAttemptAtMs = 0
        ..lastErrorCategory = null
        ..backoffAttempt = 0
        ..nextEligibleAtMs = 0
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);

      // Keep rows as evidence, but make every old-generation operation
      // terminal and every old mapping unreadable by the active generation.
      _fenceStaleOutboxLocked(
        request.scope,
        checkpoint: checkpoint,
        nowMs: nowMs,
      );
      for (final entity in _findRecordMapsForScopeLocked(request.scope)) {
        entity
          ..generation = 0
          ..updatedAtMs = nowMs;
        _recordMaps.put(entity);
      }
      for (final entity in _findInboxForScopeLocked(request.scope)) {
        final status = _inboxStatusFromInt(entity.status);
        entity
          ..generation = 0
          ..updatedAtMs = nowMs;
        if (status == CloudInboxStatus.pending) {
          entity
            ..status = _inboxStatusToInt(CloudInboxStatus.quarantined)
            ..retryCount += 1
            ..failureCategory = CloudFailureCategory.localStorage.name
            ..nextEligibleAtMs = 0
            ..completedAtMs = nowMs;
        }
        _inbox.put(entity);
      }
    });
    return CloudSyncResetCompletionProof(
      scope: request.scope,
      transitionIdHash: request.transitionIdHash,
      activeIdentityFingerprint: request.activeIdentityFingerprint,
      previousGeneration: previousGeneration,
      generation: nextGeneration,
      protectedRemoteStateProofReference:
          request.protectedRemoteStateProofReference,
    );
  }

  @override
  Future<CloudSyncCheckpoint> advanceOutboxGeneration(
    CloudSyncScope scope, {
    required DateTime now,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    _store.runInTransaction(TxMode.write, () {
      final leaseKey = _scopedDigest(scope, 'coordinator-lease', 'v1');
      final activeLease = _findLeaseByKeyLocked(leaseKey);
      if (activeLease != null && activeLease.expiresAtMs > nowMs) {
        throw _storageFailure('generation_advance_coordinator_active');
      }
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      checkpoint
        ..generation += 1
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);
      _fenceStaleOutboxLocked(scope, checkpoint: checkpoint, nowMs: nowMs);
    });
    // Preserve the caller-visible protected continuation token. It is never
    // needed inside the fencing transaction and is deliberately unprotected
    // only after the durable generation advance commits.
    return readCheckpoint(scope);
  }

  @override
  Future<List<CloudOutboxOperation>> leaseEligibleOutbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
    required Set<CloudOutboxAction> allowedActions,
  }) async {
    _requirePositiveLimit(limit);
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(scope, checkpoint: checkpoint, nowMs: nowMs);
      _recoverExpiredOutboxLeasesLocked(scope, nowMs);
      final allEntities = _findOutboxForScopeLocked(scope).toList();
      final blockingByLogicalKey = <String, CloudOutboxOperationEntity>{};
      for (final entity in allEntities) {
        if (!_isBlockingOutboxStatus(_outboxStatusFromInt(entity.state))) {
          continue;
        }
        final existing = blockingByLogicalKey[entity.logicalEntityKeyHash];
        if (existing == null || _compareMutationOrder(entity, existing) < 0) {
          blockingByLogicalKey[entity.logicalEntityKeyHash] = entity;
        }
      }

      final candidates =
          allEntities
              .where(
                (entity) =>
                    _outboxStatusFromInt(entity.state) ==
                        CloudOutboxStatus.pending &&
                    allowedActions.contains(_actionFromInt(entity.action)) &&
                    entity.nextEligibleAtMs <= nowMs,
              )
              .toList()
            ..sort((first, second) {
              final revision = first.mutationRevision.compareTo(
                second.mutationRevision,
              );
              if (revision != 0) return revision;
              return first.operationId.compareTo(second.operationId);
            });

      final allById = {
        for (final entity in allEntities) entity.operationId: entity,
      };
      final leased = <CloudOutboxOperation>[];
      for (final entity in candidates) {
        if (leased.length == limit) break;
        final blocker = blockingByLogicalKey[entity.logicalEntityKeyHash];
        if (blocker != null && _compareMutationOrder(blocker, entity) < 0) {
          continue;
        }
        final dependencies = _decodeDependencies(
          entity.dependencyOperationIdsJson,
        );
        final dependenciesConfirmed = dependencies.every((operationId) {
          final dependency = allById[operationId];
          return dependency != null &&
              dependency.checkpointGeneration == entity.checkpointGeneration &&
              _outboxStatusFromInt(dependency.state) ==
                  CloudOutboxStatus.confirmed;
        });
        if (!dependenciesConfirmed) continue;

        entity
          ..state = _outboxStatusToInt(CloudOutboxStatus.leased)
          ..leaseIdHash = leaseIdHash
          ..leaseExpiresAtMs = now.add(leaseDuration).millisecondsSinceEpoch
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
        leased.add(_outboxFromEntity(scope, entity, leaseId: leaseId));
      }
      return leased;
    });
  }

  @override
  Future<List<CloudOutboxOperation>> leaseUnknownOutcomes(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
  }) async {
    _requirePositiveLimit(limit);
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(scope, checkpoint: checkpoint, nowMs: nowMs);
      final eligible =
          _findOutboxForScopeLocked(scope)
              .where(
                (entity) =>
                    entity.checkpointGeneration == checkpoint.generation &&
                    _outboxStatusFromInt(entity.state) ==
                        CloudOutboxStatus.unknownOutcome &&
                    entity.appleRequestUuid != null &&
                    entity.appleOperationUuid != null &&
                    entity.leaseExpiresAtMs <= nowMs &&
                    entity.nextEligibleAtMs <= nowMs,
              )
              .toList()
            ..sort((first, second) {
              final revision = first.mutationRevision.compareTo(
                second.mutationRevision,
              );
              if (revision != 0) return revision;
              return first.operationId.compareTo(second.operationId);
            });

      final leased = <CloudOutboxOperation>[];
      for (final entity in eligible) {
        if (leased.length == limit) break;
        entity
          ..state = _outboxStatusToInt(CloudOutboxStatus.unknownOutcome)
          ..leaseIdHash = leaseIdHash
          ..leaseExpiresAtMs = now.add(leaseDuration).millisecondsSinceEpoch
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
        leased.add(_outboxFromEntity(scope, entity, leaseId: leaseId));
      }
      return leased;
    });
  }

  @override
  Future<List<CloudOutboxOperation>> markOutboxSubmissionStarted(
    CloudSyncScope scope, {
    required String leaseId,
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required DateTime now,
  }) async {
    final ids = submissionIdentity.operationUuids.keys.toList(growable: false);
    if (ids.isEmpty) {
      throw ArgumentError('outbox_submission_operation_ids_empty');
    }
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      final entities = <String, CloudOutboxOperationEntity>{};
      for (final operationId in ids) {
        if (entities.containsKey(operationId)) {
          throw _storageFailure('duplicate_outbox_submission_operation');
        }
        final entity = _findOutboxByOperationIdLocked(operationId);
        if (entity == null ||
            entity.scopeKey != _scopeKey(scope) ||
            entity.checkpointGeneration <= 0 ||
            entity.checkpointGeneration != checkpoint.generation) {
          throw _storageFailure('stale_outbox_generation');
        }
        if (_outboxStatusFromInt(entity.state) != CloudOutboxStatus.leased ||
            entity.leaseIdHash != leaseIdHash ||
            entity.leaseExpiresAtMs <= nowMs) {
          throw _storageFailure('stale_outbox_lease');
        }
        if (entity.appleRequestUuid != null ||
            entity.appleOperationUuid != null) {
          throw _storageFailure('outbox_submission_identity_already_assigned');
        }
        entities[operationId] = entity;
      }
      for (final entity in entities.values) {
        entity
          ..state = _outboxStatusToInt(CloudOutboxStatus.unknownOutcome)
          ..lastErrorCategory = CloudFailureCategory.unknown.name
          ..appleRequestUuid = submissionIdentity.requestUuid
          ..appleOperationUuid =
              submissionIdentity.operationUuids[entity.operationId]
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
      }
      return entities.values
          .map((entity) => _outboxFromEntity(scope, entity, leaseId: leaseId))
          .toList(growable: false);
    });
  }

  @override
  Future<void> applyOutboxTransitions(
    CloudSyncScope scope, {
    required String leaseId,
    required Iterable<CloudOutboxTransition> transitions,
    required DateTime now,
  }) async {
    final transitionList = transitions.toList(growable: false);
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      final entities = <String, CloudOutboxOperationEntity>{};
      for (final transition in transitionList) {
        if (entities.containsKey(transition.operationId)) {
          throw _storageFailure('duplicate_outbox_transition');
        }
        final entity = _findOutboxByOperationIdLocked(transition.operationId);
        if (entity != null &&
            (entity.checkpointGeneration <= 0 ||
                entity.checkpointGeneration != checkpoint.generation)) {
          throw _storageFailure('stale_outbox_generation');
        }
        if (entity == null ||
            entity.scopeKey != _scopeKey(scope) ||
            (_outboxStatusFromInt(entity.state) != CloudOutboxStatus.leased &&
                _outboxStatusFromInt(entity.state) !=
                    CloudOutboxStatus.unknownOutcome) ||
            entity.leaseIdHash != leaseIdHash ||
            entity.leaseExpiresAtMs <= nowMs) {
          throw _storageFailure('stale_outbox_lease');
        }
        _validateTransition(transition);
        entities[transition.operationId] = entity;
      }

      for (final transition in transitionList) {
        final entity = entities[transition.operationId]!;
        switch (transition.type) {
          case CloudOutboxTransitionType.confirmed:
            entity
              ..state = _outboxStatusToInt(CloudOutboxStatus.confirmed)
              ..confirmedAtMs = nowMs
              ..lastErrorCategory = null
              ..nextEligibleAtMs = 0;
            break;
          case CloudOutboxTransitionType.retryable:
            entity
              ..state = _outboxStatusToInt(CloudOutboxStatus.pending)
              ..attemptCount += 1
              ..nextEligibleAtMs =
                  transition.nextEligibleAt!.millisecondsSinceEpoch
              ..lastErrorCategory = transition.category!.name
              ..encryptedPayloadRef =
                  transition.encryptedPayloadReference ??
                  entity.encryptedPayloadRef
              ..payloadSha256 = transition.payloadSha256 ?? entity.payloadSha256
              ..serverRecordIdHash =
                  transition.serverRecordIdHash ?? entity.serverRecordIdHash;
            if (transition.clearSubmissionIdentity) {
              entity
                ..appleRequestUuid = null
                ..appleOperationUuid = null;
            }
            break;
          case CloudOutboxTransitionType.paused:
            entity
              ..state = _outboxStatusToInt(CloudOutboxStatus.paused)
              ..attemptCount += 1
              ..nextEligibleAtMs =
                  transition.nextEligibleAt?.millisecondsSinceEpoch ?? 0
              ..lastErrorCategory = transition.category!.name;
            if (transition.clearSubmissionIdentity) {
              entity
                ..appleRequestUuid = null
                ..appleOperationUuid = null;
            }
            break;
          case CloudOutboxTransitionType.quarantined:
            entity
              ..state = _outboxStatusToInt(CloudOutboxStatus.quarantined)
              ..attemptCount += 1
              ..nextEligibleAtMs = 0
              ..lastErrorCategory =
                  (transition.category ?? CloudFailureCategory.unknown).name;
            break;
          case CloudOutboxTransitionType.unknownOutcome:
            if (transition.category != CloudFailureCategory.unknown) {
              throw ArgumentError(
                'Unknown outcome transitions require unknown category',
              );
            }
            entity
              ..state = _outboxStatusToInt(CloudOutboxStatus.unknownOutcome)
              ..attemptCount += 1
              ..nextEligibleAtMs =
                  transition.nextEligibleAt?.millisecondsSinceEpoch ?? 0
              ..lastErrorCategory = CloudFailureCategory.unknown.name;
            break;
        }
        entity
          ..leaseIdHash = null
          ..leaseExpiresAtMs = 0
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
      }
    });
  }

  @override
  Future<int> recoverExpiredOutboxLeases(
    CloudSyncScope scope, {
    required DateTime now,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(scope, checkpoint: checkpoint, nowMs: nowMs);
      return _recoverExpiredOutboxLeasesLocked(scope, nowMs);
    });
  }

  @override
  Future<void> attachOutboxRecordMapping(
    CloudSyncScope scope, {
    required String leaseId,
    required String operationId,
    required String serverRecordIdHash,
    required DateTime now,
  }) async {
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      final entity = _findOutboxByOperationIdLocked(operationId);
      if (entity != null &&
          (entity.checkpointGeneration <= 0 ||
              entity.checkpointGeneration != checkpoint.generation)) {
        throw _storageFailure('stale_outbox_generation');
      }
      if (entity == null ||
          entity.scopeKey != _scopeKey(scope) ||
          _outboxStatusFromInt(entity.state) != CloudOutboxStatus.leased ||
          entity.leaseIdHash != leaseIdHash ||
          entity.leaseExpiresAtMs <= nowMs) {
        throw _storageFailure('stale_outbox_lease');
      }
      if (entity.serverRecordIdHash != null &&
          entity.serverRecordIdHash != serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      entity
        ..serverRecordIdHash = serverRecordIdHash
        ..updatedAtMs = _nowMs();
      _outbox.put(entity);
    });
  }

  @override
  Future<int> resumePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(scope, checkpoint: checkpoint, nowMs: nowMs);
      var resumed = 0;
      for (final entity in _findOutboxForScopeLocked(scope)) {
        if (_outboxStatusFromInt(entity.state) != CloudOutboxStatus.paused ||
            entity.lastErrorCategory == null ||
            entity.nextEligibleAtMs > nowMs ||
            !categories
                .map((category) => category.name)
                .contains(entity.lastErrorCategory)) {
          continue;
        }
        entity
          ..state = _outboxStatusToInt(CloudOutboxStatus.pending)
          ..lastErrorCategory = null
          ..nextEligibleAtMs = nowMs
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
        resumed++;
      }
      return resumed;
    });
  }

  @override
  Future<Set<CloudFailureCategory>> readPausedOutboxFailureCategories(
    CloudSyncScope scope, {
    required DateTime now,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.read, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (checkpoint == null) return <CloudFailureCategory>{};
      return _findOutboxForScopeLocked(scope)
          .where(
            (entity) =>
                entity.checkpointGeneration == checkpoint.generation &&
                _outboxStatusFromInt(entity.state) ==
                    CloudOutboxStatus.paused &&
                entity.nextEligibleAtMs <= nowMs,
          )
          .map((entity) => entity.lastErrorCategory)
          .whereType<String>()
          .map(_failureOrNull)
          .whereType<CloudFailureCategory>()
          .toSet();
    });
  }

  /// Read-only, exact-scope inspection used by the manual one-row canary and
  /// its process-death recovery path. No row is leased or mutated.
  Future<List<CloudOutboxOperation>> readOutboxEntries(
    CloudSyncScope scope,
  ) async {
    return _store.runInTransaction(TxMode.read, () {
      final entries = _findOutboxForScopeLocked(scope)
          .map((entity) => _outboxFromEntity(scope, entity))
          .toList(growable: false);
      entries.sort((left, right) {
        final revision = left.mutationRevision.compareTo(
          right.mutationRevision,
        );
        return revision != 0
            ? revision
            : left.operationId.compareTo(right.operationId);
      });
      return entries;
    });
  }

  @override
  Future<int> postponeEligiblePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
    required DateTime nextEligibleAt,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    final nextEligibleAtMs = nextEligibleAt.millisecondsSinceEpoch;
    final categoryNames = categories.map((category) => category.name).toSet();
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(scope, checkpoint: checkpoint, nowMs: nowMs);
      var postponed = 0;
      for (final entity in _findOutboxForScopeLocked(scope)) {
        if (_outboxStatusFromInt(entity.state) != CloudOutboxStatus.paused ||
            entity.lastErrorCategory == null ||
            !categoryNames.contains(entity.lastErrorCategory) ||
            entity.nextEligibleAtMs > nowMs) {
          continue;
        }
        entity
          ..nextEligibleAtMs = nextEligibleAtMs
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
        postponed++;
      }
      return postponed;
    });
  }

  @override
  Future<CloudCoordinatorLeaseFence?> tryAcquireCoordinatorLease(
    CloudSyncScope scope, {
    required String ownerId,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    if (ownerId.isEmpty) throw ArgumentError.value(ownerId, 'ownerId');
    final scopeKey = _scopeKey(scope);
    final leaseKey = _scopedDigest(scope, 'coordinator-lease', 'v1');
    final ownerIdHash = _digest('coordinator-owner\u001f$ownerId');
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      final existing = _findLeaseByKeyLocked(leaseKey);
      if (existing != null && existing.expiresAtMs > nowMs) return null;
      final generation = (existing?.generation ?? 0) + 1;
      _leases.put(
        CloudSyncLeaseEntity(
          id: existing?.id ?? 0,
          leaseKey: leaseKey,
          scopeKey: scopeKey,
          accountFingerprint: scope.accountFingerprint,
          ownerIdHash: ownerIdHash,
          generation: generation,
          acquiredAtMs: nowMs,
          expiresAtMs: now.add(leaseDuration).millisecondsSinceEpoch,
        ),
      );
      return CloudCoordinatorLeaseFence(
        ownerId: ownerId,
        generation: generation,
      );
    });
  }

  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    if (leaseFence.ownerId.isEmpty) {
      throw ArgumentError.value(leaseFence.ownerId, 'leaseFence.ownerId');
    }
    final leaseKey = _scopedDigest(scope, 'coordinator-lease', 'v1');
    final ownerIdHash = _digest('coordinator-owner\u001f${leaseFence.ownerId}');
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      final existing = _findLeaseByKeyLocked(leaseKey);
      if (existing == null ||
          existing.scopeKey != _scopeKey(scope) ||
          existing.ownerIdHash != ownerIdHash ||
          existing.generation != leaseFence.generation ||
          existing.expiresAtMs <= nowMs) {
        return false;
      }
      existing.expiresAtMs = now.add(leaseDuration).millisecondsSinceEpoch;
      _leases.put(existing);
      return true;
    });
  }

  @override
  Future<void> releaseCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    final leaseKey = _scopedDigest(scope, 'coordinator-lease', 'v1');
    final ownerIdHash = _digest('coordinator-owner\u001f${leaseFence.ownerId}');
    _store.runInTransaction(TxMode.write, () {
      final existing = _findLeaseByKeyLocked(leaseKey);
      if (existing != null &&
          existing.scopeKey == _scopeKey(scope) &&
          existing.ownerIdHash == ownerIdHash &&
          existing.generation == leaseFence.generation) {
        // Preserve the generation tombstone. Deleting the row would let a
        // same-owner release/reacquire cycle reuse generation 1 and make an
        // old fence valid again.
        existing.expiresAtMs = 0;
        _leases.put(existing);
      }
    });
  }

  @override
  Future<CloudRecordMapEntry?> readRecordMap(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
    required int generation,
  }) async {
    final mapKey = _scopedDigest(scope, 'record-map', logicalEntityKeyHash);
    return _store.runInTransaction(TxMode.read, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (generation <= 0 || checkpoint?.generation != generation) {
        throw _storageFailure('record_map_generation_mismatch');
      }
      final entity = _findRecordMapByKeyLocked(mapKey);
      if (entity == null || entity.generation != generation) return null;
      if (entity.scopeKey != _scopeKey(scope)) {
        throw _storageFailure('scope_collision');
      }
      return CloudRecordMapEntry(
        scope: scope,
        logicalEntityKeyHash: entity.logicalEntityKeyHash,
        serverRecordIdHash: entity.serverRecordIdHash,
        encryptedServerRecordId: entity.encryptedServerRecordId,
        etagHash: entity.etagHash,
        encryptedRawRecordReference: entity.encryptedRawRecordRef,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          entity.updatedAtMs,
          isUtc: true,
        ),
      );
    });
  }

  @override
  Future<void> upsertRecordMap(
    CloudRecordMapEntry entry, {
    required int generation,
  }) async {
    final mapKey = _scopedDigest(
      entry.scope,
      'record-map',
      entry.logicalEntityKeyHash,
    );
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(
        entry.scope,
        nowMs: entry.updatedAt.millisecondsSinceEpoch,
      );
      if (generation <= 0 || checkpoint.generation != generation) {
        throw _storageFailure('record_map_generation_mismatch');
      }
      final existing = _findRecordMapByKeyLocked(mapKey);
      if (existing != null &&
          existing.generation == generation &&
          existing.serverRecordIdHash != entry.serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      _recordMaps.put(
        CloudRecordMapEntity(
          id: existing?.id ?? 0,
          mapKey: mapKey,
          scopeKey: _scopeKey(entry.scope),
          accountFingerprint: entry.scope.accountFingerprint,
          zone: entry.scope.zone,
          logicalEntityKeyHash: entry.logicalEntityKeyHash,
          serverRecordIdHash: entry.serverRecordIdHash,
          generation: generation,
          encryptedServerRecordId: existing?.generation == generation
              ? existing!.encryptedServerRecordId
              : entry.encryptedServerRecordId,
          etagHash: entry.etagHash,
          encryptedRawRecordRef: entry.encryptedRawRecordReference,
          updatedAtMs: entry.updatedAt.millisecondsSinceEpoch,
        ),
      );
    });
  }

  @override
  Future<void> recordRun(CloudSyncRunRecord run) async {
    _store.runInTransaction(TxMode.write, () {
      _runs.put(
        CloudSyncRunEntity(
          runId: _scopedDigest(run.scope, 'run', run.runId),
          scopeKey: _scopeKey(run.scope),
          accountFingerprint: run.scope.accountFingerprint,
          trigger: run.triggerName,
          architecture: run.architectureName,
          mode: run.modeName,
          fetchedCount: run.counters.fetched,
          appliedCount: run.counters.applied,
          deferredCount: run.counters.deferred,
          quarantinedCount: run.counters.quarantined,
          confirmedCount: run.counters.confirmed,
          retriedCount: run.counters.retried,
          startedAtMs: run.startedAt.millisecondsSinceEpoch,
          finishedAtMs: run.finishedAt.millisecondsSinceEpoch,
          failureCategory: run.failureCategory?.name,
        ),
      );
      _trimRunHistoryLocked(run.scope);
    });
  }

  Future<String?> _protectCheckpointToken(
    CloudSyncScope scope,
    String? token,
  ) async {
    if (token == null) return null;
    try {
      return await _protector.protect(
        scope: scope,
        kind: CloudSyncProtectedValueKind.checkpointToken,
        plaintext: token,
      );
    } catch (_) {
      throw _storageFailure('checkpoint_protect_failed');
    }
  }

  CloudSyncCheckpointEntity _checkpointLocked(
    CloudSyncScope scope, {
    required int nowMs,
  }) {
    final checkpointKey = _scopeKey(scope);
    final existing = _findCheckpointByKeyLocked(checkpointKey);
    if (existing != null) {
      _validateCheckpointScope(existing, scope);
      if (existing.generation == 0) {
        if (existing.fetchedTokenCiphertext != null ||
            existing.pendingFetchedTokenCiphertext != null ||
            existing.pendingBatchId != null ||
            existing.lastBatchId != null ||
            existing.fetchedSequence != 0 ||
            existing.appliedSequence != 0 ||
            existing.mutationRevisionCounter != 0 ||
            _findInboxForScopeLocked(scope).isNotEmpty) {
          throw _storageFailure(
            'checkpoint_generation_zero_requires_rebootstrap',
          );
        }
        existing
          ..generation = 1
          ..updatedAtMs = nowMs;
        _checkpoints.put(existing);
      }
      if (existing.generation <= 0) {
        throw _storageFailure('checkpoint_generation_invalid');
      }
      return existing;
    }
    final created = CloudSyncCheckpointEntity(
      checkpointKey: checkpointKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      persistenceLane: scope.persistenceLane.name,
      updatedAtMs: nowMs,
    );
    created.id = _checkpoints.put(created);
    return created;
  }

  CloudSyncCheckpoint _checkpointFromEntity(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity entity, {
    required String? fetchedToken,
    bool hasUnmarkedPendingInbox = false,
  }) {
    _validateCheckpointScope(entity, scope);
    return CloudSyncCheckpoint(
      scope: scope,
      fetchedToken: fetchedToken,
      generation: entity.generation,
      lastBatchId: entity.lastBatchId,
      pendingBatchId: entity.pendingBatchId,
      hasUnmarkedPendingInbox: hasUnmarkedPendingInbox,
      fetchedSequence: entity.fetchedSequence,
      lastAppliedSequence: entity.appliedSequence,
      mutationRevisionCounter: entity.mutationRevisionCounter,
      consecutivePullFailures: entity.backoffAttempt,
      nextPullEligibleAt: _dateOrNull(entity.nextEligibleAtMs),
      lastSuccessfulRunAt: _dateOrNull(entity.lastSuccessfulAtMs),
      lastFailure: _failureOrNull(entity.lastErrorCategory),
    );
  }

  void _validateCheckpointScope(
    CloudSyncCheckpointEntity entity,
    CloudSyncScope scope,
  ) {
    if (entity.checkpointKey != _scopeKey(scope) ||
        entity.accountFingerprint != scope.accountFingerprint ||
        entity.container != scope.container ||
        entity.database != scope.database ||
        entity.zone != scope.zone ||
        entity.streamKind != scope.streamKind.name ||
        entity.schemaVersion != scope.schemaVersion ||
        _persistenceLaneFromName(entity.persistenceLane) !=
            scope.persistenceLane) {
      throw _storageFailure('scope_collision');
    }
  }

  CloudInboxEntry _inboxFromEntity(
    CloudSyncScope scope,
    CloudInboxChangeEntity entity,
  ) {
    if (entity.scopeKey != _scopeKey(scope)) {
      throw _storageFailure('scope_collision');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(entity.changeIdHash)) {
      throw _storageFailure('inbox_change_id_missing_or_invalid');
    }
    return CloudInboxEntry(
      scope: scope,
      sequence: entity.fetchSequence,
      change: CloudFetchedChange(
        changeId: entity.changeIdHash,
        recordIdHash: entity.serverRecordIdHash,
        etagHash: entity.etagHash,
        type: _changeTypeFromName(entity.changeType),
        encryptedServerRecordId: entity.encryptedServerRecordId,
        protectedSystemFieldsReference: entity.protectedSystemFieldsRef,
        encryptedPayloadReference: entity.encryptedPayloadRef,
        payloadSha256: entity.payloadSha256,
        isTombstone: entity.isTombstone,
        serverModifiedAt: _dateOrNull(entity.serverModifiedAtMs),
        preflightFailure: _failureOrNull(
          entity.preflightCategory ??
              (entity.retryCount == 0 ? entity.failureCategory : null),
        ),
        preflightCode: _preflightCodeOrNull(entity.preflightCode),
      ),
      status: _inboxStatusFromInt(entity.status),
      attemptCount: entity.retryCount,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        entity.createdAtMs,
        isUtc: true,
      ),
      batchId: entity.batchId,
      generation: entity.generation,
      nextEligibleAt: _dateOrNull(entity.nextEligibleAtMs),
      lastFailure: _failureOrNull(entity.failureCategory),
      completedAt: _dateOrNull(entity.completedAtMs),
    );
  }

  CloudOutboxOperation _outboxFromEntity(
    CloudSyncScope scope,
    CloudOutboxOperationEntity entity, {
    String? leaseId,
  }) {
    if (entity.scopeKey != _scopeKey(scope)) {
      throw _storageFailure('scope_collision');
    }
    return CloudOutboxOperation(
      scope: scope,
      operationId: entity.operationId,
      logicalEntityKeyHash: entity.logicalEntityKeyHash,
      action: _actionFromInt(entity.action),
      payloadVersion: entity.payloadVersion,
      mutationRevision: entity.mutationRevision,
      checkpointGeneration: entity.checkpointGeneration,
      encryptedPayloadReference: entity.encryptedPayloadRef,
      payloadSha256: entity.payloadSha256,
      serverRecordIdHash: entity.serverRecordIdHash,
      protectedLeaseReference: entity.protectedLeaseReference,
      appleRequestUuid: entity.appleRequestUuid,
      appleOperationUuid: entity.appleOperationUuid,
      dependencyOperationIds: _decodeDependencies(
        entity.dependencyOperationIdsJson,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        entity.createdAtMs,
        isUtc: true,
      ),
      status: _outboxStatusFromInt(entity.state),
      attemptCount: entity.attemptCount,
      nextEligibleAt: _dateOrNull(entity.nextEligibleAtMs),
      lastFailure: _failureOrNull(entity.lastErrorCategory),
      leaseId: leaseId,
      leaseExpiresAt: _dateOrNull(entity.leaseExpiresAtMs),
      confirmedAt: _dateOrNull(entity.confirmedAtMs),
    );
  }

  void _enqueueOutboxLocked(CloudOutboxOperation operation) {
    final identical = _findOutboxByOperationIdLocked(operation.operationId);
    if (identical != null) {
      if (identical.scopeKey != _scopeKey(operation.scope)) {
        throw _storageFailure('outbox_operation_scope_collision');
      }
      return;
    }

    if (operation.action == CloudOutboxAction.save) {
      final candidates = _findOutboxForScopeLocked(operation.scope)
          .where(
            (entity) =>
                _actionFromInt(entity.action) == CloudOutboxAction.save &&
                entity.logicalEntityKeyHash == operation.logicalEntityKeyHash,
          )
          .toList();
      final newerOrEqualExists = candidates.any(
        (entity) =>
            _outboxStatusFromInt(entity.state) !=
                CloudOutboxStatus.quarantined &&
            entity.mutationRevision >= operation.mutationRevision,
      );
      if (newerOrEqualExists) return;

      final superseded = candidates
          .where(
            (entity) =>
                _outboxStatusFromInt(entity.state) ==
                    CloudOutboxStatus.pending &&
                entity.mutationRevision < operation.mutationRevision,
          )
          .toList();
      final supersededIds = superseded
          .map((entity) => entity.operationId)
          .toSet();
      if (supersededIds.isNotEmpty) {
        for (final dependent in _findOutboxForScopeLocked(operation.scope)) {
          if (_outboxStatusFromInt(dependent.state) !=
              CloudOutboxStatus.pending) {
            continue;
          }
          final dependencies = _decodeDependencies(
            dependent.dependencyOperationIdsJson,
          );
          if (!dependencies.any(supersededIds.contains)) continue;
          dependent
            ..dependencyOperationIdsJson = _encodeDependencies({
              ...dependencies.where(
                (dependency) => !supersededIds.contains(dependency),
              ),
              operation.operationId,
            })
            ..updatedAtMs = operation.createdAt.millisecondsSinceEpoch;
          _outbox.put(dependent);
        }
        _outbox.removeMany(
          superseded.map((entity) => entity.id).toList(growable: false),
        );
      }
    }
    _outbox.put(_outboxEntity(operation));
  }

  CloudOutboxOperationEntity _outboxEntity(CloudOutboxOperation operation) {
    final createdAtMs = operation.createdAt.millisecondsSinceEpoch;
    return CloudOutboxOperationEntity(
      operationId: operation.operationId,
      scopeKey: _scopeKey(operation.scope),
      accountFingerprint: operation.scope.accountFingerprint,
      zone: operation.scope.zone,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      action: _actionToInt(operation.action),
      dependencyOperationIdsJson: _encodeDependencies(
        operation.dependencyOperationIds,
      ),
      payloadVersion: operation.payloadVersion,
      mutationRevision: operation.mutationRevision,
      checkpointGeneration: operation.checkpointGeneration,
      encryptedPayloadRef: operation.encryptedPayloadReference,
      payloadSha256: operation.payloadSha256,
      protectedLeaseReference: operation.protectedLeaseReference,
      state: _outboxStatusToInt(operation.status),
      attemptCount: operation.attemptCount,
      nextEligibleAtMs: operation.nextEligibleAt?.millisecondsSinceEpoch ?? 0,
      lastErrorCategory: operation.lastFailure?.name,
      serverRecordIdHash: operation.serverRecordIdHash,
      appleRequestUuid: operation.appleRequestUuid,
      appleOperationUuid: operation.appleOperationUuid,
      leaseIdHash: operation.leaseId == null
          ? null
          : _digest('outbox-lease\u001f${operation.leaseId}'),
      leaseExpiresAtMs: operation.leaseExpiresAt?.millisecondsSinceEpoch ?? 0,
      confirmedAtMs: operation.confirmedAt?.millisecondsSinceEpoch ?? 0,
      createdAtMs: createdAtMs,
      updatedAtMs: createdAtMs,
    );
  }

  int _recoverExpiredOutboxLeasesLocked(CloudSyncScope scope, int nowMs) {
    var recovered = 0;
    for (final entity in _findOutboxForScopeLocked(scope)) {
      if (_outboxStatusFromInt(entity.state) == CloudOutboxStatus.leased &&
          entity.leaseExpiresAtMs > 0 &&
          entity.leaseExpiresAtMs <= nowMs) {
        entity
          ..state = _outboxStatusToInt(CloudOutboxStatus.pending)
          ..leaseIdHash = null
          ..leaseExpiresAtMs = 0
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
        recovered++;
      }
    }
    return recovered;
  }

  void _fenceStaleOutboxLocked(
    CloudSyncScope scope, {
    required CloudSyncCheckpointEntity checkpoint,
    required int nowMs,
  }) {
    for (final entity in _findOutboxForScopeLocked(scope)) {
      final status = _outboxStatusFromInt(entity.state);
      if (!_isBlockingOutboxStatus(status) ||
          entity.checkpointGeneration == checkpoint.generation) {
        continue;
      }
      entity
        ..state = _outboxStatusToInt(CloudOutboxStatus.quarantined)
        ..attemptCount += 1
        ..lastErrorCategory = CloudFailureCategory.localStorage.name
        ..nextEligibleAtMs = 0
        ..leaseIdHash = null
        ..leaseExpiresAtMs = 0
        ..updatedAtMs = nowMs;
      _outbox.put(entity);
    }
  }

  bool _isBlockingOutboxStatus(CloudOutboxStatus status) =>
      status == CloudOutboxStatus.pending ||
      status == CloudOutboxStatus.leased ||
      status == CloudOutboxStatus.paused ||
      status == CloudOutboxStatus.unknownOutcome;

  int _compareMutationOrder(
    CloudOutboxOperationEntity first,
    CloudOutboxOperationEntity second,
  ) {
    final revision = first.mutationRevision.compareTo(second.mutationRevision);
    if (revision != 0) return revision;
    return first.operationId.compareTo(second.operationId);
  }

  void _advanceContiguousAppliedLocked(CloudSyncScope scope, int nowMs) {
    final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
    var next = checkpoint.appliedSequence + 1;
    while (true) {
      final entity = _findInboxBySequenceLocked(scope, next);
      if (entity == null ||
          !_isAppliedInboxStatus(_inboxStatusFromInt(entity.status))) {
        break;
      }
      next++;
    }
    final appliedThrough = next - 1;
    if (appliedThrough != checkpoint.appliedSequence) {
      checkpoint
        ..appliedSequence = appliedThrough
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);
    }
    _promotePendingFetchedTokenIfTerminalLocked(scope, nowMs);
  }

  void _promotePendingFetchedTokenIfTerminalLocked(
    CloudSyncScope scope,
    int nowMs,
  ) {
    final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
    final pendingBatchId = checkpoint.pendingBatchId;
    if (pendingBatchId == null) return;

    final batchQuery =
        _inbox
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(_scopeKey(scope))
                  .and(
                    CloudInboxChangeEntity_.generation.equals(
                      checkpoint.generation,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.batchId.equals(pendingBatchId)),
            )
            .build()
          ..limit = 1;
    try {
      if (batchQuery.findFirst() == null) return;
    } finally {
      batchQuery.close();
    }

    final nonterminalQuery =
        _inbox
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(_scopeKey(scope))
                  .and(
                    CloudInboxChangeEntity_.generation.equals(
                      checkpoint.generation,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.batchId.equals(pendingBatchId))
                  .and(
                    CloudInboxChangeEntity_.status.notEquals(
                      _inboxStatusToInt(CloudInboxStatus.applied),
                    ),
                  ),
            )
            .build()
          ..limit = 1;
    try {
      if (nonterminalQuery.findFirst() != null) return;
    } finally {
      nonterminalQuery.close();
    }

    if (checkpoint.pendingBatchId != pendingBatchId) {
      return;
    }

    checkpoint
      ..fetchedTokenCiphertext = checkpoint.pendingFetchedTokenCiphertext
      ..pendingFetchedTokenCiphertext = null
      ..pendingBatchId = null
      ..updatedAtMs = nowMs;
    _checkpoints.put(checkpoint);
  }

  bool _hasUnmarkedPendingInboxLocked(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity checkpoint,
  ) {
    if (checkpoint.pendingBatchId != null) return false;
    // A missing sequence has no row for the query below to discover. Treat
    // every unmarked fetched/applied gap as unsafe legacy state and require an
    // explicit recovery path instead of advancing a continuation token.
    if (checkpoint.fetchedSequence > checkpoint.appliedSequence) return true;
    final query =
        _inbox
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(_scopeKey(scope))
                  .and(
                    CloudInboxChangeEntity_.generation.equals(
                      checkpoint.generation,
                    ),
                  )
                  .and(
                    CloudInboxChangeEntity_.status.notEquals(
                      _inboxStatusToInt(CloudInboxStatus.applied),
                    ),
                  ),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst() != null;
    } finally {
      query.close();
    }
  }

  bool _isAppliedInboxStatus(CloudInboxStatus status) =>
      status == CloudInboxStatus.applied;

  void _validateTransition(CloudOutboxTransition transition) {
    if (transition.type == CloudOutboxTransitionType.retryable &&
        (transition.category == null || transition.nextEligibleAt == null)) {
      throw ArgumentError(
        'Retryable outbox transitions require category and next time',
      );
    }
    if (transition.type == CloudOutboxTransitionType.paused &&
        transition.category == null) {
      throw ArgumentError(
        'Paused outbox transitions require a failure category',
      );
    }
  }

  void _trimRunHistoryLocked(CloudSyncScope scope) {
    final builder = _runs.query(
      CloudSyncRunEntity_.scopeKey.equals(_scopeKey(scope)),
    )..order(CloudSyncRunEntity_.startedAtMs);
    final query = builder.build();
    try {
      final rows = query.find();
      final excess = rows.length - _maximumRetainedRunsPerScope;
      if (excess > 0) {
        _runs.removeMany(
          rows.take(excess).map((row) => row.id).toList(growable: false),
        );
      }
    } finally {
      query.close();
    }
  }

  CloudShadowJournalUsage _shadowJournalUsageLocked(
    CloudSyncScope scope,
    CloudShadowJournalBudget budget,
  ) {
    final builder = _inbox.query(
      CloudInboxChangeEntity_.scopeKey
          .equals(_scopeKey(scope))
          .and(
            CloudInboxChangeEntity_.status.equals(
              _inboxStatusToInt(CloudInboxStatus.pending),
            ),
          ),
    )..order(CloudInboxChangeEntity_.fetchSequence);
    final query = builder.build();
    try {
      var usage = CloudShadowJournalUsage.empty;
      for (final entity in query.find()) {
        final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
        if (checkpoint == null || entity.generation != checkpoint.generation) {
          continue;
        }
        final entry = _inboxFromEntity(scope, entity);
        usage = usage.add(
          entries: 1,
          bytes: budget.estimateEntryBytes(
            scope: scope,
            batchId: entry.batchId,
            change: entry.change,
          ),
          oldestAt: entry.createdAt,
        );
      }
      return usage;
    } finally {
      query.close();
    }
  }

  CloudSyncCheckpointEntity? _findCheckpointByKeyLocked(String key) {
    final query =
        _checkpoints
            .query(CloudSyncCheckpointEntity_.checkpointKey.equals(key))
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudInboxChangeEntity? _findInboxByChangeKeyLocked(String key) {
    final query =
        _inbox.query(CloudInboxChangeEntity_.changeKey.equals(key)).build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudInboxChangeEntity? _findInboxBySequenceLocked(
    CloudSyncScope scope,
    int sequence,
  ) {
    final query = _inbox
        .query(
          CloudInboxChangeEntity_.scopeKey
              .equals(_scopeKey(scope))
              .and(CloudInboxChangeEntity_.fetchSequence.equals(sequence)),
        )
        .build();
    try {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      final matches = query
          .find()
          .where((entity) => entity.generation == checkpoint?.generation)
          .toList(growable: false);
      if (matches.length > 1) {
        throw _storageFailure('inbox_sequence_ambiguous');
      }
      return matches.isEmpty ? null : matches.single;
    } finally {
      query.close();
    }
  }

  List<CloudInboxChangeEntity> _findInboxForScopeLocked(CloudSyncScope scope) {
    final query = _inbox
        .query(CloudInboxChangeEntity_.scopeKey.equals(_scopeKey(scope)))
        .build();
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudRecordMapEntity> _findRecordMapsForScopeLocked(
    CloudSyncScope scope,
  ) {
    final query = _recordMaps
        .query(CloudRecordMapEntity_.scopeKey.equals(_scopeKey(scope)))
        .build();
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  CloudInboxChangeEntity _requireInboxLocked(
    CloudSyncScope scope,
    int sequence,
  ) {
    final entity = _findInboxBySequenceLocked(scope, sequence);
    if (entity == null) throw _storageFailure('inbox_entry_missing');
    return entity;
  }

  List<CloudOutboxOperationEntity> _findOutboxForScopeLocked(
    CloudSyncScope scope,
  ) {
    final query = _outbox
        .query(CloudOutboxOperationEntity_.scopeKey.equals(_scopeKey(scope)))
        .build();
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  CloudOutboxOperationEntity? _findOutboxByOperationIdLocked(
    String operationId,
  ) {
    final query =
        _outbox
            .query(CloudOutboxOperationEntity_.operationId.equals(operationId))
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudSyncLeaseEntity? _findLeaseByKeyLocked(String leaseKey) {
    final query =
        _leases.query(CloudSyncLeaseEntity_.leaseKey.equals(leaseKey)).build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  void _requireActiveCoordinatorLeaseLocked(
    CloudSyncScope scope,
    CloudCoordinatorLeaseFence leaseFence, {
    required int nowMs,
  }) {
    final leaseKey = _scopedDigest(scope, 'coordinator-lease', 'v1');
    final ownerIdHash = _digest('coordinator-owner\u001f${leaseFence.ownerId}');
    final lease = _findLeaseByKeyLocked(leaseKey);
    if (lease == null ||
        lease.scopeKey != _scopeKey(scope) ||
        lease.ownerIdHash != ownerIdHash ||
        lease.generation != leaseFence.generation ||
        lease.expiresAtMs <= nowMs) {
      throw _storageFailure('coordinator_lease_fence_lost');
    }
  }

  void _adoptProtectedPageLeaseLocked(
    CloudFetchBatch batch, {
    required int nowMs,
  }) {
    final leaseReference = batch.protectedPageLeaseReference;
    if (leaseReference == null) return;
    if (!_isProtectedPageLease(leaseReference)) {
      throw _storageFailure('protected_page_lease_reference_invalid');
    }
    final scopeKey = _scopeKey(batch.scope);
    final batchIdHash = _digest('protected-page-batch\u001f${batch.batchId}');
    final existing = _findProtectedPageLeaseLocked(leaseReference);
    if (existing != null) {
      if (existing.scopeKey != scopeKey ||
          existing.accountFingerprint != batch.scope.accountFingerprint ||
          existing.generation != batch.generation ||
          existing.batchIdHash != batchIdHash) {
        throw _storageFailure('protected_page_lease_adoption_collision');
      }
      return;
    }
    _protectedPageLeases.put(
      CloudProtectedPageLeaseEntity(
        leaseReference: leaseReference,
        scopeKey: scopeKey,
        accountFingerprint: batch.scope.accountFingerprint,
        generation: batch.generation,
        batchIdHash: batchIdHash,
        adoptedAtMs: nowMs,
      ),
    );
  }

  CloudProtectedPageLeaseEntity? _findProtectedPageLeaseLocked(
    String leaseReference,
  ) {
    final query =
        _protectedPageLeases
            .query(
              CloudProtectedPageLeaseEntity_.leaseReference.equals(
                leaseReference,
              ),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  bool _isProtectedPageLease(String value) =>
      RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(value);

  bool _isNativeProtectedReference(String value) =>
      RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$').hasMatch(value);

  bool _isNativeDigest(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

  bool _isContentDigest(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  CloudSyncScope _scopeFromCheckpointEntity(CloudSyncCheckpointEntity entity) {
    final stream = CloudSyncStreamKind.values
        .where((candidate) => candidate.name == entity.streamKind)
        .toList(growable: false);
    if (stream.length != 1) {
      throw _storageFailure('checkpoint_stream_invalid');
    }
    final scope = CloudSyncScope(
      accountFingerprint: entity.accountFingerprint,
      container: entity.container,
      database: entity.database,
      zone: entity.zone,
      streamKind: stream.single,
      schemaVersion: entity.schemaVersion,
      persistenceLane: _persistenceLaneFromName(entity.persistenceLane),
    );
    _validateCheckpointScope(entity, scope);
    return scope;
  }

  CloudRecordMapEntity? _findRecordMapByKey(String mapKey) {
    final query =
        _recordMaps.query(CloudRecordMapEntity_.mapKey.equals(mapKey)).build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudRecordMapEntity? _findRecordMapByKeyLocked(String mapKey) =>
      _findRecordMapByKey(mapKey);

  String _scopeKey(CloudSyncScope scope) => cloudSyncPersistentScopeKey(scope);

  String _scopedDigest(CloudSyncScope scope, String purpose, String value) =>
      '$purpose:${_digest('${scope.storageKey}\u001f$purpose\u001f$value')}';

  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

  String _changeKey(CloudSyncScope scope, int generation, String changeId) =>
      generation == 1
      ? _scopedDigest(scope, 'change', changeId)
      : _scopedDigest(scope, 'change-generation-$generation', changeId);

  String _encodeDependencies(Iterable<String> values) {
    final sorted = values.toSet().toList()..sort();
    return jsonEncode(sorted);
  }

  Set<String> _decodeDependencies(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List ||
          decoded.any((value) => value is! String || value.isEmpty)) {
        throw const FormatException();
      }
      return decoded.cast<String>().toSet();
    } catch (_) {
      throw _storageFailure('outbox_dependencies_invalid');
    }
  }

  DateTime? _dateOrNull(int milliseconds) => milliseconds <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);

  CloudFailureCategory? _failureOrNull(String? name) {
    if (name == null) return null;
    for (final value in CloudFailureCategory.values) {
      if (value.name == name) return value;
    }
    throw _storageFailure('failure_category_invalid');
  }

  CloudPreflightCode? _preflightCodeOrNull(String? name) {
    if (name == null) return null;
    for (final value in CloudPreflightCode.values) {
      if (value.name == name) return value;
    }
    // A future or corrupted value must stay quarantined without becoming an
    // arbitrary diagnostic string.
    return CloudPreflightCode.unknown;
  }

  CloudSyncPersistenceLane _persistenceLaneFromName(String? name) {
    if (name == null || name.isEmpty) return CloudSyncPersistenceLane.legacy;
    for (final value in CloudSyncPersistenceLane.values) {
      if (value.name == name) return value;
    }
    throw _storageFailure('persistence_lane_invalid');
  }

  CloudChangeType _changeTypeFromName(String name) {
    for (final value in CloudChangeType.values) {
      if (value.name == name) return value;
    }
    throw _storageFailure('change_type_invalid');
  }

  int _inboxStatusToInt(CloudInboxStatus status) => switch (status) {
    CloudInboxStatus.pending => 0,
    CloudInboxStatus.applied => 1,
    CloudInboxStatus.quarantined => 2,
  };

  CloudInboxStatus _inboxStatusFromInt(int status) => switch (status) {
    0 => CloudInboxStatus.pending,
    1 => CloudInboxStatus.applied,
    2 => CloudInboxStatus.quarantined,
    _ => throw _storageFailure('inbox_status_invalid'),
  };

  int _actionToInt(CloudOutboxAction action) => switch (action) {
    CloudOutboxAction.save => 0,
    CloudOutboxAction.delete => 1,
  };

  CloudOutboxAction _actionFromInt(int action) => switch (action) {
    0 => CloudOutboxAction.save,
    1 => CloudOutboxAction.delete,
    _ => throw _storageFailure('outbox_action_invalid'),
  };

  int _outboxStatusToInt(CloudOutboxStatus status) => switch (status) {
    CloudOutboxStatus.pending => 0,
    CloudOutboxStatus.leased => 1,
    CloudOutboxStatus.confirmed => 2,
    CloudOutboxStatus.paused => 3,
    CloudOutboxStatus.quarantined => 4,
    CloudOutboxStatus.unknownOutcome => 5,
  };

  CloudOutboxStatus _outboxStatusFromInt(int status) => switch (status) {
    0 => CloudOutboxStatus.pending,
    1 => CloudOutboxStatus.leased,
    2 => CloudOutboxStatus.confirmed,
    3 => CloudOutboxStatus.paused,
    4 => CloudOutboxStatus.quarantined,
    5 => CloudOutboxStatus.unknownOutcome,
    _ => throw _storageFailure('outbox_status_invalid'),
  };

  void _requirePositiveLimit(int limit) {
    if (limit <= 0 || limit > 256 * 8) {
      throw ArgumentError.value(limit, 'limit');
    }
  }

  int _nowMs() => _clock().toUtc().millisecondsSinceEpoch;

  CloudSyncFailure _storageFailure(String safeCode) => CloudSyncFailure(
    category: CloudFailureCategory.localStorage,
    safeCode: safeCode,
  );
}

final class _ProtectedCheckpointCapture {
  const _ProtectedCheckpointCapture({
    required this.scope,
    required this.ciphertext,
  });

  final CloudSyncScope scope;
  final String ciphertext;
}

final class _ProtectedReferenceCapture {
  const _ProtectedReferenceCapture({
    required this.references,
    required this.checkpoints,
    required this.isComplete,
  });

  const _ProtectedReferenceCapture.incomplete()
    : references = const {},
      checkpoints = const [],
      isComplete = false;

  final Set<String> references;
  final List<_ProtectedCheckpointCapture> checkpoints;
  final bool isComplete;
}
