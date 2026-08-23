import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

/// Read-only source used by the outbound canary candidate selector.
///
/// Implementations must not save, update, or delete any entity while reading.
abstract interface class CloudSyncOutboundCanaryMessageReader {
  List<Message> readMessages();
}

/// The production ObjectBox reader. The query is deliberately limited to
/// outgoing rows; the selector still validates [Message.isFromMe] again so a
/// different reader cannot weaken the safety boundary.
final class ObjectBoxCloudSyncOutboundCanaryMessageReader
    implements CloudSyncOutboundCanaryMessageReader {
  const ObjectBoxCloudSyncOutboundCanaryMessageReader({this.messages});

  final Box<Message>? messages;

  Box<Message> get _box => messages ?? Database.messages;

  @override
  List<Message> readMessages() {
    final query = _box.query(Message_.isFromMe.equals(true)).build();
    try {
      return query.find();
    } finally {
      query.close();
    }
  }
}

typedef CloudSyncOutboundCanaryCloudEncoder =
    api.CloudMessage Function(Message message);

/// Redacted information about one already-existing local message that passed
/// every outbound canary safety check.
///
/// The CloudMessage is intentionally available for the next, separately
/// confirmed canary step, but this object's diagnostics never include its
/// contents, destination, or local handle.
final class CloudSyncOutboundCanaryCandidate {
  CloudSyncOutboundCanaryCandidate._({
    required this.cloudMessage,
    required this.guidHash,
    required this.createdAtUtc,
    required this.characterCount,
  });

  final api.CloudMessage cloudMessage;

  /// The first 16 hexadecimal characters of SHA-256(guid).
  final String guidHash;

  final DateTime createdAtUtc;
  final int characterCount;

  Map<String, Object> toJson() => <String, Object>{
    'guidHash': guidHash,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'characterCount': characterCount,
  };

  @override
  String toString() =>
      'CloudSyncOutboundCanaryCandidate('
      'guidHash=$guidHash, '
      'createdAtUtc=${createdAtUtc.toIso8601String()}, '
      'characterCount=$characterCount)';
}

/// Selects the newest strictly ordinary, one-to-one outgoing iMessage text.
///
/// Selection is read-only. No legacy uploader is called. Conversion to a
/// [api.CloudMessage] is deferred until after all local filters pass, and the
/// default conversion is the existing [Message.toCloud] path with attachments
/// disabled. The rejected shapes are intentionally conservative because this
/// candidate is the first possible V2 write.
final class CloudSyncOutboundCanaryCandidateSelector {
  static const maximumCandidateAge = Duration(minutes: 10);

  CloudSyncOutboundCanaryCandidateSelector({
    CloudSyncOutboundCanaryMessageReader? reader,
    CloudSyncOutboundCanaryCloudEncoder? encoder,
    DateTime Function()? clock,
  }) : _reader =
           reader ?? const ObjectBoxCloudSyncOutboundCanaryMessageReader(),
       _encoder = encoder ?? ((message) => message.toCloud(true)),
       _clock = clock ?? DateTime.now;

  final CloudSyncOutboundCanaryMessageReader _reader;
  final CloudSyncOutboundCanaryCloudEncoder _encoder;
  final DateTime Function() _clock;

  /// Returns the newest eligible candidate, or null if no row is safe.
  ///
  /// Only the newest outgoing row is considered. Falling back to an older row
  /// could silently select a different conversation than the operator expects.
  CloudSyncOutboundCanaryCandidate? selectNewest() {
    final messages = List<Message>.of(_reader.readMessages());
    messages.sort(_newestFirst);
    if (messages.isEmpty) return null;

    final now = _clock().toUtc();
    final message = messages.first;
    final validated = _validate(message, now: now);
    if (validated == null) return null;

    try {
      final cloudMessage = _encoder(message);
      return CloudSyncOutboundCanaryCandidate._(
        cloudMessage: cloudMessage,
        guidHash: _guidHash(message.guid!),
        createdAtUtc: validated.createdAtUtc,
        characterCount: validated.characterCount,
      );
    } catch (_) {
      // Conversion failure rejects this selection without trying another row.
      // Message text must never enter diagnostics.
      return null;
    }
  }

  static int _newestFirst(Message left, Message right) {
    final leftDate = left.dateCreated;
    final rightDate = right.dateCreated;
    if (leftDate == null && rightDate == null) {
      return (right.guid ?? '').compareTo(left.guid ?? '');
    }
    if (leftDate == null) return 1;
    if (rightDate == null) return -1;
    final dateOrder = rightDate.compareTo(leftDate);
    if (dateOrder != 0) return dateOrder;
    return (right.guid ?? '').compareTo(left.guid ?? '');
  }

