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
      expect(model['lastEntityId'], '30:156682190547124916');
      expect(model['modelVersion'], 5);
      expect(model['modelVersionParserMinimum'], 5);
    },
  );
}
