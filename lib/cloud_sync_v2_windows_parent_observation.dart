// Diagnostic-only cached-parent correlation. No decode, fetch, projection,
// receipt, or authority is created here. Raw identifiers never leave this call.
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/src/rust/api/cloud_sync_dependency.dart' as native;

/// Reject mixed or stale native observations before they can select an inbox
/// record. This is correlation only, never permission to project or fetch.
String? validateCloudSyncParentLocator({
  required native.CloudSyncDependencyParentResult result,
  required String sourceChangeHash,
  required String sourceRecordHash,
  required int sourceGeneration,
  required int messageGeneration,
  required String parentLogicalHash,
  required String nativeSessionId,
}) {
  final hashPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  if (sourceGeneration < 1 ||
      messageGeneration < 1 ||
      !hashPattern.hasMatch(sourceChangeHash) ||
      !hashPattern.hasMatch(sourceRecordHash) ||
      !hashPattern.hasMatch(parentLogicalHash) ||
      nativeSessionId.isEmpty) {
    throw StateError('retained_parent_locator_binding_rejected');
  }
  final target = result.target;
  if (target == null && result.failureCode != null) return null;
  if (target == null ||
      result.failureCode != null ||
      target.sourceChangeIdHash != sourceChangeHash ||
      target.sourceRecordIdHash != sourceRecordHash ||
      target.sourceGeneration != BigInt.from(sourceGeneration) ||
      target.messageGeneration != BigInt.from(messageGeneration) ||
      target.parentLogicalKeyHash != parentLogicalHash ||
      target.nativeSessionId != nativeSessionId ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(target.parentRecordIdHash) ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(target.bindingHash)) {
    throw StateError('retained_parent_locator_binding_rejected');
  }
  return target.parentRecordIdHash;
}

