import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_group_send_route.dart';
import 'cloud_inbox_applier.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_record_maps.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';

/// Captures the exact protected group-chat dependency for a local text send.
///
/// The binding contains only scoped digests and local row IDs. It pins the
/// current protected record and the native decoder's group-routing digest;
/// raw members, handles, group IDs, and Apple record IDs never leave memory.
String requireCloudSyncRestoredGroupChat({
  required Store store,
  required CloudSyncScope messageScope,
  required Message message,
}) => _requireRestoredGroupChatById(
  store: store,
  messageScope: messageScope,
  chatId: message.chat.targetId,
);

/// Revalidates a previously admitted group dependency after awaits/restarts.
void requireCloudSyncAdoptedGroupChatDependency({
  required Store store,
  required CloudSyncScope messageScope,
  required String? binding,
  int? expectedChatId,
}) {
  Never reject() => throw CloudSyncFailure(
    category: CloudFailureCategory.dependency,
    safeCode: 'cloud_sync_local_send_chat_not_ready',
  );
  if (binding == null || binding.length > 1536) reject();
  final dynamic decoded;
  try {
    decoded = jsonDecode(binding);
  } on FormatException {
    reject();
  }
  if (decoded is! List ||
      decoded.length != 11 ||
      decoded[0] != 3 ||
      decoded[3] is! int ||
      (decoded[3] as int) <= 0 ||
      (expectedChatId != null && decoded[3] != expectedChatId) ||
      decoded[7] is! String ||
      decoded[8] is! String ||
      decoded[9] is! String ||
      decoded[10] is! String ||
      !_indexedDigest.hasMatch(decoded[7] as String) ||
      !_indexedDigest.hasMatch(decoded[8] as String) ||
      !_indexedDigest.hasMatch(decoded[9] as String) ||
      !_contentDigest.hasMatch(decoded[10] as String)) {
    reject();
  }
  if (_requireRestoredGroupChatById(
        store: store,
        messageScope: messageScope,
        chatId: decoded[3] as int,
        serverRecordIdHash: decoded[7] as String,
      ) !=
      binding) {
    reject();
  }
}

String _requireRestoredGroupChatById({
  required Store store,
  required CloudSyncScope messageScope,
  required int chatId,
  String? serverRecordIdHash,
}) {
  Never reject() => throw CloudSyncFailure(
    category: CloudFailureCategory.dependency,
    safeCode: 'cloud_sync_local_send_chat_not_ready',
  );

  final chat = chatId > 0 ? store.box<Chat>().get(chatId) : null;
  final route = chat == null ? null : CloudSyncGroupSendRoute.capture(chat);
  if (chat == null ||
      route == null ||
      route.provisional ||
      route.groupId == null) {
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
          'semantic-snapshot4:$generationKey:chat:${snapshot.logicalEntityKeyHash}' ||
      !_contentDigest.hasMatch(snapshot.groupMetadataDigest ?? '') ||
      route.routingMetadataDigest(groupVersion: chat.groupVersion) !=
          snapshot.groupMetadataDigest) {
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

  final serviceAlias = _chatAlias(
    store: store,
    generationKey: generationKey,
    lookup: lookup,
    kind: CloudSemanticChatAliasKind.serviceIdentifier,
  );
  final groupAlias = _chatAlias(
    store: store,
    generationKey: generationKey,
    lookup: lookup,
    kind: CloudSemanticChatAliasKind.groupId,
  );
  if (!_validAlias(
        alias: serviceAlias,
        scope: scope,
        scopeKey: scopeKey,
        generationKey: generationKey,
        generation: generation,
        chat: chat,
        snapshot: snapshot,
        canonicalHash: canonicalHash,
        expectedKind: CloudSemanticChatAliasKind.serviceIdentifier,
      ) ||
      !_validAlias(
        alias: groupAlias,
        scope: scope,
        scopeKey: scopeKey,
        generationKey: generationKey,
        generation: generation,
        chat: chat,
        snapshot: snapshot,
        canonicalHash: canonicalHash,
        expectedKind: CloudSemanticChatAliasKind.groupId,
      )) {
    reject();
  }

  final canonicalMapping = cloudSyncFindRecordMap(
    store: store,
    scope: scope,
    generation: generation,
    logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
  );
  if (canonicalMapping == null) reject();
  final mapping = serverRecordIdHash == null
      ? canonicalMapping
      : cloudSyncFindRecordMap(
          store: store,
          scope: scope,
          generation: generation,
          logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
          serverRecordIdHash: serverRecordIdHash,
        );
  if (mapping == null ||
      mapping.scopeKey != scopeKey ||
      mapping.accountFingerprint != scope.accountFingerprint ||
      mapping.zone != scope.zone ||
      mapping.generation != generation ||
      mapping.logicalEntityKeyHash != snapshot.logicalEntityKeyHash ||
      mapping.encryptedRawRecordRef == null ||
      !_indexedDigest.hasMatch(mapping.serverRecordIdHash)) {
    reject();
  }

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
        latest.encryptedServerRecordId != mapping.encryptedServerRecordId ||
        latest.encryptedPayloadRef != mapping.encryptedRawRecordRef ||
        (mapping.serverRecordIdHash == canonicalMapping.serverRecordIdHash &&
            latest.etagHash != snapshot.etagHash)) {
      reject();
    }
  } finally {
    latestQuery.close();
  }
  return jsonEncode([
    3,
    scopeKey,
    generation,
    chat.id,
    lookup,
    canonicalHash,
    snapshot.logicalEntityKeyHash,
    mapping.serverRecordIdHash,
    serviceAlias!.aliasKeyHash,
    groupAlias!.aliasKeyHash,
    snapshot.groupMetadataDigest,
  ]);
}

