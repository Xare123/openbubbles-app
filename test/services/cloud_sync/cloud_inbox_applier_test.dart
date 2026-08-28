import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

const _testLeaseFence = CloudCoordinatorLeaseFence(
  ownerId: 'semantic-applier-test',
  generation: 1,
);

Future<CloudInboxApplyResult> _apply(
  TransactionalCloudInboxApplier applier,
  CloudInboxEntry entry,
) => applier.apply(entry, leaseFence: _testLeaseFence);

void main() {
  final epoch = DateTime.utc(2026, 8, 1);
  late CloudSyncScope scope;
  late _MemorySemanticStore store;
  late _Decoder decoder;
  late TransactionalCloudInboxApplier applier;

  CloudInboxEntry entry(int sequence, {bool tombstone = false}) {
    return CloudInboxEntry(
      scope: scope,
      sequence: sequence,
      change: testChange(sequence, tombstone: tombstone),
      status: CloudInboxStatus.pending,
      attemptCount: 0,
      createdAt: epoch,
      batchId: 'batch-a',
      generation: 3,
    );
  }

  CloudSemanticSnapshot message({
    String key = 'message-key',
    String? parentKey,
    String content = 'content-a',
    DateTime? createdAt,
    DateTime? deliveredAt,
    DateTime? readAt,
    DateTime? retractedAt,
    Map<String, CloudEditPart> edits = const {},
    String etag = 'etag-a',
  }) {
    return CloudSemanticSnapshot(
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: key,
      parentLogicalKeyHash: parentKey,
      immutableContentDigest: content,
      createdAt: createdAt,
      deliveredAt: deliveredAt,
      readAt: readAt,
      retractedAt: retractedAt,
      editParts: edits,
      etagHash: etag,
      encryptedRawRecordReference: 'protected:$etag',
    );
  }

  CloudSemanticEntityPayload payloadFor(CloudSemanticSnapshot snapshot) {
    return switch (snapshot.kind) {
      CloudEntityKind.message => CloudMessageEntityPayload(
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuid: 'message-guid',
        chatAliasKeyHash: 'chat-key',
        chatIdentifier: 'iMessage;-;chat',
        body: 'renderable body',
        senderHandle: 'sender@example.invalid',
      ),
      CloudEntityKind.chat => CloudChatEntityPayload(
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuid: 'chat-guid',
        chatIdentifier: 'iMessage;-;chat',
        displayName: 'Renderable chat',
        participantHandles: const ['participant@example.invalid'],
      ),
      CloudEntityKind.reaction => CloudReactionEntityPayload(
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuid: 'reaction-guid',
        parentLogicalKeyHash: snapshot.parentLogicalKeyHash!,
        parentCanonicalGuid: 'parent-message-guid',
        parentPart: 0,
        senderHandle: 'sender@example.invalid',
        reactionType: 'like',
      ),
      CloudEntityKind.attachment => CloudAttachmentEntityPayload(
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuid: 'attachment-guid',
        ownerLogicalKeyHash: snapshot.parentLogicalKeyHash!,
        ownerCanonicalGuid: 'owner-message-guid',
        ownerPart: 0,
        fileName: 'attachment.bin',
        mimeType: 'application/octet-stream',
        protectedLocalReference: 'protected:attachment',
      ),
      CloudEntityKind.sharedProfile => CloudProfileEntityPayload(
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        displayName: 'Renderable profile',
        handle: 'profile@example.invalid',
      ),
      CloudEntityKind.groupPhoto => CloudGroupPhotoEntityPayload(
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        ownerLogicalKeyHash: snapshot.parentLogicalKeyHash!,
        photoGuid: 'group-photo-guid',
        protectedLocalReference: 'protected:group-photo',
      ),
    };
  }

  void decodeUpsert(
    CloudInboxEntry inbox,
    CloudSemanticSnapshot snapshot, {
    CloudSemanticEntityPayload? payload,
  }) {
    decoder.values[inbox.change.changeId] = CloudDecodedMutation.upsert(
      scope: scope,
      generation: inbox.generation,
      changeId: inbox.change.changeId,
      snapshot: snapshot,
      payload: payload ?? payloadFor(snapshot),
    );
  }

  setUp(() {
    scope = testScope();
    store = _MemorySemanticStore(scope: scope, generation: 3);
    store.transaction.existingEntities.add((CloudEntityKind.chat, 'chat-key'));
    decoder = _Decoder();
    applier = TransactionalCloudInboxApplier(decoder: decoder, store: store);
  });

  test(
    'replayed change is idempotent inside the semantic transaction',
    () async {
      final inbox = entry(1);
      decodeUpsert(inbox, message());

      expect(
        (await _apply(applier, inbox)).disposition,
        CloudInboxApplyDisposition.applied,
      );
      expect(
        (await _apply(applier, inbox)).disposition,
        CloudInboxApplyDisposition.applied,
      );
      expect(store.transaction.entityApplyCount, 1);
      expect(store.transaction.appliedChanges, {inbox.change.changeId});
    },
  );

  test(
    'immutable content conflict is quarantined without replacing local',
    () async {
      final inbox = entry(1);
      store.transaction.put(message());
      decodeUpsert(inbox, message(content: 'content-b', etag: 'etag-b'));

      final result = await _apply(applier, inbox);

      expect(result.disposition, CloudInboxApplyDisposition.quarantined);
      expect(
        store.transaction.snapshot('message-key')!.immutableContentDigest,
        'content-a',
      );
      expect(
        store.transaction.quarantines[inbox.change.changeId],
        'immutable_content_mismatch',
      );
      expect(store.transaction.appliedChanges, isEmpty);
      expect(store.transaction.entityApplyCount, 0);
    },
  );

  test('edit histories converge by part revision', () async {
    final inbox = entry(1);
    store.transaction.put(
      message(
        edits: {
          'part-a': CloudEditPart(
            partKeyHash: 'part-a',
            revision: 1,
            contentDigest: 'edit-a1',
            modifiedAt: epoch,
          ),
        },
      ),
    );
    decodeUpsert(
      inbox,
      message(
        etag: 'etag-b',
        edits: {
          'part-a': CloudEditPart(
            partKeyHash: 'part-a',
            revision: 2,
            contentDigest: 'edit-a2',
            modifiedAt: epoch.add(const Duration(minutes: 2)),
          ),
          'part-b': CloudEditPart(
            partKeyHash: 'part-b',
            revision: 1,
            contentDigest: 'edit-b1',
            modifiedAt: epoch.add(const Duration(minutes: 1)),
          ),
        },
      ),
    );

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.applied,
    );
    final edits = store.transaction.snapshot('message-key')!.editParts;
    expect(edits['part-a']!.revision, 2);
    expect(edits['part-b']!.contentDigest, 'edit-b1');
  });

  test('equal edit revision with different content is quarantined', () async {
    final inbox = entry(1);
    store.transaction.put(
      message(
        edits: {
          'part-a': CloudEditPart(
            partKeyHash: 'part-a',
            revision: 2,
            contentDigest: 'edit-a',
            modifiedAt: epoch,
          ),
        },
      ),
    );
    decodeUpsert(
      inbox,
      message(
        etag: 'etag-b',
        edits: {
          'part-a': CloudEditPart(
            partKeyHash: 'part-a',
            revision: 2,
            contentDigest: 'edit-b',
            modifiedAt: epoch.add(const Duration(minutes: 1)),
          ),
        },
      ),
    );

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.quarantined,
    );
    expect(
      store.transaction.quarantines[inbox.change.changeId],
      'edit_revision_mismatch',
    );
  });

  test('retractions and delivered/read timestamps remain monotonic', () async {
    final inbox = entry(1);
    store.transaction.put(
      message(
        deliveredAt: epoch.add(const Duration(minutes: 5)),
        readAt: epoch.add(const Duration(minutes: 8)),
        retractedAt: epoch.add(const Duration(minutes: 7)),
      ),
    );
    decodeUpsert(
      inbox,
      message(
        deliveredAt: epoch.add(const Duration(minutes: 9)),
        readAt: epoch.add(const Duration(minutes: 3)),
        retractedAt: epoch.add(const Duration(minutes: 2)),
        etag: 'etag-b',
      ),
    );

    await _apply(applier, inbox);
    final merged = store.transaction.snapshot('message-key')!;
    expect(merged.deliveredAt, epoch.add(const Duration(minutes: 9)));
    expect(merged.readAt, epoch.add(const Duration(minutes: 8)));
    expect(merged.retractedAt, epoch.add(const Duration(minutes: 7)));
  });

  test('reaction is deferred until its parent exists', () async {
    final inbox = entry(1);
    decodeUpsert(
      inbox,
      CloudSemanticSnapshot(
        kind: CloudEntityKind.reaction,
        logicalEntityKeyHash: 'reaction-key',
        parentLogicalKeyHash: 'missing-parent',
        immutableContentDigest: 'reaction-digest',
      ),
    );

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.deferred,
    );
    expect(store.transaction.appliedChanges, isEmpty);
    expect(store.transaction.entityApplyCount, 0);
  });

  test('reply message requires a message parent, not a chat parent', () async {
    final inbox = entry(1);
    final snapshot = message(parentKey: 'reply-parent-key');
    decodeUpsert(
      inbox,
      snapshot,
      payload: CloudMessageEntityPayload(
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuid: 'reply-message-guid',
        chatAliasKeyHash: 'chat-key',
        chatIdentifier: 'iMessage;-;chat',
        body: 'reply body',
        senderHandle: 'sender@example.invalid',
        replyParentLogicalKeyHash: 'reply-parent-key',
        replyParentCanonicalGuid: 'parent-message-guid',
        replyParentPart: '0',
      ),
    );

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.deferred,
    );

    store.transaction.existingEntities.add((
      CloudEntityKind.message,
      'reply-parent-key',
    ));
    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.applied,
    );
  });

  test('equal group-version conflict retains local server base', () async {
    final inbox = entry(1);
    CloudSemanticSnapshot chat(String metadata, String etag) =>
        CloudSemanticSnapshot(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: 'chat-key',
          groupVersion: 4,
          groupMetadataDigest: metadata,
          etagHash: etag,
          encryptedRawRecordReference: 'protected:$etag',
        );
    store.transaction.put(chat('metadata-a', 'etag-a'));
    decodeUpsert(inbox, chat('metadata-b', 'etag-b'));

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.applied,
    );
    final retained = store.transaction.snapshot('chat-key')!;
    expect(retained.groupMetadataDigest, 'metadata-a');
    expect(retained.etagHash, 'etag-a');
    expect(
      store.transaction.conflicts[inbox.change.changeId],
      'equal_group_version_mismatch',
    );
  });

  test('higher group version replaces the local group base', () async {
    final inbox = entry(1);
    CloudSemanticSnapshot chat(int version, String metadata, String etag) =>
        CloudSemanticSnapshot(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: 'chat-key',
          groupVersion: version,
          groupMetadataDigest: metadata,
          etagHash: etag,
          encryptedRawRecordReference: 'protected:$etag',
        );
    store.transaction.put(chat(3, 'metadata-a', 'etag-a'));
    decodeUpsert(inbox, chat(4, 'metadata-b', 'etag-b'));

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.applied,
    );
    final merged = store.transaction.snapshot('chat-key')!;
    expect(merged.groupVersion, 4);
    expect(merged.groupMetadataDigest, 'metadata-b');
  });

  test(
    'confirmed tombstone applies while unconfirmed tombstone quarantines',
    () async {
      applier = TransactionalCloudInboxApplier(
        decoder: decoder,
        store: store,
        allowTombstones: true,
      );
      final confirmed = entry(1, tombstone: true);
      decoder.values[confirmed.change.changeId] =
          CloudDecodedMutation.tombstone(
            scope: scope,
            generation: 3,
            changeId: confirmed.change.changeId,
            tombstone: CloudSemanticTombstone(
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: 'message-key',
              deletedAt: epoch.add(const Duration(hours: 1)),
              serverConfirmed: true,
            ),
          );
      store.transaction.put(message(createdAt: epoch));

      expect(
        (await _apply(applier, confirmed)).disposition,
        CloudInboxApplyDisposition.applied,
      );
      expect(store.transaction.snapshot('message-key'), isNull);
      expect(store.transaction.entityApplyCount, 0);

      final unconfirmed = entry(2, tombstone: true);
      decoder.values[unconfirmed.change.changeId] =
          CloudDecodedMutation.tombstone(
            scope: scope,
            generation: 3,
            changeId: unconfirmed.change.changeId,
            tombstone: CloudSemanticTombstone(
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: 'other-key',
              deletedAt: epoch,
              serverConfirmed: false,
            ),
          );
      expect(
        (await _apply(applier, unconfirmed)).disposition,
        CloudInboxApplyDisposition.quarantined,
      );
    },
  );

  test('stale tombstone cannot erase newer local semantic state', () async {
    applier = TransactionalCloudInboxApplier(
      decoder: decoder,
      store: store,
      allowTombstones: true,
    );
    final inbox = entry(1, tombstone: true);
    store.transaction.put(
      message(createdAt: epoch, readAt: epoch.add(const Duration(hours: 2))),
    );
    decoder.values[inbox.change.changeId] = CloudDecodedMutation.tombstone(
      scope: scope,
      generation: 3,
      changeId: inbox.change.changeId,
      tombstone: CloudSemanticTombstone(
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: 'message-key',
        deletedAt: epoch.add(const Duration(hours: 1)),
        serverConfirmed: true,
      ),
    );

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.applied,
    );
    expect(store.transaction.snapshot('message-key'), isNotNull);
    expect(
      store.transaction.conflicts[inbox.change.changeId],
      'stale_tombstone',
    );
  });

  test(
    'disabled tombstones quarantine without deleting or opening a transaction',
    () async {
      final inbox = entry(1, tombstone: true);
      decoder.values[inbox.change.changeId] = CloudDecodedMutation.tombstone(
        scope: scope,
        generation: 3,
        changeId: inbox.change.changeId,
        tombstone: CloudSemanticTombstone(
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: 'message-key',
          deletedAt: epoch,
          serverConfirmed: true,
        ),
      );
      store.transaction.put(message(createdAt: epoch));

      expect(
        (await _apply(applier, inbox)).disposition,
        CloudInboxApplyDisposition.quarantined,
      );
      expect(store.transactionCount, 0);
      expect(store.transaction.snapshot('message-key'), isNotNull);
    },
  );

  test(
    'enabled tombstone without server time defers without deleting',
    () async {
      applier = TransactionalCloudInboxApplier(
        decoder: decoder,
        store: store,
        allowTombstones: true,
      );
      final inbox = entry(1, tombstone: true);
      decoder.values[inbox.change.changeId] = CloudDecodedMutation.tombstone(
        scope: scope,
        generation: 3,
        changeId: inbox.change.changeId,
        tombstone: CloudSemanticTombstone(
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: 'message-key',
          deletedAt: null,
          serverConfirmed: true,
        ),
      );
      store.transaction.put(message(createdAt: epoch));

      expect(
        (await _apply(applier, inbox)).disposition,
        CloudInboxApplyDisposition.deferred,
      );
      expect(store.transaction.snapshot('message-key'), isNotNull);
      expect(store.transaction.appliedChanges, isEmpty);
    },
  );

  test('decoded account or generation mismatch fails closed', () async {
    final accountMismatch = entry(1);
    decoder.values[accountMismatch.change.changeId] =
        CloudDecodedMutation.upsert(
          scope: testScope(account: testAccountFingerprintB),
          generation: 3,
          changeId: accountMismatch.change.changeId,
          snapshot: message(),
          payload: payloadFor(message()),
        );
    expect(
      (await _apply(applier, accountMismatch)).disposition,
      CloudInboxApplyDisposition.quarantined,
    );

    final generationMismatch = entry(2);
    decoder.values[generationMismatch.change.changeId] =
        CloudDecodedMutation.upsert(
          scope: scope,
          generation: 2,
          changeId: generationMismatch.change.changeId,
          snapshot: message(),
          payload: payloadFor(message()),
        );
    expect(
      (await _apply(applier, generationMismatch)).disposition,
      CloudInboxApplyDisposition.quarantined,
    );
    expect(store.transaction.entityApplyCount, 0);
  });

  test('active transaction scope and generation are revalidated', () async {
    final inbox = entry(1);
    decodeUpsert(inbox, message());
    store.transaction.activeGenerationOverride = 4;

    expect(
      (await _apply(applier, inbox)).disposition,
      CloudInboxApplyDisposition.quarantined,
    );
    expect(store.transaction.entityApplyCount, 0);
  });

  test('active native account is revalidated immediately before write',
      () async {
    final inbox = entry(1);
    decodeUpsert(inbox, message());
    applier = TransactionalCloudInboxApplier(
      decoder: decoder,
      store: store,
      activeScopeRevalidator: () async => false,
    );

    final result = await _apply(applier, inbox);

    expect(result.disposition, CloudInboxApplyDisposition.quarantined);
    expect(result.failureCategory, CloudFailureCategory.conflict);
    expect(store.transactionCount, 0);
  });

  test('native account revalidation failure remains retryable', () async {
    final inbox = entry(1);
    decodeUpsert(inbox, message());
    applier = TransactionalCloudInboxApplier(
      decoder: decoder,
      store: store,
      activeScopeRevalidator: () async => throw StateError('unavailable'),
    );

    final result = await _apply(applier, inbox);

    expect(result.disposition, CloudInboxApplyDisposition.retryable);
    expect(result.failureCategory, CloudFailureCategory.authorization);
    expect(store.transactionCount, 0);
  });

  test(
    'typed decoder failure quarantines without opening a transaction',
    () async {
      final inbox = entry(1);
      decoder.failures[inbox.change.changeId] =
          const CloudSemanticDecodeFailure(
            CloudFailureCategory.malformedRecord,
          );

      final result = await _apply(applier, inbox);

      expect(result.disposition, CloudInboxApplyDisposition.quarantined);
      expect(result.failureCategory, CloudFailureCategory.malformedRecord);
      expect(store.transactionCount, 0);
    },
  );

  test('typed retryable decoder failures remain retryable', () async {
    final inbox = entry(1);
    const retryableCategories = [
      CloudFailureCategory.network,
      CloudFailureCategory.throttled,
      CloudFailureCategory.server,
      CloudFailureCategory.authorization,
      CloudFailureCategory.pcsUnavailable,
      CloudFailureCategory.dependency,
      CloudFailureCategory.localStorage,
    ];

    for (final category in retryableCategories) {
      decoder.failures[inbox.change.changeId] = CloudSemanticDecodeFailure(
        category,
      );
      final result = await _apply(applier, inbox);
      expect(
        result.disposition,
        CloudInboxApplyDisposition.retryable,
        reason: category.name,
      );
      expect(result.failureCategory, category, reason: category.name);
    }
    expect(store.transactionCount, 0);
  });

  test(
    'typed unknown decoder failure is left for bounded engine policy',
    () async {
      final inbox = entry(1);
      decoder.failures[inbox.change.changeId] =
          const CloudSemanticDecodeFailure(CloudFailureCategory.unknown);

      final result = await _apply(applier, inbox);

      expect(result.disposition, CloudInboxApplyDisposition.quarantined);
      expect(result.failureCategory, CloudFailureCategory.unknown);
      expect(store.transactionCount, 0);
    },
  );

  test('untyped decoder failure is classified as bounded unknown', () async {
    final inbox = entry(1);

    final result = await _apply(applier, inbox);

    expect(result.disposition, CloudInboxApplyDisposition.quarantined);
    expect(result.failureCategory, CloudFailureCategory.unknown);
    expect(store.transactionCount, 0);
  });

  test(
    'only confirmed permanent decoder categories quarantine immediately',
    () async {
      final inbox = entry(1);
      const permanentCategories = [
        CloudFailureCategory.malformedRecord,
        CloudFailureCategory.conflict,
        CloudFailureCategory.cancelled,
        CloudFailureCategory.unsupportedService,
      ];

      for (final category in permanentCategories) {
        decoder.failures[inbox.change.changeId] = CloudSemanticDecodeFailure(
          category,
        );
        final result = await _apply(applier, inbox);
        expect(
          result.disposition,
          CloudInboxApplyDisposition.quarantined,
          reason: category.name,
        );
        expect(result.failureCategory, category, reason: category.name);
      }
      expect(store.transactionCount, 0);
    },
  );

  test(
    'create and update apply transient payload to the canonical entity',
    () async {
      final create = entry(1);
      final firstPayload = CloudMessageEntityPayload(
        logicalEntityKeyHash: 'message-key',
        canonicalGuid: 'message-guid',
        chatAliasKeyHash: 'chat-key',
        chatIdentifier: 'iMessage;-;chat',
        body: 'first plaintext body',
        senderHandle: 'first@example.invalid',
      );
      decodeUpsert(create, message(), payload: firstPayload);
      await _apply(applier, create);

      final update = entry(2);
      final secondPayload = CloudMessageEntityPayload(
        logicalEntityKeyHash: 'message-key',
        canonicalGuid: 'message-guid',
        chatAliasKeyHash: 'chat-key',
        chatIdentifier: 'iMessage;-;chat',
        body: 'edited plaintext body',
        senderHandle: 'first@example.invalid',
      );
      decodeUpsert(
        update,
        message(
          etag: 'etag-b',
          edits: {
            'part-a': CloudEditPart(
              partKeyHash: 'part-a',
              revision: 1,
              contentDigest: 'edit-digest',
              modifiedAt: epoch,
            ),
          },
        ),
        payload: secondPayload,
      );
      await _apply(applier, update);

      expect(store.transaction.appliedPayloads, [firstPayload, secondPayload]);
      expect(store.transaction.entityApplyCount, 2);
    },
  );

  test('payload and decoded envelope string output are always redacted', () {
    const secretBody = 'secret-message-body-8472';
    const secretHandle = 'private-handle@example.invalid';
    final payload = CloudMessageEntityPayload(
      logicalEntityKeyHash: 'message-key',
      canonicalGuid: 'private-message-guid',
      chatAliasKeyHash: 'chat-key',
      chatIdentifier: 'iMessage;-;private-chat',
      body: secretBody,
      senderHandle: secretHandle,
    );
    final decoded = CloudDecodedMutation.upsert(
      scope: scope,
      generation: 3,
      changeId: 'change-digest',
      snapshot: message(),
      payload: payload,
    );

    expect(payload.toString(), isNot(contains(secretBody)));
    expect(payload.toString(), isNot(contains(secretHandle)));
    expect(decoded.toString(), isNot(contains(secretBody)));
    expect(decoded.toString(), isNot(contains(secretHandle)));
    expect(decoded.toString(), contains('redacted'));
    expect(
      () => jsonEncode(payload),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
  });
}

