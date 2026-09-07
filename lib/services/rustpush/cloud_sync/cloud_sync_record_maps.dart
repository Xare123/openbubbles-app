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
  void validate(CloudRecordMapEntity row, String key) {
    if (row.mapKey != key ||
        row.scopeKey != cloudSyncPersistentScopeKey(scope) ||
        row.accountFingerprint != scope.accountFingerprint ||
        row.zone != scope.zone ||
        row.generation != generation ||
        row.logicalEntityKeyHash != logicalEntityKeyHash ||
        row.serverRecordIdHash.isEmpty ||
        row.encryptedServerRecordId.isEmpty) {
      reject();
    }
  }

  validate(canonical, canonicalKey);
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
  final key = cloudSyncChatRecordMemberKey(scope, generation, target);
  final member = read(key);
  if (member != null) {
    validate(member, key);
    if (member.serverRecordIdHash != target) reject();
  }
  if (canonical.serverRecordIdHash != target) return member;
  if (member != null &&
      (member.etagHash != canonical.etagHash ||
          member.encryptedServerRecordId != canonical.encryptedServerRecordId ||
          member.encryptedRawRecordRef != canonical.encryptedRawRecordRef)) {
    reject();
  }
  return canonical;
}
