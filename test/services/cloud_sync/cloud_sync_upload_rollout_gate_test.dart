import 'dart:convert';

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
  const expectedReceivedProfile = bool.fromEnvironment(
    'TEST_EXPECT_RECEIVED_PROFILE',
  );
  const expectedReceivedArchive = bool.fromEnvironment(
    'TEST_EXPECT_RECEIVED_ARCHIVE',
    defaultValue: expectedReceivedProfile,
  );

  test('writer opt-in matches the explicitly qualified build mode', () {
    expect(CloudSyncDevGate.manualOutboundCanaryEnabled, expectedWriter);
    expect(CloudKitWriterOwnership.v2MutationsEnabled, expectedWriter);
  });

  test('automatic uploads remain a separate explicit opt-in', () {
    expect(CloudSyncDevGate.localSendRuntimeEnabled, expectedAutomatic);
    if (expectedAutomatic) expect(expectedWriter, isTrue);
  });

  test(
    'all five received flags match the explicitly qualified bundle, including off',
    () {
      for (final flag in <String, bool>{
        'capture': CloudSyncDevGate.receivedArchiveCaptureEnabled,
        'inspection': CloudSyncDevGate.receivedArchiveInspectionEnabled,
        'uploads': CloudSyncDevGate.receivedArchiveUploadsEnabled,
        'discovery': CloudSyncDevGate.receivedArchiveDiscoveryEnabled,
        'Profile': CloudSyncDevGate.receivedArchiveProfileEnabled,
      }.entries) {
        expect(flag.value, expectedReceivedArchive, reason: flag.key);
      }
      if (expectedReceivedArchive) {
        expect(expectedAutomatic, isTrue);
        expect(expectedWriter, isTrue);
        expect(CloudSyncDevGate.manualSemanticPullEnabled, isTrue);
      }
    },
  );

  test(
    'compiled received availability never replaces stored scoped consent',
    () async {
      final identity = CloudSyncAutomaticArchiveIdentity(
        accountFingerprint: 'A' * 43,
        protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
        ownershipEpoch: 2,
      );
      var writes = 0;
      var prepares = 0;
      for (final scope
          in <({Object? stored, bool sent, bool text, bool media})>[
            (stored: null, sent: false, text: false, media: false),
            (stored: true, sent: false, text: false, media: false),
            (
              stored: jsonEncode([
                1,
                'queued-and-future-local-sends',
                2,
                'f' * 32,
              ]),
              sent: true,
              text: false,
              media: false,
            ),
            (
              stored: jsonEncode([
                2,
                'queued-and-future-local-sends-and-receives',
                2,
                'f' * 32,
              ]),
              sent: true,
              text: true,
              media: false,
            ),
            (
              stored: jsonEncode([
                3,
                'queued-and-future-local-sends-and-received-text-and-media',
                2,
                'f' * 32,
              ]),
              sent: true,
              text: true,
              media: true,
            ),
          ]) {
        Object? stored = scope.stored;
        final preferences = CloudSyncAutomaticArchivePreferences(
          captureIdentity: () async => identity,
          currentOwnershipEpoch: () => identity.ownershipEpoch,
          stillCurrent: () => true,
          reload: () async {},
          read: (key) => key == identity.preferenceKey ? stored : null,
          write: (_, _) async {
            writes++;
            return true;
          },
          prepareWriter: () async {
            prepares++;
          },
        );
        final consent = await preferences.load();
        expect(preferences.isGranted(consent), scope.sent);
        expect(preferences.isReceivedGranted(consent), scope.text);
        expect(preferences.isReceivedMediaGranted(consent), scope.media);
        expect(
          consent.permitsReceivedCapture(
            accountFingerprint: identity.accountFingerprint,
            protectedStoreIdentity: identity.protectedStoreIdentity,
            ownershipEpoch: identity.ownershipEpoch,
            currentStoredValue: stored,
          ),
          scope.text,
        );
        expect(
          consent.permitsReceivedMediaCapture(
            accountFingerprint: identity.accountFingerprint,
            protectedStoreIdentity: identity.protectedStoreIdentity,
            ownershipEpoch: identity.ownershipEpoch,
            currentStoredValue: stored,
          ),
          scope.media,
        );
        stored = jsonEncode([1, 'off']);
        expect(preferences.isGranted(consent), isFalse);
        expect(preferences.isReceivedGranted(consent), isFalse);
        expect(preferences.isReceivedMediaGranted(consent), isFalse);
      }
      expect(writes, 0);
      expect(prepares, 0);
    },
  );

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

  test('runtime package fence accepts only Android Canary', () async {
    expect(
      CloudSyncDevGate.isCanaryRuntime(
        isAndroid: true,
        packageName: CloudSyncDevGate.androidCanaryPackageName,
      ),
      isTrue,
    );
    final identity = CloudSyncAutomaticArchiveIdentity(
      accountFingerprint: 'A' * 43,
      protectedStoreIdentity: 'obcs2.store.${'B' * 43}',
      ownershipEpoch: 2,
    );
    final consent = CloudSyncAutomaticArchivePreference(
      identity: identity,
      storedValue: jsonEncode([
        3,
        'queued-and-future-local-sends-and-received-text-and-media',
        2,
        'f' * 32,
      ]),
    );
    expect(consent.includesReceivedMedia, isTrue);
    for (final runtime in <({bool isAndroid, String packageName})>[
      (isAndroid: true, packageName: 'com.bluebubbles.messaging.alpha'),
      (isAndroid: true, packageName: 'com.bluebubbles.messaging.beta'),
      (isAndroid: true, packageName: 'com.bluebubbles.messaging'),
      (isAndroid: true, packageName: ''),
      (
        isAndroid: false,
        packageName: CloudSyncDevGate.androidCanaryPackageName,
      ),
    ]) {
      bool runtimeAllowed() => CloudSyncDevGate.isCanaryRuntime(
        isAndroid: runtime.isAndroid,
        packageName: runtime.packageName,
      );
      expect(runtimeAllowed(), isFalse, reason: '$runtime');
      var accountReads = 0;
      final adapter = CloudSyncProductionLocalSendAdapter(
        readActiveClient: () {
          accountReads++;
          return null;
        },
        privateStorageDirectory: 'unused-wrong-runtime-rollout-path',
        stillCurrent: runtimeAllowed,
        automaticArchiveIdentity: identity,
        receivedArchiveAllowed: () => consent.includesReceived,
        receivedMediaArchiveAllowed: () => consent.includesReceivedMedia,
      );
      await expectLater(
        adapter.runOnce(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'admission code',
            'cloud_sync_local_send_consumer_disabled',
          ),
        ),
      );
      expect(accountReads, 0, reason: '$runtime');
    }
  });
}
