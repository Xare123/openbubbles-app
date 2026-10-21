import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/objectbox.g.dart' as generated;
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx_internal;

// Synthetic store only. Prior model is immutable dd0778c736ae279d52acfd5e5e03ad4f504c80bd:
// 29 entities with lastEntityId 37 and lastIndexId 108. The addition adds only
// CloudSyncReceivedMutationIntentEntity (38/113). This tests forward upgrade,
// not permission to downgrade a live database.
void main() {
  test(
    'received mutation addition preserves messages, relations, and queue data',
    () async {
      final current = generated.getObjectBoxModel();
      expect(current.model.entities, hasLength(30));
      expect(current.model.toMap()['lastEntityId'], '38:5532331514038610908');
      expect(current.model.toMap()['lastIndexId'], '113:1133848427709071513');
      final previousMap = current.model.toMap();
      (previousMap['entities'] as List).removeWhere(
        (e) => e['name'] == 'CloudSyncReceivedMutationIntentEntity',
      );
      expect(previousMap['entities'], hasLength(29));
      previousMap['lastEntityId'] = '37:1644657105908350051';
      previousMap['lastIndexId'] = '108:4081572127477748998';
      final previousInfo = obx_internal.ModelInfo.fromMap(previousMap)
        ..generatorVersion = current.model.generatorVersion;
      final previousBindings = Map<Type, obx_internal.EntityDefinition>.from(
        current.bindings,
      )..remove(CloudSyncReceivedMutationIntentEntity);
      final previous = obx_internal.ModelDefinition(
        previousInfo,
        previousBindings,
      );
      final root = await Directory(
        '${Directory.current.path}/build/test-temp',
      ).create(recursive: true);
      final directory = await root.createTemp('received-mutation-upgrade-');
      Store? store;
      try {
        store = Store(previous, directory: directory.path);
        final chat = Chat(guid: 'iMessage;-;mutation-prior@example.test');
        final chatId = store.box<Chat>().put(chat);
        final message = Message(
          guid: '22222222-3333-4444-8555-666666666666',
          text: 'synthetic pre-mutation message',
          isFromMe: false,
          hasAttachments: true,
          dateCreated: DateTime.utc(2026, 9, 16),
        )..chat.target = chat;
        final messageId = store.box<Message>().put(message);
        final attachment = Attachment(guid: 'synthetic-mutation-attachment')
          ..message.target = message;
        final attachmentId = store.box<Attachment>().put(attachment);
        final receivedId = store
            .box<CloudSyncReceivedArchiveIntentEntity>()
            .put(
              CloudSyncReceivedArchiveIntentEntity(
                intentKey: 'synthetic-original-received',
                accountFingerprint: 'A' * 43,
                writerEpoch: 1,
                localMessageId: messageId,
                localChatId: chatId,
                messageGuidHash: 'b' * 64,
                sourceSha256: 'c' * 64,
                origin: 0,
                protectedSourceBinding: 'unchanged-original-binding',
                createdAtMs: 1,
                updatedAtMs: 1,
                state: 1,
              ),
            );
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
        store = Store(current, directory: directory.path);
        final restored = store.box<Message>().get(messageId)!;
        expect(restored.text, 'synthetic pre-mutation message');
        expect(restored.chat.targetId, chatId);
        expect(restored.chat.target!.guid, chat.guid);
        expect(
          store.box<Attachment>().get(attachmentId)?.guid,
          'synthetic-mutation-attachment',
        );
        expect(restored.dbAttachments.single.id, attachmentId);
        expect(
          store.box<Attachment>().get(attachmentId)!.message.targetId,
          messageId,
        );
        final received = store.box<CloudSyncReceivedArchiveIntentEntity>().get(
          receivedId,
        )!;
        expect(received.protectedSourceBinding, 'unchanged-original-binding');
        expect(received.state, 1);
        expect(received.localMessageId, messageId);
        expect(received.localChatId, chatId);
        final send = store.box<CloudSyncLocalSendIntentEntity>().get(sendId)!;
        expect(send.intentKey, 'synthetic-uncertain-send');
        expect(send.state, 0);
        final operation = store.box<CloudOutboxOperationEntity>().get(
          outboxId,
        )!;
        expect(operation.state, CloudOutboxStatus.unknownOutcome.index);
        expect(operation.attemptCount, 1);
        expect(operation.protectedLeaseReference, 'obcs2.lease.${'f' * 32}');
        expect(store.box<CloudSyncReceivedMutationIntentEntity>().count(), 0);
        store.close();
        store = Store(current, directory: directory.path);
        expect(
          store.box<Message>().get(messageId)!.text,
          'synthetic pre-mutation message',
        );
        expect(store.box<Message>().get(messageId)!.chat.targetId, chatId);
        expect(
          store
              .box<CloudSyncReceivedArchiveIntentEntity>()
              .get(receivedId)!
              .intentKey,
          'synthetic-original-received',
        );
        expect(
          store.box<CloudSyncLocalSendIntentEntity>().get(sendId)!.state,
          0,
        );
        expect(
          store.box<Message>().get(messageId)!.dbAttachments.single.id,
          attachmentId,
        );
        expect(
          store.box<CloudOutboxOperationEntity>().get(outboxId)!.state,
          CloudOutboxStatus.unknownOutcome.index,
        );
        expect(store.box<CloudSyncReceivedMutationIntentEntity>().count(), 0);
      } finally {
        if (store != null && !store.isClosed()) store.close();
        expect(directory.parent.absolute.path, root.absolute.path);
        await directory.delete(recursive: true);
      }
    },
  );
}
