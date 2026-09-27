import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx;

void main() {
  test(
    'reader linkage upgrade preserves already-committed historical sources',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ob-history-reader-upgrade-',
      );
      final current = getObjectBoxModel();
      final beforeMap = current.model.toMap();
      final entity =
          (beforeMap['entities'] as List).singleWhere(
                (e) => e['name'] == 'CloudSyncHistoricalArchiveIntentEntity',
              )
              as Map;
      (entity['properties'] as List).removeWhere(
        (p) => p['name'] == 'readerObservationBinding',
      );
      entity['lastPropertyId'] = '7:2021597163113578838';
      final before = obx.ModelDefinition(
        obx.ModelInfo.fromMap(beforeMap),
        current.bindings,
      );
      Store? store;
      try {
        store = Store(before, directory: directory.path);
        final id = store.box<CloudSyncHistoricalArchiveIntentEntity>().put(
          CloudSyncHistoricalArchiveIntentEntity(
            intentKey: 'synthetic-existing-intent',
            scopeKey: 'synthetic-existing-scope',
            protectedSourceBinding: 'retained-opaque-binding',
            state: 1,
            createdAtMs: 1000,
            updatedAtMs: 2000,
          ),
        );
        store.close();
        for (var restart = 0; restart < 2; restart++) {
          store = await openStore(directory: directory.path);
          final row = store.box<CloudSyncHistoricalArchiveIntentEntity>().get(
            id,
          )!;
          expect(row.intentKey, 'synthetic-existing-intent');
          expect(row.scopeKey, 'synthetic-existing-scope');
          expect(row.protectedSourceBinding, 'retained-opaque-binding');
          expect(row.state, 1);
          expect(row.readerObservationBinding, isNull);
          expect(row.createdAtMs, 1000);
          expect(row.updatedAtMs, 2000);
          store.close();
        }
      } finally {
        if (store != null && !store.isClosed()) store.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      }
    },
  );

  test(
    'historical journal upgrade preserves messages and uncertain work',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ob-history-upgrade-',
      );
      final current = getObjectBoxModel();
      final beforeMap = current.model.toMap();
      (beforeMap['entities'] as List).removeWhere(
        (e) => e['name'] == 'CloudSyncHistoricalArchiveIntentEntity',
      );
      // The exact model counters of aab9, the candidate preceding this addition.
      beforeMap['lastEntityId'] = '36:4861163290100543941';
      beforeMap['lastIndexId'] = '104:3906661285702552393';
      final before = obx.ModelDefinition(
        obx.ModelInfo.fromMap(beforeMap),
        Map.of(current.bindings)
          ..remove(CloudSyncHistoricalArchiveIntentEntity),
      );
      Store? store;
      try {
        store = Store(before, directory: directory.path);
        final chat = Chat(guid: 'iMessage;-;peer@example.invalid');
        final chatId = store.box<Chat>().put(chat);
        final message = Message(
          guid: 'pre-history-message',
          text: 'synthetic preserved message',
          isFromMe: true,
        )..chat.target = chat;
        final messageId = store.box<Message>().put(message);
        final sendId = store.box<CloudSyncLocalSendIntentEntity>().put(
          CloudSyncLocalSendIntentEntity(
            intentKey: 'synthetic-uncertain-send',
            accountFingerprint: 'A' * 43,
            writerEpoch: 2,
            localMessageId: messageId,
            sourceSha256: 'b' * 64,
            messageGuidHash: 'c' * 64,
            state: 0,
            createdAtMs: 1000,
            updatedAtMs: 1000,
          ),
        );
        final outboxId = store.box<CloudOutboxOperationEntity>().put(
          CloudOutboxOperationEntity(
            operationId: 'op1:${'d' * 64}',
            scopeKey: 'synthetic-scope',
            accountFingerprint: 'A' * 43,
            zone: 'messageManateeZone',
            logicalEntityKeyHash: 'L' * 43,
            action: CloudOutboxAction.save.index,
            payloadVersion: 1,
            mutationRevision: 12,
            checkpointGeneration: 7,
            state: CloudOutboxStatus.unknownOutcome.index,
            attemptCount: 1,
            encryptedPayloadRef: 'obcs2.ref.${'P' * 43}',
            payloadSha256: 'e' * 64,
            protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
            createdAtMs: 1000,
            updatedAtMs: 2000,
          ),
        );
        store.close();
        for (var restart = 0; restart < 2; restart++) {
          store = await openStore(directory: directory.path);
          final restored = store.box<Message>().get(messageId)!;
          expect(restored.text, message.text);
          expect(restored.chat.targetId, chatId);
          expect(restored.chat.target!.guid, chat.guid);
          final send = store.box<CloudSyncLocalSendIntentEntity>().get(sendId)!;
          expect(send.state, 0);
          expect(send.writerEpoch, 2);
          expect(send.sourceSha256, 'b' * 64);
          expect(send.localMessageId, messageId);
          final operation = store.box<CloudOutboxOperationEntity>().get(
            outboxId,
          )!;
          expect(operation.state, CloudOutboxStatus.unknownOutcome.index);
          expect(operation.attemptCount, 1);
          expect(operation.mutationRevision, 12);
          expect(operation.checkpointGeneration, 7);
          expect(operation.encryptedPayloadRef, 'obcs2.ref.${'P' * 43}');
          expect(operation.payloadSha256, 'e' * 64);
          expect(operation.protectedLeaseReference, 'obcs2.lease.${'f' * 32}');
          expect(
            store.box<CloudSyncHistoricalArchiveIntentEntity>().count(),
            0,
          );
          store.close();
        }
      } finally {
        if (store != null && !store.isClosed()) store.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      }
    },
  );
}
