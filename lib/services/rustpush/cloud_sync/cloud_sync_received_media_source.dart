import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// Frozen, body-only evidence for a received iMessage containing MMCS media.
///
/// Capture is pure: it never restores an opaque attachment, opens a file,
/// calls native code, or grants upload/author/account authority. The received
/// identity must separately bind the live recipient, author, saved row and
/// route. Native code must protect and validate the complete original body;
/// this manifest is not a replacement body or an outgoing-send receipt.
final class CloudSyncReceivedMediaSource {
  const CloudSyncReceivedMediaSource._(this.text, this.mediaManifest);

  static const maximumAttachments = 64;
  static const maximumParts = 128;
  static const maximumTextUtf8Bytes = 256 * 1024;
  static const maximumMetadataUtf8Bytes = 4096;
  static const maximumDescriptorUtf8Bytes = 8192;
  static const maximumContentBytes = 8 * 1024 * 1024 * 1024;
  static const maximumPart = 0x7fffffffffffffff;

  /// Exact wire-order concatenation: text verbatim and one ASCII space for
  /// EVERY attachment, including iris and display-only MIME parts. Indices
  /// never reorder this value. This is not the ordinary UI projection.
  final String text;

  /// Deeply immutable V3 rows, in exact wire order. Contains synthetic or real
  /// MMCS key material: never log or persist this unprotected. Native source
  /// sealing, not this class, owns encrypted durable retention.
  final List<List<Object?>> mediaManifest;

  /// Captures supported body shape only. No live-receive or persistence proof
  /// is inferred by this method; use the received identity's capture/preview.
  static CloudSyncReceivedMediaSource? captureWire(api.MessageInst wire) {
    final message = wire.message;
    if (message is! api.Message_Message) return null;
    final normal = message.field0;
    if (normal.service is! api.MessageType_IMessage ||
        normal.voice ||
        normal.replyGuid != null ||
        normal.replyPart != null ||
        normal.effect != null ||
        normal.app != null ||
        normal.subject?.isNotEmpty == true ||
        normal.linkMeta != null ||
        normal.scheduled != null ||
        normal.embeddedProfile != null) {
      return null;
    }
    final parts = normal.parts.field0;
    if (parts.isEmpty || parts.length > maximumParts) return null;
    var attachmentCount = 0;
    var textBytes = 0;
    final text = StringBuffer();
    final manifest = <List<Object?>>[];
    for (final indexed in parts) {
      if (indexed.ext != null || !_validPart(indexed.idx)) return null;
      final part = indexed.part_;
      if (part is api.MessagePart_Text) {
        final format = part.field1;
        if (format is! api.TextFormat_Flags) return null;
        final flags = format.field0;
        if (flags.bold ||
            flags.italic ||
            flags.underline ||
            flags.strikethrough) {
          return null;
        }
        final length = _utf8Length(part.field0);
        if (length < 0 || length > maximumTextUtf8Bytes) return null;
        textBytes += length;
        if (textBytes > maximumTextUtf8Bytes) return null;
        text.write(part.field0);
        manifest.add(List<Object?>.unmodifiable([0, part.field0, indexed.idx]));
      } else if (part is api.MessagePart_Attachment) {
        attachmentCount++;
        if (attachmentCount > maximumAttachments) return null;
        final attachment = part.field0;
        final type = attachment.aType;
        if (type is! api.AttachmentType_MMCS ||
            !_validPart(attachment.part_) ||
            !_boundedString(attachment.utiType, maximumMetadataUtf8Bytes) ||
            !_boundedString(attachment.mime, maximumMetadataUtf8Bytes) ||
            !_boundedString(attachment.name, maximumMetadataUtf8Bytes)) {
          return null;
        }
        final file = type.field0;
        if (file.key.length != 32 ||
            file.signature.length != 21 ||
            !_boundedString(file.object, maximumDescriptorUtf8Bytes) ||
            !_boundedString(file.url, maximumDescriptorUtf8Bytes) ||
            file.size < 0 ||
            file.size > maximumContentBytes) {
          return null;
        }
        final descriptor = List<Object?>.unmodifiable([
          List<int>.unmodifiable(file.key),
          List<int>.unmodifiable(file.signature),
          file.object,
          file.url,
          file.size,
        ]);
        manifest.add(
          List<Object?>.unmodifiable([
            1,
            attachment.part_,
            attachment.utiType,
            attachment.mime,
            attachment.name,
            attachment.iris,
            descriptor,
            indexed.idx,
          ]),
        );
        text.write(' ');
      } else {
        return null;
      }
    }
    // Attachment spaces are part of the full V3 capture text's byte bound.
    if (attachmentCount == 0 ||
        textBytes + attachmentCount > maximumTextUtf8Bytes) {
      return null;
    }
    return CloudSyncReceivedMediaSource._(
      text.toString(),
      List<List<Object?>>.unmodifiable(manifest),
    );
  }

