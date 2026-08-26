import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    as frb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'construction and capture expose no raw account input in Dart',
    () async {
      final client = Object();
      final binding = _FakeNativeAuthBinding();
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: () => client,
        nativeAuthBinding: binding,
        privateStorageDirectory: 'private-storage',
      );

      expect(binding.calls, 0);
      final snapshot = await provider.capture();

      expect(binding.calls, 1);
      expect(binding.clients.single, same(client));
      expect(snapshot!.cloudMessagesClient, same(client));
      expect(snapshot.accountFingerprint, _digest('F'));
      expect(snapshot.nativeSessionId, _digest('N'));
      expect(
        snapshot.protectedStoreIdentity,
        'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      );
    },
  );

  test('client replacement during native capture fails closed', () async {
    final first = Object();
    final second = Object();
    var active = first;
    final blocker = Completer<void>();
    final binding = _FakeNativeAuthBinding(blocker: blocker);
    final provider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: () => active,
      nativeAuthBinding: binding,
      privateStorageDirectory: 'private-storage',
    );

    final pending = provider.capture();
    await Future<void>.delayed(Duration.zero);
    active = second;
    blocker.complete();

    expect(await pending, isNull);
  });

  test('missing active client performs no native call', () async {
    final binding = _FakeNativeAuthBinding();
    final provider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: () => null,
      nativeAuthBinding: binding,
      privateStorageDirectory: 'private-storage',
    );

    expect(await provider.capture(), isNull);
    expect(binding.calls, 0);
  });

  test(
    'production binding rejects a non-FRB client before native access',
    () async {
      final binding = FrbCloudSyncNativeAuthBinding();

      await expectLater(
        binding.capture(
          cloudMessagesClient: Object(),
          privateStorageDirectory: 'private-storage',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_native_auth_client_type_invalid',
          ),
        ),
      );
    },
  );

  test('native auth bridge classification exposes only reviewed tags', () {
    expect(
      cloudSyncNativeAuthBridgeSafeCode(
        frb.AnyhowException('cloud_sync_native_auth_account_unavailable'),
      ),
      'cloud_sync_native_auth_account_unavailable',
    );
    expect(
      cloudSyncNativeAuthBridgeSafeCode(
        frb.AnyhowException(
          'prefix cloud_sync_native_auth_account_unavailable suffix',
        ),
      ),
      'cloud_sync_native_auth_bridge_failed',
    );
    expect(
      cloudSyncNativeAuthBridgeSafeCode(
        Exception('token=private-value account=user@example.com'),
      ),
      'cloud_sync_native_auth_bridge_failed',
    );
  });
}

final class _FakeNativeAuthBinding implements CloudSyncNativeAuthBinding {
  _FakeNativeAuthBinding({this.blocker});

  final Completer<void>? blocker;
  int calls = 0;
  final List<Object> clients = [];

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {
    calls++;
    clients.add(cloudMessagesClient);
    await blocker?.future;
    return const CloudSyncNativeAuthMetadata(
      nativeSessionId: _nativeSession,
      accountFingerprint: _accountFingerprint,
      protectedStoreIdentity:
          'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
  }
}

const _nativeSession = 'NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN';
const _accountFingerprint = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';
String _digest(String character) => List<String>.filled(43, character).join();