CloudSemanticChatAliasEntity? _chatAlias({
  required Store store,
  required String generationKey,
  required String lookup,
  required CloudSemanticChatAliasKind kind,
}) => _unique(
  store.box<CloudSemanticChatAliasEntity>().query(
    CloudSemanticChatAliasEntity_.scopeGenerationKey
        .equals(generationKey)
        .and(
          CloudSemanticChatAliasEntity_.canonicalGuidLookupHash.equals(lookup),
        )
        .and(CloudSemanticChatAliasEntity_.aliasKind.equals(kind.name)),
  ),
);

bool _validAlias({
  required CloudSemanticChatAliasEntity? alias,
  required CloudSyncScope scope,
  required String scopeKey,
  required String generationKey,
  required int generation,
  required Chat chat,
  required CloudSemanticSnapshotEntity snapshot,
  required String canonicalHash,
  required CloudSemanticChatAliasKind expectedKind,
}) {
  if (alias == null ||
      alias.scopeGenerationKey != generationKey ||
      alias.scopeKey != scopeKey ||
      alias.accountFingerprint != scope.accountFingerprint ||
      alias.container != scope.container ||
      alias.database != scope.database ||
      alias.zone != scope.zone ||
      alias.streamKind != scope.streamKind.name ||
      alias.schemaVersion != scope.schemaVersion ||
      alias.generation != generation ||
      alias.service != CloudSemanticService.iMessage.name ||
      alias.aliasKind != expectedKind.name ||
      alias.chatId != chat.id ||
      alias.chatLogicalEntityKeyHash != snapshot.logicalEntityKeyHash ||
      alias.canonicalGuidHash != canonicalHash ||
      alias.canonicalGuidLookupHash != snapshot.canonicalGuidLookupHash ||
      !_indexedDigest.hasMatch(alias.aliasKeyHash)) {
    return false;
  }
  final expectedBindingKey = switch (expectedKind) {
    CloudSemanticChatAliasKind.serviceIdentifier =>
      'semantic-chat-strong2:${_digest('${scope.storageKey}\u001f$generation\u001f${CloudSemanticService.iMessage.name}\u001f${CloudSemanticChatAliasKind.serviceIdentifier.name}\u001f${alias.aliasKeyHash}')}',
    CloudSemanticChatAliasKind.groupId =>
      'semantic-chat-claim2:${_digest('${scope.storageKey}\u001f$generation\u001f${CloudSemanticService.iMessage.name}\u001f${CloudSemanticChatAliasKind.groupId.name}\u001f${alias.aliasKeyHash}\u001f${snapshot.logicalEntityKeyHash}')}',
    _ => '',
  };
  return alias.bindingKey == expectedBindingKey;
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

final _indexedDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _contentDigest = RegExp(r'^[0-9a-f]{64}$');

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
