import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android trusted-device 2FA falls back after proximity failure', () {
    final source = File('rust/src/api/api.rs').readAsStringSync();

    expect(
      source,
      contains('tokio::time::timeout(Duration::from_secs(10)'),
    );
    expect(
      source,
      contains('Trusted-device 2FA proximity exchange failed'),
    );
    expect(
      source,
      contains('Trusted-device 2FA proximity response timed out'),
    );

    final directVerificationCalls = RegExp(
      r'account\.lock\(\)\.await\.verify_2fa\(code\)\.await\?',
    ).allMatches(source);
    expect(directVerificationCalls.length, greaterThanOrEqualTo(3));
  });
}
