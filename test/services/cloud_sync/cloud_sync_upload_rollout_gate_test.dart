import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const expectedWriter = bool.fromEnvironment('TEST_EXPECT_CLOUDKIT_WRITER');
  const expectedAutomatic = bool.fromEnvironment(
    'TEST_EXPECT_AUTOMATIC_UPLOADS',
  );

  test('writer opt-in matches the explicitly qualified build mode', () {
    expect(CloudSyncDevGate.manualOutboundCanaryEnabled, expectedWriter);
    expect(CloudKitWriterOwnership.v2MutationsEnabled, expectedWriter);
  });

  test('automatic uploads remain a separate explicit opt-in', () {
    expect(CloudSyncDevGate.localSendRuntimeEnabled, expectedAutomatic);
    if (expectedAutomatic) expect(expectedWriter, isTrue);
  });

  test('runtime package fence accepts only Android Canary', () {
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: true,
        packageName: CloudSyncDevGate.androidCanaryPackageName,
      ),
      isTrue,
    );
    for (final package in [
      'com.bluebubbles.messaging.alpha',
      'com.bluebubbles.messaging.beta',
      'com.bluebubbles.messaging',
    ]) {
      expect(
        CloudSyncDevGate.isCanaryRuntime(isAndroid: true, packageName: package),
        isFalse,
      );
    }
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: false,
        packageName: CloudSyncDevGate.androidCanaryPackageName,
      ),
      isFalse,
    );
  });
}
