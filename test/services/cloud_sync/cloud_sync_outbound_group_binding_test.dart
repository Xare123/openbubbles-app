import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_message_dependency.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

final _now = DateTime.utc(2026, 9, 7);
final _blocked = throwsA(isA<CloudSyncFailure>());

void main() {
  late _Fixture fixture;
  setUp(() async => fixture = await _Fixture.create());
  tearDown(() async => fixture.close());

  test('protected group dependency is opaque and survives restart', () async {
    final binding = fixture.capture();
    final decoded = jsonDecode(binding) as List;
    expect(decoded[0], 3);
    expect(decoded, hasLength(11));
    expect(binding, isNot(contains('restored-group')));
    expect(binding, isNot(contains('opaque-apple-group-id')));
    expect(binding, isNot(contains('member-a@example.invalid')));
    expect(() => fixture.validate(binding), returnsNormally);

    await fixture.reopen();
    expect(() => fixture.validate(binding), returnsNormally);
  });

  test('normal dependency selector chooses the group binding', () {
    final binding = requireCloudSyncLocalSendDependencies(
      store: fixture.db,
      messageScope: fixture.messageScope,
      message: fixture.message,
    );
    expect(jsonDecode(binding)[0], 3);
    expect(binding, fixture.capture());
  });

  test('same-version member drift invalidates an adopted dependency', () {
    final binding = fixture.capture();
    final member = fixture.chat.handles.first
      ..address = 'changed@example.invalid';
    fixture.db.box<Handle>().put(member);
    expect(() => fixture.validate(binding), _blocked);
    expect(fixture.capture, _blocked);
  });

  test('raw group retarget invalidates an adopted dependency', () {
    final binding = fixture.capture();
    fixture.db.box<Chat>().put(
      fixture.chat..cloudGuid = 'different-opaque-group-id',
    );
    expect(() => fixture.validate(binding), _blocked);
    expect(fixture.capture, _blocked);
  });

  test('local group version drift invalidates an adopted dependency', () {
    final binding = fixture.capture();
    fixture.db.box<Chat>().put(fixture.chat..groupVersion = 10);
    expect(() => fixture.validate(binding), _blocked);
    expect(fixture.capture, _blocked);
  });

  test('missing protected digest or group alias fails closed', () {
    var binding = fixture.capture();
    final expectedDigest = fixture.expectedDigest;
    final snapshot = fixture.snapshot..groupMetadataDigest = null;
    fixture.db.box<CloudSemanticSnapshotEntity>().put(snapshot);
    expect(() => fixture.validate(binding), _blocked);
    expect(fixture.capture, _blocked);

    snapshot.groupMetadataDigest = expectedDigest;
    fixture.db.box<CloudSemanticSnapshotEntity>().put(snapshot);
    binding = fixture.capture();
    fixture.db.box<CloudSemanticChatAliasEntity>().remove(
      fixture.groupAlias.id,
    );
    expect(() => fixture.validate(binding), _blocked);
    expect(fixture.capture, _blocked);
  });

 test('retained update and tombstone cannot reuse applied proof', () {
   final binding = fixture.capture();
   final inbox = fixture.inbox;
   inbox.status = CloudInboxStatus.retainedUnprojected.index;
   fixture.db.box<CloudInboxChangeEntity>().put(inbox);
   expect(() => fixture.validate(binding), _blocked);

   inbox
     ..status = CloudInboxStatus.applied.index
     ..isTombstone = true
     ..changeType = CloudChangeType.delete.name;
   fixture.db.box<CloudInboxChangeEntity>().put(inbox);
   expect(() => fixture.validate(binding), _blocked);
  });

  test('pinned proof captures exact source, generation, and routing digest',
      () {
    final binding = fixture.capture();
    final proof = fixture.proof();
    final decoded = jsonDecode(binding) as List;
    expect(proof.binding, binding);
    expect(proof.generation, decoded[2]);
    expect(proof.routingMetadataDigest, decoded[10]);
    expect(proof.routingMetadataDigest, fixture.expectedDigest);
    final inbox = fixture.inbox;
    expect(proof.source.changeIdHash, inbox.changeIdHash);
    expect(proof.source.recordIdHash, inbox.serverRecordIdHash);
    expect(proof.source.etagHash, inbox.etagHash);
    expect(proof.source.payloadSha256, inbox.payloadSha256);
    expect(proof.source.payloadLength, isNull);
    expect(
      proof.source.serverModifiedAtMillis,
      inbox.serverModifiedAtMs <= 0 ? null : inbox.serverModifiedAtMs,
    );
    expect(
      proof.source.protectedRawEnvelopeReference,
      inbox.encryptedPayloadRef,
    );
  });

  test('tombstoned latest row rejects the pinned proof', () {
    final binding = fixture.capture();
    final inbox = fixture.inbox;
    inbox
      ..status = CloudInboxStatus.applied.index
      ..isTombstone = true
      ..changeType = CloudChangeType.delete.name;
    fixture.db.box<CloudInboxChangeEntity>().put(inbox);
    expect(() => fixture.proof(), _blocked);
    expect(fixture.capture, _blocked);
    expect(() => fixture.validate(binding), _blocked);
  });

  test('newer unapplied row rejects the pinned proof; unrelated rows do not',
      () {
    final baseline = fixture.capture();
    final inbox = fixture.inbox;
    final box = fixture.db.box<CloudInboxChangeEntity>();
    final unrelated = CloudInboxChangeEntity(
      changeKey: '${inbox.changeKey}-unrelated',
      changeIdHash: inbox.changeIdHash,
      scopeKey: inbox.scopeKey,
      accountFingerprint: inbox.accountFingerprint,
      zone: inbox.zone,
      serverRecordIdHash: 'Z' * 43,
      changeType: CloudChangeType.save.name,
      batchId: 'unrelated-batch',
      generation: inbox.generation,
      fetchSequence: inbox.fetchSequence + 1,
      createdAtMs: inbox.createdAtMs,
      updatedAtMs: inbox.updatedAtMs,
    );
    box.put(unrelated);
    expect(fixture.proof().binding, baseline);
    final newer = CloudInboxChangeEntity(
      changeKey: '${inbox.changeKey}-newer',
      changeIdHash: inbox.changeIdHash,
      scopeKey: inbox.scopeKey,
      accountFingerprint: inbox.accountFingerprint,
      zone: inbox.zone,
      serverRecordIdHash: inbox.serverRecordIdHash,
      etagHash: inbox.etagHash,
      changeType: CloudChangeType.save.name,
      encryptedServerRecordId: inbox.encryptedServerRecordId,
      encryptedPayloadRef: inbox.encryptedPayloadRef,
      payloadSha256: inbox.payloadSha256,
      batchId: 'newer-batch',
      generation: inbox.generation,
      fetchSequence: inbox.fetchSequence + 1,
      createdAtMs: inbox.createdAtMs,
      updatedAtMs: inbox.updatedAtMs,
    );
    box.put(newer);
    expect(() => fixture.proof(), _blocked);
    expect(fixture.capture, _blocked);
    box.remove(newer.id);
    expect(fixture.proof().binding, baseline);
    box.remove(unrelated.id);
  });

  test('group route drift rejects the pinned proof', () {
    final binding = fixture.capture();
    fixture.db.box<Chat>().put(fixture.chat..groupVersion = 10);
    expect(() => fixture.proof(), _blocked);
    expect(fixture.capture, _blocked);
    expect(() => fixture.validate(binding), _blocked);
  });

  test('adopted proof opens the retained binding without the Message', () {
    final binding = fixture.capture();
    final fresh = fixture.proof();
    fixture.db.box<Message>().remove(fixture.messageId);
    final opened = fixture.adoptedProof(binding);
    expect(opened.binding, binding);
    expect(opened.generation, fresh.generation);
    expect(opened.routingMetadataDigest, fresh.routingMetadataDigest);
    expect(opened.source, fresh.source);
    expect(
      () => fixture.adoptedProof(binding, expectedChatId: -1),
      _blocked,
    );
    expect(() => fixture.validate(binding), returnsNormally);
  });

  test('adopted proof rejects row drift', () {
    final binding = fixture.capture();
    final inbox = fixture.inbox;
    inbox
      ..status = CloudInboxStatus.applied.index
      ..isTombstone = true
      ..changeType = CloudChangeType.delete.name;
    fixture.db.box<CloudInboxChangeEntity>().put(inbox);
    expect(() => fixture.adoptedProof(binding), _blocked);
    expect(() => fixture.validate(binding), _blocked);
  });
}

