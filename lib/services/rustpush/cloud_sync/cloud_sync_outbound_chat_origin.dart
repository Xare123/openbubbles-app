import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_operation_identity.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_record_maps.dart';

/// Transient local identity captured before native staging. Raw identifiers
/// never enter the outbox: only [binding] is persisted with the operation.
final class CloudSyncOutboundChatOrigin {
  CloudSyncOutboundChatOrigin._({
    required this.scope,
    required this.chatId,
    required this.originalGuid,
    required this.chatIdentifier,
    required this.usingHandle,
  });

  factory CloudSyncOutboundChatOrigin.capture({
    required CloudSyncScope scope,
    required Chat chat,
  }) {
    _requireChatScope(scope);
    final handles = chat.handles.toList(growable: false);
    final sender = _bareHandle(chat.usingHandle);
    if (chat.id == null ||
        chat.id! <= 0 ||
        !_uuidV4.hasMatch(chat.guid) ||
        chat.isRpSms ||
        chat.isRoutingStub ||
        (chat.style != null && chat.style != 45) ||
        chat.ckRecordId != null ||
        chat.cloudData != null ||
        (chat.cloudGuid != null && chat.cloudGuid != chat.guid) ||
        handles.length != 1 ||
        handles.single.service != 'iMessage' ||
        !_validHandle(handles.single.address) ||
        sender == null ||
        (chat.chatIdentifier != null &&
            chat.chatIdentifier != handles.single.address)) {
      _reject('cloud_sync_outbound_chat_origin_invalid');
    }
    return CloudSyncOutboundChatOrigin._(
      scope: scope,
      chatId: chat.id!,
      originalGuid: chat.guid,
      chatIdentifier: handles.single.address,
      usingHandle: sender,
    );
  }

  final CloudSyncScope scope;
  final int chatId;
  final String originalGuid;
  final String chatIdentifier;
  final String usingHandle;

  String get canonicalGuid => 'iMessage;-;$chatIdentifier';

  String _hash(String kind, String value) => _digest([
    'cloud-sync-local-chat-origin-v1',
    scope.storageKey,
    chatId,
    kind,
    value,
  ]);

  String binding(int generation, {String? localSendProof}) {
    if (generation <= 0) _reject('cloud_sync_outbound_chat_generation_invalid');
    return jsonEncode([
      localSendProof == null ? 1 : 2,
      generation,
      chatId,
      _hash('original-guid', originalGuid),
      _hash('canonical-guid', canonicalGuid),
      _hash('recipient', chatIdentifier),
      _hash('sender', usingHandle),
      if (localSendProof != null) localSendProof,
    ]);
  }

  /// Re-read the same row inside admission's write transaction. Changes to
  /// names, mute settings or message contents are irrelevant to this identity.
  void requireUnchanged(Store store) {
    final current = store.box<Chat>().get(chatId);
    if (current == null ||
        CloudSyncOutboundChatOrigin.capture(
              scope: scope,
              chat: current,
            ).binding(1) !=
            binding(1)) {
      _reject('cloud_sync_outbound_chat_origin_changed');
    }
  }

  @override
  String toString() => 'CloudSyncOutboundChatOrigin(redacted)';
}

