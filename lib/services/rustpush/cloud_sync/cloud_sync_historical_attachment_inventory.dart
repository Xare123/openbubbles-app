import 'dart:convert';

import 'package:bluebubbles/database/models.dart';

const _invalid = 'cloud_sync_historical_attachment_inventory_invalid';

/// Detached attachment metadata in the encrypted historical snapshot.
///
/// This is source evidence, not permission to upload. Capture never opens a
/// file, resolves a cache path, downloads bytes, or invokes the legacy converter.
/// Availability and content hashes must be verified separately before staging.
/// Keep absent and inconsistent stored values; never manufacture replacements.
/// The writer must also reconcile this stored relation set with the message's
/// declared count and attributed-body references. Capture alone proves neither
/// complete part coverage nor that an attachment belongs to this message.
final class CloudSyncHistoricalAttachmentInventory {
  CloudSyncHistoricalAttachmentInventory._(
    Iterable<CloudSyncHistoricalAttachmentState> attachments,
  ) : attachments = List.unmodifiable(attachments);

  static const maximumAttachments = 64;
  static const maximumMetadataBytes = 1024 * 1024;
  static const maximumMetadataDepth = 16;

  factory CloudSyncHistoricalAttachmentInventory.capture(
    Iterable<Attachment> storedAttachments,
  ) {
    try {
      final captured = <CloudSyncHistoricalAttachmentState>[];
      for (final attachment in storedAttachments) {
        if (captured.length >= maximumAttachments) throw StateError(_invalid);
        captured.add(CloudSyncHistoricalAttachmentState._capture(attachment));
      }
      final inventory = CloudSyncHistoricalAttachmentInventory._(captured);
      _requireBoundedJson(inventory.toWire());
      return inventory;
    } catch (_) {
      throw StateError(_invalid);
    }
  }

  factory CloudSyncHistoricalAttachmentInventory.fromWire(Object? value) {
    try {
      if (value is! List ||
          value.length != 2 ||
          value[0] is! int ||
          value[0] != 1 ||
          value[1] is! List) {
        throw StateError(_invalid);
      }
      final entries = value[1] as List;
      if (entries.length > maximumAttachments) throw StateError(_invalid);
      final inventory = CloudSyncHistoricalAttachmentInventory._(
        entries.map(CloudSyncHistoricalAttachmentState._fromWire),
      );
      _requireBoundedJson(inventory.toWire());
      return inventory;
    } catch (_) {
      throw StateError(_invalid);
    }
  }

  final List<CloudSyncHistoricalAttachmentState> attachments;

  List<Object?> toWire() => [
    1,
    attachments.map((attachment) => attachment.toWire()).toList(),
  ];

  @override
  String toString() => 'CloudSyncHistoricalAttachmentInventory(redacted)';
}

/// Original persisted fields only. Transient bytes/sourcePath and computed
/// Attachment.path are deliberately absent. metadataJson preserves descriptor
/// strings exactly while detaching nested maps/lists from mutable model data.
final class CloudSyncHistoricalAttachmentState {
  const CloudSyncHistoricalAttachmentState._({
    required this.id,
    required this.originalRowId,
    required this.guid,
    required this.messageId,
    required this.uti,
    required this.mimeType,
    required this.isOutgoing,
    required this.transferName,
    required this.totalBytes,
    required this.height,
    required this.width,
    required this.webUrl,
    required this.hasLivePhoto,
    required this.ckRecordId,
    required this.metadataJson,
  });

  factory CloudSyncHistoricalAttachmentState._capture(Attachment attachment) =>
      CloudSyncHistoricalAttachmentState._(
        id: attachment.id,
        originalRowId: attachment.originalROWID,
        guid: attachment.guid,
        messageId: attachment.message.targetId,
        uti: attachment.uti,
        mimeType: attachment.mimeType,
        isOutgoing: attachment.isOutgoing,
        transferName: attachment.transferName,
        totalBytes: attachment.totalBytes,
        height: attachment.height,
        width: attachment.width,
        webUrl: attachment.webUrl,
        hasLivePhoto: attachment.hasLivePhoto,
        ckRecordId: attachment.ckRecordId,
        metadataJson: _metadata(attachment.metadata),
      );

