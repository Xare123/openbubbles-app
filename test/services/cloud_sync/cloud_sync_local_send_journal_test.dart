import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot authoritySnapshot;
  late CloudSyncLocalSendJournal journal;
  late Chat chat;

  void provisionJournal() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final existing = authority.read(_scope);
    if (existing == null) {
      final disabled = authority.initializeDisabled(_scope, now: _time(0));
      authority.provisionInitialOwner(
        _scope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: _completeEvidence,
        now: _time(1),
      );
    }
    authoritySnapshot = authority.read(_scope)!;
    journal = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authoritySnapshot,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-local-send-journal-',
    );
    store = await openStore(directory: directory.path);
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    provisionJournal();
  }

  test(
    'callback failure rolls back the local message and intent atomically',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);

      expect(
        () => journal.saveSubmission(
          identity: identity,
          newlyGeneratedGuid: true,
          persistMessage: () {
            store.box<Message>().put(message);
            throw StateError('injected local persistence failure');
          },
          now: _time(2),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'injected local persistence failure',
          ),
        ),
      );

      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  test('saved source mismatch rolls back the local message and intent', () {
    final submitted = _message(
      chat: chat,
      text: 'submitted',
      stagingGuid: _guidA,
    );
    final identity = _identity(submitted, chat, _guidA);
    final changed = _message(
      chat: chat,
      guid: 'changed-local-row',
      text: 'changed after capture',
      stagingGuid: _guidA,
    );

    expect(
      () => journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(changed),
        now: _time(2),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_source_changed')),
    );

    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
  });

  test(
    'fresh send stays pending until the post-IDS-success callback marks it ready',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);

      journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );

      var intent = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
      expect(intent.state, 0);
      expect(journal.readReady(), isEmpty);

      // This models the caller invoking the callback after sendMsg succeeds.
      // It is deliberately not evidence of a real IDS or network operation.
      message
        ..guid = _guidA
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: identity,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(3),
      );

      intent = journal.readReady().single;
      expect(intent.state, 1);
      expect(intent.localMessageId, message.id);
      expect(intent.writerEpoch, authoritySnapshot.epoch);
      expect(intent.accountFingerprint, _scope.accountFingerprint);
      expect(store.box<Message>().get(intent.localMessageId)?.guid, _guidA);
    },
  );

  test(
    'restart keeps interrupted pending non-ready and confirmed intent ready',
    () async {
      final pending = _message(
        chat: chat,
        guid: 'pending-local-row',
        stagingGuid: _guidA,
      );
      final pendingIdentity = _identity(pending, chat, _guidA);
      journal.saveSubmission(
        identity: pendingIdentity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(pending),
        now: _time(2),
      );

      final confirmed = _message(
        chat: chat,
        guid: 'confirmed-local-row',
        text: 'confirmed text',
        stagingGuid: _guidB,
      );
      final confirmedIdentity = _identity(confirmed, chat, _guidB);
      journal.saveSubmission(
        identity: confirmedIdentity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(confirmed),
        now: _time(3),
      );
      confirmed
        ..guid = _guidB
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: confirmedIdentity,
        persistMessage: () => store.box<Message>().put(confirmed),
        now: _time(4),
      );

      await reopen();

      final intents = store.box<CloudSyncLocalSendIntentEntity>().getAll();
      expect(intents, hasLength(2));
      expect(intents.where((intent) => intent.state == 0), hasLength(1));
      final ready = journal.readReady();
      expect(ready, hasLength(1));
      expect(ready.single.state, 1);
      expect(
        store.box<Message>().get(ready.single.localMessageId)?.guid,
        _guidB,
      );
    },
  );

  test('stable GUID retries are idempotent before and after confirmation', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    int persist() => store.box<Message>().put(message);

    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: persist,
      now: _time(2),
    );
    final first = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;

    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: false,
      persistMessage: persist,
      now: _time(3),
    );
    message
      ..guid = _guidA
      ..stagingGuid = null;
    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: persist,
      now: _time(4),
    );
    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: persist,
      now: _time(5),
    );

    final only = store.box<CloudSyncLocalSendIntentEntity>().getAll().single;
    expect(only.id, first.id);
    expect(only.localMessageId, message.id);
    expect(only.state, 1);
    expect(only.createdAtMs, _time(2).millisecondsSinceEpoch);
    expect(only.updatedAtMs, _time(5).millisecondsSinceEpoch);
    expect(store.box<Message>().count(), 1);
    expect(journal.readReady(), hasLength(1));
  });

  test(
    'preexisting GUID without an intent cannot gain local origin on retry',
    () {
      final preexisting = _message(chat: chat, guid: _guidA);
      final identity = _identity(preexisting, chat, _guidA);
      final id = store.box<Message>().put(preexisting);
      var callbackInvoked = false;

      expect(
        () => journal.saveSubmission(
          identity: identity,
          newlyGeneratedGuid: false,
          persistMessage: () {
            callbackInvoked = true;
            return id;
          },
          now: _time(2),
        ),
        throwsA(_stateFailure('cloud_sync_local_send_origin_missing')),
      );

      expect(callbackInvoked, isFalse);
      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(journal.readReady(), isEmpty);
    },
  );

  test('account scope drift blocks before local persistence callback', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
    final durable = authorityBox.getAll().single
      ..accountFingerprint = _otherAccount;
    authorityBox.put(durable);
    var callbackInvoked = false;

    expect(
      () => journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () {
          callbackInvoked = true;
          return store.box<Message>().put(message);
        },
        now: _time(2),
      ),
      throwsA(_authorityFailure('cloudkit_writer_authority_scope_collision')),
    );

    expect(callbackInvoked, isFalse);
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
  });

  test('writer epoch drift blocks before local persistence callback', () {
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
    final durable = authorityBox.getAll().single..epoch += 1;
    authorityBox.put(durable);
    var callbackInvoked = false;

    expect(
      () => journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () {
          callbackInvoked = true;
          return store.box<Message>().put(message);
        },
        now: _time(2),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_owner_changed')),
    );

    expect(callbackInvoked, isFalse);
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
  });

  test(
    'same-epoch mutationUnknown still records pending and confirmed local intent',
    () {
      final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
      final durable = authorityBox.getAll().single..state = 4;
      authorityBox.put(durable);
      authoritySnapshot = authority.read(_scope)!;
      expect(
        authoritySnapshot.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );
      journal = CloudSyncLocalSendJournal(
        store: store,
        authority: authority,
        authoritySnapshot: authoritySnapshot,
      );
      final message = _message(chat: chat, stagingGuid: _guidA);
      final identity = _identity(message, chat, _guidA);

      journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );
      expect(journal.readReady(), isEmpty);
      expect(
        store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state,
        0,
      );

      message
        ..guid = _guidA
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: identity,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(3),
      );

      final ready = journal.readReady().single;
      expect(ready.state, 1);
      expect(ready.writerEpoch, authoritySnapshot.epoch);
      expect(ready.localMessageId, message.id);
    },
  );

  test('actual wire text and route bind the same local source', () {
    final message = _message(chat: chat);
    final wire = _wire(chat, text: message.text!);
    final actual = CloudSyncLocalSendIdentity.captureWire(message, chat, wire)!;
    expect(actual.sourceSha256, _identity(message, chat, _guidA).sourceSha256);
  });

  for (final change in <String, void Function(api.MessageInst)>{
    'text frozen before local edit': (wire) {
      (wire.message as api.Message_Message).field0.parts = _parts('old text');
    },
    'sender': (wire) => wire.sender = 'mailto:someone-else@example.com',
    'recipient': (wire) =>
        wire.conversation!.participants[0] = 'mailto:other@example.com',
    'extra participant': (wire) =>
        wire.conversation!.participants.add('mailto:third@example.com'),
    'conversation': (wire) =>
        wire.conversation!.senderGuid = 'iMessage;-;other@example.com',
    'SMS service': (wire) => wire.message = api.Message.message(
      api.NormalMessage(
        parts: _parts('ordinary text'),
        voice: false,
        service: const api.MessageType.sms(
          isPhone: false,
          usingNumber: '+15555550123',
        ),
      ),
    ),
    'formatted text': (wire) {
      (wire.message as api.Message_Message).field0.parts = const api.MessageParts(
        field0: [
          api.IndexedMessagePart(
            part_: api.MessagePart.text(
              'ordinary text',
              api.TextFormat.flags(
                api.TextFlags(
                  bold: true,
                  italic: false,
                  underline: false,
                  strikethrough: false,
                ),
              ),
            ),
          ),
        ],
      );
    },
    'reply': (wire) =>
        (wire.message as api.Message_Message).field0.replyGuid = _guidB,
    'verification failure': (wire) => wire.verificationFailed = true,
  }.entries) {
    test('wire identity rejects changed ${change.key}', () {
      final message = _message(chat: chat);
      final wire = _wire(chat, text: message.text!);
      change.value(wire);
      expect(
        CloudSyncLocalSendIdentity.captureWire(message, chat, wire),
        isNull,
      );
    });
  }

  test(
    'retry cannot mark a changed source as the original submitted payload',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final original = CloudSyncLocalSendIdentity.captureWire(
        message,
        chat,
        _wire(chat),
      )!;
      journal.saveSubmission(
        identity: original,
        newlyGeneratedGuid: true,
        persistMessage: () => store.box<Message>().put(message),
        now: _time(2),
      );
      message
        ..text = 'edited while sending'
        ..attributedBody = [AttributedBody.raw('edited while sending')];
      final rebuilt = CloudSyncLocalSendIdentity.captureWire(
        message,
        chat,
        _wire(chat, text: message.text!),
      )!;
      expect(rebuilt.sourceSha256, isNot(original.sourceSha256));
      message
        ..guid = _guidA
        ..stagingGuid = null;
      expect(
        () => journal.saveConfirmedSubmission(
          identity: rebuilt,
          persistMessage: () => store.box<Message>().put(message),
          now: _time(3),
        ),
        throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
      );
      expect(journal.readReady(), isEmpty);
      expect(store.box<Message>().get(message.id!)!.text, 'ordinary text');
    },
  );

  test(
    'new GUID alone cannot establish local origin for an existing message',
    () {
      bool isFresh(Message message, {String generated = _guidA}) =>
          CloudSyncLocalSendIdentity.isFreshLocalSubmission(
            message,
            generatedGuid: generated,
            stableGuid: _guidA,
          );
      final fresh = _message(chat: chat, guid: 'temp-Abc12345');
      expect(isFresh(fresh), isTrue);
      expect(isFresh(_message(chat: chat, guid: _guidB)), isFalse);
      expect(isFresh(fresh, generated: _guidB), isFalse);
      fresh.stagingGuid = _guidA;
      expect(isFresh(fresh), isFalse);
      fresh
        ..stagingGuid = null
        ..ckRecordId = 'restored';
      expect(isFresh(fresh), isFalse);
    },
  );

  test(
    'auth fence persists synchronously only after matching native proof',
    () async {
      final client = Object();
      final auth = _auth(client);
      var persisted = false;
      await CloudSyncLocalSendAuthFence(
        expected: auth,
        capture: () async => _auth(client),
        stillCurrent: () => true,
      ).run(() => persisted = true);
      expect(persisted, isTrue);
    },
  );

  for (final change in <String, CloudSyncNativeAuthSnapshot? Function(Object)>{
    'same-client account drift': (client) =>
        _auth(client, account: _otherAccount),
    'same-client native session drift': (client) =>
        _auth(client, session: 'new-native-session'),
    'same-client protected store drift': (client) =>
        _auth(client, store: 'obcs2.store.$_otherAccount'),
    'client replacement': (_) => _auth(Object()),
    'missing capture': (_) => null,
  }.entries) {
    test('auth fence rejects ${change.key} before local persistence', () async {
      final client = Object();
      var persisted = false;
      final fence = CloudSyncLocalSendAuthFence(
        expected: _auth(client),
        capture: () async => change.value(client),
        stillCurrent: () => true,
      );
      await expectLater(
        fence.run(() => persisted = true),
        throwsA(_stateFailure('cloud_sync_local_send_identity_changed')),
      );
      expect(persisted, isFalse);
    });
  }

  test('account teardown during native capture prevents persistence', () async {
    final client = Object();
    final captured = Completer<CloudSyncNativeAuthSnapshot?>();
    var active = true;
    var persisted = false;
    final fence = CloudSyncLocalSendAuthFence(
      expected: _auth(client),
      capture: () => captured.future,
      stillCurrent: () => active,
    );
    final result = fence.run(() => persisted = true);
    final assertion = expectLater(
      result,
      throwsA(_stateFailure('cloud_sync_local_send_identity_changed')),
    );
    active = false;
    captured.complete(_auth(client));
    await assertion;
    expect(persisted, isFalse);
  });

  test('native capture failure cannot promote an interrupted send', () async {
    final client = Object();
    final message = _message(chat: chat, stagingGuid: _guidA);
    final identity = _identity(message, chat, _guidA);
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(2),
    );
    message
      ..guid = _guidA
      ..stagingGuid = null;
    final fence = CloudSyncLocalSendAuthFence(
      expected: _auth(client),
      capture: () async => throw TimeoutException('injected'),
      stillCurrent: () => true,
    );
    await expectLater(
      fence.run(
        () => journal.saveConfirmedSubmission(
          identity: identity,
          persistMessage: () => store.box<Message>().put(message),
          now: _time(3),
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await reopen();
    expect(journal.readReady(), isEmpty);
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state,
      0,
    );
  });

  for (final entry in <String, ({Message message, Chat chat}) Function()>{
    'restored CloudKit record': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat)..ckRecordId = 'restored-record',
        chat: shapeChat,
      );
    },
    'previously synced record': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat)..ckSyncState = true,
        chat: shapeChat,
      );
    },
    'SMS': () {
      final shapeChat = _chat(isRpSms: true);
      return (message: _message(chat: shapeChat), chat: shapeChat);
    },
    'group': () {
      final shapeChat = _chat(
        participants: [
          _handle('person@example.com'),
          _handle('second@example.com'),
        ],
      );
      return (message: _message(chat: shapeChat), chat: shapeChat);
    },
    'attachment': () {
      final shapeChat = _chat();
      return (
        message: _message(
          chat: shapeChat,
          attachments: [Attachment(guid: 'attachment-guid')],
        ),
        chat: shapeChat,
      );
    },
    'edit': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat, dateEdited: _time(2)),
        chat: shapeChat,
      );
    },
    'scheduled': () {
      final shapeChat = _chat();
      return (
        message: _message(chat: shapeChat, dateScheduled: _time(2)),
        chat: shapeChat,
      );
    },
    'reaction': () {
      final shapeChat = _chat();
      return (
        message: _message(
          chat: shapeChat,
          associatedMessageGuid: 'parent-message-guid',
        ),
        chat: shapeChat,
      );
    },
  }.entries) {
    test('identity capture rejects unsupported ${entry.key} shape', () {
      final shape = entry.value();
      expect(
        CloudSyncLocalSendIdentity.capture(shape.message, shape.chat, _guidA),
        isNull,
      );
    });
  }

  test(
    'read and delivery receipts plus reaction flag preserve original text identity',
    () {
      final message = _message(chat: chat, stagingGuid: _guidA);
      final original = _identity(message, chat, _guidA);
      final id = store.box<Message>().put(message);

      final updated = store.box<Message>().get(id)!
        ..dateRead = _time(3)
        ..dateDelivered = _time(4)
        ..hasReactions = true;
      store.box<Message>().put(updated);
      final reloaded = store.box<Message>().get(id)!;
      final afterReceipts = _identity(reloaded, reloaded.chat.target!, _guidA);

      expect(afterReceipts.guidHash, original.guidHash);
      expect(afterReceipts.sourceSha256, original.sourceSha256);
      expect(reloaded.text, message.text);
      expect(reloaded.dateRead?.toUtc(), _time(3));
      expect(reloaded.dateDelivered?.toUtc(), _time(4));
      expect(reloaded.hasReactions, isTrue);
    },
  );
}