/// Resolve only a durably admitted local origin of this exact authenticated
/// remote Chat. The caller already bound the incoming record map in the same
/// ObjectBox transaction. This function performs no writes or remote I/O.
Chat? resolveCloudSyncOutboundChatOrigin({
  required Store store,
  required CloudSyncScope scope,
  required int generation,
  required CloudChatEntityPayload payload,
  required CloudSemanticSnapshot snapshot,
  required Chat? canonicalChat,
}) {
  // Existing read-only installations and unrelated scopes retain their path.
  if (!_isChatScope(scope)) return null;
  final query = store
      .box<CloudOutboxOperationEntity>()
      .query(
        CloudOutboxOperationEntity_.scopeKey
            .equals(cloudSyncPersistentScopeKey(scope))
            .and(
              CloudOutboxOperationEntity_.logicalEntityKeyHash.equals(
                payload.logicalEntityKeyHash,
              ),
            ),
      )
      .build();
  final List<CloudOutboxOperationEntity> origins;
  try {
    origins = query.find().where((row) => row.localChatOrigin != null).toList();
  } finally {
    query.close();
  }
  if (origins.isEmpty) return null;
  if (origins.length != 1) _reject('cloud_sync_outbound_chat_origin_ambiguous');
  final operation = origins.single;
  final proof = _decodeBinding(operation.localChatOrigin!);
  if (operation.accountFingerprint != scope.accountFingerprint ||
      operation.zone != scope.zone ||
      operation.checkpointGeneration != generation ||
      proof[1] != generation ||
      operation.action != CloudOutboxAction.save.index ||
      operation.payloadVersion != cloudSyncOutboundChatPayloadVersion ||
      operation.operationId !=
          CloudOperationIdentity.forInitialCreate(
            scope: scope,
            logicalEntityKeyHash: payload.logicalEntityKeyHash,
            payloadVersion: cloudSyncOutboundChatPayloadVersion,
          )) {
    _reject('cloud_sync_outbound_chat_origin_scope_changed');
  }
  final chatId = proof[2] as int;
  if (canonicalChat != null) {
    if (canonicalChat.id != chatId) {
      _reject('cloud_sync_outbound_chat_origin_row_conflict');
    }
    // Already adopted; normal canonical ownership/merge checks now govern
    // subsequent remote updates, not the immutable initial-create snapshot.
    return canonicalChat;
  }
  final local = store.box<Chat>().get(chatId);
  if (local == null) _reject('cloud_sync_outbound_chat_origin_missing');
  final origin = CloudSyncOutboundChatOrigin.capture(scope: scope, chat: local);
  if (origin.binding(generation) !=
          cloudSyncOutboundChatOriginIdentity(operation.localChatOrigin!) ||
      payload.canonicalGuid != origin.canonicalGuid ||
      payload.chatIdentifier != origin.chatIdentifier ||
      payload.groupId != origin.originalGuid ||
      payload.originalGroupId != origin.originalGuid ||
      payload.service != CloudSemanticService.iMessage ||
      payload.style != CloudSemanticChatStyle.direct ||
      payload.participantHandles.length != 1 ||
      _bareHandle(payload.participantHandles.single) != origin.chatIdentifier ||
      payload.lastAddressedHandleState != CloudSemanticFieldState.value ||
      _bareHandle(payload.lastAddressedHandle) != origin.usingHandle) {
    _reject('cloud_sync_outbound_chat_origin_payload_changed');
  }
  // attemptCount counts retry/error transitions, not successful submissions.
  // A first-attempt receipt legitimately has zero. Submission identity and
  // state, followed by exact authenticated record/payload binding, are the
  // evidence here. Merely leasing an operation does not allocate these UUIDs.
  if (operation.attemptCount < 0 ||
      !{
        CloudOutboxStatus.leased.index,
        CloudOutboxStatus.unknownOutcome.index,
        CloudOutboxStatus.confirmed.index,
      }.contains(operation.state) ||
      !_uuidV4.hasMatch(operation.appleRequestUuid ?? '') ||
      !_uuidV4.hasMatch(operation.appleOperationUuid ?? '') ||
      operation.encryptedPayloadRef == null ||
      (operation.protectedLeaseReference == null &&
          operation.state != CloudOutboxStatus.confirmed.index) ||
      operation.payloadSha256 == null) {
    _reject('cloud_sync_outbound_chat_origin_not_submitted');
  }
  final mapping = cloudSyncFindRecordMap(
    store: store, scope: scope, generation: generation,
    logicalEntityKeyHash: payload.logicalEntityKeyHash,
    serverRecordIdHash: operation.serverRecordIdHash,
  );
  if (mapping == null ||
      mapping.serverRecordIdHash != operation.serverRecordIdHash ||
      snapshot.etagHash == null ||
      mapping.etagHash != snapshot.etagHash ||
      snapshot.encryptedRawRecordReference == null ||
      mapping.encryptedRawRecordRef != snapshot.encryptedRawRecordReference) {
    _reject('cloud_sync_outbound_chat_origin_record_changed');
  }
  return local;
}

