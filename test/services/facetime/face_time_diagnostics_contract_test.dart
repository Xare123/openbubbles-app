import 'dart:io';

import 'package:bluebubbles/services/rustpush/face_time_outgoing_lifecycle.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('setup diagnostics require both gates and format only bounded typed fields', () {
    for (final developer in [false, true]) {
      for (final enabled in [false, true]) {
        final line = faceTimeOutgoingSetupDiagnostic(1,
            FaceTimeOutgoingPhase.rejected, FaceTimeOutgoingPhase.link_before,
            developerEnabled: developer, diagnosticsEnabled: enabled);
        expect(line, developer && enabled
            ? 'facetime_setup attempt=1 event=rejected phase=link_before'
            : isNull);
      }
    }
    for (final event in FaceTimeOutgoingPhase.values) {
      for (final phase in FaceTimeOutgoingPhase.values) {
        final line = faceTimeOutgoingSetupDiagnostic(0x7fffffff, event, phase,
            developerEnabled: true, diagnosticsEnabled: true)!;
        expect(line.length, lessThan(160));
        expect(line, matches(r'^facetime_setup attempt=[0-9]+ event=[a-z_]+ phase=[a-z_]+$'));
      }
    }
    for (final invalid in [-1, 0, 0x80000000]) {
      expect(faceTimeOutgoingSetupDiagnostic(invalid,
          FaceTimeOutgoingPhase.started, FaceTimeOutgoingPhase.started,
          developerEnabled: true, diagnosticsEnabled: true), isNull);
    }
  });

  test('setup sender uses existing gated Dart logger without private fields', () {
    final source = File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final sender = source.substring(source.indexOf('void traceFaceTimeOutgoingSetup('),
        source.indexOf('String faceTimeOutgoingStartFailureMessage('));
    expect(sender, contains('ss.settings.developerEnabled.value'));
    expect(sender, contains('ss.settings.faceTimeDiagnosticsEnabled.value'));
    expect(sender, contains('if (line != null) Logger.info(line);'));
    expect(sender, contains('catch (_)'));
    for (final forbidden in ['error:', 'trace:', '.metadata', '.id', 'callUuid',
      '.handle', 'invokeMethod', 'api.', 'File(', 'Timer(', 'await ']) {
      expect(sender, isNot(contains(forbidden)));
    }
    expect(source, contains('diagnostic: traceFaceTimeOutgoingSetup,'));
  });

  test('setup observations bracket actual awaits including optional handles', () {
    final source = File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final start = source.indexOf('Future<void> placeOutgoingCall(');
    final setup = source.substring(start, source.indexOf('// returns handle to show poster of', start));
    for (final entry in {'link': 'getFtLink', 'handles': 'getHandles', 'create': 'createFacetime'}.entries) {
      final before = setup.indexOf('FaceTimeOutgoingPhase.${entry.key}_before');
      final request = setup.indexOf('await api.${entry.value}(');
      final after = setup.indexOf('FaceTimeOutgoingPhase.${entry.key}_after');
      expect(before, greaterThanOrEqualTo(0));
      expect(before, lessThan(request));
      expect(request, lessThan(after));
      expect(RegExp('await api\\.${entry.value}\\(').allMatches(setup), hasLength(1));
    }
    final optional = setup.substring(setup.indexOf('if (ss.settings.userName.value == "You")'),
        setup.indexOf('// A newer call'));
    expect(optional.indexOf('FaceTimeOutgoingPhase.handles_before'), lessThan(optional.indexOf('} else {')));
    expect(optional.indexOf('FaceTimeOutgoingPhase.handles_after'), lessThan(optional.indexOf('} else {')));
    expect(setup, isNot(contains('await _outgoingCalls.observe')));
    final lifecycle = File('lib/services/rustpush/face_time_outgoing_lifecycle.dart').readAsStringSync();
    expect(lifecycle.indexOf('observe(call, FaceTimeOutgoingPhase.timer_before)'),
        lessThan(lifecycle.indexOf('call._timer = _schedule(')));
    expect(lifecycle.indexOf('observe(call, FaceTimeOutgoingPhase.timer_armed)'),
        greaterThan(lifecycle.indexOf('call._timer = _schedule(')));
  });

  test('remote leave diagnostics observe refresh without controlling it', () {
    final source = File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final dispatch = source.substring(
      source.indexOf('if (push is api.PushMessage_FaceTime) {'),
      source.indexOf('String? ring;', source.indexOf('if (push is api.PushMessage_FaceTime) {')),
    );
    final refresh = dispatch.indexOf('await updateState();');
    expect(dispatch.indexOf("unawaited(_traceFaceTimeRemoteLeave(facetime.guid, 'received'))"), lessThan(refresh));
    expect(dispatch.indexOf("unawaited(_traceFaceTimeRemoteLeave(facetime.guid, 'refreshed'))"), greaterThan(refresh));
    expect(dispatch, contains("unawaited(_traceFaceTimeRemoteLeave(facetime.guid, 'refresh_failed'))"));
    expect(dispatch, contains('rethrow;'));
    expect(RegExp(r'await updateState\(\);').allMatches(dispatch), hasLength(1));
    expect(dispatch, isNot(contains('await _traceFaceTimeRemoteLeave')));
  });

  test('remote leave sender is gated redacted and has finite in-flight work', () {
    final source = File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final sender = source.substring(source.indexOf('Future<void> _traceFaceTimeRemoteLeave('),
        source.indexOf('RxList<api.FTSession> sessions'));
    expect(sender, contains('!Platform.isAndroid'));
    expect(sender, contains('!ss.settings.developerEnabled.value'));
    expect(sender, contains('!ss.settings.faceTimeDiagnosticsEnabled.value'));
    expect(sender, contains("const {'received', 'refreshed', 'refresh_failed'}.contains(phase)"));
    expect(sender, contains('_faceTimeLeaveDiagnosticsInFlight.add(phase)'));
    expect(sender, contains('if (!claimed) return;'));
    expect(sender, contains('_faceTimeLeaveDiagnosticsInFlight.remove(phase)'));
    expect(sender, contains('catch (_)'));
    expect(sender, contains("mcs.channel.invokeMethod<void>('update-call-state'"));
    expect(sender, contains("'state': 'remote_leave_diagnostic'"));
    expect(sender, contains('activeSessions.firstWhereOrNull'));
    expect(sender, contains('sessions.firstWhereOrNull'));
    for (final forbidden in ['Logger.', '.handle', '.token', '.participantId', 'api.', 'hideFaceTimeOverlay(', 'endCall(']) {
      expect(sender, isNot(contains(forbidden)));
    }
  });

  test('native remote leave branch is diagnostics only and returns early', () {
    final source = File('android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeCallStateHandler.kt').readAsStringSync();
    final diagnostic = source.substring(source.indexOf('if (state == "remote_leave_diagnostic")'),
        source.indexOf('if (state == "ringing")'));
    expect(diagnostic, contains('FaceTimeDiagnostics.isEnabled(context)'));
    expect(diagnostic, contains('FaceTimeDiagnosticStage.REMOTE_LEAVE'));
    expect(diagnostic, contains('FaceTimeRemoteLeaveEvidence.fromArguments('));
    expect(diagnostic, contains('result.success(null)'));
    expect(diagnostic, contains('return'));
    expect(diagnostic, contains('catch (_: Exception)'));
    for (final forbidden in ['finishAndRemoveTask', '.destroy(', 'cancelCallbacks', 'endCall(', 'Log.', 'CLOSE_REASON']) {
      expect(diagnostic, isNot(contains(forbidden)));
    }
  });

  test('timeouts are scoped to the activity and cached page call IDs', () {
    final handler = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeCallStateHandler.kt',
    ).readAsStringSync();
    final timeout = handler.substring(handler.indexOf('} else if (state == "timeout")'));
    expect(timeout, contains('val callUuid = call.argument<String>("callUuid")'));
    expect(timeout, contains('FaceTimeTimeoutPolicy.shouldFinishActivity(callUuid, it.callUuid, it.answered, it.isCall)'));
    expect(timeout, contains('cachedWebview?.takeIf { it.matchesCallId(callUuid) }?.let'));
    expect(timeout, contains('it.cancelCallbacks()'));
    expect(timeout, contains('it.webView.destroy()'));
    expect(timeout, contains('FaceTimeActivity.cachedWebview = null'));

    final cached = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt',
    ).readAsStringSync();
    expect(cached, contains('internal fun matchesCallId(callId: String?): Boolean ='));
    expect(cached, contains('FaceTimeTimeoutPolicy.matchesCall(callId, sessionId)'));
  });

  test('PiP and probe updates share one native visibility and footer owner', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final positionStart = activity.indexOf('private fun positionNativeEndControl(');
    final showStart = activity.indexOf('private fun showCallUi(');
    final probeStart = activity.indexOf('private fun scheduleConnectionProbe(');
    final position = activity.substring(positionStart, showStart);
    expect(position, contains('inPictureInPicture: Boolean = isInPictureInPictureMode'));
    expect(position, contains('FaceTimeControlPolicy.shouldShowNativeEndControl(inPictureInPicture)'));
    expect(position, contains('inPictureInPicture = inPictureInPicture'));
    expect(position, contains('FaceTimeViewerLayout.padding('));
    expect(position, contains('WindowInsetsCompat.Type.ime()'));
    expect(position, contains('binding.connectionStatus.visibility == View.VISIBLE'));
    final layout = File('android/app/src/main/res/layout/activity_face_time.xml').readAsStringSync();
    expect(layout, contains('android:id="@+id/viewerSurface"'));
    expect(layout, contains('android:layout_weight="1"'));
    expect(RegExp(r'binding\.nativeCallControls\.visibility\s*=(?!=)').allMatches(activity), hasLength(1));
    expect(activity.substring(showStart, probeStart), contains('positionNativeEndControl()'));
    final pipStart = activity.indexOf('override fun onPictureInPictureModeChanged(');
    final pipEnd = activity.indexOf('private fun decline()', pipStart);
    expect(activity.substring(pipStart, pipEnd), contains(
      'positionNativeEndControl(inPictureInPicture = isInPictureInPictureMode)',
    ));
    expect(activity, contains('.setActions(listOf('));
    expect(activity, contains('RemoteAction('));
    expect(activity, contains('"End this FaceTime Call"'));
    expect(activity, contains('FaceTimeActionReceiver::class.java'));
  });

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
    expect(source, contains('FaceTimeDiagnosticPolicy.shouldEnable'));
    final policy = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeDiagnosticLog.kt',
    ).readAsStringSync();
    expect(policy, contains('developerModeEnabled && diagnosticsEnabled'));
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

    final joinStart = activity.indexOf('private fun attemptJoin(');
    final joinEnd = activity.indexOf('fun endCall()', joinStart);
    final endStart = joinEnd;
    final endEnd = activity.indexOf(
      'private fun hideControlsForPIP()',
      endStart,
    );

    expect(joinStart, greaterThanOrEqualTo(0));
    expect(joinEnd, greaterThan(joinStart));
    expect(endEnd, greaterThan(endStart));
    expect(
      activity.substring(joinStart, joinEnd),
      contains('webView.evaluateJavascript(joinButtonScript)'),
    );
    expect(
      activity.substring(endStart, endEnd),
      contains('webView.evaluateJavascript('),
    );
    expect(cachedWebview, contains('message=<omitted>'));
    expect(cachedWebview, isNot(contains('consoleMessage.message()')));
  });

  test('outgoing calls enter the same automatic admission loop', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();
    final start = activity.indexOf('private fun startOutgoingCall()');
    final end = activity.indexOf('override fun onCreate', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final outgoingPath = activity.substring(start, end);
    expect(outgoingPath, contains('answered = true'));
    expect(outgoingPath, contains('scheduleJoinAttempt("outgoing-ready")'));

    final configStart = activity.indexOf('private fun handleConfig(');
    final configEnd = activity.indexOf(
      'private fun parseMediaEvidence',
      configStart,
    );
    expect(
      activity.substring(configStart, configEnd),
      contains('startOutgoingCall()'),
    );
  });

  test('FaceTime WebView preserves session state and permits admitted media', () {
    final cachedWebview = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/CachedWebview.kt',
    ).readAsStringSync();

    expect(cachedWebview, contains('domStorageEnabled = true'));
    expect(
      cachedWebview,
      contains('mediaPlaybackRequiresUserGesture = false'),
    );
  });

  test('WebView media permissions are granted through the activity policy', () {
    final activity = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/services/facetime/FaceTimeActivity.kt',
    ).readAsStringSync();

    expect(activity, contains('PermissionRequest.RESOURCE_VIDEO_CAPTURE'));
    expect(activity, contains('PermissionRequest.RESOURCE_AUDIO_CAPTURE'));
    expect(activity, contains('request.grant(request.resources)'));
    expect(activity, contains('FaceTimePermissionPolicy.isGranted'));
    expect(
      activity,
      contains('FaceTimePermissionPolicy.shouldStartInCallService'),
    );
  });
}
