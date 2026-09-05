import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';

/// Admission-only dependency check for a fresh direct iMessage create.
///
/// Runs inside the caller's ObjectBox transaction, before staging and again
/// before adopting the envelope. A local Chat (including a legacy row) is not
/// evidence that the corresponding chatEncryptedv2 record exists in iCloud.
/// This does not grant transmission permission or create missing remote chats.
void requireCloudSyncRestoredDirectChat({
  required Store store,
  required CloudSyncScope messageScope,
  required Message message,
}) {
  Never reject() => throw CloudSyncFailure(
    category: CloudFailureCategory.dependency,
    safeCode: 'cloud_sync_local_send_chat_not_ready',
  );

  final chat = store.box<Chat>().get(message.chat.targetId);
  if (chat == null ||
      chat.id == null ||
      chat.id! <= 0 ||
      chat.isRpSms ||
      chat.isRoutingStub ||
      chat.style != 45 ||
      chat.chatIdentifier?.isNotEmpty != true ||
      chat.guid != 'iMessage;-;${chat.chatIdentifier}') {
    reject();
  }
  final scope = CloudSyncScope(
    accountFingerprint: messageScope.accountFingerprint,
    container: messageScope.container,
    database: messageScope.database,
    zone: 'chatManateeZone',
    streamKind: messageScope.streamKind,
    schemaVersion: messageScope.schemaVersion,
    persistenceLane: messageScope.persistenceLane,
  );
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final checkpoint = _unique(
    store.box<CloudSyncCheckpointEntity>().query(
      CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey),
    ),
  );
  // The account projection gate validates the complete checkpoint before
  // entering here. Bind this proof to its current chat generation, not the
  // message zone's independently advancing generation.
  if (checkpoint == null || checkpoint.generation <= 0) reject();
  final generation = checkpoint.generation;
  final generationKey =
      'semantic-generation4:${_digest('$scopeKey\u001f$generation')}';
  final lookup = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
    scope: scope,
    generation: generation,
    canonicalGuid: chat.guid,
  );
  final snapshot = _unique(
    store.box<CloudSemanticSnapshotEntity>().query(
      CloudSemanticSnapshotEntity_.scopeGenerationKey
          .equals(generationKey)
          .and(
            CloudSemanticSnapshotEntity_.canonicalGuidLookupHash.equals(lookup),
          ),
    ),
  );
  if (snapshot == null ||
      snapshot.scopeKey != scopeKey ||
      snapshot.accountFingerprint != scope.accountFingerprint ||
      snapshot.container != scope.container ||
      snapshot.database != scope.database ||
      snapshot.zone != scope.zone ||
      snapshot.streamKind != scope.streamKind.name ||
      snapshot.schemaVersion != scope.schemaVersion ||
      snapshot.generation != generation ||
      snapshot.entityKind != CloudEntityKind.chat.name ||
      snapshot.logicalEntityKeyHash.isEmpty ||
      snapshot.snapshotKey !=
          'semantic-snapshot4:$generationKey:chat:${snapshot.logicalEntityKeyHash}') {
    reject();
  }
  final canonicalHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
    scope: scope,
    generation: generation,
    kind: CloudEntityKind.chat,
    logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
    canonicalGuid: chat.guid,
  );
  if (snapshot.canonicalGuidHash != canonicalHash) reject();

  final alias = _unique(
    store.box<CloudSemanticChatAliasEntity>().query(
      CloudSemanticChatAliasEntity_.scopeGenerationKey
          .equals(generationKey)
          .and(
            CloudSemanticChatAliasEntity_.canonicalGuidLookupHash.equals(
              lookup,
            ),
          )
          .and(
            CloudSemanticChatAliasEntity_.aliasKind.equals('serviceIdentifier'),
          ),
    ),
  );
  if (alias == null ||
      alias.scopeKey != scopeKey ||
      alias.accountFingerprint != scope.accountFingerprint ||
      alias.container != scope.container ||
      alias.database != scope.database ||
      alias.zone != scope.zone ||
      alias.streamKind != scope.streamKind.name ||
      alias.schemaVersion != scope.schemaVersion ||
      alias.generation != generation ||
      alias.service != 'iMessage' ||
      alias.chatId != chat.id ||
      alias.chatLogicalEntityKeyHash != snapshot.logicalEntityKeyHash ||
      alias.canonicalGuidHash != canonicalHash ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(alias.aliasKeyHash) ||
      alias.bindingKey !=
          'semantic-chat-strong2:${_digest('${scope.storageKey}\u001f$generation\u001fiMessage\u001fserviceIdentifier\u001f${alias.aliasKeyHash}')}') {
    reject();
  }

  final mapKey =
      'record-map:${_digest('${scope.storageKey}\u001frecord-map\u001f${snapshot.logicalEntityKeyHash}')}';
  final mapping = _unique(
    store.box<CloudRecordMapEntity>().query(
      CloudRecordMapEntity_.mapKey.equals(mapKey),
    ),
  );
  if (mapping == null ||
      mapping.scopeKey != scopeKey ||
      mapping.accountFingerprint != scope.accountFingerprint ||
      mapping.zone != scope.zone ||
      mapping.generation != generation ||
      mapping.logicalEntityKeyHash != snapshot.logicalEntityKeyHash ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(mapping.serverRecordIdHash)) {
    reject();
  }
  // A once-valid snapshot must not mask a later deletion or retained update
  // for this exact remote chat. Unrelated retained history is not a dependency.
  final latestQuery =
      (store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey
                .equals(scopeKey)
                .and(CloudInboxChangeEntity_.generation.equals(generation))
                .and(
                  CloudInboxChangeEntity_.serverRecordIdHash.equals(
                    mapping.serverRecordIdHash,
                  ),
                ),
          )..order(
            CloudInboxChangeEntity_.fetchSequence,
            flags: Order.descending,
          ))
          .build()
        ..limit = 1;
  try {
    final latest = latestQuery.findFirst();
    if (latest == null ||
        latest.accountFingerprint != scope.accountFingerprint ||
        latest.zone != scope.zone ||
        latest.status != CloudInboxStatus.applied.index ||
        latest.isTombstone ||
        latest.changeType != CloudChangeType.save.name ||
        latest.etagHash != mapping.etagHash ||
        latest.etagHash != snapshot.etagHash) {
      reject();
    }
  } finally {
    latestQuery.close();
  }
}

T? _unique<T>(QueryBuilder<T> builder) {
  final query = builder.build()..limit = 2;
  try {
    final rows = query.find();
    return rows.length == 1 ? rows.single : null;
  } finally {
    query.close();
  }
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
