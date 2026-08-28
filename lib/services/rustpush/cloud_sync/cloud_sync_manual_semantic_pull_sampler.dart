import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_semantic_pull_report.dart';
import 'cloud_sync_shadow_transport.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloudkit_operation_interlock.dart';

typedef CloudSyncSemanticStoreFactory =
    Future<CloudSyncStore> Function(CloudSyncScope scope);
typedef CloudSyncSemanticRawTransportFactory =
    Future<CloudSyncTransport> Function(
      CloudSyncNativeAuthSnapshot authSnapshot,
      CloudSyncScope scope,
    );
typedef CloudSyncSemanticInboxApplierFactory =
    Future<CloudInboxApplier> Function(
      CloudSyncNativeAuthSnapshot authSnapshot,
      CloudSyncScope scope,
      int generation,
    );

/// Developer-only one-shot CloudKit reader that may project supported records
/// into canonical local ObjectBox entities but has no remote write capability.
final class CloudSyncManualSemanticPullSampler {
  CloudSyncManualSemanticPullSampler({
    required this._readPreflight,
    required this._readAuthSnapshot,
    required this._createStore,
    required this._createRawTransport,
    required this._createInboxApplier,
    required CloudSyncStore operationFenceStore,
    required String privateStorageDirectory,
    required this.platform,
    required this.architecture,
    required this.buildCommit,
    this._observerFactory,
    bool? compileGateOverrideForTest,
    Duration? fetchTimeoutOverrideForTest,
  }) : _operationInterlock = CloudKitOperationInterlock(
         privateStorageDirectory: privateStorageDirectory,
         fenceStore: operationFenceStore,
       ),
       _fetchTimeout = fetchTimeoutOverrideForTest ?? _maximumFetchTimeout,
       _enabled =
           compileGateOverrideForTest ??
           CloudSyncDevGate.manualSemanticPullEnabled {
    if (_fetchTimeout <= Duration.zero ||
        _fetchTimeout > _maximumFetchTimeout) {
      throw ArgumentError.value(fetchTimeoutOverrideForTest);
    }
  }

  static const container = 'com.apple.messages.cloud';
  static const database = 'private';
  static const zones = <String>[
    'chatManateeZone',
    'messageManateeZone',
    'attachmentManateeZone',
  ];
  static const pageLimit = 1;
  static const changeLimit = 50;
  static const _maximumFetchTimeout = Duration(seconds: 45);
  static final _journalBudget = CloudShadowJournalBudget(
    maximumEntriesPerScope: 512,
    maximumEstimatedBytesPerScope: 8 * 1024 * 1024,
    maximumPendingAge: const Duration(hours: 24),
  );

  final CloudSyncShadowPreflightReader _readPreflight;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudSyncSemanticStoreFactory _createStore;
  final CloudSyncSemanticRawTransportFactory _createRawTransport;
  final CloudSyncSemanticInboxApplierFactory _createInboxApplier;
  final CloudKitOperationInterlock _operationInterlock;
  final String platform;
  final String architecture;
  final String buildCommit;
  final CloudSyncObserverFactory? _observerFactory;
  final Duration _fetchTimeout;
  final bool _enabled;
  bool _active = false;

  bool get isActive => _active;

  CloudSyncFeatureFlags get debugFlags => _config().flags;

