import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_composer_admission.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late Chat chat;
  late Object client;
  late CloudSyncLocalSendJournal journal;
  late CloudSyncLocalSendAuthFence authFence;

  void bindJournal() {
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
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
    final snapshot = authority.read(_scope)!;
    journal = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: snapshot,
    );
    client = Object();
    final auth = _auth(client);
    authFence = CloudSyncLocalSendAuthFence(
      expected: auth,
      capture: () async => auth,
      stillCurrent: () => !store.isClosed(),
    );
  }

  void persistChat() {
    final participant = Handle(
      address: 'person@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'person@example.com/iMessage',
    );
    store.box<Handle>().put(participant);
    chat = Chat(
      guid: 'iMessage;-;person@example.com',
      chatIdentifier: 'person@example.com',
      usingHandle: 'me@example.com',
      style: 45,
      participants: [participant],
    )..handles.add(participant);
    store.box<Chat>().put(chat);
  }

  Message message() => Message(
    guid: 'temp-12345678',
    text: 'ordinary text',
    attributedBody: [AttributedBody.raw('ordinary text')],
    dateCreated: _time(2),
    isFromMe: true,
  )..chat.target = chat;

  CloudSyncComposerAdmission admission(
    Message source, {
    CloudSyncLocalSendAuthFence? fence,
    String stableGuid = _stableGuid,
  }) => CloudSyncComposerAdmission.captureFresh(
    stableGuid: stableGuid,
    message: source,
    chat: source.chat.target!,
    journal: journal,
    authFence: fence ?? authFence,
    admittedAt: _time(2),
  )!;

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    bindJournal();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-composer-admission-',
    );
    store = await openStore(directory: directory.path);
    bindJournal();
    persistChat();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'legacy composer persistence demonstrates the pre-admission orphan gap',
    () async {
      store.box<Message>().put(message());
      await reopen();

      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  test(
    'injected failure leaves no rows, restores UUID state, and retries once',
    () async {
      final source = message();
      final selected = admission(source);

      await expectLater(
        selected.persist(() {
          store.box<Message>().put(source);
          throw StateError('injected_message_persistence_failure');
        }),
        throwsStateError,
      );

      expect(source.id, isNull);
      expect(source.stagingGuid, isNull);
      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);

      await admission(source).persist(() {
        source.id = store.box<Message>().put(source);
        return source;
      });
      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
      expect(
        CloudSyncLocalSendJournal.hasPendingComposerAdmission(store, source),
        isTrue,
      );
    },
  );

  test(
    'selected admission auth fault propagates without standalone rows',
    () async {
      final source = message();
      final auth = _auth(Object());
      final selected = admission(
        source,
        fence: CloudSyncLocalSendAuthFence(
          expected: auth,
          capture: () async => throw StateError('injected_auth_failure'),
          stillCurrent: () => true,
        ),
      );

      await expectLater(
        selected.persist(() {
          source.id = store.box<Message>().put(source);
          return source;
        }),
        throwsStateError,
      );

      expect(source.id, isNull);
      expect(source.stagingGuid, isNull);
      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  test('URL text is excluded before asynchronous rich-link enrichment', () {
    final source = message()
      ..text = 'https://example.com'
      ..attributedBody = [AttributedBody.raw('https://example.com')];

    expect(CloudSyncComposerAdmission.isPlainTextCandidate(source), isFalse);
    final selected = CloudSyncComposerAdmission.captureFresh(
      stableGuid: _stableGuid,
      message: source,
      chat: chat,
      journal: journal,
      authFence: authFence,
      admittedAt: _time(2),
    );

    expect(selected, isNull);
    expect(source.stagingGuid, isNull);
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
  });

  test('service classifies rich links before strict V2 admission starts', () async {
    final source = await File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsString();
    final method = source.indexOf('prepareCloudSyncV2ComposerAdmission(',
        source.indexOf('class RustPushService'));
    final classifier = source.indexOf(
      'if (!CloudSyncComposerAdmission.isPlainTextCandidate(message)) return null;',
      method,
    );
    final stableAllocation = source.indexOf(
      'final stableGuid = CloudSyncComposerAdmission.selectStableGuid(',
      method,
    );

    expect(method, greaterThanOrEqualTo(0));
    expect(classifier, greaterThan(method));
    expect(stableAllocation, greaterThan(classifier));
  });

  test(
    'success reopens as exactly one Message plus one state-0 intent',
    () async {
      final source = message();
      await admission(source).persist(() {
        source.id = store.box<Message>().put(source);
        return source;
      });
      final messageId = source.id;

      await reopen();

      final messages = store.box<Message>().getAll();
      final intents = store.box<CloudSyncLocalSendIntentEntity>().getAll();
      expect(messages, hasLength(1));
      expect(messages.single.id, messageId);
      expect(messages.single.stagingGuid, _stableGuid);
      expect(intents, hasLength(1));
      expect(intents.single.localMessageId, messageId);
      expect(intents.single.state, 0);
    },
  );

  test(
    'stable retry after reopen does not duplicate Message or intent',
    () async {
      final source = message();
      await admission(source).persist(() {
        source.id = store.box<Message>().put(source);
        return source;
      });
      await reopen();
      final restored = store.box<Message>().getAll().single;
      var allocated = false;
      final selectedStableGuid = CloudSyncComposerAdmission.selectStableGuid(
        store: store,
        message: restored,
        allocate: () {
          allocated = true;
          return '22222222-2222-4222-8222-222222222222';
        },
      );

      expect(selectedStableGuid, _stableGuid);
      expect(allocated, isFalse);
      expect(
        journal.isComposerSubmissionPending(
          CloudSyncLocalSendIdentity.capture(
            restored,
            restored.chat.target!,
            selectedStableGuid!,
          )!,
        ),
        isTrue,
      );

      await admission(restored, stableGuid: selectedStableGuid).persist(() {
        restored.id = store.box<Message>().put(restored);
        return restored;
      });

      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
      expect(
        store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state,
        0,
      );
    },
  );

  test('unrelated preexisting staging UUID is not selected for admission', () {
    final source = message()
      ..stagingGuid = '22222222-2222-4222-8222-222222222222';
    var allocated = false;

    final selectedStableGuid = CloudSyncComposerAdmission.selectStableGuid(
      store: store,
      message: source,
      allocate: () {
        allocated = true;
        return _stableGuid;
      },
    );

    expect(selectedStableGuid, isNull);
    expect(allocated, isFalse);
  });
}

CloudSyncNativeAuthSnapshot _auth(Object client) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'native-session',
      accountFingerprint: _account,
      protectedStoreIdentity: 'obcs2.store.$_account',
      cloudMessagesClient: client,
    );

DateTime _time(int seconds) => DateTime.utc(2026, 9, 8, 12, 0, seconds);

const _account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _stableGuid = '11111111-1111-4111-8111-111111111111';
final _scope = CloudKitWriterScope(accountFingerprint: _account);
const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
