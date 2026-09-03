import 'dart:async';

import 'package:bluebubbles/app/layouts/settings/pages/misc/troubleshoot_panel.dart';
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

typedef _TestSemanticInboxApplierFactory =
    Future<CloudInboxApplier> Function(
      CloudSyncNativeAuthSnapshot authSnapshot,
      CloudSyncScope scope,
      int generation,
    );

typedef _RetainedProjectionWindowCallback =
    Future<CloudRetainedProjectionWindowResult> Function(
      CloudSyncScope scope,
      int generation,
      CloudCoordinatorLeaseFence leaseFence,
      int afterFetchSequence,
      int throughFetchSequence,
      int limit,
    );

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

CloudFetchedChange _tombstone(String id) => CloudFetchedChange(
  changeId: id,
  recordIdHash: 'record-$id',
  type: CloudChangeType.delete,
  encryptedServerRecordId: 'protected:server-$id',
  protectedSystemFieldsReference: 'protected:system-$id',
  isTombstone: true,
);

CloudSyncSemanticPullZoneReport _zoneReport({
  CloudFailureCategory? failureCategory,
  String? failureSafeCode,
}) => CloudSyncSemanticPullZoneReport(
  zoneLabel: 'chats',
  status: failureCategory == null
      ? CloudSyncRunStatus.completed
      : CloudSyncRunStatus.degraded,
  fetched: 0,
  applied: 0,
  deferred: 0,
  quarantined: 0,
  preflightQuarantined: 0,
  preflightUnsupportedRecordType: 0,
  preflightMalformedMetadata: 0,
  preflightOversizedRecord: 0,
  preflightInvalidChangeShape: 0,
  preflightUnknown: 0,
  startupQuarantined: 0,
  postFetchQuarantined: 0,
  tombstoneQuarantined: 0,
  tombstoneReadOnlyAcknowledged: 0,
  semanticUnsupportedServiceQuarantined: 0,
  semanticStageQuarantined: 0,
  retried: 0,
  elapsedMilliseconds: 0,
  failureCategory: failureCategory,
  failureSafeCode: failureSafeCode,
);

CloudSyncManualSemanticPullSampler _sampler({
  required Directory privateStorageDirectory,
  required CloudSyncShadowPreflightReader readPreflight,
  required CloudSyncNativeAuthSnapshotReader readAuthSnapshot,
  CloudSyncEnsuredAuthSnapshotReader? ensureAuthSnapshot,
  CloudSyncSemanticPausedPreparedAuthSnapshotReader? prepareAuthSnapshot,
  required CloudSyncSemanticStoreFactory createStore,
  required CloudSyncSemanticRawTransportFactory createRawTransport,
  required _TestSemanticInboxApplierFactory createInboxApplier,
  void Function(Object pauseToken)? onInboxPauseToken,
  required CloudSyncStore operationFenceStore,
  CloudSyncNativeWriterPause? nativeWriterPause,
  bool enabled = true,
  Duration? fetchTimeout,
  CloudSyncSemanticRetryWait? retryWait,
  CloudSyncClock? clock,
  CloudSyncObserverFactory? observerFactory,
}) => CloudSyncManualSemanticPullSampler(
  readPreflight: readPreflight,
  ensureAuthSnapshot: ensureAuthSnapshot ?? () async => _auth(),
  prepareAuthSnapshot:
      prepareAuthSnapshot ?? (pauseToken, expectedAuth) => readAuthSnapshot(),
  readAuthSnapshot: readAuthSnapshot,
  createStore: createStore,
  createRawTransport: createRawTransport,
  createInboxApplier: (auth, scope, generation, pauseToken) {
    onInboxPauseToken?.call(pauseToken);
    return createInboxApplier(auth, scope, generation);
  },
  nativeWriterPause: nativeWriterPause ?? _RecordingNativeWriterPause(),
  operationFenceStore: operationFenceStore,
  privateStorageDirectory: privateStorageDirectory.path,
  platform: 'windows',
  architecture: 'arm64',
  buildCommit: 'test-commit',
  compileGateOverrideForTest: enabled,
  fetchTimeoutOverrideForTest: fetchTimeout,
  retryWaitOverrideForTest: retryWait,
  clockOverrideForTest: clock,
  observerFactory: observerFactory,
);