  static String _guidHash(String guid) =>
      sha256.convert(utf8.encode(guid)).toString().substring(0, 16);

  static _ValidatedCanaryMessage? _validate(
    Message message, {
    required DateTime now,
  }) {
    if (message.isFromMe != true) return null;

    final guid = message.guid;
    if (guid == null || guid.isEmpty || guid.trim() != guid) return null;
    if (guid.startsWith('temp') || guid.startsWith('error')) return null;

    final text = message.text;
    final createdAt = message.dateCreated;
    if (text == null || text.trim().isEmpty || createdAt == null) return null;
    final createdAtUtc = createdAt.toUtc();
    if (createdAtUtc.isAfter(now)) return null;
    if (now.difference(createdAtUtc) > maximumCandidateAge) return null;

    // These fields identify non-ordinary messages or a row that another
    // writer is still changing. Treat even empty metadata maps as unsafe.
    if (message.dateScheduled != null ||
        message.dateDeleted != null ||
        message.stagingGuid != null ||
        message.sendingServiceId != null ||
        message.error != 0 ||
        message.temp ||
        message.verificationFailed) {
      return null;
    }
    if (message.ckRecordId != null || message.ckSyncState) return null;
    if (message.subject?.trim().isNotEmpty == true) return null;
    if (message.expressiveSendStyleId != null ||
        message.balloonBundleId != null ||
        message.payloadData != null ||
        message.hasApplePayloadData ||
        message.metadata != null ||
        message.messageSummaryInfo.isNotEmpty ||
        message.dateEdited != null ||
        message.amkSessionId != null) {
      return null;
    }

    // Do not select a reaction, sticker, reply, group event, or any message
    // with an associated child. The associatedMessages relation is read-only.
    if (message.associatedMessageGuid != null ||
        message.associatedMessagePart != null ||
        message.associatedMessageType != null ||
        message.associatedMessageEmoji != null ||
        message.associatedMessages.isNotEmpty ||
        message.hasReactions ||
        message.threadOriginatorGuid != null ||
        message.threadOriginatorPart != null ||
        message.itemType != null && message.itemType! > 0 ||
        message.groupTitle != null ||
        message.groupActionType != null && message.groupActionType! > 0 ||
        message.bigEmoji == true) {
      return null;
    }

    // Check both serialized attachment fields and the ObjectBox relation.
    // Attachment-bearing attributed runs are rejected before toCloud(true).
    if (message.hasAttachments ||
        message.attachments.isNotEmpty ||
        message.dbAttachments.isNotEmpty) {
      return null;
    }

    final bodies = message.attributedBody;
    if (bodies.length != 1) return null;
    final body = bodies.single;
    if (body.string.isEmpty ||
        body.string.trim().isEmpty ||
        text != body.string) {
      return null;
    }

    var cursor = 0;
    if (body.runs.isEmpty) return null;
    for (final run in body.runs) {
      if (run.range.length != 2) return null;
      final start = run.range[0];
      final length = run.range[1];
      if (start != cursor || length <= 0 || start < 0) return null;
      final end = start + length;
      if (end > body.string.length) return null;

      final attributes = run.attributes;
      if (attributes == null ||
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
        return null;
      }
      cursor = end;
    }
    if (cursor != body.string.length) return null;

    final chat = message.chat.target;
    if (chat == null ||
        chat.guid.trim().isEmpty ||
        chat.chatIdentifier?.trim().isEmpty != false ||
        chat.usingHandle?.trim().isEmpty != false ||
        chat.isRpSms ||
        chat.isRoutingStub ||
        chat.style == 43) {
      return null;
    }

    final chatGuid = chat.guid.toLowerCase();
    if (chatGuid.startsWith('sms') ||
        chatGuid.startsWith('mms') ||
        chatGuid.startsWith('rcs')) {
      return null;
    }

    // A single loaded iMessage participant plus the non-group style is the
    // minimum evidence needed to safely avoid group-chat encoding.
    // Use the persisted relation directly when available. This keeps the
    // selector read-only and avoids requiring a second global ObjectBox
    // lookup merely to inspect a chat returned by the supplied box.
    final participants = chat.handles.isNotEmpty
        ? chat.handles.toList(growable: false)
        : chat.participants;
    if (participants.length != 1 || chat.style == 43) return null;
    if (participants.single.service.trim().toLowerCase() != 'imessage') {
      return null;
    }

    return _ValidatedCanaryMessage(
      createdAtUtc: createdAtUtc,
      characterCount: body.string.runes.length,
    );
  }
}

final class _ValidatedCanaryMessage {
  const _ValidatedCanaryMessage({
    required this.createdAtUtc,
    required this.characterCount,
  });

  final DateTime createdAtUtc;
  final int characterCount;
}
