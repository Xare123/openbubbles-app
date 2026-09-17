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

    test('treats non-string version keys as malformed instead of throwing', () {
      final result = validateRelayVersionResponse(
        statusCode: 200,
        data: {
          'versions': {1: 'x'},
        },
      );

      expect(result.kind, RelayVersionResponseKind.malformed);
    });
  });

  group('relay app credential preflight', () {
    const officialHost = 'https://registration-relay.beeper.com';
    const customHost = 'https://relay.example.com';

    test('blocks official-origin requests with a blank app credential', () {
      expect(isRelayAppCredentialMissing(''), isTrue);
      expect(isRelayAppCredentialMissing('   '), isTrue);
      expect(
        shouldBlockRelayRegistrationForMissingAppCredential(
          relayHost: officialHost,
          appCredential: '',
          officialRelayHost: officialHost,
        ),
        isTrue,
      );
      expect(
        shouldBlockRelayRegistrationForMissingAppCredential(
          relayHost: officialHost,
          appCredential: '   ',
          officialRelayHost: officialHost,
        ),
        isTrue,
      );
    });

    test('allows official-origin requests with a supplied app credential', () {
      expect(isRelayAppCredentialMissing('token'), isFalse);
      expect(
        shouldBlockRelayRegistrationForMissingAppCredential(
          relayHost: officialHost,
          appCredential: 'token',
          officialRelayHost: officialHost,
        ),
        isFalse,
      );
    });

    test('allows custom-origin requests without an app credential', () {
      expect(
        isOfficialRelayHost(
          relayHost: customHost,
          officialRelayHost: officialHost,
        ),
        isFalse,
      );
      expect(
        shouldBlockRelayRegistrationForMissingAppCredential(
          relayHost: customHost,
          appCredential: '',
          officialRelayHost: officialHost,
        ),
        isFalse,
      );
    });

    test('matches the official host regardless of trailing slash', () {
      expect(
        shouldBlockRelayRegistrationForMissingAppCredential(
          relayHost: '$officialHost/',
          appCredential: '',
          officialRelayHost: officialHost,
        ),
        isTrue,
      );
    });

    test('treats official host case and the default port as the same origin', () {
      expect(
        isOfficialRelayHost(
          relayHost: 'HTTPS://REGISTRATION-RELAY.BEEPER.COM',
          officialRelayHost: officialHost,
        ),
        isTrue,
      );
      expect(
        isOfficialRelayHost(
          relayHost: 'https://registration-relay.beeper.com:443',
          officialRelayHost: officialHost,
        ),
        isTrue,
      );
      expect(
        shouldBlockRelayRegistrationForMissingAppCredential(
          relayHost: 'https://registration-relay.beeper.com:443/',
          appCredential: '  ',
          officialRelayHost: officialHost,
        ),
        isTrue,
      );
    });

    test('rejects non-origins without claiming a custom relay', () {
      expect(
        isOfficialRelayHost(
          relayHost: 'not-a-url',
          officialRelayHost: officialHost,
        ),
        isFalse,
      );
      expect(
        isOfficialRelayHost(
          relayHost: 'https://registration-relay.beeper.com/api/v1',
          officialRelayHost: officialHost,
        ),
        isFalse,
      );
    });

    test('missing-credential copy reports an unsent request without blaming the code', () {
      expect(
        missingRelayAppCredentialMessage,
        'This build has no access to the registration relay. '
        'No request was sent and your device code was not checked. '
        'Use a relay-enabled build or contact its provider.',
      );
      expect(missingRelayAppCredentialMessage, isNot(contains('Generate a new code')));
    });

    test('authorization-failed copy stays uncertain between code and app access', () {
      expect(
        relayAuthorizationFailedMessage,
        contains('The relay could not authorize this request.'),
      );
      expect(relayAuthorizationFailedMessage, contains('device code'));
      expect(relayAuthorizationFailedMessage, contains('relay access may need renewal'));
      expect(relayAuthorizationFailedMessage, isNot(contains('Generate a new code')));
    });
  });
}
