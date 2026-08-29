import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 1, 12);
  final scope = _scope();
  const leaseFence = CloudCoordinatorLeaseFence(
    ownerId: 'semantic-test-owner',
    generation: 7,
  );
  late Directory directory;
  late Store objectBox;
  late _ObjectBoxTestCanonicalAdapter adapter;
  late ObjectBoxCloudSemanticStoreGateway gateway;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-semantic-gateway-',
    );
    objectBox = await openStore(directory: directory.path);
    adapter = _ObjectBoxTestCanonicalAdapter(objectBox)
      ..activeScope = scope
      ..activeGeneration = 7
      ..existingEntities.add((CloudEntityKind.chat, _digestValue('H')));
    gateway = ObjectBoxCloudSemanticStoreGateway(
      store: objectBox,
      canonicalAdapter: adapter,
      clock: () => now,
    );
  });

  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'atomically commits canonical, snapshot, map, replay, and inbox',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      final result = await gateway.writeTransaction<CloudInboxApplyResult>(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          _applyMessage(transaction);
          transaction.markChangeApplied(entry.change.changeId);
          return const CloudInboxApplyResult.applied(
            inboxStatusPersisted: true,
          );
        },
      );

      expect(result.inboxStatusPersisted, isTrue);
      expect(adapter.entityApplyCalls, 1);
      expect(objectBox.box<CloudSyncRunEntity>().count(), 1);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 1);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 1);

      final map = objectBox.box<CloudRecordMapEntity>().getAll().single;
      expect(map.logicalEntityKeyHash, _digestValue('L'));
      expect(map.serverRecordIdHash, entry.change.recordIdHash);
      expect(map.encryptedServerRecordId, _protectedReference('S'));
      expect(map.encryptedRawRecordRef, _protectedReference('W'));

      final replay = objectBox.box<CloudSemanticReplayEntity>().getAll().single;
      expect(replay.terminalOutcome, 'applied');
      expect(replay.terminalSafeCode, isNull);
      expect(replay.serverRecordIdHash, entry.change.recordIdHash);
      expect(replay.logicalEntityKeyHash, _digestValue('L'));
      expect(replay.payloadSha256, entry.change.payloadSha256);
      expect(replay.inboxSequence, entry.sequence);
      expect(replay.changeType, entry.change.type.name);

      final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single;
      expect(inbox.status, CloudInboxStatus.applied.index);
      expect(inbox.completedAtMs, now.millisecondsSinceEpoch);
      final checkpoint = objectBox
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .single;
      expect(checkpoint.appliedSequence, 1);
    },
  );

  test(
    'real adapter atomically resolves an attachment parent across zones',
    () async {
      final fixture = _prepareCrossZoneAttachmentFixture(objectBox, now);

      final result = await fixture.gateway
          .writeTransaction<CloudInboxApplyResult>(
            entry: fixture.entry,
            leaseFence: fixture.leaseFence,
            action: (transaction) {
              transaction.applyEntity(
                payload: fixture.payload,
                snapshot: fixture.snapshot,
              );
              transaction.markChangeApplied(fixture.entry.change.changeId);
              return const CloudInboxApplyResult.applied(
                inboxStatusPersisted: true,
              );
            },
          );

      expect(result.inboxStatusPersisted, isTrue);
      final attachment = objectBox.box<Attachment>().getAll().single;
      expect(attachment.message.targetId, fixture.ownerMessageId);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 2);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 1);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 1);
      expect(
        objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
        CloudInboxStatus.applied.index,
      );
    },
  );

  test(
    'real adapter rolls back when a dependency generation advances',
    () async {
      final fixture = _prepareCrossZoneAttachmentFixture(objectBox, now);
      final checkpoint =
          objectBox.box<CloudSyncCheckpointEntity>().getAll().singleWhere(
            (row) => row.checkpointKey == _scopeKey(fixture.messageScope),
          )..generation = fixture.messageGeneration + 1;
      objectBox.box<CloudSyncCheckpointEntity>().put(checkpoint);

      await expectLater(
        fixture.gateway.writeTransaction<void>(
          entry: fixture.entry,
          leaseFence: fixture.leaseFence,
          action: (transaction) {
            transaction.applyEntity(
              payload: fixture.payload,
              snapshot: fixture.snapshot,
            );
            transaction.markChangeApplied(fixture.entry.change.changeId);
          },
        ),
        throwsA(_failureCode('canonical_dependency_scope_stale')),
      );

      expect(objectBox.box<Attachment>().count(), 0);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 0);
      expect(
        objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
        CloudInboxStatus.pending.index,
      );
    },
  );

  test('promotes a pending page token with its final applied row', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );
    final checkpoint =
        objectBox.box<CloudSyncCheckpointEntity>().getAll().single
          ..fetchedTokenCiphertext = 'protected-old-token'
          ..pendingFetchedTokenCiphertext = 'protected-next-token'
          ..pendingBatchId = entry.batchId;
    objectBox.box<CloudSyncCheckpointEntity>().put(checkpoint);

    await gateway.writeTransaction<void>(
      entry: entry,
      leaseFence: leaseFence,
      action: _applyAndMark(entry),
    );

    final promoted = objectBox.box<CloudSyncCheckpointEntity>().getAll().single;
    expect(promoted.fetchedTokenCiphertext, 'protected-next-token');
    expect(promoted.pendingFetchedTokenCiphertext, isNull);
    expect(promoted.pendingBatchId, isNull);
  });

  test(
    'does not promote a page token while a sibling row is quarantined',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final inboxBox = objectBox.box<CloudInboxChangeEntity>();
      final siblingChangeId = _digestValue('D');
      final sibling =
          _copyInbox(
              inboxBox.getAll().single,
              changeKey: _scopedDigest(scope, 'change', siblingChangeId),
            )
            ..changeIdHash = siblingChangeId
            ..fetchSequence = 2
            ..status = CloudInboxStatus.quarantined.index;
      inboxBox.put(sibling);
      final checkpoint =
          objectBox.box<CloudSyncCheckpointEntity>().getAll().single
            ..fetchedTokenCiphertext = 'protected-old-token'
            ..pendingFetchedTokenCiphertext = 'protected-next-token'
            ..pendingBatchId = entry.batchId
            ..fetchedSequence = 2;
      objectBox.box<CloudSyncCheckpointEntity>().put(checkpoint);

      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      );

      final retained = objectBox
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .single;
      expect(retained.fetchedTokenCiphertext, 'protected-old-token');
      expect(retained.pendingFetchedTokenCiphertext, 'protected-next-token');
      expect(retained.pendingBatchId, entry.batchId);
      expect(
        inboxBox.getAll().where((row) => row.fetchSequence == 2).single.status,
        CloudInboxStatus.quarantined.index,
      );
    },
  );

  test(
    'does not promote a current batch token across an earlier legacy barrier',
    () async {
      final entry = _entry(
        scope: scope,
        sequence: 2,
        batchId: 'current-batch',
        changeId: _digestValue('D'),
        recordIdHash: _digestValue('T'),
      );
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final inboxBox = objectBox.box<CloudInboxChangeEntity>();
      final current = inboxBox.getAll().single;
      final earlier =
          _copyInbox(
              current,
              changeKey: _scopedDigest(scope, 'change', _digestValue('B')),
            )
            ..changeIdHash = _digestValue('B')
            ..serverRecordIdHash = _digestValue('U')
            ..batchId = 'legacy-earlier-batch'
            ..fetchSequence = 1
            ..status = CloudInboxStatus.quarantined.index
            ..failureCategory = CloudFailureCategory.conflict.name
            ..completedAtMs = now.millisecondsSinceEpoch;
      inboxBox.put(earlier);
      final checkpointBox = objectBox.box<CloudSyncCheckpointEntity>();
      final checkpoint = checkpointBox.getAll().single
        ..fetchedTokenCiphertext = 'protected-old-token'
        ..pendingFetchedTokenCiphertext = 'protected-next-token'
        ..pendingBatchId = entry.batchId;
      checkpointBox.put(checkpoint);

      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      );

      final retained = checkpointBox.getAll().single;
      expect(retained.appliedSequence, 0);
      expect(retained.fetchedTokenCiphertext, 'protected-old-token');
      expect(retained.pendingFetchedTokenCiphertext, 'protected-next-token');
      expect(retained.pendingBatchId, entry.batchId);
      final rows = inboxBox.getAll()
        ..sort(
          (left, right) => left.fetchSequence.compareTo(right.fetchSequence),
        );
      expect(rows.first.status, CloudInboxStatus.quarantined.index);
      expect(rows.last.status, CloudInboxStatus.applied.index);
    },
  );

  test(
    'promotes a current batch token across a retained predecessor',
    () async {
      final entry = _entry(
        scope: scope,
        sequence: 2,
        batchId: 'current-batch',
        changeId: _digestValue('D'),
        recordIdHash: _digestValue('T'),
      );
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final inboxBox = objectBox.box<CloudInboxChangeEntity>();
      final current = inboxBox.getAll().single;
      final earlier =
          _copyInbox(
              current,
              changeKey: _scopedDigest(scope, 'change', _digestValue('B')),
            )
            ..changeIdHash = _digestValue('B')
            ..serverRecordIdHash = _digestValue('U')
            ..batchId = 'legacy-earlier-batch'
            ..fetchSequence = 1
            ..status = CloudInboxStatus.retainedUnprojected.index
            ..failureCategory = CloudFailureCategory.malformedRecord.name
            ..completedAtMs = now.millisecondsSinceEpoch;
      inboxBox.put(earlier);
      final checkpointBox = objectBox.box<CloudSyncCheckpointEntity>();
      final checkpoint = checkpointBox.getAll().single
        ..fetchedTokenCiphertext = 'protected-old-token'
        ..pendingFetchedTokenCiphertext = 'protected-next-token'
        ..pendingBatchId = entry.batchId;
      checkpointBox.put(checkpoint);

      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      );

      final promoted = checkpointBox.getAll().single;
      expect(promoted.appliedSequence, 2);
      expect(promoted.fetchedTokenCiphertext, 'protected-next-token');
      expect(promoted.pendingFetchedTokenCiphertext, isNull);
      expect(promoted.pendingBatchId, isNull);
      final rows = inboxBox.getAll()
        ..sort(
          (left, right) => left.fetchSequence.compareTo(right.fetchSequence),
        );
      expect(rows.first.status, CloudInboxStatus.retainedUnprojected.index);
      expect(rows.last.status, CloudInboxStatus.applied.index);
    },
  );

  test('rejects legacy transport grammar before opening a transaction', () async {
    final entry = _entry(
      scope: scope,
      changeId:
          'change2:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      recordIdHash:
          'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      etagHash:
          'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      encryptedServerRecordId: _protectedReference('S'),
      protectedSystemFieldsReference: null,
      encryptedPayloadReference: _protectedReference('W'),
    );
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );

    expect(
      () => gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      ),
      throwsA(_failureCode('semantic_digest_invalid')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test(
    'durable metadata never stores transient payload identity or content',
    () async {
      const secretBody = 'PRIVATE BODY 97213';
      const secretSender = 'private.sender@example.com';
      const secretMessageGuid = 'PRIVATE-MESSAGE-GUID-97213';
      const secretChatIdentifier = 'iMessage;-;PRIVATE-CHAT-97213';
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          transaction.applyEntity(
            payload: CloudMessageEntityPayload(
              logicalEntityKeyHash: _digestValue('L'),
              canonicalGuid: secretMessageGuid,
              chatAliasKeyHash: _digestValue('H'),
              chatIdentifier: secretChatIdentifier,
              body: secretBody,
              senderHandle: secretSender,
            ),
            snapshot: _snapshot(),
          );
          transaction.markChangeApplied(entry.change.changeId);
        },
      );

      final durable = <String>[
        ...objectBox.box<CloudSemanticSnapshotEntity>().getAll().expand(
          (row) => [
            row.snapshotKey,
            row.scopeGenerationKey,
            row.scopeKey,
            row.accountFingerprint,
            row.logicalEntityKeyHash,
            row.editPartsJson,
          ],
        ),
        ...objectBox.box<CloudSemanticReplayEntity>().getAll().expand(
          (row) => [
            row.replayKey,
            row.scopeGenerationKey,
            row.scopeKey,
            row.accountFingerprint,
            row.changeIdHash,
            row.serverRecordIdHash,
            row.logicalEntityKeyHash ?? '',
            row.payloadSha256 ?? '',
            row.terminalOutcome,
            row.terminalSafeCode ?? '',
          ],
        ),
        ...objectBox.box<CloudRecordMapEntity>().getAll().expand(
          (row) => [
            row.mapKey,
            row.logicalEntityKeyHash,
            row.serverRecordIdHash,
            row.encryptedServerRecordId,
            row.encryptedRawRecordRef ?? '',
          ],
        ),
      ].join('\n');
      expect(durable, isNot(contains(secretBody)));
      expect(durable, isNot(contains(secretSender)));
      expect(durable, isNot(contains(secretMessageGuid)));
      expect(durable, isNot(contains(secretChatIdentifier)));
    },
  );

  test('semantic metadata and protected record map survive reopen', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );
    await gateway.writeTransaction<void>(
      entry: entry,
      leaseFence: leaseFence,
      action: _applyAndMark(entry),
    );

    objectBox.close();
    objectBox = await openStore(directory: directory.path);
    adapter = _ObjectBoxTestCanonicalAdapter(objectBox)
      ..activeScope = scope
      ..activeGeneration = 7
      ..existingEntities.add((CloudEntityKind.chat, _digestValue('H')));
    gateway = ObjectBoxCloudSemanticStoreGateway(
      store: objectBox,
      canonicalAdapter: adapter,
      clock: () => now,
    );

    final replay = objectBox.box<CloudSemanticReplayEntity>().getAll().single;
    final map = objectBox.box<CloudRecordMapEntity>().getAll().single;
    expect(replay.terminalOutcome, 'applied');
    expect(replay.logicalEntityKeyHash, _digestValue('L'));
    expect(map.encryptedRawRecordRef, _protectedReference('W'));
  });

  test(
    'reopened generation-zero record maps remain rejected and unchanged',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final mapId = objectBox.box<CloudRecordMapEntity>().put(
        CloudRecordMapEntity(
          mapKey: _recordMapKey(scope, _digestValue('L')),
          scopeKey: _scopeKey(scope),
          accountFingerprint: scope.accountFingerprint,
          zone: scope.zone,
          logicalEntityKeyHash: _digestValue('L'),
          serverRecordIdHash: entry.change.recordIdHash,
          generation: 0,
          encryptedServerRecordId: entry.change.encryptedServerRecordId!,
          etagHash: entry.change.etagHash,
          encryptedRawRecordRef: entry.change.encryptedPayloadReference,
          updatedAtMs: now.millisecondsSinceEpoch,
        ),
      );

      objectBox.close();
      objectBox = await openStore(directory: directory.path);
      adapter = _ObjectBoxTestCanonicalAdapter(objectBox)
        ..activeScope = scope
        ..activeGeneration = 7
        ..existingEntities.add((CloudEntityKind.chat, _digestValue('H')));
      gateway = ObjectBoxCloudSemanticStoreGateway(
        store: objectBox,
        canonicalAdapter: adapter,
        clock: () => now,
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: _applyAndMark(entry),
        ),
        throwsA(_failureCode('semantic_record_map_scope_mismatch')),
      );

      final map = objectBox.box<CloudRecordMapEntity>().get(mapId)!;
      expect(map.id, mapId);
      expect(map.generation, 0);
      expect(adapter.entityApplyCalls, 0);
    },
  );

  test('lease takeover fails before canonical mutation', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: const CloudCoordinatorLeaseFence(
        ownerId: 'new-owner',
        generation: 5,
      ),
      now: now,
    );

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      ),
      throwsA(_failureCode('semantic_coordinator_lease_fence_lost')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test('independent lease and data generations commit safely', () async {
    final entry = _entry(scope: scope);
    const laterLeaseFence = CloudCoordinatorLeaseFence(
      ownerId: 'semantic-test-owner',
      generation: 8,
    );
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: laterLeaseFence,
      now: now,
    );

    await gateway.writeTransaction<void>(
      entry: entry,
      leaseFence: laterLeaseFence,
      action: _applyAndMark(entry),
    );

    expect(adapter.entityApplyCalls, 1);
    expect(
      objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
      CloudInboxStatus.applied.index,
    );
  });

  test(
    'checkpoint generation mismatch fails before canonical mutation',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
        checkpointGeneration: 8,
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: _applyAndMark(entry),
        ),
        throwsA(_failureCode('semantic_checkpoint_fence_lost')),
      );
      _expectNoSemanticMutation(objectBox, adapter);
    },
  );

  test('expired lease fails before canonical mutation', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
      expiresAt: now,
    );

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      ),
      throwsA(_failureCode('semantic_coordinator_lease_fence_lost')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test('account switch fails before canonical mutation', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );
    adapter.activeScope = _scope(account: _digestValue('B'));

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      ),
      throwsA(_failureCode('semantic_active_account_scope_changed')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test('generation reset fails before canonical mutation', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
      checkpointGeneration: 8,
    );

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      ),
      throwsA(_failureCode('semantic_checkpoint_fence_lost')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test('exact inbox digest and sequence are fenced', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );
    final row = objectBox.box<CloudInboxChangeEntity>().getAll().single
      ..payloadSha256 = _digestValue('X');
    objectBox.box<CloudInboxChangeEntity>().put(row);

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      ),
      throwsA(_failureCode('semantic_inbox_fence_lost')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test('captured transaction is inactive after callback returns', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );
    late CloudSemanticStoreTransaction escaped;

    await gateway.writeTransaction<void>(
      entry: entry,
      leaseFence: leaseFence,
      action: (transaction) {
        escaped = transaction;
      },
    );

    expect(
      () => escaped.entityExists(
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: _digestValue('L'),
      ),
      throwsA(_failureCode('semantic_transaction_inactive')),
    );
  });

  test('scheduled microtask cannot use a committed transaction', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );
    late Future<Object> deferredUse;

    await gateway.writeTransaction<void>(
      entry: entry,
      leaseFence: leaseFence,
      action: (transaction) {
        deferredUse = Future<Object>.microtask(() {
          try {
            transaction.entityExists(
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: _digestValue('L'),
            );
            return StateError('transaction unexpectedly remained active');
          } catch (error) {
            return error;
          }
        });
      },
    );

    final error = await deferredUse;
    expect(error, _failureCode('semantic_transaction_inactive'));
  });

  test(
    'discarded nested gateway call aborts and rolls back outer transaction',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            transaction.applyEntity(payload: _payload(), snapshot: _snapshot());
            gateway.writeTransaction<void>(
              entry: entry,
              leaseFence: leaseFence,
              action: (_) {},
            );
          },
        ),
        throwsA(_failureCode('semantic_nested_transaction_forbidden')),
      );
      _expectNoSemanticMutation(objectBox, adapter);
    },
  );

  test('missing terminal outcome rolls back canonical state', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          transaction.applyEntity(payload: _payload(), snapshot: _snapshot());
        },
      ),
      throwsA(_failureCode('semantic_terminal_outcome_missing')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test('record binding without a terminal outcome rolls back', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          transaction.bindRecordIdentity(
            logicalEntityKeyHash: _digestValue('L'),
            encryptedRawRecordReference: _protectedReference('W'),
          );
        },
      ),
      throwsA(_failureCode('semantic_terminal_outcome_missing')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test(
    'a legacy no-digest snapshot blocks the noChange map replay and checkpoint path',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final logicalKey = _digestValue('L');
      objectBox.box<CloudSemanticSnapshotEntity>().put(
        CloudSemanticSnapshotEntity(
          snapshotKey:
              'semantic-snapshot4:${_scopeGenerationKey(scope, entry.generation)}:message:$logicalKey',
          scopeGenerationKey: _scopeGenerationKey(scope, entry.generation),
          scopeKey: _scopeKey(scope),
          accountFingerprint: scope.accountFingerprint,
          container: scope.container,
          database: scope.database,
          zone: scope.zone,
          streamKind: scope.streamKind.name,
          schemaVersion: scope.schemaVersion,
          generation: entry.generation,
          entityKind: CloudEntityKind.message.name,
          logicalEntityKeyHash: logicalKey,
          immutableContentDigest: _digestValue('I'),
          updatedAtMs: now.millisecondsSinceEpoch,
        ),
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            // This is the exact noChange sequence. readSnapshot must reject
            // before the record-map/replay/inbox/checkpoint writes below.
            transaction.readSnapshot(
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: logicalKey,
            );
            transaction.bindRecordIdentity(
              logicalEntityKeyHash: logicalKey,
              encryptedRawRecordReference:
                  entry.change.encryptedPayloadReference,
            );
            transaction.markChangeApplied(entry.change.changeId);
          },
        ),
        throwsA(_failureCode('canonical_identity_owner_unproven')),
      );

      expect(adapter.entityApplyCalls, 0);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 0);
      expect(
        objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
        CloudInboxStatus.pending.index,
      );
      expect(
        objectBox
            .box<CloudSyncCheckpointEntity>()
            .getAll()
            .single
            .appliedSequence,
        0,
      );
    },
  );

  test(
    'quarantine after a canonical mutation is forbidden and rolls back',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            _applyMessage(transaction);
            transaction.quarantineChange(
              entry.change.changeId,
              'late_quarantine',
            );
          },
        ),
        throwsA(_failureCode('semantic_quarantine_after_mutation_forbidden')),
      );
      _expectNoSemanticMutation(objectBox, adapter);
    },
  );

  test(
    'a terminal transaction rejects any later mutation and rolls back',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            transaction.bindRecordIdentity(
              logicalEntityKeyHash: _digestValue('L'),
              encryptedRawRecordReference: _protectedReference('W'),
            );
            transaction.markChangeApplied(entry.change.changeId);
            _applyMessage(transaction);
          },
        ),
        throwsA(_failureCode('semantic_transaction_terminal')),
      );
      _expectNoSemanticMutation(objectBox, adapter);
    },
  );

  test('decoder raw-envelope or etag substitution rolls back', () async {
    for (final snapshot in [
      _snapshot().copyWith(
        encryptedRawRecordReference: _protectedReference('X'),
      ),
      _snapshot().copyWith(etagHash: _digestValue('X')),
    ]) {
      final entry = _entry(
        scope: _scope(
          account: snapshot.etagHash == _digestValue('X')
              ? _digestValue('F')
              : _digestValue('G'),
        ),
      );
      adapter.activeScope = entry.scope;
      adapter.existingEntities.add((CloudEntityKind.chat, _digestValue('H')));
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            transaction.applyEntity(payload: _payload(), snapshot: snapshot);
          },
        ),
        throwsA(_failureCode('semantic_snapshot_envelope_mismatch')),
      );
    }
    expect(objectBox.box<CloudSyncRunEntity>().count(), 0);
    expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(objectBox.box<CloudRecordMapEntity>().count(), 0);
    expect(objectBox.box<CloudSemanticReplayEntity>().count(), 0);
  });

  test(
    'ambiguous contiguous inbox sequence aborts checkpoint advancement',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final original = objectBox.box<CloudInboxChangeEntity>().getAll().single;
      objectBox.box<CloudInboxChangeEntity>().put(
        _copyInbox(original, changeKey: 'duplicate:${_sha256('sequence-1')}'),
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: _applyAndMark(entry),
        ),
        throwsA(_failureCode('semantic_inbox_sequence_ambiguous')),
      );
      expect(objectBox.box<CloudSyncRunEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 0);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 0);
      expect(
        objectBox
            .box<CloudInboxChangeEntity>()
            .getAll()
            .where((row) => row.changeKey == original.changeKey)
            .single
            .status,
        CloudInboxStatus.pending.index,
      );
    },
  );

  test('checkpoint cannot claim an applied sequence beyond fetched', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );
    final checkpoint =
        objectBox.box<CloudSyncCheckpointEntity>().getAll().single
          ..appliedSequence = 2;
    objectBox.box<CloudSyncCheckpointEntity>().put(checkpoint);

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      ),
      throwsA(_failureCode('semantic_checkpoint_fence_lost')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test(
    'record-map conflict fails closed and rolls back canonical state',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      objectBox.box<CloudRecordMapEntity>().put(
        CloudRecordMapEntity(
          mapKey: _recordMapKey(scope, _digestValue('L')),
          scopeKey: _scopeKey(scope),
          accountFingerprint: scope.accountFingerprint,
          zone: scope.zone,
          logicalEntityKeyHash: _digestValue('L'),
          serverRecordIdHash: _digestValue('Z'),
          generation: entry.generation,
          encryptedServerRecordId: _protectedReference('O'),
          updatedAtMs: now.millisecondsSinceEpoch,
        ),
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: _applyAndMark(entry),
        ),
        throwsA(_failureCode('semantic_record_mapping_conflict')),
      );
      expect(objectBox.box<CloudSyncRunEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 0);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 1);
    },
  );

  test(
    'generation-zero record maps fail closed without identity adoption',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final mapId = objectBox.box<CloudRecordMapEntity>().put(
        CloudRecordMapEntity(
          mapKey: _recordMapKey(scope, _digestValue('L')),
          scopeKey: _scopeKey(scope),
          accountFingerprint: scope.accountFingerprint,
          zone: scope.zone,
          logicalEntityKeyHash: _digestValue('L'),
          serverRecordIdHash: entry.change.recordIdHash,
          generation: 0,
          encryptedServerRecordId: entry.change.encryptedServerRecordId!,
          etagHash: entry.change.etagHash,
          encryptedRawRecordRef: _protectedReference('X'),
          updatedAtMs: now.millisecondsSinceEpoch,
        ),
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: _applyAndMark(entry),
        ),
        throwsA(_failureCode('semantic_record_map_scope_mismatch')),
      );

      final map = objectBox.box<CloudRecordMapEntity>().get(mapId)!;
      expect(map.id, mapId);
      expect(map.generation, 0);
      expect(adapter.entityApplyCalls, 0);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 0);
    },
  );

  test(
    'required payload parents must exactly match snapshot parents',
    () async {
      final cases =
          <
            (
              CloudSyncScope,
              CloudSemanticEntityPayload,
              CloudSemanticSnapshot,
              String,
            )
          >[
            (
              _scope(account: _digestValue('B'), zone: 'messageManateeZone'),
              CloudMessageEntityPayload(
                logicalEntityKeyHash: _digestValue('L'),
                canonicalGuid: 'message-guid',
                chatAliasKeyHash: _digestValue('P'),
                chatIdentifier: 'iMessage;-;chat',
                body: 'message',
                senderHandle: 'sender',
              ),
              CloudSemanticSnapshot(
                kind: CloudEntityKind.message,
                logicalEntityKeyHash: _digestValue('L'),
                parentLogicalKeyHash: _digestValue('Q'),
              ),
              'semantic_parent_identity_invalid',
            ),
            (
              _scope(account: _digestValue('C'), zone: 'messageManateeZone'),
              CloudReactionEntityPayload(
                logicalEntityKeyHash: _digestValue('Y'),
                canonicalGuid: 'reaction-guid',
                parentLogicalKeyHash: _digestValue('P'),
                parentCanonicalGuid: 'parent-message-guid',
                parentPart: 0,
                senderHandle: 'sender',
                reactionType: 'like',
              ),
              CloudSemanticSnapshot(
                kind: CloudEntityKind.reaction,
                logicalEntityKeyHash: _digestValue('Y'),
              ),
              'semantic_parent_identity_mismatch',
            ),
            (
              _scope(account: _digestValue('D'), zone: 'attachmentManateeZone'),
              CloudAttachmentEntityPayload(
                logicalEntityKeyHash: _digestValue('T'),
                canonicalGuid: 'attachment-guid',
                ownerLogicalKeyHash: _digestValue('P'),
                ownerCanonicalGuid: 'owner-message-guid',
                ownerPart: 0,
                fileName: 'photo.jpg',
                mimeType: 'image/jpeg',
                protectedLocalReference: _protectedReference('A'),
              ),
              CloudSemanticSnapshot(
                kind: CloudEntityKind.attachment,
                logicalEntityKeyHash: _digestValue('T'),
                parentLogicalKeyHash: _digestValue('Q'),
              ),
              'semantic_parent_identity_mismatch',
            ),
            (
              _scope(account: _digestValue('E'), zone: 'chatManateeZone'),
              CloudGroupPhotoEntityPayload(
                logicalEntityKeyHash: _digestValue('G'),
                ownerLogicalKeyHash: _digestValue('P'),
                photoGuid: 'group-photo-guid',
                protectedLocalReference: _protectedReference('G'),
              ),
              CloudSemanticSnapshot(
                kind: CloudEntityKind.groupPhoto,
                logicalEntityKeyHash: _digestValue('G'),
                parentLogicalKeyHash: _digestValue('Q'),
              ),
              'semantic_parent_identity_mismatch',
            ),
          ];

      for (final (caseScope, payload, snapshot, safeCode) in cases) {
        final entry = _entry(scope: caseScope);
        adapter.activeScope = caseScope;
        _seedDurableFence(
          objectBox,
          entry: entry,
          leaseFence: leaseFence,
          now: now,
        );
        await expectLater(
          gateway.writeTransaction<void>(
            entry: entry,
            leaseFence: leaseFence,
            action: (transaction) {
              transaction.applyEntity(payload: payload, snapshot: snapshot);
            },
          ),
          throwsA(_failureCode(safeCode)),
        );
      }
      expect(objectBox.box<CloudSyncRunEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 0);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 0);
      expect(
        objectBox.box<CloudInboxChangeEntity>().getAll().every(
          (row) => row.status == CloudInboxStatus.pending.index,
        ),
        isTrue,
      );
    },
  );

  test(
    'accepts a reply message with the exact existing snapshot parent',
    () async {
      final entry = _entry(scope: scope);
      final parentKey = _digestValue('P');
      adapter.existingEntities.add((CloudEntityKind.message, parentKey));
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          transaction.applyEntity(
            payload: CloudMessageEntityPayload(
              logicalEntityKeyHash: _digestValue('L'),
              canonicalGuid: 'reply-message-guid',
              chatAliasKeyHash: _digestValue('H'),
              chatIdentifier: 'iMessage;-;chat',
              body: 'reply',
              senderHandle: 'sender',
              replyParentLogicalKeyHash: parentKey,
              replyParentCanonicalGuid: 'parent-message-guid',
              replyParentPart: '0',
            ),
            snapshot: CloudSemanticSnapshot(
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: _digestValue('L'),
              parentLogicalKeyHash: parentKey,
              etagHash: entry.change.etagHash,
              encryptedRawRecordReference:
                  entry.change.encryptedPayloadReference,
            ),
          );
          transaction.markChangeApplied(entry.change.changeId);
        },
      );

      expect(adapter.entityApplyCalls, 1);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(
        objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
        CloudInboxStatus.applied.index,
      );
    },
  );

  test('message and profile streams reject the wrong entity kinds', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );

    await expectLater(
      gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          transaction.applyEntity(
            payload: CloudProfileEntityPayload(
              logicalEntityKeyHash: _digestValue('F'),
              displayName: 'Profile',
              handle: 'profile@example.com',
            ),
            snapshot: CloudSemanticSnapshot(
              kind: CloudEntityKind.sharedProfile,
              logicalEntityKeyHash: _digestValue('F'),
            ),
          );
        },
      ),
      throwsA(_failureCode('semantic_stream_entity_mismatch')),
    );
    _expectNoSemanticMutation(objectBox, adapter);
  });

  test(
    'replay outcome is bound to payload, record, generation, and sequence',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      );

      final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single
        ..status = CloudInboxStatus.pending.index
        ..payloadSha256 = _digestValue('X');
      objectBox.box<CloudInboxChangeEntity>().put(inbox);
      final changedEntry = _entry(
        scope: scope,
        payloadSha256: _digestValue('X'),
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: changedEntry,
          leaseFence: leaseFence,
          action: (transaction) {
            transaction.hasAppliedChange(changedEntry.change.changeId);
          },
        ),
        throwsA(_failureCode('semantic_replay_binding_mismatch')),
      );
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 1);
    },
  );

  test(
    'replay rejects a corrupted protected record-map binding after reopen',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: _applyAndMark(entry),
      );

      final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single
        ..status = CloudInboxStatus.pending.index;
      objectBox.box<CloudInboxChangeEntity>().put(inbox);
      final map = objectBox.box<CloudRecordMapEntity>().getAll().single
        ..encryptedRawRecordRef = _protectedReference('X');
      objectBox.box<CloudRecordMapEntity>().put(map);

      objectBox.close();
      objectBox = await openStore(directory: directory.path);
      adapter = _ObjectBoxTestCanonicalAdapter(objectBox)
        ..activeScope = scope
        ..activeGeneration = 7
        ..existingEntities.add((CloudEntityKind.chat, _digestValue('H')));
      gateway = ObjectBoxCloudSemanticStoreGateway(
        store: objectBox,
        canonicalAdapter: adapter,
        clock: () => now,
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            transaction.hasAppliedChange(entry.change.changeId);
          },
        ),
        throwsA(_failureCode('semantic_replay_record_binding_mismatch')),
      );
    },
  );

  test('one explicit applied-with-conflict outcome is persisted', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );

    await gateway.writeTransaction<void>(
      entry: entry,
      leaseFence: leaseFence,
      action: (transaction) {
        transaction.bindRecordIdentity(
          logicalEntityKeyHash: _digestValue('L'),
          encryptedRawRecordReference: _protectedReference('W'),
        );
        transaction.recordConflict(
          entry.change.changeId,
          'equal_group_version_mismatch',
        );
        transaction.markChangeApplied(entry.change.changeId);
      },
    );

    final replay = objectBox.box<CloudSemanticReplayEntity>().getAll().single;
    expect(replay.terminalOutcome, 'appliedWithConflict');
    expect(replay.terminalSafeCode, 'equal_group_version_mismatch');
    expect(
      objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
      CloudInboxStatus.applied.index,
    );
  });

  test('one explicit quarantined outcome is persisted', () async {
    final entry = _entry(scope: scope);
    _seedDurableFence(
      objectBox,
      entry: entry,
      leaseFence: leaseFence,
      now: now,
    );

    await gateway.writeTransaction<void>(
      entry: entry,
      leaseFence: leaseFence,
      action: (transaction) {
        transaction.quarantineChange(
          entry.change.changeId,
          'immutable_content_mismatch',
        );
      },
    );

    final replay = objectBox.box<CloudSemanticReplayEntity>().getAll().single;
    expect(replay.terminalOutcome, 'quarantined');
    expect(replay.terminalSafeCode, 'immutable_content_mismatch');
    expect(
      objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
      CloudInboxStatus.quarantined.index,
    );
    expect(
      objectBox
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .single
          .appliedSequence,
      0,
    );
  });

  test(
    'raw email, GUID, body, uppercase hex, and delimiter scope are rejected',
    () async {
      expect(() => _scope(account: 'raw@example.com'), throwsArgumentError);
      final validEntry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: validEntry,
        leaseFence: leaseFence,
        now: now,
      );
      for (final invalid in [
        '550e8400-e29b-41d4-a716-446655440000',
        'secret body text',
        List.filled(64, 'A').join(),
      ]) {
        await expectLater(
          gateway.writeTransaction<void>(
            entry: validEntry,
            leaseFence: leaseFence,
            action: (transaction) {
              transaction.bindRecordIdentity(logicalEntityKeyHash: invalid);
            },
          ),
          throwsA(_failureCode('semantic_digest_invalid')),
        );
      }
      expect(
        () => CloudSyncScope(
          accountFingerprint: _digestValue('A'),
          container: 'container\u001fcollision',
          database: 'private',
          zone: 'zone',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'secret-bearing adapter exception is sanitized and fully rolled back',
    () async {
      const secret = 'TOP SECRET MESSAGE BODY';
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      adapter.throwAfterCanonicalWrite = Exception(secret);

      try {
        await gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: _applyAndMark(entry),
        );
        fail('expected sanitized failure');
      } catch (error) {
        expect(error, isA<CloudSyncFailure>());
        expect(error.toString(), isNot(contains(secret)));
        expect(
          (error as CloudSyncFailure).safeCode,
          'semantic_canonical_write_failed',
        );
      }
      _expectNoSemanticMutation(objectBox, adapter);
    },
  );

  test(
    'tombstones are permanently disabled before any durable mutation',
    () async {
      final entry = _entry(scope: scope, tombstone: true);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      await expectLater(
        gateway.writeTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            transaction.applyTombstone(
              CloudSemanticTombstone(
                kind: CloudEntityKind.message,
                logicalEntityKeyHash: _digestValue('L'),
                deletedAt: now,
                serverConfirmed: true,
              ),
            );
          },
        ),
        throwsA(_failureCode('semantic_tombstones_disabled')),
      );
      _expectNoSemanticMutation(objectBox, adapter);
    },
  );

  test(
    'a generic tombstone toggle cannot mutate the ObjectBox gateway',
    () async {
      final entry = _entry(scope: scope, tombstone: true);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final applier = TransactionalCloudInboxApplier(
        decoder: _FixedDecoder(
          CloudDecodedMutation.tombstone(
            scope: scope,
            generation: entry.generation,
            changeId: entry.change.changeId,
            tombstone: CloudSemanticTombstone(
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: _digestValue('L'),
              deletedAt: now,
              serverConfirmed: true,
            ),
          ),
        ),
        store: gateway,
        allowTombstones: true,
      );

      final result = await applier.apply(entry, leaseFence: leaseFence);

      expect(result.disposition, CloudInboxApplyDisposition.quarantined);
      expect(result.failureCategory, CloudFailureCategory.conflict);
      expect(adapter.tombstoneCalls, 0);
      _expectNoSemanticMutation(objectBox, adapter);
    },
  );

  test(
    'repairs an applied chat alias without changing durable sync control',
    () async {
      final chatScope = _scope(zone: 'chatManateeZone');
      final entry = _entry(scope: chatScope);
      adapter.activeScope = chatScope;
      objectBox.box<Chat>().put(
        Chat(guid: 'chat-guid', chatIdentifier: 'iMessage;-;chat', style: 45),
      );
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );

      final legacyPayload = _chatPayload(includeServiceIdentifierAlias: false);
      final snapshot = _chatSnapshot();
      await gateway.writeTransaction<void>(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          transaction.applyEntity(payload: legacyPayload, snapshot: snapshot);
          transaction.markChangeApplied(entry.change.changeId);
        },
      );
      expect(objectBox.box<CloudSemanticChatAliasEntity>().count(), 0);

      final identityRegistry = TransientCloudCanonicalIdentityRegistry();
      final activeScope = CloudCanonicalActiveScope(
        scope: chatScope,
        generation: entry.generation,
      );
      final currentAdapter = ObjectBoxCanonicalSemanticEntityAdapter(
        store: objectBox,
        activeScopeProvider: () => activeScope,
        identityResolver: identityRegistry,
        semanticApplyEnabled: true,
        allowChatUpserts: true,
      );
      final currentGateway = ObjectBoxCloudSemanticStoreGateway(
        store: objectBox,
        canonicalAdapter: currentAdapter,
        clock: () => now,
      );
      final repairedPayload = _chatPayload(
        includeServiceIdentifierAlias: true,
        participantHandles: const ['mailto:new-participant@example.com'],
      );
      final repairer = TransactionalCloudInboxApplier(
        decoder: _FixedDecoder(
          CloudDecodedMutation.upsert(
            scope: chatScope,
            generation: entry.generation,
            changeId: entry.change.changeId,
            snapshot: snapshot,
            payload: repairedPayload,
          ),
        ),
        store: currentGateway,
        identityRegistrar: identityRegistry,
        activeScopeRevalidator: () async => true,
      );

      final candidates = await currentGateway
          .readAppliedProjectionRepairCandidates(
            scope: chatScope,
            generation: entry.generation,
            leaseFence: leaseFence,
            limit: 8,
          );
      expect(candidates, hasLength(1));
      final controlBefore = _durableSyncControlFingerprint(objectBox);
      final handleCountBefore = objectBox.box<Handle>().count();
      final chatBefore = objectBox.box<Chat>().getAll().single;
      final participantIdsBefore = chatBefore.handles
          .map((handle) => handle.id)
          .toList(growable: false);
      final displayNameBefore = chatBefore.displayName;

      expect(
        await repairer.repairAppliedProjections(
          scope: chatScope,
          generation: entry.generation,
          leaseFence: leaseFence,
          limit: 8,
        ),
        1,
      );

      expect(_durableSyncControlFingerprint(objectBox), controlBefore);
      expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      expect(objectBox.box<Chat>().count(), 1);
      expect(objectBox.box<Handle>().count(), handleCountBefore);
      final chatAfter = objectBox.box<Chat>().getAll().single;
      expect(chatAfter.displayName, displayNameBefore);
      expect(
        chatAfter.handles.map((handle) => handle.id).toList(growable: false),
        participantIdsBefore,
      );
      final aliases = objectBox.box<CloudSemanticChatAliasEntity>().getAll();
      expect(aliases, hasLength(1));
      expect(
        aliases.single.aliasKind,
        CloudSemanticChatAliasKind.serviceIdentifier.name,
      );
      expect(
        await currentGateway.readAppliedProjectionRepairCandidates(
          scope: chatScope,
          generation: entry.generation,
          leaseFence: leaseFence,
          limit: 8,
        ),
        isEmpty,
      );

      final repairedAlias = aliases.single;
      final validCanonicalGuidHash = repairedAlias.canonicalGuidHash;
      repairedAlias.canonicalGuidHash = List.filled(64, '0').join();
      objectBox.box<CloudSemanticChatAliasEntity>().put(repairedAlias);
      await expectLater(
        currentGateway.readAppliedProjectionRepairCandidates(
          scope: chatScope,
          generation: entry.generation,
          leaseFence: leaseFence,
          limit: 8,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'projection_repair_alias_ownership_invalid',
          ),
        ),
      );
      repairedAlias.canonicalGuidHash = validCanonicalGuidHash;
      objectBox.box<CloudSemanticChatAliasEntity>().put(repairedAlias);

      final changedSnapshot = CloudSemanticSnapshot(
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        groupVersion: 1,
        etagHash: snapshot.etagHash,
        encryptedRawRecordReference: snapshot.encryptedRawRecordReference,
      );
      final changedMutation = CloudDecodedMutation.upsert(
        scope: chatScope,
        generation: entry.generation,
        changeId: entry.change.changeId,
        snapshot: changedSnapshot,
        payload: repairedPayload,
      );
      final identityLease = identityRegistry.bind(changedMutation);
      try {
        await expectLater(
          currentGateway.repairAppliedProjection(
            entry: candidates.single,
            leaseFence: leaseFence,
            payload: repairedPayload,
            snapshot: changedSnapshot,
          ),
          throwsA(
            isA<CloudSyncFailure>().having(
              (failure) => failure.safeCode,
              'safeCode',
              'projection_repair_snapshot_changed',
            ),
          ),
        );
      } finally {
        identityLease.release();
      }
      expect(_durableSyncControlFingerprint(objectBox), controlBefore);
      expect(objectBox.box<CloudSemanticChatAliasEntity>().count(), 1);
    },
  );

  test(
    'retained reprojection commits local projection without moving cursor',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final inboxBox = objectBox.box<CloudInboxChangeEntity>();
      final retained = inboxBox.getAll().single
        ..status = CloudInboxStatus.retainedUnprojected.index
        ..retryCount = 3
        ..failureCategory = CloudFailureCategory.dependency.name
        ..nextEligibleAtMs = 0
        ..completedAtMs = now.millisecondsSinceEpoch;
      inboxBox.put(retained);
      final checkpointBox = objectBox.box<CloudSyncCheckpointEntity>();
      final checkpoint = checkpointBox.getAll().single
        ..fetchedTokenCiphertext = 'protected-current-token'
        ..pendingFetchedTokenCiphertext = null
        ..pendingBatchId = null
        ..appliedSequence = entry.sequence;
      checkpointBox.put(checkpoint);

      final identityRegistry = TransientCloudCanonicalIdentityRegistry();
      final reprocessor = TransactionalCloudInboxApplier(
        decoder: _FixedDecoder(
          CloudDecodedMutation.upsert(
            scope: scope,
            generation: entry.generation,
            changeId: entry.change.changeId,
            snapshot: _snapshot(),
            payload: _payload(),
          ),
        ),
        store: gateway,
        identityRegistrar: identityRegistry,
        activeScopeRevalidator: () async => true,
      );

      final result = await reprocessor.reprojectRetainedUnprojected(
        scope: scope,
        generation: entry.generation,
        leaseFence: leaseFence,
        limit: 8,
      );

      expect(result.examined, 1);
      expect(result.reprojected, 1);
      expect(result.retained, 0);
      expect(adapter.entityApplyCalls, 1);
      expect(objectBox.box<CloudSyncRunEntity>().count(), 1);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 1);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 1);
      final projected = inboxBox.getAll().single;
      expect(projected.status, CloudInboxStatus.applied.index);
      expect(projected.failureCategory, isNull);
      expect(projected.retryCount, 3);
      expect(projected.batchId, entry.batchId);
      expect(projected.fetchSequence, entry.sequence);
      final unchangedCheckpoint = checkpointBox.getAll().single;
      expect(
        unchangedCheckpoint.fetchedTokenCiphertext,
        'protected-current-token',
      );
      expect(unchangedCheckpoint.pendingFetchedTokenCiphertext, isNull);
      expect(unchangedCheckpoint.pendingBatchId, isNull);
      expect(unchangedCheckpoint.fetchedSequence, entry.sequence);
      expect(unchangedCheckpoint.appliedSequence, entry.sequence);
      expect(
        await gateway.readRetainedProjectionCandidates(
          scope: scope,
          generation: entry.generation,
          leaseFence: leaseFence,
          limit: 8,
        ),
        isEmpty,
      );
    },
  );

  test(
    'retained reprojection rolls back canonical state and records fair retry',
    () async {
      final entry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: entry,
        leaseFence: leaseFence,
        now: now,
      );
      final inboxBox = objectBox.box<CloudInboxChangeEntity>();
      final retained = inboxBox.getAll().single
        ..status = CloudInboxStatus.retainedUnprojected.index
        ..retryCount = 4
        ..failureCategory = CloudFailureCategory.malformedRecord.name
        ..nextEligibleAtMs = 0
        ..completedAtMs = now.millisecondsSinceEpoch;
      inboxBox.put(retained);
      final checkpointBox = objectBox.box<CloudSyncCheckpointEntity>();
      final checkpoint = checkpointBox.getAll().single
        ..fetchedTokenCiphertext = 'protected-current-token'
        ..appliedSequence = entry.sequence;
      checkpointBox.put(checkpoint);
      final checkpointBefore = jsonEncode(
        checkpointBox
            .getAll()
            .map(
              (row) => [
                row.fetchedTokenCiphertext,
                row.pendingFetchedTokenCiphertext,
                row.pendingBatchId,
                row.generation,
                row.fetchedSequence,
                row.appliedSequence,
                row.mutationRevisionCounter,
              ],
            )
            .toList(),
      );
      adapter.throwAfterCanonicalWrite = StateError('forced rollback');
      final identityRegistry = TransientCloudCanonicalIdentityRegistry();
      final reprocessor = TransactionalCloudInboxApplier(
        decoder: _FixedDecoder(
          CloudDecodedMutation.upsert(
            scope: scope,
            generation: entry.generation,
            changeId: entry.change.changeId,
            snapshot: _snapshot(),
            payload: _payload(),
          ),
        ),
        store: gateway,
        identityRegistrar: identityRegistry,
        activeScopeRevalidator: () async => true,
      );

      final result = await reprocessor.reprojectRetainedUnprojected(
        scope: scope,
        generation: entry.generation,
        leaseFence: leaseFence,
        limit: 8,
      );

      expect(result.examined, 1);
      expect(result.reprojected, 0);
      expect(result.retained, 1);
      expect(result.hasRemaining, isTrue);
      expect(objectBox.box<CloudSyncRunEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticSnapshotEntity>().count(), 0);
      expect(objectBox.box<CloudRecordMapEntity>().count(), 0);
      expect(objectBox.box<CloudSemanticReplayEntity>().count(), 0);
      final preserved = inboxBox.getAll().single;
      expect(preserved.status, CloudInboxStatus.retainedUnprojected.index);
      expect(
        preserved.failureCategory,
        CloudFailureCategory.malformedRecord.name,
      );
      expect(preserved.retryCount, 5);
      expect(preserved.updatedAtMs, now.millisecondsSinceEpoch + 1);
      expect(preserved.completedAtMs, now.millisecondsSinceEpoch);
      expect(preserved.encryptedServerRecordId, _protectedReference('S'));
      expect(preserved.protectedSystemFieldsRef, _protectedReference('F'));
      expect(preserved.encryptedPayloadRef, _protectedReference('W'));
      expect(
        jsonEncode(
          checkpointBox
              .getAll()
              .map(
                (row) => [
                  row.fetchedTokenCiphertext,
                  row.pendingFetchedTokenCiphertext,
                  row.pendingBatchId,
                  row.generation,
                  row.fetchedSequence,
                  row.appliedSequence,
                  row.mutationRevisionCounter,
                ],
              )
              .toList(),
        ),
        checkpointBefore,
      );
    },
  );

  test(
    'retained candidate rotation survives restart and reaches later rows',
    () async {
      final firstEntry = _entry(scope: scope);
      _seedDurableFence(
        objectBox,
        entry: firstEntry,
        leaseFence: leaseFence,
        now: now,
      );
      final inboxBox = objectBox.box<CloudInboxChangeEntity>();
      final first = inboxBox.getAll().single
        ..status = CloudInboxStatus.retainedUnprojected.index
        ..retryCount = 4
        ..failureCategory = CloudFailureCategory.malformedRecord.name
        ..nextEligibleAtMs = 0
        ..completedAtMs = now.millisecondsSinceEpoch;
      inboxBox.put(first);
      final secondChangeId = _digestValue('D');
      final second =
          _copyInbox(
              first,
              changeKey: _scopedDigest(scope, 'change', secondChangeId),
            )
            ..changeIdHash = secondChangeId
            ..serverRecordIdHash = _digestValue('T')
            ..fetchSequence = 2;
      final thirdChangeId = _digestValue('G');
      final third =
          _copyInbox(
              first,
              changeKey: _scopedDigest(scope, 'change', thirdChangeId),
            )
            ..changeIdHash = thirdChangeId
            ..serverRecordIdHash = _digestValue('U')
            ..fetchSequence = 3;
      inboxBox.putMany([second, third]);
      final checkpointBox = objectBox.box<CloudSyncCheckpointEntity>();
      final checkpoint = checkpointBox.getAll().single
        ..fetchedSequence = 3
        ..appliedSequence = 3;
      checkpointBox.put(checkpoint);

      final firstWindow = await gateway.readRetainedProjectionCandidates(
        scope: scope,
        generation: firstEntry.generation,
        leaseFence: leaseFence,
        limit: 2,
      );
      expect(firstWindow.map((entry) => entry.sequence), [1, 2]);
      for (final entry in firstWindow) {
        await gateway.recordRetainedProjectionFailure(
          entry: entry,
          leaseFence: leaseFence,
        );
      }
      final rotatedRows = inboxBox.getAll()
        ..sort(
          (left, right) => left.fetchSequence.compareTo(right.fetchSequence),
        );
      expect(rotatedRows.map((row) => row.retryCount), [5, 5, 4]);
      expect(rotatedRows[0].updatedAtMs, now.millisecondsSinceEpoch + 1);
      expect(rotatedRows[1].updatedAtMs, now.millisecondsSinceEpoch + 1);
      expect(rotatedRows[2].updatedAtMs, now.millisecondsSinceEpoch);
      expect(
        rotatedRows.map((row) => row.failureCategory),
        everyElement(CloudFailureCategory.malformedRecord.name),
      );
      expect(
        rotatedRows.map((row) => row.completedAtMs),
        everyElement(now.millisecondsSinceEpoch),
      );

      objectBox.close();
      objectBox = await openStore(directory: directory.path);
      adapter = _ObjectBoxTestCanonicalAdapter(objectBox)
        ..activeScope = scope
        ..activeGeneration = firstEntry.generation
        ..existingEntities.add((CloudEntityKind.chat, _digestValue('H')));
      gateway = ObjectBoxCloudSemanticStoreGateway(
        store: objectBox,
        canonicalAdapter: adapter,
        clock: () => now,
      );

      final secondWindow = await gateway.readRetainedProjectionCandidates(
        scope: scope,
        generation: firstEntry.generation,
        leaseFence: leaseFence,
        limit: 2,
      );
      expect(secondWindow.map((entry) => entry.sequence), [3, 1]);
      await expectLater(
        gateway.recordRetainedProjectionFailure(
          entry: secondWindow.first,
          leaseFence: const CloudCoordinatorLeaseFence(
            ownerId: 'stale-retained-owner',
            generation: 7,
          ),
        ),
        throwsA(_failureCode('semantic_coordinator_lease_fence_lost')),
      );
    },
  );
}

