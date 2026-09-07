import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

const _guid = '11111111-1111-4111-8111-111111111111';
const _recipient = 'recipient@example.invalid';
const _sender = 'sender@example.invalid';
const _body = 'synthetic pinned chat member';
final _now = DateTime.utc(2026, 9, 6);
final _recordB = 'B' * 43;
final _etagB = 'E' * 43;

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async => f.close());

  for (final reopen in [false, true]) {
    test('A stays pinned, new admission selects B (reopen=$reopen)', () async {
      final admitted = f.intent;
      final bindingA = admitted.admittedChatBinding!;
      final mapA = f.canonical;
      expect(f.capture(), bindingA);
      expect(jsonDecode(bindingA)[7], mapA.serverRecordIdHash);

      f.joinB();
      if (reopen) await f.reopen();

      expect(() => f.validate(bindingA), returnsNormally);
      final bindingB = f.capture();
      final decodedA = jsonDecode(bindingA) as List;
      final decodedB = jsonDecode(bindingB) as List;
      expect(decodedB[7], _recordB);
      expect(decodedB.take(7), orderedEquals(decodedA.take(7)));
      expect(decodedB[8], decodedA[8]);
      expect(() => f.validate(bindingB), returnsNormally);
      // Exercise the public journal recovery path, not just the binding helper.
      final recovered = f.readIntent();
      expect(recovered.state, 2);
      expect(recovered.admittedChatBinding, bindingA);
      expect(recovered.admittedOperationId, admitted.admittedOperationId);
      expect(f.intent.admittedBindingSha256, admitted.admittedBindingSha256);
      expect(f.memberA.etagHash, mapA.etagHash);
      expect(f.memberA.encryptedServerRecordId, mapA.encryptedServerRecordId);
      expect(f.memberA.encryptedRawRecordRef, mapA.encryptedRawRecordRef);
      f.expectUnchangedLocalState();
    });
  }

  test('fully applied newer A revision is valid without matching B ETag', () {
    f.joinB();
    final mapping = f.memberA..etagHash = 'U' * 43;
    f.db.box<CloudRecordMapEntity>().put(mapping);
    f.appendSource(mapping);
    expect(f.snapshot.etagHash, _etagB);
    expect(() => f.validate(f.bindingA), returnsNormally);
    expect(f.readIntent().admittedChatBinding, f.bindingA);
  });

  for (final status in [
    CloudInboxStatus.pending,
    CloudInboxStatus.quarantined,
    CloudInboxStatus.retainedUnprojected,
  ]) {
    test(
      'latest ${status.name} A revision cannot reuse earlier applied proof',
      () {
        f.joinB();
        // Keep the ETag identical so the latest-status check is indispensable.
        f.appendSource(f.memberA, status: status);
        expect(() => f.validate(f.bindingA), throwsA(isA<CloudSyncFailure>()));
        expect(f.readIntent, throwsA(isA<CloudSyncFailure>()));
        expect(jsonDecode(f.capture())[7], _recordB);
        f.expectUnchangedLocalState();
      },
    );
  }

  for (final status in [
    CloudInboxStatus.applied,
    CloudInboxStatus.retainedUnprojected,
  ]) {
    test('A deletion never retargets its binding to B (${status.name})', () {
      f.joinB();
      f.appendSource(f.memberA, status: status, deleted: true);
      expect(() => f.validate(f.bindingA), throwsA(isA<CloudSyncFailure>()));
      expect(f.readIntent, throwsA(isA<CloudSyncFailure>()));
      expect(jsonDecode(f.capture())[7], _recordB);
      expect(f.intent.admittedChatBinding, f.bindingA);
      f.expectUnchangedLocalState();
    });
  }

  test('applied inbox ETag must still match the exact member', () {
    f.joinB();
    f.appendSource(f.memberA..etagHash = 'U' * 43);
    expect(() => f.validate(f.bindingA), throwsA(isA<CloudSyncFailure>()));
    expect(f.readIntent, throwsA(isA<CloudSyncFailure>()));
  });

  for (final pointer in ['server record', 'payload']) {
    test('same ETag cannot mask a mismatching $pointer pointer', () {
      f.joinB();
      final mapping = f.memberA;
      f.appendSource(mapping);
      final revisions =
          f.db
              .box<CloudInboxChangeEntity>()
              .getAll()
              .where(
                (row) => row.serverRecordIdHash == mapping.serverRecordIdHash,
              )
              .toList()
            ..sort(
              (left, right) =>
                  left.fetchSequence.compareTo(right.fetchSequence),
            );
      final latest = revisions.last;
      if (pointer == 'server record') {
        latest.encryptedServerRecordId = 'obcs2.ref.${'X' * 43}';
      } else {
        latest.encryptedPayloadRef = 'obcs2.ref.${'X' * 43}';
      }
      f.db.box<CloudInboxChangeEntity>().put(latest);
      expect(revisions, hasLength(2));
      expect(latest.status, CloudInboxStatus.applied.index);
      expect(latest.etagHash, mapping.etagHash);
      final rejected = throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_local_send_chat_not_ready',
        ),
      );
      expect(() => f.validate(f.bindingA), rejected);
      expect(f.readIntent, rejected);
      expect(jsonDecode(f.capture())[7], _recordB);
      f.expectUnchangedLocalState();
    });
  }

  test('member provenance without an inbox source is not applied proof', () {
    f.joinB();
    final source = f.db.box<CloudInboxChangeEntity>().getAll().singleWhere(
      (row) =>
          row.serverRecordIdHash == syntheticRestoredChatServerRecordIdHash,
    );
    f.db.box<CloudInboxChangeEntity>().remove(source.id);
    expect(() => f.validate(f.bindingA), throwsA(isA<CloudSyncFailure>()));
    expect(f.readIntent, throwsA(isA<CloudSyncFailure>()));
    expect(jsonDecode(f.capture())[7], _recordB);
  });

  for (final mutation in [
    'member owner',
    'member scope',
    'member generation',
    'member missing',
    'canonical owner',
    'snapshot owner',
    'alias owner',
    'alias identity',
    'checkpoint generation',
  ]) {
    test('pinned A rejects $mutation drift', () {
      f.joinB();
      switch (mutation) {
        case 'member owner':
          f.db.box<CloudRecordMapEntity>().put(
            f.memberA..logicalEntityKeyHash = 'X' * 43,
          );
        case 'member scope':
          f.db.box<CloudRecordMapEntity>().put(
            f.memberA..accountFingerprint = 'X' * 43,
          );
        case 'member generation':
          f.db.box<CloudRecordMapEntity>().put(f.memberA..generation = 2);
        case 'member missing':
          f.db.box<CloudRecordMapEntity>().remove(f.memberA.id);
        case 'canonical owner':
          f.db.box<CloudRecordMapEntity>().put(
            f.canonical..logicalEntityKeyHash = 'X' * 43,
          );
        case 'snapshot owner':
          f.db.box<CloudSemanticSnapshotEntity>().put(
            f.snapshot..canonicalGuidHash = 'f' * 64,
          );
        case 'alias owner':
          f.db.box<CloudSemanticChatAliasEntity>().put(
            f.alias..chatLogicalEntityKeyHash = 'X' * 43,
          );
        case 'alias identity':
          final alias = f.alias..aliasKeyHash = 'X' * 43;
          alias.bindingKey =
              'semantic-chat-strong2:${_digest('${f.chatScope.storageKey}\u001f1\u001fiMessage\u001fserviceIdentifier\u001f${alias.aliasKeyHash}')}';
          f.db.box<CloudSemanticChatAliasEntity>().put(alias);
        case 'checkpoint generation':
          final checkpoint = f.db
              .box<CloudSyncCheckpointEntity>()
              .getAll()
              .singleWhere((row) => row.zone == 'chatManateeZone');
          f.db.box<CloudSyncCheckpointEntity>().put(checkpoint..generation = 2);
      }
      expect(() => f.validate(f.bindingA), throwsA(isA<CloudSyncFailure>()));
      expect(f.readIntent, throwsA(isA<CloudSyncFailure>()));
    });
  }

  test(
    'snapshot ETag remains mandatory for the currently canonical source',
    () {
      f.joinB();
      final bindingB = f.capture();
      f.db.box<CloudSemanticSnapshotEntity>().put(
        f.snapshot..etagHash = 'X' * 43,
      );
      expect(f.capture, throwsA(isA<CloudSyncFailure>()));
      expect(() => f.validate(bindingB), throwsA(isA<CloudSyncFailure>()));
      expect(() => f.validate(f.bindingA), returnsNormally);
    },
  );

  test(
    'canonical selection does not fall back to live A when B is retained',
    () {
      f.joinB();
      f.appendSource(f.canonical, status: CloudInboxStatus.retainedUnprojected);
      expect(f.capture, throwsA(isA<CloudSyncFailure>()));
      expect(() => f.validate(f.bindingA), returnsNormally);
    },
  );

  test('journal still requires its original Message to Chat row binding', () {
    f.joinB();
    final replacement = Chat(
      guid: 'iMessage;-;replacement@example.invalid',
      chatIdentifier: 'replacement@example.invalid',
      usingHandle: _sender,
      style: 45,
    );
    f.db.box<Chat>().put(replacement);
    f.db.box<Message>().put(f.message..chat.target = replacement);
    expect(() => f.validate(f.bindingA), returnsNormally);
    expect(f.readIntent, throwsA(isA<CloudSyncFailure>()));
  });

  for (final invalidServer in [null, '', 7, 'not-a-digest']) {
    test(
      'malformed pinned server $invalidServer never becomes canonical lookup',
      () {
        f.joinB();
        final decoded = jsonDecode(f.bindingA) as List;
        decoded[7] = invalidServer;
        expect(
          () => f.validate(jsonEncode(decoded)),
          throwsA(isA<CloudSyncFailure>()),
        );
      },
    );
  }

  test(
    'coherent canonical and member copies do not create logical ambiguity',
    () {
      f.joinB();
      final canonical = f.canonical;
      f.db.box<CloudRecordMapEntity>().put(
        _copyMap(
          canonical,
          mapKey: cloudSyncChatRecordMemberKey(f.chatScope, 1, _recordB),
        ),
      );
      expect(jsonDecode(f.capture())[7], _recordB);
      expect(() => f.validate(f.bindingA), returnsNormally);
      expect(f.readIntent().admittedChatBinding, f.bindingA);
    },
  );
}

