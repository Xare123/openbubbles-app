import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/transient_cloud_canonical_identity_registry.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

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
      _seedExactOwnershipProof(
        store,
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'chat-guid',
      );
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

  test('classifies a present invalid canonical identity as malformed', () {
    const invalidHash = 'invalid-identity-hash';
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: invalidHash,
      canonicalGuid: 'message\u0001guid',
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
    );

    expect(
      () => adapter.validateOwnershipEvidence(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: invalidHash,
      ),
      throwsA(
        isA<CloudSyncFailure>()
            .having(
              (failure) => failure.category,
              'category',
              CloudFailureCategory.malformedRecord,
            )
            .having(
              (failure) => failure.safeCode,
              'safeCode',
              'canonical_identity_guid_invalid',
            ),
      ),
    );
  });

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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
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
    final aliasRows = store.box<CloudSemanticChatAliasEntity>().getAll();
    expect(aliasRows, hasLength(1));
    expect(aliasRows.single.chatId, chats.single.id);
    expect(aliasRows.single.chatLogicalEntityKeyHash, chatHash);
  });

  test('projects exact SMS chats and messages without iMessage aliasing', () {
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
      allowMessageUpserts: true,
    );
    const identifier = 'SMS;-;+19492476163';
    store.box<Handle>().put(
      Handle(
        address: '+19492476163',
        service: 'iMessage',
        uniqueAddressAndService: '+19492476163/iMessage',
      ),
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: chatHash,
          canonicalGuid: 'chat-guid',
          chatIdentifier: identifier,
          participantHandles: const ['tel:+19492476163'],
          service: CloudSemanticService.sms,
        ),
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
    );
    final messagePayload = _messagePayload(
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
      chatIdentifier: identifier,
      senderHandle: 'tel:+19492476163',
      service: CloudSemanticService.sms,
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: messagePayload,
        snapshot: _snapshot(
          CloudEntityKind.message,
          messageHash,
          parentLogicalKeyHash: chatHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: messagePayload,
        snapshot: _snapshot(
          CloudEntityKind.message,
          messageHash,
          parentLogicalKeyHash: chatHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    final chat = store.box<Chat>().getAll().single;
    final message = store.box<Message>().getAll().single;
    expect(chat.isRpSms, isTrue);
    expect(chat.handles.single.uniqueAddressAndService, '+19492476163/SMS');
    expect(message.chat.targetId, chat.id);
    final smsSenderQuery =
        store
            .box<Handle>()
            .query(Handle_.uniqueAddressAndService.equals('+19492476163/SMS'))
            .build()
          ..limit = 1;
    try {
      final smsSender = smsSenderQuery.findFirst();
      expect(smsSender, isNotNull);
      expect(message.handleId, smsSender!.id);
    } finally {
      smsSenderQuery.close();
    }
    expect(
      store
          .box<Handle>()
          .getAll()
          .map((handle) => handle.uniqueAddressAndService)
          .toSet(),
      {'+19492476163/iMessage', '+19492476163/SMS'},
    );
  });

  test('keeps identical chat identifiers isolated by service', () {
    const identifier = 'shared-service-identifier';
    store.box<Chat>().put(
      Chat(
        guid: 'existing-imessage-chat',
        chatIdentifier: identifier,
        isRpSms: false,
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
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: chatHash,
          canonicalGuid: 'chat-guid',
          chatIdentifier: identifier,
          service: CloudSemanticService.sms,
        ),
        snapshot: _snapshot(CloudEntityKind.chat, chatHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    final chats = store.box<Chat>().getAll();
    expect(chats, hasLength(2));
    expect(
      chats
          .singleWhere((chat) => chat.guid == 'existing-imessage-chat')
          .isRpSms,
      isFalse,
    );
    expect(
      chats.singleWhere((chat) => chat.guid == 'chat-guid').isRpSms,
      isTrue,
    );
  });

  test('rejects an exact chat-alias conflict without creating rows', () {
    final diagnostics = <String>[];
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
      diagnosticRecorder: diagnostics.add,
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
    expect(
      diagnostics,
      contains('canonical_chat_alias_conflict_identifier_owner'),
    );
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
            'MAILTO:alice@example.com',
            'alice@example.com',
            'tel:+19492476163',
            'TEL:+19492476163',
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: versionedHash,
      canonicalGuid: 'versioned-chat-guid',
    );
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
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
      final diagnostics = <String>[];
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        diagnosticRecorder: diagnostics.add,
        semanticApplyEnabled: true,
        allowChatUpserts: true,
      );

      const invalidShapes = {
        'not a valid participant': [
          'canonical_participant_shape_embedded_whitespace',
        ],
        'opaque\u0001participant': [
          'canonical_participant_shape_control_character',
        ],
        'urn:apple:opaque': ['canonical_participant_shape_unknown_scheme'],
        'urn:biz:not-a-uuid': ['canonical_participant_shape_unknown_scheme'],
        'URN:BIZ:123e4567-e89b-12d3-a456-426614174000': [
          'canonical_participant_shape_unknown_scheme',
        ],
        ' mailto:valid@example.com': [
          'canonical_participant_shape_outer_whitespace',
        ],
      };
      for (final invalidShape in invalidShapes.entries) {
        diagnostics.clear();
        expect(
          () => store.runInTransaction(TxMode.write, () {
            adapter.applyEntity(
              scope: scope,
              generation: generation,
              payload: _chatPayload(
                logicalEntityKeyHash: chatHash,
                canonicalGuid: 'chat-guid',
                chatIdentifier: 'iMessage;+;invalid',
                participantHandles: [
                  'mailto:valid@example.com',
                  invalidShape.key,
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
        expect(diagnostics, invalidShape.value);
        expect(store.box<Chat>().count(), 0);
        expect(store.box<Handle>().count(), 0);
        expect(store.box<CloudSemanticChatAliasEntity>().count(), 0);
      }
    },
  );

  test(
    'classifies invalid telephone shapes without exposing candidate content',
    () {
      const invalidTelephoneShapes = {
        'tel:(949) 247-6163':
            'canonical_participant_shape_telephone_invalid_formatted_punctuation',
        'tel:12abc':
            'canonical_participant_shape_telephone_invalid_alphabetic_ascii',
        'tel:%2B19492476163':
            'canonical_participant_shape_telephone_invalid_percent_escaped',
        'tel:+١٢٣٤': 'canonical_participant_shape_telephone_invalid_non_ascii',
        'tel:12+34':
            'canonical_participant_shape_telephone_invalid_plus_position_count',
        'tel:--':
            'canonical_participant_shape_telephone_invalid_punctuation_only',
        'tel:12/34':
            'canonical_participant_shape_telephone_invalid_formatted_punctuation',
      };

      final allowedDiagnosticKeys = RegExp(
        r'^canonical_participant_shape_telephone_invalid(?:_'
        r'(?:formatted_punctuation|alphabetic_ascii|percent_escaped|'
        r'non_ascii|plus_position_count|punctuation_only|other))?$',
      );
      for (final invalidShape in invalidTelephoneShapes.entries) {
        final diagnostics = <String>[];
        final adapter = _newAdapter(
          store: store,
          activeScopeProvider: () => activeScope,
          resolver: resolver,
          diagnosticRecorder: diagnostics.add,
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
                chatIdentifier: 'iMessage;+;invalid-telephone',
                participantHandles: [invalidShape.key],
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

        expect(
          diagnostics,
          containsAll([
            'canonical_participant_shape_telephone_invalid',
            invalidShape.value,
          ]),
        );
        expect(diagnostics, everyElement(matches(allowedDiagnosticKeys)));
        expect(diagnostics, everyElement(isNot(contains(RegExp(r'[0-9]')))));
        expect(diagnostics, everyElement(isNot(contains(invalidShape.key))));
        expect(store.box<Chat>().count(), 0);
        expect(store.box<Handle>().count(), 0);
        expect(store.box<CloudSemanticChatAliasEntity>().count(), 0);
      }
    },
  );

  test('preserves valid explicit and opaque bare participant identifiers', () {
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    adapter.applyEntity(
      scope: scope,
      generation: generation,
      payload: _chatPayload(
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'chat-guid',
        chatIdentifier: 'iMessage;+;valid-participants',
        participantHandles: const [
          'tel:+19492476163',
          'mailto:valid@example.com',
          'j',
          'opaque+AbC/123',
          'urn:biz:123e4567-e89b-12d3-a456-426614174000',
        ],
      ),
      snapshot: _snapshot(CloudEntityKind.chat, chatHash),
    );

    final chat = store.box<Chat>().getAll().single;
    expect(
      chat.handles
          .map((handle) => '${handle.address}/${handle.service}')
          .toSet(),
      {
        '+19492476163/iMessage',
        'valid@example.com/iMessage',
        'j/iMessage',
        'opaque+AbC/123/iMessage',
        'urn:biz:123e4567-e89b-12d3-a456-426614174000/iMessage',
      },
    );
    expect(chat.chatIdentifier, 'iMessage;+;valid-participants');
    expect(diagnostics, isEmpty);
  });

  test('does not accept an opaque bare identifier as a message sender', () {
    const chatIdentifier = 'iMessage;-;strict-sender-chat';
    final chatId = store.box<Chat>().put(
      Chat(guid: 'strict-sender-chat-guid', chatIdentifier: chatIdentifier),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'strict-sender-chat-guid',
      chatIdentifier: chatIdentifier,
      chatId: chatId,
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
          chatIdentifier: chatIdentifier,
          senderHandle: 'j',
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_sender_invalid',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
  });

  test('does not accept a business URN as a message sender', () {
    const chatIdentifier = 'iMessage;-;strict-business-sender-chat';
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'strict-business-sender-chat-guid',
        chatIdentifier: chatIdentifier,
      ),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'strict-business-sender-chat-guid',
      chatIdentifier: chatIdentifier,
      chatId: chatId,
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
          chatIdentifier: chatIdentifier,
          senderHandle: 'urn:biz:123e4567-e89b-12d3-a456-426614174000',
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_sender_invalid',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
  });

  test('creates and idempotently replays a message into its exact chat', () {
    const chatIdentifier = 'iMessage;-;message-chat';
    final chatId = store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: chatIdentifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: chatIdentifier,
      chatId: chatId,
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
      chatIdentifier: chatIdentifier,
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
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

  for (final cloudAliasIdentifier in const [
    'cloud-group-id',
    'iMessage;+;cloud-group-id',
  ]) {
    test('resolves a group message through current CloudKit group ID '
        '$cloudAliasIdentifier', () {
      const storedIdentifier = 'iMessage;-;canonical-chat-id';
      final cloudAliasHash = _testChatAliasHash(cloudAliasIdentifier);
      final chatId = store.box<Chat>().put(
        Chat(guid: 'chat-guid', chatIdentifier: storedIdentifier, style: 43),
      );
      _seedChatOwnershipAndAlias(
        store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'chat-guid',
        chatIdentifier: cloudAliasIdentifier,
        chatId: chatId,
        aliasKind: CloudSemanticChatAliasKind.groupId,
      );
      final diagnostics = <String>[];
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        diagnosticRecorder: diagnostics.add,
        semanticApplyEnabled: true,
        allowMessageUpserts: true,
      );

      expect(
        adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: _messagePayload(
            logicalEntityKeyHash: messageHash,
            canonicalGuid: 'message-guid',
            chatIdentifier: cloudAliasIdentifier,
            chatAliasKeyHash: cloudAliasHash,
            chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
              'missing-group-exact-owner',
            ),
            chatIdAliasCandidates: _typedMessageAliases(
              serviceIdentifierHash: cloudAliasHash,
              groupIdHash: cloudAliasHash,
            ),
          ),
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        ),
        CloudCanonicalSemanticMutationReceipt.committed,
      );

      final message = store.box<Message>().getAll().single;
      expect(message.chat.targetId, chatId);
      expect(store.box<Chat>().get(chatId)!.chatIdentifier, storedIdentifier);
      expect(
        diagnostics,
        contains('canonical_message_chat_reference_current_group_id'),
      );
      expect(
        diagnostics,
        contains(
          cloudAliasIdentifier.contains(';')
              ? 'canonical_message_chat_route_group'
              : 'canonical_message_chat_route_bare',
        ),
      );
    });
  }

  test('accepts a bare direct CID with exact canonical ownership', () {
    const directCid = 'bare-direct-cid-exact';
    final ownerLogicalHash = _testChatAliasHash(
      'bare-direct-exact-owner-logical-hash',
    );
    final routeHash = _testChatAliasHash(directCid);
    final chatId = store.box<Chat>().put(
      Chat(guid: directCid, chatIdentifier: 'local-direct-cid', style: 45),
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: ownerLogicalHash,
      canonicalGuid: directCid,
    );
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: directCid,
          chatAliasKeyHash: routeHash,
          chatIdExactGuidLogicalKeyHash: ownerLogicalHash,
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: routeHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    expect(store.box<Message>().getAll().single.chat.targetId, chatId);
    expect(diagnostics, contains('canonical_message_chat_route_bare'));
    expect(
      diagnostics,
      contains('canonical_message_chat_reference_exact_guid'),
    );
  });

  test('resolves a bare direct CID through its service identity', () {
    const directCid = 'bare-direct-cid-service';
    final routeHash = _testChatAliasHash(directCid);
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'bare-direct-service-owner-guid',
        chatIdentifier: 'local-direct-service-owner',
        style: 45,
      ),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: 'bare-direct-service-owner-logical-hash',
      canonicalGuid: 'bare-direct-service-owner-guid',
      chatIdentifier: directCid,
      chatId: chatId,
    );
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: directCid,
          chatAliasKeyHash: routeHash,
          chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
            'missing-bare-direct-exact-owner',
          ),
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: routeHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    expect(store.box<Message>().getAll().single.chat.targetId, chatId);
    expect(diagnostics, contains('canonical_message_chat_route_bare'));
    expect(
      diagnostics,
      contains('canonical_message_chat_reference_strong_service'),
    );
  });

  test('observes a qualified bare direct CID owner without selecting it', () {
    const directCid = 'bare-direct-cid-qualified-diagnostic';
    const qualifiedIdentifier =
        'iMessage;-;bare-direct-cid-qualified-diagnostic';
    final rawRouteHash = _testChatAliasHash(directCid);
    final qualifiedRouteHash = _testChatAliasHash(qualifiedIdentifier);
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'qualified-direct-service-owner-guid',
        chatIdentifier: qualifiedIdentifier,
        style: 45,
      ),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: 'qualified-direct-service-owner-logical-hash',
      canonicalGuid: 'qualified-direct-service-owner-guid',
      chatIdentifier: qualifiedIdentifier,
      chatId: chatId,
    );
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
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
          chatIdentifier: directCid,
          chatAliasKeyHash: rawRouteHash,
          chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
            'missing-qualified-direct-exact-owner',
          ),
          chatIdBareDirectServiceIdentifierAliasKeyHash: qualifiedRouteHash,
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: rawRouteHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );

    expect(store.box<Message>().count(), 0);
    expect(
      diagnostics,
      containsAll([
        'canonical_message_chat_candidate_bare_direct_service_identifier_unique',
        'canonical_message_chat_candidate_bare_direct_service_identifier_style_45',
        'canonical_message_chat_reference_unavailable',
      ]),
    );
    expect(
      diagnostics,
      isNot(contains('canonical_message_chat_reference_strong_service')),
    );
  });

  test(
    'a corrupt qualified-CID diagnostic binding cannot block an exact owner',
    () {
      const directCid = 'bare-direct-cid-exact-with-corrupt-diagnostic';
      const exactOwnerGuid = directCid;
      const qualifiedIdentifier =
          'iMessage;-;bare-direct-cid-exact-with-corrupt-diagnostic';
      final exactOwnerLogicalHash = _testChatAliasHash(
        'exact-owner-with-corrupt-diagnostic-logical',
      );
      final exactChatId = store.box<Chat>().put(
        Chat(
          guid: exactOwnerGuid,
          chatIdentifier: 'local-exact-owner',
          style: 45,
        ),
      );
      _seedExactOwnershipProof(
        store,
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: exactOwnerLogicalHash,
        canonicalGuid: exactOwnerGuid,
      );

      final diagnosticChatId = store.box<Chat>().put(
        Chat(
          guid: 'corrupt-diagnostic-owner-guid',
          chatIdentifier: qualifiedIdentifier,
          style: 45,
        ),
      );
      _seedChatOwnershipAndAlias(
        store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: 'corrupt-diagnostic-owner-logical',
        canonicalGuid: 'corrupt-diagnostic-owner-guid',
        chatIdentifier: qualifiedIdentifier,
        chatId: diagnosticChatId,
      );
      final aliasBox = store.box<CloudSemanticChatAliasEntity>();
      final corruptBinding = aliasBox.getAll().singleWhere(
        (row) => row.aliasKeyHash == _testChatAliasHash(qualifiedIdentifier),
      );
      corruptBinding.canonicalGuidHash = List.filled(64, '0').join();
      aliasBox.put(corruptBinding);

      final diagnostics = <String>[];
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        diagnosticRecorder: diagnostics.add,
        semanticApplyEnabled: true,
        allowMessageUpserts: true,
      );
      final rawRouteHash = _testChatAliasHash(directCid);

      expect(
        adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: _messagePayload(
            logicalEntityKeyHash: messageHash,
            canonicalGuid: 'message-guid',
            chatIdentifier: directCid,
            chatAliasKeyHash: rawRouteHash,
            chatIdExactGuidLogicalKeyHash: exactOwnerLogicalHash,
            chatIdBareDirectServiceIdentifierAliasKeyHash: _testChatAliasHash(
              qualifiedIdentifier,
            ),
            chatIdAliasCandidates: _typedMessageAliases(
              serviceIdentifierHash: rawRouteHash,
            ),
          ),
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        ),
        CloudCanonicalSemanticMutationReceipt.committed,
      );

      expect(store.box<Message>().getAll().single.chat.targetId, exactChatId);
      expect(
        diagnostics,
        contains(
          'canonical_message_chat_candidate_bare_direct_service_identifier_lookup_failed',
        ),
      );
      expect(
        diagnostics,
        isNot(
          contains(
            'canonical_message_chat_candidate_bare_direct_service_identifier_none',
          ),
        ),
      );
      expect(
        diagnostics,
        contains('canonical_message_chat_reference_exact_guid'),
      );
    },
  );

  test('keeps exact canonical-guid ownership decisive over msgProto4', () {
    const repairChatGuid = 'iMessage;-;repair-chat-guid';
    final repairChatHash = _testChatAliasHash('repair-chat-logical-key');
    const storedIdentifier = '+15555550100';
    final chatId = store.box<Chat>().put(
      Chat(guid: repairChatGuid, chatIdentifier: storedIdentifier, style: 45),
    );
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: repairChatHash,
      canonicalGuid: repairChatGuid,
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: repairChatHash,
      canonicalGuid: repairChatGuid,
      chatIdentifier: storedIdentifier,
      chatId: chatId,
    );
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );
    final aliasCountBefore = store.box<CloudSemanticChatAliasEntity>().count();
    final messageServiceHash = _testChatAliasHash(repairChatGuid);

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: repairChatGuid,
          chatAliasKeyHash: messageServiceHash,
          chatIdExactGuidLogicalKeyHash: repairChatHash,
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: messageServiceHash,
          ),
          msgProto4GroupIdAliasKeyHash: _testChatAliasHash(
            'unrelated-msg-proto4-group-id',
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );

    expect(store.box<Message>().getAll().single.chat.targetId, chatId);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);
    expect(
      store.box<CloudSemanticChatAliasEntity>().getAll().where(
        (row) => row.aliasKeyHash == messageServiceHash,
      ),
      isEmpty,
    );
    expect(
      diagnostics,
      contains('canonical_message_chat_reference_exact_guid'),
    );
    expect(
      diagnostics,
      isNot(contains('canonical_message_chat_group_corroborator_none')),
    );
  });

  test('uses a strong service alias when exact-guid ownership is absent', () {
    const ownerGuid = 'strong-service-owner-guid';
    const storedIdentifier = 'iMessage;-;stored-service-owner';
    const serviceAliasIdentifier = 'iMessage;-;cloud-service-owner';
    const ownerLogicalHash = 'strong-service-owner-logical-hash';
    final serviceAliasHash = _testChatAliasHash(serviceAliasIdentifier);
    final chatId = store.box<Chat>().put(
      Chat(guid: ownerGuid, chatIdentifier: storedIdentifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: ownerLogicalHash,
      canonicalGuid: ownerGuid,
      chatIdentifier: serviceAliasIdentifier,
      chatId: chatId,
    );
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: serviceAliasIdentifier,
          chatAliasKeyHash: serviceAliasHash,
          chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
            'missing-exact-chat-logical-key',
          ),
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: serviceAliasHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    expect(store.box<Message>().getAll().single.chat.targetId, chatId);
    expect(
      diagnostics,
      contains('canonical_message_chat_reference_strong_service'),
    );
    expect(
      diagnostics,
      isNot(contains('canonical_message_chat_reference_weak_evidence_only')),
    );
  });

  test('accepts exact and current group-ID proof for the same group', () {
    const groupId = 'same-current-group-id';
    final ownerLogicalHash = _testChatAliasHash(
      'same-current-group-owner-logical-hash',
    );
    final groupHash = _testChatAliasHash(groupId);
    final chatId = store.box<Chat>().put(
      Chat(guid: groupId, chatIdentifier: 'local-group-id', style: 43),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: ownerLogicalHash,
      canonicalGuid: groupId,
      chatIdentifier: groupId,
      chatId: chatId,
      aliasKind: CloudSemanticChatAliasKind.groupId,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    expect(
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: groupId,
          chatAliasKeyHash: groupHash,
          chatIdExactGuidLogicalKeyHash: ownerLogicalHash,
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: groupHash,
            groupIdHash: groupHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    expect(store.box<Message>().getAll().single.chat.targetId, chatId);
  });

  test('rejects disagreement between exact and current group-ID owners', () {
    const groupId = 'conflicting-current-group-id';
    final exactLogicalHash = _testChatAliasHash(
      'group-exact-owner-logical-hash',
    );
    final aliasLogicalHash = _testChatAliasHash(
      'group-alias-owner-logical-hash',
    );
    final groupHash = _testChatAliasHash(groupId);
    final exactChatId = store.box<Chat>().put(
      Chat(guid: groupId, chatIdentifier: 'exact-local-group', style: 43),
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: exactLogicalHash,
      canonicalGuid: groupId,
    );
    final aliasChatId = store.box<Chat>().put(
      Chat(
        guid: 'different-group-owner-guid',
        chatIdentifier: 'different-local-group',
        style: 43,
      ),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: aliasLogicalHash,
      canonicalGuid: 'different-group-owner-guid',
      chatIdentifier: groupId,
      chatId: aliasChatId,
      aliasKind: CloudSemanticChatAliasKind.groupId,
    );
    final aliasCountBefore = store.box<CloudSemanticChatAliasEntity>().count();
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
          chatIdentifier: groupId,
          chatAliasKeyHash: groupHash,
          chatIdExactGuidLogicalKeyHash: exactLogicalHash,
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: groupHash,
            groupIdHash: groupHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_message_chat_conflict' &&
              failure.category == CloudFailureCategory.conflict,
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Chat>().get(exactChatId), isNotNull);
    expect(store.box<Chat>().get(aliasChatId), isNotNull);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);
  });

  test('rejects multiple current group-ID owners without reparenting', () {
    const groupId = 'shared-current-group-id';
    final groupHash = _testChatAliasHash(groupId);
    for (var index = 0; index < 2; index++) {
      final guid = 'shared-group-owner-$index';
      final logicalHash = 'shared-group-owner-logical-$index';
      final chatId = store.box<Chat>().put(
        Chat(guid: guid, chatIdentifier: 'local-group-$index', style: 43),
      );
      _seedChatOwnershipAndAlias(
        store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: logicalHash,
        canonicalGuid: guid,
        chatIdentifier: groupId,
        chatId: chatId,
        aliasKind: CloudSemanticChatAliasKind.groupId,
      );
    }
    final aliasCountBefore = store.box<CloudSemanticChatAliasEntity>().count();
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
          chatIdentifier: groupId,
          chatAliasKeyHash: groupHash,
          chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
            'missing-colliding-group-owner',
          ),
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: groupHash,
            groupIdHash: groupHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_message_chat_conflict' &&
              failure.category == CloudFailureCategory.conflict,
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Chat>().count(), 2);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);
  });

  for (final groupId in const [
    'direct-style-group-claim',
    'iMessage;+;direct-style-group-claim',
  ]) {
    test('rejects current group-ID claim owned by a direct chat $groupId', () {
      final groupHash = _testChatAliasHash(groupId);
      final chatId = store.box<Chat>().put(
        Chat(
          guid: 'direct-owner-guid',
          chatIdentifier: 'local-direct',
          style: 45,
        ),
      );
      _seedChatOwnershipAndAlias(
        store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: 'direct-owner-logical-hash',
        canonicalGuid: 'direct-owner-guid',
        chatIdentifier: groupId,
        chatId: chatId,
        aliasKind: CloudSemanticChatAliasKind.groupId,
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
            chatIdentifier: groupId,
            chatAliasKeyHash: groupHash,
            chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
              'missing-direct-style-owner',
            ),
            chatIdAliasCandidates: _typedMessageAliases(
              serviceIdentifierHash: groupHash,
              groupIdHash: groupHash,
            ),
          ),
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        ),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) => failure.safeCode == 'canonical_message_chat_conflict',
          ),
        ),
      );
      expect(store.box<Message>().count(), 0);
    });
  }

  for (final chatIdentifier in const [
    'iMessage;-;cross-route-owner',
    'bare-cross-route-owner',
  ]) {
    test('rejects direct service and current group-ID owners that disagree for '
        '$chatIdentifier', () {
      final aliasHash = _testChatAliasHash(chatIdentifier);
      final directChatId = store.box<Chat>().put(
        Chat(guid: 'direct-guid', chatIdentifier: 'local-direct', style: 45),
      );
      _seedChatOwnershipAndAlias(
        store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: 'direct-logical-hash',
        canonicalGuid: 'direct-guid',
        chatIdentifier: chatIdentifier,
        chatId: directChatId,
      );
      final groupChatId = store.box<Chat>().put(
        Chat(guid: 'group-guid', chatIdentifier: 'local-group', style: 43),
      );
      _seedChatOwnershipAndAlias(
        store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: 'group-logical-hash',
        canonicalGuid: 'group-guid',
        chatIdentifier: chatIdentifier,
        chatId: groupChatId,
        aliasKind: CloudSemanticChatAliasKind.groupId,
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
            chatIdentifier: chatIdentifier,
            chatAliasKeyHash: aliasHash,
            chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
              'missing-cross-route-owner',
            ),
            chatIdAliasCandidates: _typedMessageAliases(
              serviceIdentifierHash: aliasHash,
              groupIdHash: aliasHash,
            ),
          ),
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        ),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) => failure.safeCode == 'canonical_message_chat_conflict',
          ),
        ),
      );
      expect(store.box<Message>().count(), 0);
    });
  }

  test('rejects a malformed composite message route without mutation', () {
    const chatIdentifier = 'iMessage;?;invalid-route';
    final aliasHash = _testChatAliasHash(chatIdentifier);
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
          chatIdentifier: chatIdentifier,
          chatAliasKeyHash: aliasHash,
          chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
            'missing-malformed-route-owner',
          ),
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: aliasHash,
            groupIdHash: aliasHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_message_chat_route_invalid' &&
              failure.category == CloudFailureCategory.malformedRecord,
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Handle>().count(), 0);
  });

  for (final chatIdentifier in const [
    'ForeignService;-;invalid-route',
    ';-;missing-service-route',
    'iMessage;-;invalid-route;extra',
    'iMessage;+;invalid-route;extra',
  ]) {
    test('rejects composite message route $chatIdentifier', () {
      final aliasHash = _testChatAliasHash(chatIdentifier);
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
            chatIdentifier: chatIdentifier,
            chatAliasKeyHash: aliasHash,
            chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
              'missing-service-prefix-owner',
            ),
            chatIdAliasCandidates: _typedMessageAliases(
              serviceIdentifierHash: aliasHash,
              groupIdHash: aliasHash,
            ),
          ),
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        ),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) =>
                failure.safeCode == 'canonical_message_chat_route_invalid' &&
                failure.category == CloudFailureCategory.malformedRecord,
          ),
        ),
      );
      expect(store.box<Message>().count(), 0);
      expect(store.box<Handle>().count(), 0);
    });
  }

  test('rejects disagreement between exact and strong service owners', () {
    const exactGuid = 'iMessage;-;exact-owner-guid';
    const serviceGuid = 'service-owner-guid';
    const conflictingServiceIdentifier = exactGuid;
    final exactLogicalHash = _testChatAliasHash('exact-owner-logical-hash');
    final serviceLogicalHash = _testChatAliasHash('service-owner-logical-hash');
    final exactChatId = store.box<Chat>().put(
      Chat(guid: exactGuid, chatIdentifier: 'exact-local-id', style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: exactLogicalHash,
      canonicalGuid: exactGuid,
      chatIdentifier: 'exact-service-owner',
      chatId: exactChatId,
    );
    final serviceChatId = store.box<Chat>().put(
      Chat(guid: serviceGuid, chatIdentifier: 'service-local-id', style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: serviceLogicalHash,
      canonicalGuid: serviceGuid,
      chatIdentifier: conflictingServiceIdentifier,
      chatId: serviceChatId,
    );
    final conflictingServiceHash = _testChatAliasHash(
      conflictingServiceIdentifier,
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
          chatIdentifier: exactGuid,
          chatAliasKeyHash: conflictingServiceHash,
          chatIdExactGuidLogicalKeyHash: exactLogicalHash,
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: conflictingServiceHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_message_chat_conflict' &&
              failure.category == CloudFailureCategory.conflict,
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
  });

  test('legacy messages do not infer an exact-guid chat reference', () {
    store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: '+15555550100', style: 45),
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
    );
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
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
          chatIdentifier: 'chat-guid',
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(
      diagnostics,
      contains('canonical_message_chat_reference_unavailable'),
    );
  });

  test('rejects an exact-guid typed reference across services', () {
    const smsChatGuid = 'sms-repair-chat-guid';
    final smsChatHash = _testChatAliasHash('sms-repair-logical-key');
    const storedIdentifier = '+15555550100';
    final chatId = store.box<Chat>().put(
      Chat(
        guid: smsChatGuid,
        chatIdentifier: storedIdentifier,
        style: 45,
        isRpSms: true,
      ),
    );
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: smsChatHash,
      canonicalGuid: smsChatGuid,
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: smsChatHash,
      canonicalGuid: smsChatGuid,
      chatIdentifier: storedIdentifier,
      chatId: chatId,
      service: CloudSemanticService.sms,
    );
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );
    final aliasCountBefore = store.box<CloudSemanticChatAliasEntity>().count();
    final messageServiceHash = _testChatAliasHash(smsChatGuid);

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: smsChatGuid,
          service: CloudSemanticService.iMessage,
          chatAliasKeyHash: messageServiceHash,
          chatIdExactGuidLogicalKeyHash: smsChatHash,
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: messageServiceHash,
          ),
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_message_chat_conflict' &&
              failure.category == CloudFailureCategory.conflict,
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);
  });

  test('uses attributed-body text when Apple omits the plain body', () {
    const chatIdentifier = 'iMessage;-;attributed-only-chat';
    final chatId = store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: chatIdentifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: chatIdentifier,
      chatId: chatId,
    );
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
        chatIdentifier: chatIdentifier,
        subject: null,
        subjectState: CloudSemanticFieldState.absent,
        body: null,
        bodyState: CloudSemanticFieldState.absent,
        attributedBodies: [
          CloudSemanticAttributedBody(
            text: 'Only attributed text',
            runs: [
              CloudSemanticTextRun(
                startUtf16: 0,
                lengthUtf16: 20,
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
      ),
      snapshot: _snapshot(CloudEntityKind.message, messageHash),
    );

    final message = store.box<Message>().getAll().single;
    expect(message.text, 'Only attributed text');
    expect(message.fullText, 'Only attributed text');
    expect(message.buildMessageParts().single.text, 'Only attributed text');
  });

  test('keeps identical CloudKit aliases isolated by message service', () {
    const sharedAliasIdentifier = 'shared-cloud-alias';
    const smsChatHash = 'sms-chat-hash';
    const smsChatGuid = 'sms-chat-guid';
    final imessageChatId = store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: 'imessage-local-id', style: 45),
    );
    final smsChatId = store.box<Chat>().put(
      Chat(
        guid: smsChatGuid,
        chatIdentifier: 'sms-local-id',
        style: 45,
        isRpSms: true,
      ),
    );
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: smsChatHash,
      canonicalGuid: smsChatGuid,
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: sharedAliasIdentifier,
      chatId: imessageChatId,
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: smsChatHash,
      canonicalGuid: smsChatGuid,
      chatIdentifier: sharedAliasIdentifier,
      chatId: smsChatId,
      service: CloudSemanticService.sms,
    );
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
        chatIdentifier: sharedAliasIdentifier,
        service: CloudSemanticService.sms,
      ),
      snapshot: _snapshot(CloudEntityKind.message, messageHash),
    );

    expect(store.box<Message>().getAll().single.chat.targetId, smsChatId);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), 2);
  });

  test('retries a message after its cross-zone chat becomes available', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'chatManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final messageScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    const chatGeneration = 7;
    const messageGeneration = 11;
    _seedCheckpoint(store, scope: chatScope, generation: chatGeneration);
    const identifier = 'iMessage;-;cross-zone-chat';
    final crossZoneResolver = _Resolver()
      ..put(
        scope: messageScope,
        generation: messageGeneration,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: 'cross-zone-message-guid',
      );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => CloudCanonicalActiveScope(
        scope: messageScope,
        generation: messageGeneration,
      ),
      resolver: crossZoneResolver,
      chatDependencyScope: CloudCanonicalActiveScope(
        scope: chatScope,
        generation: chatGeneration,
      ),
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );
    final payload = _messagePayload(
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'cross-zone-message-guid',
      chatIdentifier: identifier,
      body: 'ordering-fixture',
      senderHandle: 'mailto:sender@example.invalid',
    );

    expect(
      () => adapter.applyEntity(
        scope: messageScope,
        generation: messageGeneration,
        payload: payload,
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Handle>().count(), 0);

    final chatId = store.box<Chat>().put(
      Chat(guid: 'cross-zone-chat-guid', chatIdentifier: identifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: chatScope,
      generation: chatGeneration,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'cross-zone-chat-guid',
      chatIdentifier: identifier,
      chatId: chatId,
    );

    expect(
      adapter.applyEntity(
        scope: messageScope,
        generation: messageGeneration,
        payload: payload,
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    final messages = store.box<Message>().getAll();
    expect(messages, hasLength(1));
    expect(messages.single.guid, 'cross-zone-message-guid');
    expect(messages.single.chat.targetId, chatId);
    expect(store.box<Handle>().count(), 1);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), 1);
  });

  test('does not accept a stale cross-zone chat ownership generation', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'chatManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final messageScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    const identifier = 'iMessage;-;stale-cross-zone-chat';
    _seedCheckpoint(store, scope: chatScope, generation: 4);
    final chatId = store.box<Chat>().put(
      Chat(guid: 'stale-chat-guid', chatIdentifier: identifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: chatScope,
      generation: 3,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'stale-chat-guid',
      chatIdentifier: identifier,
      chatId: chatId,
    );
    final crossZoneResolver = _Resolver()
      ..put(
        scope: messageScope,
        generation: 9,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: 'stale-message-guid',
      );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () =>
          CloudCanonicalActiveScope(scope: messageScope, generation: 9),
      resolver: crossZoneResolver,
      chatDependencyScope: CloudCanonicalActiveScope(
        scope: chatScope,
        generation: 4,
      ),
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    expect(
      () => adapter.applyEntity(
        scope: messageScope,
        generation: 9,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'stale-message-guid',
          chatIdentifier: identifier,
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
  });

  test('rejects a dependency generation advanced after capture', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'chatManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final messageScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    const identifier = 'iMessage;-;advanced-cross-zone-chat';
    _seedCheckpoint(store, scope: chatScope, generation: 3);
    final chatId = store.box<Chat>().put(
      Chat(guid: 'advanced-chat-guid', chatIdentifier: identifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: chatScope,
      generation: 3,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'advanced-chat-guid',
      chatIdentifier: identifier,
      chatId: chatId,
    );
    final crossZoneResolver = _Resolver()
      ..put(
        scope: messageScope,
        generation: 9,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: 'advanced-message-guid',
      );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () =>
          CloudCanonicalActiveScope(scope: messageScope, generation: 9),
      resolver: crossZoneResolver,
      chatDependencyScope: CloudCanonicalActiveScope(
        scope: chatScope,
        generation: 3,
      ),
      semanticApplyEnabled: true,
      allowMessageUpserts: true,
    );

    _seedCheckpoint(store, scope: chatScope, generation: 4);

    expect(
      () => adapter.applyEntity(
        scope: messageScope,
        generation: 9,
        payload: _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'advanced-message-guid',
          chatIdentifier: identifier,
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_dependency_scope_stale',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
  });

  test('rejects mismatched cross-zone dependency namespaces', () {
    final messageScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    CloudSyncScope dependencyScope({
      String? accountFingerprint,
      String? container,
      String? database,
      String zone = 'chatManateeZone',
      CloudSyncStreamKind streamKind = CloudSyncStreamKind.messages,
      int schemaVersion = 2,
      CloudSyncPersistenceLane persistenceLane =
          CloudSyncPersistenceLane.semantic,
    }) => CloudSyncScope(
      accountFingerprint: accountFingerprint ?? messageScope.accountFingerprint,
      container: container ?? messageScope.container,
      database: database ?? messageScope.database,
      zone: zone,
      streamKind: streamKind,
      schemaVersion: schemaVersion,
      persistenceLane: persistenceLane,
    );
    final mismatches = <CloudSyncScope>[
      dependencyScope(zone: 'messageManateeZone'),
      dependencyScope(accountFingerprint: testAccountFingerprintB),
      dependencyScope(container: 'other-container'),
      dependencyScope(database: 'shared'),
      dependencyScope(streamKind: CloudSyncStreamKind.profiles),
      dependencyScope(schemaVersion: 3),
      dependencyScope(persistenceLane: CloudSyncPersistenceLane.shadow),
    ];

    for (final mismatchedScope in mismatches) {
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () =>
            CloudCanonicalActiveScope(scope: messageScope, generation: 9),
        resolver: _Resolver()
          ..put(
            scope: messageScope,
            generation: 9,
            kind: CloudEntityKind.message,
            logicalEntityKeyHash: messageHash,
            canonicalGuid: 'mismatched-scope-message-guid',
          ),
        chatDependencyScope: CloudCanonicalActiveScope(
          scope: mismatchedScope,
          generation: 9,
        ),
        semanticApplyEnabled: true,
        allowMessageUpserts: true,
      );

      expect(
        () => adapter.applyEntity(
          scope: messageScope,
          generation: 9,
          payload: _messagePayload(
            logicalEntityKeyHash: messageHash,
            canonicalGuid: 'mismatched-scope-message-guid',
            chatIdentifier: 'iMessage;-;mismatched-scope',
          ),
          snapshot: _snapshot(CloudEntityKind.message, messageHash),
        ),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) =>
                failure.safeCode == 'canonical_dependency_scope_conflict',
          ),
        ),
      );
      expect(store.box<Message>().count(), 0);
    }
  });

  test('rejects a same-scope dependency with a different generation', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'chatManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final sameScopeResolver = _Resolver()
      ..put(
        scope: chatScope,
        generation: 4,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: chatHash,
        canonicalGuid: 'same-scope-chat-guid',
      );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () =>
          CloudCanonicalActiveScope(scope: chatScope, generation: 4),
      resolver: sameScopeResolver,
      chatDependencyScope: CloudCanonicalActiveScope(
        scope: chatScope,
        generation: 5,
      ),
      semanticApplyEnabled: true,
    );

    expect(
      () => adapter.entityExists(
        scope: chatScope,
        generation: 4,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: chatHash,
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'canonical_dependency_scope_conflict',
        ),
      ),
    );
  });

  test('does not fall back to an unproven raw chat identifier', () {
    const identifier = 'iMessage;-;raw-only-chat';
    store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: identifier, style: 45),
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
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
          chatIdentifier: identifier,
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Handle>().count(), 0);
  });

  test('ignores and preserves alias1 rows during message resolution', () {
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'chat-guid',
        chatIdentifier: 'legacy-service-identifier',
        style: 45,
      ),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: 'legacy-service-identifier',
      chatId: chatId,
      legacyBinding: true,
    );
    final legacyBefore = store
        .box<CloudSemanticChatAliasEntity>()
        .getAll()
        .single;
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
          chatIdentifier: 'chat-guid',
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );

    final aliasesAfter = store.box<CloudSemanticChatAliasEntity>().getAll();
    expect(aliasesAfter, hasLength(1));
    expect(aliasesAfter.single.id, legacyBefore.id);
    expect(aliasesAfter.single.bindingKey, legacyBefore.bindingKey);
    expect(aliasesAfter.single.bindingKey, startsWith('semantic-chat-alias1:'));
    expect(aliasesAfter.single.updatedAtMs, legacyBefore.updatedAtMs);
    expect(store.box<Message>().count(), 0);
  });

  test('rolls back a strong service-alias conflict from a second owner', () {
    final diagnostics = <String>[];
    const aliasIdentifier = 'already-owned-cloud-alias';
    const conflictingHash = 'conflicting-chat-hash';
    const conflictingGuid = 'conflicting-chat-guid';
    final existingChatId = store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: 'existing-local-id', style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: aliasIdentifier,
      chatId: existingChatId,
    );
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: conflictingHash,
      canonicalGuid: conflictingGuid,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );

    expect(
      () => store.runInTransaction(TxMode.write, () {
        adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: _chatPayload(
            logicalEntityKeyHash: conflictingHash,
            canonicalGuid: conflictingGuid,
            chatIdentifier: 'conflicting-local-id',
            participantHandles: const ['mailto:new@example.com'],
            aliases: [
              CloudSemanticChatAlias(
                kind: CloudSemanticChatAliasKind.serviceIdentifier,
                keyHash: _testChatAliasHash(aliasIdentifier),
              ),
            ],
          ),
          snapshot: _snapshot(CloudEntityKind.chat, conflictingHash),
        );
      }),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_chat_alias_conflict',
        ),
      ),
    );
    expect(store.box<Chat>().count(), 1);
    expect(store.box<Handle>().count(), 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), 1);
    expect(
      diagnostics,
      contains('canonical_chat_alias_conflict_binding_owner'),
    );
    expect(
      store.box<CloudSemanticChatAliasEntity>().getAll().single.chatId,
      existingChatId,
    );
    expect(
      store.box<CloudSemanticChatAliasEntity>().getAll().single.bindingKey,
      startsWith('semantic-chat-strong2:'),
    );
  });

  test(
    'keeps shared typed lineage claims owner-scoped without merging or reparenting',
    () {
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
        allowChatUpserts: true,
      );
      const lineageKinds = [
        CloudSemanticChatAliasKind.groupId,
        CloudSemanticChatAliasKind.originalGroupId,
        CloudSemanticChatAliasKind.legacyGroupIdentifier,
      ];

      for (final kind in lineageKinds) {
        final sharedIdentifier = 'shared-${kind.name}';
        final sharedHash = _testChatAliasHash(sharedIdentifier);
        final firstLogicalHash = 'first-${kind.name}-logical-hash';
        final secondLogicalHash = 'second-${kind.name}-logical-hash';
        final firstGuid = 'first-${kind.name}-guid';
        final secondGuid = 'second-${kind.name}-guid';
        final firstIdentifier = 'first-${kind.name}-service-id';
        final secondIdentifier = 'second-${kind.name}-service-id';
        final firstPayload = _chatPayload(
          logicalEntityKeyHash: firstLogicalHash,
          canonicalGuid: firstGuid,
          chatIdentifier: firstIdentifier,
          style: CloudSemanticChatStyle.group,
          aliases: [
            CloudSemanticChatAlias(
              kind: CloudSemanticChatAliasKind.serviceIdentifier,
              keyHash: _testChatAliasHash(firstIdentifier),
            ),
            CloudSemanticChatAlias(kind: kind, keyHash: sharedHash),
          ],
        );
        final secondPayload = _chatPayload(
          logicalEntityKeyHash: secondLogicalHash,
          canonicalGuid: secondGuid,
          chatIdentifier: secondIdentifier,
          style: CloudSemanticChatStyle.group,
          aliases: [
            CloudSemanticChatAlias(
              kind: CloudSemanticChatAliasKind.serviceIdentifier,
              keyHash: _testChatAliasHash(secondIdentifier),
            ),
            CloudSemanticChatAlias(kind: kind, keyHash: sharedHash),
          ],
        );
        resolver
          ..put(
            scope: scope,
            generation: generation,
            kind: CloudEntityKind.chat,
            logicalEntityKeyHash: firstLogicalHash,
            canonicalGuid: firstGuid,
          )
          ..put(
            scope: scope,
            generation: generation,
            kind: CloudEntityKind.chat,
            logicalEntityKeyHash: secondLogicalHash,
            canonicalGuid: secondGuid,
          );

        store.runInTransaction(TxMode.write, () {
          adapter.applyEntity(
            scope: scope,
            generation: generation,
            payload: firstPayload,
            snapshot: _snapshot(CloudEntityKind.chat, firstLogicalHash),
          );
        });
        _seedExactOwnershipProof(
          store,
          scope: scope,
          generation: generation,
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: firstLogicalHash,
          canonicalGuid: firstGuid,
        );
        final firstChat = store.box<Chat>().getAll().singleWhere(
          (chat) => chat.guid == firstGuid,
        );
        final existingMessageId = store.box<Message>().put(
          Message(
            guid: 'existing-${kind.name}-message-guid',
            dateCreated: testEpoch,
            isFromMe: false,
          )..chat.targetId = firstChat.id!,
        );

        store.runInTransaction(TxMode.write, () {
          adapter.applyEntity(
            scope: scope,
            generation: generation,
            payload: secondPayload,
            snapshot: _snapshot(CloudEntityKind.chat, secondLogicalHash),
          );
        });
        _seedExactOwnershipProof(
          store,
          scope: scope,
          generation: generation,
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: secondLogicalHash,
          canonicalGuid: secondGuid,
        );
        final secondChat = store.box<Chat>().getAll().singleWhere(
          (chat) => chat.guid == secondGuid,
        );
        final claims = store
            .box<CloudSemanticChatAliasEntity>()
            .getAll()
            .where(
              (row) =>
                  row.aliasKind == kind.name && row.aliasKeyHash == sharedHash,
            )
            .toList(growable: false);

        expect(firstChat.id, isNot(secondChat.id));
        expect(claims, hasLength(2));
        expect(claims.map((row) => row.chatLogicalEntityKeyHash).toSet(), {
          firstLogicalHash,
          secondLogicalHash,
        });
        expect(claims.map((row) => row.chatId).toSet(), {
          firstChat.id,
          secondChat.id,
        });
        expect(claims.map((row) => row.bindingKey).toSet(), {
          _testChatAliasBindingKey(
            scope: scope,
            generation: generation,
            service: CloudSemanticService.iMessage,
            kind: kind,
            aliasKeyHash: sharedHash,
            logicalEntityKeyHash: firstLogicalHash,
          ),
          _testChatAliasBindingKey(
            scope: scope,
            generation: generation,
            service: CloudSemanticService.iMessage,
            kind: kind,
            aliasKeyHash: sharedHash,
            logicalEntityKeyHash: secondLogicalHash,
          ),
        });
        expect(
          claims.every(
            (row) => row.bindingKey.startsWith('semantic-chat-claim2:'),
          ),
          isTrue,
        );
        expect(
          store.box<Message>().get(existingMessageId)!.chat.targetId,
          firstChat.id,
        );

        final aliasCountBeforeReplay = store
            .box<CloudSemanticChatAliasEntity>()
            .count();
        store.runInTransaction(TxMode.write, () {
          adapter.applyEntity(
            scope: scope,
            generation: generation,
            payload: secondPayload,
            snapshot: _snapshot(CloudEntityKind.chat, secondLogicalHash),
          );
        });
        expect(
          store.box<CloudSemanticChatAliasEntity>().count(),
          aliasCountBeforeReplay,
        );
        expect(
          store.box<Message>().get(existingMessageId)!.chat.targetId,
          firstChat.id,
        );
      }
    },
  );

  test('keeps weak lineage and msgProto4 claims diagnostic-only', () {
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
      allowMessageUpserts: true,
    );
    const firstLogicalHash = 'typed-first-chat-owner';
    const secondLogicalHash = 'typed-second-chat-owner';
    const thirdLogicalHash = 'typed-third-chat-owner';
    const firstGuid = 'typed-first-chat-guid';
    const secondGuid = 'typed-second-chat-guid';
    const thirdGuid = 'typed-third-chat-guid';
    final sharedOriginalGroupHash = _testChatAliasHash(
      'typed-shared-original-group',
    );
    final firstGroupHash = _testChatAliasHash('typed-first-group');
    final secondGroupHash = _testChatAliasHash('typed-second-group');
    final thirdGroupHash = _testChatAliasHash('typed-third-group');

    final chatInputs = [
      (
        logicalHash: firstLogicalHash,
        guid: firstGuid,
        serviceHash: _testChatAliasHash('typed-first-service'),
        groupHash: firstGroupHash,
        originalGroupHash: sharedOriginalGroupHash,
      ),
      (
        logicalHash: secondLogicalHash,
        guid: secondGuid,
        serviceHash: _testChatAliasHash('typed-second-service'),
        groupHash: secondGroupHash,
        originalGroupHash: sharedOriginalGroupHash,
      ),
      (
        logicalHash: thirdLogicalHash,
        guid: thirdGuid,
        serviceHash: _testChatAliasHash('typed-third-service'),
        groupHash: thirdGroupHash,
        originalGroupHash: _testChatAliasHash('typed-third-original-group'),
      ),
    ];

    for (final input in chatInputs) {
      resolver.put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: input.logicalHash,
        canonicalGuid: input.guid,
      );
      adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: input.logicalHash,
          canonicalGuid: input.guid,
          chatIdentifier: 'service-${input.guid}',
          style: CloudSemanticChatStyle.group,
          aliases: [
            CloudSemanticChatAlias(
              kind: CloudSemanticChatAliasKind.serviceIdentifier,
              keyHash: input.serviceHash,
            ),
            CloudSemanticChatAlias(
              kind: CloudSemanticChatAliasKind.groupId,
              keyHash: input.groupHash,
            ),
            CloudSemanticChatAlias(
              kind: CloudSemanticChatAliasKind.originalGroupId,
              keyHash: input.originalGroupHash,
            ),
          ],
        ),
        snapshot: _snapshot(CloudEntityKind.chat, input.logicalHash),
      );
      _seedExactOwnershipProof(
        store,
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: input.logicalHash,
        canonicalGuid: input.guid,
      );
    }

    final aliasCountBefore = store.box<CloudSemanticChatAliasEntity>().count();
    final unknownServiceHash = _testChatAliasHash(
      'typed-message-unknown-service',
    );
    final candidates = _typedMessageAliases(
      serviceIdentifierHash: unknownServiceHash,
      groupIdHash: _testChatAliasHash('typed-message-unknown-group'),
      originalGroupIdHash: sharedOriginalGroupHash,
      legacyGroupIdentifierHash: _testChatAliasHash(
        'typed-message-unknown-legacy',
      ),
    );
    CloudMessageEntityPayload payload({String? corroboratingGroupHash}) =>
        _messagePayload(
          logicalEntityKeyHash: messageHash,
          canonicalGuid: 'message-guid',
          chatIdentifier: 'typed-unmatched-chat-guid',
          chatAliasKeyHash: unknownServiceHash,
          chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
            'typed-unmatched-chat-owner',
          ),
          chatIdAliasCandidates: candidates,
          msgProto4GroupIdAliasKeyHash: corroboratingGroupHash,
        );

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload(),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload(corroboratingGroupHash: thirdGroupHash),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);

    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: generation,
        payload: payload(corroboratingGroupHash: secondGroupHash),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);
    expect(
      diagnostics,
      containsAll([
        'canonical_message_chat_reference_weak_evidence_only',
        'canonical_message_chat_reference_unavailable',
      ]),
    );
    expect(
      diagnostics,
      isNot(contains('canonical_message_chat_reference_corroborated')),
    );
  });

  test('does not route when all weak chat references agree', () {
    const ownerGuid = 'all-weak-owner-guid';
    const weakIdentifier = 'all-weak-lineage';
    const proto4GroupIdentifier = 'all-weak-proto4-group';
    const chatIdentifier = 'iMessage;-;unmatched-strong-route';
    final ownerLogicalHash = _testChatAliasHash('all-weak-owner-logical');
    final routeHash = _testChatAliasHash(chatIdentifier);
    final weakHash = _testChatAliasHash(weakIdentifier);
    final proto4GroupHash = _testChatAliasHash(proto4GroupIdentifier);
    final chatId = store.box<Chat>().put(
      Chat(guid: ownerGuid, chatIdentifier: 'local-weak-owner', style: 43),
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: ownerLogicalHash,
      canonicalGuid: ownerGuid,
    );
    for (final alias in [
      (
        kind: CloudSemanticChatAliasKind.originalGroupId,
        identifier: weakIdentifier,
      ),
      (
        kind: CloudSemanticChatAliasKind.legacyGroupIdentifier,
        identifier: weakIdentifier,
      ),
      (
        kind: CloudSemanticChatAliasKind.groupId,
        identifier: proto4GroupIdentifier,
      ),
    ]) {
      _seedChatAliasClaim(
        store,
        scope: scope,
        generation: generation,
        logicalEntityKeyHash: ownerLogicalHash,
        canonicalGuid: ownerGuid,
        chatIdentifier: alias.identifier,
        chatId: chatId,
        aliasKind: alias.kind,
      );
    }
    final aliasCountBefore = store.box<CloudSemanticChatAliasEntity>().count();
    final diagnostics = <String>[];
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      diagnosticRecorder: diagnostics.add,
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
          chatIdentifier: chatIdentifier,
          chatAliasKeyHash: routeHash,
          chatIdExactGuidLogicalKeyHash: _testChatAliasHash(
            'missing-all-weak-exact-owner',
          ),
          chatIdAliasCandidates: _typedMessageAliases(
            serviceIdentifierHash: routeHash,
            groupIdHash: routeHash,
            originalGroupIdHash: weakHash,
            legacyGroupIdentifierHash: weakHash,
          ),
          msgProto4GroupIdAliasKeyHash: proto4GroupHash,
        ),
        snapshot: _snapshot(CloudEntityKind.message, messageHash),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_message_chat_unavailable',
        ),
      ),
    );
    expect(store.box<Message>().count(), 0);
    expect(store.box<Chat>().get(chatId), isNotNull);
    expect(store.box<CloudSemanticChatAliasEntity>().count(), aliasCountBefore);
    expect(
      diagnostics,
      contains('canonical_message_chat_reference_weak_evidence_only'),
    );
    expect(
      diagnostics,
      isNot(contains('canonical_message_chat_reference_current_group_id')),
    );
  });

  test('preserves createdAt and monotonically merges message dates', () {
    const chatIdentifier = 'iMessage;-;monotonic-chat';
    final chatId = store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: chatIdentifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: chatIdentifier,
      chatId: chatId,
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
          chatIdentifier: chatIdentifier,
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
    );
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
    const chatIdentifier = 'iMessage;-;attachment-owner-chat';
    final chat = Chat(
      guid: 'chat-guid',
      chatIdentifier: chatIdentifier,
      style: 45,
    );
    final chatId = store.box<Chat>().put(chat);
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: chatIdentifier,
      chatId: chatId,
    );
    final message = Message(
      guid: 'message-guid',
      dateCreated: testEpoch,
      isFromMe: false,
      hasAttachments: true,
    )..chat.target = chat;
    final messageId = store.box<Message>().put(message);
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
    );
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
        chatIdentifier: chatIdentifier,
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
    final secondChatId = store.box<Chat>().put(
      Chat(
        guid: 'second-chat-guid',
        chatIdentifier: 'iMessage;-;second-chat',
        style: 45,
      ),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: 'second-chat-hash',
      canonicalGuid: 'second-chat-guid',
      chatIdentifier: 'iMessage;-;second-chat',
      chatId: secondChatId,
    );
    final existing = Message(
      guid: 'message-guid',
      dateCreated: testEpoch,
      isFromMe: false,
      text: 'original',
    )..chat.targetId = firstChatId;
    store.box<Message>().put(existing);
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
    );
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

  test('rejects a canonical GUID already owned by another entity kind', () {
    final chatId = store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: 'iMessage;-;chat'),
    );
    final existing = Message(
      guid: 'shared-guid',
      dateCreated: testEpoch,
      isFromMe: false,
    )..chat.targetId = chatId;
    final existingId = store.box<Message>().put(existing);
    resolver
      ..put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.reaction,
        logicalEntityKeyHash: 'existing-reaction-key',
        canonicalGuid: 'shared-guid',
      )
      ..put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'new-message-key',
        canonicalGuid: 'shared-guid',
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
          logicalEntityKeyHash: 'new-message-key',
          canonicalGuid: 'shared-guid',
          chatIdentifier: 'iMessage;-;chat',
        ),
        snapshot: _snapshot(CloudEntityKind.message, 'new-message-key'),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_identity_owner_conflict',
        ),
      ),
    );
    final unchanged = store.box<Message>().get(existingId)!;
    expect(unchanged.guid, 'shared-guid');
    expect(unchanged.chat.targetId, chatId);
    expect(unchanged.text, isNull);
    expect(store.box<Handle>().count(), 0);
  });

  test(
    'rejects a released transient GUID reuse using the durable snapshot owner',
    () {
      final chatId = store.box<Chat>().put(
        Chat(guid: 'chat-guid', chatIdentifier: 'iMessage;-;chat'),
      );
      final existingId = store.box<Message>().put(
        Message(
          guid: 'shared-guid',
          dateCreated: testEpoch,
          isFromMe: false,
          text: 'prior durable body',
        )..chat.targetId = chatId,
      );
      final registry = TransientCloudCanonicalIdentityRegistry();
      final priorPayload = _messagePayload(
        logicalEntityKeyHash: 'prior-message-key',
        canonicalGuid: 'shared-guid',
        chatIdentifier: 'iMessage;-;chat',
      );
      final priorLease = registry.bind(
        CloudDecodedMutation.upsert(
          scope: scope,
          generation: generation,
          changeId: 'prior-change',
          snapshot: _snapshot(CloudEntityKind.message, 'prior-message-key'),
          payload: priorPayload,
        ),
      );
      priorLease.release();
      expect(registry.hasActiveLease, isFalse);

      store.runInTransaction(TxMode.write, () {
        store.box<CloudRecordMapEntity>().put(
          CloudRecordMapEntity(
            mapKey: 'prior-record-map',
            scopeKey: _semanticScopeKey(scope),
            accountFingerprint: scope.accountFingerprint,
            zone: scope.zone,
            logicalEntityKeyHash: 'prior-message-key',
            serverRecordIdHash: 'prior-record-id',
            generation: generation,
            encryptedServerRecordId: _protectedReference('prior-record'),
            updatedAtMs: testEpoch.millisecondsSinceEpoch,
          ),
        );
        store.box<CloudSemanticSnapshotEntity>().put(
          CloudSemanticSnapshotEntity(
            snapshotKey: 'prior-semantic-snapshot',
            scopeGenerationKey: _semanticScopeGenerationKey(scope, generation),
            scopeKey: _semanticScopeKey(scope),
            accountFingerprint: scope.accountFingerprint,
            container: scope.container,
            database: scope.database,
            zone: scope.zone,
            streamKind: scope.streamKind.name,
            schemaVersion: scope.schemaVersion,
            generation: generation,
            entityKind: CloudEntityKind.message.name,
            logicalEntityKeyHash: 'prior-message-key',
            canonicalGuidHash: CloudCanonicalIdentityDigest.forPayload(
              scope: scope,
              generation: generation,
              payload: priorPayload,
            ),
            canonicalGuidLookupHash:
                CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
                  scope: scope,
                  generation: generation,
                  canonicalGuid: priorPayload.canonicalGuid,
                ),
            immutableContentDigest: 'prior-content-digest',
            updatedAtMs: testEpoch.millisecondsSinceEpoch,
          ),
        );
      });

      final reusedPayload = _messagePayload(
        logicalEntityKeyHash: 'reused-message-key',
        canonicalGuid: 'shared-guid',
        chatIdentifier: 'iMessage;-;chat',
        body: 'must not replace prior body',
      );
      final reusedLease = registry.bind(
        CloudDecodedMutation.upsert(
          scope: scope,
          generation: generation,
          changeId: 'reused-change',
          snapshot: _snapshot(CloudEntityKind.message, 'reused-message-key'),
          payload: reusedPayload,
        ),
      );
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: registry,
        semanticApplyEnabled: true,
        allowMessageUpserts: true,
      );

      try {
        expect(
          () => adapter.applyEntity(
            scope: scope,
            generation: generation,
            payload: reusedPayload,
            snapshot: _snapshot(CloudEntityKind.message, 'reused-message-key'),
          ),
          throwsA(
            predicate<CloudSyncFailure>(
              (failure) =>
                  failure.safeCode == 'canonical_identity_owner_conflict',
            ),
          ),
        );
      } finally {
        reusedLease.release();
      }

      final unchanged = store.box<Message>().get(existingId)!;
      expect(unchanged.guid, 'shared-guid');
      expect(unchanged.chat.targetId, chatId);
      expect(unchanged.text, 'prior durable body');
      expect(store.box<Message>().count(), 1);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(store.box<Handle>().count(), 0);
    },
  );

  test(
    'rejects a legacy scoped snapshot without an ownership digest before a new canonical row is created',
    () {
      const incomingKey = 'new-message-key';
      const incomingGuid = 'new-message-guid';
      resolver.put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: incomingKey,
        canonicalGuid: incomingGuid,
      );
      store.box<CloudSemanticSnapshotEntity>().put(
        CloudSemanticSnapshotEntity(
          snapshotKey: 'legacy-semantic-snapshot-without-owner',
          scopeGenerationKey: _semanticScopeGenerationKey(scope, generation),
          scopeKey: _semanticScopeKey(scope),
          accountFingerprint: scope.accountFingerprint,
          container: scope.container,
          database: scope.database,
          zone: scope.zone,
          streamKind: scope.streamKind.name,
          schemaVersion: scope.schemaVersion,
          generation: generation,
          entityKind: CloudEntityKind.message.name,
          logicalEntityKeyHash: 'legacy-message-key',
          immutableContentDigest: 'legacy-content-digest',
          updatedAtMs: testEpoch.millisecondsSinceEpoch,
        ),
      );
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
        allowMessageUpserts: true,
      );

      expect(store.box<Message>().count(), 0);
      expect(
        () => adapter.applyEntity(
          scope: scope,
          generation: generation,
          payload: _messagePayload(
            logicalEntityKeyHash: incomingKey,
            canonicalGuid: incomingGuid,
            chatIdentifier: 'iMessage;-;chat',
          ),
          snapshot: _snapshot(CloudEntityKind.message, incomingKey),
        ),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) =>
                failure.safeCode == 'canonical_identity_owner_unproven',
          ),
        ),
      );
      expect(store.box<Message>().count(), 0);
      expect(store.box<Handle>().count(), 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
    },
  );

  test('proves exact legacy chat ownership without mutating the chat', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'chatManateeZone',
    );
    const logicalKey = 'legacy-chat-proof-key';
    const canonicalGuid = 'legacy-chat-proof-guid';
    const chatIdentifier = 'legacy-chat-proof-identifier';
    resolver.put(
      scope: chatScope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: logicalKey,
      canonicalGuid: canonicalGuid,
    );
    activeScope = CloudCanonicalActiveScope(
      scope: chatScope,
      generation: generation,
    );
    final chat = Chat(
      guid: canonicalGuid,
      chatIdentifier: chatIdentifier,
      style: null,
    )..isRpSms = false;
    final chatId = store.box<Chat>().put(chat);
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
    );
    final payload = _chatPayload(
      logicalEntityKeyHash: logicalKey,
      canonicalGuid: canonicalGuid,
      chatIdentifier: chatIdentifier,
      displayName: 'mutable-name-is-not-identity',
    );
    final snapshot = _snapshot(CloudEntityKind.chat, logicalKey);
    final before = store.box<Chat>().get(chatId)!;

    final proof = adapter.proveLegacyCanonicalOwnership(
      scope: chatScope,
      generation: generation,
      payload: payload,
      snapshot: snapshot,
    );

    expect(
      proof.canonicalGuidHash,
      CloudCanonicalIdentityDigest.forPayload(
        scope: chatScope,
        generation: generation,
        payload: payload,
      ),
    );
    expect(
      proof.canonicalGuidLookupHash,
      CloudCanonicalIdentityDigest.forPayloadLookup(
        scope: chatScope,
        generation: generation,
        payload: payload,
      ),
    );
    final after = store.box<Chat>().get(chatId)!;
    expect(after.guid, before.guid);
    expect(after.chatIdentifier, before.chatIdentifier);
    expect(after.style, before.style);
    expect(after.displayName, before.displayName);
  });

  test('rejects contradictory non-null legacy chat style ownership', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'chatManateeZone',
    );
    const logicalKey = 'legacy-chat-style-mismatch-key';
    const canonicalGuid = 'legacy-chat-style-mismatch-guid';
    const chatIdentifier = 'legacy-chat-style-mismatch-identifier';
    resolver.put(
      scope: chatScope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: logicalKey,
      canonicalGuid: canonicalGuid,
    );
    activeScope = CloudCanonicalActiveScope(
      scope: chatScope,
      generation: generation,
    );
    store.box<Chat>().put(
      Chat(guid: canonicalGuid, chatIdentifier: chatIdentifier, style: 43)
        ..isRpSms = false,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
    );

    expect(
      () => adapter.proveLegacyCanonicalOwnership(
        scope: chatScope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: logicalKey,
          canonicalGuid: canonicalGuid,
          chatIdentifier: chatIdentifier,
        ),
        snapshot: _snapshot(CloudEntityKind.chat, logicalKey),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'legacy_ownership_canonical_row_mismatch',
        ),
      ),
    );
  });

  test('proves exact legacy message ownership without comparing body', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'chatManateeZone',
    );
    const chatGuid = 'legacy-message-proof-chat-guid';
    const chatIdentifier = 'legacy-message-proof-chat-identifier';
    const logicalKey = 'legacy-message-proof-key';
    const canonicalGuid = 'legacy-message-proof-guid';
    resolver
      ..put(
        scope: chatScope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: chatHash,
        canonicalGuid: chatGuid,
      )
      ..put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: logicalKey,
        canonicalGuid: canonicalGuid,
      );
    final chat = Chat(guid: chatGuid, chatIdentifier: chatIdentifier, style: 45)
      ..isRpSms = false;
    final chatId = store.box<Chat>().put(chat);
    _seedChatOwnershipAndAlias(
      store,
      scope: chatScope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: chatGuid,
      chatIdentifier: chatIdentifier,
      chatId: chatId,
    );
    _seedCheckpoint(store, scope: chatScope, generation: generation);
    final message =
        Message(
            guid: canonicalGuid,
            dateCreated: testEpoch,
            text: 'old mutable body',
          )
          ..chat.targetId = chatId
          ..isFromMe = false;
    final messageId = store.box<Message>().put(message);
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      chatDependencyScope: CloudCanonicalActiveScope(
        scope: chatScope,
        generation: generation,
      ),
      semanticApplyEnabled: true,
    );
    final payload = _messagePayload(
      logicalEntityKeyHash: logicalKey,
      canonicalGuid: canonicalGuid,
      chatIdentifier: chatIdentifier,
      body: 'new mutable body',
    );

    final proof = adapter.proveLegacyCanonicalOwnership(
      scope: scope,
      generation: generation,
      payload: payload,
      snapshot: _snapshot(CloudEntityKind.message, logicalKey),
    );

    expect(
      proof.canonicalGuidHash,
      CloudCanonicalIdentityDigest.forPayload(
        scope: scope,
        generation: generation,
        payload: payload,
      ),
    );
    expect(store.box<Message>().get(messageId)!.text, 'old mutable body');
  });

  test('proves exact legacy reaction ownership through its stored parent', () {
    const reactionLogicalKey = 'legacy-reaction-proof-key';
    const reactionGuid = 'legacy-reaction-proof-guid';
    const parentGuid = 'message-guid';
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.reaction,
      logicalEntityKeyHash: reactionLogicalKey,
      canonicalGuid: reactionGuid,
    );
    final chatId = store.box<Chat>().put(
      Chat(
        guid: 'legacy-reaction-chat-guid',
        chatIdentifier: 'legacy-reaction-chat',
        style: 45,
      )..isRpSms = false,
    );
    final parentId = store.box<Message>().put(
      Message(guid: parentGuid, dateCreated: testEpoch, isFromMe: false)
        ..chat.targetId = chatId,
    );
    final reactionId = store.box<Message>().put(
      Message(guid: reactionGuid, dateCreated: testEpoch, isFromMe: false)
        ..chat.targetId = chatId
        ..associatedMessageGuid = parentGuid
        ..associatedMessagePart = 0
        ..associatedMessageType = 'emoji',
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: parentGuid,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
    );
    final payload = _reactionPayload(
      logicalEntityKeyHash: reactionLogicalKey,
      canonicalGuid: reactionGuid,
      parentLogicalKeyHash: messageHash,
      parentCanonicalGuid: parentGuid,
      parentPart: 0,
    );

    final proof = adapter.proveLegacyCanonicalOwnership(
      scope: scope,
      generation: generation,
      payload: payload,
      snapshot: _snapshot(
        CloudEntityKind.reaction,
        reactionLogicalKey,
        parentLogicalKeyHash: messageHash,
      ),
    );

    expect(
      proof.canonicalGuidHash,
      CloudCanonicalIdentityDigest.forPayload(
        scope: scope,
        generation: generation,
        payload: payload,
      ),
    );
    expect(store.box<Message>().get(parentId)!.guid, parentGuid);
    expect(
      store.box<Message>().get(reactionId)!.associatedMessageGuid,
      parentGuid,
    );
  });

  test(
    'rejects legacy reaction when parent proof is from a stale generation',
    () {
      const reactionLogicalKey = 'legacy-reaction-stale-parent-key';
      const reactionGuid = 'legacy-reaction-stale-parent-guid';
      const parentGuid = 'message-guid';
      resolver.put(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.reaction,
        logicalEntityKeyHash: reactionLogicalKey,
        canonicalGuid: reactionGuid,
      );
      final chatId = store.box<Chat>().put(
        Chat(
          guid: 'legacy-reaction-stale-chat-guid',
          chatIdentifier: 'legacy-reaction-stale-chat',
          style: 45,
        )..isRpSms = false,
      );
      store.box<Message>()
        ..put(
          Message(guid: parentGuid, dateCreated: testEpoch, isFromMe: false)
            ..chat.targetId = chatId,
        )
        ..put(
          Message(guid: reactionGuid, dateCreated: testEpoch, isFromMe: false)
            ..chat.targetId = chatId
            ..associatedMessageGuid = parentGuid
            ..associatedMessagePart = 0
            ..associatedMessageType = 'emoji',
        );
      _seedExactOwnershipProof(
        store,
        scope: scope,
        generation: generation + 1,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: parentGuid,
      );
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
      );
      final payload = _reactionPayload(
        logicalEntityKeyHash: reactionLogicalKey,
        canonicalGuid: reactionGuid,
        parentLogicalKeyHash: messageHash,
        parentCanonicalGuid: parentGuid,
        parentPart: 0,
      );

      expect(
        () => adapter.proveLegacyCanonicalOwnership(
          scope: scope,
          generation: generation,
          payload: payload,
          snapshot: _snapshot(
            CloudEntityKind.reaction,
            reactionLogicalKey,
            parentLogicalKeyHash: messageHash,
          ),
        ),
        throwsA(
          predicate<CloudSyncFailure>(
            (failure) =>
                failure.safeCode == 'canonical_identity_owner_unproven',
          ),
        ),
      );
    },
  );

  test('rejects legacy ownership when payload and snapshot parents differ', () {
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
    );

    expect(
      () => adapter.proveLegacyCanonicalOwnership(
        scope: scope,
        generation: generation,
        payload: _reactionPayload(
          logicalEntityKeyHash: 'legacy-reaction-parent-mismatch-key',
          canonicalGuid: 'legacy-reaction-parent-mismatch-guid',
          parentLogicalKeyHash: messageHash,
          parentCanonicalGuid: 'message-guid',
          parentPart: 0,
        ),
        snapshot: _snapshot(
          CloudEntityKind.reaction,
          'legacy-reaction-parent-mismatch-key',
          parentLogicalKeyHash: 'different-parent-logical-key',
        ),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'legacy_ownership_canonical_shape_invalid',
        ),
      ),
    );
  });

  test('proves exact legacy attachment ownership through its stored owner', () {
    final messageScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'messageManateeZone',
    );
    final attachmentScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'attachmentManateeZone',
    );
    const attachmentLogicalKey = 'legacy-attachment-proof-key';
    const ownerGuid = 'message-guid';
    const ownerPart = 1;
    const attachmentGuid = '${ownerGuid}_$ownerPart';
    resolver
      ..put(
        scope: attachmentScope,
        generation: generation,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: attachmentLogicalKey,
        canonicalGuid: attachmentGuid,
      )
      ..put(
        scope: attachmentScope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: ownerGuid,
      );
    activeScope = CloudCanonicalActiveScope(
      scope: attachmentScope,
      generation: generation,
    );
    final ownerId = store.box<Message>().put(
      Message(guid: ownerGuid, dateCreated: testEpoch, isFromMe: false),
    );
    final attachmentId = store.box<Attachment>().put(
      Attachment(guid: attachmentGuid)..message.targetId = ownerId,
    );
    _seedCheckpoint(store, scope: messageScope, generation: generation);
    _seedExactOwnershipProof(
      store,
      scope: messageScope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: ownerGuid,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      messageDependencyScope: CloudCanonicalActiveScope(
        scope: messageScope,
        generation: generation,
      ),
      semanticApplyEnabled: true,
    );
    final payload = _attachmentPayload(
      logicalEntityKeyHash: attachmentLogicalKey,
      canonicalGuid: attachmentGuid,
      ownerLogicalKeyHash: messageHash,
      ownerCanonicalGuid: ownerGuid,
      ownerPart: ownerPart,
      protectedLocalReference: 'protected:legacy-attachment-proof',
    );

    final proof = adapter.proveLegacyCanonicalOwnership(
      scope: attachmentScope,
      generation: generation,
      payload: payload,
      snapshot: _snapshot(
        CloudEntityKind.attachment,
        attachmentLogicalKey,
        parentLogicalKeyHash: messageHash,
      ),
    );

    expect(
      proof.canonicalGuidLookupHash,
      CloudCanonicalIdentityDigest.forPayloadLookup(
        scope: attachmentScope,
        generation: generation,
        payload: payload,
      ),
    );
    expect(
      store.box<Attachment>().get(attachmentId)!.message.targetId,
      ownerId,
    );
  });

  test('rejects legacy attachment owner proof from another account scope', () {
    final messageScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'messageManateeZone',
    );
    final staleMessageScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintB,
      container: scope.container,
      database: scope.database,
      zone: 'messageManateeZone',
    );
    final attachmentScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'attachmentManateeZone',
    );
    const attachmentLogicalKey = 'legacy-attachment-cross-scope-key';
    const ownerGuid = 'legacy-attachment-cross-scope-owner';
    const attachmentGuid = '${ownerGuid}_2';
    final attachmentResolver = _Resolver()
      ..put(
        scope: attachmentScope,
        generation: generation,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: attachmentLogicalKey,
        canonicalGuid: attachmentGuid,
      )
      ..put(
        scope: attachmentScope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: ownerGuid,
      );
    activeScope = CloudCanonicalActiveScope(
      scope: attachmentScope,
      generation: generation,
    );
    final ownerId = store.box<Message>().put(
      Message(guid: ownerGuid, dateCreated: testEpoch, isFromMe: false),
    );
    store.box<Attachment>().put(
      Attachment(guid: attachmentGuid)..message.targetId = ownerId,
    );
    _seedCheckpoint(store, scope: messageScope, generation: generation);
    _seedExactOwnershipProof(
      store,
      scope: staleMessageScope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: ownerGuid,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: attachmentResolver,
      messageDependencyScope: CloudCanonicalActiveScope(
        scope: messageScope,
        generation: generation,
      ),
      semanticApplyEnabled: true,
    );
    final payload = _attachmentPayload(
      logicalEntityKeyHash: attachmentLogicalKey,
      canonicalGuid: attachmentGuid,
      ownerLogicalKeyHash: messageHash,
      ownerCanonicalGuid: ownerGuid,
      ownerPart: 2,
      protectedLocalReference: 'protected:cross-scope-rejected',
    );

    expect(
      () => adapter.proveLegacyCanonicalOwnership(
        scope: attachmentScope,
        generation: generation,
        payload: payload,
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          attachmentLogicalKey,
          parentLogicalKeyHash: messageHash,
        ),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) => failure.safeCode == 'canonical_identity_owner_unproven',
        ),
      ),
    );
  });

  test('rejects legacy ownership when immutable chat identity differs', () {
    final chatScope = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'chatManateeZone',
    );
    const logicalKey = 'legacy-chat-mismatch-key';
    const canonicalGuid = 'legacy-chat-mismatch-guid';
    resolver.put(
      scope: chatScope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: logicalKey,
      canonicalGuid: canonicalGuid,
    );
    activeScope = CloudCanonicalActiveScope(
      scope: chatScope,
      generation: generation,
    );
    store.box<Chat>().put(
      Chat(
        guid: canonicalGuid,
        chatIdentifier: 'different-identifier',
        style: 45,
      )..isRpSms = false,
    );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => activeScope,
      resolver: resolver,
      semanticApplyEnabled: true,
    );

    expect(
      () => adapter.proveLegacyCanonicalOwnership(
        scope: chatScope,
        generation: generation,
        payload: _chatPayload(
          logicalEntityKeyHash: logicalKey,
          canonicalGuid: canonicalGuid,
          chatIdentifier: 'expected-identifier',
        ),
        snapshot: _snapshot(CloudEntityKind.chat, logicalKey),
      ),
      throwsA(
        predicate<CloudSyncFailure>(
          (failure) =>
              failure.safeCode == 'legacy_ownership_canonical_row_mismatch',
        ),
      ),
    );
  });

  test(
    'rejects ownership evidence re-homed across scope generation kind or owner',
    () {
      final alternateScope = CloudSyncScope(
        accountFingerprint: testAccountFingerprintB,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
      );
      const canonicalGuid = 're-homed-guid';
      const sourceOwner = 'source-owner';
      const targetOwner = 'target-owner';
      final cases =
          <
            (
              String,
              CloudSyncScope,
              int,
              CloudEntityKind,
              String,
              CloudSyncScope,
              int,
              CloudEntityKind,
              String,
            )
          >[
            (
              'scope',
              alternateScope,
              generation,
              CloudEntityKind.message,
              sourceOwner,
              scope,
              generation,
              CloudEntityKind.message,
              sourceOwner,
            ),
            (
              'generation',
              scope,
              generation + 1,
              CloudEntityKind.message,
              sourceOwner,
              scope,
              generation,
              CloudEntityKind.message,
              sourceOwner,
            ),
            (
              'kind',
              scope,
              generation,
              CloudEntityKind.reaction,
              sourceOwner,
              scope,
              generation,
              CloudEntityKind.message,
              sourceOwner,
            ),
            (
              'owner',
              scope,
              generation,
              CloudEntityKind.message,
              targetOwner,
              scope,
              generation,
              CloudEntityKind.message,
              sourceOwner,
            ),
          ];

      for (final value in cases) {
        final (
          label,
          targetScope,
          targetGeneration,
          targetKind,
          targetOwner,
          sourceScope,
          sourceGeneration,
          sourceKind,
          sourceOwnerForDigest,
        ) = value;
        final caseCanonicalGuid = '$canonicalGuid-$label';
        store.box<CloudSemanticSnapshotEntity>().removeAll();
        resolver.put(
          scope: targetScope,
          generation: targetGeneration,
          kind: targetKind,
          logicalEntityKeyHash: targetOwner,
          canonicalGuid: caseCanonicalGuid,
        );
        activeScope = CloudCanonicalActiveScope(
          scope: targetScope,
          generation: targetGeneration,
        );
        store.box<CloudSemanticSnapshotEntity>().put(
          CloudSemanticSnapshotEntity(
            snapshotKey: 're-homed-$label',
            scopeGenerationKey: _semanticScopeGenerationKey(
              targetScope,
              targetGeneration,
            ),
            scopeKey: _semanticScopeKey(targetScope),
            accountFingerprint: targetScope.accountFingerprint,
            container: targetScope.container,
            database: targetScope.database,
            zone: targetScope.zone,
            streamKind: targetScope.streamKind.name,
            schemaVersion: targetScope.schemaVersion,
            generation: targetGeneration,
            entityKind: targetKind.name,
            logicalEntityKeyHash: targetOwner,
            canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
              scope: sourceScope,
              generation: sourceGeneration,
              kind: sourceKind,
              logicalEntityKeyHash: sourceOwnerForDigest,
              canonicalGuid: caseCanonicalGuid,
            ),
            canonicalGuidLookupHash:
                CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
                  scope: targetScope,
                  generation: targetGeneration,
                  canonicalGuid: caseCanonicalGuid,
                ),
            updatedAtMs: testEpoch.millisecondsSinceEpoch,
          ),
        );
        final adapter = _newAdapter(
          store: store,
          activeScopeProvider: () => activeScope,
          resolver: resolver,
          semanticApplyEnabled: true,
        );

        expect(
          () => adapter.validateOwnershipEvidence(
            scope: targetScope,
            generation: targetGeneration,
            kind: targetKind,
            logicalEntityKeyHash: targetOwner,
          ),
          throwsA(
            predicate<CloudSyncFailure>(
              (failure) =>
                  failure.safeCode == 'canonical_identity_owner_unproven',
            ),
          ),
          reason: label,
        );
      }
    },
  );

  test(
    'rejects inherited and foreign-scope canonical rows without an exact current durable proof',
    () {
      final chatId = store.box<Chat>().put(
        Chat(guid: 'chat-guid', chatIdentifier: 'iMessage;-;ownership-chat'),
      );
      final adapter = _newAdapter(
        store: store,
        activeScopeProvider: () => activeScope,
        resolver: resolver,
        semanticApplyEnabled: true,
        allowMessageUpserts: true,
      );
      final foreignScope = CloudSyncScope(
        accountFingerprint: testAccountFingerprintB,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
      );
      final cases = <(String, String, bool)>[
        ('inherited-without-proof', 'inherited-guid', false),
        ('foreign-scope-proof', 'foreign-guid', true),
      ];

      for (final (logicalKey, canonicalGuid, seedForeignProof) in cases) {
        final existingId = store.box<Message>().put(
          Message(
            guid: canonicalGuid,
            dateCreated: testEpoch,
            isFromMe: false,
            text: 'must remain unchanged',
          )..chat.targetId = chatId,
        );
        resolver.put(
          scope: scope,
          generation: generation,
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: logicalKey,
          canonicalGuid: canonicalGuid,
        );
        if (seedForeignProof) {
          store.box<CloudSemanticSnapshotEntity>().put(
            CloudSemanticSnapshotEntity(
              snapshotKey: 'foreign-proof-$logicalKey',
              scopeGenerationKey: _semanticScopeGenerationKey(
                foreignScope,
                generation,
              ),
              scopeKey: _semanticScopeKey(foreignScope),
              accountFingerprint: foreignScope.accountFingerprint,
              container: foreignScope.container,
              database: foreignScope.database,
              zone: foreignScope.zone,
              streamKind: foreignScope.streamKind.name,
              schemaVersion: foreignScope.schemaVersion,
              generation: generation,
              entityKind: CloudEntityKind.message.name,
              logicalEntityKeyHash: logicalKey,
              canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
                scope: foreignScope,
                generation: generation,
                kind: CloudEntityKind.message,
                logicalEntityKeyHash: logicalKey,
                canonicalGuid: canonicalGuid,
              ),
              canonicalGuidLookupHash:
                  CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
                    scope: foreignScope,
                    generation: generation,
                    canonicalGuid: canonicalGuid,
                  ),
              updatedAtMs: testEpoch.millisecondsSinceEpoch,
            ),
          );
        }

        expect(
          () => adapter.applyEntity(
            scope: scope,
            generation: generation,
            payload: _messagePayload(
              logicalEntityKeyHash: logicalKey,
              canonicalGuid: canonicalGuid,
              chatIdentifier: 'iMessage;-;ownership-chat',
              body: 'must not be written',
            ),
            snapshot: _snapshot(CloudEntityKind.message, logicalKey),
          ),
          throwsA(
            predicate<CloudSyncFailure>(
              (failure) =>
                  failure.safeCode == 'canonical_identity_owner_unproven',
            ),
          ),
          reason: logicalKey,
        );
        expect(
          store.box<Message>().get(existingId)!.text,
          'must remain unchanged',
        );
      }
      expect(store.box<Handle>().count(), 0);
    },
  );

  test('rolls back a message and sender handle for a malformed text range', () {
    const chatIdentifier = 'iMessage;-;range-chat';
    final chatId = store.box<Chat>().put(
      Chat(guid: 'chat-guid', chatIdentifier: chatIdentifier, style: 45),
    );
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
      chatIdentifier: chatIdentifier,
      chatId: chatId,
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
      chatIdentifier: chatIdentifier,
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
      _seedExactOwnershipProof(
        store,
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: 'message-guid',
      );
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
      _seedExactOwnershipProof(
        store,
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.reaction,
        logicalEntityKeyHash: reactionHash,
        canonicalGuid: 'reaction-guid',
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
    );
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: ownerLogicalKeyHash,
      canonicalGuid: 'message_guid_with_underscores',
    );
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: 'attachment-hash',
      canonicalGuid: 'message_guid_with_underscores_2',
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
    expect(attachment.metadata, <String, dynamic>{
      cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
      cloudAttachmentV2BodyCapabilityKey:
          CloudAttachmentBodyCapability.materializable.metadataValue,
    });
    expect(attachment.bytes, isNull);
    expect(attachment.sourcePath, isNull);
  });

  test('resolves an attachment owner through the message-zone scope', () {
    final messageScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final attachmentScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'container',
      database: 'private',
      zone: 'attachmentManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    const messageGeneration = 5;
    const attachmentGeneration = 8;
    _seedCheckpoint(store, scope: messageScope, generation: messageGeneration);
    const ownerHash = 'cross-zone-attachment-owner-hash';
    const attachmentHash = 'cross-zone-attachment-hash';
    const ownerGuid = 'cross-zone-owner-guid';
    const attachmentGuid = '${ownerGuid}_1';
    final ownerId = store.box<Message>().put(
      Message(guid: ownerGuid, dateCreated: testEpoch, isFromMe: false),
    );
    _seedExactOwnershipProof(
      store,
      scope: messageScope,
      generation: messageGeneration,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: ownerHash,
      canonicalGuid: ownerGuid,
    );
    final crossZoneResolver = _Resolver()
      ..put(
        scope: attachmentScope,
        generation: attachmentGeneration,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: ownerHash,
        canonicalGuid: ownerGuid,
      )
      ..put(
        scope: attachmentScope,
        generation: attachmentGeneration,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: attachmentHash,
        canonicalGuid: attachmentGuid,
      );
    final adapter = _newAdapter(
      store: store,
      activeScopeProvider: () => CloudCanonicalActiveScope(
        scope: attachmentScope,
        generation: attachmentGeneration,
      ),
      resolver: crossZoneResolver,
      messageDependencyScope: CloudCanonicalActiveScope(
        scope: messageScope,
        generation: messageGeneration,
      ),
      semanticApplyEnabled: true,
      allowAttachmentMetadataUpserts: true,
    );

    expect(
      adapter.entityExists(
        scope: attachmentScope,
        generation: attachmentGeneration,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: ownerHash,
      ),
      isTrue,
    );
    expect(
      adapter.applyEntity(
        scope: attachmentScope,
        generation: attachmentGeneration,
        payload: _attachmentPayload(
          logicalEntityKeyHash: attachmentHash,
          canonicalGuid: attachmentGuid,
          ownerLogicalKeyHash: ownerHash,
          ownerCanonicalGuid: ownerGuid,
          ownerPart: 1,
          protectedLocalReference: 'protected:cross-zone',
        ),
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          attachmentHash,
          parentLogicalKeyHash: ownerHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    expect(store.box<Attachment>().getAll().single.message.targetId, ownerId);
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
    expect(attachment.metadata, <String, dynamic>{
      cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
      cloudAttachmentV2BodyCapabilityKey:
          CloudAttachmentBodyCapability.materializable.metadataValue,
    });
  });

  test('metadata-only attachment can never enter a body download lane', () {
    resolver.put(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: 'metadata-only-attachment-hash',
      canonicalGuid: 'metadata-only-attachment-guid',
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
        logicalEntityKeyHash: 'metadata-only-attachment-hash',
        canonicalGuid: 'metadata-only-attachment-guid',
        ownerLogicalKeyHash: null,
        ownerCanonicalGuid: null,
        ownerPart: null,
        bodyCapability: CloudAttachmentBodyCapability
            .metadataOnlyUnsupportedMediaCredentials,
        protectedLocalReference: 'protected:metadata-only',
      ),
      snapshot: _snapshot(
        CloudEntityKind.attachment,
        'metadata-only-attachment-hash',
      ),
    );

    final attachment = store.box<Attachment>().getAll().single;
    expect(attachment.metadata, <String, dynamic>{
      cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
      cloudAttachmentV2BodyCapabilityKey: CloudAttachmentBodyCapability
          .metadataOnlyUnsupportedMediaCredentials
          .metadataValue,
    });
    expect(
      cloudAttachmentDownloadLaneFor(attachment.metadata),
      CloudAttachmentDownloadLane.unavailable,
    );
    expect(attachment.bytes, isNull);
    expect(attachment.sourcePath, isNull);
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: messageHash,
      canonicalGuid: 'message-guid',
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: 'relation-conflict-hash',
      canonicalGuid: 'message-guid_1',
    );
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
      _seedExactOwnershipProof(
        store,
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: messageHash,
        canonicalGuid: 'message-guid',
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: chatHash,
      canonicalGuid: 'chat-guid',
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
  CloudCanonicalActiveScope? chatDependencyScope,
  CloudCanonicalActiveScope? messageDependencyScope,
  CloudSyncSemanticDiagnosticRecorder? diagnosticRecorder,
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
  chatDependencyScope: chatDependencyScope,
  messageDependencyScope: messageDependencyScope,
  diagnosticRecorder: diagnosticRecorder,
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
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticChatStyle style = CloudSemanticChatStyle.direct,
  Iterable<CloudSemanticChatAlias>? aliases,
  int? groupVersion,
}) => CloudChatEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  chatIdentifier: chatIdentifier,
  displayName: displayName,
  displayNameState: displayNameState,
  participantHandles: participantHandles,
  aliases:
      aliases ??
      [
        CloudSemanticChatAlias(
          kind: CloudSemanticChatAliasKind.serviceIdentifier,
          keyHash: _testChatAliasHash(chatIdentifier),
        ),
      ],
  service: service,
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
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticKnownMessageFlags? knownFlags,
  String? chatAliasKeyHash,
  String? chatIdExactGuidLogicalKeyHash,
  String? chatIdBareDirectServiceIdentifierAliasKeyHash,
  Iterable<CloudSemanticChatAlias> chatIdAliasCandidates = const [],
  String? msgProto4GroupIdAliasKeyHash,
}) => CloudMessageEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  chatAliasKeyHash: chatAliasKeyHash ?? _testChatAliasHash(chatIdentifier),
  chatIdentifier: chatIdentifier,
  chatIdExactGuidLogicalKeyHash: chatIdExactGuidLogicalKeyHash,
  chatIdBareDirectServiceIdentifierAliasKeyHash:
      chatIdBareDirectServiceIdentifierAliasKeyHash,
  chatIdAliasCandidates: chatIdAliasCandidates,
  msgProto4GroupIdAliasKeyHash: msgProto4GroupIdAliasKeyHash,
  body: body,
  senderHandle: senderHandle,
  createdAt: createdAt ?? testEpoch,
  service: service,
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
  CloudAttachmentBodyCapability bodyCapability =
      CloudAttachmentBodyCapability.materializable,
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
  bodyCapability: bodyCapability,
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