CloudSyncScope _scope({String? account, String zone = 'messageManateeZone'}) {
  return CloudSyncScope(
    accountFingerprint: account ?? _digestValue('A'),
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: zone,
    streamKind: CloudSyncStreamKind.messages,
    schemaVersion: 2,
  );
}

CloudInboxEntry _entry({
  required CloudSyncScope scope,
  int sequence = 1,
  String batchId = 'batch-1',
  int generation = 7,
  bool tombstone = false,
  String? payloadSha256,
  String? changeId,
  String? recordIdHash,
  String? etagHash,
  String? encryptedServerRecordId,
  String? protectedSystemFieldsReference,
  String? encryptedPayloadReference,
}) {
  final change = CloudFetchedChange(
    changeId: changeId ?? _digestValue('C'),
    recordIdHash: recordIdHash ?? _digestValue('R'),
    etagHash: tombstone ? null : etagHash ?? _digestValue('E'),
    type: tombstone ? CloudChangeType.delete : CloudChangeType.save,
    encryptedServerRecordId:
        encryptedServerRecordId ?? _protectedReference('S'),
    protectedSystemFieldsReference:
        protectedSystemFieldsReference ?? _protectedReference('F'),
    encryptedPayloadReference:
        encryptedPayloadReference ?? _protectedReference('W'),
    payloadSha256: tombstone ? null : payloadSha256 ?? _sha256('payload'),
    isTombstone: tombstone,
  );
  return CloudInboxEntry(
    scope: scope,
    sequence: sequence,
    change: change,
    status: CloudInboxStatus.pending,
    attemptCount: 0,
    createdAt: DateTime.utc(2026, 8, 1, 11),
    batchId: batchId,
    generation: generation,
  );
}

