import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_message_dependency.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

const _reactionGuid = 'EA6165FC-EFF7-40A7-8F11-C0D3D397597B';
const _parentGuid = 'B3E7A1C4-9D2F-4B6E-8A1C-5F0E9D2C7B3A';
const _otherParentGuid = 'C4D8B2E5-1A3F-4C7D-9B2E-6A1F8C3D5E7B';
const _recipient = 'recipient@example.invalid';
const _sender = 'mailto:sender@example.invalid';
const _logical = 'LrLrLrLrLrLrLrLrLrLrLrLrLrLrLrLrLrLrLrLrLrL';
const _record = 'MrMrMrMrMrMrMrMrMrMrMrMrMrMrMrMrMrMrMrMrMrM';
const _etag = 'ErErErErErErErErErErErErErErErErErErErErErE';
final _now = DateTime.utc(2026, 9, 7);

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async => f.close());

  test('reaction dependency is opaque, ready, and survives restart', () async {
    final binding = f.capture();
    final decoded = jsonDecode(binding) as List;
    expect(decoded[0], 2);
    expect(decoded[1], f.chatBinding);
    expect(decoded[2], isA<List>());
    expect(binding, isNot(contains(_reactionGuid)));
    expect(binding, isNot(contains(_parentGuid)));
    expect(binding, isNot(contains(_recipient)));
    expect(binding, isNot(contains(f.parent.text!)));
    expect(() => f.validate(binding), returnsNormally);

    await f.reopen();
    expect(() => f.validate(binding), returnsNormally);
  });

  test('plaintext keeps the exact v1 chat binding and validator', () {
    final plaintext = Message(
      guid: '11111111-1111-4111-8111-111111111111',
      text: 'synthetic plaintext',
      attributedBody: [AttributedBody.raw('synthetic plaintext')],
      isFromMe: true,
      dateCreated: _now,
    )..chat.target = f.chat;
    f.db.box<Message>().put(plaintext);
    final old = requireCloudSyncRestoredDirectChat(
      store: f.db,
      messageScope: f.messageScope,
      message: plaintext,
    );
    final wrapped = requireCloudSyncLocalSendDependencies(
      store: f.db,
      messageScope: f.messageScope,
      message: plaintext,
    );
    expect(wrapped, old);
    expect(jsonDecode(wrapped)[0], 1);
    expect(
      () => requireCloudSyncAdoptedLocalSendDependencies(
        store: f.db,
        messageScope: f.messageScope,
        binding: wrapped,
        expectedChatId: f.chat.id,
      ),
      returnsNormally,
    );
  });

  test(
    'mutation predecessor binds the local target to one current raw record',
    () async {
      f.db.box<Message>().put(f.parent..isFromMe = true);
      CloudSyncMessageMutationPredecessor resolve() =>
          requireCloudSyncMessageMutationPredecessor(
            store: f.db,
            messageScope: f.messageScope,
            localMessageId: f.parentId,
            localChatId: f.chatId,
            targetGuidHash: sha256
                .convert(
                  utf8.encode(
                    jsonEncode(<Object?>[
                      'cloud-sync-local-send-guid-v1',
                      _parentGuid,
                    ]),
                  ),
                )
                .toString(),
          );

      final first = resolve();
      expect(first.localMessageId, f.parentId);
      expect(first.generation, f.messageCheckpoint.generation);
      expect(first.recordMapping.logicalEntityKeyHash, _logical);
      expect(first.recordMapping.serverRecordIdHash, _record);
      expect(first.recordMapping.etagHash, _etag);
      expect(
        first.recordMapping.rawRecordGeneration,
        f.messageCheckpoint.generation,
      );
      expect(first.toString(), isNot(contains(_parentGuid)));

      await f.reopen();
      final reopened = resolve();
      expect(
        reopened.recordMapping.sameDurableSnapshotAs(first.recordMapping),
        isTrue,
      );
    },
  );

  test('mutation predecessor rejects drift and unfinished readback', () {
    f.db.box<Message>().put(f.parent..isFromMe = true);
    CloudSyncMessageMutationPredecessor resolve({String? targetGuidHash}) =>
        requireCloudSyncMessageMutationPredecessor(
          store: f.db,
          messageScope: f.messageScope,
          localMessageId: f.parentId,
          localChatId: f.chatId,
          targetGuidHash:
              targetGuidHash ??
              sha256
                  .convert(
                    utf8.encode(
                      jsonEncode(<Object?>[
                        'cloud-sync-local-send-guid-v1',
                        _parentGuid,
                      ]),
                    ),
                  )
                  .toString(),
        );

    expect(() => resolve(targetGuidHash: 'f' * 64), _blocked);
    final mapping = f.mapping
      ..protectedReadbackLeaseReference = 'obcs2.lease.${'a' * 32}'
      ..pendingUpdateOperationId = 'op1:${'b' * 64}'
      ..pendingUpdatePredecessorEtagHash = _etag;
    f.db.box<CloudRecordMapEntity>().put(mapping);
    expect(resolve, _blocked);
  });

  test('partial association fields cannot fall through to plaintext', () {
    final malformed = Message(
      guid: '11111111-1111-4111-8111-111111111111',
      text: 'not a reaction',
      attributedBody: [AttributedBody.raw('not a reaction')],
      isFromMe: true,
      dateCreated: _now,
      associatedMessageType: 'love',
    )..chat.target = f.chat;
    f.db.box<Message>().put(malformed);
    expect(
      () => requireCloudSyncLocalSendDependencies(
        store: f.db,
        messageScope: f.messageScope,
        message: malformed,
      ),
      _blocked,
    );
  });

  test('attachment wrapper requires the child proof as well as the original Chat', () {
    final proof = jsonEncode([1, 'synthetic-child-readback']);
    final binding = jsonEncode([4, f.chatBinding, proof]);
    var verified = 0;
    void validate(String candidate, {void Function(String)? reader}) =>
        requireCloudSyncAdoptedLocalSendDependencies(
          store: f.db, messageScope: f.messageScope, binding: candidate,
          expectedChatId: f.chat.id, requireAttachmentReadback: reader);
    expect(() => validate(binding), _blocked);
    validate(binding, reader: (captured) {
      expect(captured, proof);
      verified++;
    });
    expect(verified, 1);
    expect(() => validate(binding, reader: (_) {
      throw StateError('changed-child');
    }), throwsStateError);
    expect(() => validate(jsonEncode([4, '[]', proof]), reader: (_) {}), _blocked);
    expect(() => validate(jsonEncode([4, binding, proof]), reader: (_) {}), _blocked);
    expect(() => validate(jsonEncode([4, f.capture(), proof]), reader: (_) {}), _blocked);
  });

  test('attachment wrapper retains Chat generation checks after restart', () async {
    final binding = jsonEncode([4, f.chatBinding, 'synthetic-proof']);
    await f.reopen();
    void validate() => requireCloudSyncAdoptedLocalSendDependencies(
      store: f.db, messageScope: f.messageScope, binding: binding,
      expectedChatId: f.chat.id, requireAttachmentReadback: (_) {});
    expect(validate, returnsNormally);
    final rows = f.db.box<CloudSyncCheckpointEntity>().getAll();
    for (final row in rows) { row.generation++; }
    f.db.box<CloudSyncCheckpointEntity>().putMany(rows);
    expect(validate, _blocked);
  });

  test('missing parent Message is not restored-parent proof', () {
    final binding = f.capture();
    f.db.box<Message>().remove(f.parent.id!);
    expect(() => f.validate(binding), _blocked);
    expect(f.capture, _blocked);
  });

  test('parent Message in another Chat is rejected', () {
    final binding = f.capture();
    final foreign = Chat(
      guid: 'iMessage;-;foreign@example.invalid',
      chatIdentifier: 'foreign@example.invalid',
      usingHandle: _sender,
      style: 45,
    );
    f.db.box<Chat>().put(foreign);
    f.db.box<Message>().put(f.parent..chat.target = foreign);
    expect(() => f.validate(binding), _blocked);
    expect(f.capture, _blocked);
  });

  test('reparented reaction cannot reuse the restored parent', () {
    final binding = f.capture();
    f.db.box<Message>().put(
      Message(
        guid: _otherParentGuid,
        text: 'different synthetic parent',
        isFromMe: false,
        dateCreated: _now,
      )..chat.target = f.chat,
    );
    f.db.box<Message>().put(
      f.reaction..associatedMessageGuid = _otherParentGuid,
    );
    expect(f.capture, _blocked);
    // Adopted validation pins the original parent. The send journal separately
    // revalidates the reaction identity before it can use this binding.
    expect(() => f.validate(binding), returnsNormally);
  });

  for (final mutation in ['wrong kind', 'wrong canonical hash']) {
    test('$mutation cannot claim parent ownership', () {
      final snapshot = f.snapshot;
      if (mutation == 'wrong kind') {
        snapshot.entityKind = CloudEntityKind.reaction.name;
      } else {
        snapshot.canonicalGuidHash = 'f' * 64;
      }
      f.db.box<CloudSemanticSnapshotEntity>().put(snapshot);
      expect(f.capture, _blocked);
    });
  }

  test('foreign-scope RecordMap cannot prove the parent', () {
    final binding = f.capture();
    f.db.box<CloudRecordMapEntity>().put(
      f.mapping..accountFingerprint = 'Z' * 43,
    );
    expect(() => f.validate(binding), _blocked);
  });

  test('latest retained update blocks earlier applied proof', () {
    final binding = f.capture();
    f.appendSource(status: CloudInboxStatus.retainedUnprojected);
    expect(() => f.validate(binding), _blocked);
  });

  test('latest tombstone blocks earlier applied proof', () {
    final binding = f.capture();
    f.appendSource(status: CloudInboxStatus.applied, deleted: true);
    expect(() => f.validate(binding), _blocked);
  });

  test('fully applied ETag update to the pinned record remains valid', () {
    final binding = f.capture();
    final mapping = f.mapping
      ..etagHash = 'UrUrUrUrUrUrUrUrUrUrUrUrUrUrUrUrUrUrUrUrUrU';
    f.db.box<CloudRecordMapEntity>().put(mapping);
    f.db.box<CloudSemanticSnapshotEntity>().put(
      f.snapshot..etagHash = mapping.etagHash,
    );
    f.appendSource(mapping: mapping);
    expect(() => f.validate(binding), returnsNormally);
  });

  test('checkpoint generation change invalidates the frozen generation', () {
    final binding = f.capture();
    final checkpoint = f.messageCheckpoint;
    f.db.box<CloudSyncCheckpointEntity>().put(checkpoint..generation = 2);
    expect(() => f.validate(binding), _blocked);
  });

  test('new canonical server member cannot retarget an adopted binding', () {
    final binding = f.capture();
    final mapping = f.mapping
      ..serverRecordIdHash = 'NrNrNrNrNrNrNrNrNrNrNrNrNrNrNrNrNrNrNrNrNrN'
      ..etagHash = 'VrVrVrVrVrVrVrVrVrVrVrVrVrVrVrVrVrVrVrVrVrV'
      ..encryptedServerRecordId = 'obcs2.ref.${'N' * 43}'
      ..encryptedRawRecordRef = 'obcs2.ref.${'V' * 43}';
    f.db.box<CloudRecordMapEntity>().put(mapping);
    f.db.box<CloudSemanticSnapshotEntity>().put(
      f.snapshot..etagHash = mapping.etagHash,
    );
    f.appendSource(mapping: mapping);
    expect(() => f.validate(binding), _blocked);
    expect(f.capture(), isNot(binding));
  });
}

