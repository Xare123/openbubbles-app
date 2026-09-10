import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

/// Immutable semantic identity for an outgoing attachment-bearing send body.
///
/// Capture AFTER the MMCS upload persists the exact descriptor XML into
/// `Attachment.metadata['rustpush']` but BEFORE IDS submission. The digest
/// then survives the local reflection write (the incoming echo that stores
/// the same descriptor XML under a new `<msgId>_<fieldIdx>` GUID with a
/// literal-space placeholder): the local attachment GUID becomes
/// `<msgId>_<fieldIdx>` and the attachment placeholder may read as U+FFFC
/// pre-reflection or a literal space post-reflection. Neither value enters
/// the digest. Descriptor XML strings (the exact `metadata['rustpush']`
/// payloads that `sendAttachment` stores), text content with its formatting
/// flags, token order, and token kinds do, so a replaced or reordered
/// descriptor, an edited text run, or a changed text/attachment sequence all
/// change [sourceSha256].
///
/// Reflection here is the local echo write, not CloudKit.
///
/// The capture keeps raw descriptor and text strings in memory only. They are
/// never logged and never persisted; [toString] is redacted.
///
/// This helper is identity evidence only. It is not send or upload authority:
/// the parent validates route, normal-message metadata, and the staged native
/// source before anything is enabled.
final class CloudSyncAttachmentSendBody {
  const CloudSyncAttachmentSendBody._({
    required this.sourceSha256,
    required this._attachmentGuids,
    required this._descriptorStrings,
    required this._tokens,
  });

  /// Conservative local bounds. Anything beyond them fails closed (null /
  /// false) instead of hashing an unbounded body.
  static const int maxAttachments = 64;
  static const int maxRuns = 128;
  static const int maxDescriptorBytes = 1048576;
  static const int maxTextBytes = 1048576;

  static const String _domain = 'bluebubbles.cloud-sync.attachment-send-body';
  static const String _version = '1';

  /// Length-framed semantic digest. Stable across the reflection GUID rename
  /// and the U+FFFC/space placeholder alias.
  final String sourceSha256;
  final List<String> _attachmentGuids;
  final List<String> _descriptorStrings;
  final List<_BodyToken> _tokens;

  /// Exact ordered local attachment GUIDs, retained separately from the
  /// descriptors. GUIDs never enter [sourceSha256].
  List<String> get attachmentGuids => List.unmodifiable(_attachmentGuids);

  /// Exact ordered descriptor XML strings, retained separately from the GUIDs.
  List<String> get descriptorStrings => List.unmodifiable(_descriptorStrings);

  /// Captures the send-body identity of [message], or null when the body is
  /// absent, malformed, out of bounds, or carries anything this digest does
  /// not model (mentions, text effects, stickers, transcripts, live photos).
  ///
  /// Attachment runs resolve by exact GUID against [Message.attachments] and
  /// [Message.dbAttachments] only. No global database lookup is performed.
  static CloudSyncAttachmentSendBody? capture(Message message) {
    final bodies = message.attributedBody;
    // Exactly one body: multiple bodies have no defined wire order and the
    // send path only ever submits `.first`.
    if (bodies.length > 1) return null;
    if (bodies.isEmpty) return _capturePreSend(message);
    final body = bodies.first;
    if (body.string.isEmpty && body.runs.isEmpty) {
      return _capturePreSend(message);
    }
    return _captureFromBody(message, body);
  }

