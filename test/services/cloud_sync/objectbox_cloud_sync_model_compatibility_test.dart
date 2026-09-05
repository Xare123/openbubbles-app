import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:objectbox/internal.dart' as obx;

void main() {
  test(
    'adding the local send journal preserves a database with last entity ID 32',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cloud-sync-model-upgrade-',
      );
      addTearDown(() async {
        if (directory.existsSync()) await directory.delete(recursive: true);
      });
      final current = getObjectBoxModel();
      final previousMap = current.model.toMap();
      (previousMap['entities'] as List).removeWhere(
        (entity) => entity['name'] == 'CloudSyncLocalSendIntentEntity',
      );
      // Exact counters from the qualified pre-journal model, not a fresh store
      // with the new model. All predecessor entity definitions stay unchanged.
      previousMap['lastEntityId'] = '32:3377435011161314855';
      previousMap['lastIndexId'] = '92:7759272949562488518';
      final previous = obx.ModelDefinition(
        obx.ModelInfo.fromMap(previousMap),
        Map.of(current.bindings)..remove(CloudSyncLocalSendIntentEntity),
      );
      final oldStore = Store(previous, directory: directory.path);
      late final int messageId;
      late final int chatId;
      late final int attachmentId;
      late final int checkpointId;
      try {
        final chat = Chat(guid: 'iMessage;-;synthetic@example.com');
        chatId = oldStore.box<Chat>().put(chat);
        final message = Message(
          guid: 'synthetic-migration-guid',
          text: 'synthetic migration sentinel',
          dateCreated: DateTime.utc(2026, 9, 4),
          isFromMe: true,
        )..chat.target = chat;
        messageId = oldStore.box<Message>().put(message);
        attachmentId = oldStore.box<Attachment>().put(
          Attachment(guid: 'synthetic-attachment-guid'),
        );
        checkpointId = oldStore.box<CloudSyncCheckpointEntity>().put(
          CloudSyncCheckpointEntity(
            checkpointKey: 'synthetic-checkpoint',
            accountFingerprint: 'A' * 43,
            container: 'com.apple.messages.cloud',
            database: 'private',
            zone: 'messageManateeZone',
            streamKind: 'messages',
            generation: 7,
            fetchedSequence: 43,
            appliedSequence: 41,
            mutationRevisionCounter: 12,
            updatedAtMs: 1000,
          ),
        );
      } finally {
        oldStore.close();
      }

      final upgraded = await openStore(directory: directory.path);
      try {
        expect(upgraded.box<Message>().count(), 1);
        expect(
          upgraded.box<Message>().get(messageId)?.text,
          'synthetic migration sentinel',
        );
        expect(upgraded.box<Message>().get(messageId)?.chat.targetId, chatId);
        expect(
          upgraded.box<Attachment>().get(attachmentId)?.guid,
          'synthetic-attachment-guid',
        );
        final checkpoint = upgraded.box<CloudSyncCheckpointEntity>().get(
          checkpointId,
        )!;
        expect(checkpoint.generation, 7);
        expect(checkpoint.fetchedSequence, 43);
        expect(checkpoint.appliedSequence, 41);
        expect(checkpoint.mutationRevisionCounter, 12);
        expect(upgraded.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      } finally {
        upgraded.close();
      }
      final reopened = await openStore(directory: directory.path);
      try {
        expect(
          reopened.box<Message>().get(messageId)?.text,
          'synthetic migration sentinel',
        );
        expect(
          reopened
              .box<CloudSyncCheckpointEntity>()
              .get(checkpointId)
              ?.generation,
          7,
        );
      } finally {
        reopened.close();
      }
    },
  );

  test('cloud inbox status codes preserve the durable 0 through 3 mapping', () {
    expect(CloudInboxStatus.pending.index, 0);
    expect(CloudInboxStatus.applied.index, 1);
    expect(CloudInboxStatus.quarantined.index, 2);
    expect(CloudInboxStatus.retainedUnprojected.index, 3);
  });

  test(
    'admission link upgrade preserves existing pending and ready intents',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cloud-sync-admission-upgrade-',
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
      (intentModel['properties'] as List).removeWhere(
        (property) => [
          'admittedOperationId',
          'admittedBindingSha256',
        ].contains(property['name']),
      );
      intentModel['lastPropertyId'] = '10:3816774319385985138';
      final previous = obx.ModelDefinition(
        obx.ModelInfo.fromMap(previousMap),
        current.bindings,
      );
      final oldStore = Store(previous, directory: directory.path);
      final ids = <int>[];
      try {
        for (final state in [0, 1]) {
          ids.add(
            oldStore.box<CloudSyncLocalSendIntentEntity>().put(
              CloudSyncLocalSendIntentEntity(
                intentKey: 'synthetic-intent-$state',
                accountFingerprint: 'A' * 43,
                writerEpoch: 3,
                localMessageId: state + 1,
                messageGuidHash: 'B' * 64,
                sourceSha256: 'C' * 64,
                state: state,
                createdAtMs: 1000,
                updatedAtMs: 2000,
              ),
            ),
          );
        }
      } finally {
        oldStore.close();
      }
      for (var reopen = 0; reopen < 2; reopen++) {
        final upgraded = await openStore(directory: directory.path);
        try {
          expect(upgraded.box<CloudSyncLocalSendIntentEntity>().count(), 2);
          for (var state = 0; state < 2; state++) {
            final intent = upgraded.box<CloudSyncLocalSendIntentEntity>().get(
              ids[state],
            )!;
            expect(intent.state, state);
            expect(intent.admittedOperationId, isNull);
            expect(intent.admittedBindingSha256, isNull);
            expect(intent.intentKey, 'synthetic-intent-$state');
            expect(intent.writerEpoch, 3);
            expect(intent.sourceSha256, 'C' * 64);
            expect(intent.localMessageId, state + 1);
          }
        } finally {
          upgraded.close();
        }
      }
    },
  );

  test(
    'Cloud Sync entities extend rather than renumber the canonical model',
    () {
      final model =
          jsonDecode(File('lib/objectbox-model.json').readAsStringSync())
              as Map<String, dynamic>;
      final entities = {
        for (final value in model['entities'] as List<dynamic>)
          (value as Map<String, dynamic>)['name'] as String:
              value['id'] as String,
      };

      expect(entities, containsPair('Attachment', '1:2065429213543838585'));
      expect(entities, containsPair('Chat', '3:9017250848141753702'));
      expect(entities, containsPair('FCMData', '6:5390756932993878582'));
      expect(entities, containsPair('Handle', '7:1716592500251888002'));
      expect(entities, containsPair('ThemeEntry', '10:7380334062783734091'));
      expect(entities, containsPair('Message', '13:4148278195232901830'));
      expect(entities, containsPair('ThemeObject', '15:7753273527865539946'));
      expect(entities, containsPair('ThemeStruct', '16:1815690088052698449'));
      expect(entities, containsPair('Contact', '17:2547083341603323785'));

      expect(
        entities,
        containsPair('CloudInboxChangeEntity', '18:6719772093493207335'),
      );
      expect(
        entities,
        containsPair('CloudProtectedPageLeaseEntity', '27:4280538170716883312'),
      );
      expect(
        entities,
        containsPair('CloudKitWriterAuthorityEntity', '28:889478301778181246'),
      );
      expect(
        entities,
        containsPair('CloudKitDeletionIntentEntity', '29:3887662870209685934'),
      );
      expect(
        entities,
        containsPair(
          'CloudKitDeletionQuarantineEntity',
          '30:156682190547124916',
        ),
      );
      expect(
        entities,
        containsPair(
          'CloudKitV2QuarantineRepairReceiptEntity',
          '31:5051649657745290821',
        ),
      );
      expect(
        entities,
        containsPair('CloudSemanticChatAliasEntity', '32:3377435011161314855'),
      );
      expect(
        entities,
        containsPair(
          'CloudSyncLocalSendIntentEntity',
          '33:7403419454425897175',
        ),
      );
      expect(model['lastEntityId'], '33:7403419454425897175');
      expect(model['modelVersion'], 5);
      expect(model['modelVersionParserMinimum'], 5);

      final outbox = (model['entities'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (entity) => entity['name'] == 'CloudOutboxOperationEntity',
          );
      final properties = {
        for (final value in outbox['properties'] as List<dynamic>)
          (value as Map<String, dynamic>)['name'] as String:
              value['id'] as String,
      };
      expect(properties['checkpointGeneration'], '23:3453625028306797643');
      expect(properties['appleRequestUuid'], '24:2838853240019164046');
      expect(properties['appleOperationUuid'], '25:593864995002474100');

      final checkpoint = (model['entities'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (entity) => entity['name'] == 'CloudSyncCheckpointEntity',
          );
      final checkpointProperties = {
        for (final value in checkpoint['properties'] as List<dynamic>)
          (value as Map<String, dynamic>)['name'] as String:
              value['id'] as String,
      };
      expect(checkpoint['lastPropertyId'], '23:8346271905819443021');
      expect(
        checkpointProperties['pendingFetchedTokenCiphertext'],
        '22:7163548097042261884',
      );
      expect(checkpointProperties['pendingBatchId'], '23:8346271905819443021');

      Map<String, Map<String, dynamic>> propertiesFor(String entityName) {
        final entity = (model['entities'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .singleWhere((value) => value['name'] == entityName);
        return {
          for (final value in entity['properties'] as List<dynamic>)
            (value as Map<String, dynamic>)['name'] as String: value,
        };
      }

      final inboxProperties = propertiesFor('CloudInboxChangeEntity');
      expect(inboxProperties['generation']?['id'], '21:8085608731784905006');
      expect(
        inboxProperties['generation']?['indexId'],
        '81:3830688548090503170',
      );

      final replayProperties = propertiesFor('CloudSemanticReplayEntity');
      expect(
        replayProperties['inboxSequence']?['id'],
        '21:2926325749401488941',
      );
      expect(
        replayProperties['inboxSequence']?['indexId'],
        '83:2290394163013382047',
      );

      final snapshotProperties = propertiesFor('CloudSemanticSnapshotEntity');
      expect(
        snapshotProperties['canonicalGuidLookupHash']?['id'],
        '26:6951661599762727523',
      );
      expect(
        snapshotProperties['canonicalGuidLookupHash']?['indexId'],
        '84:3233573957190533269',
      );

      final receiptProperties = propertiesFor(
        'CloudKitV2QuarantineRepairReceiptEntity',
      );
      expect(
        receiptProperties['inboxSequence']?['id'],
        '15:9098288398353927251',
      );
      expect(
        receiptProperties['inboxSequence']?['indexId'],
        '82:1274079036917826277',
      );
      expect(
        receiptProperties['evidenceDigestVersion']?['id'],
        '25:2636988580358074206',
      );
      expect(
        receiptProperties['evidenceDigestSha256']?['id'],
        '26:4954038203640662813',
      );

      final chatAliasProperties = propertiesFor('CloudSemanticChatAliasEntity');
      expect(chatAliasProperties['bindingKey']?['id'], '2:7332341716914930469');
      expect(
        chatAliasProperties['bindingKey']?['indexId'],
        '85:5536211795662003449',
      );
      expect(
        chatAliasProperties['aliasKeyHash']?['id'],
        '14:3699140591669288204',
      );
      expect(chatAliasProperties['chatId']?['id'], '18:1466186784207767557');
    },
  );
}
