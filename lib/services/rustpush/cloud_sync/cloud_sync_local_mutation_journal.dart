import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

import 'cloud_sync_local_mutation_identity.dart';
import 'cloud_sync_local_mutation_projection.dart';
import 'cloud_sync_local_mutation_source_binding.dart';
import 'cloud_operation_identity.dart';
import 'cloud_sync_local_send_journal.dart'
    show CloudSyncNativeReceiptReplayBinding;
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Retains edits/unsends without treating them as initial message creates.
/// Network and native keystore work stay outside ObjectBox transactions.
/// The source lease must be committed under the protected-store exclusion
/// after adoption and before claiming submission. This journal never sends,
/// acknowledges a native receipt, releases protected data or writes CloudKit.
final class CloudSyncLocalMutationJournal {
  CloudSyncLocalMutationJournal({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot authoritySnapshot,
  }) : _store = store,
       _authority = authority,
       _owner = authoritySnapshot {
    if (!authority.isBoundToStore(store)) _fail('authority_store_mismatch');
  }

  final Store _store;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterAuthoritySnapshot _owner;
  Box<CloudSyncLocalMutationIntentEntity> get _rows =>
      _store.box<CloudSyncLocalMutationIntentEntity>();

  bool isBoundToStore(Store store) => identical(store, _store);

  /// Capture before any asynchronous staging. Its digest covers the exact
  /// existing local body/history and route, not just a mutable message row ID.
  String captureTargetSnapshot({
    required int localMessageId,
    required CloudSyncLocalMutationIdentity identity,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireOwner();
    final target = _target(localMessageId, identity.targetGuidHash);
    _requireRoute(target, identity);
    return _snapshot(target);
  });

  /// Reuse only this unclaimed intent's original source after interrupted
  /// preparation. A claimed/confirmed intent can never enter submission again.
  ({int intentId, CloudSyncLocalMutationSourceBinding source})?
  readStagedSource({
    required int localMessageId,
    required CloudSyncLocalMutationIdentity identity,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireOwner();
    final existing = _findByGuid(identity.guidHash);
    if (existing == null) return null;
    final row = _read(existing.id, originalEpoch: true);
    final source = validateCloudSyncMutationRow(row);
    _requireAuth(source, currentAuth, stillCurrent);
    source.requireOrigin(
      accountFingerprint: _owner.scope.accountFingerprint,
      mutationGuidHash: identity.guidHash,
      targetGuidHash: identity.targetGuidHash,
      targetPart: identity.targetPart,
      sourceSha256: identity.sourceSha256,
    );
    if (row.state != 0) _fail('already_claimed');
    if (row.localMessageId != localMessageId ||
        row.kind != identity.kind.index) {
      _fail('intent_changed');
    }
    final target = _target(
      localMessageId,
      identity.targetGuidHash,
      row.localChatId,
    );
    _requireRoute(target, identity);
    if (_snapshot(target) != row.targetSnapshotSha256) _fail('target_changed');
    return (intentId: row.id, source: source);
  });

  /// Called by both live callbacks and cold receipt replay. Keep the native
  /// receipt until conditional-write readback, not merely local confirmation.
  bool recordNativeReceiptIfTracked({
    required api.CloudSyncNativeSendReceipt receipt,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireOwner();
    if (receipt.sourceBinding?.kind !=
        api.CloudSyncNativeSendSourceKind.mutation) {
      return false;
    }
    final row = _findByGuid(receipt.guidHash);
    if (row == null) return false;
    recordNativeReceipt(
      intentId: row.id,
      receipt: receipt,
      capturedAuth: capturedAuth,
      stillCurrent: stillCurrent,
      now: now,
      replayBinding: replayBinding,
    );
    return true;
  });

  CloudSyncLocalMutationIntentEntity? _findByGuid(String guidHash) {
    final query = _rows
        .query(
          CloudSyncLocalMutationIntentEntity_.intentKey.equals(
            _intentKey(_owner.scope.accountFingerprint, guidHash),
          ),
        )
        .build();
    try {
      return query.findUnique();
    } finally {
      query.close();
    }
  }

