import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

/// Immutable eligibility for a message observed on the live IDS receive path.
///
/// This primitive answers one question: is this persisted [Message] plus its
/// bound [Chat] a well-formed plain-text iMessage that arrived via the
/// supplied live receive observation, and is therefore a candidate for a
/// future received-archive lane? It grants no upload authority, performs no
/// network requests or database writes, and never mutates its inputs. Model
/// relations may be loaded by their normal getters.
///
/// Honest limits, read once. The live context below is a caller claim, not
/// authentication: a `true` flag plus cleared send markers cannot prove a
/// fully-sent local row is foreign-origin, because an own-device echo can
/// look mirrored. The row's legacy CloudKit flags (`ckRecordId`,
/// `ckSyncState`) cover only the legacy mapping; a future admission lane must
/// still check the V2 record-map and snapshot plus the existing outgoing
/// journal before authorizing any remote write. A returned identity must not
/// be treated as permission to save to CloudKit, and this file contains no
/// such call.
///
/// Plain text first: media, replies, reactions, and rich payloads are
/// reported with explicit ineligibility codes so no caller can mistake them
/// for covered archive shapes. Group chats stay explicitly unsupported in
/// this bounded step; provisional (bare-UUID) direct rows are covered.
enum CloudSyncReceivedArchiveOrigin {
  /// Sender is not one of the locally observed handles. The row keeps
  /// `isFromMe == false`; this primitive preserves that value and never
  /// flips it.
  incoming,

  /// Sender is one of the locally observed handles but the row arrived
  /// through the receive path rather than the local composer.
  /// `isFromMe == true` is preserved, never reinterpreted as a fresh local
  /// submission.
  mirrored,
}

/// Caller-supplied observation that the wire arrived via the live native
/// receive callback. This records where the caller saw the wire, not proof
/// of authentication. Locally-composed sends must not be presented with
/// [observedViaLiveReceive] set to true; they belong to the local-send lane.
final class CloudSyncReceivedArchiveLiveContext {
  const CloudSyncReceivedArchiveLiveContext({
    required this.observedViaLiveReceive,
    required this.observedLocalHandles,
    required this.receivedOnHandle,
  });

  final bool observedViaLiveReceive;

  /// Raw handle strings exactly as observed alongside the receive callback
  /// (the same representation reflection uses for its direction check and
  /// `rustParticipantsToBB` uses to split self from peers). Compared by exact
  /// string equality; the only normalization used anywhere here is the bare
  /// `mailto:`/`tel:` prefix comparison for route binding.
  final List<String> observedLocalHandles;

  /// Exact addressed local handle from IDSRecvMessage.target (tP). Capture
  /// before native conversion: MessageInst.target is a reply-device token,
  /// and certifiedContext carries tP only for certified messages. Never infer
  /// this from chat.usingHandle or choose an arbitrary account alias.
  final String receivedOnHandle;
}

/// Result of one pure eligibility check. [CloudSyncReceivedArchiveEligible]
/// carries the bound identity; [CloudSyncReceivedArchiveIneligible] carries
/// a fixed machine-readable reason code only, never raw content.
sealed class CloudSyncReceivedArchiveCapture {
  const CloudSyncReceivedArchiveCapture();
}

/// Eligible received plain-text candidate with its immutable source binding.
final class CloudSyncReceivedArchiveEligible
    extends CloudSyncReceivedArchiveCapture {
  const CloudSyncReceivedArchiveEligible(this.identity);

  final CloudSyncReceivedArchiveIdentity identity;
}

/// Explicit rejection with a fixed [reason] code (for example
/// `cloud_sync_received_archive_media`). The code contains no message
/// content, GUIDs, handles, or timestamps, so it is safe to log.
final class CloudSyncReceivedArchiveIneligible
    extends CloudSyncReceivedArchiveCapture {
  const CloudSyncReceivedArchiveIneligible(this.reason);

  final String reason;
}

/// Immutable source identity for one eligible received plain-text message.
///
/// [guidHash] and [sourceSha256] use a `cloud-sync-received-archive-*`
/// namespace deliberately distinct from the `cloud-sync-local-send-*`
/// namespace so a received candidate can never collide with an outgoing send
/// identity. These are lane-local digests, not cross-lane deduplication proof.
/// The source binds the wire conversation and direct peer, not mutable local
/// chat aliases or the outgoing sender preference. Admission must separately
/// revalidate the persisted parent and its protected CloudKit binding.
final class CloudSyncReceivedArchiveIdentity {
  const CloudSyncReceivedArchiveIdentity._(
    this.guidHash,
    this.sourceSha256,
    this.origin,
  );

