import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordinary builds keep the manual production sampler absent', () {
    expect(CloudSyncDevGate.manualShadowSamplerEnabled, isFalse);
  });

  test('production entry point requires both developer safety gates', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final methodStart = source.indexOf('runCloudSyncV2ManualShadowConfirmed()');
    final methodEnd = source.indexOf(
      'CloudSyncManualShadowOwner _cloudSyncV2Owner()',
      methodStart,
    );

    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final method = source.substring(methodStart, methodEnd);
    expect(method, contains('CloudSyncDevGate.manualShadowSamplerEnabled'));
    expect(method, contains('_cloudSyncV2DeveloperRuntimeAllowed'));
    expect(method, contains('ss.settings.developerEnabled.value'));
    expect(method, isNot(contains('Platform.isWindows ||')));
    expect(method, contains('runConfirmedAndPersist()'));
  });

  test('manual shadow UI is developer-gated and serializes confirmations', () {
    final source = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();
    final sectionStart = source.indexOf('text: "Cloud Sync V2"');
    final sectionEnd = source.indexOf('SettingsHeader(', sectionStart + 1);
    expect(sectionStart, greaterThanOrEqualTo(0));
    final section = source.substring(
      sectionStart,
      sectionEnd < 0 ? source.length : sectionEnd,
    );

    expect(
      source.substring(
        source.lastIndexOf(
          'if (CloudSyncDevGate.manualShadowSamplerEnabled',
          sectionStart,
        ),
        sectionStart,
      ),
      contains('ss.settings.developerEnabled.value'),
    );
    final confirmed = section.indexOf('if (confirmed != true) return;');
    final recheck = section.indexOf(
      'if (cloudSyncV2Running.value) return;',
      confirmed,
    );
    final claim = section.indexOf(
      'cloudSyncV2Running.value = true;',
      confirmed,
    );
    final run = section.indexOf(
      'runCloudSyncV2ManualShadowConfirmed()',
      confirmed,
    );
    expect(confirmed, greaterThanOrEqualTo(0));
    expect(recheck, greaterThan(confirmed));
    expect(claim, greaterThan(recheck));
    expect(run, greaterThan(claim));
    expect(section, contains('protected local journal, checkpoint'));
    expect(section, contains('No CloudKit writes or semantic applies'));
    expect(section, contains('cloudSyncV2SafeFailureCode(error)'));
    expect(section, isNot(contains('catch (_)')));
  });

  test('account teardown quiesces V2 before releasing Rust state', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final resetStart = source.indexOf(
      'Future reset(bool hw, bool logout, bool setup)',
    );
    final resetEnd = source.indexOf('void disposeState(', resetStart);
    expect(resetStart, greaterThanOrEqualTo(0));
    expect(resetEnd, greaterThan(resetStart));

    final reset = source.substring(resetStart, resetEnd);
    final quiesce = reset.indexOf('quiesceForAccountTransition()');
    final detachState = reset.indexOf('state = null');
    final nativeReset = reset.indexOf('api.resetState(');
    final resume = reset.indexOf('resumeAfterAccountTransition()');

    expect(quiesce, greaterThanOrEqualTo(0));
    expect(detachState, greaterThan(quiesce));
    expect(nativeReset, greaterThan(detachState));
    expect(resume, greaterThan(nativeReset));
    expect(reset, contains('finally'));
  });

  test('production composition has no automatic V2 trigger wiring', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final blockStart = source.indexOf('_buildCloudSyncV2ShadowController()');
    final blockEnd = source.indexOf(
      'Future<T> _runLegacyCloudKitOperation',
      blockStart,
    );
    expect(blockStart, greaterThanOrEqualTo(0));
    expect(blockEnd, greaterThan(blockStart));

    final block = source.substring(blockStart, blockEnd);
    expect(block, isNot(contains('Timer.')));
    expect(block, isNot(contains('WorkManager')));
    expect(block, isNot(contains('onNetworkReconnect')));
    expect(block, isNot(contains('onIdsReconnect')));
    expect(block, isNot(contains('semanticApply: true')));
    expect(block, isNot(contains('saves: true')));
    expect(block, isNot(contains('deletions: true')));
  });
}
