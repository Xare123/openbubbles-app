import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void _expectCanaryPackagingContract({
  required String workflowPath,
  required String buildStepName,
  required String verificationStepName,
}) {
  final workflow = File(
    workflowPath,
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final exclusionStep = workflow.indexOf(
    '- name: Exclude dotenv asset from the Canary APK',
  );
  final buildStep = workflow.indexOf('- name: $buildStepName');
  final verificationStep = workflow.indexOf('- name: $verificationStepName');

  expect(exclusionStep, isNonNegative);
  expect(buildStep, greaterThan(exclusionStep));
  expect(verificationStep, greaterThan(buildStep));
  expect("dotenv_asset_line='    - .env'".allMatches(workflow).length, 1);
  expect(
    workflow,
    contains(r'''dotenv_asset_count="$(
            grep -Fxc -- "$dotenv_asset_line" pubspec.yaml || true
          )"'''),
  );
  expect(
    workflow,
    contains(r'''if [[ "$dotenv_asset_count" != '1' ]]; then'''),
  );
  expect(workflow, contains(r'''sed -i '/^    - \.env$/d' pubspec.yaml'''));
  expect(
    workflow,
    contains(
      r'''if unzip -Z1 "$apk" 'assets/flutter_assets/.env' >/dev/null 2>&1; then''',
    ),
  );
}

void main() {
  test('registration relay bearer token is excluded from Canary artifacts', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    final dedicatedCanaryWorkflow = File(
      '.github/workflows/cloudkit-canary.yml',
    ).readAsStringSync();

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
      3,
      reason: 'Only the three relay-onboarding artifacts receive the token.',
    );

    final canaryBuildStart = workflow.indexOf(
      '- name: Build developer-only CloudKit V2 Evidence Canary APK',
    );
    final canaryBuildEnd = workflow.indexOf(
      '- name: Sign the evidence canary',
      canaryBuildStart,
    );
    expect(canaryBuildStart, isNonNegative);
    expect(canaryBuildEnd, greaterThan(canaryBuildStart));
    final canaryBuild = workflow.substring(canaryBuildStart, canaryBuildEnd);
    expect(
      canaryBuild,
      isNot(contains('OPENBUBBLES_REGISTRATION_RELAY_ACCESS_TOKEN')),
    );
    expect(
      canaryBuild,
      isNot(contains('secrets.REGISTRATION_RELAY_ACCESS_TOKEN')),
    );
    expect(
      dedicatedCanaryWorkflow,
      isNot(contains('OPENBUBBLES_REGISTRATION_RELAY_ACCESS_TOKEN')),
    );
    expect(
      dedicatedCanaryWorkflow,
      isNot(contains('secrets.REGISTRATION_RELAY_ACCESS_TOKEN')),
    );
  });

  test('main workflow excludes dotenv from only the Canary APK', () {
    _expectCanaryPackagingContract(
      workflowPath: '.github/workflows/build.yml',
      buildStepName: 'Build developer-only CloudKit V2 Evidence Canary APK',
      verificationStepName:
          'Verify the evidence canary identity, signature, and native libraries',
    );
  });

  test('dedicated Canary workflow excludes dotenv from its APK', () {
    _expectCanaryPackagingContract(
      workflowPath: '.github/workflows/cloudkit-canary.yml',
      buildStepName: 'Build CloudKit V2 Evidence Canary APK',
      verificationStepName: 'Verify the signed Canary APK',
    );
  });

  test('runtime dotenv lookups tolerate the Canary asset being absent', () {
    for (final path in <String>[
      'lib/app/layouts/setup/setup_view.dart',
      'lib/app/layouts/conversation_view/widgets/text_field/'
          'conversation_text_field.dart',
      'lib/app/layouts/conversation_view/widgets/message/popup/'
          'message_popup.dart',
    ]) {
      final source = File(path).readAsStringSync();
      final unsafeLookup = RegExp(r"dotenv\.get\(\s*'[A-Z0-9_]+'\s*\)");
      expect(
        unsafeLookup.hasMatch(source),
        isFalse,
        reason: '$path must remain safe when Canary omits the dotenv asset.',
      );
    }
  });
}