CloudSemanticSnapshot _snapshot() {
  return CloudSemanticSnapshot(
    kind: CloudEntityKind.message,
    logicalEntityKeyHash: _digestValue('L'),
    immutableContentDigest: _digestValue('I'),
    createdAt: DateTime.utc(2026, 7, 31, 10),
    readAt: DateTime.utc(2026, 7, 31, 11),
    editParts: {
      _digestValue('K'): CloudEditPart(
        partKeyHash: _digestValue('K'),
        revision: 1,
        contentDigest: _digestValue('D'),
        modifiedAt: DateTime.utc(2026, 7, 31, 11, 30),
      ),
    },
    etagHash: _digestValue('E'),
    encryptedRawRecordReference: _protectedReference('W'),
  );
}

CloudMessageEntityPayload _payload() {
  return CloudMessageEntityPayload(
    logicalEntityKeyHash: _digestValue('L'),
    canonicalGuid: 'message-guid',
    chatAliasKeyHash: _digestValue('H'),
    chatIdentifier: 'iMessage;-;chat',
    body: 'secret message body',
    senderHandle: 'secret@example.com',
  );
}

CloudSemanticSnapshot _chatSnapshot() {
  return CloudSemanticSnapshot(
    kind: CloudEntityKind.chat,
    logicalEntityKeyHash: _digestValue('L'),
    etagHash: _digestValue('E'),
    encryptedRawRecordReference: _protectedReference('W'),
  );
}

