// The test host uses the locked Windows plugin implementations directly so its
// real preferences engine and native support paths share the marked profile.
// No dependency or native-boundary change is needed for these test-only seams.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

abstract final class BackendHarnessWindowsStorage {
  /// Called by the guarded Windows test entry before settings or native startup.
  /// This never creates a profile, marker, setup flag, or account state.
  static Directory installMarkedProfile() {
    if (!Platform.isWindows ||
        !kDebugMode ||
        !BackendHarnessGate.compiledIn ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(BackendHarnessGate.source)) {
      throw StateError('backend_windows_storage_disabled');
    }
    final profile = CloudSyncWindowsDevProfile.requireBootstrapped();
    bindExistingDirectory(CloudSyncWindowsDevProfile.requireBootstrapped);
    fs.configureCloudSyncV2WindowsDevProfile();
    return profile;
  }

  /// The injected validator lets offline tests use only their own directories.
  /// The real entry above always supplies the existing fixed-profile guard.
  @visibleForTesting
  static void bindExistingDirectory(Directory Function() requireDirectory) {
    final provider = _ProfilePaths(requireDirectory);
    // Refuse an already-loaded preferences cache instead of transplanting or
    // resetting it. Normal backend startup must bind storage before getInstance.
    SharedPreferences.setPrefix('flutter.');
    final preferences = SharedPreferencesWindows()..pathProvider = provider;
    PathProviderPlatform.instance = provider;
    SharedPreferencesStorePlatform.instance = preferences;
  }
}

final class _ProfilePaths extends PathProviderWindows {
  _ProfilePaths(this.requireDirectory) {
    final directory = requireDirectory();
    expectedPath = path.normalize(directory.absolute.path);
    expectedResolved = path.normalize(directory.resolveSymbolicLinksSync());
    _profile();
  }

  final Directory Function() requireDirectory;
  late final String expectedPath;
  late final String expectedResolved;

  String _profile() {
    final directory = requireDirectory();
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        path.normalize(directory.absolute.path) != expectedPath ||
        path.normalize(directory.resolveSymbolicLinksSync()) !=
            expectedResolved) {
      throw StateError('backend_windows_storage_changed');
    }
    return expectedPath;
  }

  @override
  Future<String?> getApplicationSupportPath() async => _profile();

  @override
  Future<String?> getApplicationDocumentsPath() async => _profile();

  @override
  Future<String?> getApplicationCachePath() async =>
      path.join(_profile(), 'cache');

  @override
  Future<String?> getTemporaryPath() async => path.join(_profile(), 'tmp');

  @override
  Future<String?> getDownloadsPath() async =>
      path.join(_profile(), 'downloads');
}
