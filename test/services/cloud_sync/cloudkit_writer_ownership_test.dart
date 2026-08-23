import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordinary builds have no CloudKit writer', () {
    expect(CloudKitWriterOwnership.decision.configurationValid, isTrue);
    expect(CloudKitWriterOwnership.decision.owner, CloudKitWriterOwner.none);
    expect(CloudKitWriterOwnership.legacyMutationsEnabled, isFalse);
    expect(CloudKitWriterOwnership.v2MutationsEnabled, isFalse);
  });

  test(
    'the one selector can grant ownership to exactly one implementation',
    () {
      final legacy = CloudKitWriterOwnership.resolve('legacy');
      expect(legacy.legacyMutationsEnabled, isTrue);
      expect(legacy.v2MutationsEnabled, isFalse);

      final v2 = CloudKitWriterOwnership.resolve('v2');
      expect(v2.legacyMutationsEnabled, isFalse);
      expect(v2.v2MutationsEnabled, isTrue);
    },
  );

  test('unknown or non-canonical values fail closed without disclosure', () {
    for (final value in <String>[
      '',
      'LEGACY',
      'legacy,v2',
      'v2\nsecret-value',
    ]) {
      final decision = CloudKitWriterOwnership.resolve(value);
      expect(decision.configurationValid, isFalse);
      expect(decision.owner, CloudKitWriterOwner.none);
      expect(decision.legacyMutationsEnabled, isFalse);
      expect(decision.v2MutationsEnabled, isFalse);
      expect(
        decision.toString(),
        'CloudKitWriterOwnershipDecision('
        'status=cloudkit_writer_configuration_invalid)',
      );
      expect(decision.safeStatusCode, 'cloudkit_writer_configuration_invalid');
    }
  });

  test(
    'legacy mutations use the shared owner instead of an independent flag',
    () {
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('OPENBUBBLES_LEGACY_CLOUDKIT_MUTATIONS')));
      expect(
        source,
        contains('CloudKitWriterOwnership.legacyMutationsEnabled'),
      );
    },
  );

  test('beta canary does not select any CloudKit writer', () {
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    final betaStart = workflow.indexOf(
      'Build Beta Debug APK with the Cloud Sync V2 sampler',
    );
    final evidenceStart = workflow.indexOf(
      'Build developer-only CloudKit V2 Evidence Canary APK',
      betaStart,
    );
    expect(betaStart, greaterThanOrEqualTo(0));
    expect(evidenceStart, greaterThan(betaStart));
    final betaBuild = workflow.substring(betaStart, evidenceStart);
    expect(betaBuild, isNot(contains('OPENBUBBLES_CLOUDKIT_WRITER_OWNER=')));
    final evidenceBuild = workflow.substring(evidenceStart);
    expect(
      evidenceBuild,
      isNot(contains('OPENBUBBLES_CLOUDKIT_WRITER_OWNER=')),
    );
  });

  test('encrypted-data reset uses the shared destructive interlock', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final resetCall = source.indexOf('api.resetClique(');
    expect(resetCall, greaterThanOrEqualTo(0));
    final wrapper = source.lastIndexOf(
      '_runCloudKitDestructiveReset(',
      resetCall,
    );
    expect(wrapper, greaterThanOrEqualTo(0));
    expect(resetCall - wrapper, lessThan(200));
    expect(source, contains('kind: CloudKitOperationKind.destructiveReset'));
  });
}
