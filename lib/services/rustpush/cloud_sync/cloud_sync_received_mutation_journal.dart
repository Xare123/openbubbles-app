// Keep readable public names at the injection boundary.
// ignore_for_file: prefer_initializing_formals
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

import 'cloud_operation_identity.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_mutation_lineage.dart';
import 'cloud_sync_outbound_message_dependency.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_received_archive_identity.dart';
import 'cloud_sync_received_mutation_identity.dart';
import 'cloud_sync_received_mutation_source_binding.dart';
import 'cloud_sync_record_maps.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Local durable ownership only. No writer permit, native calls or network I/O.
/// Source and original target identities are immutable across duplicate events;
/// target reflection and its completion marker commit in one ObjectBox write.
final class CloudSyncReceivedMutationJournal {
  CloudSyncReceivedMutationJournal({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot owner,
  }) : _store = store,
       _authority = authority,
       _owner = owner {
    if (!authority.isBoundToStore(store)) {
      _fail('owner_changed');
    }
  }
  final Store _store;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterAuthoritySnapshot _owner;

  bool isBoundToStore(Store store) => identical(store, _store);

  /// Routing evidence only. A retained operation must not fall through into
  /// another origin's journal, even when its current owner cannot dispatch it.
  bool hasAdoptedOperationId(String operationId) => _store.runInTransaction(
    TxMode.read,
    () => _findAdopted(operationId) != null,
  );

  /// Fair, bounded inventory, not eligibility or permission to stage an update.
  List<CloudSyncReceivedMutationIntentEntity> readUpdateCandidates({
    required CloudSyncNativeAuthSnapshot currentAuth,
    int limit = 5,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    _requireUpdateOwner();
    if (limit < 1 || limit > 20) _fail('limit_invalid');
    final query =
        (_store.box<CloudSyncReceivedMutationIntentEntity>().query(
                CloudSyncReceivedMutationIntentEntity_.accountFingerprint
                    .equals(currentAuth.accountFingerprint)
                    .and(
                      CloudSyncReceivedMutationIntentEntity_.ownershipEpoch
                          .equals(_owner.automaticArchiveEpoch),
                    )
                    .and(
                      CloudSyncReceivedMutationIntentEntity_.state.equals(1),
                    ),
              )
              ..order(CloudSyncReceivedMutationIntentEntity_.updatedAtMs)
              ..order(CloudSyncReceivedMutationIntentEntity_.id))
            .build()
          ..limit = limit;
    try {
      return query.find();
    } finally {
      query.close();
    }
  });

  void markUpdateConsidered({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireCurrent(currentAuth, stillCurrent);
    _requireUpdateOwner();
    final row = _read(intentId);
    _validateRow(row, currentAuth);
    if (row.state != 1) _fail('update_not_ready');
    row.updatedAtMs = _advanceTime(row, now);
    _store.box<CloudSyncReceivedMutationIntentEntity>().put(row);
    _requireCurrent(currentAuth, stillCurrent);
    _requireUpdateOwner();
  });

  /// Existence only: keep exact readback retirement reachable even if no fresh
  /// source is eligible. This does not claim the operation is confirmed.
  bool hasPendingReadbackRetirement({
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    final query =
        _store
            .box<CloudSyncReceivedMutationIntentEntity>()
            .query(
              CloudSyncReceivedMutationIntentEntity_.accountFingerprint
                  .equals(currentAuth.accountFingerprint)
                  .and(
                    CloudSyncReceivedMutationIntentEntity_.ownershipEpoch
                        .equals(_owner.automaticArchiveEpoch),
                  )
                  .and(CloudSyncReceivedMutationIntentEntity_.state.equals(2)),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst() != null;
    } finally {
      query.close();
    }
  });