  Future<CloudSyncSemanticPullReport> runConfirmed() async {
    if (!_enabled) throw StateError('cloud_sync_semantic_pull_disabled');
    if (_active) throw StateError('cloud_sync_semantic_pull_active');
    _active = true;
    try {
      return await _operationInterlock.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: _runConfirmedUnderInterlock,
      );
    } finally {
      _active = false;
    }
  }

  Future<CloudSyncSemanticPullReport> _runConfirmedUnderInterlock() async {
    final before = await _readPreflight();
    _validatePreflight(before);
    final auth = await _readAuthSnapshot();
    if (auth == null) throw StateError('account_unavailable');

    final reports = <CloudSyncSemanticPullZoneReport>[];
    for (final zone in zones) {
      await _requireSameAuth(auth);
      final scope = CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: container,
        database: database,
        zone: zone,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final store = await _createStore(scope);
      final observer = await _createObserver(scope);
      final checkpoint = await store.readCheckpoint(scope);
      final inboxApplier = await _createInboxApplier(
        auth,
        scope,
        checkpoint.generation,
      );
      final rawTransport = await _createRawTransport(auth, scope);
      try {
        final guardedTransport = AccountBoundShadowTransport(
          delegate: rawTransport,
          readActiveFingerprint: () async {
            final current = await _readAuthSnapshot();
            return auth.sameIdentity(current)
                ? current!.accountFingerprint
                : null;
          },
          expectedFingerprint: auth.accountFingerprint,
        );
        final engine = CloudSyncEngine(
          scope: scope,
          coordinatorId: 'manual-semantic-${auth.nativeSessionId}-$zone',
          architectureName: architecture,
          store: store,
          transport: guardedTransport,
          inboxApplier: inboxApplier,
          config: _config(),
          observer: observer,
        );
        final result = await engine.synchronize(
          trigger: CloudSyncTrigger.manual,
        );
        await _flushObserver(observer);
        if (result.counters.confirmed != 0) {
          throw StateError('cloud_sync_semantic_remote_write_tripwire');
        }
        reports.add(
          CloudSyncSemanticPullZoneReport(
            zoneLabel: _zoneLabel(zone),
            status: result.status,
            fetched: result.counters.fetched,
            applied: result.counters.applied,
            deferred: result.counters.deferred,
            quarantined: result.counters.quarantined,
            preflightQuarantined: result.counters.preflightQuarantined,
            preflightUnsupportedRecordType:
                result.counters.preflightUnsupportedRecordType,
            preflightMalformedMetadata:
                result.counters.preflightMalformedMetadata,
            preflightOversizedRecord: result.counters.preflightOversizedRecord,
            preflightInvalidChangeShape:
                result.counters.preflightInvalidChangeShape,
            preflightUnknown: result.counters.preflightUnknown,
            startupQuarantined: result.counters.startupQuarantined,
            postFetchQuarantined: result.counters.postFetchQuarantined,
            tombstoneQuarantined: result.counters.tombstoneQuarantined,
            semanticUnsupportedServiceQuarantined:
                result.counters.semanticUnsupportedServiceQuarantined,
            semanticStageQuarantined: result.counters.semanticStageQuarantined,
            retried: result.counters.retried,
            elapsedMilliseconds: result.finishedAt
                .difference(result.startedAt)
                .inMilliseconds,
            failureCategory: result.failureCategory,
            skipReason: result.skipReason,
          ),
        );
      } catch (_) {
        await _flushObserverAfterFailure(observer);
        rethrow;
      } finally {
        if (rawTransport case CloudSyncNativeOperationQuiescence quiescence) {
          await quiescence.quiesceNativeOperations();
        }
      }
      await _requireSameAuth(auth);
    }

    final after = await _readPreflight();
    _validatePreflight(after);
    if (after.outboxCount != before.outboxCount) {
      throw StateError('cloud_sync_semantic_remote_write_tripwire');
    }
    return CloudSyncSemanticPullReport(
      timestampUtc: DateTime.now().toUtc(),
      platform: platform,
      architecture: architecture,
      buildCommit: buildCommit,
      pageLimit: pageLimit,
      changeLimit: changeLimit,
      outboxCountBefore: before.outboxCount,
      outboxCountAfter: after.outboxCount,
      zones: reports,
    );
  }

  Future<CloudSyncObserver> _createObserver(CloudSyncScope scope) async =>
      _observerFactory == null
      ? const NoopCloudSyncObserver()
      : _observerFactory(scope);

  Future<void> _flushObserver(CloudSyncObserver observer) async {
    if (observer case FlushableCloudSyncObserver flushable) {
      await flushable.flush();
    }
  }

  Future<void> _flushObserverAfterFailure(CloudSyncObserver observer) async {
    try {
      await _flushObserver(observer);
    } catch (_) {
      // Preserve the primary synchronization failure.
    }
  }

  CloudSyncEngineConfig _config() => CloudSyncEngineConfig(
    maximumBatchSize: changeLimit,
    maximumFetchPagesPerRun: pageLimit,
    maximumInboxEntriesPerRun: changeLimit,
    maximumOutboxBatchesPerRun: 1,
    fetchOperationTimeout: _fetchTimeout,
    shadowJournalBudget: _journalBudget,
    flags: const CloudSyncFeatureFlags(
      readOnlyFetch: true,
      semanticApply: true,
      saves: false,
      deletions: false,
      profiles: false,
      notificationHints: false,
    ),
  );

  void _validatePreflight(CloudSyncShadowPreflightState state) {
    if (!state.platformSupported) throw StateError('unsupported_platform');
    if (!state.uiIsolate) throw StateError('not_ui_isolate');
    if (!state.rustPushReady) throw StateError('rustpush_not_ready');
    if (!state.objectBoxReady) throw StateError('objectbox_not_ready');
    if (!state.privateStorageExists) throw StateError('storage_unavailable');
    if (state.logoutActive) throw StateError('logout_active');
    if (state.legacySyncEnabled || state.legacySyncActive) {
      throw StateError('legacy_sync_active');
    }
    if (state.coordinatorLeaseActive) throw StateError('coordinator_active');
    if (state.outboxCount != 0) throw StateError('outbox_not_empty');
    if (!state.protectorSentinelValid) {
      throw StateError('protector_unavailable');
    }
  }

  Future<void> _requireSameAuth(CloudSyncNativeAuthSnapshot expected) async {
    if (!expected.sameIdentity(await _readAuthSnapshot())) {
      throw StateError('account_changed');
    }
  }

  String _zoneLabel(String zone) => switch (zone) {
    'chatManateeZone' => 'chats',
    'messageManateeZone' => 'messages',
    'attachmentManateeZone' => 'attachments',
    _ => throw StateError('unsupported_cloud_zone'),
  };
}