String _testChatAliasHash(String value) => base64Url
    .encode(sha256.convert(utf8.encode('test-chat-alias\u001f$value')).bytes)
    .replaceAll('=', '');

List<CloudSemanticChatAlias> _typedMessageAliases({
  required String serviceIdentifierHash,
  String? groupIdHash,
  String? originalGroupIdHash,
  String? legacyGroupIdentifierHash,
}) => [
  CloudSemanticChatAlias(
    kind: CloudSemanticChatAliasKind.serviceIdentifier,
    keyHash: serviceIdentifierHash,
  ),
  CloudSemanticChatAlias(
    kind: CloudSemanticChatAliasKind.groupId,
    keyHash: groupIdHash ?? _testChatAliasHash('typed-message-group-id'),
  ),
  CloudSemanticChatAlias(
    kind: CloudSemanticChatAliasKind.originalGroupId,
    keyHash:
        originalGroupIdHash ??
        _testChatAliasHash('typed-message-original-group-id'),
  ),
  CloudSemanticChatAlias(
    kind: CloudSemanticChatAliasKind.legacyGroupIdentifier,
    keyHash:
        legacyGroupIdentifierHash ??
        _testChatAliasHash('typed-message-legacy-group-identifier'),
  ),
];

void _seedChatOwnershipAndAlias(
  Store store, {
  required CloudSyncScope scope,
  required int generation,
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  required int chatId,
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticChatAliasKind aliasKind =
      CloudSemanticChatAliasKind.serviceIdentifier,
  bool legacyBinding = false,
}) {
  _seedExactOwnershipProof(
    store,
    scope: scope,
    generation: generation,
    kind: CloudEntityKind.chat,
    logicalEntityKeyHash: logicalEntityKeyHash,
    canonicalGuid: canonicalGuid,
  );
  _seedChatAliasClaim(
    store,
    scope: scope,
    generation: generation,
    logicalEntityKeyHash: logicalEntityKeyHash,
    canonicalGuid: canonicalGuid,
    chatIdentifier: chatIdentifier,
    chatId: chatId,
    service: service,
    aliasKind: aliasKind,
    legacyBinding: legacyBinding,
  );
}