  CloudSyncReceivedMutationAdmissionSource readReflectedForUpdate({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, stillCurrent);
    final row = _read(intentId);
    final source = _validateRow(row, currentAuth);
    _requireUpdateOwner(
      capturedEpoch: row.state >= 2 ? row.admittedWriterEpoch : null,
    );
    if ((row.state != 1 && row.state != 2) || row.targetPart != 0) {
      _fail('update_not_ready');
    }
    final tip = _requireReflectedTip(row, source.protectedStoreIdentity);
    return CloudSyncReceivedMutationAdmissionSource._(
      row,
      store: _store,
      writerEpoch: _owner.epoch,
      protectedStoreIdentity: source.protectedStoreIdentity,
      validatedTipSnapshotSha256: tip,
    );
  });

  CloudSyncReceivedMutationAdmissionSource readAdoptedForUpdate({
    required String operationId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, stillCurrent);
    final row = _findAdopted(operationId);
    if (row == null) _fail('adoption_missing');
    final source = _validateRow(row, currentAuth);
    if (row.state != 2) _fail('adoption_changed');
    _requireUpdateOwner(capturedEpoch: row.admittedWriterEpoch);
    final tip = _requireReflectedTip(row, source.protectedStoreIdentity);
    return CloudSyncReceivedMutationAdmissionSource._(
      row,
      store: _store,
      writerEpoch: _owner.epoch,
      protectedStoreIdentity: source.protectedStoreIdentity,
      validatedTipSnapshotSha256: tip,
    );
  });

  /// Synchronous hooks in the caller's exact outbox write transaction. The
  /// source owns an inline encrypted seed, not an outgoing receipt/file lease.
  String? adoptedOperationIdInOutboxTransaction(
    Store transactionStore,
    CloudSyncReceivedMutationAdmissionSource expected, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) => _requireUpdateSource(
    transactionStore,
    expected,
    currentAuth: currentAuth,
    stillCurrent: stillCurrent,
  ).admittedOperationId;

  void adoptInOutboxTransaction(
    Store transactionStore,
    CloudSyncReceivedMutationAdmissionSource expected,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required DateTime now,
    CloudSyncConfirmedLocalParentReader? readConfirmedLocalParent,
  }) {
    final row = _requireUpdateSource(
      transactionStore,
      expected,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    _requireUpdateOperation(row, operation, predecessor);
    final claimed = _findAdopted(operation.operationId);
    if (claimed != null && claimed.id != row.id) _fail('adoption_changed');
    final binding = _updateAdoptionBinding(
      row,
      operation,
      predecessor,
      writerEpoch: expected.writerEpoch,
    );
    if (row.state == 2) {
      if (row.admittedOperationId != operation.operationId ||
          row.admittedBindingSha256 != binding) {
        _fail('adoption_changed');
      }
      return;
    }
    _requireFreshUpdateOwner(expected.writerEpoch);
    final resolved = expected.requirePredecessor(
      store: transactionStore,
      messageScope: operation.scope,
      readConfirmedLocalParent: readConfirmedLocalParent,
    );
    if (!resolved.recordMapping.sameDurableSnapshotAs(
      _mapEntry(operation.scope, predecessor),
    )) {
      _fail('predecessor_changed');
    }
    row
      ..state = 2
      ..admittedOperationId = operation.operationId
      ..admittedBindingSha256 = binding
      ..admittedWriterEpoch = expected.writerEpoch
      ..updatedAtMs = _advanceTime(row, now);
    _store.box<CloudSyncReceivedMutationIntentEntity>().put(row);
    _requireCurrent(currentAuth, stillCurrent);
    _requireFreshUpdateOwner(expected.writerEpoch);
  }

  /// Validates only durable local correlation. The caller still needs native
  /// actor/route proof, consent and the normal executor's write/readback fences.
  void validateAdoptedOperation(
    Store transactionStore,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor,
  ) {
    _requireStore(transactionStore);
    final row = _findAdopted(operation.operationId);
    if (row == null) _fail('adoption_missing');
    final source = _validateCorrelatedRow(row);
    if (row.state != 2) _fail('adoption_changed');
    _requireUpdateOwner(capturedEpoch: row.admittedWriterEpoch);
    _requireReflectedTip(row, source.protectedStoreIdentity);
    _requireUpdateOperation(row, operation, predecessor);
    if (row.admittedBindingSha256 !=
        _updateAdoptionBinding(row, operation, predecessor)) {
      _fail('adoption_changed');
    }
  }

  /// Called by exact-readback settlement, after the persisted confirmed outbox
  /// receipt's native lease is cleared. Neither IDS nor save-only success is
  /// sufficient. The inline seed remains immutable retained evidence.
  CloudSyncReceivedMutationSourceBinding markExactReadbackConfirmed({
    required int intentId,
    required CloudOutboxOperation operation,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireCurrent(currentAuth, stillCurrent);
    if (_authority.read(_owner.scope)!.state !=
        CloudKitWriterAuthorityState.stable) {
      _fail('owner_changed');
    }
    final row = _read(intentId);
    final source = _validateRow(row, currentAuth);
    _requireUpdateOwner(capturedEpoch: row.admittedWriterEpoch);
    if ((row.state != 2 && row.state != 3) ||
        row.admittedOperationId != operation.operationId ||
        operation.scope.accountFingerprint != row.accountFingerprint ||
        operation.payloadVersion != cloudSyncMessageUpdatePayloadVersion ||
        operation.action != CloudOutboxAction.save ||
        operation.status != CloudOutboxStatus.confirmed ||
        operation.confirmedAt == null ||
        !operation.confirmedAt!.isUtc ||
        operation.confirmedAt!.millisecondsSinceEpoch <= 0 ||
        operation.protectedLeaseReference != null) {
      _fail('terminal_changed');
    }
    final persisted = _requirePersistedOperation(operation);
    if (persisted.state != CloudOutboxStatus.confirmed.index ||
        persisted.protectedLeaseReference != null ||
        persisted.confirmedAtMs !=
            operation.confirmedAt!.millisecondsSinceEpoch ||
        persisted.attemptCount != operation.attemptCount) {
      _fail('terminal_changed');
    }
    if (row.state == 3) return source;
    row
      ..state = 3
      ..updatedAtMs = _advanceTime(row, now);
    _store.box<CloudSyncReceivedMutationIntentEntity>().put(row);
    _requireCurrent(currentAuth, stillCurrent);
    return source;
  });

  CloudSyncReceivedMutationIntentEntity _requireUpdateSource(
    Store transactionStore,
    CloudSyncReceivedMutationAdmissionSource expected, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) {
    _requireStore(transactionStore);
    if (!identical(expected._store, _store)) _fail('adoption_store_mismatch');
    _requireCurrent(currentAuth, stillCurrent);
    final row = _read(expected.intentId);
    final source = _validateRow(row, currentAuth);
    _requireUpdateOwner(
      capturedEpoch: row.state >= 2 ? row.admittedWriterEpoch : null,
    );
    if (expected.writerEpoch !=
            (row.state >= 2 ? row.admittedWriterEpoch : _owner.epoch) ||
        !expected._matches(row) ||
        (row.state != 1 && row.state != 2) ||
        row.targetPart != 0) {
      _fail('adoption_changed');
    }
    if (_requireReflectedTip(row, source.protectedStoreIdentity) !=
        expected._validatedTipSnapshotSha256) {
      _fail('reflection_changed');
    }
    return row;
  }

  void _requireStore(Store store) {
    if (!isBoundToStore(store)) _fail('adoption_store_mismatch');
  }

  void _requireUpdateOwner({int? capturedEpoch}) {
    final current = _authority.read(_owner.scope);
    if (_owner.owner != CloudKitWriterOwner.v2 ||
        _owner.epoch <= 0 ||
        _owner.scope.container != 'com.apple.messages.cloud' ||
        _owner.scope.database != 'private' ||
        current == null ||
        current.owner != CloudKitWriterOwner.v2 ||
        current.automaticArchiveEpoch <= 0 ||
        current.automaticArchiveEpoch != _owner.automaticArchiveEpoch ||
        (capturedEpoch == null
            ? current.epoch != _owner.epoch
            : !(current.continuesCapturedEpoch(
                    capturedEpoch,
                    allowMutationUnknown: true,
                  ) ||
                  (current.ownershipEpoch == 0 &&
                      current.state == CloudKitWriterAuthorityState.stable &&
                      current.epoch == capturedEpoch &&
                      _owner.epoch == capturedEpoch)))) {
      _fail('owner_changed');
    }
  }

  void _requireFreshUpdateOwner(int epoch) {
    _requireUpdateOwner();
    final current = _authority.read(_owner.scope)!;
    if (epoch != _owner.epoch ||
        current.state != CloudKitWriterAuthorityState.stable) {
      _fail('owner_changed');
    }
  }

  CloudSyncReceivedMutationIntentEntity? _findAdopted(String operationId) {
    if (!_operationId.hasMatch(operationId)) _fail('adoption_missing');
    return _unique(
      _store.box<CloudSyncReceivedMutationIntentEntity>().query(
        CloudSyncReceivedMutationIntentEntity_.admittedOperationId.equals(
          operationId,
        ),
      ),
    );
  }

  Message _requireEligibleReflectedTarget(
    CloudSyncReceivedMutationIntentEntity row,
  ) {
    final target = _store.box<Message>().get(row.localMessageId);
    final chat = _store.box<Chat>().get(row.localChatId);
    final guid = target?.guid;
    if (target == null ||
        guid == null ||
        _digest(['cloud-sync-received-archive-guid-v1', guid]) !=
            row.targetGuidHash ||
        target.chat.targetId != row.localChatId ||
        target.isFromMe !=
            (row.origin == CloudSyncReceivedArchiveOrigin.mirrored.index) ||
        target.verificationFailed ||
        target.dateDeleted != null ||
        target.associatedMessageGuid != null ||
        target.associatedMessagePart != null ||
        target.associatedMessageType != null ||
        target.associatedMessageEmoji != null ||
        chat == null ||
        chat.dateDeleted != null ||
        chat.isRpSms ||
        (chat.style != 43 && chat.style != 45)) {
      _fail('reflection_changed');
    }
    if (row.origin == CloudSyncReceivedArchiveOrigin.incoming.index) {
      final handle = target.handleId == null
          ? null
          : _unique(
              _store.box<Handle>().query(
                Handle_.originalROWID.equals(target.handleId!),
              ),
            );
      if (handle == null ||
          handle.service != 'iMessage' ||
          handle.address.isEmpty ||
          (chat.style == 45 &&
              chat.chatIdentifier != handle.address &&
              chat.guid != 'iMessage;-;${handle.address}')) {
        _fail('target_author_changed');
      }
    }
    // Author/unsupported-source checks stay separate from shared snapshot bytes.
    return target;
  }

  String _requireReflectedTip(
    CloudSyncReceivedMutationIntentEntity row,
    String storeIdentity,
  ) => requireCloudSyncMutationForwardLineage(
    store: _store,
    target: _requireEligibleReflectedTarget(row),
    accountFingerprint: row.accountFingerprint,
    protectedStoreIdentity: storeIdentity,
    maximumWriterEpoch: _authority.read(_owner.scope)!.epoch,
    automaticArchiveEpoch: _owner.automaticArchiveEpoch,
    receivedOrigin: true,
    intentId: row.id,
    reject: () => _fail('reflection_changed'),
  );

  void _requireUpdateOperation(
    CloudSyncReceivedMutationIntentEntity row,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor,
  ) {
    final scope = operation.scope;
    if (!_messageScope(scope) ||
        scope.accountFingerprint != row.accountFingerprint ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncMessageUpdatePayloadVersion ||
        operation.mutationRevision <= 0 ||
        operation.checkpointGeneration <= 0 ||
        operation.dependencyOperationIds.isNotEmpty ||
        !_reference.hasMatch(operation.encryptedPayloadReference ?? '') ||
        !_hash.hasMatch(operation.payloadSha256 ?? '') ||
        !_nativeDigest.hasMatch(operation.logicalEntityKeyHash) ||
        !_nativeDigest.hasMatch(operation.serverRecordIdHash ?? '') ||
        !_lease.hasMatch(operation.protectedLeaseReference ?? '') ||
        !operation.createdAt.isUtc ||
        operation.createdAt.millisecondsSinceEpoch <= 0 ||
        predecessor.mapKey !=
            cloudSyncCanonicalRecordMapKey(
              scope,
              operation.logicalEntityKeyHash,
            ) ||
        predecessor.scopeKey != cloudSyncPersistentScopeKey(scope) ||
        predecessor.accountFingerprint != scope.accountFingerprint ||
        predecessor.zone != scope.zone ||
        predecessor.generation != operation.checkpointGeneration ||
        predecessor.rawRecordGeneration != operation.checkpointGeneration ||
        predecessor.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
        predecessor.serverRecordIdHash != operation.serverRecordIdHash ||
        !_reference.hasMatch(predecessor.encryptedServerRecordId) ||
        !_reference.hasMatch(predecessor.encryptedRawRecordRef ?? '') ||
        !_nativeDigest.hasMatch(predecessor.etagHash ?? '')) {
      _fail('adoption_operation_invalid');
    }
    final checkpoint = _unique(
      _store.box<CloudSyncCheckpointEntity>().query(
        CloudSyncCheckpointEntity_.checkpointKey.equals(predecessor.scopeKey),
      ),
    );
    if (checkpoint == null ||
        checkpoint.generation != operation.checkpointGeneration ||
        checkpoint.accountFingerprint != scope.accountFingerprint ||
        checkpoint.container != scope.container ||
        checkpoint.database != scope.database ||
        checkpoint.zone != scope.zone ||
        checkpoint.schemaVersion != scope.schemaVersion ||
        checkpoint.streamKind != scope.streamKind.name ||
        checkpoint.persistenceLane != scope.persistenceLane.name) {
      _fail('predecessor_changed');
    }
    final currentMap = cloudSyncFindRecordMap(
      store: _store,
      scope: scope,
      generation: operation.checkpointGeneration,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: operation.serverRecordIdHash,
    );
    if (currentMap == null ||
        _adoptionDigest(_mapContext(currentMap)) !=
            _adoptionDigest(_mapContext(predecessor))) {
      _fail('predecessor_changed');
    }
    final persisted = _requirePersistedOperation(operation);
    if (row.state == 1 &&
        (operation.status != CloudOutboxStatus.pending ||
            operation.attemptCount != 0 ||
            operation.nextEligibleAt != null ||
            operation.lastFailure != null ||
            operation.leaseId != null ||
            operation.leaseExpiresAt != null ||
            operation.confirmedAt != null ||
            operation.appleRequestUuid != null ||
            operation.appleOperationUuid != null ||
            persisted.state != CloudOutboxStatus.pending.index ||
            persisted.attemptCount != 0 ||
            persisted.nextEligibleAtMs != 0 ||
            persisted.lastErrorCategory != null ||
            persisted.leaseIdHash != null ||
            persisted.leaseExpiresAtMs != 0 ||
            persisted.confirmedAtMs != 0 ||
            persisted.appleRequestUuid != null ||
            persisted.appleOperationUuid != null ||
            predecessor.protectedReadbackLeaseReference != null ||
            predecessor.pendingUpdateOperationId != null ||
            predecessor.pendingUpdatePredecessorEtagHash != null)) {
      _fail('adoption_operation_invalid');
    }
  }

  CloudOutboxOperationEntity _requirePersistedOperation(
    CloudOutboxOperation operation,
  ) {
    final persisted = _unique(
      _store.box<CloudOutboxOperationEntity>().query(
        CloudOutboxOperationEntity_.operationId.equals(operation.operationId),
      ),
    );
    if (persisted == null ||
        !_messageScope(operation.scope) ||
        operation.mutationRevision <= 0 ||
        operation.dependencyOperationIds.isNotEmpty ||
        operation.operationId !=
            CloudOperationIdentity.forMutation(
              scope: operation.scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              action: operation.action,
              payloadVersion: operation.payloadVersion,
              mutationRevision: operation.mutationRevision,
              payloadSha256: operation.payloadSha256,
            ) ||
        persisted.scopeKey != cloudSyncPersistentScopeKey(operation.scope) ||
        persisted.accountFingerprint != operation.scope.accountFingerprint ||
        persisted.zone != operation.scope.zone ||
        persisted.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
        persisted.action != operation.action.index ||
        persisted.payloadVersion != operation.payloadVersion ||
        persisted.mutationRevision != operation.mutationRevision ||
        persisted.checkpointGeneration != operation.checkpointGeneration ||
        persisted.encryptedPayloadRef != operation.encryptedPayloadReference ||
        persisted.payloadSha256 != operation.payloadSha256 ||
        persisted.serverRecordIdHash != operation.serverRecordIdHash ||
        persisted.protectedLeaseReference !=
            operation.protectedLeaseReference ||
        persisted.createdAtMs != operation.createdAt.millisecondsSinceEpoch) {
      _fail('adoption_operation_invalid');
    }
    try {
      final dependencies = jsonDecode(persisted.dependencyOperationIdsJson);
      if (dependencies is! List || dependencies.isNotEmpty) {
        _fail('adoption_operation_invalid');
      }
    } on FormatException {
      _fail('adoption_operation_invalid');
    }
    return persisted;
  }

  String _updateAdoptionBinding(
    CloudSyncReceivedMutationIntentEntity row,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor, {
    int? writerEpoch,
  }) => _adoptionDigest([
    'cloud-sync-received-mutation-update-adoption-v1',
    _mutationContext(row, writerEpoch: writerEpoch ?? row.admittedWriterEpoch),
    operation.scope.storageKey,
    operation.operationId,
    operation.logicalEntityKeyHash,
    operation.action.name,
    operation.payloadVersion,
    operation.mutationRevision,
    operation.checkpointGeneration,
    operation.encryptedPayloadReference,
    operation.payloadSha256,
    operation.serverRecordIdHash,
    operation.protectedLeaseReference,
    operation.dependencyOperationIds.toList()..sort(),
    operation.createdAt.millisecondsSinceEpoch,
    _mapContext(predecessor),
  ]);

  int retain({
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required CloudSyncReceivedMutationSourceBinding source,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireCurrent(currentAuth, stillCurrent);
    final identity = CloudSyncReceivedMutationIdentity.captureWire(
      wire,
      liveContext: liveContext,
      expectedSourceSha256: source.sourceSha256,
    );
    if (identity == null || identity.guidHash != source.mutationGuidHash) {
      _fail('source_changed');
    }
    source.requireOrigin(
      account: currentAuth.accountFingerprint,
      store: currentAuth.protectedStoreIdentity,
      eventGuidHash: identity.guidHash,
      sourceDigest: identity.sourceSha256,
    );
    final key = intentKey(currentAuth.accountFingerprint, identity.guidHash);
    final existing = _unique(
      _store.box<CloudSyncReceivedMutationIntentEntity>().query(
        CloudSyncReceivedMutationIntentEntity_.intentKey.equals(key),
      ),
    );
    if (existing != null) {
      _validateRow(existing, currentAuth);
      if (existing.sourceSha256 != identity.sourceSha256 ||
          existing.targetGuidHash != identity.targetGuidHash ||
          existing.targetPart != identity.targetPart ||
          existing.kind != identity.kind.index ||
          existing.origin != identity.origin.index ||
          existing.sentTimestampMs != identity.sentTimestamp) {
        _fail('source_changed');
      }
      // Randomized encryption of the same source never replaces its first seed.
      return existing.id;
    }
    if (!now.isUtc || now.millisecondsSinceEpoch <= 0) _fail('time_invalid');
    final time = now.millisecondsSinceEpoch;
    final id = _store.box<CloudSyncReceivedMutationIntentEntity>().put(
      CloudSyncReceivedMutationIntentEntity(
        intentKey: key,
        accountFingerprint: currentAuth.accountFingerprint,
        ownershipEpoch: _owner.automaticArchiveEpoch,
        mutationGuidHash: identity.guidHash,
        targetGuidHash: identity.targetGuidHash,
        targetPart: identity.targetPart,
        origin: identity.origin.index,
        kind: identity.kind.index,
        sentTimestampMs: identity.sentTimestamp,
        sourceSha256: identity.sourceSha256,
        protectedSourceBinding: source.encode(),
        createdAtMs: time,
        updatedAtMs: time,
      ),
    );
    _requireCurrent(currentAuth, stillCurrent);
    return id;
  });

  CloudSyncReceivedMutationSourceBinding? findSource({
    required String eventGuid,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    final row = _unique(
      _store.box<CloudSyncReceivedMutationIntentEntity>().query(
        CloudSyncReceivedMutationIntentEntity_.intentKey.equals(
          intentKey(
            currentAuth.accountFingerprint,
            _digest(['cloud-sync-received-mutation-guid-v1', eventGuid]),
          ),
        ),
      ),
    );
    if (row == null) return null;
    return _validateRow(row, currentAuth);
  });

  /// Reading local rows is not permission to replay them to Apple. A worker must
  /// reopen the native seed, resolve its exact predecessor and obtain consent.
  List<CloudSyncReceivedMutationIntentEntity> readPending({
    required CloudSyncNativeAuthSnapshot currentAuth,
    int afterId = 0,
    int limit = 20,
    bool onlyPendingReflection = false,
    int? maximumIntentId,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    if (limit < 1 ||
        limit > 50 ||
        afterId < 0 ||
        (maximumIntentId != null && maximumIntentId < 0)) {
      _fail('limit_invalid');
    }
    var condition = CloudSyncReceivedMutationIntentEntity_.accountFingerprint
        .equals(currentAuth.accountFingerprint)
        .and(
          CloudSyncReceivedMutationIntentEntity_.ownershipEpoch.equals(
            _owner.automaticArchiveEpoch,
          ),
        )
        .and(CloudSyncReceivedMutationIntentEntity_.id.greaterThan(afterId));
    if (onlyPendingReflection) {
      condition = condition.and(
        CloudSyncReceivedMutationIntentEntity_.state.equals(0),
      );
    }
    if (maximumIntentId != null) {
      condition = condition.and(
        CloudSyncReceivedMutationIntentEntity_.id.lessOrEqual(maximumIntentId),
      );
    }
    final query = (_store.box<CloudSyncReceivedMutationIntentEntity>().query(
      condition,
    )..order(CloudSyncReceivedMutationIntentEntity_.id)).build()..limit = limit;
    try {
      final rows = query.find();
      for (final row in rows) {
        _validateRow(row, currentAuth);
      }
      return rows;
    } finally {
      query.close();
    }
  });

  int captureReadHighWatermark({
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    final query =
        (_store.box<CloudSyncReceivedMutationIntentEntity>().query(
              CloudSyncReceivedMutationIntentEntity_.accountFingerprint
                  .equals(currentAuth.accountFingerprint)
                  .and(
                    CloudSyncReceivedMutationIntentEntity_.ownershipEpoch
                        .equals(_owner.automaticArchiveEpoch),
                  ),
            )..order(
              CloudSyncReceivedMutationIntentEntity_.id,
              flags: Order.descending,
            ))
            .build()
          ..limit = 1;
    try {
      return query.findFirst()?.id ?? 0;
    } finally {
      query.close();
    }
  });

  /// True means the one exact event already committed its local reflection.
  /// Later edits to the target do not erase this retained receipt or reapply it.
  bool reflectionCommitted({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    final row = _read(intentId);
    _validateRow(row, currentAuth);
    return row.state >= 1;
  });

  Message commitReflection({
    required int intentId,
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required String expectedBeforeSnapshot,
    required Message reflected,
    required DateTime now,
  }) => _commitReflection(
    intentId: intentId,
    wire: wire,
    currentAuth: currentAuth,
    stillCurrent: stillCurrent,
    expectedBeforeSnapshot: expectedBeforeSnapshot,
    reflected: reflected,
    now: now,
    capturedLocalHandles: liveContext.observedLocalHandles,
    identify: (row) => CloudSyncReceivedMutationIdentity.captureWire(
      wire,
      liveContext: liveContext,
      expectedSourceSha256: row.sourceSha256,
    ),
  );

  /// Local crash recovery only. A native-restored event is not a new live
  /// receive. It must match the first retained source and current account/store.
  Message commitReplayedReflection({
    required int intentId,
    required api.CloudSyncRestoredReceivedMutation restored,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required String expectedBeforeSnapshot,
    required Message reflected,
    required DateTime now,
  }) {
    if (restored.accountFingerprint != currentAuth.accountFingerprint ||
        restored.protectedStoreIdentity != currentAuth.protectedStoreIdentity) {
      _fail('source_changed');
    }
    return _commitReflection(
      intentId: intentId,
      wire: restored.message,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
      expectedBeforeSnapshot: expectedBeforeSnapshot,
      reflected: reflected,
      now: now,
      capturedLocalHandles: restored.capturedLocalHandles,
      identify: (row) => CloudSyncReceivedMutationIdentity.restoreNative(
        restored,
        expectedGuidHash: row.mutationGuidHash,
        expectedTargetGuidHash: row.targetGuidHash,
        expectedSourceSha256: row.sourceSha256,
      ),
    );
  }

  Message _commitReflection({
    required int intentId,
    required api.MessageInst wire,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required String expectedBeforeSnapshot,
    required Message reflected,
    required DateTime now,
    required List<String> capturedLocalHandles,
    required CloudSyncReceivedMutationIdentity? Function(
      CloudSyncReceivedMutationIntentEntity,
    )
    identify,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireCurrent(currentAuth, stillCurrent);
    final row = _read(intentId);
    _validateRow(row, currentAuth);
    final identity = identify(row);
    if (identity == null || identity.guidHash != row.mutationGuidHash) {
      _fail('source_changed');
    }
    final targetGuid = switch (wire.message) {
      api.Message_Edit(:final field0) => field0.tuuid,
      api.Message_Unsend(:final field0) => field0.tuuid,
      _ => null,
    };
    if (targetGuid == null || reflected.guid != targetGuid) {
      _fail('target_changed');
    }
    final target = _unique(
      _store.box<Message>().query(Message_.guid.equals(targetGuid)),
    );
    if (target == null || target.id == null || target.id! <= 0) {
      _fail('target_missing');
    }
    if (row.state >= 1) return target;
    _requireTargetAuthor(target, wire, identity, capturedLocalHandles);
    if (snapshot(target) != expectedBeforeSnapshot ||
        reflected.id != target.id ||
        reflected.chat.targetId != target.chat.targetId ||
        reflected.isFromMe != target.isFromMe ||
        reflected.handleId != target.handleId ||
        reflected.dateCreated != target.dateCreated ||
        reflected.dateDeleted != target.dateDeleted) {
      _fail('target_changed');
    }
    _requireOrderedTarget(row, target);
    if (!now.isUtc || now.millisecondsSinceEpoch <= 0) _fail('time_invalid');
    // Persist only reflection-owned fields. A read receipt, bookmark or cloud
    // mapping can change while reflection awaits without being rolled back by
    // a stale whole-row put. The original media relations are never rewritten.
    target
      ..text = reflected.text
      ..attributedBody = reflected.attributedBody
      ..messageSummaryInfo = reflected.messageSummaryInfo
      ..dateEdited = DateTime.fromMillisecondsSinceEpoch(row.sentTimestampMs)
      ..verificationFailed = reflected.verificationFailed;
    _store.box<Message>().put(target, mode: PutMode.update);
    row.localMessageId = target.id!;
    row.localChatId = target.chat.targetId;
    row.beforeSnapshotSha256 = expectedBeforeSnapshot;
    row.reflectedSnapshotSha256 = snapshot(
      _store.box<Message>().get(target.id!)!,
    );
    row.state = 1;
    row.updatedAtMs = now.millisecondsSinceEpoch > row.updatedAtMs
        ? now.millisecondsSinceEpoch
        : row.updatedAtMs + 1;
    _store.box<CloudSyncReceivedMutationIntentEntity>().put(row);
    _requireCurrent(currentAuth, stillCurrent);
    return target;
  });

  void _requireOrderedTarget(
    CloudSyncReceivedMutationIntentEntity row,
    Message target,
  ) {
    if (target.dateCreated == null ||
        row.sentTimestampMs < target.dateCreated!.millisecondsSinceEpoch) {
      _fail('predecessor_changed');
    }
    // Retraction is terminal for this part. A late edit must not resurrect it.
    for (final summary in target.messageSummaryInfo) {
      if (summary.retractedParts.contains(row.targetPart)) {
        _fail('predecessor_changed');
      }
      for (final edit
          in summary.editedContent[row.targetPart.toString()] ??
              <EditedContent>[]) {
        final date = edit.date;
        if (date == null || !date.isFinite || date >= row.sentTimestampMs) {
          _fail('predecessor_changed');
        }
      }
    }
    final query = _store
        .box<CloudSyncReceivedMutationIntentEntity>()
        .query(
          CloudSyncReceivedMutationIntentEntity_.accountFingerprint
              .equals(row.accountFingerprint)
              .and(
                CloudSyncReceivedMutationIntentEntity_.targetGuidHash.equals(
                  row.targetGuidHash,
                ),
              )
              .and(
                CloudSyncReceivedMutationIntentEntity_.targetPart.equals(
                  row.targetPart,
                ),
              )
              .and(CloudSyncReceivedMutationIntentEntity_.state.greaterThan(0))
              .and(CloudSyncReceivedMutationIntentEntity_.state.lessOrEqual(3)),
        )
        .build();
    try {
      for (final previous in query.find()) {
        if (previous.id == row.id) continue;
        if (previous.kind == CloudSyncReceivedMutationKind.unsend.index ||
            previous.sentTimestampMs >= row.sentTimestampMs) {
          _fail('predecessor_changed');
        }
      }
    } finally {
      query.close();
    }
  }

  void _requireTargetAuthor(
    Message target,
    api.MessageInst wire,
    CloudSyncReceivedMutationIdentity identity,
    List<String> capturedLocalHandles,
  ) {
    final chat = _store.box<Chat>().get(target.chat.targetId);
    if (chat == null ||
        chat.dateDeleted != null ||
        target.dateDeleted != null ||
        target.verificationFailed ||
        target.isFromMe !=
            (identity.origin == CloudSyncReceivedArchiveOrigin.mirrored)) {
      _fail('target_author_changed');
    }
    if (identity.origin == CloudSyncReceivedArchiveOrigin.incoming) {
      if (target.handleId == null) _fail('target_author_changed');
      final handle = _unique(
        _store.box<Handle>().query(
          Handle_.originalROWID.equals(target.handleId!),
        ),
      );
      if (handle == null ||
          handle.service != 'iMessage' ||
          _bare(wire.sender!) != handle.address) {
        _fail('target_author_changed');
      }
    }
    if (chat.isRpSms || (chat.style != 43 && chat.style != 45)) {
      _fail('target_author_changed');
    }
    if (chat.style == 45) {
      final peers = wire.conversation!.participants
          .where((h) => !capturedLocalHandles.contains(h))
          .map(_bare)
          .toSet();
      if (peers.length != 1 ||
          (chat.chatIdentifier != peers.single &&
              chat.guid != 'iMessage;-;${peers.single}')) {
        _fail('target_author_changed');
      }
    } else {
      final group = wire.conversation!.senderGuid;
      if (group == null ||
          ![
            chat.guid.replaceFirst('iMessage;+;', ''),
            chat.chatIdentifier,
            chat.cloudGuid,
          ].contains(group)) {
        _fail('target_author_changed');
      }
    }
  }

  CloudSyncReceivedMutationSourceBinding _validateRow(
    CloudSyncReceivedMutationIntentEntity row,
    CloudSyncNativeAuthSnapshot auth,
  ) {
    final source = _validateCorrelatedRow(row);
    source.requireOrigin(
      account: auth.accountFingerprint,
      store: auth.protectedStoreIdentity,
      eventGuidHash: row.mutationGuidHash,
      sourceDigest: row.sourceSha256,
    );
    return source;
  }

  CloudSyncReceivedMutationSourceBinding _validateCorrelatedRow(
    CloudSyncReceivedMutationIntentEntity row,
  ) {
    if (row.accountFingerprint != _owner.scope.accountFingerprint ||
        row.ownershipEpoch != _owner.automaticArchiveEpoch) {
      _fail('intent_changed');
    }
    return validateCloudSyncReceivedMutationRow(row);
  }

  CloudSyncReceivedMutationIntentEntity _read(int id) =>
      _store.box<CloudSyncReceivedMutationIntentEntity>().get(id) ??
      (throw StateError('cloud_sync_received_mutation_intent_changed'));

  void _requireCurrent(
    CloudSyncNativeAuthSnapshot auth,
    bool Function() stillCurrent,
  ) {
    final current = _authority.read(_owner.scope);
    if (!stillCurrent() ||
        _owner.scope.accountFingerprint != auth.accountFingerprint ||
        _owner.owner != CloudKitWriterOwner.v2 ||
        _owner.automaticArchiveEpoch <= 0 ||
        current == null ||
        current.owner != CloudKitWriterOwner.v2 ||
        current.automaticArchiveEpoch != _owner.automaticArchiveEpoch) {
      _fail('identity_changed');
    }
  }

  static String intentKey(String account, String hash) =>
      _digest(['cloud-sync-received-mutation-intent-v1', account, hash]);
  static String snapshot(Message m) => cloudSyncMutationTargetSnapshot(m);
}

