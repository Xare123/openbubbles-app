import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FaceTime diagnostics default off and persist through settings maps', () {
    final source = File('lib/database/global/settings.dart').readAsStringSync();

    expect(
      source,
      contains('final RxBool faceTimeDiagnosticsEnabled = false.obs;'),
    );
    expect(
      RegExp(
        "'faceTimeDiagnosticsEnabled': faceTimeDiagnosticsEnabled\\.value",
      ).allMatches(source),
      hasLength(1),
    );
    expect(
      RegExp(
        r"faceTimeDiagnosticsEnabled\.value = map\['faceTimeDiagnosticsEnabled'\] \?\? false;",
      ).allMatches(source),
      hasLength(2),
    );
  });

  test('native preference gate requires developer mode and opt in', () {
    final source = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeDiagnostics.kt',
    ).readAsStringSync();

    expect(source, contains('"flutter.developerEnabled"'));
    expect(source, contains('"flutter.faceTimeDiagnosticsEnabled"'));
    expect(source, contains('developerModeEnabled && diagnosticsEnabled'));
  });

  test('disabling developer mode also clears FaceTime diagnostics', () {
    final source = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();
    final disableStart = source.indexOf('if (!val) {');
    final disableEnd = source.indexOf('} else {', disableStart);

    expect(disableStart, greaterThanOrEqualTo(0));
    expect(disableEnd, greaterThan(disableStart));
    final disablePath = source.substring(disableStart, disableEnd);
    expect(disablePath, contains('faceTimeDiagnosticsEnabled.value = false'));
    expect(disablePath, contains("'faceTimeDiagnosticsEnabled'"));
  });

  test('diagnostic gates do not wrap functional join or end-call paths', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final cachedWebview = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt',
    ).readAsStringSync();

    final joinStart = activity.indexOf('private fun answerCall()');
    final joinEnd = activity.indexOf('override fun onNewIntent(', joinStart);
    final endStart = activity.indexOf('fun endCall()');
    final endEnd = activity.indexOf(
      'private fun hideControlsForPIP()',
      endStart,
    );

    expect(joinStart, greaterThanOrEqualTo(0));
    expect(joinEnd, greaterThan(joinStart));
    expect(endEnd, greaterThan(endStart));
    expect(
      activity.substring(joinStart, joinEnd),
      contains('scheduleJoinAttempt("answer-ready")'),
    );
    expect(activity, contains('callcontrols-join-button-session-banner'));
    expect(
      activity.substring(endStart, endEnd),
      contains('callcontrols-leave-button-session-banner'),
    );
    expect(cachedWebview, contains('message=<omitted>'));
    expect(cachedWebview, isNot(contains('consoleMessage.message()')));
  });

  test('incoming ring and admission paths reject stale state', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final ringGuard = source.indexOf('incomingRingingCallGuid == ring');
    final incomingLink = source.indexOf('usage: "nextincomingcall"', ringGuard);

    expect(ringGuard, greaterThanOrEqualTo(0));
    expect(incomingLink, greaterThan(ringGuard));
    expect(
      source,
      contains('Unable to render optional incoming FaceTime poster'),
    );
    expect(
      source,
      contains(
        'Refusing stale FaceTime admission for a session that is no longer present',
      ),
    );
  });

  test(
    'automatic FaceTime admission retries cannot change the first decision',
    () {
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final admissionGuard = source.indexOf(
        'FaceTime web admission retry skipped:',
      );
      final approvedGroup = source.indexOf(
        'var approvedGroup = chosenFTRoomGuid;',
        admissionGuard,
      );

      expect(source, contains('automaticRetry: retryCount > 0'));
      expect(admissionGuard, greaterThanOrEqualTo(0));
      expect(approvedGroup, greaterThan(admissionGuard));
      expect(source, contains('errorType=ambiguous_response'));
      expect(source, contains('FaceTime web admission response failed: "'));
      expect(
        source,
        contains(r'stage=dispatch errorType=${error.runtimeType}'),
      );
    },
  );

  test('ordinary FaceTime answer API cannot invoke manual replay', () {
    final nativeSource = File('rustpush/src/facetime.rs').readAsStringSync();
    final bridgeSource = File('rust/src/api/api.rs').readAsStringSync();
    final serviceSource = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();

    final ordinaryStart = nativeSource.indexOf('pub async fn respond_letmein(');
    final manualStart = nativeSource.indexOf(
      'pub async fn retry_letmein_manually(',
      ordinaryStart,
    );
    final internalStart = nativeSource.indexOf(
      'async fn respond_letmein_internal(',
      manualStart,
    );
    final ordinaryBody = nativeSource.substring(ordinaryStart, manualStart);
    final manualBody = nativeSource.substring(manualStart, internalStart);

    final bridgeStart = bridgeSource.indexOf('pub async fn answer_ft_request(');
    final bridgeEnd = bridgeSource.indexOf(
      'pub async fn decline_facetime(',
      bridgeStart,
    );
    final bridgeBody = bridgeSource.substring(bridgeStart, bridgeEnd);

    expect(ordinaryBody, contains('approved_group, false'));
    expect(ordinaryBody, isNot(contains('approved_group, true')));
    expect(manualBody, contains('approved_group, true'));
    expect(bridgeBody, contains('.respond_letmein('));
    expect(bridgeBody, isNot(contains('retry_letmein_manually')));
    expect(bridgeSource, contains('pub async fn retry_ft_request('));
    expect(serviceSource, isNot(contains('retryLetmeinManually')));
    expect(serviceSource, contains('retryFtRequest'));
    expect(
      RegExp(r'retry_letmein_manually\(').allMatches(nativeSource),
      hasLength(2),
    );
  });

  test('admission diagnostics record only secret-free APS state', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final helperStart = source.indexOf(
      'Future<void> _recordFaceTimeAdmissionTransport',
    );
    final helperEnd = source.indexOf('\n  bool authing', helperStart);
    final helper = source.substring(helperStart, helperEnd);

    expect(source, contains('_recordFaceTimeAdmissionTransport'));
    expect(
      source,
      contains('_recordFaceTimeAdmissionTransport("before-response")'),
    );
    expect(
      source,
      contains('_recordFaceTimeAdmissionTransport("after-response-failure")'),
    );
    expect(helper, contains(r'apsState=${status.state}'));
    expect(helper, contains(r'activePortPresent=${status.activePort != null}'));
    expect(
      helper,
      contains(r'retryWaitPresent=${status.retryWaitSeconds != null}'),
    );
    expect(helper, contains(r'errorPresent=${status.error != null}'));
    expect(helper, isNot(contains('status.error}')));
    expect(helper, contains(r'stage=$stage errorType=${error.runtimeType}'));
    expect(helper, isNot(contains('error: error')));
    expect(helper, isNot(contains('trace:')));
  });

  test(
    'FaceTime admission excludes bridge identities and missing sessions are typed',
    () {
      final nativeSource = File('rustpush/src/facetime.rs').readAsStringSync();
      final identitySource = File(
        'rustpush/src/ids/identity_manager.rs',
      ).readAsStringSync();

      expect(
        nativeSource,
        contains('get_participants_targets_excluding_bridge_devices'),
      );
      expect(identitySource, contains('get_sms_targets(handle, false)'));
      expect(identitySource, contains('get_sms_targets(handle, true)'));
      expect(identitySource, contains('cache_needs_refresh'));
      expect(identitySource, contains('return Err(PushError::BadMsg)'));
      expect(identitySource, contains('get_device_uuid()'));
      expect(
        nativeSource,
        contains('let snapshot = self.snapshot_session(approved).await?'),
      );
      expect(
        nativeSource,
        contains('self.reconcile_session(snapshot, session).await?'),
      );
      expect(nativeSource, contains('FaceTimeSessionNotFound'));
      expect(
        nativeSource,
        isNot(contains('expect("Approved session not found!")')),
      );
      expect(nativeSource, isNot(contains('expect("No session")')));
      expect(identitySource, contains('private_data.as_slice()'));
      expect(identitySource, contains('get("com.apple.madrid")'));
      expect(identitySource, contains('is_bridge_owned_push_token'));
    },
  );

  test(
    'FaceTime decline and cancel APIs do not await under the state lock',
    () {
      final nativeSource = File('rustpush/src/facetime.rs').readAsStringSync();
      final bridgeSource = File('rust/src/api/api.rs').readAsStringSync();

      final nativeDeclineStart = nativeSource.indexOf(
        'pub async fn decline_session(',
      );
      final nativeDeclineEnd = nativeSource.indexOf(
        'pub async fn unprop_conv(',
        nativeDeclineStart,
      );
      final nativeCancelStart = nativeSource.indexOf(
        'pub async fn cancel_session(',
      );
      final nativeCancelEnd = nativeSource.indexOf(
        'pub async fn add_members(',
        nativeCancelStart,
      );
      final nativeDecline = nativeSource.substring(
        nativeDeclineStart,
        nativeDeclineEnd,
      );
      final nativeCancel = nativeSource.substring(
        nativeCancelStart,
        nativeCancelEnd,
      );

      expect(nativeDecline, contains('operation_for_session(group_id).await'));
      expect(nativeDecline, contains('snapshot_session(group_id).await?'));
      expect(
        nativeDecline,
        contains('reconcile_session(snapshot, session).await?'),
      );
      expect(nativeDecline, isNot(contains('self.state.write()')));
      expect(nativeCancel, contains('operation_for_session(group_id).await'));
      expect(nativeCancel, contains('snapshot_session(group_id).await?'));
      expect(
        nativeCancel,
        contains('reconcile_session(snapshot, session).await?'),
      );
      expect(nativeCancel, isNot(contains('self.state.write()')));

      final bridgeDeclineStart = bridgeSource.indexOf(
        'pub async fn decline_facetime(',
      );
      final bridgeDeclineEnd = bridgeSource.indexOf(
        'pub async fn create_facetime(',
        bridgeDeclineStart,
      );
      final bridgeCancelStart = bridgeSource.indexOf(
        'pub async fn cancel_facetime(',
      );
      final bridgeCancelEnd = bridgeSource.indexOf(
        'pub async fn validate_targets_facetime(',
        bridgeCancelStart,
      );
      final bridgeDecline = bridgeSource.substring(
        bridgeDeclineStart,
        bridgeDeclineEnd,
      );
      final bridgeCancel = bridgeSource.substring(
        bridgeCancelStart,
        bridgeCancelEnd,
      );

      expect(bridgeDecline, contains('facetime.decline_session(&guid).await?'));
      expect(bridgeDecline, isNot(contains('state.write()')));
      expect(bridgeCancel, contains('facetime.cancel_session(&guid).await?'));
      expect(bridgeCancel, isNot(contains('state.write()')));
    },
  );

  test('ambiguous admission exposes only a bounded retained retry', () {
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final nativeBridge = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/MethodCallHandler.kt',
    ).readAsStringSync();

    expect(service, contains('_pendingFaceTimeAdmissionDelegations'));
    expect(service, contains('length > 4'));
    expect(service, contains('retryFtRequest'));
    expect(service, contains('facetime-admission-recovery-available'));
    expect(activity, contains('FaceTimeAdmissionRetryState'));
    expect(activity, contains('facetime-admission-retry'));
    expect(activity, contains('invokeMethodForBooleanResult'));
    expect(nativeBridge, contains('showAdmissionRecovery'));
  });

  test('outgoing timeout cannot clear a superseding call', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();

    expect(source, contains('_outgoingCallSetupInProgress'));
    expect(source, contains('currentOutgoingCallGuid'));
    expect(source, contains('!identical(currentOutgoingCall, callState)'));
    expect(
      source,
      contains('Ignoring stale FaceTime timeout for a superseded call'),
    );
    expect(
      source,
      contains('_clearOutgoingCall(facetime.guid, finalState: "ended")'),
    );
  });

  test('duplicate outgoing join events cannot relaunch the active call', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final handler = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeLaunchHandler.kt',
    ).readAsStringSync();

    expect(source, contains('if (chosenFTRoomGuid == facetime.guid)'));
    expect(source, contains('Ignoring duplicate FaceTime join event'));
    expect(handler, contains('activeCall?.callUuid == requestedCallUuid'));
    expect(handler, contains('ignored duplicate launch for active call'));

    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    expect(
      activity.indexOf('callUuid = launchExtras.getString("callUuid")'),
      lessThan(activity.indexOf('activeFaceTimeActivity = this')),
    );
  });

  test('joined FaceTime UI preserves a separate native end control', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final layout = File(
      'android/app/src/main/res/layout/activity_face_time.xml',
    ).readAsStringSync();

    expect(
      activity,
      contains('binding.nativeCallControls.visibility = View.VISIBLE'),
    );
    expect(
      layout,
      contains('android:layout_gravity="bottom|center_horizontal"'),
    );
    expect(layout, isNot(contains('android:layout_gravity="top|start"')));
  });

  test('media evidence reaches Android only after the Promise resolves', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final bridge = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeResolvedMediaBridge.kt',
    ).readAsStringSync();
    final cachedWebView = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt',
    ).readAsStringSync();

    expect(
      activity,
      contains('FaceTimeResolvedMediaBridge.requestScript(probeId)'),
    );
    expect(
      bridge,
      contains('Promise.resolve(window.__obFaceTimeDiagnostics.snapshot())'),
    );
    expect(bridge, contains('Native.mediaEvidence(String(probeId), payload)'));
    expect(
      cachedWebView,
      contains('fun mediaEvidence(probeId: String?, payload: String?)'),
    );
    expect(cachedWebView, isNot(contains('remoteParticipantCount: counts')));
  });

  test('web leave bridge is scoped to an explicit leave-button tap', () {
    final cachedWebView = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt',
    ).readAsStringSync();

    expect(
      cachedWebView,
      isNot(
        contains(
          '.replace("this.onLeave.notifyListeners()", "Native.leave(), this.onLeave.notifyListeners()")',
        ),
      ),
    );
    expect(
      cachedWebView,
      contains('document.addEventListener("click", (event) => {'),
    );
    expect(cachedWebView, contains('callcontrols-leave-button-session-banner'));
    expect(cachedWebView, contains('setTimeout(() => Native.leave(), 0)'));
  });

  test('programmatic FaceTime join can start remote media playback', () {
    final cachedWebView = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt',
    ).readAsStringSync();

    expect(cachedWebView, contains('mediaPlaybackRequiresUserGesture = false'));
  });

  test('media permission grants refresh foreground service types', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeInCallService.kt',
    ).readAsStringSync();

    expect(activity, contains('startOrRefreshService()'));
    expect(
      activity,
      contains('FaceTimeInCallService.ACTION_REFRESH_FOREGROUND_TYPES'),
    );
    expect(service, contains('override fun onStartCommand'));
    expect(service, contains('notifyForeground()'));
  });

  test('native local end clears only the matching outgoing call', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final channel = File(
      'lib/services/backend/java_dart_interop/method_channel_service.dart',
    ).readAsStringSync();
    final nativeBridge = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/MethodCallHandler.kt',
    ).readAsStringSync();
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();

    expect(activity, contains('"facetime-call-ended"'));
    expect(activity, contains('mapOf("callUuid" to endedCallUuid)'));
    expect(activity, contains('reportLocalCallEnded()'));
    expect(
      activity,
      contains('val isCurrentActivity = activeFaceTimeActivity === this'),
    );
    expect(activity, contains('invokeMethodOrWorker'));
    expect(nativeBridge, contains('DartWorkManager.createWorker'));
    expect(channel, contains('case "facetime-call-ended":'));
    expect(service, contains('if (currentOutgoingCallGuid != guid) return;'));
    expect(service, contains('_clearOutgoingCall(guid, finalState: "ended")'));
  });

  test('native call cache and timeout handling are call-specific', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final stateHandler = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeCallStateHandler.kt',
    ).readAsStringSync();

    expect(activity, contains('cachedCallUuid == requestedCallUuid'));
    expect(
      activity,
      contains('binding.nativeCallControls.visibility = View.VISIBLE'),
    );
    expect(
      stateHandler,
      contains('FaceTimeActivity.cachedCallUuid == callUuid'),
    );
    expect(
      stateHandler,
      contains(
        'shouldFinishFaceTimeActivity(state, it.isCall, it.answered, it.callUuid, callUuid)',
      ),
    );
    expect(stateHandler, contains('!answered'));
    expect(activity, contains('hasRequiredFaceTimeLaunchData'));
    expect(activity, contains('finishAndRemoveTask()'));

    final notification = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/notifications/CreateIncomingFaceTimeNotification.kt',
    ).readAsStringSync();
    expect(notification, contains('PendingIntent.FLAG_UPDATE_CURRENT'));
  });
}