final class _Fixture {
  _Fixture(this.directory, this.db);

  final Directory directory;
  Store db;
  late CloudSyncLocalSendJournal journal;
  late ObjectBoxCloudSyncStore sync;
  late int intentId;
  late String sourceHash;
  late String bindingA;
  final writerScope = CloudKitWriterScope(accountFingerprint: 'A' * 43);

  CloudSyncScope scope([String zone = 'messageManateeZone']) => CloudSyncScope(
    accountFingerprint: writerScope.accountFingerprint,
    container: writerScope.container,
    database: writerScope.database,
    zone: zone,
    streamKind: CloudSyncStreamKind.messages,
    schemaVersion: cloudSyncSchemaVersion,
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  CloudSyncScope get chatScope => scope('chatManateeZone');
  CloudSyncLocalSendIntentEntity get intent =>
      db.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;
  Message get message => db.box<Message>().get(intent.localMessageId)!;
  CloudSemanticSnapshotEntity get snapshot =>
      db.box<CloudSemanticSnapshotEntity>().getAll().single;
  CloudSemanticChatAliasEntity get alias =>
      db.box<CloudSemanticChatAliasEntity>().getAll().single;
  CloudRecordMapEntity get canonical =>
      db.box<CloudRecordMapEntity>().getAll().singleWhere(
        (row) =>
            row.mapKey ==
            cloudSyncCanonicalRecordMapKey(
              chatScope,
              snapshot.logicalEntityKeyHash,
            ),
      );
  CloudRecordMapEntity get memberA =>
      db.box<CloudRecordMapEntity>().getAll().singleWhere(
        (row) =>
            row.mapKey ==
            cloudSyncChatRecordMemberKey(
              chatScope,
              1,
              syntheticRestoredChatServerRecordIdHash,
            ),
      );

  String capture() => db.runInTransaction(
    TxMode.read,
    () => requireCloudSyncRestoredDirectChat(
      store: db,
      messageScope: scope(),
      message: message,
    ),
  );
  void validate(String binding) => db.runInTransaction(TxMode.read, () {
    requireCloudSyncAdoptedChatDependency(
      store: db,
      messageScope: scope(),
      binding: binding,
    );
  });
  CloudSyncLocalSendAdmissionSource readIntent() => journal.readExactIntent(
    intentId: intentId,
    expectedRecipient: _recipient,
    expectedSourceSha256: sourceHash,
  );

  void bind() {
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: db,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    if (authority.read(writerScope) == null) {
      final disabled = authority.initializeDisabled(writerScope, now: _now);
      authority.provisionInitialOwner(
        writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: _now,
      );
    }
    journal = CloudSyncLocalSendJournal(
      store: db,
      authority: authority,
      authoritySnapshot: authority.read(writerScope)!,
    );
    sync = ObjectBoxCloudSyncStore(
      store: db,
      protector: _Protector(),
      localSendJournal: journal,
      clock: () => _now,
    );
  }

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'chat-member-binding-',
    );
    final f = _Fixture(directory, await openStore(directory: directory.path))
      ..bind();
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
    f.db.box<Chat>().put(chat);
    final message = Message(
      guid: 'temp-Abc12345',
      stagingGuid: _guid,
      text: _body,
      attributedBody: [AttributedBody.raw(_body)],
      isFromMe: true,
      dateCreated: _now,
    )..chat.target = chat;
    final identity = CloudSyncLocalSendIdentity.capture(message, chat, _guid)!;
    f.sourceHash = identity.sourceSha256;
    f.journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => f.db.box<Message>().put(message),
      now: _now,
    );
    message
      ..guid = _guid
      ..stagingGuid = null;
    f.journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: () => f.db.box<Message>().put(message),
      now: _now,
    );
    f.intentId = f.db.box<CloudSyncLocalSendIntentEntity>().getAll().single.id;
    final applied = await seedSyntheticRestoredChatAppliedSource(
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
      appliedSource: applied,
      now: _now,
    );
    final scope = f.scope();
    final operation = CloudOutboxOperation(
      scope: scope,
      operationId: CloudOperationIdentity.forInitialCreate(
        scope: scope,
        logicalEntityKeyHash: 'L' * 43,
        payloadVersion: cloudSyncOutboundPayloadVersion,
      ),
      logicalEntityKeyHash: 'L' * 43,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncOutboundPayloadVersion,
      mutationRevision: 1,
      checkpointGeneration: 1,
      dependencyOperationIds: const {},
      createdAt: _now,
      encryptedPayloadReference: 'obcs2.ref.${'P' * 43}',
      payloadSha256: 'a' * 64,
      serverRecordIdHash: 'S' * 43,
      protectedLeaseReference: 'obcs2.lease.${'b' * 32}',
    );
    await f.sync.upsertRecordMap(
      CloudRecordMapEntry(
        scope: scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        serverRecordIdHash: operation.serverRecordIdHash!,
        encryptedServerRecordId: operation.encryptedPayloadReference!,
        updatedAt: _now,
      ),
      generation: 1,
    );
    final source = f.journal.readForAdmission(f.intentId);
    // Synthetic journal/outbox adoption boundary only. No native staging,
    // transport, account credentials, or production profile is involved.
    f.db.runInTransaction(TxMode.write, () {
      f.journal.adoptInOutboxTransaction(f.db, source, operation);
      f.db.box<CloudOutboxOperationEntity>().put(
        CloudOutboxOperationEntity(
          operationId: operation.operationId,
          scopeKey: cloudSyncPersistentScopeKey(scope),
          accountFingerprint: scope.accountFingerprint,
          zone: scope.zone,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          action: operation.action.index,
          payloadVersion: operation.payloadVersion,
          mutationRevision: operation.mutationRevision,
          checkpointGeneration: operation.checkpointGeneration,
          encryptedPayloadRef: operation.encryptedPayloadReference,
          payloadSha256: operation.payloadSha256,
          serverRecordIdHash: operation.serverRecordIdHash,
          protectedLeaseReference: operation.protectedLeaseReference,
          createdAtMs: _now.millisecondsSinceEpoch,
          updatedAtMs: _now.millisecondsSinceEpoch,
        ),
      );
    });
    f.bindingA = f.intent.admittedChatBinding!;
    return f;
  }

  void joinB() => db.runInTransaction(TxMode.write, () {
    final previous = canonical;
    db.box<CloudRecordMapEntity>().put(
      _copyMap(
        previous,
        mapKey: cloudSyncChatRecordMemberKey(
          chatScope,
          1,
          previous.serverRecordIdHash,
        ),
      ),
    );
    final next = _copyMap(previous, mapKey: previous.mapKey)
      ..id = previous.id
      ..serverRecordIdHash = _recordB
      ..etagHash = _etagB
      ..encryptedServerRecordId = 'obcs2.ref.${'B' * 43}'
      ..encryptedRawRecordRef = 'obcs2.ref.${'C' * 43}';
    db.box<CloudRecordMapEntity>().put(next);
    db.box<CloudSemanticSnapshotEntity>().put(snapshot..etagHash = _etagB);
    appendSource(next);
  });

  // Direct synthetic rows isolate binding validation from whole-account
  // admission and gateway projection; they never authorize a remote write.
  void appendSource(
    CloudRecordMapEntity mapping, {
    CloudInboxStatus status = CloudInboxStatus.applied,
    bool deleted = false,
  }) {
    final scopeKey = cloudSyncPersistentScopeKey(chatScope);
    final sources = db.box<CloudInboxChangeEntity>().getAll().where(
      (row) => row.scopeKey == scopeKey && row.generation == 1,
    );
    final sequence =
        sources.fold<int>(
          0,
          (max, row) => row.fetchSequence > max ? row.fetchSequence : max,
        ) +
        1;
    final changeHash = base64Url
        .encode(
          sha256
              .convert(utf8.encode('synthetic-chat-member-change-$sequence'))
              .bytes,
        )
        .replaceAll('=', '');
    db.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey:
            'change:${_digest('${chatScope.storageKey}\u001fchange\u001f$changeHash')}',
        changeIdHash: changeHash,
        scopeKey: scopeKey,
        accountFingerprint: chatScope.accountFingerprint,
        zone: chatScope.zone,
        serverRecordIdHash: mapping.serverRecordIdHash,
        etagHash: mapping.etagHash,
        changeType: deleted
            ? CloudChangeType.delete.name
            : CloudChangeType.save.name,
        encryptedServerRecordId: mapping.encryptedServerRecordId,
        encryptedPayloadRef: deleted ? null : mapping.encryptedRawRecordRef,
        protectedSystemFieldsRef: 'obcs2.ref.${'F' * 43}',
        payloadSha256: deleted ? null : 'e' * 64,
        batchId: 'synthetic-chat-member-batch-$sequence',
        generation: 1,
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

  void expectUnchangedLocalState() {
    expect(db.box<Chat>().count(), 1);
    expect(db.box<Message>().count(), 1);
    expect(db.box<CloudSyncLocalSendIntentEntity>().count(), 1);
    expect(db.box<CloudOutboxOperationEntity>().count(), 1);
    expect(message.text, _body);
    expect(message.guid, _guid);
    expect(message.ckRecordId, isNull);
    expect(intent.admittedChatBinding, bindingA);
  }

  Future<void> reopen() async {
    db.close();
    db = await openStore(directory: directory.path);
    bind();
  }

  Future<void> close() async {
    if (!db.isClosed()) db.close();
    // This directory is created by this synthetic fixture, never a profile.
    await directory.delete(recursive: true);
  }
}

CloudRecordMapEntity _copyMap(
  CloudRecordMapEntity source, {
  required String mapKey,
}) => CloudRecordMapEntity(
  mapKey: mapKey,
  scopeKey: source.scopeKey,
  accountFingerprint: source.accountFingerprint,
  zone: source.zone,
  logicalEntityKeyHash: source.logicalEntityKeyHash,
  serverRecordIdHash: source.serverRecordIdHash,
  generation: source.generation,
  encryptedServerRecordId: source.encryptedServerRecordId,
  etagHash: source.etagHash,
  encryptedRawRecordRef: source.encryptedRawRecordRef,
  updatedAtMs: source.updatedAtMs,
);

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
