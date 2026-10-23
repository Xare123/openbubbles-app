import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';

/// Selects provenance, never write authority or proof that a record is live.
/// Call within the owner's ObjectBox transaction. Existing operations must
/// specify their immutable server identity instead of silently following a
/// later canonical source for the same conversation.
CloudRecordMapEntity? cloudSyncFindRecordMap({
  required Store store,
  required CloudSyncScope scope,
  required int generation,
  required String logicalEntityKeyHash,
  String? serverRecordIdHash,
}) {
  Never reject() => throw CloudSyncFailure(
    category: CloudFailureCategory.conflict,
    safeCode: 'semantic_record_mapping_conflict',
  );
  CloudRecordMapEntity? read(String key) {
    final query = store
        .box<CloudRecordMapEntity>()
        .query(CloudRecordMapEntity_.mapKey.equals(key))
        .build();
    try {
      return query.findUnique();
    } finally {
      query.close();
    }
  }

  final canonicalKey = cloudSyncCanonicalRecordMapKey(
    scope,
    logicalEntityKeyHash,
  );
  final canonical = read(canonicalKey);
  if (generation <= 0) reject();
  if (canonical == null || canonical.generation != generation) return null;
  void validate(CloudRecordMapEntity row, String key, String logicalKey) {
    if (row.mapKey != key ||
        row.scopeKey != cloudSyncPersistentScopeKey(scope) ||
        row.accountFingerprint != scope.accountFingerprint ||
        row.zone != scope.zone ||
        row.generation != generation ||
        row.logicalEntityKeyHash != logicalKey ||
        row.serverRecordIdHash.isEmpty ||
        row.encryptedServerRecordId.isEmpty) {
      reject();
    }
  }

  validate(canonical, canonicalKey, logicalEntityKeyHash);
  final chatMembersAllowed =
      scope.container == 'com.apple.messages.cloud' &&
      scope.database == 'private' &&
      scope.zone == 'chatManateeZone' &&
      scope.streamKind == CloudSyncStreamKind.messages &&
      scope.persistenceLane == CloudSyncPersistenceLane.semantic;
  if (!chatMembersAllowed) {
    return serverRecordIdHash == null ||
            serverRecordIdHash == canonical.serverRecordIdHash
        ? canonical
        : null;
  }
  final target = serverRecordIdHash ?? canonical.serverRecordIdHash;
  final key = cloudSyncChatRecordMemberKey(scope, generation, target,
    logicalEntityKeyHash: logicalEntityKeyHash);
  final legacyKey = cloudSyncChatRecordMemberKey(scope, generation, target);
  final routedMember = read(key);
  final legacyMember = read(legacyKey);
  if (routedMember != null) {
    validate(routedMember, key, logicalEntityKeyHash);
    if (routedMember.serverRecordIdHash != target) reject();
  }
  if (legacyMember != null) {
    validate(legacyMember, legacyKey, legacyMember.logicalEntityKeyHash);
    if (legacyMember.serverRecordIdHash != target) reject();
    if (legacyMember.logicalEntityKeyHash == logicalEntityKeyHash) {
      if (routedMember != null &&
          !cloudSyncRecordMapProvenanceMatches(legacyMember, routedMember)) {
        reject();
      }
    } else {
      // A foreign v1 row is never a fallback for this route. It can coexist
      // only when both routes have explicit v2 provenance and its own durable
      // owner still exists. Do not silently hide a corrupt legacy owner.
      if (routedMember == null) reject();
      final ownerKey = cloudSyncCanonicalRecordMapKey(
        scope, legacyMember.logicalEntityKeyHash);
      final owner = read(ownerKey);
      final foreignKey = cloudSyncChatRecordMemberKey(scope, generation, target,
        logicalEntityKeyHash: legacyMember.logicalEntityKeyHash);
      final foreign = read(foreignKey);
      if (owner == null || foreign == null) reject();
      validate(owner, ownerKey, legacyMember.logicalEntityKeyHash);
      validate(foreign, foreignKey, legacyMember.logicalEntityKeyHash);
      if (!cloudSyncRecordMapProvenanceMatches(legacyMember, foreign) ||
          (owner.serverRecordIdHash == target &&
              !cloudSyncRecordMapProvenanceMatches(owner, foreign))) {
        reject();
      }
    }
  }
  final member = routedMember ?? legacyMember;
  if (member != null) {
    validate(member, routedMember == null ? legacyKey : key,
      logicalEntityKeyHash);
    if (member.serverRecordIdHash != target) reject();
  }
  if (canonical.serverRecordIdHash != target) return member;
  if (member != null &&
      !cloudSyncRecordMapProvenanceMatches(member, canonical)) {
    reject();
  }
  return canonical;
}

/// Compares the immutable source and pending-writer fields, not row IDs, keys
/// or timestamps. Mirroring provenance must never replace write authority.
bool cloudSyncRecordMapProvenanceMatches(
  CloudRecordMapEntity left,
  CloudRecordMapEntity right,
) => left.scopeKey == right.scopeKey &&
    left.accountFingerprint == right.accountFingerprint &&
    left.zone == right.zone && left.generation == right.generation &&
    left.logicalEntityKeyHash == right.logicalEntityKeyHash &&
    left.serverRecordIdHash == right.serverRecordIdHash &&
    left.etagHash == right.etagHash &&
    left.encryptedServerRecordId == right.encryptedServerRecordId &&
    left.encryptedRawRecordRef == right.encryptedRawRecordRef &&
    left.rawRecordGeneration == right.rawRecordGeneration &&
    left.protectedReadbackLeaseReference == right.protectedReadbackLeaseReference &&
    left.pendingUpdateOperationId == right.pendingUpdateOperationId &&
    left.pendingUpdatePredecessorEtagHash == right.pendingUpdatePredecessorEtagHash;