final _blocked = throwsA(isA<CloudSyncFailure>());

final class _Fixture {
  _Fixture(this.directory, this.db) {
    _bindStore();
  }

  final Directory directory;
  Store db;
  late ObjectBoxCloudSyncStore sync;
  late int chatId;
  late int parentId;
  late int reactionId;
  late String chatBinding;

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
  Message get parent => db.box<Message>().get(parentId)!;
  Message get reaction => db.box<Message>().get(reactionId)!;
  CloudSyncCheckpointEntity get messageCheckpoint => db
      .box<CloudSyncCheckpointEntity>()
      .getAll()
      .singleWhere((row) => row.zone == messageScope.zone);
  CloudSemanticSnapshotEntity get snapshot => db
      .box<CloudSemanticSnapshotEntity>()
      .getAll()
      .singleWhere((row) => row.zone == messageScope.zone);
  CloudRecordMapEntity get mapping => db
      .box<CloudRecordMapEntity>()
      .getAll()
      .singleWhere((row) => row.zone == messageScope.zone);

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'outbound-message-dependency-',
    );
    final f = _Fixture(directory, await openStore(directory: directory.path));
    final handle = Handle(
      address: _recipient,
      service: 'iMessage',
      uniqueAddressAndService: '$_recipient/iMessage',
    );
    f.db.box<Handle>().put(handle);
    final chat = Chat(
      guid: 'iMessage;-;$_recipient',
      chatIdentifier: _recipient,
      usingHandle: _sender,
      style: 45,
    )..handles.add(handle);
    f.chatId = f.db.box<Chat>().put(chat);
    final parent = Message(
      guid: _parentGuid,
      text: 'synthetic restored parent',
      isFromMe: false,
      dateCreated: _now.subtract(const Duration(minutes: 1)),
    )..chat.target = chat;
    f.parentId = f.db.box<Message>().put(parent);
    final reaction = Message(
      guid: _reactionGuid,
      isFromMe: true,
      dateCreated: _now,
      associatedMessageGuid: _parentGuid,
      associatedMessagePart: 0,
      associatedMessageType: 'love',
    )..chat.target = chat;
    f.reactionId = f.db.box<Message>().put(reaction);

    final chatSource = await seedSyntheticRestoredChatAppliedSource(
      objectBox: f.db,
      store: f.sync,
      chatScope: f.chatScope,
      now: _now,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: f.db,
      store: f.sync,
      chatScope: f.chatScope,
      chat: chat,
      appliedSource: chatSource,
      now: _now,
    );
    await f.sync.readCheckpoint(f.messageScope);
    f.seedParentProof();
    f.chatBinding = requireCloudSyncRestoredDirectChat(
      store: f.db,
      messageScope: f.messageScope,
      message: f.reaction,
    );
    return f;
  }

  void _bindStore() {
    sync = ObjectBoxCloudSyncStore(
      store: db,
      protector: _Protector(),
      clock: () => _now,
    );
  }

  void seedParentProof() {
    final scopeKey = cloudSyncPersistentScopeKey(messageScope);
    final checkpoint = messageCheckpoint
      ..fetchedSequence = 1
      ..appliedSequence = 1
      ..lastSuccessfulAtMs = _now.millisecondsSinceEpoch;
    db.box<CloudSyncCheckpointEntity>().put(checkpoint);
    final generationKey =
        'semantic-generation4:${_digest('$scopeKey\u001f${checkpoint.generation}')}';
    final lookup = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
      scope: messageScope,
      generation: checkpoint.generation,
      canonicalGuid: _parentGuid,
    );
    final canonicalHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
      scope: messageScope,
      generation: checkpoint.generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: _logical,
      canonicalGuid: _parentGuid,
    );
    db.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(messageScope, _logical),
        scopeKey: scopeKey,
        accountFingerprint: messageScope.accountFingerprint,
        zone: messageScope.zone,
        logicalEntityKeyHash: _logical,
        serverRecordIdHash: _record,
        generation: checkpoint.generation,
        encryptedServerRecordId: 'obcs2.ref.${'R' * 43}',
        etagHash: _etag,
        encryptedRawRecordRef: 'obcs2.ref.${'P' * 43}',
        rawRecordGeneration: checkpoint.generation,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    db.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey: 'semantic-snapshot4:$generationKey:message:$_logical',
        scopeGenerationKey: generationKey,
        scopeKey: scopeKey,
        accountFingerprint: messageScope.accountFingerprint,
        container: messageScope.container,
        database: messageScope.database,
        zone: messageScope.zone,
        streamKind: messageScope.streamKind.name,
        schemaVersion: messageScope.schemaVersion,
        generation: checkpoint.generation,
        entityKind: CloudEntityKind.message.name,
        logicalEntityKeyHash: _logical,
        canonicalGuidHash: canonicalHash,
        canonicalGuidLookupHash: lookup,
        etagHash: _etag,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    appendSource();
  }

  void appendSource({
    CloudRecordMapEntity? mapping,
    CloudInboxStatus status = CloudInboxStatus.applied,
    bool deleted = false,
  }) {
    final selected = mapping ?? this.mapping;
    final sources = db.box<CloudInboxChangeEntity>().getAll().where(
      (row) => row.scopeKey == cloudSyncPersistentScopeKey(messageScope),
    );
    final sequence =
        sources.fold<int>(
          0,
          (value, row) => row.fetchSequence > value ? row.fetchSequence : value,
        ) +
        1;
    db.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: 'synthetic-parent-change-$sequence',
        changeIdHash: 'CrCrCrCrCrCrCrCrCrCrCrCrCrCrCrCrCrCrCrCrCrC',
        scopeKey: cloudSyncPersistentScopeKey(messageScope),
        accountFingerprint: messageScope.accountFingerprint,
        zone: messageScope.zone,
        serverRecordIdHash: selected.serverRecordIdHash,
        etagHash: selected.etagHash,
        changeType: deleted
            ? CloudChangeType.delete.name
            : CloudChangeType.save.name,
        encryptedServerRecordId: selected.encryptedServerRecordId,
        encryptedPayloadRef: deleted ? null : selected.encryptedRawRecordRef,
        protectedSystemFieldsRef: 'obcs2.ref.${'F' * 43}',
        payloadSha256: deleted ? null : 'a' * 64,
        batchId: 'synthetic-parent-batch-$sequence',
        generation: messageCheckpoint.generation,
        fetchSequence: sequence,
        status: status.index,
        isTombstone: deleted,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
        completedAtMs: status == CloudInboxStatus.applied
            ? _now.millisecondsSinceEpoch
            : 0,
      ),
    );
  }

  String capture() => db.runInTransaction(
    TxMode.read,
    () => requireCloudSyncLocalSendDependencies(
      store: db,
      messageScope: messageScope,
      message: reaction,
    ),
  );

  void validate(String binding) => db.runInTransaction(TxMode.read, () {
    requireCloudSyncAdoptedLocalSendDependencies(
      store: db,
      messageScope: messageScope,
      binding: binding,
      expectedChatId: reaction.chat.targetId,
    );
  });

  Future<void> reopen() async {
    db.close();
    db = await openStore(directory: directory.path);
    _bindStore();
  }

  Future<void> close() async {
    if (!db.isClosed()) db.close();
    await directory.delete(recursive: true);
  }
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

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
