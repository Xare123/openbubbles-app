import 'dart:convert';

import 'package:bluebubbles/database/models.dart';

import 'package:bluebubbles/utils/attachment_guid_utils.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_attachment_inventory.dart';

const _invalid = 'cloud_sync_historical_media_source_invalid';

/// Detached media source for one historical row: frozen body layout plus the
/// already-captured attachment inventory.
///
/// This is source evidence, not permission to upload. Capture never opens a
/// file, resolves a cache path, downloads bytes, parses descriptor payloads,
/// or reconstructs captions from row text. Staged native code verifies
/// descriptors and bytes separately before anything is staged or sent.
final class CloudSyncHistoricalMediaSource {
  CloudSyncHistoricalMediaSource._({
    required this.messageId,
    required this.originalText,
    required this.bodyJson,
    required this.inventory,
  });

  static const maximumBodies = 16;
  static const maximumRuns = 128;
  static const maximumTextUtf8Bytes = 256 * 1024;
  static const maximumWireUtf8Bytes = 1024 * 1024;
  static const _maxU32 = 4294967295;

  final int messageId;
  final String? originalText;
  final String bodyJson;
  final CloudSyncHistoricalAttachmentInventory inventory;

  List<Object?> toWire() => [
    1,
    messageId,
    originalText,
    bodyJson,
    inventory.toWire(),
  ];

  @override
  String toString() => 'CloudSyncHistoricalMediaSource(redacted)';

  /// Freezes the row bodies and inventory with full layout validation.
  /// Empty or null row text is supported only alongside real attachments.
  factory CloudSyncHistoricalMediaSource.capture(
    CloudSyncHistoricalRowView row,
  ) {
    try {
      if (row.messageId <= 0) throw StateError(_invalid);
      final CloudSyncHistoricalAttachmentInventory inventory;
      if (row.attachmentInventory != null) {
        inventory = row.attachmentInventory!;
      } else if (row.hasAttachments || row.attachmentCount > 0) {
        throw StateError(_invalid);
      } else {
        inventory = CloudSyncHistoricalAttachmentInventory.capture(
          const <Attachment>[],
        );
      }
      final bodies = row.attributedBodies;
      final bodyJson = _validatedBodyJson(
        messageId: row.messageId,
        bodies: bodies,
        inventory: inventory,
        ownerGuid: row.guid,
      );
      if (row.attachmentCount != inventory.attachments.length) {
        throw StateError(_invalid);
      }
      _requireText(row.text, hasAttachments: inventory.attachments.isNotEmpty);
      final source = CloudSyncHistoricalMediaSource._(
        messageId: row.messageId,
        originalText: row.text,
        bodyJson: bodyJson,
        inventory: inventory,
      );
      _requireBoundedWire(source.toWire());
      return source;
    } catch (_) {
      throw StateError(_invalid);
    }
  }

  /// Reopens an exact wire value with the same validation as capture.
  /// When [messageGuid] is supplied, embedded attachment owners must equal
  /// it, mirroring native validation against the outer source.
  factory CloudSyncHistoricalMediaSource.fromWire(
    Object? value, {
    String? messageGuid,
  }) {
    try {
      if (value is! List ||
          value.length != 5 ||
          value[0] is! int ||
          value[0] != 1) {
        throw StateError(_invalid);
      }
      final messageId = value[1];
      final originalText = value[2];
      final bodyJson = value[3];
      if (messageId is! int || messageId <= 0 || bodyJson is! String) {
        throw StateError(_invalid);
      }
      final String? text;
      if (originalText == null) {
        text = null;
      } else if (originalText is String) {
        text = originalText;
      } else {
        throw StateError(_invalid);
      }
      if (utf8.encode(bodyJson).length >
          CloudSyncHistoricalMediaSource.maximumWireUtf8Bytes) {
        throw StateError(_invalid);
      }
      final decoded = jsonDecode(bodyJson);
      if (decoded is! List) throw StateError(_invalid);
      final bodies = decoded
          .map(
            (entry) => AttributedBody.fromMap(
              (entry as Map).cast<String, Object>(),
            ),
          )
          .toList();
      final inventory =
          CloudSyncHistoricalAttachmentInventory.fromWire(value[4]);
      final canonical = _validatedBodyJson(
        messageId: messageId,
        bodies: bodies,
        inventory: inventory,
        ownerGuid: messageGuid,
      );
      if (canonical != bodyJson) throw StateError(_invalid);
      _requireText(
        text,
        hasAttachments: inventory.attachments.isNotEmpty,
      );
      final source = CloudSyncHistoricalMediaSource._(
        messageId: messageId,
        originalText: text,
        bodyJson: bodyJson,
        inventory: inventory,
      );
      _requireBoundedWire(source.toWire());
      return source;
    } catch (_) {
      throw StateError(_invalid);
    }
  }
}

