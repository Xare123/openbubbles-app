import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_operation_identity.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloud_sync_persistent_keys.dart';

/// Byte-upload progress, deliberately not a CloudKit record-save status.
/// Persisted codes are stable. There is no automatic unknown -> prepared edge.
enum CloudAttachmentUploadState {
  prepared,
  started,
  uploaded,
  adopted,
  unknown,
}

final class CloudAttachmentUploadSnapshot {
  CloudAttachmentUploadSnapshot._(CloudAttachmentUploadEntity row)
    : id = row.id,
      uploadKey = row.uploadKey,
      localSendIntentId = row.localSendIntentId,
      state = CloudAttachmentUploadState.values[row.state],
      attemptId = row.attemptId,
      admittedOperationId = row.admittedOperationId,
      plan = _plan(row),
      result = row.resultReference == null ? null : _result(row);

  final int id;
  final String uploadKey;
  final int localSendIntentId;
  final CloudAttachmentUploadState state;
  final String? attemptId;
  final String? admittedOperationId;
  final CloudSyncProtectedOutboundStageData plan;
  final CloudSyncProtectedOutboundStageData? result;
}

/// Owns original preparation and completed-upload envelopes independently of
/// the immutable final-save outbox. Only content-free bindings enter ObjectBox.
///
/// Caller holds the CloudKit interlock and native protected-store exclusion
/// through stage/adopt/commit, and revalidates native auth around awaits. A
/// successful beginAttempt must be durable BEFORE consuming the native upload
/// owner. A started row surviving process death is ambiguous, never retryable
/// merely because its eventual attachment record is absent.
final class CloudSyncAttachmentUploadJournal {
  CloudSyncAttachmentUploadJournal({
    required Store store,
    required CloudSyncLocalSendJournal localSends,
    required CloudSyncScope scope,
    required int checkpointGeneration,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) : _store = store,
       _localSends = localSends,
       _scope = scope,
       _generation = checkpointGeneration,
       _auth = currentAuth {
    if (!localSends.isBoundToStore(store) ||
        scope.accountFingerprint != currentAuth.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'attachmentManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        scope.schemaVersion != 2 ||
        checkpointGeneration <= 0) {
      throw StateError('cloud_sync_attachment_upload_scope_invalid');
    }
  }

  final Store _store;
  final CloudSyncLocalSendJournal _localSends;
  final CloudSyncScope _scope;
  final int _generation;
  final CloudSyncNativeAuthSnapshot _auth;
  Box<CloudAttachmentUploadEntity> get _uploads =>
      _store.box<CloudAttachmentUploadEntity>();

  bool isBoundTo(Store store, CloudSyncScope scope) =>
      identical(_store, store) && _scope == scope;

  /// Revalidate the completed upload and original IDS source at dispatch, not
  /// just admission. Called synchronously within the outbox store transaction.
  void requireAdoptedOperation(CloudOutboxOperation operation) {
    if (operation.scope != _scope ||
        operation.checkpointGeneration != _generation) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.admittedOperationId.equals(
            operation.operationId,
          ),
        )
        .build();
    final CloudAttachmentUploadEntity? candidate;
    try {
      candidate = query.findUnique();
    } finally {
      query.close();
    }
    if (candidate == null) {
      throw StateError('cloud_sync_attachment_upload_origin_missing');
    }
    final row = _readBound(candidate.id);
    if (row.state != CloudAttachmentUploadState.adopted.index ||
        row.attachmentKeyHash != operation.logicalEntityKeyHash ||
        row.serverRecordIdHash != operation.serverRecordIdHash ||
        row.resultReference != operation.encryptedPayloadReference ||
        row.resultPayloadSha256 != operation.payloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    _requireFinalOperation(row, operation.operationId);
  }

  CloudAttachmentUploadSnapshot adoptPlan({
    required int localSendIntentId,
    required CloudSyncProtectedOutboundStageData plan,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireGeneration();
    _validateStage(plan);
    final origin = _localSends.requireConfirmedAttachmentUploadOrigin(
      transactionStore: _store,
      intentId: localSendIntentId,
      currentAuth: _auth,
    );
    // Neither record identity nor checkpoint generation is part of this key:
    // allocating a name or resetting sync cannot hide an earlier attempt.
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-attachment-upload-v1',
              _scope.storageKey,
              origin.source.messageGuidHash,
              origin.source.sourceSha256,
              plan.logicalEntityKeyHash,
            ]),
          ),
        )
        .toString();
    final query = _uploads
        .query(CloudAttachmentUploadEntity_.uploadKey.equals(key))
        .build();
    final CloudAttachmentUploadEntity? existing;
    try {
      existing = query.findUnique();
    } finally {
      query.close();
    }
    if (existing != null) {
      final row = _readBound(existing.id);
      if (row.localSendIntentId != localSendIntentId ||
          !_sameStage(_plan(row), plan)) {
        throw StateError('cloud_sync_attachment_upload_plan_changed');
      }
      return CloudAttachmentUploadSnapshot._(row);
    }
    final row = CloudAttachmentUploadEntity(
      uploadKey: key,
      accountFingerprint: _scope.accountFingerprint,
      writerEpoch: origin.writerEpoch,
      checkpointGeneration: _generation,
      localSendIntentId: localSendIntentId,
      messageGuidHash: origin.source.messageGuidHash,
      sourceSha256: origin.source.sourceSha256,
      protectedStoreIdentity: _auth.protectedStoreIdentity,
      attachmentKeyHash: plan.logicalEntityKeyHash,
      serverRecordIdHash: plan.serverRecordIdHash,
      planReference: plan.protectedEnvelopeReference,
      planLeaseReference: plan.leaseReference,
      planPayloadSha256: plan.payloadSha256,
      createdAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  CloudAttachmentUploadSnapshot read(int id) => _store.runInTransaction(
    TxMode.read,
    () => CloudAttachmentUploadSnapshot._(_readBound(id)),
  );

  /// No idempotent repeat is returned as another consumable attempt. If the
  /// caller cannot observe this transaction, it must inspect/recover, not send.
  CloudAttachmentUploadSnapshot beginAttempt({
    required int id,
    required String attemptId,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    if (!_uuid.hasMatch(attemptId)) {
      throw StateError('cloud_sync_attachment_upload_attempt_invalid');
    }
    final row = _readBound(id);
    if (row.state != CloudAttachmentUploadState.prepared.index) {
      throw StateError('cloud_sync_attachment_upload_already_attempted');
    }
    row
      ..state = CloudAttachmentUploadState.started.index
      ..attemptId = attemptId
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Adopt only the native-validated result from this exact attempt. This is
  /// upload evidence, not remote-record success. Lease commit follows outside
  /// the transaction and can be retried without any upload network request.
  CloudAttachmentUploadSnapshot recordUploaded({
    required int id,
    required String attemptId,
    required CloudSyncProtectedOutboundStageData result,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readBound(id);
    _validateStage(result);
    if (row.attemptId != attemptId ||
        result.logicalEntityKeyHash != row.attachmentKeyHash ||
        result.serverRecordIdHash != row.serverRecordIdHash) {
      throw StateError('cloud_sync_attachment_upload_result_changed');
    }
    if (row.state == CloudAttachmentUploadState.uploaded.index ||
        row.state == CloudAttachmentUploadState.adopted.index) {
      if (!_sameStage(_result(row), result)) {
        throw StateError('cloud_sync_attachment_upload_result_changed');
      }
      return CloudAttachmentUploadSnapshot._(row);
    }
    // Unknown may receive a late authenticated receipt for the SAME attempt.
    // It never creates a new attempt or accepts a record-absence observation.
    if (row.state != CloudAttachmentUploadState.started.index &&
        row.state != CloudAttachmentUploadState.unknown.index) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    row
      ..state = CloudAttachmentUploadState.uploaded.index
      ..resultReference = result.protectedEnvelopeReference
      ..resultLeaseReference = result.leaseReference
      ..resultPayloadSha256 = result.payloadSha256
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  void markUnknown({
    required int id,
    required String attemptId,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readBound(id);
    if (row.attemptId != attemptId) {
      throw StateError('cloud_sync_attachment_upload_attempt_changed');
    }
    if (row.state == CloudAttachmentUploadState.uploaded.index ||
        row.state == CloudAttachmentUploadState.adopted.index) {
      return;
    }
    if (row.state != CloudAttachmentUploadState.started.index &&
        row.state != CloudAttachmentUploadState.unknown.index) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    row
      ..state = CloudAttachmentUploadState.unknown.index
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
  });

  /// Runs final-envelope outbox admission in this SAME transaction. The
  /// callback performs the existing record-map/dependency admission, never
  /// network I/O. Throwing or returning an unpersisted/different envelope
  /// rolls back both sides. Recovery does not invoke the callback a second time.
  CloudAttachmentUploadSnapshot adoptRecordCreate({
    required int id,
    required CloudOutboxOperation Function(
      Store transactionStore,
      CloudSyncProtectedOutboundStageData result,
    )
    admit,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readBound(id);
    if (row.state == CloudAttachmentUploadState.adopted.index) {
      _requireFinalOperation(row, row.admittedOperationId!);
      return CloudAttachmentUploadSnapshot._(row);
    }
    if (row.state != CloudAttachmentUploadState.uploaded.index) {
      throw StateError('cloud_sync_attachment_upload_result_missing');
    }
    final operation = admit(_store, _result(row));
    if (operation.scope != _scope ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != 1 ||
        operation.checkpointGeneration != _generation ||
        operation.logicalEntityKeyHash != row.attachmentKeyHash ||
        operation.serverRecordIdHash != row.serverRecordIdHash ||
        operation.encryptedPayloadReference != row.resultReference ||
        operation.protectedLeaseReference != row.resultLeaseReference ||
        operation.payloadSha256 != row.resultPayloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    _requireFinalOperation(row, operation.operationId);
    row
      ..state = CloudAttachmentUploadState.adopted.index
      ..admittedOperationId = operation.operationId
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  void _requireFinalOperation(
    CloudAttachmentUploadEntity upload,
    String operationId,
  ) {
    final query = _store
        .box<CloudOutboxOperationEntity>()
        .query(CloudOutboxOperationEntity_.operationId.equals(operationId))
        .build();
    final CloudOutboxOperationEntity? row;
    try {
      row = query.findUnique();
    } finally {
      query.close();
    }
    if (operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: _scope,
              logicalEntityKeyHash: upload.attachmentKeyHash,
              payloadVersion: 1,
            ) ||
        row == null ||
        row.action != CloudOutboxAction.save.index ||
        row.payloadVersion != 1 ||
        row.accountFingerprint != _scope.accountFingerprint ||
        row.zone != _scope.zone ||
        row.scopeKey != cloudSyncPersistentScopeKey(_scope) ||
        row.checkpointGeneration != _generation ||
        row.logicalEntityKeyHash != upload.attachmentKeyHash ||
        row.serverRecordIdHash != upload.serverRecordIdHash ||
        row.encryptedPayloadRef != upload.resultReference ||
        row.payloadSha256 != upload.resultPayloadSha256 ||
        (row.protectedLeaseReference != upload.resultLeaseReference &&
            !(upload.state == CloudAttachmentUploadState.adopted.index &&
                row.state == CloudOutboxStatus.confirmed.index &&
                row.protectedLeaseReference == null))) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    if (upload.state != CloudAttachmentUploadState.adopted.index &&
        (row.state != CloudOutboxStatus.pending.index ||
            row.attemptCount != 0 ||
            row.leaseIdHash != null ||
            row.appleRequestUuid != null ||
            row.appleOperationUuid != null)) {
      throw StateError(
        'cloud_sync_attachment_upload_adoption_already_submitted',
      );
    }
  }

  void _requireGeneration() {
    final query = _store
        .box<CloudSyncCheckpointEntity>()
        .query(
          CloudSyncCheckpointEntity_.checkpointKey.equals(
            cloudSyncPersistentScopeKey(_scope),
          ),
        )
        .build();
    final CloudSyncCheckpointEntity? checkpoint;
    try {
      checkpoint = query.findUnique();
    } finally {
      query.close();
    }
    if (checkpoint == null || checkpoint.generation != _generation) {
      throw StateError('cloud_sync_attachment_upload_generation_changed');
    }
  }

  CloudAttachmentUploadEntity _readBound(int id) {
    _requireGeneration();
    final row = id > 0 ? _uploads.get(id) : null;
    if (row == null ||
        row.accountFingerprint != _scope.accountFingerprint ||
        row.checkpointGeneration != _generation ||
        row.protectedStoreIdentity != _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    validateCloudAttachmentUploadRow(row);
    final origin = _localSends.requireConfirmedAttachmentUploadOrigin(
      transactionStore: _store,
      intentId: row.localSendIntentId,
      currentAuth: _auth,
    );
    if (origin.writerEpoch != row.writerEpoch ||
        origin.source.messageGuidHash != row.messageGuidHash ||
        origin.source.sourceSha256 != row.sourceSha256) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
    final expectedKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-attachment-upload-v1',
              _scope.storageKey,
              row.messageGuidHash,
              row.sourceSha256,
              row.attachmentKeyHash,
            ]),
          ),
        )
        .toString();
    if (row.uploadKey != expectedKey) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    return row;
  }
}

/// Used by protected-store recovery even when the account/owner changed.
/// Malformed metadata blocks cleanup rather than discarding retained keys.
void validateCloudAttachmentUploadRow(CloudAttachmentUploadEntity row) {
  if (row.state < 0 ||
      row.state >= CloudAttachmentUploadState.values.length ||
      row.localSendIntentId <= 0 ||
      row.writerEpoch <= 0 ||
      row.checkpointGeneration <= 0 ||
      !_digest.hasMatch(row.uploadKey) ||
      !_token.hasMatch(row.accountFingerprint) ||
      !_digest.hasMatch(row.messageGuidHash) ||
      !_digest.hasMatch(row.sourceSha256) ||
      !RegExp(
        r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
      ).hasMatch(row.protectedStoreIdentity)) {
    throw StateError('cloud_sync_attachment_upload_row_invalid');
  }
  _validateStage(_plan(row));
  final hasResult =
      row.state == CloudAttachmentUploadState.uploaded.index ||
      row.state == CloudAttachmentUploadState.adopted.index;
  if ((row.state == CloudAttachmentUploadState.prepared.index
          ? row.attemptId != null
          : !_uuid.hasMatch(row.attemptId ?? '')) ||
      (hasResult
          ? row.resultReference == null ||
                row.resultLeaseReference == null ||
                row.resultPayloadSha256 == null
          : row.resultReference != null ||
                row.resultLeaseReference != null ||
                row.resultPayloadSha256 != null) ||
      (row.state == CloudAttachmentUploadState.adopted.index
          ? !_operationId.hasMatch(row.admittedOperationId ?? '')
          : row.admittedOperationId != null)) {
    throw StateError('cloud_sync_attachment_upload_row_invalid');
  }
  if (hasResult) _validateStage(_result(row));
}

final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _digest = RegExp(r'^[a-f0-9]{64}$');
final _operationId = RegExp(r'^op1:[a-f0-9]{64}$');
final _uuid = RegExp(
  r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$',
);
void _validateStage(CloudSyncProtectedOutboundStageData stage) {
  if (!_token.hasMatch(stage.logicalEntityKeyHash) ||
      !_token.hasMatch(stage.serverRecordIdHash) ||
      !_digest.hasMatch(stage.payloadSha256) ||
      !RegExp(
        r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
      ).hasMatch(stage.protectedEnvelopeReference) ||
      !RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(stage.leaseReference)) {
    throw StateError('cloud_sync_attachment_upload_stage_invalid');
  }
}

CloudSyncProtectedOutboundStageData _plan(CloudAttachmentUploadEntity row) =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: row.attachmentKeyHash,
      protectedEnvelopeReference: row.planReference,
      payloadSha256: row.planPayloadSha256,
      serverRecordIdHash: row.serverRecordIdHash,
      leaseReference: row.planLeaseReference,
    );
CloudSyncProtectedOutboundStageData _result(CloudAttachmentUploadEntity row) =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: row.attachmentKeyHash,
      protectedEnvelopeReference: row.resultReference!,
      payloadSha256: row.resultPayloadSha256!,
      serverRecordIdHash: row.serverRecordIdHash,
      leaseReference: row.resultLeaseReference!,
    );
bool _sameStage(
  CloudSyncProtectedOutboundStageData a,
  CloudSyncProtectedOutboundStageData b,
) =>
    a.logicalEntityKeyHash == b.logicalEntityKeyHash &&
    a.serverRecordIdHash == b.serverRecordIdHash &&
    a.payloadSha256 == b.payloadSha256 &&
    a.protectedEnvelopeReference == b.protectedEnvelopeReference &&
    a.leaseReference == b.leaseReference;
