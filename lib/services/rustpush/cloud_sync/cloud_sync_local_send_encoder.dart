import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_group_send_route.dart';
import 'cloud_sync_reaction_send_identity.dart';

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

/// Wire encoding for a plain text sent to an already-restored iMessage group.
///
/// Apple's CloudKit record uses the opaque group ID as its outer chat ID while
/// MessageProto4 retains the canonical local chat GUID. A provisional local
/// group or a group whose raw route has not been restored is never encodable.
api.CloudMessage encodeCloudSyncLocalSendGroupPlainText(Message message) {
  final chat = message.chat.target;
  final guid = message.guid;
  final route = chat == null ? null : CloudSyncGroupSendRoute.capture(chat);
  if (chat == null ||
      guid == null ||
      message.error != 0 ||
      route == null ||
      route.provisional ||
      route.groupId == null ||
      CloudSyncLocalSendIdentity.capture(message, chat, guid) == null) {
    throw StateError('cloud_sync_outbound_unsupported_message');
  }
  return api.CloudMessage(
    utm: api.utmNow(),
    type: 1,
    error: message.error,
    chatId: route.groupId!,
    sender: '',
    time: RustPushBBUtils.nsSinceAppleEpoch(message.dateCreated!),
    destinationCallerId: route.sender,
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

/// Wire encoding for a strictly validated local reaction (tapback) send.
///
/// Validates with [CloudSyncReactionSendIdentity.capture] using the row's own
/// confirmed stable GUID (strict: no submission-GUID allowance), plus the
/// canonical direct route and error-0 gate shared with the plaintext path.
/// Never mutates the local row. Emits the existing [api.CloudMessage] with
/// type=2 and the same common receipt/flags/route metadata as
/// [encodeCloudSyncLocalSendPlainText]. Standard-six adds use 2000..2005 and
/// removes use 3000..3005. The parent wire is bare when the part is null,
/// otherwise 'p:<part>/<guid>'. No range, text or attributed body is invented.
/// Admission separately proves actual IDS success and the CloudKit parent.
api.CloudMessage encodeCloudSyncLocalSendReaction(Message message) {
  final chat = message.chat.target;
  final guid = message.guid;
  if (chat == null ||
      guid == null ||
      message.error != 0 ||
      chat.guid != 'iMessage;-;${chat.chatIdentifier}' ||
      CloudSyncReactionSendIdentity.capture(message, chat, guid) == null) {
    throw StateError('cloud_sync_outbound_unsupported_message');
  }
  final reactionType = message.associatedMessageType!;
  final parentGuid = message.associatedMessageGuid!;
  final parentPart = message.associatedMessagePart;
  return api.CloudMessage(
    utm: api.utmNow(),
    type: 2,
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
        dateRead: message.dateRead == null
            ? 0
            : RustPushBBUtils.nsSinceAppleEpoch(message.dateRead!),
        dateDelivered: message.dateDelivered == null
            ? 0
            : RustPushBBUtils.nsSinceAppleEpoch(message.dateDelivered!),
        unk10: 0,
        unk11: 0,
        unk14: 0,
        associatedMessageType: _reactionWireType(reactionType),
        associatedMessageGuid: parentPart == null
            ? parentGuid
            : 'p:$parentPart/$parentGuid',
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

/// Map the standard-six row type to the wire add/remove range. Throws
/// [StateError] for emoji/sticker or any non-standard value; the row
/// validator rejects those first, so this never invents a range.
int _reactionWireType(String reactionType) {
  const order = ['love', 'like', 'dislike', 'laugh', 'emphasize', 'question'];
  final remove = reactionType.startsWith('-');
  final base = remove ? reactionType.substring(1) : reactionType;
  final index = order.indexOf(base);
  if (base.isEmpty || index < 0) {
    throw StateError('cloud_sync_outbound_unsupported_message');
  }
  return (remove ? 3000 : 2000) + index;
}