CloudChatEntityPayload _chatPayload({
  required bool includeServiceIdentifierAlias,
  Iterable<String> participantHandles = const [],
}) {
  return CloudChatEntityPayload(
    logicalEntityKeyHash: _digestValue('L'),
    canonicalGuid: 'chat-guid',
    chatIdentifier: 'iMessage;-;chat',
    displayName: 'Cloud chat',
    participantHandles: participantHandles,
    aliases: includeServiceIdentifierAlias
        ? [
            CloudSemanticChatAlias(
              kind: CloudSemanticChatAliasKind.serviceIdentifier,
              keyHash: _digestValue('H'),
            ),
          ]
        : const [],
    service: CloudSemanticService.iMessage,
    style: CloudSemanticChatStyle.direct,
  );
}

void _applyMessage(CloudSemanticStoreTransaction transaction) {
  transaction.applyEntity(payload: _payload(), snapshot: _snapshot());
}

void Function(CloudSemanticStoreTransaction) _applyAndMark(
  CloudInboxEntry entry,
) {
  return (transaction) {
    _applyMessage(transaction);
    transaction.markChangeApplied(entry.change.changeId);
  };
}

void _seedDurableFence(
  Store store, {
  required CloudInboxEntry entry,
  required CloudCoordinatorLeaseFence leaseFence,
  required DateTime now,
  DateTime? expiresAt,
  int? checkpointGeneration,
}) {
  final scope = entry.scope;
  final scopeKey = _scopeKey(scope);
  store.runInTransaction(TxMode.write, () {
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: checkpointGeneration ?? entry.generation,
        lastBatchId: entry.batchId,
        fetchedSequence: entry.sequence,
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    store.box<CloudSyncLeaseEntity>().put(
      CloudSyncLeaseEntity(
        leaseKey: _scopedDigest(scope, 'coordinator-lease', 'v1'),
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        ownerIdHash: _sha256('coordinator-owner\u001f${leaseFence.ownerId}'),
        generation: leaseFence.generation,
        acquiredAtMs: now
            .subtract(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
        expiresAtMs: (expiresAt ?? now.add(const Duration(minutes: 1)))
            .millisecondsSinceEpoch,
      ),
    );
    final change = entry.change;
    store.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: _scopedDigest(scope, 'change', change.changeId),
        changeIdHash: change.changeId,
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        serverRecordIdHash: change.recordIdHash,
        etagHash: change.etagHash,
        changeType: change.type.name,
        encryptedServerRecordId: change.encryptedServerRecordId,
        protectedSystemFieldsRef: change.protectedSystemFieldsReference,
        encryptedPayloadRef: change.encryptedPayloadReference,
        payloadSha256: change.payloadSha256,
        batchId: entry.batchId,
        generation: entry.generation,
        fetchSequence: entry.sequence,
        status: CloudInboxStatus.pending.index,
        isTombstone: change.isTombstone,
        createdAtMs: entry.createdAt.millisecondsSinceEpoch,
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
  });
}

CloudInboxChangeEntity _copyInbox(
  CloudInboxChangeEntity source, {
  required String changeKey,
}) {
  return CloudInboxChangeEntity(
    changeKey: changeKey,
    changeIdHash: source.changeIdHash,
    scopeKey: source.scopeKey,
    accountFingerprint: source.accountFingerprint,
    zone: source.zone,
    serverRecordIdHash: source.serverRecordIdHash,
    etagHash: source.etagHash,
    changeType: source.changeType,
    encryptedServerRecordId: source.encryptedServerRecordId,
    protectedSystemFieldsRef: source.protectedSystemFieldsRef,
    encryptedPayloadRef: source.encryptedPayloadRef,
    payloadSha256: source.payloadSha256,
    batchId: source.batchId,
    generation: source.generation,
    fetchSequence: source.fetchSequence,
    status: source.status,
    isTombstone: source.isTombstone,
    failureCategory: source.failureCategory,
    retryCount: source.retryCount,
    nextEligibleAtMs: source.nextEligibleAtMs,
    serverModifiedAtMs: source.serverModifiedAtMs,
    createdAtMs: source.createdAtMs,
    updatedAtMs: source.updatedAtMs,
    completedAtMs: source.completedAtMs,
  );
}

void _expectNoSemanticMutation(Store store, _ObjectBoxTestCanonicalAdapter _) {
  expect(store.box<CloudSyncRunEntity>().count(), 0);
  expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
  expect(store.box<CloudRecordMapEntity>().count(), 0);
  expect(store.box<CloudSemanticReplayEntity>().count(), 0);
  expect(
    store.box<CloudInboxChangeEntity>().getAll().single.status,
    CloudInboxStatus.pending.index,
  );
}

Matcher _failureCode(String safeCode) {
  return isA<CloudSyncFailure>().having(
    (failure) => failure.safeCode,
    'safeCode',
    safeCode,
  );
}

String _scopeKey(CloudSyncScope scope) => 'scope2:${_sha256(scope.storageKey)}';

String _scopeGenerationKey(CloudSyncScope scope, int generation) =>
    'semantic-generation4:${_sha256('${_scopeKey(scope)}\u001f$generation')}';

String _recordMapKey(CloudSyncScope scope, String logicalEntityKeyHash) =>
    _scopedDigest(scope, 'record-map', logicalEntityKeyHash);

String _scopedDigest(CloudSyncScope scope, String purpose, String value) =>
    '$purpose:${_sha256('${scope.storageKey}\u001f$purpose\u001f$value')}';

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();

String _digestValue(String character) => List.filled(43, character).join();

String _protectedReference(String character) =>
    'obcs2.ref.${_digestValue(character)}';

String _durableSyncControlFingerprint(Store store) {
  final checkpoints = store.box<CloudSyncCheckpointEntity>().getAll()
    ..sort((left, right) => left.id.compareTo(right.id));
  final inbox = store.box<CloudInboxChangeEntity>().getAll()
    ..sort((left, right) => left.id.compareTo(right.id));
  final maps = store.box<CloudRecordMapEntity>().getAll()
    ..sort((left, right) => left.id.compareTo(right.id));
  final snapshots = store.box<CloudSemanticSnapshotEntity>().getAll()
    ..sort((left, right) => left.id.compareTo(right.id));
  final replay = store.box<CloudSemanticReplayEntity>().getAll()
    ..sort((left, right) => left.id.compareTo(right.id));
  return jsonEncode({
    'checkpoint': checkpoints
        .map(
          (row) => [
            row.id,
            row.checkpointKey,
            row.fetchedTokenCiphertext,
            row.pendingFetchedTokenCiphertext,
            row.pendingBatchId,
            row.generation,
            row.lastBatchId,
            row.fetchedSequence,
            row.appliedSequence,
            row.lastSuccessfulAtMs,
            row.lastAttemptAtMs,
            row.lastErrorCategory,
            row.backoffAttempt,
            row.nextEligibleAtMs,
            row.mutationRevisionCounter,
            row.updatedAtMs,
          ],
        )
        .toList(),
    'inbox': inbox
        .map(
          (row) => [
            row.id,
            row.changeKey,
            row.changeIdHash,
            row.serverRecordIdHash,
            row.etagHash,
            row.changeType,
            row.encryptedServerRecordId,
            row.protectedSystemFieldsRef,
            row.encryptedPayloadRef,
            row.payloadSha256,
            row.batchId,
            row.generation,
            row.fetchSequence,
            row.status,
            row.isTombstone,
            row.preflightCategory,
            row.failureCategory,
            row.preflightCode,
            row.retryCount,
            row.nextEligibleAtMs,
            row.completedAtMs,
            row.updatedAtMs,
          ],
        )
        .toList(),
    'recordMap': maps
        .map(
          (row) => [
            row.id,
            row.mapKey,
            row.logicalEntityKeyHash,
            row.serverRecordIdHash,
            row.generation,
            row.encryptedServerRecordId,
            row.etagHash,
            row.encryptedRawRecordRef,
            row.updatedAtMs,
          ],
        )
        .toList(),
    'snapshot': snapshots
        .map(
          (row) => [
            row.id,
            row.snapshotKey,
            row.generation,
            row.entityKind,
            row.logicalEntityKeyHash,
            row.canonicalGuidHash,
            row.canonicalGuidLookupHash,
            row.parentLogicalKeyHash,
            row.immutableContentDigest,
            row.createdAtMs,
            row.readAtMs,
            row.deliveredAtMs,
            row.editPartsJson,
            row.retractedAtMs,
            row.groupVersion,
            row.groupMetadataDigest,
            row.etagHash,
            row.updatedAtMs,
          ],
        )
        .toList(),
    'replay': replay
        .map(
          (row) => [
            row.id,
            row.replayKey,
            row.generation,
            row.changeIdHash,
            row.serverRecordIdHash,
            row.logicalEntityKeyHash,
            row.payloadSha256,
            row.protectedPayloadReferenceHash,
            row.inboxSequence,
            row.changeType,
            row.terminalOutcome,
            row.terminalSafeCode,
            row.updatedAtMs,
          ],
        )
        .toList(),
    'outboxCount': store.box<CloudOutboxOperationEntity>().count(),
  });
}

_CrossZoneAttachmentFixture _prepareCrossZoneAttachmentFixture(
  Store store,
  DateTime now,
) {
  final messageScope = _scope(zone: 'messageManateeZone');
  final attachmentScope = _scope(zone: 'attachmentManateeZone');
  const messageGeneration = 5;
  const attachmentGeneration = 7;
  final ownerLogicalKeyHash = _digestValue('P');
  final attachmentLogicalKeyHash = _digestValue('L');
  const ownerGuid = 'cross-zone-owner-guid';
  const attachmentGuid = '${ownerGuid}_1';
  final ownerMessageId = store.box<Message>().put(
    Message(guid: ownerGuid, dateCreated: now, isFromMe: false),
  );
  store.box<CloudSyncCheckpointEntity>().put(
    CloudSyncCheckpointEntity(
      checkpointKey: _scopeKey(messageScope),
      accountFingerprint: messageScope.accountFingerprint,
      container: messageScope.container,
      database: messageScope.database,
      zone: messageScope.zone,
      streamKind: messageScope.streamKind.name,
      schemaVersion: messageScope.schemaVersion,
      persistenceLane: messageScope.persistenceLane.name,
      generation: messageGeneration,
      updatedAtMs: now.millisecondsSinceEpoch,
    ),
  );
  store.box<CloudSemanticSnapshotEntity>().put(
    CloudSemanticSnapshotEntity(
      snapshotKey:
          'ownership-proof:$messageGeneration:message:$ownerLogicalKeyHash',
      scopeGenerationKey: _scopeGenerationKey(messageScope, messageGeneration),
      scopeKey: _scopeKey(messageScope),
      accountFingerprint: messageScope.accountFingerprint,
      container: messageScope.container,
      database: messageScope.database,
      zone: messageScope.zone,
      streamKind: messageScope.streamKind.name,
      schemaVersion: messageScope.schemaVersion,
      generation: messageGeneration,
      entityKind: CloudEntityKind.message.name,
      logicalEntityKeyHash: ownerLogicalKeyHash,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: messageScope,
        generation: messageGeneration,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: ownerLogicalKeyHash,
        canonicalGuid: ownerGuid,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: messageScope,
            generation: messageGeneration,
            canonicalGuid: ownerGuid,
          ),
      updatedAtMs: now.millisecondsSinceEpoch,
    ),
  );
  final resolver = _ExactCanonicalResolver()
    ..put(
      scope: attachmentScope,
      generation: attachmentGeneration,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: ownerLogicalKeyHash,
      canonicalGuid: ownerGuid,
    )
    ..put(
      scope: attachmentScope,
      generation: attachmentGeneration,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: attachmentLogicalKeyHash,
      canonicalGuid: attachmentGuid,
    );
  final canonicalAdapter = ObjectBoxCanonicalSemanticEntityAdapter(
    store: store,
    activeScopeProvider: () => CloudCanonicalActiveScope(
      scope: attachmentScope,
      generation: attachmentGeneration,
    ),
    identityResolver: resolver,
    messageDependencyScope: CloudCanonicalActiveScope(
      scope: messageScope,
      generation: messageGeneration,
    ),
    semanticApplyEnabled: true,
    allowAttachmentMetadataUpserts: true,
  );
  final gateway = ObjectBoxCloudSemanticStoreGateway(
    store: store,
    canonicalAdapter: canonicalAdapter,
    clock: () => now,
  );
  final entry = _entry(scope: attachmentScope);
  const leaseFence = CloudCoordinatorLeaseFence(
    ownerId: 'cross-zone-semantic-owner',
    generation: 7,
  );
  _seedDurableFence(store, entry: entry, leaseFence: leaseFence, now: now);
  final payload = CloudAttachmentEntityPayload(
    logicalEntityKeyHash: attachmentLogicalKeyHash,
    canonicalGuid: attachmentGuid,
    ownerLogicalKeyHash: ownerLogicalKeyHash,
    ownerCanonicalGuid: ownerGuid,
    ownerPart: 1,
    fileName: 'report.pdf',
    mimeType: 'application/pdf',
    protectedLocalReference: _protectedReference('A'),
  );
  final snapshot = CloudSemanticSnapshot(
    kind: CloudEntityKind.attachment,
    logicalEntityKeyHash: attachmentLogicalKeyHash,
    parentLogicalKeyHash: ownerLogicalKeyHash,
    immutableContentDigest: _digestValue('I'),
    etagHash: entry.change.etagHash,
    encryptedRawRecordReference: entry.change.encryptedPayloadReference,
  );
  return _CrossZoneAttachmentFixture(
    gateway: gateway,
    entry: entry,
    leaseFence: leaseFence,
    payload: payload,
    snapshot: snapshot,
    messageScope: messageScope,
    messageGeneration: messageGeneration,
    ownerMessageId: ownerMessageId,
  );
}

