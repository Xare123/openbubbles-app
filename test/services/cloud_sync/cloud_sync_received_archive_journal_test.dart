import 'dart:io';
import 'dart:typed_data';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

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
}

class _ReceivedLeaseTransport implements CloudProtectedPageLeaseTransport {
  bool failCommit = false;
  bool held = false;
  final committed = <String>[];
  final rolledBack = <String>[];
  @override
  String get protectedPageLeaseRecoveryIdentity => _storeId;
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) async {
    expect(held, isFalse);
    held = true;
    try {
      return await action();
    } finally {
      held = false;
    }
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async {
    expect(held, isTrue);
    expect(retainedReferences, hasLength(1));
    committed.add(leaseReference);
    if (failCommit) throw StateError('synthetic lost commit response');
  }

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async {
    expect(held, isTrue);
    rolledBack.add(leaseReference);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected operation');
}
