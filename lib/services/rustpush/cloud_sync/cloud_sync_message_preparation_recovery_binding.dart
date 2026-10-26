import 'dart:convert';

import 'package:bluebubbles/database/models.dart';

import 'cloud_operation_identity.dart';
import 'cloud_sync_fresh_group_recovery_snapshot.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_message_preparation_recovery_origin.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_write_transport.dart';

const messagePreparationRecoveryChangedCode =
    'cloud_sync_message_preparation_recovery_changed';

/// Immutable read set only, NEVER an authenticated recovery owner.
///
/// The journal must capture/revalidate these complete snapshots on the actual
/// bound store, authenticate the old adoption and native source/child proof,
/// and prove current ownership independently. No model construction here reads
/// or writes a database, commits a native lease, or issues a mutation permit.
final class CloudSyncMessagePreparationRecoveryClaim {
  CloudSyncMessagePreparationRecoveryClaim._({
    required this.operation,
    required this.operationSnapshot,
    required this.recordMapSnapshot,
    required this.sourceSnapshot,
    required this.chatId,
    required this.intentId,
  });

  factory CloudSyncMessagePreparationRecoveryClaim({
    required CloudOutboxOperation operation,
    required Map<String, Object?> operationSnapshot,
    required Map<String, Object?> recordMapSnapshot,
    required Map<String, Object?> sourceSnapshot,
    required int chatId,
    required int intentId,
  }) => _checked(() {
    final old = _freezeSnapshot(operationSnapshot);
    final map = _freezeSnapshot(recordMapSnapshot);
    final source = _freezeSnapshot(sourceSnapshot);
    final reconstructed = _originalOperation(
      operation.scope, old, map, source, chatId, intentId,
    );
    if (!operation.sameDurableSnapshotAs(reconstructed)) {
      _reject();
    }
    return CloudSyncMessagePreparationRecoveryClaim._(
      operation: operation,
      operationSnapshot: old,
      recordMapSnapshot: map,
      sourceSnapshot: source,
      chatId: chatId,
      intentId: intentId,
    );
  });

  final CloudOutboxOperation operation;
  final Map<String, Object?> operationSnapshot;
  final Map<String, Object?> recordMapSnapshot;
  final Map<String, Object?> sourceSnapshot;
  final int chatId;
  final int intentId;

  @override
  String toString() => 'CloudSyncMessagePreparationRecoveryClaim(redacted)';
}

/// Builds and validates bounded metadata, not a native/authentication receipt.
/// The caller authenticates claim/currentAuth/ownership and the genuine stage,
/// then atomically adopts this audit BEFORE committing the fresh native lease.
/// Current writer epochs deliberately need not equal the retained source epoch.
Map<String, Object?> messagePreparationRecoveryBuildReceipt({
  required CloudSyncMessagePreparationRecoveryClaim claim,
  required CloudSyncProtectedOutboundStageData stage,
  required CloudSyncNativeAuthSnapshot currentAuth,
  required int writerEpoch,
  required int ownershipEpoch,
  required String ownershipSnapshotSha256,
  required DateTime now,
}) => _checked(() {
  if (currentAuth.accountFingerprint != claim.operation.scope.accountFingerprint) {
    _reject();
  }
  final origin = CloudSyncMessagePreparationRecoveryOrigin.create(
    legacyBinding: claim.sourceSnapshot['admittedChatBinding']! as String,
    receipt: {
      'schema': 1,
      'reason': CloudSyncMessagePreparationRecoveryOrigin.reason,
      'mode': CloudSyncMessagePreparationRecoveryOrigin.mode,
      'operation': claim.operationSnapshot,
      'recordMap': claim.recordMapSnapshot,
      'source': claim.sourceSnapshot,
      'stage': {
        'protectedPayloadReference': stage.protectedEnvelopeReference,
        'protectedServerRecordReference': stage.protectedEnvelopeReference,
        'leaseReference': stage.leaseReference,
        'payloadSha256': stage.payloadSha256,
        'logicalEntityKeyHash': stage.logicalEntityKeyHash,
        'serverRecordIdHash': stage.serverRecordIdHash,
      },
      'binding': {
        'scopeKey': claim.operationSnapshot['scopeKey'],
        'accountFingerprint': currentAuth.accountFingerprint,
        'checkpointGeneration': claim.operation.checkpointGeneration,
        'chatId': claim.chatId,
        'intentId': claim.intentId,
        'localMessageId': claim.sourceSnapshot['localMessageId'],
        'nativeSessionId': currentAuth.nativeSessionId,
        'protectedStoreIdentity': currentAuth.protectedStoreIdentity,
        'owner': 'v2',
        'writerEpoch': writerEpoch,
        'ownershipEpoch': ownershipEpoch,
        'ownershipSnapshotSha256': ownershipSnapshotSha256,
        'recoveredAtMs': now.toUtc().millisecondsSinceEpoch,
      },
      'legacyAdoptionSha256': claim.sourceSnapshot['admittedBindingSha256'],
    },
  );
  final original = validateMessagePreparationRecoveryReceipt(origin);
  if (!claim.operation.sameDurableSnapshotAs(original)) {
    _reject();
  }
  return origin.receipt;
});

