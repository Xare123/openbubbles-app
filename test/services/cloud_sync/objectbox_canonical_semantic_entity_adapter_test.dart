import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

const _defaultChatHash = 'chat-hash';
const _defaultMessageHash = 'message-hash';

void main() {
  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'container',
    database: 'private',
    zone: 'messageManateeZone',
  );
  const generation = 4;
  const chatHash = 'chat-hash';
  const messageHash = 'message-hash';
  late Directory directory;
  late Store store;
  late _Resolver resolver;
  late CloudCanonicalActiveScope? activeScope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-canonical-adapter-',
    );
    store = await openStore(directory: directory.path);
    resolver = _Resolver()
      ..put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'chat-guid',
      )
      ..put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: 'message-guid',
      );
    activeScope = CloudCanonicalActiveScope(
      scope: scope,
      generation: generation,
    );
  });

  tearDown(() async {
    store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('is default-off even when the active scope and identity resolve', () {
    store.box<Chat>().put(Chat(guid: 'chat-guid'));
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
    );

    expect(
      adapter.isActiveAccountScope(scope: scope, generation: generation),
      isFalse,
    );
    expect(
      adapter.entityExists(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: chatHash,
      ),
      isFalse,
    );
  });

  test(
    'uses exact scope, generation, kind, and resolved canonical identity',
    () {
      store.box<Chat>().put(Chat(guid: 'chat-guid'));
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
      );

      expect(
        adapter.entityExists(
          scope: scope,
          generation: generation,
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: chatHash,
        ),
        isTrue,
      );
      expect(
        adapter.entityExists(
          scope: scope,
          generation: generation + 1,
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: chatHash,
        ),
        isFalse,
      );
      expect(
        adapter.entityExists(
          scope: scope,
          generation: generation,
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: chatHash,
        ),
        isFalse,
      );
      activeScope = null;
      expect(
        adapter.entityExists(
          scope: scope,
          generation: generation,
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: chatHash,
        ),
        isFalse,
      );
    },
  );

  test('creates a chat and replays the same payload idempotently', () {
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );
    final payload = _chatPayload(
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: 'iMessage;-;chat-guid',
      displayName: 'Created chat',
      participantHandles: const [
        'mailto:alice@example.com',
        'tel:+19492476163',
      ],
      groupVersion: 1,
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    final chats = store.box<Chat>().getAll();
    expect(chats, hasLength(1));
    expect(chats.single.guid, 'chat-guid');
    expect(chats.single.style, 45);
    expect(chats.single.displayName, 'Created chat');
    expect(chats.single.groupVersion, 1);
    expect(chats.single.handles.map((handle) => handle.address).toSet(), {
      'alice@example.com',
      '+19492476163',
    });
    expect(store.box<Handle>().count(), 2);
  });

  test('rejects an exact chat-alias conflict without creating rows', () {
    store.box<Chat>().put(
      Chat(
        guid: 'different-chat-guid',
        chatIdentifier: 'iMessage;-;shared-alias',
      ),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: chatHash,
          canonicalGuid: 'chat-guid',
          chatIdentifier: 'iMessage;-;shared-alias',
        ),
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_chat_alias_conflict',
        ),
      ),
    );
    expect(store.box<Chat>().count(), 1);
    expect(store.box<Handle>().count(), 0);
  });

  test('rejects a resolver canonical GUID mismatch without creating rows', () {
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: chatHash,
          canonicalGuid: 'unresolved-chat-guid',
          chatIdentifier: 'iMessage;-;mismatch',
        ),
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_identity_mismatch',
        ),
      ),
    );
    expect(store.box<Chat>().count(), 0);
    expect(store.box<Handle>().count(), 0);
  });

  test('maps direct chats to style 45 and group chats to style 43', () {
    const groupHash = 'group-chat-hash';
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: groupHash,
      canonicalGuid: 'group-chat-guid',
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: _chatPayload(
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'chat-guid',
        chatIdentifier: 'iMessage;-;direct',
      ),
      snapshot: _snapshot(CloudEntityKind.chat, chatHash),
    );
    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: _chatPayload(
        logicalEntityKeyHash: groupHash,
        canonicalGuid: 'group-chat-guid',
        chatIdentifier: 'iMessage;+;group',
        style: CloudSemanticChatStyle.group,
      ),
      snapshot: _snapshot(CloudEntityKind.chat, groupHash),
    );

    final chats = store.box<Chat>().getAll();
    expect(chats.singleWhere((chat) => chat.guid == 'chat-guid').style, 45);
    expect(
      chats.singleWhere((chat) => chat.guid == 'group-chat-guid').style,
      43,
    );
  });

  test(
    'normalizes and deduplicates participant handles in the chat relation',
    () {
      const participantsHash = 'participants-chat-hash';
      resolver.put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: participantsHash,
        canonicalGuid: 'participants-chat-guid',
      );
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
        allowChatUpserts: true,
      );

      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: participantsHash,
          canonicalGuid: 'participants-chat-guid',
          chatIdentifier: 'iMessage;+;participants',
          style: CloudSemanticChatStyle.group,
          participantHandles: const [
            'mailto:alice@example.com',
            'alice@example.com',
            'tel:+19492476163',
            '+19492476163',
          ],
        ),
        snapshot: _snapshot(CloudEntityKind.chat, participantsHash),
      );

      final chat = store.box<Chat>().getAll().single;
      expect(store.box<Handle>().count(), 2);
      expect(chat.handles, hasLength(2));
      expect(chat.handles.map((handle) => handle.address).toSet(), {
        'alice@example.com',
        '+19492476163',
      });
      expect(
        chat.handles.map((handle) => handle.uniqueAddressAndService).toSet(),
        {'alice@example.com/iMessage', '+19492476163/iMessage'},
      );
    },
  );

  test('replaces participants only on create or a higher group version', () {
    const versionedHash = 'versioned-chat-hash';
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: versionedHash,
      canonicalGuid: 'versioned-chat-guid',
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    void apply(int version, String participant) {
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: versionedHash,
          canonicalGuid: 'versioned-chat-guid',
          chatIdentifier: 'iMessage;+;versioned',
          style: CloudSemanticChatStyle.group,
          groupVersion: version,
          participantHandles: [participant],
        ),
        snapshot: _snapshot(CloudEntityKind.chat, versionedHash),
      );
    }

    apply(2, 'mailto:alice@example.com');
    apply(2, 'mailto:bob@example.com');
    expect(
      store.box<Chat>().getAll().single.handles.map((handle) => handle.address),
      ['alice@example.com'],
    );
    apply(1, 'mailto:charlie@example.com');
    expect(
      store.box<Chat>().getAll().single.handles.map((handle) => handle.address),
      ['alice@example.com'],
    );
    apply(3, 'mailto:bob@example.com');
    final chat = store.box<Chat>().getAll().single;
    expect(chat.groupVersion, 3);
    expect(chat.handles.map((handle) => handle.address), ['bob@example.com']);
  });

  test('preserves a locally locked display name during a chat upsert', () {
    store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'iMessage;-;locked',
        displayName: 'Local name',
        lockChatName: true,
        style: 45,
      ),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: _chatPayload(
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'chat-guid',
        chatIdentifier: 'iMessage;-;locked',
        displayName: 'Cloud name',
      ),
      snapshot: _snapshot(CloudEntityKind.chat, chatHash),
    );

    expect(store.box<Chat>().getAll().single.displayName, 'Local name');
  });

  test('blocks explicit display-name clear unless its separate gate is on', () {
    store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'iMessage;-;clear',
        displayName: 'Keep until verified',
        style: 45,
      ),
    );
    final payload = _chatPayload(
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: 'iMessage;-;clear',
      displayName: null,
      displayNameState: CloudSemanticFieldState.explicitClear,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode ==
              'canonical_chat_display_name_clear_unverified',
        ),
      ),
    );
    expect(
      store.box<Chat>().getAll().single.displayName,
      'Keep until verified',
    );

    final clearEnabledAdapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
      allowExistingChatDisplayNameClears: true,
    );
    clearEnabledAdapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: payload,
      snapshot: _snapshot(CloudEntityKind.chat, chatHash),
    );
    expect(store.box<Chat>().getAll().single.displayName, isNull);
  });

  test(
    'rolls back participant and chat rows when a participant is invalid',
    () {
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
        allowChatUpserts: true,
      );

      expect(
        () => store.runInTransaction(TxMode.write, () {
          adapter.applyEntity(
            scope: scope,
            generation: generation,
            payload: _chatPayload(
              logicalEntityKeyHash: chatHash,
              canonicalGuid: 'chat-guid',
              chatIdentifier: 'iMessage;+;invalid',
              participantHandles: const [
                'mailto:valid@example.com',
                'not a valid participant',
              ],
            ),
            snapshot: _snapshot(CloudEntityKind.chat, chatHash),
          );
        }),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) =>
                failure.safeCode == 'canonical_chat_participant_invalid',
          ),
        ),
      );
      expect(store.box<Chat>().count(), 0);
      expect(store.box<Handle>().count(), 0);
    },
  );

  test('creates and idempotently replays a message into its exact chat', () {
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'iMessage;-;message-chat',
        style: 45,
      ),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );
    final createdAt = testEpoch.add(const Duration(milliseconds: 100));
    final readAt = createdAt.add(const Duration(milliseconds: 200));
    final deliveredAt = createdAt.add(const Duration(milliseconds: 100));
    final payload = _messagePayload(
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
      chatIdentifier: 'iMessage;-;message-chat',
      createdAt: createdAt,
      subject: 'Subject',
      body: 'A😀B',
      senderHandle: 'mailto:sender@example.com',
      readAt: readAt,
      deliveredAt: deliveredAt,
      effect: 'com.apple.messages.effect.CKConfettiEffect',
      attributedBodies: [
        CloudSemanticAttributedBody(
          text: 'A😀B',
          runs: [
            CloudSemanticTextRun(
              startUtf16: 1,
              lengthUtf16: 2,
              messagePart: 0,
              attachmentCanonicalGuid: null,
              attachmentLogicalKeyHash: null,
              mentionHandle: null,
              audioTranscript: null,
              textEffect: null,
              bold: true,
              italic: null,
              strikethrough: null,
              underline: null,
            ),
          ],
        ),
      ],
      knownFlags: _messageFlags(
        fromMe: false,
        delivered: true,
        read: true,
        hasDataDetectorResults: true,
        deliveredQuietly: true,
        didNotifyRecipient: true,
      ),
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    final chat = store.box<Chat>().get(chatId)!;
    final messages = store.box<Message>().getAll();
    expect(messages, hasLength(1));
    final message = messages.single;
    expect(message.guid, 'message-guid');
    expect(message.chat.targetId, chat.id);
    expect(message.text, 'A😀B');
    expect(message.subject, 'Subject');
    expect(message.isFromMe, isFalse);
    expect(message.hasDdResults, isTrue);
    expect(message.wasDeliveredQuietly, isTrue);
    expect(message.didNotifyRecipient, isTrue);
    expect(message.isDelivered, isTrue);
    expect(message.dateRead?.toUtc(), readAt);
    expect(message.dateDelivered?.toUtc(), deliveredAt);
    expect(
      message.expressiveSendStyleId,
      'com.apple.messages.effect.CKConfettiEffect',
    );
    expect(message.attributedBody, hasLength(1));
    expect(message.attributedBody.single.string, 'A😀B');
    expect(message.attributedBody.single.runs.single.range, [1, 2]);
    expect(message.attributedBody.single.runs.single.attributes?.bold, isTrue);

    final sender =
        store
            .box<Handle>()
            .query(
              Handle_.uniqueAddressAndService.equals(
                'sender@example.com/iMessage',
              ),
            )
            .build()
          ..limit = 1;
    try {
      final senderHandle = sender.findFirst();
      expect(senderHandle, isNotNull);
      expect(message.handleId, senderHandle!.id);
    } finally {
      sender.close();
    }
  });

  test('preserves createdAt and monotonically merges message dates', () {
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'iMessage;-;monotonic-chat',
        style: 45,
      ),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );
    final createdAt = testEpoch.add(const Duration(milliseconds: 500));
    final firstRead = createdAt.add(const Duration(seconds: 1));
    final firstDelivered = createdAt.add(const Duration(seconds: 2));
    final secondRead = createdAt.add(const Duration(seconds: 4));
    final secondDelivered = createdAt.add(const Duration(seconds: 5));

    void apply({
      required String body,
      required DateTime readAt,
      required DateTime deliveredAt,
    }) {
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: 'iMessage;-;monotonic-chat',
          createdAt: createdAt,
          body: body,
          readAt: readAt,
          deliveredAt: deliveredAt,
          knownFlags: _messageFlags(fromMe: false, delivered: true, read: true),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      );
    }

    apply(body: 'first', readAt: firstRead, deliveredAt: firstDelivered);
    final firstId = store.box<Message>().getAll().single.id;
    apply(body: 'second', readAt: secondRead, deliveredAt: secondDelivered);
    apply(body: 'older', readAt: firstRead, deliveredAt: firstDelivered);

    final chat = store.box<Chat>().get(chatId)!;
    final message = store.box<Message>().getAll().single;
    expect(message.id, firstId);
    expect(message.chat.targetId, chat.id);
    expect(message.dateCreated?.toUtc(), createdAt);
    expect(message.text, 'older');
    expect(message.dateRead?.toUtc(), secondRead);
    expect(message.dateDelivered?.toUtc(), secondDelivered);
  });

  test('message replay cannot hide an already-linked attachment', () {
    final chat = Chat(
      guid: 'chat-guid',
      chatIdentifier: 'iMessage;-;attachment-owner-chat',
      style: 45,
    );
    store.box<Chat>().put(chat);
    final message = Message(
      guid: 'message-guid',
      dateCreated: testEpoch,
      isFromMe: false,
      hasAttachments: true,
    )..chat.target = chat;
    final messageId = store.box<Message>().put(message);
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: _messagePayload(
        logicalEntityKeyHash: messageHash,
        canonicalGuid: 'message-guid',
        chatIdentifier: 'iMessage;-;attachment-owner-chat',
        attributedBodiesState: CloudSemanticFieldState.absent,
        knownFlags: _messageFlags(fromMe: false),
      ),
      snapshot: _snapshot(CloudEntityKind.message, messageHash),
    );

    expect(store.box<Message>().get(messageId)!.hasAttachments, isTrue);
  });

  test('rejects message chat and resolver mismatches without mutation', () {
    final firstChatId = store.box<Chat>().put(
      Chat(
        guid: 'first-chat-guid',
        chatIdentifier: 'iMessage;-;first-chat',
        style: 45,
      ),
    );
    store.box<Chat>().put(
      Chat(
        guid: 'second-chat-guid',
        chatIdentifier: 'iMessage;-;second-chat',
        style: 45,
      ),
    );
    final existing = Message(
      guid: 'message-guid',
      dateCreated: testEpoch,
      isFromMe: false,
      text: 'original',
    )..chat.targetId = firstChatId;
    store.box<Message>().put(existing);
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    expect(
      () => store.runInTransaction(TxMode.write, () {
        adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: _messagePayload(
            logicalEntityKeyHash: messageHash,
            canonicalGuid: 'message-guid',
            chatIdentifier: 'iMessage;-;second-chat',
            createdAt: testEpoch,
            senderHandle: 'mailto:new-sender@example.com',
            knownFlags: _messageFlags(fromMe: false),
          ),
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        );
      }),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_conflict',
        ),
      ),
    );
    expect(store.box<Message>().count(), 1);
    expect(store.box<Handle>().count(), 0);
    expect(store.box<Message>().getAll().single.text, 'original');
    expect(store.box<Message>().getAll().single.chat.targetId, firstChatId);

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'wrong-message-guid',
          chatIdentifier: 'iMessage;-;first-chat',
          createdAt: testEpoch,
          knownFlags: _messageFlags(fromMe: false),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_identity_mismatch',
        ),
      ),
    );
    expect(store.box<Message>().count(), 1);
    expect(store.box<Handle>().count(), 0);
  });

  test('rolls back a message and sender handle for a malformed text range', () {
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'iMessage;-;range-chat',
        style: 45,
      ),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );
    final payload = _messagePayload(
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
      chatIdentifier: 'iMessage;-;range-chat',
      createdAt: testEpoch,
      senderHandle: 'mailto:range-sender@example.com',
      attributedBodies: [
        CloudSemanticAttributedBody(
          text: 'Hi',
          runs: [
            CloudSemanticTextRun(
              startUtf16: 1,
              lengthUtf16: 2,
              messagePart: 0,
              attachmentCanonicalGuid: null,
              attachmentLogicalKeyHash: null,
              mentionHandle: null,
              audioTranscript: null,
              textEffect: null,
              bold: null,
              italic: null,
              strikethrough: null,
              underline: null,
            ),
          ],
        ),
      ],
      knownFlags: _messageFlags(fromMe: false),
    );

    expect(
      () => store.runInTransaction(TxMode.write, () {
        adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: payload,
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        );
      }),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_message_text_range_invalid',
        ),
      ),
    );
    expect(store.box<Chat>().get(chatId), isNotNull);
    expect(store.box<Message>().count(), 0);
    expect(store.box<Handle>().count(), 0);
  });

  test('blocks decoded extension values before message mutation', () {
    store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'iMessage;-;extension-chat',
        style: 45,
      ),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: 'iMessage;-;extension-chat',
          createdAt: testEpoch,
          decodedExtensionPayload: Uint8List.fromList([1, 2, 3]),
          knownFlags: _messageFlags(fromMe: false),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_message_extension_decode_required',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Handle>().count(), 0);
  });

  test(
    'creates and idempotently attaches a reaction to its bare parent GUID',
    () {
      const reactionHash = 'reaction-hash';
      resolver.put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.reaction,
        logicalEntityKeyHash: reactionHash,
        canonicalGuid: 'reaction-guid',
      );
      final chatId = store.box<Chat>().put(
        Chat(
          guid: 'chat-guid',
          chatIdentifier: 'iMessage;-;reaction-chat',
          style: 45,
        ),
      );
      final parent = Message(
        guid: 'message-guid',
        dateCreated: testEpoch,
        isFromMe: false,
      )..chat.targetId = chatId;
      final parentId = store.box<Message>().put(parent);
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
        allowReactionUpserts: true,
      );
      final payload = _reactionPayload(
        logicalEntityKeyHash: reactionHash,
        canonicalGuid: 'reaction-guid',
        parentPart: 3,
        parentCanonicalGuid: 'message-guid',
        senderHandle: 'mailto:reactor@example.com',
        reactionType: 'emoji',
        associatedEmoji: '❤️',
        knownFlags: _messageFlags(fromMe: false, delivered: true),
      );

      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(
          CloudEntityKind.reaction,
          reactionHash,
          parentLogicalKeyHash: messageHash,
        ),
      );
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(
          CloudEntityKind.reaction,
          reactionHash,
          parentLogicalKeyHash: messageHash,
        ),
      );

      final messages = store.box<Message>().getAll();
      expect(messages, hasLength(2));
      final reaction = messages.singleWhere(
        (message) => message.guid == 'reaction-guid',
      );
      final savedParent = store.box<Message>().get(parentId)!;
      expect(reaction.chat.targetId, chatId);
      expect(reaction.associatedMessageGuid, 'message-guid');
      expect(reaction.associatedMessagePart, 3);
      expect(reaction.associatedMessageType, 'emoji');
      expect(reaction.associatedMessageEmoji, '❤️');
      expect(reaction.isDelivered, isTrue);
      expect(savedParent.hasReactions, isTrue);
      expect(store.box<Handle>().count(), 1);
    },
  );

  test('preserves a negative removal reaction type', () {
    const reactionHash = 'removal-reaction-hash';
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.reaction,
      logicalEntityKeyHash: reactionHash,
      canonicalGuid: 'removal-reaction-guid',
    );
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'iMessage;-;removal-chat',
        style: 45,
      ),
    );
    final parent = Message(
      guid: 'message-guid',
      dateCreated: testEpoch,
      isFromMe: false,
    )..chat.targetId = chatId;
    store.box<Message>().put(parent);
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowReactionUpserts: true,
    );

    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: _reactionPayload(
        logicalEntityKeyHash: reactionHash,
        canonicalGuid: 'removal-reaction-guid',
        parentCanonicalGuid: 'message-guid',
        parentPart: 1,
        reactionType: '-like',
        associatedEmoji: null,
        knownFlags: _messageFlags(fromMe: false),
      ),
      snapshot: _snapshot(
        CloudEntityKind.reaction,
        reactionHash,
        parentLogicalKeyHash: messageHash,
      ),
    );

    final reaction = store.box<Message>().getAll().singleWhere(
      (message) => message.guid == 'removal-reaction-guid',
    );
    expect(reaction.associatedMessageType, '-like');
    expect(reaction.associatedMessageEmoji, isNull);
  });

  test('rejects missing and mismatched reaction parents without an orphan', () {
    const reactionHash = 'orphan-reaction-hash';
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.reaction,
      logicalEntityKeyHash: reactionHash,
      canonicalGuid: 'orphan-reaction-guid',
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowReactionUpserts: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _reactionPayload(
          logicalEntityKeyHash: reactionHash,
          canonicalGuid: 'orphan-reaction-guid',
          parentCanonicalGuid: 'message-guid',
          knownFlags: _messageFlags(fromMe: false),
        ),
        snapshot: _snapshot(
          CloudEntityKind.reaction,
          reactionHash,
          parentLogicalKeyHash: messageHash,
        ),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_reaction_parent_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Handle>().count(), 0);

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _reactionPayload(
          logicalEntityKeyHash: reactionHash,
          canonicalGuid: 'orphan-reaction-guid',
          parentCanonicalGuid: 'wrong-parent-guid',
          knownFlags: _messageFlags(fromMe: false),
        ),
        snapshot: _snapshot(
          CloudEntityKind.reaction,
          reactionHash,
          parentLogicalKeyHash: messageHash,
        ),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_identity_mismatch',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Handle>().count(), 0);
  });

  test('creates and idempotently replays owned attachment metadata', () {
    const ownerLogicalKeyHash = 'attachment-owner-message-hash';
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: ownerLogicalKeyHash,
      canonicalGuid: 'message_guid_with_underscores',
    );
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: 'attachment-hash',
      canonicalGuid: 'message_guid_with_underscores_2',
    );
    final owner = Message(
      guid: 'message_guid_with_underscores',
      dateCreated: testEpoch,
      isFromMe: false,
    );
    final ownerId = store.box<Message>().put(owner);
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowAttachmentMetadataUpserts: true,
    );
    final payload = _attachmentPayload(
      logicalEntityKeyHash: 'attachment-hash',
      canonicalGuid: 'message_guid_with_underscores_2',
      ownerLogicalKeyHash: ownerLogicalKeyHash,
      ownerCanonicalGuid: 'message_guid_with_underscores',
      ownerPart: 2,
      utiState: CloudSemanticFieldState.value,
      uti: 'public.data',
      fileName: 'report.pdf',
      mimeType: 'application/pdf',
      totalBytesState: CloudSemanticFieldState.value,
      totalBytes: 4096,
      isOutgoingState: CloudSemanticFieldState.value,
      isOutgoing: true,
      protectedLocalReference: 'protected:must-not-persist',
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          'attachment-hash',
          parentLogicalKeyHash: ownerLogicalKeyHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          'attachment-hash',
          parentLogicalKeyHash: ownerLogicalKeyHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    final attachments = store.box<Attachment>().getAll();
    expect(attachments, hasLength(1));
    final attachment = attachments.single;
    expect(attachment.guid, 'message_guid_with_underscores_2');
    expect(attachment.uti, 'public.data');
    expect(attachment.transferName, 'report.pdf');
    expect(attachment.mimeType, 'application/pdf');
    expect(attachment.totalBytes, 4096);
    expect(attachment.isOutgoing, isTrue);
    expect(attachment.message.targetId, ownerId);
    expect(store.box<Message>().get(ownerId)!.hasAttachments, isTrue);
    expect(attachment.ckRecordId, isNull);
    expect(attachment.metadata, isNull);
    expect(attachment.bytes, isNull);
    expect(attachment.sourcePath, isNull);
  });

  test('creates a standalone attachment without inventing an owner', () {
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: 'standalone-attachment-hash',
      canonicalGuid: 'standalone_attachment_with_underscores',
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowAttachmentMetadataUpserts: true,
    );

    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: _attachmentPayload(
        logicalEntityKeyHash: 'standalone-attachment-hash',
        canonicalGuid: 'standalone_attachment_with_underscores',
        ownerLogicalKeyHash: null,
        ownerCanonicalGuid: null,
        ownerPart: null,
        fileName: 'standalone.bin',
        mimeType: 'application/octet-stream',
        protectedLocalReference: 'protected:standalone',
      ),
      snapshot: _snapshot(
        CloudEntityKind.attachment,
        'standalone-attachment-hash',
      ),
    );

    final attachment = store.box<Attachment>().getAll().single;
    expect(attachment.guid, 'standalone_attachment_with_underscores');
    expect(attachment.message.targetId, 0);
    expect(store.box<Message>().count(), 0);
    expect(attachment.ckRecordId, isNull);
    expect(attachment.metadata, isNull);
  });

  test('rolls back owner and resolver identity mismatches', () {
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: 'attachment-mismatch-hash',
      canonicalGuid: 'message-guid_3',
    );
    store.box<Message>().put(
      Message(guid: 'message-guid', dateCreated: testEpoch, isFromMe: false),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowAttachmentMetadataUpserts: true,
    );

    expect(
      () => store.runInTransaction(TxMode.write, () {
        adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: _attachmentPayload(
            logicalEntityKeyHash: 'attachment-mismatch-hash',
            canonicalGuid: 'message-guid_3',
            ownerLogicalKeyHash: messageHash,
            ownerCanonicalGuid: 'message-guid',
            ownerPart: 2,
            protectedLocalReference: 'protected:owner-mismatch',
          ),
          snapshot: _snapshot(
            CloudEntityKind.attachment,
            'attachment-mismatch-hash',
            parentLogicalKeyHash: messageHash,
          ),
        );
      }),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_attachment_owner_conflict',
        ),
      ),
    );
    expect(store.box<Attachment>().count(), 0);
    expect(store.box<Handle>().count(), 0);

    expect(
      () => store.runInTransaction(TxMode.write, () {
        adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: _attachmentPayload(
            logicalEntityKeyHash: 'attachment-mismatch-hash',
            canonicalGuid: 'wrong-attachment-guid',
            ownerLogicalKeyHash: messageHash,
            ownerCanonicalGuid: 'message-guid',
            ownerPart: 3,
            protectedLocalReference: 'protected:resolver-mismatch',
          ),
          snapshot: _snapshot(
            CloudEntityKind.attachment,
            'attachment-mismatch-hash',
            parentLogicalKeyHash: messageHash,
          ),
        );
      }),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_identity_mismatch',
        ),
      ),
    );
    expect(store.box<Attachment>().count(), 0);
    expect(store.box<Handle>().count(), 0);
  });

  test('rejects an existing attachment relation conflict without mutation', () {
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: 'relation-conflict-hash',
      canonicalGuid: 'message-guid_1',
    );
    final firstOwnerId = store.box<Message>().put(
      Message(guid: 'message-guid', dateCreated: testEpoch, isFromMe: false),
    );
    final secondOwnerId = store.box<Message>().put(
      Message(
        guid: 'other-message-guid',
        dateCreated: testEpoch,
        isFromMe: false,
      ),
    );
    final existing = Attachment(
      guid: 'message-guid_1',
      transferName: 'existing.bin',
    )..message.targetId = secondOwnerId;
    final attachmentId = store.box<Attachment>().put(existing);
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowAttachmentMetadataUpserts: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _attachmentPayload(
          logicalEntityKeyHash: 'relation-conflict-hash',
          canonicalGuid: 'message-guid_1',
          ownerLogicalKeyHash: messageHash,
          ownerCanonicalGuid: 'message-guid',
          ownerPart: 1,
          fileName: 'replacement.bin',
          protectedLocalReference: 'protected:relation-conflict',
        ),
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          'relation-conflict-hash',
          parentLogicalKeyHash: messageHash,
        ),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_attachment_relation_conflict',
        ),
      ),
    );
    final unchanged = store.box<Attachment>().get(attachmentId)!;
    expect(unchanged.message.targetId, secondOwnerId);
    expect(unchanged.transferName, 'existing.bin');
    expect(store.box<Message>().get(firstOwnerId)!.hasAttachments, isFalse);
  });

  test(
    'rolls back an invalid attachment size and keeps the gate default-off',
    () {
      resolver.put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: 'invalid-size-hash',
        canonicalGuid: 'message-guid_0',
      );
      final payload = _attachmentPayload(
        logicalEntityKeyHash: 'invalid-size-hash',
        canonicalGuid: 'message-guid_0',
        ownerLogicalKeyHash: messageHash,
        ownerCanonicalGuid: 'message-guid',
        ownerPart: 0,
        totalBytes: -1,
        totalBytesState: CloudSemanticFieldState.value,
        protectedLocalReference: 'protected:invalid-size',
      );
      final defaultOffAdapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
      );
      expect(
        () => defaultOffAdapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: payload,
          snapshot: _snapshot(
            CloudEntityKind.attachment,
            'invalid-size-hash',
            parentLogicalKeyHash: messageHash,
          ),
        ),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) => failure.safeCode == 'canonical_payload_dto_incomplete',
          ),
        ),
      );
      expect(store.box<Attachment>().count(), 0);

      store.box<Message>().put(
        Message(guid: 'message-guid', dateCreated: testEpoch, isFromMe: false),
      );
      final enabledAdapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
        allowAttachmentMetadataUpserts: true,
      );
      expect(
        () => store.runInTransaction(TxMode.write, () {
          enabledAdapter.applyEntity(
            scope: scope,
            generation: generation,
            payload: payload,
            snapshot: _snapshot(
              CloudEntityKind.attachment,
              'invalid-size-hash',
              parentLogicalKeyHash: messageHash,
            ),
          );
        }),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) =>
                failure.safeCode == 'canonical_attachment_size_invalid',
          ),
        ),
      );
      expect(store.box<Attachment>().count(), 0);
      expect(store.box<Message>().getAll().single.hasAttachments, isFalse);
    },
  );

  test('only updates an existing unlocked chat presentation field', () {
    final id = store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'preserve-this',
        displayName: 'Old name',
        lockChatName: false,
      ),
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowExistingChatPresentationUpdates: true,
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: CloudChatEntityPayload(
          logicalEntityKeyHash: chatHash,
          canonicalGuid: 'chat-guid',
          chatIdentifier: 'preserve-this',
          displayName: 'Updated name',
          participantHandles: const ['should-not-be-written'],
        ),
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    final updated = store.box<Chat>().get(id)!;
    expect(updated.displayName, 'Updated name');
    expect(updated.chatIdentifier, 'preserve-this');
    expect(updated.guidRefs, ['chat-guid']);

    updated.lockChatName = true;
    store.box<Chat>().put(updated);
    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: CloudChatEntityPayload(
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'chat-guid',
        chatIdentifier: 'preserve-this',
        displayName: 'Must preserve local lock',
        participantHandles: const [],
      ),
      snapshot: _snapshot(CloudEntityKind.chat, chatHash),
    );
    expect(store.box<Chat>().get(id)!.displayName, 'Updated name');
  });

  test('refuses message creation until the native DTO is sufficient', () {
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: CloudMessageEntityPayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatAliasKeyHash: chatHash,
          chatIdentifier: 'iMessage;-;chat',
          body: 'synthetic body',
          senderHandle: 'synthetic@example.invalid',
        ),
        snapshot: _snapshot(
          CloudEntityKind.message,
          messageHash,
          parentLogicalKeyHash: chatHash,
        ),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.category == CloudFailureCategory.dependency &&
              failure.safeCode == 'canonical_payload_dto_incomplete',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Attachment>().count(), 0);
    expect(store.box<Chat>().count(), 0);
  });

  test('refuses a stale account fence without mutating canonical rows', () {
    final id = store.box<Chat>().put(Chat(guid: 'chat-guid'));
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowExistingChatPresentationUpdates: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation + 1,
        payload: CloudChatEntityPayload(
          logicalEntityKeyHash: chatHash,
          canonicalGuid: 'chat-guid',
          chatIdentifier: 'preserve-this',
          displayName: 'Wrong generation',
          participantHandles: const [],
        ),
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_scope_fence_rejected',
        ),
      ),
    );
    expect(store.box<Chat>().get(id)!.displayName, isNull);
  });
}

