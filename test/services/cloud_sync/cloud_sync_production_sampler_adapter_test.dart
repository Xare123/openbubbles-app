import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
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
    'production semantic dependencies use exact zones and checkpoint generations',
    () async {
      final store = InMemoryCloudSyncStore();
      final messageScope = CloudSyncScope(
        accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: 2,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final chatScope = CloudSyncScope(
        accountFingerprint: messageScope.accountFingerprint,
        container: messageScope.container,
        database: messageScope.database,
        zone: 'chatManateeZone',
        streamKind: messageScope.streamKind,
        schemaVersion: messageScope.schemaVersion,
        persistenceLane: messageScope.persistenceLane,
      );
      await store.advanceOutboxGeneration(
        chatScope,
        now: DateTime.utc(2026, 1, 1),
      );
      final current = CloudCanonicalActiveScope(
        scope: messageScope,
        generation: 9,
      );

      final sameScope = await cloudSyncProductionDependencyActiveScope(
        store: store,
        current: current,
        zone: 'messageManateeZone',
      );
      final chat = await cloudSyncProductionDependencyActiveScope(
        store: store,
        current: current,
        zone: 'chatManateeZone',
      );

      expect(sameScope, same(current));
      expect(chat.scope, chatScope);
      expect(chat.generation, 2);
      await expectLater(
        cloudSyncProductionDependencyActiveScope(
          store: store,
          current: current,
          zone: 'unexpectedZone',
        ),
        throwsArgumentError,
      );
    },
  );

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
      final warmStarted = Completer<void>();
      final binding = _FakeNativeAuthBinding(
        warmBlocker: warmBlocker,
        warmStarted: warmStarted,
      );
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: () => active,
        nativeAuthBinding: binding,
        privateStorageDirectory: 'private-storage',
      );

      final pending = interlock.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: () => provider.prepareReadAuthenticationUnderNativeWriterPause(
          BigInt.from(17),
        ),
      );
      await warmStarted.future;
      active = second;
      warmBlocker.complete();

      expect(await pending, isNull);
      expect(binding.warmCalls, 0);
      expect(binding.pausedWarmCalls, 1);
      expect(binding.pauseTokens, <BigInt>[BigInt.from(17)]);
      expect(binding.calls, 1);
    },
  );

  test(
    'semantic read authentication forwards the exact writer pause token',
    () async {
      final client = Object();
      final binding = _FakeNativeAuthBinding();
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: () => client,
        nativeAuthBinding: binding,
        privateStorageDirectory: 'private-storage',
      );
      final token = BigInt.parse('18446744073709551615');

      final snapshot = await interlock.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: () =>
            provider.prepareReadAuthenticationUnderNativeWriterPause(token),
      );

      expect(snapshot, isNotNull);
      expect(binding.warmCalls, 0);
      expect(binding.pausedWarmCalls, 1);
      expect(binding.pausedWarmedClients.single, same(client));
      expect(binding.pauseTokens, <BigInt>[token]);
      expect(binding.calls, 2);
    },
  );

  test(
    'semantic read authentication rejects invalid pause tokens before capture',
    () async {
      final binding = _FakeNativeAuthBinding();
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: Object.new,
        nativeAuthBinding: binding,
        privateStorageDirectory: 'private-storage',
      );

      for (final token in <Object>[
        BigInt.zero,
        BigInt.from(-1),
        BigInt.one << 64,
        'not-a-native-token',
      ]) {
        await expectLater(
          interlock.runExclusive(
            kind: CloudKitOperationKind.v2SemanticRead,
            action: () =>
                provider.prepareReadAuthenticationUnderNativeWriterPause(token),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'cloud_sync_native_auth_writer_pause_scope_failed',
            ),
          ),
        );
      }

      expect(binding.calls, 0);
      expect(binding.warmCalls, 0);
      expect(binding.pausedWarmCalls, 0);
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

  test(
    'semantic read authentication requires the semantic interlock',
    () async {
      final binding = _FakeNativeAuthBinding();
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: Object.new,
        nativeAuthBinding: binding,
        privateStorageDirectory: 'private-storage',
      );

      await expectLater(
        provider.prepareReadAuthenticationUnderNativeWriterPause(BigInt.one),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_required',
          ),
        ),
      );
      await expectLater(
        interlock.runExclusive(
          kind: CloudKitOperationKind.v2ShadowRead,
          action: () => provider
              .prepareReadAuthenticationUnderNativeWriterPause(BigInt.one),
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_mode_violation',
          ),
        ),
      );
      expect(binding.calls, 0);
      expect(binding.warmCalls, 0);
      expect(binding.pausedWarmCalls, 0);
    },
  );

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

  test('production binding rejects an invalid pause token locally', () async {
    final binding = FrbCloudSyncNativeAuthBinding();

    await expectLater(
      binding.warmReadAuthenticationUnderWriterPause(
        cloudMessagesClient: Object(),
        pauseToken: BigInt.zero,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_auth_writer_pause_scope_failed',
        ),
      ),
    );
  });

  test('native auth bridge classification exposes only reviewed tags', () {
    for (final tag in <String>[
      'cloud_sync_native_auth_account_unavailable',
      'cloud_sync_native_auth_account_changed',
      'cloud_sync_native_auth_warm_failed',
      'cloud_sync_native_auth_warm_timeout',
      'cloud_sync_native_auth_writer_pause_scope_failed',
      'cloud_sync_native_auth_messages_container_failed',
      'cloud_sync_native_auth_keychain_container_failed',
      'cloud_sync_native_auth_security_container_failed',
      'cloud_sync_native_auth_cloudkit_token_failed',
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

  test('native writer pause bridge round-trips one opaque token', () async {
    final events = <String>[];
    final binding = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.from(7),
      pauseCall: (token) async {
        events.add('pause');
        return token;
      },
      resumeCall: (token) async {
        events.add('resume-$token');
      },
    );

    final token = await binding.pause();
    await binding.resume(token);

    expect(token, BigInt.from(7));
    expect(events, <String>['pause', 'resume-7']);
  });

  test('native writer resume retries a lost bridge response', () async {
    var resumeCalls = 0;
    final binding = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.from(9),
      pauseCall: (token) async => token,
      resumeCall: (_) async {
        resumeCalls++;
        if (resumeCalls == 1) {
          throw Exception('response lost after native release');
        }
      },
    );

    final token = await binding.pause();
    await binding.resume(token);

    expect(resumeCalls, 2);
  });

  test('native writer resume does not retry an invalid token', () async {
    var resumeCalls = 0;
    final binding = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.from(11),
      pauseCall: (token) async => token,
      resumeCall: (_) async {
        resumeCalls++;
        throw frb.AnyhowException(
          'cloud_sync_native_writer_resume_token_invalid',
        );
      },
    );

    await expectLater(
      binding.resume(BigInt.from(11)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_writer_resume_token_invalid',
        ),
      ),
    );
    expect(resumeCalls, 1);
  });

  test('native writer pause bridge rejects invalid tokens locally', () async {
    var pauseCalls = 0;
    final invalidPause = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.zero,
      pauseCall: (token) async {
        pauseCalls++;
        return token;
      },
      resumeCall: (_) async {},
    );
    await expectLater(
      invalidPause.pause(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_writer_pause_token_invalid',
        ),
      ),
    );
    expect(pauseCalls, 0);

    var resumeCalls = 0;
    final invalidResume = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.one,
      pauseCall: (token) async => token,
      resumeCall: (_) async => resumeCalls++,
    );
    await expectLater(
      invalidResume.resume(1),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_writer_resume_token_invalid',
        ),
      ),
    );
    expect(resumeCalls, 0);
  });

  test('native writer pause retries a lost response with one token', () async {
    final tokens = <BigInt>[];
    var pauseCalls = 0;
    final binding = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.from(41),
      retryDelay: Duration.zero,
      pauseCall: (token) async {
        tokens.add(token);
        pauseCalls++;
        if (pauseCalls == 1) {
          throw Exception('response lost after native activation');
        }
        return token;
      },
      resumeCall: (_) async {},
    );

    expect(await binding.pause(), BigInt.from(41));
    expect(tokens, <BigInt>[BigInt.from(41), BigInt.from(41)]);
  });

  test('ambiguous pause failure cancels the caller-owned token', () async {
    final resumed = <BigInt>[];
    final binding = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.from(43),
      bridgeCallTimeout: const Duration(milliseconds: 5),
      retryDelay: Duration.zero,
      pauseCall: (_) => Completer<BigInt>().future,
      resumeCall: (token) async => resumed.add(token),
    );

    await expectLater(binding.pause(), throwsStateError);
    expect(resumed, <BigInt>[BigInt.from(43)]);
  });

  test('unconfirmed pause cleanup is reported fail-closed', () async {
    final binding = FrbCloudSyncNativeWriterPause(
      tokenFactory: () => BigInt.from(47),
      bridgeCallTimeout: const Duration(milliseconds: 5),
      retryDelay: Duration.zero,
      pauseCall: (_) => Completer<BigInt>().future,
      resumeCall: (_) => Completer<void>().future,
    );

    await expectLater(
      binding.pause(),
      throwsA(isA<CloudSyncNativeWriterPauseUncertain>()),
    );
  });

  test('native writer pause bridge exposes only reviewed tags', () {
    for (final tag in <String>[
      'cloud_sync_native_writer_pause_already_active',
      'cloud_sync_native_writer_pause_failed',
      'cloud_sync_native_writer_pause_timeout',
      'cloud_sync_native_writer_pause_token_invalid',
      'cloud_sync_native_writer_resume_failed',
      'cloud_sync_native_writer_resume_token_invalid',
    ]) {
      expect(
        cloudSyncNativeWriterPauseBridgeSafeCode(frb.AnyhowException(tag)),
        tag,
      );
    }
    expect(
      cloudSyncNativeWriterPauseBridgeSafeCode(
        frb.AnyhowException(
          'prefix cloud_sync_native_writer_pause_timeout suffix',
        ),
      ),
      'cloud_sync_native_writer_pause_bridge_failed',
    );
    expect(
      cloudSyncNativeWriterPauseBridgeSafeCode(
        Exception('token=private-value account=user@example.com'),
      ),
      'cloud_sync_native_writer_pause_bridge_failed',
    );
  });
}

final class _FakeNativeAuthBinding implements CloudSyncNativeAuthBinding {
  _FakeNativeAuthBinding({this.blocker, this.warmBlocker, this.warmStarted});

  final Completer<void>? blocker;
  final Completer<void>? warmBlocker;
  final Completer<void>? warmStarted;
  int calls = 0;
  int warmCalls = 0;
  int pausedWarmCalls = 0;
  final List<Object> clients = [];
  final List<Object> warmedClients = [];
  final List<Object> pausedWarmedClients = [];
  final List<BigInt> pauseTokens = [];

  @override
  Future<void> warmReadAuthentication({
    required Object cloudMessagesClient,
  }) async {
    warmCalls++;
    warmedClients.add(cloudMessagesClient);
    final started = warmStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await warmBlocker?.future;
  }

  @override
  Future<void> warmReadAuthenticationUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt pauseToken,
  }) async {
    pausedWarmCalls++;
    pausedWarmedClients.add(cloudMessagesClient);
    pauseTokens.add(pauseToken);
    final started = warmStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
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
