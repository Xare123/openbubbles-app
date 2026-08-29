import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordinary builds keep the manual production sampler absent', () {
    expect(CloudSyncDevGate.manualShadowSamplerEnabled, isFalse);
    expect(CloudSyncDevGate.manualSemanticPullEnabled, isFalse);
    expect(CloudSyncDevGate.manualOutboundCanaryEnabled, isFalse);
    expect(CloudSyncDevGate.protocolEvidenceAvailable, isFalse);
  });

  test('local mutation canaries require the exact Android Canary package', () {
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: true,
        packageName: CloudSyncDevGate.androidCanaryPackageName,
      ),
      isTrue,
    );
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: true,
        packageName: 'com.bluebubbles.messaging.alpha',
      ),
      isFalse,
    );
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: false,
        packageName: CloudSyncDevGate.androidCanaryPackageName,
      ),
      isFalse,
    );
  });

  test('evidence canary is a distinct read-only Android artifact', () {
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final betaStart = workflow.indexOf(
      'Build Beta Debug APK with the Cloud Sync V2 sampler',
    );
    final canaryStart = workflow.indexOf(
      'Build developer-only CloudKit V2 Evidence Canary APK',
    );
    expect(betaStart, greaterThanOrEqualTo(0));
    expect(canaryStart, greaterThan(betaStart));
    final betaBuild = workflow.substring(betaStart, canaryStart);
    expect(betaBuild, isNot(contains('OPENBUBBLES_CLOUDKIT_WRITER_OWNER')));
    expect(
      betaBuild,
      isNot(contains('OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY')),
    );
    expect(betaBuild, isNot(contains('OPENBUBBLES_CLOUD_SYNC_V2_EVIDENCE')));
    final canaryBuild = workflow.substring(canaryStart);
    expect(canaryBuild, isNot(contains('OPENBUBBLES_CLOUDKIT_WRITER_OWNER')));
    expect(
      canaryBuild,
      isNot(contains('OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY')),
    );
    expect(
      canaryBuild,
      contains('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true'),
    );
    expect(
      canaryBuild,
      contains('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true'),
    );
    expect(
      canaryBuild,
      contains('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_EVIDENCE=true'),
    );
    expect(canaryBuild, contains('app-canary-debug.apk'));
    expect(canaryBuild, contains('Unexpected Canary application ID'));
    expect(
      gradle,
      contains('applicationId "com.bluebubbles.messaging.cloudkitcanary"'),
    );
    expect(gradle, contains('applicationId "com.bluebubbles.messaging.beta"'));
    expect(gradle, contains('applicationId "com.bluebubbles.messaging.alpha"'));
  });

  test('outbound runtime requires V2 ownership and blocks the legacy path', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final availability = source.indexOf(
      'bool get cloudSyncV2ManualOutboundAvailable',
    );
    final legacy = source.indexOf('_runLegacyCloudKitOperation<T>');
    expect(availability, greaterThanOrEqualTo(0));
    expect(legacy, greaterThan(availability));
    final outbound = source.substring(availability, legacy);
    expect(outbound, contains('CloudSyncDevGate.manualOutboundCanaryEnabled'));
    expect(outbound, contains('CloudKitWriterOwnership.v2MutationsEnabled'));
    expect(outbound, contains('prepareCloudSyncV2OutboundWriter'));
    expect(outbound, contains('armCloudSyncV2OutboundConfirmed'));
    expect(outbound, contains('armCloudSyncV2OutboundRecoveryConfirmed'));
    expect(outbound, contains('runCloudSyncV2OutboundDoubleConfirmed'));
    expect(outbound, contains('pendingCountForScope'));
    expect(outbound, contains("lookupPortByName('bg_sync')"));

    final legacyEnd = source.indexOf('_runCloudKitDestructiveReset<T>', legacy);
    final legacyBlock = source.substring(legacy, legacyEnd);
    expect(legacyBlock, contains('CloudKitWriterOwner.v2'));
    expect(legacyBlock, contains('legacy_cloudkit_blocked_by_v2_writer'));
  });

  test('beta sampler CI explicitly enables both independent canary gates', () {
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    expect(
      workflow,
      contains('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true'),
    );
    expect(
      workflow,
      contains('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true'),
    );
    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, contains('canary_only:'));
    expect(workflow, contains("'[canary only]'"));
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
    expect(method, contains('_cloudSyncV2CanaryRuntimeAllowed'));
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
    expect(
      source.substring(wrapperStart, sectionStart),
      contains('CloudSyncDevGate.protocolEvidenceAvailable'),
    );

    final shadowStart = section.indexOf('title: "Run Read-only Shadow Sample"');
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
    final claim = shadow.indexOf('cloudSyncV2Running.value = true;', confirmed);
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

    final semanticStart = section.indexOf('title: "Run Semantic Pull Canary"');
    final semantic = section.substring(semanticStart);
    expect(semantic, contains('cloudSyncV2ManualSemanticPullAvailable'));
    expect(semantic, contains('runCloudSyncV2ManualSemanticPullConfirmed()'));
    expect(semantic, contains('Local canonical chats, messages, reactions'));
    expect(semantic, contains('No CloudKit uploads or deletes'));
    expect(semantic, contains('no local message deletes'));
    expect(
      semantic,
      contains('tombstones are retained as read-only acknowledgements'),
    );
    expect(semantic, contains('CloudSyncRunStatus.completed'));
    expect(semantic, contains('expectedZones'));
    expect(semantic, contains('reportedZones.containsAll(expectedZones)'));
    expect(semantic, contains('report.zones.length == expectedZones.length'));
    expect(semantic, contains('final canaryPassed'));
    expect(semantic, contains('deferred == 0'));
    expect(semantic, contains('quarantined == 0'));
    expect(semantic, contains('unsupportedServiceQuarantined == 0'));
    expect(semantic, contains('tombstoneQuarantined == 0'));
    expect(semantic, contains('tombstoneReadOnlyAcknowledged'));
    expect(semantic, contains('tombstone failures'));
    expect(semantic, contains('retried == 0'));
    expect(semantic, isNot(contains('CloudSyncRunStatus.skipped')));
    expect(semantic, contains('remoteWriteTripwiresIntact'));
    expect(semantic, contains('Incomplete records/zone'));
    expect(semantic, contains('cloudSyncV2SafeFailureCode(error)'));
    expect(semantic, isNot(contains('catch (_)')));
    expect(
      semantic,
      isNot(contains('title: "Upload One Existing Text Canary"')),
    );
    expect(
      semantic,
      isNot(contains('title: "Recover One Interrupted Upload"')),
    );
    expect(section, contains('title: "Record CloudKit protocol evidence"'));
    expect(section, contains('CloudSyncDevGate.protocolEvidenceAvailable'));
    expect(section, contains('cloudSyncV2EvidenceEnabled'));
    expect(section, contains('Never records message text'));
  });

  test('protocol evidence preference is default-off and developer-bound', () {
    final settings = File(
      'lib/database/global/settings.dart',
    ).readAsStringSync();
    final panel = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();

    expect(
      settings,
      contains('final RxBool cloudSyncV2EvidenceEnabled = false.obs;'),
    );
    expect(
      settings,
      contains(
        "'cloudSyncV2EvidenceEnabled': cloudSyncV2EvidenceEnabled.value",
      ),
    );
    expect(settings, contains("map['cloudSyncV2EvidenceEnabled'] ?? false"));
    expect(
      panel,
      contains('ss.settings.cloudSyncV2EvidenceEnabled.value = false'),
    );
    expect(panel, contains("'cloudSyncV2EvidenceEnabled'"));
  });

  test('outbound UI remains absent until remote absence proof exists', () {
    final source = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('_runCloudSyncV2OutboundCanary')));
    expect(source, isNot(contains('_recoverCloudSyncV2OutboundCanary')));
    expect(source, isNot(contains('Upload One Existing Text Canary')));
    expect(source, isNot(contains('Recover One Interrupted Upload')));
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
    final awaitSemantic = reset.indexOf(
      'await semanticPull.timeout(',
      semanticWait,
    );
    final boundedWait = reset.indexOf(
      '_cloudSyncV2SemanticPullQuiescenceTimeout',
      awaitSemantic,
    );
    final safeAbort = reset.indexOf(
      'cloud_sync_semantic_pull_quiescence_timeout',
      boundedWait,
    );
    final detachState = reset.indexOf('state = null');
    final outboundWait = reset.indexOf(
      'await outbound.timeout(_cloudSyncV2OutboundQuiescenceTimeout)',
    );
    final nativeReset = reset.indexOf('api.resetState(');
    final resume = reset.indexOf('resumeAfterAccountTransition()');

    expect(quiesce, greaterThanOrEqualTo(0));
    expect(semanticWait, greaterThan(quiesce));
    expect(awaitSemantic, greaterThan(semanticWait));
    expect(boundedWait, greaterThan(awaitSemantic));
    expect(safeAbort, greaterThan(boundedWait));
    expect(outboundWait, greaterThan(safeAbort));
    expect(detachState, greaterThan(outboundWait));
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