  /// Matches a staged wire message against this capture.
  ///
  /// The wire side is rebuilt into the same canonical token stream: plain
  /// (flags-format) text plus MMCS, non-iris attachments whose descriptor
  /// strings come from [serializeAttachment] (the test seam standing in for
  /// `api.saveAttachment`; the production caller injects the real
  /// serializer). Descriptor XML is compared as exact strings in order.
  /// Anything else on the wire (mention/object parts, effect-format text,
  /// inline attachments, iris attachments, part extensions, voice messages)
  /// returns false. Bounded and fail-closed: oversized wire bodies return
  /// false. Nothing is logged and no raw wire data is retained.
  ///
  /// The wire body is fingerprinted synchronously before the first
  /// serializer await and re-fingerprinted after the awaits: if the
  /// callback replaced the staged message or mutated attachment bytes or
  /// the parts list in place, the fingerprints differ and the match fails
  /// instead of validating stale parts. Header and route state stay out of
  /// scope here; the parent revalidates those.
  Future<bool> matchesWire(
    api.MessageInst wire, {
    required Future<String> Function(api.Attachment) serializeAttachment,
  }) async {
    final message = wire.message;
    if (message is! api.Message_Message) return false;
    final normal = message.field0;
    if (normal.voice) return false;
    final parts = normal.parts.field0;
    if (parts.length > maxRuns) return false;
    // Synchronous content snapshot before the first serializer await. The
    // callback runs arbitrary async code; without this, a replaced message
    // or an in-place mutation could validate against stale parts.
    final snapshot = _wireSnapshot(parts);
    if (snapshot == null) return false;
    // Stable copy for token building: the live list may be replaced or
    // extended under the serializer awaits below, which must fail closed
    // via the snapshot recheck rather than throw mid-iteration.
    final frozen = List<api.IndexedMessagePart>.of(parts);
    final tokens = <_BodyToken>[];
    var attachmentCount = 0;
    var descriptorBytes = 0;
    var textBytes = 0;
    for (final indexed in frozen) {
      // Unextended only: any part extension (stickers and friends) is out
      // of scope for this digest.
      if (indexed.ext != null) return false;
      // Composer wire leaves `idx` unset; a set index must be valid.
      if (indexed.idx != null && indexed.idx! < 0) return false;
      final part = indexed.part_;
      if (part is api.MessagePart_Text) {
        final format = part.field1;
        if (format is! api.TextFormat_Flags) return false;
        textBytes += utf8.encode(part.field0).length;
        if (textBytes > maxTextBytes) return false;
        _appendText(tokens, part.field0, _flagsOf(format.field0));
      } else if (part is api.MessagePart_Attachment) {
        final attachment = part.field0;
        if (attachment.iris) return false;
        if (attachment.aType is! api.AttachmentType_MMCS) return false;
        attachmentCount += 1;
        if (attachmentCount > maxAttachments) return false;
        final String descriptor;
        try {
          descriptor = await serializeAttachment(attachment);
        } catch (_) {
          return false;
        }
        if (descriptor.isEmpty) return false;
        descriptorBytes += utf8.encode(descriptor).length;
        if (descriptorBytes > maxDescriptorBytes) return false;
        tokens.add(_BodyToken.attachment(_sha256Hex(descriptor)));
      } else {
        // Mentions, objects, and any future part kind are rejected: the
        // local capture cannot model them either.
        return false;
      }
    }
    if (tokens.isEmpty) return false;
    // Attachment-origin variant only: a text-only wire message never matches.
    if (attachmentCount < 1) return false;
    // Fail closed when the staged wire changed under the awaits.
    final reseated = wire.message;
    if (reseated is! api.Message_Message) return false;
    if (reseated.field0.voice) return false;
    if (_wireSnapshot(reseated.field0.parts.field0) != snapshot) return false;
    if (tokens.length != _tokens.length) return false;
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i] != _tokens[i]) return false;
    }
    return true;
  }

  /// Synchronous content fingerprint of the supported wire body: ordered
  /// part indexes, exact text with flags, and complete attachment fields
  /// (MMCS object/url/size plus base64 key/signature, or inline bytes; part,
  /// UTI, MIME, name, iris). Part extensions and unmodeled part kinds fail
  /// the snapshot, matching the wire matcher. Counts and text sizes reuse
  /// the same bounds; the raw snapshot lives in memory only and is never
  /// logged.
  static String? _wireSnapshot(List<api.IndexedMessagePart> parts) {
    if (parts.length > maxRuns) return null;
    final out = BytesBuilder(copy: false);
    var budget = maxTextBytes + maxDescriptorBytes;
    bool take(List<int> bytes) {
      budget -= bytes.length;
      if (budget < 0) return false;
      out.add(utf8.encode('${bytes.length}:'));
      out.add(bytes);
      out.addByte(0);
      return true;
    }

    bool takeString(String value) => take(utf8.encode(value));
    var attachments = 0;
    for (final indexed in parts) {
      if (indexed.ext != null) return null;
      if (!takeString(indexed.idx?.toString() ?? 'null')) return null;
      final part = indexed.part_;
      if (part is api.MessagePart_Text) {
        final format = part.field1;
        if (format is! api.TextFormat_Flags) return null;
        if (!takeString('T') ||
            !takeString(part.field0) ||
            !takeString(_flagsOf(format.field0).toString())) {
          return null;
        }
      } else if (part is api.MessagePart_Attachment) {
        final attachment = part.field0;
        attachments += 1;
        if (attachments > maxAttachments) return null;
        if (!takeString('A')) return null;
        final kind = attachment.aType;
        if (kind is api.AttachmentType_Inline) {
          if (!takeString('I') || !take(kind.field0)) return null;
        } else if (kind is api.AttachmentType_MMCS) {
          final file = kind.field0;
          if (!takeString('M') ||
              !take(file.signature) ||
              !takeString(file.object) ||
              !takeString(file.url) ||
              !take(file.key) ||
              !takeString(file.size.toString())) {
            return null;
          }
        } else {
          return null;
        }
        if (!takeString(attachment.part_.toString()) ||
            !takeString(attachment.utiType) ||
            !takeString(attachment.mime) ||
            !takeString(attachment.name) ||
            !takeString(attachment.iris.toString())) {
          return null;
        }
      } else {
        return null;
      }
    }
    return sha256.convert(out.toBytes()).toString();
  }

  /// Single-attachment pre-send row (composer queue shape): no attributed
  /// body, empty/null text, exactly one attachment. Normalized to a single
  /// attachment token so it aliases the post-reflection body capture.
  ///
  /// This matches the composer in `send_animation.dart`, which queues one
  /// attachment message per file with empty text and no attributed body.
  static CloudSyncAttachmentSendBody? _capturePreSend(Message message) {
    final text = message.text;
    if (text != null && text.isNotEmpty) return null;
    final candidates = _candidateAttachments(message);
    if (candidates == null || candidates.length != 1) return null;
    final attachment = candidates.single;
    final descriptor = _descriptorOf(attachment);
    if (descriptor == null) return null;
    if (utf8.encode(descriptor).length > maxDescriptorBytes) return null;
    final tokens = [_BodyToken.attachment(_sha256Hex(descriptor))];
    return CloudSyncAttachmentSendBody._(
      sourceSha256: _digest(tokens),
      attachmentGuids: [attachment.guid!],
      descriptorStrings: [descriptor],
      tokens: tokens,
    );
  }

  static CloudSyncAttachmentSendBody? _captureFromBody(
    Message message,
    AttributedBody body,
  ) {
    final runs = body.runs;
    if (runs.length > maxRuns) return null;
    // The row text column must agree with the body string when it is set.
    // A null text is the composer shape that has not synced its text column.
    final rowText = message.text;
    if (rowText != null && rowText != body.string) return null;
    final candidates = _candidateAttachments(message);
    if (candidates == null) return null;
    // Candidates arrive merged to one entry per GUID: identical same-GUID
    // rows from `attachments` and `dbAttachments` collapse, while
    // conflicting same-GUID rows already failed the capture inside
    // `_candidateAttachments`.
    final byGuid = <String, Attachment>{
      for (final attachment in candidates) attachment.guid!: attachment,
    };
    final tokens = <_BodyToken>[];
    final guids = <String>[];
    final descriptors = <String>[];
    final used = <String>{};
    var descriptorBytes = 0;
    var textBytes = 0;
    var cursor = 0;
    for (final run in runs) {
      final range = run.range;
      final attributes = run.attributes;
      // Contiguous exact ranges only: no gaps, overlaps, or ragged ends.
      if (range.length != 2 || attributes == null) return null;
      final start = range[0];
      final length = range[1];
      if (start != cursor || length < 0) return null;
      if (attributes.mention != null ||
          attributes.audioTranscript != null ||
          attributes.stickerData != null ||
          attributes.textEffect != null) {
        return null;
      }
      final attachmentGuid = attributes.attachmentGuid;
      if (attachmentGuid != null) {
        // Attachment placeholder is exactly one char: U+FFFC pre-reflection
        // or a literal space post-reflection. Either is accepted and neither
        // enters the digest.
        if (length != 1) return null;
        if (cursor >= body.string.length) return null;
        final placeholder = body.string[cursor];
        if (placeholder != '\uFFFC' && placeholder != ' ') return null;
        if (attributes.bold == true ||
            attributes.italic == true ||
            attributes.underline == true ||
            attributes.strikethrough == true) {
          return null;
        }
        if (attachmentGuid.isEmpty || !used.add(attachmentGuid)) {
          // Missing GUID spelling, or the same GUID claimed twice.
          return null;
        }
        final attachment = byGuid[attachmentGuid];
        if (attachment == null) return null;
        final descriptor = _descriptorOf(attachment);
        if (descriptor == null) return null;
        descriptorBytes += utf8.encode(descriptor).length;
        if (descriptorBytes > maxDescriptorBytes) return null;
        if (guids.length >= maxAttachments) return null;
        guids.add(attachmentGuid);
        descriptors.add(descriptor);
        tokens.add(_BodyToken.attachment(_sha256Hex(descriptor)));
        cursor += length;
        continue;
      }
      if (length < 1) return null;
      if (start + length > body.string.length) return null;
      final text = body.string.substring(start, start + length);
      textBytes += utf8.encode(text).length;
      if (textBytes > maxTextBytes) return null;
      _appendText(tokens, text, _flagsOfAttributes(attributes));
      cursor += length;
    }
    if (cursor != body.string.length) return null;
    if (tokens.isEmpty) return null;
    if (guids.isEmpty) return null;
    // Unreferenced: attachment rows with no run claiming them.
    if (used.length != byGuid.length) return null;
    return CloudSyncAttachmentSendBody._(
      sourceSha256: _digest(tokens),
      attachmentGuids: guids,
      descriptorStrings: descriptors,
      tokens: tokens,
    );
  }

  /// In-memory candidate rows only. Never touches the global database.
  ///
  /// The same row often appears in both `attachments` and `dbAttachments`.
  /// Rows sharing a GUID merge only when they carry the exact same
  /// descriptor payload; conflicting same-GUID rows fail the capture.
  static List<Attachment>? _candidateAttachments(Message message) {
    final seen = <Attachment>[];
    for (final attachment in message.attachments) {
      if (attachment == null) return null;
      if (attachment.guid == null || attachment.guid!.isEmpty) return null;
      seen.add(attachment);
    }
    try {
      for (final attachment in message.dbAttachments) {
        if (attachment.guid == null || attachment.guid!.isEmpty) {
          return null;
        }
        seen.add(attachment);
      }
    } catch (_) {
      return null;
    }
    final merged = <String, Attachment>{};
    final descriptorByGuid = <String, String>{};
    for (final attachment in seen) {
      final descriptor = _descriptorOf(attachment);
      if (descriptor == null) return null;
      final existing = descriptorByGuid[attachment.guid!];
      if (existing == null) {
        merged[attachment.guid!] = attachment;
        descriptorByGuid[attachment.guid!] = descriptor;
      } else if (existing != descriptor) {
        return null;
      }
    }
    return merged.values.toList();
  }

  /// The exact stored descriptor XML for one attachment row, or null when the
  /// row cannot participate. Local filenames, isOutgoing, cache state, ids,
  /// and paths are deliberately never consulted: reflection changes them.
  static String? _descriptorOf(Attachment attachment) {
    if (attachment.hasLivePhoto) return null;
    final metadata = attachment.metadata;
    if (metadata == null) return null;
    // A non-null myIris entry means a paired live-photo payload is present.
    if (metadata['myIris'] != null) return null;
    final rustpush = metadata['rustpush'];
    if (rustpush is! String || rustpush.isEmpty) return null;
    return rustpush;
  }

  static void _appendText(List<_BodyToken> tokens, String text, int flags) {
    if (tokens.isNotEmpty) {
      final last = tokens.last;
      if (!last.isAttachment && last.flags == flags) {
        tokens[tokens.length - 1] = _BodyToken.text(last.text + text, flags);
        return;
      }
    }
    tokens.add(_BodyToken.text(text, flags));
  }

  static int _flagsOf(api.TextFlags flags) {
    var bits = 0;
    if (flags.bold) bits |= 1;
    if (flags.italic) bits |= 2;
    if (flags.underline) bits |= 4;
    if (flags.strikethrough) bits |= 8;
    return bits;
  }

  static int _flagsOfAttributes(Attributes attributes) {
    var bits = 0;
    if (attributes.bold == true) bits |= 1;
    if (attributes.italic == true) bits |= 2;
    if (attributes.underline == true) bits |= 4;
    if (attributes.strikethrough == true) bits |= 8;
    return bits;
  }

  static String _sha256Hex(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _digest(List<_BodyToken> tokens) {
    final out = BytesBuilder(copy: false);
    void frame(String value) {
      final bytes = utf8.encode(value);
      out.add(utf8.encode('${bytes.length}:'));
      out.add(bytes);
      out.addByte(0);
    }

    frame(_domain);
    frame(_version);
    frame(tokens.length.toString());
    for (final token in tokens) {
      if (token.isAttachment) {
        frame('A');
        frame(token.descriptorSha);
      } else {
        frame('T');
        frame(token.flags.toString());
        frame(token.text);
      }
    }
    return sha256.convert(out.toBytes()).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is CloudSyncAttachmentSendBody &&
      other.sourceSha256 == sourceSha256;

  @override
  int get hashCode => sourceSha256.hashCode;

  /// Redacted by design: raw descriptors, text, and GUIDs stay in memory.
  @override
  String toString() => 'CloudSyncAttachmentSendBody(redacted)';
}

/// One canonical body token. Text merges only with adjacent text carrying
/// identical flags; attachment tokens carry the descriptor SHA, never the
/// local GUID. UI messagePart numbering is ignored on both sides because
/// reflection renumbers it.
final class _BodyToken {
  const _BodyToken.text(this.text, this.flags)
    : isAttachment = false,
      descriptorSha = '';

  const _BodyToken.attachment(this.descriptorSha)
    : isAttachment = true,
      text = '',
      flags = 0;

  final bool isAttachment;
  final String text;
  final int flags;
  final String descriptorSha;

  @override
  bool operator ==(Object other) =>
      other is _BodyToken &&
      other.isAttachment == isAttachment &&
      other.text == text &&
      other.flags == flags &&
      other.descriptorSha == descriptorSha;

  @override
  int get hashCode => Object.hash(isAttachment, text, flags, descriptorSha);
}