  /// Checks only correspondence with ordinary, unedited receive reflection.
  /// Unlike [text], that projection omits iris/application-specified SMIL and
  /// can replace runs by index. Nothing here generates or writes a UI body.
  /// All original parts remain in [mediaManifest], even when omitted by UI.
  /// Opaque `rustpush`/`myIris` metadata is NOT decoded or authenticated here;
  /// native complete-body binding remains mandatory before any media write.
  bool matchesReceivedMessage(Message message) {
    if (!message.hasAttachments || message.attributedBody.length != 1) {
      return false;
    }
    final guid = message.guid;
    if (guid == null || guid.isEmpty) return false;
    final display = StringBuffer();
    final runs = <({int start, int length, int part, String? guid})>[];
    final visible = <({String guid, List<Object?> row, bool iris})>[];
    final addedIndices = <int>{};
    for (var i = 0; i < mediaManifest.length; i++) {
      final row = mediaManifest[i];
      final fieldIndex =
          (row.last as int?) ?? runs.where((run) => run.guid != null).length;
      if (addedIndices.add(fieldIndex)) {
        runs.removeWhere((run) => run.part == fieldIndex);
      }
      if (row.first == 0) {
        final value = row[1] as String;
        runs.add((
          start: display.length,
          length: value.length,
          part: fieldIndex,
          guid: null,
        ));
        display.write(value);
      } else {
        if (row[5] == true || row[3] == 'application/smil') continue;
        final attachmentGuid = '${guid}_$fieldIndex';
        final next = i + 1 < mediaManifest.length ? mediaManifest[i + 1] : null;
        visible.add((
          guid: attachmentGuid,
          row: row,
          iris: next != null && next.first == 1 && next[5] == true,
        ));
        runs.add((
          start: display.length,
          length: 1,
          part: runs.length,
          guid: attachmentGuid,
        ));
        display.write(' ');
      }
    }
    // An all-hidden body has no ordinary attachment-bearing Message to bind.
    if (visible.isEmpty) return false;
    final body = message.attributedBody.single;
    if (message.text != display.toString() ||
        body.string != message.text ||
        body.runs.length != runs.length) {
      return false;
    }
    for (var i = 0; i < runs.length; i++) {
      final expected = runs[i];
      final actual = body.runs[i];
      final attributes = actual.attributes;
      if (actual.range.length != 2 ||
          actual.range[0] != expected.start ||
          actual.range[1] != expected.length ||
          attributes == null ||
          attributes.messagePart != expected.part ||
          attributes.attachmentGuid != expected.guid ||
          attributes.mention != null ||
          attributes.audioTranscript != null ||
          attributes.stickerData != null ||
          attributes.textEffect != null ||
          attributes.bold == true ||
          attributes.italic == true ||
          attributes.underline == true ||
          attributes.strikethrough == true) {
        return false;
      }
    }
    bool matchesAttachments(List<Attachment?> actual) {
      if (actual.length != visible.length) return false;
      for (var i = 0; i < visible.length; i++) {
        final expected = visible[i];
        final row = expected.row;
        final file = row[6] as List<Object?>;
        final attachment = actual[i];
        if (attachment == null ||
            attachment.guid != expected.guid ||
            attachment.uti != row[2] ||
            attachment.mimeType != row[3] ||
            attachment.transferName !=
                (row[4] as String).replaceAll('/', '_').replaceAll('\\', '_') ||
            attachment.totalBytes != file[4] ||
            attachment.isOutgoing != false ||
            attachment.hasLivePhoto != expected.iris) {
          return false;
        }
      }
      return true;
    }

    final transient = message.attachments;
    final stored = message.dbAttachments.toList(growable: false);
    if (transient.isEmpty && stored.isEmpty) return false;
    return (transient.isEmpty || matchesAttachments(transient)) &&
        (stored.isEmpty || matchesAttachments(stored));
  }

  static bool _validPart(int? part) =>
      part == null || (part >= 0 && part <= maximumPart);

  static final _controls = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

  static bool _boundedString(String value, int maximum) {
    final length = _utf8Length(value);
    return length > 0 && length <= maximum && !_controls.hasMatch(value);
  }

  // Rust strings cannot contain unpaired UTF-16 surrogates. Do not let Dart's
  // replacement encoding create a source digest different from native input.
  static int _utf8Length(String value) {
    final units = value.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          return -1;
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return -1;
      }
    }
    return utf8.encode(value).length;
  }

  @override
  String toString() => 'CloudSyncReceivedMediaSource(redacted)';
}