final class _CrossZoneAttachmentFixture {
  const _CrossZoneAttachmentFixture({
    required this.gateway,
    required this.entry,
    required this.leaseFence,
    required this.payload,
    required this.snapshot,
    required this.messageScope,
    required this.messageGeneration,
    required this.ownerMessageId,
  });

  final ObjectBoxCloudSemanticStoreGateway gateway;
  final CloudInboxEntry entry;
  final CloudCoordinatorLeaseFence leaseFence;
  final CloudAttachmentEntityPayload payload;
  final CloudSemanticSnapshot snapshot;
  final CloudSyncScope messageScope;
  final int messageGeneration;
  final int ownerMessageId;
}

final class _ExactCanonicalResolver implements CloudCanonicalIdentityResolver {
  final Map<String, String> _values = <String, String>{};
  final Map<String, CloudCanonicalIdentityOwner> _owners =
      <String, CloudCanonicalIdentityOwner>{};

  void put({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
    required String canonicalGuid,
  }) {
    _values[_key(scope, generation, kind, logicalEntityKeyHash)] =
        canonicalGuid;
    _owners['${scope.storageKey}:$generation:$canonicalGuid'] =
        CloudCanonicalIdentityOwner(
          kind: kind,
          logicalEntityKeyHash: logicalEntityKeyHash,
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

final class _FixedDecoder implements CloudSemanticDecoder {
  const _FixedDecoder(this._mutation);

  final CloudDecodedMutation _mutation;

  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async => _mutation;
}

final class _ObjectBoxTestCanonicalAdapter
    implements CloudCanonicalSemanticEntityAdapter {
  _ObjectBoxTestCanonicalAdapter(this.store)
    : _canonical = store.box<CloudSyncRunEntity>();

  @override
  final Store store;
  final Box<CloudSyncRunEntity> _canonical;
  CloudSyncScope? activeScope;
  int? activeGeneration;
  int entityApplyCalls = 0;
  int tombstoneCalls = 0;
  Object? throwAfterCanonicalWrite;
  final existingEntities = <(CloudEntityKind, String)>{};

  @override
  bool isActiveAccountScope({
    required CloudSyncScope scope,
    required int generation,
  }) => activeScope == scope && activeGeneration == generation;

  @override
  bool entityExists({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) =>
      existingEntities.contains((kind, logicalEntityKeyHash)) ||
      _find(scope, generation, kind, logicalEntityKeyHash) != null;

  @override
  void validateOwnershipEvidence({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    for (final snapshot in store.box<CloudSemanticSnapshotEntity>().getAll()) {
      if (snapshot.scopeKey == _scopeKey(scope) &&
          snapshot.accountFingerprint == scope.accountFingerprint &&
          snapshot.container == scope.container &&
          snapshot.database == scope.database &&
          snapshot.zone == scope.zone &&
          snapshot.streamKind == scope.streamKind.name &&
          snapshot.schemaVersion == scope.schemaVersion &&
          snapshot.generation == generation &&
          snapshot.canonicalGuidHash == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_identity_owner_unproven',
        );
      }
    }
  }

  @override
  CloudCanonicalSemanticMutationReceipt applyEntity({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    entityApplyCalls++;
    final existing = _find(
      scope,
      generation,
      snapshot.kind,
      snapshot.logicalEntityKeyHash,
    );
    _canonical.put(
      CloudSyncRunEntity(
        id: existing?.id ?? 0,
        runId: _key(
          scope,
          generation,
          snapshot.kind,
          snapshot.logicalEntityKeyHash,
        ),
        scopeKey: 'canonical-test-scope',
        accountFingerprint: scope.accountFingerprint,
        trigger: 'canonical-test',
        architecture: 'test',
        mode: 'semantic',
        startedAtMs: 1,
      ),
    );
    final failure = throwAfterCanonicalWrite;
    if (failure != null) throw failure;
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  @override
  CloudCanonicalSemanticMutationReceipt applyTombstone({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticTombstone tombstone,
  }) {
    tombstoneCalls++;
    final existing = _find(
      scope,
      generation,
      tombstone.kind,
      tombstone.logicalEntityKeyHash,
    );
    if (existing != null) _canonical.remove(existing.id);
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  CloudSyncRunEntity? _find(
    CloudSyncScope scope,
    int generation,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) {
    final query =
        _canonical
            .query(
              CloudSyncRunEntity_.runId.equals(
                _key(scope, generation, kind, logicalEntityKeyHash),
              ),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  String _key(
    CloudSyncScope scope,
    int generation,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) =>
      'canonical-test:${scope.accountFingerprint}:$generation:'
      '${kind.name}:$logicalEntityKeyHash';
}
