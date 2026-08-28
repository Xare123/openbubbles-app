import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';

/// Versioned, length-framed digest for the canonical payload that crosses the
/// Rust-to-Dart boundary. Rust persists this value in the snapshot and Dart
/// recomputes it before a quarantine repair can write local state.
///
/// This is deliberately not JSON: every field name and value is framed before
/// hashing, so optional values, list boundaries, and UTF-8 content are
/// unambiguous across implementations.
final class CloudKitV2CanonicalRepairDigest {
  const CloudKitV2CanonicalRepairDigest._();

  static const domain = 'bluebubbles.cloudkit.repair.digest';
  static const version = '1';

  /// Pins the UTF-8 and opaque-byte framing contract without allowing native
  /// extension bytes into the production transient payload boundary.
  /// Production repair capability validation must never use this probe.
  static String testOnlyFramingProbe({
    required String unicodeText,
    required Uint8List rawBytes,
  }) {
    final writer = _DigestWriter()
      ..string('domain', domain)
      ..string('version', version)
      ..string('entityKind', 'framingProbe')
      ..string('unicodeText', unicodeText)
      ..nullableBytes('rawBytes', rawBytes);
    return writer.finish();
  }

  static String forPayload(CloudSemanticEntityPayload payload) {
    final writer = _DigestWriter()
      ..string('domain', domain)
      ..string('version', version);
    switch (payload) {
      case CloudMessageEntityPayload value:
        writer.string('entityKind', 'message');
        _message(writer, value);
      case CloudReactionEntityPayload value:
        writer.string('entityKind', 'reaction');
        _reaction(writer, value);
      default:
        throw ArgumentError('quarantine_repair_payload_kind_unsupported');
    }
    return writer.finish();
  }

  static void _message(_DigestWriter writer, CloudMessageEntityPayload value) {
    writer
      ..string('logicalEntityKeyHash', value.logicalEntityKeyHash)
      ..string('canonicalGuid', value.canonicalGuid)
      ..string('chatAliasKeyHash', value.chatAliasKeyHash)
      ..string('chatIdentifier', value.chatIdentifier)
      ..nullableString('body', value.body)
      ..string('senderHandle', value.senderHandle)
      ..nullableInt('createdAtMs', _timestamp(value.createdAt))
      ..nullableInt('error', value.error)
      ..nullableString('service', value.service?.name)
      ..string('subjectState', value.subjectState.name)
      ..nullableString('subject', value.subject)
      ..string('bodyState', value.bodyState.name)
      ..string('attributedBodiesState', value.attributedBodiesState.name)
      ..nullableString('balloonBundleIdState', value.balloonBundleIdState.name)
      ..nullableString('balloonBundleId', value.balloonBundleId)
      ..string(
        'decodedExtensionPayloadState',
        value.decodedExtensionPayloadState.name,
      )
      ..nullableBytes('decodedExtensionPayload', value.decodedExtensionPayload)
      ..string('effectState', value.effectState.name)
      ..nullableString('effect', value.effect)
      ..string('readAtState', value.readAtState.name)
      ..nullableInt('readAtMs', _timestamp(value.readAt))
      ..string('deliveredAtState', value.deliveredAtState.name)
      ..nullableInt('deliveredAtMs', _timestamp(value.deliveredAt))
      ..nullableBool(
        'knownFlagsPresent',
        value.knownFlags == null ? null : true,
      );
    final flags = value.knownFlags;
    if (flags != null) {
      writer
        ..boolValue('knownFlags.fromMe', flags.fromMe)
        ..boolValue('knownFlags.delivered', flags.delivered)
        ..boolValue('knownFlags.read', flags.read)
        ..boolValue(
          'knownFlags.hasDataDetectorResults',
          flags.hasDataDetectorResults,
        )
        ..boolValue('knownFlags.deliveredQuietly', flags.deliveredQuietly)
        ..boolValue('knownFlags.didNotifyRecipient', flags.didNotifyRecipient);
    }
    writer
      ..string('associationKind', value.associationKind.name)
      ..nullableString(
        'associationParentLogicalKeyHash',
        value.associationParentLogicalKeyHash,
      )
      ..nullableString(
        'associationParentCanonicalGuid',
        value.associationParentCanonicalGuid,
      )
      ..nullableInt('associationParentPart', value.associationParentPart)
      ..nullableInt('associatedRangeLocation', value.associatedRangeLocation)
      ..nullableInt('associatedRangeLength', value.associatedRangeLength)
      ..nullableString(
        'replyParentLogicalKeyHash',
        value.replyParentLogicalKeyHash,
      )
      ..nullableString(
        'replyParentCanonicalGuid',
        value.replyParentCanonicalGuid,
      )
      ..nullableString('replyParentPart', value.replyParentPart)
      ..string('editsState', value.editsState.name)
      ..string('retractedPartsState', value.retractedPartsState.name);
    _bodies(writer, 'attributedBodies', value.attributedBodies);
    _edits(writer, value.edits);
    writer.intValue('retractedParts.count', value.retractedParts.length);
    for (var index = 0; index < value.retractedParts.length; index++) {
      writer.intValue('retractedParts[$index]', value.retractedParts[index]);
    }
  }