/// Immutable local correlation only. No raw body/actor, IDS receipt, file lease
/// or native/write permit is exposed. The seed must still be reopened natively.
final class CloudSyncReceivedMutationAdmissionSource {
  CloudSyncReceivedMutationAdmissionSource._(
    CloudSyncReceivedMutationIntentEntity row, {
    required Store store,
    required int writerEpoch,
    required this.protectedStoreIdentity,
    required String validatedTipSnapshotSha256,
  }) : _store = store,
       intentId = row.id,
       intentKey = row.intentKey,
       accountFingerprint = row.accountFingerprint,
       ownershipEpoch = row.ownershipEpoch,
       writerEpoch = row.state >= 2 ? row.admittedWriterEpoch : writerEpoch,
       localMessageId = row.localMessageId,
       localChatId = row.localChatId,
       mutationGuidHash = row.mutationGuidHash,
       targetGuidHash = row.targetGuidHash,
       targetPart = row.targetPart,
       origin = CloudSyncReceivedArchiveOrigin.values[row.origin],
       kind = row.kind,
       sentTimestampMs = row.sentTimestampMs,
       sourceSha256 = row.sourceSha256,
       beforeSnapshotSha256 = row.beforeSnapshotSha256!,
       reflectedSnapshotSha256 = row.reflectedSnapshotSha256!,
       protectedSourceBinding = row.protectedSourceBinding,
       adoptedOperationId = row.admittedOperationId,
       createdAtMs = row.createdAtMs,
       _validatedTipSnapshotSha256 = validatedTipSnapshotSha256,
       _rowBindingSha256 = _adoptionDigest(
         _mutationContext(
           row,
           writerEpoch: row.state >= 2 ? row.admittedWriterEpoch : writerEpoch,
         ),
       );

