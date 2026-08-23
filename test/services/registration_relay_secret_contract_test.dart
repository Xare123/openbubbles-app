import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registration relay bearer token is supplied only at build time', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final workflow = File('.github/workflows/build.yml').readAsStringSync();

    expect(
      RegExp(
        r"const registrationRelayAccessToken\s*=\s*String\.fromEnvironment\(\s*'OPENBUBBLES_REGISTRATION_RELAY_ACCESS_TOKEN',?\s*\);",
      ).hasMatch(source),
      isTrue,
    );
    expect(
      RegExp(
        r'const registrationRelayAccessToken\s*=\s*["\x27][^"\x27]+',
      ).hasMatch(source),
      isFalse,
    );
    expect(workflow, contains('secrets.REGISTRATION_RELAY_ACCESS_TOKEN'));
    expect(
      RegExp(
        r'--dart-define=OPENBUBBLES_REGISTRATION_RELAY_ACCESS_TOKEN=',
      ).allMatches(workflow).length,
      4,
      reason:
          'Every Android artifact that initializes rustpush, including the '
          'separate CloudKit canary, must receive the build-time relay secret.',
    );
  });
}
