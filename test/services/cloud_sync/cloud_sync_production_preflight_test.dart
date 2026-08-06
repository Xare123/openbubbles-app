import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudSyncProductionPreflightProbe readyProbe({
    Future<bool> Function()? protectorSentinelValid,
  }) {
    return CloudSyncProductionPreflightProbe(
      platformSupported: () => true,
      uiIsolate: () => true,
      rustPushReady: () => true,
      localState: () => const CloudSyncLocalPreflightState(
        objectBoxReady: true,
        coordinatorLeaseActive: false,
        outboxCount: 0,
      ),
      privateStorageExists: () => true,
      logoutActive: () => false,
      legacySyncEnabled: () => false,
      legacySyncActive: () => false,
      protectorSentinelValid: protectorSentinelValid ?? () async => true,
    );
  }

  test(
    'returns the exact ready state from synchronous and async probes',
    () async {
      final state = await readyProbe().read();

      expect(state.platformSupported, isTrue);
      expect(state.uiIsolate, isTrue);
      expect(state.rustPushReady, isTrue);
      expect(state.objectBoxReady, isTrue);
      expect(state.privateStorageExists, isTrue);
      expect(state.logoutActive, isFalse);
      expect(state.legacySyncEnabled, isFalse);
      expect(state.legacySyncActive, isFalse);
      expect(state.coordinatorLeaseActive, isFalse);
      expect(state.outboxCount, 0);
      expect(state.protectorSentinelValid, isTrue);
    },
  );

  test('availability probe failures become blocking false values', () async {
    final probe = CloudSyncProductionPreflightProbe(
      platformSupported: () => throw StateError('secret-platform-detail'),
      uiIsolate: () => throw StateError('secret-ui-detail'),
      rustPushReady: () => throw StateError('secret-rust-detail'),
      localState: () => throw StateError('secret-store-detail'),
      privateStorageExists: () => throw StateError('secret-path-detail'),
      logoutActive: () => false,
      legacySyncEnabled: () => false,
      legacySyncActive: () => false,
      protectorSentinelValid: () => throw StateError('secret-key-detail'),
    );

    final state = await probe.read();
    expect(state.platformSupported, isFalse);
    expect(state.uiIsolate, isFalse);
    expect(state.rustPushReady, isFalse);
    expect(state.objectBoxReady, isFalse);
    expect(state.privateStorageExists, isFalse);
    expect(state.protectorSentinelValid, isFalse);
  });

  test(
    'uncertain mutation or lifecycle state always blocks the sampler',
    () async {
      final probe = CloudSyncProductionPreflightProbe(
        platformSupported: () => true,
        uiIsolate: () => true,
        rustPushReady: () => true,
        localState: () => throw StateError('local-state-read-failed'),
        privateStorageExists: () => true,
        logoutActive: () => throw StateError('logout-read-failed'),
        legacySyncEnabled: () => throw StateError('setting-read-failed'),
        legacySyncActive: () => throw StateError('activity-read-failed'),
        protectorSentinelValid: () => true,
      );

      final state = await probe.read();
      expect(state.logoutActive, isTrue);
      expect(state.legacySyncEnabled, isTrue);
      expect(state.legacySyncActive, isTrue);
      expect(state.coordinatorLeaseActive, isTrue);
      expect(state.outboxCount, -1);
    },
  );

  test(
    'negative outbox counts cannot be mistaken for an empty outbox',
    () async {
      final probe = CloudSyncProductionPreflightProbe(
        platformSupported: () => true,
        uiIsolate: () => true,
        rustPushReady: () => true,
        localState: () => const CloudSyncLocalPreflightState(
          objectBoxReady: true,
          coordinatorLeaseActive: false,
          outboxCount: -500,
        ),
        privateStorageExists: () => true,
        logoutActive: () => false,
        legacySyncEnabled: () => false,
        legacySyncActive: () => false,
        protectorSentinelValid: () => true,
      );

      expect((await probe.read()).outboxCount, -1);
    },
  );

  test('every probe is evaluated once per immutable snapshot', () async {
    var calls = 0;
    bool boolean() {
      calls++;
      return true;
    }

    final probe = CloudSyncProductionPreflightProbe(
      platformSupported: boolean,
      uiIsolate: boolean,
      rustPushReady: boolean,
      localState: () {
        calls++;
        return const CloudSyncLocalPreflightState(
          objectBoxReady: true,
          coordinatorLeaseActive: false,
          outboxCount: 0,
        );
      },
      privateStorageExists: boolean,
      logoutActive: () {
        calls++;
        return false;
      },
      legacySyncEnabled: () {
        calls++;
        return false;
      },
      legacySyncActive: () {
        calls++;
        return false;
      },
      protectorSentinelValid: boolean,
    );

    await probe.read();
    expect(calls, 9);
  });
}