void _seedChatAliasClaim(
  Store store, {
  required CloudSyncScope scope,
  required int generation,
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  required int chatId,
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticChatAliasKind aliasKind =
      CloudSemanticChatAliasKind.serviceIdentifier,
  bool legacyBinding = false,
}) {
  final aliasKeyHash = _testChatAliasHash(chatIdentifier);
  final bindingKey = _testChatAliasBindingKey(
    scope: scope,
    generation: generation,
    service: service,
    kind: aliasKind,
    aliasKeyHash: aliasKeyHash,
    logicalEntityKeyHash: logicalEntityKeyHash,
    legacy: legacyBinding,
  );
  store.box<CloudSemanticChatAliasEntity>().put(
    CloudSemanticChatAliasEntity(
      bindingKey: bindingKey,
      scopeGenerationKey: _semanticScopeGenerationKey(scope, generation),
      scopeKey: _semanticScopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      service: service.name,
      aliasKind: aliasKind.name,
      aliasKeyHash: aliasKeyHash,
      chatLogicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: logicalEntityKeyHash,
        canonicalGuid: canonicalGuid,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: generation,
            canonicalGuid: canonicalGuid,
          ),
      chatId: chatId,
      updatedAtMs: testEpoch.millisecondsSinceEpoch,
    ),
  );
}

