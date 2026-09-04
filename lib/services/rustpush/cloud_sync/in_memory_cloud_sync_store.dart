import 'dart:collection';

import 'package:synchronized/synchronized.dart';

import 'cloud_operation_identity.dart';
import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_store.dart';

/// Transactional reference implementation used by unit tests and adapter
/// development. It is not durable across process restarts.
class InMemoryCloudSyncStore
    implements
        CloudSyncStore,
        CloudRetainedUnprojectedBacklogStore,
        CloudRetainedUnprojectedBacklogSummaryStore,
        CloudSyncUnknownOutcomeLeasingStore,
        CloudSyncOutboxPresenceStore,
        CloudCoordinatorLeaseStatusReader,
        CloudConfirmedOutboundReceiptStore {
  final Lock _lock = Lock();
  final Map<String, CloudSyncCheckpoint> _checkpoints = {};
  final Map<String, String?> _pendingFetchedTokens = {};
  final Map<String, SplayTreeMap<int, CloudInboxEntry>> _inbox = {};
  final Map<String, Set<String>> _seenChangeIds = {};
  final Map<String, Map<String, CloudOutboxOperation>> _outbox = {};
  final Map<String, _CoordinatorLease> _coordinatorLeases = {};
  final Map<String, _GenerationBoundRecordMap> _recordMaps = {};
  final List<CloudSyncRunRecord> _runs = [];

  List<CloudSyncRunRecord> get runs => List.unmodifiable(_runs);

  Future<List<CloudInboxEntry>> inboxEntries(CloudSyncScope scope) {
    return _lock.synchronized(() async {
      return List.unmodifiable(
        _inbox[scope.storageKey]?.values ?? const <CloudInboxEntry>[],
      );
    });
  }

  Future<List<CloudOutboxOperation>> outboxEntries(CloudSyncScope scope) {
    return _lock.synchronized(() async {
      return List.unmodifiable(
        _outbox[scope.storageKey]?.values ?? const <CloudOutboxOperation>[],
      );
    });
  }

  @override
  Future<void> clearConfirmedProtectedOutboundLeaseReference({
    required CloudOutboxOperation expectedOperation,
  }) {
    return _lock.synchronized(() async {
      _requireConfirmedReceiptReleaseCandidate(expectedOperation);
      final entries = _outbox[expectedOperation.scope.storageKey];
      final current = entries?[expectedOperation.operationId];
      if (current == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'confirmed_outbound_receipt_row_missing',
        );
      }
      if (!current.sameDurableSnapshotAs(expectedOperation)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'confirmed_outbound_receipt_snapshot_changed',
        );
      }
      entries![expectedOperation.operationId] = current.copyWith(
        clearProtectedLeaseReference: true,
      );
    });
  }

  @override
  Future<bool> hasNonterminalOutbox(CloudSyncScope scope) {
    return _lock.synchronized(() async {
      final entries = _outbox[scope.storageKey];
      return entries != null &&
          entries.values.any(
            (operation) => _isBlockingOutboxStatus(operation.status),
          );
    });
  }

  @override
  Future<CloudSyncCheckpoint> readCheckpoint(CloudSyncScope scope) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      return checkpoint.copyWith(
        hasUnmarkedPendingInbox: _hasUnmarkedPendingInbox(scope, checkpoint),
      );
    });
  }

  @override
  Future<int> journalFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  }) {
    return _lock.synchronized(() async {
      _requireCommitFenceLocked(
        batch.scope,
        leaseFence: leaseFence,
        expectedGeneration: expectedGeneration,
        expectedFetchedToken: expectedFetchedToken,
        now: now,
      );
      return _journalFetchedBatchLocked(batch, now: now);
    });
  }

  @override
  Future<CloudShadowJournalUsage> readShadowJournalUsage(
    CloudSyncScope scope, {
    required CloudShadowJournalBudget budget,
  }) {
    budget.validate();
    return _lock.synchronized(
      () async => _shadowJournalUsageLocked(scope, budget),
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
  }) {
    budget.validate();
    return _lock.synchronized(() async {
      final checkpoint = _requireCommitFenceLocked(
        batch.scope,
        leaseFence: leaseFence,
        expectedGeneration: expectedGeneration,
        expectedFetchedToken: expectedFetchedToken,
        now: now,
      );
      _requireGeneration(batch, checkpoint);

      final current = _shadowJournalUsageLocked(batch.scope, budget);
      final currentReason = budget.blockReasonForCurrentUsage(
        current,
        now: now,
      );
      if (currentReason != null) {
        return CloudShadowJournalAdmission(
          insertedEntries: 0,
          rejectedEntries: 0,
          usage: current,
          blockReason: currentReason,
        );
      }

      final seen = _seenChangeIds[batch.scope.storageKey] ?? const <String>{};
      final pageIds = <String>{};
      final unseen = batch.changes
          .where(
            (change) =>
                pageIds.add(change.changeId) && !seen.contains(change.changeId),
          )
          .toList(growable: false);
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
        oldestAt: unseen.isEmpty ? null : now,
      );
      final projectedReason = budget.blockReasonForProjectedUsage(
        projected,
        now: now,
      );
      if (projectedReason != null) {
        return CloudShadowJournalAdmission(
          insertedEntries: 0,
          rejectedEntries: unseen.length,
          usage: current,
          blockReason: projectedReason,
        );
      }

      final inserted = _journalFetchedBatchLocked(
        batch,
        now: now,
        deferTokenUntilTerminal: false,
      );
      return CloudShadowJournalAdmission(
        insertedEntries: inserted,
        rejectedEntries: 0,
        usage: projected,
      );
    });
  }

  @override
  Future<void> recordPullFailure(
    CloudSyncScope scope, {
    required CloudFailureCategory category,
    required DateTime nextEligibleAt,
  }) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      _checkpoints[scope.storageKey] = checkpoint.copyWith(
        consecutivePullFailures: checkpoint.consecutivePullFailures + 1,
        nextPullEligibleAt: nextEligibleAt,
        lastFailure: category,
      );
    });
  }

  @override
  Future<void> recordPullSuccess(
    CloudSyncScope scope, {
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      _checkpoints[scope.storageKey] = _checkpoint(scope).copyWith(
        consecutivePullFailures: 0,
        clearNextPullEligibleAt: true,
        lastSuccessfulRunAt: now,
        clearLastFailure: true,
      );
    });
  }

  @override
  Future<List<CloudInboxEntry>> readEligibleInbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
  }) {
    _requirePositiveLimit(limit);
    return _lock.synchronized(() async {
      // Retained rows are terminal for fetch progress but deliberately do not
      // advance the exact-applied projection floor. Select the first remaining
      // nonterminal row rather than deriving eligibility from that floor.
      final entry = _findFirstNonterminalInbox(scope, _checkpoint(scope));
      if (entry == null ||
          entry.status != CloudInboxStatus.pending ||
          (entry.nextEligibleAt != null &&
              entry.nextEligibleAt!.isAfter(now))) {
        return const <CloudInboxEntry>[];
      }
      return <CloudInboxEntry>[entry];
    });
  }

  @override
  Future<int> readRetainedUnprojectedInboxCount(CloudSyncScope scope) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoints[scope.storageKey];
      if (checkpoint == null) return 0;
      final generation = checkpoint.generation;
      return (_inbox[scope.storageKey]?.values ?? const <CloudInboxEntry>[])
          .where(
            (entry) =>
                entry.generation == generation &&
                entry.status == CloudInboxStatus.retainedUnprojected,
          )
          .length;
    });
  }

  @override
  Future<CloudRetainedUnprojectedBacklogSummary>
  readRetainedUnprojectedInboxSummary(CloudSyncScope scope) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoints[scope.storageKey];
      if (checkpoint == null) {
        return CloudRetainedUnprojectedBacklogSummary(
          total: 0,
          saves: 0,
          tombstones: 0,
          unclassified: 0,
        );
      }
      final rows =
          (_inbox[scope.storageKey]?.values ?? const <CloudInboxEntry>[])
              .where(
                (entry) =>
                    entry.generation == checkpoint.generation &&
                    entry.status == CloudInboxStatus.retainedUnprojected,
              )
              .toList(growable: false);
      final categories = <CloudFailureCategory, int>{};
      var tombstones = 0;
      var unclassified = 0;
      var outOfScopeServices = 0;
      for (final row in rows) {
        if (row.change.isTombstone) tombstones++;
        final category = row.lastFailure;
        if (category == null) {
          unclassified++;
        } else {
          categories.update(category, (count) => count + 1, ifAbsent: () => 1);
          if (category == CloudFailureCategory.outOfScopeService &&
              !row.change.isTombstone) {
            outOfScopeServices++;
          }
        }
      }
      return CloudRetainedUnprojectedBacklogSummary(
        total: rows.length,
        saves: rows.length - tombstones,
        tombstones: tombstones,
        unclassified: unclassified,
        outOfScopeServices: outOfScopeServices,
        byFailureCategory: categories,
      );
    });
  }

  @override
  Future<void> markInboxApplied(
    CloudSyncScope scope, {
    required int sequence,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  }) {
    return _lock.synchronized(() async {
      _requireActiveCoordinatorLeaseLocked(scope, leaseFence, now);
      final entry = _requireInboxEntry(scope, sequence);
      if (entry.status == CloudInboxStatus.applied) {
        _advanceContiguousAppliedPosition(scope);
        return;
      }
      if (entry.status != CloudInboxStatus.pending) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_transition_not_pending',
        );
      }
      _inbox[scope.storageKey]![sequence] = entry.copyWith(
        status: CloudInboxStatus.applied,
        completedAt: now,
        clearLastFailure: true,
        clearNextEligibleAt: true,
      );
      _advanceContiguousAppliedPosition(scope);
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
  }) {
    return _lock.synchronized(() async {
      _requireActiveCoordinatorLeaseLocked(scope, leaseFence, now);
      final entry = _requireInboxEntry(scope, sequence);
      if (entry.status == CloudInboxStatus.retainedUnprojected) {
        _promotePendingFetchedTokenIfTerminal(scope, _checkpoint(scope));
        return;
      }
      if (entry.status != CloudInboxStatus.pending &&
          entry.status != CloudInboxStatus.quarantined) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_retention_transition_invalid',
        );
      }
      if (entry.status == CloudInboxStatus.quarantined &&
          entry.lastFailure != category) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_retention_category_mismatch',
        );
      }
      if (!_mayRetainUnprojected(
        entry,
        category: category,
        now: now,
        maximumDeferredAttempts: maximumDeferredAttempts,
        maximumDeferredAge: maximumDeferredAge,
        includeCurrentAttempt: entry.status == CloudInboxStatus.pending,
        readOnlySemanticAttachmentConflictSafeCode:
            readOnlySemanticAttachmentConflictSafeCode,
      )) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_retention_policy_rejected',
        );
      }
      _inbox[scope.storageKey]![sequence] = entry.copyWith(
        status: CloudInboxStatus.retainedUnprojected,
        attemptCount: entry.status == CloudInboxStatus.pending
            ? entry.attemptCount + 1
            : entry.attemptCount,
        lastFailure: category,
        completedAt: now,
        clearNextEligibleAt: true,
      );
      _promotePendingFetchedTokenIfTerminal(scope, _checkpoint(scope));
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
  }) {
    return _lock.synchronized(() async {
      _requireActiveCoordinatorLeaseLocked(scope, leaseFence, now);
      final checkpoint = _checkpoint(scope);
      final rows =
          (_inbox[scope.storageKey]?.values ?? const <CloudInboxEntry>[])
              .where((entry) => entry.generation == checkpoint.generation)
              .toList()
            ..sort((left, right) => left.sequence.compareTo(right.sequence));
      if (rows.length != checkpoint.fetchedSequence ||
          rows.indexed.any((item) => item.$2.sequence != item.$1 + 1)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_retention_journal_incomplete',
        );
      }

      if (checkpoint.lastAppliedSequence > checkpoint.fetchedSequence) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_retention_checkpoint_invalid',
        );
      }
      final previousAppliedSequence = checkpoint.lastAppliedSequence;
      var exactAppliedPrefix = 0;
      for (final entry in rows) {
        if (!_isExactlyAppliedInboxStatus(entry.status)) break;
        exactAppliedPrefix = entry.sequence;
      }
      final legacyAppliedFloorInflated =
          checkpoint.pendingBatchId == null &&
          checkpoint.lastAppliedSequence > exactAppliedPrefix;

      var retained = 0;
      var tombstones = 0;
      for (final entry in rows) {
        final legacyReadOnlyTombstone =
            allowLegacyReadOnlyTombstoneAcknowledgement &&
            legacyAppliedFloorInflated &&
            entry.sequence <= checkpoint.lastAppliedSequence &&
            entry.lastFailure == CloudFailureCategory.conflict &&
            entry.change.isTombstone &&
            entry.change.type == CloudChangeType.delete &&
            entry.change.preflightFailure == null &&
            entry.change.preflightCode == null;
        if (entry.status != CloudInboxStatus.quarantined ||
            (!legacyReadOnlyTombstone &&
                !_mayRetainUnprojected(
                  entry,
                  category: entry.lastFailure,
                  now: now,
                  maximumDeferredAttempts: maximumDeferredAttempts,
                  maximumDeferredAge: maximumDeferredAge,
                  includeCurrentAttempt: false,
                ))) {
          continue;
        }
        _inbox[scope.storageKey]![entry.sequence] = entry.copyWith(
          status: CloudInboxStatus.retainedUnprojected,
          completedAt: now,
          clearNextEligibleAt: true,
        );
        retained++;
        if (entry.change.isTombstone) tombstones++;
      }
      final recomputedAppliedSequence = _recomputeContiguousAppliedPosition(
        scope,
      );
      final reconciledRows =
          (_inbox[scope.storageKey]?.values ?? const <CloudInboxEntry>[])
              .where((entry) => entry.generation == checkpoint.generation)
              .toList()
            ..sort((left, right) => left.sequence.compareTo(right.sequence));
      CloudInboxEntry? firstUnresolved;
      for (final entry in reconciledRows) {
        if (!_isExactlyAppliedInboxStatus(entry.status)) {
          firstUnresolved = entry;
          break;
        }
      }
      return CloudInboxRetentionRecovery(
        retainedUnprojected: retained,
        tombstoneReadOnlyAcknowledged: tombstones,
        previousAppliedSequence: previousAppliedSequence,
        recomputedAppliedSequence: recomputedAppliedSequence,
        legacyFloorInflated: legacyAppliedFloorInflated,
        firstUnresolvedSequence: firstUnresolved?.sequence,
        firstUnresolvedStatus: firstUnresolved?.status,
        firstUnresolvedCategory: firstUnresolved?.lastFailure,
        recoveryComplete: firstUnresolved == null,
      );
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
  }) {
    return _lock.synchronized(() async {
      _requireActiveCoordinatorLeaseLocked(scope, leaseFence, now);
      final entry = _requireInboxEntry(scope, sequence);
      if (entry.status != CloudInboxStatus.pending) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_transition_not_pending',
        );
      }
      if (entry.lastFailure == category &&
          entry.nextEligibleAt != null &&
          !entry.nextEligibleAt!.isBefore(nextEligibleAt)) {
        return;
      }
      _inbox[scope.storageKey]![sequence] = entry.copyWith(
        status: CloudInboxStatus.pending,
        attemptCount: entry.attemptCount + 1,
        nextEligibleAt:
            entry.nextEligibleAt != null &&
                entry.nextEligibleAt!.isAfter(nextEligibleAt)
            ? entry.nextEligibleAt
            : nextEligibleAt,
        lastFailure: category,
      );
    });
  }

  @override
  Future<void> quarantineInbox(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory category,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  }) {
    return _lock.synchronized(() async {
      _requireActiveCoordinatorLeaseLocked(scope, leaseFence, now);
      final entry = _requireInboxEntry(scope, sequence);
      if (entry.status == CloudInboxStatus.quarantined &&
          entry.lastFailure == category) {
        return;
      }
      if (entry.status != CloudInboxStatus.pending) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'inbox_transition_not_pending',
        );
      }
      _inbox[scope.storageKey]![sequence] = entry.copyWith(
        status: CloudInboxStatus.quarantined,
        attemptCount: entry.attemptCount + 1,
        lastFailure: category,
        completedAt: now,
        clearNextEligibleAt: true,
      );
    });
  }

  @override
  Future<void> enqueueOutbox(CloudOutboxOperation operation) {
    return _lock.synchronized(() async {
      _fenceStaleOutboxLocked(operation.scope, now: operation.createdAt);
      _enqueueOutboxLocked(operation);
    });
  }

  @override
  Future<CloudOutboxOperation> enqueueOutboxMutation(CloudOutboxDraft draft) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(draft.scope);
      _fenceStaleOutboxLocked(draft.scope, now: draft.createdAt);
      final revision = checkpoint.mutationRevisionCounter + 1;
      _checkpoints[draft.scope.storageKey] = checkpoint.copyWith(
        mutationRevisionCounter: revision,
      );
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
        dependencyOperationIds: draft.dependencyOperationIds,
        createdAt: draft.createdAt,
      );
      _enqueueOutboxLocked(operation);
      return operation;
    });
  }

  @override
  Future<CloudSyncResetCompletionProof> rebootstrapAfterReset(
    CloudSyncResetRebootstrapRequest request, {
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      final activeLease = _coordinatorLeases[request.scope.storageKey];
      if (activeLease != null && activeLease.expiresAt.isAfter(now)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'reset_rebootstrap_coordinator_active',
        );
      }
      final checkpoint = _checkpoint(request.scope);
      if (checkpoint.generation != request.expectedGeneration) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'reset_rebootstrap_generation_mismatch',
        );
      }
      final previousGeneration = checkpoint.generation;
      final generation = previousGeneration + 1;
      _checkpoints[request.scope.storageKey] = checkpoint.copyWith(
        generation: generation,
        clearFetchedToken: true,
        lastBatchId: null,
        clearPendingBatchId: true,
        fetchedSequence: 0,
        lastAppliedSequence: 0,
        consecutivePullFailures: 0,
        clearNextPullEligibleAt: true,
        lastSuccessfulRunAt: null,
        clearLastFailure: true,
      );
      _fenceStaleOutboxLocked(
        request.scope,
        now: now,
        checkpoint: _checkpoints[request.scope.storageKey],
      );
      // The in-memory implementation has no durable archive; dropping only
      // its test journal is the equivalent of fencing old ObjectBox rows.
      _inbox.remove(request.scope.storageKey);
      _seenChangeIds.remove(request.scope.storageKey);
      _pendingFetchedTokens.remove(request.scope.storageKey);
      return CloudSyncResetCompletionProof(
        scope: request.scope,
        transitionIdHash: request.transitionIdHash,
        activeIdentityFingerprint: request.activeIdentityFingerprint,
        previousGeneration: previousGeneration,
        generation: generation,
        protectedRemoteStateProofReference:
            request.protectedRemoteStateProofReference,
      );
    });
  }

  @override
  Future<CloudSyncCheckpoint> advanceOutboxGeneration(
    CloudSyncScope scope, {
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      final activeLease = _coordinatorLeases[scope.storageKey];
      if (activeLease != null && activeLease.expiresAt.isAfter(now)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'generation_advance_coordinator_active',
        );
      }
      final checkpoint = _checkpoint(scope);
      final advanced = checkpoint.copyWith(
        generation: checkpoint.generation + 1,
      );
      _checkpoints[scope.storageKey] = advanced;
      _fenceStaleOutboxLocked(scope, now: now, checkpoint: advanced);
      return advanced;
    });
  }

  @override
  Future<List<CloudOutboxOperation>> leaseEligibleOutbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
    required Set<CloudOutboxAction> allowedActions,
  }) {
    _requirePositiveLimit(limit);
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    return _lock.synchronized(() async {
      final entries = _outbox[scope.storageKey];
      final checkpoint = _checkpoint(scope);
      if (entries != null &&
          entries.values.any(
            (operation) => _isBlockingOutboxStatus(operation.status),
          ) &&
          (checkpoint.pendingBatchId != null ||
              _hasUnmarkedPendingInbox(scope, checkpoint))) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'checkpoint_pending_page_unresolved',
        );
      }
      _fenceStaleOutboxLocked(scope, now: now);
      _recoverExpiredOutboxLeasesLocked(scope, now);
      if (entries == null) return const <CloudOutboxOperation>[];

      final blockingByLogicalKey = <String, CloudOutboxOperation>{};
      for (final operation in entries.values) {
        if (!_isBlockingOutboxStatus(operation.status)) continue;
        final existing = blockingByLogicalKey[operation.logicalEntityKeyHash];
        if (existing == null ||
            _compareMutationOrder(operation, existing) < 0) {
          blockingByLogicalKey[operation.logicalEntityKeyHash] = operation;
        }
      }

      final eligible =
          entries.values
              .where(
                (operation) =>
                    operation.status == CloudOutboxStatus.pending &&
                    allowedActions.contains(operation.action) &&
                    (operation.nextEligibleAt == null ||
                        !operation.nextEligibleAt!.isAfter(now)) &&
                    operation.dependencyOperationIds.every((dependencyId) {
                      final dependency = entries[dependencyId];
                      return dependency?.status ==
                              CloudOutboxStatus.confirmed &&
                          dependency?.checkpointGeneration ==
                              operation.checkpointGeneration;
                    }),
              )
              .toList()
            ..sort((first, second) {
              final created = first.createdAt.compareTo(second.createdAt);
              if (created != 0) return created;
              return first.operationId.compareTo(second.operationId);
            });

      final leased = <CloudOutboxOperation>[];
      for (final operation in eligible) {
        if (leased.length == limit) break;
        final blocker = blockingByLogicalKey[operation.logicalEntityKeyHash];
        if (blocker != null && _compareMutationOrder(blocker, operation) < 0) {
          continue;
        }
        final updated = operation.copyWith(
          status: CloudOutboxStatus.leased,
          leaseId: leaseId,
          leaseExpiresAt: now.add(leaseDuration),
        );
        entries[operation.operationId] = updated;
        leased.add(updated);
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
  }) {
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
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      final entries = _outbox[scope.storageKey];
      final operations = <CloudOutboxOperation>[];
      for (final operationId in ids) {
        final operation = entries?[operationId];
        if (operation == null ||
            operation.checkpointGeneration <= 0 ||
            operation.checkpointGeneration != checkpoint.generation ||
            (operation.status != CloudOutboxStatus.leased &&
                operation.status != CloudOutboxStatus.unknownOutcome) ||
            operation.leaseId != leaseId ||
            operation.leaseExpiresAt == null ||
            !operation.leaseExpiresAt!.isAfter(now)) {
          return false;
        }
        operations.add(operation);
      }
      final renewedUntil = now.add(leaseDuration);
      for (final operation in operations) {
        entries![operation.operationId] = operation.copyWith(
          leaseExpiresAt: renewedUntil,
        );
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
  }) {
    _requirePositiveLimit(limit);
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    return _lock.synchronized(() async {
      _fenceStaleOutboxLocked(scope, now: now);
      final checkpoint = _checkpoint(scope);
      final entries = _outbox[scope.storageKey];
      if (entries == null) return const <CloudOutboxOperation>[];

      final eligible =
          entries.values
              .where(
                (operation) =>
                    operation.checkpointGeneration == checkpoint.generation &&
                    operation.status == CloudOutboxStatus.unknownOutcome &&
                    operation.appleRequestUuid != null &&
                    operation.appleOperationUuid != null &&
                    (operation.leaseExpiresAt == null ||
                        !operation.leaseExpiresAt!.isAfter(now)) &&
                    (operation.nextEligibleAt == null ||
                        !operation.nextEligibleAt!.isAfter(now)),
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
      for (final operation in eligible) {
        if (leased.length == limit) break;
        final updated = operation.copyWith(
          status: CloudOutboxStatus.unknownOutcome,
          leaseId: leaseId,
          leaseExpiresAt: now.add(leaseDuration),
        );
        entries[operation.operationId] = updated;
        leased.add(updated);
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
  }) {
    final ids = submissionIdentity.operationUuids.keys.toList(growable: false);
    if (ids.isEmpty) {
      throw ArgumentError('outbox_submission_operation_ids_empty');
    }
    if (leaseId.isEmpty) throw ArgumentError.value(leaseId, 'leaseId');
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      final entries = _outbox[scope.storageKey];
      final operations = <CloudOutboxOperation>[];
      final seen = <String>{};
      for (final operationId in ids) {
        if (!seen.add(operationId)) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.localStorage,
            safeCode: 'duplicate_outbox_submission_operation',
          );
        }
        final operation = entries?[operationId];
        if (operation == null ||
            operation.checkpointGeneration <= 0 ||
            operation.checkpointGeneration != checkpoint.generation) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.localStorage,
            safeCode: 'stale_outbox_generation',
          );
        }
        if (operation.status != CloudOutboxStatus.leased ||
            operation.leaseId != leaseId ||
            operation.leaseExpiresAt == null ||
            !operation.leaseExpiresAt!.isAfter(now)) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.localStorage,
            safeCode: 'stale_outbox_lease',
          );
        }
        if (operation.appleRequestUuid != null ||
            operation.appleOperationUuid != null) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.localStorage,
            safeCode: 'outbox_submission_identity_already_assigned',
          );
        }
        operations.add(operation);
      }
      final updated = <CloudOutboxOperation>[];
      for (final operation in operations) {
        final submitted = operation.copyWith(
          status: CloudOutboxStatus.unknownOutcome,
          lastFailure: CloudFailureCategory.unknown,
          appleRequestUuid: submissionIdentity.requestUuid,
          appleOperationUuid:
              submissionIdentity.operationUuids[operation.operationId],
        );
        entries![operation.operationId] = submitted;
        updated.add(submitted);
      }
      return updated;
    });
  }

  @override
  Future<void> applyOutboxTransitions(
    CloudSyncScope scope, {
    required String leaseId,
    required Iterable<CloudOutboxTransition> transitions,
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      final transitionList = transitions.toList(growable: false);
      final entries = _outbox[scope.storageKey];
      if (entries == null && transitionList.isNotEmpty) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'outbox_missing',
        );
      }

      final transitionIds = <String>{};
      for (final transition in transitionList) {
        if (!transitionIds.add(transition.operationId)) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.localStorage,
            safeCode: 'duplicate_outbox_transition',
          );
        }
        final operation = entries?[transition.operationId];
        if (operation != null &&
            (operation.checkpointGeneration <= 0 ||
                operation.checkpointGeneration != checkpoint.generation)) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.localStorage,
            safeCode: 'stale_outbox_generation',
          );
        }
        if (operation == null ||
            (operation.status != CloudOutboxStatus.leased &&
                operation.status != CloudOutboxStatus.unknownOutcome) ||
            operation.leaseId != leaseId ||
            operation.leaseExpiresAt == null ||
            !operation.leaseExpiresAt!.isAfter(now)) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.localStorage,
            safeCode: 'stale_outbox_lease',
          );
        }
        if (transition.type == CloudOutboxTransitionType.retryable &&
            (transition.category == null ||
                transition.nextEligibleAt == null)) {
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
        if (transition.type == CloudOutboxTransitionType.unknownOutcome &&
            transition.category != CloudFailureCategory.unknown) {
          throw ArgumentError(
            'Unknown outcome transitions require unknown category',
          );
        }
        if (transition.retainProtectedLeaseReference &&
            transition.type != CloudOutboxTransitionType.confirmed) {
          throw ArgumentError(
            'Only confirmed transitions may retain a protected receipt',
          );
        }
      }

      for (final transition in transitionList) {
        final operation = entries![transition.operationId]!;
        switch (transition.type) {
          case CloudOutboxTransitionType.confirmed:
            entries[operation.operationId] = operation.copyWith(
              status: CloudOutboxStatus.confirmed,
              confirmedAt: now,
              clearLeaseId: true,
              clearLeaseExpiresAt: true,
              clearLastFailure: true,
              clearNextEligibleAt: true,
              clearProtectedLeaseReference:
                  !transition.retainProtectedLeaseReference,
            );
            break;
          case CloudOutboxTransitionType.retryable:
            entries[operation.operationId] = operation.copyWith(
              status: CloudOutboxStatus.pending,
              attemptCount: operation.attemptCount + 1,
              nextEligibleAt: transition.nextEligibleAt,
              lastFailure: transition.category,
              encryptedPayloadReference: transition.encryptedPayloadReference,
              payloadSha256: transition.payloadSha256,
              serverRecordIdHash: transition.serverRecordIdHash,
              clearSubmissionIdentity: transition.clearSubmissionIdentity,
              clearLeaseId: true,
              clearLeaseExpiresAt: true,
            );
            break;
          case CloudOutboxTransitionType.paused:
            entries[operation.operationId] = operation.copyWith(
              status: CloudOutboxStatus.paused,
              attemptCount: operation.attemptCount + 1,
              lastFailure: transition.category,
              nextEligibleAt: transition.nextEligibleAt,
              clearSubmissionIdentity: transition.clearSubmissionIdentity,
              clearLeaseId: true,
              clearLeaseExpiresAt: true,
              clearNextEligibleAt: transition.nextEligibleAt == null,
            );
            break;
          case CloudOutboxTransitionType.quarantined:
            entries[operation.operationId] = operation.copyWith(
              status: CloudOutboxStatus.quarantined,
              attemptCount: operation.attemptCount + 1,
              lastFailure: transition.category ?? CloudFailureCategory.unknown,
              clearLeaseId: true,
              clearLeaseExpiresAt: true,
              clearNextEligibleAt: true,
              clearProtectedLeaseReference: true,
            );
            break;
          case CloudOutboxTransitionType.unknownOutcome:
            entries[operation.operationId] = operation.copyWith(
              status: CloudOutboxStatus.unknownOutcome,
              attemptCount: operation.attemptCount + 1,
              lastFailure: CloudFailureCategory.unknown,
              nextEligibleAt: transition.nextEligibleAt,
              clearLeaseId: true,
              clearLeaseExpiresAt: true,
              clearNextEligibleAt: transition.nextEligibleAt == null,
            );
            break;
        }
      }
    });
  }

  @override
  Future<int> recoverExpiredOutboxLeases(
    CloudSyncScope scope, {
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      _fenceStaleOutboxLocked(scope, now: now);
      return _recoverExpiredOutboxLeasesLocked(scope, now);
    });
  }

  @override
  Future<void> attachOutboxRecordMapping(
    CloudSyncScope scope, {
    required String leaseId,
    required String operationId,
    required String serverRecordIdHash,
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      final operation = _outbox[scope.storageKey]?[operationId];
      if (operation != null &&
          (operation.checkpointGeneration <= 0 ||
              operation.checkpointGeneration != checkpoint.generation)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'stale_outbox_generation',
        );
      }
      if (operation == null ||
          operation.status != CloudOutboxStatus.leased ||
          operation.leaseId != leaseId ||
          operation.leaseExpiresAt == null ||
          !operation.leaseExpiresAt!.isAfter(now)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'stale_outbox_lease',
        );
      }
      if (operation.serverRecordIdHash != null &&
          operation.serverRecordIdHash != serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      _outbox[scope.storageKey]![operationId] = operation.copyWith(
        serverRecordIdHash: serverRecordIdHash,
      );
    });
  }

  @override
  Future<int> resumePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      _fenceStaleOutboxLocked(scope, now: now);
      final entries = _outbox[scope.storageKey];
      if (entries == null) return 0;
      var resumed = 0;
      for (final entry in entries.entries.toList()) {
        final operation = entry.value;
        if (operation.status == CloudOutboxStatus.paused &&
            operation.lastFailure != null &&
            categories.contains(operation.lastFailure) &&
            (operation.nextEligibleAt == null ||
                !operation.nextEligibleAt!.isAfter(now))) {
          entries[entry.key] = operation.copyWith(
            status: CloudOutboxStatus.pending,
            nextEligibleAt: now,
            clearLastFailure: true,
          );
          resumed++;
        }
      }
      return resumed;
    });
  }

  @override
  Future<Set<CloudFailureCategory>> readPausedOutboxFailureCategories(
    CloudSyncScope scope, {
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      final generation = _checkpoint(scope).generation;
      final entries = _outbox[scope.storageKey];
      if (entries == null) return <CloudFailureCategory>{};
      return entries.values
          .where(
            (operation) =>
                operation.checkpointGeneration == generation &&
                operation.status == CloudOutboxStatus.paused &&
                (operation.nextEligibleAt == null ||
                    !operation.nextEligibleAt!.isAfter(now)),
          )
          .map((operation) => operation.lastFailure)
          .whereType<CloudFailureCategory>()
          .toSet();
    });
  }

  @override
  Future<int> postponeEligiblePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
    required DateTime nextEligibleAt,
  }) {
    return _lock.synchronized(() async {
      _fenceStaleOutboxLocked(scope, now: now);
      final entries = _outbox[scope.storageKey];
      if (entries == null) return 0;
      var postponed = 0;
      for (final entry in entries.entries.toList()) {
        final operation = entry.value;
        if (operation.status != CloudOutboxStatus.paused ||
            operation.lastFailure == null ||
            !categories.contains(operation.lastFailure) ||
            (operation.nextEligibleAt != null &&
                operation.nextEligibleAt!.isAfter(now))) {
          continue;
        }
        entries[entry.key] = operation.copyWith(nextEligibleAt: nextEligibleAt);
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
  }) {
    return _lock.synchronized(() async {
      final existing = _coordinatorLeases[scope.storageKey];
      if (existing != null && existing.expiresAt.isAfter(now)) {
        return null;
      }
      final generation = (existing?.generation ?? 0) + 1;
      _coordinatorLeases[scope.storageKey] = _CoordinatorLease(
        ownerId,
        generation,
        now.add(leaseDuration),
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
  }) {
    return _lock.synchronized(() async {
      final existing = _coordinatorLeases[scope.storageKey];
      if (existing == null || !existing.expiresAt.isAfter(now)) return null;
      return existing.expiresAt.toUtc();
    });
  }

  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) {
    return _lock.synchronized(() async {
      final existing = _coordinatorLeases[scope.storageKey];
      if (existing == null ||
          existing.ownerId != leaseFence.ownerId ||
          existing.generation != leaseFence.generation ||
          !existing.expiresAt.isAfter(now)) {
        return false;
      }
      _coordinatorLeases[scope.storageKey] = _CoordinatorLease(
        leaseFence.ownerId,
        existing.generation,
        now.add(leaseDuration),
      );
      return true;
    });
  }

  @override
  Future<void> releaseCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) {
    return _lock.synchronized(() async {
      final existing = _coordinatorLeases[scope.storageKey];
      if (existing?.ownerId == leaseFence.ownerId &&
          existing?.generation == leaseFence.generation) {
        _coordinatorLeases[scope.storageKey] = _CoordinatorLease(
          existing!.ownerId,
          existing.generation,
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        );
      }
    });
  }

  @override
  Future<CloudRecordMapEntry?> readRecordMap(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
    required int generation,
  }) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      if (generation <= 0 || generation != checkpoint.generation) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'record_map_generation_mismatch',
        );
      }
      final entry = _recordMaps[_recordMapKey(scope, logicalEntityKeyHash)];
      if (entry == null || entry.generation != generation) return null;
      return entry.value;
    });
  }

  @override
  Future<void> upsertRecordMap(
    CloudRecordMapEntry entry, {
    required int generation,
  }) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(entry.scope);
      if (generation <= 0 || generation != checkpoint.generation) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'record_map_generation_mismatch',
        );
      }
      final key = _recordMapKey(entry.scope, entry.logicalEntityKeyHash);
      final existing = _recordMaps[key];
      if (existing != null &&
          existing.generation == generation &&
          existing.value.serverRecordIdHash != entry.serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      _recordMaps[key] = _GenerationBoundRecordMap(generation, entry);
    });
  }

  @override
  Future<void> recordRun(CloudSyncRunRecord run) {
    return _lock.synchronized(() async {
      if (_runs.length == 256) _runs.removeAt(0);
      _runs.add(run);
    });
  }

  int _journalFetchedBatchLocked(
    CloudFetchBatch batch, {
    required DateTime now,
    bool deferTokenUntilTerminal = true,
  }) {
    final scope = batch.scope;
    var checkpoint = _checkpoint(scope);
    _requireGeneration(batch, checkpoint);
    if (deferTokenUntilTerminal &&
        (checkpoint.pendingBatchId != null ||
            _hasUnmarkedPendingInbox(scope, checkpoint))) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'checkpoint_pending_page_unresolved',
      );
    }
    final entries = _inbox.putIfAbsent(
      scope.storageKey,
      SplayTreeMap<int, CloudInboxEntry>.new,
    );
    final seen = _seenChangeIds.putIfAbsent(scope.storageKey, () => <String>{});
    var inserted = 0;
    var nextSequence = checkpoint.fetchedSequence + 1;
    for (final change in batch.changes) {
      if (!seen.add(change.changeId)) continue;
      entries[nextSequence] = CloudInboxEntry(
        scope: scope,
        sequence: nextSequence,
        change: change,
        status: CloudInboxStatus.pending,
        attemptCount: 0,
        createdAt: now,
        batchId: batch.batchId,
        generation: batch.generation,
        lastFailure: change.preflightFailure,
      );
      nextSequence++;
      inserted++;
    }
    checkpoint = checkpoint.copyWith(
      generation: batch.generation,
      lastBatchId: batch.batchId,
      fetchedSequence: nextSequence - 1,
    );
    if (!deferTokenUntilTerminal || inserted == 0) {
      checkpoint = checkpoint.copyWith(
        fetchedToken: batch.nextToken,
        clearFetchedToken: batch.nextToken == null,
        clearPendingBatchId: true,
      );
      _pendingFetchedTokens.remove(scope.storageKey);
    } else {
      checkpoint = checkpoint.copyWith(pendingBatchId: batch.batchId);
      _pendingFetchedTokens[scope.storageKey] = batch.nextToken;
    }
    _checkpoints[scope.storageKey] = checkpoint;
    return inserted;
  }

  CloudSyncCheckpoint _requireCommitFenceLocked(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
    required DateTime now,
  }) {
    final checkpoint = _checkpoint(scope);
    _requireActiveCoordinatorLeaseLocked(scope, leaseFence, now);
    if (checkpoint.generation != expectedGeneration ||
        checkpoint.fetchedToken != expectedFetchedToken) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'checkpoint_compare_and_swap_failed',
      );
    }
    return checkpoint;
  }

  void _requireActiveCoordinatorLeaseLocked(
    CloudSyncScope scope,
    CloudCoordinatorLeaseFence leaseFence,
    DateTime now,
  ) {
    final lease = _coordinatorLeases[scope.storageKey];
    if (lease == null ||
        lease.ownerId != leaseFence.ownerId ||
        lease.generation != leaseFence.generation ||
        !lease.expiresAt.isAfter(now)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'coordinator_lease_fence_lost',
      );
    }
  }

  CloudShadowJournalUsage _shadowJournalUsageLocked(
    CloudSyncScope scope,
    CloudShadowJournalBudget budget,
  ) {
    var usage = CloudShadowJournalUsage.empty;
    final entries =
        _inbox[scope.storageKey]?.values ?? const <CloudInboxEntry>[];
    for (final entry in entries) {
      if (entry.status != CloudInboxStatus.pending) continue;
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
  }

  void _requireGeneration(
    CloudFetchBatch batch,
    CloudSyncCheckpoint checkpoint,
  ) {
    if (batch.generation != checkpoint.generation) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'generation_mismatch',
      );
    }
  }

  CloudSyncCheckpoint _checkpoint(CloudSyncScope scope) {
    return _checkpoints.putIfAbsent(
      scope.storageKey,
      () => CloudSyncCheckpoint(scope: scope),
    );
  }

  bool _hasUnmarkedPendingInbox(
    CloudSyncScope scope,
    CloudSyncCheckpoint checkpoint,
  ) {
    if (checkpoint.pendingBatchId != null) return false;
    // fetchedSequence may legitimately exceed the exact-applied floor when a
    // protected row is retained for later projection repair. Only an
    // incomplete, missing, or nonterminal journal is unsafe without a pending
    // batch marker.
    return !_isCompleteTerminalInboxJournal(scope, checkpoint);
  }

  CloudInboxEntry? _findFirstNonterminalInbox(
    CloudSyncScope scope,
    CloudSyncCheckpoint checkpoint,
  ) {
    final entries = _inbox[scope.storageKey];
    final candidates =
        entries?.values
            .where(
              (entry) =>
                  entry.generation == checkpoint.generation &&
                  !_isTerminalInboxStatus(entry.status),
            )
            .toList()
          ?..sort((left, right) => left.sequence.compareTo(right.sequence));
    if (candidates == null || candidates.isEmpty) return null;
    final entry = candidates.first;
    if (entry.sequence <= 0 || entry.sequence > checkpoint.fetchedSequence) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'inbox_nonterminal_sequence_invalid',
      );
    }
    final predecessorCount = entries!.values
        .where(
          (candidate) =>
              candidate.generation == checkpoint.generation &&
              candidate.sequence < entry.sequence,
        )
        .length;
    if (predecessorCount != entry.sequence - 1) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'inbox_journal_sequence_gap',
      );
    }
    return entry;
  }

  CloudInboxEntry _requireInboxEntry(CloudSyncScope scope, int sequence) {
    final entry = _inbox[scope.storageKey]?[sequence];
    if (entry == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'inbox_entry_missing',
      );
    }
    return entry;
  }

  void _advanceContiguousAppliedPosition(CloudSyncScope scope) {
    var checkpoint = _checkpoint(scope);
    final entries = _inbox[scope.storageKey];
    var next = checkpoint.lastAppliedSequence + 1;
    while (_isExactlyAppliedInboxStatus(entries?[next]?.status)) {
      next++;
    }
    final appliedThrough = next - 1;
    if (appliedThrough != checkpoint.lastAppliedSequence) {
      checkpoint = checkpoint.copyWith(lastAppliedSequence: appliedThrough);
      _checkpoints[scope.storageKey] = checkpoint;
    }
    _promotePendingFetchedTokenIfTerminal(scope, checkpoint);
  }

  int _recomputeContiguousAppliedPosition(CloudSyncScope scope) {
    var checkpoint = _checkpoint(scope);
    final entries = _inbox[scope.storageKey];
    var next = 1;
    while (_isExactlyAppliedInboxStatus(entries?[next]?.status)) {
      next++;
    }
    final appliedThrough = next - 1;
    if (appliedThrough != checkpoint.lastAppliedSequence) {
      checkpoint = checkpoint.copyWith(lastAppliedSequence: appliedThrough);
      _checkpoints[scope.storageKey] = checkpoint;
    }
    _promotePendingFetchedTokenIfTerminal(scope, checkpoint);
    return appliedThrough;
  }

  void _promotePendingFetchedTokenIfTerminal(
    CloudSyncScope scope,
    CloudSyncCheckpoint checkpoint,
  ) {
    final entries = _inbox[scope.storageKey];
    final pendingBatchId = checkpoint.pendingBatchId;
    if (pendingBatchId == null) return;
    if (!_isCompleteTerminalInboxJournal(scope, checkpoint)) return;
    final pendingEntries = entries?.values.where(
      (entry) =>
          entry.generation == checkpoint.generation &&
          entry.batchId == pendingBatchId,
    );
    if (pendingEntries == null ||
        pendingEntries.isEmpty ||
        pendingEntries.any((entry) => !_isTerminalInboxStatus(entry.status))) {
      return;
    }
    _checkpoints[scope.storageKey] = checkpoint.copyWith(
      fetchedToken: _pendingFetchedTokens[scope.storageKey],
      clearFetchedToken: _pendingFetchedTokens[scope.storageKey] == null,
      clearPendingBatchId: true,
    );
    _pendingFetchedTokens.remove(scope.storageKey);
  }

  bool _isCompleteTerminalInboxJournal(
    CloudSyncScope scope,
    CloudSyncCheckpoint checkpoint,
  ) {
    final entries =
        _inbox[scope.storageKey]?.values
            .where((entry) => entry.generation == checkpoint.generation)
            .toList()
          ?..sort((left, right) => left.sequence.compareTo(right.sequence));
    if (entries == null || entries.length != checkpoint.fetchedSequence) {
      return checkpoint.fetchedSequence == 0 && entries == null;
    }
    return !entries.indexed.any(
      (item) =>
          item.$2.sequence != item.$1 + 1 ||
          !_isTerminalInboxStatus(item.$2.status),
    );
  }

  bool _isExactlyAppliedInboxStatus(CloudInboxStatus? status) =>
      status == CloudInboxStatus.applied;

  bool _isTerminalInboxStatus(CloudInboxStatus? status) =>
      status == CloudInboxStatus.applied ||
      status == CloudInboxStatus.retainedUnprojected;

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
      return entry.scope.container == 'com.apple.messages.cloud' &&
          entry.scope.database == 'private' &&
          entry.scope.zone == 'attachmentManateeZone' &&
          entry.scope.streamKind == CloudSyncStreamKind.messages &&
          entry.scope.schemaVersion == 2 &&
          entry.scope.persistenceLane == CloudSyncPersistenceLane.semanticV2 &&
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

  int _recoverExpiredOutboxLeasesLocked(CloudSyncScope scope, DateTime now) {
    final entries = _outbox[scope.storageKey];
    if (entries == null) return 0;
    var recovered = 0;
    for (final entry in entries.entries.toList()) {
      final operation = entry.value;
      if (operation.status == CloudOutboxStatus.leased &&
          operation.leaseExpiresAt != null &&
          !operation.leaseExpiresAt!.isAfter(now)) {
        entries[entry.key] = operation.copyWith(
          status: CloudOutboxStatus.pending,
          clearLeaseId: true,
          clearLeaseExpiresAt: true,
        );
        recovered++;
      }
    }
    return recovered;
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
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'confirmed_outbound_receipt_release_invalid',
      );
    }
  }

  String _recordMapKey(CloudSyncScope scope, String logicalKeyHash) =>
      '${scope.storageKey}\u001f$logicalKeyHash';

  void _enqueueOutboxLocked(CloudOutboxOperation operation) {
    for (final scopedEntry in _outbox.entries) {
      if (scopedEntry.key != operation.scope.storageKey &&
          scopedEntry.value.containsKey(operation.operationId)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'outbox_operation_scope_collision',
        );
      }
    }
    final checkpoint = _checkpoint(operation.scope);
    if (operation.checkpointGeneration != checkpoint.generation) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'outbox_generation_mismatch',
      );
    }
    if (operation.mutationRevision > checkpoint.mutationRevisionCounter) {
      _checkpoints[operation.scope.storageKey] = checkpoint.copyWith(
        mutationRevisionCounter: operation.mutationRevision,
      );
    }

    final entries = _outbox.putIfAbsent(
      operation.scope.storageKey,
      () => <String, CloudOutboxOperation>{},
    );
    if (entries.containsKey(operation.operationId)) return;

    if (operation.action == CloudOutboxAction.save) {
      final newerOrEqualExists = entries.values.any(
        (candidate) =>
            candidate.status != CloudOutboxStatus.quarantined &&
            candidate.action == CloudOutboxAction.save &&
            candidate.logicalEntityKeyHash == operation.logicalEntityKeyHash &&
            _compareMutationOrder(candidate, operation) >= 0,
      );
      if (newerOrEqualExists) return;

      final superseded = entries.values
          .where(
            (candidate) =>
                candidate.status == CloudOutboxStatus.pending &&
                candidate.action == CloudOutboxAction.save &&
                candidate.logicalEntityKeyHash ==
                    operation.logicalEntityKeyHash &&
                _compareMutationOrder(candidate, operation) < 0,
          )
          .map((candidate) => candidate.operationId)
          .toList();
      if (superseded.isNotEmpty) {
        for (final entry in entries.entries.toList()) {
          final candidate = entry.value;
          if (candidate.status != CloudOutboxStatus.pending ||
              !candidate.dependencyOperationIds.any(superseded.contains)) {
            continue;
          }
          entries[entry.key] = candidate.copyWith(
            dependencyOperationIds: {
              ...candidate.dependencyOperationIds.where(
                (dependency) => !superseded.contains(dependency),
              ),
              operation.operationId,
            },
          );
        }
      }
      for (final operationId in superseded) {
        entries.remove(operationId);
      }
    }
    entries[operation.operationId] = operation;
  }

  void _fenceStaleOutboxLocked(
    CloudSyncScope scope, {
    required DateTime now,
    CloudSyncCheckpoint? checkpoint,
  }) {
    final activeCheckpoint = checkpoint ?? _checkpoint(scope);
    final entries = _outbox[scope.storageKey];
    if (entries == null) return;
    for (final entry in entries.entries.toList()) {
      final operation = entry.value;
      if (!_isBlockingOutboxStatus(operation.status) ||
          operation.checkpointGeneration == activeCheckpoint.generation) {
        continue;
      }
      entries[entry.key] = operation.copyWith(
        status: CloudOutboxStatus.quarantined,
        attemptCount: operation.attemptCount + 1,
        lastFailure: CloudFailureCategory.localStorage,
        clearLeaseId: true,
        clearLeaseExpiresAt: true,
        clearNextEligibleAt: true,
      );
    }
  }

  int _compareMutationOrder(
    CloudOutboxOperation first,
    CloudOutboxOperation second,
  ) {
    return first.mutationRevision.compareTo(second.mutationRevision);
  }

  void _requirePositiveLimit(int limit) {
    if (limit <= 0 || limit > 256 * 8) {
      throw ArgumentError.value(limit, 'limit');
    }
  }
}

class _CoordinatorLease {
  const _CoordinatorLease(this.ownerId, this.generation, this.expiresAt);

  final String ownerId;
  final int generation;
  final DateTime expiresAt;
}

class _GenerationBoundRecordMap {
  const _GenerationBoundRecordMap(this.generation, this.value);

  final int generation;
  final CloudRecordMapEntry value;
}
