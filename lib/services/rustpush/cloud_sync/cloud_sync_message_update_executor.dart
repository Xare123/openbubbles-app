import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:uuid/uuid.dart';

import 'cloud_sync_local_mutation_journal.dart';
import 'cloud_sync_local_send_journal.dart'
    show CloudSyncNativeReceiptReplayBinding;
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_message_update_transport.dart';
import 'cloud_sync_received_message_update_transport.dart';
import 'cloud_sync_received_mutation_journal.dart';
import 'cloud_sync_historical_parent_binding.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_message_dependency.dart';
import 'cloud_sync_record_maps.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_write_transport.dart';
import 'objectbox_cloud_sync_store.dart';

final class CloudSyncMessageUpdateRunResult {
  const CloudSyncMessageUpdateRunResult({
    required this.recoveredReadbacks,
    required this.reconciledUnknown,
    required this.submitted,
    required this.confirmed,
    required this.notApplied,
    required this.diverged,
    required this.unresolved,
  });

  final int recoveredReadbacks;
  final int reconciledUnknown;
  final int submitted;
  final int confirmed;
  final int notApplied;
  final int diverged;
  final int unresolved;

  @override
  String toString() =>
      'CloudSyncMessageUpdateRunResult('
      'recoveredReadbacks=$recoveredReadbacks, '
      'reconciledUnknown=$reconciledUnknown, submitted=$submitted, '
      'confirmed=$confirmed, notApplied=$notApplied, diverged=$diverged, '
      'unresolved=$unresolved)';
}

/// Dedicated conditional-update worker for locally reflected edits/unsends.
///
/// The generic create engine intentionally cannot lease payload version 3.
/// This worker processes one update at a time so every Apple operation UUID,
/// predecessor ETag, native handle, outbox lease, and readback lease remains an
/// exact one-to-one relationship.
final class CloudSyncMessageUpdateExecutor {
  CloudSyncMessageUpdateExecutor({
    required Store objectBoxStore,
    required ObjectBoxCloudSyncStore cloudStore,
    required CloudSyncLocalMutationJournal journal,
    required CloudSyncMessageUpdateTransport transport,
    required CloudSyncPreparedSubmissionReleaser preparedSubmissionReleaser,
    required CloudProtectedPageLeaseTransport leaseTransport,
    CloudSyncReceivedMutationJournal? receivedJournal,
    CloudSyncReceivedMessageUpdateTransport? receivedTransport,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
    CloudSyncConfirmedLocalParentReader? readConfirmedLocalParent,
    DateTime Function()? clock,
    String Function()? uuidFactory,
  }) : _objectBoxStore = objectBoxStore,
       // Public named parameters stay readable at the composition boundary.
       // ignore: prefer_initializing_formals
       _cloudStore = cloudStore,
       _journal = journal,
       // Keep public composition names separate from private fields.
       // ignore: prefer_initializing_formals
       _receivedJournal = receivedJournal,
       // ignore: prefer_initializing_formals
       _receivedTransport = receivedTransport,
       // ignore: prefer_initializing_formals
       _transport = transport,
       // ignore: prefer_initializing_formals
       _preparedSubmissionReleaser = preparedSubmissionReleaser,
       // ignore: prefer_initializing_formals
       _leaseTransport = leaseTransport,
       // ignore: prefer_initializing_formals
       _replayBinding = replayBinding,
       // ignore: prefer_initializing_formals
       _readConfirmedLocalParent = readConfirmedLocalParent,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _uuidFactory = uuidFactory ?? (() => const Uuid().v4().toUpperCase()) {
    if (!journal.isBoundToStore(objectBoxStore)) {
      throw ArgumentError('cloud_sync_message_update_store_mismatch');
    }
    if (receivedJournal != null &&
        !receivedJournal.isBoundToStore(objectBoxStore)) {
      throw ArgumentError('cloud_sync_message_update_store_mismatch');
    }
  }

  final Store _objectBoxStore;
  final ObjectBoxCloudSyncStore _cloudStore;
  final CloudSyncLocalMutationJournal _journal;
  final CloudSyncReceivedMutationJournal? _receivedJournal;
  final CloudSyncReceivedMessageUpdateTransport? _receivedTransport;
  final CloudSyncMessageUpdateTransport _transport;
  final CloudSyncPreparedSubmissionReleaser _preparedSubmissionReleaser;
  final CloudProtectedPageLeaseTransport _leaseTransport;
  final CloudSyncNativeReceiptReplayBinding? _replayBinding;
  final CloudSyncConfirmedLocalParentReader? _readConfirmedLocalParent;
  final DateTime Function() _clock;
  final String Function() _uuidFactory;