/// Reconstructs the ORIGINAL operation, preserving its quarantine, UUIDs,
/// timestamps, failure and original nullable lease. Checks model relationships
/// in addition to the codec. This does not authenticate any persisted claim.
CloudOutboxOperation validateMessagePreparationRecoveryReceipt(
  CloudSyncMessagePreparationRecoveryOrigin origin,
) => _checked(() {
  final scope = _messageScope(origin.operation['accountFingerprint']! as String);
  return _originalOperation(
    scope, origin.operation, origin.recordMap, origin.source,
    origin.binding['chatId']! as int, origin.binding['intentId']! as int,
  );
});

/// PREPARATION-ONLY projection from an independently authenticated durable
/// recovery owner. The caller must freshly authenticate the original complete
/// snapshots, legacy adoption, current source/child/ownership and exact native
/// COMMITTED fresh lease before calling. A phase or syntax hash proves none of
/// these. Use existing prepareSubmission/reconcile and release only; this DTO
/// does not grant save, consume, replay, IDS or a writer permit.
///
/// The fresh receipt supplies both protected references directly. No fabricated
/// CloudOutboxOperation status/lease or record-map overlay is ever constructed.
CloudSyncProtectedWriteOperation resolveMessagePreparationRecoveryOperation(
  CloudSyncMessagePreparationRecoveryOrigin origin, {
  required CloudOutboxOperation originalOperation,
}) => _checked(() {
  final original = validateMessagePreparationRecoveryReceipt(origin);
  if ((origin.phase != CloudSyncMessagePreparationRecoveryPhase.committed &&
          origin.phase != CloudSyncMessagePreparationRecoveryPhase.retained) ||
      !originalOperation.sameDurableSnapshotAs(original)) {
    _reject();
  }
  return CloudSyncProtectedWriteOperation(
    operationId: original.operationId,
    logicalEntityKeyHash: original.logicalEntityKeyHash,
    action: original.action,
    protectedLeaseReference: origin.freshLeaseReference,
    protectedServerRecordIdReference: origin.freshProtectedReference,
    serverRecordIdHash: original.serverRecordIdHash!,
    protectedPayloadReference: origin.freshProtectedReference,
    payloadSha256: original.payloadSha256,
  );
});

/// Complete audit references, including after retirement. A separate reviewed
/// disposal policy is required to stop retaining these bytes. Corrupt/unknown
/// wrappers fail closed; callers must not catch that failure as an empty set.
Set<String> messagePreparationRecoveryAuditProtectedReferences(String encoded) =>
    _checked(() {
      final origin = CloudSyncMessagePreparationRecoveryOrigin.decode(encoded);
      validateMessagePreparationRecoveryReceipt(origin);
      final source = CloudSyncLocalSendSourceBinding.decode(
        origin.source['protectedSourceBinding']! as String,
      );
      return Set<String>.unmodifiable({
        origin.operation['encryptedPayloadRef']! as String,
        origin.recordMap['encryptedServerRecordId']! as String,
        if (origin.recordMap['encryptedRawRecordRef'] case final String reference)
          reference,
        origin.freshProtectedReference,
        source.protectedReference,
      });
    });

/// Only the genuine NEW recovery lease is added to outbound recovery ownership.
/// The old Message receipt may have been acknowledged; do not resurrect it.
/// Existing source/readback owners remain responsible for their own leases.
/// Adopted, committed and retained phases keep the fresh lease live. Retirement
/// syntax permits an empty result only after full decode/domain validation;
/// actual retirement/disposal still requires independent authorization.
Set<String> messagePreparationRecoveryAuditLeaseReferences(String encoded) =>
    _checked(() {
      final origin = CloudSyncMessagePreparationRecoveryOrigin.decode(encoded);
      validateMessagePreparationRecoveryReceipt(origin);
      return Set<String>.unmodifiable({
        if (origin.retainsFreshLease) origin.freshLeaseReference,
      });
    });