class _Decoder implements CloudSemanticDecoder {
  final values = <String, CloudDecodedMutation>{};
  final failures = <String, CloudSemanticDecodeFailure>{};

  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async {
    final failure = failures[entry.change.changeId];
    if (failure != null) throw failure;
    return values[entry.change.changeId]!;
  }
}

class _MemorySemanticStore implements CloudSemanticStoreGateway {
  _MemorySemanticStore({required CloudSyncScope scope, required int generation})
    : transaction = _MemoryTransaction(scope, generation);

  final _MemoryTransaction transaction;
  int transactionCount = 0;

  @override
  Future<T> writeTransaction<T>({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
    required T Function(CloudSemanticStoreTransaction transaction) action,
  }) async {
    transactionCount++;
    return action(transaction);
  }
}

class _MemoryTransaction implements CloudSemanticStoreTransaction {
  _MemoryTransaction(this.activeScope, this._activeGeneration);

  @override
  final CloudSyncScope activeScope;
  final int _activeGeneration;
  int? activeGenerationOverride;
  final snapshots = <String, CloudSemanticSnapshot>{};
  final appliedChanges = <String>{};
  final quarantines = <String, String>{};
  final conflicts = <String, String>{};
  final appliedPayloads = <CloudSemanticEntityPayload>[];
  final boundLogicalEntityKeyHashes = <String>[];
  final existingEntities = <(CloudEntityKind, String)>{};
  int entityApplyCount = 0;