  int adoptSource({
    required int localMessageId,
    required CloudSyncLocalMutationIdentity identity,
    required String targetSnapshotSha256,
    required CloudSyncLocalMutationSourceBinding source,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireOwner();
    _requireAuth(source, capturedAuth, stillCurrent);
    source.requireOrigin(
      accountFingerprint: _owner.scope.accountFingerprint,
      mutationGuidHash: identity.guidHash,
      targetGuidHash: identity.targetGuidHash,
      targetPart: identity.targetPart,
      sourceSha256: identity.sourceSha256,
    );
    final target = _target(localMessageId, identity.targetGuidHash);
    _requireRoute(target, identity);
    final key = _intentKey(_owner.scope.accountFingerprint, identity.guidHash);
    final query = _rows
        .query(CloudSyncLocalMutationIntentEntity_.intentKey.equals(key))
        .build();
    final CloudSyncLocalMutationIntentEntity? existing;
    try {
      existing = query.findUnique();
    } finally {
      query.close();
    }
    final time = _time(now);
    if (existing != null) {
      final old = _read(existing.id, originalEpoch: true);
      if (old.localMessageId != localMessageId ||
          old.localChatId != target.chat.targetId ||
          old.kind != identity.kind.index ||
          old.targetSnapshotSha256 != targetSnapshotSha256 ||
          old.protectedSourceBinding != source.encode()) {
        _fail('intent_changed');
      }
      // Duplicate adoption is bookkeeping, never permission to send again.
      return old.id;
    }
    if (_snapshot(target) != targetSnapshotSha256) _fail('target_changed');
    return _rows.put(
      CloudSyncLocalMutationIntentEntity(
        intentKey: key,
        accountFingerprint: _owner.scope.accountFingerprint,
        writerEpoch: _owner.epoch,
        localMessageId: localMessageId,
        localChatId: target.chat.targetId,
        mutationGuidHash: identity.guidHash,
        targetGuidHash: identity.targetGuidHash,
        targetPart: identity.targetPart,
        kind: identity.kind.index,
        sourceSha256: identity.sourceSha256,
        targetSnapshotSha256: targetSnapshotSha256,
        protectedSourceBinding: source.encode(),
        createdAtMs: time,
        updatedAtMs: time,
      ),
    );
  });

  /// Claim exactly once, after the native committed source was reopened and
  /// validated by the staging adapter. Interruption after this transaction
  /// leaves an unknown result, not an automatically retryable intent.
  void beginSubmission({
    required int intentId,
    required CloudSyncLocalMutationSourceBinding committedSource,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireOwner();
    final row = _read(intentId, originalEpoch: true);
    _requireAuth(committedSource, capturedAuth, stillCurrent);
    if (row.protectedSourceBinding != committedSource.encode()) {
      _fail('source_changed');
    }
    if (row.state != 0) _fail('already_claimed');
    if (_snapshot(
          _target(row.localMessageId, row.targetGuidHash, row.localChatId),
        ) !=
        row.targetSnapshotSha256) {
      _fail('target_changed');
    }
    row
      ..state = 1
      ..submissionAuthBindingSha256 = _authHash(
        capturedAuth.accountFingerprint,
        capturedAuth.protectedStoreIdentity,
        capturedAuth.nativeSessionId,
      )
      ..updatedAtMs = _advanceTime(row, now);
    _rows.put(row);
  });

  /// Final local check after asynchronous preparation, immediately before IDS.
  /// This validates an already-claimed operation and cannot claim it again.
  void requireClaimedSubmission({
    required int intentId,
    required CloudSyncLocalMutationSourceBinding committedSource,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireOwner();
    final row = _read(intentId, originalEpoch: true);
    _requireAuth(committedSource, capturedAuth, stillCurrent);
    if (row.state != 1 ||
        row.protectedSourceBinding != committedSource.encode() ||
        row.submissionAuthBindingSha256 !=
            _authHash(
              capturedAuth.accountFingerprint,
              capturedAuth.protectedStoreIdentity,
              capturedAuth.nativeSessionId,
            )) {
      _fail('submission_changed');
    }
    if (_snapshot(
          _target(row.localMessageId, row.targetGuidHash, row.localChatId),
        ) !=
        row.targetSnapshotSha256) {
      _fail('target_changed');
    }
  });

  /// Only the native positive-participant-acceptance receipt can promote a
  /// claimed intent. A cold replay must carry the existing runtime/auth fence;
  /// it cannot merely disable the native session check with a boolean flag.
  void recordNativeReceipt({
    required int intentId,
    required api.CloudSyncNativeSendReceipt receipt,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireOwner();
    final row = _read(intentId);
    final source = validateCloudSyncMutationRow(row);
    _requireAuth(source, capturedAuth, stillCurrent);
    final proof = _receiptProof(
      row,
      source,
      receipt,
      capturedAuth,
      replayBinding,
    );
    if (row.idsReceiptBindingSha256 != null) {
      if (row.idsReceiptBindingSha256 != proof) _fail('receipt_changed');
      return;
    }
    row
      ..idsReceiptBindingSha256 = proof
      ..state = 2
      ..updatedAtMs = _advanceTime(row, now);
    _rows.put(row);
  });