CloudOutboxOperation _originalOperation(
  CloudSyncScope scope,
  Map<String, Object?> operation,
  Map<String, Object?> recordMap,
  Map<String, Object?> source,
  int chatId,
  int intentId,
) {
  final old = freshGroupRecoveryOperationFromSnapshot(operation);
  final map = _recordMapFromSnapshot(recordMap);
  final intent = _sourceFromSnapshot(source);
  if (scope != _messageScope(old.accountFingerprint) ||
      old.id <= 0 || old.scopeKey != cloudSyncPersistentScopeKey(scope) ||
      old.zone != scope.zone || old.action != CloudOutboxAction.save.index ||
      old.payloadVersion != cloudSyncOutboundPayloadVersion ||
      old.state != CloudOutboxStatus.quarantined.index ||
      old.dependencyOperationIdsJson != '[]' || old.localChatOrigin != null ||
      old.leaseIdHash != null || old.leaseExpiresAtMs != 0 ||
      old.operationId != CloudOperationIdentity.forInitialCreate(
        scope: scope, logicalEntityKeyHash: old.logicalEntityKeyHash,
        payloadVersion: old.payloadVersion,
      ) ||
      map.id <= 0 || map.scopeKey != old.scopeKey || map.zone != old.zone ||
      map.accountFingerprint != old.accountFingerprint ||
      map.mapKey != cloudSyncCanonicalRecordMapKey(scope, old.logicalEntityKeyHash) ||
      map.generation != old.checkpointGeneration ||
      map.logicalEntityKeyHash != old.logicalEntityKeyHash ||
      map.serverRecordIdHash != old.serverRecordIdHash ||
      map.encryptedServerRecordId != old.encryptedPayloadRef ||
      intentId <= 0 || intent.id != intentId || chatId <= 0 ||
      intent.localMessageId <= 0 || intent.writerEpoch <= 0 ||
      intent.accountFingerprint != old.accountFingerprint || intent.state != 2 ||
      intent.idsConfirmationVersion != 2 || intent.admittedOperationId != old.operationId ||
      intent.admittedBindingSha256 == null ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(intent.admittedBindingSha256!) ||
      intent.admittedChatBinding == null || intent.protectedSourceBinding == null ||
      _legacyChatId(intent.admittedChatBinding!, old.accountFingerprint) != chatId) {
    _reject();
  }
  CloudSyncLocalSendSourceBinding.decode(intent.protectedSourceBinding!).requireOrigin(
    accountFingerprint: intent.accountFingerprint,
    messageGuidHash: intent.messageGuidHash,
    sourceSha256: intent.sourceSha256,
  );
  // Match the store's real model conversion. A persisted lease hash cannot
  // reconstruct a coordinator's raw lease ID, so an actively leased read set is
  // refused above rather than synthesized. No inference concerns Apple UUIDs.
  return CloudOutboxOperation(
    scope: scope,
    operationId: old.operationId,
    logicalEntityKeyHash: old.logicalEntityKeyHash,
    action: CloudOutboxAction.save,
    payloadVersion: old.payloadVersion,
    mutationRevision: old.mutationRevision,
    checkpointGeneration: old.checkpointGeneration,
    dependencyOperationIds: const {},
    createdAt: DateTime.fromMillisecondsSinceEpoch(old.createdAtMs, isUtc: true),
    encryptedPayloadReference: old.encryptedPayloadRef,
    payloadSha256: old.payloadSha256,
    serverRecordIdHash: old.serverRecordIdHash,
    protectedLeaseReference: old.protectedLeaseReference,
    appleRequestUuid: old.appleRequestUuid,
    appleOperationUuid: old.appleOperationUuid,
    status: CloudOutboxStatus.quarantined,
    attemptCount: old.attemptCount,
    nextEligibleAt: _dateOrNull(old.nextEligibleAtMs),
    lastFailure: old.lastErrorCategory == null ? null :
        CloudFailureCategory.values.firstWhere((v) => v.name == old.lastErrorCategory),
    leaseExpiresAt: _dateOrNull(old.leaseExpiresAtMs),
    confirmedAt: _dateOrNull(old.confirmedAtMs),
  );
}

