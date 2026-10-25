import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_fixtures.dart';
import 'package:bluebubbles/backend_harness/backend_harness_fixture_archive.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_mutation_lineage.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/cloud_sync/cloud_sync_restored_chat_test_fixture.dart';

const fixture = '01234567-89AB-4DEF-8123-456789ABCDEF';
const guid = '11234567-89AB-4DEF-8123-456789ABCDEF';
final account = 'A' * 43;
final now = DateTime.utc(2026, 10, 24);
final stamp = now.millisecondsSinceEpoch;
String digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
String ref(String c) => 'obcs2.ref.${c * 43}';
CloudSyncScope scope(String zone) => CloudSyncScope(
  accountFingerprint: account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Store store;
  late CloudSyncNativeAuthSnapshot auth;
  late Message message;
  late CloudSyncLocalSendIntentEntity origin;
  late CloudOutboxOperationEntity create;
  late String chatBinding;

  Map<String, bool> observe() =>
      BackendHarnessFixtures.readStatus(store, auth, fixture).flags;
  void saveOrigin() => store.box<CloudSyncLocalSendIntentEntity>().put(origin);
  void saveCreate() => store.box<CloudOutboxOperationEntity>().put(create);
  String binding() => digest([
    origin.protectedSourceBinding == null
        ? 'cloud-sync-local-send-adoption-v2'
        : 'cloud-sync-local-send-adoption-v3',
    scope('messageManateeZone').storageKey,
    create.operationId,
    create.logicalEntityKeyHash,
    'save',
    create.payloadVersion,
    create.mutationRevision,
    create.checkpointGeneration,
    create.encryptedPayloadRef,
    create.payloadSha256,
    create.serverRecordIdHash,
    [],
    create.createdAtMs,
    origin.admittedChatBinding,
    if (origin.protectedSourceBinding != null) origin.protectedSourceBinding,
  ]);
  void settleCreate() {
    create.state = 2;
    create.confirmedAtMs = stamp + 1;
    create.protectedLeaseReference = null;
    create.appleRequestUuid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
    create.appleOperationUuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
    origin.confirmedReadbackBindingSha256 = origin.admittedBindingSha256;
    saveCreate();
    saveOrigin();
  }

  void checkpoint(CloudSyncScope s) =>
      store.box<CloudSyncCheckpointEntity>().put(
        CloudSyncCheckpointEntity(
          checkpointKey: cloudSyncPersistentScopeKey(s),
          accountFingerprint: account,
          container: s.container,
          database: s.database,
          zone: s.zone,
          streamKind: s.streamKind.name,
          persistenceLane: s.persistenceLane.name,
          updatedAtMs: stamp,
        ),
      );

  setUp(() async {
    // Disposable stores stay inside the assigned checkout. No real profile,
    // native client, network, account, or service singleton is initialized.
    directory = await Directory(
      '${Directory.current.path}/test/backend_harness',
    ).createTemp('fixture-archive-');
    store = await openStore(directory: directory.path);
    auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic',
      accountFingerprint: account,
      protectedStoreIdentity: 'obcs2.store.$account',
      cloudMessagesClient: Object(),
    );
    final writer = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final writerScope = CloudKitWriterScope(accountFingerprint: account);
    final disabled = writer.initializeDisabled(writerScope, now: now);
    writer.provisionInitialOwner(
      writerScope,
      owner: CloudKitWriterOwner.v2,
      expectedEpoch: disabled.epoch,
      evidence: const CloudKitWriterTransitionEvidence.forTest(
        operationsQuiesced: true,
        activeIdentityRevalidated: true,
        legacyMutationQueues: LegacyMutationQueueDisposition.empty,
      ),
      now: now,
    );
    final handle = Handle(
      address: '+16177106179',
      service: 'iMessage',
      uniqueAddressAndService: '+16177106179/iMessage',
    );
    store.box<Handle>().put(handle);
    final chat =
        Chat(
            guid: 'iMessage;-;+16177106179',
            chatIdentifier: '+16177106179',
            style: 45,
            usingHandle: 'tel:+19079786948',
          )
          ..cloudGuid = fixture
          ..handles.add(handle);
    store.box<Chat>().put(chat);
    message = Message(
      guid: guid,
      text: BackendHarnessFixtures.marker(fixture),
      isFromMe: true,
      dateCreated: now,
      attributedBody: [
        AttributedBody.raw(BackendHarnessFixtures.marker(fixture)),
      ],
    )..chat.target = chat;
    store.box<Message>().put(message);
    final identity = CloudSyncLocalSendIdentity.capture(message, chat, guid)!;
    final cloudStore = ObjectBoxCloudSyncStore(
      store: store,
      protector: _Protector(),
      clock: () => now,
    );
    final chatScope = scope('chatManateeZone');
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: store,
      store: cloudStore,
      chatScope: chatScope,
      now: now,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: store,
      store: cloudStore,
      chatScope: chatScope,
      chat: chat,
      appliedSource: applied,
      now: now,
    );
    final s = scope('messageManateeZone');
    checkpoint(s);
    chatBinding = requireCloudSyncRestoredDirectChat(
      store: store,
      messageScope: s,
      message: message,
    );
    create = CloudOutboxOperationEntity(
      operationId: CloudOperationIdentity.forInitialCreate(
        scope: s,
        logicalEntityKeyHash: 'L' * 43,
        payloadVersion: 2,
      ),
      scopeKey: cloudSyncPersistentScopeKey(s),
      accountFingerprint: account,
      zone: s.zone,
      logicalEntityKeyHash: 'L' * 43,
      action: 0,
      mutationRevision: 1,
      checkpointGeneration: 1,
      payloadVersion: 2,
      encryptedPayloadRef: ref('P'),
      payloadSha256: 'a' * 64,
      serverRecordIdHash: 'R' * 43,
      protectedLeaseReference: 'obcs2.lease.${'a' * 32}',
      createdAtMs: stamp,
      updatedAtMs: stamp + 1,
    );
    saveCreate();
    store.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(s, create.logicalEntityKeyHash),
        scopeKey: create.scopeKey,
        accountFingerprint: account,
        zone: s.zone,
        logicalEntityKeyHash: create.logicalEntityKeyHash,
        serverRecordIdHash: create.serverRecordIdHash!,
        generation: 1,
        encryptedServerRecordId: ref('P'),
        etagHash: 'E' * 43,
        encryptedRawRecordRef: ref('W'),
        rawRecordGeneration: 1,
        updatedAtMs: stamp,
      ),
    );
    origin = CloudSyncLocalSendIntentEntity(
      intentKey: digest([
        'cloud-sync-local-send-intent-v1',
        account,
        identity.guidHash,
      ]),
      accountFingerprint: account,
      writerEpoch: writer.read(writerScope)!.epoch,
      localMessageId: message.id!,
      messageGuidHash: identity.guidHash,
      sourceSha256: identity.sourceSha256,
      state: 2,
      idsConfirmationVersion: 2,
      admittedOperationId: create.operationId,
      admittedChatBinding: chatBinding,
      createdAtMs: stamp,
      updatedAtMs: stamp + 1,
    );
    origin.admittedBindingSha256 = binding();
    saveOrigin();
  });
  tearDown(() async {
    store.close();
    // Exact test-owned directory only; no profile or other checkout data.
    await directory.delete(recursive: true);
  });

  test('canonical adoption cannot make the same fixture send available again', () {
    expect(BackendHarnessFixtures.hasRetainedFixture(store, fixture), isTrue);
    store.box<Message>().removeAll();
    expect(BackendHarnessFixtures.hasRetainedFixture(store, fixture), isTrue);
    expect(BackendHarnessFixtures.hasRetainedFixture(store,
      '31234567-89AB-4DEF-8123-456789ABCDEF'), isFalse);
  });

  test('positive IDS and pending create are distinct from readback', () {
    expect(observe(), containsPair('ids_evidence_present', true));
    expect(observe(), containsPair('fixture_create_pending', true));
    expect(observe(), containsPair('fixture_create_settled', false));
    settleCreate();
    expect(observe(), containsPair('fixture_create_settled', true));
    expect(observe(), containsPair('fixture_edit_present', false));
    expect(observe(), containsPair('outcome_uncertain', false));
  });

  test('canonical retained parent permits mutation only with exact completed evidence', () {
    bool allowed() => BackendHarnessFixtures.hasSettledMutationPredecessor(
      store, auth, fixture, guid);
    expect(message.chat.target!.guid, isNot(fixture));
    expect(message.chat.target!.cloudGuid, fixture);
    expect(allowed(), false);
    settleCreate();
    expect(allowed(), true);
    expect(BackendHarnessFixtures.hasSettledMutationPredecessor(
      store, auth, fixture, '31234567-89AB-4DEF-8123-456789ABCDEF'), false);
    origin.sourceSha256 = '0' * 64; saveOrigin();
    expect(allowed(), false);
  });

  test('duplicate retained chat identity refuses status and mutation', () {
    settleCreate();
    store.box<Chat>().put(Chat(guid: fixture));
    expect(observe()['fixture_create_settled'], false);
    expect(observe()['outcome_uncertain'], true);
    expect(BackendHarnessFixtures.hasSettledMutationPredecessor(store, auth, fixture, guid), false);
  });

  test('fixture status serializes with the parent protocol flags', () {
    settleCreate();
    expect(BackendHarnessFixtures.readStatus(store, auth, fixture).toJson()['flags'], observe());
  });

  test('save confirmation and receipt cleanup without marker never settle', () {
    settleCreate();
    origin.confirmedReadbackBindingSha256 = null;
    saveOrigin();
    expect(observe()['fixture_create_settled'], false);
    expect(observe()['outcome_uncertain'], true);
    create.protectedLeaseReference = 'obcs2.lease.${'a' * 32}';
    saveCreate();
    expect(observe()['fixture_create_pending'], true);
    expect(observe()['fixture_create_settled'], false);
  });

  test(
    'ordinary archive progress never leaves sticky writer job uncertainty',
    () {
      for (final state in [0, 1, 3]) {
        create.state = state;
        saveCreate();
        expect(observe()['fixture_create_pending'], true);
        expect(observe()['outcome_uncertain'], false);
        final completion = BackendHarnessFixtures.readStatus(
          store,
          auth,
          fixture,
          completedAction: 'create',
        );
        expect(completion.flags['outcome_uncertain'], false);
        expect(completion.flags['fixture_create_settled'], false);
      }
      create.state = 5;
      saveCreate();
      expect(observe()['outcome_uncertain'], true);
      expect(
        BackendHarnessFixtures.readStatus(
          store,
          auth,
          fixture,
          completedAction: 'create',
        ).flags['outcome_uncertain'],
        false,
      );
      origin.idsConfirmationVersion = 0;
      saveOrigin();
      expect(
        BackendHarnessFixtures.readStatus(
          store,
          auth,
          fixture,
          completedAction: 'create',
        ).flags['outcome_uncertain'],
        true,
      );
    },
  );

  test('Delivered and empty total outbox do not substitute for origin', () {
    store.box<CloudSyncLocalSendIntentEntity>().removeAll();
    store.box<CloudOutboxOperationEntity>().removeAll();
    message.dateDelivered = now;
    store.box<Message>().put(message);
    expect(observe()['ids_evidence_present'], false);
    expect(observe()['fixture_create_present'], false);
    expect(observe()['outcome_uncertain'], true);
  });

  test('absent fixture has explicit absent facts', () {
    final result = BackendHarnessFixtures.readStatus(
      store,
      auth,
      '31234567-89AB-4DEF-8123-456789ABCDEF',
    );
    expect(result.counts['messages'], 0);
    expect(result.flags['fixture_create_present'], false);
    expect(result.flags['fixture_create_settled'], false);
    expect(result.flags['outcome_uncertain'], false);
  });

  for (final state in [1, 3, 4, 5]) {
    test('nonterminal outbox state $state never settles', () {
      settleCreate();
      create.state = state;
      saveCreate();
      expect(observe()['fixture_create_settled'], false);
      expect(observe()['outcome_uncertain'], true);
    });
  }
  final corruptions = <String, void Function()>{
    'GUID': () {
      origin.messageGuidHash = '0' * 64;
      saveOrigin();
    },
    'source': () {
      origin.sourceSha256 = '0' * 64;
      saveOrigin();
    },
    'binding': () {
      origin.confirmedReadbackBindingSha256 = '0' * 64;
      saveOrigin();
    },
    'operation': () {
      origin.admittedOperationId = 'missing';
      saveOrigin();
    },
    'operation account': () {
      create.accountFingerprint = 'B' * 43;
      saveCreate();
    },
    'payload': () {
      create.payloadSha256 = '0' * 64;
      saveCreate();
    },
    'generation': () {
      create.checkpointGeneration++;
      saveCreate();
    },
    'IDS legacy': () {
      origin.idsConfirmationVersion = 0;
      saveOrigin();
    },
    'held lease': () {
      create.protectedLeaseReference = 'obcs2.lease.${'a' * 32}';
      saveCreate();
    },
    'submission': () {
      create.appleOperationUuid = null;
      saveCreate();
    },
    'account': () {
      auth = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'other',
        accountFingerprint: 'B' * 43,
        protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
        cloudMessagesClient: Object(),
      );
    },
  };
  for (final entry in corruptions.entries) {
    test('${entry.key} mismatch prevents settled claim', () {
      settleCreate();
      expect(observe()['fixture_create_settled'], true);
      entry.value();
      expect(observe()['fixture_create_settled'], false);
      expect(observe()['outcome_uncertain'], true);
    });
  }

  test('duplicate origin cannot borrow exact completed evidence', () {
    settleCreate();
    origin.id = 0;
    origin.intentKey = 'duplicate';
    saveOrigin();
    expect(observe()['fixture_create_settled'], false);
    expect(observe()['outcome_uncertain'], true);
  });

  test(
    'settlement survives reopening and observation preserves rows',
    () async {
      settleCreate();
      final before = observe();
      final rowCount = store.box<CloudOutboxOperationEntity>().count();
      store.close();
      store = await openStore(directory: directory.path);
      expect(observe(), before);
      expect(store.box<CloudOutboxOperationEntity>().count(), rowCount);
      expect(
        store
            .box<CloudSyncLocalSendIntentEntity>()
            .get(origin.id)!
            .confirmedReadbackBindingSha256,
        origin.confirmedReadbackBindingSha256,
      );
      expect(store.box<Message>().get(message.id!)!.text, message.text);
    },
  );

  CloudSyncLocalMutationIntentEntity mutate({required bool undo}) {
    message = store.box<Message>().get(message.id!)!;
    final before = cloudSyncMutationTargetSnapshot(message);
    final summary = message.messageSummaryInfo.isEmpty
        ? MessageSummaryInfo.empty()
        : message.messageSummaryInfo.single;
    final time = now.add(Duration(seconds: undo ? 2 : 1));
    if (undo) {
      summary.retractedParts = [0];
    } else {
      summary.editedContent['0'] = [
        EditedContent(
          text: Content(values: message.attributedBody),
          date: stamp.toDouble(),
        ),
        EditedContent(
          text: Content(
            values: [
              AttributedBody.raw(
                BackendHarnessFixtures.marker(fixture, edited: true),
              ),
            ],
          ),
          date: time.millisecondsSinceEpoch.toDouble(),
        ),
      ];
      summary.editedParts = [0];
      message.text = BackendHarnessFixtures.marker(fixture, edited: true);
      message.attributedBody = [AttributedBody.raw(message.text!)];
    }
    message.messageSummaryInfo = [summary];
    message.dateEdited = time;
    store.box<Message>().put(message);
    final mutationHash = digest([
      'cloud-sync-local-send-guid-v1',
      undo ? 'undo' : 'edit',
    ]);
    final source = CloudSyncLocalMutationSourceBinding(
      accountFingerprint: account,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      mutationGuidHash: mutationHash,
      targetGuidHash: origin.messageGuidHash,
      targetPart: 0,
      sourceSha256: 'c' * 64,
      protectedReference: ref('U'),
      leaseReference: 'obcs2.lease.${'c' * 32}',
      payloadSha256: 'd' * 64,
      payloadLength: 10,
    );
    final s = scope('messageManateeZone');
    final revision = undo ? 3 : 2;
    final operation = CloudOutboxOperationEntity(
      operationId: CloudOperationIdentity.forMutation(
        scope: s,
        logicalEntityKeyHash: create.logicalEntityKeyHash,
        action: CloudOutboxAction.save,
        payloadVersion: 3,
        mutationRevision: revision,
        payloadSha256: 'e' * 64,
      ),
      scopeKey: create.scopeKey,
      accountFingerprint: account,
      zone: s.zone,
      logicalEntityKeyHash: create.logicalEntityKeyHash,
      action: 0,
      payloadVersion: 3,
      mutationRevision: revision,
      checkpointGeneration: 1,
      encryptedPayloadRef: ref('U'),
      payloadSha256: 'e' * 64,
      serverRecordIdHash: create.serverRecordIdHash,
      state: 2,
      confirmedAtMs: time.millisecondsSinceEpoch,
      appleRequestUuid: create.appleRequestUuid,
      appleOperationUuid: create.appleOperationUuid,
      createdAtMs: time.millisecondsSinceEpoch,
      updatedAtMs: time.millisecondsSinceEpoch,
    );
    store.box<CloudOutboxOperationEntity>().put(operation);
    final row = CloudSyncLocalMutationIntentEntity(
      intentKey: digest([
        'cloud-sync-local-mutation-intent-v1',
        account,
        mutationHash,
      ]),
      accountFingerprint: account,
      writerEpoch: origin.writerEpoch,
      localMessageId: message.id!,
      localChatId: message.chat.targetId,
      mutationGuidHash: mutationHash,
      targetGuidHash: origin.messageGuidHash,
      targetPart: 0,
      kind: undo ? 1 : 0,
      sourceSha256: source.sourceSha256,
      targetSnapshotSha256: before,
      protectedSourceBinding: source.encode(),
      state: 5,
      submissionAuthBindingSha256: 'a' * 64,
      idsReceiptBindingSha256: 'b' * 64,
      reflectedSnapshotSha256: cloudSyncMutationTargetSnapshot(message),
      admittedOperationId: operation.operationId,
      admittedBindingSha256: 'c' * 64,
      createdAtMs: time.millisecondsSinceEpoch,
      updatedAtMs: time.millisecondsSinceEpoch + 1,
    );
    store.box<CloudSyncLocalMutationIntentEntity>().put(row);
    return row;
  }

  for (final undo in [false, true]) {
    test(
      'exact ${undo ? 'undo' : 'edit'} readback requires state 5 and matching operation',
      () {
        settleCreate();
        final row = mutate(undo: undo);
        final kind = undo ? 'undo' : 'edit';
        expect(observe()['fixture_create_settled'], true);
        expect(observe()['fixture_${kind}_settled'], true);
        expect(observe()['outcome_uncertain'], false);
        row.state = 4;
        store.box<CloudSyncLocalMutationIntentEntity>().put(row);
        expect(observe()['fixture_${kind}_settled'], false);
        row.state = 5;
        row.admittedOperationId = create.operationId;
        store.box<CloudSyncLocalMutationIntentEntity>().put(row);
        expect(observe()['fixture_${kind}_settled'], false);
        expect(observe()['outcome_uncertain'], true);
      },
    );
  }
  test('edit then undo retains both exact terminal observations', () {
    settleCreate();
    mutate(undo: false);
    mutate(undo: true);
    expect(observe()['fixture_edit_settled'], true);
    expect(observe()['fixture_undo_settled'], true);
    expect(observe()['outcome_uncertain'], false);
  });
  test('mutation pending is not sticky completion uncertainty or a settled predecessor', () {
    settleCreate(); final row = mutate(undo: false);
    row.state = 4; store.box<CloudSyncLocalMutationIntentEntity>().put(row);
    final op = store.box<CloudOutboxOperationEntity>().getAll()
      .singleWhere((candidate) => candidate.operationId == row.admittedOperationId);
    op.state = 1; op.confirmedAtMs = 0;
    op.protectedLeaseReference = 'obcs2.lease.${'c' * 32}';
    store.box<CloudOutboxOperationEntity>().put(op);
    expect(observe()['fixture_edit_pending'], true);
    expect(observe()['outcome_uncertain'], false);
    expect(BackendHarnessFixtures.readStatus(store, auth, fixture, completedAction: 'edit')
      .flags['outcome_uncertain'], false);
    expect(BackendHarnessFixtures.hasSettledMutationPredecessor(store, auth, fixture, guid), false);
  });

  test('settled edit permits undo but an existing undo never permits another mutation', () {
    settleCreate(); mutate(undo: false);
    expect(BackendHarnessFixtures.hasSettledMutationPredecessor(store, auth, fixture, guid), true);
    mutate(undo: true);
    expect(BackendHarnessFixtures.hasSettledMutationPredecessor(store, auth, fixture, guid), false);
  });
  test('same-parent edit and undo operations cannot be swapped', () {
    settleCreate();
    final edit = mutate(undo: false);
    final undo = mutate(undo: true);
    final first = edit.admittedOperationId;
    edit.admittedOperationId = undo.admittedOperationId;
    undo.admittedOperationId = first;
    store.box<CloudSyncLocalMutationIntentEntity>().putMany([edit, undo]);
    expect(observe()['fixture_edit_settled'], false);
    expect(observe()['fixture_undo_settled'], false);
    expect(observe()['outcome_uncertain'], true);
  });
  test('mutation protected store mismatch never settles', () {
    settleCreate();
    mutate(undo: false);
    auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic',
      accountFingerprint: account,
      protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
      cloudMessagesClient: Object(),
    );
    expect(observe()['fixture_edit_settled'], false);
    expect(observe()['outcome_uncertain'], true);
  });
  test('detached mutation reflection cannot become settled', () {
    settleCreate();
    final row = mutate(undo: false);
    row.reflectedSnapshotSha256 = '0' * 64;
    store.box<CloudSyncLocalMutationIntentEntity>().put(row);
    expect(observe()['fixture_edit_settled'], false);
    expect(observe()['outcome_uncertain'], true);
  });
  test('attachment source from a different protected store fails closed', () {
    settleCreate();
    origin.protectedSourceBinding = CloudSyncLocalSendSourceBinding(
      accountFingerprint: account,
      protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
      messageGuidHash: origin.messageGuidHash,
      sourceSha256: origin.sourceSha256,
      protectedReference: ref('S'),
      leaseReference: 'obcs2.lease.${'a' * 32}',
      payloadSha256: 'a' * 64,
      payloadLength: 10,
    ).encode();
    origin.admittedBindingSha256 = binding();
    origin.confirmedReadbackBindingSha256 = binding();
    saveOrigin();
    expect(observe()['fixture_attachment_archive_settled'], false);
    expect(observe()['fixture_create_settled'], false);
    expect(observe()['outcome_uncertain'], true);
  });

  test(
    'stored attachment child inventory requires exact released readback',
    () {
      final attachment = Attachment(
        guid: '${guid}_0',
        mimeType: 'image/png',
        metadata: {'rustpush': '<synthetic-mmcs-descriptor/>'},
      );
      store.box<Attachment>().put(attachment);
      final prepared = BackendHarnessFixtures.prepareAttachment(fixture, attachment);
      message.text = prepared.text;
      message.subject = prepared.subject;
      message.attributedBody = prepared.attributedBody;
      message.hasAttachments = true;
      message.dbAttachments.add(attachment);
      store.box<Message>().put(message);
      final source = CloudSyncLocalSendIdentity.captureAttachment(
        message,
        message.chat.target!,
        guid,
      )!;
      origin.sourceSha256 = source.sourceSha256;
      origin.protectedSourceBinding = CloudSyncLocalSendSourceBinding(
        accountFingerprint: account,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        messageGuidHash: origin.messageGuidHash,
        sourceSha256: origin.sourceSha256,
        protectedReference: ref('S'),
        leaseReference: 'obcs2.lease.${'a' * 32}',
        payloadSha256: 'a' * 64,
        payloadLength: 10,
      ).encode();
      final s = scope('attachmentManateeZone');
      checkpoint(s);
      final child = CloudOutboxOperationEntity(
        operationId: CloudOperationIdentity.forInitialCreate(
          scope: s,
          logicalEntityKeyHash: 'K' * 43,
          payloadVersion: 1,
        ),
        scopeKey: cloudSyncPersistentScopeKey(s),
        accountFingerprint: account,
        zone: s.zone,
        logicalEntityKeyHash: 'K' * 43,
        action: 0,
        mutationRevision: 1,
        checkpointGeneration: 1,
        encryptedPayloadRef: ref('D'),
        payloadSha256: 'd' * 64,
        serverRecordIdHash: 'C' * 43,
        state: 2,
        confirmedAtMs: stamp,
        appleRequestUuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        appleOperationUuid: 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',
        createdAtMs: stamp,
        updatedAtMs: stamp,
      );
      store.box<CloudOutboxOperationEntity>().put(child);
      final upload = CloudAttachmentUploadEntity(
        uploadKey: digest([
          'cloud-sync-attachment-upload-v1',
          s.storageKey,
          origin.messageGuidHash,
          origin.sourceSha256,
          'K' * 43,
        ]),
        accountFingerprint: account,
        writerEpoch: origin.writerEpoch,
        checkpointGeneration: 1,
        localSendIntentId: origin.id,
        messageGuidHash: origin.messageGuidHash,
        sourceSha256: origin.sourceSha256,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        attachmentKeyHash: 'K' * 43,
        serverRecordIdHash: 'C' * 43,
        planReference: ref('P'),
        planLeaseReference: 'obcs2.lease.${'a' * 32}',
        planPayloadSha256: 'a' * 64,
        state: 3,
        attemptId: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        resultReference: ref('D'),
        resultLeaseReference: 'obcs2.lease.${'d' * 32}',
        resultPayloadSha256: 'd' * 64,
        admittedOperationId: child.operationId,
        createdAtMs: stamp,
        updatedAtMs: stamp,
      );
      store.box<CloudAttachmentUploadEntity>().put(upload);
      final body = <Object>[
        1,
        s.storageKey,
        1,
        origin.id,
        origin.messageGuidHash,
        origin.sourceSha256,
        auth.protectedStoreIdentity,
        origin.writerEpoch,
        ['K' * 43],
        [
          [
            upload.id,
            upload.attachmentKeyHash,
            upload.serverRecordIdHash,
            upload.resultPayloadSha256!,
            child.operationId,
          ],
        ],
      ];
      origin.admittedChatBinding = jsonEncode([
        4,
        chatBinding,
        jsonEncode([...body, digest(body)]),
      ]);
      origin.admittedBindingSha256 = binding();
      settleCreate();
      Map<String, bool> inspect() => backendFixtureArchiveFlags(
        store: store,
        auth: auth,
        message: store.box<Message>().get(message.id!)!,
        messageGuid: guid,
      );
      expect(inspect()['fixture_attachment_archive_settled'], true);
      expect(inspect()['fixture_create_settled'], true);
      // This one receipt test resolves attachment parts through the ordinary
      // static box, bound only to this disposable store for this isolate.
      Database.attachments = store.box<Attachment>();
      expect(observe()['fixture_attachment_archive_settled'], true);
      expect(inspect().containsKey('attachment_bytes_match'), false);
      child.protectedLeaseReference = upload.resultLeaseReference;
      store.box<CloudOutboxOperationEntity>().put(child);
      expect(inspect()['fixture_attachment_archive_settled'], false);
      expect(inspect()['fixture_create_settled'], false);
      expect(inspect()['outcome_uncertain'], true);
    },
  );

  for (final kind in ['image/png', 'text/plain']) {
    test('$kind fixture marker body survives attachment capture and reflection', () {
      const descriptor = '<plist><dict><key>mmcs-object</key>'
          '<string>synthetic-object</string></dict></plist>';
      final attachment = Attachment(
        guid: 'synthetic-pending-attachment', mimeType: kind,
        metadata: {'rustpush': descriptor},
      );
      final pending = BackendHarnessFixtures.prepareAttachment(fixture, attachment);
      final chat = message.chat.target!;
      pending.guid = guid;
      pending.chat.target = chat;
      expect(pending.subject, isNull);
      expect(BackendHarnessFixtures.ownsMessage(pending, fixture, retainedChat: true), true);
      final source = CloudSyncLocalSendIdentity.captureAttachment(pending, chat, guid);
      expect(source, isNotNull);
      expect(source!.isAttachment, true);

      final reflectedAttachment = Attachment(
        guid: '${guid}_1', mimeType: kind, metadata: {'rustpush': descriptor},
      );
      final reflected = BackendHarnessFixtures.prepareAttachment(fixture, reflectedAttachment);
      reflected.guid = guid;
      reflected.chat.target = chat;
      final body = reflected.attributedBody.single;
      reflected.text = '${BackendHarnessFixtures.marker(fixture)} ';
      reflected.attributedBody = [AttributedBody(string: reflected.text!, runs: body.runs)];
      expect(BackendHarnessFixtures.ownsMessage(reflected, fixture, retainedChat: true), true);
      expect(CloudSyncLocalSendIdentity.captureAttachment(reflected, chat, guid,
        expectedSourceSha256: source.sourceSha256), isNotNull);
      reflected.subject = BackendHarnessFixtures.marker(fixture);
      expect(CloudSyncLocalSendIdentity.captureAttachment(reflected, chat, guid), isNull);
      reflected.subject = null;
      reflected.text = 'unowned body ';
      expect(BackendHarnessFixtures.ownsMessage(reflected, fixture, retainedChat: true), false);
      expect(CloudSyncLocalSendIdentity.captureAttachment(reflected, chat, guid,
        expectedSourceSha256: source.sourceSha256), isNull);
      reflected.text = '${BackendHarnessFixtures.marker(fixture)} ';
      reflectedAttachment.metadata = {'rustpush': '<plist>changed descriptor</plist>'};
      expect(CloudSyncLocalSendIdentity.captureAttachment(reflected, chat, guid,
        expectedSourceSha256: source.sourceSha256), isNull);
    });
  }
}

final class _Protector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      account;
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'protected:$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext.substring('protected:'.length);
}