  String _receiptProof(
    CloudSyncLocalMutationIntentEntity row,
    CloudSyncLocalMutationSourceBinding source,
    api.CloudSyncNativeSendReceipt receipt,
    CloudSyncNativeAuthSnapshot capturedAuth,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
  ) {
    if (replayBinding == null) {
      if (receipt.nativeSessionId != capturedAuth.nativeSessionId) {
        _fail('receipt_session_changed');
      }
    } else {
      replayBinding.requireCapturedAuth(capturedAuth);
    }
    final native = receipt.sourceBinding;
    if (row.state == 0 ||
        receipt.guidHash != row.mutationGuidHash ||
        !_receiptId.hasMatch(receipt.receiptId) ||
        receipt.nativeSessionId.isEmpty ||
        row.submissionAuthBindingSha256 !=
            _authHash(
              source.accountFingerprint,
              source.protectedStoreIdentity,
              receipt.nativeSessionId,
            ) ||
        native == null ||
        native.kind != api.CloudSyncNativeSendSourceKind.mutation ||
        native.sourceSha256 != source.sourceSha256 ||
        native.protectedReference != source.protectedReference ||
        native.leaseReference != source.leaseReference ||
        native.payloadSha256 != source.payloadSha256 ||
        native.payloadLength != BigInt.from(source.payloadLength)) {
      _fail('receipt_changed');
    }
    final preparedTime = receipt.preparedSentTimestampMs;
    if (preparedTime != null &&
        (preparedTime <= BigInt.zero ||
            preparedTime > BigInt.parse('9223372036854775807'))) {
      _fail('receipt_time_invalid');
    }
    // Historical receipts keep the old proof unchanged. They prove acceptance,
    // but cannot supply a time for local reflection. Never upgrade them in place.
    return _digest([
      preparedTime == null
          ? 'cloud-sync-mutation-ids-receipt-v1'
          : 'cloud-sync-mutation-ids-receipt-v2',
      source.accountFingerprint,
      source.protectedStoreIdentity,
      receipt.receiptId,
      receipt.nativeSessionId,
      source.encode(),
      if (preparedTime != null) preparedTime.toString(),
    ]);
  }

