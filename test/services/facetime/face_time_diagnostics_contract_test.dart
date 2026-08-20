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
      contains('scheduleJoinAttempt("answer-ready")'),
    );
    expect(activity, contains('callcontrols-join-button-session-banner'));
    expect(
      activity.substring(endStart, endEnd),
      contains('webView.evaluateJavascript('),
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
    expect(activity, contains('invokeMethodOrWorker'));
    expect(nativeBridge, contains('DartWorkManager.createWorker'));
    expect(channel, contains('case "facetime-call-ended":'));
    expect(service, contains('if (currentOutgoingCallGuid != guid) return;'));
    expect(service, contains('_clearOutgoingCall(guid, finalState: "ended")'));
  });

  test('native call cache and connecting UI are call-specific', () {
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
  });
}
