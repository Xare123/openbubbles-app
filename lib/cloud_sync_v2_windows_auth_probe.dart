import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;

const String cloudSyncV2WindowsAuthProbeStatusVersion =
    'cloud-sync-v2-windows-auth-probe-status-v1';
const String cloudSyncV2WindowsAuthProbeStatusFileName =
    'cloud-sync-v2-windows-auth-probe-status.json';

final class CloudSyncV2WindowsAuthProbeLaunch {
  const CloudSyncV2WindowsAuthProbeLaunch({required this.launchId});

  static const String launchIdArgumentPrefix = '--launch-id=';
  static final RegExp _launchIdPattern = RegExp(r'^[a-f0-9]{32}$');

  final String launchId;

  static CloudSyncV2WindowsAuthProbeLaunch parse(List<String> arguments) {
    if (arguments.length != 1 ||
        !arguments.single.startsWith(launchIdArgumentPrefix)) {
      throw StateError('cloud_sync_windows_auth_probe_launch_invalid');
    }
    final launchId = arguments.single.substring(launchIdArgumentPrefix.length);
    if (!_launchIdPattern.hasMatch(launchId)) {
      throw StateError('cloud_sync_windows_auth_probe_launch_invalid');
    }
    return CloudSyncV2WindowsAuthProbeLaunch(launchId: launchId);
  }
}

enum CloudSyncV2WindowsAuthProbeOutcome {
  admitted,
  twoFactorRequired,
  rejected,
}

CloudSyncV2WindowsAuthProbeOutcome cloudSyncV2WindowsAuthProbeOutcome(
  api.LoginState state,
) {
  if (state is api.LoginState_LoggedIn) {
    return CloudSyncV2WindowsAuthProbeOutcome.admitted;
  }
  if (state is api.LoginState_NeedsSMS2FA ||
      state is api.LoginState_NeedsDevice2FA ||
      state is api.LoginState_NeedsSMS2FAVerification) {
    return CloudSyncV2WindowsAuthProbeOutcome.twoFactorRequired;
  }
  return CloudSyncV2WindowsAuthProbeOutcome.rejected;
}

const Set<String> _allowedProbeStates = <String>{
  'initializing',
  'running',
  'finished',
  'challenge-required',
  'failed',
};
const Set<String> _allowedProbeStages = <String>{
  'process-entry',
  'binding-ready',
  'profile-compile-gate',
  'profile-directory-check',
  'profile-canonical-check',
  'profile-marker-check',
  'profile-preflight-ready',
  'filesystem-service-configure',
  'profile-configured',
  'rust-ready',
  'probe-profile-prepared',
  'hardware-restore',
  'hardware-restored',
  'aps-setup',
  'aps-ready',
  'anisette-setup',
  'anisette-ready',
  'auth-login',
  'auth-admitted',
  'auth-two-factor-required',
  'auth-rejected',
};
const Set<String> _allowedProbeSafeCodes = <String>{
  'none',
  'cloud_sync_windows_auth_probe_profile_failed',
  'cloud_sync_windows_auth_probe_hardware_failed',
  'cloud_sync_windows_auth_probe_aps_failed',
  'cloud_sync_windows_auth_probe_anisette_failed',
  'cloud_sync_windows_auth_probe_login_failed',
  'cloud_sync_windows_auth_probe_two_factor_required',
  'cloud_sync_windows_auth_probe_state_rejected',
  'cloud_sync_windows_auth_probe_status_failed',
};

Map<String, Object?> cloudSyncV2WindowsAuthProbeStatusPayload({
  required String launchId,
  required int processId,
  required String state,
  required String stage,
  required String safeCode,
  required DateTime updatedUtc,
}) {
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(launchId) ||
      processId <= 0 ||
      !_allowedProbeStates.contains(state) ||
      !_allowedProbeStages.contains(stage) ||
      !_allowedProbeSafeCodes.contains(safeCode)) {
    throw StateError('cloud_sync_windows_auth_probe_status_invalid');
  }
  return <String, Object?>{
    'version': cloudSyncV2WindowsAuthProbeStatusVersion,
    'launch_id': launchId,
    'process_id': processId,
    'state': state,
    'stage': stage,
    'safe_code': safeCode,
    'updated_utc': updatedUtc.toUtc().toIso8601String(),
  };
}

String cloudSyncV2WindowsAuthProbeSafeCode(String stage) {
  switch (stage) {
    case 'process-entry':
    case 'binding-ready':
    case 'profile-compile-gate':
    case 'profile-directory-check':
    case 'profile-canonical-check':
    case 'profile-marker-check':
    case 'profile-preflight-ready':
    case 'filesystem-service-configure':
    case 'profile-configured':
    case 'rust-ready':
    case 'probe-profile-prepared':
      return 'cloud_sync_windows_auth_probe_profile_failed';
    case 'hardware-restore':
    case 'hardware-restored':
      return 'cloud_sync_windows_auth_probe_hardware_failed';
    case 'aps-setup':
    case 'aps-ready':
      return 'cloud_sync_windows_auth_probe_aps_failed';
    case 'anisette-setup':
    case 'anisette-ready':
      return 'cloud_sync_windows_auth_probe_anisette_failed';
    case 'auth-login':
      return 'cloud_sync_windows_auth_probe_login_failed';
    case 'auth-admitted':
    case 'auth-two-factor-required':
    case 'auth-rejected':
      return 'cloud_sync_windows_auth_probe_status_failed';
    default:
      return 'cloud_sync_windows_auth_probe_profile_failed';
  }
}

