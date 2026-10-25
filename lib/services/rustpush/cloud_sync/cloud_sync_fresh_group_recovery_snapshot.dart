import 'dart:collection';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

/// Complete persisted scalar snapshots, including nulls. These are audit data,
/// never permission to repair or dispatch. The caller separately validates the
/// current account, source, origin, native stage and transactional ownership.
Map<String, Object?> freshGroupRecoveryOperationSnapshot(
  CloudOutboxOperationEntity row,
) => Map.unmodifiable({
  'id': row.id,
  'operationId': row.operationId,
  'scopeKey': row.scopeKey,
  'accountFingerprint': row.accountFingerprint,
  'zone': row.zone,
  'logicalEntityKeyHash': row.logicalEntityKeyHash,
  'action': row.action,
  'dependencyOperationIdsJson': row.dependencyOperationIdsJson,
  'payloadVersion': row.payloadVersion,
  'mutationRevision': row.mutationRevision,
  'checkpointGeneration': row.checkpointGeneration,
  'appleRequestUuid': row.appleRequestUuid,
  'appleOperationUuid': row.appleOperationUuid,
  'encryptedPayloadRef': row.encryptedPayloadRef,
  'payloadSha256': row.payloadSha256,
  'protectedLeaseReference': row.protectedLeaseReference,
  'localChatOrigin': row.localChatOrigin,
  'state': row.state,
  'attemptCount': row.attemptCount,
  'nextEligibleAtMs': row.nextEligibleAtMs,
  'lastErrorCategory': row.lastErrorCategory,
  'serverRecordIdHash': row.serverRecordIdHash,
  'leaseIdHash': row.leaseIdHash,
  'leaseExpiresAtMs': row.leaseExpiresAtMs,
  'confirmedAtMs': row.confirmedAtMs,
  'createdAtMs': row.createdAtMs,
  'updatedAtMs': row.updatedAtMs,
});

Map<String, Object?> freshGroupRecoveryMapSnapshot(CloudRecordMapEntity row) =>
    Map.unmodifiable({
      'id': row.id,
      'mapKey': row.mapKey,
      'scopeKey': row.scopeKey,
      'accountFingerprint': row.accountFingerprint,
      'zone': row.zone,
      'logicalEntityKeyHash': row.logicalEntityKeyHash,
      'serverRecordIdHash': row.serverRecordIdHash,
      'generation': row.generation,
      'encryptedServerRecordId': row.encryptedServerRecordId,
      'etagHash': row.etagHash,
      'encryptedRawRecordRef': row.encryptedRawRecordRef,
      'rawRecordGeneration': row.rawRecordGeneration,
      'protectedReadbackLeaseReference': row.protectedReadbackLeaseReference,
      'pendingUpdateOperationId': row.pendingUpdateOperationId,
      'pendingUpdatePredecessorEtagHash': row.pendingUpdatePredecessorEtagHash,
      'updatedAtMs': row.updatedAtMs,
    });

Map<String, Object?> freshGroupRecoverySourceSnapshot(
  CloudSyncLocalSendIntentEntity row,
) => Map.unmodifiable({
  'id': row.id,
  'intentKey': row.intentKey,
  'accountFingerprint': row.accountFingerprint,
  'writerEpoch': row.writerEpoch,
  'localMessageId': row.localMessageId,
  'messageGuidHash': row.messageGuidHash,
  'sourceSha256': row.sourceSha256,
  'state': row.state,
  'admittedOperationId': row.admittedOperationId,
  'admittedBindingSha256': row.admittedBindingSha256,
  'admittedChatBinding': row.admittedChatBinding,
  'confirmedReadbackBindingSha256': row.confirmedReadbackBindingSha256,
  'idsConfirmationVersion': row.idsConfirmationVersion,
  'protectedSourceBinding': row.protectedSourceBinding,
  'createdAtMs': row.createdAtMs,
  'updatedAtMs': row.updatedAtMs,
});

String freshGroupRecoverySnapshotFingerprint(Map<String, Object?> value) {
  if (value.values.any((v) => v != null && v is! String && v is! int)) {
    throw StateError('cloud_sync_local_send_chat_binding_changed');
  }
  return sha256
      .convert(utf8.encode(jsonEncode(SplayTreeMap<String, Object?>.of(value))))
      .toString();
}

/// Reconstruct only an in-memory old operation for proof verification. This
/// never inserts or rewrites it. Roundtrip equality rejects missing nullable
/// fields and unknown fields instead of silently accepting constructor defaults.
CloudOutboxOperationEntity freshGroupRecoveryOperationFromSnapshot(
  Map<String, Object?> value,
) {
  Never reject() =>
      throw StateError('cloud_sync_local_send_chat_binding_changed');
  int integer(String key) => value[key] is int ? value[key] as int : reject();
  String string(String key) =>
      value[key] is String ? value[key] as String : reject();
  String? optionalString(String key) => value[key] == null
      ? null
      : value[key] is String
      ? value[key] as String
      : reject();
  final row = CloudOutboxOperationEntity(
    id: integer('id'),
    operationId: string('operationId'),
    scopeKey: string('scopeKey'),
    accountFingerprint: string('accountFingerprint'),
    zone: string('zone'),
    logicalEntityKeyHash: string('logicalEntityKeyHash'),
    action: integer('action'),
    dependencyOperationIdsJson: string('dependencyOperationIdsJson'),
    payloadVersion: integer('payloadVersion'),
    mutationRevision: integer('mutationRevision'),
    checkpointGeneration: integer('checkpointGeneration'),
    appleRequestUuid: optionalString('appleRequestUuid'),
    appleOperationUuid: optionalString('appleOperationUuid'),
    encryptedPayloadRef: optionalString('encryptedPayloadRef'),
    payloadSha256: optionalString('payloadSha256'),
    protectedLeaseReference: optionalString('protectedLeaseReference'),
    localChatOrigin: optionalString('localChatOrigin'),
    state: integer('state'),
    attemptCount: integer('attemptCount'),
    nextEligibleAtMs: integer('nextEligibleAtMs'),
    lastErrorCategory: optionalString('lastErrorCategory'),
    serverRecordIdHash: optionalString('serverRecordIdHash'),
    leaseIdHash: optionalString('leaseIdHash'),
    leaseExpiresAtMs: integer('leaseExpiresAtMs'),
    confirmedAtMs: integer('confirmedAtMs'),
    createdAtMs: integer('createdAtMs'),
    updatedAtMs: integer('updatedAtMs'),
  );
  if (freshGroupRecoverySnapshotFingerprint(value) !=
      freshGroupRecoverySnapshotFingerprint(
        freshGroupRecoveryOperationSnapshot(row),
      )) {
    reject();
  }
  return row;
}
