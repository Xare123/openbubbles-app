import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    as frb;
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

void main() {
  late Directory temporaryDirectory;
  late CloudKitOperationInterlock interlock;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'cloud-sync-production-auth-',
    );
    interlock = CloudKitOperationInterlock(
      privateStorageDirectory: temporaryDirectory.path,
      fenceStore: InMemoryCloudSyncStore(),
    );
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

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
      expect(binding.warmCalls, 0);
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

  test(
    'read authentication warm is explicit and revalidates identity',
    () async {
      final client = Object();
      final binding = _FakeNativeAuthBinding();
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: () => client,
        nativeAuthBinding: binding,
        privateStorageDirectory: 'private-storage',
      );

      final snapshot = await interlock.runExclusive(
        kind: CloudKitOperationKind.v2ShadowRead,
        action: provider.prepareReadAuthenticationUnderInterlock,
      );

      expect(snapshot, isNotNull);
      expect(binding.warmCalls, 1);
      expect(binding.calls, 2);
      expect(binding.warmedClients.single, same(client));
    },
  );

  test(
    'client replacement during read authentication warm fails closed',
    () async {
      final first = Object();
      final second = Object();
      var active = first;
      final warmBlocker = Completer<void>();
      final binding = _FakeNativeAuthBinding(warmBlocker: warmBlocker);
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: () => active,
        nativeAuthBinding: binding,
        privateStorageDirectory: 'private-storage',
      );

      final pending = interlock.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: provider.prepareReadAuthenticationUnderInterlock,
      );
      await Future<void>.delayed(Duration.zero);
      active = second;
      warmBlocker.complete();

      expect(await pending, isNull);
      expect(binding.warmCalls, 1);
      expect(binding.calls, 1);
    },
  );

  test('read authentication warm requires an active read interlock', () async {
    final binding = _FakeNativeAuthBinding();
    final provider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: Object.new,
      nativeAuthBinding: binding,
      privateStorageDirectory: 'private-storage',
    );

    await expectLater(
      provider.prepareReadAuthenticationUnderInterlock(),
      throwsA(
        isA<CloudKitOperationInterlockException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_interlock_required',
        ),
      ),
    );
    expect(binding.calls, 0);
    expect(binding.warmCalls, 0);
  });

  test('read authentication warm rejects every write interlock', () async {
    final client = Object();
    final binding = _FakeNativeAuthBinding();
    final provider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: () => client,
      nativeAuthBinding: binding,
      privateStorageDirectory: 'private-storage',
    );

    for (final kind in <CloudKitOperationKind>[
      CloudKitOperationKind.legacyReadWrite,
      CloudKitOperationKind.v2ReadWrite,
      CloudKitOperationKind.writerTransition,
    ]) {
      await expectLater(
        interlock.runExclusive(
          kind: kind,
          action: provider.prepareReadAuthenticationUnderInterlock,
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_mode_violation',
          ),
        ),
      );
    }
    expect(binding.calls, 0);
    expect(binding.warmCalls, 0);
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
    for (final tag in <String>[
      'cloud_sync_native_auth_account_unavailable',
      'cloud_sync_native_auth_account_changed',
      'cloud_sync_native_auth_warm_failed',
      'cloud_sync_native_auth_warm_timeout',
    ]) {
      expect(cloudSyncNativeAuthBridgeSafeCode(frb.AnyhowException(tag)), tag);
    }
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
  _FakeNativeAuthBinding({this.blocker, this.warmBlocker});

  final Completer<void>? blocker;
  final Completer<void>? warmBlocker;
  int calls = 0;
  int warmCalls = 0;
  final List<Object> clients = [];
  final List<Object> warmedClients = [];

  @override
  Future<void> warmReadAuthentication({
    required Object cloudMessagesClient,
  }) async {
    warmCalls++;
    warmedClients.add(cloudMessagesClient);
    await warmBlocker?.future;
  }

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
