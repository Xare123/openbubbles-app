import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_group_send_route.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_selection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot authoritySnapshot;
  late CloudSyncLocalSendJournal journal;

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
    // Project scratch requirement: unique temp under repo build/, never the
    // shared system temp and never a recursive tree delete.
    directory = Directory(
      '${_scratchRoot().path}/cloud-sync-exact-group-'
      '${DateTime.now().microsecondsSinceEpoch}-$pid',
    );
    directory.createSync(recursive: true);
    store = await openStore(directory: directory.path);
    provisionJournal();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    // Exact ObjectBox artifact cleanup only: data.mdb and lock.mdb.
    for (final name in const ['data.mdb', 'lock.mdb']) {
      final file = File('${directory.path}/$name');
      if (file.existsSync()) file.deleteSync();
    }
    if (directory.existsSync()) {
      try {
        directory.deleteSync();
      } on FileSystemException {
        // Leave unexpected scratch in place rather than deleting blindly.
      }
    }
  });

  CloudSyncLocalSendIntentEntity saveDeferredIdsSuccess({
    required Chat chat,
    String stableGuid = _guidA,
  }) {
    final message = _message(chat: chat, stagingGuid: stableGuid);
    final identity =
        CloudSyncLocalSendIdentity.capture(message, chat, stableGuid)!;
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(2),
    );
    message
      ..guid = stableGuid
      ..stagingGuid = null;
    final intentId = journal.saveIdsConfirmedDeferredSubmission(
      identity: identity,
      capturedAuth: _auth(Object()),
      stillCurrent: () => true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(3),
    );
    return store.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;
  }

  test('group exact selection reads deferred IDS success without promoting',
      () {
    final group = _group();
    _persistChat(store, group);
    final selected = saveDeferredIdsSuccess(chat: group);
    expect(selected.state, 3);
    expect(
      CloudSyncGroupSendRoute.capture(group)!.members,
      ['+15550000002', 'first@example.com'],
    );
    final source = journal.readExactGroupIntent(
      intentId: selected.id,
      expectedChatGuid: group.guid,
      expectedMembers: ['first@example.com', '+15550000002'],
      expectedSender: 'me@example.com',
      expectedSourceSha256: selected.sourceSha256,
    );
    expect(source.intentId, selected.id);
    expect(source.state, 3);
    expect(source.message!.guid, _guidA);
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().get(selected.id)!.state,
      3,
      reason: 'Exact group selection must never promote a journal entry',
    );
  });

  test('group exact selection rejects wrong extra/missing/duplicate member',
      () {
    final group = _group();
    _persistChat(store, group);
    final selected = saveDeferredIdsSuccess(chat: group);
    final members = ['+15550000002', 'first@example.com'];
    for (final badMembers in [
      [...members, 'other@example.com'],
      [members.first],
      [members.first, members.first],
      [...members, 'me@example.com'],
      [members.first, ''],
    ]) {
      expect(
        () => journal.readExactGroupIntent(
          intentId: selected.id,
          expectedChatGuid: group.guid,
          expectedMembers: badMembers,
          expectedSender: 'me@example.com',
          expectedSourceSha256: selected.sourceSha256,
        ),
        _stateFailure('cloud_sync_local_send_selection_changed'),
      );
    }
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().get(selected.id)!.state,
      3,
    );
  });

  test('group exact selection rejects sender/guid/source drift', () {
    final group = _group();
    _persistChat(store, group);
    final selected = saveDeferredIdsSuccess(chat: group);
    final members = ['+15550000002', 'first@example.com'];
    expect(
      () => journal.readExactGroupIntent(
        intentId: selected.id,
        expectedChatGuid: group.guid,
        expectedMembers: members,
        expectedSender: 'someone-else@example.com',
        expectedSourceSha256: selected.sourceSha256,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );
    expect(
      () => journal.readExactGroupIntent(
        intentId: selected.id,
        expectedChatGuid: 'iMessage;+;other-group',
        expectedMembers: members,
        expectedSender: 'me@example.com',
        expectedSourceSha256: selected.sourceSha256,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );
    expect(
      () => journal.readExactGroupIntent(
        intentId: selected.id,
        expectedChatGuid: group.guid,
        expectedMembers: members,
        expectedSender: 'me@example.com',
        expectedSourceSha256: 'b' * 64,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );
    expect(
      () => journal.readExactGroupIntent(
        intentId: selected.id + 100,
        expectedChatGuid: group.guid,
        expectedMembers: members,
        expectedSender: 'me@example.com',
        expectedSourceSha256: selected.sourceSha256,
      ),
      // A missing intent keeps the legacy bound-intent code, same as direct.
      _stateFailure('cloud_sync_local_send_intent_changed'),
    );
    expect(
      () => journal.readExactGroupIntent(
        intentId: selected.id,
        expectedChatGuid: '',
        expectedMembers: const [],
        expectedSender: '',
        expectedSourceSha256: selected.sourceSha256,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );
  });

  test('group exact selection rejects provisional and direct rows', () {
    final provisional = _group()
      ..guid = _originUuid
      ..chatIdentifier = null
      ..style = null;
    _persistChat(store, provisional);
    final provisionalIntent = saveDeferredIdsSuccess(chat: provisional);
    expect(
      CloudSyncGroupSendRoute.capture(
        store.box<Chat>().get(provisional.id!)!,
      )!.provisional,
      isTrue,
    );
    expect(
      () => journal.readExactGroupIntent(
        intentId: provisionalIntent.id,
        expectedChatGuid: _originUuid,
        expectedMembers: ['+15550000002', 'first@example.com'],
        expectedSender: 'me@example.com',
        expectedSourceSha256: provisionalIntent.sourceSha256,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );

    final direct = _directChat();
    _persistChat(store, direct);
    final directIntent = saveDeferredIdsSuccess(chat: direct, stableGuid: _guidB);
    expect(
      () => journal.readExactGroupIntent(
        intentId: directIntent.id,
        expectedChatGuid: direct.guid,
        expectedMembers: ['person@example.com'],
        expectedSender: 'me@example.com',
        expectedSourceSha256: directIntent.sourceSha256,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );
  });

  test('direct exact selection is unchanged and rejects group rows cleanly',
      () {
    final direct = _directChat();
    _persistChat(store, direct);
    final directIntent = saveDeferredIdsSuccess(chat: direct);
    final source = journal.readExactIntent(
      intentId: directIntent.id,
      expectedRecipient: 'person@example.com',
      expectedSourceSha256: directIntent.sourceSha256,
    );
    expect(source.intentId, directIntent.id);
    expect(source.message!.guid, _guidA);

    final group = _group();
    _persistChat(store, group);
    final groupIntent = saveDeferredIdsSuccess(
      chat: group,
      stableGuid: _guidB,
    );
    expect(
      () => journal.readExactIntent(
        intentId: groupIntent.id,
        expectedRecipient: 'first@example.com',
        expectedSourceSha256: groupIntent.sourceSha256,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );
  });

  test('mutating a journaled group row breaks source instead of reselecting',
      () {
    final group = _group();
    _persistChat(store, group);
    final selected = saveDeferredIdsSuccess(chat: group);
    final members = ['+15550000002', 'first@example.com'];
    final changed = store.box<Chat>().get(group.id!)!
      ..handles.add(_handle('other@example.com'));
    store.box<Chat>().put(changed);
    expect(
      () => journal.readExactGroupIntent(
        intentId: selected.id,
        expectedChatGuid: group.guid,
        expectedMembers: members,
        expectedSender: 'me@example.com',
        expectedSourceSha256: selected.sourceSha256,
      ),
      _stateFailure('cloud_sync_local_send_source_changed'),
    );
  });

  test('group selection validates against an empty outbox without adopting',
      () {
    final group = _group();
    _persistChat(store, group);
    final selected = saveDeferredIdsSuccess(chat: group);
    final durable = _durable(store);
    final selection = _groupSelection(selected, group);
    final source = selection.validate(
      store: store,
      journal: journal,
      durable: durable,
      scope: _messageScope,
    );
    expect(source.intentId, selected.id);
    expect(source.admittedOperationId, isNull);
    expect(
      selection.validate(
        store: store,
        journal: journal,
        durable: durable,
        scope: _messageScope,
      ).intentId,
      selected.id,
    );
    expect(
      store.box<CloudSyncLocalSendIntentEntity>().get(selected.id)!.state,
      3,
    );
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  test('group selection rejects an unrelated active chatManateeZone row', () {
    final group = _group();
    _persistChat(store, group);
    final selected = saveDeferredIdsSuccess(chat: group);
    store.box<CloudOutboxOperationEntity>().put(_activeChatRow());
    final durable = _durable(store);
    final selection = _groupSelection(selected, group);
    expect(
      () => selection.validate(
        store: store,
        journal: journal,
        durable: durable,
        scope: _messageScope,
      ),
      _stateFailure('cloud_sync_local_send_unrelated_outbox'),
    );
    expect(
      () => _groupSelection(selected, group).validate(
        store: store,
        journal: journal,
        durable: durable,
        scope: _messageScope,
      ),
      _stateFailure('cloud_sync_local_send_unrelated_outbox'),
    );
    expect(
      store.box<CloudOutboxOperationEntity>().getAll().single.state,
      CloudOutboxStatus.pending.index,
    );
  });

  test('group selection pins settled audit rows through existing predicates',
      () {
    final group = _group();
    _persistChat(store, group);
    final selected = saveDeferredIdsSuccess(chat: group);
    store.box<CloudOutboxOperationEntity>().put(_settledAuditRow());
    final durable = _durable(store);
    final selection = _groupSelection(selected, group);
    expect(
      selection.validate(
        store: store,
        journal: journal,
        durable: durable,
        scope: _messageScope,
      ).intentId,
      selected.id,
    );
    expect(selection.isInertAuditOperation('settled-audit-op'), isTrue);
    expect(
      selection.validate(
        store: store,
        journal: journal,
        durable: durable,
        scope: _messageScope,
      ).intentId,
      selected.id,
    );
    final mutated = store.box<CloudOutboxOperationEntity>().getAll().single
      ..attemptCount = 1;
    store.box<CloudOutboxOperationEntity>().put(mutated);
    expect(
      () => selection.validate(
        store: store,
        journal: journal,
        durable: durable,
        scope: _messageScope,
      ),
      _stateFailure('cloud_sync_local_send_selection_changed'),
    );
    final reselected = _groupSelection(selected, group).validate(
      store: store,
      journal: journal,
      durable: durable,
      scope: _messageScope,
    );
    expect(reselected.intentId, selected.id);
  });
}

Message _message({
  required Chat chat,
  String guid = 'local-message-row',
  String text = 'ordinary text',
  String? stagingGuid,
}) {
  final message = Message(
    guid: guid,
    text: text,
    dateCreated: _time(1),
    isFromMe: true,
    attributedBody: [AttributedBody.raw(text)],
    stagingGuid: stagingGuid,
  );
  message.chat.target = chat;
  return message;
}

Chat _group() {
  final participants = [
    _handle('first@example.com'),
    _handle('+15550000002'),
  ];
  final chat = Chat(
    guid: 'iMessage;+;chat-group',
    chatIdentifier: 'chat-group',
    usingHandle: 'me@example.com',
    style: 43,
    participants: participants,
  );
  chat.handles.addAll(participants);
  return chat;
}

Chat _directChat() {
  final participants = [_handle('person@example.com')];
  final chat = Chat(
    guid: 'iMessage;-;person@example.com',
    chatIdentifier: 'person@example.com',
    usingHandle: 'me@example.com',
    style: 45,
    participants: participants,
  );
  chat.handles.addAll(participants);
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

/// Repo build/ scratch root derived from this test file's location, so runs
/// never touch the shared system temp or the user's Desktop.
Directory _scratchRoot() {
  final testFile = File(Platform.script.toFilePath());
  // test/services/cloud_sync/<file>.dart -> up three levels to project root.
  final root = testFile.parent.parent.parent.parent;
  final build = Directory('${root.path}/build');
  build.createSync(recursive: true);
  return build;
}

CloudSyncNativeAuthSnapshot _auth(
  Object client, {
  String account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  String session = 'native-session',
  String store = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
}) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: session,
      accountFingerprint: account,
      protectedStoreIdentity: store,
      cloudMessagesClient: client,
    );

Matcher _stateFailure(String message) =>
    throwsA(isA<StateError>().having((error) => error.message, 'message', message));

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);

final _scope = CloudKitWriterScope(
  accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
const _guidA = '11111111-1111-4111-8111-111111111111';
const _guidB = '22222222-2222-4222-8222-222222222222';
const _originUuid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';

const _account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final _messageScope = CloudSyncScope(
  accountFingerprint: _account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

ObjectBoxCloudSyncStore _durable(Store store) => ObjectBoxCloudSyncStore(
      store: store,
      protector: _GroupTestProtector(),
      clock: () => _time(0),
    );

CloudSyncLocalSendExactSelection _groupSelection(
  CloudSyncLocalSendIntentEntity intent,
  Chat group,
) =>
    CloudSyncLocalSendExactSelection.group(
      intentId: intent.id,
      expectedChatGuid: group.guid,
      expectedMembers: ['+15550000002', 'first@example.com'],
      expectedSender: 'me@example.com',
      expectedSourceSha256: intent.sourceSha256,
    );

CloudOutboxOperationEntity _activeChatRow() => CloudOutboxOperationEntity(
      operationId: 'unrelated-chat-op',
      scopeKey: 'unrelated-chat-scope',
      accountFingerprint: _account,
      zone: 'chatManateeZone',
      logicalEntityKeyHash: 'unrelated-chat-logical',
      action: CloudOutboxAction.save.index,
      mutationRevision: 0,
      state: CloudOutboxStatus.pending.index,
      createdAtMs: _time(1).millisecondsSinceEpoch,
      updatedAtMs: _time(1).millisecondsSinceEpoch,
    );

CloudOutboxOperationEntity _settledAuditRow() => CloudOutboxOperationEntity(
      operationId: 'settled-audit-op',
      scopeKey: 'settled-message-scope',
      accountFingerprint: _account,
      zone: 'messageManateeZone',
      logicalEntityKeyHash: 'settled-message-logical',
      action: CloudOutboxAction.save.index,
      mutationRevision: 0,
      checkpointGeneration: 1,
      encryptedPayloadRef: 'obcs2.ref.NaN',
      payloadSha256: 'e' * 64,
      serverRecordIdHash: 'S' * 43,
      state: CloudOutboxStatus.confirmed.index,
      confirmedAtMs: _time(2).millisecondsSinceEpoch,
      createdAtMs: _time(1).millisecondsSinceEpoch,
      updatedAtMs: _time(2).millisecondsSinceEpoch,
    );

final class _GroupTestProtector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      sha256.convert(utf8.encode(rawAccountIdentifier)).toString();
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async =>
      'protected:$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async =>
      ciphertext.substring('protected:'.length);
}
