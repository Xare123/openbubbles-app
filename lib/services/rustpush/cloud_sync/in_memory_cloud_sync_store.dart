import 'dart:collection';

import 'package:synchronized/synchronized.dart';

import 'cloud_operation_identity.dart';
import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';

/// Transactional reference implementation used by unit tests and adapter
/// development. It is not durable across process restarts.
class InMemoryCloudSyncStore
    implements CloudSyncStore, CloudSyncInboxFloorReader {
  final Lock _lock = Lock();
  final Map<String, CloudSyncCheckpoint> _checkpoints = {};
  final Map<String, SplayTreeMap<int, CloudInboxEntry>> _inbox = {};
  final Map<String, Set<String>> _seenChangeIds = {};
  final Map<String, Map<String, CloudOutboxOperation>> _outbox = {};
  final Map<String, _CoordinatorLease> _coordinatorLeases = {};
  final Map<String, CloudRecordMapEntry> _recordMaps = {};
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
  Future<CloudSyncCheckpoint> readCheckpoint(CloudSyncScope scope) {
    return _lock.synchronized(() async => _checkpoint(scope));
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

      final inserted = _journalFetchedBatchLocked(batch, now: now);
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
      final entries =
          _inbox[scope.storageKey]?.values ?? const <CloudInboxEntry>[];
      return entries
          .where(
            (entry) =>
                entry.status == CloudInboxStatus.pending &&
                (entry.nextEligibleAt == null ||
                    !entry.nextEligibleAt!.isAfter(now)),
          )
          .take(limit)
          .toList(growable: false);
    });
  }

  @override
  Future<CloudInboxAppliedFloorState> readInboxAppliedFloorState(
    CloudSyncScope scope,
  ) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(scope);
      final entries = _inbox[scope.storageKey];
      CloudInboxEntry? blockingEntry;
      if (checkpoint.lastAppliedSequence < checkpoint.fetchedSequence) {
        for (final entry in entries?.values ?? const <CloudInboxEntry>[]) {
          if (entry.sequence <= checkpoint.lastAppliedSequence) continue;
          if (entry.sequence > checkpoint.fetchedSequence) break;
          if (entry.status != CloudInboxStatus.applied) {
            blockingEntry = entry;
            break;
          }
        }
      }
      return CloudInboxAppliedFloorState(
        fetchedSequence: checkpoint.fetchedSequence,
        lastAppliedSequence: checkpoint.lastAppliedSequence,
        blockingStatus: blockingEntry?.status,
        blockingAttemptCount: blockingEntry?.attemptCount ?? 0,
        blockingFailureCategory: blockingEntry?.lastFailure,
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
      if (entry.status == CloudInboxStatus.applied) return;
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
      _enqueueOutboxLocked(operation);
    });
  }

  @override
  Future<CloudOutboxOperation> enqueueOutboxMutation(CloudOutboxDraft draft) {
    return _lock.synchronized(() async {
      final checkpoint = _checkpoint(draft.scope);
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
      _recoverExpiredOutboxLeasesLocked(scope, now);
      final entries = _outbox[scope.storageKey];
      if (entries == null) return const <CloudOutboxOperation>[];

      final eligible =
          entries.values
              .where(
                (operation) =>
                    operation.status == CloudOutboxStatus.pending &&
                    allowedActions.contains(operation.action) &&
                    (operation.nextEligibleAt == null ||
                        !operation.nextEligibleAt!.isAfter(now)) &&
                    operation.dependencyOperationIds.every(
                      (dependencyId) =>
                          entries[dependencyId]?.status ==
                          CloudOutboxStatus.confirmed,
                    ),
              )
              .toList()
            ..sort((first, second) {
              final created = first.createdAt.compareTo(second.createdAt);
              if (created != 0) return created;
              return first.operationId.compareTo(second.operationId);
            });

      final leased = <CloudOutboxOperation>[];
      for (final operation in eligible.take(limit)) {
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
  Future<void> applyOutboxTransitions(
    CloudSyncScope scope, {
    required String leaseId,
    required Iterable<CloudOutboxTransition> transitions,
    required DateTime now,
  }) {
    return _lock.synchronized(() async {
      final transitionList = transitions.toList(growable: false);
      final entries = _outbox[scope.storageKey];
      if (entries == null && transitionList.isNotEmpty) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'outbox_missing',
        );
      }

      for (final transition in transitionList) {
        final operation = entries?[transition.operationId];
        if (operation == null ||
            operation.status != CloudOutboxStatus.leased ||
            operation.leaseId != leaseId) {
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
              clearLeaseId: true,
              clearLeaseExpiresAt: true,
            );
            break;
          case CloudOutboxTransitionType.paused:
            entries[operation.operationId] = operation.copyWith(
              status: CloudOutboxStatus.paused,
              attemptCount: operation.attemptCount + 1,
              lastFailure: transition.category,
              clearLeaseId: true,
              clearLeaseExpiresAt: true,
              clearNextEligibleAt: true,
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
    return _lock.synchronized(
      () async => _recoverExpiredOutboxLeasesLocked(scope, now),
    );
  }

  @override
  Future<void> attachOutboxRecordMapping(
    CloudSyncScope scope, {
    required String leaseId,
    required String operationId,
    required String serverRecordIdHash,
  }) {
    return _lock.synchronized(() async {
      final operation = _outbox[scope.storageKey]?[operationId];
      if (operation == null ||
          operation.status != CloudOutboxStatus.leased ||
          operation.leaseId != leaseId) {
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
      final entries = _outbox[scope.storageKey];
      if (entries == null) return 0;
      var resumed = 0;
      for (final entry in entries.entries.toList()) {
        final operation = entry.value;
        if (operation.status == CloudOutboxStatus.paused &&
            operation.lastFailure != null &&
            categories.contains(operation.lastFailure)) {
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
  }) {
    return _lock.synchronized(() async {
      return _recordMaps[_recordMapKey(scope, logicalEntityKeyHash)];
    });
  }

  @override
  Future<void> upsertRecordMap(CloudRecordMapEntry entry) {
    return _lock.synchronized(() async {
      final key = _recordMapKey(entry.scope, entry.logicalEntityKeyHash);
      final existing = _recordMaps[key];
      if (existing != null &&
          existing.serverRecordIdHash != entry.serverRecordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'server_mapping_changed',
        );
      }
      _recordMaps[key] = entry;
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
  }) {
    final scope = batch.scope;
    var checkpoint = _checkpoint(scope);
    _requireGeneration(batch, checkpoint);
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
      fetchedToken: batch.nextToken,
      clearFetchedToken: batch.nextToken == null,
      generation: batch.generation,
      lastBatchId: batch.batchId,
      fetchedSequence: nextSequence - 1,
    );
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
    while (entries?[next]?.status == CloudInboxStatus.applied) {
      next++;
    }
    final appliedThrough = next - 1;
    if (appliedThrough != checkpoint.lastAppliedSequence) {
      checkpoint = checkpoint.copyWith(lastAppliedSequence: appliedThrough);
      _checkpoints[scope.storageKey] = checkpoint;
    }
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

  String _recordMapKey(CloudSyncScope scope, String logicalKeyHash) =>
      '${scope.storageKey}\u001f$logicalKeyHash';

  void _enqueueOutboxLocked(CloudOutboxOperation operation) {
    final checkpoint = _checkpoint(operation.scope);
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
