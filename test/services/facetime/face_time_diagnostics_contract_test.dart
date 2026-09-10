import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(position, contains('bottomMargin = reserved'));
    expect(RegExp(r'binding\.nativeCallControls\.visibility\s*=').allMatches(activity), hasLength(1));
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
