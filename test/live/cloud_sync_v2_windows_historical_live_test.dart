import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart' as harness;
import 'package:bluebubbles/cloud_sync_v2_windows_historical_import.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// Dart-only historical-import entry against a verified local-write harness
/// bundle: Dart executes from source while the native library comes from
/// OPENBUBBLES_TEST_NATIVE_LIBRARY. Without explicit enablement this file
/// passes inert and touches nothing: no profile, store, account, upload,
/// send, or CloudKit access of any kind.
void main() {
  final enabled =
      Platform.environment['OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS'] == '1';
  final operation =
      Platform.environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] ??
      'view-projection';
  final launchId = Platform.environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'];
  final timeoutSeconds =
      int.tryParse(
        Platform.environment['OPENBUBBLES_HISTORICAL_IMPORT_TIMEOUT_SECONDS'] ??
            '',
      ) ??
      600;
  var rustInitialized = false;
  var databaseOpen = false;
  CloudSyncWindowsHistoricalRequest? request;

  setUpAll(() async {
    if (!enabled || operation != 'historical-import') return;
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (_) async => <String, Object?>{
            'appName': 'OpenBubbles Cloud Sync V2 Test Host',
            'packageName': 'com.bluebubbles.cloudsync.testhost',
            'version': '0.0.0',
            'buildNumber': '0',
            'buildSignature': '',
            'installerStore': null,
          },
        );
    if (launchId == null ||
        !harness.CloudSyncV2WindowsHarnessLaunch.isValidLaunchId(launchId)) {
      throw StateError('OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID is required');
    }
    final nativeLibrary =
        Platform.environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'];
    if (nativeLibrary == null) {
      throw StateError('OPENBUBBLES_TEST_NATIVE_LIBRARY is required');
    }
    harness.configureCloudSyncV2WindowsHarnessTestLaunch(launchId);
    fs.configureCloudSyncV2WindowsDevProfile();
    final profile = CloudSyncWindowsDevProfile.requireBootstrapped();
    final bytes = await File(
      path.join(profile.path, CloudSyncWindowsHistoricalRequest.fileName),
    ).openRead(0, 16385).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final expectedHash =
        Platform.environment['OPENBUBBLES_HISTORICAL_IMPORT_REQUEST_SHA256'];
    if (bytes.isEmpty ||
        bytes.length > 16384 ||
        expectedHash == null ||
        sha256.convert(bytes).toString() != expectedHash) {
      throw StateError('cloud_sync_windows_historical_request_changed');
    }
    request = CloudSyncWindowsHistoricalRequest.parse(
      jsonDecode(utf8.decode(bytes)),
    );
    await RustLib.init(externalLibrary: ExternalLibrary.open(nativeLibrary));
    rustInitialized = true;
    await fs.init(headless: true);
    await Logger.init();
    await api.doFirstTimeInit(path: fs.appDocDir.path);
    await Database.init(cloudSyncV2Harness: true);
    databaseOpen = true;
  });

  tearDownAll(() {
    if (databaseOpen && !Database.store.isClosed()) Database.store.close();
    if (rustInitialized) RustLib.dispose();
  });

  test('historical import stays inert without explicit live enablement', () {
    if (enabled && operation == 'historical-import') {
      expect(launchId, isNotNull);
      return;
    }
    expect(true, isTrue);
  });

  testWidgets(
    'isolated profile executes one historical import pass',
    (tester) async {
      if (!enabled || operation != 'historical-import') return;
      final harnessKey = GlobalKey<harness.CloudSyncV2WindowsHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: harness.CloudSyncV2WindowsHarness(
            key: harnessKey,
            autoStart: false,
            operation:
                harness.CloudSyncV2WindowsHarnessOperation.historicalImport,
          ),
        ),
      );
      await tester.runAsync(
        () => harnessKey.currentState!.initializeForTestHost(),
      );
      final profile = CloudSyncWindowsDevProfile.requireBootstrapped();
      final statusFile = File(
        path.join(profile.path, 'cloud-sync-v2', 'windows-harness-status.json'),
      );
      final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
      Map<String, Object?> status = {};
      while (DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        if (!statusFile.existsSync()) continue;
        final decoded = jsonDecode(statusFile.readAsStringSync());
        if (decoded is! Map<String, dynamic>) continue;
        status = decoded.cast<String, Object?>();
        if (status['launch_id'] != launchId) continue;
        if (status['state'] == 'failed') {
          throw StateError('cloud_sync_windows_historical_operation_failed');
        }
        if (status['state'] == 'finished' &&
            status['stage'] == 'historical-import-pass-complete') {
          break;
        }
      }
      // A deadline expiry fails here without deleting any queue, report,
      // profile, or evidence: cleanup of other runs is never this test's job.
      expect(status['launch_id'], launchId);
      expect(status['state'], 'finished');
      expect(status['stage'], 'historical-import-pass-complete');
      final detail = status['detail'];
      expect(detail, isA<String>());
      final report = (jsonDecode(detail as String) as Map<String, dynamic>)
          .cast<String, Object?>();
      for (final key in [
        'action',
        'snapshot_sha256',
        'phase',
        'scan_complete',
        'confirmed_creates_this_session',
      ]) {
        expect(report.containsKey(key), isTrue, reason: key);
      }
      expect(report['action'], request!.execute ? 'archive' : 'preview');
      expect(report['scan_complete'], isA<bool>());
      expect(
        report['confirmed_creates_this_session'],
        inInclusiveRange(0, request!.execute ? request!.maximumCreates : 0),
      );
      if (request!.execute) {
        expect(report['snapshot_sha256'], request!.snapshotSha256);
      }
      debugPrint(
        'windows_historical_live action=${report['action']} '
        'phase=${report['phase']} scan_complete=${report['scan_complete']} '
        'confirmed=${report['confirmed_creates_this_session']}',
      );
    },
    skip: !enabled || operation != 'historical-import',
    timeout: Timeout(Duration(seconds: timeoutSeconds + 30)),
  );
}
