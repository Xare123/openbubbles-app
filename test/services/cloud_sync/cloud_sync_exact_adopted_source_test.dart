import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

const _guid = '11111111-1111-4111-8111-111111111111';
const _recipient = 'recipient@example.invalid';
const _sender = 'sender@example.invalid';
const _body = 'synthetic exact adopted source';
final _now = DateTime.utc(2026, 9, 5);

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async => f.close());

  for (final metadata in ['record', 'sync', 'both']) {
    for (final restart in [false, true]) {
      test(
        'state2 $metadata metadata is read-only and recoverable (restart=$restart)',
        () async {
          final before = f.intent;
          f.setMetadata(metadata);
          if (restart) await f.reopen();
          final source = f.read();
          expect(source.state, 2);
          expect(
            source.message!.ckRecordId,
            metadata == 'sync' ? null : 'synthetic-record',
          );
          expect(source.message!.ckSyncState, metadata != 'record');
          expect(source.message!.text, _body);
          expect(source.message!.guid, _guid);
          expect(source.admittedOperationId, before.admittedOperationId);
          expect(source.sourceSha256, before.sourceSha256);
          expect(f.intent.admittedBindingSha256, before.admittedBindingSha256);
          final persisted = f.db.box<Message>().get(before.localMessageId)!;
          expect(persisted.ckRecordId, source.message!.ckRecordId);
          expect(persisted.ckSyncState, source.message!.ckSyncState);
          // No historical-origin creation, projection rewrite, or new outbox row.
          expect(f.db.box<CloudSyncLocalSendIntentEntity>().count(), 1);
          expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
          expect(f.db.box<Message>().count(), 1);
          expect(f.read().admittedOperationId, before.admittedOperationId);
        },
      );
    }
  }

  for (final mutation in [
    'text',
    'body formatting',
    'recipient',
    'sender',
    'message GUID',
    'different Chat',
    'deleted Message',
    'deleted flag',
    'edit flag',
    'attachment',
    'account',
    'owner',
    'epoch',
    'source hash',
    'outbox account',
    'outbox payload',
    'outbox missing',
    'record map',
    'generation',
  ]) {
    test('canonical metadata never bypasses $mutation drift', () {
      f.setMetadata('both');
      final message = f.message;
      final chat = message.chat.target!;
      switch (mutation) {
        case 'text':
          message.text = 'changed body';
          message.attributedBody = [AttributedBody.raw('changed body')];
        case 'body formatting':
          message.attributedBody = [];
        case 'recipient':
          f.db.box<Handle>().put(
            chat.handles.single..address = 'other@example.invalid',
          );
        case 'sender':
          f.db.box<Chat>().put(chat..usingHandle = 'other@example.invalid');
        case 'message GUID':
          message.guid = '22222222-2222-4222-8222-222222222222';
        case 'different Chat':
          final originalGuid = chat.guid;
          f.db.box<Chat>().put(
            chat..guid = 'iMessage;-;displaced@example.invalid',
          );
          final replacement = Chat(
            guid: originalGuid,
            chatIdentifier: _recipient,
            usingHandle: _sender,
            style: 45,
          )..handles.addAll(chat.handles);
          f.db.box<Chat>().put(replacement);
          message.chat.target = replacement;
        case 'deleted Message':
          f.db.box<Message>().remove(message.id!);
        case 'deleted flag':
          message.dateDeleted = _now;
        case 'edit flag':
          message.dateEdited = _now;
        case 'attachment':
          message.hasAttachments = true;
        case 'account':
          f.db.box<CloudSyncLocalSendIntentEntity>().put(
            f.intent..accountFingerprint = 'B' * 43,
          );
        case 'owner':
          f.db.box<CloudKitWriterAuthorityEntity>().put(
            f.db.box<CloudKitWriterAuthorityEntity>().getAll().single
              ..owner = 1,
          );
        case 'epoch':
          f.db.box<CloudKitWriterAuthorityEntity>().put(
            f.db.box<CloudKitWriterAuthorityEntity>().getAll().single
              ..epoch += 1,
          );
        case 'source hash':
          f.db.box<CloudSyncLocalSendIntentEntity>().put(
            f.intent..sourceSha256 = 'f' * 64,
          );
        case 'outbox account':
          f.db.box<CloudOutboxOperationEntity>().put(
            f.outbox..accountFingerprint = 'B' * 43,
          );
        case 'outbox payload':
          f.db.box<CloudOutboxOperationEntity>().put(
            f.outbox..payloadSha256 = 'f' * 64,
          );
        case 'outbox missing':
          f.db.box<CloudOutboxOperationEntity>().remove(f.outbox.id);
        case 'record map':
          final mapping = f.db.box<CloudRecordMapEntity>().getAll().singleWhere(
            (row) => row.zone == 'messageManateeZone',
          );
          f.db.box<CloudRecordMapEntity>().put(
            mapping..serverRecordIdHash = 'X' * 43,
          );
        case 'generation':
          final checkpoint = f.db
              .box<CloudSyncCheckpointEntity>()
              .getAll()
              .singleWhere((row) => row.zone == 'messageManateeZone');
          f.db.box<CloudSyncCheckpointEntity>().put(
            checkpoint..generation += 1,
          );
      }
      if (mutation != 'deleted Message') f.db.box<Message>().put(message);
      expect(
        f.read,
        throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())),
      );
      expect(f.db.box<CloudSyncLocalSendIntentEntity>().count(), 1);
    });
  }

  test(
    'caller recipient and original source hash remain mandatory after adoption',
    () {
      f.setMetadata('both');
      expect(
        () => f.journal.readExactIntent(
          intentId: f.intentId,
          expectedRecipient: 'other@example.invalid',
          expectedSourceSha256: f.sourceHash,
        ),
        throwsStateError,
      );
      expect(
        () => f.journal.readExactIntent(
          intentId: f.intentId,
          expectedRecipient: _recipient,
          expectedSourceSha256: 'b' * 64,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'confirmed readback may retain a newer map reference without restaging',
    () {
      f.setMetadata('both');
      f.db.box<CloudOutboxOperationEntity>().put(
        f.outbox
          ..state = CloudOutboxStatus.confirmed.index
          ..protectedLeaseReference = null,
      );
      final map = f.db.box<CloudRecordMapEntity>().getAll().singleWhere(
        (row) => row.zone == 'messageManateeZone',
      );
      f.db.box<CloudRecordMapEntity>().put(
        map..encryptedServerRecordId = 'obcs2.ref.${'Q' * 43}',
      );
      expect(f.read().admittedOperationId, f.outbox.operationId);
      expect(f.message.ckRecordId, 'synthetic-record');
      expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );

  test(
    'history metadata cannot create an intent or make ready history admissible',
    () {
      f.setMetadata('both');
      final history =
          Message(
              guid: '22222222-2222-4222-8222-222222222222',
              isFromMe: true,
              text: _body,
              dateCreated: _now,
              attributedBody: [AttributedBody.raw(_body)],
              ckRecordId: 'history-record',
            )
            ..chat.target = f.message.chat.target
            ..ckSyncState = true;
      f.db.box<Message>().put(history);
      expect(
        () => f.journal.readExactIntent(
          intentId: f.intentId + 100,
          expectedRecipient: _recipient,
          expectedSourceSha256: f.sourceHash,
        ),
        throwsStateError,
      );
      expect(
        CloudSyncLocalSendIdentity.capture(
          history,
          history.chat.target!,
          history.guid!,
        ),
        isNull,
      );
      // Even an existing ready origin does not receive the state2 exception.
      final ready = f.intent
        ..state = 1
        ..admittedOperationId = null
        ..admittedBindingSha256 = null
        ..admittedChatBinding = null;
      f.db.box<CloudSyncLocalSendIntentEntity>().put(ready);
      expect(f.read, throwsStateError);
      expect(f.db.box<CloudSyncLocalSendIntentEntity>().count(), 1);
      expect(f.db.box<CloudOutboxOperationEntity>().count(), 1);
      expect(
        f.db.box<Message>().get(history.id!)!.ckRecordId,
        'history-record',
      );
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
  CloudSyncLocalSendIntentEntity get intent =>
      db.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;
  Message get message => db.box<Message>().get(intent.localMessageId)!;
  CloudOutboxOperationEntity get outbox =>
      db.box<CloudOutboxOperationEntity>().getAll().single;
  CloudSyncLocalSendAdmissionSource read() => journal.readExactIntent(
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
      'exact-adopted-source-',
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
      chatScope: f.scope('chatManateeZone'),
      now: _now,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: f.db,
      store: f.sync,
      chatScope: f.scope('chatManateeZone'),
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
    // Journal unit boundary: synthetic protected envelope, actual journal
    // adoption and outbox persistence in one transaction, no native writer.
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
    return f;
  }

  void setMetadata(String metadata) {
    final local = message;
    if (metadata != 'sync') local.ckRecordId = 'synthetic-record';
    local.ckSyncState = metadata != 'record';
    db.box<Message>().put(local);
  }

  Future<void> reopen() async {
    db.close();
    db = await openStore(directory: directory.path);
    bind();
  }

  Future<void> close() async {
    if (!db.isClosed()) db.close();
    await directory.delete(recursive: true);
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
