import 'package:bluebubbles/database/io/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parentGuid = 'ABCDEF12-3456-7890-ABCD-EF1234567890';

  test('ordinary messages have no association', () {
    expect(
      parseCloudAssociation(
        associatedMessageType: null,
        associatedMessageGuid: null,
      ),
      isNull,
    );
  });

  test('known reactions retain their normalized parent and part', () {
    final association = parseCloudAssociation(
      associatedMessageType: 2001,
      associatedMessageGuid: 'p:3/$parentGuid',
    );

    expect(association!.type, 'like');
    expect(association.parent.localMessageGuid, parentGuid);
    expect(association.parent.part, 3);
  });

  test('sticker associations are accepted', () {
    final association = parseCloudAssociation(
      associatedMessageType: 2,
      associatedMessageGuid: parentGuid,
    );

    expect(association!.type, 'sticker');
    expect(association.parent.localMessageGuid, parentGuid);
    expect(association.parent.part, isNull);
  });

  test('unknown association types fail closed without a RangeError', () {
    expect(
      () => parseCloudAssociation(
        associatedMessageType: 2008,
        associatedMessageGuid: 'p:0/$parentGuid',
      ),
      throwsA(
        isA<CloudAssociationImportException>().having(
          (error) => error.failure,
          'failure',
          CloudAssociationImportFailure.unknownType,
        ),
      ),
    );
  });

  test('known associations require a valid parent', () {
    expect(
      () => parseCloudAssociation(
        associatedMessageType: 2000,
        associatedMessageGuid: null,
      ),
      throwsA(
        isA<CloudAssociationImportException>().having(
          (error) => error.failure,
          'failure',
          CloudAssociationImportFailure.missingParent,
        ),
      ),
    );

    expect(
      () => parseCloudAssociation(
        associatedMessageType: 2000,
        associatedMessageGuid: 'bpdi:0/$parentGuid',
      ),
      throwsA(
        isA<CloudAssociationImportException>().having(
          (error) => error.failure,
          'failure',
          CloudAssociationImportFailure.malformedParent,
        ),
      ),
    );
  });

  test('association failures never include the parent GUID', () {
    Object? caught;
    try {
      parseCloudAssociation(
        associatedMessageType: 2000,
        associatedMessageGuid: 'bpdi:0/$parentGuid',
      );
    } catch (error) {
      caught = error;
    }

    expect(caught, isA<CloudAssociationImportException>());
    expect(caught.toString(), isNot(contains(parentGuid)));
  });
}