  final Store _store;
  final String _rowBindingSha256;
  // Transient complete-lineage tip; never replaces this event's stored hashes.
  final String _validatedTipSnapshotSha256;
  final int intentId;
  final String intentKey;
  final String accountFingerprint;
  final String protectedStoreIdentity;
  final int writerEpoch;
  final int ownershipEpoch;
  final int localMessageId;
  final int localChatId;
  final String mutationGuidHash;
  final String targetGuidHash;
  final int targetPart;
  final CloudSyncReceivedArchiveOrigin origin;
  final int kind;
  final int sentTimestampMs;
  final String sourceSha256;
  final String beforeSnapshotSha256;
  final String reflectedSnapshotSha256;
  final String protectedSourceBinding;
  final String? adoptedOperationId;
  final int createdAtMs;

  CloudSyncReceivedMutationSourceBinding decodeProtectedSourceBinding() =>
      CloudSyncReceivedMutationSourceBinding.decode(protectedSourceBinding);

  bool matchesReflectedParent(Message parent) =>
      parent.id == localMessageId &&
      parent.chat.targetId == localChatId &&
      parent.guid != null &&
      _digest(['cloud-sync-received-archive-guid-v1', parent.guid]) ==
          targetGuidHash &&
      parent.isFromMe == (origin == CloudSyncReceivedArchiveOrigin.mirrored) &&
      CloudSyncReceivedMutationJournal.snapshot(parent) ==
          _validatedTipSnapshotSha256;