File cloudSyncV2WindowsAuthProbeStatusFile({
  Map<String, String>? environment,
}) {
  final profile = CloudSyncWindowsDevProfile.expectedDirectory(
    environment: environment,
  );
  return File(
    path.join(profile.path, cloudSyncV2WindowsAuthProbeStatusFileName),
  );
}

void _writeProbeStatus({
  required File statusFile,
  required String launchId,
  required String state,
  required String stage,
  required String safeCode,
}) {
  final payload = jsonEncode(
    cloudSyncV2WindowsAuthProbeStatusPayload(
      launchId: launchId,
      processId: pid,
      state: state,
      stage: stage,
      safeCode: safeCode,
      updatedUtc: DateTime.now().toUtc(),
    ),
  );
  final temporaryStatusFile = File('${statusFile.path}.tmp.$pid');
  try {
    temporaryStatusFile.writeAsStringSync(payload, flush: true);
    temporaryStatusFile.renameSync(statusFile.path);
  } finally {
    if (temporaryStatusFile.existsSync()) {
      temporaryStatusFile.deleteSync();
    }
  }
}

Future<void> main(List<String> arguments) async {
  final launch = CloudSyncV2WindowsAuthProbeLaunch.parse(arguments);
  final statusFile = cloudSyncV2WindowsAuthProbeStatusFile();
  var stage = 'process-entry';
  _writeProbeStatus(
    statusFile: statusFile,
    launchId: launch.launchId,
    state: 'initializing',
    stage: stage,
    safeCode: 'none',
  );

  try {
    WidgetsFlutterBinding.ensureInitialized();
    stage = 'binding-ready';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );

    final profile = CloudSyncWindowsDevProfile.expectedDirectory();
    stage = 'profile-compile-gate';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );
    if (!CloudSyncWindowsDevProfile.compileEnabled) {
      throw StateError('cloud_sync_windows_dev_profile_disabled');
    }

    stage = 'profile-directory-check';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );
    if (!profile.existsSync()) {
      throw StateError('cloud_sync_windows_dev_profile_not_bootstrapped');
    }

    stage = 'profile-canonical-check';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );
    if (!CloudSyncWindowsDevProfile.isExpectedDirectory(profile)) {
      throw StateError('cloud_sync_windows_dev_profile_not_bootstrapped');
    }

    stage = 'profile-marker-check';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );
    if (!CloudSyncWindowsDevProfile.hasValidMarker(profile)) {
      throw StateError('cloud_sync_windows_dev_profile_not_bootstrapped');
    }

    stage = 'profile-preflight-ready';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );
    stage = 'filesystem-service-configure';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );
    fs.configureCloudSyncV2WindowsDevProfile();
    stage = 'profile-configured';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );

    await RustLib.init();
    stage = 'rust-ready';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );

    api.prepareCloudSyncWindowsAuthProbe(path: fs.appDocDir.path);
    stage = 'probe-profile-prepared';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );

    stage = 'hardware-restore';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );
    final hardware = api.readHardware(path: fs.appDocDir.path);
    if (hardware == null) {
      throw StateError('cloud_sync_windows_auth_probe_hardware_failed');
    }
    final identity = api.decodeIdentity(identity: hardware.identity);
    final config = hardware.osConfig;
    stage = 'hardware-restored';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'initializing',
      stage: stage,
      safeCode: 'none',
    );

    stage = 'aps-setup';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'running',
      stage: stage,
      safeCode: 'none',
    );
    final pushSetup = await api.setupPush(
      config: config,
      identity: identity,
      state: hardware.push,
      statePath: fs.appDocDir.path,
    );
    if (pushSetup.$2 != null) {
      throw StateError('cloud_sync_windows_auth_probe_aps_failed');
    }
    final connection = pushSetup.$1;
    stage = 'aps-ready';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'running',
      stage: stage,
      safeCode: 'none',
    );

    stage = 'anisette-setup';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'running',
      stage: stage,
      safeCode: 'none',
    );
    final anisette = await api.makeAnisette(
      path: fs.appDocDir.path,
      config: config,
      conn: connection,
    );
    stage = 'anisette-ready';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'running',
      stage: stage,
      safeCode: 'none',
    );

    stage = 'auth-login';
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'running',
      stage: stage,
      safeCode: 'none',
    );
    final result = await api.tryAuth(
      path: fs.appDocDir.path,
      conf: config,
      conn: connection,
      anisette: anisette,
    );
    final outcome = cloudSyncV2WindowsAuthProbeOutcome(result.$2);
    late final String terminalState;
    late final String terminalSafeCode;
    late final int terminalExitCode;
    switch (outcome) {
      case CloudSyncV2WindowsAuthProbeOutcome.admitted:
        stage = 'auth-admitted';
        terminalState = 'finished';
        terminalSafeCode = 'none';
        terminalExitCode = 0;
        break;
      case CloudSyncV2WindowsAuthProbeOutcome.twoFactorRequired:
        stage = 'auth-two-factor-required';
        terminalState = 'challenge-required';
        terminalSafeCode = 'cloud_sync_windows_auth_probe_two_factor_required';
        terminalExitCode = 3;
        break;
      case CloudSyncV2WindowsAuthProbeOutcome.rejected:
        stage = 'auth-rejected';
        terminalState = 'failed';
        terminalSafeCode = 'cloud_sync_windows_auth_probe_state_rejected';
        terminalExitCode = 2;
        break;
    }
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: terminalState,
      stage: stage,
      safeCode: terminalSafeCode,
    );
    exit(terminalExitCode);
  } catch (_) {
    _writeProbeStatus(
      statusFile: statusFile,
      launchId: launch.launchId,
      state: 'failed',
      stage: stage,
      safeCode: cloudSyncV2WindowsAuthProbeSafeCode(stage),
    );
    exit(1);
  }
}