List<dynamic> _decodeBinding(String encoded) {
  if (encoded.length > 512) {
    _reject('cloud_sync_outbound_chat_origin_malformed');
  }
  final dynamic value;
  try {
    value = jsonDecode(encoded);
  } on FormatException {
    _reject('cloud_sync_outbound_chat_origin_malformed');
  }
  if (value is! List ||
      !((value.length == 7 && value[0] == 1) ||
          (value.length == 8 && {2, 3, 4}.contains(value[0]) &&
              value[7] is String && value[7].length <= 256)) ||
      value[1] is! int ||
      value[1] <= 0 ||
      value[2] is! int ||
      value[2] <= 0 ||
      value.skip(3).take(4).any((part) => part is! String || !_sha256.hasMatch(part))) {
    _reject('cloud_sync_outbound_chat_origin_malformed');
  }
  return value;
}

/// Locate a durable origin before allocating another random server name.
int cloudSyncOutboundChatOriginId(String encoded) =>
    _decodeBinding(encoded)[2] as int;

/// Version 1's row identity remains stable when version 2 adds journal proof.
String cloudSyncOutboundChatOriginIdentity(String encoded) =>
    jsonEncode([1, ..._decodeBinding(encoded).skip(1).take(6)]);

String? cloudSyncOutboundChatOriginSendProof(String encoded) {
  final value = _decodeBinding(encoded);
  return {2, 3}.contains(value[0]) ? value[7] as String : null;
}

// These new local origin versions have never shipped before this candidate.
// 2: unconsumed send capability; 3: ever submitted; 4: locally retired.
// Version 3 is committed atomically with submission UUIDs and never cleared by
// retry/reconciliation. Retry counts alone cannot prove a remote attempt.
String cloudSyncSubmittedChatOrigin(String encoded) {
  final value = _decodeBinding(encoded);
  if (value[0] == 4) _reject('cloud_sync_outbound_chat_source_retired');
  return value[0] == 2 ? jsonEncode([3, ...value.skip(1)]) : encoded;
}

String cloudSyncRetiredChatOrigin(String encoded) {
  final value = _decodeBinding(encoded);
  if (value[0] != 2) _reject('cloud_sync_outbound_chat_retirement_invalid');
  return jsonEncode([4, ...value.skip(1)]);
}

bool cloudSyncChatOriginIsRetired(String encoded) => _decodeBinding(encoded)[0] == 4;

/// Pin immutable authorization while allowing its atomic consumption. A
/// retirement is deliberately not normalized and ends an exact selection.
String cloudSyncActiveChatOriginBinding(String encoded) {
  final value = _decodeBinding(encoded);
  return value[0] == 3 ? jsonEncode([2, ...value.skip(1)]) : encoded;
}

bool cloudSyncIsNeverSubmittedChatCreate(CloudOutboxOperationEntity row) =>
    _hasChatCreateAuditShape(row, version: 2);

/// Local cancellation audit only, never evidence of a remote save. Ordinary
/// quarantine (including unknown outcomes) must still block semantic reads.
/// Creation of this shape requires the store's journal-bound transaction.
bool cloudSyncIsRetiredUnsubmittedChatCreate(CloudOutboxOperationEntity row) {
  if (row.state != CloudOutboxStatus.quarantined.index ||
      row.lastErrorCategory != CloudFailureCategory.cancelled.name ||
      row.leaseIdHash != null || row.leaseExpiresAtMs != 0 ||
      row.nextEligibleAtMs != 0) {
    return false;
  }
  return _hasChatCreateAuditShape(row, version: 4);
}

