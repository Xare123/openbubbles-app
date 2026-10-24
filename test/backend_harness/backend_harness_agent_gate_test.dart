import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new backend package requires the explicit debug build flag', () {
    const compiled = bool.fromEnvironment('OPENBUBBLES_AGENT_BACKEND');
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: true,
        packageName: CloudSyncDevGate.androidBackendTestPackageName,
      ),
      compiled && kDebugMode,
    );
    expect(
      BackendHarnessGate.allowed(
        compiled: compiled,
        debug: kDebugMode,
        platform: 'android',
        package: CloudSyncDevGate.androidBackendTestPackageName,
      ),
      compiled && kDebugMode,
    );
  });

  test(
    'backend startup routing requires exact package or isolated Windows profile',
    () {
      const compiled = bool.fromEnvironment('OPENBUBBLES_AGENT_BACKEND');
      bool allowed(
        String package, {
        bool android = true,
        bool isolated = false,
      }) => CloudSyncDevGate.isAgentBackendRuntime(
        isAndroid: android,
        isWindows: !android,
        packageName: package,
        isolatedWindowsProfile: isolated,
      );
      expect(
        allowed(CloudSyncDevGate.androidBackendTestPackageName),
        compiled && kDebugMode,
      );
      expect(allowed(CloudSyncDevGate.androidCanaryPackageName), isFalse);
      expect(allowed('com.bluebubbles.messaging.alpha'), isFalse);
      expect(allowed('windows', android: false), isFalse);
      expect(
        allowed('windows', android: false, isolated: true),
        compiled && kDebugMode,
      );
    },
  );

  test('agent command mode does not enable personal or release packages', () {
    for (final package in [
      'com.openbubbles.messaging',
      'com.bluebubbles.messaging.alpha',
      'com.bluebubbles.messaging.beta',
      CloudSyncDevGate.androidCanaryPackageName,
    ]) {
      expect(
        BackendHarnessGate.allowed(
          compiled: true,
          debug: true,
          platform: 'android',
          package: package,
        ),
        false,
      );
    }
    expect(
      BackendHarnessGate.allowed(
        compiled: true,
        debug: false,
        platform: 'android',
        package: CloudSyncDevGate.androidBackendTestPackageName,
      ),
      false,
    );
    // The existing Canary qualification feature gate remains unchanged.
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: true,
        packageName: CloudSyncDevGate.androidCanaryPackageName,
      ),
      true,
    );
  });
}