  /// Digest of the row's exact persisted GUID.
  final String guidHash;

  /// Versioned digest of the immutable received source.
  final String sourceSha256;

  /// Whether the row arrived from another party or was mirrored from this
  /// account's other device. Both preserve the row's original `isFromMe`.
  final CloudSyncReceivedArchiveOrigin origin;

  static const String reasonNotLiveReceive =
      'cloud_sync_received_archive_not_live_receive';
  static const String reasonGuidMismatch =
      'cloud_sync_received_archive_guid_mismatch';
  static const String reasonTempGuid = 'cloud_sync_received_archive_temp_guid';
  static const String reasonVerificationFailed =
      'cloud_sync_received_archive_verification_failed';
  static const String reasonLegacyMapped =
      'cloud_sync_received_archive_legacy_mapped';
  static const String reasonUnpersisted =
      'cloud_sync_received_archive_unpersisted';
  static const String reasonDirectionMismatch =
      'cloud_sync_received_archive_direction_mismatch';
  static const String reasonSendState =
      'cloud_sync_received_archive_send_state';
  static const String reasonSystemMessage =
      'cloud_sync_received_archive_system_message';
  static const String reasonScheduled = 'cloud_sync_received_archive_scheduled';
  static const String reasonNotIMessage =
      'cloud_sync_received_archive_not_imessage';
  static const String reasonSms = 'cloud_sync_received_archive_sms';
  static const String reasonReply = 'cloud_sync_received_archive_reply';
  static const String reasonReaction = 'cloud_sync_received_archive_reaction';
  static const String reasonMedia = 'cloud_sync_received_archive_media';
  static const String reasonRichPayload =
      'cloud_sync_received_archive_rich_payload';
  static const String reasonGroup = 'cloud_sync_received_archive_group';
  static const String reasonRoute = 'cloud_sync_received_archive_route';
  static const String reasonCounterparts =
      'cloud_sync_received_archive_counterparts';
  static const String reasonSender = 'cloud_sync_received_archive_sender';
  static const String reasonRecipient = 'cloud_sync_received_archive_recipient';
  static const String reasonBody = 'cloud_sync_received_archive_body';
  static const String reasonWireBodyMismatch =
      'cloud_sync_received_archive_wire_body_mismatch';
  static const String reasonTarget = 'cloud_sync_received_archive_target';
  static const String reasonSourceChanged =
      'cloud_sync_received_archive_source_changed';

  /// Pure eligibility check over an already-persisted row, its bound chat,
  /// and the exact wire object delivered to the live receive callback.
  ///
  /// Both rows must carry positive database ids and the message must be bound
  /// to the supplied chat. The caller must load them from the intended store;
  /// assigned ids alone cannot establish persistence or provenance. Pass
  /// [expectedSourceSha256] to revalidate a previously captured source.
  /// Scope, account, protected-source staging, V2 record-map checks, and
  /// remote record naming are intentionally not handled here.
  static CloudSyncReceivedArchiveCapture capture({
    required Message message,
    required Chat chat,
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    String? expectedSourceSha256,
  }) => _capture(
    message: message,
    chat: chat,
    wire: wire,
    liveContext: liveContext,
    expectedSourceSha256: expectedSourceSha256,
    requirePersistedMessage: true,
  );

  /// Shape-only preflight before the receive persistence callback. This never
  /// replaces capture on database-loaded rows inside journal adoption.
  static CloudSyncReceivedArchiveCapture preview({
    required Message message,
    required Chat chat,
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
  }) => _capture(
    message: message,
    chat: chat,
    wire: wire,
    liveContext: liveContext,
    requirePersistedMessage: false,
  );

