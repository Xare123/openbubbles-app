import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_local_send_journal.dart';

/// Wire encoding for the journal's strictly plain, confirmed local text.
///
/// The legacy encoder always emits an NSAttributedString archive. V2's current
/// native contract accepts text only. Prove that the archive would carry no
/// extra semantics before omitting it; never modify the canonical Message or
/// relax native validation. Journal admission still proves actual IDS success.
api.CloudMessage encodeCloudSyncLocalSendPlainText(Message message) {
  final chat = message.chat.target;
  final guid = message.guid;
  if (chat == null ||
      guid == null ||
      message.error != 0 ||
      chat.guid != 'iMessage;-;${chat.chatIdentifier}' ||
      CloudSyncLocalSendIdentity.capture(message, chat, guid) == null) {
    throw StateError('cloud_sync_outbound_unsupported_message');
  }
  return api.CloudMessage(
    utm: api.utmNow(),
    type: 1,
    error: message.error,
    chatId: chat.guid,
    sender: '',
    time: RustPushBBUtils.nsSinceAppleEpoch(message.dateCreated!),
    destinationCallerId: chat.usingHandle!
        .replaceFirst('mailto:', '')
        .replaceFirst('tel:', ''),
    msgProto: api.encodeMessageproto(
      messageproto: api.MessageProto(
        unk1: 1,
        text: message.text,
        dateRead: message.dateRead == null
            ? 0
            : RustPushBBUtils.nsSinceAppleEpoch(message.dateRead!),
        dateDelivered: message.dateDelivered == null
            ? 0
            : RustPushBBUtils.nsSinceAppleEpoch(message.dateDelivered!),
        unk10: 0,
        unk11: 0,
        unk14: 0,
      ),
    ),
    flags: api.MessageFlags.fromBitsTruncate(
      val:
          IS_FINISHED |
          IS_FROM_ME |
          IS_SENT |
          WAS_DATA_DETECTED |
          (message.isDelivered ? IS_DELIVERED : 0) |
          (message.dateRead != null ? IS_READ : 0),
    ),
    guid: guid,
    msgProto3: api.encodeMessageproto3(
      messageproto3: const api.MessageProto3(unk2: 0, unk3: 0),
    ),
    service: 'iMessage',
    msgProto4: api.encodeMessageproto4(
      messageproto4: api.MessageProto4(
        service: 'iMessage',
        scheduleType: 0,
        scheduleState: 0,
        groupId: chat.guid,
        sentOrReceivedOffGrid: 0,
      ),
    ),
  );
}