void _requireText(String? text, {required bool hasAttachments}) {
  if (text != null) {
    _requireBoundedString(text);
    _requireValidTextUnits(text);
  }
  if (text != null && text.isNotEmpty) return;
  if (!hasAttachments) throw StateError(_invalid);
}

void _requireBoundedString(String value) {
  if (utf8.encode(value).length >
      CloudSyncHistoricalMediaSource.maximumTextUtf8Bytes) {
    throw StateError(_invalid);
  }
}

void _requireBoundedWire(List<Object?> wire) {
  if (utf8.encode(jsonEncode(wire)).length >
      CloudSyncHistoricalMediaSource.maximumWireUtf8Bytes) {
    throw StateError(_invalid);
  }
}

String _validatedBodyJson({
  required int messageId,
  required List<AttributedBody> bodies,
  required CloudSyncHistoricalAttachmentInventory inventory,
  required String? ownerGuid,
}) {
  if (bodies.isEmpty ||
      bodies.length > CloudSyncHistoricalMediaSource.maximumBodies) {
    throw StateError(_invalid);
  }
  var totalRuns = 0;
  for (final body in bodies) {
    _requireBoundedString(body.string);
    _requireValidTextUnits(body.string);
    if (body.string.isEmpty) throw StateError(_invalid);
    totalRuns += body.runs.length;
  }
  if (totalRuns > CloudSyncHistoricalMediaSource.maximumRuns) {
    throw StateError(_invalid);
  }
  _requireInventoryShape(
    messageId: messageId,
    inventory: inventory,
    ownerGuid: ownerGuid,
  );
  final referenced = <int>{};
  var attachmentRuns = 0;
  for (final body in bodies) {
    _validateBodyLayout(body);
    for (final run in body.runs) {
      _validateRunAttributes(run);
      final guid = run.attributes?.attachmentGuid;
      if (guid == null) continue;
      attachmentRuns++;
      referenced.add(
        _resolveAttachment(
          messageId: messageId,
          guid: guid,
          inventory: inventory,
          ownerGuid: ownerGuid,
          referenced: referenced,
        ),
      );
    }
  }
  if (attachmentRuns != inventory.attachments.length) {
    throw StateError(_invalid);
  }
  for (var i = 0; i < inventory.attachments.length; i++) {
    if (!referenced.contains(i)) throw StateError(_invalid);
  }
  return jsonEncode(bodies.map((body) => body.toMap()).toList());
}

void _requireInventoryShape({
  required int messageId,
  required CloudSyncHistoricalAttachmentInventory inventory,
  required String? ownerGuid,
}) {
  if (inventory.attachments.isEmpty) throw StateError(_invalid);
  final ids = <int>{};
  final canonicalGuids = <String>{};
  for (final state in inventory.attachments) {
    if (state.id == null || state.id! <= 0 || !ids.add(state.id!)) {
      throw StateError(_invalid);
    }
    if (state.messageId != messageId) throw StateError(_invalid);
    if (state.guid != null) {
      final owner = _embeddedOwner(state.guid!);
      if (ownerGuid != null && owner != null && owner != ownerGuid) {
        throw StateError(_invalid);
      }
      if (!canonicalGuids.add(_canonicalGuid(state.guid!))) {
        throw StateError(_invalid);
      }
    }
  }
}

void _requireGuidShape(String guid) {
  if (guid.isEmpty) throw StateError(_invalid);
  if (utf8.encode(guid).length > 4096) throw StateError(_invalid);
  _requireValidTextUnits(guid);
  for (var i = 0; i < guid.length; i++) {
    final unit = guid.codeUnitAt(i);
    if (unit <= 0x20 ||
        (unit >= 0x7f && unit <= 0x9f) ||
        unit == 0x2028 ||
        unit == 0x2029) {
      throw StateError(_invalid);
    }
  }
}

bool _isCanonicalDecimal(String value) {
  if (value.isEmpty) return false;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return value == '0' || !value.startsWith('0');
}

void _requirePartNumber(String part) {
  if (part.length > 10) throw StateError(_invalid);
  if (int.parse(part) > CloudSyncHistoricalMediaSource._maxU32) {
    throw StateError(_invalid);
  }
}

