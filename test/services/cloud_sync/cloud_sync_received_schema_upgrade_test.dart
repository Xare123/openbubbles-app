import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/objectbox.g.dart' as generated;
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx_internal;

// Synthetic store only. The pre-received model is the e65bee42e model:
// all 27 existing entity/property definitions are unchanged by this addition.
// This tests forward upgrade, not permission to downgrade a live database.
void main() {
  test(
    'nullable observation upgrade preserves the original received-source row',
    () async {
      final current = generated.getObjectBoxModel();
      final previousMap = current.model.toMap();
      final entity = (previousMap['entities'] as List).cast<Map>().singleWhere(
        (e) => e['name'] == 'CloudSyncReceivedArchiveIntentEntity',
      );
      (entity['properties'] as List).removeWhere(
        (p) => p['name'] == 'recordObservationBinding',
      );
      entity['lastPropertyId'] = '13:3733844521104586883';
      final previous = obx_internal.ModelDefinition(
        obx_internal.ModelInfo.fromMap(previousMap),
        current.bindings,
      );
      final root = await Directory(
        '${Directory.current.path}/build/test-temp',
      ).create(recursive: true);
      final directory = await root.createTemp('received-observation-upgrade-');
      Store? store;
      try {
        store = Store(previous, directory: directory.path);
        final id = store.box<CloudSyncReceivedArchiveIntentEntity>().put(
          CloudSyncReceivedArchiveIntentEntity(
            intentKey: 'synthetic-original',
            accountFingerprint: 'A' * 43,
            writerEpoch: 1,
            localMessageId: 1,
            localChatId: 1,
            messageGuidHash: 'b' * 64,
            sourceSha256: 'c' * 64,
            origin: 0,
            protectedSourceBinding: 'unchanged-original-binding',
            createdAtMs: 1,
            updatedAtMs: 1,
            state: 1,
          ),
        );
        store.close();
        store = Store(current, directory: directory.path);
        final restored = store.box<CloudSyncReceivedArchiveIntentEntity>().get(
          id,
        )!;
        expect(restored.protectedSourceBinding, 'unchanged-original-binding');
        expect(restored.state, 1);
        expect(restored.recordObservationBinding, isNull);
      } finally {
        if (store != null && !store.isClosed()) store.close();
        expect(directory.parent.absolute.path, root.absolute.path);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'received journal addition preserves prior messages and relationships',
    () async {
      final current = generated.getObjectBoxModel();
      final previousMap = current.model.toMap();
      final entities = previousMap['entities'] as List;
      expect(
        entities.where(
          (dynamic e) => e['name'] == 'CloudSyncReceivedArchiveIntentEntity',
        ),
        hasLength(1),
      );
      previousMap['entities'] = entities
          .where(
            (dynamic e) => e['name'] != 'CloudSyncReceivedArchiveIntentEntity',
          )
          .toList();
      expect(previousMap['entities'], hasLength(27));
      previousMap['lastEntityId'] = '35:5717746217656693252';
      previousMap['lastIndexId'] = '100:128294639452592612';
      final previousInfo = obx_internal.ModelInfo.fromMap(previousMap)
        ..generatorVersion = current.model.generatorVersion;
      final previousBindings = Map<Type, obx_internal.EntityDefinition>.from(
        current.bindings,
      )..remove(CloudSyncReceivedArchiveIntentEntity);
      final previous = obx_internal.ModelDefinition(
        previousInfo,
        previousBindings,
      );
      final root = await Directory(
        '${Directory.current.path}/build/test-temp',
      ).create(recursive: true);
      final directory = await root.createTemp('received-upgrade-');
      Store? store;
      try {
        store = Store(previous, directory: directory.path);
        final chat = Chat(guid: 'iMessage;-;peer@example.test');
        final chatId = store.box<Chat>().put(chat);
        final message = Message(
          guid: '11111111-2222-4333-8444-555555555555',
          text: 'synthetic pre-upgrade message',
          isFromMe: false,
          dateCreated: DateTime.utc(2026, 9, 16),
        )..chat.target = chat;
        final messageId = store.box<Message>().put(message);
        store.close();
        store = Store(current, directory: directory.path);
        final restored = store.box<Message>().get(messageId)!;
        expect(restored.text, message.text);
        expect(restored.guid, message.guid);
        expect(restored.isFromMe, isFalse);
        expect(restored.chat.targetId, chatId);
        expect(restored.chat.target!.guid, chat.guid);
        expect(store.box<Message>().count(), 1);
        expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
        store.close();
        store = Store(current, directory: directory.path);
        expect(store.box<Message>().get(messageId)!.text, message.text);
        expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
      } finally {
        if (store != null && !store.isClosed()) store.close();
        expect(directory.parent.absolute.path, root.absolute.path);
        await directory.delete(recursive: true);
      }
    },
  );
}
