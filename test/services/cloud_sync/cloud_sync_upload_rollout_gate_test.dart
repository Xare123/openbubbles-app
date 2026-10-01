import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
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

  // This file is also executed by the established Canary flag-qualification
  // step with writes compiled on. Assert the precise failure, not merely a
  // StateError from an earlier disabled-build gate. No client, DB or Apple I/O.
  for (final consent in <String, CloudSyncAutomaticArchiveIdentity?>{
    'missing identity': null,
    'unprepared ownership epoch': CloudSyncAutomaticArchiveIdentity(
      accountFingerprint: List.filled(43, 'A').join(),
      protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'B').join()}',
      ownershipEpoch: 0,
    ),
  }.entries) {
    test(
      'automatic consumer rejects ${consent.key} before account reads',
      () async {
        var accountReads = 0;
        final adapter = CloudSyncProductionLocalSendAdapter(
          readActiveClient: () {
            accountReads++;
            return null;
          },
          privateStorageDirectory: 'unused-unconsented-rollout-path',
          stillCurrent: () => true,
          automaticArchiveIdentity: consent.value,
        );
        await expectLater(
          adapter.runOnce(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'admission code',
              expectedAutomatic
                  ? 'cloud_sync_automatic_archive_confirmation_required'
                  : 'cloud_sync_local_send_consumer_disabled',
            ),
          ),
        );
        expect(accountReads, 0);
      },
    );
  }

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
