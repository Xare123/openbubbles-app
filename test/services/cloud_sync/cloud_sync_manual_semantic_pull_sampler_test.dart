import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

const _accountFingerprintA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _accountFingerprintB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
final _nativeClientA = Object();
final _nativeClientB = Object();

CloudSyncShadowPreflightState _readyState({int outboxCount = 0}) =>
    CloudSyncShadowPreflightState(
      platformSupported: true,
      uiIsolate: true,
      rustPushReady: true,
      objectBoxReady: true,
      privateStorageExists: true,
      logoutActive: false,
      legacySyncEnabled: false,
      legacySyncActive: false,
      coordinatorLeaseActive: false,
      outboxCount: outboxCount,
      protectorSentinelValid: true,
    );

CloudSyncNativeAuthSnapshot _auth({
  String session = 'session-a',
  String fingerprint = _accountFingerprintA,
  Object? client,
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: session,
  accountFingerprint: fingerprint,
  protectedStoreIdentity:
      'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  cloudMessagesClient: client ?? _nativeClientA,
);

CloudFetchedChange _change(String id) => CloudFetchedChange(
  changeId: id,
  recordIdHash: 'record-$id',
  type: CloudChangeType.save,
  etagHash: 'etag-$id',
  encryptedServerRecordId: 'protected:server-$id',
  protectedSystemFieldsReference: 'protected:system-$id',
  encryptedPayloadReference: 'protected:payload-$id',
  payloadSha256: 'payload-$id',
);

CloudSyncManualSemanticPullSampler _sampler({
  required Directory privateStorageDirectory,
  required CloudSyncShadowPreflightReader readPreflight,
  required CloudSyncNativeAuthSnapshotReader readAuthSnapshot,
  CloudSyncPreparedAuthSnapshotReader? prepareAuthSnapshot,
  required CloudSyncSemanticStoreFactory createStore,
  required CloudSyncSemanticRawTransportFactory createRawTransport,
  required CloudSyncSemanticInboxApplierFactory createInboxApplier,
  required CloudSyncStore operationFenceStore,
  bool enabled = true,
  Duration? fetchTimeout,
  CloudSyncObserverFactory? observerFactory,
}) => CloudSyncManualSemanticPullSampler(
  readPreflight: readPreflight,
  prepareAuthSnapshot: prepareAuthSnapshot ?? readAuthSnapshot,
  readAuthSnapshot: readAuthSnapshot,
  createStore: createStore,
  createRawTransport: createRawTransport,
  createInboxApplier: createInboxApplier,
  operationFenceStore: operationFenceStore,
  privateStorageDirectory: privateStorageDirectory.path,
  platform: 'windows',
  architecture: 'arm64',
  buildCommit: 'test-commit',
  compileGateOverrideForTest: enabled,
  fetchTimeoutOverrideForTest: fetchTimeout,
  observerFactory: observerFactory,
);

void main() {
  late Directory privateStorageDirectory;

  setUp(() {
    privateStorageDirectory = Directory.systemTemp.createTempSync(
      'cloud-sync-semantic-pull-sampler-',
    );
  });

  tearDown(() {
    privateStorageDirectory.deleteSync(recursive: true);
  });

  test(
    'read authentication preparation runs under the semantic interlock',
    () async {
      final fenceStore = InMemoryCloudSyncStore();
      final competing = CloudKitOperationInterlock(
        privateStorageDirectory: privateStorageDirectory.path,
        fenceStore: fenceStore,
      );
      var observedActiveInterlock = false;
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: fenceStore,
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        prepareAuthSnapshot: () async {
          await expectLater(
            competing.runExclusive(
              kind: CloudKitOperationKind.legacyReadWrite,
              action: () async {},
            ),
            throwsA(
              isA<CloudKitOperationInterlockException>().having(
                (error) => error.safeCode,
                'safeCode',
                'cloudkit_interlock_mode_violation',
              ),
            ),
          );
          observedActiveInterlock = true;
          return _auth();
        },
        createStore: (scope) async => InMemoryCloudSyncStore(),
        createRawTransport: (snapshot, scope) async => FakeCloudSyncTransport(),
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
      );

      await sampler.runConfirmed();
      expect(observedActiveInterlock, isTrue);
    },
  );

  test(
    'semantic report keeps quarantine phases and redacted subtype counts',
    () {
      final zone = CloudSyncSemanticPullZoneReport(
        zoneLabel: 'messages',
        status: CloudSyncRunStatus.completed,
        fetched: 3,
        applied: 0,
        deferred: 0,
        quarantined: 3,
        preflightQuarantined: 1,
        preflightUnsupportedRecordType: 0,
        preflightMalformedMetadata: 0,
        preflightOversizedRecord: 0,
        preflightInvalidChangeShape: 1,
        preflightUnknown: 0,
        startupQuarantined: 1,
        postFetchQuarantined: 2,
        tombstoneQuarantined: 1,
        semanticUnsupportedServiceQuarantined: 1,
        semanticStageQuarantined: 0,
        retried: 0,
        elapsedMilliseconds: 1,
        diagnosticCounts: const {'native_quarantined_unsupported_service': 1},
      );

      final json = zone.toJson();

      expect(json['quarantinePhases'], <String, int>{
        'startup': 1,
        'postFetch': 2,
      });
      expect(json['tombstoneQuarantined'], 1);
      expect(json['semanticUnsupportedServiceQuarantined'], 1);
      expect(json['semanticDiagnostics'], <String, int>{
        'native_quarantined_unsupported_service': 1,
      });
      expect(json.toString(), isNot(contains('service-name')));
      expect(json.toString(), isNot(contains('record-id')));
      expect(json.toString(), isNot(contains('message-body')));
      expect(json.toString(), isNot(contains('change-token')));
      expect(json.toString(), isNot(contains('protected-reference')));
    },
  );

  test(
    'disabled compile gate performs no work and starts no background run',
    () async {
      var preflightCalls = 0;
      var authCalls = 0;
      var storeCalls = 0;
      var transportCalls = 0;
      var applierCalls = 0;
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        enabled: false,
        readPreflight: () async {
          preflightCalls++;
          throw StateError('disabled sampler performed preflight');
        },
        readAuthSnapshot: () async {
          authCalls++;
          throw StateError('disabled sampler read auth');
        },
        createStore: (scope) async {
          storeCalls++;
          throw StateError('disabled sampler created store');
        },
        createRawTransport: (auth, scope) async {
          transportCalls++;
          throw StateError('disabled sampler created transport');
        },
        createInboxApplier: (auth, scope, generation) async {
          applierCalls++;
          throw StateError('disabled sampler created applier');
        },
      );

      await expectLater(sampler.runConfirmed(), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sampler.isActive, isFalse);
      expect(preflightCalls, 0);
      expect(authCalls, 0);
      expect(storeCalls, 0);
      expect(transportCalls, 0);
      expect(applierCalls, 0);
    },
  );

  test(
    'runs only on explicit confirmation in exact zone order with read-only flags',
    () async {
      final scopes = <String>[];
      final lanes = <CloudSyncPersistenceLane>[];
      final transports = <String, FakeCloudSyncTransport>{};
      final appliers = <String, FakeCloudInboxApplier>{};
      final applied = <String>[];
      final stores = <String, InMemoryCloudSyncStore>{};
      final preflightStates = <CloudSyncShadowPreflightState>[];
      final observers = <String, _RecordingFlushableObserver>{};

      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        readPreflight: () async {
          final state = _readyState();
          preflightStates.add(state);
          return state;
        },
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async {
          scopes.add(scope.zone);
          lanes.add(scope.persistenceLane);
          final store = InMemoryCloudSyncStore();
          stores[scope.zone] = store;
          return store;
        },
        createRawTransport: (auth, scope) async {
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler = (scope, token, generation, limit) async =>
              CloudFetchBatch(
                scope: scope,
                changes: [_change('change-${scope.zone}')],
                batchId: 'batch-${scope.zone}',
                generation: generation,
                nextToken: 'token-${scope.zone}',
                hasMore: false,
              );
          transports[scope.zone] = transport;
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async {
          final applier = FakeCloudInboxApplier();
          applier.handler = (entry) async {
            applied.add('${scope.zone}:${entry.sequence}');
            return const CloudInboxApplyResult.applied();
          };
          appliers[scope.zone] = applier;
          return applier;
        },
        observerFactory: (scope) async =>
            observers[scope.zone] = _RecordingFlushableObserver(),
      );

      expect(scopes, isEmpty);
      expect(transports, isEmpty);
      expect(appliers, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(scopes, isEmpty);

      final report = await sampler.runConfirmed();

      expect(scopes, CloudSyncManualSemanticPullSampler.zones);
      expect(lanes, everyElement(CloudSyncPersistenceLane.semantic));
      expect(report.zones.map((zone) => zone.zoneLabel), const [
        'chats',
        'messages',
        'attachments',
      ]);
      expect(report.zones.map((zone) => zone.fetched), [1, 1, 1]);
      expect(report.zones.map((zone) => zone.applied), [1, 1, 1]);
      expect(report.zones.map((zone) => zone.preflightQuarantined), [0, 0, 0]);
      expect(
        report.zones.map((zone) => zone.toJson()['preflightReasons']),
        everyElement(<String, int>{
          'unsupportedRecordType': 0,
          'malformedMetadata': 0,
          'oversizedRecord': 0,
          'invalidChangeShape': 0,
          'unknown': 0,
        }),
      );
      expect(
        report.zones.map((zone) => zone.toJson()['quarantinePhases']),
        everyElement(<String, int>{'startup': 0, 'postFetch': 0}),
      );
      expect(report.zones.map((zone) => zone.tombstoneQuarantined), [0, 0, 0]);
      expect(
        report.zones.map((zone) => zone.semanticUnsupportedServiceQuarantined),
        [0, 0, 0],
      );
      expect(report.zones.map((zone) => zone.semanticStageQuarantined), [
        0,
        0,
        0,
      ]);
      expect(applied, const [
        'chatManateeZone:1',
        'messageManateeZone:1',
        'attachmentManateeZone:1',
      ]);

      expect(sampler.debugFlags.readOnlyFetch, isTrue);
      expect(sampler.debugFlags.semanticApply, isTrue);
      expect(sampler.debugFlags.saves, isFalse);
      expect(sampler.debugFlags.deletions, isFalse);
      expect(sampler.debugFlags.profiles, isFalse);
      expect(sampler.debugFlags.notificationHints, isFalse);

      expect(report.outboxCountBefore, 0);
      expect(report.outboxCountAfter, 0);
      expect(preflightStates.map((state) => state.outboxCount), [0, 0]);
      expect(report.remoteWriteTripwiresIntact, isTrue);
      expect(observers.keys, CloudSyncManualSemanticPullSampler.zones);
      expect(observers.values.every((observer) => observer.flushed), isTrue);
      expect(
        observers.values.every((observer) => observer.events.isNotEmpty),
        isTrue,
      );
      expect(transports.values.map((transport) => transport.fetchCallCount), [
        1,
        1,
        1,
      ]);
      expect(transports.values.map((transport) => transport.pushCallCount), [
        0,
        0,
        0,
      ]);
      expect(
        transports.values.every(
          (transport) =>
              transport.authenticationRefreshCallCount == 0 &&
              transport.pcsRefreshCallCount == 0 &&
              transport.recordMappingCallCount == 0 &&
              transport.conflictCallCount == 0,
        ),
        isTrue,
      );
      expect(
        stores.values.every(
          (store) => store.runs.single.counters.confirmed == 0,
        ),
        isTrue,
      );

      final countsAfterRun = [
        ...transports.values.map((transport) => transport.fetchCallCount),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        transports.values.map((transport) => transport.fetchCallCount),
        countsAfterRun,
      );
    },
  );

  test(
    'repairs applied chat projection before transport and releases its lease',
    () async {
      final events = <String>[];
      final stores = <String, InMemoryCloudSyncStore>{};
      late _RepairingFakeCloudInboxApplier chatApplier;
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async {
          final store = InMemoryCloudSyncStore();
          stores[scope.zone] = store;
          return store;
        },
        createRawTransport: (auth, scope) async {
          events.add('transport:${scope.zone}');
          return FakeCloudSyncTransport();
        },
        createInboxApplier: (auth, scope, generation) async {
          events.add('applier:${scope.zone}');
          if (scope.zone == 'chatManateeZone') {
            chatApplier = _RepairingFakeCloudInboxApplier(
              onRepair: (repairScope, repairGeneration, leaseFence, limit) {
                events.add('repair:${repairScope.zone}');
                expect(repairGeneration, generation);
                expect(leaseFence.ownerId, contains(auth.nativeSessionId));
                expect(
                  limit,
                  CloudSyncManualSemanticPullSampler.projectionRepairLimit,
                );
              },
            );
            return chatApplier;
          }
          return FakeCloudInboxApplier();
        },
      );

      await sampler.runConfirmed();

      expect(chatApplier.repairCalls, 1);
      expect(events, const [
        'applier:chatManateeZone',
        'repair:chatManateeZone',
        'transport:chatManateeZone',
        'applier:messageManateeZone',
        'transport:messageManateeZone',
        'applier:attachmentManateeZone',
        'transport:attachmentManateeZone',
      ]);
      final chatScope = CloudSyncScope(
        accountFingerprint: _accountFingerprintA,
        container: CloudSyncManualSemanticPullSampler.container,
        database: CloudSyncManualSemanticPullSampler.database,
        zone: 'chatManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final replacementLease = await stores['chatManateeZone']!
          .tryAcquireCoordinatorLease(
            chatScope,
            ownerId: 'post-repair-test-owner',
            now: DateTime.now().toUtc(),
            leaseDuration: const Duration(minutes: 1),
          );
      expect(replacementLease, isNotNull);
      await stores['chatManateeZone']!.releaseCoordinatorLease(
        chatScope,
        leaseFence: replacementLease!,
      );
    },
  );

  test(
    'provided applier is the only semantic application path and confirmation remains unreachable',
    () async {
      final transports = <FakeCloudSyncTransport>[];
      final appliers = <FakeCloudInboxApplier>[];
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => InMemoryCloudSyncStore(),
        createRawTransport: (auth, scope) async {
          final transport = FakeCloudSyncTransport();
          transport.pushHandler = (scope, operations) async =>
              CloudPushBatchResult(
                outcomes: operations.map(
                  (operation) => CloudPushOutcome(
                    operationId: operation.operationId,
                    disposition: CloudPushDisposition.confirmed,
                  ),
                ),
              );
          transport.fetchHandler = (scope, token, generation, limit) async =>
              CloudFetchBatch(
                scope: scope,
                changes: [_change('tripwire-${scope.zone}')],
                batchId: 'tripwire-batch-${scope.zone}',
                generation: generation,
                nextToken: null,
                hasMore: false,
              );
          transports.add(transport);
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async {
          final applier = FakeCloudInboxApplier();
          appliers.add(applier);
          return applier;
        },
      );

      final report = await sampler.runConfirmed();

      expect(appliers, hasLength(3));
      expect(
        appliers.every(
          (applier) =>
              applier.appliedSequences.length == 1 &&
              applier.appliedSequences.single == 1,
        ),
        isTrue,
      );
      expect(
        transports.every((transport) => transport.pushCallCount == 0),
        isTrue,
      );
      expect(report.zones.every((zone) => zone.applied == 1), isTrue);
      expect(
        report.zones.every(
          (zone) => zone.status == CloudSyncRunStatus.completed,
        ),
        isTrue,
      );
    },
  );

  test(
    'account replacement fails closed before journaling or applying the page',
    () async {
      var current = _auth();
      final stores = <String, InMemoryCloudSyncStore>{};
      final transports = <FakeCloudSyncTransport>[];
      final applied = <int>[];
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => current,
        createStore: (scope) async {
          final store = InMemoryCloudSyncStore();
          stores[scope.zone] = store;
          return store;
        },
        createRawTransport: (auth, scope) async {
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler = (scope, token, generation, limit) async {
            current = _auth(
              session: 'session-b',
              fingerprint: _accountFingerprintB,
              client: _nativeClientB,
            );
            return CloudFetchBatch(
              scope: scope,
              changes: [_change('stale-${scope.zone}')],
              batchId: 'stale-batch-${scope.zone}',
              generation: generation,
              nextToken: 'must-not-commit',
              hasMore: false,
            );
          };
          transports.add(transport);
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async {
          final applier = FakeCloudInboxApplier();
          applier.handler = (entry) async {
            applied.add(entry.sequence);
            return const CloudInboxApplyResult.applied();
          };
          return applier;
        },
      );

      await expectLater(
        sampler.runConfirmed(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'account_changed',
          ),
        ),
      );

      expect(transports, hasLength(1));
      expect(transports.single.fetchCallCount, 1);
      expect(applied, isEmpty);
      final store = stores.values.single;
      final scope = CloudSyncScope(
        accountFingerprint: _accountFingerprintA,
        container: CloudSyncManualSemanticPullSampler.container,
        database: CloudSyncManualSemanticPullSampler.database,
        zone: CloudSyncManualSemanticPullSampler.zones.first,
      );
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect(await store.inboxEntries(scope), isEmpty);
      expect(transports.single.pushCallCount, 0);
      expect(sampler.isActive, isFalse);
    },
  );

  test(
    'fetch timeout waits for native quiescence before releasing the interlock',
    () async {
      final nativeFetch = Completer<CloudFetchBatch>();
      final nativeFetchEntered = Completer<void>();
      final fenceStore = InMemoryCloudSyncStore();
      final stores = <String, InMemoryCloudSyncStore>{};
      var transportIndex = 0;
      var quiesceStarted = false;
      var quiesceCompleted = false;
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: fenceStore,
        fetchTimeout: const Duration(milliseconds: 5),
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async {
          final store = InMemoryCloudSyncStore();
          stores[scope.zone] = store;
          return store;
        },
        createRawTransport: (auth, scope) async {
          if (transportIndex++ == 0) {
            return _JoinableTransport(
              fetchHandler: (scope, token, generation, limit) {
                nativeFetchEntered.complete();
                return nativeFetch.future;
              },
              quiesce: () async {
                quiesceStarted = true;
                await nativeFetch.future;
                quiesceCompleted = true;
              },
            );
          }
          return FakeCloudSyncTransport();
        },
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
      );

      final run = sampler.runConfirmed();
      await nativeFetchEntered.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(quiesceStarted, isTrue);
      expect(quiesceCompleted, isFalse);
      expect(sampler.isActive, isTrue);

      final competingInterlock = CloudKitOperationInterlock(
        privateStorageDirectory: privateStorageDirectory.path,
        fenceStore: fenceStore,
      );
      await expectLater(
        competingInterlock.runExclusive(
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
            accountFingerprint: _accountFingerprintA,
            container: CloudSyncManualSemanticPullSampler.container,
            database: CloudSyncManualSemanticPullSampler.database,
            zone: CloudSyncManualSemanticPullSampler.zones.first,
          ),
          changes: const [],
          batchId: 'late-native-page',
          generation: 1,
          nextToken: 'late-token',
          hasMore: false,
        ),
      );

      final report = await run;
      expect(quiesceCompleted, isTrue);
      expect(sampler.isActive, isFalse);
      expect(report.zones.first.status, CloudSyncRunStatus.degraded);
      expect(report.zones.first.failureCategory, CloudFailureCategory.network);
      final firstScope = CloudSyncScope(
        accountFingerprint: _accountFingerprintA,
        container: CloudSyncManualSemanticPullSampler.container,
        database: CloudSyncManualSemanticPullSampler.database,
        zone: CloudSyncManualSemanticPullSampler.zones.first,
      );
      expect(
        (await stores[firstScope.zone]!.readCheckpoint(
          firstScope,
        )).fetchedToken,
        isNull,
      );
      await competingInterlock.runExclusive(
        kind: CloudKitOperationKind.legacyReadWrite,
        action: () async {},
      );
    },
  );
}

