import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_associated_message_parent_reference.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

/// Immutable validation for an outgoing iMessage reaction (tapback) send.
///
/// This is foundation only: it validates a local reaction row and its exact
/// agreement with the native `Message_React` wire. It is not wired to
/// `sendTapback`, journal capture, or admission; those integrations land
/// together with native-kind and parent-ready checks next.
///
/// What it proves: the row is a well-formed standard-six add/remove with its
/// own stable v4 GUID, a bare parent GUID plus an exactly preserved nullable
/// part, and a canonical direct-chat route. What it never proves: delivery. A
/// returned identity is usable by a future journal capture before the native
/// send and by revalidation after the `SendConfirm` callback, but only an
/// explicit `SendConfirm` success plus journal promotion authorizes upload.
///
/// Conventions inherited from the plain-text path without copying it:
/// the parent logical hash covers the parent GUID only, while the part
/// selects the target inside the parent and never alters the parent hash.
/// Only the standard six (`love/like/dislike/laugh/emphasize/question`
/// plus `-` removes) are admitted; `emoji`/`stickerback` stay rejected
/// until wire fixtures prove their native shape. The native `u64::MAX`
/// partless sentinel must never be cast into a fake part or a CloudKit
/// range: the row part is validated as a nullable u32 and the wire part is
/// compared exactly, so `null` and `0` never collapse into each other.
final class CloudSyncReactionSendIdentity {
  const CloudSyncReactionSendIdentity._(this.guidHash, this.sourceSha256);

  /// Digest of the reaction row's own stable GUID. The digest namespace
  /// intentionally matches the plain-text identity's guid namespace so a
  /// future journal intentKey derivation stays uniform across kinds.
  final String guidHash;

  /// Versioned digest of the immutable reaction source: own stable GUID,
  /// parent GUID, nullable parent part, reaction type, and chat route.
  final String sourceSha256;

  static const _standardSix = <String>{
    'love',
    'like',
    'dislike',
    'laugh',
    'emphasize',
    'question',
  };

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  /// Validate the local reaction row before a native send is attempted.
  ///
  /// Requires the row's own GUID to equal [stableGuid] exactly (UUIDv4), the
  /// parent GUID to be a bare parent reference per
  /// [CloudAssociatedMessageParentReference] (wrappers rejected, self-parent
  /// rejected, non-v4 bare values accepted), the part to be null or a valid
  /// u32, and the type to be a standard-six add/remove with no emoji
  /// payload. The provided [chat] must be the row's bound chat: a null
  /// relation is invalid, the same transient object is accepted, and a
  /// reloaded row is accepted only when it carries the same positive DB id,
  /// guid, and sender/recipient route. Pass [expectedSourceSha256] to
  /// revalidate a previously captured source instead of trusting whatever
  /// the row holds now.
  static CloudSyncReactionSendIdentity? capture(
    Message message,
    Chat chat,
    String stableGuid, {
    String? expectedSourceSha256,
  }) {
    if (!_uuid.hasMatch(stableGuid)) return null;
    if (message.guid != stableGuid) return null;
    // The provided chat must be the row's own bound chat; a row retargeted
    // at a different chat is never validated as if it belonged to it. A
    // null relation is invalid. The same transient object is accepted, and
    // an ObjectBox reload is accepted only with the same positive DB id,
    // guid, and sender/recipient route.
    final bound = message.chat.target;
    if (bound == null) return null;
    if (!identical(bound, chat) && !_samePersistedChat(bound, chat)) {
      return null;
    }
    if (message.isFromMe != true ||
        message.ckRecordId != null ||
        message.ckSyncState == true ||
        message.temp ||
        message.hasBeenForwarded ||
        message.verificationFailed ||
        message.dateCreated == null ||
        message.dateScheduled != null ||
        message.dateDeleted != null ||
        message.dateEdited != null ||
        message.subject?.isNotEmpty == true ||
        message.hasAttachments ||
        message.attachments.isNotEmpty ||
        message.dbAttachments.isNotEmpty ||
        message.messageSummaryInfo.isNotEmpty ||
        message.sendingServiceId != null ||
        message.stagingGuid != null ||
        message.threadOriginatorGuid != null ||
        message.threadOriginatorPart != null ||
        message.expressiveSendStyleId != null ||
        message.balloonBundleId != null ||
        message.payloadData != null ||
        message.hasApplePayloadData ||
        message.metadata != null ||
        message.amkSessionId != null ||
        (message.itemType ?? 0) != 0 ||
        (message.groupActionType ?? 0) != 0 ||
        message.groupTitle != null ||
        message.error != 0) {
      return null;
    }
    // This proposed minimal outbound capture accepts an empty local reaction
    // body only; it makes no claim that every iMessage reaction has no body.
    if ((message.text != null && message.text!.isNotEmpty) ||
        message.attributedBody.isNotEmpty) {
      return null;
    }
    final parentGuid = message.associatedMessageGuid;
    final parentPart = message.associatedMessagePart;
    final reactionType = message.associatedMessageType;
    if (parentGuid == null ||
        !_isBareParentGuid(parentGuid, stableGuid) ||
        (parentPart != null && (parentPart < 0 || parentPart > 0xFFFFFFFF)) ||
        reactionType == null ||
        reactionType.isEmpty ||
        !_standardSix.contains(
          reactionType.startsWith('-')
              ? reactionType.substring(1)
              : reactionType,
        ) ||
        message.associatedMessageEmoji != null) {
      return null;
    }
    // Canonical direct-chat route only. Provisional origins are out of scope:
    // supporting them needs the shared route helpers extracted from the
    // plain-text identity, not a second copy of that validator.
    if (chat.style != 45 ||
        chat.isRpSms ||
        chat.isRoutingStub ||
        chat.usingHandle?.isNotEmpty != true) {
      return null;
    }
    final participants = chat.handles.toList(growable: false);
    if (participants.length != 1 || participants.single.service != 'iMessage') {
      return null;
    }
    final recipient = participants.single.address;
    if (recipient.isEmpty ||
        chat.chatIdentifier != recipient ||
        chat.guid != 'iMessage;-;$recipient') {
      return null;
    }
    final sourceHash = _digest([
      'cloud-sync-local-send-reaction-v1',
      stableGuid,
      parentGuid,
      parentPart,
      reactionType,
      chat.guid,
      chat.chatIdentifier,
      chat.usingHandle,
    ]);
    if (expectedSourceSha256 != null && expectedSourceSha256 != sourceHash) {
      return null;
    }
    return CloudSyncReactionSendIdentity._(
      _digest(['cloud-sync-local-send-guid-v1', stableGuid]),
      sourceHash,
    );
  }

