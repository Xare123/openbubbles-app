import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';

const _syntheticSemanticKey = 'restored-chat-test-fixture-key';

final syntheticRestoredChatServerRecordIdHash = _nativeSemanticHash(
  domain: 'OpenBubbles Cloud Sync V2 server record identity\u0000',
  value: 'synthetic-restored-chat-record',
);

final syntheticRestoredChatEtagHash = _nativeSemanticHash(
  domain: 'OpenBubbles Cloud Sync V2 canonical etag identity v1\u0000',
  value: 'synthetic-restored-chat-etag',
);

String syntheticRestoredChatLogicalEntityKeyHash(String canonicalGuid) =>
    _nativeSemanticHash(
      domain: 'OpenBubbles Cloud Sync V2 logical entity identity\u0000',
      value: 'chat\u0000$canonicalGuid',
    );

String syntheticRestoredChatAliasKeyHash(String chatIdentifier) =>
    _nativeSemanticHash(
      domain: 'OpenBubbles Cloud Sync V2 canonical alias identity v1\u0000',
      value: 'service-identifier\u0000$chatIdentifier',
    );

Future<CloudInboxChangeEntity> seedSyntheticRestoredChatAppliedSource({
  required Store objectBox,
  required ObjectBoxCloudSyncStore store,
  required CloudSyncScope chatScope,
  required DateTime now,
}) async {
  final checkpoint = await store.readCheckpoint(chatScope);
  final fence = (await store.tryAcquireCoordinatorLease(
    chatScope,
    ownerId: 'synthetic-restored-chat-source',
    now: now,
    leaseDuration: const Duration(hours: 1),
  ))!;
  final sequence = checkpoint.fetchedSequence + 1;
  final change = CloudFetchedChange(
    changeId: _nativeSemanticHash(
      domain: 'OpenBubbles Cloud Sync V2 synthetic change identity\u0000',
      value: '$sequence',
    ),
    recordIdHash: syntheticRestoredChatServerRecordIdHash,
    etagHash: syntheticRestoredChatEtagHash,
    type: CloudChangeType.save,
    encryptedServerRecordId: 'obcs2.ref.${'R' * 43}',
    protectedSystemFieldsReference: 'obcs2.ref.${'F' * 43}',
    encryptedPayloadReference: 'obcs2.ref.${'P' * 43}',
    payloadSha256: 'e' * 64,
    isTombstone: false,
  );
  await store.journalFetchedBatch(
    CloudFetchBatch(
      scope: chatScope,
      changes: [change],
      batchId: 'synthetic-restored-chat-batch-$sequence',
      generation: checkpoint.generation,
      nextToken: 'synthetic-restored-chat-token-$sequence',
      hasMore: false,
    ),
    now: now,
    leaseFence: fence,
    expectedGeneration: checkpoint.generation,
    expectedFetchedToken: checkpoint.fetchedToken,
  );
  await store.markInboxApplied(
    chatScope,
    sequence: sequence,
    now: now,
    leaseFence: fence,
  );
  await store.recordPullSuccess(chatScope, now: now);
  return objectBox.box<CloudInboxChangeEntity>().getAll().singleWhere(
    (row) =>
        row.scopeKey == cloudSyncPersistentScopeKey(chatScope) &&
        row.generation == checkpoint.generation &&
        row.fetchSequence == sequence,
  );
}

