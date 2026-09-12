import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_operation_identity.dart';
import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_local_mutation_journal.dart';
import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_chat_identity_evidence.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_message_dependency.dart';
import 'cloud_sync_outbound_chat_origin.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_record_maps.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_semantic_diagnostics.dart';
import 'cloud_sync_store.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';

/// Durable ObjectBox implementation of the Cloud Sync V2 journal and outbox.
///
/// Every state transition that changes a checkpoint, lease, journal entry, or
/// outbox operation is synchronous inside one ObjectBox transaction. Network
/// and platform-keystore work always happen outside the transaction.
class ObjectBoxCloudSyncStore
    implements
        CloudSyncStore,
        CloudRetainedUnprojectedBacklogStore,
        CloudRetainedUnprojectedBacklogSummaryStore,
        CloudUnknownInboxBarrierRecoveryStore,
        CloudLegacyOwnershipConflictBarrierRecoveryStore,
        CloudPretransactionChatConflictBarrierRecoveryStore,
        CloudPretransactionAttachmentConflictBarrierRecoveryStore,
        CloudSyncUnknownOutcomeLeasingStore,
        CloudSyncOutboxPresenceStore,
        CloudCoordinatorLeaseStatusReader,
        CloudProtectedPageLeaseAdoptionStore,
        CloudProtectedOutboundLeaseAdoptionStore,
        CloudConfirmedOutboundReceiptStore,
        CloudMessageCreateReadbackStore,
        CloudMessageUpdateReadbackStore {
  ObjectBoxCloudSyncStore({
    required Store store,
    required this._protector,
    DateTime Function()? clock,
    CloudSyncLocalSendJournal? localSendJournal,
    CloudSyncLocalMutationJournal? localMutationJournal,
    CloudSyncAttachmentUploadJournal? attachmentUploadJournal,
    this._readChatIdentityEvidence,
    CloudSyncSemanticDiagnosticRecorder? recordExistingHistoryDiagnostic,
  }) : _store = store,
       _localSendJournal = localSendJournal,
       _localMutationJournal = localMutationJournal,
       // Keep the public named parameter stable while the field stays private.
       // ignore: prefer_initializing_formals
       _attachmentUploadJournal = attachmentUploadJournal,
       // Keep the public named parameter stable while the field stays private.
       // ignore: prefer_initializing_formals
       _recordExistingHistoryDiagnostic = recordExistingHistoryDiagnostic,
       _clock = clock ?? DateTime.now,
       _checkpoints = store.box<CloudSyncCheckpointEntity>(),
       _inbox = store.box<CloudInboxChangeEntity>(),
       _leases = store.box<CloudSyncLeaseEntity>(),
       _protectedPageLeases = store.box<CloudProtectedPageLeaseEntity>(),
       _outbox = store.box<CloudOutboxOperationEntity>(),
       _recordMaps = store.box<CloudRecordMapEntity>(),
       _writerAuthorities = store.box<CloudKitWriterAuthorityEntity>(),
       _attachmentMaterializations = store
           .box<CloudAttachmentMaterializationEntity>(),
       _semanticReplays = store.box<CloudSemanticReplayEntity>(),
       _runs = store.box<CloudSyncRunEntity>() {
    if (localSendJournal != null && !localSendJournal.isBoundToStore(store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    if (localMutationJournal != null &&
        !localMutationJournal.isBoundToStore(store)) {
      throw StateError('cloud_sync_local_mutation_adoption_store_mismatch');
    }
  }

  factory ObjectBoxCloudSyncStore.fromDatabase({
    required CloudSyncProtector protector,
  }) {
    return ObjectBoxCloudSyncStore(store: Database.store, protector: protector);
  }

  static const int _maximumRetainedRunsPerScope = 256;
  final CloudSyncChatIdentityEvidence? Function(CloudOutboxOperation operation)?
  _readChatIdentityEvidence;
  final CloudSyncSemanticDiagnosticRecorder? _recordExistingHistoryDiagnostic;
  static const String _messagesCloudContainer = 'com.apple.messages.cloud';
  static const String _messagesCloudDatabase = 'private';
  static const Set<String> _messagesCloudSemanticZones = <String>{
    'chatManateeZone',
    'messageManateeZone',
    'attachmentManateeZone',
  };
  static const Set<int> _recoverablePretransactionChatConflictRetryCounts =
      <int>{
        // Original auth-drift quarantine from the pretransaction decoder.
        1,
        // The same preserved row after the two signed diagnostic retries that
        // isolated and repaired the mixed-route Chat decoder contract.
        3,
      };
  static const Set<int>
  _recoverablePretransactionAttachmentConflictRetryCounts = <int>{1};

  final Store _store;
  // Explicitly scoped by the production local-send session. Generic/legacy
  // stores never infer local origin or relax their existing projection gate.
  final CloudSyncLocalSendJournal? _localSendJournal;
  final CloudSyncLocalMutationJournal? _localMutationJournal;
  final CloudSyncAttachmentUploadJournal? _attachmentUploadJournal;
  final CloudSyncProtector _protector;
  final DateTime Function() _clock;
  final Box<CloudSyncCheckpointEntity> _checkpoints;
  final Box<CloudInboxChangeEntity> _inbox;
  final Box<CloudSyncLeaseEntity> _leases;
  final Box<CloudProtectedPageLeaseEntity> _protectedPageLeases;
  final Box<CloudOutboxOperationEntity> _outbox;
  final Box<CloudRecordMapEntity> _recordMaps;
  final Box<CloudKitWriterAuthorityEntity> _writerAuthorities;
  final Box<CloudAttachmentMaterializationEntity> _attachmentMaterializations;
  final Box<CloudSemanticReplayEntity> _semanticReplays;
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

  /// Returns protected leases owned by outbox rows or local send sources.
  ///
  /// These references are intentionally returned separately from page leases:
  /// page-lease cleanup must not acknowledge or release an outbound receipt.
  /// Existing rows without the not-yet-generated schema property are treated
  /// as having no outbound lease reference.
  @override
  Future<Set<String>> readLiveProtectedOutboundLeaseReferences({
    required int maximumCount,
  }) async {
    if (maximumCount <= 0 || maximumCount > 4096) {
      throw ArgumentError.value(maximumCount, 'maximumCount');
    }
    return _store.runInTransaction(TxMode.read, () {
      final references = <String>{};
      for (final entity in _outbox.getAll()) {
        final status = _outboxStatusFromInt(entity.state);
        if (!_isBlockingOutboxStatus(status) &&
            status != CloudOutboxStatus.confirmed &&
            !cloudSyncIsNeverSubmittedChatCreate(entity) &&
            !cloudSyncIsRetiredUnsubmittedChatCreate(entity)) {
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
      final sources = _store
          .box<CloudSyncLocalSendIntentEntity>()
          .query(
            CloudSyncLocalSendIntentEntity_.protectedSourceBinding.notNull(),
          )
          .build();
      try {
        if (sources.count() > maximumCount) {
          throw _storageFailure(
            'protected_outbound_lease_recovery_bound_exceeded',
          );
        }
        for (final intent in sources.find()) {
          references.add(_localSendSource(intent)!.leaseReference);
          if (references.length > maximumCount) {
            throw _storageFailure(
              'protected_outbound_lease_recovery_bound_exceeded',
            );
          }
        }
      } finally {
        sources.close();
      }
      final mutations = _store
          .box<CloudSyncLocalMutationIntentEntity>()
          .query(CloudSyncLocalMutationIntentEntity_.state.notEquals(5))
          .build();
      try {
        if (mutations.count() > maximumCount) {
          throw _storageFailure(
            'protected_outbound_lease_recovery_bound_exceeded',
          );
        }
        for (final mutation in mutations.find()) {
          references.add(validateCloudSyncMutationRow(mutation).leaseReference);
          if (references.length > maximumCount) {
            throw _storageFailure(
              'protected_outbound_lease_recovery_bound_exceeded',
            );
          }
        }
      } finally {
        mutations.close();
      }
      for (final mapping in _recordMaps.getAll()) {
        _validatePendingMessageReadbackMappingLease(mapping);
        final reference = mapping.protectedReadbackLeaseReference;
        if (reference == null) continue;
        references.add(reference);
        if (references.length > maximumCount) {
          throw _storageFailure(
            'protected_outbound_lease_recovery_bound_exceeded',
          );
        }
      }
      // Upload preparation and result precede final-save outbox admission.
      // Retain leases across interruption/account replacement. The result
      // lease is also the final-save receipt: exact verified child readback
      // releases it. Its historical reference and payload are still retained.
      final uploads = _store.box<CloudAttachmentUploadEntity>();
      if (uploads.count() > maximumCount) {
        throw _storageFailure(
          'protected_outbound_lease_recovery_bound_exceeded',
        );
      }
      for (final upload in uploads.getAll()) {
        validateCloudAttachmentUploadRow(upload);
        references.add(upload.planLeaseReference);
        final resultLease = upload.resultLeaseReference;
        if (resultLease != null &&
            !CloudSyncAttachmentUploadJournal.resultLeaseReleasedAfterReadback(
              _store,
              upload,
            )) {
          references.add(resultLease);
        }
        if (references.length > maximumCount) {
          throw _storageFailure(
            'protected_outbound_lease_recovery_bound_exceeded',
          );
        }
      }
      return Set<String>.unmodifiable(references);
    });
  }

  static CloudSyncLocalSendSourceBinding? _localSendSource(
    CloudSyncLocalSendIntentEntity intent,
  ) {
    final encoded = intent.protectedSourceBinding;
    if (encoded == null) return null;
    final source = CloudSyncLocalSendSourceBinding.decode(encoded);
    source.requireOrigin(
      accountFingerprint: intent.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    return source;
  }

  @override
  Future<void> clearConfirmedProtectedOutboundLeaseReference({
    required CloudOutboxOperation expectedOperation,
    // Opt in only from the transport's validated no-save replay callback.
    // A terminal save or generic receipt cleanup does not prove readback.
    bool recordVerifiedLocalSendReadback = false,
  }) async {
    _requireConfirmedReceiptReleaseCandidate(expectedOperation);
    _store.runInTransaction(TxMode.write, () {
      final entity = _findOutboxByOperationIdLocked(
        expectedOperation.operationId,
      );
      if (entity == null) {
        throw _storageFailure('confirmed_outbound_receipt_row_missing');
      }
      if (entity.scopeKey != _scopeKey(expectedOperation.scope)) {
        throw _storageFailure('confirmed_outbound_receipt_snapshot_changed');
      }
      final current = _outboxFromEntity(expectedOperation.scope, entity);
      if (!current.sameDurableSnapshotAs(expectedOperation)) {
        throw _storageFailure('confirmed_outbound_receipt_snapshot_changed');
      }
      if (_requiresAttachmentReadbackLocked(current.operationId)) {
        if (!recordVerifiedLocalSendReadback) {
          throw _storageFailure('attachment_readback_required');
        }
        final uploads = _attachmentUploadJournal;
        if (uploads == null) {
          throw _storageFailure('attachment_upload_journal_required');
        }
        uploads.requireAdoptedOperation(current);
      }
      if (recordVerifiedLocalSendReadback) {
        final journal = _localSendJournal;
        if (journal == null) {
          final intentQuery = _store
              .box<CloudSyncLocalSendIntentEntity>()
              .query(
                CloudSyncLocalSendIntentEntity_.admittedOperationId.equals(
                  current.operationId,
                ),
              )
              .build();
          try {
            if (intentQuery.count() != 0) {
              throw StateError('cloud_sync_local_send_journal_required');
            }
          } finally {
            intentQuery.close();
          }
        } else {
          journal.recordConfirmedReadbackInTransaction(_store, current);
        }
      }
      entity.protectedLeaseReference = null;
      _outbox.put(entity);
    });
  }

  @override
  Future<bool> hasNonterminalOutbox(CloudSyncScope scope) async {
    return _store.runInTransaction(TxMode.read, () {
      return _hasBlockingOutboxLocked(scope);
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
      final activeMutationQuery = _store
          .box<CloudSyncLocalMutationIntentEntity>()
          .query(CloudSyncLocalMutationIntentEntity_.state.notEquals(5))
          .build();
      final activeMutationCount = activeMutationQuery.count();
      activeMutationQuery.close();
      final upperBound =
          (_checkpoints.count() * 2) +
          (_inbox.count() * 3) +
          _outbox.count() +
          (_recordMaps.count() * 2) +
          _writerAuthorities.count() +
          _store.box<CloudSyncLocalSendIntentEntity>().count() +
          activeMutationCount +
          (_store.box<CloudAttachmentUploadEntity>().count() * 2) +
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
          _validatePendingMessageReadbackMappingLease(entry);
        },
      );
      scanPaged(
        (_writerAuthorities.query()..order(CloudKitWriterAuthorityEntity_.id))
            .build(),
        (entry) => capture(entry.resetProofReference),
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
        (_store.box<CloudSyncLocalSendIntentEntity>().query()
              ..order(CloudSyncLocalSendIntentEntity_.id))
            .build(),
        (intent) => capture(_localSendSource(intent)?.protectedReference),
      );
      scanPaged(
        (_store.box<CloudSyncLocalMutationIntentEntity>().query(
              CloudSyncLocalMutationIntentEntity_.state.notEquals(5),
            )
              ..order(CloudSyncLocalMutationIntentEntity_.id))
            .build(),
        (intent) =>
            capture(validateCloudSyncMutationRow(intent).protectedReference),
      );
      // Upload plans and results own committed leases before final record
      // admission. Recovery must see their bytes, not only their lease IDs.
      // Keep every retained state/account until explicit journal retirement.
      scanPaged(
        (_store.box<CloudAttachmentUploadEntity>().query()
              ..order(CloudAttachmentUploadEntity_.id))
            .build(),
        (upload) {
          validateCloudAttachmentUploadRow(upload);
          capture(upload.planReference);
          capture(upload.resultReference);
        },
      );
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
    if (checkpoint == null) return const <CloudInboxEntry>[];
    _validateCheckpointScope(checkpoint, scope);
    final entity = _findFirstNonterminalInboxLocked(scope, checkpoint);
    if (entity == null ||
        _inboxStatusFromInt(entity.status) != CloudInboxStatus.pending ||
        entity.nextEligibleAtMs > nowMs) {
      return const <CloudInboxEntry>[];
    }
    return <CloudInboxEntry>[_inboxFromEntity(scope, entity)];
  }

  @override
  Future<int> readRetainedUnprojectedInboxCount(CloudSyncScope scope) async {
    return _store.runInTransaction(TxMode.read, () {
      final scopeKey = _scopeKey(scope);
      final checkpoint = _findCheckpointByKeyLocked(scopeKey);
      if (checkpoint == null) return 0;
      _validateCheckpointScope(checkpoint, scope);
      final query = _inbox
          .query(
            CloudInboxChangeEntity_.scopeKey
                .equals(scopeKey)
                .and(
                  CloudInboxChangeEntity_.generation.equals(
                    checkpoint.generation,
                  ),
                )
                .and(
                  CloudInboxChangeEntity_.status.equals(
                    _inboxStatusToInt(CloudInboxStatus.retainedUnprojected),
                  ),
                ),
          )
          .build();
      try {
        return query.count();
      } finally {
        query.close();
      }
    });
  }

  @override
  Future<CloudRetainedUnprojectedBacklogSummary>
  readRetainedUnprojectedInboxSummary(CloudSyncScope scope) async {
    return _store.runInTransaction(TxMode.read, () {
      final scopeKey = _scopeKey(scope);
      final checkpoint = _findCheckpointByKeyLocked(scopeKey);
      if (checkpoint == null) {
        return CloudRetainedUnprojectedBacklogSummary(
          total: 0,
          saves: 0,
          tombstones: 0,
          unclassified: 0,
        );
      }
      _validateCheckpointScope(checkpoint, scope);
      final total = _countRetainedUnprojectedLocked(
        scopeKey: scopeKey,
        generation: checkpoint.generation,
      );
      final tombstones = _countRetainedUnprojectedLocked(
        scopeKey: scopeKey,
        generation: checkpoint.generation,
        tombstone: true,
      );
      final saves = _countRetainedUnprojectedLocked(
        scopeKey: scopeKey,
        generation: checkpoint.generation,
        tombstone: false,
      );
      final outOfScopeServices = _countRetainedUnprojectedLocked(
        scopeKey: scopeKey,
        generation: checkpoint.generation,
        tombstone: false,
        failureCategory: CloudFailureCategory.outOfScopeService.name,
      );
      final categories = <CloudFailureCategory, int>{};
      var classified = 0;
      for (final category in CloudFailureCategory.values) {
        final count = _countRetainedUnprojectedLocked(
          scopeKey: scopeKey,
          generation: checkpoint.generation,
          failureCategory: category.name,
        );
        if (count > 0) {
          categories[category] = count;
          classified += count;
        }
      }
      return CloudRetainedUnprojectedBacklogSummary(
        total: total,
        saves: saves,
        tombstones: tombstones,
        unclassified: total - classified,
        outOfScopeServices: outOfScopeServices,
        byFailureCategory: categories,
      );
    });
  }

  int _countRetainedUnprojectedLocked({
    required String scopeKey,
    required int generation,
    bool? tombstone,
    String? failureCategory,
  }) {
    var condition = CloudInboxChangeEntity_.scopeKey
        .equals(scopeKey)
        .and(CloudInboxChangeEntity_.generation.equals(generation))
        .and(
          CloudInboxChangeEntity_.status.equals(
            _inboxStatusToInt(CloudInboxStatus.retainedUnprojected),
          ),
        );
    if (tombstone != null) {
      condition = condition.and(
        CloudInboxChangeEntity_.isTombstone.equals(tombstone),
      );
    }
    if (failureCategory != null) {
      condition = condition.and(
        CloudInboxChangeEntity_.failureCategory.equals(failureCategory),
      );
    }
    final query = _inbox.query(condition).build();
    try {
      return query.count();
    } finally {
      query.close();
    }
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
  Future<void> markInboxRetainedUnprojected(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory? category,
    required DateTime now,
    required int maximumDeferredAttempts,
    required Duration maximumDeferredAge,
    required CloudCoordinatorLeaseFence leaseFence,
    String? readOnlySemanticAttachmentConflictSafeCode,
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
      if (status == CloudInboxStatus.retainedUnprojected) {
        _promotePendingFetchedTokenIfTerminalLocked(scope, transactionNowMs);
        return;
      }
      if (status != CloudInboxStatus.pending &&
          status != CloudInboxStatus.quarantined) {
        throw _storageFailure('inbox_retention_transition_invalid');
      }
      final entry = _inboxFromEntity(scope, entity);
      if (status == CloudInboxStatus.quarantined &&
          entry.lastFailure != category) {
        throw _storageFailure('inbox_retention_category_mismatch');
      }
      if (!_mayRetainUnprojected(
        entry,
        category: category,
        now: DateTime.fromMillisecondsSinceEpoch(transactionNowMs, isUtc: true),
        maximumDeferredAttempts: maximumDeferredAttempts,
        maximumDeferredAge: maximumDeferredAge,
        includeCurrentAttempt: status == CloudInboxStatus.pending,
        readOnlySemanticAttachmentConflictSafeCode:
            readOnlySemanticAttachmentConflictSafeCode,
      )) {
        throw _storageFailure('inbox_retention_policy_rejected');
      }
      entity
        ..status = _inboxStatusToInt(CloudInboxStatus.retainedUnprojected)
        ..retryCount += status == CloudInboxStatus.pending ? 1 : 0
        ..failureCategory = category?.name
        ..nextEligibleAtMs = 0
        ..completedAtMs = transactionNowMs
        ..updatedAtMs = transactionNowMs;
      _inbox.put(entity);
      _promotePendingFetchedTokenIfTerminalLocked(scope, transactionNowMs);
    });
  }

  @override
  Future<CloudInboxRetentionRecovery> recoverRetainedInboxBarriers(
    CloudSyncScope scope, {
    required DateTime now,
    required int maximumDeferredAttempts,
    required Duration maximumDeferredAge,
    required CloudCoordinatorLeaseFence leaseFence,
    bool allowLegacyReadOnlyTombstoneAcknowledgement = false,
  }) async {
    return _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final checkpoint = _checkpointLocked(scope, nowMs: transactionNowMs);
      final rows =
          _findInboxForScopeLocked(
              scope,
            ).where((row) => row.generation == checkpoint.generation).toList()
            ..sort(
              (left, right) =>
                  left.fetchSequence.compareTo(right.fetchSequence),
            );
      if (rows.length != checkpoint.fetchedSequence ||
          rows.indexed.any((item) => item.$2.fetchSequence != item.$1 + 1)) {
        throw _storageFailure('inbox_retention_journal_incomplete');
      }
      if (rows.any(
        (row) =>
            row.scopeKey != _scopeKey(scope) ||
            row.accountFingerprint != scope.accountFingerprint ||
            row.zone != scope.zone ||
            row.generation != checkpoint.generation,
      )) {
        throw _storageFailure('inbox_retention_journal_scope_mismatch');
      }
      if (checkpoint.appliedSequence > checkpoint.fetchedSequence) {
        throw _storageFailure('inbox_retention_checkpoint_invalid');
      }
      final previousAppliedSequence = checkpoint.appliedSequence;
      var exactAppliedPrefix = 0;
      for (final row in rows) {
        if (!_isExactlyAppliedInboxStatus(_inboxStatusFromInt(row.status))) {
          break;
        }
        exactAppliedPrefix = row.fetchSequence;
      }
      final legacyAppliedFloorInflated =
          checkpoint.pendingBatchId == null &&
          checkpoint.appliedSequence > exactAppliedPrefix;
      final replayedSequences =
          allowLegacyReadOnlyTombstoneAcknowledgement &&
              legacyAppliedFloorInflated
          ? _semanticReplayInboxSequencesLocked(
              scope,
              generation: checkpoint.generation,
            )
          : const <int>{};

      final effectiveNow = DateTime.fromMillisecondsSinceEpoch(
        transactionNowMs,
        isUtc: true,
      );
      final candidates = <CloudInboxChangeEntity>[];
      var tombstones = 0;
      for (final row in rows) {
        final entry = _inboxFromEntity(scope, row);
        final legacyReadOnlyTombstone =
            allowLegacyReadOnlyTombstoneAcknowledgement &&
            legacyAppliedFloorInflated &&
            entry.sequence <= checkpoint.appliedSequence &&
            entry.lastFailure == CloudFailureCategory.conflict &&
            entry.change.isTombstone &&
            entry.change.type == CloudChangeType.delete &&
            row.preflightCategory == null &&
            row.preflightCode == null &&
            !replayedSequences.contains(entry.sequence);
        if (entry.status != CloudInboxStatus.quarantined ||
            (!legacyReadOnlyTombstone &&
                !_mayRetainUnprojected(
                  entry,
                  category: entry.lastFailure,
                  now: effectiveNow,
                  maximumDeferredAttempts: maximumDeferredAttempts,
                  maximumDeferredAge: maximumDeferredAge,
                  includeCurrentAttempt: false,
                ))) {
          continue;
        }
        candidates.add(row);
        if (entry.change.isTombstone) tombstones++;
      }
      for (final row in candidates) {
        row
          ..status = _inboxStatusToInt(CloudInboxStatus.retainedUnprojected)
          ..nextEligibleAtMs = 0
          ..completedAtMs = transactionNowMs
          ..updatedAtMs = transactionNowMs;
        _inbox.put(row);
      }
      final recomputedAppliedSequence =
          _recomputeContiguousAppliedFromJournalLocked(
            scope,
            checkpoint: checkpoint,
            rows: rows,
            nowMs: transactionNowMs,
          );
      CloudInboxChangeEntity? firstUnresolved;
      for (final row in rows) {
        if (!_isExactlyAppliedInboxStatus(_inboxStatusFromInt(row.status))) {
          firstUnresolved = row;
          break;
        }
      }
      return CloudInboxRetentionRecovery(
        retainedUnprojected: candidates.length,
        tombstoneReadOnlyAcknowledged: tombstones,
        previousAppliedSequence: previousAppliedSequence,
        recomputedAppliedSequence: recomputedAppliedSequence,
        legacyFloorInflated: legacyAppliedFloorInflated,
        firstUnresolvedSequence: firstUnresolved?.fetchSequence,
        firstUnresolvedStatus: firstUnresolved == null
            ? null
            : _inboxStatusFromInt(firstUnresolved.status),
        firstUnresolvedCategory: firstUnresolved == null
            ? null
            : _failureOrNull(firstUnresolved.failureCategory),
        recoveryComplete: firstUnresolved == null,
      );
    });
  }

  @override
  Future<bool> requeueUnknownInboxBarrier(
    CloudSyncScope scope, {
    required DateTime now,
    required DateTime quarantinedBefore,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    final requestedNowMs = now.toUtc().millisecondsSinceEpoch;
    final cutoffMs = quarantinedBefore.toUtc().millisecondsSinceEpoch;
    if (!quarantinedBefore.isUtc ||
        cutoffMs <= 0 ||
        requestedNowMs <= cutoffMs) {
      throw _storageFailure('unknown_barrier_recovery_window_invalid');
    }
    return _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      if (transactionNowMs <= cutoffMs) {
        throw _storageFailure('unknown_barrier_recovery_clock_invalid');
      }
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final checkpoint = _checkpointLocked(scope, nowMs: transactionNowMs);
      if (checkpoint.appliedSequence > checkpoint.fetchedSequence) {
        throw _storageFailure('unknown_barrier_recovery_checkpoint_invalid');
      }
      final pendingBatchId = checkpoint.pendingBatchId;
      if (pendingBatchId == null ||
          checkpoint.pendingFetchedTokenCiphertext == null) {
        return false;
      }
      final row = _findInboxBySequenceLocked(
        scope,
        checkpoint.appliedSequence + 1,
      );
      if (row == null ||
          row.generation != checkpoint.generation ||
          row.batchId != pendingBatchId ||
          _inboxStatusFromInt(row.status) != CloudInboxStatus.quarantined ||
          row.failureCategory != CloudFailureCategory.unknown.name ||
          row.preflightCategory != null ||
          row.preflightCode != null ||
          row.isTombstone ||
          row.changeType != CloudChangeType.save.name ||
          row.encryptedPayloadRef == null ||
          row.payloadSha256 == null ||
          row.retryCount < 3 ||
          row.nextEligibleAtMs != 0 ||
          row.completedAtMs <= 0 ||
          row.completedAtMs != row.updatedAtMs ||
          row.completedAtMs > cutoffMs) {
        return false;
      }

      // Preserve the protected source and historical retry count. If this
      // build still cannot decode the row, the existing bound immediately
      // returns it to quarantine and updatedAt moves it beyond this one-time
      // migration window.
      row
        ..status = _inboxStatusToInt(CloudInboxStatus.pending)
        ..nextEligibleAtMs = 0
        ..completedAtMs = 0
        ..updatedAtMs = transactionNowMs;
      _inbox.put(row);
      return true;
    });
  }

  @override
  Future<bool> requeueLegacyOwnershipConflictBarrier(
    CloudSyncScope scope, {
    required DateTime now,
    required DateTime quarantinedBefore,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    final requestedNowMs = now.toUtc().millisecondsSinceEpoch;
    final cutoffMs = quarantinedBefore.toUtc().millisecondsSinceEpoch;
    if (!quarantinedBefore.isUtc ||
        cutoffMs <= 0 ||
        requestedNowMs <= cutoffMs) {
      throw _storageFailure(
        'legacy_ownership_conflict_recovery_window_invalid',
      );
    }
    return _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      if (transactionNowMs <= cutoffMs) {
        throw _storageFailure(
          'legacy_ownership_conflict_recovery_clock_invalid',
        );
      }
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final checkpoint = _checkpointLocked(scope, nowMs: transactionNowMs);
      if (checkpoint.appliedSequence > checkpoint.fetchedSequence) {
        throw _storageFailure(
          'legacy_ownership_conflict_recovery_checkpoint_invalid',
        );
      }
      final pendingBatchId = checkpoint.pendingBatchId;
      if (pendingBatchId == null ||
          checkpoint.pendingFetchedTokenCiphertext == null) {
        return false;
      }
      final row = _findFirstNonterminalInboxLocked(scope, checkpoint);
      if (row == null ||
          row.generation != checkpoint.generation ||
          row.batchId != pendingBatchId ||
          _inboxStatusFromInt(row.status) != CloudInboxStatus.quarantined ||
          row.failureCategory != CloudFailureCategory.conflict.name ||
          row.preflightCategory != null ||
          row.preflightCode != null ||
          row.isTombstone ||
          row.changeType != CloudChangeType.save.name ||
          row.encryptedPayloadRef == null ||
          row.payloadSha256 == null ||
          row.retryCount < 1 ||
          row.nextEligibleAtMs != 0 ||
          row.completedAtMs <= 0 ||
          row.completedAtMs != row.updatedAtMs ||
          row.completedAtMs > cutoffMs) {
        return false;
      }

      // Preserve all protected source and retry history. If exact ownership
      // still cannot be proven, ordinary semantic handling quarantines this
      // row again after the fixed cutoff, preventing another migration retry.
      row
        ..status = _inboxStatusToInt(CloudInboxStatus.pending)
        ..nextEligibleAtMs = 0
        ..completedAtMs = 0
        ..updatedAtMs = transactionNowMs;
      _inbox.put(row);
      return true;
    });
  }

  @override
  Future<bool> requeuePretransactionChatConflictBarrier(
    CloudSyncScope scope, {
    required DateTime now,
    required DateTime quarantinedBefore,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    final requestedNowMs = now.toUtc().millisecondsSinceEpoch;
    final cutoffMs = quarantinedBefore.toUtc().millisecondsSinceEpoch;
    if (!quarantinedBefore.isUtc ||
        cutoffMs <= 0 ||
        requestedNowMs <= cutoffMs) {
      throw _storageFailure(
        'pretransaction_chat_conflict_recovery_window_invalid',
      );
    }
    if (scope.container != _messagesCloudContainer ||
        scope.database != _messagesCloudDatabase ||
        scope.zone != 'chatManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.persistenceLane != CloudSyncPersistenceLane.semanticV2) {
      return false;
    }
    return _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      if (transactionNowMs <= cutoffMs) {
        throw _storageFailure(
          'pretransaction_chat_conflict_recovery_clock_invalid',
        );
      }
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final checkpoint = _checkpointLocked(scope, nowMs: transactionNowMs);
      if (checkpoint.appliedSequence > checkpoint.fetchedSequence) {
        throw _storageFailure(
          'pretransaction_chat_conflict_recovery_checkpoint_invalid',
        );
      }
      final pendingBatchId = checkpoint.pendingBatchId;
      if (pendingBatchId == null ||
          checkpoint.pendingFetchedTokenCiphertext == null) {
        return false;
      }
      final row = _findFirstNonterminalInboxLocked(scope, checkpoint);
      if (row == null ||
          row.generation != checkpoint.generation ||
          row.batchId != pendingBatchId ||
          _inboxStatusFromInt(row.status) != CloudInboxStatus.quarantined ||
          row.failureCategory != CloudFailureCategory.conflict.name ||
          row.preflightCategory != null ||
          row.preflightCode != null ||
          row.isTombstone ||
          row.changeType != CloudChangeType.save.name ||
          row.encryptedPayloadRef == null ||
          row.payloadSha256 == null ||
          !_recoverablePretransactionChatConflictRetryCounts.contains(
            row.retryCount,
          ) ||
          row.nextEligibleAtMs != 0 ||
          row.completedAtMs <= 0 ||
          row.completedAtMs != row.updatedAtMs ||
          row.completedAtMs > cutoffMs ||
          _hasSemanticReplayForInboxSequenceLocked(
            scope,
            generation: checkpoint.generation,
            sequence: row.fetchSequence,
          ) ||
          _hasRecordMapForServerRecordLocked(
            scope,
            generation: checkpoint.generation,
            serverRecordIdHash: row.serverRecordIdHash,
          )) {
        return false;
      }

      // Preserve the protected source, checkpoint, and historical attempts.
      // The allowlist deliberately skips retry 2 and stops after retry 3: a
      // failed migration advances to 2 or 4, neither of which can re-enter.
      row
        ..status = _inboxStatusToInt(CloudInboxStatus.pending)
        ..nextEligibleAtMs = 0
        ..completedAtMs = 0
        ..updatedAtMs = transactionNowMs;
      _inbox.put(row);
      return true;
    });
  }

  @override
  Future<bool> requeuePretransactionAttachmentConflictBarrier(
    CloudSyncScope scope, {
    required DateTime now,
    required DateTime quarantinedBefore,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    final requestedNowMs = now.toUtc().millisecondsSinceEpoch;
    final cutoffMs = quarantinedBefore.toUtc().millisecondsSinceEpoch;
    if (!quarantinedBefore.isUtc ||
        cutoffMs <= 0 ||
        requestedNowMs <= cutoffMs) {
      throw _storageFailure(
        'pretransaction_attachment_conflict_recovery_window_invalid',
      );
    }
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'attachmentManateeZone') {
      return false;
    }
    return _store.runInTransaction(TxMode.write, () {
      final transactionNowMs = _nowMs();
      if (transactionNowMs <= cutoffMs) {
        throw _storageFailure(
          'pretransaction_attachment_conflict_recovery_clock_invalid',
        );
      }
      _requireActiveCoordinatorLeaseLocked(
        scope,
        leaseFence,
        nowMs: transactionNowMs,
      );
      final checkpoint = _checkpointLocked(scope, nowMs: transactionNowMs);
      if (checkpoint.appliedSequence > checkpoint.fetchedSequence) {
        throw _storageFailure(
          'pretransaction_attachment_conflict_recovery_checkpoint_invalid',
        );
      }
      final pendingBatchId = checkpoint.pendingBatchId;
      if (pendingBatchId == null ||
          checkpoint.pendingFetchedTokenCiphertext == null) {
        return false;
      }
      final row = _findFirstNonterminalInboxLocked(scope, checkpoint);
      if (row == null ||
          row.generation != checkpoint.generation ||
          row.batchId != pendingBatchId ||
          _inboxStatusFromInt(row.status) != CloudInboxStatus.quarantined ||
          row.failureCategory != CloudFailureCategory.conflict.name ||
          row.preflightCategory != null ||
          row.preflightCode != null ||
          row.isTombstone ||
          row.changeType != CloudChangeType.save.name ||
          row.encryptedPayloadRef == null ||
          row.payloadSha256 == null ||
          !_recoverablePretransactionAttachmentConflictRetryCounts.contains(
            row.retryCount,
          ) ||
          row.nextEligibleAtMs != 0 ||
          row.completedAtMs <= 0 ||
          row.completedAtMs != row.updatedAtMs ||
          row.completedAtMs > cutoffMs ||
          _hasSemanticReplayForInboxSequenceLocked(
            scope,
            generation: checkpoint.generation,
            sequence: row.fetchSequence,
          ) ||
          _hasRecordMapForServerRecordLocked(
            scope,
            generation: checkpoint.generation,
            serverRecordIdHash: row.serverRecordIdHash,
          )) {
        return false;
      }

      // Preserve the protected source, checkpoint, and original failed
      // attempt. If this retry is not one of the explicitly retainable legacy
      // attachment conflicts, it advances to retry two and cannot re-enter.
      row
        ..status = _inboxStatusToInt(CloudInboxStatus.pending)
        ..nextEligibleAtMs = 0
        ..completedAtMs = 0
        ..updatedAtMs = transactionNowMs;
      _inbox.put(row);
      return true;
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
  }) async => _admitProtectedOutboundCreate(draft, recordMapping);

  /// Atomically consumes one reflected local edit/unsend into a protected
  /// conditional-update outbox row. The mapped predecessor is re-read inside
  /// this exact transaction; a changed ETag, raw record, generation, identity,
  /// auth fence or local reflection rolls the entire adoption back.
  CloudOutboxOperation admitProtectedLocalMutationUpdate({
    required CloudOutboxDraft draft,
    required CloudRecordMapEntry expectedPredecessor,
    required CloudSyncLocalMutationJournal journal,
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
  }) {
    if (!journal.isBoundToStore(_store) ||
        draft.scope.container != _messagesCloudContainer ||
        draft.scope.database != _messagesCloudDatabase ||
        draft.scope.zone != 'messageManateeZone' ||
        draft.scope.streamKind != CloudSyncStreamKind.messages ||
        draft.scope.schemaVersion != cloudSyncSchemaVersion ||
        draft.scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        draft.action != CloudOutboxAction.save ||
        draft.payloadVersion != cloudSyncMessageUpdatePayloadVersion ||
        draft.dependencyOperationIds.isNotEmpty ||
        draft.encryptedPayloadReference == null ||
        !_isNativeProtectedReference(draft.encryptedPayloadReference!) ||
        draft.payloadSha256 == null ||
        !_isContentDigest(draft.payloadSha256!) ||
        draft.serverRecordIdHash == null ||
        !_isNativeDigest(draft.logicalEntityKeyHash) ||
        !_isNativeDigest(draft.serverRecordIdHash!) ||
        draft.protectedLeaseReference == null ||
        !_isProtectedPageLease(draft.protectedLeaseReference!) ||
        !draft.createdAt.isUtc ||
        draft.createdAt.millisecondsSinceEpoch <= 0 ||
        expectedPredecessor.scope != draft.scope ||
        expectedPredecessor.logicalEntityKeyHash !=
            draft.logicalEntityKeyHash ||
        expectedPredecessor.serverRecordIdHash != draft.serverRecordIdHash ||
        !_isNativeProtectedReference(
          expectedPredecessor.encryptedServerRecordId,
        ) ||
        expectedPredecessor.etagHash == null ||
        !_isNativeDigest(expectedPredecessor.etagHash!) ||
        expectedPredecessor.encryptedRawRecordReference == null ||
        !_isNativeProtectedReference(
          expectedPredecessor.encryptedRawRecordReference!,
        )) {
      throw _storageFailure('protected_message_update_admission_invalid');
    }

    return _store.runInTransaction(TxMode.write, () {
      final nowMs = draft.createdAt.millisecondsSinceEpoch;
      final checkpoint = _checkpointLocked(draft.scope, nowMs: nowMs);
      _fenceStaleOutboxLocked(
        draft.scope,
        checkpoint: checkpoint,
        nowMs: nowMs,
      );
      final predecessor = cloudSyncFindRecordMap(
        store: _store,
        scope: draft.scope,
        generation: checkpoint.generation,
        logicalEntityKeyHash: draft.logicalEntityKeyHash,
        serverRecordIdHash: draft.serverRecordIdHash,
      );
      if (predecessor == null ||
          predecessor.mapKey !=
              cloudSyncCanonicalRecordMapKey(
                draft.scope,
                draft.logicalEntityKeyHash,
              ) ||
          predecessor.scopeKey != _scopeKey(draft.scope) ||
          predecessor.accountFingerprint != draft.scope.accountFingerprint ||
          predecessor.zone != draft.scope.zone ||
          predecessor.generation != checkpoint.generation ||
          predecessor.logicalEntityKeyHash !=
              expectedPredecessor.logicalEntityKeyHash ||
          predecessor.serverRecordIdHash !=
              expectedPredecessor.serverRecordIdHash ||
          predecessor.encryptedServerRecordId !=
              expectedPredecessor.encryptedServerRecordId ||
          predecessor.etagHash != expectedPredecessor.etagHash ||
          predecessor.encryptedRawRecordRef !=
              expectedPredecessor.encryptedRawRecordReference ||
          predecessor.updatedAtMs !=
              expectedPredecessor.updatedAt.millisecondsSinceEpoch) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'protected_message_update_predecessor_changed',
        );
      }

      final adoptedId = journal.adoptedOperationIdInOutboxTransaction(
        _store,
        source,
        currentAuth: currentAuth,
        stillCurrent: stillCurrent,
        replayBinding: replayBinding,
      );
      if (adoptedId != null) {
        final existingEntity = _findOutboxByOperationIdLocked(adoptedId);
        if (existingEntity == null ||
            existingEntity.scopeKey != _scopeKey(draft.scope)) {
          throw _storageFailure('protected_message_update_outbox_missing');
        }
        final existing = _outboxFromEntity(draft.scope, existingEntity);
        if (!_sameUpdateDraft(existing, draft) ||
            existing.checkpointGeneration != checkpoint.generation) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'protected_message_update_retry_changed',
          );
        }
        journal.adoptInOutboxTransaction(
          _store,
          source,
          existing,
          predecessor,
          currentAuth: currentAuth,
          stillCurrent: stillCurrent,
          now: draft.createdAt,
          replayBinding: replayBinding,
        );
        return existing;
      }

      final blockingSameRecord = _findOutboxForScopeLocked(draft.scope).any(
        (row) =>
            row.logicalEntityKeyHash == draft.logicalEntityKeyHash &&
            _isBlockingOutboxStatus(_outboxStatusFromInt(row.state)),
      );
      if (blockingSameRecord) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'protected_message_update_predecessor_busy',
        );
      }

      final revision = checkpoint.mutationRevisionCounter + 1;
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
      if (_findOutboxByOperationIdLocked(operation.operationId) != null) {
        throw _storageFailure('outbox_operation_scope_collision');
      }
      _outbox.put(_outboxEntity(operation));
      journal.adoptInOutboxTransaction(
        _store,
        source,
        operation,
        predecessor,
        currentAuth: currentAuth,
        stillCurrent: stillCurrent,
        now: draft.createdAt,
        replayBinding: replayBinding,
      );
      checkpoint
        ..mutationRevisionCounter = revision
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);
      final inserted = _findOutboxByOperationIdLocked(operation.operationId);
      if (inserted == null ||
          !_outboxFromEntity(
            draft.scope,
            inserted,
          ).sameDurableSnapshotAs(operation)) {
        throw _storageFailure('protected_message_update_outbox_changed');
      }
      return operation;
    });
  }

  bool _sameUpdateDraft(
    CloudOutboxOperation operation,
    CloudOutboxDraft draft,
  ) =>
      operation.scope == draft.scope &&
      operation.logicalEntityKeyHash == draft.logicalEntityKeyHash &&
      operation.action == draft.action &&
      operation.payloadVersion == draft.payloadVersion &&
      operation.encryptedPayloadReference == draft.encryptedPayloadReference &&
      operation.payloadSha256 == draft.payloadSha256 &&
      operation.serverRecordIdHash == draft.serverRecordIdHash &&
      operation.protectedLeaseReference == draft.protectedLeaseReference &&
      operation.dependencyOperationIds.length ==
          draft.dependencyOperationIds.length &&
      operation.dependencyOperationIds.containsAll(
        draft.dependencyOperationIds,
      ) &&
      operation.createdAt.millisecondsSinceEpoch ==
          draft.createdAt.millisecondsSinceEpoch &&
      operation.operationId ==
          CloudOperationIdentity.forMutation(
            scope: operation.scope,
            logicalEntityKeyHash: operation.logicalEntityKeyHash,
            action: operation.action,
            payloadVersion: operation.payloadVersion,
            mutationRevision: operation.mutationRevision,
            payloadSha256: operation.payloadSha256,
          );

  /// Read a prior Chat create before staging. A retry keeps the original
  /// random record name even after an uncertain submission or process restart.
  CloudOutboxOperation? readOutboundChatCreateForLocalRow(
    CloudSyncScope scope,
    int chatId,
  ) => _store.runInTransaction(TxMode.read, () {
    final matches = _findOutboxForScopeLocked(scope)
        .where(
          (row) =>
              row.localChatOrigin != null &&
              cloudSyncOutboundChatOriginId(row.localChatOrigin!) == chatId,
        )
        .toList();
    if (matches.isEmpty) return null;
    if (matches.length != 1) {
      throw _storageFailure('cloud_sync_outbound_chat_origin_ambiguous');
    }
    final row = matches.single;
    final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
    final mapping = cloudSyncFindRecordMap(
      store: _store,
      scope: scope,
      generation: row.checkpointGeneration,
      logicalEntityKeyHash: row.logicalEntityKeyHash,
      serverRecordIdHash: row.serverRecordIdHash,
    );
    if (scope.container != _messagesCloudContainer ||
        scope.database != _messagesCloudDatabase ||
        scope.zone != 'chatManateeZone' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        row.accountFingerprint != scope.accountFingerprint ||
        row.zone != scope.zone ||
        checkpoint == null ||
        row.checkpointGeneration != checkpoint.generation ||
        row.payloadVersion != cloudSyncOutboundChatPayloadVersion ||
        row.action != CloudOutboxAction.save.index ||
        row.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: scope,
              logicalEntityKeyHash: row.logicalEntityKeyHash,
              payloadVersion: cloudSyncOutboundChatPayloadVersion,
            ) ||
        mapping == null ||
        mapping.scopeKey != _scopeKey(scope) ||
        mapping.accountFingerprint != scope.accountFingerprint ||
        mapping.generation != row.checkpointGeneration ||
        mapping.serverRecordIdHash != row.serverRecordIdHash ||
        row.encryptedPayloadRef == null ||
        !_isNativeProtectedReference(row.encryptedPayloadRef!) ||
        (row.protectedLeaseReference == null
            ? row.state != CloudOutboxStatus.confirmed.index
            : !_isProtectedPageLease(row.protectedLeaseReference!)) ||
        row.payloadSha256 == null ||
        !_isContentDigest(row.payloadSha256!)) {
      throw _storageFailure('cloud_sync_outbound_chat_recovery_changed');
    }
    return _outboxFromEntity(scope, row);
  });

  /// Cancel only proven, never-submitted Chat dependencies whose original
  /// Message was removed/edited. All immutable evidence and the adopted native
  /// lease remain. This transaction must finish before selection validation,
  /// so an invalid diagnostic selection cannot roll the disposition back.
  int retireUnsubmittedChatCreates(
    CloudSyncScope scope, {
    required DateTime now,
    int? onlyIntentId,
  }) => _store.runInTransaction(TxMode.write, () {
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'chatManateeZone') {
      throw _storageFailure('cloud_sync_outbound_chat_scope_invalid');
    }
    final query =
        _outbox
            .query(
              CloudOutboxOperationEntity_.scopeKey
                  .equals(_scopeKey(scope))
                  .and(
                    CloudOutboxOperationEntity_.localChatOrigin.startsWith(
                      '[2,',
                    ),
                  )
                  .and(
                    CloudOutboxOperationEntity_.state.oneOf([
                      CloudOutboxStatus.pending.index,
                      CloudOutboxStatus.paused.index,
                      CloudOutboxStatus.quarantined.index,
                    ]),
                  ),
            )
            .build()
          ..limit = 4097;
    final List<CloudOutboxOperationEntity> rows;
    try {
      rows = query.find();
    } finally {
      query.close();
    }
    if (rows.length > 4096) {
      throw _storageFailure(
        'cloud_sync_outbound_chat_retirement_bound_exceeded',
      );
    }
    var retired = 0;
    for (final row in rows) {
      if (!cloudSyncIsNeverSubmittedChatCreate(row) ||
          row.leaseIdHash != null ||
          row.leaseExpiresAtMs != 0) {
        continue;
      }
      final proof = cloudSyncOutboundChatOriginSendProof(row.localChatOrigin!);
      if (proof == null) continue;
      if (onlyIntentId != null) {
        final decoded = jsonDecode(proof);
        if (decoded is! List ||
            decoded.length != 3 ||
            decoded[1] != onlyIntentId) {
          continue;
        }
      }
      final operation = _outboxFromEntity(scope, row);
      final chatId = cloudSyncOutboundChatOriginId(row.localChatOrigin!);
      final recovered = readOutboundChatCreateForLocalRow(scope, chatId);
      if (recovered == null || !recovered.sameDurableSnapshotAs(operation)) {
        throw _storageFailure('cloud_sync_outbound_chat_recovery_changed');
      }
      if (!_requireChatCreateJournal().hasRetiredChatCreateSource(
        _store,
        operation,
        chatId,
        cloudSyncOutboundChatOriginIdentity(row.localChatOrigin!),
        proof,
      )) {
        continue;
      }
      row
        ..state = CloudOutboxStatus.quarantined.index
        ..lastErrorCategory = CloudFailureCategory.cancelled.name
        ..nextEligibleAtMs = 0
        ..localChatOrigin = cloudSyncRetiredChatOrigin(row.localChatOrigin!)
        ..updatedAtMs = now.toUtc().millisecondsSinceEpoch;
      if (!cloudSyncIsRetiredUnsubmittedChatCreate(row)) {
        throw _storageFailure('cloud_sync_outbound_chat_retirement_invalid');
      }
      _outbox.put(row);
      retired++;
    }
    return retired;
  });

  bool isRetiredUnsubmittedChatCreate(CloudOutboxOperation expected) =>
      _store.runInTransaction(TxMode.read, () {
        final row = _findOutboxByOperationIdLocked(expected.operationId);
        return row != null &&
            row.scopeKey == _scopeKey(expected.scope) &&
            cloudSyncIsRetiredUnsubmittedChatCreate(row) &&
            _outboxFromEntity(
              expected.scope,
              row,
            ).sameDurableSnapshotAs(expected);
      });

  bool isRetainedPreproofPendingCreate(CloudOutboxOperation expected) =>
      _store.runInTransaction(TxMode.read, () {
        final row = _findOutboxByOperationIdLocked(expected.operationId);
        return row != null &&
            row.scopeKey == _scopeKey(expected.scope) &&
            _outboxFromEntity(
              expected.scope,
              row,
            ).sameDurableSnapshotAs(expected) &&
            (_localSendJournal?.isRetainedPreproofPendingCreate(row) ?? false);
      });

  /// Candidate capture only, never adoption or permission to create remotely.
  CloudSyncOutboundChatOrigin captureOutboundChatObservationOrigin(
    CloudSyncScope scope,
    int chatId, {
    required CloudSyncLocalSendAdmissionSource localSendSource,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireChatCreateJournal().validateChatCreateSource(
      _store,
      scope,
      chatId,
      localSendSource,
    );
    _requireMessagesCloudAccountProjectionReadyLocked(
      scope,
      allowRetainedForFreshCreate: true,
    );
    final chat = _store.box<Chat>().get(chatId);
    if (chat == null) {
      throw _storageFailure('cloud_sync_outbound_chat_origin_missing');
    }
    final origin = CloudSyncOutboundChatOrigin.capture(
      scope: scope,
      chat: chat,
    );
    _requireNoPriorChatIdentityLocked(origin);
    return origin;
  });

  CloudSyncOutboundChatOrigin captureFreshOutboundChatOrigin(
    CloudSyncScope scope,
    int chatId, {
    CloudSyncLocalSendAdmissionSource? localSendSource,
  }) => _store.runInTransaction(TxMode.read, () {
    if (localSendSource == null) {
      _requireMessagesCloudAccountProjectionReadyLocked(scope);
    } else {
      _requireChatCreateJournal().validateChatCreateSource(
        _store,
        scope,
        chatId,
        localSendSource,
      );
      _requireMessagesCloudAccountProjectionReadyLocked(
        scope,
        allowRetainedForFreshCreate: true,
        requireResolvedChatSaves: true,
      );
    }
    final chat = _store.box<Chat>().get(chatId);
    if (chat == null) {
      throw _storageFailure('cloud_sync_outbound_chat_origin_missing');
    }
    final origin = CloudSyncOutboundChatOrigin.capture(
      scope: scope,
      chat: chat,
    );
    if (localSendSource != null) _requireNoPriorChatIdentityLocked(origin);
    return origin;
  });

  /// Origin proof, immutable payload and record map commit together. Neither
  /// staging nor this admission is permission to perform a remote create.
  CloudOutboxOperation admitProtectedOutboundChatCreate({
    required CloudOutboxDraft draft,
    required CloudRecordMapEntry recordMapping,
    required CloudSyncOutboundChatOrigin origin,
    CloudSyncLocalSendAdmissionSource? localSendSource,
    void Function()? validateLocalOrigin,
    CloudSyncChatIdentityEvidence? identityEvidence,
  }) => _admitProtectedOutboundCreate(
    draft,
    recordMapping,
    chatOrigin: origin,
    chatLocalSendSource: localSendSource,
    chatIdentityEvidence: identityEvidence,
    validateFreshDependency: () {
      origin.requireUnchanged(_store);
      validateLocalOrigin?.call();
    },
    onAdopt: (operation) {
      origin.requireUnchanged(_store);
      final row = _findOutboxByOperationIdLocked(operation.operationId)!;
      final identity = origin.binding(operation.checkpointGeneration);
      final binding = origin.binding(
        operation.checkpointGeneration,
        localSendProof: localSendSource == null
            ? null
            : _requireChatCreateJournal().bindChatCreateSource(
                _store,
                operation,
                origin.chatId,
                identity,
                localSendSource,
              ),
      );
      if (row.localChatOrigin != null && row.localChatOrigin != binding) {
        throw _storageFailure('cloud_sync_outbound_chat_origin_changed');
      }
      row.localChatOrigin = binding;
      _outbox.put(row);
    },
  );

  /// Check before encoding/staging a fresh local intent. Pending outbox work
  /// blocks semantic reads, so admitting a write behind an unmet projection
  /// prerequisite can strand both lanes. This is an optimization, not a
  /// permission: new adoption rechecks inside its write transaction below.
  void requireFreshOutboundProjectionReady(
    CloudSyncScope scope, {
    CloudSyncLocalSendAdmissionSource? localSendSource,
    CloudSyncLocalSendJournal? localSendJournal,
    bool retainedAttachmentResume = false,
  }) => _store.runInTransaction(TxMode.read, () {
    final journal = _localSendJournal;
    if (journal != null && localSendSource != null) {
      journal.validateReadyForCreate(
        _store,
        scope,
        localSendSource,
        retainedAttachmentResume: retainedAttachmentResume,
      );
      _requireMessagesCloudAccountProjectionReadyLocked(
        scope,
        allowRetainedForFreshCreate: true,
      );
    } else {
      _requireMessagesCloudAccountProjectionReadyLocked(scope);
    }
    if (localSendSource != null) {
      if (localSendJournal == null) {
        throw StateError('cloud_sync_local_send_adoption_store_mismatch');
      }
      requireCloudSyncLocalSendDependencies(
        store: _store,
        messageScope: scope,
        message: localSendJournal.validateReadyForCreate(
          _store,
          scope,
          localSendSource,
          retainedAttachmentResume: retainedAttachmentResume,
        ),
        readConfirmedLocalParent: (parent) => localSendJournal
            .readConfirmedParentDependency(_store, scope, parent),
      );
    }
  });

  /// Synchronous so the native auth revalidation and this write transaction
  /// have no intervening await. The journal is adopted in this exact Store,
  /// not through a separately committed callback or an async transaction hook.
  CloudOutboxOperation admitProtectedLocalSendCreate({
    required CloudOutboxDraft draft,
    required CloudRecordMapEntry recordMapping,
    required CloudSyncLocalSendJournal journal,
    required CloudSyncLocalSendAdmissionSource source,
    String? attachmentParentChatBinding,
    bool retainedAttachmentResume = false,
  }) => _admitProtectedOutboundCreate(
    draft,
    recordMapping,
    onAdopt: (operation) {
      // The identical-existing-envelope path also reaches this callback.
      // Revalidate the pinned group before adopting either a new or retained
      // mapping, in the same write transaction as current writer authority.
      if (attachmentParentChatBinding != null) {
        journal.requireFreshAttachmentGroupDependency(
          draft.scope,
          source,
          attachmentParentChatBinding,
          retainedAttachmentResume: retainedAttachmentResume,
        );
      }
      journal.adoptInOutboxTransaction(
        _store,
        source,
        operation,
        retainedAttachmentResume: retainedAttachmentResume,
      );
    },
    localSendSource: source,
    retainedAttachmentResume: retainedAttachmentResume,
    validateFreshDependency: () {
      if (attachmentParentChatBinding != null) {
        journal.requireFreshAttachmentGroupDependency(
          draft.scope,
          source,
          attachmentParentChatBinding,
          retainedAttachmentResume: retainedAttachmentResume,
        );
      }
      requireCloudSyncLocalSendDependencies(
        store: _store,
        messageScope: draft.scope,
        message: journal.validateReadyForCreate(
          _store,
          draft.scope,
          source,
          adopting: true,
          retainedAttachmentResume: retainedAttachmentResume,
        ),
        readConfirmedLocalParent: (parent) =>
            journal.readConfirmedParentDependency(_store, draft.scope, parent),
      );
    },
  );

  /// Atomic handoff of a completed byte upload, its original record mapping,
  /// and a pending Attachment-v1 save. The upload journal validates the exact
  /// IDS-confirmed origin, account, generation and result before this callback.
  /// No network I/O or plaintext reconstruction takes place here.
  CloudAttachmentUploadSnapshot admitCompletedAttachmentUpload({
    required CloudSyncScope scope,
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
    required DateTime createdAt,
  }) {
    if (!uploads.isBoundTo(_store, scope)) {
      throw _storageFailure('attachment_upload_adoption_store_mismatch');
    }
    return uploads.adoptRecordCreate(
      id: uploadId,
      now: createdAt,
      admit: (transactionStore, stage) => _admitProtectedOutboundCreate(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: stage.logicalEntityKeyHash,
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          dependencyOperationIds: const {},
          createdAt: createdAt,
          encryptedPayloadReference: stage.protectedEnvelopeReference,
          payloadSha256: stage.payloadSha256,
          serverRecordIdHash: stage.serverRecordIdHash,
          protectedLeaseReference: stage.leaseReference,
        ),
        CloudRecordMapEntry(
          scope: scope,
          logicalEntityKeyHash: stage.logicalEntityKeyHash,
          serverRecordIdHash: stage.serverRecordIdHash,
          encryptedServerRecordId: stage.protectedEnvelopeReference,
          updatedAt: createdAt,
        ),
        isAttachmentCreate: true,
      ),
    );
  }

  CloudOutboxOperation _admitProtectedOutboundCreate(
    CloudOutboxDraft draft,
    CloudRecordMapEntry recordMapping, {
    void Function(CloudOutboxOperation)? onAdopt,
    CloudSyncLocalSendAdmissionSource? localSendSource,
    void Function()? validateFreshDependency,
    CloudSyncOutboundChatOrigin? chatOrigin,
    CloudSyncLocalSendAdmissionSource? chatLocalSendSource,
    CloudSyncChatIdentityEvidence? chatIdentityEvidence,
    bool isAttachmentCreate = false,
    bool retainedAttachmentResume = false,
  }) {
    final isChatCreate = chatOrigin != null;
    if (draft.action != CloudOutboxAction.save ||
        draft.payloadVersion !=
            (isAttachmentCreate
                ? 1
                : isChatCreate
                ? cloudSyncOutboundChatPayloadVersion
                : cloudSyncOutboundPayloadVersion) ||
        (isAttachmentCreate &&
            (isChatCreate || draft.scope.zone != 'attachmentManateeZone')) ||
        (isChatCreate &&
            (chatOrigin.scope != draft.scope ||
                draft.scope.zone != 'chatManateeZone')) ||
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
        recordMapping.updatedAt.millisecondsSinceEpoch !=
            draft.createdAt.millisecondsSinceEpoch ||
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
        final existingMapping = cloudSyncFindRecordMap(
          store: _store,
          scope: draft.scope,
          generation: checkpoint.generation,
          logicalEntityKeyHash: draft.logicalEntityKeyHash,
          serverRecordIdHash: existing.serverRecordIdHash,
        );
        if (existing.scope != draft.scope ||
            existing.logicalEntityKeyHash != draft.logicalEntityKeyHash ||
            existing.action != CloudOutboxAction.save ||
            existing.payloadVersion != draft.payloadVersion ||
            existing.checkpointGeneration != checkpoint.generation ||
            existing.dependencyOperationIds.isNotEmpty ||
            existing.createdAt.millisecondsSinceEpoch !=
                draft.createdAt.millisecondsSinceEpoch ||
            existing.payloadSha256 != draft.payloadSha256 ||
            existing.serverRecordIdHash != draft.serverRecordIdHash ||
            existing.encryptedPayloadReference == null ||
            !_isNativeProtectedReference(existing.encryptedPayloadReference!) ||
            existing.protectedLeaseReference == null ||
            !_isProtectedPageLease(existing.protectedLeaseReference!) ||
            existing.status != CloudOutboxStatus.pending ||
            existing.attemptCount != 0 ||
            existing.nextEligibleAt != null ||
            existing.lastFailure != null ||
            existing.leaseId != null ||
            existing.leaseExpiresAt != null ||
            existing.confirmedAt != null ||
            existing.appleRequestUuid != null ||
            existing.appleOperationUuid != null) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'protected_outbound_retry_payload_changed',
          );
        }
        if (existingMapping == null ||
            existingMapping.scopeKey != _scopeKey(draft.scope) ||
            existingMapping.accountFingerprint !=
                draft.scope.accountFingerprint ||
            existingMapping.zone != draft.scope.zone ||
            existingMapping.logicalEntityKeyHash !=
                existing.logicalEntityKeyHash ||
            existingMapping.serverRecordIdHash != existing.serverRecordIdHash ||
            existingMapping.generation != existing.checkpointGeneration ||
            existingMapping.encryptedServerRecordId !=
                existing.encryptedPayloadReference ||
            existingMapping.etagHash != null ||
            existingMapping.encryptedRawRecordRef != null ||
            existingMapping.updatedAtMs !=
                existing.createdAt.millisecondsSinceEpoch) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'protected_outbound_retry_mapping_changed',
          );
        }
        onAdopt?.call(existing);
        return existing;
      }

      // Do not create blocking outbox work while the reads needed to make it
      // eligible remain unfinished. A local send stays in its durable ready
      // journal instead. Existing-envelope recovery above must remain possible
      // after later history debt; leasing/submission retain their own checks.
      final journal = _localSendJournal;
      if (chatOrigin != null && chatLocalSendSource != null) {
        _requireChatCreateJournal().validateChatCreateSource(
          _store,
          draft.scope,
          chatOrigin.chatId,
          chatLocalSendSource,
        );
        _requireMessagesCloudAccountProjectionReadyLocked(
          draft.scope,
          allowRetainedForFreshCreate: true,
          requireResolvedChatSaves: true,
          freshRecordIdHash: draft.serverRecordIdHash,
          requireChatIdentityEvidence: chatIdentityEvidence == null
              ? null
              : () {
                  chatIdentityEvidence.requireMatches(
                    store: _store,
                    origin: chatOrigin,
                    logicalEntityKeyHash: draft.logicalEntityKeyHash,
                    serverRecordIdHash: draft.serverRecordIdHash,
                    payloadSha256: draft.payloadSha256,
                    protectedEnvelopeReference: draft.encryptedPayloadReference,
                    leaseReference: draft.protectedLeaseReference,
                  );
                },
        );
        _requireNoPriorChatIdentityLocked(
          chatOrigin,
          logicalEntityKeyHash: draft.logicalEntityKeyHash,
          freshRecordIdHash: draft.serverRecordIdHash,
        );
      } else if (journal != null && localSendSource != null) {
        journal.validateReadyForCreate(
          _store,
          draft.scope,
          localSendSource,
          adopting: true,
          retainedAttachmentResume: retainedAttachmentResume,
        );
        _requireMessagesCloudAccountProjectionReadyLocked(
          draft.scope,
          allowRetainedForFreshCreate: true,
          freshRecordIdHash: draft.serverRecordIdHash,
        );
      } else if (isAttachmentCreate) {
        // Only the completed-upload journal reaches this branch. Its fresh,
        // IDS-confirmed source has the same retained-history treatment as a
        // fresh Message create; checkpoint errors and exact tombstones still
        // block. Recovered envelopes above never allocate another record.
        _requireMessagesCloudAccountProjectionReadyLocked(
          draft.scope,
          allowRetainedForFreshCreate: true,
          freshRecordIdHash: draft.serverRecordIdHash,
        );
      } else {
        _requireMessagesCloudAccountProjectionReadyLocked(draft.scope);
      }
      validateFreshDependency?.call();

      final mapKey = _scopedDigest(
        draft.scope,
        'record-map',
        draft.logicalEntityKeyHash,
      );
      final existingMapping = _findRecordMapByKeyLocked(mapKey);
      if (existingMapping != null &&
          existingMapping.generation == checkpoint.generation) {
        if (existingMapping.serverRecordIdHash !=
            recordMapping.serverRecordIdHash) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'server_mapping_changed',
          );
        }
        if (existingMapping.etagHash != null ||
            existingMapping.encryptedRawRecordRef != null) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'protected_outbound_existing_record_requires_update',
          );
        }
      }
      final crossLaneOutboxConflict = _findOutboxForScopeLocked(draft.scope)
          .any(
            (entity) =>
                entity.logicalEntityKeyHash == draft.logicalEntityKeyHash &&
                entity.payloadVersion != draft.payloadVersion &&
                _outboxStatusFromInt(entity.state) !=
                    CloudOutboxStatus.quarantined,
          );
      if (crossLaneOutboxConflict) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'protected_outbound_record_lane_busy',
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
          rawRecordGeneration: recordMapping.encryptedRawRecordReference == null
              ? 0
              : recordMapping.rawRecordGeneration > 0
              ? recordMapping.rawRecordGeneration
              : checkpoint.generation,
          updatedAtMs: nowMs,
        ),
      );
      onAdopt?.call(operation);
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
        if (entity.mapKey ==
            cloudSyncChatRecordMemberKey(
              request.scope,
              entity.generation,
              entity.serverRecordIdHash,
            )) {
          continue; // Preserve the historical member's epoch and evidence.
        }
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
    Set<int>? allowedPayloadVersions,
  }) async {
    _requirePositiveLimit(limit);
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      _fenceUnsupportedOutboundVersionsLocked(scope, nowMs: nowMs);
      if (_hasBlockingOutboxLocked(scope)) {
        if (checkpoint.pendingBatchId != null ||
            _hasUnmarkedPendingInboxLocked(scope, checkpoint)) {
          throw _storageFailure('checkpoint_pending_page_unresolved');
        }
        if (_localSendJournal == null &&
            _localMutationJournal == null &&
            _attachmentUploadJournal?.isBoundTo(_store, scope) != true) {
          _requireMessagesCloudAccountProjectionReadyLocked(scope);
        }
      }
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
                    (allowedPayloadVersions == null ||
                        allowedPayloadVersions.contains(
                          entity.payloadVersion,
                        )) &&
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

        try {
          _requireOperationProjectionReadyLocked(scope, entity);
        } on StateError catch (error) {
          if (error.message != 'cloud_sync_local_send_ids_proof_required') {
            rethrow;
          }
          // Retain pre-proof pending work without letting it monopolize every
          // lease pass. This neither resolves unknown outcomes nor resends IDS.
          continue;
        }

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
  Future<bool> renewOutboxLease(
    CloudSyncScope scope, {
    required String leaseId,
    required Iterable<String> operationIds,
    required DateTime now,
    required Duration leaseDuration,
  }) async {
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    if (leaseDuration.inMicroseconds <= 0) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
    final ids = operationIds.toList(growable: false);
    if (ids.isEmpty) {
      throw ArgumentError('outbox_renewal_operation_ids_empty');
    }
    if (ids.toSet().length != ids.length) {
      throw ArgumentError('outbox_renewal_operation_ids_duplicate');
    }
    final nowMs = now.millisecondsSinceEpoch;
    final renewedUntilMs = now.add(leaseDuration).millisecondsSinceEpoch;
    final scopeKey = _scopeKey(scope);
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      final entities = <CloudOutboxOperationEntity>[];
      for (final operationId in ids) {
        final entity = _findOutboxByOperationIdLocked(operationId);
        if (entity == null ||
            entity.scopeKey != scopeKey ||
            entity.checkpointGeneration <= 0 ||
            entity.checkpointGeneration != checkpoint.generation ||
            (_outboxStatusFromInt(entity.state) != CloudOutboxStatus.leased &&
                _outboxStatusFromInt(entity.state) !=
                    CloudOutboxStatus.unknownOutcome) ||
            entity.leaseIdHash != leaseIdHash ||
            entity.leaseExpiresAtMs <= nowMs) {
          return false;
        }
        // A lease renewal extends remote-mutation authority. Revalidate the
        // same immutable source, mapping and protected evidence required for
        // the original lease before extending that authority.
        _requireOperationProjectionReadyLocked(scope, entity);
        entities.add(entity);
      }
      for (final entity in entities) {
        entity
          ..leaseExpiresAtMs = renewedUntilMs
          ..updatedAtMs = nowMs;
        _outbox.put(entity);
      }
      return true;
    });
  }

  @override
  Future<List<CloudOutboxOperation>> leaseUnknownOutcomes(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
    Set<int>? allowedPayloadVersions,
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
                    (allowedPayloadVersions == null ||
                        allowedPayloadVersions.contains(
                          entity.payloadVersion,
                        )) &&
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
        // Unknown outcome means the prior network result may already have
        // reached Apple. Reconciliation must remain available even if the
        // local projection or restored-chat proof changed after submission.
        // The exact persisted request, operation and predecessor identities
        // are revalidated by the reconciliation path before any resolution.
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
      _fenceUnsupportedOutboundVersionsLocked(scope, nowMs: nowMs);
      if (_localSendJournal == null && _localMutationJournal == null) {
        _requireMessagesCloudAccountProjectionReadyLocked(scope);
      }
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
        _requireOperationProjectionReadyLocked(scope, entity);
        entities[operationId] = entity;
      }
      for (final entity in entities.values) {
        if (entity.localChatOrigin != null) {
          entity.localChatOrigin = cloudSyncSubmittedChatOrigin(
            entity.localChatOrigin!,
          );
        }
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
            // For journal-owned attachments, confirmed+released is the durable
            // exact-readback marker. A transition cannot create that same
            // state through immediate release, even though no receipt is
            // involved on this path. Retention keeps the row releasable only
            // through the verified readback path.
            if (!transition.retainProtectedLeaseReference &&
                _requiresAttachmentReadbackLocked(entity.operationId)) {
              throw _storageFailure('attachment_receipt_retention_required');
            }
            entity
              ..state = _outboxStatusToInt(CloudOutboxStatus.confirmed)
              ..confirmedAtMs = nowMs
              ..lastErrorCategory = null
              ..nextEligibleAtMs = 0
              ..protectedLeaseReference =
                  transition.retainProtectedLeaseReference
                  ? entity.protectedLeaseReference
                  : null;
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
              ..protectedLeaseReference =
                  cloudSyncIsNeverSubmittedChatCreate(entity)
                  ? entity.protectedLeaseReference
                  : null
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
  Future<void> commitOutboxCreateReceipt(
    CloudSyncScope scope, {
    required String leaseId,
    required CloudOutboxCreateReceipt receipt,
    bool retainProtectedLeaseReference = false,
    required DateTime now,
  }) async {
    if (receipt.operationId.isEmpty ||
        receipt.logicalEntityKeyHash.isEmpty ||
        receipt.serverRecordIdHash.isEmpty ||
        receipt.etagHash.isEmpty) {
      throw _storageFailure('outbox_receipt_field_missing');
    }
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
      if (checkpoint.generation <= 0) {
        throw _storageFailure('stale_outbox_generation');
      }
      final entity = _findOutboxByOperationIdLocked(receipt.operationId);
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
      if (_actionFromInt(entity.action) != CloudOutboxAction.save) {
        throw _storageFailure('outbox_receipt_action_unsupported');
      }
      // For journal-owned attachments, confirmed+released is the durable
      // exact-readback marker. A save acknowledgement cannot create that same
      // state through the generic immediate-release path, even on a store
      // opened without the optional upload journal.
      if (!retainProtectedLeaseReference &&
          _requiresAttachmentReadbackLocked(entity.operationId)) {
        throw _storageFailure('attachment_receipt_retention_required');
      }
      if (entity.logicalEntityKeyHash != receipt.logicalEntityKeyHash) {
        throw _storageFailure('outbox_receipt_logical_key_mismatch');
      }
      // A null operation hash never matches: the exact operation/server
      // binding must already be recorded before the receipt can commit.
      if (entity.serverRecordIdHash != receipt.serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      final mapping = cloudSyncFindRecordMap(
        store: _store,
        scope: scope,
        generation: checkpoint.generation,
        logicalEntityKeyHash: receipt.logicalEntityKeyHash,
        serverRecordIdHash: receipt.serverRecordIdHash,
      );
      if (mapping == null) {
        final other = _findRecordMapByKeyLocked(
          cloudSyncCanonicalRecordMapKey(scope, receipt.logicalEntityKeyHash),
        );
        if (other != null &&
            other.generation == checkpoint.generation &&
            other.serverRecordIdHash != receipt.serverRecordIdHash) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'server_mapping_changed',
          );
        }
      }
      if (mapping == null ||
          mapping.generation != checkpoint.generation ||
          mapping.scopeKey != _scopeKey(scope) ||
          mapping.logicalEntityKeyHash != receipt.logicalEntityKeyHash ||
          mapping.encryptedServerRecordId.isEmpty) {
        throw _storageFailure('outbox_receipt_map_missing');
      }
      if (mapping.serverRecordIdHash != receipt.serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      if (mapping.etagHash != null && mapping.etagHash != receipt.etagHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'outbox_receipt_changed',
        );
      }
      mapping
        ..etagHash = receipt.etagHash
        ..updatedAtMs = nowMs;
      _putRecordMapAndMirrorLocked(scope, mapping);
      entity
        ..serverRecordIdHash = receipt.serverRecordIdHash
        ..state = _outboxStatusToInt(CloudOutboxStatus.confirmed)
        ..confirmedAtMs = nowMs
        ..lastErrorCategory = null
        ..nextEligibleAtMs = 0
        ..protectedLeaseReference = retainProtectedLeaseReference
            ? entity.protectedLeaseReference
            : null
        ..leaseIdHash = null
        ..leaseExpiresAtMs = 0
        ..updatedAtMs = nowMs;
      _outbox.put(entity);
    });
  }

  @override
  Future<CloudMessageUpdateReadbackCommitSnapshot>
  commitMessageUpdateReadbackReceipt(
    CloudSyncScope scope, {
    required String leaseId,
    required CloudMessageUpdateReadbackReceipt receipt,
    required DateTime now,
  }) async {
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'messageManateeZone' ||
        leaseId.isEmpty ||
        !now.isUtc ||
        now.millisecondsSinceEpoch <= 0) {
      throw _storageFailure('message_update_readback_commit_invalid');
    }
    final leaseIdHash = _digest('outbox-lease\u001f$leaseId');
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (checkpoint == null || checkpoint.generation <= 0) {
        throw _storageFailure('stale_outbox_generation');
      }
      final entity = _findOutboxByOperationIdLocked(receipt.operationId);
      if (entity != null &&
          entity.scopeKey == _scopeKey(scope) &&
          _outboxStatusFromInt(entity.state) == CloudOutboxStatus.confirmed) {
        final mapping = cloudSyncFindRecordMap(
          store: _store,
          scope: scope,
          generation: checkpoint.generation,
          logicalEntityKeyHash: receipt.logicalEntityKeyHash,
          serverRecordIdHash: receipt.serverRecordIdHash,
        );
        final duplicate =
            mapping != null &&
            entity.checkpointGeneration == checkpoint.generation &&
            entity.logicalEntityKeyHash == receipt.logicalEntityKeyHash &&
            entity.serverRecordIdHash == receipt.serverRecordIdHash &&
            entity.appleRequestUuid == receipt.appleRequestUuid &&
            entity.appleOperationUuid == receipt.appleOperationUuid &&
            mapping.etagHash == receipt.resultingEtagHash &&
            mapping.encryptedRawRecordRef ==
                receipt.protectedCurrentRawRecordReference &&
            mapping.rawRecordGeneration == receipt.rawGeneration &&
            mapping.protectedReadbackLeaseReference ==
                receipt.protectedCurrentRawRecordLeaseReference &&
            mapping.pendingUpdateOperationId == receipt.operationId &&
            mapping.pendingUpdatePredecessorEtagHash ==
                receipt.predecessorEtagHash;
        throw _storageFailure(
          duplicate
              ? 'message_update_readback_receipt_duplicate'
              : 'message_update_readback_receipt_changed',
        );
      }
      if (entity == null ||
          entity.scopeKey != _scopeKey(scope) ||
          entity.accountFingerprint != scope.accountFingerprint ||
          entity.zone != scope.zone ||
          entity.checkpointGeneration != checkpoint.generation) {
        throw _storageFailure('stale_outbox_generation');
      }
      if (_outboxStatusFromInt(entity.state) !=
              CloudOutboxStatus.unknownOutcome ||
          entity.leaseIdHash != leaseIdHash ||
          entity.leaseExpiresAtMs <= nowMs) {
        throw _storageFailure('stale_outbox_lease');
      }
      if (_actionFromInt(entity.action) != CloudOutboxAction.save ||
          entity.payloadVersion != cloudSyncMessageUpdatePayloadVersion ||
          entity.dependencyOperationIdsJson != '[]' ||
          entity.logicalEntityKeyHash != receipt.logicalEntityKeyHash ||
          entity.serverRecordIdHash != receipt.serverRecordIdHash ||
          entity.appleRequestUuid != receipt.appleRequestUuid ||
          entity.appleOperationUuid != receipt.appleOperationUuid ||
          entity.encryptedPayloadRef == null ||
          !_isNativeProtectedReference(entity.encryptedPayloadRef!) ||
          entity.payloadSha256 == null ||
          !_isContentDigest(entity.payloadSha256!) ||
          entity.protectedLeaseReference == null ||
          !_isProtectedPageLease(entity.protectedLeaseReference!) ||
          entity.protectedLeaseReference ==
              receipt.protectedCurrentRawRecordLeaseReference) {
        throw _storageFailure('message_update_submission_identity_changed');
      }
      final mapping = cloudSyncFindRecordMap(
        store: _store,
        scope: scope,
        generation: checkpoint.generation,
        logicalEntityKeyHash: receipt.logicalEntityKeyHash,
        serverRecordIdHash: receipt.serverRecordIdHash,
      );
      if (mapping == null ||
          mapping.mapKey !=
              cloudSyncCanonicalRecordMapKey(
                scope,
                receipt.logicalEntityKeyHash,
              ) ||
          mapping.scopeKey != _scopeKey(scope) ||
          mapping.accountFingerprint != scope.accountFingerprint ||
          mapping.zone != scope.zone ||
          mapping.generation != checkpoint.generation ||
          mapping.logicalEntityKeyHash != receipt.logicalEntityKeyHash ||
          mapping.serverRecordIdHash != receipt.serverRecordIdHash ||
          !_isNativeProtectedReference(mapping.encryptedServerRecordId) ||
          mapping.encryptedRawRecordRef == null ||
          !_isNativeProtectedReference(mapping.encryptedRawRecordRef!) ||
          mapping.etagHash != receipt.predecessorEtagHash ||
          _recordMapRawGeneration(mapping) != receipt.rawGeneration ||
          receipt.rawGeneration != checkpoint.generation) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'message_update_readback_predecessor_changed',
        );
      }
      if (mapping.protectedReadbackLeaseReference != null ||
          mapping.pendingUpdateOperationId != null ||
          mapping.pendingUpdatePredecessorEtagHash != null) {
        throw _storageFailure('message_update_readback_already_pending');
      }

      mapping
        ..etagHash = receipt.resultingEtagHash
        ..encryptedRawRecordRef = receipt.protectedCurrentRawRecordReference
        ..rawRecordGeneration = receipt.rawGeneration
        ..protectedReadbackLeaseReference =
            receipt.protectedCurrentRawRecordLeaseReference
        ..pendingUpdateOperationId = receipt.operationId
        ..pendingUpdatePredecessorEtagHash = receipt.predecessorEtagHash
        ..updatedAtMs = nowMs;
      _putRecordMapAndMirrorLocked(scope, mapping);
      entity
        ..state = _outboxStatusToInt(CloudOutboxStatus.confirmed)
        ..confirmedAtMs = nowMs
        ..lastErrorCategory = null
        ..nextEligibleAtMs = 0
        // The update-stage lease remains independently owned until native
        // finalization of both it and the mapping readback lease succeeds.
        ..protectedLeaseReference = entity.protectedLeaseReference
        ..leaseIdHash = null
        ..leaseExpiresAtMs = 0
        ..updatedAtMs = nowMs;
      _outbox.put(entity);

      final confirmed = _outboxFromEntity(scope, entity);
      final mapped = _recordMapEntryFromEntity(scope, mapping);
      return CloudMessageUpdateReadbackCommitSnapshot(
        confirmedOperation: confirmed,
        recordMapping: mapped,
      );
    });
  }

  @override
  Future<void> finalizeMessageUpdateReadbackLeases({
    required CloudMessageUpdateReadbackCommitSnapshot expectedSnapshot,
    required bool updateStageLeaseCommitted,
    required bool readbackLeaseCommitted,
  }) async {
    if (!updateStageLeaseCommitted || !readbackLeaseCommitted) {
      throw _storageFailure('message_update_native_finalization_incomplete');
    }
    final expectedOperation = expectedSnapshot.confirmedOperation;
    final expectedMapping = expectedSnapshot.recordMapping;
    final scope = expectedOperation.scope;
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'messageManateeZone') {
      throw _storageFailure('message_update_finalization_scope_invalid');
    }
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (checkpoint == null ||
          checkpoint.generation != expectedOperation.checkpointGeneration ||
          checkpoint.generation != expectedMapping.generation) {
        throw _storageFailure('stale_outbox_generation');
      }
      final entity = _findOutboxByOperationIdLocked(
        expectedOperation.operationId,
      );
      if (entity == null || entity.scopeKey != _scopeKey(scope)) {
        throw _storageFailure('message_update_finalization_snapshot_changed');
      }
      final currentOperation = _outboxFromEntity(scope, entity);
      if (!currentOperation.sameDurableSnapshotAs(expectedOperation)) {
        throw _storageFailure('message_update_finalization_snapshot_changed');
      }
      final mapping = cloudSyncFindRecordMap(
        store: _store,
        scope: scope,
        generation: checkpoint.generation,
        logicalEntityKeyHash: expectedMapping.logicalEntityKeyHash,
        serverRecordIdHash: expectedMapping.serverRecordIdHash,
      );
      if (mapping == null) {
        throw _storageFailure('message_update_finalization_snapshot_changed');
      }
      _validatePendingMessageUpdateMappingLease(mapping);
      final currentMapping = _recordMapEntryFromEntity(scope, mapping);
      if (!currentMapping.sameDurableSnapshotAs(expectedMapping) ||
          mapping.pendingUpdateOperationId != expectedOperation.operationId) {
        throw _storageFailure('message_update_finalization_snapshot_changed');
      }
      entity.protectedLeaseReference = null;
      mapping
        ..protectedReadbackLeaseReference = null
        ..pendingUpdateOperationId = null
        ..pendingUpdatePredecessorEtagHash = null;
      _outbox.put(entity);
      _putRecordMapAndMirrorLocked(scope, mapping);
    });
  }

  @override
  Future<CloudMessageCreateReadbackCommitSnapshot>
  commitConfirmedMessageCreateReadback({
    required CloudOutboxOperation expectedOperation,
    required CloudOutboxCreateReceipt receipt,
    required DateTime now,
  }) async {
    final scope = expectedOperation.scope;
    final rawReference = receipt.protectedCurrentRawRecordReference;
    final readbackLease = receipt.protectedCurrentRawRecordLeaseReference;
    final rawGeneration = receipt.rawGeneration;
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'messageManateeZone' ||
        !now.isUtc ||
        now.millisecondsSinceEpoch <= 0 ||
        receipt.operationId != expectedOperation.operationId ||
        receipt.logicalEntityKeyHash !=
            expectedOperation.logicalEntityKeyHash ||
        receipt.serverRecordIdHash != expectedOperation.serverRecordIdHash ||
        rawReference == null ||
        !_isNativeProtectedReference(rawReference) ||
        readbackLease == null ||
        !_isProtectedPageLease(readbackLease) ||
        rawGeneration == null ||
        rawGeneration != expectedOperation.checkpointGeneration ||
        expectedOperation.protectedLeaseReference == readbackLease) {
      throw _storageFailure('message_create_readback_commit_invalid');
    }
    _requireConfirmedReceiptReleaseCandidate(expectedOperation);
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.write, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (checkpoint == null ||
          checkpoint.generation != expectedOperation.checkpointGeneration ||
          checkpoint.generation != rawGeneration) {
        throw _storageFailure('stale_outbox_generation');
      }
      final entity = _findOutboxByOperationIdLocked(
        expectedOperation.operationId,
      );
      if (entity == null || entity.scopeKey != _scopeKey(scope)) {
        throw _storageFailure('message_create_readback_snapshot_changed');
      }
      final currentOperation = _outboxFromEntity(scope, entity);
      if (!currentOperation.sameDurableSnapshotAs(expectedOperation)) {
        throw _storageFailure('message_create_readback_snapshot_changed');
      }
      final mapping = cloudSyncFindRecordMap(
        store: _store,
        scope: scope,
        generation: checkpoint.generation,
        logicalEntityKeyHash: receipt.logicalEntityKeyHash,
        serverRecordIdHash: receipt.serverRecordIdHash,
      );
      if (mapping == null ||
          mapping.mapKey !=
              cloudSyncCanonicalRecordMapKey(
                scope,
                receipt.logicalEntityKeyHash,
              ) ||
          mapping.scopeKey != _scopeKey(scope) ||
          mapping.accountFingerprint != scope.accountFingerprint ||
          mapping.zone != scope.zone ||
          mapping.generation != checkpoint.generation ||
          mapping.logicalEntityKeyHash != receipt.logicalEntityKeyHash ||
          mapping.serverRecordIdHash != receipt.serverRecordIdHash ||
          !_isNativeProtectedReference(mapping.encryptedServerRecordId) ||
          mapping.etagHash != receipt.etagHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'message_create_readback_mapping_changed',
        );
      }
      if (mapping.protectedReadbackLeaseReference != null ||
          mapping.pendingUpdateOperationId != null ||
          mapping.pendingUpdatePredecessorEtagHash != null) {
        throw _storageFailure('message_create_readback_already_pending');
      }

      mapping
        ..encryptedRawRecordRef = rawReference
        ..rawRecordGeneration = rawGeneration
        ..protectedReadbackLeaseReference = readbackLease
        ..pendingUpdateOperationId = receipt.operationId
        // Equal current/pending etags identify a create readback. Conditional
        // updates deliberately require these values to differ.
        ..pendingUpdatePredecessorEtagHash = receipt.etagHash
        ..updatedAtMs = nowMs;
      _putRecordMapAndMirrorLocked(scope, mapping);
      final mapped = _recordMapEntryFromEntity(scope, mapping);
      return CloudMessageCreateReadbackCommitSnapshot(
        confirmedOperation: currentOperation,
        recordMapping: mapped,
      );
    });
  }

  @override
  Future<void> finalizeMessageCreateReadbackLeases({
    required CloudMessageCreateReadbackCommitSnapshot expectedSnapshot,
    required bool createSourceLeaseCommitted,
    required bool readbackLeaseCommitted,
  }) async {
    if (!createSourceLeaseCommitted || !readbackLeaseCommitted) {
      throw _storageFailure('message_create_native_finalization_incomplete');
    }
    final expectedOperation = expectedSnapshot.confirmedOperation;
    final expectedMapping = expectedSnapshot.recordMapping;
    final scope = expectedOperation.scope;
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'messageManateeZone') {
      throw _storageFailure('message_create_finalization_scope_invalid');
    }
    _store.runInTransaction(TxMode.write, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (checkpoint == null ||
          checkpoint.generation != expectedOperation.checkpointGeneration ||
          checkpoint.generation != expectedMapping.generation) {
        throw _storageFailure('stale_outbox_generation');
      }
      final entity = _findOutboxByOperationIdLocked(
        expectedOperation.operationId,
      );
      if (entity == null || entity.scopeKey != _scopeKey(scope)) {
        throw _storageFailure('message_create_finalization_snapshot_changed');
      }
      final currentOperation = _outboxFromEntity(scope, entity);
      if (!currentOperation.sameDurableSnapshotAs(expectedOperation)) {
        throw _storageFailure('message_create_finalization_snapshot_changed');
      }
      final mapping = cloudSyncFindRecordMap(
        store: _store,
        scope: scope,
        generation: checkpoint.generation,
        logicalEntityKeyHash: expectedMapping.logicalEntityKeyHash,
        serverRecordIdHash: expectedMapping.serverRecordIdHash,
      );
      if (mapping == null) {
        throw _storageFailure('message_create_finalization_snapshot_changed');
      }
      _validatePendingMessageCreateMappingLease(mapping);
      final currentMapping = _recordMapEntryFromEntity(scope, mapping);
      if (!currentMapping.sameDurableSnapshotAs(expectedMapping) ||
          mapping.pendingUpdateOperationId != expectedOperation.operationId) {
        throw _storageFailure('message_create_finalization_snapshot_changed');
      }
      final journal = _localSendJournal;
      if (journal == null) {
        final intentQuery = _store
            .box<CloudSyncLocalSendIntentEntity>()
            .query(
              CloudSyncLocalSendIntentEntity_.admittedOperationId.equals(
                currentOperation.operationId,
              ),
            )
            .build();
        try {
          if (intentQuery.count() != 0) {
            throw StateError('cloud_sync_local_send_journal_required');
          }
        } finally {
          intentQuery.close();
        }
      } else {
        journal.recordConfirmedReadbackInTransaction(
          _store,
          currentOperation,
        );
      }
      entity.protectedLeaseReference = null;
      mapping
        ..protectedReadbackLeaseReference = null
        ..pendingUpdateOperationId = null
        ..pendingUpdatePredecessorEtagHash = null;
      _outbox.put(entity);
      _putRecordMapAndMirrorLocked(scope, mapping);
    });
  }

  @override
  Future<List<CloudMessageCreateReadbackCommitSnapshot>>
  readPendingMessageCreateReadbacks(
    CloudSyncScope scope, {
    required int maximumCount,
  }) async {
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'messageManateeZone' ||
        maximumCount <= 0 ||
        maximumCount > 4096) {
      throw _storageFailure('message_create_readback_inventory_invalid');
    }
    return _store.runInTransaction(TxMode.read, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (checkpoint == null) {
        return const <CloudMessageCreateReadbackCommitSnapshot>[];
      }
      final snapshots = <CloudMessageCreateReadbackCommitSnapshot>[];
      for (final mapping in _pendingMessageReadbackMappings(
        scope,
        checkpoint.generation,
      )) {
        final entity = _findPendingMessageReadbackOutboxLocked(scope, mapping);
        if (entity.payloadVersion == cloudSyncMessageUpdatePayloadVersion) {
          continue;
        }
        if (entity.payloadVersion != cloudSyncOutboundPayloadVersion) {
          throw _storageFailure('message_create_readback_inventory_corrupt');
        }
        _validatePendingMessageCreateMappingLease(mapping);
        snapshots.add(
          CloudMessageCreateReadbackCommitSnapshot(
            confirmedOperation: _outboxFromEntity(scope, entity),
            recordMapping: _recordMapEntryFromEntity(scope, mapping),
          ),
        );
        if (snapshots.length > maximumCount) {
          throw _storageFailure(
            'message_create_readback_inventory_bound_exceeded',
          );
        }
      }
      snapshots.sort(
        (left, right) => left.confirmedOperation.mutationRevision.compareTo(
          right.confirmedOperation.mutationRevision,
        ),
      );
      return List.unmodifiable(snapshots);
    });
  }

  @override
  Future<List<CloudMessageUpdateReadbackCommitSnapshot>>
  readPendingMessageUpdateReadbacks(
    CloudSyncScope scope, {
    required int maximumCount,
  }) async {
    if (!_isMessagesCloudSemanticScope(scope) ||
        scope.zone != 'messageManateeZone' ||
        maximumCount <= 0 ||
        maximumCount > 4096) {
      throw _storageFailure('message_update_readback_inventory_invalid');
    }
    return _store.runInTransaction(TxMode.read, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (checkpoint == null) {
        return const <CloudMessageUpdateReadbackCommitSnapshot>[];
      }
      final snapshots = <CloudMessageUpdateReadbackCommitSnapshot>[];
      for (final mapping in _pendingMessageReadbackMappings(
        scope,
        checkpoint.generation,
      )) {
        final entity = _findPendingMessageReadbackOutboxLocked(scope, mapping);
        if (entity.payloadVersion == cloudSyncOutboundPayloadVersion) {
          continue;
        }
        if (entity.payloadVersion != cloudSyncMessageUpdatePayloadVersion) {
          throw _storageFailure('message_update_readback_inventory_corrupt');
        }
        _validatePendingMessageUpdateMappingLease(mapping);
        snapshots.add(
          CloudMessageUpdateReadbackCommitSnapshot(
            confirmedOperation: _outboxFromEntity(scope, entity),
            recordMapping: _recordMapEntryFromEntity(scope, mapping),
          ),
        );
        if (snapshots.length > maximumCount) {
          throw _storageFailure(
            'message_update_readback_inventory_bound_exceeded',
          );
        }
      }
      snapshots.sort(
        (left, right) => left.confirmedOperation.mutationRevision.compareTo(
          right.confirmedOperation.mutationRevision,
        ),
      );
      return List.unmodifiable(snapshots);
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

  bool _requiresAttachmentReadbackLocked(String operationId) {
    final query =
        _store
            .box<CloudAttachmentUploadEntity>()
            .query(
              CloudAttachmentUploadEntity_.admittedOperationId.equals(
                operationId,
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

  /// Exact indexed lookup for an already-adopted local send. This neither
  /// leases nor restages the operation, regardless of its current outcome.
  CloudOutboxOperation readAdoptedLocalSendOperation(
    CloudSyncScope scope, {
    required CloudSyncLocalSendJournal journal,
    required CloudSyncLocalSendAdmissionSource source,
  }) => _store.runInTransaction(TxMode.read, () {
    final entity = _findOutboxByOperationIdLocked(
      source.admittedOperationId ?? '',
    );
    final scopeKey = _scopeKey(scope);
    if (entity == null ||
        entity.scopeKey != scopeKey ||
        entity.accountFingerprint != scope.accountFingerprint ||
        entity.zone != scope.zone) {
      throw StateError('cloud_sync_local_send_adopted_operation_missing');
    }
    final operation = _outboxFromEntity(scope, entity);
    journal.validateAdoptedOperation(_store, source, operation);
    final mapping = cloudSyncFindRecordMap(
      store: _store,
      scope: scope,
      generation: operation.checkpointGeneration,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: operation.serverRecordIdHash,
    );
    final checkpoint = _findCheckpointByKeyLocked(scopeKey);
    final reference = operation.encryptedPayloadReference;
    final lease = operation.protectedLeaseReference;
    if (reference == null ||
        !_isNativeProtectedReference(reference) ||
        operation.payloadSha256 == null ||
        !_isContentDigest(operation.payloadSha256!) ||
        (lease == null
            ? operation.status != CloudOutboxStatus.confirmed
            : !_isProtectedPageLease(lease)) ||
        checkpoint == null ||
        checkpoint.generation != operation.checkpointGeneration ||
        mapping == null ||
        mapping.scopeKey != scopeKey ||
        mapping.accountFingerprint != scope.accountFingerprint ||
        mapping.zone != scope.zone ||
        mapping.generation != operation.checkpointGeneration ||
        mapping.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
        mapping.serverRecordIdHash != operation.serverRecordIdHash ||
        !_isNativeProtectedReference(mapping.encryptedServerRecordId) ||
        // A settled confirmed row may acquire a newer inbound record mapping.
        // Unsettled work must still reference its adopted upload envelope.
        ((operation.status != CloudOutboxStatus.confirmed || lease != null) &&
            mapping.encryptedServerRecordId != reference)) {
      throw StateError('cloud_sync_local_send_adopted_mapping_changed');
    }
    return operation;
  });

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
  Future<DateTime?> readActiveCoordinatorLeaseExpiry(
    CloudSyncScope scope, {
    required DateTime now,
  }) async {
    final leaseKey = _scopedDigest(scope, 'coordinator-lease', 'v1');
    final nowMs = now.millisecondsSinceEpoch;
    return _store.runInTransaction(TxMode.read, () {
      final existing = _findLeaseByKeyLocked(leaseKey);
      if (existing == null || existing.expiresAtMs <= nowMs) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        existing.expiresAtMs,
        isUtc: true,
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
    String? serverRecordIdHash,
  }) async {
    return _store.runInTransaction(TxMode.read, () {
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      if (generation <= 0 || checkpoint?.generation != generation) {
        throw _storageFailure('record_map_generation_mismatch');
      }
      final entity = cloudSyncFindRecordMap(
        store: _store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: logicalEntityKeyHash,
        serverRecordIdHash: serverRecordIdHash,
      );
      if (entity == null || entity.generation != generation) return null;
      if (entity.scopeKey != _scopeKey(scope)) {
        throw _storageFailure('scope_collision');
      }
      return _recordMapEntryFromEntity(scope, entity);
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
      final canonical = _findRecordMapByKeyLocked(mapKey);
      final selected = cloudSyncFindRecordMap(
        store: _store,
        scope: entry.scope,
        generation: generation,
        logicalEntityKeyHash: entry.logicalEntityKeyHash,
        serverRecordIdHash: entry.serverRecordIdHash,
      );
      if (selected == null && canonical?.generation == generation) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      final existing = selected ?? canonical;
      if (entry.protectedReadbackLeaseReference != null ||
          entry.pendingUpdateOperationId != null ||
          entry.pendingUpdatePredecessorEtagHash != null) {
        throw _storageFailure('record_map_pending_update_import_forbidden');
      }
      if (existing?.protectedReadbackLeaseReference != null) {
        _validatePendingMessageReadbackMappingLease(existing!);
        if (existing.serverRecordIdHash != entry.serverRecordIdHash ||
            existing.etagHash != entry.etagHash ||
            existing.encryptedRawRecordRef !=
                entry.encryptedRawRecordReference ||
            existing.encryptedServerRecordId != entry.encryptedServerRecordId) {
          throw _storageFailure('message_update_readback_finalization_pending');
        }
      }
      final rawRecordGeneration = entry.encryptedRawRecordReference == null
          ? 0
          : entry.rawRecordGeneration > 0
          ? entry.rawRecordGeneration
          : existing?.encryptedRawRecordRef ==
                    entry.encryptedRawRecordReference &&
                existing!.rawRecordGeneration > 0
          ? existing.rawRecordGeneration
          : generation;
      _putRecordMapAndMirrorLocked(
        entry.scope,
        CloudRecordMapEntity(
          id: existing?.id ?? 0,
          mapKey: selected?.mapKey ?? mapKey,
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
          rawRecordGeneration: rawRecordGeneration,
          protectedReadbackLeaseReference:
              existing?.protectedReadbackLeaseReference,
          pendingUpdateOperationId: existing?.pendingUpdateOperationId,
          pendingUpdatePredecessorEtagHash:
              existing?.pendingUpdatePredecessorEtagHash,
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
    if (entity.scopeKey != _scopeKey(scope) ||
        entity.accountFingerprint != scope.accountFingerprint ||
        entity.zone != scope.zone) {
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
                entity.payloadVersion == operation.payloadVersion &&
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
    _fenceUnsupportedOutboundVersionsLocked(scope, nowMs: nowMs);
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

  /// Permanently quarantines durable rows created before deterministic Apple
  /// record identity became a schema invariant.
  ///
  /// The transition is content-free and preserves every protected reference,
  /// payload hash, server mapping, and Apple request/operation UUID. No row is
  /// decrypted, restaged, deleted, or made eligible for remote reconciliation.
  void _fenceUnsupportedOutboundVersionsLocked(
    CloudSyncScope scope, {
    required int nowMs,
  }) {
    if (scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2 ||
        scope.persistenceLane != CloudSyncPersistenceLane.semanticV2) {
      return;
    }
    for (final entity in _findOutboxForScopeLocked(scope)) {
      final status = _outboxStatusFromInt(entity.state);
      if (!_isBlockingOutboxStatus(status) ||
          _actionFromInt(entity.action) != CloudOutboxAction.save ||
          entity.payloadVersion == cloudSyncOutboundPayloadVersion ||
          entity.payloadVersion == cloudSyncMessageUpdatePayloadVersion) {
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

  void _requireConfirmedReceiptReleaseCandidate(
    CloudOutboxOperation operation,
  ) {
    if (operation.action != CloudOutboxAction.save ||
        operation.status != CloudOutboxStatus.confirmed ||
        operation.protectedLeaseReference == null ||
        operation.serverRecordIdHash == null ||
        operation.appleRequestUuid == null ||
        operation.appleOperationUuid == null ||
        operation.confirmedAt == null ||
        operation.nextEligibleAt != null ||
        operation.lastFailure != null ||
        operation.leaseId != null ||
        operation.leaseExpiresAt != null) {
      throw _storageFailure('confirmed_outbound_receipt_release_invalid');
    }
  }

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
          !_isExactlyAppliedInboxStatus(_inboxStatusFromInt(entity.status))) {
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

  int _recomputeContiguousAppliedFromJournalLocked(
    CloudSyncScope scope, {
    required CloudSyncCheckpointEntity checkpoint,
    required List<CloudInboxChangeEntity> rows,
    required int nowMs,
  }) {
    var appliedThrough = 0;
    for (final row in rows) {
      if (!_isExactlyAppliedInboxStatus(_inboxStatusFromInt(row.status))) {
        break;
      }
      appliedThrough = row.fetchSequence;
    }
    if (checkpoint.appliedSequence != appliedThrough) {
      checkpoint
        ..appliedSequence = appliedThrough
        ..updatedAtMs = nowMs;
      _checkpoints.put(checkpoint);
    }
    _promotePendingFetchedTokenIfTerminalLocked(scope, nowMs);
    return appliedThrough;
  }

  void _promotePendingFetchedTokenIfTerminalLocked(
    CloudSyncScope scope,
    int nowMs,
  ) {
    final checkpoint = _checkpointLocked(scope, nowMs: nowMs);
    final pendingBatchId = checkpoint.pendingBatchId;
    if (pendingBatchId == null) return;
    if (!_isCompleteTerminalInboxJournalLocked(scope, checkpoint)) {
      return;
    }

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
                  )
                  .and(
                    CloudInboxChangeEntity_.status.notEquals(
                      _inboxStatusToInt(CloudInboxStatus.retainedUnprojected),
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

  bool _isCompleteTerminalInboxJournalLocked(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity checkpoint,
  ) {
    final rows =
        _findInboxForScopeLocked(
            scope,
          ).where((row) => row.generation == checkpoint.generation).toList()
          ..sort(
            (left, right) => left.fetchSequence.compareTo(right.fetchSequence),
          );
    if (rows.length != checkpoint.fetchedSequence) return false;
    for (final (index, row) in rows.indexed) {
      if (row.fetchSequence != index + 1 ||
          row.scopeKey != _scopeKey(scope) ||
          row.accountFingerprint != scope.accountFingerprint ||
          row.zone != scope.zone ||
          row.generation != checkpoint.generation ||
          !_isTerminalInboxStatus(_inboxStatusFromInt(row.status))) {
        return false;
      }
    }
    return true;
  }

  CloudSyncLocalSendJournal _requireChatCreateJournal() =>
      _localSendJournal ??
      (throw StateError('cloud_sync_local_send_chat_journal_missing'));

  /// Chat record names are random, but the recipient identity is not. Saved
  /// Chat identities must be resolved separately. Retain and reject known
  /// earlier identity even if its row was deleted or its generation was reset.
  void _requireNoPriorChatIdentityLocked(
    CloudSyncOutboundChatOrigin origin, {
    String? logicalEntityKeyHash,
    String? allowedOperationId,
    String? freshRecordIdHash,
  }) {
    final matches = _existingChatHistoryMatchesLocked(
      origin,
      logicalEntityKeyHash: logicalEntityKeyHash,
      allowedOperationId: allowedOperationId,
      freshRecordIdHash: freshRecordIdHash,
    );
    for (final diagnosticCode in matches.diagnosticCodes) {
      try {
        _recordExistingHistoryDiagnostic?.call(diagnosticCode);
      } catch (_) {
        // Diagnostics must never change the existing admission result.
      }
    }
    if (matches.hasExistingHistory) {
      throw _storageFailure('cloud_sync_outbound_chat_existing_history');
    }
    if (matches.tombstoneConflict) {
      throw _storageFailure('messages_cloud_tombstone_projection_unavailable');
    }
  }

  _ExistingChatHistoryMatches _existingChatHistoryMatchesLocked(
    CloudSyncOutboundChatOrigin origin, {
    String? logicalEntityKeyHash,
    String? allowedOperationId,
    String? freshRecordIdHash,
  }) {
    final scope = origin.scope;
    bool readLaterPredicate(
      bool existingHistoryAlreadyMatched,
      bool Function() read,
    ) {
      if (!existingHistoryAlreadyMatched) return read();
      try {
        return read();
      } catch (_) {
        // The original short-circuit already selected existing_history.
        // Later diagnostics are best-effort and cannot replace that failure.
        return false;
      }
    }

    var localChatMatch = false;
    for (final chat in _store.box<Chat>().getAll()) {
      if (chat.id == origin.chatId) continue;
      final handles = chat.handles.toList(growable: false);
      if (chat.guid == origin.canonicalGuid ||
          (!chat.isRpSms &&
              !chat.isRoutingStub &&
              handles.length == 1 &&
              handles.single.service == 'iMessage' &&
              handles.single.address == origin.chatIdentifier)) {
        localChatMatch = true;
        break;
      }
    }
    String lookup(int generation) =>
        CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
          scope: scope,
          generation: generation,
          canonicalGuid: origin.canonicalGuid,
        );
    final snapshotMatch = readLaterPredicate(localChatMatch, () {
      final snapshots = _store
          .box<CloudSemanticSnapshotEntity>()
          .query(CloudSemanticSnapshotEntity_.scopeKey.equals(_scopeKey(scope)))
          .build();
      try {
        return snapshots.find().any(
          (row) => row.canonicalGuidLookupHash == lookup(row.generation),
        );
      } finally {
        snapshots.close();
      }
    });
    final aliasMatch = readLaterPredicate(localChatMatch || snapshotMatch, () {
      final aliases = _store
          .box<CloudSemanticChatAliasEntity>()
          .query(
            CloudSemanticChatAliasEntity_.scopeKey.equals(_scopeKey(scope)),
          )
          .build();
      try {
        return aliases.find().any(
          (row) =>
              row.chatId == origin.chatId ||
              row.canonicalGuidLookupHash == lookup(row.generation),
        );
      } finally {
        aliases.close();
      }
    });
    final priorOutboundOriginMatch = readLaterPredicate(
      localChatMatch || snapshotMatch || aliasMatch,
      () {
        for (final row in _findOutboxForScopeLocked(scope)) {
          if (row.operationId == allowedOperationId) continue;
          if (row.localChatOrigin != null &&
              cloudSyncOutboundChatOriginMatchesCanonical(
                row.localChatOrigin!,
                scope,
                origin.canonicalGuid,
              )) {
            return true;
          }
        }
        return false;
      },
    );
    final priorMatch =
        localChatMatch ||
        snapshotMatch ||
        aliasMatch ||
        priorOutboundOriginMatch;
    final recordMapConflict =
        logicalEntityKeyHash != null &&
        readLaterPredicate(priorMatch, () {
          final own = allowedOperationId == null
              ? null
              : _findOutboxByOperationIdLocked(allowedOperationId);
          return _findRecordMapsForScopeLocked(scope).any(
            (row) =>
                row.logicalEntityKeyHash == logicalEntityKeyHash &&
                (own == null ||
                    row.generation != own.checkpointGeneration ||
                    row.serverRecordIdHash != own.serverRecordIdHash),
          );
        });
    final tombstoneConflict =
        freshRecordIdHash != null &&
        readLaterPredicate(
          priorMatch || recordMapConflict,
          () => _findInboxForScopeLocked(scope).any(
            (row) =>
                row.isTombstone &&
                row.changeType == CloudChangeType.delete.name &&
                row.serverRecordIdHash == freshRecordIdHash,
          ),
        );
    return _ExistingChatHistoryMatches(
      localChatMatch: localChatMatch,
      snapshotMatch: snapshotMatch,
      aliasMatch: aliasMatch,
      priorOutboundOriginMatch: priorOutboundOriginMatch,
      recordMapConflict: recordMapConflict,
      tombstoneConflict: tombstoneConflict,
    );
  }

  void _putRecordMapAndMirrorLocked(
    CloudSyncScope scope,
    CloudRecordMapEntity row,
  ) {
    _validatePendingMessageReadbackMappingLease(row);
    _recordMaps.put(row);
    if (scope.zone != 'chatManateeZone') return;
    final canonicalKey = cloudSyncCanonicalRecordMapKey(
      scope,
      row.logicalEntityKeyHash,
    );
    final memberKey = cloudSyncChatRecordMemberKey(
      scope,
      row.generation,
      row.serverRecordIdHash,
    );
    final mirror = _findRecordMapByKeyLocked(
      row.mapKey == canonicalKey ? memberKey : canonicalKey,
    );
    if (mirror == null ||
        mirror.generation != row.generation ||
        mirror.serverRecordIdHash != row.serverRecordIdHash) {
      return;
    }
    if (mirror.logicalEntityKeyHash != row.logicalEntityKeyHash ||
        mirror.accountFingerprint != row.accountFingerprint ||
        mirror.scopeKey != row.scopeKey ||
        mirror.zone != row.zone) {
      throw _storageFailure('scope_collision');
    }
    mirror
      ..encryptedServerRecordId = row.encryptedServerRecordId
      ..etagHash = row.etagHash
      ..encryptedRawRecordRef = row.encryptedRawRecordRef
      ..rawRecordGeneration = row.rawRecordGeneration
      ..protectedReadbackLeaseReference = row.protectedReadbackLeaseReference
      ..pendingUpdateOperationId = row.pendingUpdateOperationId
      ..pendingUpdatePredecessorEtagHash = row.pendingUpdatePredecessorEtagHash
      ..updatedAtMs = row.updatedAtMs;
    _recordMaps.put(mirror);
  }

  CloudRecordMapEntry _recordMapEntryFromEntity(
    CloudSyncScope scope,
    CloudRecordMapEntity entity,
  ) => CloudRecordMapEntry(
    scope: scope,
    logicalEntityKeyHash: entity.logicalEntityKeyHash,
    serverRecordIdHash: entity.serverRecordIdHash,
    encryptedServerRecordId: entity.encryptedServerRecordId,
    generation: entity.generation,
    etagHash: entity.etagHash,
    encryptedRawRecordReference: entity.encryptedRawRecordRef,
    rawRecordGeneration: _recordMapRawGeneration(entity),
    protectedReadbackLeaseReference: entity.protectedReadbackLeaseReference,
    pendingUpdateOperationId: entity.pendingUpdateOperationId,
    pendingUpdatePredecessorEtagHash: entity.pendingUpdatePredecessorEtagHash,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      entity.updatedAtMs,
      isUtc: true,
    ),
  );

  /// Recover the original queued Chat and its journal authorization, without
  /// staging another record or demanding evidence that is being refreshed.
  CloudSyncOutboundChatOrigin? captureQueuedChatObservationOrigin(
    CloudOutboxOperation expected,
  ) => _store.runInTransaction(TxMode.read, () {
    final row = _findOutboxByOperationIdLocked(expected.operationId);
    final scope = expected.scope;
    if (row == null ||
        row.scopeKey != _scopeKey(scope) ||
        row.accountFingerprint != scope.accountFingerprint ||
        row.zone != scope.zone ||
        !_outboxFromEntity(scope, row).sameDurableSnapshotAs(expected) ||
        row.state != CloudOutboxStatus.pending.index ||
        expected.status != CloudOutboxStatus.pending) {
      throw _storageFailure('cloud_sync_outbound_chat_recovery_changed');
    }
    return _captureJournalBoundChatOriginLocked(scope, row);
  });

  CloudSyncOutboundChatOrigin? _captureJournalBoundChatOriginLocked(
    CloudSyncScope scope,
    CloudOutboxOperationEntity entity,
  ) {
    final operation = _outboxFromEntity(scope, entity);
    final chatBinding = entity.localChatOrigin;
    if (chatBinding != null && cloudSyncChatOriginIsRetired(chatBinding)) {
      throw _storageFailure('cloud_sync_outbound_chat_source_retired');
    }
    final chatProof = chatBinding == null
        ? null
        : cloudSyncOutboundChatOriginSendProof(chatBinding);
    if (chatProof != null) {
      final chatId = cloudSyncOutboundChatOriginId(chatBinding!);
      final identity = cloudSyncOutboundChatOriginIdentity(chatBinding);
      _requireChatCreateJournal().validateChatCreateBinding(
        _store,
        operation,
        chatId,
        identity,
        chatProof,
      );
      final recovered = readOutboundChatCreateForLocalRow(scope, chatId);
      if (recovered?.operationId != operation.operationId) {
        throw _storageFailure('cloud_sync_outbound_chat_recovery_changed');
      }
      final chat = _store.box<Chat>().get(chatId);
      if (chat == null) {
        throw _storageFailure('cloud_sync_outbound_chat_origin_missing');
      }
      final origin = CloudSyncOutboundChatOrigin.capture(
        scope: scope,
        chat: chat,
      );
      if (origin.binding(operation.checkpointGeneration) != identity) {
        throw _storageFailure('cloud_sync_outbound_chat_origin_changed');
      }
      return origin;
    }
    return null;
  }

  void _requireOperationProjectionReadyLocked(
    CloudSyncScope scope,
    CloudOutboxOperationEntity entity,
  ) {
    final operation = _outboxFromEntity(scope, entity);
    if (_isMessagesCloudSemanticScope(scope) &&
        scope.zone == 'messageManateeZone' &&
        operation.payloadVersion == cloudSyncMessageUpdatePayloadVersion) {
      final journal = _localMutationJournal;
      if (journal == null || !journal.isBoundToStore(_store)) {
        throw StateError('cloud_sync_local_mutation_journal_required');
      }
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(scope));
      final predecessor = checkpoint == null
          ? null
          : cloudSyncFindRecordMap(
              store: _store,
              scope: scope,
              generation: checkpoint.generation,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              serverRecordIdHash: operation.serverRecordIdHash,
            );
      if (checkpoint == null ||
          operation.checkpointGeneration != checkpoint.generation ||
          predecessor == null) {
        throw _storageFailure('protected_message_update_predecessor_changed');
      }
      journal.validateAdoptedOperation(_store, operation, predecessor);
      // A conditional update owns one exact, already-mapped CloudKit record.
      // Unrelated retained history cannot make that record ambiguous, while a
      // retained deletion of this exact record must still block submission.
      // The server ETag remains the final concurrency fence for a newer save.
      _requireMessagesCloudAccountProjectionReadyLocked(
        scope,
        allowRetainedForFreshCreate: true,
        freshRecordIdHash: operation.serverRecordIdHash,
      );
      return;
    }
    if (_isMessagesCloudSemanticScope(scope) &&
        scope.zone == 'attachmentManateeZone' &&
        operation.payloadVersion == 1) {
      final uploads = _attachmentUploadJournal;
      if (uploads == null || !uploads.isBoundTo(_store, scope)) {
        throw StateError('cloud_sync_attachment_upload_journal_required');
      }
      uploads.requireAdoptedOperation(operation);
      _requireMessagesCloudAccountProjectionReadyLocked(
        scope,
        allowRetainedForFreshCreate: true,
        freshRecordIdHash: operation.serverRecordIdHash,
      );
      return;
    }
    final origin = _captureJournalBoundChatOriginLocked(scope, entity);
    if (origin != null) {
      _requireMessagesCloudAccountProjectionReadyLocked(
        scope,
        allowRetainedForFreshCreate: true,
        requireResolvedChatSaves: true,
        freshRecordIdHash: operation.serverRecordIdHash,
        requireChatIdentityEvidence: _readChatIdentityEvidence == null
            ? null
            : () {
                final evidence = _readChatIdentityEvidence(operation);
                if (evidence == null) {
                  throw _storageFailure(
                    'cloud_sync_chat_identity_evidence_required',
                  );
                }
                evidence.requireOperation(
                  store: _store,
                  origin: origin,
                  operation: operation,
                );
              },
      );
      _requireNoPriorChatIdentityLocked(
        origin,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        allowedOperationId: operation.operationId,
        freshRecordIdHash: operation.serverRecordIdHash,
      );
      return;
    }
    final journal = _localSendJournal;
    final source = journal?.readAdoptedCreateSource(_store, operation);
    if (journal == null || source == null) {
      _requireMessagesCloudAccountProjectionReadyLocked(scope);
      if (journal == null) {
        // A generic store may read an adopted envelope, but cannot send it
        // without the account-bound journal that validates its dependencies.
        final query =
            _store
                .box<CloudSyncLocalSendIntentEntity>()
                .query(
                  CloudSyncLocalSendIntentEntity_.admittedOperationId.equals(
                    operation.operationId,
                  ),
                )
                .build()
              ..limit = 1;
        try {
          if (query.findFirst() != null) {
            throw StateError('cloud_sync_local_send_journal_required');
          }
        } finally {
          query.close();
        }
      }
      return;
    }
    // Validate mapping, original protected envelope and current generation in
    // this same transaction, including after restart and after lease changes.
    journal.requireIdsConfirmationForDispatch(source);
    readAdoptedLocalSendOperation(scope, journal: journal, source: source);
    requireCloudSyncAdoptedLocalSendDependencies(
      store: _store,
      messageScope: scope,
      binding: source.admittedChatBinding,
      requireAttachmentReadback: (proof) =>
          journal.requireAttachmentParentReadback(source, proof),
      readConfirmedLocalParent: (parent) =>
          journal.readConfirmedParentDependency(_store, scope, parent),
    );
    _requireMessagesCloudAccountProjectionReadyLocked(
      scope,
      allowRetainedForFreshCreate: true,
      freshRecordIdHash: operation.serverRecordIdHash,
    );
  }

  void _requireMessagesCloudAccountProjectionReadyLocked(
    CloudSyncScope scope, {
    bool allowRetainedForFreshCreate = false,
    bool requireResolvedChatSaves = false,
    String? freshRecordIdHash,
    void Function()? requireChatIdentityEvidence,
  }) {
    if (!_isMessagesCloudSemanticScope(scope)) return;

    for (final zone in _messagesCloudSemanticZones) {
      final siblingScope = CloudSyncScope(
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: zone,
        streamKind: scope.streamKind,
        schemaVersion: scope.schemaVersion,
        persistenceLane: scope.persistenceLane,
      );
      final checkpoint = _findCheckpointByKeyLocked(_scopeKey(siblingScope));
      if (checkpoint == null) {
        throw _storageFailure('messages_cloud_account_projection_incomplete');
      }
      _validateCheckpointScope(checkpoint, siblingScope);
      // A journal-proven new send may create a new random Chat record after
      // unrelated deletions. This grants no old-message replay or deletion
      // permission. Undecoded Chat saves block unless every retained save was
      // natively observed as disjoint from this exact staged candidate.
      final allowRetained = allowRetainedForFreshCreate;
      final requireResolvedSaves =
          requireResolvedChatSaves && zone == 'chatManateeZone';
      // Retention is not completed projection. Only a journal-proven initial
      // create may be independent of unrelated history. It still cannot
      // recreate a record with an observed deletion; all other writes keep
      // the original full-projection requirement.
      final freshRecordTombstoneConflict =
          allowRetainedForFreshCreate &&
          freshRecordIdHash != null &&
          siblingScope == scope &&
          _findInboxForScopeLocked(scope).any(
            (row) =>
                row.generation == checkpoint.generation &&
                row.isTombstone &&
                row.changeType == CloudChangeType.delete.name &&
                row.serverRecordIdHash == freshRecordIdHash,
          );
      if ((!allowRetained &&
              _hasRetainedTombstoneLocked(siblingScope, checkpoint)) ||
          freshRecordTombstoneConflict) {
        if (freshRecordTombstoneConflict && requireResolvedChatSaves) {
          try {
            _recordExistingHistoryDiagnostic?.call(
              'outbound_chat_existing_history_tombstone_conflict',
            );
          } catch (_) {
            // Diagnostics must never replace the projection failure.
          }
        }
        throw _storageFailure(
          'messages_cloud_tombstone_projection_unavailable',
        );
      }
      if (checkpoint.generation <= 0 ||
          checkpoint.lastSuccessfulAtMs <= 0 ||
          checkpoint.lastErrorCategory != null ||
          checkpoint.backoffAttempt != 0 ||
          checkpoint.nextEligibleAtMs != 0 ||
          checkpoint.pendingBatchId != null ||
          checkpoint.pendingFetchedTokenCiphertext != null ||
          checkpoint.appliedSequence < 0 ||
          checkpoint.appliedSequence > checkpoint.fetchedSequence ||
          (allowRetained
              ? !_isCompleteTerminalInboxJournalLocked(siblingScope, checkpoint)
              : (checkpoint.appliedSequence != checkpoint.fetchedSequence ||
                    !_isCompleteAppliedInboxJournalLocked(
                      siblingScope,
                      checkpoint,
                    )))) {
        throw _storageFailure('messages_cloud_account_projection_incomplete');
      }
      if (allowRetained &&
          requireResolvedSaves &&
          !_hasOnlyAppliedChatSavesLocked(siblingScope, checkpoint)) {
        if (requireChatIdentityEvidence == null) {
          throw _storageFailure('messages_cloud_account_projection_incomplete');
        }
        requireChatIdentityEvidence();
      }
    }
  }

  /// A retained tombstone is not an applied deletion. It stays in the inbox
  /// with its exact record identity and does not advance the applied floor.
  /// Only those structurally valid terminal deletions may be independent of a
  /// fresh Chat. Every save must have completed projection, even if its decoder
  /// classified it as unsupported or out of scope.
  bool _hasOnlyAppliedChatSavesLocked(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity checkpoint,
  ) => _findInboxForScopeLocked(scope)
      .where((row) => row.generation == checkpoint.generation)
      .every(
        (row) =>
            row.status == CloudInboxStatus.applied.index ||
            (row.status == CloudInboxStatus.retainedUnprojected.index &&
                row.isTombstone &&
                row.changeType == CloudChangeType.delete.name &&
                row.failureCategory == null &&
                row.preflightCategory == null &&
                row.preflightCode == null),
      );

  bool _hasRetainedTombstoneLocked(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity checkpoint,
  ) => _findInboxForScopeLocked(scope).any(
    (row) =>
        row.generation == checkpoint.generation &&
        row.status == CloudInboxStatus.retainedUnprojected.index &&
        row.changeType == CloudChangeType.delete.name &&
        row.isTombstone,
  );

  bool _isMessagesCloudSemanticScope(CloudSyncScope scope) =>
      scope.container == _messagesCloudContainer &&
      scope.database == _messagesCloudDatabase &&
      scope.streamKind == CloudSyncStreamKind.messages &&
      scope.schemaVersion == cloudSyncSchemaVersion &&
      scope.persistenceLane == CloudSyncPersistenceLane.semantic &&
      _messagesCloudSemanticZones.contains(scope.zone);

  bool _isCompleteAppliedInboxJournalLocked(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity checkpoint,
  ) {
    final rows =
        _findInboxForScopeLocked(
            scope,
          ).where((row) => row.generation == checkpoint.generation).toList()
          ..sort(
            (left, right) => left.fetchSequence.compareTo(right.fetchSequence),
          );
    if (rows.length != checkpoint.fetchedSequence) return false;
    for (final (index, row) in rows.indexed) {
      if (row.fetchSequence != index + 1 ||
          row.scopeKey != _scopeKey(scope) ||
          row.accountFingerprint != scope.accountFingerprint ||
          row.zone != scope.zone ||
          row.generation != checkpoint.generation ||
          _inboxStatusFromInt(row.status) != CloudInboxStatus.applied) {
        return false;
      }
    }
    return true;
  }

  bool _hasUnmarkedPendingInboxLocked(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity checkpoint,
  ) {
    if (checkpoint.pendingBatchId != null) return false;
    // fetchedSequence may legitimately exceed the exact-applied floor when a
    // protected row is retained for later projection repair. Only an
    // incomplete, missing, or nonterminal journal is unsafe without a pending
    // batch marker.
    return !_isCompleteTerminalInboxJournalLocked(scope, checkpoint);
  }

  bool _isExactlyAppliedInboxStatus(CloudInboxStatus status) =>
      status == CloudInboxStatus.applied;

  bool _isTerminalInboxStatus(CloudInboxStatus status) =>
      status == CloudInboxStatus.applied ||
      status == CloudInboxStatus.retainedUnprojected;

  Set<int> _semanticReplayInboxSequencesLocked(
    CloudSyncScope scope, {
    required int generation,
  }) {
    final query = _semanticReplays
        .query(
          CloudSemanticReplayEntity_.scopeKey
              .equals(_scopeKey(scope))
              .and(CloudSemanticReplayEntity_.generation.equals(generation)),
        )
        .build();
    try {
      return query.find().map((row) => row.inboxSequence).toSet();
    } finally {
      query.close();
    }
  }

  bool _hasSemanticReplayForInboxSequenceLocked(
    CloudSyncScope scope, {
    required int generation,
    required int sequence,
  }) {
    final query = _semanticReplays
        .query(
          CloudSemanticReplayEntity_.scopeKey
              .equals(_scopeKey(scope))
              .and(CloudSemanticReplayEntity_.generation.equals(generation))
              .and(CloudSemanticReplayEntity_.inboxSequence.equals(sequence)),
        )
        .build();
    try {
      return query.count() != 0;
    } finally {
      query.close();
    }
  }

  bool _hasRecordMapForServerRecordLocked(
    CloudSyncScope scope, {
    required int generation,
    required String serverRecordIdHash,
  }) {
    final query = _recordMaps
        .query(
          CloudRecordMapEntity_.scopeKey
              .equals(_scopeKey(scope))
              .and(CloudRecordMapEntity_.generation.equals(generation))
              .and(
                CloudRecordMapEntity_.serverRecordIdHash.equals(
                  serverRecordIdHash,
                ),
              ),
        )
        .build();
    try {
      return query.count() != 0;
    } finally {
      query.close();
    }
  }

  bool _mayRetainUnprojected(
    CloudInboxEntry entry, {
    required CloudFailureCategory? category,
    required DateTime now,
    required int maximumDeferredAttempts,
    required Duration maximumDeferredAge,
    required bool includeCurrentAttempt,
    String? readOnlySemanticAttachmentConflictSafeCode,
  }) {
    // A read-only tombstone reaches this method with no failure category.
    // Never let the tombstone shape override a conflict/unknown classification
    // recovered from an older build; those remain causal barriers.
    if (entry.change.isTombstone && category == null) return true;
    if (category == CloudFailureCategory.outOfScopeService) {
      return entry.change.type == CloudChangeType.save &&
          !entry.change.isTombstone &&
          entry.change.preflightFailure == null &&
          entry.change.preflightCode == null;
    }
    if (category == CloudFailureCategory.malformedRecord ||
        category == CloudFailureCategory.unsupportedService) {
      return true;
    }
    if (CloudSyncV2LegacyOwnershipSafeFailureCodes
            .readOnlyCanaryRetainableAttachmentConflicts
            .contains(readOnlySemanticAttachmentConflictSafeCode) &&
        category == CloudFailureCategory.conflict) {
      return _isMessagesCloudSemanticScope(entry.scope) &&
          entry.scope.zone == 'attachmentManateeZone' &&
          entry.change.type == CloudChangeType.save &&
          !entry.change.isTombstone &&
          entry.change.preflightFailure == null &&
          entry.change.preflightCode == null;
    }
    if (category != CloudFailureCategory.dependency) return false;
    final attempts = entry.attemptCount + (includeCurrentAttempt ? 1 : 0);
    final age = now.difference(entry.createdAt);
    return attempts >= maximumDeferredAttempts &&
        !age.isNegative &&
        age >= maximumDeferredAge;
  }

  void _validateTransition(CloudOutboxTransition transition) {
    if (transition.retainProtectedLeaseReference &&
        transition.type != CloudOutboxTransitionType.confirmed) {
      throw ArgumentError(
        'Only confirmed transitions may retain a protected receipt',
      );
    }
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

  CloudInboxChangeEntity? _findFirstNonterminalInboxLocked(
    CloudSyncScope scope,
    CloudSyncCheckpointEntity checkpoint,
  ) {
    final scopeKey = _scopeKey(scope);
    final builder = _inbox.query(
      CloudInboxChangeEntity_.scopeKey
          .equals(scopeKey)
          .and(CloudInboxChangeEntity_.generation.equals(checkpoint.generation))
          .and(
            CloudInboxChangeEntity_.status.notEquals(
              _inboxStatusToInt(CloudInboxStatus.applied),
            ),
          )
          .and(
            CloudInboxChangeEntity_.status.notEquals(
              _inboxStatusToInt(CloudInboxStatus.retainedUnprojected),
            ),
          ),
    )..order(CloudInboxChangeEntity_.fetchSequence);
    final query = builder.build()..limit = 1;
    final CloudInboxChangeEntity? entity;
    try {
      entity = query.findFirst();
    } finally {
      query.close();
    }
    if (entity == null) return null;
    if (entity.fetchSequence <= 0 ||
        entity.fetchSequence > checkpoint.fetchedSequence) {
      throw _storageFailure('inbox_nonterminal_sequence_invalid');
    }

    // Page admission writes a complete contiguous journal atomically. Keep a
    // defensive count here so a legacy missing sequence cannot be skipped just
    // because a later pending row is otherwise eligible.
    final predecessorQuery = _inbox
        .query(
          CloudInboxChangeEntity_.scopeKey
              .equals(scopeKey)
              .and(
                CloudInboxChangeEntity_.generation.equals(
                  checkpoint.generation,
                ),
              )
              .and(
                CloudInboxChangeEntity_.fetchSequence.lessThan(
                  entity.fetchSequence,
                ),
              ),
        )
        .build();
    try {
      if (predecessorQuery.count() != entity.fetchSequence - 1) {
        throw _storageFailure('inbox_journal_sequence_gap');
      }
    } finally {
      predecessorQuery.close();
    }
    return entity;
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

  bool _hasBlockingOutboxLocked(CloudSyncScope scope) {
    final blockingState = CloudOutboxOperationEntity_.state
        .equals(_outboxStatusToInt(CloudOutboxStatus.pending))
        .or(
          CloudOutboxOperationEntity_.state.equals(
            _outboxStatusToInt(CloudOutboxStatus.leased),
          ),
        )
        .or(
          CloudOutboxOperationEntity_.state.equals(
            _outboxStatusToInt(CloudOutboxStatus.paused),
          ),
        )
        .or(
          CloudOutboxOperationEntity_.state.equals(
            _outboxStatusToInt(CloudOutboxStatus.unknownOutcome),
          ),
        );
    final query =
        _outbox
            .query(
              CloudOutboxOperationEntity_.scopeKey
                  .equals(_scopeKey(scope))
                  .and(blockingState),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst() != null;
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

  List<CloudRecordMapEntity> _pendingMessageReadbackMappings(
    CloudSyncScope scope,
    int generation,
  ) => _findRecordMapsForScopeLocked(scope)
      .where(
        (mapping) =>
            mapping.generation == generation &&
            (mapping.protectedReadbackLeaseReference != null ||
                mapping.pendingUpdateOperationId != null ||
                mapping.pendingUpdatePredecessorEtagHash != null),
      )
      .toList(growable: false);

  void _validatePendingMessageReadbackMappingLease(
    CloudRecordMapEntity mapping,
  ) {
    final lease = mapping.protectedReadbackLeaseReference;
    final operationId = mapping.pendingUpdateOperationId;
    final recordedEtag = mapping.pendingUpdatePredecessorEtagHash;
    if (lease == null && operationId == null && recordedEtag == null) {
      return;
    }
    if (mapping.etagHash != null && mapping.etagHash == recordedEtag) {
      _validatePendingMessageCreateMappingLease(mapping);
      return;
    }
    _validatePendingMessageUpdateMappingLease(mapping);
  }

  CloudOutboxOperationEntity _findPendingMessageReadbackOutboxLocked(
    CloudSyncScope scope,
    CloudRecordMapEntity mapping,
  ) {
    final operationId = mapping.pendingUpdateOperationId;
    if (operationId == null) {
      throw _storageFailure('message_readback_inventory_corrupt');
    }
    final entity = _findOutboxByOperationIdLocked(operationId);
    if (entity == null || entity.scopeKey != _scopeKey(scope)) {
      throw _storageFailure('message_readback_inventory_corrupt');
    }
    return entity;
  }

  void _validatePendingMessageCreateMappingLease(
    CloudRecordMapEntity mapping,
  ) {
    final lease = mapping.protectedReadbackLeaseReference;
    final operationId = mapping.pendingUpdateOperationId;
    final currentEtag = mapping.etagHash;
    final recordedEtag = mapping.pendingUpdatePredecessorEtagHash;
    if (lease == null ||
        !_isProtectedPageLease(lease) ||
        operationId == null ||
        !RegExp(r'^op1:[0-9a-f]{64}$').hasMatch(operationId) ||
        currentEtag == null ||
        !_isNativeDigest(currentEtag) ||
        recordedEtag == null ||
        recordedEtag != currentEtag ||
        mapping.encryptedRawRecordRef == null ||
        !_isNativeProtectedReference(mapping.encryptedRawRecordRef!) ||
        _recordMapRawGeneration(mapping) <= 0) {
      throw _storageFailure('message_create_readback_mapping_corrupt');
    }
  }

  void _validatePendingMessageUpdateMappingLease(CloudRecordMapEntity mapping) {
    final lease = mapping.protectedReadbackLeaseReference;
    final operationId = mapping.pendingUpdateOperationId;
    final predecessorEtag = mapping.pendingUpdatePredecessorEtagHash;
    if (lease == null && operationId == null && predecessorEtag == null) {
      return;
    }
    if (lease == null ||
        !_isProtectedPageLease(lease) ||
        operationId == null ||
        !RegExp(r'^op1:[0-9a-f]{64}$').hasMatch(operationId) ||
        predecessorEtag == null ||
        !_isNativeDigest(predecessorEtag) ||
        mapping.etagHash == null ||
        !_isNativeDigest(mapping.etagHash!) ||
        mapping.etagHash == predecessorEtag ||
        mapping.encryptedRawRecordRef == null ||
        !_isNativeProtectedReference(mapping.encryptedRawRecordRef!) ||
        _recordMapRawGeneration(mapping) <= 0) {
      throw _storageFailure('message_update_readback_mapping_corrupt');
    }
  }

  /// Before this nullable schema field existed, raw record references were
  /// always protected with their record-map checkpoint generation. Preserve
  /// that exact meaning for upgraded rows instead of making them unusable.
  int _recordMapRawGeneration(CloudRecordMapEntity mapping) =>
      mapping.encryptedRawRecordRef == null
      ? 0
      : mapping.rawRecordGeneration > 0
      ? mapping.rawRecordGeneration
      : mapping.generation;

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
    CloudInboxStatus.retainedUnprojected => 3,
  };

  CloudInboxStatus _inboxStatusFromInt(int status) => switch (status) {
    0 => CloudInboxStatus.pending,
    1 => CloudInboxStatus.applied,
    2 => CloudInboxStatus.quarantined,
    3 => CloudInboxStatus.retainedUnprojected,
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

final class _ExistingChatHistoryMatches {
  const _ExistingChatHistoryMatches({
    required this.localChatMatch,
    required this.snapshotMatch,
    required this.aliasMatch,
    required this.priorOutboundOriginMatch,
    required this.recordMapConflict,
    required this.tombstoneConflict,
  });

  final bool localChatMatch;
  final bool snapshotMatch;
  final bool aliasMatch;
  final bool priorOutboundOriginMatch;
  final bool recordMapConflict;
  final bool tombstoneConflict;

  bool get hasExistingHistory =>
      localChatMatch ||
      snapshotMatch ||
      aliasMatch ||
      priorOutboundOriginMatch ||
      recordMapConflict;

  List<String> get diagnosticCodes => <String>[
    if (localChatMatch) 'outbound_chat_existing_history_local_chat_match',
    if (snapshotMatch) 'outbound_chat_existing_history_snapshot_match',
    if (aliasMatch) 'outbound_chat_existing_history_alias_match',
    if (priorOutboundOriginMatch)
      'outbound_chat_existing_history_prior_outbound_origin_match',
    if (recordMapConflict) 'outbound_chat_existing_history_record_map_conflict',
    if (tombstoneConflict) 'outbound_chat_existing_history_tombstone_conflict',
  ];
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
