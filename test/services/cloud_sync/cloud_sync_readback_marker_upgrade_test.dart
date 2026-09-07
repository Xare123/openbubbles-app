import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx;

void main() {
  test(
    'pre-readback-marker rows survive additive upgrade without gaining proof',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'ob-readback-upgrade-',
      );
      Store? store;
      try {
        final current = getObjectBoxModel();
        final oldMap = current.model.toMap();
        final entity = (oldMap['entities'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere(
              (row) => row['name'] == 'CloudSyncLocalSendIntentEntity',
            );
        expect(entity['id'], '33:7403419454425897175');
        final properties = (entity['properties'] as List)
            .cast<Map<String, dynamic>>();
        final added = properties.singleWhere(
          (row) => row['name'] == 'confirmedReadbackBindingSha256',
        );
        expect(added['id'], '14:6652370228940045642');
        properties.remove(added);
        entity['properties'] = properties;
        entity['lastPropertyId'] = '13:3888648459471300555';
        // Use the real pre-field schema, not an empty store already upgraded to
        // the new schema. The null new field has no serialized value in these rows.
        store = Store(
          obx.ModelDefinition(obx.ModelInfo.fromMap(oldMap), current.bindings),
          directory: directory.path,
        );
        final ids = <int>[];
        for (var state = 0; state <= 3; state++) {
          ids.add(
            store.box<CloudSyncLocalSendIntentEntity>().put(
              CloudSyncLocalSendIntentEntity(
                intentKey: 'synthetic-intent-$state',
                accountFingerprint: 'synthetic-account',
                writerEpoch: 3,
                localMessageId: state + 100,
                messageGuidHash: 'synthetic-guid-$state',
                sourceSha256: 'a' * 64,
                state: state,
                admittedOperationId: state == 2 ? 'synthetic-operation' : null,
                admittedBindingSha256: state >= 2 ? 'b' * 64 : null,
                admittedChatBinding: state == 2
                    ? 'synthetic-chat-binding'
                    : null,
                createdAtMs: 1000,
                updatedAtMs: 2000,
              ),
            ),
          );
        }
        store.close();
        store = Store(getObjectBoxModel(), directory: directory.path);
        final box = store.box<CloudSyncLocalSendIntentEntity>();
        expect(box.count(), 4);
        for (var state = 0; state <= 3; state++) {
          final row = box.get(ids[state])!;
          expect(row.state, state);
          expect(row.intentKey, 'synthetic-intent-$state');
          expect(row.localMessageId, state + 100);
          expect(row.accountFingerprint, 'synthetic-account');
          expect(row.writerEpoch, 3);
          expect(row.createdAtMs, 1000);
          expect(row.updatedAtMs, 2000);
          expect(row.sourceSha256, 'a' * 64);
          expect(
            row.admittedOperationId,
            state == 2 ? 'synthetic-operation' : null,
          );
          expect(row.admittedBindingSha256, state >= 2 ? 'b' * 64 : null);
          expect(
            row.admittedChatBinding,
            state == 2 ? 'synthetic-chat-binding' : null,
          );
          expect(row.confirmedReadbackBindingSha256, isNull);
        }
        // Storage round-trip only. This does not simulate a verified Apple read.
        box.put(box.get(ids[2])!..confirmedReadbackBindingSha256 = 'b' * 64);
        store.close();
        store = Store(getObjectBoxModel(), directory: directory.path);
        expect(
          store
              .box<CloudSyncLocalSendIntentEntity>()
              .get(ids[2])!
              .confirmedReadbackBindingSha256,
          'b' * 64,
        );
      } finally {
        store?.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