bool _hasChatCreateAuditShape(CloudOutboxOperationEntity row, {required int version}) {
  if (row.attemptCount < 0 || row.action != CloudOutboxAction.save.index ||
      row.appleRequestUuid != null || row.appleOperationUuid != null ||
      row.confirmedAtMs != 0 ||
      row.payloadVersion != cloudSyncOutboundChatPayloadVersion ||
      row.mutationRevision <= 0 || row.checkpointGeneration <= 0 ||
      row.dependencyOperationIdsJson != '[]' ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(row.accountFingerprint) ||
      row.zone != 'chatManateeZone' ||
      row.logicalEntityKeyHash.isEmpty || row.createdAtMs <= 0 ||
      row.updatedAtMs < row.createdAtMs ||
      !RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$').hasMatch(row.encryptedPayloadRef ?? '') ||
      !RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(row.protectedLeaseReference ?? '') ||
      !_sha256.hasMatch(row.payloadSha256 ?? '') ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(row.serverRecordIdHash ?? '') ||
      row.localChatOrigin == null) {
    return false;
  }
  final scope = CloudSyncScope(
    accountFingerprint: row.accountFingerprint,
    container: 'com.apple.messages.cloud', database: 'private',
    zone: row.zone, streamKind: CloudSyncStreamKind.messages,
    schemaVersion: 2, persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  if (row.scopeKey != cloudSyncPersistentScopeKey(scope) ||
      row.operationId != CloudOperationIdentity.forInitialCreate(
        scope: scope, logicalEntityKeyHash: row.logicalEntityKeyHash,
        payloadVersion: row.payloadVersion)) {
    return false;
  }
  try {
    final origin = _decodeBinding(row.localChatOrigin!);
    if (origin[0] != version || origin[1] != row.checkpointGeneration) return false;
    final proof = jsonDecode(origin[7] as String);
    return proof is List && proof.length == 3 && proof[0] == 1 &&
        proof[1] is int && proof[1] > 0 && proof[2] is String &&
        _sha256.hasMatch(proof[2]);
  } on FormatException {
    return false;
  } on StateError {
    return false;
  } on CloudSyncFailure {
    return false;
  }
}

bool cloudSyncOutboundChatOriginMatchesCanonical(
  String encoded,
  CloudSyncScope scope,
  String canonicalGuid,
) {
  final value = _decodeBinding(encoded);
  return value[4] == _digest([
    'cloud-sync-local-chat-origin-v1', scope.storageKey,
    value[2] as int, 'canonical-guid', canonicalGuid,
  ]);
}

final _uuidV4 = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);
final _sha256 = RegExp(r'^[0-9a-f]{64}$');

bool _validHandle(String value) =>
    value.isNotEmpty &&
    value.length <= 1024 &&
    (RegExp(r'^\+[1-9][0-9]{6,14}$').hasMatch(value) ||
        RegExp(r'^[^\s@;:/]+@[^\s@;:/]+\.[^\s@;:/]+$').hasMatch(value));

String? _bareHandle(String? value) {
  if (value == null) return null;
  final bare = value.startsWith('mailto:')
      ? value.substring(7)
      : value.startsWith('tel:')
      ? value.substring(4)
      : value;
  return _validHandle(bare) ? bare : null;
}

bool _isChatScope(CloudSyncScope scope) =>
    scope.container == 'com.apple.messages.cloud' &&
    scope.database == 'private' &&
    scope.zone == 'chatManateeZone' &&
    scope.streamKind == CloudSyncStreamKind.messages &&
    scope.schemaVersion == 2 &&
    scope.persistenceLane == CloudSyncPersistenceLane.semantic;

void _requireChatScope(CloudSyncScope scope) {
  if (!_isChatScope(scope)) _reject('cloud_sync_outbound_chat_scope_invalid');
}

String _digest(List<Object> values) =>
    sha256.convert(utf8.encode(jsonEncode(values))).toString();

Never _reject(String code) => throw CloudSyncFailure(
  category: CloudFailureCategory.conflict,
  safeCode: code,
);