  /// Stages and atomically adopts one exact reflected local mutation.
  ///
  /// Repeated delivery after adoption returns the existing outbox operation and
  /// never stages a second native update envelope.
  Future<CloudOutboxOperation> admitReflectedUpdate(
    CloudSyncScope scope, {
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required frb_api.CloudSyncNativeSendReceipt receipt,
  }) async {
    final refreshedSource = _journal.readReflectedForUpdate(
      intentId: source.intentId,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
      replayBinding: _replayBinding,
    );
    if (!source.sameReflectedMutationAs(refreshedSource)) {
      throw StateError('cloud_sync_message_update_source_changed');
    }
    return _admitReflectedStage(
      scope,
      predecessor: predecessor,
      adoptedOperationId: refreshedSource.adoptedOperationId,
      stageUpdate: () => _transport.stageMessageUpdate(
        scope,
        source: refreshedSource,
        predecessor: predecessor,
        currentAuth: currentAuth,
        receipt: receipt,
      ),
      adopt: (draft) => _cloudStore.admitProtectedLocalMutationUpdate(
        draft: draft,
        expectedPredecessor: predecessor.recordMapping,
        journal: _journal,
        source: refreshedSource,
        currentAuth: currentAuth,
        stillCurrent: stillCurrent,
        replayBinding: _replayBinding,
      ),
    );
  }

