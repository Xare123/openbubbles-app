import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordinary builds keep the manual production sampler absent', () {
    expect(CloudSyncDevGate.manualShadowSamplerEnabled, isFalse);
    expect(CloudSyncDevGate.manualSemanticPullEnabled, isFalse);
  });

  test('beta sampler CI explicitly enables both independent canary gates', () {
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    expect(
      workflow,
      contains('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true'),
    );
    expect(
      workflow,
      contains(
        '--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true',
      ),
    );
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

  test('semantic production entry point is separately gated and bounded', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final methodStart = source.indexOf(
      'runCloudSyncV2ManualSemanticPullConfirmed()',
    );
    final methodEnd = source.indexOf(
      '_runCloudSyncV2ManualSemanticPull() async',
      methodStart,
    );

    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final method = source.substring(methodStart, methodEnd);
    expect(method, contains('CloudSyncDevGate.manualSemanticPullEnabled'));
    expect(method, contains('_cloudSyncV2DeveloperRuntimeAllowed'));
    expect(method, contains('_cloudSyncV2SemanticPullQuiescing'));
    expect(method, contains('_cloudSyncV2SemanticPullInFlight'));
    expect(method, contains('cloud_sync_semantic_pull_disabled'));
    expect(method, contains('cloud_sync_semantic_pull_active'));
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

    final wrapperStart = source.lastIndexOf(
      'if ((CloudSyncDevGate.manualShadowSamplerEnabled ||',
      sectionStart,
    );
    expect(wrapperStart, greaterThanOrEqualTo(0));
    expect(
      source.substring(wrapperStart, sectionStart),
      contains('ss.settings.developerEnabled.value'),
    );

    final shadowStart = section.indexOf(
      'title: "Run Read-only Shadow Sample"',
    );
    final semanticGate = section.indexOf(
      'if (CloudSyncDevGate.manualSemanticPullEnabled)',
      shadowStart,
    );
    expect(shadowStart, greaterThanOrEqualTo(0));
    expect(semanticGate, greaterThan(shadowStart));
    final shadow = section.substring(shadowStart, semanticGate);
    final confirmed = shadow.indexOf('if (confirmed != true) return;');
    final recheck = shadow.indexOf(
      'if (cloudSyncV2Running.value) return;',
      confirmed,
    );
    final claim = shadow.indexOf(
      'cloudSyncV2Running.value = true;',
      confirmed,
    );
    final run = shadow.indexOf(
      'runCloudSyncV2ManualShadowConfirmed()',
      confirmed,
    );
    expect(confirmed, greaterThanOrEqualTo(0));
    expect(recheck, greaterThan(confirmed));
    expect(claim, greaterThan(recheck));
    expect(run, greaterThan(claim));
    expect(shadow, contains('protected local journal, checkpoint'));
    expect(shadow, contains('No CloudKit writes or semantic applies'));
    expect(shadow, contains('cloudSyncV2SafeFailureCode(error)'));
    expect(shadow, isNot(contains('catch (_)')));

    final semanticStart = section.indexOf(
      'title: "Run Semantic Pull Canary"',
    );
    final semantic = section.substring(semanticStart);
    expect(semantic, contains('cloudSyncV2ManualSemanticPullAvailable'));
    expect(semantic, contains('runCloudSyncV2ManualSemanticPullConfirmed()'));
    expect(semantic, contains('Local canonical chats, messages, reactions'));
    expect(semantic, contains('No CloudKit uploads or deletes'));
    expect(semantic, contains('no local message deletes'));
    expect(semantic, contains('tombstones are quarantined'));
    expect(semantic, contains('CloudSyncRunStatus.completed'));
    expect(semantic, contains('expectedZones'));
    expect(semantic, contains('reportedZones.containsAll(expectedZones)'));
    expect(semantic, contains('report.zones.length == expectedZones.length'));
    expect(semantic, contains('final canaryPassed'));
    expect(semantic, contains('deferred == 0'));
    expect(semantic, contains('quarantined == 0'));
    expect(semantic, contains('retried == 0'));
    expect(semantic, isNot(contains('CloudSyncRunStatus.skipped')));
    expect(semantic, contains('remoteWriteTripwiresIntact'));
    expect(semantic, contains('Incomplete records/zone'));
    expect(semantic, contains('cloudSyncV2SafeFailureCode(error)'));
    expect(semantic, isNot(contains('catch (_)')));
  });

  test('semantic sampler pins local-only flags and manual trigger', () {
    final source = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart',
    ).readAsStringSync();
    final configStart = source.indexOf('CloudSyncEngineConfig _config()');
    final configEnd = source.indexOf('void _validatePreflight', configStart);
    expect(configStart, greaterThanOrEqualTo(0));
    expect(configEnd, greaterThan(configStart));
    final config = source.substring(configStart, configEnd);

    expect(source, contains('trigger: CloudSyncTrigger.manual'));
    expect(config, contains('readOnlyFetch: true'));
    expect(config, contains('semanticApply: true'));
    expect(config, contains('saves: false'));
    expect(config, contains('deletions: false'));
    expect(config, contains('profiles: false'));
    expect(config, contains('notificationHints: false'));
    expect(source, isNot(contains('Timer(')));
    expect(source, isNot(contains('WorkManager')));
    expect(source, isNot(contains('onNetworkReconnect')));
    expect(source, isNot(contains('onIdsReconnect')));
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
    final quiesce = reset.indexOf('_cloudSyncV2SemanticPullQuiescing = true;');
    final semanticWait = reset.indexOf('final semanticPull =');
    final awaitSemantic = reset.indexOf('await semanticPull.timeout(', semanticWait);
    final boundedWait = reset.indexOf(
      '_cloudSyncV2SemanticPullQuiescenceTimeout',
      awaitSemantic,
    );
    final safeAbort = reset.indexOf(
      'cloud_sync_semantic_pull_quiescence_timeout',
      boundedWait,
    );
    final detachState = reset.indexOf('state = null');
    final nativeReset = reset.indexOf('api.resetState(');
    final resume = reset.indexOf('resumeAfterAccountTransition()');

    expect(quiesce, greaterThanOrEqualTo(0));
    expect(semanticWait, greaterThan(quiesce));
    expect(awaitSemantic, greaterThan(semanticWait));
    expect(boundedWait, greaterThan(awaitSemantic));
    expect(safeAbort, greaterThan(boundedWait));
    expect(detachState, greaterThan(safeAbort));
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
      '_runLegacyCloudKitOperation<T>',
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
