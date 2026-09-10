import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx;

void main() {
  test('ids confirmation upgrade never auto-proves pre-existing intents', () async {
    final directory = await Directory.systemTemp.createTemp(
      'synthetic-ids-confirmation-upgrade-',
    );
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    final current = getObjectBoxModel();
    final previousMap = current.model.toMap();
    final intentModel = (previousMap['entities'] as List)
        .cast<Map>()
        .singleWhere(
          (entity) => entity['name'] == 'CloudSyncLocalSendIntentEntity',
        );
    expect(intentModel['id'], '33:7403419454425897175');
    // Additive upgrade: the new IDS proof column exists in the current
    // schema but was absent when the predecessor rows were written.
    expect(
      (intentModel['properties'] as List).any(
        (property) => (property as Map)['name'] == 'idsConfirmationVersion',
      ),
      isTrue,
    );
    (intentModel['properties'] as List).removeWhere(
      (property) => (property as Map)['name'] == 'idsConfirmationVersion',
    );
    intentModel['lastPropertyId'] = '14:6652370228940045642';

    // Actually create and populate the predecessor schema, then close it.
    // Absent idsConfirmationVersion values deserialize as 0.
    final predecessor = Store(
      obx.ModelDefinition(obx.ModelInfo.fromMap(previousMap), current.bindings),
      directory: directory.path,
    );
    final intentIds = <int>[];
    late int chatId, messageId, checkpointId, leaseId, outboxId;
    try {
      final chat = Chat(guid: 'synthetic-ids-chat');
      chatId = predecessor.box<Chat>().put(chat);
      messageId = predecessor.box<Message>().put(
        Message(
          guid: 'synthetic-ids-message',
          text: 'synthetic ids upgrade sentinel',
          isFromMe: true,
          dateCreated: DateTime.utc(2026, 9, 9),
        )..chat.target = chat,
      );
      checkpointId = predecessor.box<CloudSyncCheckpointEntity>().put(
        CloudSyncCheckpointEntity(
          checkpointKey: 'synthetic-ids-checkpoint',
          accountFingerprint: 'A' * 43,
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: 'chatManateeZone',
          streamKind: 'messages',
          generation: 7,
          fetchedSequence: 43,
          appliedSequence: 41,
          mutationRevisionCounter: 12,
          updatedAtMs: 1000,
        ),
      );
      leaseId = predecessor.box<CloudSyncLeaseEntity>().put(
        CloudSyncLeaseEntity(
          leaseKey: 'synthetic-ids-lease',
          scopeKey: 'synthetic-ids-scope',
          accountFingerprint: 'A' * 43,
          ownerIdHash: 'O' * 43,
          generation: 7,
          acquiredAtMs: 1000,
          expiresAtMs: 2000,
        ),
      );
      // Ambiguous outcome sentinel: unknown-outcome envelope state must
      // survive the additive upgrade untouched.
      outboxId = predecessor.box<CloudOutboxOperationEntity>().put(
        CloudOutboxOperationEntity(
          operationId: 'op1:${'b' * 64}',
          scopeKey: 'synthetic-ids-scope',
          accountFingerprint: 'A' * 43,
          zone: 'chatManateeZone',
          logicalEntityKeyHash: 'L' * 43,
          action: CloudOutboxAction.save.index,
          payloadVersion: 1,
          mutationRevision: 12,
          checkpointGeneration: 7,
          state: CloudOutboxStatus.unknownOutcome.index,
          attemptCount: 1,
          encryptedPayloadRef:
              'obcs2.ref.PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP',
          payloadSha256:
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          protectedLeaseReference:
              'obcs2.lease.dddddddddddddddddddddddddddddddd',
          serverRecordIdHash: 'S' * 43,
          appleRequestUuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
          appleOperationUuid: 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',
          createdAtMs: 1000,
          updatedAtMs: 2000,
        ),
      );
      for (var state = 0; state <= 3; state++) {
        intentIds.add(
          predecessor.box<CloudSyncLocalSendIntentEntity>().put(
            CloudSyncLocalSendIntentEntity(
              intentKey: 'synthetic-ids-intent-$state',
              accountFingerprint: 'A' * 43,
              writerEpoch: 3,
              localMessageId: state + 100,
              messageGuidHash: 'B' * 64,
              sourceSha256: 'C' * 64,
              state: state,
              admittedOperationId: state == 2 ? 'synthetic-ids-envelope' : null,
              admittedBindingSha256: state == 0 || state == 1
                  ? null
                  : state == 2
                  ? 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
                  : 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
              admittedChatBinding: state == 2
                  ? 'synthetic-ids-chat-binding'
                  : null,
              confirmedReadbackBindingSha256: state == 2
                  ? 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
                  : null,
              idsConfirmationVersion: 0,
              createdAtMs: 1000,
              updatedAtMs: 2000,
            ),
          ),
        );
      }
    } finally {
      predecessor.close();
    }

    int? freshV2Id;
    for (var restart = 0; restart < 2; restart++) {
      final upgraded = await openStore(directory: directory.path);
      try {
        // User data survives.
        expect(upgraded.box<Chat>().count(), 1);
        expect(upgraded.box<Message>().count(), 1);
        final message = upgraded.box<Message>().get(messageId)!;
        expect(message.text, 'synthetic ids upgrade sentinel');
        expect(message.chat.targetId, chatId);
        expect(message.chat.target!.guid, 'synthetic-ids-chat');
        final checkpoint = upgraded.box<CloudSyncCheckpointEntity>().get(
          checkpointId,
        )!;
        expect(checkpoint.generation, 7);
        expect(checkpoint.fetchedSequence, 43);
        expect(checkpoint.appliedSequence, 41);
        expect(checkpoint.mutationRevisionCounter, 12);

        // Lease sentinel survives.
        final lease = upgraded.box<CloudSyncLeaseEntity>().get(leaseId)!;
        expect(lease.leaseKey, 'synthetic-ids-lease');
        expect(lease.scopeKey, 'synthetic-ids-scope');
        expect(lease.ownerIdHash, 'O' * 43);
        expect(lease.acquiredAtMs, 1000);
        expect(lease.generation, 7);
        expect(lease.expiresAtMs, 2000);

        // Ambiguous unknown-outcome envelope survives untouched.
        final outbox = upgraded.box<CloudOutboxOperationEntity>().get(
          outboxId,
        )!;
        expect(outbox.state, CloudOutboxStatus.unknownOutcome.index);
        expect(outbox.operationId, 'op1:${'b' * 64}');
        expect(outbox.checkpointGeneration, 7);
        expect(
          outbox.encryptedPayloadRef,
          'obcs2.ref.PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP',
        );
        expect(
          outbox.payloadSha256,
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        );
        expect(
          outbox.protectedLeaseReference,
          'obcs2.lease.dddddddddddddddddddddddddddddddd',
        );
        expect(outbox.serverRecordIdHash, 'S' * 43);
        expect(outbox.attemptCount, 1);
        expect(outbox.mutationRevision, 12);
        expect(outbox.appleRequestUuid, 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA');
        expect(
          outbox.appleOperationUuid,
          'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',
        );
        expect(outbox.createdAtMs, 1000);
        expect(outbox.updatedAtMs, 2000);

        // Pre-existing intents keep states and bindings, and absent IDS
        // proof deserializes as 0: never auto-upgraded.
        expect(
          upgraded.box<CloudSyncLocalSendIntentEntity>().count(),
          restart == 0 ? 4 : 5,
        );
        for (var state = 0; state <= 3; state++) {
          final intent = upgraded.box<CloudSyncLocalSendIntentEntity>().get(
            intentIds[state],
          )!;
          expect(intent.state, state);
          expect(intent.idsConfirmationVersion, 0);
          expect(intent.intentKey, 'synthetic-ids-intent-$state');
          expect(intent.localMessageId, state + 100);
          expect(intent.writerEpoch, 3);
          expect(intent.accountFingerprint, 'A' * 43);
          expect(intent.messageGuidHash, 'B' * 64);
          expect(intent.sourceSha256, 'C' * 64);
          expect(intent.createdAtMs, 1000);
          expect(intent.updatedAtMs, 2000);
          expect(
            intent.admittedOperationId,
            state == 2 ? 'synthetic-ids-envelope' : isNull,
          );
          expect(
            intent.admittedBindingSha256,
            state == 0 || state == 1
                ? isNull
                : state == 2
                ? 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
                : 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
          );
          expect(
            intent.admittedChatBinding,
            state == 2 ? 'synthetic-ids-chat-binding' : isNull,
          );
          expect(
            intent.confirmedReadbackBindingSha256,
            state == 2
                ? 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
                : isNull,
          );
        }

        if (restart == 0) {
          // New write path: the current positive IDS proof persists.
          freshV2Id = upgraded.box<CloudSyncLocalSendIntentEntity>().put(
            CloudSyncLocalSendIntentEntity(
              intentKey: 'synthetic-ids-intent-fresh-v2',
              accountFingerprint: 'A' * 43,
              writerEpoch: 3,
              localMessageId: 999,
              messageGuidHash: 'B' * 64,
              sourceSha256: 'C' * 64,
              state: 1,
              idsConfirmationVersion: 2,
              createdAtMs: 3000,
              updatedAtMs: 4000,
            ),
          );
        } else {
          final fresh = upgraded.box<CloudSyncLocalSendIntentEntity>().get(
            freshV2Id!,
          )!;
          expect(fresh.idsConfirmationVersion, 2);
          expect(fresh.state, 1);
          expect(fresh.intentKey, 'synthetic-ids-intent-fresh-v2');
          expect(fresh.accountFingerprint, 'A' * 43);
          expect(fresh.localMessageId, 999);
        }
      } finally {
        upgraded.close();
      }
    }
  });
}
