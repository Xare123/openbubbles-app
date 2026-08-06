import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_android_work_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'metadata work is battery safe and delays coalesced work by 15 seconds',
    () {
      final policy = CloudSyncAndroidWorkPolicy.forKind(
        CloudSyncAndroidWorkKind.metadata,
      );

      expect(
        policy.networkRequirement,
        CloudSyncAndroidNetworkRequirement.connected,
      );
      expect(policy.requiresBatteryNotLow, isTrue);
      expect(policy.requiresStorageNotLow, isTrue);
      expect(policy.coalescingDelay, const Duration(seconds: 15));
      expect(policy.requestsExpeditedExecution, isFalse);
    },
  );

  test('automatic media is deferred to unmetered network', () {
    final policy = CloudSyncAndroidWorkPolicy.forKind(
      CloudSyncAndroidWorkKind.automaticMedia,
    );

    expect(
      policy.networkRequirement,
      CloudSyncAndroidNetworkRequirement.unmetered,
    );
    expect(policy.requiresBatteryNotLow, isTrue);
    expect(policy.requiresStorageNotLow, isTrue);
    expect(policy.requestsExpeditedExecution, isFalse);
  });

  test('a user-visible event is modeled but not silently expedited', () {
    final policy = CloudSyncAndroidWorkPolicy.forKind(
      CloudSyncAndroidWorkKind.userVisibleManual,
    );

    expect(policy.requestsExpeditedExecution, isFalse);
  });

  test('unique work names require a complete scope hash', () {
    const hash =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    expect(
      CloudSyncAndroidWorkPolicy.uniqueWorkNameForScopeHash(hash),
      'cloud-sync-v2/$hash',
    );
    expect(
      () => CloudSyncAndroidWorkPolicy.uniqueWorkNameForScopeHash('account-a'),
      throwsArgumentError,
    );
  });
}