final class _RecordingFlushableObserver implements FlushableCloudSyncObserver {
  final List<CloudSyncEvent> events = [];
  bool flushed = false;

  @override
  void onEvent(CloudSyncEvent event) => events.add(event);

  @override
  Future<void> flush() async => flushed = true;
}

final class _JoinableTransport extends FakeCloudSyncTransport
    implements CloudSyncNativeOperationQuiescence {
  _JoinableTransport({
    required CloudFetchHandler fetchHandler,
    required this.quiesce,
  }) {
    this.fetchHandler = fetchHandler;
  }

  final Future<void> Function() quiesce;

  @override
  Future<void> quiesceNativeOperations() => quiesce();
}

typedef _ProjectionRepairCallback =
    void Function(
      CloudSyncScope scope,
      int generation,
      CloudCoordinatorLeaseFence leaseFence,
      int limit,
    );

final class _RepairingFakeCloudInboxApplier extends FakeCloudInboxApplier
    implements CloudAppliedProjectionRepairer {
  _RepairingFakeCloudInboxApplier({required this.onRepair});

  final _ProjectionRepairCallback onRepair;
  int repairCalls = 0;

  @override
  Future<int> repairAppliedProjections({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  }) async {
    repairCalls++;
    onRepair(scope, generation, leaseFence, limit);
    return 1;
  }
}
