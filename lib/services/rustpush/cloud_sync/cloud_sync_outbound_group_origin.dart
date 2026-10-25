import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_chat_identity_origin.dart';
import 'cloud_sync_group_send_route.dart';
import 'cloud_sync_models.dart';

/// A fresh local group, never a historical upload or a group inferred by peers.
/// Its deterministic CloudKit identifier leaves the original native group UUID
/// intact and survives restart without mutating the local Chat before readback.
final class CloudSyncOutboundGroupOrigin
    implements CloudSyncLocalChatCreateOrigin {
  CloudSyncOutboundGroupOrigin._({
    required this.scope,
    required this.chatId,
    required this.originalGuid,
    required this.usingHandle,
    required this.members,
    required this.initialGroupVersion,
    required this.displayName,
  });

  factory CloudSyncOutboundGroupOrigin.capture({
    required CloudSyncScope scope,
    required Chat chat,
  }) {
    final route = CloudSyncGroupSendRoute.capture(chat);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(scope.accountFingerprint) ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'chatManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != cloudSyncSchemaVersion ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        route == null ||
        !route.provisional ||
        route.members.length < 2 ||
        chat.dateDeleted != null ||
        chat.photoAttachmentGuid != null ||
        route.members.any((member) => !_supportedMember(member)) ||
        route.members.any(
          (member) => member.toLowerCase() == route.sender.toLowerCase(),
        ) ||
        route.members.map((member) => member.toLowerCase()).toSet().length !=
            route.members.length ||
        !_supportedMember(route.sender) ||
        (chat.groupVersion != null &&
            (chat.groupVersion! < 0 || chat.groupVersion! > 0xffffffff)) ||
        (chat.displayName != null &&
            (utf8.encode(chat.displayName!).length > 4096 ||
                chat.displayName!.contains('\u0000')))) {
      throw StateError('cloud_sync_outbound_group_origin_invalid');
    }
    return CloudSyncOutboundGroupOrigin._(
      scope: scope,
      chatId: route.chatId,
      originalGuid: route.guid,
      usingHandle: route.sender,
      members: route.members,
      initialGroupVersion: chat.groupVersion,
      displayName: chat.displayName,
    );
  }

  @override
  final CloudSyncScope scope;
  @override
  final int chatId;
  @override
  final String originalGuid;
  @override
  final String usingHandle;
  final List<String> members;
  final int? initialGroupVersion;
  final String? displayName;
  int get groupVersion => initialGroupVersion ?? 1;

  @override
  String get chatIdentifier =>
      'chat${originalGuid.replaceAll('-', '').toLowerCase()}';
  @override
  String get canonicalGuid => 'iMessage;+;$chatIdentifier';

  String _hash(String kind, Object? value) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'cloud-sync-local-group-origin-v1',
            scope.storageKey,
            chatId,
            kind,
            value,
          ]),
        ),
      )
      .toString();

  @override
  String binding(int generation, {String? localSendProof}) {
    if (generation <= 0) {
      throw StateError('cloud_sync_outbound_chat_generation_invalid');
    }
    return jsonEncode([
      localSendProof == null ? 5 : 6,
      generation,
      chatId,
      _hash('original-guid', originalGuid),
      _hash('canonical-guid', canonicalGuid),
      _hash('members', members),
      _hash('sender', usingHandle),
      _hash('metadata', [groupVersion, displayName]),
      if (localSendProof != null) localSendProof,
    ]);
  }

  @override
  void requireUnchanged(Store store) {
    final current = store.box<Chat>().get(chatId);
    if (current == null ||
        CloudSyncOutboundGroupOrigin.capture(
              scope: scope,
              chat: current,
            ).binding(1) !=
            binding(1)) {
      throw StateError('cloud_sync_outbound_group_origin_changed');
    }
  }

  @override
  String toString() => 'CloudSyncOutboundGroupOrigin(redacted)';
}

bool _supportedMember(String value) =>
    value.length <= 1024 &&
    (RegExp(r'^\+[1-9][0-9]{0,14}$').hasMatch(value) ||
        RegExp(r'^[^\s@;:/\\]+@[^\s@;:/\\]+$').hasMatch(value));

/// Version5 is identity;6 adds an unsubmitted local-send proof;7 records an
/// entered submission;8 is the retained local retirement audit.
bool isCloudSyncOutboundGroupOrigin(String encoded) {
  try {
    final value = jsonDecode(encoded);
    return value is List && value.isNotEmpty && {5, 6, 7, 8}.contains(value[0]);
  } on FormatException {
    return false;
  }
}

List<dynamic> decodeCloudSyncOutboundGroupOrigin(String encoded) {
  if (encoded.length > 768) {
    throw StateError('cloud_sync_outbound_group_origin_malformed');
  }
  final dynamic value;
  try {
    value = jsonDecode(encoded);
  } on FormatException {
    throw StateError('cloud_sync_outbound_group_origin_malformed');
  }
  if (value is! List ||
      !((value.length == 8 && value[0] == 5) ||
          (value.length == 9 &&
              {6, 7, 8}.contains(value[0]) &&
              value[8] is String &&
              value[8].length <= 256)) ||
      value[1] is! int ||
      value[1] <= 0 ||
      value[2] is! int ||
      value[2] <= 0 ||
      value
          .skip(3)
          .take(5)
          .any(
            (part) =>
                part is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(part),
          )) {
    throw StateError('cloud_sync_outbound_group_origin_malformed');
  }
  return value;
}

bool cloudSyncGroupOriginMatchesCanonical(
  String encoded,
  CloudSyncScope scope,
  String canonicalGuid,
) {
  final value = decodeCloudSyncOutboundGroupOrigin(encoded);
  return value[4] ==
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'cloud-sync-local-group-origin-v1',
                scope.storageKey,
                value[2] as int,
                'canonical-guid',
                canonicalGuid,
              ]),
            ),
          )
          .toString();
}