  factory CloudSyncHistoricalAttachmentState._fromWire(Object? value) {
    if (value is! List ||
        value.length != 16 ||
        value[0] is! int ||
        value[0] != 1 ||
        value[4] is! int ||
        value[13] is! bool) {
      throw StateError(_invalid);
    }
    final metadata = _optionalString(value[15]);
    if (metadata != null &&
        (metadata.length >
                CloudSyncHistoricalAttachmentInventory.maximumMetadataBytes ||
            utf8.encode(metadata).length >
                CloudSyncHistoricalAttachmentInventory.maximumMetadataBytes)) {
      throw StateError(_invalid);
    }
    if (metadata != null && _metadata(jsonDecode(metadata)) != metadata) {
      throw StateError(_invalid);
    }
    return CloudSyncHistoricalAttachmentState._(
      id: _optionalInt(value[1]),
      originalRowId: _optionalInt(value[2]),
      guid: _optionalString(value[3]),
      messageId: value[4] as int,
      uti: _optionalString(value[5]),
      mimeType: _optionalString(value[6]),
      isOutgoing: _optionalBool(value[7]),
      transferName: _optionalString(value[8]),
      totalBytes: _optionalInt(value[9]),
      height: _optionalInt(value[10]),
      width: _optionalInt(value[11]),
      webUrl: _optionalString(value[12]),
      hasLivePhoto: value[13] as bool,
      ckRecordId: _optionalString(value[14]),
      metadataJson: metadata,
    );
  }

  final int? id;
  final int? originalRowId;
  final String? guid;
  final int messageId;
  final String? uti;
  final String? mimeType;
  final bool? isOutgoing;
  final String? transferName;
  final int? totalBytes;
  final int? height;
  final int? width;
  final String? webUrl;
  final bool hasLivePhoto;
  final String? ckRecordId;
  final String? metadataJson;

  List<Object?> toWire() => [
    1,
    id,
    originalRowId,
    guid,
    messageId,
    uti,
    mimeType,
    isOutgoing,
    transferName,
    totalBytes,
    height,
    width,
    webUrl,
    hasLivePhoto,
    ckRecordId,
    metadataJson,
  ];

  @override
  String toString() => 'CloudSyncHistoricalAttachmentState(redacted)';
}

String? _optionalString(Object? value) {
  if (value == null || value is String) return value as String?;
  throw StateError(_invalid);
}

int? _optionalInt(Object? value) {
  if (value == null || value is int) return value as int?;
  throw StateError(_invalid);
}

bool? _optionalBool(Object? value) {
  if (value == null || value is bool) return value as bool?;
  throw StateError(_invalid);
}

String? _metadata(Object? value) {
  if (value == null) return null;
  if (value is! Map) throw StateError(_invalid);
  final canonical = _canonicalJson(value, 0, [0]);
  return _requireBoundedJson(canonical);
}

Object? _canonicalJson(Object? value, int depth, List<int> nodes) {
  if (depth > CloudSyncHistoricalAttachmentInventory.maximumMetadataDepth ||
      ++nodes[0] > 16384) {
    throw StateError(_invalid);
  }
  if (value == null || value is bool || value is int) return value;
  if (value is double && value.isFinite) return value;
  if (value is String) {
    if (value.length >
        CloudSyncHistoricalAttachmentInventory.maximumMetadataBytes) {
      throw StateError(_invalid);
    }
    return value;
  }
  if (value is List) {
    if (value.length > 16384) throw StateError(_invalid);
    return value.map((item) => _canonicalJson(item, depth + 1, nodes)).toList();
  }
  if (value is Map) {
    if (value.length > 16384) throw StateError(_invalid);
    if (value.keys.any((key) => key is! String)) throw StateError(_invalid);
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key], depth + 1, nodes),
    };
  }
  // No custom toJson hooks, NaN, infinity or opaque runtime objects.
  throw StateError(_invalid);
}

String _requireBoundedJson(Object? value) {
  final encoded = jsonEncode(value);
  if (encoded.length >
          CloudSyncHistoricalAttachmentInventory.maximumMetadataBytes ||
      utf8.encode(encoded).length >
          CloudSyncHistoricalAttachmentInventory.maximumMetadataBytes) {
    throw StateError(_invalid);
  }
  return encoded;
}
