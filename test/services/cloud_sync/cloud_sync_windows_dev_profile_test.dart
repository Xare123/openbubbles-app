import 'dart:io';

import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  test('accepts the fixed profile across Windows package path virtualization', () {
    final root = Directory.systemTemp.createTempSync('ob-cloud-profile-');
    try {
      final environment = <String, String>{'APPDATA': root.path};
      final profile = CloudSyncWindowsDevProfile.expectedDirectory(
        environment: environment,
      )..createSync(recursive: true);
      File(path.join(profile.path, CloudSyncWindowsDevProfile.markerFileName))
          .writeAsStringSync(CloudSyncWindowsDevProfile.markerContents);

      expect(
        CloudSyncWindowsDevProfile.isExpectedDirectory(
          profile,
          environment: environment,
        ),
        isTrue,
      );
      expect(CloudSyncWindowsDevProfile.hasValidMarker(profile), isTrue);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('rejects a different lexical profile and an invalid marker', () {
    final root = Directory.systemTemp.createTempSync('ob-cloud-profile-');
    try {
      final environment = <String, String>{'APPDATA': root.path};
      final profile = CloudSyncWindowsDevProfile.expectedDirectory(
        environment: environment,
      )..createSync(recursive: true);
      final other = Directory(path.join(root.path, 'other'))
        ..createSync(recursive: true);
      File(path.join(profile.path, CloudSyncWindowsDevProfile.markerFileName))
          .writeAsStringSync('invalid');

      expect(
        CloudSyncWindowsDevProfile.isExpectedDirectory(
          other,
          environment: environment,
        ),
        isFalse,
      );
      expect(CloudSyncWindowsDevProfile.hasValidMarker(profile), isFalse);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