Map<String, Object?> observeCloudSyncRetainedMessageParent({
  required Store store,
  required CloudSyncScope scope,
  required int generation,
  required String logicalParentHash,
  required String canonicalParentGuid,
  String? locatedParentRecordHash,
}) {
  if (scope.zone != 'messageManateeZone' ||
      scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
      generation < 1 ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(logicalParentHash) ||
      (locatedParentRecordHash != null &&
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(locatedParentRecordHash))) {
    throw StateError('retained_parent_observation_scope_invalid');
  }
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final expectedLookup = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
    scope: scope,
    generation: generation,
    canonicalGuid: canonicalParentGuid,
  );
  final expectedOwner = CloudCanonicalIdentityDigest.forCanonicalGuid(
    scope: scope,
    generation: generation,
    kind: CloudEntityKind.message,
    logicalEntityKeyHash: logicalParentHash,
    canonicalGuid: canonicalParentGuid,
  );
  return store.runInTransaction(TxMode.read, () {
    final checkpoints = store
        .box<CloudSyncCheckpointEntity>()
        .query(CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey))
        .build();
    try {
      final checkpoint = checkpoints.findUnique();
      if (checkpoint == null ||
          checkpoint.generation != generation ||
          checkpoint.accountFingerprint != scope.accountFingerprint ||
          checkpoint.zone != scope.zone) {
        throw StateError('retained_parent_observation_checkpoint_changed');
      }
    } finally {
      checkpoints.close();
    }
    final rows = store
        .box<Message>()
        .query(Message_.guid.equals(canonicalParentGuid))
        .build();
    final variants = store
        .box<Message>()
        .query(
          Message_.guid
              .equals(canonicalParentGuid.toUpperCase())
              .or(Message_.guid.equals(canonicalParentGuid.toLowerCase())),
        )
        .build();
    final snapshots =
        store
            .box<CloudSemanticSnapshotEntity>()
            .query(
              CloudSemanticSnapshotEntity_.scopeKey
                  .equals(scopeKey)
                  .and(
                    CloudSemanticSnapshotEntity_.accountFingerprint.equals(
                      scope.accountFingerprint,
                    ),
                  )
                  .and(CloudSemanticSnapshotEntity_.zone.equals(scope.zone))
                  .and(
                    CloudSemanticSnapshotEntity_.generation.equals(generation),
                  )
                  .and(
                    CloudSemanticSnapshotEntity_.logicalEntityKeyHash.equals(
                      logicalParentHash,
                    ),
                  )
                  .and(
                    CloudSemanticSnapshotEntity_.entityKind.equals(
                      CloudEntityKind.message.name,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    final maps =
        store
            .box<CloudRecordMapEntity>()
            .query(
              CloudRecordMapEntity_.scopeKey
                  .equals(scopeKey)
                  .and(
                    CloudRecordMapEntity_.accountFingerprint.equals(
                      scope.accountFingerprint,
                    ),
                  )
                  .and(CloudRecordMapEntity_.zone.equals(scope.zone))
                  .and(CloudRecordMapEntity_.generation.equals(generation))
                  .and(
                    CloudRecordMapEntity_.logicalEntityKeyHash.equals(
                      logicalParentHash,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      final savedSnapshots = snapshots.find();
      final savedMaps = maps.find();
      final result = <String, Object?>{
        'parent_row_count': rows.count(),
        'parent_case_variant_count': variants.count(),
        'parent_snapshot_count': savedSnapshots.length,
        'parent_snapshot_guid_matches':
            savedSnapshots.length == 1 &&
            savedSnapshots.single.canonicalGuidLookupHash == expectedLookup &&
            savedSnapshots.single.canonicalGuidHash == expectedOwner,
        'parent_map_count': savedMaps.length,
        'parent_map_key_matches':
            savedMaps.length == 1 &&
            savedMaps.single.mapKey ==
                cloudSyncCanonicalRecordMapKey(scope, logicalParentHash),
      };
      // An explicitly bound native locator can find retained physical evidence
      // before projection has created a map. It still grants no row ownership.
      final map = savedMaps.length == 1 ? savedMaps.single : null;
      final physicalHash = locatedParentRecordHash ?? map?.serverRecordIdHash;
      if (physicalHash == null) return result;
      result['parent_physical_lookup_used'] = locatedParentRecordHash != null;
      result['parent_locator_matches_map'] =
          map != null && map.serverRecordIdHash == physicalHash;
      final latest =
          (store.box<CloudInboxChangeEntity>().query(
                CloudInboxChangeEntity_.scopeKey
                    .equals(scopeKey)
                    .and(
                      CloudInboxChangeEntity_.accountFingerprint.equals(
                        scope.accountFingerprint,
                      ),
                    )
                    .and(CloudInboxChangeEntity_.zone.equals(scope.zone))
                    .and(CloudInboxChangeEntity_.generation.equals(generation))
                    .and(
                      CloudInboxChangeEntity_.serverRecordIdHash.equals(
                        physicalHash,
                      ),
                    ),
              )..order(
                CloudInboxChangeEntity_.fetchSequence,
                flags: Order.descending,
              ))
              .build()
            ..limit = 1;
      try {
        final row = latest.findFirst();
        result['parent_physical_inbox_present'] = row != null;
        result['parent_mapped_inbox_present'] =
            row != null &&
            map != null &&
            map.serverRecordIdHash == physicalHash;
        if (row != null) {
          result.addAll({
            'parent_latest_is_save':
                row.changeType == 'save' && !row.isTombstone,
            'parent_latest_tombstone': row.isTombstone,
            'parent_latest_status': row.status,
            'parent_latest_excluded':
                row.failureCategory ==
                CloudFailureCategory.outOfScopeService.name,
            'parent_map_matches_latest':
                map != null &&
                map.serverRecordIdHash == physicalHash &&
                map.mapKey ==
                    cloudSyncCanonicalRecordMapKey(scope, logicalParentHash) &&
                map.etagHash == row.etagHash &&
                map.encryptedServerRecordId == row.encryptedServerRecordId &&
                map.encryptedRawRecordRef == row.encryptedPayloadRef &&
                map.rawRecordGeneration == generation,
          });
        }
      } finally {
        latest.close();
      }
      return result;
    } finally {
      rows.close();
      variants.close();
      snapshots.close();
      maps.close();
    }
  });
}