final class _Fixture {
  _Fixture(this.directory, this.db) {
    _bindStore();
  }

  final Directory directory;
  Store db;
  late ObjectBoxCloudSyncStore sync;
  late int chatId;
  late int messageId;

  CloudSyncScope scope(String zone) => CloudSyncScope(
    accountFingerprint: 'A' * 43,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: zone,
    streamKind: CloudSyncStreamKind.messages,
    schemaVersion: cloudSyncSchemaVersion,
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  CloudSyncScope get messageScope => scope('messageManateeZone');
  CloudSyncScope get chatScope => scope('chatManateeZone');
  Chat get chat => db.box<Chat>().get(chatId)!;
  Message get message => db.box<Message>().get(messageId)!;
  CloudSemanticSnapshotEntity get snapshot => db
      .box<CloudSemanticSnapshotEntity>()
      .getAll()
      .singleWhere((row) => row.zone == chatScope.zone);
  CloudSemanticChatAliasEntity get groupAlias =>
      db.box<CloudSemanticChatAliasEntity>().getAll().singleWhere(
        (row) => row.aliasKind == CloudSemanticChatAliasKind.groupId.name,
      );
  CloudInboxChangeEntity get inbox => db
      .box<CloudInboxChangeEntity>()
      .getAll()
      .singleWhere((row) => row.zone == chatScope.zone);
  String get expectedDigest => snapshot.groupMetadataDigest!;

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'outbound-group-dependency-',
    );
    final fixture = _Fixture(
      directory,
      await openStore(directory: directory.path),
    );
    final first = Handle(
      address: 'member-a@example.invalid',
      service: 'iMessage',
      uniqueAddressAndService: 'member-a@example.invalid/iMessage',
    );
    final second = Handle(
      address: '+15555550101',
      service: 'iMessage',
      uniqueAddressAndService: '+15555550101/iMessage',
    );
    fixture.db.box<Handle>().putMany([first, second]);
    final chat =
        Chat(
            guid: 'iMessage;+;restored-group',
            chatIdentifier: 'restored-group',
            usingHandle: 'mailto:sender@example.invalid',
            style: 43,
          )
          ..cloudGuid = 'opaque-apple-group-id'
          ..groupVersion = 9;
    chat.handles.addAll([first, second]);
    fixture.chatId = fixture.db.box<Chat>().put(chat);
    final message = Message(
      guid: '11111111-1111-4111-8111-111111111111',
      text: 'synthetic group text',
      attributedBody: [AttributedBody.raw('synthetic group text')],
      isFromMe: true,
      dateCreated: _now,
    )..chat.target = chat;
    fixture.messageId = fixture.db.box<Message>().put(message);
    final source = await seedSyntheticRestoredChatAppliedSource(
      objectBox: fixture.db,
      store: fixture.sync,
      chatScope: fixture.chatScope,
      now: _now,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: fixture.db,
      store: fixture.sync,
      chatScope: fixture.chatScope,
      chat: chat,
      appliedSource: source,
      now: _now,
    );
    return fixture;
  }

  String capture() => requireCloudSyncRestoredGroupChat(
    store: db,
    messageScope: messageScope,
    message: message,
  );

  CloudSyncRestoredGroupChatProof proof() =>
      requireCloudSyncRestoredGroupChatProof(
        store: db,
        messageScope: messageScope,
        message: message,
      );

  CloudSyncRestoredGroupChatProof adoptedProof(
    String binding, {
    int? expectedChatId,
  }) =>
      requireCloudSyncAdoptedGroupChatProof(
        store: db,
        messageScope: messageScope,
        binding: binding,
        expectedChatId: expectedChatId ?? chatId,
      );

  void validate(String binding) => requireCloudSyncAdoptedGroupChatDependency(
    store: db,
    messageScope: messageScope,
    binding: binding,
    expectedChatId: chatId,
  );

  void _bindStore() {
    sync = ObjectBoxCloudSyncStore(
      store: db,
      protector: _Protector(),
      clock: () => _now,
    );
  }

  Future<void> reopen() async {
    db.close();
    db = await openStore(directory: directory.path);
    _bindStore();
  }

  Future<void> close() async {
    if (!db.isClosed()) db.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

final class _Protector implements CloudSyncProtector {
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'test:$plaintext';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext.substring(5);

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      'A' * 43;
}