CloudSyncLocalSendIdentity _identity(
  Message message,
  Chat chat,
  String stableGuid,
) => CloudSyncLocalSendIdentity.capture(message, chat, stableGuid)!;

Message _message({
  required Chat chat,
  String guid = 'local-message-row',
  String text = 'ordinary text',
  String? stagingGuid,
  List<Attachment?> attachments = const [],
  DateTime? dateEdited,
  DateTime? dateScheduled,
  String? associatedMessageGuid,
}) {
  final message = Message(
    guid: guid,
    text: text,
    dateCreated: _time(1),
    isFromMe: true,
    hasAttachments: attachments.isNotEmpty,
    attachments: attachments,
    attributedBody: [AttributedBody.raw(text)],
    stagingGuid: stagingGuid,
    dateEdited: dateEdited,
    dateScheduled: dateScheduled,
    associatedMessageGuid: associatedMessageGuid,
  );
  message.chat.target = chat;
  return message;
}

Chat _chat({bool isRpSms = false, List<Handle>? participants}) {
  final actualParticipants = participants ?? [_handle('person@example.com')];
  final chat = Chat(
    guid: 'iMessage;-;person@example.com',
    chatIdentifier: 'person@example.com',
    usingHandle: 'me@example.com',
    isRpSms: isRpSms,
    style: 45,
    participants: actualParticipants,
  );
  chat.handles.addAll(actualParticipants);
  return chat;
}