String _testChatAliasBindingKey({
  required CloudSyncScope scope,
  required int generation,
  required CloudSemanticService service,
  required CloudSemanticChatAliasKind kind,
  required String aliasKeyHash,
  required String logicalEntityKeyHash,
  bool legacy = false,
}) {
  if (legacy) {
    return 'semantic-chat-alias1:${sha256.convert(utf8.encode('${scope.storageKey}\u001f$generation\u001f${service.name}\u001f${kind.name}\u001f$aliasKeyHash'))}';
  }
  if (kind == CloudSemanticChatAliasKind.serviceIdentifier) {
    return 'semantic-chat-strong2:${sha256.convert(utf8.encode('${scope.storageKey}\u001f$generation\u001f${service.name}\u001f${kind.name}\u001f$aliasKeyHash'))}';
  }
  return 'semantic-chat-claim2:${sha256.convert(utf8.encode('${scope.storageKey}\u001f$generation\u001f${service.name}\u001f${kind.name}\u001f$aliasKeyHash\u001f$logicalEntityKeyHash'))}';
}

void _seedExactOwnershipProof(
  Store store, {
  required CloudSyncScope scope,
  required int generation,
  required CloudEntityKind kind,
  required String logicalEntityKeyHash,
  required String canonicalGuid,
}) {
  store.box<CloudSemanticSnapshotEntity>().put(
    CloudSemanticSnapshotEntity(
      snapshotKey:
          'ownership-proof:$generation:${kind.name}:$logicalEntityKeyHash:$canonicalGuid',
      scopeGenerationKey: _semanticScopeGenerationKey(scope, generation),
      scopeKey: _semanticScopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      entityKind: kind.name,
      logicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: kind,
        logicalEntityKeyHash: logicalEntityKeyHash,
        canonicalGuid: canonicalGuid,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: generation,
            canonicalGuid: canonicalGuid,
          ),
      updatedAtMs: testEpoch.millisecondsSinceEpoch,
    ),
  );
}

