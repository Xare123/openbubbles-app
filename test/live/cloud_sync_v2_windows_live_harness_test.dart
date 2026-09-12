import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart' as harness;
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  final enabled =
      Platform.environment['OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS'] == '1';
  final operation =
      Platform.environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] ??
      'view-projection';
  final launchId = Platform.environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'];
  var rustInitialized = false;
  var databaseOpen = false;

  setUpAll(() async {
    if (!enabled) return;
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
    await RustLib.init(externalLibrary: ExternalLibrary.open(nativeLibrary));
    rustInitialized = true;
    await fs.init(headless: true);
    await Logger.init();
    api.doFirstTimeInit(path: fs.appDocDir.path);
    await Database.init(cloudSyncV2Harness: true);
    databaseOpen = true;
  });

  tearDownAll(() {
    if (databaseOpen && !Database.store.isClosed()) Database.store.close();
    if (rustInitialized) RustLib.dispose();
  });

  testWidgets(
    'isolated Windows profile executes one explicit harness operation',
    (tester) async {
      const allowedOperations = <String>{
        'view-projection',
        'run-once',
        'drain',
        'local-write',
        'probe-message-feed',
      };
      expect(operation, isIn(allowedOperations));
      final harnessKey = GlobalKey<harness.CloudSyncV2WindowsHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: harness.CloudSyncV2WindowsHarness(
            key: harnessKey,
            autoStart: false,
            operation: harness.CloudSyncV2WindowsHarnessOperation.values
                .singleWhere(
                  (candidate) => switch (operation) {
                    'view-projection' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .projectionViewer,
                    'run-once' =>
                      candidate ==
                          harness.CloudSyncV2WindowsHarnessOperation.runOnce,
                    'drain' =>
                      candidate ==
                          harness.CloudSyncV2WindowsHarnessOperation.drain,
                    'local-write' =>
                      candidate ==
                          harness.CloudSyncV2WindowsHarnessOperation.localWrite,
                    'probe-message-feed' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .messageFeedProbe,
                    _ => false,
                  },
                ),
          ),
        ),
      );
      await tester.runAsync(
        () => harnessKey.currentState!.initializeForTestHost(),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );

      final profile = CloudSyncWindowsDevProfile.requireBootstrapped();
      final statusFile = File(
        path.join(profile.path, 'cloud-sync-v2', 'windows-harness-status.json'),
      );
      expect(statusFile.existsSync(), isTrue);
      final decoded = jsonDecode(statusFile.readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      final status = (decoded as Map<String, dynamic>).cast<String, Object?>();
      expect(status['launch_id'], launchId);
      expect(
        status['state'],
        anyOf('finished', 'ready'),
        reason: jsonEncode(status),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
