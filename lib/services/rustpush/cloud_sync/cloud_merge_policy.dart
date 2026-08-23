import 'dart:collection';

import 'cloud_sync_models.dart';

class CloudEditPart {
  CloudEditPart({
    required this.partKeyHash,
    required this.revision,
    required this.contentDigest,
    required DateTime modifiedAt,
  }) : modifiedAt = _normalizeCloudTimestamp(modifiedAt) {
    if (partKeyHash.isEmpty) {
      throw ArgumentError('cloud_edit_part_key_invalid');
    }
    if (revision < 0) {
      throw ArgumentError('cloud_edit_part_revision_invalid');
    }
    if (contentDigest.isEmpty) {
      throw ArgumentError('cloud_edit_part_digest_invalid');
    }
  }

  final String partKeyHash;
  final int revision;
  final String contentDigest;
  final DateTime modifiedAt;
}

/// Content-free semantic state used to make deterministic merge decisions.
///
/// Digests and encrypted references may identify state, but this type must
/// never contain a decrypted message body, handle, Apple credential, or key.
class CloudSemanticSnapshot {
  CloudSemanticSnapshot({
    required this.kind,
    required this.logicalEntityKeyHash,
    this.parentLogicalKeyHash,
    this.immutableContentDigest,
    DateTime? createdAt,
    DateTime? readAt,
    DateTime? deliveredAt,
    Map<String, CloudEditPart> editParts = const {},
    DateTime? retractedAt,
    this.groupVersion,
    this.groupMetadataDigest,
    this.etagHash,
    this.encryptedRawRecordReference,
  }) : createdAt = _normalizeOptionalCloudTimestamp(createdAt),
       readAt = _normalizeOptionalCloudTimestamp(readAt),
       deliveredAt = _normalizeOptionalCloudTimestamp(deliveredAt),
       editParts = UnmodifiableMapView(Map.of(editParts)),
       retractedAt = _normalizeOptionalCloudTimestamp(retractedAt) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_semantic_snapshot_logical_key_invalid');
    }
    if (parentLogicalKeyHash != null && parentLogicalKeyHash!.isEmpty) {
      throw ArgumentError('cloud_semantic_snapshot_parent_key_invalid');
    }
    if (immutableContentDigest != null && immutableContentDigest!.isEmpty) {
      throw ArgumentError('cloud_semantic_snapshot_content_digest_invalid');
    }
    if (groupVersion != null && groupVersion! < 0) {
      throw ArgumentError('cloud_semantic_snapshot_group_version_invalid');
    }
    if (groupMetadataDigest != null && groupMetadataDigest!.isEmpty) {
      throw ArgumentError('cloud_semantic_snapshot_group_digest_invalid');
    }
    if (etagHash != null && etagHash!.isEmpty) {
      throw ArgumentError('cloud_semantic_snapshot_etag_hash_invalid');
    }
    if (encryptedRawRecordReference != null &&
        encryptedRawRecordReference!.isEmpty) {
      throw ArgumentError('cloud_semantic_snapshot_record_reference_invalid');
    }
  }

  final CloudEntityKind kind;
  final String logicalEntityKeyHash;
  final String? parentLogicalKeyHash;
  final String? immutableContentDigest;
  final DateTime? createdAt;
  final DateTime? readAt;
  final DateTime? deliveredAt;
  final Map<String, CloudEditPart> editParts;
  final DateTime? retractedAt;
  final int? groupVersion;
  final String? groupMetadataDigest;
  final String? etagHash;

  /// Encrypted record or protected reference retained for unknown fields.
  final String? encryptedRawRecordReference;

  CloudSemanticSnapshot copyWith({
    String? immutableContentDigest,
    bool clearImmutableContentDigest = false,
    DateTime? createdAt,
    bool clearCreatedAt = false,
    DateTime? readAt,
    bool clearReadAt = false,
    DateTime? deliveredAt,
    bool clearDeliveredAt = false,
    Map<String, CloudEditPart>? editParts,
    DateTime? retractedAt,
    bool clearRetractedAt = false,
    int? groupVersion,
    bool clearGroupVersion = false,
    String? groupMetadataDigest,
    bool clearGroupMetadataDigest = false,
    String? etagHash,
    bool clearEtagHash = false,
    String? encryptedRawRecordReference,
    bool clearEncryptedRawRecordReference = false,
  }) {
    if ((clearImmutableContentDigest && immutableContentDigest != null) ||
        (clearCreatedAt && createdAt != null) ||
        (clearReadAt && readAt != null) ||
        (clearDeliveredAt && deliveredAt != null) ||
        (clearRetractedAt && retractedAt != null) ||
        (clearGroupVersion && groupVersion != null) ||
        (clearGroupMetadataDigest && groupMetadataDigest != null) ||
        (clearEtagHash && etagHash != null) ||
        (clearEncryptedRawRecordReference &&
            encryptedRawRecordReference != null)) {
      throw ArgumentError('cloud_semantic_snapshot_clear_conflict');
    }
    return CloudSemanticSnapshot(
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
      parentLogicalKeyHash: parentLogicalKeyHash,
      immutableContentDigest: clearImmutableContentDigest
          ? null
          : immutableContentDigest ?? this.immutableContentDigest,
      createdAt: clearCreatedAt ? null : createdAt ?? this.createdAt,
      readAt: clearReadAt ? null : readAt ?? this.readAt,
      deliveredAt: clearDeliveredAt ? null : deliveredAt ?? this.deliveredAt,
      editParts: editParts ?? this.editParts,
      retractedAt: clearRetractedAt ? null : retractedAt ?? this.retractedAt,
      groupVersion: clearGroupVersion
          ? null
          : groupVersion ?? this.groupVersion,
      groupMetadataDigest: clearGroupMetadataDigest
          ? null
          : groupMetadataDigest ?? this.groupMetadataDigest,
      etagHash: clearEtagHash ? null : etagHash ?? this.etagHash,
      encryptedRawRecordReference: clearEncryptedRawRecordReference
          ? null
          : encryptedRawRecordReference ?? this.encryptedRawRecordReference,
    );
  }
}