String? _embeddedOwner(String guid) {
  _requireGuidShape(guid);
  final apple = parseAppleOwnedAttachmentGuid(guid);
  if (apple != null) {
    _requirePartNumber(apple.part);
    return apple.messageGuid;
  }
  if (guid.startsWith('at_')) throw StateError(_invalid);
  final separator = guid.lastIndexOf('_');
  if (separator > 0 && separator < guid.length - 1) {
    final part = guid.substring(separator + 1);
    if (_isCanonicalDecimal(part)) {
      _requirePartNumber(part);
      return guid.substring(0, separator);
    }
  }
  return null;
}

void _requireValidTextUnits(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit == 0x00) throw StateError(_invalid);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= value.length) throw StateError(_invalid);
      final next = value.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) throw StateError(_invalid);
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      throw StateError(_invalid);
    }
  }
}

String _canonicalGuid(String guid) =>
    parseAppleOwnedAttachmentGuid(guid) != null
        ? guid
        : unconvertAppleAttachmentGuid(guid);

int _resolveAttachment({
  required int messageId,
  required String guid,
  required CloudSyncHistoricalAttachmentInventory inventory,
  required String? ownerGuid,
  required Set<int> referenced,
}) {
  final runOwner = _embeddedOwner(guid);
  if (ownerGuid != null && runOwner != null && runOwner != ownerGuid) {
    throw StateError(_invalid);
  }
  final want = _canonicalGuid(guid);
  for (var i = 0; i < inventory.attachments.length; i++) {
    final state = inventory.attachments[i];
    if (state.guid == null ||
        state.messageId != messageId ||
        _canonicalGuid(state.guid!) != want) {
      continue;
    }
    if (referenced.contains(i)) throw StateError(_invalid);
    return i;
  }
  throw StateError(_invalid);
}

const _spaceUnit = 0x20;
const _objectReplacementUnit = 0xFFFC;
const _surrogateLeadMin = 0xD800;
const _surrogateLeadMax = 0xDBFF;
const _surrogateTrailMin = 0xDC00;
const _surrogateTrailMax = 0xDFFF;

void _validateBodyLayout(AttributedBody body) {
  var cursor = 0;
  for (final run in body.runs) {
    if (run.range.length != 2) throw StateError(_invalid);
    final start = run.range[0];
    final length = run.range[1];
    if (start < 0 ||
        length <= 0 ||
        start > CloudSyncHistoricalMediaSource._maxU32 ||
        length > CloudSyncHistoricalMediaSource._maxU32 ||
        start != cursor ||
        start + length > body.string.length) {
      throw StateError(_invalid);
    }
    if (!_validBoundary(body.string, start) ||
        !_validBoundary(body.string, start + length)) {
      throw StateError(_invalid);
    }
    if (run.attributes?.attachmentGuid != null) {
      if (length != 1) throw StateError(_invalid);
      final unit = body.string.codeUnitAt(start);
      if (unit != _spaceUnit && unit != _objectReplacementUnit) {
        throw StateError(_invalid);
      }
    }
    cursor = start + length;
  }
  if (cursor != body.string.length) throw StateError(_invalid);
  for (var i = 0; i < body.string.length; i++) {
    if (body.string.codeUnitAt(i) == _objectReplacementUnit &&
        !_coveredByAttachment(body, i)) {
      throw StateError(_invalid);
    }
  }
}

bool _coveredByAttachment(AttributedBody body, int index) {
  for (final run in body.runs) {
    if (run.attributes?.attachmentGuid != null &&
        run.range.length == 2 &&
        index >= run.range[0] &&
        index < run.range[0] + run.range[1]) {
      return true;
    }
  }
  return false;
}

bool _validBoundary(String value, int position) {
  if (position < 0 || position > value.length) return false;
  if (position == 0 || position == value.length) return true;
  return !(value.codeUnitAt(position - 1) >= _surrogateLeadMin &&
      value.codeUnitAt(position - 1) <= _surrogateLeadMax &&
      value.codeUnitAt(position) >= _surrogateTrailMin &&
      value.codeUnitAt(position) <= _surrogateTrailMax);
}

void _validateRunAttributes(Run run) {
  final attributes = run.attributes;
  if (attributes == null) throw StateError(_invalid);
  if (attributes.messagePart == null ||
      attributes.messagePart! < 0 ||
      attributes.messagePart! > CloudSyncHistoricalMediaSource._maxU32) {
    throw StateError(_invalid);
  }
  if (attributes.mention != null ||
      attributes.audioTranscript != null ||
      attributes.stickerData != null ||
      attributes.textEffect != null ||
      (attributes.bold ?? false) ||
      (attributes.italic ?? false) ||
      (attributes.strikethrough ?? false) ||
      (attributes.underline ?? false)) {
    throw StateError(_invalid);
  }
}
