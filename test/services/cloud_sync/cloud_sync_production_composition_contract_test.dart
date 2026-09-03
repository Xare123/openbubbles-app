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

  test('empty CloudKit chat previews reconcile after bulk projection', () {
    final source = File(
      'lib/app/layouts/conversation_list/widgets/tile/conversation_tile.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('.watch(triggerImmediately: subtitle == "Empty message")'),
    );
    expect(
      source,
      contains('subtitle == "Empty message"'),
    );
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
    expect(outbound, contains('armCloudSyncV2OutboundReplayConfirmed'));
    expect(outbound, contains('runCloudSyncV2OutboundDoubleConfirmed'));
    expect(outbound, contains('reselectExact(candidate)'));
    expect(outbound, contains('_cloudSyncV2OutboundProvisioningInFlight'));
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

  test('V2 PCS preparation joins existing trust without a reset path', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final methodStart = source.indexOf('prepareCloudSyncV2PcsConfirmed()');
    final methodEnd = source.indexOf(
      'bool get cloudSyncV2ManualShadowAvailable',
      methodStart,
    );

    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final method = source.substring(methodStart, methodEnd);
    expect(method, contains('CloudSyncDevGate.manualSemanticPullEnabled'));
    expect(method, contains('_cloudSyncV2CanaryRuntimeAllowed'));
    expect(method, contains('_cloudSyncV2DeveloperRuntimeAllowed'));
    expect(method, contains('legacy_sync_active'));
    expect(method, contains('.isInClique('));
    expect(method, contains('.getBottles('));
    expect(method, contains('.joinCliqueWithBottle('));
    expect(method, contains('promptPassword('));
    expect(method, contains('_promptCloudSyncV2BottleChoice('));
    expect(method, contains("identical(state, preparedState)"));
    expect(method, contains('cloud_sync_v2_pcs_recovery_required'));
    expect(method, isNot(contains('promptResetData(')));
    expect(method, isNot(contains('resetClique(')));
    expect(method, isNot(contains('cloudSyncingEnabled.value = true')));
    expect(method, isNot(contains('doCloudKitSync(')));

    final uiSource = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();
    final uiStart = uiSource.indexOf(
      'title: "Prepare iCloud Encryption (Canary)"',
    );
    final uiEnd = uiSource.indexOf(
      'title: "Catch Up Messages in iCloud (Canary)"',
      uiStart,
    );
    expect(uiStart, greaterThanOrEqualTo(0));
    expect(uiEnd, greaterThan(uiStart));
    final ui = uiSource.substring(uiStart, uiEnd);
    expect(ui, contains('_runCloudSyncV2PcsPreparation'));
    expect(ui, contains('Never resets encrypted data'));
    expect(ui, isNot(contains('promptResetData')));
  });

  test('semantic production entry point is separately gated and bounded', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final methodStart = source.indexOf(
      'runCloudSyncV2ManualSemanticPullConfirmed({int maximumPasses = 1})',
    );
    final methodEnd = source.indexOf(
      'runCloudSyncV2ManualSemanticCatchUpConfirmed()',
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
    expect(method, contains('cloud_sync_semantic_drain_pass_limit_invalid'));
    expect(
      method,
      contains('CloudSyncSemanticDrainController.defaultMaximumPasses'),
    );
  });

  test('VM trigger preserves one-pass mode and exposes bounded catch-up', () {
    final source = File('tooling/vm_trigger_semantic.dart').readAsStringSync();
    expect(source, contains("args[1] != '--catch-up'"));
    expect(source, contains("args.first"));
    expect(source, isNot(contains('args.single')));
    expect(source, contains("'runCloudSyncV2ManualSemanticPullConfirmed'"));
    expect(source, contains("'runCloudSyncV2ManualSemanticCatchUpConfirmed'"));
  });

  test('semantic projection suppresses historical message notifications', () {
    final rustpushSource = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final methodStart = rustpushSource.indexOf(
      '_runCloudSyncV2ManualSemanticPull({',
    );
    final methodEnd = rustpushSource.indexOf(
      'bool get cloudSyncV2ManualOutboundAvailable',
      methodStart,
    );

    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final method = rustpushSource.substring(methodStart, methodEnd);
    final capture = method.indexOf(
      'final restoringBeforeSemanticPull = chats.restoring;',
    );
    final suppress = method.indexOf('chats.restoring = true;', capture);
    final run = method.indexOf(
      'controller.drainConfirmedAndPersist()',
      suppress,
    );
    final restore = method.indexOf(
      'chats.restoring = restoringBeforeSemanticPull;',
      run,
    );
    expect(capture, greaterThanOrEqualTo(0));
    expect(suppress, greaterThan(capture));
    expect(run, greaterThan(suppress));
    expect(method, contains('finally'));
    expect(restore, greaterThan(run));

    final notificationSource = File(
      'lib/services/backend/notifications/notifications_service.dart',
    ).readAsStringSync();
    final listenerStart = notificationSource.indexOf(
      'countSub = countQuery.listen((event)',
    );
    final listenerEnd = notificationSource.indexOf(
      'currentCount = newCount;',
      notificationSource.indexOf('if (ls.isAlive', listenerStart),
    );
    expect(listenerStart, greaterThanOrEqualTo(0));
    expect(listenerEnd, greaterThan(listenerStart));
    final listener = notificationSource.substring(listenerStart, listenerEnd);
    final count = listener.indexOf('final newCount = event.count();');
    final guard = listener.indexOf('if (chats.restoring', count);
    final baseline = listener.indexOf('currentCount = newCount;', guard);
    final earlyReturn = listener.indexOf('return;', baseline);
    expect(count, greaterThanOrEqualTo(0));
    expect(guard, greaterThan(count));
    expect(baseline, greaterThan(guard));
    expect(earlyReturn, greaterThan(baseline));
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

    final semanticStart = section.indexOf(
      'title: "Catch Up Messages in iCloud (Canary)"',
    );
    final semantic = section.substring(semanticStart);
    expect(semantic, contains('cloudSyncV2ManualSemanticPullAvailable'));
    expect(semantic, contains('runCloudSyncV2ManualSemanticPullConfirmed('));
    expect(semantic, contains('maximumPasses: maximumPasses'));
    expect(semantic, contains('maximumPasses * 200'));
    expect(semantic, contains('Up to 200 changes per CloudKit zone.'));
    expect(semantic, contains('Up to 800 changes per zone'));
    expect(semantic, contains('Up to 3,200 changes per zone'));
    expect(
      semantic,
      contains('checkpoint-ordered rather than safely date-seekable'),
    );
    expect(semantic, contains('Local canonical chats, messages, reactions'));
    expect(semantic, contains('No CloudKit uploads or deletes'));
    expect(semantic, contains('no local message deletes'));
    expect(
      semantic,
      contains('tombstones are retained as read-only acknowledgements'),
    );
    expect(semantic, contains('cloudSyncV2SemanticCanaryPresentation('));
    expect(semantic, contains('result.lastReport'));
    final semanticRun = semantic.indexOf(
      'runCloudSyncV2ManualSemanticPullConfirmed(',
    );
    final chatOrderRepair = semantic.indexOf(
      'await repairCloudSyncChatLatestMessageDates();',
      semanticRun,
    );
    final chatRefresh = semantic.indexOf(
      'await chats.init(force: true);',
      semanticRun,
    );
    final semanticPresentation = semantic.indexOf(
      'cloudSyncV2SemanticCanaryPresentation(',
      semanticRun,
    );
    expect(semanticRun, greaterThanOrEqualTo(0));
    expect(chatOrderRepair, greaterThan(semanticRun));
    expect(chatRefresh, greaterThan(chatOrderRepair));
    expect(semanticPresentation, greaterThan(chatRefresh));
    expect(semantic, contains('Chat list refreshed.'));
    expect(
      semantic,
      contains(
        'CloudKit catch-up completed, but the chat list could not refresh. Restart OpenBubbles to display any newly available history.',
      ),
    );
    expect(semantic, contains('Cloud Sync V2 local chat refresh failed code='));
    final semanticCatch = semantic.indexOf(
      '} catch (error) {',
      semanticPresentation,
    );
    final busyPresentation = semantic.indexOf(
      'if (_showCloudSyncV2Busy(error)) return;',
      semanticCatch,
    );
    final genericFailure = semantic.indexOf(
      'cloudSyncV2SafeFailureCode(error)',
      semanticCatch,
    );
    expect(semanticCatch, greaterThan(chatRefresh));
    expect(busyPresentation, greaterThan(semanticCatch));
    expect(genericFailure, greaterThan(busyPresentation));
    final presentationStart = source.indexOf(
      'CloudSyncV2SemanticCanaryPresentation cloudSyncV2SemanticCanaryPresentation(',
    );
    final presentationEnd = source.indexOf(
      'class TroubleshootPanel',
      presentationStart,
    );
    expect(presentationStart, greaterThanOrEqualTo(0));
    expect(presentationEnd, greaterThan(presentationStart));
    final presentation = source.substring(presentationStart, presentationEnd);
    expect(presentation, contains('CloudSyncRunStatus.completed'));
    expect(presentation, contains('expectedZones'));
    expect(presentation, contains('reportedZones.containsAll(expectedZones)'));
    expect(
      presentation,
      contains('report.zones.length == expectedZones.length'),
    );
    expect(presentation, contains('zoneStructureIntact'));
    expect(presentation, contains('allZonesReadWithoutBlockingFailure'));
    expect(presentation, contains('readCompletionGatesPassed'));
    expect(presentation, contains('retained_projection_incomplete'));
    expect(presentation, contains('deferred == 0'));
    expect(presentation, contains('quarantined == 0'));
    expect(presentation, contains('unsupportedServiceQuarantined == 0'));
    expect(presentation, contains('tombstoneQuarantined == 0'));
    expect(presentation, contains('tombstoneReadOnlyAcknowledged'));
    expect(presentation, contains('tombstone failures'));
    expect(presentation, contains('retried == 0'));
    expect(presentation, isNot(contains('CloudSyncRunStatus.skipped')));
    expect(presentation, contains('remoteWriteTripwiresIntact'));
    expect(presentation, contains('retainedUnprojected == 0'));
    expect(presentation, contains('retained-unprojected'));
    expect(presentation, contains('Cloud Sync V2 Partial'));
    expect(presentation, contains('Incomplete records/zone'));
    expect(semantic, contains('cloudSyncV2SafeFailureCode(error)'));
    expect(semantic, isNot(contains('catch (_)')));
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

  test('outbound UI is gated, double-confirmed, and recovery-only', () {
    final source = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();

    expect(source, contains('CloudSyncDevGate.manualOutboundCanaryEnabled'));
    expect(source, contains('title: "Upload One Existing Text Canary"'));
    expect(source, contains('title: "Recover One Interrupted Upload"'));
    expect(source, contains('create-only CloudKit V2 writer'));
    expect(source, contains('No deletes or automatic retry'));
    expect(source, contains('Never retry automatically'));

    final outboundStart = source.indexOf(
      'Future<void> _runCloudSyncV2OutboundCanary()',
    );
    final outboundEnd = source.indexOf(
      'Future<void> _recoverCloudSyncV2OutboundCanary()',
      outboundStart,
    );
    expect(outboundStart, greaterThanOrEqualTo(0));
    expect(outboundEnd, greaterThan(outboundStart));
    final outbound = source.substring(outboundStart, outboundEnd);
    final selection = outbound.indexOf(
      'selectCloudSyncV2OutboundCanaryCandidate(',
    );
    final arm = outbound.indexOf('armCloudSyncV2OutboundConfirmed(', selection);
    final prepare = outbound.indexOf('prepareCloudSyncV2OutboundWriter()', arm);
    final run = outbound.indexOf('runCloudSyncV2OutboundDoubleConfirmed(', arm);
    final finallyBlock = outbound.lastIndexOf('finally {');
    final disarm = outbound.indexOf(
      'disarmCloudSyncV2Outbound(armed)',
      finallyBlock,
    );
    expect(selection, greaterThanOrEqualTo(0));
    expect(arm, greaterThan(selection));
    expect(prepare, greaterThan(arm));
    expect(run, greaterThan(prepare));
    expect(finallyBlock, greaterThan(run));
    expect(disarm, greaterThan(finallyBlock));
    expect(outbound, contains('if (!secondConfirmed) return;'));
    expect(outbound, contains('Do not retry'));
    expect(outbound, contains('candidate.guidHash'));
    expect(outbound, contains('candidate.characterCount'));
    expect(outbound, contains('_requestCloudSyncV2OutboundRecipient()'));
    expect(outbound, contains('expectedRecipient: expectedRecipient'));
    expect(outbound, contains('current IDS sending handle'));
    expect(outbound, isNot(contains('candidate.cloudMessage.text')));
    expect(outbound, isNot(contains('candidate.destination')));

    final recoveryFlowStart = source.indexOf(
      '_runCloudSyncV2OutboundRecoveryFlow({',
    );
    final recoveryFlowEnd = source.indexOf(
      'Future<void> _runCloudSyncV2OutboundCanary()',
      recoveryFlowStart,
    );
    expect(recoveryFlowStart, greaterThanOrEqualTo(0));
    expect(recoveryFlowEnd, greaterThan(recoveryFlowStart));
    final recoveryFlow = source.substring(recoveryFlowStart, recoveryFlowEnd);
    expect(recoveryFlow, contains('armCloudSyncV2OutboundRecoveryConfirmed()'));
    expect(recoveryFlow, contains('armCloudSyncV2OutboundReplayConfirmed()'));
    expect(
      recoveryFlow,
      contains('final replayVerification = armed.replayVerification;'),
    );
    expect(recoveryFlow, contains('if (prepareWriter && !replayVerification)'));
    expect(
      recoveryFlow.indexOf(
        'final replayVerification = armed.replayVerification;',
      ),
      lessThan(
        recoveryFlow.indexOf('if (prepareWriter && !replayVerification)'),
      ),
    );
    expect(recoveryFlow, contains('runCloudSyncV2OutboundDoubleConfirmed('));
    expect(recoveryFlow, contains('disarmCloudSyncV2Outbound(armed)'));
    expect(recoveryFlow, isNot(contains('selectCloudSyncV2Outbound')));
    expect(recoveryFlow, isNot(contains('armCloudSyncV2OutboundConfirmed(')));
    expect(source, contains('CloudSyncDevGate.manualOutboundCanaryEnabled'));
    expect(source, contains('Platform.isAndroid'));
  });

  test('confirmed replay is an exact no-save protected readback', () {
    final manual = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart',
    ).readAsStringSync();
    final replayBranchStart = manual.indexOf(
      'case CloudSyncOutboundCanarySessionKind.confirmedReplay:',
    );
    final replayBranchEnd = manual.indexOf(
      'case CloudSyncOutboundCanarySessionKind.unknownRecovery:',
      replayBranchStart,
    );
    expect(replayBranchStart, greaterThanOrEqualTo(0));
    expect(replayBranchEnd, greaterThan(replayBranchStart));
    final replayBranch = manual.substring(replayBranchStart, replayBranchEnd);
    expect(replayBranch, contains('verifyConfirmedNoSave'));
    expect(replayBranch, isNot(contains('flushOneBatch')));

    final adapter = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart',
    ).readAsStringSync();
    expect(
      adapter,
      contains('Future<CloudSyncConfirmedReplayProof> verifyConfirmedNoSave'),
    );
    expect(adapter, contains('verifyConfirmedMessageCreateNoSave'));
    expect(adapter, contains('retainConfirmedReceiptsForReplay: true'));
    expect(adapter, contains('Future<void> finalizeConfirmedReplayProof'));
    expect(adapter, contains('required CloudSyncConfirmedReplayProof proof'));
    expect(adapter, contains('releaseConfirmedReplayReceipt'));
    expect(adapter, contains('clearConfirmedProtectedOutboundLeaseReference'));
    expect(adapter, contains('proof: proof'));
    expect(manual, contains('finalizeConfirmedReplayProof'));
    expect(adapter, contains('verifyConfirmedMessageCreateNoSave('));
    final verifyStart = adapter.indexOf('verifyConfirmedMessageCreateNoSave(');
    final verifyEnd = adapter.indexOf(');', verifyStart);
    expect(verifyStart, greaterThanOrEqualTo(0));
    expect(verifyEnd, greaterThan(verifyStart));
    final verificationCall = adapter.substring(verifyStart, verifyEnd);
    expect(verificationCall, contains('scope'));
    expect(verificationCall, contains('operation: operation'));

    expect(adapter, contains('clearDurableAdoptionMarker: () =>'));

    final native = File(
      'lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart',
    ).readAsStringSync();
    final releaseStart = native.indexOf(
      'Future<void> releaseConfirmedReplayReceipt(',
    );
    final durableClearStart = native.indexOf(
      'await clearDurableAdoptionMarker();',
      releaseStart,
    );
    final nativeAcknowledgeStart = native.indexOf(
      '_bindings.acknowledgeCommittedPageLease(',
      releaseStart,
    );
    expect(releaseStart, greaterThanOrEqualTo(0));
    expect(durableClearStart, greaterThan(releaseStart));
    expect(nativeAcknowledgeStart, greaterThan(durableClearStart));
  });

  test('ambiguous recovery is structurally isolated from every write lane', () {
    final adapter = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart',
    ).readAsStringSync();
    final sessionStart = adapter.indexOf(
      'createSession: (snapshot, scope, kind, expectedOperation) async {',
    );
    final sessionEnd = adapter.indexOf('\n      },', sessionStart);
    expect(sessionStart, greaterThanOrEqualTo(0));
    expect(sessionEnd, greaterThan(sessionStart));
    final session = adapter.substring(sessionStart, sessionEnd);
    final durableRead = session.indexOf('readOutboxEntries(scope)');
    final unknownStatus = session.indexOf('CloudOutboxStatus.unknownOutcome');
    final reconciliationAdmission = session.indexOf(
      'requireReconciliationAllowed(',
      unknownStatus,
    );
    final firstUnknownBranch = session.indexOf(
      'if (kind == CloudSyncOutboundCanarySessionKind.unknownRecovery)',
      unknownStatus,
    );
    final unknownLaneStart = session.indexOf(
      'if (kind == CloudSyncOutboundCanarySessionKind.unknownRecovery)',
      firstUnknownBranch + 1,
    );
    final transportStart = session.indexOf(
      'final transport = NativeProtectedCloudSyncTransport(',
      unknownLaneStart,
    );
    expect(durableRead, greaterThanOrEqualTo(0));
    expect(unknownStatus, greaterThan(durableRead));
    expect(firstUnknownBranch, greaterThan(unknownStatus));
    expect(reconciliationAdmission, greaterThan(firstUnknownBranch));
    expect(unknownLaneStart, greaterThan(firstUnknownBranch));
    expect(transportStart, greaterThan(unknownLaneStart));
    final unknownLane = session.substring(unknownLaneStart, transportStart);
    expect(unknownLane, contains('_ProductionUnknownOutcomeCanarySession'));
    expect(unknownLane, contains('mutationGuard.reconcileUnknownOutcome('));
    for (final forbidden in const [
      'CloudSyncEngine',
      'CloudSyncOutboundAdmissionCoordinator',
      'NativeProtectedCloudSyncTransport',
      'prepareSubmission',
      'consumePreparedSubmission',
      '_resolveServerRecordChanged',
      'CloudOutboxTransition.quarantined',
      'CloudOutboxAction.delete',
    ]) {
      expect(unknownLane, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(session, isNot(contains('reconcileUnknownOutcomesOnly')));

    final manual = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart',
    ).readAsStringSync();
    expect(manual, contains('CloudSyncOutboundCanaryUnknownRecoverySession'));
    expect(manual, contains('CloudSyncOutboundCanaryReplaySession'));
    expect(manual, contains('_requireExactSessionCapability'));
    expect(
      manual,
      contains('_requireAllowedUnknownRecoveryPostflightOperation'),
    );

    final native = File(
      'lib/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart',
    ).readAsStringSync();
    final reconcileStart = native.indexOf(
      'Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome(',
    );
    final reconcileEnd = native.indexOf(
      'verifyConfirmedMessageCreateNoSave(',
      reconcileStart,
    );
    final reconcile = native.substring(reconcileStart, reconcileEnd);
    expect(reconcile, contains('mutationGuard.reconcileUnknownOutcome('));
    expect(reconcile, isNot(contains('prepareSubmission(')));
    expect(reconcile, isNot(contains('consumePreparedSubmission(')));

    final guard = File(
      'lib/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart',
    ).readAsStringSync();
    expect(guard, contains('_completeReconciliationAfterExactReadback('));
    expect(guard, contains('binding.reconcileMessageCreate('));
    expect(guard, isNot(contains('Future<void> completeReconciliation(')));

    final models = File(
      'lib/services/rustpush/cloud_sync/cloud_sync_models.dart',
    ).readAsStringSync();
    expect(models, isNot(contains('CloudUnknownOutcomeProof')));
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
    final pcsQuiesce = reset.indexOf(
      '_cloudSyncV2PcsPreparationQuiescing = true;',
    );
    final pcsWait = reset.indexOf('final pcsPreparation =');
    final awaitPcs = reset.indexOf('await pcsPreparation.timeout(', pcsWait);
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
    final provisioningWait = reset.indexOf(
      'await outboundProvisioning.timeout(',
    );
    final nativeReset = reset.indexOf('api.resetState(');
    final resume = reset.indexOf('resumeAfterAccountTransition()');

    expect(pcsQuiesce, greaterThanOrEqualTo(0));
    expect(quiesce, greaterThan(pcsQuiesce));
    expect(pcsWait, greaterThan(quiesce));
    expect(awaitPcs, greaterThan(pcsWait));
    expect(semanticWait, greaterThan(awaitPcs));
    expect(awaitSemantic, greaterThan(semanticWait));
    expect(boundedWait, greaterThan(awaitSemantic));
    expect(safeAbort, greaterThan(boundedWait));
    expect(provisioningWait, greaterThan(safeAbort));
    expect(outboundWait, greaterThan(provisioningWait));
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
