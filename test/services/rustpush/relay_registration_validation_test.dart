import 'package:bluebubbles/services/rustpush/relay_registration_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('registration code recognition', () {
    test('waits for a complete relay code', () {
      expect(isCompleteRelayCode('ABCD-EFGH-IJKL-MNOP'), isTrue);
      expect(isCompleteRelayCode('ABCD-EFGH-IJKL-MNO'), isFalse);
      expect(isPotentialEncodedHardwareTransfer('ABCD-EFGH'), isFalse);
    });

    test('recognizes a complete OpenAbsinthe code', () {
      expect(isCompleteOpenAbsintheCode('ABCDEF-GHIJ-KLMN-OPQR'), isTrue);
      expect(isCompleteOpenAbsintheCode('ABCDEF-GHIJ-KLMN-OPQ'), isFalse);
    });

    test('only attempts complete base64 transfers', () {
      expect(isPotentialEncodedHardwareTransfer('T0FCU0RBVEE='), isTrue);
      expect(isPotentialEncodedHardwareTransfer('T0FCU0RBVEE'), isFalse);
      expect(isPotentialEncodedHardwareTransfer('not-a-code'), isFalse);
    });
  });

  group('relay version response validation', () {
    test('classifies authorization failures without decoding null data', () {
      final result = validateRelayVersionResponse(statusCode: 401, data: null);

      expect(result.kind, RelayVersionResponseKind.rejected);
      expect(result.versions, isNull);
    });

    test('accepts a complete version response', () {
      final result = validateRelayVersionResponse(
        statusCode: 200,
        data: {
          'versions': {
            'software_name': 'iPhone OS',
            'software_version': '15.7.9',
            'unique_device_id': 'device-id',
          },
        },
      );

      expect(result.kind, RelayVersionResponseKind.success);
      expect(result.versions?['software_name'], 'iPhone OS');
    });

    test('rejects malformed successful responses', () {
      final result = validateRelayVersionResponse(
        statusCode: 200,
        data: {'versions': null},
      );

      expect(result.kind, RelayVersionResponseKind.malformed);
    });
  });
}