  /// Project only a reopened committed source and the exact accepted receipt.
  /// Neither callback time nor a new wire is authority to alter the target.
  void reflectSourceConfirmed({
    required int intentId,
    required CloudSyncLocalMutationSourceBinding committedSource,
    required api.MessageInst original,
    required api.CloudSyncNativeSendReceipt receipt,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required DateTime now,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireOwner();
    final row = _read(intentId);
    if (row.protectedSourceBinding != committedSource.encode()) {
      _fail('source_changed');
    }
    final identity = CloudSyncLocalMutationIdentity.captureWire(
      original,
      expectedSourceSha256: committedSource.sourceSha256,
    );
    if (identity == null || identity.kind.index != row.kind) {
      _fail('source_changed');
    }
    committedSource.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      mutationGuidHash: identity.guidHash,
      targetGuidHash: identity.targetGuidHash,
      targetPart: identity.targetPart,
      sourceSha256: identity.sourceSha256,
    );
    reflectConfirmed(
      intentId: intentId,
      receipt: receipt,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
      now: now,
      replayBinding: replayBinding,
      project: (target, preparedTime) {
        _requireRoute(target, identity);
        final projection = CloudSyncLocalMutationProjection.projectFirst(
          target: target,
          wire: original,
          source: committedSource,
          preparedSentTimestampMs: preparedTime,
        );
        return target
          ..text = projection.text
          ..attributedBody = projection.attributedBody
          ..messageSummaryInfo = projection.messageSummaryInfo
          ..dateEdited = projection.dateEdited;
      },
    );
  });

  /// The caller prepares the exact protected mutation outside this transaction.
  /// Commit its local projection only while the original target snapshot still
  /// matches. A newer local/remote edit is retained, never silently overwritten.
  /// Duplicate replay after state 3 does not call the projector again.
  void reflectConfirmed({
    required int intentId,
    required api.CloudSyncNativeSendReceipt receipt,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required Message Function(Message target, int preparedSentTimestampMs)
    project,
    required DateTime now,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireOwner();
    final row = _read(intentId);
    final source = validateCloudSyncMutationRow(row);
    _requireAuth(source, currentAuth, stillCurrent);
    if (row.state < 2) _fail('ids_unconfirmed');
    if (_receiptProof(row, source, receipt, currentAuth, replayBinding) !=
        row.idsReceiptBindingSha256) {
      _fail('receipt_changed');
    }
    final preparedTime = receipt.preparedSentTimestampMs;
    // Dart DateTime has a tighter range than native u64/i64. Keep an accepted
    // but unprojectable receipt, instead of substituting now or the source's 0.
    if (preparedTime == null || preparedTime > BigInt.from(8640000000000000)) {
      _fail('receipt_time_unavailable');
    }
    if (row.state >= 3) return;
    final target = _target(
      row.localMessageId,
      row.targetGuidHash,
      row.localChatId,
    );
    if (_snapshot(target) != row.targetSnapshotSha256) _fail('target_changed');
    final route = _digest(_routingData(target));
    final updated = project(target, preparedTime.toInt());
    if (updated.id != row.localMessageId ||
        updated.chat.targetId != row.localChatId ||
        updated.guid == null ||
        _guidHash(updated.guid!) != row.targetGuidHash ||
        updated.isFromMe != true ||
        updated.verificationFailed ||
        updated.dateScheduled != null ||
        _digest(_routingData(updated)) != route) {
      _fail('reflection_target_changed');
    }
    final after = _snapshot(updated);
    if (after == row.targetSnapshotSha256) _fail('reflection_unchanged');
    _store.box<Message>().put(updated);
    if (!stillCurrent()) _fail('auth_changed');
    _requireOwner();
    row
      ..state = 3
      ..reflectedSnapshotSha256 = after
      ..updatedAtMs = _advanceTime(row, now);
    _rows.put(row);
  });

  /// Captures the exact reflected mutation that may be staged as one
  /// conditional CloudKit update. The returned value is immutable evidence,
  /// not permission to send or to follow a newer record mapping.
  CloudSyncLocalMutationAdmissionSource readReflectedForUpdate({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireOwner();
    final row = _read(intentId, originalEpoch: true);
    final source = validateCloudSyncMutationRow(row);
    _requireAuth(source, currentAuth, stillCurrent);
    if ((row.state != 3 && row.state != 4) || row.targetPart != 0) {
      _fail('update_not_ready');
    }
    if (row.submissionAuthBindingSha256 !=
        _authHash(
          currentAuth.accountFingerprint,
          currentAuth.protectedStoreIdentity,
          currentAuth.nativeSessionId,
        )) {
      _fail('auth_changed');
    }
    final target = _target(
      row.localMessageId,
      row.targetGuidHash,
      row.localChatId,
    );
    if (_snapshot(target) != row.reflectedSnapshotSha256) {
      _fail('reflection_changed');
    }
    return CloudSyncLocalMutationAdmissionSource._(row);
  });

  /// Returns the already-adopted operation while executing in the caller's
  /// exact ObjectBox transaction. A non-null result is recovery evidence only;
  /// [adoptInOutboxTransaction] must still validate the operation and map.
  String? adoptedOperationIdInOutboxTransaction(
    Store transactionStore,
    CloudSyncLocalMutationAdmissionSource expected, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) {
    final row = _requireUpdateSource(
      transactionStore,
      expected,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    return row.state == 4 ? row.admittedOperationId : null;
  }

  /// Atomically consumes one reflected IDS receipt into one immutable
  /// conditional-update outbox row. This method is synchronous by design and
  /// must be called from the same Store write transaction that inserts the
  /// [operation]. It performs no network or protected-store work.
  void adoptInOutboxTransaction(
    Store transactionStore,
    CloudSyncLocalMutationAdmissionSource expected,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) {
    final row = _requireUpdateSource(
      transactionStore,
      expected,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    _requireUpdateOperation(row, operation, predecessor);
    final binding = _updateAdoptionBinding(row, operation, predecessor);
    if (row.state == 4) {
      if (row.admittedOperationId != operation.operationId ||
          row.admittedBindingSha256 != binding) {
        _fail('adoption_changed');
      }
      return;
    }
    if (row.admittedOperationId != null || row.admittedBindingSha256 != null) {
      _fail('row_corrupt');
    }
    if (!stillCurrent()) _fail('auth_changed');
    _requireOwner();
    row
      ..state = 4
      ..admittedOperationId = operation.operationId
      ..admittedBindingSha256 = binding
      ..updatedAtMs = _advanceTime(row, now);
    _rows.put(row);
  }

  /// Revalidates the durable journal/outbox/map triangle immediately before
  /// leasing or submission. Mutable lease, retry and receipt state is ignored;
  /// every immutable field remains covered by the adoption binding.
  void validateAdoptedOperation(
    Store transactionStore,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor,
  ) {
    if (!identical(transactionStore, _store)) {
      _fail('adoption_store_mismatch');
    }
    _requireOwner();
    final query = _rows
        .query(
          CloudSyncLocalMutationIntentEntity_.admittedOperationId.equals(
            operation.operationId,
          ),
        )
        .build();
    final CloudSyncLocalMutationIntentEntity? row;
    try {
      row = query.findUnique();
    } finally {
      query.close();
    }
    if (row == null) _fail('adoption_missing');
    validateCloudSyncMutationRow(row);
    if (row.state != 4 ||
        row.accountFingerprint != _owner.scope.accountFingerprint ||
        row.writerEpoch != _owner.epoch) {
      _fail('adoption_changed');
    }
    final target = _target(
      row.localMessageId,
      row.targetGuidHash,
      row.localChatId,
    );
    if (_snapshot(target) != row.reflectedSnapshotSha256) {
      _fail('reflection_changed');
    }
    _requireUpdateOperation(row, operation, predecessor);
    if (row.admittedBindingSha256 !=
        _updateAdoptionBinding(row, operation, predecessor)) {
      _fail('adoption_changed');
    }
  }

  CloudSyncLocalMutationIntentEntity _requireUpdateSource(
    Store transactionStore,
    CloudSyncLocalMutationAdmissionSource expected, {
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) {
    if (!identical(transactionStore, _store)) {
      _fail('adoption_store_mismatch');
    }
    _requireOwner();
    final row = _read(expected.intentId, originalEpoch: true);
    final source = validateCloudSyncMutationRow(row);
    _requireAuth(source, currentAuth, stillCurrent);
    if (!expected._matches(row) ||
        (row.state != 3 && row.state != 4) ||
        row.targetPart != 0 ||
        row.submissionAuthBindingSha256 !=
            _authHash(
              currentAuth.accountFingerprint,
              currentAuth.protectedStoreIdentity,
              currentAuth.nativeSessionId,
            )) {
      _fail('adoption_changed');
    }
    final target = _target(
      row.localMessageId,
      row.targetGuidHash,
      row.localChatId,
    );
    if (_snapshot(target) != row.reflectedSnapshotSha256) {
      _fail('reflection_changed');
    }
    return row;
  }

  void _requireUpdateOperation(
    CloudSyncLocalMutationIntentEntity row,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor,
  ) {
    final scope = operation.scope;
    if (scope.accountFingerprint != row.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2 ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncMessageUpdatePayloadVersion ||
        operation.mutationRevision <= 0 ||
        operation.checkpointGeneration <= 0 ||
        operation.dependencyOperationIds.isNotEmpty ||
        operation.encryptedPayloadReference == null ||
        !_protectedReference.hasMatch(operation.encryptedPayloadReference!) ||
        operation.payloadSha256 == null ||
        !_hash.hasMatch(operation.payloadSha256!) ||
        operation.serverRecordIdHash == null ||
        !_nativeDigest.hasMatch(operation.logicalEntityKeyHash) ||
        !_nativeDigest.hasMatch(operation.serverRecordIdHash!) ||
        operation.protectedLeaseReference == null ||
        !_protectedLease.hasMatch(operation.protectedLeaseReference!) ||
        !operation.createdAt.isUtc ||
        operation.createdAt.millisecondsSinceEpoch <= 0 ||
        operation.operationId !=
            CloudOperationIdentity.forMutation(
              scope: scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              action: operation.action,
              payloadVersion: operation.payloadVersion,
              mutationRevision: operation.mutationRevision,
              payloadSha256: operation.payloadSha256,
            ) ||
        predecessor.mapKey !=
            cloudSyncCanonicalRecordMapKey(
              scope,
              operation.logicalEntityKeyHash,
            ) ||
        predecessor.scopeKey != cloudSyncPersistentScopeKey(scope) ||
        predecessor.accountFingerprint != scope.accountFingerprint ||
        predecessor.zone != scope.zone ||
        predecessor.generation != operation.checkpointGeneration ||
        predecessor.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
        predecessor.serverRecordIdHash != operation.serverRecordIdHash ||
        !_protectedReference.hasMatch(predecessor.encryptedServerRecordId) ||
        predecessor.etagHash == null ||
        !_nativeDigest.hasMatch(predecessor.etagHash!) ||
        predecessor.encryptedRawRecordRef == null ||
        !_protectedReference.hasMatch(predecessor.encryptedRawRecordRef!) ||
        (row.state == 3 &&
            (operation.status != CloudOutboxStatus.pending ||
                operation.attemptCount != 0 ||
                operation.nextEligibleAt != null ||
                operation.lastFailure != null ||
                operation.leaseId != null ||
                operation.leaseExpiresAt != null ||
                operation.confirmedAt != null ||
                operation.appleRequestUuid != null ||
                operation.appleOperationUuid != null))) {
      _fail('adoption_operation_invalid');
    }
  }

  String _updateAdoptionBinding(
    CloudSyncLocalMutationIntentEntity row,
    CloudOutboxOperation operation,
    CloudRecordMapEntity predecessor,
  ) => _digest([
    'cloud-sync-local-mutation-update-adoption-v1',
    row.intentKey,
    row.idsReceiptBindingSha256,
    row.reflectedSnapshotSha256,
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
    predecessor.mapKey,
    predecessor.scopeKey,
    predecessor.accountFingerprint,
    predecessor.zone,
    predecessor.logicalEntityKeyHash,
    predecessor.serverRecordIdHash,
    predecessor.encryptedServerRecordId,
    predecessor.etagHash,
    predecessor.encryptedRawRecordRef,
    predecessor.generation,
  ]);

  /// Read-only reconciliation inventory. Neither staged nor claimed intents
  /// are returned as confirmed. Old epochs retain evidence but grant no send.
  List<CloudSyncLocalMutationIntentEntity> readConfirmed({int limit = 50}) =>
      _store.runInTransaction(TxMode.read, () {
        _requireOwner();
        if (limit < 1 || limit > 50) _fail('limit_invalid');
        final query =
            _rows
                .query(
                  CloudSyncLocalMutationIntentEntity_.accountFingerprint
                      .equals(_owner.scope.accountFingerprint)
                      .and(CloudSyncLocalMutationIntentEntity_.state.equals(2)),
                )
                .order(CloudSyncLocalMutationIntentEntity_.id)
                .build()
              ..limit = limit;
        try {
          return query
              .find()
              .map((row) => _read(row.id))
              .toList(growable: false);
        } finally {
          query.close();
        }
      });

  CloudSyncLocalMutationIntentEntity _read(
    int id, {
    bool originalEpoch = false,
  }) {
    final row = _rows.get(id);
    if (row == null) _fail('intent_missing');
    validateCloudSyncMutationRow(row);
    if (row.accountFingerprint != _owner.scope.accountFingerprint ||
        row.writerEpoch > _owner.epoch ||
        (originalEpoch && row.writerEpoch != _owner.epoch)) {
      _fail('owner_changed');
    }
    return row;
  }

  void _requireRoute(Message target, CloudSyncLocalMutationIdentity identity) {
    final chat = target.chat.target!;
    if (chat.isRoutingStub ||
        chat.usingHandle?.isNotEmpty != true ||
        (chat.style != 45 && chat.style != 43) ||
        chat.handles.isEmpty ||
        chat.handles.any((h) => h.service != 'iMessage') ||
        !identity.matchesRoute(
          sender: chat.usingHandle!,
          chatGuid: chat.guid,
          participants: chat.handles
              .map(
                (h) =>
                    '${h.address.contains('@') ? 'mailto' : 'tel'}:${h.address}',
              )
              .toList(growable: false),
        )) {
      _fail('route_changed');
    }
  }

  Message _target(int id, String guidHash, [int? chatId]) {
    final target = id > 0 ? _store.box<Message>().get(id) : null;
    if (target == null ||
        target.guid == null ||
        _guidHash(target.guid!) != guidHash ||
        target.isFromMe != true ||
        target.verificationFailed ||
        target.temp ||
        target.error != 0 ||
        target.dateDeleted != null ||
        target.dateScheduled != null ||
        target.chat.targetId <= 0 ||
        (chatId != null && target.chat.targetId != chatId) ||
        target.chat.target == null ||
        target.chat.target!.isRpSms ||
        target.chat.target!.isRoutingStub) {
      _fail('target_changed');
    }
    return target;
  }

  void _requireOwner() {
    if (_owner.owner != CloudKitWriterOwner.v2 ||
        _owner.epoch <= 0 ||
        _owner.scope.container != 'com.apple.messages.cloud' ||
        _owner.scope.database != 'private') {
      _fail('owner_invalid');
    }
    final current = _authority.read(_owner.scope);
    if (current == null ||
        current.owner != _owner.owner ||
        current.epoch != _owner.epoch) {
      _fail('owner_changed');
    }
    // Journaling creates no remote write permit, including when uploads are fenced.
  }

  void _requireAuth(
    CloudSyncLocalMutationSourceBinding source,
    CloudSyncNativeAuthSnapshot auth,
    bool Function() stillCurrent,
  ) {
    if (!stillCurrent() ||
        auth.accountFingerprint != _owner.scope.accountFingerprint ||
        source.accountFingerprint != auth.accountFingerprint ||
        source.protectedStoreIdentity != auth.protectedStoreIdentity) {
      _fail('auth_changed');
    }
  }

  @override
  String toString() => 'CloudSyncLocalMutationJournal(redacted)';
}

/// Immutable bridge from a reflected mutation receipt to one outbox adoption.
/// It contains only local identifiers, one-way digests and protected refs.
final class CloudSyncLocalMutationAdmissionSource {
  CloudSyncLocalMutationAdmissionSource._(
    CloudSyncLocalMutationIntentEntity row,
  ) : intentId = row.id,
      intentKey = row.intentKey,
      accountFingerprint = row.accountFingerprint,
      writerEpoch = row.writerEpoch,
      localMessageId = row.localMessageId,
      localChatId = row.localChatId,
      mutationGuidHash = row.mutationGuidHash,
      targetGuidHash = row.targetGuidHash,
      targetPart = row.targetPart,
      kind = row.kind,
      sourceSha256 = row.sourceSha256,
      targetSnapshotSha256 = row.targetSnapshotSha256,
      protectedSourceBinding = row.protectedSourceBinding,
      submissionAuthBindingSha256 = row.submissionAuthBindingSha256!,
      idsReceiptBindingSha256 = row.idsReceiptBindingSha256!,
      reflectedSnapshotSha256 = row.reflectedSnapshotSha256!,
      createdAtMs = row.createdAtMs;

  final int intentId;
  final String intentKey;
  final String accountFingerprint;
  final int writerEpoch;
  final int localMessageId;
  final int localChatId;
  final String mutationGuidHash;
  final String targetGuidHash;
  final int targetPart;
  final int kind;
  final String sourceSha256;
  final String targetSnapshotSha256;
  final String protectedSourceBinding;
  final String submissionAuthBindingSha256;
  final String idsReceiptBindingSha256;
  final String reflectedSnapshotSha256;
  final int createdAtMs;

  bool _matches(CloudSyncLocalMutationIntentEntity row) =>
      intentId == row.id &&
      intentKey == row.intentKey &&
      accountFingerprint == row.accountFingerprint &&
      writerEpoch == row.writerEpoch &&
      localMessageId == row.localMessageId &&
      localChatId == row.localChatId &&
      mutationGuidHash == row.mutationGuidHash &&
      targetGuidHash == row.targetGuidHash &&
      targetPart == row.targetPart &&
      kind == row.kind &&
      sourceSha256 == row.sourceSha256 &&
      targetSnapshotSha256 == row.targetSnapshotSha256 &&
      protectedSourceBinding == row.protectedSourceBinding &&
      submissionAuthBindingSha256 == row.submissionAuthBindingSha256 &&
      idsReceiptBindingSha256 == row.idsReceiptBindingSha256 &&
      reflectedSnapshotSha256 == row.reflectedSnapshotSha256 &&
      createdAtMs == row.createdAtMs;

  @override
  String toString() => 'CloudSyncLocalMutationAdmissionSource(redacted)';
}

/// Shared by journal and *both* native GC roots. Every retained row, account and
/// state owns its original source/lease, even after local reflection. No generic
/// terminal flag is permission to reclaim the bytes or native acceptance receipt.
CloudSyncLocalMutationSourceBinding validateCloudSyncMutationRow(
  CloudSyncLocalMutationIntentEntity row,
) {
  if (row.id <= 0 ||
      row.writerEpoch <= 0 ||
      row.localMessageId <= 0 ||
      row.localChatId <= 0 ||
      row.kind < 0 ||
      row.kind > 1 ||
      row.state < 0 ||
      row.state > 4 ||
      row.createdAtMs <= 0 ||
      row.updatedAtMs < row.createdAtMs ||
      !_hash.hasMatch(row.targetSnapshotSha256) ||
      row.intentKey !=
          _intentKey(row.accountFingerprint, row.mutationGuidHash) ||
      ((row.state == 0) != (row.submissionAuthBindingSha256 == null)) ||
      (row.submissionAuthBindingSha256 != null &&
          !_hash.hasMatch(row.submissionAuthBindingSha256!)) ||
      ((row.state < 2) != (row.idsReceiptBindingSha256 == null)) ||
      (row.idsReceiptBindingSha256 != null &&
          !_hash.hasMatch(row.idsReceiptBindingSha256!)) ||
      ((row.state < 3) != (row.reflectedSnapshotSha256 == null)) ||
      (row.reflectedSnapshotSha256 != null &&
          !_hash.hasMatch(row.reflectedSnapshotSha256!)) ||
      ((row.state < 4) != (row.admittedOperationId == null)) ||
      ((row.state < 4) != (row.admittedBindingSha256 == null)) ||
      (row.admittedOperationId != null &&
          !_operationId.hasMatch(row.admittedOperationId!)) ||
      (row.admittedBindingSha256 != null &&
          !_hash.hasMatch(row.admittedBindingSha256!))) {
    _fail('row_corrupt');
  }
  final source = CloudSyncLocalMutationSourceBinding.decode(
    row.protectedSourceBinding,
  );
  source.requireOrigin(
    accountFingerprint: row.accountFingerprint,
    mutationGuidHash: row.mutationGuidHash,
    targetGuidHash: row.targetGuidHash,
    targetPart: row.targetPart,
    sourceSha256: row.sourceSha256,
  );
  return source;
}

String _snapshot(Message target) {
  final chat = target.chat.target;
  if (chat == null) _fail('target_changed');
  return _digest([
    'cloud-sync-mutation-target-v1',
    target.id,
    target.guid,
    target.chat.targetId,
    target.isFromMe,
    target.dateCreated?.millisecondsSinceEpoch,
    target.dateEdited?.millisecondsSinceEpoch,
    target.dateDeleted?.millisecondsSinceEpoch,
    target.text,
    target.subject,
    target.attributedBody.map((part) => part.toMap()).toList(),
    target.messageSummaryInfo.map((info) => info.toJson()).toList(),
    target.dbAttachments
        .map((attachment) => [attachment.id, attachment.guid])
        .toList(),
    ..._routingData(target),
  ]);
}

List<Object?> _routingData(Message target) {
  final chat = target.chat.target;
  if (chat == null) _fail('target_changed');
  return [
    chat.guid,
    chat.chatIdentifier,
    chat.usingHandle,
    chat.style,
    chat.isRpSms,
    chat.handles.map((handle) => [handle.address, handle.service]).toList(),
  ];
}

// ObjectBox JSON map iteration order is not semantic. Canonicalize nested maps
// while preserving list order and exact text/UUID spellings in the digest.
Object? _canonical(Object? value) {
  if (value is List) return value.map(_canonical).toList();
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  return value;
}

String _digest(List<Object?> value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
String _guidHash(String value) =>
    _digest(['cloud-sync-local-send-guid-v1', value]);
String _intentKey(String account, String guid) =>
    _digest(['cloud-sync-local-mutation-intent-v1', account, guid]);
String _authHash(String account, String store, String session) => _digest([
  'cloud-sync-mutation-submission-auth-v1',
  account,
  store,
  session,
]);
final _hash = RegExp(r'^[a-f0-9]{64}$');
final _receiptId = RegExp(r'^obcs2\.ids\.[A-Za-z0-9_-]{43}$');
final _operationId = RegExp(r'^op1:[a-f0-9]{64}$');
final _nativeDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _protectedReference = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
final _protectedLease = RegExp(r'^obcs2\.lease\.[a-f0-9]{32}$');
int _time(DateTime now) {
  if (!now.isUtc || now.millisecondsSinceEpoch <= 0) _fail('time_invalid');
  return now.millisecondsSinceEpoch;
}

int _advanceTime(CloudSyncLocalMutationIntentEntity row, DateTime now) {
  final time = _time(now);
  return time < row.updatedAtMs ? row.updatedAtMs : time;
}

Never _fail(String code) => throw StateError('cloud_sync_local_mutation_$code');
