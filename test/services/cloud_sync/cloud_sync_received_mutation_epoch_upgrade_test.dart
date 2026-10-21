import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx;

void main() {
  test(
    'received stage epoch appends without inventing old admission proof',
    () async {
      final current = getObjectBoxModel();
      final committed = obx.ModelInfo.fromMap(
        jsonDecode(File('lib/objectbox-model.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      expect(current.model.toMap(), committed.toMap());
      final previousMap = current.model.toMap();
      final entity =
          (previousMap['entities'] as List).singleWhere(
                (e) => e['name'] == 'CloudSyncReceivedMutationIntentEntity',
              )
              as Map;
      final properties = entity['properties'] as List;
      final addition =
          properties.singleWhere((p) => p['name'] == 'admittedWriterEpoch')
              as Map;
      expect(addition['type'], 6);
      expect((addition['id'] as String).split(':').first, '22');
      properties.remove(addition);
      expect(properties, hasLength(21));
      expect(properties.last['id'], '21:8922497060611147397');
      entity['lastPropertyId'] = properties.last['id'];
      final previous = obx.ModelDefinition(
        obx.ModelInfo.fromMap(previousMap),
        current.bindings,
      );
      final directory = await Directory.systemTemp.createTemp(
        'ob-received-stage-epoch-upgrade-',
      );
      Store? store;
      try {
        store = Store(previous, directory: directory.path);
        final chat = Chat(guid: 'iMessage;-;synthetic@example.test');
        store.box<Chat>().put(chat);
        final message = Message(
          guid: '22222222-3333-4444-8555-666666666666',
          text: 'synthetic retained body',
          isFromMe: false,
        )..chat.target = chat;
        store.box<Message>().put(message);
        final original = CloudSyncReceivedMutationIntentEntity(
          intentKey: 'synthetic-retained-update',
          accountFingerprint: 'A' * 43,
          ownershipEpoch: 2,
          mutationGuidHash: 'a' * 64,
          targetGuidHash: 'b' * 64,
          targetPart: 0,
          origin: 0,
          kind: 0,
          sentTimestampMs: 1000,
          sourceSha256: 'c' * 64,
          protectedSourceBinding: 'unchanged encrypted test fixture',
          localMessageId: message.id!,
          localChatId: chat.id!,
          beforeSnapshotSha256: 'd' * 64,
          reflectedSnapshotSha256: 'e' * 64,
          state: 2,
          admittedOperationId: 'op1:${'f' * 64}',
          admittedBindingSha256: '1' * 64,
          createdAtMs: 1000,
          updatedAtMs: 1001,
        );
        store.box<CloudSyncReceivedMutationIntentEntity>().put(original);
        store.close();
        store = null;
        for (var restart = 0; restart < 2; restart++) {
          store = await openStore(directory: directory.path);
          final row = store.box<CloudSyncReceivedMutationIntentEntity>().get(
            original.id,
          )!;
          expect(row.intentKey, original.intentKey);
          expect(row.accountFingerprint, original.accountFingerprint);
          expect(row.ownershipEpoch, original.ownershipEpoch);
          expect(row.mutationGuidHash, original.mutationGuidHash);
          expect(row.targetGuidHash, original.targetGuidHash);
          expect(row.sourceSha256, original.sourceSha256);
          expect(row.protectedSourceBinding, original.protectedSourceBinding);
          expect(row.beforeSnapshotSha256, original.beforeSnapshotSha256);
          expect(row.reflectedSnapshotSha256, original.reflectedSnapshotSha256);
          expect(row.state, 2);
          expect(row.admittedOperationId, original.admittedOperationId);
          expect(row.admittedBindingSha256, original.admittedBindingSha256);
          // An old, unshipped adoption remains held at zero, not silently
          // granted the current writer's epoch. Only a new adoption sets it.
          expect(row.admittedWriterEpoch, restart == 0 ? 0 : 7);
          final restored = store.box<Message>().get(message.id!)!;
          expect(restored.text, message.text);
          expect(restored.chat.targetId, chat.id);
          if (restart == 0) {
            row.admittedWriterEpoch = 7;
            store.box<CloudSyncReceivedMutationIntentEntity>().put(row);
          }
          store.close();
          store = null;
        }
      } finally {
        store?.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
