import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_owner.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

CloudSyncShadowPreflightState readyState({
  bool legacySyncEnabled = false,
  int outboxCount = 0,
}) => CloudSyncShadowPreflightState(
  platformSupported: true,
  uiIsolate: true,
  rustPushReady: true,
  objectBoxReady: true,
  privateStorageExists: true,
  logoutActive: false,
  legacySyncEnabled: legacySyncEnabled,
  legacySyncActive: false,
  coordinatorLeaseActive: false,
  outboxCount: outboxCount,
  protectorSentinelValid: true,
);

final testCloudMessagesClient = Object();

CloudSyncNativeAuthSnapshot auth(
  String session, [
  String fp = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
  Object? client,
]) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: session,
  accountFingerprint: fp,
  protectedStoreIdentity:
      'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  cloudMessagesClient: client ?? testCloudMessagesClient,
);

void main() {
  late Directory privateStorageDirectory;

  setUp(() {
    privateStorageDirectory = Directory.systemTemp.createTempSync(
      'cloud-sync-sampler-',
    );
  });

  tearDown(() {
    privateStorageDirectory.deleteSync(recursive: true);
  });

  test('native auth snapshot rejects non-HMAC account identifiers', () {
    expect(
      () => CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'session',
        accountFingerprint: 'raw-account@example.com',
        protectedStoreIdentity:
            'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        cloudMessagesClient: Object(),
      ),
      throwsArgumentError,
    );
  });

  test(
    'disabled gate performs no preflight, store, or transport work',
    () async {
      var preflightCalls = 0;
      var storeCalls = 0;
      var transportCalls = 0;
      final sampler = CloudSyncManualShadowSampler(
        readPreflight: () async {
          preflightCalls++;
          return readyState();
        },
        readAuthSnapshot: () async => auth('session-a'),
        createStore: (scope) async {
          storeCalls++;
          return InMemoryCloudSyncStore();
        },
        createRawTransport: (snapshot, scope) async {
          transportCalls++;
          return FakeCloudSyncTransport();
        },
        operationFenceStore: InMemoryCloudSyncStore(),
        privateStorageDirectory: privateStorageDirectory.path,
        platform: 'windows',
        architecture: 'arm64',
        buildCommit: 'test',
        compileGateOverrideForTest: false,
      );

      await expectLater(sampler.runConfirmed(), throwsStateError);
      expect(preflightCalls, 0);
      expect(storeCalls, 0);
      expect(transportCalls, 0);
    },
  );

  test(
    'owns exact bounded read-only composition for all fixed zones',
    () async {
      final transports = <FakeCloudSyncTransport>[];
      final scopes = <CloudSyncScope>[];
      final sampler = CloudSyncManualShadowSampler(
        readPreflight: () async => readyState(),
        readAuthSnapshot: () async => auth('session-a'),
        createStore: (scope) async {
          scopes.add(scope);
          return InMemoryCloudSyncStore();
        },
        createRawTransport: (snapshot, scope) async {
          final transport = FakeCloudSyncTransport();
          transports.add(transport);
          return transport;
        },
        operationFenceStore: InMemoryCloudSyncStore(),
        privateStorageDirectory: privateStorageDirectory.path,
        platform: 'windows',
        architecture: 'arm64',
        buildCommit: 'test',
        compileGateOverrideForTest: true,
      );

      final report = await sampler.runConfirmed();

      expect(
        scopes.map((scope) => scope.zone),
        CloudSyncManualShadowSampler.zones,
      );
      expect(transports.map((transport) => transport.fetchCallCount), [
        1,
        1,
        1,
      ]);
      expect(transports.map((transport) => transport.pushCallCount), [0, 0, 0]);
      expect(report.pageLimit, 1);
      expect(report.changeLimit, 50);
      expect(report.toJson(), isNot(contains('fingerprintPrefix')));
      expect(report.correlationTag, hasLength(16));
      expect(report.isValidReadOnlySuccess, isTrue);
    },
  );

  test('account switch during fetch cannot journal the stale page', () async {
    var current = auth('session-a');
    late InMemoryCloudSyncStore store;
    final sampler = CloudSyncManualShadowSampler(
      readPreflight: () async => readyState(),
      readAuthSnapshot: () async => current,
      createStore: (scope) async => store = InMemoryCloudSyncStore(),
      createRawTransport: (snapshot, scope) async {
        final transport = FakeCloudSyncTransport();
        transport.fetchHandler = (scope, token, generation, limit) async {
          current = auth(
            'session-b',
            'OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO',
          );
          return CloudFetchBatch(
            scope: scope,
            changes: const [],
            batchId: 'stale-page',
            generation: generation,
            nextToken: 'must-not-commit',
            hasMore: false,
          );
        };
        return transport;
      },
      operationFenceStore: InMemoryCloudSyncStore(),
      privateStorageDirectory: privateStorageDirectory.path,
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'test',
      compileGateOverrideForTest: true,
    );

    await expectLater(sampler.runConfirmed(), throwsStateError);
    final scope = CloudSyncScope(
      accountFingerprint: 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
      container: CloudSyncManualShadowSampler.container,
      database: CloudSyncManualShadowSampler.database,
      zone: CloudSyncManualShadowSampler.zones.first,
    );
    expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
  });

  test('late fetch completion after timeout cannot journal', () async {
    final fetch = Completer<CloudFetchBatch>();
    late InMemoryCloudSyncStore store;
    late CloudSyncScope observedScope;
    final sampler = CloudSyncManualShadowSampler(
      readPreflight: () async => readyState(),
      readAuthSnapshot: () async => auth('session-a'),
      createStore: (scope) async {
        observedScope = scope;
        return store = InMemoryCloudSyncStore();
      },
      createRawTransport: (snapshot, scope) async {
        final transport = FakeCloudSyncTransport()
          ..fetchHandler = (scope, token, generation, limit) => fetch.future;
        return transport;
      },
      operationFenceStore: InMemoryCloudSyncStore(),
      privateStorageDirectory: privateStorageDirectory.path,
      platform: 'windows',
      architecture: 'x64',
      buildCommit: 'test',
      compileGateOverrideForTest: true,
      fetchTimeoutOverrideForTest: const Duration(milliseconds: 10),
    );

    final report = await sampler.runConfirmed();
    expect(report.zones.first.status.name, 'degraded');
    fetch.complete(
      CloudFetchBatch(
        scope: observedScope,
        changes: const [],
        batchId: 'late',
        generation: 1,
        nextToken: 'late-token',
        hasMore: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect((await store.readCheckpoint(observedScope)).fetchedToken, isNull);
  });

  test(
    'timeout keeps owner and interlock fenced until native quiescence joins',
    () async {
      final nativeFetch = Completer<CloudFetchBatch>();
      final nativeFetchEntered = Completer<void>();
      final fenceStore = InMemoryCloudSyncStore();
      var transportIndex = 0;
      final sampler = CloudSyncManualShadowSampler(
        readPreflight: () async => readyState(),
        readAuthSnapshot: () async => auth('session-a'),
        createStore: (scope) async => InMemoryCloudSyncStore(),
        createRawTransport: (snapshot, scope) async {
          if (transportIndex++ > 0) return FakeCloudSyncTransport();
          return _JoinableFakeCloudSyncTransport(
            fetchHandler: (scope, token, generation, limit) {
              nativeFetchEntered.complete();
              return nativeFetch.future;
            },
            join: () async {
              try {
                await nativeFetch.future;
              } catch (_) {
                // The native completion itself is the credential boundary.
              }
            },
          );
        },
        operationFenceStore: fenceStore,
        privateStorageDirectory: privateStorageDirectory.path,
        platform: 'windows',
        architecture: 'arm64',
        buildCommit: 'test',
        compileGateOverrideForTest: true,
        fetchTimeoutOverrideForTest: const Duration(milliseconds: 5),
      );
      final controller = CloudSyncManualShadowController(
        runConfirmed: sampler.runConfirmed,
        persistReport: (_) async => Object(),
      );
      final owner = CloudSyncManualShadowOwner(
        buildController: () async => controller,
      );

      final run = owner.runConfirmedAndPersist();
      await nativeFetchEntered.future;
      var quiesced = false;
      final ownerQuiescence = owner.quiesceForAccountTransition().then((_) {
        quiesced = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(quiesced, isFalse);

      final conflicting = CloudKitOperationInterlock(
        privateStorageDirectory: privateStorageDirectory.path,
        fenceStore: fenceStore,
      );
      await expectLater(
        conflicting.runExclusive(
          kind: CloudKitOperationKind.legacyReadWrite,
          action: () async {},
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_busy',
          ),
        ),
      );

      nativeFetch.complete(
        CloudFetchBatch(
          scope: CloudSyncScope(
            accountFingerprint: 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
            container: CloudSyncManualShadowSampler.container,
            database: CloudSyncManualShadowSampler.database,
            zone: CloudSyncManualShadowSampler.zones.first,
          ),
          changes: const [],
          batchId: 'late-native-page',
          generation: 1,
          nextToken: null,
          hasMore: false,
        ),
      );
      await run;
      await ownerQuiescence;
      expect(quiesced, isTrue);
      await conflicting.runExclusive(
        kind: CloudKitOperationKind.legacyReadWrite,
        action: () async {},
      );
    },
  );

  test('legacy sync and concurrent runs fail closed', () async {
    final blocker = Completer<void>();
    var legacy = true;
    final sampler = CloudSyncManualShadowSampler(
      readPreflight: () async => readyState(legacySyncEnabled: legacy),
      readAuthSnapshot: () async => auth('session-a'),
      createStore: (scope) async {
        await blocker.future;
        return InMemoryCloudSyncStore();
      },
      createRawTransport: (snapshot, scope) async => FakeCloudSyncTransport(),
      operationFenceStore: InMemoryCloudSyncStore(),
      privateStorageDirectory: privateStorageDirectory.path,
      platform: 'windows',
      architecture: 'arm64',
      buildCommit: 'test',
      compileGateOverrideForTest: true,
    );

    await expectLater(sampler.runConfirmed(), throwsStateError);
    legacy = false;
    final first = sampler.runConfirmed();
    await Future<void>.delayed(Duration.zero);
    await expectLater(sampler.runConfirmed(), throwsStateError);
    blocker.complete();
    await first;
    expect(sampler.isActive, isFalse);
  });
}

final class _JoinableFakeCloudSyncTransport extends FakeCloudSyncTransport
    implements CloudSyncNativeOperationQuiescence {
  _JoinableFakeCloudSyncTransport({
    required Future<CloudFetchBatch> Function(
      CloudSyncScope scope,
      String? token,
      int generation,
      int limit,
    )
    fetchHandler,
    required this._join,
  }) {
    this.fetchHandler = fetchHandler;
  }

  final Future<void> Function() _join;

  @override
  Future<void> quiesceNativeOperations() => _join();
}
