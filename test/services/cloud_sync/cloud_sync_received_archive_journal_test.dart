import 'dart:io';
import 'dart:typed_data';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_inspection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_record_observation.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';
import 'cloud_sync_test_helpers.dart' show testSubmissionIdentity;

String _a43(String c) => List.filled(43, c).join();
String _h64(String c) => List.filled(64, c).join();
String _lease(String c) => 'obcs2.lease.${List.filled(32, c).join()}';
DateTime _time(int s) => DateTime.utc(2026, 9, 15, 12, 0, s);
final _scope = CloudKitWriterScope(
  accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
const _evidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
String get _account => 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
String get _storeId => 'obcs2.store.${_a43('S')}';
CloudSyncNativeAuthSnapshot _auth(Object client) {
  return CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: 'native-session',
    accountFingerprint: _account,
    protectedStoreIdentity: _storeId,
    cloudMessagesClient: client,
  );
}

Matcher _fails(String code) =>
    isA<StateError>().having((e) => e.message, 'message', code);
const _owner = 'mailto:owner@example.com';
const _chatGuid = 'iMessage;-;remote@example.com';
const _live = CloudSyncReceivedArchiveLiveContext(
  observedViaLiveReceive: true,
  observedLocalHandles: [_owner],
  receivedOnHandle: _owner,
);
api.NormalMessage _plainNormal(String text) {
  return api.NormalMessage(
    parts: api.MessageParts(
      field0: [
        api.IndexedMessagePart(
          part_: api.MessagePart.text(
            text,
            const api.TextFormat.flags(
              api.TextFlags(
                bold: false,
                italic: false,
                underline: false,
                strikethrough: false,
              ),
            ),
          ),
        ),
      ],
    ),
    service: const api.MessageType_IMessage(),
    voice: false,
  );
}

api.MessageInst _wire({
  required String id,
  required String text,
  required int sentAt,
  String? sender,
}) {
  return api.MessageInst(
    id: id,
    sender: sender ?? 'mailto:remote@example.com',
    conversation: api.ConversationData(
      participants: [_owner, 'mailto:remote@example.com'],
      senderGuid: _chatGuid,
    ),
    message: api.Message.message(_plainNormal(text)),
    sentTimestamp: sentAt,
    target: [api.MessageTarget.token(Uint8List(32))],
    sendDelivered: false,
    verificationFailed: false,
    receivedOnHandle: _owner,
  );
}

Message _scratch(
  String guid,
  String text,
  Chat chat, {
  String handleAddr = 'remote@example.com',
}) {
  final sentAt = _time(2).millisecondsSinceEpoch;
  final row = Message(
    guid: guid,
    text: text,
    dateCreated: DateTime.fromMillisecondsSinceEpoch(sentAt, isUtc: true),
    isFromMe: false,
    attributedBody: [AttributedBody.raw(text)],
    handle: Handle(address: handleAddr, service: 'iMessage'),
  );
  row.id = 901;
  row.handle!.originalROWID = 9001;
  row.handleId = 9001;
  row.chat.target = chat;
  return row;
}

Message _fresh(
  String guid,
  String text,
  Chat chat, {
  String handleAddr = 'remote@example.com',
}) {
  final sentAt = _time(2).millisecondsSinceEpoch;
  final row = Message(
    guid: guid,
    text: text,
    dateCreated: DateTime.fromMillisecondsSinceEpoch(sentAt, isUtc: true),
    isFromMe: false,
    attributedBody: [AttributedBody.raw(text)],
    handle: Handle(address: handleAddr, service: 'iMessage'),
  );
  row.handle!.originalROWID = 9001;
  row.handleId = 9001;
  row.chat.target = chat;
  return row;
}

CloudSyncReceivedArchiveSourceBinding _staged(
  String guid,
  String text,
  Chat chat, {
  String? sender,
  int? sentAt,
  String ref = 'R',
  String lease = 'a',
}) {
  final stamp = sentAt ?? _time(2).millisecondsSinceEpoch;
  final s = _scratch(guid, text, chat);
  final cap = CloudSyncReceivedArchiveIdentity.capture(
    message: s,
    chat: chat,
    wire: _wire(id: guid, text: text, sentAt: stamp, sender: sender),
    liveContext: _live,
  );
  if (cap is! CloudSyncReceivedArchiveEligible) {
    throw StateError('staging setup failed');
  }
  final idn = cap.identity;
  return CloudSyncReceivedArchiveSourceBinding(
    accountFingerprint: _account,
    protectedStoreIdentity: _storeId,
    messageGuidHash: idn.guidHash,
    sourceSha256: idn.sourceSha256,
    protectedReference: 'obcs2.ref.${_a43(ref)}',
    leaseReference: _lease(lease),
    payloadSha256: _h64('b'),
    payloadLength: 128,
  );
}

