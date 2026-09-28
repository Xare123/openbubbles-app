import 'dart:convert';

import 'package:bluebubbles/database/models.dart';

/// Detached parent-chat state within the encrypted, account-confirmed snapshot.
/// This preserves conversion inputs, not proof of cloud ownership or permission
/// to create a parent. Never fill missing values from a later mutable Chat or
/// call Chat.toCloud here: that can allocate an identity and choose an account
/// handle. The eventual writer must freeze its candidate before admission.
final class CloudSyncHistoricalChatState {
  CloudSyncHistoricalChatState({
    required this.cloudGuid,
    required this.usingHandle,
    required this.displayName,
    required this.groupVersion,
    required this.lastReadMessageGuid,
    required this.latestMessageDateMs,
    required this.photoAttachmentGuid,
    required this.customAvatarPresent,
    required this.ckRecordId,
    required this.ckSyncState,
    required this.cloudDataBase64,
    required Iterable<String> guidRefs,
  }) : guidRefs = List.unmodifiable(guidRefs);

  factory CloudSyncHistoricalChatState.capture(Chat chat) =>
      CloudSyncHistoricalChatState(
        cloudGuid: chat.cloudGuid,
        usingHandle: chat.usingHandle,
        displayName: chat.displayName,
        groupVersion: chat.groupVersion,
        lastReadMessageGuid: chat.lastReadMessageGuid,
        latestMessageDateMs:
            chat.dbOnlyLatestMessageDate?.millisecondsSinceEpoch,
        photoAttachmentGuid: chat.photoAttachmentGuid,
        customAvatarPresent: chat.customAvatarPath != null,
        ckRecordId: chat.ckRecordId,
        ckSyncState: chat.ckSyncState,
        cloudDataBase64: chat.cloudData == null
            ? null
            : base64.encode(chat.cloudData!),
        guidRefs: chat.guidRefs,
      );

  final String? cloudGuid;
  final String? usingHandle;
  final String? displayName;
  final int? groupVersion;
  final String? lastReadMessageGuid;
  final int? latestMessageDateMs;
  final String? photoAttachmentGuid;
  final bool customAvatarPresent;
  final String? ckRecordId;
  final bool ckSyncState;

  /// Exact saved CloudChat plist bytes. Opaque here; native validation is still
  /// mandatory before use. A string copy cannot share the mutable source bytes.
  final String? cloudDataBase64;
  final List<String> guidRefs;

  List<Object?> toWire() => [
    1,
    cloudGuid,
    usingHandle,
    displayName,
    groupVersion,
    lastReadMessageGuid,
    latestMessageDateMs,
    photoAttachmentGuid,
    customAvatarPresent,
    ckRecordId,
    ckSyncState,
    cloudDataBase64,
    guidRefs,
  ];

  @override
  String toString() => 'CloudSyncHistoricalChatState(redacted)';
}