  bool sameReflectedMutationAs(
    CloudSyncReceivedMutationAdmissionSource other,
  ) =>
      intentId == other.intentId &&
      writerEpoch == other.writerEpoch &&
      _validatedTipSnapshotSha256 == other._validatedTipSnapshotSha256 &&
      _rowBindingSha256 == other._rowBindingSha256;

  CloudSyncMessageMutationPredecessor requirePredecessor({
    required Store store,
    required CloudSyncScope messageScope,
    CloudSyncConfirmedLocalParentReader? readConfirmedLocalParent,
  }) {
    if (!identical(store, _store)) _fail('adoption_store_mismatch');
    final parent = store.box<Message>().get(localMessageId);
    if (parent == null || !matchesReflectedParent(parent)) {
      _fail('reflection_changed');
    }
    return requireCloudSyncReceivedMessageMutationPredecessor(
      store: store,
      messageScope: messageScope,
      localMessageId: localMessageId,
      localChatId: localChatId,
      targetGuidHash: targetGuidHash,
      origin: origin,
      readConfirmedLocalParent: readConfirmedLocalParent,
    );
  }

  bool _matches(CloudSyncReceivedMutationIntentEntity row) =>
      intentId == row.id &&
      _rowBindingSha256 ==
          _adoptionDigest(
            _mutationContext(
              row,
              writerEpoch: row.state >= 2
                  ? row.admittedWriterEpoch
                  : writerEpoch,
            ),
          ) &&
      (adoptedOperationId == null ||
          adoptedOperationId == row.admittedOperationId);