DateTime _normalizeCloudTimestamp(DateTime value) =>
    DateTime.fromMillisecondsSinceEpoch(
      value.toUtc().millisecondsSinceEpoch,
      isUtc: true,
    );

DateTime? _normalizeOptionalCloudTimestamp(DateTime? value) =>
    value == null ? null : _normalizeCloudTimestamp(value);

enum CloudMergeAction { create, update, noChange, defer, quarantine }

enum CloudMergeConflict {
  immutableContentMismatch,
  editRevisionMismatch,
  equalGroupVersionMismatch,
}

class CloudMergeDecision {
  CloudMergeDecision({
    required this.action,
    required this.snapshot,
    Iterable<CloudMergeConflict> conflicts = const [],
  }) : conflicts = Set.unmodifiable(conflicts.toSet());

  final CloudMergeAction action;
  final CloudSemanticSnapshot? snapshot;
  final Set<CloudMergeConflict> conflicts;
}

class CloudMergePolicy {
  const CloudMergePolicy();

  CloudMergeDecision merge({
    required CloudSemanticSnapshot? local,
    required CloudSemanticSnapshot incoming,
    bool parentExists = true,
  }) {
    if (incoming.parentLogicalKeyHash != null && !parentExists) {
      return CloudMergeDecision(
        action: CloudMergeAction.defer,
        snapshot: local,
      );
    }

    if (local == null) {
      return CloudMergeDecision(
        action: CloudMergeAction.create,
        snapshot: incoming,
      );
    }
    if (local.kind != incoming.kind ||
        local.logicalEntityKeyHash != incoming.logicalEntityKeyHash) {
      throw ArgumentError(
        'Cloud merge requires matching entity kind and logical key hash',
      );
    }

    if (local.immutableContentDigest != null &&
        incoming.immutableContentDigest != null &&
        local.immutableContentDigest != incoming.immutableContentDigest) {
      return CloudMergeDecision(
        action: CloudMergeAction.quarantine,
        snapshot: local,
        conflicts: const [CloudMergeConflict.immutableContentMismatch],
      );
    }

    final conflicts = <CloudMergeConflict>{};
    var changed = false;
    var immutableContentDigest = local.immutableContentDigest;
    if (immutableContentDigest == null &&
        incoming.immutableContentDigest != null) {
      immutableContentDigest = incoming.immutableContentDigest;
      changed = true;
    }
    final createdAt = _minimum(local.createdAt, incoming.createdAt);
    if (createdAt != local.createdAt) {
      changed = true;
    }
    final readAt = _maximum(local.readAt, incoming.readAt);
    final deliveredAt = _maximum(local.deliveredAt, incoming.deliveredAt);
    if (readAt != local.readAt || deliveredAt != local.deliveredAt) {
      changed = true;
    }

    final mergedEdits = Map<String, CloudEditPart>.of(local.editParts);
    for (final entry in incoming.editParts.entries) {
      final current = mergedEdits[entry.key];
      final candidate = entry.value;
      if (current == null ||
          candidate.revision > current.revision ||
          (candidate.revision == current.revision &&
              candidate.modifiedAt.isAfter(current.modifiedAt) &&
              candidate.contentDigest == current.contentDigest)) {
        mergedEdits[entry.key] = candidate;
        changed = true;
      } else if (candidate.revision == current.revision &&
          candidate.contentDigest != current.contentDigest) {
        conflicts.add(CloudMergeConflict.editRevisionMismatch);
      }
    }

    var retractedAt = local.retractedAt;
    if (incoming.retractedAt != null &&
        (retractedAt == null || incoming.retractedAt!.isAfter(retractedAt))) {
      retractedAt = incoming.retractedAt;
      changed = true;
    }

    var groupVersion = local.groupVersion;
    var groupMetadataDigest = local.groupMetadataDigest;
    final incomingGroupVersion = incoming.groupVersion;
    if (incomingGroupVersion != null &&
        (groupVersion == null || incomingGroupVersion > groupVersion)) {
      groupVersion = incomingGroupVersion;
      groupMetadataDigest = incoming.groupMetadataDigest;
      changed = true;
    } else if (incomingGroupVersion != null &&
        groupVersion == incomingGroupVersion &&
        incoming.groupMetadataDigest != null &&
        groupMetadataDigest != null &&
        incoming.groupMetadataDigest != groupMetadataDigest) {
      conflicts.add(CloudMergeConflict.equalGroupVersionMismatch);
    }

    // Unknown fields and their etag are retained from the latest observed
    // server record without attempting to interpret them.
    var etagHash = local.etagHash;
    var encryptedRawRecordReference = local.encryptedRawRecordReference;
    if (incoming.etagHash != null && incoming.etagHash != local.etagHash) {
      etagHash = incoming.etagHash;
      encryptedRawRecordReference =
          incoming.encryptedRawRecordReference ?? encryptedRawRecordReference;
      changed = true;
    }

    final merged = local.copyWith(
      immutableContentDigest: immutableContentDigest,
      createdAt: createdAt,
      readAt: readAt,
      deliveredAt: deliveredAt,
      editParts: mergedEdits,
      retractedAt: retractedAt,
      groupVersion: groupVersion,
      groupMetadataDigest: groupMetadataDigest,
      etagHash: etagHash,
      encryptedRawRecordReference: encryptedRawRecordReference,
    );
    return CloudMergeDecision(
      action: changed ? CloudMergeAction.update : CloudMergeAction.noChange,
      snapshot: merged,
      conflicts: conflicts,
    );
  }

  DateTime? _maximum(DateTime? first, DateTime? second) {
    if (first == null) return second;
    if (second == null) return first;
    return second.isAfter(first) ? second : first;
  }

  DateTime? _minimum(DateTime? first, DateTime? second) {
    if (first == null) return second;
    if (second == null) return first;
    return second.isBefore(first) ? second : first;
  }
}
