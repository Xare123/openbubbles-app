// Diagnostic-only cached-parent correlation. No decode, fetch, projection,
// receipt, or authority is created here. Raw identifiers never leave this call.
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';

Map<String, Object?> observeCloudSyncRetainedMessageParent({
  required Store store,
  required CloudSyncScope scope,
  required int generation,
  required String logicalParentHash,
  required String canonicalParentGuid,
}) {
  if (scope.zone != 'messageManateeZone' ||
      scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
      generation < 1 ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(logicalParentHash)) {
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
      if (savedMaps.length != 1) return result;
      final map = savedMaps.single;
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
                        map.serverRecordIdHash,
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
        result['parent_mapped_inbox_present'] = row != null;
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
