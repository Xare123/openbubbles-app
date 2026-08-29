import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
      expect(model['lastEntityId'], '32:3377435011161314855');
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
