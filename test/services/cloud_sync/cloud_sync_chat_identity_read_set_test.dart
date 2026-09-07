import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_identity_read_set.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late Directory directory;
  late Store store;
  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'chatManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  String hash(int n) => n.toString().padLeft(43, 'A');
  CloudSyncCheckpointEntity checkpoint() =>
      store.box<CloudSyncCheckpointEntity>().getAll().single;
  CloudInboxChangeEntity saved() => store
      .box<CloudInboxChangeEntity>()
      .getAll()
      .singleWhere((row) => row.fetchSequence == 2);
  CloudInboxChangeEntity row(
    int sequence, {
    int status = 3,
    bool deleted = false,
  }) => CloudInboxChangeEntity(
    changeKey: hash(sequence),
    changeIdHash: hash(sequence + 100),
    scopeKey: cloudSyncPersistentScopeKey(scope),
    accountFingerprint: scope.accountFingerprint,
    zone: scope.zone,
    serverRecordIdHash: hash(sequence + 200),
    etagHash: hash(sequence + 300),
    changeType: deleted ? 'delete' : 'save',
    isTombstone: deleted,
    encryptedServerRecordId: 'private-ciphertext-$sequence',
    encryptedPayloadRef: 'obcs2.ref.${hash(sequence + 400)}',
    payloadSha256: 'a' * 64,
    batchId: 'private-batch',
    generation: 1,
    fetchSequence: sequence,
    status: status,
    createdAtMs: 1,
    updatedAtMs: 1,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'cloud-chat-identity-test-',
    );
    store = await openStore(directory: directory.path);
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: cloudSyncPersistentScopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        persistenceLane: scope.persistenceLane.name,
        fetchedSequence: 3,
        appliedSequence: 1,
        fetchedTokenCiphertext: 'private-token',
        lastSuccessfulAtMs: 1,
        updatedAtMs: 1,
      ),
    );
    store.box<CloudInboxChangeEntity>().putMany([
      row(1, status: 1),
      row(2)..failureCategory = 'unsupportedService',
      row(3, deleted: true),
    ]);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'captures opaque retained saves without granting projection or writing',
    () {
      final snapshot = CloudSyncChatIdentityReadSet.capture(store, scope);
      expect(snapshot.fetchedSequence, 3);
      expect(snapshot.appliedSequence, 1);
      expect(snapshot.retainedTombstones, 1);
      expect(snapshot.retainedSaves.single.sequence, 2);
      expect(snapshot.retainedSaves.single.etagHash, hash(302));
      expect(() => snapshot.retainedSaves.clear(), throwsUnsupportedError);
      store.runInTransaction(
        TxMode.write,
        () => snapshot.requireUnchanged(store),
      );
      expect(saved().status, 3);
      expect(saved().failureCategory, 'unsupportedService');
      expect(checkpoint().appliedSequence, 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(snapshot.toString(), isNot(contains('private')));
      expect(
        snapshot.retainedSaves.single.toString(),
        isNot(contains('private')),
      );
    },
  );

  for (final mutation in <String, void Function(CloudInboxChangeEntity)>{
    'etag': (r) => r.etagHash = hash(999),
    'record id': (r) => r.serverRecordIdHash = hash(999),
    'change id': (r) => r.changeIdHash = hash(999),
    'payload digest': (r) => r.payloadSha256 = 'b' * 64,
    'protected payload': (r) =>
        r.encryptedPayloadRef = 'obcs2.ref.${hash(999)}',
    'protected identity': (r) => r.encryptedServerRecordId = 'private-other',
    'system fields': (r) => r.protectedSystemFieldsRef = 'private-other',
    'status': (r) => r.status = 1,
    'classification': (r) => r.failureCategory = 'outOfScopeService',
    'preflight': (r) => r.preflightCode = 'private-other',
    'account': (r) => r.accountFingerprint = testAccountFingerprintB,
    'zone': (r) => r.zone = 'messageManateeZone',
    'sequence': (r) => r.fetchSequence = 4,
    'generation': (r) => r.generation = 2,
    'pending': (r) => r.status = 0,
  }.entries) {
    test('invalidates the read set after ${mutation.key} changes', () {
      final snapshot = CloudSyncChatIdentityReadSet.capture(store, scope);
      final updated = saved();
      mutation.value(updated);
      store.box<CloudInboxChangeEntity>().put(updated);
      expect(() => snapshot.requireUnchanged(store), throwsStateError);
    });
  }

  for (final mutation in <String, void Function(CloudSyncCheckpointEntity)>{
    'token': (c) => c.fetchedTokenCiphertext = 'private-new-token',
    'generation': (c) => c.generation = 2,
    'pending batch': (c) => c.pendingBatchId = 'private-pending',
    'pending token': (c) => c.pendingFetchedTokenCiphertext = 'private-pending',
    'backoff': (c) => c.backoffAttempt = 1,
    'error': (c) => c.lastErrorCategory = 'authorization',
    'sequence gap': (c) => c.fetchedSequence = 4,
    'invalid applied floor': (c) => c.appliedSequence = 2,
    'revision': (c) => c.mutationRevisionCounter++,
  }.entries) {
    test('invalidates the read set after checkpoint ${mutation.key}', () {
      final snapshot = CloudSyncChatIdentityReadSet.capture(store, scope);
      final updated = checkpoint();
      mutation.value(updated);
      store.box<CloudSyncCheckpointEntity>().put(updated);
      expect(() => snapshot.requireUnchanged(store), throwsStateError);
    });
  }

  test(
    'rejects missing protected source instead of skipping an unknown Chat',
    () {
      store.box<CloudInboxChangeEntity>().put(
        saved()..encryptedPayloadRef = null,
      );
      expect(
        () => CloudSyncChatIdentityReadSet.capture(store, scope),
        throwsStateError,
      );
    },
  );
  test('does not ignore a classified retained tombstone', () {
    final deleted = store.box<CloudInboxChangeEntity>().getAll().last;
    store.box<CloudInboxChangeEntity>().put(
      deleted..failureCategory = 'conflict',
    );
    expect(
      () => CloudSyncChatIdentityReadSet.capture(store, scope),
      throwsStateError,
    );
  });
  test(
    'includes a newly retained save in the next capture but fences the old one',
    () {
      final snapshot = CloudSyncChatIdentityReadSet.capture(store, scope);
      store.box<CloudInboxChangeEntity>().put(row(4));
      store.box<CloudSyncCheckpointEntity>().put(
        checkpoint()..fetchedSequence = 4,
      );
      expect(() => snapshot.requireUnchanged(store), throwsStateError);
      expect(
        CloudSyncChatIdentityReadSet.capture(store, scope).retainedSaves.length,
        2,
      );
    },
  );
  test('rejects retained identities from a previous generation', () {
    store.box<CloudSyncCheckpointEntity>().put(checkpoint()..generation = 2);
    final current = store.box<CloudInboxChangeEntity>().getAll();
    for (final r in current) {
      r.generation = 2;
    }
    store.box<CloudInboxChangeEntity>().putMany(current);
    final previous = row(10);
    store.box<CloudInboxChangeEntity>().put(previous);
    expect(
      () => CloudSyncChatIdentityReadSet.capture(store, scope),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          'cloud_sync_chat_identity_prior_generation_unresolved',
        ),
      ),
    );
    store.box<CloudInboxChangeEntity>().put(previous..status = 1);
    expect(CloudSyncChatIdentityReadSet.capture(store, scope).generation, 2);
  });
  test('rejects applied future-generation rows instead of ignoring them', () {
    store.box<CloudInboxChangeEntity>().put(row(10, status: 1)..generation = 2);
    expect(
      () => CloudSyncChatIdentityReadSet.capture(store, scope),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          'cloud_sync_chat_identity_journal_incomplete',
        ),
      ),
    );
  });
  test('requires a fresh observation after reopening the store', () async {
    final snapshot = CloudSyncChatIdentityReadSet.capture(store, scope);
    store.close();
    store = await openStore(directory: directory.path);
    expect(() => snapshot.requireUnchanged(store), throwsStateError);
    final fresh = CloudSyncChatIdentityReadSet.capture(store, scope);
    expect(fresh.fenceSha256, snapshot.fenceSha256);
    fresh.requireUnchanged(store);
  });
  test('rejects excessive journal rows before returning an incomplete set', () {
    store.box<CloudInboxChangeEntity>().putMany([
      for (
        var i = 4;
        i <= CloudSyncChatIdentityReadSet.maximumJournalRows + 1;
        i++
      )
        row(i),
    ]);
    store.box<CloudSyncCheckpointEntity>().put(
      checkpoint()
        ..fetchedSequence = CloudSyncChatIdentityReadSet.maximumJournalRows + 1,
    );
    expect(
      () => CloudSyncChatIdentityReadSet.capture(store, scope),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          'cloud_sync_chat_identity_journal_limit',
        ),
      ),
    );
  });
}