CloudSyncScope _messageScope(String account) => CloudSyncScope(
  accountFingerprint: account, container: 'com.apple.messages.cloud',
  database: 'private', zone: 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

int _legacyChatId(String encoded, String account) {
  if (encoded.length > CloudSyncMessagePreparationRecoveryOrigin.maximumLegacyBindingCodeUnits) {
    _reject();
  }
  final root = jsonDecode(encoded);
  if (root is! List || root.length != 3 || root[0] is! int || root[0] != 4 ||
      root[1] is! String || (root[1] as String).length > 1536 ||
      root[2] is! String || jsonEncode(root) != encoded) {
    _reject();
  }
  final chat = jsonDecode(root[1] as String);
  final chatScope = CloudSyncScope(
    accountFingerprint: account, container: 'com.apple.messages.cloud',
    database: 'private', zone: 'chatManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  if (chat is! List || chat.isEmpty || chat[0] is! int ||
      !((chat[0] == 1 && chat.length == 9) || (chat[0] == 3 && chat.length == 11)) ||
      chat[1] != cloudSyncPersistentScopeKey(chatScope) ||
      chat[3] is! int || (chat[3] as int) <= 0) {
    _reject();
  }
  return chat[3] as int;
}

CloudRecordMapEntity _recordMapFromSnapshot(Map<String, Object?> v) {
  final row = CloudRecordMapEntity(
    id: _integer(v, 'id'), mapKey: _string(v, 'mapKey'), scopeKey: _string(v, 'scopeKey'),
    accountFingerprint: _string(v, 'accountFingerprint'), zone: _string(v, 'zone'),
    logicalEntityKeyHash: _string(v, 'logicalEntityKeyHash'),
    serverRecordIdHash: _string(v, 'serverRecordIdHash'), generation: _integer(v, 'generation'),
    encryptedServerRecordId: _string(v, 'encryptedServerRecordId'),
    etagHash: _optionalString(v, 'etagHash'), encryptedRawRecordRef: _optionalString(v, 'encryptedRawRecordRef'),
    rawRecordGeneration: _integer(v, 'rawRecordGeneration'),
    protectedReadbackLeaseReference: _optionalString(v, 'protectedReadbackLeaseReference'),
    pendingUpdateOperationId: _optionalString(v, 'pendingUpdateOperationId'),
    pendingUpdatePredecessorEtagHash: _optionalString(v, 'pendingUpdatePredecessorEtagHash'),
    updatedAtMs: _integer(v, 'updatedAtMs'),
  );
  _requireSameSnapshot(v, freshGroupRecoveryMapSnapshot(row));
  return row;
}

CloudSyncLocalSendIntentEntity _sourceFromSnapshot(Map<String, Object?> v) {
  final row = CloudSyncLocalSendIntentEntity(
    id: _integer(v, 'id'), intentKey: _string(v, 'intentKey'),
    accountFingerprint: _string(v, 'accountFingerprint'), writerEpoch: _integer(v, 'writerEpoch'),
    localMessageId: _integer(v, 'localMessageId'), messageGuidHash: _string(v, 'messageGuidHash'),
    sourceSha256: _string(v, 'sourceSha256'), state: _integer(v, 'state'),
    admittedOperationId: _optionalString(v, 'admittedOperationId'),
    admittedBindingSha256: _optionalString(v, 'admittedBindingSha256'),
    admittedChatBinding: _optionalString(v, 'admittedChatBinding'),
    confirmedReadbackBindingSha256: _optionalString(v, 'confirmedReadbackBindingSha256'),
    idsConfirmationVersion: _integer(v, 'idsConfirmationVersion'),
    protectedSourceBinding: _optionalString(v, 'protectedSourceBinding'),
    createdAtMs: _integer(v, 'createdAtMs'), updatedAtMs: _integer(v, 'updatedAtMs'),
  );
  _requireSameSnapshot(v, freshGroupRecoverySourceSnapshot(row));
  return row;
}

Map<String, Object?> _freezeSnapshot(Map<String, Object?> value) {
  if (value.length > 32 || value.values.any((v) =>
      v != null && v is! int && v is! String ||
      v is String && v.length > CloudSyncMessagePreparationRecoveryOrigin.maximumReceiptCodeUnits)) {
    _reject();
  }
  return Map<String, Object?>.unmodifiable(value);
}

void _requireSameSnapshot(Map<String, Object?> before, Map<String, Object?> after) {
  if (freshGroupRecoverySnapshotFingerprint(before) != freshGroupRecoverySnapshotFingerprint(after)) {
    _reject();
  }
}

int _integer(Map<String, Object?> value, String key) =>
    value[key] is int ? value[key]! as int : _reject();
String _string(Map<String, Object?> value, String key) =>
    value[key] is String ? value[key]! as String : _reject();
String? _optionalString(Map<String, Object?> value, String key) =>
    value[key] == null ? null : _string(value, key);
DateTime? _dateOrNull(int value) => value == 0 ? null :
    DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);

T _checked<T>(T Function() action) {
  try {
    return action();
  } on ArgumentError {
    _reject();
  } on FormatException {
    _reject();
  } on StateError {
    _reject();
  }
}

Never _reject() => throw StateError(messagePreparationRecoveryChangedCode);