  static void _reaction(
    _DigestWriter writer,
    CloudReactionEntityPayload value,
  ) {
    writer
      ..string('logicalEntityKeyHash', value.logicalEntityKeyHash)
      ..string('canonicalGuid', value.canonicalGuid)
      ..string('parentLogicalKeyHash', value.parentLogicalKeyHash)
      ..string('parentCanonicalGuid', value.parentCanonicalGuid)
      ..nullableInt('parentPart', value.parentPart)
      ..string('senderHandle', value.senderHandle)
      ..string('reactionType', value.reactionType)
      ..nullableString('associatedEmoji', value.associatedEmoji)
      ..nullableInt('createdAtMs', _timestamp(value.createdAt))
      ..nullableInt('error', value.error)
      ..nullableString('service', value.service?.name)
      ..nullableBool(
        'knownFlagsPresent',
        value.knownFlags == null ? null : true,
      );
    final flags = value.knownFlags;
    if (flags != null) {
      writer
        ..boolValue('knownFlags.fromMe', flags.fromMe)
        ..boolValue('knownFlags.delivered', flags.delivered)
        ..boolValue('knownFlags.read', flags.read)
        ..boolValue(
          'knownFlags.hasDataDetectorResults',
          flags.hasDataDetectorResults,
        )
        ..boolValue('knownFlags.deliveredQuietly', flags.deliveredQuietly)
        ..boolValue('knownFlags.didNotifyRecipient', flags.didNotifyRecipient);
    }
    writer
      ..string('readAtState', value.readAtState.name)
      ..nullableInt('readAtMs', _timestamp(value.readAt))
      ..string('deliveredAtState', value.deliveredAtState.name)
      ..nullableInt('deliveredAtMs', _timestamp(value.deliveredAt))
      ..nullableInt('associatedRangeLocation', value.associatedRangeLocation)
      ..nullableInt('associatedRangeLength', value.associatedRangeLength);
  }

  static void _edits(
    _DigestWriter writer,
    List<CloudSemanticMessageEdit> edits,
  ) {
    writer.intValue('edits.count', edits.length);
    for (var index = 0; index < edits.length; index++) {
      final edit = edits[index];
      final prefix = 'edits[$index].';
      writer
        ..intValue('${prefix}part', edit.part)
        ..intValue('${prefix}revision', edit.revision)
        ..intValue(
          '${prefix}modifiedAtMs',
          edit.modifiedAt.toUtc().millisecondsSinceEpoch,
        )
        ..nullableInt(
          '${prefix}originalRangeLocation',
          edit.originalRangeLocation,
        )
        ..nullableInt('${prefix}originalRangeLength', edit.originalRangeLength);
      _bodies(writer, '${prefix}bodies', edit.bodies);
    }
  }

  static void _bodies(
    _DigestWriter writer,
    String name,
    List<CloudSemanticAttributedBody> bodies,
  ) {
    writer.intValue('$name.count', bodies.length);
    for (var bodyIndex = 0; bodyIndex < bodies.length; bodyIndex++) {
      final body = bodies[bodyIndex];
      final prefix = '$name[$bodyIndex].';
      writer
        ..string('${prefix}text', body.text)
        ..intValue('${prefix}runs.count', body.runs.length);
      for (var runIndex = 0; runIndex < body.runs.length; runIndex++) {
        final run = body.runs[runIndex];
        final runPrefix = '${prefix}runs[$runIndex].';
        writer
          ..intValue('${runPrefix}startUtf16', run.startUtf16)
          ..intValue('${runPrefix}lengthUtf16', run.lengthUtf16)
          ..nullableInt('${runPrefix}messagePart', run.messagePart)
          ..nullableString(
            '${runPrefix}attachmentCanonicalGuid',
            run.attachmentCanonicalGuid,
          )
          ..nullableString(
            '${runPrefix}attachmentLogicalKeyHash',
            run.attachmentLogicalKeyHash,
          )
          ..nullableString('${runPrefix}mentionHandle', run.mentionHandle)
          ..nullableString('${runPrefix}audioTranscript', run.audioTranscript)
          ..nullableInt('${runPrefix}textEffect', run.textEffect)
          ..nullableBool('${runPrefix}bold', run.bold)
          ..nullableBool('${runPrefix}italic', run.italic)
          ..nullableBool('${runPrefix}strikethrough', run.strikethrough)
          ..nullableBool('${runPrefix}underline', run.underline);
      }
    }
  }

  static int? _timestamp(DateTime? value) =>
      value?.toUtc().millisecondsSinceEpoch;
}

final class _DigestWriter {
  final _parts = <List<int>>[];

  void string(String name, String value) => _add(name, 1, utf8.encode(value));
  void nullableString(String name, String? value) =>
      value == null ? _add(name, 0, const []) : string(name, value);
  void intValue(String name, int value) =>
      _add(name, 2, utf8.encode(value.toString()));
  void nullableInt(String name, int? value) =>
      value == null ? _add(name, 0, const []) : intValue(name, value);
  void boolValue(String name, bool value) =>
      _add(name, 3, <int>[value ? 1 : 0]);
  void nullableBool(String name, bool? value) =>
      value == null ? _add(name, 0, const []) : boolValue(name, value);
  void nullableBytes(String name, Uint8List? value) =>
      value == null ? _add(name, 0, const []) : _add(name, 4, value);

  void _add(String name, int type, List<int> value) {
    _parts.add(utf8.encode(name));
    _parts.add(<int>[type, ...value]);
  }

  String finish() {
    final bytes = BytesBuilder(copy: false);
    for (final part in _parts) {
      // dart2js does not implement ByteData.setUint64. Encode the same
      // unsigned big-endian length arithmetically so native and web use one
      // deterministic framing rule.
      final length = Uint8List(8);
      var remaining = part.length;
      for (var index = length.length - 1; index >= 0; index--) {
        length[index] = remaining % 256;
        remaining ~/= 256;
      }
      bytes.add(length);
      bytes.add(part);
    }
    return sha256.convert(bytes.takeBytes()).toString();
  }
}
