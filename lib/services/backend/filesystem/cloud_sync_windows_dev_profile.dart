import 'dart:io';

import 'package:path/path.dart' as path;

/// Fixed, private Windows profile for the Cloud Sync V2 development harness.
///
/// The harness never accepts an arbitrary profile path. Its compile-time gate,
/// exact directory, and commit marker must all agree before startup.
abstract final class CloudSyncWindowsDevProfile {
  static const bool compileEnabled = bool.fromEnvironment(
    'OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_DEV_PROFILE',
    defaultValue: false,
  );

  static const String directoryName = 'cloudkit-v2-dev';
  static const String markerFileName = '.openbubbles-cloud-sync-v2-windows-dev';
  static const String markerContents =
      'openbubbles-cloud-sync-v2-windows-dev-profile:v1';

  static Directory expectedDirectory({Map<String, String>? environment}) {
    final appData = (environment ?? Platform.environment)['APPDATA']?.trim();
    if (appData == null || appData.isEmpty || !path.isAbsolute(appData)) {
      throw StateError('cloud_sync_windows_dev_appdata_unavailable');
    }
    return Directory(
      path.normalize(path.join(appData, 'OpenBubbles', directoryName)),
    ).absolute;
  }

  static bool isExpectedDirectory(
    Directory directory, {
    Map<String, String>? environment,
  }) {
    final expected = path.normalize(
      expectedDirectory(environment: environment).absolute.path,
    );
    final candidate = path.normalize(directory.absolute.path);
    if (expected.toLowerCase() != candidate.toLowerCase()) return false;
    try {
      final resolved = path.normalize(directory.resolveSymbolicLinksSync());
      return expected.toLowerCase() == resolved.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  static bool hasValidMarker(Directory directory) {
    try {
      final marker = File(path.join(directory.path, markerFileName));
      final expectedMarker = path.normalize(marker.absolute.path);
      final resolvedMarker = path.normalize(marker.resolveSymbolicLinksSync());
      return marker.existsSync() &&
          expectedMarker.toLowerCase() == resolvedMarker.toLowerCase() &&
          marker.readAsStringSync() == markerContents;
    } catch (_) {
      return false;
    }
  }

  static Directory requireBootstrapped({Map<String, String>? environment}) {
    if (!compileEnabled) {
      throw StateError('cloud_sync_windows_dev_profile_disabled');
    }
    final directory = expectedDirectory(environment: environment);
    if (!directory.existsSync() ||
        !isExpectedDirectory(directory, environment: environment) ||
        !hasValidMarker(directory)) {
      throw StateError('cloud_sync_windows_dev_profile_not_bootstrapped');
    }
    return directory;
  }
}