void main() {
  late Directory directory;
  late Directory tempRoot;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot snap;
  late CloudSyncReceivedArchiveJournal journal;
  late Chat chat;
  late Handle remote;
  void provision() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    if (authority.read(_scope) == null) {
      final d = authority.initializeDisabled(_scope, now: _time(0));
      authority.provisionInitialOwner(
        _scope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: d.epoch,
        evidence: _evidence,
        now: _time(1),
      );
    }
    snap = authority.read(_scope)!;
    journal = CloudSyncReceivedArchiveJournal(
      store: store,
      authority: authority,
      authoritySnapshot: snap,
    );
  }

  setUp(() async {
    tempRoot = await Directory(
      '${Directory.current.path}/build/test-temp',
    ).create(recursive: true);
    directory = await tempRoot.createTemp('recv-journal-');
    store = await openStore(directory: directory.path);
    provision();
    remote = Handle(
      address: 'remote@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'remote@example.com/iMessage',
    );
    remote.originalROWID = 9001;
    chat = Chat(
      guid: 'iMessage;-;remote@example.com',
      chatIdentifier: 'remote@example.com',
      usingHandle: 'mailto:owner@example.com',
      isRpSms: false,
      style: 45,
      participants: [remote],
    );
    chat.handles.add(remote);
    store.box<Handle>().put(remote);
    store.box<Chat>().put(chat);
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      expect(directory.parent.absolute.path, tempRoot.absolute.path);
      await directory.delete(recursive: true);
    }
  });
  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    provision();
  }

  Message? _byGuid(String guid) {
    final q = store.box<Message>().query(Message_.guid.equals(guid)).build();
    try {
      return q.findFirst();
    } finally {
      q.close();
    }
  }

  test(
    'genuinely unpersisted first save adopts and reopens idempotently',
    () async {
      const guid = 'recv-guid-1001';
      const text = 'hello one';
      expect(_byGuid(guid), isNull);
      final src = _staged(guid, text, chat);
      final wire = _wire(
        id: guid,
        text: text,
        sentAt: _time(2).millisecondsSinceEpoch,
      );
      final fresh = _fresh(guid, text, chat);
      final first = journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(fresh),
        localChatId: chat.id!,
        source: src,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(3),
      );
      expect(first, greaterThan(0));
      expect(_byGuid(guid)!.id, fresh.id);
      final again = journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(fresh),
        localChatId: chat.id!,
        source: src,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(4),
      );
      expect(again, first);
      expect(
        journal
            .readProtectedSource(intentId: first, currentAuth: _auth(Object()))
            .encode(),
        src.encode(),
      );
      await reopen();
      expect(
        journal
            .readProtectedSource(intentId: first, currentAuth: _auth(Object()))
            .encode(),
        src.encode(),
      );
      final reopenedPage = journal.readReadyPage(currentAuth: _auth(Object()));
      expect(reopenedPage.ready, hasLength(1));
      expect(reopenedPage.exhausted, isTrue);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );
  test('read page does not consume a valid row beyond its ready limit', () {
    for (var i = 0; i < 4; i++) {
      final guid = 'page-boundary-$i';
      final message = _fresh(guid, 'hello', chat);
      journal.saveReceivedCapture(
        wire: _wire(
          id: guid,
          text: 'hello',
          sentAt: _time(2).millisecondsSinceEpoch,
        ),
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(message),
        localChatId: chat.id!,
        source: _staged(guid, 'hello', chat),
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(3 + i),
      );
      if (i == 0) {
        message.dateDeleted = _time(12);
        store.box<Message>().put(message);
      }
    }
    // A deleted first row makes the first query page only partly ready.
    // The next page fills the limit before its own final row is visited.
    final first = journal.readReadyPage(limit: 2, currentAuth: _auth(Object()));
    final second = journal.readReadyPage(
      limit: 2,
      currentAuth: _auth(Object()),
      cursor: first.nextCursor,
    );
    expect(first.ready, hasLength(2));
    expect(second.ready, hasLength(1));
    expect({
      ...first.ready.map((r) => r.id),
      ...second.ready.map((r) => r.id),
    }, hasLength(3));
  });

  test('auth changed during persistence rolls back both rows', () {
    var current = true;
    final message = _fresh('auth-drift', 'hello', chat);
    expect(
      () => journal.saveReceivedCapture(
        wire: _wire(
          id: 'auth-drift',
          text: 'hello',
          sentAt: _time(2).millisecondsSinceEpoch,
        ),
        liveContext: _live,
        persistMessage: () {
          final id = store.box<Message>().put(message);
          current = false;
          return id;
        },
        localChatId: chat.id!,
        source: _staged('auth-drift', 'hello', chat),
        capturedAuth: _auth(Object()),
        stillCurrent: () => current,
        now: _time(3),
      ),
      throwsA(_fails('cloud_sync_received_archive_identity_changed')),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
  });

  test(
    'lost native commit response retains exact received lease across reopen',
    () async {
      const guid = 'lease-recovery';
      final source = _staged(guid, 'hello', chat);
      final wire = _wire(
        id: guid,
        text: 'hello',
        sentAt: _time(2).millisecondsSinceEpoch,
      );
      final transport = _ReceivedLeaseTransport()..failCommit = true;
      final identity = _auth(Object());
      var stages = 0;
      CloudSyncReceivedArchiveStaging flow() => CloudSyncReceivedArchiveStaging(
        journal: journal,
        transport: transport,
        capturedIdentity: identity,
        validateCurrentIdentity: () async {},
        stillCurrent: () => true,
      );
      Future<int> run() => flow().persist(
        wire: wire,
        liveContext: _live,
        localChatId: chat.id!,
        persistMessage: () => store.box<Message>().put(
          _byGuid(guid) ?? _fresh(guid, 'hello', chat),
        ),
        stageNative: () async {
          stages++;
          return source;
        },
        clock: () => _time(3),
      );
      await expectLater(run(), throwsStateError);
      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 1);
      expect(transport.rolledBack, isEmpty);
      final chatId = chat.id!;
      await reopen();
      chat = store.box<Chat>().get(chatId)!;
      transport.failCommit = false;
      expect(await run(), greaterThan(0));
      expect(stages, 1);
      expect(transport.committed, [
        source.leaseReference,
        source.leaseReference,
      ]);
      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test('an own-send echo is rejected before received persistence', () {
    const guid = 'own-send-echo';
    expect(journal.hasOutgoingOrigin(guid), isFalse);
    store.box<CloudSyncLocalSendIntentEntity>().put(
      CloudSyncLocalSendIntentEntity(
        intentKey: 'own-send-echo',
        accountFingerprint: _account,
        writerEpoch: snap.epoch,
        localMessageId: 987,
        messageGuidHash: CloudSyncReceivedArchiveJournal.localSendGuidHashFor(
          guid,
        ),
        sourceSha256: _h64('b'),
        createdAtMs: 1,
        updatedAtMs: 1,
      ),
    );
    expect(journal.hasOutgoingOrigin(guid), isTrue);
    var persisted = false;
    expect(
      () => journal.saveReceivedCapture(
        wire: _wire(
          id: guid,
          text: 'hello',
          sentAt: _time(2).millisecondsSinceEpoch,
        ),
        liveContext: _live,
        localChatId: chat.id!,
        persistMessage: () {
          persisted = true;
          return 987;
        },
        source: _staged(guid, 'hello', chat),
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(3),
      ),
      throwsA(_fails('cloud_sync_received_archive_outgoing_overlap')),
    );
    expect(persisted, isFalse);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  test(
    'sealed source and Message commit together; restart retries original seed',
    () async {
      const guid = 'sealed-retry';
      final staged = _staged(guid, 'original', chat);
      final seed = CloudSyncReceivedArchiveSourceBinding.sealed(
        accountFingerprint: staged.accountFingerprint,
        protectedStoreIdentity: staged.protectedStoreIdentity,
        messageGuidHash: staged.messageGuidHash,
        sourceSha256: staged.sourceSha256,
        ciphertext: 'obcs2.test.U3ludGhldGlj',
      );
      final wire = _wire(
        id: guid,
        text: 'original',
        sentAt: _time(2).millisecondsSinceEpoch,
      );
      final auth = _auth(Object());
      var sealed = 0;
      Future<int> capture() => CloudSyncReceivedArchiveStaging.persistSealed(
        journal: journal,
        capturedIdentity: auth,
        validateCurrentIdentity: () async {},
        stillCurrent: () => true,
        wire: wire,
        liveContext: _live,
        localChatId: chat.id!,
        persistMessage: () => store.box<Message>().put(
          _byGuid(guid) ?? _fresh(guid, 'original', chat),
        ),
        sealNative: () async {
          sealed++;
          return seed;
        },
        clock: () => _time(3),
      );
      final id = await capture();
      expect(store.box<Message>().count(), 1);
      expect(
        journal.readLiveReceivedArchiveLeaseReferences(maximumCount: 10),
        isEmpty,
      );
      expect(
        journal.readLiveReceivedArchiveReferences(maximumCount: 10),
        isEmpty,
      );
      final chatId = chat.id!;
      await reopen();
      chat = store.box<Chat>().get(chatId)!;
      expect(await capture(), id);
      expect(sealed, 1);
      expect(journal.readReadyPage(currentAuth: auth).ready.single.id, id);
      final transport = _ReceivedLeaseTransport();
      CloudSyncReceivedArchiveStaging flow() => CloudSyncReceivedArchiveStaging(
        journal: journal,
        transport: transport,
        capturedIdentity: auth,
        validateCurrentIdentity: () async {},
        stillCurrent: () => true,
      );
      await expectLater(
        flow().materialize(
          intentId: id,
          stageSeedNative: (_) async {
            throw StateError('disk unavailable');
          },
        ),
        throwsStateError,
      );
      expect(
        journal.readProtectedSource(intentId: id, currentAuth: auth).encode(),
        seed.encode(),
      );
      transport.failCommit = true;
      var stages = 0;
      Future<CloudSyncReceivedArchiveSourceBinding> materialize() =>
          flow().materialize(
            intentId: id,
            stageSeedNative: (original) async {
              expect(original.encode(), seed.encode());
              stages++;
              return staged;
            },
          );
      await expectLater(materialize(), throwsStateError);
      expect(
        journal.readProtectedSource(intentId: id, currentAuth: auth).encode(),
        staged.encode(),
      );
      expect(transport.rolledBack, isEmpty);
      await reopen();
      transport.failCommit = false;
      expect((await materialize()).encode(), staged.encode());
      expect(stages, 1);
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 1);
      expect(
        store.box<CloudSyncReceivedArchiveIntentEntity>().get(id)!.state,
        1,
      );
      expect(
        journal
            .readReadyPage(currentAuth: auth, onlyPendingMaterialization: true)
            .ready,
        isEmpty,
      );
      expect(journal.readReadyPage(currentAuth: auth).ready.single.id, id);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'seed materialization mismatch rolls back only the unadopted stage',
    () async {
      const guid = 'seed-drift';
      final staged = _staged(guid, 'original', chat);
      final seed = CloudSyncReceivedArchiveSourceBinding.sealed(
        accountFingerprint: staged.accountFingerprint,
        protectedStoreIdentity: staged.protectedStoreIdentity,
        messageGuidHash: staged.messageGuidHash,
        sourceSha256: staged.sourceSha256,
        ciphertext: 'obcs2.test.U3ludGhldGlj',
      );
      final auth = _auth(Object());
      final id = await CloudSyncReceivedArchiveStaging.persistSealed(
        journal: journal,
        capturedIdentity: auth,
        validateCurrentIdentity: () async {},
        stillCurrent: () => true,
        wire: _wire(
          id: guid,
          text: 'original',
          sentAt: _time(2).millisecondsSinceEpoch,
        ),
        liveContext: _live,
        localChatId: chat.id!,
        persistMessage: () =>
            store.box<Message>().put(_fresh(guid, 'original', chat)),
        sealNative: () async => seed,
        clock: () => _time(3),
      );
      final transport = _ReceivedLeaseTransport();
      final changed = _staged(guid, 'different', chat);
      await expectLater(
        CloudSyncReceivedArchiveStaging(
          journal: journal,
          transport: transport,
          capturedIdentity: auth,
          validateCurrentIdentity: () async {},
          stillCurrent: () => true,
        ).materialize(intentId: id, stageSeedNative: (_) async => changed),
        throwsStateError,
      );
      expect(transport.rolledBack, [changed.leaseReference]);
      expect(
        journal.readProtectedSource(intentId: id, currentAuth: auth).encode(),
        seed.encode(),
      );
    },
  );

  test(
    'source mismatch before durable adoption rolls back only fresh lease',
    () async {
      final source = _staged('mismatch', 'hello', chat);
      final transport = _ReceivedLeaseTransport();
      final flow = CloudSyncReceivedArchiveStaging(
        journal: journal,
        transport: transport,
        capturedIdentity: _auth(Object()),
        validateCurrentIdentity: () async {},
        stillCurrent: () => true,
      );
      await expectLater(
        flow.persist(
          wire: _wire(
            id: 'mismatch',
            text: 'hello',
            sentAt: _time(2).millisecondsSinceEpoch,
          ),
          liveContext: _live,
          localChatId: chat.id!,
          persistMessage: () =>
              store.box<Message>().put(_fresh('mismatch', 'different', chat)),
          stageNative: () async => source,
          clock: () => _time(3),
        ),
        throwsStateError,
      );
      expect(transport.rolledBack, [source.leaseReference]);
      expect(transport.committed, isEmpty);
      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
    },
  );

  test(
    'identity loss after commit never rolls back an adopted source',
    () async {
      final source = _staged('after-commit', 'hello', chat);
      final transport = _ReceivedLeaseTransport();
      var validations = 0;
      final flow = CloudSyncReceivedArchiveStaging(
        journal: journal,
        transport: transport,
        capturedIdentity: _auth(Object()),
        validateCurrentIdentity: () async {
          if (++validations == 3) throw StateError('identity changed');
        },
        stillCurrent: () => true,
      );
      await expectLater(
        flow.persist(
          wire: _wire(
            id: 'after-commit',
            text: 'hello',
            sentAt: _time(2).millisecondsSinceEpoch,
          ),
          liveContext: _live,
          localChatId: chat.id!,
          persistMessage: () =>
              store.box<Message>().put(_fresh('after-commit', 'hello', chat)),
          stageNative: () async => source,
          clock: () => _time(3),
        ),
        throwsStateError,
      );
      expect(transport.rolledBack, isEmpty);
      expect(transport.committed, [source.leaseReference]);
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test('worker high-watermark bounds a round while new receives arrive', () {
    int add(String guid) => journal.saveReceivedCapture(
      wire: _wire(
        id: guid,
        text: 'hello',
        sentAt: _time(2).millisecondsSinceEpoch,
      ),
      liveContext: _live,
      localChatId: chat.id!,
      persistMessage: () =>
          store.box<Message>().put(_fresh(guid, 'hello', chat)),
      source: _staged(guid, 'hello', chat),
      capturedAuth: _auth(Object()),
      stillCurrent: () => true,
      now: _time(3),
    );
    final first = add('before-round');
    final ceiling = journal.captureReadHighWatermark();
    final second = add('during-round');
    final bounded = journal.readReadyPage(
      currentAuth: _auth(Object()),
      maximumIntentId: ceiling,
      onlyPendingMaterialization: true,
    );
    expect(bounded.ready.map((row) => row.id), [first]);
    expect(bounded.exhausted, isTrue);
    expect(journal.captureReadHighWatermark(), second);
    expect(
      journal.readReadyPage(currentAuth: _auth(Object())).ready,
      hasLength(2),
    );
  });

  for (final disposition in CloudSyncReceivedRecordState.values) {
    test(
      'exact record observation retains evidence across restart: ${disposition.name}',
      () async {
        const guid = 'observed-original';
        final source = _staged(guid, 'original', chat);
        final auth = _auth(Object());
        final id = journal.saveReceivedCapture(
          wire: _wire(
            id: guid,
            text: 'original',
            sentAt: _time(2).millisecondsSinceEpoch,
          ),
          liveContext: _live,
          localChatId: chat.id!,
          persistMessage: () =>
              store.box<Message>().put(_fresh(guid, 'original', chat)),
          source: source,
          capturedAuth: auth,
          stillCurrent: () => true,
          now: _time(3),
        );
        journal.markSourceMaterialized(
          intentId: id,
          source: source,
          currentAuth: auth,
          stillCurrent: () => true,
        );
        final found = disposition.index < 3;
        final observation = CloudSyncReceivedRecordObservation(
          state: disposition,
          accountFingerprint: _account,
          protectedStoreIdentity: _storeId,
          messageGuidHash: source.messageGuidHash,
          sourceSha256: source.sourceSha256,
          logicalEntityKeyHash: _a43('L'),
          serverRecordIdHash: _a43('R'),
          generation: 3,
          parentBinding: 'synthetic-parent',
          observedAtMs: 4,
          etagHash: found ? _a43('E') : null,
          rawReference: found ? 'obcs2.ref.${_a43('W')}' : null,
          rawLeaseReference: found ? _lease('f') : null,
        );
        final transport = _ReceivedLeaseTransport()..failCommit = found;
        var prepares = 0;
        var stages = 0;
        Future<CloudSyncReceivedRecordObservation> run() =>
            CloudSyncReceivedInspectionCoordinator(
              journal: journal,
              transport: transport,
              auth: auth,
              validate: () async {},
              stillCurrent: () => true,
            ).inspect<int>(
              intentId: id,
              expectedGeneration: 3,
              expectedParentBinding: 'synthetic-parent',
              validateParent: () {},
              prepareNative: (_) async {
                prepares++;
                // Network/read-only phase: outer held, local lease free so
                // competing maintenance is not blocked by a mere read.
                expect(transport.outerHeld, isTrue);
                expect(transport.localHeld, isFalse);
                return 7;
              },
              stageNative: (_) async {
                stages++;
                expect(transport.outerHeld, isTrue);
                expect(transport.localHeld, isTrue);
                return observation;
              },
            );
        if (found) {
          await expectLater(run(), throwsStateError);
          // Lost commit after adoption: exactly one prepare and one stage.
          expect(prepares, 1);
          expect(stages, 1);
          // Match the production inspection worker's selector. A durable
          // observation is not completion until its raw lease is committed.
          expect(
            journal.readReadyPage(currentAuth: auth).ready.map((row) => row.id),
            contains(id),
          );
        } else {
          expect((await run()).state, disposition);
          expect(prepares, 1);
          expect(stages, 1);
        }
        expect(transport.rolledBack, isEmpty);
        final retained = journal.readRecordObservation(
          intentId: id,
          currentAuth: auth,
        );
        if (disposition == CloudSyncReceivedRecordState.unresolved) {
          expect(retained, isNull);
          expect(journal.readReadyPage(currentAuth: auth).ready, hasLength(1));
          expect(store.box<CloudOutboxOperationEntity>().count(), 0);
          return;
        }
        expect(retained!.encode(), observation.encode());
        final chatId = chat.id!;
        await reopen();
        chat = store.box<Chat>().get(chatId)!;
        transport.failCommit = false;
        expect((await run()).encode(), observation.encode());
        // Existing observation skips both callbacks and recommits the raw
        // lease under the local lease after a lost commit response.
        expect(prepares, 1);
        expect(stages, 1);
        if (found) {
          // Failed first attempt plus retry recommit, both under local.
          expect(transport.committed, [_lease('f'), _lease('f')]);
          expect(transport.commitSawLocalHeld, [true, true]);
        } else {
          expect(transport.committed, isEmpty);
        }
        expect(journal.readReadyPage(currentAuth: auth).ready, isEmpty);
        expect(store.box<CloudSyncReceivedArchiveIntentEntity>().get(id)!.state, 2);
        journal.markSourceMaterialized(intentId: id, source: source,
          currentAuth: auth, stillCurrent: () => true);
        expect(store.box<CloudSyncReceivedArchiveIntentEntity>().get(id)!.state, 2);
        final refs = journal.readLiveReceivedArchiveReferences(
          maximumCount: 10,
        );
        expect(refs, contains(source.protectedReference));
        if (found) expect(refs, contains(observation.rawReference));
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );
  }

  for (final failure in ['identity', 'generation', 'parent']) {
    test(
      'lookup $failure drift rolls back only unowned raw evidence',
      () async {
        const guid = 'read-drift';
        final source = _staged(guid, 'original', chat);
        final auth = _auth(Object());
        final id = journal.saveReceivedCapture(
          wire: _wire(
            id: guid,
            text: 'original',
            sentAt: _time(2).millisecondsSinceEpoch,
          ),
          liveContext: _live,
          localChatId: chat.id!,
          persistMessage: () =>
              store.box<Message>().put(_fresh(guid, 'original', chat)),
          source: source,
          capturedAuth: auth,
          stillCurrent: () => true,
          now: _time(3),
        );
        journal.markSourceMaterialized(
          intentId: id,
          source: source,
          currentAuth: auth,
          stillCurrent: () => true,
        );
        final transport = _ReceivedLeaseTransport();
        var prepares = 0;
        var stages = 0;
        final result = CloudSyncReceivedRecordObservation(
          state: CloudSyncReceivedRecordState.equivalent,
          accountFingerprint: _account,
          protectedStoreIdentity: _storeId,
          messageGuidHash: source.messageGuidHash,
          sourceSha256: source.sourceSha256,
          logicalEntityKeyHash: _a43('L'),
          serverRecordIdHash: _a43('R'),
          generation: failure == 'generation' ? 4 : 3,
          parentBinding: 'parent-proof',
          observedAtMs: 4,
          etagHash: _a43('E'),
          rawReference: 'obcs2.ref.${_a43('W')}',
          rawLeaseReference: _lease('f'),
        );
        await expectLater(
          CloudSyncReceivedInspectionCoordinator(
            journal: journal,
            transport: transport,
            auth: auth,
            stillCurrent: () => true,
            validate: () async {
              // Identity is revalidated after prepare but before stage: a
              // change there must never reach staging or the journal. The
              // entry check still passes so prepare runs exactly once.
              if (failure == 'identity' && prepares > 0) {
                throw StateError('identity changed');
              }
            },
          ).inspect<int>(
            intentId: id,
            expectedGeneration: 3,
            expectedParentBinding: 'parent-proof',
            prepareNative: (_) async {
              prepares++;
              return 7;
            },
            stageNative: (_) async {
              stages++;
              return result;
            },
            validateParent: () {
              if (failure == 'parent') throw StateError('parent changed');
            },
          ),
          throwsStateError,
        );
        expect(prepares, 1);
        // Identity and parent drift fail before staging: no raw lease
        // exists, so no rollback is expected. Generation drift is detected
        // after staging, so the unowned raw lease must roll back.
        if (failure == 'generation') {
          expect(stages, 1);
          expect(transport.rolledBack, [_lease('f')]);
        } else {
          expect(stages, 0);
          expect(transport.rolledBack, isEmpty);
        }
        expect(
          journal.readRecordObservation(intentId: id, currentAuth: auth),
          isNull,
        );
        expect(transport.committed, isEmpty);
        expect(
          journal.readProtectedSource(intentId: id, currentAuth: auth).encode(),
          source.encode(),
        );
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );
  }

  test('recovery identity mismatch is rejected before native work', () async {
    const guid = 'identity-fence';
    final source = _staged(guid, 'original', chat);
    final auth = _auth(Object());
    final id = journal.saveReceivedCapture(
      wire: _wire(id: guid, text: 'original', sentAt: _time(2).millisecondsSinceEpoch),
      liveContext: _live,
      localChatId: chat.id!,
      persistMessage: () =>
          store.box<Message>().put(_fresh(guid, 'original', chat)),
      source: source,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(3),
    );
    journal.markSourceMaterialized(
      intentId: id,
      source: source,
      currentAuth: auth,
      stillCurrent: () => true,
    );
    final transport = _ReceivedLeaseTransport()
      ..identityOverride = 'obcs2.store.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX';
    var prepares = 0;
    var stages = 0;
    await expectLater(
      CloudSyncReceivedInspectionCoordinator(
        journal: journal,
        transport: transport,
        auth: auth,
        validate: () async {},
        stillCurrent: () => true,
      ).inspect<int>(
        intentId: id,
        expectedGeneration: 3,
        expectedParentBinding: 'synthetic-parent',
        validateParent: () {},
        prepareNative: (_) async {
          prepares++;
          return 7;
        },
        stageNative: (_) async {
          stages++;
          throw StateError('must not stage on identity mismatch');
        },
      ),
      throwsStateError,
    );
    expect(prepares, 0);
    expect(stages, 0);
    expect(
      journal.readRecordObservation(intentId: id, currentAuth: auth),
      isNull,
    );
    expect(transport.committed, isEmpty);
    expect(transport.rolledBack, isEmpty);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  test('transport without local lifecycle is rejected before native work',
      () async {
    const guid = 'no-local-lease';
    final source = _staged(guid, 'original', chat);
    final auth = _auth(Object());
    final id = journal.saveReceivedCapture(
      wire: _wire(id: guid, text: 'original', sentAt: _time(2).millisecondsSinceEpoch),
      liveContext: _live,
      localChatId: chat.id!,
      persistMessage: () =>
          store.box<Message>().put(_fresh(guid, 'original', chat)),
      source: source,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(3),
    );
    journal.markSourceMaterialized(
      intentId: id,
      source: source,
      currentAuth: auth,
      stillCurrent: () => true,
    );
    final transport = _OuterOnlyTransport();
    var prepares = 0;
    var stages = 0;
    await expectLater(
      CloudSyncReceivedInspectionCoordinator(
        journal: journal,
        transport: transport,
        auth: auth,
        validate: () async {},
        stillCurrent: () => true,
      ).inspect<int>(
        intentId: id,
        expectedGeneration: 3,
        expectedParentBinding: 'synthetic-parent',
        validateParent: () {},
        prepareNative: (_) async {
          prepares++;
          return 7;
        },
        stageNative: (_) async {
          stages++;
          throw StateError('must not stage without local lease');
        },
      ),
      throwsStateError,
    );
    expect(prepares, 0);
    expect(stages, 0);
    expect(
      journal.readRecordObservation(intentId: id, currentAuth: auth),
      isNull,
    );
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  test('prepare yields without local lease while stage holds it', () async {
    const guid = 'two-phase-lease';
    final source = _staged(guid, 'original', chat);
    final auth = _auth(Object());
    final id = journal.saveReceivedCapture(
      wire: _wire(id: guid, text: 'original', sentAt: _time(2).millisecondsSinceEpoch),
      liveContext: _live,
      localChatId: chat.id!,
      persistMessage: () =>
          store.box<Message>().put(_fresh(guid, 'original', chat)),
      source: source,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(3),
    );
    journal.markSourceMaterialized(
      intentId: id,
      source: source,
      currentAuth: auth,
      stillCurrent: () => true,
    );
    final observation = CloudSyncReceivedRecordObservation(
      state: CloudSyncReceivedRecordState.equivalent,
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      messageGuidHash: source.messageGuidHash,
      sourceSha256: source.sourceSha256,
      logicalEntityKeyHash: _a43('L'),
      serverRecordIdHash: _a43('R'),
      generation: 3,
      parentBinding: 'two-phase-parent',
      observedAtMs: 4,
      etagHash: _a43('E'),
      rawReference: 'obcs2.ref.${_a43('W')}',
      rawLeaseReference: _lease('f'),
    );
    final transport = _ReceivedLeaseTransport();
    var prepares = 0;
    var stages = 0;
    var probeRanDuringPrepare = false;
    var contentionSeenDuringStage = false;
    final result =
        await CloudSyncReceivedInspectionCoordinator(
          journal: journal,
          transport: transport,
          auth: auth,
          validate: () async {},
          stillCurrent: () => true,
        ).inspect<int>(
          intentId: id,
          expectedGeneration: 3,
          expectedParentBinding: 'two-phase-parent',
          validateParent: () {},
          prepareNative: (_) async {
            prepares++;
            expect(transport.outerHeld, isTrue);
            expect(transport.localHeld, isFalse);
            await transport.runLocalProtectedStoreExclusive(() async {
              probeRanDuringPrepare = true;
            });
            return 7;
          },
          stageNative: (_) async {
            stages++;
            expect(transport.outerHeld, isTrue);
            expect(transport.localHeld, isTrue);
            await expectLater(
              transport.runLocalProtectedStoreExclusive(() async {}),
              throwsStateError,
            );
            contentionSeenDuringStage = true;
            return observation;
          },
        );
    expect(result.encode(), observation.encode());
    expect(prepares, 1);
    expect(stages, 1);
    expect(probeRanDuringPrepare, isTrue);
    expect(contentionSeenDuringStage, isTrue);
    expect(transport.committed, [_lease('f')]);
    expect(transport.commitSawLocalHeld, [true]);
    expect(transport.rolledBack, isEmpty);
    expect(
      store.box<CloudSyncReceivedArchiveIntentEntity>().get(id)!.state,
      2,
    );
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  group('received create admission', () {
    late ObjectBoxCloudSyncStore durable;
    late CloudSyncNativeAuthSnapshot auth;
    late int intentId;
    late CloudSyncReceivedArchiveSourceBinding originalSource;
    late CloudSyncReceivedRecordObservation observation;
    const guid = 'received-create-original';

    CloudSyncScope scopeFor(String zone) => CloudSyncScope(
      accountFingerprint: _account,
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: zone,
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final scope = scopeFor('messageManateeZone');

    ObjectBoxCloudSyncStore bindDurable() => ObjectBoxCloudSyncStore(
      store: store,
      protector: _ReceivedTestProtector(),
      receivedArchiveJournal: journal,
      clock: () => _time(4),
    );

    Future<void> completeAccount(ObjectBoxCloudSyncStore target) async {
      for (final zone in const [
        'chatManateeZone',
        'messageManateeZone',
        'attachmentManateeZone',
      ]) {
        await target.recordPullSuccess(scopeFor(zone), now: _time(1));
      }
    }

    setUp(() async {
      auth = _auth(Object());
      durable = bindDurable();
      await completeAccount(durable);
      final chatScope = scopeFor('chatManateeZone');
      final applied = await seedSyntheticRestoredChatAppliedSource(
        objectBox: store,
        store: durable,
        chatScope: chatScope,
        now: _time(1),
      );
      await seedSyntheticRestoredChatProof(
        objectBox: store,
        store: durable,
        chatScope: chatScope,
        chat: chat,
        appliedSource: applied,
        now: _time(1),
      );
    });

    Future<void> seedOrigin({
      CloudSyncReceivedRecordState disposition =
          CloudSyncReceivedRecordState.absent,
      String messageGuid = guid,
      String logicalMarker = 'L',
      String recordMarker = 'M',
    }) async {
      originalSource = _staged(messageGuid, 'original', chat);
      intentId = journal.saveReceivedCapture(
        wire: _wire(
          id: messageGuid,
          text: 'original',
          sentAt: _time(2).millisecondsSinceEpoch,
        ),
        liveContext: _live,
        localChatId: chat.id!,
        persistMessage: () =>
            store.box<Message>().put(_fresh(messageGuid, 'original', chat)),
        source: originalSource,
        capturedAuth: auth,
        stillCurrent: () => true,
        now: _time(3),
      );
      journal.markSourceMaterialized(
        intentId: intentId,
        source: originalSource,
        currentAuth: auth,
        stillCurrent: () => true,
      );
      final found = const {
        CloudSyncReceivedRecordState.equivalent,
        CloudSyncReceivedRecordState.needsProjection,
        CloudSyncReceivedRecordState.conflictingIdentity,
      }.contains(disposition);
      observation = CloudSyncReceivedRecordObservation(
        state: disposition,
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        messageGuidHash: originalSource.messageGuidHash,
        sourceSha256: originalSource.sourceSha256,
        logicalEntityKeyHash: _a43(logicalMarker),
        serverRecordIdHash: _a43(recordMarker),
        generation: (await durable.readCheckpoint(scope)).generation,
        parentBinding: requireCloudSyncRestoredDirectChat(
          store: store,
          messageScope: scope,
          message: _byGuid(messageGuid)!,
        ),
        observedAtMs: _time(4).millisecondsSinceEpoch,
        etagHash: found ? _a43('E') : null,
        rawReference: found ? 'obcs2.ref.${_a43('W')}' : null,
        rawLeaseReference: found ? _lease('f') : null,
      );
      await CloudSyncReceivedInspectionCoordinator(
        journal: journal,
        transport: _ReceivedLeaseTransport(),
        auth: auth,
        validate: () async {},
        stillCurrent: () => true,
      ).inspect<int>(
        intentId: intentId,
        prepareNative: (_) async => 7,
        stageNative: (_) async => observation,
        validateParent: () {},
        expectedGeneration: observation.generation,
        expectedParentBinding: observation.parentBinding,
      );
    }

    CloudSyncReceivedArchiveIntentEntity intent() =>
        store.box<CloudSyncReceivedArchiveIntentEntity>().get(intentId)!;

    CloudSyncReceivedArchiveAdmissionSource admissionSource() =>
        journal.readForCreateAdmission(intentId: intentId, currentAuth: auth);

    CloudOutboxDraft draft({String? recordHash}) => CloudOutboxDraft(
      scope: scope,
      logicalEntityKeyHash: observation.logicalEntityKeyHash,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncOutboundPayloadVersion,
      dependencyOperationIds: const {},
      createdAt: _time(3),
      encryptedPayloadReference: 'obcs2.ref.${_a43('V')}',
      payloadSha256: _h64('c'),
      serverRecordIdHash: recordHash ?? observation.serverRecordIdHash,
      protectedLeaseReference: _lease('d'),
    );

    CloudRecordMapEntry mapping(CloudOutboxDraft value) => CloudRecordMapEntry(
      scope: value.scope,
      logicalEntityKeyHash: value.logicalEntityKeyHash,
      serverRecordIdHash: value.serverRecordIdHash!,
      encryptedServerRecordId: value.encryptedPayloadReference!,
      updatedAt: value.createdAt,
    );

    CloudOutboxOperation admit({
      CloudSyncReceivedArchiveAdmissionSource? source,
      CloudOutboxDraft? value,
      CloudSyncNativeAuthSnapshot? currentAuth,
      bool Function()? stillCurrent,
    }) {
      final candidate = value ?? draft();
      return durable.admitProtectedReceivedCreate(
        draft: candidate,
        recordMapping: mapping(candidate),
        journal: journal,
        source: source ?? admissionSource(),
        currentAuth: currentAuth ?? auth,
        stillCurrent: stillCurrent ?? () => true,
      );
    }

    void expectUnadopted() {
      expect(intent().state, 2);
      expect(intent().admittedOperationId, isNull);
      expect(intent().admittedBinding, isNull);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(recordMapCountForZone(store, scope.zone), 0);
      expect(recordMapCountForZone(store, 'chatManateeZone'), 1);
    }

    void addOutgoingOverlap({required bool byGuid}) {
      store.box<CloudSyncLocalSendIntentEntity>().put(
        CloudSyncLocalSendIntentEntity(
          intentKey: 'received-create-outgoing-overlap',
          accountFingerprint: _account,
          writerEpoch: snap.epoch,
          localMessageId: intent().localMessageId + (byGuid ? 999 : 0),
          messageGuidHash: byGuid
              ? CloudSyncReceivedArchiveJournal.localSendGuidHashFor(guid)
              : _h64('e'),
          sourceSha256: _h64('a'),
          createdAtMs: _time(3).millisecondsSinceEpoch,
          updatedAtMs: _time(3).millisecondsSinceEpoch,
        ),
      );
    }

    test('atomically owns source and outbox without forging local send success',
        () async {
      await seedOrigin();
      final received = _byGuid(guid)!..dateRead = _time(5);
      store.box<Message>().put(received);
      final source = admissionSource();
      final operation = admit(source: source);
      expect(operation.operationId, CloudOperationIdentity.forInitialCreate(
        scope: scope,
        logicalEntityKeyHash: observation.logicalEntityKeyHash,
        payloadVersion: cloudSyncOutboundPayloadVersion,
      ));
      expect(intent().state, 3);
      expect(intent().admittedOperationId, operation.operationId);
      expect(intent().admittedBinding, isNotEmpty);
      expect(intent().protectedSourceBinding, originalSource.encode());
      expect(intent().recordObservationBinding, observation.encode());
      expect((await durable.readOutboxEntries(scope)).single
          .sameDurableSnapshotAs(operation), isTrue);
      final messageMap = store.box<CloudRecordMapEntity>().getAll()
          .singleWhere((row) => row.zone == scope.zone);
      expect(messageMap.serverRecordIdHash, observation.serverRecordIdHash);
      expect(messageMap.encryptedServerRecordId, draft().encryptedPayloadReference);
      expect(messageMap.generation, observation.generation);
      store.runInTransaction(TxMode.read, () {
        journal.requireAdoptedDispatch(transactionStore: store, operation: operation);
        expect(journal.readAdoptedSource(transactionStore: store, operation: operation)!
            .source.encode(), originalSource.encode());
      });
      final retained = _byGuid(guid)!;
      expect(retained.text, 'original');
      expect(retained.attributedBody.single.string, 'original');
      expect(retained.dateRead?.toUtc(), _time(5));
      expect(retained.dateEdited, isNull);
      expect(retained.isFromMe, isFalse);
      expect(retained.dateCreated?.toUtc(), _time(2));
      expect(retained.sendingServiceId, isNull);
      expect(retained.ckRecordId, isNull);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    });

    for (final afterAdoption in [false, true]) {
      test('rolls back outbox, map and ownership ${afterAdoption ? 'after' : 'before'} journal adoption',
          () async {
        await seedOrigin();
        final source = admissionSource();
        final revision = (await durable.readCheckpoint(scope)).mutationRevisionCounter;
        var sawTentativeWrites = false;
        if (afterAdoption) {
          // ObjectBox rejects Never-returning callbacks before opening a
          // transaction. Explicit void makes the injected abort run only
          // after the actual outbox, map and ownership writes below.
          void abortAfterAdoption() {
            admit(source: source);
            expect(intent().state, 3);
            expect(store.box<CloudOutboxOperationEntity>().count(), 1);
            expect(recordMapCountForZone(store, scope.zone), 1);
            sawTentativeWrites = true;
            throw StateError('abort caller transaction');
          }
          expect(() => store.runInTransaction<void>(
            TxMode.write, abortAfterAdoption,
          ), throwsA(_fails('abort caller transaction')));
        } else {
          expect(() => admit(source: source, stillCurrent: () {
            if (store.box<CloudOutboxOperationEntity>().count() == 1) {
              expect(recordMapCountForZone(store, scope.zone), 1);
              expect(intent().state, 2);
              sawTentativeWrites = true;
              return false;
            }
            return true;
          }), throwsA(_fails('cloud_sync_received_archive_admission_changed')));
        }
        expect(sawTentativeWrites, isTrue);
        expectUnadopted();
        expect(intent().protectedSourceBinding, originalSource.encode());
        expect(intent().recordObservationBinding, observation.encode());
        expect((await durable.readCheckpoint(scope)).mutationRevisionCounter, revision);
        // The same protected envelope remains usable after rollback; no new
        // operation identity or source is needed to recover this local failure.
        final operation = admit(source: source);
        expect(operation.mutationRevision, revision + 1);
        expect(intent().admittedOperationId, operation.operationId);
      });
    }

    test('rejects ownership adoption through a different Store', () async {
      await seedOrigin();
      final source = admissionSource();
      final other = await openStore(directory: '${directory.path}/other-store');
      try {
        expect(() => ObjectBoxCloudSyncStore(
          store: other,
          protector: _ReceivedTestProtector(),
          receivedArchiveJournal: journal,
        ), throwsA(_fails('cloud_sync_received_archive_admission_changed')));
        final otherAuthority = ObjectBoxCloudKitWriterAuthority.forTest(
          store: other,
          buildDecision: CloudKitWriterOwnership.resolve('v2'),
        );
        final disabled = otherAuthority.initializeDisabled(_scope, now: _time(0));
        final otherOwner = otherAuthority.provisionInitialOwner(
          _scope,
          owner: CloudKitWriterOwner.v2,
          expectedEpoch: disabled.epoch,
          evidence: _evidence,
          now: _time(1),
        );
        final otherJournal = CloudSyncReceivedArchiveJournal(
          store: other,
          authority: otherAuthority,
          authoritySnapshot: otherOwner,
        );
        final otherDurable = ObjectBoxCloudSyncStore(
          store: other,
          protector: _ReceivedTestProtector(),
          receivedArchiveJournal: otherJournal,
        );
        await completeAccount(otherDurable);
        final value = draft();
        expect(() => otherDurable.admitProtectedReceivedCreate(
          draft: value,
          recordMapping: mapping(value),
          journal: journal,
          source: source,
          currentAuth: auth,
          stillCurrent: () => true,
        ), throwsA(_fails('cloud_sync_received_archive_admission_changed')));
        expect(other.box<CloudOutboxOperationEntity>().count(), 0);
        expect(other.box<CloudRecordMapEntity>().count(), 0);
        expect((await otherDurable.readCheckpoint(scope)).mutationRevisionCounter, 0);
        expectUnadopted();
        expect(intent().protectedSourceBinding, originalSource.encode());
      } finally {
        other.close();
      }
    });

    for (final disposition in [
      CloudSyncReceivedRecordState.equivalent,
      CloudSyncReceivedRecordState.needsProjection,
      CloudSyncReceivedRecordState.conflictingIdentity,
      CloudSyncReceivedRecordState.unresolved,
    ]) {
      test('${disposition.name} never acquires create ownership', () async {
        await seedOrigin(disposition: disposition);
        final before = intent().recordObservationBinding;
        expect(() => admit(), throwsA(_fails('cloud_sync_received_archive_not_absent')));
        expect(intent().state,
            disposition == CloudSyncReceivedRecordState.unresolved ? 1 : 2);
        expect(intent().admittedOperationId, isNull);
        expect(intent().recordObservationBinding, before);
        expect(intent().protectedSourceBinding, originalSource.encode());
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
        expect(recordMapCountForZone(store, scope.zone), 0);
        expect(journal.readCreateCandidates(currentAuth: auth), isEmpty);
        if (observation.rawReference != null) {
          expect(journal.readLiveReceivedArchiveReferences(maximumCount: 10),
              contains(observation.rawReference));
        }
      });
    }

    for (final change in [
      'account', 'protected store', 'source', 'generation', 'parent',
      'outgoing row', 'outgoing GUID', 'record identity', 'edit', 'unsend',
    ]) {
      test('rejects changed $change without consuming source or revision', () async {
        await seedOrigin();
        final source = admissionSource();
        var currentAuth = auth;
        var value = draft();
        Matcher failure = _fails('cloud_sync_received_archive_not_ready');
        switch (change) {
          case 'account':
          case 'protected store':
            currentAuth = CloudSyncNativeAuthSnapshot.fromNative(
              nativeSessionId: auth.nativeSessionId,
              accountFingerprint: change == 'account' ? _a43('B') : _account,
              protectedStoreIdentity: change == 'protected store'
                  ? 'obcs2.store.${_a43('X')}' : _storeId,
              cloudMessagesClient: Object(),
            );
          case 'source':
            final replacement = _staged(guid, 'original', chat, ref: 'Q', lease: 'b');
            final row = intent()..protectedSourceBinding = replacement.encode();
            store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
            failure = _fails('cloud_sync_received_archive_admission_changed');
          case 'generation':
            final row = store.box<CloudSyncCheckpointEntity>().getAll()
                .singleWhere((row) => row.checkpointKey == cloudSyncPersistentScopeKey(scope));
            row.generation++;
            store.box<CloudSyncCheckpointEntity>().put(row);
            failure = _fails('cloud_sync_received_archive_admission_changed');
          case 'parent':
            final row = store.box<CloudRecordMapEntity>().getAll()
                .singleWhere((row) => row.zone == 'chatManateeZone');
            row.etagHash = _a43('X');
            store.box<CloudRecordMapEntity>().put(row);
            failure = isA<CloudSyncFailure>().having((error) => error.safeCode,
                'safeCode', 'cloud_sync_local_send_chat_not_ready');
          case 'outgoing row':
          case 'outgoing GUID':
            addOutgoingOverlap(byGuid: change == 'outgoing GUID');
          case 'record identity':
            value = draft(recordHash: _a43('X'));
            failure = _fails('cloud_sync_received_archive_admission_changed');
          case 'edit':
          case 'unsend':
            final message = _byGuid(guid)!;
            if (change == 'edit') {
              message
                ..text = 'received edit'
                ..attributedBody = [AttributedBody.raw('received edit')]
                ..dateEdited = _time(5);
            } else {
              message.messageSummaryInfo = [
                MessageSummaryInfo.empty()..retractedParts.add(0),
              ];
            }
            store.box<Message>().put(message);
            failure = _fails('cloud_sync_received_archive_admitted_source_changed');
        }
        final bindingBefore = intent().protectedSourceBinding;
        final revision = (await durable.readCheckpoint(scope)).mutationRevisionCounter;
        expect(() => admit(source: source, value: value, currentAuth: currentAuth),
            throwsA(failure));
        expectUnadopted();
        expect(intent().protectedSourceBinding, bindingBefore);
        expect(intent().recordObservationBinding, observation.encode());
        expect((await durable.readCheckpoint(scope)).mutationRevisionCounter, revision);
      });
    }

    test('fresh Found retires cached Absent and survives lost raw commit across reopen',
        () async {
      await seedOrigin();
      final absent = journal.readCreateCandidates(currentAuth: auth).single;
      final originalUpdatedAt = intent().updatedAtMs;
      journal.markReadConsidered(intentId: intentId, now: _time(5));
      expect(intent().updatedAtMs, greaterThan(originalUpdatedAt));
      final found = CloudSyncReceivedRecordObservation(
        state: CloudSyncReceivedRecordState.equivalent,
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        messageGuidHash: originalSource.messageGuidHash,
        sourceSha256: originalSource.sourceSha256,
        logicalEntityKeyHash: observation.logicalEntityKeyHash,
        serverRecordIdHash: observation.serverRecordIdHash,
        generation: observation.generation,
        parentBinding: observation.parentBinding,
        observedAtMs: _time(6).millisecondsSinceEpoch,
        etagHash: _a43('E'),
        rawReference: 'obcs2.ref.${_a43('W')}',
        rawLeaseReference: _lease('f'),
      );
      final transport = _ReceivedLeaseTransport()..failCommit = true;
      await expectLater(transport.runLocalProtectedStoreExclusive(() async {
        journal.replaceAbsenceWithFound(
          expected: absent,
          found: found,
          currentAuth: auth,
          stillCurrent: () => true,
          validateParent: () {},
        );
        await transport.commitProtectedPageLease(found.rawLeaseReference!, {
          found.rawReference!,
        });
      }), throwsA(_fails('synthetic lost commit response')));
      expect(intent().state, 1);
      expect(intent().recordObservationBinding, found.encode());
      expect(journal.readCreateCandidates(currentAuth: auth), isEmpty);
      expect(journal.readReadyPage(currentAuth: auth).ready.single.id, intentId);
      expect(() => admit(source: absent),
          throwsA(_fails('cloud_sync_received_archive_not_absent')));
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      await reopen();
      durable = bindDurable();
      final resumedTransport = _ReceivedLeaseTransport();
      final recovered = await CloudSyncReceivedInspectionCoordinator(
        journal: journal,
        transport: resumedTransport,
        auth: auth,
        validate: () async {},
        stillCurrent: () => true,
      ).inspect<int>(
        intentId: intentId,
        prepareNative: (_) async => fail('retained Found must not re-prepare'),
        stageNative: (_) async => fail('retained Found must not restage'),
        validateParent: () {},
        expectedGeneration: found.generation,
        expectedParentBinding: found.parentBinding,
      );
      expect(recovered.encode(), found.encode());
      expect(resumedTransport.committed, [found.rawLeaseReference]);
      expect(resumedTransport.commitSawLocalHeld, [true]);
      expect(resumedTransport.rolledBack, isEmpty);
      expect(intent().state, 2);
      expect(journal.readCreateCandidates(currentAuth: auth), isEmpty);
      expect(() => journal.replaceAbsenceWithFound(
        expected: absent,
        found: found,
        currentAuth: auth,
        stillCurrent: () => true,
        validateParent: () {},
      ), throwsA(_fails('cloud_sync_received_archive_not_absent')));
      expect(intent().recordObservationBinding, found.encode());
      expect(journal.readLiveReceivedArchiveReferences(maximumCount: 10),
          containsAll([originalSource.protectedReference, found.rawReference]));
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(recordMapCountForZone(store, scope.zone), 0);
    });

    for (final unknown in [false, true]) {
      test('restart preserves exact ${unknown ? 'unknownOutcome' : 'pending'} operation for source readback',
          () async {
        await seedOrigin();
        final source = admissionSource();
        var operation = admit(source: source);
        if (unknown) {
          final leased = await durable.leaseEligibleOutbox(scope,
            now: _time(5), limit: 1, leaseId: 'received-submit',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save});
          expect(leased.single.operationId, operation.operationId);
          operation = (await durable.markOutboxSubmissionStarted(scope,
            leaseId: 'received-submit',
            submissionIdentity: testSubmissionIdentity([operation.operationId]),
            now: _time(6))).single;
          expect(operation.status, CloudOutboxStatus.unknownOutcome);
        }
        // Persisted leases expose their expiry but not the caller's plaintext
        // lease ID, so compare the durable snapshot without that session hint.
        final expected = operation.copyWith(clearLeaseId: true);
        final admittedBinding = intent().admittedBinding;
        final display = _byGuid(guid)!..dateRead = _time(7);
        if (unknown) {
          // A lost remote outcome must still be readable after local deletion.
          display
            ..text = 'edited after admission'
            ..attributedBody = [AttributedBody.raw('edited after admission')]
            ..dateEdited = _time(7)
            ..dateDeleted = _time(8);
          final parent = store.box<Chat>().get(intent().localChatId)!
            ..dateDeleted = _time(8);
          store.box<Chat>().put(parent);
        }
        store.box<Message>().put(display);
        await reopen();
        durable = bindDurable();
        final recovered = (await durable.readOutboxEntries(scope)).single;
        expect(recovered.sameDurableSnapshotAs(expected), isTrue);
        final retained = store.runInTransaction(TxMode.read, () =>
            journal.readAdoptedSource(transactionStore: store, operation: recovered))!;
        expect(retained.source.encode(), originalSource.encode());
        expect(retained.observation.encode(), observation.encode());
        expect(retained.admittedOperationId, expected.operationId);
        expect(intent().admittedBinding, admittedBinding);
        expect(journal.readReadyPage(currentAuth: auth).ready, isEmpty);
        expect(() => admissionSource(),
            throwsA(_fails('cloud_sync_received_archive_not_ready')));
        if (unknown) {
          expect(() => store.runInTransaction(TxMode.read, () =>
              journal.requireAdoptedDispatch(transactionStore: store, operation: recovered)),
              throwsA(_fails('cloud_sync_received_archive_admitted_source_changed')));
          expect(await durable.leaseEligibleOutbox(scope,
            now: _time(130), limit: 1, leaseId: 'must-not-resubmit',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save}), isEmpty);
          final readback = (await durable.leaseUnknownOutcomes(scope,
            now: _time(130), limit: 1, leaseId: 'received-readback',
            leaseDuration: const Duration(minutes: 1))).single;
          expect(readback.status, CloudOutboxStatus.unknownOutcome);
          expect(readback.operationId, expected.operationId);
          expect(readback.appleRequestUuid, expected.appleRequestUuid);
          expect(readback.appleOperationUuid, expected.appleOperationUuid);
          expect(readback.encryptedPayloadReference, expected.encryptedPayloadReference);
          expect(readback.payloadSha256, expected.payloadSha256);
          expect(readback.protectedLeaseReference, expected.protectedLeaseReference);
          expect(journal.readAdoptedSource(transactionStore: store, operation: readback)!
              .source.encode(), originalSource.encode());
        } else {
          final leased = await durable.leaseEligibleOutbox(scope,
            now: _time(9), limit: 1, leaseId: 'received-resume',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save});
          expect(leased.single.operationId, expected.operationId);
          expect(leased.single.encryptedPayloadReference, expected.encryptedPayloadReference);
        }
        expect(_byGuid(guid)!.text, unknown ? 'edited after admission' : 'original');
        expect(_byGuid(guid)!.dateRead?.toUtc(), _time(7));
        expect(store.box<CloudOutboxOperationEntity>().count(), 1);
        expect(recordMapCountForZone(store, scope.zone), 1);
        expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
        expect(await durable.readLiveProtectedOutboundLeaseReferences(maximumCount: 20),
            containsAll([originalSource.leaseReference, expected.protectedLeaseReference]));
      });
    }

    group('Found reader handoff', () {
      late CloudCoordinatorLeaseFence fence;
      final readerLease = _lease('c');
      final readerBatch = _a43('D');

      CloudSyncCheckpointEntity checkpoint() => store
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .singleWhere((row) => row.checkpointKey == cloudSyncPersistentScopeKey(scope));

      Map<String, Object?> checkpointFields(CloudSyncCheckpointEntity row) => {
        'id': row.id, 'key': row.checkpointKey, 'account': row.accountFingerprint,
        'container': row.container, 'database': row.database, 'zone': row.zone,
        'stream': row.streamKind, 'schema': row.schemaVersion,
        'lane': row.persistenceLane, 'direction': row.fetchDirection,
        'token': row.fetchedTokenCiphertext,
        'pendingToken': row.pendingFetchedTokenCiphertext,
        'pendingBatch': row.pendingBatchId, 'generation': row.generation,
        'lastBatch': row.lastBatchId, 'fetched': row.fetchedSequence,
        'applied': row.appliedSequence, 'successful': row.lastSuccessfulAtMs,
        'attempt': row.lastAttemptAtMs, 'failure': row.lastErrorCategory,
        'backoff': row.backoffAttempt, 'eligible': row.nextEligibleAtMs,
        'revision': row.mutationRevisionCounter, 'updated': row.updatedAtMs,
      };

      List<Object?> inboxFields(CloudInboxChangeEntity row) => [
        row.id, row.changeKey, row.changeIdHash, row.scopeKey,
        row.accountFingerprint, row.zone, row.serverRecordIdHash, row.etagHash,
        row.changeType, row.encryptedServerRecordId, row.protectedSystemFieldsRef,
        row.encryptedPayloadRef, row.payloadSha256, row.batchId, row.generation,
        row.fetchSequence, row.status, row.isTombstone, row.preflightCategory,
        row.failureCategory, row.preflightCode, row.retryCount,
        row.nextEligibleAtMs, row.serverModifiedAtMs,
        row.serverModifiedAtFormatVersion, row.createdAtMs, row.updatedAtMs,
        row.completedAtMs,
      ];

      List<Object?> pageLeaseFields(CloudProtectedPageLeaseEntity row) => [
        row.id, row.leaseReference, row.scopeKey, row.accountFingerprint,
        row.generation, row.batchIdHash, row.adoptedAtMs,
        row.finalizeAttemptCount, row.nextFinalizeEligibleAtMs,
      ];

      List<CloudInboxChangeEntity> messageInbox() => store
          .box<CloudInboxChangeEntity>().getAll()
          .where((row) => row.scopeKey == cloudSyncPersistentScopeKey(scope))
          .toList()..sort((a, b) => a.fetchSequence.compareTo(b.fetchSequence));

      Map<String, Object?> durableReaderState() {
        final row = intent();
        final message = _byGuid(guid)!;
        return {
          'checkpoints': store.box<CloudSyncCheckpointEntity>().getAll()
              .map(checkpointFields).toList(),
          'inbox': store.box<CloudInboxChangeEntity>().getAll()
              .map(inboxFields).toList(),
          'pageLeases': store.box<CloudProtectedPageLeaseEntity>().getAll()
              .map(pageLeaseFields).toList(),
          'intent': [
            row.id, row.intentKey, row.accountFingerprint, row.writerEpoch,
            row.localMessageId, row.localChatId, row.messageGuidHash,
            row.sourceSha256, row.origin, row.protectedSourceBinding,
            row.recordObservationBinding, row.admittedOperationId,
            row.admittedBinding, row.readerChangeId, row.state,
            row.createdAtMs, row.updatedAtMs,
          ],
          'message': [
            message.id, message.guid, message.text, message.chat.targetId,
            message.isFromMe, message.handleId, message.dateCreated?.toUtc(),
            message.dateRead?.toUtc(), message.dateEdited?.toUtc(),
            message.dateDeleted?.toUtc(), message.dbMessageSummaryInfo,
            message.attributedBody.map((part) => part.toMap()).toList(),
            message.ckRecordId, message.ckSyncState, message.sendingServiceId,
          ],
          'messageMaps': recordMapCountForZone(store, scope.zone),
          'outbox': store.box<CloudOutboxOperationEntity>().count(),
        };
      }

      Matcher storageFailure(String code) => isA<CloudSyncFailure>()
          .having((error) => error.safeCode, 'safeCode', code);

      CloudFetchedChange readerChange({
        String id = 'C', String etag = 'E', String raw = 'Y',
        String server = 'I', String fields = 'J', String? record,
        bool tombstone = false,
      }) => CloudFetchedChange(
        changeId: _a43(id),
        recordIdHash: record ?? observation.serverRecordIdHash,
        etagHash: tombstone ? null : _a43(etag),
        type: tombstone ? CloudChangeType.delete : CloudChangeType.save,
        isTombstone: tombstone,
        encryptedServerRecordId: 'obcs2.ref.${_a43(server)}',
        protectedSystemFieldsReference: 'obcs2.ref.${_a43(fields)}',
        encryptedPayloadReference: tombstone ? null : 'obcs2.ref.${_a43(raw)}',
        payloadSha256: tombstone ? null : _h64('d'),
        serverModifiedAt: _time(2),
      );

      bool handoff({
        CloudSyncReceivedArchiveAdmissionSource? source,
        CloudFetchedChange? change,
        CloudCoordinatorLeaseFence? leaseFence,
        bool Function()? stillCurrent,
      }) => durable.journalReceivedFound(
        scope: scope,
        change: change ?? readerChange(),
        generation: observation.generation,
        batchId: readerBatch,
        leaseReference: readerLease,
        leaseFence: leaseFence ?? fence,
        journal: journal,
        source: source ?? journal.readForReader(intentId: intentId, currentAuth: auth),
        currentAuth: auth,
        stillCurrent: stillCurrent ?? () => true,
      );

      Future<void> seedHistory(CloudFetchedChange change, {
        String lease = '1', bool apply = true,
      }) async {
        final prior = await durable.readCheckpoint(scope);
        await durable.journalFetchedBatch(
          CloudFetchBatch(
            scope: scope, changes: [change],
            batchId: 'synthetic-reader-history-${prior.fetchedSequence + 1}',
            generation: prior.generation,
            nextToken: 'synthetic-server-cursor-${prior.fetchedSequence + 1}',
            hasMore: false,
            protectedPageLeaseReference: _lease(lease),
          ),
          now: _time(4), leaseFence: fence,
          expectedGeneration: prior.generation,
          expectedFetchedToken: prior.fetchedToken,
          expectedFetchDirection: prior.fetchDirection,
        );
        if (apply) {
          // Fixture bookkeeping for already-processed history, not a decoder.
          await durable.markInboxApplied(scope,
            sequence: prior.fetchedSequence + 1, now: _time(4), leaseFence: fence);
        }
      }

      setUp(() async {
        fence = (await durable.tryAcquireCoordinatorLease(scope,
          ownerId: 'received-found-reader', now: _time(4),
          leaseDuration: const Duration(hours: 1)))!;
        final prior = await durable.readCheckpoint(scope);
        await durable.journalFetchedBatch(
          CloudFetchBatch(scope: scope, changes: const [],
            batchId: 'synthetic-server-cursor-baseline',
            generation: prior.generation,
            nextToken: 'synthetic-existing-server-cursor', hasMore: false),
          now: _time(4), leaseFence: fence,
          expectedGeneration: prior.generation,
          expectedFetchedToken: prior.fetchedToken,
          expectedFetchDirection: prior.fetchDirection,
        );
        expect(checkpoint().fetchedTokenCiphertext, isNotNull);
        expect(checkpoint().pendingFetchedTokenCiphertext, isNull);
      });

      test('Found scan honors round ceiling across reopen and excludes state3/state4 ownership',
          () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent,
            messageGuid: 'selector-reader-owned');
        final readerOwned = intentId;
        expect(handoff(), isTrue);
        expect(intent().state, 4);
        // Settle the synthetic inbox bookkeeping so the independent create
        // origin can enter the actual outbox without unrelated read debt.
        await durable.markInboxApplied(scope, sequence: messageInbox().single.fetchSequence,
            now: _time(4), leaseFence: fence);
        await seedOrigin(messageGuid: 'selector-create-owned',
            logicalMarker: 'N', recordMarker: 'O');
        final createOwned = intentId;
        final operation = admit();
        expect(intent().state, 3);
        expect(intent().admittedOperationId, operation.operationId);

        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent,
            messageGuid: 'selector-equivalent', logicalMarker: 'P', recordMarker: 'Q');
        final equivalent = intentId;
        journal.markReadConsidered(intentId: equivalent, now: _time(6));
        await seedOrigin(disposition: CloudSyncReceivedRecordState.needsProjection,
            messageGuid: 'selector-needs-projection', logicalMarker: 'R', recordMarker: 'S');
        final needsProjection = intentId;
        journal.markReadConsidered(intentId: needsProjection, now: _time(6));
        final ceiling = journal.captureReadHighWatermark();

        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent,
            messageGuid: 'selector-after-ceiling', logicalMarker: 'T', recordMarker: 'U');
        final later = intentId;
        expect(later, greaterThan(ceiling));
        // Its older consideration timestamp sorts the new row first. The
        // high-watermark must be applied before LIMIT, not after selection.
        expect(journal.readFoundCandidates(currentAuth: auth, limit: 1), [later]);
        expect(journal.readFoundCandidates(currentAuth: auth, limit: 1,
            maximumIntentId: ceiling), [equivalent]);
        await reopen();
        durable = bindDurable();
        expect(journal.readReadyPage(currentAuth: auth).ready, isEmpty);
        expect(journal.readFoundCandidates(currentAuth: auth, limit: 20,
            maximumIntentId: ceiling), [equivalent, needsProjection]);
        expect(journal.readFoundCandidates(currentAuth: auth, limit: 20),
            [later, equivalent, needsProjection]);
        expect(store.box<CloudSyncReceivedArchiveIntentEntity>().get(readerOwned)!.state, 4);
        expect(store.box<CloudSyncReceivedArchiveIntentEntity>().get(createOwned)!.state, 3);
        expect((await durable.readOutboxEntries(scope)).single.operationId, operation.operationId);
      });

      test('equivalent becomes normal pending inbox with exact cursor and ownership across reopen',
          () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent);
        final before = checkpointFields(checkpoint());
        final beforeMessage = durableReaderState()['message'];
        final change = readerChange();
        expect(handoff(change: change), isTrue);
        final expectedCheckpoint = Map<String, Object?>.from(before)
          ..['fetched'] = (before['fetched'] as int) + 1
          ..['updated'] = _time(4).millisecondsSinceEpoch;
        expect(checkpointFields(checkpoint()), expectedCheckpoint);
        expect(intent().state, 4);
        expect(intent().readerChangeId, change.changeId);
        expect(intent().admittedOperationId, isNull);
        expect(intent().protectedSourceBinding, originalSource.encode());
        expect(intent().recordObservationBinding, observation.encode());
        final row = messageInbox().single;
        expect(row.status, CloudInboxStatus.pending.index);
        expect(row.fetchSequence, (before['fetched'] as int) + 1);
        expect(row.batchId, readerBatch);
        expect(row.generation, observation.generation);
        expect(row.changeIdHash, change.changeId);
        expect(row.etagHash, change.etagHash);
        expect(row.encryptedPayloadRef, change.encryptedPayloadReference);
        expect(row.encryptedServerRecordId, change.encryptedServerRecordId);
        expect(row.protectedSystemFieldsRef, change.protectedSystemFieldsReference);
        expect(row.payloadSha256, change.payloadSha256);
        expect(cloudInboxCanonicalServerModifiedAtMillis(row),
            change.serverModifiedAt!.millisecondsSinceEpoch);
        expect(durableReaderState()['message'], beforeMessage);
        expect(recordMapCountForZone(store, scope.zone), 0);
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
        final pageOwner = store.box<CloudProtectedPageLeaseEntity>().getAll().single;
        expect(pageOwner.leaseReference, readerLease);
        expect(pageOwner.scopeKey, cloudSyncPersistentScopeKey(scope));
        expect(pageOwner.generation, observation.generation);
        final committedState = durableReaderState();
        // A lost native commit response must not let the worker's fairness
        // update throw or undo an already adopted reader owner.
        journal.markReaderAttemptConsidered(intentId: intentId, now: _time(6));
        expect(durableReaderState(), committedState);
        await reopen();
        durable = bindDurable();
        expect(durableReaderState(), committedState);
        final restored = await durable.readCheckpoint(scope);
        expect(restored.fetchedToken, 'synthetic-existing-server-cursor');
        expect(restored.hasUnmarkedPendingInbox, isTrue);
        final pending = (await durable.readEligibleInbox(scope,
          now: _time(5), limit: 10)).single;
        expect(pending.status, CloudInboxStatus.pending);
        expect(pending.change.changeId, change.changeId);
        expect(pending.change.encryptedPayloadReference, change.encryptedPayloadReference);
        expect(await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10),
            {readerLease});
        final live = await durable.readLiveProtectedReferences(maximumCount: 128);
        expect(live.isComplete, isTrue);
        expect(live.references, containsAll([
          originalSource.protectedReference, observation.rawReference,
          change.encryptedServerRecordId, change.protectedSystemFieldsReference,
          change.encryptedPayloadReference,
        ]));
        expect(journal.readLiveReceivedArchiveReferences(maximumCount: 10),
            containsAll([originalSource.protectedReference, observation.rawReference]));
      });

      test('needsProjection enters pending only after rejecting unsupported origins and local mutations',
          () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.needsProjection);
        final source = journal.readForReader(intentId: intentId, currentAuth: auth);
        for (final failure in ['absent', 'conflicting', 'unresolved', 'edit', 'unsend', 'deletion']) {
          final row = intent();
          final message = _byGuid(guid)!;
          if (failure == 'edit') {
            message
              ..text = 'new local edit'
              ..attributedBody = [AttributedBody.raw('new local edit')]
              ..dateEdited = _time(5);
          } else if (failure == 'unsend') {
            message.messageSummaryInfo = [MessageSummaryInfo.empty()..retractedParts.add(0)];
          } else if (failure == 'deletion') {
            message.dateDeleted = _time(5);
          } else if (failure == 'unresolved') {
            row..state = 1..recordObservationBinding = null;
          } else {
            final conflicting = failure == 'conflicting';
            row.recordObservationBinding = CloudSyncReceivedRecordObservation(
              state: conflicting ? CloudSyncReceivedRecordState.conflictingIdentity
                  : CloudSyncReceivedRecordState.absent,
              accountFingerprint: _account, protectedStoreIdentity: _storeId,
              messageGuidHash: originalSource.messageGuidHash,
              sourceSha256: originalSource.sourceSha256,
              logicalEntityKeyHash: observation.logicalEntityKeyHash,
              serverRecordIdHash: observation.serverRecordIdHash,
              generation: observation.generation, parentBinding: observation.parentBinding,
              observedAtMs: observation.observedAtMs,
              etagHash: conflicting ? observation.etagHash : null,
              rawReference: conflicting ? observation.rawReference : null,
              rawLeaseReference: conflicting ? observation.rawLeaseReference : null,
            ).encode();
          }
          store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
          store.box<Message>().put(message);
          final before = durableReaderState();
          expect(() => handoff(source: source), throwsA(_fails(
            failure == 'edit' || failure == 'unsend'
                ? 'cloud_sync_received_archive_admitted_source_changed'
                : 'cloud_sync_received_archive_found_projection_not_ready',
          )), reason: failure);
          expect(durableReaderState(), before, reason: failure);
          row..state = 2..recordObservationBinding = observation.encode();
          message
            ..text = 'original'
            ..attributedBody = [AttributedBody.raw('original')]
            ..dateEdited = null..dateDeleted = null..messageSummaryInfo = [];
          store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
          store.box<Message>().put(message);
        }
        expect(handoff(source: source), isTrue);
        expect((await durable.readEligibleInbox(scope, now: _time(5), limit: 1))
            .single.status, CloudInboxStatus.pending);
        expect(intent().state, 4);
        expect(intent().recordObservationBinding, observation.encode());
        expect(_byGuid(guid)!.text, 'original');
      });

      test('rolls back checkpoint, inbox, page lease and received ownership after tentative writes',
          () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent);
        final source = journal.readForReader(intentId: intentId, currentAuth: auth);
        for (final abortAfterAdoption in [false, true]) {
          final before = durableReaderState();
          var sawWrites = false;
          if (abortAfterAdoption) {
            void abortReaderTransaction() {
              expect(handoff(source: source), isTrue);
              expect(intent().state, 4);
              expect(intent().readerChangeId, readerChange().changeId);
              expect(messageInbox(), hasLength(1));
              expect(store.box<CloudProtectedPageLeaseEntity>().getAll().single.leaseReference,
                  readerLease);
              sawWrites = true;
              throw StateError('abort complete reader handoff');
            }
            expect(() => store.runInTransaction<void>(TxMode.write, abortReaderTransaction),
                throwsA(_fails('abort complete reader handoff')));
          } else {
            expect(() => handoff(source: source, stillCurrent: () {
              if (messageInbox().isNotEmpty) {
                expect(checkpoint().fetchedSequence, 1);
                expect(store.box<CloudProtectedPageLeaseEntity>().getAll().single.leaseReference,
                    readerLease);
                expect(intent().state, 2);
                sawWrites = true;
                return false;
              }
              return true;
            }), throwsA(_fails('cloud_sync_received_archive_admission_changed')));
          }
          expect(sawWrites, isTrue);
          expect(durableReaderState(), before);
          expect(await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10), isEmpty);
        }
        expect(handoff(source: source), isTrue);
        expect(messageInbox().single.fetchSequence, 1);
        expect(intent().state, 4);
      });

      test('same existing inbox change keeps original lease and rolls back newly staged references',
          () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent);
        final existing = readerChange(raw: 'O', server: 'U', fields: 'H');
        await seedHistory(existing);
        final before = durableReaderState();
        final source = journal.readForReader(intentId: intentId, currentAuth: auth);
        final transport = _ReceivedLeaseTransport();
        await transport.runLocalProtectedStoreExclusive(() async {
          final adopted = handoff(source: source);
          expect(adopted, isFalse);
          if (!adopted) await transport.rollbackProtectedPageLease(readerLease);
        });
        final after = durableReaderState();
        expect(after['checkpoints'], before['checkpoints']);
        expect(after['inbox'], before['inbox']);
        expect(after['pageLeases'], before['pageLeases']);
        expect(after['message'], before['message']);
        expect(intent().state, 4);
        expect(intent().readerChangeId, existing.changeId);
        expect(transport.rolledBack, [readerLease]);
        expect(transport.committed, isEmpty);
        expect(messageInbox(), hasLength(1));
        expect(messageInbox().single.encryptedPayloadRef, existing.encryptedPayloadReference);
        expect(await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10),
            {_lease('1')});
        final live = await durable.readLiveProtectedReferences(maximumCount: 128);
        expect(live.references, containsAll([
          existing.encryptedPayloadReference, existing.encryptedServerRecordId,
          existing.protectedSystemFieldsReference, observation.rawReference,
        ]));
        expect(live.references, isNot(contains(readerChange().encryptedPayloadReference)));
        expect(live.references, isNot(contains(readerChange().encryptedServerRecordId)));
        await reopen();
        durable = bindDurable();
        expect(durableReaderState(), after);
        expect((await durable.readCheckpoint(scope)).fetchedToken, 'synthetic-server-cursor-1');
      });

      test('rejects different latest ETag, later change and tombstone despite an older exact match',
          () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent);
        final source = journal.readForReader(intentId: intentId, currentAuth: auth);
        await seedHistory(readerChange(raw: 'O', server: 'U', fields: 'H'));
        final laterChanges = [
          readerChange(id: 'N', etag: 'X'),
          readerChange(id: 'Q'), // Same content/ETag, distinct later change identity.
          readerChange(id: 'T', tombstone: true),
        ];
        for (var index = 0; index < laterChanges.length; index++) {
          await seedHistory(laterChanges[index], lease: ['2', '3', '4'][index]);
          final before = durableReaderState();
          expect(() => handoff(source: source),
              throwsA(storageFailure('received_found_reader_newer_evidence')));
          expect(durableReaderState(), before);
          expect(messageInbox().first.changeIdHash, readerChange().changeId);
          expect(messageInbox().last.changeIdHash, laterChanges[index].changeId);
          expect(intent().state, 2);
          expect(intent().readerChangeId, isNull);
          expect(await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10),
              isNot(contains(readerLease)));
        }
      });

      test('stale coordinator fence and checkpoint generation cannot journal Found', () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent);
        final source = journal.readForReader(intentId: intentId, currentAuth: auth);
        final stale = fence;
        await durable.releaseCoordinatorLease(scope, leaseFence: stale);
        fence = (await durable.tryAcquireCoordinatorLease(scope,
          ownerId: stale.ownerId, now: _time(4),
          leaseDuration: const Duration(hours: 1)))!;
        expect(fence.generation, greaterThan(stale.generation));
        final beforeStaleFence = durableReaderState();
        expect(() => handoff(source: source, leaseFence: stale),
            throwsA(storageFailure('coordinator_lease_fence_lost')));
        expect(durableReaderState(), beforeStaleFence);
        final row = checkpoint();
        row.generation++;
        store.box<CloudSyncCheckpointEntity>().put(row);
        final beforeStaleGeneration = durableReaderState();
        expect(() => handoff(source: source), throwsA(storageFailure('generation_mismatch')));
        expect(durableReaderState(), beforeStaleGeneration);
        row.generation = observation.generation;
        store.box<CloudSyncCheckpointEntity>().put(row);
        expect(handoff(source: source), isTrue);
        expect(intent().state, 4);
      });

      test('pending server page blocks new handoff and preserves both cursor ciphertexts', () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent);
        await seedHistory(readerChange(id: 'Z', record: _a43('Z')),
            apply: false);
        expect(checkpoint().fetchedTokenCiphertext, isNotNull);
        expect(checkpoint().pendingFetchedTokenCiphertext, isNotNull);
        expect(checkpoint().pendingFetchedTokenCiphertext,
            isNot(checkpoint().fetchedTokenCiphertext));
        final before = durableReaderState();
        expect(() => handoff(), throwsA(storageFailure('checkpoint_pending_page_unresolved')));
        expect(durableReaderState(), before);
        expect(intent().readerChangeId, isNull);
        expect(messageInbox().single.serverRecordIdHash, _a43('Z'));
        expect(await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10),
            {_lease('1')});
      });

      test('unsettled sibling-zone outbox blocks Found reader without consuming source', () async {
        await seedOrigin(disposition: CloudSyncReceivedRecordState.equivalent);
        final sibling = scopeFor('attachmentManateeZone');
        final pending = await durable.enqueueOutboxMutation(CloudOutboxDraft(
          scope: sibling, logicalEntityKeyHash: _a43('Z'),
          action: CloudOutboxAction.save, payloadVersion: 1,
          dependencyOperationIds: const {}, createdAt: _time(3),
          encryptedPayloadReference: 'obcs2.ref.${_a43('K')}',
          payloadSha256: _h64('b'), protectedLeaseReference: _lease('b'),
        ));
        final before = durableReaderState();
        expect(() => handoff(), throwsA(storageFailure('received_found_reader_outbox_unsettled')));
        expect(durableReaderState(), before);
        expect((await durable.readOutboxEntries(sibling)).single.sameDurableSnapshotAs(pending),
            isTrue);
        expect(messageInbox(), isEmpty);
        expect(await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10), isEmpty);
        expect(intent().state, 2);
        expect(intent().protectedSourceBinding, originalSource.encode());
        expect(intent().recordObservationBinding, observation.encode());
      });
    });

    for (final change in ['outgoing overlap', 'edit', 'unsend']) {
      test('late $change blocks leasing but preserves adopted readback source',
          () async {
        await seedOrigin();
        final operation = admit();
        if (change == 'outgoing overlap') {
          addOutgoingOverlap(byGuid: true);
        } else {
          final message = _byGuid(guid)!;
          if (change == 'edit') {
            message.dateEdited = _time(5);
          } else {
            message.messageSummaryInfo = [
              MessageSummaryInfo.empty()..retractedParts.add(0),
            ];
          }
          store.box<Message>().put(message);
        }
        await expectLater(durable.leaseEligibleOutbox(scope,
          now: _time(5), limit: 1, leaseId: 'late-change-must-not-send',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save}),
          throwsA(_fails('cloud_sync_received_archive_admitted_source_changed')));
        expect((await durable.readOutboxEntries(scope)).single
            .sameDurableSnapshotAs(operation), isTrue);
        expect(journal.readAdoptedSource(transactionStore: store, operation: operation)!
            .source.encode(), originalSource.encode());
        expect(intent().admittedOperationId, operation.operationId);
      });
    }
  });

  test('body drift rolls back both message and intent', () {
    const guid = 'recv-guid-1002';
    final src = _staged(guid, 'staged body', chat);
    final wire = _wire(
      id: guid,
      text: 'staged body',
      sentAt: _time(2).millisecondsSinceEpoch,
    );
    final drifted = _fresh(guid, 'mutated body', chat);
    expect(
      () => journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(drifted),
        localChatId: chat.id!,
        source: src,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(3),
      ),
      throwsStateError,
    );
    expect(_byGuid(guid), isNull);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
  });
  test('sender drift rolls back both message and intent', () {
    const guid = 'recv-guid-1003';
    final src = _staged(guid, 'hello sender', chat);
    final wire = _wire(
      id: guid,
      text: 'hello sender',
      sentAt: _time(2).millisecondsSinceEpoch,
    );
    final drifted = _fresh(
      guid,
      'hello sender',
      chat,
      handleAddr: 'other@example.com',
    );
    drifted.handle!.originalROWID = 9002;
    drifted.handleId = 9002;
    expect(
      () => journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(drifted),
        localChatId: chat.id!,
        source: src,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(3),
      ),
      throwsStateError,
    );
    expect(_byGuid(guid), isNull);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
  });
  test('time drift rolls back both message and intent', () {
    const guid = 'recv-guid-1004';
    final src = _staged(guid, 'hello time', chat);
    final wire = _wire(
      id: guid,
      text: 'hello time',
      sentAt: _time(2).millisecondsSinceEpoch,
    );
    final drifted = _fresh(guid, 'hello time', chat);
    drifted.dateCreated = _time(9);
    expect(
      () => journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(drifted),
        localChatId: chat.id!,
        source: src,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(3),
      ),
      throwsStateError,
    );
    expect(_byGuid(guid), isNull);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
  });
  test('changed source retains prior capture', () {
    const guid = 'recv-guid-1005';
    const text = 'hello prior';
    final src = _staged(guid, text, chat);
    final wire = _wire(
      id: guid,
      text: text,
      sentAt: _time(2).millisecondsSinceEpoch,
    );
    final fresh = _fresh(guid, text, chat);
    final first = journal.saveReceivedCapture(
      wire: wire,
      liveContext: _live,
      persistMessage: () => store.box<Message>().put(fresh),
      localChatId: chat.id!,
      source: src,
      capturedAuth: _auth(Object()),
      stillCurrent: () => true,
      now: _time(3),
    );
    final other = CloudSyncReceivedArchiveSourceBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      messageGuidHash: src.messageGuidHash,
      sourceSha256: src.sourceSha256,
      protectedReference: 'obcs2.ref.${_a43('Q')}',
      leaseReference: _lease('b'),
      payloadSha256: _h64('c'),
      payloadLength: 128,
    );
    expect(
      () => journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(fresh),
        localChatId: chat.id!,
        source: other,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: _time(4),
      ),
      throwsA(_fails('cloud_sync_received_archive_intent_changed')),
    );
    expect(
      journal
          .readProtectedSource(intentId: first, currentAuth: _auth(Object()))
          .encode(),
      src.encode(),
    );
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 1);
  });
  test('readReady bounded fair metadata-only with overlap and no outbox', () {
    Message saveOne(
      String guid,
      String text,
      String ref,
      String lease,
      DateTime at,
    ) {
      final src = _staged(guid, text, chat);
      final fixed = CloudSyncReceivedArchiveSourceBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        messageGuidHash: src.messageGuidHash,
        sourceSha256: src.sourceSha256,
        protectedReference: 'obcs2.ref.${_a43(ref)}',
        leaseReference: _lease(lease),
        payloadSha256: _h64('b'),
        payloadLength: 64,
      );
      final wire = _wire(
        id: guid,
        text: text,
        sentAt: _time(2).millisecondsSinceEpoch,
      );
      final fresh = _fresh(guid, text, chat);
      journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(fresh),
        localChatId: chat.id!,
        source: fixed,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: at,
      );
      return _byGuid(guid)!;
    }

    final m1 = saveOne('recv-guid-1011', 'fair one', 'R', 'a', _time(3));
    saveOne('recv-guid-1012', 'fair two', 'W', 'c', _time(4));
    var page = journal.readReadyPage(currentAuth: _auth(Object()));
    expect(page.ready, hasLength(2));
    expect(page.ready.first.localMessageId, m1.id);
    expect(page.exhausted, isTrue);
    expect(
      () => journal.readReadyPage(limit: 0, currentAuth: _auth(Object())),
      throwsArgumentError,
    );
    expect(
      journal.readReadyPage(limit: 1, currentAuth: _auth(Object())).ready,
      hasLength(1),
    );
    journal.markReadConsidered(intentId: page.ready.first.id, now: _time(9));
    page = journal.readReadyPage(currentAuth: _auth(Object()));
    expect(page.ready, hasLength(2));
    expect(page.ready.last.localMessageId, m1.id);
    expect(
      journal.readLiveReceivedArchiveReferences(maximumCount: 10),
      hasLength(2),
    );
    expect(
      journal.readLiveReceivedArchiveLeaseReferences(maximumCount: 10),
      hasLength(2),
    );
    store.box<CloudSyncLocalSendIntentEntity>().put(
      CloudSyncLocalSendIntentEntity(
        intentKey: 'overlap-row',
        accountFingerprint: _account,
        writerEpoch: snap.epoch,
        localMessageId: m1.id!,
        messageGuidHash: _h64('a'),
        sourceSha256: _h64('b'),
        createdAtMs: _time(3).millisecondsSinceEpoch,
        updatedAtMs: _time(3).millisecondsSinceEpoch,
      ),
    );
    expect(
      journal.readReadyPage(currentAuth: _auth(Object())).ready,
      hasLength(1),
    );
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });
  test('stale rows beyond one scan budget still drain via cursor', () {
    Message saveAt(String guid, String text, DateTime at) {
      final src = _staged(guid, text, chat);
      final wire = _wire(
        id: guid,
        text: text,
        sentAt: _time(2).millisecondsSinceEpoch,
      );
      final fresh = _fresh(guid, text, chat);
      journal.saveReceivedCapture(
        wire: wire,
        liveContext: _live,
        persistMessage: () => store.box<Message>().put(fresh),
        localChatId: chat.id!,
        source: src,
        capturedAuth: _auth(Object()),
        stillCurrent: () => true,
        now: at,
      );
      return _byGuid(guid)!;
    }

    // Ten stale head rows exceed one limit-1 call budget (8 pages of 1).
    final staleIds = <int>[];
    for (var i = 0; i < 10; i++) {
      final m = saveAt('recv-guid-104$i', 'stale number $i', _time(3 + i));
      staleIds.add(m.id!);
    }
    final valid = saveAt('recv-guid-1050', 'valid tail', _time(30));
    for (var i = 0; i < staleIds.length; i++) {
      if (i.isEven) {
        final edit = store.box<Message>().get(staleIds[i])!;
        edit.ckRecordId = 'legacy-record-$i';
        store.box<Message>().put(edit);
      } else {
        store.box<CloudSyncLocalSendIntentEntity>().put(
          CloudSyncLocalSendIntentEntity(
            intentKey: 'overlap-stale-$i',
            accountFingerprint: _account,
            writerEpoch: snap.epoch,
            localMessageId: staleIds[i],
            messageGuidHash: _h64('a'),
            sourceSha256: _h64('b'),
            createdAtMs: _time(3).millisecondsSinceEpoch,
            updatedAtMs: _time(3).millisecondsSinceEpoch,
          ),
        );
      }
    }
    final first = journal.readReadyPage(limit: 1, currentAuth: _auth(Object()));
    expect(first.ready, isEmpty);
    expect(first.scanned, 8);
    expect(first.exhausted, isFalse);
    expect(first.nextCursor, isNotNull);
    final second = journal.readReadyPage(
      limit: 1,
      currentAuth: _auth(Object()),
      cursor: first.nextCursor,
    );
    expect(second.ready.map((e) => e.localMessageId), [valid.id]);
    final third = journal.readReadyPage(
      limit: 1,
      currentAuth: _auth(Object()),
      cursor: second.nextCursor,
    );
    expect(third.ready, isEmpty);
    expect(third.exhausted, isTrue);
    expect(third.nextCursor, isNull);
    expect(
      () => journal.readReadyPage(
        limit: 1,
        currentAuth: _auth(Object()),
        cursor: 'bogus',
      ),
      throwsArgumentError,
    );
  });
  test('old epoch rows keep refs and malformed rows fail closed', () async {
    const guid = 'recv-guid-1031';
    const text = 'epoch proof';
    final src = _staged(guid, text, chat);
    final wire = _wire(
      id: guid,
      text: text,
      sentAt: _time(2).millisecondsSinceEpoch,
    );
    final fresh = _fresh(guid, text, chat);
    journal.saveReceivedCapture(
      wire: wire,
      liveContext: _live,
      persistMessage: () => store.box<Message>().put(fresh),
      localChatId: chat.id!,
      source: src,
      capturedAuth: _auth(Object()),
      stillCurrent: () => true,
      now: _time(3),
    );
    final permit = authority.issuePermit(
      _scope,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    authority.markMutationUnknown(permit, now: _time(9));
    await reopen();
    expect(journal.readLiveReceivedArchiveReferences(maximumCount: 10), {
      src.protectedReference,
    });
    expect(journal.readLiveReceivedArchiveLeaseReferences(maximumCount: 10), {
      src.leaseReference,
    });
    final epochPage = journal.readReadyPage(currentAuth: _auth(Object()));
    expect(epochPage.ready, isEmpty);
    expect(epochPage.exhausted, isTrue);
    store.box<CloudSyncReceivedArchiveIntentEntity>().put(
      CloudSyncReceivedArchiveIntentEntity(
        intentKey: 'corrupt-row',
        accountFingerprint: _account,
        writerEpoch: snap.epoch,
        localMessageId: 1,
        localChatId: 1,
        messageGuidHash: _h64('a'),
        sourceSha256: _h64('b'),
        origin: 0,
        protectedSourceBinding: 'corrupt',
        state: 0,
        createdAtMs: _time(3).millisecondsSinceEpoch,
        updatedAtMs: _time(3).millisecondsSinceEpoch,
      ),
    );
    expect(
      () => journal.readLiveReceivedArchiveReferences(maximumCount: 10),
      throwsStateError,
    );
    expect(
      () => journal.readLiveReceivedArchiveLeaseReferences(maximumCount: 10),
      throwsStateError,
    );
  });
  group('source-bound discovery admission', () {
    late ObjectBoxCloudSyncStore durable;
    late CloudCoordinatorLeaseFence fence;
    late CloudSyncNativeAuthSnapshot auth;
    late CloudSyncReceivedArchiveSourceBinding discoverySource;
    late int discoveryIntentId;
    CloudSyncScope discoveryScope() => CloudSyncScope(
      accountFingerprint: _account,
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    Future<int> currentGeneration() async =>
        (await durable.readCheckpoint(discoveryScope())).generation;
    CloudFetchedChange discoveryChange() => CloudFetchedChange(
      changeId: _a43('D'),
      recordIdHash: _a43('R'),
      etagHash: _a43('E'),
      type: CloudChangeType.save,
      isTombstone: false,
      encryptedServerRecordId: 'obcs2.ref.${_a43('I')}',
      protectedSystemFieldsReference: 'obcs2.ref.${_a43('J')}',
      encryptedPayloadReference: 'obcs2.ref.${_a43('Y')}',
      payloadSha256: _h64('d'),
      serverModifiedAt: _time(2),
    );
    Future<void> seedDiscovery(String messageGuid) async {
      discoverySource = _staged(messageGuid, 'original', chat);
      discoveryIntentId = journal.saveReceivedCapture(
        wire: _wire(id: messageGuid, text: 'original', sentAt: _time(2).millisecondsSinceEpoch),
        liveContext: _live,
        localChatId: chat.id!,
        persistMessage: () =>
            store.box<Message>().put(_fresh(messageGuid, 'original', chat)),
        source: discoverySource,
        capturedAuth: auth,
        stillCurrent: () => true,
        now: _time(3),
      );
      journal.markSourceMaterialized(
        intentId: discoveryIntentId,
        source: discoverySource,
        currentAuth: auth,
        stillCurrent: () => true,
      );
    }
    bool adoptDiscovery({CloudFetchedChange? change, int? generation, CloudSyncNativeAuthSnapshot? currentAuth}) =>
        durable.journalDiscoveredFound(
          scope: discoveryScope(),
          change: change ?? discoveryChange(),
          generation: generation ?? 0,
          batchId: _a43('B'),
          leaseReference: _lease('1'),
          leaseFence: fence,
          journal: journal,
          intentId: discoveryIntentId,
          source: discoverySource,
          currentAuth: currentAuth ?? auth,
          stillCurrent: () => true,
        );
    CloudSyncReceivedArchiveIntentEntity discoveryIntent() =>
        store.box<CloudSyncReceivedArchiveIntentEntity>().get(discoveryIntentId)!;
    setUp(() async {
      auth = _auth(Object());
      durable = ObjectBoxCloudSyncStore(
        store: store,
        protector: _ReceivedTestProtector(),
        receivedArchiveJournal: journal,
        clock: () => _time(4),
      );
      await durable.recordPullSuccess(discoveryScope(), now: _time(1));
      fence = (await durable.tryAcquireCoordinatorLease(discoveryScope(),
        ownerId: 'discovery-admission-test', now: _time(4),
        leaseDuration: const Duration(hours: 1)))!;
      final prior = await durable.readCheckpoint(discoveryScope());
      await durable.journalFetchedBatch(
        CloudFetchBatch(scope: discoveryScope(), changes: const [],
          batchId: 'synthetic-discovery-baseline',
          generation: prior.generation,
          nextToken: 'synthetic-discovery-cursor', hasMore: false),
        now: _time(4), leaseFence: fence,
        expectedGeneration: prior.generation,
        expectedFetchedToken: prior.fetchedToken,
        expectedFetchDirection: prior.fetchDirection,
      );
    });
    test('state1 discovery intent adopts into pending inbox without parent proof', () async {
      await seedDiscovery('discovery-guid-1');
      expect(discoveryIntent().state, 1);
      expect(discoveryIntent().readerChangeId, isNull);
      expect(adoptDiscovery(generation: await currentGeneration()), isTrue);
      expect(discoveryIntent().state, 4);
      expect(discoveryIntent().readerChangeId, _a43('D'));
      final inbox = store.box<CloudInboxChangeEntity>().getAll()
          .where((row) => row.serverRecordIdHash == _a43('R'))
          .toList();
      expect(inbox, hasLength(1));
      expect(inbox.single.status, CloudInboxStatus.pending.index);
      expect(adoptDiscovery(generation: await currentGeneration()), isFalse);
    });
    test('generation drift rejects without writes', () async {
      await seedDiscovery('discovery-guid-2');
      expect(
        () => adoptDiscovery(generation: 999),
        throwsA(isA<CloudSyncFailure>().having((e) => e.safeCode, 'safeCode', 'generation_mismatch')),
      );
      expect(discoveryIntent().readerChangeId, isNull);
      expect(store.box<CloudInboxChangeEntity>().count(), 0);
    });
    test('drifted source binding rejects', () async {
      await seedDiscovery('discovery-guid-3');
      final other = _staged('other-guid-3', 'original', chat);
      final gen3 = await currentGeneration();
      expect(
        () => durable.journalDiscoveredFound(
          scope: discoveryScope(),
          change: discoveryChange(),
          generation: gen3,
          batchId: _a43('B'),
          leaseReference: _lease('1'),
          leaseFence: fence,
          journal: journal,
          intentId: discoveryIntentId,
          source: other,
          currentAuth: auth,
          stillCurrent: () => true,
        ),
        throwsStateError,
      );
    });
    test('newer local edit blocks adoption', () async {
      await seedDiscovery('discovery-guid-4');
      final message = store.box<Message>().query(Message_.guid.equals('discovery-guid-4')).build().findFirst()!;
      message.dateEdited = _time(5);
      store.box<Message>().put(message);
      final gen4 = await currentGeneration();
      expect(() => adoptDiscovery(generation: gen4), throwsStateError);
      expect(discoveryIntent().readerChangeId, isNull);
    });
    test('tombstone change cannot adopt', () async {
      await seedDiscovery('discovery-guid-5');
      final tombstone = CloudFetchedChange(
        changeId: _a43('D'),
        recordIdHash: _a43('R'),
        etagHash: null,
        type: CloudChangeType.delete,
        isTombstone: true,
        encryptedServerRecordId: 'obcs2.ref.${_a43('I')}',
        protectedSystemFieldsReference: 'obcs2.ref.${_a43('J')}',
        encryptedPayloadReference: null,
        payloadSha256: null,
        serverModifiedAt: _time(2),
      );
      final gen5 = await currentGeneration();
      expect(
        () => adoptDiscovery(change: tombstone, generation: gen5),
        throwsA(isA<CloudSyncFailure>().having((e) => e.safeCode, 'safeCode', 'received_found_reader_input_invalid')),
      );
      expect(discoveryIntent().readerChangeId, isNull);
    });
    test('adopted discovery row survives reopen and reader recovery accepts it', () async {
      await seedDiscovery('discovery-guid-6');
      final adoptedGen = await currentGeneration();
      expect(adoptDiscovery(generation: adoptedGen), isTrue);
      journal.markReaderAttemptConsidered(intentId: discoveryIntentId, now: _time(6));
      await reopen();
      journal.markReaderAttemptConsidered(intentId: discoveryIntentId, now: _time(7));
      final row = discoveryIntent();
      expect(row.state, 4);
      final obs = CloudSyncReceivedDiscoveryObservation.decode(row.recordObservationBinding!);
      obs.requireSource(discoverySource);
      expect(obs.serverRecordIdHash, _a43('R'));
      expect(obs.generation, adoptedGen);
    });
    test('rotated current auth rejects with zero writes', () async {
      await seedDiscovery('discovery-guid-7');
      final rotated = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'native-session',
        accountFingerprint: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        protectedStoreIdentity: _storeId,
        cloudMessagesClient: Object(),
      );
      final gen = await currentGeneration();
      expect(() => adoptDiscovery(generation: gen, currentAuth: rotated), throwsStateError);
      expect(discoveryIntent().readerChangeId, isNull);
      expect(store.box<CloudInboxChangeEntity>().count(), 0);
    });
    test('same-account wrong-store source rejects with zero writes', () async {
      await seedDiscovery('discovery-guid-8');
      final foreign = CloudSyncReceivedArchiveSourceBinding(
        accountFingerprint: discoverySource.accountFingerprint,
        protectedStoreIdentity: 'obcs2.store.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        messageGuidHash: discoverySource.messageGuidHash,
        sourceSha256: discoverySource.sourceSha256,
        protectedReference: discoverySource.protectedReference,
        leaseReference: discoverySource.leaseReference,
        payloadSha256: discoverySource.payloadSha256,
        payloadLength: discoverySource.payloadLength,
      );
      final gen = await currentGeneration();
      expect(
        () => durable.journalDiscoveredFound(
          scope: discoveryScope(),
          change: discoveryChange(),
          generation: gen,
          batchId: _a43('B'),
          leaseReference: _lease('1'),
          leaseFence: fence,
          journal: journal,
          intentId: discoveryIntentId,
          source: foreign,
          currentAuth: auth,
          stillCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(discoveryIntent().readerChangeId, isNull);
      expect(store.box<CloudInboxChangeEntity>().count(), 0);
    });
    test('v2 adoption survives production inventory and reopen', () async {
      await seedDiscovery('discovery-guid-9');
      final adoptedGen = await currentGeneration();
      expect(adoptDiscovery(generation: adoptedGen), isTrue);
      // Production lease/reference inventory must accept the v2 marker row:
      // the source lease stays owned while the marker contributes no raw refs.
      expect(
        await durable.readLiveProtectedOutboundLeaseReferences(maximumCount: 4096),
        contains(discoverySource.leaseReference),
      );
      final before = await durable.readLiveProtectedReferences(maximumCount: 131072);
      expect(before.isComplete, isTrue);
      expect(before.references, contains(discoverySource.protectedReference));
      await reopen();
      durable = ObjectBoxCloudSyncStore(
        store: store,
        protector: _ReceivedTestProtector(),
        receivedArchiveJournal: journal,
        clock: () => _time(4),
      );
      expect(
        await durable.readLiveProtectedOutboundLeaseReferences(maximumCount: 4096),
        contains(discoverySource.leaseReference),
      );
      final after = await durable.readLiveProtectedReferences(maximumCount: 131072);
      expect(after.isComplete, isTrue);
      expect(after.references, contains(discoverySource.protectedReference));
      expect(discoveryIntent().state, 4);
    });
    test('v2 marker in the wrong state is rejected', () async {
      await seedDiscovery('discovery-guid-10');
      expect(adoptDiscovery(generation: await currentGeneration()), isTrue);
      final row = discoveryIntent();
      row.state = 1;
      store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
      expect(
        () => journal.markReaderAttemptConsidered(intentId: discoveryIntentId, now: _time(6)),
        throwsStateError,
      );
    });
    test('malformed v2 marker fails closed in reads and inventory', () async {
      await seedDiscovery('discovery-guid-11');
      expect(adoptDiscovery(generation: await currentGeneration()), isTrue);
      final row = discoveryIntent();
      row.recordObservationBinding = '[2,"truncated"';
      store.box<CloudSyncReceivedArchiveIntentEntity>().put(row);
      expect(
        () => journal.markReaderAttemptConsidered(intentId: discoveryIntentId, now: _time(6)),
        throwsStateError,
      );
      await expectLater(
        durable.readLiveProtectedOutboundLeaseReferences(maximumCount: 4096),
        throwsStateError,
      );
    });
    test('duplicate with a crossed intent and source throws', () async {
      await seedDiscovery('discovery-guid-12');
      final adoptedGen = await currentGeneration();
      final adoptedSource = discoverySource;
      expect(adoptDiscovery(generation: adoptedGen), isTrue);
      await seedDiscovery('discovery-guid-13');
      expect(
        () => durable.journalDiscoveredFound(
          scope: discoveryScope(),
          change: discoveryChange(),
          generation: adoptedGen,
          batchId: _a43('B'),
          leaseReference: _lease('1'),
          leaseFence: fence,
          journal: journal,
          intentId: discoveryIntentId,
          source: adoptedSource,
          currentAuth: auth,
          stillCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(store.box<CloudInboxChangeEntity>().count(), 1);
      expect(discoveryIntent().readerChangeId, isNull);
    });
    test('duplicate with rotated auth throws', () async {
      await seedDiscovery('discovery-guid-14');
      final adoptedGen = await currentGeneration();
      expect(adoptDiscovery(generation: adoptedGen), isTrue);
      final rotated = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'native-session',
        accountFingerprint: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        protectedStoreIdentity: _storeId,
        cloudMessagesClient: Object(),
      );
      expect(
        () => durable.journalDiscoveredFound(
          scope: discoveryScope(),
          change: discoveryChange(),
          generation: adoptedGen,
          batchId: _a43('B'),
          leaseReference: _lease('1'),
          leaseFence: fence,
          journal: journal,
          intentId: discoveryIntentId,
          source: discoverySource,
          currentAuth: rotated,
          stillCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(store.box<CloudInboxChangeEntity>().count(), 1);
    });
  });
}

/// Synthetic token protection for the restored-chat fixture. No native keys
/// or platform protection are involved in these ObjectBox transaction tests.
class _ReceivedTestProtector implements CloudSyncProtector {
  String _prefix(CloudSyncScope scope, CloudSyncProtectedValueKind kind) =>
      'received-test:${scope.storageKey}:${kind.name}:';

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => '${_prefix(scope, kind)}$plaintext';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    final prefix = _prefix(scope, kind);
    if (!ciphertext.startsWith(prefix)) throw StateError('test token scope changed');
    return ciphertext.substring(prefix.length);
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) =>
      throw StateError('unexpected account lookup in received test');
}

class _ReceivedLeaseTransport
    implements
        CloudProtectedPageLeaseTransport,
        CloudProtectedLocalLifecycleTransport {
  bool failCommit = false;
  bool outerHeld = false;
  bool localHeld = false;
  String? identityOverride;
  final committed = <String>[];
  final commitSawLocalHeld = <bool>[];
  final rolledBack = <String>[];
  @override
  String get protectedPageLeaseRecoveryIdentity =>
      identityOverride ?? _storeId;
  @override
  Future<T> runLocalProtectedStoreExclusive<T>(
    Future<T> Function() action,
  ) async {
    if (localHeld) throw StateError('local lease busy');
    localHeld = true;
    try {
      return await action();
    } finally {
      localHeld = false;
    }
  }
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) async {
    expect(outerHeld, isFalse);
    outerHeld = true;
    try {
      return await action();
    } finally {
      outerHeld = false;
    }
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async {
    expect(localHeld, isTrue);
    expect(retainedReferences, hasLength(1));
    committed.add(leaseReference);
    commitSawLocalHeld.add(localHeld);
    if (failCommit) throw StateError('synthetic lost commit response');
  }

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async {
    expect(localHeld, isTrue);
    rolledBack.add(leaseReference);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected operation');
}

/// Outer-lease-only transport: lacks the local lifecycle interface, so
/// the inspection fence must reject it before any native callback runs.
class _OuterOnlyTransport implements CloudProtectedPageLeaseTransport {
  bool outerHeld = false;
  @override
  String get protectedPageLeaseRecoveryIdentity => _storeId;
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) async {
    expect(outerHeld, isFalse);
    outerHeld = true;
    try {
      return await action();
    } finally {
      outerHeld = false;
    }
  }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected operation');
}