  /// Validate exact agreement between the local row and the native wire.
  ///
  /// The wire id must equal the row's stable GUID, the native kind plus
  /// enable flag must reproduce the row's type string exactly, and the
  /// native parent GUID plus nullable part must match the row exactly. The
  /// conversation must be present with the chat guid as senderGuid and the
  /// exact sorted recipient-plus-sender multiset, matching the plain-text
  /// path. `toText` and the embedded profile are transport snapshots and
  /// are deliberately not bound into the identity.
  static CloudSyncReactionSendIdentity? captureWire(
    Message message,
    Chat chat,
    api.MessageInst wire, {
    String? expectedSourceSha256,
  }) {
    final identity = capture(
      message,
      chat,
      wire.id,
      expectedSourceSha256: expectedSourceSha256,
    );
    if (identity == null ||
        wire.verificationFailed ||
        wire.target != null ||
        wire.sender != chat.usingHandle) {
      return null;
    }
    final conversation = wire.conversation;
    if (conversation == null || conversation.senderGuid != chat.guid) {
      return null;
    }
    final payload = wire.message;
    if (payload is! api.Message_React) return null;
    final react = payload.field0;
    if (react.reaction is! api.ReactMessageType_React) return null;
    final typed = react.reaction as api.ReactMessageType_React;
    final String base;
    final native = typed.reaction;
    if (native is api.Reaction_Heart) {
      base = 'love';
    } else if (native is api.Reaction_Like) {
      base = 'like';
    } else if (native is api.Reaction_Dislike) {
      base = 'dislike';
    } else if (native is api.Reaction_Laugh) {
      base = 'laugh';
    } else if (native is api.Reaction_Emphasize) {
      base = 'emphasize';
    } else if (native is api.Reaction_Question) {
      base = 'question';
    } else {
      // Emoji and sticker natives stay out until wire fixtures land.
      return null;
    }
    if (react.toUuid != message.associatedMessageGuid ||
        react.toPart != message.associatedMessagePart ||
        message.associatedMessageType != (typed.enable ? base : '-$base')) {
      return null;
    }
    final wireRecipient = chat.handles.single.address;
    final expectedParticipants = <String>[
      wireRecipient.contains('@')
          ? 'mailto:$wireRecipient'
          : 'tel:$wireRecipient',
      chat.usingHandle!,
    ]..sort();
    final actualParticipants = conversation.participants.toList()..sort();
    if (jsonEncode(actualParticipants) != jsonEncode(expectedParticipants)) {
      return null;
    }
    return identity;
  }

  static bool _isBareParentGuid(String parentGuid, String stableGuid) {
    if (parentGuid == stableGuid) return false;
    try {
      final ref = CloudAssociatedMessageParentReference.parse(parentGuid);
      return ref.part == null && ref.localMessageGuid == parentGuid;
    } on CloudAssociatedMessageParentReferenceFormatException {
      return false;
    }
  }

  static bool _samePersistedChat(Chat bound, Chat chat) {
    final boundId = bound.id;
    final chatId = chat.id;
    if (boundId == null ||
        boundId <= 0 ||
        chatId != boundId ||
        bound.guid != chat.guid ||
        bound.chatIdentifier != chat.chatIdentifier ||
        bound.usingHandle != chat.usingHandle) {
      return false;
    }
    return true;
  }

  static String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  @override
  String toString() => 'CloudSyncReactionSendIdentity(redacted)';
}