  @override
  String toString() => 'CloudSyncReceivedMutationAdmissionSource(redacted)';
}

List<Object?> _mutationContext(
  CloudSyncReceivedMutationIntentEntity row, {
  required int writerEpoch,
}) => [
  row.intentKey,
  row.accountFingerprint,
  row.ownershipEpoch,
  writerEpoch,
  row.mutationGuidHash,
  row.targetGuidHash,
  row.targetPart,
  row.origin,
  row.kind,
  row.sentTimestampMs,
  row.sourceSha256,
  row.protectedSourceBinding,
  row.localMessageId,
  row.localChatId,
  row.beforeSnapshotSha256,
  row.reflectedSnapshotSha256,
  row.createdAtMs,
];

List<Object?> _mapContext(CloudRecordMapEntity map) => [
  map.mapKey,
  map.scopeKey,
  map.accountFingerprint,
  map.zone,
  map.logicalEntityKeyHash,
  map.serverRecordIdHash,
  map.encryptedServerRecordId,
  map.etagHash,
  map.encryptedRawRecordRef,
  map.generation,
  map.rawRecordGeneration,
];

CloudRecordMapEntry _mapEntry(CloudSyncScope scope, CloudRecordMapEntity map) =>
    CloudRecordMapEntry(
      scope: scope,
      logicalEntityKeyHash: map.logicalEntityKeyHash,
      serverRecordIdHash: map.serverRecordIdHash,
      encryptedServerRecordId: map.encryptedServerRecordId,
      generation: map.generation,
      etagHash: map.etagHash,
      encryptedRawRecordReference: map.encryptedRawRecordRef,
      rawRecordGeneration: map.rawRecordGeneration,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        map.updatedAtMs,
        isUtc: true,
      ),
    );