  @override
  int get activeGeneration => activeGenerationOverride ?? _activeGeneration;

  void put(CloudSemanticSnapshot snapshot) {
    snapshots[snapshot.logicalEntityKeyHash] = snapshot;
  }

  CloudSemanticSnapshot? snapshot(String key) => snapshots[key];

  @override
  void applyTombstone(CloudSemanticTombstone tombstone) {
    snapshots.remove(tombstone.logicalEntityKeyHash);
  }

  @override
  bool entityExists({
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    final snapshot = snapshots[logicalEntityKeyHash];
    return snapshot?.kind == kind ||
        existingEntities.contains((kind, logicalEntityKeyHash));
  }

  @override
  void bindRecordIdentity({
    required String logicalEntityKeyHash,
    String? encryptedRawRecordReference,
  }) {
    boundLogicalEntityKeyHashes.add(logicalEntityKeyHash);
  }

  @override
  bool hasAppliedChange(String changeId) => appliedChanges.contains(changeId);

  @override
  void markChangeApplied(String changeId) {
    appliedChanges.add(changeId);
  }

  @override
  void quarantineChange(String changeId, String safeCode) {
    quarantines[changeId] = safeCode;
  }

  @override
  CloudSemanticSnapshot? readSnapshot({
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    final snapshot = snapshots[logicalEntityKeyHash];
    return snapshot?.kind == kind ? snapshot : null;
  }

  @override
  void recordConflict(String changeId, String safeCode) {
    conflicts[changeId] = safeCode;
  }

  @override
  void applyEntity({
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    entityApplyCount++;
    appliedPayloads.add(payload);
    snapshots[snapshot.logicalEntityKeyHash] = snapshot;
  }
}