Future<void> seedSyntheticRestoredChatProof({
  required Store objectBox,
  required ObjectBoxCloudSyncStore store,
  required CloudSyncScope chatScope,
  required Chat chat,
  required CloudInboxChangeEntity appliedSource,
  required DateTime now,
}) async {
  final checkpoint = await store.readCheckpoint(chatScope);
  final scopeKey = cloudSyncPersistentScopeKey(chatScope);
  if (appliedSource.scopeKey != scopeKey ||
      appliedSource.generation != checkpoint.generation ||
      appliedSource.status != CloudInboxStatus.applied.index ||
      appliedSource.isTombstone ||
      appliedSource.changeType != CloudChangeType.save.name ||
      appliedSource.serverRecordIdHash !=
          syntheticRestoredChatServerRecordIdHash ||
      appliedSource.etagHash != syntheticRestoredChatEtagHash) {
    throw StateError('synthetic_restored_chat_source_invalid');
  }
  final generation = checkpoint.generation;
  final generationKey =
      'semantic-generation4:${_digest('$scopeKey\u001f$generation')}';
  final logicalKey = syntheticRestoredChatLogicalEntityKeyHash(chat.guid);
  final aliasKey = syntheticRestoredChatAliasKeyHash(chat.chatIdentifier!);
  final canonicalGuidHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
    scope: chatScope,
    generation: generation,
    kind: CloudEntityKind.chat,
    logicalEntityKeyHash: logicalKey,
    canonicalGuid: chat.guid,
  );
  final canonicalGuidLookupHash =
      CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
        scope: chatScope,
        generation: generation,
        canonicalGuid: chat.guid,
      );

  await store.upsertRecordMap(
    CloudRecordMapEntry(
      scope: chatScope,
      logicalEntityKeyHash: logicalKey,
      serverRecordIdHash: appliedSource.serverRecordIdHash,
      encryptedServerRecordId: appliedSource.encryptedServerRecordId!,
      etagHash: appliedSource.etagHash,
      encryptedRawRecordReference: appliedSource.encryptedPayloadRef,
      updatedAt: now,
    ),
    generation: generation,
  );
  objectBox.box<CloudSemanticSnapshotEntity>().put(
    CloudSemanticSnapshotEntity(
      snapshotKey: 'semantic-snapshot4:$generationKey:chat:$logicalKey',
      scopeGenerationKey: generationKey,
      scopeKey: scopeKey,
      accountFingerprint: chatScope.accountFingerprint,
      container: chatScope.container,
      database: chatScope.database,
      zone: chatScope.zone,
      streamKind: chatScope.streamKind.name,
      schemaVersion: chatScope.schemaVersion,
      generation: generation,
      entityKind: CloudEntityKind.chat.name,
      logicalEntityKeyHash: logicalKey,
      canonicalGuidHash: canonicalGuidHash,
      canonicalGuidLookupHash: canonicalGuidLookupHash,
      etagHash: appliedSource.etagHash,
      updatedAtMs: now.millisecondsSinceEpoch,
    ),
  );
  objectBox.box<CloudSemanticChatAliasEntity>().put(
    CloudSemanticChatAliasEntity(
      bindingKey:
          'semantic-chat-strong2:${_digest('${chatScope.storageKey}\u001f$generation\u001fiMessage\u001fserviceIdentifier\u001f$aliasKey')}',
      scopeGenerationKey: generationKey,
      scopeKey: scopeKey,
      accountFingerprint: chatScope.accountFingerprint,
      container: chatScope.container,
      database: chatScope.database,
      zone: chatScope.zone,
      streamKind: chatScope.streamKind.name,
      schemaVersion: chatScope.schemaVersion,
      generation: generation,
      service: CloudSemanticService.iMessage.name,
      aliasKind: CloudSemanticChatAliasKind.serviceIdentifier.name,
      aliasKeyHash: aliasKey,
      chatLogicalEntityKeyHash: logicalKey,
      canonicalGuidHash: canonicalGuidHash,
      canonicalGuidLookupHash: canonicalGuidLookupHash,
      chatId: chat.id!,
      updatedAtMs: now.millisecondsSinceEpoch,
    ),
  );
}

int recordMapCountForZone(Store objectBox, String zone) => objectBox
    .box<CloudRecordMapEntity>()
    .getAll()
    .where((row) => row.zone == zone)
    .length;

String _nativeSemanticHash({required String domain, required String value}) =>
    base64Url
        .encode(
          Hmac(
            sha256,
            utf8.encode(_syntheticSemanticKey),
          ).convert(utf8.encode('$domain$value')).bytes,
        )
        .replaceAll('=', '');

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