CloudSyncScope _semanticScope(String zone) => CloudSyncScope(
  accountFingerprint: _accountFingerprintA,
  container: CloudSyncManualSemanticPullSampler.container,
  database: CloudSyncManualSemanticPullSampler.database,
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

Future<void> _seedRetainedSaves(
  InMemoryCloudSyncStore store,
  CloudSyncScope scope, {
  required int count,
}) async {
  final now = DateTime.now().toUtc();
  final checkpoint = await store.readCheckpoint(scope);
  final leaseFence = await store.tryAcquireCoordinatorLease(
    scope,
    ownerId: 'seed-retained-${scope.zone}',
    now: now,
    leaseDuration: const Duration(minutes: 5),
  );
  expect(leaseFence, isNotNull);
  try {
    await store.journalFetchedBatch(
      CloudFetchBatch(
        scope: scope,
        changes: [
          for (var index = 1; index <= count; index++)
            _change('retained-${scope.zone}-$index'),
        ],
        batchId: 'seed-retained-${scope.zone}',
        generation: checkpoint.generation,
        nextToken: 'seed-retained-token-${scope.zone}',
        hasMore: false,
      ),
      now: now,
      leaseFence: leaseFence!,
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
    for (var sequence = 1; sequence <= count; sequence++) {
      await store.markInboxRetainedUnprojected(
        scope,
        sequence: sequence,
        category: CloudFailureCategory.malformedRecord,
        now: now,
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: leaseFence,
      );
    }
  } finally {
    await store.releaseCoordinatorLease(scope, leaseFence: leaseFence!);
  }
  final seededCheckpoint = await store.readCheckpoint(scope);
  expect(seededCheckpoint.fetchedSequence, count);
  expect(seededCheckpoint.pendingBatchId, isNull);
  expect(seededCheckpoint.hasUnmarkedPendingInbox, isFalse);
}

CloudSyncManualSemanticPullSampler _catchUpSampler({
  required Directory privateStorageDirectory,
  required Map<String, InMemoryCloudSyncStore> stores,
  required CloudSyncStore operationFenceStore,
  required CloudSyncNativeWriterPause nativeWriterPause,
  required _RetainedProjectionWindowCallback onReprojectWindow,
  void Function()? onEnsureAuth,
  void Function()? onPrepareAuth,
  void Function(CloudSyncScope scope)? onCreateRawTransport,
}) {
  return _sampler(
    privateStorageDirectory: privateStorageDirectory,
    readPreflight: () async => _readyState(),
    ensureAuthSnapshot: () async {
      onEnsureAuth?.call();
      return _auth();
    },
    prepareAuthSnapshot: (pauseToken, expectedAuth) async {
      onPrepareAuth?.call();
      return _auth();
    },
    readAuthSnapshot: () async => _auth(),
    createStore: (scope) async => stores[scope.zone]!,
    createRawTransport: (auth, scope, pauseToken) async {
      onCreateRawTransport?.call(scope);
      final transport = FakeCloudSyncTransport();
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            return CloudFetchBatch(
              scope: requestedScope,
              changes: const [],
              batchId: 'terminal-empty-${requestedScope.zone}',
              generation: generation,
              nextToken: previousToken,
              hasMore: false,
            );
          };
      return transport;
    },
    createInboxApplier: (auth, scope, generation) async =>
        _RetainedProjectionWindowFakeApplier(onReproject: onReprojectWindow),
    operationFenceStore: operationFenceStore,
    nativeWriterPause: nativeWriterPause,
  );
}

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

  test('native writer pause encloses the complete semantic run', () async {
    final events = <String>[];
    final nativeWriterPause = _RecordingNativeWriterPause(events: events);
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      ensureAuthSnapshot: () async {
        events.add('ensure-auth');
        return _auth();
      },
      readPreflight: () async {
        events.add('preflight');
        return _readyState();
      },
      prepareAuthSnapshot: (pauseToken, expectedAuth) async {
        expect(pauseToken, same(nativeWriterPause.token));
        events.add('prepare-auth');
        return _auth();
      },
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async {
        expect(pauseToken, same(nativeWriterPause.token));
        events.add('transport-pause-token');
        final transport = FakeCloudSyncTransport();
        transport.fetchHandler = (scope, token, generation, limit) async {
          events.add('fetch-${scope.zone}');
          return CloudFetchBatch(
            scope: scope,
            changes: const [],
            batchId: 'empty-${scope.zone}',
            generation: generation,
            nextToken: null,
            hasMore: false,
          );
        };
        return transport;
      },
      onInboxPauseToken: (pauseToken) {
        expect(pauseToken, same(nativeWriterPause.token));
        events.add('inbox-pause-token');
      },
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    final report = await sampler.runConfirmed();

    expect(events.first, 'ensure-auth');
    expect(events[1], 'pause-native-writers');
    expect(events[2], 'preflight');
    expect(events, contains('prepare-auth'));
    expect(events, contains('transport-pause-token'));
    expect(events, contains('inbox-pause-token'));
    expect(events.last, 'resume-native-writers');
    expect(nativeWriterPause.pauseCalls, 1);
    expect(nativeWriterPause.resumeCalls, 1);
    expect(report.zones.map((zone) => zone.observedEmptyTerminalRead), [
      true,
      true,
      true,
    ]);
    expect(report.hasExactThreeZoneStructure, isTrue);
    expect(report.allZonesObservedEmptyTerminalRead, isTrue);
    expect(report.safeToContinueDrain, isTrue);
    expect(report.projectionComplete, isTrue);
  });

  test(
    'confirmed session keeps one native pause through inter-pass decisions',
    () async {
      final events = <String>[];
      final nativeWriterPause = _RecordingNativeWriterPause(events: events);
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => InMemoryCloudSyncStore(),
        createRawTransport: (auth, scope, pauseToken) async {
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler = (scope, token, generation, limit) async {
            return CloudFetchBatch(
              scope: scope,
              changes: const [],
              batchId: 'empty-${scope.zone}',
              generation: generation,
              nextToken: null,
              hasMore: false,
            );
          };
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
      );

      final reports = await sampler.runConfirmedSession((runPass) async {
        events.add('session-action-start');
        final first = await runPass();
        events.add('persist-and-inspect-first');
        expect(nativeWriterPause.resumeCalls, 0);
        final second = await runPass();
        events.add('terminal-decision');
        expect(nativeWriterPause.resumeCalls, 0);
        return [first, second];
      });

      expect(reports, hasLength(2));
      expect(nativeWriterPause.pauseCalls, 1);
      expect(nativeWriterPause.resumeCalls, 1);
      expect(events.first, 'pause-native-writers');
      expect(
        events.indexOf('persist-and-inspect-first'),
        lessThan(events.indexOf('terminal-decision')),
      );
      expect(events.last, 'resume-native-writers');
      expect(sampler.isActive, isFalse);
    },
  );

  test(
    'session never replays a completed pass after later auth rejection',
    () async {
      var prepareCalls = 0;
      var persistedPasses = 0;
      final nativeWriterPause = _RecordingNativeWriterPause();
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        readPreflight: () async => _readyState(),
        prepareAuthSnapshot: (pauseToken, expectedAuth) async {
          prepareCalls++;
          if (prepareCalls == 2) {
            throw StateError('cloud_sync_native_auth_credentials_rejected');
          }
          return _auth();
        },
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => InMemoryCloudSyncStore(),
        createRawTransport: (auth, scope, pauseToken) async {
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler = (scope, token, generation, limit) async {
            return CloudFetchBatch(
              scope: scope,
              changes: const [],
              batchId: 'empty-${scope.zone}',
              generation: generation,
              nextToken: null,
              hasMore: false,
            );
          };
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
      );

      await expectLater(
        sampler.runConfirmedSession((runPass) async {
          await runPass();
          persistedPasses++;
          return runPass();
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_native_auth_credentials_rejected',
          ),
        ),
      );

      expect(persistedPasses, 1);
      expect(prepareCalls, 2);
      expect(nativeWriterPause.pauseCalls, 1);
      expect(nativeWriterPause.resumeCalls, 1);
      expect(sampler.isActive, isFalse);
    },
  );

  test(
    'confirmed catch-up persists terminal head before one local-only sweep session',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{
        for (final zone in CloudSyncManualSemanticPullSampler.zones)
          zone: InMemoryCloudSyncStore(),
      };
      final chatScope = _semanticScope('chatManateeZone');
      await _seedRetainedSaves(stores[chatScope.zone]!, chatScope, count: 1);
      final events = <String>[];
      final persistedModes = <CloudSyncSemanticReportMode>[];
      final operationFenceStore = InMemoryCloudSyncStore();
      final nativeWriterPause = _RecordingNativeWriterPause(events: events);
      var ensureAuthCalls = 0;
      var prepareAuthCalls = 0;
      var rawTransportFactoryCalls = 0;
      var sweepCalls = 0;
      var terminalHeadPersisted = false;

      final sampler = _catchUpSampler(
        privateStorageDirectory: privateStorageDirectory,
        stores: stores,
        operationFenceStore: operationFenceStore,
        nativeWriterPause: nativeWriterPause,
        onEnsureAuth: () {
          ensureAuthCalls++;
          events.add('ensure-auth');
        },
        onPrepareAuth: () {
          prepareAuthCalls++;
          events.add('prepare-auth');
        },
        onCreateRawTransport: (scope) {
          rawTransportFactoryCalls++;
          events.add('transport:${scope.zone}');
        },
        onReprojectWindow:
            (
              scope,
              generation,
              leaseFence,
              afterFetchSequence,
              throughFetchSequence,
              limit,
            ) async {
              CloudKitOperationInterlock.requireActive(
                CloudKitOperationKind.v2SemanticRead,
              );
              sweepCalls++;
              events.add('sweep:${scope.zone}');
              expect(scope, chatScope);
              expect(generation, 1);
              expect(afterFetchSequence, 0);
              expect(throughFetchSequence, 1);
              expect(limit, 1);
              expect(terminalHeadPersisted, isTrue);
              expect(rawTransportFactoryCalls, 3);
              expect(ensureAuthCalls, 1);
              expect(prepareAuthCalls, 1);
              expect(nativeWriterPause.pauseCalls, 1);
              expect(nativeWriterPause.resumeCalls, 0);
              return const CloudRetainedProjectionWindowResult(
                examined: 1,
                reprojected: 0,
                retained: 1,
                lastExaminedSequence: 1,
                hasMoreWithinBound: false,
              );
            },
      );

      final result = await sampler.runConfirmedCatchUpAndPersist(
        projectionBatchSize: 1,
        persistReport: (report) async {
          persistedModes.add(report.mode);
          events.add('persist:${report.mode.wireName}');
          if (report.mode == CloudSyncSemanticReportMode.readOnlyCloudKit) {
            terminalHeadPersisted = true;
            expect(report.allZonesObservedEmptyTerminalRead, isTrue);
            expect(report.hasRetainedSaveBacklog, isTrue);
            return 'remote-head-report';
          }
          expect(sweepCalls, 1);
          return 'projection-sweep-report';
        },
      );

      expect(persistedModes, const [
        CloudSyncSemanticReportMode.readOnlyCloudKit,
        CloudSyncSemanticReportMode.retainedProjectionSweep,
      ]);
      expect(
        events.indexOf(
          'persist:${CloudSyncSemanticReportMode.readOnlyCloudKit.wireName}',
        ),
        lessThan(events.indexOf('sweep:chatManateeZone')),
      );
      expect(
        events.indexOf('sweep:chatManateeZone'),
        lessThan(
          events.indexOf(
            'persist:${CloudSyncSemanticReportMode.retainedProjectionSweep.wireName}',
          ),
        ),
      );
      expect(rawTransportFactoryCalls, 3);
      expect(ensureAuthCalls, 1);
      expect(prepareAuthCalls, 1);
      expect(nativeWriterPause.pauseCalls, 1);
      expect(nativeWriterPause.resumeCalls, 1);
      expect(events.last, 'resume-native-writers');
      expect(result.remotePasses, 1);
      expect(result.remoteDrained, isTrue);
      expect(result.lastRemoteReportReference, 'remote-head-report');
      expect(result.projectionReport, isNotNull);
      expect(result.projectionReportReference, 'projection-sweep-report');
      expect(sampler.isActive, isFalse);
    },
  );

  test(
    'transient server failure resumes writers before a fresh confirmed session',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{
        for (final zone in CloudSyncManualSemanticPullSampler.zones)
          zone: InMemoryCloudSyncStore(),
      };
      final operationFenceStore = InMemoryCloudSyncStore();
      final nativeWriterPause = _RecordingNativeWriterPause();
      final persistedReports = <CloudSyncSemanticPullReport>[];
      final waits = <Duration>[];
      var transportFactoryCalls = 0;
      late final CloudSyncManualSemanticPullSampler sampler;

      sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => stores[scope.zone]!,
        createRawTransport: (auth, scope, pauseToken) async {
          transportFactoryCalls++;
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler =
              (requestedScope, previousToken, generation, limit) async {
                if (nativeWriterPause.pauseCalls == 1 &&
                    requestedScope.zone == 'chatManateeZone') {
                  throw CloudSyncFailure(
                    category: CloudFailureCategory.server,
                    safeCode: 'http_server',
                  );
                }
                return CloudFetchBatch(
                  scope: requestedScope,
                  changes: const [],
                  batchId:
                      'terminal-${nativeWriterPause.pauseCalls}-${requestedScope.zone}',
                  generation: generation,
                  nextToken: previousToken,
                  hasMore: false,
                );
              };
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
        operationFenceStore: operationFenceStore,
        nativeWriterPause: nativeWriterPause,
        retryWait: (delay, cancellationToken) async {
          waits.add(delay);
          expect(cancellationToken.isCancelled, isFalse);
          expect(nativeWriterPause.pauseCalls, 1);
          expect(nativeWriterPause.resumeCalls, 1);
          expect(sampler.isActive, isTrue);
          final competingInterlock = CloudKitOperationInterlock(
            privateStorageDirectory: privateStorageDirectory.path,
            fenceStore: operationFenceStore,
          );
          await competingInterlock.runExclusive(
            kind: CloudKitOperationKind.legacyReadWrite,
            action: () async {},
          );
        },
      );

      final result = await sampler.runConfirmedCatchUpAndPersist(
        maximumRemotePasses: 3,
        persistReport: (report) async {
          persistedReports.add(report);
          return 'report-${persistedReports.length}';
        },
      );

      expect(waits, hasLength(1));
      expect(waits.single, lessThanOrEqualTo(const Duration(seconds: 60)));
      expect(persistedReports, hasLength(2));
      expect(persistedReports.first.unambiguousTransientTransportFailure, (
        category: CloudFailureCategory.server,
        safeCode: 'http_server',
      ));
      expect(result.remotePasses, 2);
      expect(result.remoteDrained, isTrue);
      expect(result.lastRemoteReportReference, 'report-2');
      expect(transportFactoryCalls, 6);
      expect(nativeWriterPause.pauseCalls, 2);
      expect(nativeWriterPause.resumeCalls, 2);
      expect(sampler.isActive, isFalse);
    },
  );

  test(
    'cancelling catch-up interrupts backoff without a new session',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{
        for (final zone in CloudSyncManualSemanticPullSampler.zones)
          zone: InMemoryCloudSyncStore(),
      };
      final nativeWriterPause = _RecordingNativeWriterPause();
      final waitEntered = Completer<void>();
      var transportFactoryCalls = 0;
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => stores[scope.zone]!,
        createRawTransport: (auth, scope, pauseToken) async {
          transportFactoryCalls++;
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler =
              (requestedScope, previousToken, generation, limit) async {
                if (requestedScope.zone == 'chatManateeZone') {
                  throw CloudSyncFailure(
                    category: CloudFailureCategory.network,
                    safeCode: 'network',
                  );
                }
                return CloudFetchBatch(
                  scope: requestedScope,
                  changes: const [],
                  batchId: 'terminal-${requestedScope.zone}',
                  generation: generation,
                  nextToken: previousToken,
                  hasMore: false,
                );
              };
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        retryWait: (delay, cancellationToken) async {
          waitEntered.complete();
          await cancellationToken.whenCancelled;
        },
      );

      final running = sampler.runConfirmedCatchUpAndPersist(
        maximumRemotePasses: 3,
        persistReport: (_) async => 'report',
      );
      await waitEntered.future;
      sampler.cancelActiveCatchUp();

      await expectLater(
        running,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_semantic_drain_cancelled',
          ),
        ),
      );
      expect(transportFactoryCalls, 3);
      expect(nativeWriterPause.pauseCalls, 1);
      expect(nativeWriterPause.resumeCalls, 1);
      expect(sampler.isActive, isFalse);
    },
  );

  test(
    'checkpoint generation change aborts retry before a new transport',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{
        for (final zone in CloudSyncManualSemanticPullSampler.zones)
          zone: InMemoryCloudSyncStore(),
      };
      final nativeWriterPause = _RecordingNativeWriterPause();
      var transportFactoryCalls = 0;
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => stores[scope.zone]!,
        createRawTransport: (auth, scope, pauseToken) async {
          transportFactoryCalls++;
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler =
              (requestedScope, previousToken, generation, limit) async {
                if (requestedScope.zone == 'chatManateeZone') {
                  throw CloudSyncFailure(
                    category: CloudFailureCategory.server,
                    safeCode: 'http_server',
                  );
                }
                return CloudFetchBatch(
                  scope: requestedScope,
                  changes: const [],
                  batchId: 'terminal-${requestedScope.zone}',
                  generation: generation,
                  nextToken: previousToken,
                  hasMore: false,
                );
              };
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        retryWait: (delay, cancellationToken) async {
          final scope = _semanticScope('chatManateeZone');
          await stores[scope.zone]!.advanceOutboxGeneration(
            scope,
            now: DateTime.now().toUtc(),
          );
        },
      );

      await expectLater(
        sampler.runConfirmedCatchUpAndPersist(
          maximumRemotePasses: 3,
          persistReport: (_) async => 'report',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_remote_head_checkpoint_unstable',
          ),
        ),
      );
      expect(transportFactoryCalls, 3);
      expect(nativeWriterPause.pauseCalls, 2);
      expect(nativeWriterPause.resumeCalls, 2);
      expect(sampler.isActive, isFalse);
    },
  );

  test(
    'checkpoint change aborts the local sweep before projection evidence',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{
        for (final zone in CloudSyncManualSemanticPullSampler.zones)
          zone: InMemoryCloudSyncStore(),
      };
      final chatScope = _semanticScope('chatManateeZone');
      final chatStore = stores[chatScope.zone]!;
      await _seedRetainedSaves(chatStore, chatScope, count: 1);
      final persistedModes = <CloudSyncSemanticReportMode>[];
      final nativeWriterPause = _RecordingNativeWriterPause();
      var rawTransportFactoryCalls = 0;

      final sampler = _catchUpSampler(
        privateStorageDirectory: privateStorageDirectory,
        stores: stores,
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        onCreateRawTransport: (_) => rawTransportFactoryCalls++,
        onReprojectWindow:
            (
              scope,
              generation,
              leaseFence,
              afterFetchSequence,
              throughFetchSequence,
              limit,
            ) async {
              final checkpoint = await chatStore.readCheckpoint(scope);
              await chatStore.journalFetchedBatch(
                CloudFetchBatch(
                  scope: scope,
                  changes: [_change('checkpoint-changed-during-sweep')],
                  batchId: 'checkpoint-changed-during-sweep',
                  generation: generation,
                  nextToken: 'checkpoint-changed-token',
                  hasMore: false,
                ),
                now: DateTime.now().toUtc(),
                leaseFence: leaseFence,
                expectedGeneration: generation,
                expectedFetchedToken: checkpoint.fetchedToken,
              );
              return const CloudRetainedProjectionWindowResult(
                examined: 1,
                reprojected: 0,
                retained: 1,
                lastExaminedSequence: 1,
                hasMoreWithinBound: false,
              );
            },
      );

      await expectLater(
        sampler.runConfirmedCatchUpAndPersist(
          projectionBatchSize: 1,
          persistReport: (report) async {
            persistedModes.add(report.mode);
            return 'report-${persistedModes.length}';
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_projection_sweep_checkpoint_changed',
          ),
        ),
      );

      expect(persistedModes, const [
        CloudSyncSemanticReportMode.readOnlyCloudKit,
      ]);
      expect(rawTransportFactoryCalls, 3);
      expect(nativeWriterPause.pauseCalls, 1);
      expect(nativeWriterPause.resumeCalls, 1);
      expect(sampler.isActive, isFalse);
    },
  );

  test('lease loss aborts a later local projection window safely', () async {
    final stores = <String, InMemoryCloudSyncStore>{
      for (final zone in CloudSyncManualSemanticPullSampler.zones)
        zone: InMemoryCloudSyncStore(),
    };
    final chatScope = _semanticScope('chatManateeZone');
    final chatStore = stores[chatScope.zone]!;
    await _seedRetainedSaves(chatStore, chatScope, count: 2);
    final persistedModes = <CloudSyncSemanticReportMode>[];
    final nativeWriterPause = _RecordingNativeWriterPause();
    var sweepCalls = 0;
    var rawTransportFactoryCalls = 0;

    final sampler = _catchUpSampler(
      privateStorageDirectory: privateStorageDirectory,
      stores: stores,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      onCreateRawTransport: (_) => rawTransportFactoryCalls++,
      onReprojectWindow:
          (
            scope,
            generation,
            leaseFence,
            afterFetchSequence,
            throughFetchSequence,
            limit,
          ) async {
            sweepCalls++;
            expect(sweepCalls, 1);
            expect(afterFetchSequence, 0);
            expect(throughFetchSequence, 2);
            expect(limit, 1);
            await chatStore.releaseCoordinatorLease(
              scope,
              leaseFence: leaseFence,
            );
            return const CloudRetainedProjectionWindowResult(
              examined: 1,
              reprojected: 0,
              retained: 1,
              lastExaminedSequence: 1,
              hasMoreWithinBound: true,
            );
          },
    );

    await expectLater(
      sampler.runConfirmedCatchUpAndPersist(
        projectionBatchSize: 1,
        persistReport: (report) async {
          persistedModes.add(report.mode);
          return 'report-${persistedModes.length}';
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_projection_sweep_lease_lost',
        ),
      ),
    );

    expect(persistedModes, const [
      CloudSyncSemanticReportMode.readOnlyCloudKit,
    ]);
    expect(sweepCalls, 1);
    expect(rawTransportFactoryCalls, 3);
    expect(nativeWriterPause.pauseCalls, 1);
    expect(nativeWriterPause.resumeCalls, 1);
    final replacementLease = await chatStore.tryAcquireCoordinatorLease(
      chatScope,
      ownerId: 'post-sweep-lease-loss',
      now: DateTime.now().toUtc(),
      leaseDuration: const Duration(minutes: 1),
    );
    expect(replacementLease, isNotNull);
    await chatStore.releaseCoordinatorLease(
      chatScope,
      leaseFence: replacementLease!,
    );
    expect(sampler.isActive, isFalse);
  });

  test(
    'projection report persistence is required before catch-up returns',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{
        for (final zone in CloudSyncManualSemanticPullSampler.zones)
          zone: InMemoryCloudSyncStore(),
      };
      final chatScope = _semanticScope('chatManateeZone');
      await _seedRetainedSaves(stores[chatScope.zone]!, chatScope, count: 1);
      final persistedModes = <CloudSyncSemanticReportMode>[];
      final nativeWriterPause = _RecordingNativeWriterPause();
      var sweepCalls = 0;

      final sampler = _catchUpSampler(
        privateStorageDirectory: privateStorageDirectory,
        stores: stores,
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        onReprojectWindow:
            (
              scope,
              generation,
              leaseFence,
              afterFetchSequence,
              throughFetchSequence,
              limit,
            ) async {
              sweepCalls++;
              return const CloudRetainedProjectionWindowResult(
                examined: 1,
                reprojected: 0,
                retained: 1,
                lastExaminedSequence: 1,
                hasMoreWithinBound: false,
              );
            },
      );

      await expectLater(
        sampler.runConfirmedCatchUpAndPersist(
          projectionBatchSize: 1,
          persistReport: (report) async {
            persistedModes.add(report.mode);
            if (report.mode ==
                CloudSyncSemanticReportMode.retainedProjectionSweep) {
              throw StateError('projection-report-persist-failed');
            }
            return 'remote-head-report';
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'projection-report-persist-failed',
          ),
        ),
      );

      expect(persistedModes, const [
        CloudSyncSemanticReportMode.readOnlyCloudKit,
        CloudSyncSemanticReportMode.retainedProjectionSweep,
      ]);
      expect(sweepCalls, 1);
      expect(nativeWriterPause.pauseCalls, 1);
      expect(nativeWriterPause.resumeCalls, 1);
      expect(sampler.isActive, isFalse);
    },
  );

  test('native writer pause failure performs no semantic work', () async {
    var preflightCalls = 0;
    final nativeWriterPause = _RecordingNativeWriterPause(
      pauseError: StateError('cloud_sync_native_writer_pause_timeout'),
    );
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      readPreflight: () async {
        preflightCalls++;
        return _readyState();
      },
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async =>
          FakeCloudSyncTransport(),
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    await expectLater(
      sampler.runConfirmed(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_writer_pause_timeout',
        ),
      ),
    );
    expect(preflightCalls, 0);
    expect(nativeWriterPause.pauseCalls, 1);
    expect(nativeWriterPause.resumeCalls, 0);
    expect(sampler.isActive, isFalse);
  });

  test(
    'unconfirmed native pause cleanup keeps the sampler fail-closed',
    () async {
      final nativeWriterPause = _RecordingNativeWriterPause(
        pauseError: const CloudSyncNativeWriterPauseUncertain(),
      );
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => InMemoryCloudSyncStore(),
        createRawTransport: (auth, scope, pauseToken) async =>
            FakeCloudSyncTransport(),
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
      );

      await expectLater(
        sampler.runConfirmed(),
        throwsA(isA<CloudSyncNativeWriterPauseUncertain>()),
      );
      expect(nativeWriterPause.resumeCalls, 0);
      expect(sampler.isActive, isTrue);
      await expectLater(sampler.runConfirmed(), throwsStateError);
    },
  );

  test('unconfirmed native resume keeps the sampler fail-closed', () async {
    final nativeWriterPause = _RecordingNativeWriterPause(
      resumeError: StateError('cloud_sync_native_writer_resume_failed'),
    );
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      readPreflight: () async => throw StateError('preflight-failed'),
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async =>
          FakeCloudSyncTransport(),
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    await expectLater(sampler.runConfirmed(), throwsStateError);
    expect(nativeWriterPause.resumeCalls, 1);
    expect(sampler.isActive, isTrue);
    await expectLater(sampler.runConfirmed(), throwsStateError);
  });

  test('native writer pause resumes after a semantic failure', () async {
    final nativeWriterPause = _RecordingNativeWriterPause();
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      readPreflight: () async => throw StateError('preflight-failed'),
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async =>
          FakeCloudSyncTransport(),
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    await expectLater(sampler.runConfirmed(), throwsStateError);
    expect(nativeWriterPause.pauseCalls, 1);
    expect(nativeWriterPause.resumeCalls, 1);
    expect(sampler.isActive, isFalse);
  });

  for (final safeCode in <String>[
    'cloud_sync_native_auth_credentials_unavailable',
    'cloud_sync_native_auth_credentials_rejected',
  ]) {
    test('retries one complete paused read after $safeCode', () async {
      var ensureCalls = 0;
      var prepareCalls = 0;
      final nativeWriterPause = _RecordingNativeWriterPause();
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        nativeWriterPause: nativeWriterPause,
        ensureAuthSnapshot: () async {
          ensureCalls++;
          return _auth();
        },
        readPreflight: () async => _readyState(),
        prepareAuthSnapshot: (pauseToken, expectedAuth) async {
          prepareCalls++;
          if (prepareCalls == 1) throw StateError(safeCode);
          return _auth();
        },
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async => InMemoryCloudSyncStore(),
        createRawTransport: (auth, scope, pauseToken) async =>
            FakeCloudSyncTransport(),
        createInboxApplier: (auth, scope, generation) async =>
            FakeCloudInboxApplier(),
      );

      await sampler.runConfirmed();

      expect(ensureCalls, 2);
      expect(prepareCalls, 2);
      expect(nativeWriterPause.pauseCalls, 2);
      expect(nativeWriterPause.resumeCalls, 2);
      expect(sampler.isActive, isFalse);
    });

    test(
      'retries when authentication ensure itself throws $safeCode',
      () async {
        var ensureCalls = 0;
        final nativeWriterPause = _RecordingNativeWriterPause();
        final sampler = _sampler(
          privateStorageDirectory: privateStorageDirectory,
          operationFenceStore: InMemoryCloudSyncStore(),
          nativeWriterPause: nativeWriterPause,
          ensureAuthSnapshot: () async {
            ensureCalls++;
            if (ensureCalls == 1) throw StateError(safeCode);
            return _auth();
          },
          readPreflight: () async => _readyState(),
          readAuthSnapshot: () async => _auth(),
          createStore: (scope) async => InMemoryCloudSyncStore(),
          createRawTransport: (auth, scope, pauseToken) async =>
              FakeCloudSyncTransport(),
          createInboxApplier: (auth, scope, generation) async =>
              FakeCloudInboxApplier(),
        );

        await sampler.runConfirmed();

        expect(ensureCalls, 2);
        expect(nativeWriterPause.pauseCalls, 1);
        expect(nativeWriterPause.resumeCalls, 1);
        expect(sampler.isActive, isFalse);
      },
    );
  }

  test('account replacement between ensure and pause fails closed', () async {
    final nativeWriterPause = _RecordingNativeWriterPause();
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      ensureAuthSnapshot: () async => _auth(client: _nativeClientA),
      readPreflight: () async => _readyState(),
      prepareAuthSnapshot: (pauseToken, expectedAuth) async => _auth(
        session: 'session-b',
        fingerprint: _accountFingerprintB,
        client: _nativeClientB,
      ),
      readAuthSnapshot: () async => _auth(client: _nativeClientB),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async =>
          FakeCloudSyncTransport(),
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
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
    expect(nativeWriterPause.pauseCalls, 1);
    expect(nativeWriterPause.resumeCalls, 1);
    expect(sampler.isActive, isFalse);
  });

  test('authentication ensure failure never pauses native writers', () async {
    var preflightCalls = 0;
    final nativeWriterPause = _RecordingNativeWriterPause();
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      ensureAuthSnapshot: () async =>
          throw StateError('cloud_sync_native_auth_refresh_session_missing'),
      readPreflight: () async {
        preflightCalls++;
        return _readyState();
      },
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async =>
          FakeCloudSyncTransport(),
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    await expectLater(
      sampler.runConfirmed(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_auth_refresh_session_missing',
        ),
      ),
    );
    expect(preflightCalls, 0);
    expect(nativeWriterPause.pauseCalls, 0);
    expect(nativeWriterPause.resumeCalls, 0);
    expect(sampler.isActive, isFalse);
  });

  test('does not retry an unrelated native authentication failure', () async {
    var ensureCalls = 0;
    var prepareCalls = 0;
    final nativeWriterPause = _RecordingNativeWriterPause();
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      ensureAuthSnapshot: () async {
        ensureCalls++;
        return _auth();
      },
      readPreflight: () async => _readyState(),
      prepareAuthSnapshot: (pauseToken, expectedAuth) async {
        prepareCalls++;
        throw StateError('cloud_sync_native_auth_messages_container_failed');
      },
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async =>
          FakeCloudSyncTransport(),
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    await expectLater(
      sampler.runConfirmed(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_auth_messages_container_failed',
        ),
      ),
    );
    expect(ensureCalls, 1);
    expect(prepareCalls, 1);
    expect(nativeWriterPause.pauseCalls, 1);
    expect(nativeWriterPause.resumeCalls, 1);
    expect(sampler.isActive, isFalse);
  });

  test('credentials rejection is retried at most once', () async {
    var ensureCalls = 0;
    var prepareCalls = 0;
    final nativeWriterPause = _RecordingNativeWriterPause();
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      nativeWriterPause: nativeWriterPause,
      ensureAuthSnapshot: () async {
        ensureCalls++;
        return _auth();
      },
      readPreflight: () async => _readyState(),
      prepareAuthSnapshot: (pauseToken, expectedAuth) async {
        prepareCalls++;
        throw StateError('cloud_sync_native_auth_credentials_rejected');
      },
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async => InMemoryCloudSyncStore(),
      createRawTransport: (auth, scope, pauseToken) async =>
          FakeCloudSyncTransport(),
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    await expectLater(
      sampler.runConfirmed(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_auth_credentials_rejected',
        ),
      ),
    );
    expect(ensureCalls, 2);
    expect(prepareCalls, 2);
    expect(nativeWriterPause.pauseCalls, 2);
    expect(nativeWriterPause.resumeCalls, 2);
    expect(sampler.isActive, isFalse);
  });

  for (final testCase in <({String input, String expected})>[
    (input: 'network', expected: 'network'),
    (input: 'http-unknown', expected: 'http-unknown'),
    (input: 'cloudkit-reset-required', expected: 'cloudkit-reset-required'),
    (
      input: 'cloudkit-change-token-expired',
      expected: 'cloudkit-change-token-expired',
    ),
    (input: 'malformed-response', expected: 'malformed-response'),
    (
      input: 'unreviewed_but_pattern_safe',
      expected: 'cloud_sync_unknown_failure',
    ),
  ]) {
    test(
      'reports only allowlisted pull failure safe codes: ${testCase.input}',
      () async {
        final sampler = _sampler(
          privateStorageDirectory: privateStorageDirectory,
          operationFenceStore: InMemoryCloudSyncStore(),
          readPreflight: () async => _readyState(),
          readAuthSnapshot: () async => _auth(),
          createStore: (scope) async => InMemoryCloudSyncStore(),
          createRawTransport: (auth, scope, pauseToken) async {
            final transport = FakeCloudSyncTransport();
            transport.fetchHandler = (scope, token, generation, limit) async {
              if (scope.zone == 'chatManateeZone') {
                throw CloudSyncFailure(
                  category: CloudFailureCategory.network,
                  safeCode: testCase.input,
                );
              }
              return CloudFetchBatch(
                scope: scope,
                changes: const [],
                batchId: 'empty-${scope.zone}',
                generation: generation,
                nextToken: null,
                hasMore: false,
              );
            };
            return transport;
          },
          createInboxApplier: (auth, scope, generation) async =>
              FakeCloudInboxApplier(),
        );

        final report = await sampler.runConfirmed();
        final failedZone = report.zones.singleWhere(
          (zone) => zone.zoneLabel == 'chats',
        );

        expect(failedZone.failureCategory, CloudFailureCategory.network);
        expect(failedZone.failureSafeCode, testCase.expected);
        expect(failedZone.toJson()['failureSafeCode'], testCase.expected);
        expect(
          report.zones
              .where((zone) => zone.zoneLabel != 'chats')
              .map((zone) => zone.failureSafeCode),
          everyElement(isNull),
        );
      },
    );
  }

  test(
    'zone report rejects invalid code text and omits codes without failures',
    () {
      final invalid = _zoneReport(
        failureCategory: CloudFailureCategory.network,
        failureSafeCode: 'invalid code text',
      );
      final completedWithCode = _zoneReport(failureSafeCode: 'http-unknown');

      expect(invalid.failureSafeCode, 'cloud_sync_unknown_failure');
      expect(invalid.toJson()['failureSafeCode'], 'cloud_sync_unknown_failure');
      expect(completedWithCode.failureSafeCode, isNull);
      expect(completedWithCode.toJson()['failureSafeCode'], isNull);
    },
  );

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
        prepareAuthSnapshot: (pauseToken, expectedAuth) async {
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
        createRawTransport: (snapshot, scope, pauseToken) async =>
            FakeCloudSyncTransport(),
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
        tombstoneReadOnlyAcknowledged: 2,
        semanticUnsupportedServiceQuarantined: 1,
        semanticStageQuarantined: 0,
        retried: 0,
        elapsedMilliseconds: 1,
        observedEmptyTerminalRead: true,
        diagnosticCounts: const {'native_quarantined_unsupported_service': 1},
      );

      final json = zone.toJson();

      expect(json['quarantinePhases'], <String, int>{
        'startup': 1,
        'postFetch': 2,
      });
      expect(json['tombstoneQuarantined'], 1);
      expect(json['tombstoneReadOnlyAcknowledged'], 2);
      expect(json['semanticUnsupportedServiceQuarantined'], 1);
      expect(json['semanticDiagnostics'], <String, int>{
        'native_quarantined_unsupported_service': 1,
      });
      expect(json['observedEmptyTerminalRead'], isTrue);
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
        createRawTransport: (auth, scope, pauseToken) async {
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
        createRawTransport: (auth, scope, pauseToken) async {
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
      expect(report.zones.map((zone) => zone.tombstoneReadOnlyAcknowledged), [
        0,
        0,
        0,
      ]);
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
    'durable retained tombstone keeps a no-change follow-up report Partial',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{};
      final transports = <String, FakeCloudSyncTransport>{};
      final fetchCounts = <String, int>{};
      final appliers = <_ReadOnlyTombstoneFakeCloudInboxApplier>[];
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async =>
            stores.putIfAbsent(scope.zone, InMemoryCloudSyncStore.new),
        createRawTransport: (auth, scope, pauseToken) async {
          return transports.putIfAbsent(scope.zone, () {
            final transport = FakeCloudSyncTransport();
            transport.fetchHandler =
                (requestedScope, previousToken, generation, limit) async {
                  final fetchCount = fetchCounts.update(
                    requestedScope.zone,
                    (value) => value + 1,
                    ifAbsent: () => 1,
                  );
                  if (requestedScope.zone == 'messageManateeZone' &&
                      previousToken == null) {
                    return CloudFetchBatch(
                      scope: requestedScope,
                      changes: [_tombstone('retained-message-tombstone')],
                      batchId: 'retained-message-tombstone-page',
                      generation: generation,
                      nextToken: 'after-retained-message-tombstone',
                      hasMore: false,
                    );
                  }
                  return CloudFetchBatch(
                    scope: requestedScope,
                    changes: const [],
                    batchId: 'empty-${requestedScope.zone}-$fetchCount',
                    generation: generation,
                    nextToken: previousToken,
                    hasMore: false,
                  );
                };
            return transport;
          });
        },
        createInboxApplier: (auth, scope, generation) async {
          final applier = _ReadOnlyTombstoneFakeCloudInboxApplier();
          appliers.add(applier);
          return applier;
        },
      );

      final firstReport = await sampler.runConfirmed();
      final firstMessageZone = firstReport.zones.singleWhere(
        (zone) => zone.zoneLabel == 'messages',
      );
      expect(firstMessageZone.status, CloudSyncRunStatus.degraded);
      expect(
        firstMessageZone.failureSafeCode,
        'retained_projection_incomplete',
      );
      expect(firstMessageZone.tombstoneReadOnlyAcknowledged, 1);
      expect(firstMessageZone.retainedUnprojected, 1);
      expect(
        firstMessageZone.diagnosticCounts,
        containsPair('retained_backlog_summary_ready', 1),
      );
      expect(
        firstMessageZone.diagnosticCounts,
        containsPair('retained_backlog_total', 1),
      );
      expect(
        firstMessageZone.diagnosticCounts,
        containsPair('retained_backlog_tombstones', 1),
      );
      expect(
        firstMessageZone.diagnosticCounts,
        containsPair('retained_backlog_unclassified', 1),
      );
      expect(
        cloudSyncV2SemanticCanaryPresentation(firstReport).outcome,
        CloudSyncV2SemanticCanaryOutcome.partial,
      );

      final secondReport = await sampler.runConfirmed();
      final secondMessageZone = secondReport.zones.singleWhere(
        (zone) => zone.zoneLabel == 'messages',
      );
      expect(secondMessageZone.status, CloudSyncRunStatus.degraded);
      expect(
        secondMessageZone.failureSafeCode,
        'retained_projection_incomplete',
      );
      expect(secondMessageZone.fetched, 0);
      expect(secondMessageZone.tombstoneReadOnlyAcknowledged, 0);
      expect(secondMessageZone.retainedUnprojected, 1);
      expect(
        secondMessageZone.diagnosticCounts,
        containsPair('retained_backlog_summary_ready', 1),
      );
      expect(
        secondMessageZone.diagnosticCounts,
        containsPair('retained_backlog_total', 1),
      );
      expect(
        secondMessageZone.diagnosticCounts,
        containsPair('retained_backlog_tombstones', 1),
      );
      final secondPresentation = cloudSyncV2SemanticCanaryPresentation(
        secondReport,
      );
      expect(
        secondPresentation.outcome,
        CloudSyncV2SemanticCanaryOutcome.partial,
      );
      expect(secondPresentation.title, 'Cloud Sync V2 Partial');

      final messageScope = CloudSyncScope(
        accountFingerprint: _accountFingerprintA,
        container: CloudSyncManualSemanticPullSampler.container,
        database: CloudSyncManualSemanticPullSampler.database,
        zone: 'messageManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final messageStore = stores['messageManateeZone']!;
      final durableRows = await messageStore.inboxEntries(messageScope);
      expect(durableRows, hasLength(1));
      expect(durableRows.single.status, CloudInboxStatus.retainedUnprojected);
      expect(durableRows.single.change.isTombstone, isTrue);
      expect(
        durableRows.single.change.encryptedServerRecordId,
        'protected:server-retained-message-tombstone',
      );
      expect(
        await messageStore.readRetainedUnprojectedInboxCount(messageScope),
        1,
      );
      expect(
        appliers.fold<int>(0, (total, applier) => total + applier.applyCalls),
        1,
      );
      expect(
        transports.values.every((transport) => transport.pushCallCount == 0),
        isTrue,
      );
      expect(firstReport.remoteWriteTripwiresIntact, isTrue);
      expect(secondReport.remoteWriteTripwiresIntact, isTrue);
    },
  );

  test('pulls four pages per zone without writes or outbox changes', () async {
    final transports = <String, FakeCloudSyncTransport>{};
    final sampler = _sampler(
      privateStorageDirectory: privateStorageDirectory,
      operationFenceStore: InMemoryCloudSyncStore(),
      readPreflight: () async => _readyState(),
      readAuthSnapshot: () async => _auth(),
      createStore: (scope) async {
        final store = InMemoryCloudSyncStore();
        return store;
      },
      createRawTransport: (auth, scope, pauseToken) async {
        final transport = FakeCloudSyncTransport();
        transport.fetchHandler = (requestedScope, token, generation, limit) {
          final page = transport.fetchCallCount;
          expect(limit, 50);
          return Future.value(
            CloudFetchBatch(
              scope: requestedScope,
              changes: [
                for (var index = 0; index < 50; index++)
                  _change('${requestedScope.zone}-$page-$index'),
              ],
              batchId: '${requestedScope.zone}-$page',
              generation: generation,
              nextToken: 'token-$page',
              hasMore: true,
            ),
          );
        };
        transports[scope.zone] = transport;
        return transport;
      },
      createInboxApplier: (auth, scope, generation) async =>
          FakeCloudInboxApplier(),
    );

    final report = await sampler.runConfirmed();

    expect(report.pageLimit, 4);
    expect(report.changeLimit, 50);
    expect(report.outboxCountBefore, 0);
    expect(report.outboxCountAfter, 0);
    expect(report.zones.map((zone) => zone.fetched), [200, 200, 200]);
    expect(transports.values.map((transport) => transport.fetchCallCount), [
      4,
      4,
      4,
    ]);
    expect(transports.values.map((transport) => transport.pushCallCount), [
      0,
      0,
      0,
    ]);
  });

  test(
    'Canary retains a known attachment dependency and fetches its parent page',
    () async {
      final stores = <String, InMemoryCloudSyncStore>{};
      final attachmentTransport = FakeCloudSyncTransport();
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async =>
            stores.putIfAbsent(scope.zone, InMemoryCloudSyncStore.new),
        createRawTransport: (auth, scope, pauseToken) async {
          if (scope.zone != 'attachmentManateeZone') {
            final transport = FakeCloudSyncTransport();
            transport.fetchHandler =
                (requestedScope, token, generation, limit) async =>
                    CloudFetchBatch(
                      scope: requestedScope,
                      changes: const [],
                      batchId: 'empty-${requestedScope.zone}',
                      generation: generation,
                      nextToken: token,
                      hasMore: false,
                    );
            return transport;
          }
          attachmentTransport.fetchHandler =
              (requestedScope, token, generation, limit) async {
                switch (token) {
                  case null:
                    return CloudFetchBatch(
                      scope: requestedScope,
                      changes: [_change('attachment-without-parent')],
                      batchId: 'attachment-dependency-page',
                      generation: generation,
                      nextToken: 'attachment-parent-page',
                      hasMore: true,
                    );
                  case 'attachment-parent-page':
                    return CloudFetchBatch(
                      scope: requestedScope,
                      changes: [_change('attachment-parent')],
                      batchId: 'attachment-parent-page-two',
                      generation: generation,
                      nextToken: 'attachment-complete-token',
                      hasMore: false,
                    );
                  default:
                    fail('unexpected attachment continuation token: $token');
                }
              };
          return attachmentTransport;
        },
        createInboxApplier: (auth, scope, generation) async {
          final applier = FakeCloudInboxApplier();
          if (scope.zone == 'attachmentManateeZone') {
            applier.handler = (entry) async => entry.sequence == 1
                ? const CloudInboxApplyResult.deferred(
                    failureCategory: CloudFailureCategory.dependency,
                    safeCode: 'semantic_parent_missing',
                  )
                : const CloudInboxApplyResult.applied();
          }
          return applier;
        },
      );

      final report = await sampler.runConfirmed();

      final attachmentZone = report.zones.singleWhere(
        (zone) => zone.zoneLabel == 'attachments',
      );
      expect(attachmentZone.status, CloudSyncRunStatus.degraded);
      expect(attachmentZone.failureSafeCode, 'retained_projection_incomplete');
      expect(attachmentZone.retainedUnprojected, 1);
      expect(attachmentZone.deferred, 0);
      expect(attachmentZone.quarantined, 0);
      expect(attachmentZone.applied, 1);
      expect(attachmentTransport.observedFetchTokens, [
        null,
        'attachment-parent-page',
      ]);
      expect(report.remoteWriteTripwiresIntact, isTrue);
      expect(
        (await stores['attachmentManateeZone']!.inboxEntries(
          CloudSyncScope(
            accountFingerprint: _accountFingerprintA,
            container: CloudSyncManualSemanticPullSampler.container,
            database: CloudSyncManualSemanticPullSampler.database,
            zone: 'attachmentManateeZone',
            persistenceLane: CloudSyncPersistenceLane.semantic,
          ),
        )).where((entry) => entry.status == CloudInboxStatus.quarantined),
        isEmpty,
      );
    },
  );

  test(
    'repairs applied chat and attachment projections before transport',
    () async {
      final events = <String>[];
      final stores = <String, InMemoryCloudSyncStore>{};
      late _RepairingFakeCloudInboxApplier chatApplier;
      late _RepairingFakeCloudInboxApplier attachmentApplier;
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
        createRawTransport: (auth, scope, pauseToken) async {
          events.add('transport:${scope.zone}');
          return FakeCloudSyncTransport();
        },
        createInboxApplier: (auth, scope, generation) async {
          events.add('applier:${scope.zone}');
          if (scope.zone == 'chatManateeZone' ||
              scope.zone == 'attachmentManateeZone') {
            final repairingApplier = _RepairingFakeCloudInboxApplier(
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
            if (scope.zone == 'chatManateeZone') {
              chatApplier = repairingApplier;
            } else {
              attachmentApplier = repairingApplier;
            }
            return repairingApplier;
          }
          return FakeCloudInboxApplier();
        },
      );

      await sampler.runConfirmed();

      expect(chatApplier.repairCalls, 1);
      expect(attachmentApplier.repairCalls, 1);
      expect(events, const [
        'applier:chatManateeZone',
        'repair:chatManateeZone',
        'transport:chatManateeZone',
        'applier:messageManateeZone',
        'transport:messageManateeZone',
        'applier:attachmentManateeZone',
        'repair:attachmentManateeZone',
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
    'scans the bounded legacy ownership window before message transport',
    () async {
      final events = <String>[];
      final stores = <String, InMemoryCloudSyncStore>{};
      late _LegacyOwnershipRepairingFakeCloudInboxApplier messageApplier;
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
        createRawTransport: (auth, scope, pauseToken) async {
          events.add('transport:${scope.zone}');
          return FakeCloudSyncTransport();
        },
        createInboxApplier: (auth, scope, generation) async {
          events.add('applier:${scope.zone}');
          if (scope.zone == 'messageManateeZone') {
            messageApplier = _LegacyOwnershipRepairingFakeCloudInboxApplier(
              repairResults: const [1],
              onRepair: (repairScope, repairGeneration, leaseFence, limit) {
                events.add('ownership:${repairScope.zone}');
                expect(repairGeneration, generation);
                expect(leaseFence.ownerId, contains(auth.nativeSessionId));
                expect(
                  limit,
                  CloudSyncManualSemanticPullSampler
                      .maximumLegacyOwnershipRepairCandidates,
                );
              },
            );
            return messageApplier;
          }
          return FakeCloudInboxApplier();
        },
      );

      await sampler.runConfirmed();

      expect(messageApplier.repairCalls, 1);
      expect(events, const [
        'applier:chatManateeZone',
        'transport:chatManateeZone',
        'applier:messageManateeZone',
        'ownership:messageManateeZone',
        'transport:messageManateeZone',
        'applier:attachmentManateeZone',
        'transport:attachmentManateeZone',
      ]);
      final messageScope = CloudSyncScope(
        accountFingerprint: _accountFingerprintA,
        container: CloudSyncManualSemanticPullSampler.container,
        database: CloudSyncManualSemanticPullSampler.database,
        zone: 'messageManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final replacementLease = await stores['messageManateeZone']!
          .tryAcquireCoordinatorLease(
            messageScope,
            ownerId: 'post-ownership-repair-test-owner',
            now: DateTime.now().toUtc(),
            leaseDuration: const Duration(minutes: 1),
          );
      expect(replacementLease, isNotNull);
      await stores['messageManateeZone']!.releaseCoordinatorLease(
        messageScope,
        leaseFence: replacementLease!,
      );
    },
  );

  test(
    'normal engine reprojects retained rows for every capable semantic zone',
    () async {
      final events = <String>[];
      final stores = <String, InMemoryCloudSyncStore>{};
      final reprocessors = <String, _RetainedProjectionFakeApplier>{};
      final fetchCounts = <String, int>{};
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
        createRawTransport: (auth, scope, pauseToken) async {
          events.add('transport:${scope.zone}');
          final transport = FakeCloudSyncTransport();
          transport.fetchHandler =
              (requestedScope, previousToken, generation, limit) async {
                events.add('fetch:${requestedScope.zone}');
                expect(limit, CloudSyncManualSemanticPullSampler.changeLimit);
                final page = (fetchCounts[requestedScope.zone] ?? 0) + 1;
                fetchCounts[requestedScope.zone] = page;
                final firstChange =
                    (page - 1) * CloudSyncManualSemanticPullSampler.changeLimit;
                return CloudFetchBatch(
                  scope: requestedScope,
                  changes: List.generate(
                    CloudSyncManualSemanticPullSampler.changeLimit,
                    (index) => _change(
                      '${requestedScope.zone}-${firstChange + index}',
                    ),
                  ),
                  batchId: 'retained-${requestedScope.zone}-$page',
                  generation: generation,
                  nextToken: 'retained-${requestedScope.zone}-token-$page',
                  hasMore: page < CloudSyncManualSemanticPullSampler.pageLimit,
                );
              };
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async {
          events.add('applier:${scope.zone}');
          final applier = _RetainedProjectionFakeApplier(
            onReproject:
                (reprojectScope, reprojectGeneration, leaseFence, limit) async {
                  events.add('retained:${reprojectScope.zone}');
                  expect(reprojectGeneration, generation);
                  expect(leaseFence.ownerId, contains(auth.nativeSessionId));
                  expect(
                    limit,
                    CloudSyncManualSemanticPullSampler
                        .retainedProjectionAllowance,
                  );
                  return CloudRetainedProjectionResult(
                    examined: limit,
                    reprojected: limit,
                    retained: 0,
                  );
                },
          );
          reprocessors[scope.zone] = applier;
          return applier;
        },
      );

      final report = await sampler.runConfirmed();

      final expectedEvents = <String>[];
      for (final zone in CloudSyncManualSemanticPullSampler.zones) {
        expectedEvents.addAll([
          'applier:$zone',
          'transport:$zone',
          'retained:$zone',
          ...List.filled(
            CloudSyncManualSemanticPullSampler.pageLimit,
            'fetch:$zone',
          ),
        ]);
        expect(events.where((event) => event == 'fetch:$zone').length, 4);
        expect(fetchCounts[zone], CloudSyncManualSemanticPullSampler.pageLimit);
      }
      expect(events, expectedEvents);
      expect(reprocessors.values.map((applier) => applier.reprojectCalls), [
        1,
        1,
        1,
      ]);
      for (final zone in report.zones) {
        expect(
          zone.fetched,
          CloudSyncManualSemanticPullSampler.pageLimit *
              CloudSyncManualSemanticPullSampler.changeLimit,
        );
        expect(
          zone.applied,
          CloudSyncManualSemanticPullSampler.pageLimit *
                  CloudSyncManualSemanticPullSampler.changeLimit +
              CloudSyncManualSemanticPullSampler.retainedProjectionAllowance,
        );
      }

      for (final zone in CloudSyncManualSemanticPullSampler.zones) {
        final scope = CloudSyncScope(
          accountFingerprint: _accountFingerprintA,
          container: CloudSyncManualSemanticPullSampler.container,
          database: CloudSyncManualSemanticPullSampler.database,
          zone: zone,
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        final replacementLease = await stores[zone]!.tryAcquireCoordinatorLease(
          scope,
          ownerId: 'post-retained-reprojection-$zone',
          now: DateTime.now().toUtc(),
          leaseDuration: const Duration(minutes: 1),
        );
        expect(replacementLease, isNotNull);
        await stores[zone]!.releaseCoordinatorLease(
          scope,
          leaseFence: replacementLease!,
        );
      }
    },
  );

  test(
    'retained projection failure releases engine lease and skips remote fetch',
    () async {
      final events = <String>[];
      final transports = <String, FakeCloudSyncTransport>{};
      late InMemoryCloudSyncStore chatStore;
      final sampler = _sampler(
        privateStorageDirectory: privateStorageDirectory,
        operationFenceStore: InMemoryCloudSyncStore(),
        readPreflight: () async => _readyState(),
        readAuthSnapshot: () async => _auth(),
        createStore: (scope) async {
          final store = InMemoryCloudSyncStore();
          if (scope.zone == 'chatManateeZone') chatStore = store;
          return store;
        },
        createRawTransport: (auth, scope, pauseToken) async {
          events.add('transport:${scope.zone}');
          final transport = FakeCloudSyncTransport();
          transports[scope.zone] = transport;
          return transport;
        },
        createInboxApplier: (auth, scope, generation) async {
          if (scope.zone != 'chatManateeZone') return FakeCloudInboxApplier();
          return _RetainedProjectionFakeApplier(
            onReproject: (scope, generation, leaseFence, limit) async {
              events.add('retained-failure:${scope.zone}');
              throw StateError('retained_projection_test_failure');
            },
          );
        },
      );

      final report = await sampler.runConfirmed();

      expect(events, const [
        'transport:chatManateeZone',
        'retained-failure:chatManateeZone',
        'transport:messageManateeZone',
        'transport:attachmentManateeZone',
      ]);
      expect(report.zones.first.status, CloudSyncRunStatus.failed);
      expect(report.zones.first.failureCategory, CloudFailureCategory.unknown);
      expect(transports['chatManateeZone']!.fetchCallCount, 0);
      final scope = CloudSyncScope(
        accountFingerprint: _accountFingerprintA,
        container: CloudSyncManualSemanticPullSampler.container,
        database: CloudSyncManualSemanticPullSampler.database,
        zone: 'chatManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final replacementLease = await chatStore.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'post-retained-failure-test-owner',
        now: DateTime.now().toUtc(),
        leaseDuration: const Duration(minutes: 1),
      );
      expect(replacementLease, isNotNull);
      await chatStore.releaseCoordinatorLease(
        scope,
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
        createRawTransport: (auth, scope, pauseToken) async {
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
        createRawTransport: (auth, scope, pauseToken) async {
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
        createRawTransport: (auth, scope, pauseToken) async {
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

final class _ReadOnlyTombstoneFakeCloudInboxApplier
    implements CloudInboxApplier, CloudReadOnlyTombstoneAcknowledgementPolicy {
  int applyCalls = 0;

  @override
  bool get readOnlyTombstoneAcknowledgementsEnabled => true;

  @override
  Future<CloudInboxApplyResult> apply(
    CloudInboxEntry entry, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    applyCalls++;
    return entry.change.isTombstone
        ? const CloudInboxApplyResult.tombstoneReadOnlyAcknowledged()
        : const CloudInboxApplyResult.applied();
  }
}

final class _RecordingNativeWriterPause implements CloudSyncNativeWriterPause {
  _RecordingNativeWriterPause({this.events, this.pauseError, this.resumeError});

  final List<String>? events;
  final Object? pauseError;
  final Object? resumeError;
  final Object token = Object();
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  Future<Object> pause() async {
    pauseCalls++;
    events?.add('pause-native-writers');
    final error = pauseError;
    if (error != null) throw error;
    return token;
  }

  @override
  Future<void> resume(Object value) async {
    expect(value, same(token));
    resumeCalls++;
    events?.add('resume-native-writers');
    final error = resumeError;
    if (error != null) throw error;
  }
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

typedef _RetainedProjectionCallback =
    Future<CloudRetainedProjectionResult> Function(
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

final class _LegacyOwnershipRepairingFakeCloudInboxApplier
    extends FakeCloudInboxApplier
    implements CloudLegacyOwnershipRepairer {
  _LegacyOwnershipRepairingFakeCloudInboxApplier({
    required List<int> repairResults,
    required this.onRepair,
  }) : _repairResults = List<int>.of(repairResults);

  final List<int> _repairResults;
  final _ProjectionRepairCallback onRepair;
  int repairCalls = 0;

  @override
  Future<int> repairLegacyOwnershipEvidence({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  }) async {
    repairCalls++;
    onRepair(scope, generation, leaseFence, limit);
    return _repairResults.removeAt(0);
  }
}

final class _RetainedProjectionFakeApplier extends FakeCloudInboxApplier
    implements CloudRetainedProjectionReprocessor {
  _RetainedProjectionFakeApplier({required this.onReproject});

  final _RetainedProjectionCallback onReproject;
  int reprojectCalls = 0;

  @override
  Future<CloudRetainedProjectionResult> reprojectRetainedUnprojected({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  }) async {
    reprojectCalls++;
    return onReproject(scope, generation, leaseFence, limit);
  }
}

final class _RetainedProjectionWindowFakeApplier extends FakeCloudInboxApplier
    implements CloudRetainedProjectionWindowReprocessor {
  _RetainedProjectionWindowFakeApplier({required this.onReproject});

  final _RetainedProjectionWindowCallback onReproject;

  @override
  Future<CloudRetainedProjectionWindowResult> reprojectRetainedSaveWindow({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int afterFetchSequence,
    required int throughFetchSequence,
    required int limit,
  }) => onReproject(
    scope,
    generation,
    leaseFence,
    afterFetchSequence,
    throughFetchSequence,
    limit,
  );
}
