import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/imessage_reaction_submission.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const _guid = '11111111-1111-4111-8111-111111111111';
const _account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _now = DateTime.utc(2026, 9, 7);

void main() {
  late Directory directory;
  late Store store;
  late CloudSyncLocalSendJournal journal;
  late Chat chat;
  final auth = CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: 'native-session',
    accountFingerprint: _account,
    protectedStoreIdentity:
        'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    cloudMessagesClient: Object(),
  );

  void openJournal() {
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final scope = CloudKitWriterScope(accountFingerprint: _account);
    if (authority.read(scope) == null) {
      final disabled = authority.initializeDisabled(scope, now: _now);
      authority.provisionInitialOwner(
        scope,
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
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(scope)!,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ob-reaction-journal-');
    store = await openStore(directory: directory.path);
    openJournal();
    final peer = Handle(
      address: 'peer@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'peer@example.com/iMessage',
    );
    store.box<Handle>().put(peer);
    chat = Chat(
      guid: 'iMessage;-;peer@example.com',
      chatIdentifier: 'peer@example.com',
      usingHandle: 'mailto:me@example.com',
      style: 45,
      participants: [peer],
    );
    chat.handles.add(peer);
    store.box<Chat>().put(chat);
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    await directory.delete(recursive: true);
  });

  Message draft({String type = 'love', int? part = 0}) {
    final row = Message(
      guid: 'temp-12345678',
      isFromMe: true,
      dateCreated: _now,
      associatedMessageGuid: 'parent-guid',
      associatedMessagePart: part,
      associatedMessageType: type,
    );
    row.chat.target = chat;
    store.box<Message>().put(row);
    return row;
  }

  api.MessageInst wire({bool enable = true, int? part = 0}) => api.MessageInst(
    id: _guid,
    sender: chat.usingHandle,
    conversation: api.ConversationData(
      senderGuid: chat.guid,
      participants: ['mailto:peer@example.com', chat.usingHandle!],
    ),
    message: api.Message.react(
      api.ReactMessage(
        toUuid: 'parent-guid',
        toPart: part,
        toText: 'parent snapshot',
        reaction: api.ReactMessageType.react(
          reaction: const api.Reaction.heart(),
          enable: enable,
        ),
      ),
    ),
    sentTimestamp: _now.millisecondsSinceEpoch,
    sendDelivered: false,
    verificationFailed: false,
  );

  CloudSyncLocalSendIdentity capture(
    Message row, {
    bool enable = true,
    int? part = 0,
  }) {
    final initial = CloudSyncLocalSendIdentity.captureReaction(
      row,
      chat,
      _guid,
    )!;
    return journal.captureReactionSubmissionWire(
      message: row,
      chat: chat,
      wire: wire(enable: enable, part: part),
      initialSourceSha256: initial.sourceSha256,
    )!;
  }

  void save(
    Message row,
    CloudSyncLocalSendIdentity identity, {
    bool fresh = true,
  }) {
    row.stagingGuid = _guid;
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: fresh,
      persistMessage: () => store.box<Message>().put(row),
      now: _now,
    );
  }

  int? confirm({bool succeeded = true}) => journal.recordNativeSendConfirmation(
    stableGuid: _guid,
    succeeded: succeeded,
    capturedAuth: auth,
    stillCurrent: () => true,
    now: _now,
  );

  test('original UI row and intent precede fast native confirmation', () async {
    final row = draft();
    final originalId = row.id;
    final identity = capture(row);
    await submitTrackedIMessageReaction(
      message: row,
      stableGuid: _guid,
      persistPending: () async => save(row, identity),
      send: () async {
        expect(store.box<Message>().count(), 1);
        expect(store.box<Message>().get(originalId!)!.stagingGuid, _guid);
        expect(journal.readReady(), isEmpty);
        final id = confirm()!;
        journal.promoteIdsConfirmedDeferred(
          intentId: id,
          currentAuth: auth,
          now: _now,
        );
        return false;
      },
      persistCompletion: (pending) async {
        expect(pending, isFalse);
        expect(journal.isSubmissionAlreadyConfirmed(identity), isTrue);
      },
    );
    expect(store.box<Message>().count(), 1);
    expect(journal.readReady().single.localMessageId, originalId);
    expect(
      journal.readForAdmission(journal.readReady().single.id).message!.guid,
      _guid,
    );
    expect(confirm(), isNull);
  });

  test('late native success supersedes a local timeout without a new row', () {
    final row = draft();
    final identity = capture(row);
    save(row, identity);
    row
      ..guid = 'error-timeout-12345678'
      ..error = 400;
    store.box<Message>().put(row);
    expect(confirm(succeeded: false), isNull);
    expect(store.box<Message>().get(row.id!)!.error, 400);
    final intentId = confirm()!;
    journal.promoteIdsConfirmedDeferred(
      intentId: intentId,
      currentAuth: auth,
      now: _now,
    );
    expect(store.box<Message>().count(), 1);
    final confirmed = store.box<Message>().get(row.id!)!;
    expect(confirmed.guid, _guid);
    expect(confirmed.stagingGuid, isNull);
    expect(confirmed.error, 0);
    expect(journal.readReady().single.localMessageId, row.id);
  });

  test('same-row UI retry reuses its original journal and source', () {
    final row = draft(type: '-love', part: null);
    final identity = capture(row, enable: false, part: null);
    save(row, identity);
    final intentId = store
        .box<CloudSyncLocalSendIntentEntity>()
        .getAll()
        .single
        .id;
    row
      ..guid = 'error-timeout-12345678'
      ..error = 400;
    prepareIMessageReactionRetry(row);
    row.generateTempGuid();
    final retryIdentity = capture(row, enable: false, part: null);
    expect(retryIdentity.sourceSha256, identity.sourceSha256);
    save(row, retryIdentity, fresh: false);
    expect(store.box<Message>().count(), 1);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
    expect(confirm(), intentId);
    journal.promoteIdsConfirmedDeferred(
      intentId: intentId,
      currentAuth: auth,
      now: _now,
    );
    expect(journal.readReady().single.localMessageId, row.id);
  });

  test('failure and process restart cannot invent send confirmation', () async {
    final row = draft();
    final identity = capture(row);
    save(row, identity);
    expect(confirm(succeeded: false), isNull);
    expect(journal.isSubmissionAlreadyConfirmed(identity), isFalse);
    store.close();
    store = await openStore(directory: directory.path);
    openJournal();
    expect(journal.readReady(), isEmpty);
    expect(journal.readIdsConfirmedDeferred(currentAuth: auth), isEmpty);
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state,
      0,
    );
  });

  test(
    'explicit IDS success survives restart for remove and absent part',
    () async {
      final row = draft(type: '-love', part: null);
      final identity = capture(row, enable: false, part: null);
      save(row, identity);
      final id = confirm()!;
      expect(journal.readReady(), isEmpty);
      store.close();
      store = await openStore(directory: directory.path);
      openJournal();
      expect(journal.readIdsConfirmedDeferred(currentAuth: auth).single.id, id);
      journal.promoteIdsConfirmedDeferred(
        intentId: id,
        currentAuth: auth,
        now: _now,
      );
      final source = journal.readForAdmission(id).message!;
      expect(source.associatedMessageType, '-love');
      expect(source.associatedMessagePart, isNull);
      expect(source.associatedMessageGuid, 'parent-guid');
      expect(confirm(), isNull);
    },
  );

  test('changed parent, part or kind cannot reuse a pending source', () {
    final row = draft();
    save(row, capture(row));
    for (final mutate in <void Function(Message)>[
      (m) => m.associatedMessageGuid = 'different-parent',
      (m) => m.associatedMessagePart = null,
      (m) => m.associatedMessageType = '-love',
    ]) {
      final changed = store.box<Message>().get(row.id!)!;
      mutate(changed);
      store.box<Message>().put(changed);
      expect(confirm, throwsStateError);
      expect(
        store.box<CloudSyncLocalSendIntentEntity>().getAll().single.state,
        0,
      );
      store.box<Message>().put(row);
    }
  });

  test('stable retries cannot invent origin and pending saves roll back', () {
    final row = draft();
    final identity = capture(row);
    expect(() => save(row, identity, fresh: false), throwsStateError);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    expect(store.box<Message>().get(row.id!)!.stagingGuid, isNull);
    save(row, identity);
    save(row, identity, fresh: false);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 1);
  });

  test('plain capture stays closed to reactions and wire mismatches', () {
    final row = draft();
    final identity = capture(row);
    expect(CloudSyncLocalSendIdentity.capture(row, chat, _guid), isNull);
    expect(CloudSyncLocalSendIdentity.captureWire(row, chat, wire()), isNull);
    expect(
      journal.captureReactionSubmissionWire(
        message: row,
        chat: chat,
        wire: wire(part: null),
        initialSourceSha256: identity.sourceSha256,
      ),
      isNull,
    );
    row.associatedMessageType = 'emoji';
    expect(
      CloudSyncLocalSendIdentity.captureReaction(row, chat, _guid),
      isNull,
    );
  });
}
