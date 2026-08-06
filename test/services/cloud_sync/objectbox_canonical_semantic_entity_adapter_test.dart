import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

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
          chatLogicalKeyHash: chatHash,
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
}) => ObjectBoxCanonicalSemanticEntityAdapter(
  store: store,
  activeScopeProvider: activeScopeProvider,
  identityResolver: resolver,
  semanticApplyEnabled: semanticApplyEnabled,
  allowExistingChatPresentationUpdates: allowExistingChatPresentationUpdates,
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