Handle _handle(String address) => Handle(
  address: address,
  service: 'iMessage',
  uniqueAddressAndService: '$address/iMessage',
);

void _persistChat(Store store, Chat chat) {
  store.box<Handle>().putMany(chat.handles.toList());
  store.box<Chat>().put(chat);
}

api.MessageParts _parts(String text) => api.MessageParts(
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
);

api.MessageInst _wire(Chat chat, {String text = 'ordinary text'}) =>
    api.MessageInst(
      id: _guidA,
      sender: chat.usingHandle,
      conversation: api.ConversationData(
        participants: ['mailto:${chat.chatIdentifier}', chat.usingHandle!],
        senderGuid: chat.guid,
      ),
      message: api.Message.message(
        api.NormalMessage(
          parts: _parts(text),
          service: const api.MessageType.iMessage(),
          voice: false,
        ),
      ),
      sentTimestamp: 0,
      sendDelivered: true,
      verificationFailed: false,
    );

CloudSyncNativeAuthSnapshot _auth(
  Object client, {
  String account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  String session = 'native-session',
  String store = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: session,
  accountFingerprint: account,
  protectedStoreIdentity: store,
  cloudMessagesClient: client,
);

Matcher _stateFailure(String message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

Matcher _authorityFailure(String safeCode) =>
    isA<CloudKitWriterAuthorityFailure>().having(
      (failure) => failure.safeCode,
      'safeCode',
      safeCode,
    );

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);

final _scope = CloudKitWriterScope(
  accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
const _otherAccount = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _guidB = '22222222-2222-4222-8222-222222222222';