ObjectBoxCanonicalSemanticEntityAdapter _newAdapter({
  required Store store,
  required CloudCanonicalActiveScope? Function() activeScopeProvider,
  required CloudCanonicalIdentityResolver resolver,
  bool semanticApplyEnabled = false,
  bool allowExistingChatPresentationUpdates = false,
  bool allowChatUpserts = false,
  bool allowExistingChatDisplayNameClears = false,
  bool allowMessageUpserts = false,
  bool allowReactionUpserts = false,
  bool allowAttachmentMetadataUpserts = false,
}) => ObjectBoxCanonicalSemanticEntityAdapter(
  store: store,
  activeScopeProvider: activeScopeProvider,
  identityResolver: resolver,
  semanticApplyEnabled: semanticApplyEnabled,
  allowExistingChatPresentationUpdates: allowExistingChatPresentationUpdates,
  allowChatUpserts: allowChatUpserts,
  allowExistingChatDisplayNameClears: allowExistingChatDisplayNameClears,
  allowMessageUpserts: allowMessageUpserts,
  allowReactionUpserts: allowReactionUpserts,
  allowAttachmentMetadataUpserts: allowAttachmentMetadataUpserts,
);

CloudChatEntityPayload _chatPayload({
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  String? displayName = 'Cloud chat',
  CloudSemanticFieldState? displayNameState,
  Iterable<String> participantHandles = const [],
  CloudSemanticChatStyle style = CloudSemanticChatStyle.direct,
  int? groupVersion,
}) => CloudChatEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  chatIdentifier: chatIdentifier,
  displayName: displayName,
  displayNameState: displayNameState,
  participantHandles: participantHandles,
  service: CloudSemanticService.iMessage,
  style: style,
  groupVersionState: groupVersion == null
      ? CloudSemanticFieldState.absent
      : CloudSemanticFieldState.value,
  groupVersion: groupVersion,
);