  /// Received source joins this same executor and lease handoff. Its separate
  /// journal/native transport has no outgoing IDS receipt field or send path.
  Future<CloudOutboxOperation> admitReflectedReceivedUpdate(
    CloudSyncScope scope, {
    required CloudSyncReceivedMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
    required CloudSyncHistoricalParentProof parent,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) async {
    final journal = _receivedJournal;
    final transport = _receivedTransport;
    if (journal == null || transport == null) {
      throw StateError('cloud_sync_received_mutation_transport_unavailable');
    }
    final refreshed = journal.readReflectedForUpdate(
      intentId: source.intentId,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    if (!source.sameReflectedMutationAs(refreshed)) {
      throw StateError('cloud_sync_message_update_source_changed');
    }
    return _admitReflectedStage(
      scope,
      predecessor: predecessor,
      adoptedOperationId: refreshed.adoptedOperationId,
      stageUpdate: () => transport.stageReceivedMessageUpdate(
        scope,
        source: refreshed,
        predecessor: predecessor,
        parent: parent,
        currentAuth: currentAuth,
      ),
      adopt: (draft) => _cloudStore.admitProtectedReceivedMutationUpdate(
        draft: draft,
        expectedPredecessor: predecessor.recordMapping,
        journal: journal,
        source: refreshed,
        currentAuth: currentAuth,
        stillCurrent: stillCurrent,
      ),
    );
  }

  Future<CloudOutboxOperation> _admitReflectedStage(
    CloudSyncScope scope, {
    required CloudSyncMessageMutationPredecessor predecessor,
    required String? adoptedOperationId,
    required Future<CloudSyncProtectedMessageUpdateStage> Function()
    stageUpdate,
    required CloudOutboxOperation Function(CloudOutboxDraft) adopt,
  }) async {
    if (adoptedOperationId != null) {
      final existing = await _readExactOperation(scope, adoptedOperationId);
      _validateAdoptedOperation(existing, predecessor);
      return existing;
    }

    return _leaseTransport.runProtectedStoreExclusive(() async {
      final stage = await stageUpdate();
      var retainedStage = false;
      try {
        final now = _utcNow();
        final operation = adopt(
          CloudOutboxDraft(
            scope: scope,
            logicalEntityKeyHash: stage.logicalEntityKeyHash,
            action: CloudOutboxAction.save,
            payloadVersion: cloudSyncMessageUpdatePayloadVersion,
            dependencyOperationIds: const <String>{},
            createdAt: now,
            encryptedPayloadReference: stage.protectedReference,
            payloadSha256: stage.payloadSha256,
            serverRecordIdHash: stage.serverRecordIdHash,
            protectedLeaseReference: stage.leaseReference,
          ),
        );
        retainedStage =
            operation.encryptedPayloadReference == stage.protectedReference &&
            operation.protectedLeaseReference == stage.leaseReference &&
            operation.payloadSha256 == stage.payloadSha256 &&
            operation.logicalEntityKeyHash == stage.logicalEntityKeyHash &&
            operation.serverRecordIdHash == stage.serverRecordIdHash;
        if (!retainedStage) {
          await _leaseTransport.rollbackProtectedPageLease(
            stage.leaseReference,
          );
          return operation;
        }
        await _leaseTransport.commitProtectedPageLease(
          stage.leaseReference,
          <String>{stage.protectedReference},
        );
        return operation;
      } catch (_) {
        if (!retainedStage) {
          try {
            await _leaseTransport.rollbackProtectedPageLease(
              stage.leaseReference,
            );
          } catch (_) {
            // Preserve the original failure. Startup lease recovery owns any
            // unadopted protected stage that could not be rolled back now.
          }
        }
        rethrow;
      }
    });
  }

  /// Runs one bounded production pass: finish committed lease handoffs,
  /// reconcile one prior unknown outcome, then submit at most one pending
  /// update. Unknown outcomes always win so a second write cannot cross an
  /// unresolved mutation fence.
  Future<CloudSyncMessageUpdateRunResult> runOnce(
    CloudSyncScope scope, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) async {
    final recovered = await _recoverCommittedReadbacks(scope);
    await _retireReceivedReadbacks(scope, currentAuth, stillCurrent);
    final unknownLeaseId = _leaseId('update-reconcile');
    final unknown = await _cloudStore.leaseUnknownOutcomes(
      scope,
      now: _utcNow(),
      limit: 1,
      leaseId: unknownLeaseId,
      leaseDuration: const Duration(minutes: 2),
      allowedPayloadVersions: const <int>{cloudSyncMessageUpdatePayloadVersion},
    );
    if (unknown.isNotEmpty) {
      final resolution = await _reconcileLeasedUnknown(
        scope,
        operation: unknown.single,
        leaseId: unknownLeaseId,
        currentAuth: currentAuth,
        stillCurrent: stillCurrent,
      );
      return _result(
        recovered: recovered,
        reconciledUnknown: 1,
        resolution: resolution,
      );
    }

    final leaseId = _leaseId('update-submit');
    final leased = await _cloudStore.leaseEligibleOutbox(
      scope,
      now: _utcNow(),
      limit: 1,
      leaseId: leaseId,
      leaseDuration: const Duration(minutes: 2),
      allowedActions: const <CloudOutboxAction>{CloudOutboxAction.save},
      allowedPayloadVersions: const <int>{cloudSyncMessageUpdatePayloadVersion},
    );
    if (leased.isEmpty) {
      return CloudSyncMessageUpdateRunResult(
        recoveredReadbacks: recovered,
        reconciledUnknown: 0,
        submitted: 0,
        confirmed: 0,
        notApplied: 0,
        diverged: 0,
        unresolved: 0,
      );
    }

    final operation = leased.single;
    final context = _readAdoptedContext(
      scope,
      operation,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    final protectedOperation = CloudSyncProtectedWriteOperation.fromOutbox(
      operation,
      recordMapping: context.predecessor.recordMapping,
    );
    final submissionIdentity = CloudOutboxSubmissionIdentity(
      requestUuid: _uuidFactory(),
      operationUuids: <String, String>{operation.operationId: _uuidFactory()},
    );
    CloudSyncPreparedSubmission? prepared;
    CloudOutboxOperation? submitted;
    try {
      prepared = await _prepareTypedSubmission(
        scope,
        submissionIdentity: submissionIdentity,
        operation: operation,
        protectedOperation: protectedOperation,
        context: context,
      );
      final started = await _cloudStore.markOutboxSubmissionStarted(
        scope,
        leaseId: leaseId,
        submissionIdentity: submissionIdentity,
        now: _utcNow(),
      );
      if (started.length != 1 ||
          started.single.operationId != operation.operationId) {
        throw StateError('cloud_sync_message_update_submission_mismatch');
      }
      submitted = started.single;
      await _transport.consumePreparedMessageUpdate(
        scope,
        preparedSubmission: prepared,
        persistedIdentity: submissionIdentity,
        operation: submitted,
        protectedOperation: protectedOperation,
      );
    } finally {
      if (prepared != null) {
        await _preparedSubmissionReleaser.releasePreparedSubmission(prepared);
      }
    }
    final resolution = await _reconcileLeasedUnknown(
      scope,
      operation: submitted,
      leaseId: leaseId,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    return _result(recovered: recovered, submitted: 1, resolution: resolution);
  }

  Future<int> _recoverCommittedReadbacks(CloudSyncScope scope) async {
    final pending = await _cloudStore.readPendingMessageUpdateReadbacks(
      scope,
      maximumCount: 16,
    );
    for (final snapshot in pending) {
      await _finalizeCommittedReadback(scope, snapshot);
    }
    return pending.length;
  }

  Future<CloudSyncMessageUpdateReconciliationDisposition>
  _reconcileLeasedUnknown(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required String leaseId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) async {
    final context = _readAdoptedContext(
      scope,
      operation,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    final result = await _reconcileTypedUpdate(
      scope,
      operation: operation,
      context: context,
    );
    final now = _utcNow();
    switch (result.disposition) {
      case CloudSyncMessageUpdateReconciliationDisposition.committed:
        final snapshot = await _cloudStore.commitMessageUpdateReadbackReceipt(
          scope,
          leaseId: leaseId,
          receipt: result.receipt!,
          now: now,
        );
        await _finalizeCommittedReadback(scope, snapshot);
        await _retireReceivedReadbacks(scope, currentAuth, stillCurrent);
        break;
      case CloudSyncMessageUpdateReconciliationDisposition.notApplied:
        await _transport.completeMessageUpdateReconciliation(
          scope,
          operation: operation,
        );
        await _cloudStore.applyOutboxTransitions(
          scope,
          leaseId: leaseId,
          transitions: <CloudOutboxTransition>[
            CloudOutboxTransition.provenNotApplied(
              operation.operationId,
              category: CloudFailureCategory.unknown,
              nextEligibleAt: now.add(const Duration(seconds: 5)),
            ),
          ],
          now: now,
        );
        break;
      case CloudSyncMessageUpdateReconciliationDisposition.diverged:
        await _transport.completeMessageUpdateReconciliation(
          scope,
          operation: operation,
        );
        await _cloudStore.applyOutboxTransitions(
          scope,
          leaseId: leaseId,
          transitions: <CloudOutboxTransition>[
            CloudOutboxTransition.quarantined(
              operation.operationId,
              category: CloudFailureCategory.conflict,
            ),
          ],
          now: now,
        );
        break;
      case CloudSyncMessageUpdateReconciliationDisposition.unresolved:
        await _cloudStore.applyOutboxTransitions(
          scope,
          leaseId: leaseId,
          transitions: <CloudOutboxTransition>[
            CloudOutboxTransition.unknownOutcome(
              operation.operationId,
              nextEligibleAt: now.add(
                result.retryAfter ?? const Duration(seconds: 30),
              ),
            ),
          ],
          now: now,
        );
        break;
    }
    return result.disposition;
  }

  Future<void> _finalizeCommittedReadback(
    CloudSyncScope scope,
    CloudMessageUpdateReadbackCommitSnapshot snapshot,
  ) => _leaseTransport.runProtectedStoreExclusive(() async {
    // Reconciliation stages the exact current raw record under an
    // uncommitted lease. ObjectBox adopts that reference first; native commit
    // is the second half of the handoff. Acknowledging the lease without this
    // commit would discard the predecessor needed by the next edit/unsend.
    await _leaseTransport.commitProtectedPageLease(
      snapshot.readbackLeaseReference,
      <String>{snapshot.recordMapping.encryptedRawRecordReference!},
    );
    // Clear the mutation fence while the protected-store exclusion is still
    // held, then clear durable ownership before deleting either native receipt.
    // A crash at either boundary leaves enough durable evidence to resume
    // without another mutation or another remote readback.
    await _transport.completeMessageUpdateReconciliation(
      scope,
      operation: snapshot.confirmedOperation,
    );
    await _cloudStore.finalizeMessageUpdateReadbackLeases(
      expectedSnapshot: snapshot,
      updateStageLeaseCommitted: true,
      readbackLeaseCommitted: true,
    );
    await _leaseTransport.acknowledgeCommittedPageLease(
      snapshot.updateStageLeaseReference,
    );
    await _leaseTransport.acknowledgeCommittedPageLease(
      snapshot.readbackLeaseReference,
    );
  });

  // Complete a crash-interrupted local marker only after the shared executor
  // has finalized exact readback and relinquished the native stage lease.
  // This does not restage, submit, acknowledge IDS or infer success from UI.
  Future<void> _retireReceivedReadbacks(
    CloudSyncScope scope,
    CloudSyncNativeAuthSnapshot auth,
    bool Function() stillCurrent,
  ) async {
    final journal = _receivedJournal;
    if (journal == null) return;
    final query =
        _objectBoxStore
            .box<CloudSyncReceivedMutationIntentEntity>()
            .query(
              CloudSyncReceivedMutationIntentEntity_.accountFingerprint
                  .equals(scope.accountFingerprint)
                  .and(CloudSyncReceivedMutationIntentEntity_.state.equals(2)),
            )
            .build()
          ..limit = 16;
    late final List<CloudSyncReceivedMutationIntentEntity> rows;
    try {
      rows = query.find();
    } finally {
      query.close();
    }
    if (rows.isEmpty) return;
    final operations = await _cloudStore.readOutboxEntries(scope);
    for (final row in rows) {
      final matches = operations
          .where((op) => op.operationId == row.admittedOperationId)
          .toList();
      if (matches.length != 1) {
        throw StateError('cloud_sync_message_update_adoption_missing');
      }
      final operation = matches.single;
      if (operation.status != CloudOutboxStatus.confirmed ||
          operation.protectedLeaseReference != null) {
        continue;
      }
      if (!_isReceivedOperation(operation.operationId)) {
        throw StateError('cloud_sync_message_update_adoption_missing');
      }
      journal.markExactReadbackConfirmed(
        intentId: row.id,
        operation: operation,
        currentAuth: auth,
        stillCurrent: stillCurrent,
        now: _utcNow(),
      );
    }
  }

  Future<CloudSyncPreparedSubmission> _prepareTypedSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
    required _AdoptedMessageUpdateContext context,
  }) => switch (context) {
    _OutgoingMessageUpdateContext(:final source, :final predecessor) =>
      _transport.prepareMessageUpdateSubmission(
        scope,
        submissionIdentity: submissionIdentity,
        operation: operation,
        protectedOperation: protectedOperation,
        source: source,
        predecessor: predecessor,
      ),
    _ReceivedMessageUpdateContext(:final source, :final predecessor) =>
      _requireReceivedTransport().prepareReceivedMessageUpdateSubmission(
        scope,
        submissionIdentity: submissionIdentity,
        operation: operation,
        protectedOperation: protectedOperation,
        source: source,
        predecessor: predecessor,
      ),
  };

  Future<CloudSyncMessageUpdateReconciliation> _reconcileTypedUpdate(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required _AdoptedMessageUpdateContext context,
  }) => switch (context) {
    _OutgoingMessageUpdateContext(:final source, :final predecessor) =>
      _transport.reconcileMessageUpdate(
        scope,
        operation: operation,
        source: source,
        predecessor: predecessor,
      ),
    _ReceivedMessageUpdateContext(:final source, :final predecessor) =>
      _requireReceivedTransport().reconcileReceivedMessageUpdate(
        scope,
        operation: operation,
        source: source,
        predecessor: predecessor,
      ),
  };

  CloudSyncReceivedMessageUpdateTransport _requireReceivedTransport() =>
      _receivedTransport ??
      (throw StateError('cloud_sync_received_mutation_transport_unavailable'));

  // An operation must belong to exactly one origin journal. The generic outbox
  // is shared; an operation ID is never itself proof of the source's origin.
  bool _isReceivedOperation(String operationId) {
    final query = _objectBoxStore
        .box<CloudSyncLocalMutationIntentEntity>()
        .query(
          CloudSyncLocalMutationIntentEntity_.admittedOperationId.equals(
            operationId,
          ),
        )
        .build();
    final bool local;
    try {
      local = query.findUnique() != null;
    } finally {
      query.close();
    }
    final received =
        _receivedJournal?.hasAdoptedOperationId(operationId) ?? false;
    if (local == received) {
      throw StateError('cloud_sync_message_update_adoption_missing');
    }
    return received;
  }

  _AdoptedMessageUpdateContext _readAdoptedContext(
    CloudSyncScope scope,
    CloudOutboxOperation operation, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) {
    if (_isReceivedOperation(operation.operationId)) {
      _requireReceivedTransport();
      final source = _receivedJournal!.readAdoptedForUpdate(
        operationId: operation.operationId,
        currentAuth: currentAuth,
        stillCurrent: stillCurrent,
      );
      final predecessor = source.requirePredecessor(
        store: _objectBoxStore,
        messageScope: scope,
        readConfirmedLocalParent: _readConfirmedLocalParent,
      );
      _validateAdoptedOperation(operation, predecessor);
      return _ReceivedMessageUpdateContext(source, predecessor);
    }
    final source = _journal.readAdoptedForUpdate(
      operationId: operation.operationId,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
      replayBinding: _replayBinding,
    );
    final predecessor = source.requirePredecessor(
      store: _objectBoxStore,
      messageScope: scope,
      readConfirmedLocalParent: _readConfirmedLocalParent,
    );
    _validateAdoptedOperation(operation, predecessor);
    return _OutgoingMessageUpdateContext(source, predecessor);
  }

  void _validateAdoptedOperation(
    CloudOutboxOperation operation,
    CloudSyncMessageMutationPredecessor predecessor,
  ) {
    final mapping = cloudSyncFindRecordMap(
      store: _objectBoxStore,
      scope: operation.scope,
      generation: predecessor.generation,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: operation.serverRecordIdHash,
    );
    if (mapping == null) {
      throw StateError('cloud_sync_message_update_predecessor_missing');
    }
    if (_isReceivedOperation(operation.operationId)) {
      _receivedJournal!.validateAdoptedOperation(
        _objectBoxStore,
        operation,
        mapping,
      );
    } else {
      _journal.validateAdoptedOperation(_objectBoxStore, operation, mapping);
    }
  }

  Future<CloudOutboxOperation> _readExactOperation(
    CloudSyncScope scope,
    String operationId,
  ) async {
    final matches = (await _cloudStore.readOutboxEntries(scope))
        .where((operation) => operation.operationId == operationId)
        .toList(growable: false);
    if (matches.length != 1 ||
        matches.single.payloadVersion != cloudSyncMessageUpdatePayloadVersion) {
      throw StateError('cloud_sync_message_update_adoption_missing');
    }
    return matches.single;
  }

  CloudSyncMessageUpdateRunResult _result({
    required int recovered,
    int reconciledUnknown = 0,
    int submitted = 0,
    required CloudSyncMessageUpdateReconciliationDisposition resolution,
  }) => CloudSyncMessageUpdateRunResult(
    recoveredReadbacks: recovered,
    reconciledUnknown: reconciledUnknown,
    submitted: submitted,
    confirmed:
        resolution == CloudSyncMessageUpdateReconciliationDisposition.committed
        ? 1
        : 0,
    notApplied:
        resolution == CloudSyncMessageUpdateReconciliationDisposition.notApplied
        ? 1
        : 0,
    diverged:
        resolution == CloudSyncMessageUpdateReconciliationDisposition.diverged
        ? 1
        : 0,
    unresolved:
        resolution == CloudSyncMessageUpdateReconciliationDisposition.unresolved
        ? 1
        : 0,
  );

  DateTime _utcNow() {
    final now = _clock();
    return now.isUtc ? now : now.toUtc();
  }

  String _leaseId(String prefix) => '$prefix:${_uuidFactory()}';
}

sealed class _AdoptedMessageUpdateContext {
  const _AdoptedMessageUpdateContext(this.predecessor);
  final CloudSyncMessageMutationPredecessor predecessor;
}

final class _OutgoingMessageUpdateContext extends _AdoptedMessageUpdateContext {
  const _OutgoingMessageUpdateContext(this.source, super.predecessor);
  final CloudSyncLocalMutationAdmissionSource source;
}

final class _ReceivedMessageUpdateContext extends _AdoptedMessageUpdateContext {
  const _ReceivedMessageUpdateContext(this.source, super.predecessor);
  final CloudSyncReceivedMutationAdmissionSource source;
}
