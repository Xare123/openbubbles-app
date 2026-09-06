import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_operation_identity.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';

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

  String binding(int generation) {
    if (generation <= 0) _reject('cloud_sync_outbound_chat_generation_invalid');
    return jsonEncode([
      1,
      generation,
      chatId,
      _hash('original-guid', originalGuid),
      _hash('canonical-guid', canonicalGuid),
      _hash('recipient', chatIdentifier),
      _hash('sender', usingHandle),
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
  if (origin.binding(generation) != operation.localChatOrigin ||
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
  if (operation.attemptCount <= 0 ||
      !{
        CloudOutboxStatus.leased.index,
        CloudOutboxStatus.unknownOutcome.index,
        CloudOutboxStatus.confirmed.index,
      }.contains(operation.state) ||
      operation.appleRequestUuid == null ||
      operation.appleOperationUuid == null ||
      operation.encryptedPayloadRef == null ||
      (operation.protectedLeaseReference == null &&
          operation.state != CloudOutboxStatus.confirmed.index) ||
      operation.payloadSha256 == null) {
    _reject('cloud_sync_outbound_chat_origin_not_submitted');
  }
  final mapQuery =
      store
          .box<CloudRecordMapEntity>()
          .query(
            CloudRecordMapEntity_.scopeKey
                .equals(cloudSyncPersistentScopeKey(scope))
                .and(
                  CloudRecordMapEntity_.logicalEntityKeyHash.equals(
                    payload.logicalEntityKeyHash,
                  ),
                ),
          )
          .build()
        ..limit = 2;
  try {
    final maps = mapQuery.find();
    if (maps.length != 1 ||
        maps.single.accountFingerprint != scope.accountFingerprint ||
        maps.single.zone != scope.zone ||
        maps.single.generation != generation ||
        maps.single.serverRecordIdHash != operation.serverRecordIdHash ||
        snapshot.etagHash == null ||
        maps.single.etagHash != snapshot.etagHash ||
        snapshot.encryptedRawRecordReference == null ||
        maps.single.encryptedRawRecordRef !=
            snapshot.encryptedRawRecordReference) {
      _reject('cloud_sync_outbound_chat_origin_record_changed');
    }
  } finally {
    mapQuery.close();
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
      value.length != 7 ||
      value[0] != 1 ||
      value[1] is! int ||
      value[1] <= 0 ||
      value[2] is! int ||
      value[2] <= 0 ||
      value.skip(3).any((part) => part is! String || !_sha256.hasMatch(part))) {
    _reject('cloud_sync_outbound_chat_origin_malformed');
  }
  return value;
}

/// Locate a durable origin before allocating another random server name.
int cloudSyncOutboundChatOriginId(String encoded) =>
    _decodeBinding(encoded)[2] as int;

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