void _seedCheckpoint(
  Store store, {
  required CloudSyncScope scope,
  required int generation,
}) {
  final box = store.box<CloudSyncCheckpointEntity>();
  final key = _semanticScopeKey(scope);
  final query =
      box.query(CloudSyncCheckpointEntity_.checkpointKey.equals(key)).build()
        ..limit = 1;
  final existing = query.findFirst();
  query.close();
  if (existing != null) {
    existing
      ..generation = generation
      ..updatedAtMs = testEpoch.millisecondsSinceEpoch;
    box.put(existing);
    return;
  }
  box.put(
    CloudSyncCheckpointEntity(
      checkpointKey: key,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      persistenceLane: scope.persistenceLane.name,
      generation: generation,
      updatedAtMs: testEpoch.millisecondsSinceEpoch,
    ),
  );
}

String _semanticScopeKey(CloudSyncScope scope) =>
    'scope2:${sha256.convert(utf8.encode(scope.storageKey))}';

String _semanticScopeGenerationKey(CloudSyncScope scope, int generation) =>
    'semantic-generation4:${sha256.convert(utf8.encode('${_semanticScopeKey(scope)}\u001f$generation'))}';

String _protectedReference(String value) =>
    'obcs2.ref.${base64Url.encode(sha256.convert(utf8.encode(value)).bytes).replaceAll('=', '')}';

final class _Resolver implements CloudCanonicalIdentityResolver {
  final Map<String, String> _values = {};
  final Map<String, CloudCanonicalIdentityOwner> _owners = {};

  void put({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
    required String canonicalGuid,
  }) {
    _values[_key(scope, generation, kind, logicalEntityKeyHash)] =
        canonicalGuid;
    _owners.putIfAbsent(
      '${scope.storageKey}:$generation:$canonicalGuid',
      () => CloudCanonicalIdentityOwner(
        kind: kind,
        logicalEntityKeyHash: logicalEntityKeyHash,
      ),
    );
  }

  @override
  String? resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) => _values[_key(scope, generation, kind, logicalEntityKeyHash)];

  @override
  CloudCanonicalIdentityOwner? resolveCanonicalIdentityOwner({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) => _owners['${scope.storageKey}:$generation:$canonicalGuid'];

  String _key(
    CloudSyncScope scope,
    int generation,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) => '${scope.storageKey}:$generation:${kind.name}:$logicalEntityKeyHash';
}