CloudMessageEntityPayload _messagePayload({
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  DateTime? createdAt,
  String? subject = 'Cloud subject',
  String? body = 'Cloud body',
  String senderHandle = 'mailto:sender@example.com',
  CloudSemanticFieldState subjectState = CloudSemanticFieldState.value,
  CloudSemanticFieldState bodyState = CloudSemanticFieldState.value,
  DateTime? readAt,
  DateTime? deliveredAt,
  CloudSemanticFieldState? readAtState,
  CloudSemanticFieldState? deliveredAtState,
  String? effect,
  CloudSemanticFieldState? effectState,
  Iterable<CloudSemanticAttributedBody> attributedBodies = const [],
  CloudSemanticFieldState? attributedBodiesState,
  Uint8List? decodedExtensionPayload,
  CloudSemanticFieldState? decodedExtensionPayloadState,
  CloudSemanticKnownMessageFlags? knownFlags,
}) => CloudMessageEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  chatAliasKeyHash: _defaultChatHash,
  chatIdentifier: chatIdentifier,
  body: body,
  senderHandle: senderHandle,
  createdAt: createdAt ?? testEpoch,
  service: CloudSemanticService.iMessage,
  subjectState: subjectState,
  subject: subject,
  bodyState: bodyState,
  attributedBodiesState:
      attributedBodiesState ??
      (attributedBodies.isEmpty
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  attributedBodies: attributedBodies,
  decodedExtensionPayloadState:
      decodedExtensionPayloadState ??
      (decodedExtensionPayload == null
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  decodedExtensionPayload: decodedExtensionPayload,
  effectState:
      effectState ??
      (effect == null
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  effect: effect,
  readAtState:
      readAtState ??
      (readAt == null
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  readAt: readAt,
  deliveredAtState:
      deliveredAtState ??
      (deliveredAt == null
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  deliveredAt: deliveredAt,
  knownFlags: knownFlags ?? _messageFlags(fromMe: false),
);

CloudSemanticKnownMessageFlags _messageFlags({
  required bool fromMe,
  bool delivered = false,
  bool read = false,
  bool hasDataDetectorResults = false,
  bool deliveredQuietly = false,
  bool didNotifyRecipient = false,
}) => CloudSemanticKnownMessageFlags(
  fromMe: fromMe,
  delivered: delivered,
  read: read,
  hasDataDetectorResults: hasDataDetectorResults,
  deliveredQuietly: deliveredQuietly,
  didNotifyRecipient: didNotifyRecipient,
);

CloudReactionEntityPayload _reactionPayload({
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  String parentLogicalKeyHash = _defaultMessageHash,
  String parentCanonicalGuid = 'message-guid',
  int? parentPart = 0,
  String senderHandle = 'mailto:reactor@example.com',
  String reactionType = 'emoji',
  String? associatedEmoji = '❤️',
  DateTime? createdAt,
  CloudSemanticKnownMessageFlags? knownFlags,
}) => CloudReactionEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  parentLogicalKeyHash: parentLogicalKeyHash,
  parentCanonicalGuid: parentCanonicalGuid,
  parentPart: parentPart,
  senderHandle: senderHandle,
  reactionType: reactionType,
  associatedEmoji: associatedEmoji,
  createdAt: createdAt ?? testEpoch,
  service: CloudSemanticService.iMessage,
  knownFlags: knownFlags ?? _messageFlags(fromMe: false),
);

CloudAttachmentEntityPayload _attachmentPayload({
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String? ownerLogicalKeyHash,
  required String? ownerCanonicalGuid,
  required int? ownerPart,
  String? uti,
  CloudSemanticFieldState utiState = CloudSemanticFieldState.absent,
  String? fileName = 'attachment.bin',
  CloudSemanticFieldState fileNameState = CloudSemanticFieldState.value,
  String? mimeType = 'application/octet-stream',
  CloudSemanticFieldState? mimeTypeState,
  int? totalBytes,
  CloudSemanticFieldState totalBytesState = CloudSemanticFieldState.absent,
  bool? isOutgoing,
  CloudSemanticFieldState isOutgoingState = CloudSemanticFieldState.absent,
  required String? protectedLocalReference,
  CloudSemanticFieldState protectedLocalReferenceState =
      CloudSemanticFieldState.value,
}) => CloudAttachmentEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  ownerLogicalKeyHash: ownerLogicalKeyHash,
  ownerCanonicalGuid: ownerCanonicalGuid,
  ownerPart: ownerPart,
  utiState: utiState,
  uti: uti,
  fileNameState: fileNameState,
  fileName: fileName,
  mimeTypeState: mimeTypeState,
  mimeType: mimeType,
  totalBytesState: totalBytesState,
  totalBytes: totalBytes,
  isOutgoingState: isOutgoingState,
  isOutgoing: isOutgoing,
  protectedLocalReferenceState: protectedLocalReferenceState,
  protectedLocalReference: protectedLocalReference,
);

CloudSemanticSnapshot _snapshot(
  CloudEntityKind kind,
  String logicalEntityKeyHash, {
  String? parentLogicalKeyHash,
}) => CloudSemanticSnapshot(
  kind: kind,
  logicalEntityKeyHash: logicalEntityKeyHash,
  parentLogicalKeyHash: parentLogicalKeyHash,
  immutableContentDigest: 'content-digest',
);

final class _Resolver implements CloudCanonicalIdentityResolver {
  final Map<String, String> _values = {};

  void put({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
    required String canonicalGuid,
  }) {
    _values[_key(scope, generation, kind, logicalEntityKeyHash)] =
        canonicalGuid;
  }

  @override
  String? resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) => _values[_key(scope, generation, kind, logicalEntityKeyHash)];

  String _key(
    CloudSyncScope scope,
    int generation,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) => '${scope.storageKey}:$generation:${kind.name}:$logicalEntityKeyHash';
}