  static CloudSyncReceivedArchiveCapture _capture({
    required Message message,
    required Chat chat,
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    String? expectedSourceSha256,
    required bool requirePersistedMessage,
  }) {
    if (!liveContext.observedViaLiveReceive ||
        liveContext.observedLocalHandles.isEmpty) {
      return const CloudSyncReceivedArchiveIneligible(reasonNotLiveReceive);
    }
    final receivedOnHandle = liveContext.receivedOnHandle;
    if (receivedOnHandle.isEmpty ||
        !liveContext.observedLocalHandles.contains(receivedOnHandle) ||
        wire.receivedOnHandle != receivedOnHandle) {
      return const CloudSyncReceivedArchiveIneligible(reasonRecipient);
    }

    final guid = message.guid;
    if (guid == null ||
        guid.isEmpty ||
        guid.trim() != guid ||
        wire.id.isEmpty ||
        guid != wire.id) {
      return const CloudSyncReceivedArchiveIneligible(reasonGuidMismatch);
    }
    if (guid.startsWith('temp') || guid.startsWith('error')) {
      return const CloudSyncReceivedArchiveIneligible(reasonTempGuid);
    }

    if (wire.verificationFailed || message.verificationFailed) {
      return const CloudSyncReceivedArchiveIneligible(reasonVerificationFailed);
    }

    // Legacy mapping only. A null record id here says nothing about the V2
    // record-map, snapshot, or outgoing journal; those are future gates.
    if (message.ckRecordId != null || message.ckSyncState == true) {
      return const CloudSyncReceivedArchiveIneligible(reasonLegacyMapped);
    }

    if ((requirePersistedMessage && (message.id == null || message.id! <= 0)) ||
        chat.id == null ||
        chat.id! <= 0) {
      return const CloudSyncReceivedArchiveIneligible(reasonUnpersisted);
    }

    final sender = wire.sender;
    if (sender == null || sender.isEmpty) {
      return const CloudSyncReceivedArchiveIneligible(reasonDirectionMismatch);
    }
    final certified = wire.certifiedContext;
    if (certified != null &&
        (certified.target != receivedOnHandle || certified.sender != sender)) {
      return const CloudSyncReceivedArchiveIneligible(reasonRecipient);
    }
    final senderIsLocal = liveContext.observedLocalHandles.contains(sender);
    final CloudSyncReceivedArchiveOrigin origin;
    if (senderIsLocal && message.isFromMe == true) {
      origin = CloudSyncReceivedArchiveOrigin.mirrored;
    } else if (!senderIsLocal && message.isFromMe == false) {
      origin = CloudSyncReceivedArchiveOrigin.incoming;
    } else {
      return const CloudSyncReceivedArchiveIneligible(reasonDirectionMismatch);
    }

    if (message.error != 0 ||
        message.temp ||
        message.stagingGuid != null ||
        message.sendingServiceId != null ||
        message.hasBeenForwarded) {
      return const CloudSyncReceivedArchiveIneligible(reasonSendState);
    }

    if ((message.itemType ?? 0) != 0 ||
        (message.groupActionType ?? 0) != 0 ||
        message.groupTitle != null ||
        message.dateDeleted != null) {
      return const CloudSyncReceivedArchiveIneligible(reasonSystemMessage);
    }
    if (message.dateScheduled != null) {
      return const CloudSyncReceivedArchiveIneligible(reasonScheduled);
    }

    final wireMessage = wire.message;
    if (wireMessage is! api.Message_Message) {
      return const CloudSyncReceivedArchiveIneligible(reasonNotIMessage);
    }
    final normal = wireMessage.field0;
    if (normal.service is! api.MessageType_IMessage) {
      return const CloudSyncReceivedArchiveIneligible(reasonNotIMessage);
    }
    if (chat.isRpSms) {
      return const CloudSyncReceivedArchiveIneligible(reasonSms);
    }

    if (message.threadOriginatorGuid != null ||
        message.threadOriginatorPart != null ||
        normal.replyGuid != null ||
        normal.replyPart != null) {
      return const CloudSyncReceivedArchiveIneligible(reasonReply);
    }
    if (message.associatedMessageGuid != null ||
        message.associatedMessagePart != null ||
        message.associatedMessageType != null ||
        message.associatedMessageEmoji != null) {
      return const CloudSyncReceivedArchiveIneligible(reasonReaction);
    }

    if (message.hasAttachments ||
        message.attachments.isNotEmpty ||
        message.dbAttachments.isNotEmpty) {
      return const CloudSyncReceivedArchiveIneligible(reasonMedia);
    }

    if (message.subject?.isNotEmpty == true ||
        normal.subject?.isNotEmpty == true ||
        message.expressiveSendStyleId != null ||
        normal.effect != null ||
        message.balloonBundleId != null ||
        normal.app != null ||
        normal.linkMeta != null ||
        message.payloadData != null ||
        message.hasApplePayloadData ||
        message.amkSessionId != null ||
        message.messageSummaryInfo.isNotEmpty ||
        message.dateEdited != null ||
        normal.voice ||
        normal.scheduled != null ||
        normal.embeddedProfile != null) {
      return const CloudSyncReceivedArchiveIneligible(reasonRichPayload);
    }

    final bound = message.chat.target;
    if ((bound == null && (requirePersistedMessage || (message.id ?? 0) > 0)) ||
        chat.dateDeleted != null) {
      return const CloudSyncReceivedArchiveIneligible(reasonRoute);
    }
    if (bound != null &&
        !identical(bound, chat) &&
        !_samePersistedChat(bound, chat)) {
      return const CloudSyncReceivedArchiveIneligible(reasonRoute);
    }
    final participants = chat.handles.toList(growable: false);
    if (participants.length > 1 ||
        chat.style == 43 ||
        chat.guid.startsWith('iMessage;+;')) {
      return const CloudSyncReceivedArchiveIneligible(reasonGroup);
    }
    if (participants.length != 1 ||
        participants.single.service != 'iMessage' ||
        participants.single.address.isEmpty) {
      return const CloudSyncReceivedArchiveIneligible(reasonRoute);
    }
    final chatIdentifier = chat.chatIdentifier;
    final bool canonicalDirect =
        chat.style == 45 &&
        !chat.isRoutingStub &&
        chatIdentifier != null &&
        chatIdentifier.isNotEmpty &&
        chat.guid == 'iMessage;-;$chatIdentifier' &&
        participants.single.address == chatIdentifier;
    // Provisional direct row from `createChat` on first receive: bare-UUID
    // guid, no style or chat identifier yet. Protected cloud-parent
    // resolution stays a later admission gate.
    final bool provisionalDirect =
        _uuid.hasMatch(chat.guid) &&
        chat.style == null &&
        chatIdentifier == null &&
        !chat.isRoutingStub;
    if (!canonicalDirect && !provisionalDirect) {
      return const CloudSyncReceivedArchiveIneligible(reasonRoute);
    }

    // Conversation evidence is required, never bypassed when null. Peer
    // split mirrors `rustParticipantsToBB`: exact raw self entries are
    // removed, and the remainder must be exactly the bound remote
    // counterpart. The sender is deliberately not required to appear in
    // participants: native receive may omit it for mirrored rows.
    final conversation = wire.conversation;
    if (conversation == null || conversation.participants.isEmpty) {
      return const CloudSyncReceivedArchiveIneligible(reasonCounterparts);
    }
    final remoteCounterparts = conversation.participants
        .where((p) => !liveContext.observedLocalHandles.contains(p))
        .map(_bare)
        .toSet();
    if (remoteCounterparts.length != 1 ||
        remoteCounterparts.single != participants.single.address) {
      return const CloudSyncReceivedArchiveIneligible(reasonCounterparts);
    }
    final senderGuid = conversation.senderGuid;
    if (senderGuid != null &&
        senderGuid != chat.guid &&
        senderGuid != chat.cloudGuid &&
        !chat.guidRefs.contains(senderGuid)) {
      return const CloudSyncReceivedArchiveIneligible(reasonCounterparts);
    }
    if (origin == CloudSyncReceivedArchiveOrigin.incoming) {
      if (_bare(sender) != remoteCounterparts.single) {
        return const CloudSyncReceivedArchiveIneligible(reasonRoute);
      }
    }

    // Stored-sender binding from `reflectMessageDyn` plus the
    // `handleNewMessage` persistence rewrite: an incoming row keeps the
    // chat's remote handle, while a mirrored row keeps its own sender row
    // (or nothing when the fallback lookup misses). Either way the stored
    // address must equal the wire sender; a null or foreign handle carries
    // no sender evidence.
    final storedHandle = message.handle;
    if (storedHandle == null || storedHandle.address != _bare(sender)) {
      return const CloudSyncReceivedArchiveIneligible(reasonSender);
    }
    final storedRowId = message.handleId;
    final storedHandleRowId = storedHandle.originalROWID;
    if (storedRowId != null &&
        storedHandleRowId != null &&
        storedRowId != storedHandleRowId) {
      return const CloudSyncReceivedArchiveIneligible(reasonSender);
    }

    final text = message.text;
    if (text == null || text.trim().isEmpty) {
      return const CloudSyncReceivedArchiveIneligible(reasonBody);
    }
    if (message.attributedBody.length != 1 ||
        message.attributedBody.single.string != text) {
      return const CloudSyncReceivedArchiveIneligible(reasonBody);
    }
    if (!_isPlainBody(message.attributedBody.single, text)) {
      return const CloudSyncReceivedArchiveIneligible(reasonBody);
    }

    final wireText = StringBuffer();
    for (final indexed in normal.parts.field0) {
      if (indexed.ext != null || (indexed.idx != null && indexed.idx != 0)) {
        return const CloudSyncReceivedArchiveIneligible(reasonWireBodyMismatch);
      }
      final part = indexed.part_;
      if (part is! api.MessagePart_Text ||
          part.field1 is! api.TextFormat_Flags) {
        return const CloudSyncReceivedArchiveIneligible(reasonWireBodyMismatch);
      }
      final flags = (part.field1 as api.TextFormat_Flags).field0;
      if (flags.bold ||
          flags.italic ||
          flags.underline ||
          flags.strikethrough) {
        return const CloudSyncReceivedArchiveIneligible(reasonWireBodyMismatch);
      }
      wireText.write(part.field0);
    }
    if (wireText.toString() != text) {
      return const CloudSyncReceivedArchiveIneligible(reasonWireBodyMismatch);
    }
    // IDSRecvMessage.to_message carries an optional reply-device token for
    // iMessage too. It is routing metadata, not the addressed local handle
    // (IDS tP), and must neither reject a normal receive nor enter its digest.
    // Other explicit destinations are not a native direct-receive shape.
    final replyTargets = wire.target;
    if (replyTargets != null && replyTargets.isNotEmpty) {
      if (replyTargets.length != 1 ||
          replyTargets.single is! api.MessageTarget_Token ||
          (replyTargets.single as api.MessageTarget_Token).field0.length !=
              32) {
        return const CloudSyncReceivedArchiveIneligible(reasonTarget);
      }
    }
    final createdAt = message.dateCreated;
    if (createdAt == null ||
        createdAt.millisecondsSinceEpoch != wire.sentTimestamp) {
      return const CloudSyncReceivedArchiveIneligible(reasonWireBodyMismatch);
    }

    final wireParticipants = conversation.participants.toList(growable: false)
      ..sort();
    final guidHash = _digest(['cloud-sync-received-archive-guid-v1', guid]);
    final sourceSha256 = _digest([
      'cloud-sync-received-archive-source-v1',
      guid,
      text,
      remoteCounterparts.single,
      sender,
      receivedOnHandle,
      wire.sentTimestamp,
      origin.name,
      senderGuid ?? '',
      wireParticipants,
      conversation.cvName ?? '',
      conversation.afterGuid ?? '',
    ]);
    if (expectedSourceSha256 != null && expectedSourceSha256 != sourceSha256) {
      return const CloudSyncReceivedArchiveIneligible(reasonSourceChanged);
    }
    return CloudSyncReceivedArchiveEligible(
      CloudSyncReceivedArchiveIdentity._(guidHash, sourceSha256, origin),
    );
  }

  static bool _samePersistedChat(Chat a, Chat b) =>
      a.id != null && a.id! > 0 && a.id == b.id && a.guid == b.guid;

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static bool _isPlainBody(AttributedBody body, String text) {
    if (body.runs.isEmpty) return false;
    var end = 0;
    for (final run in body.runs) {
      final attributes = run.attributes;
      if (run.range.length != 2 ||
          run.range.first != end ||
          run.range.last <= 0 ||
          attributes == null ||
          attributes.messagePart != 0 ||
          attributes.attachmentGuid != null ||
          attributes.mention != null ||
          attributes.audioTranscript != null ||
          attributes.stickerData != null ||
          attributes.textEffect != null ||
          attributes.bold == true ||
          attributes.italic == true ||
          attributes.strikethrough == true ||
          attributes.underline == true) {
        return false;
      }
      end += run.range.last;
      if (end > text.length) return false;
    }
    return end == text.length;
  }

  static String _bare(String value) => value.startsWith('mailto:')
      ? value.substring(7)
      : value.startsWith('tel:')
      ? value.substring(4)
      : value;

  static String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  @override
  String toString() =>
      'CloudSyncReceivedArchiveIdentity(origin=${origin.name}, redacted)';
}