bool _messageScope(CloudSyncScope scope) =>
    scope.container == 'com.apple.messages.cloud' &&
    scope.database == 'private' &&
    scope.zone == 'messageManateeZone' &&
    scope.streamKind == CloudSyncStreamKind.messages &&
    scope.schemaVersion == cloudSyncSchemaVersion &&
    scope.persistenceLane == CloudSyncPersistenceLane.semantic;

int _advanceTime(CloudSyncReceivedMutationIntentEntity row, DateTime now) {
  if (!now.isUtc || now.millisecondsSinceEpoch <= 0) _fail('time_invalid');
  return now.millisecondsSinceEpoch > row.updatedAtMs
      ? now.millisecondsSinceEpoch
      : row.updatedAtMs + 1;
}

T? _unique<T>(QueryBuilder<T> builder) {
  final query = builder.build();
  try {
    return query.findUnique();
  } finally {
    query.close();
  }
}

String _bare(String h) => h.replaceFirst(RegExp(r'^(mailto:|tel:)'), '');
Object? _canonicalAdoptionValue(Object? value) {
  if (value is List) return value.map(_canonicalAdoptionValue).toList();
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonicalAdoptionValue(value[key])};
  }
  return value;
}

// Existing received intent/GUID byte contracts are unchanged. Shared target
// snapshots have their own v1 encoder; adoption canonicalization is separate.
String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
String _adoptionDigest(Object value) => sha256
    .convert(utf8.encode(jsonEncode(_canonicalAdoptionValue(value))))
    .toString();
final _hash = RegExp(r'^[a-f0-9]{64}$');
final _operationId = RegExp(r'^op1:[a-f0-9]{64}$');
final _nativeDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _reference = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
final _lease = RegExp(r'^obcs2\.lease\.[A-Za-z0-9_-]{32}$');
Never _fail(String code) =>
    throw StateError('cloud_sync_received_mutation_$code');
