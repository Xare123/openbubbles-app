import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_runtime.dart';
import 'cloud_sync_shadow_report.dart';
import 'cloud_sync_shadow_transport.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloudkit_operation_interlock.dart';
import 'shadow_only_cloud_sync_store.dart';

/// Immutable native-issued binding between one Rust Cloud Messages client,
/// its raw account identifier (retained natively), and its derived fingerprint.
///
/// [nativeSessionId] is an opaque, non-secret generation tag. The raw account
/// identifier and client object never enter Dart.
final class CloudSyncNativeAuthSnapshot {
  const CloudSyncNativeAuthSnapshot._({
    required this.nativeSessionId,
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.cloudMessagesClient,
  });

  /// Native adapters are the only production callers of this constructor.
  /// Tests may use it to model account replacement without exposing a DSID.
  factory CloudSyncNativeAuthSnapshot.fromNative({
    required String nativeSessionId,
    required String accountFingerprint,
    required String protectedStoreIdentity,
    required Object cloudMessagesClient,
  }) {
    if (nativeSessionId.isEmpty ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(accountFingerprint) ||
        !RegExp(
          r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(protectedStoreIdentity)) {
      throw ArgumentError('Native auth snapshot fields are invalid');
    }
    return CloudSyncNativeAuthSnapshot._(
      nativeSessionId: nativeSessionId,
      accountFingerprint: accountFingerprint,
      protectedStoreIdentity: protectedStoreIdentity,
      cloudMessagesClient: cloudMessagesClient,
    );
  }

  final String nativeSessionId;
  final String accountFingerprint;
  final String protectedStoreIdentity;
  final Object cloudMessagesClient;

  bool sameIdentity(CloudSyncNativeAuthSnapshot? other) =>
      other != null &&
      identical(cloudMessagesClient, other.cloudMessagesClient) &&
      nativeSessionId == other.nativeSessionId &&
      accountFingerprint == other.accountFingerprint &&
      protectedStoreIdentity == other.protectedStoreIdentity;
}

typedef CloudSyncNativeAuthSnapshotReader =
    Future<CloudSyncNativeAuthSnapshot?> Function();
typedef CloudSyncShadowStoreFactory =
    Future<CloudSyncStore> Function(CloudSyncScope scope);
typedef CloudSyncShadowRawTransportFactory =
    Future<CloudSyncTransport> Function(
      CloudSyncNativeAuthSnapshot authSnapshot,
      CloudSyncScope scope,
    );

class CloudSyncShadowPreflightState {
  const CloudSyncShadowPreflightState({
    required this.platformSupported,
    required this.uiIsolate,
    required this.rustPushReady,
    required this.objectBoxReady,
    required this.privateStorageExists,
    required this.logoutActive,
    required this.legacySyncEnabled,
    required this.legacySyncActive,
    required this.coordinatorLeaseActive,
    required this.outboxCount,
    required this.protectorSentinelValid,
  });

  final bool platformSupported;
  final bool uiIsolate;
  final bool rustPushReady;
  final bool objectBoxReady;
  final bool privateStorageExists;
  final bool logoutActive;
  final bool legacySyncEnabled;
  final bool legacySyncActive;
  final bool coordinatorLeaseActive;
  final int outboxCount;
  final bool protectorSentinelValid;
}

typedef CloudSyncShadowPreflightReader =
    Future<CloudSyncShadowPreflightState> Function();

/// Owns the complete safe composition. Callers cannot inject an engine,
/// semantic applier, or unguarded transport.
final class CloudSyncManualShadowSampler {
  CloudSyncManualShadowSampler({
    required this._readPreflight,
    required this._readAuthSnapshot,
    required this._createStore,
    required this._createRawTransport,
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
           CloudSyncDevGate.manualShadowSamplerEnabled {
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
    'messageUpdateZone',
    'recoverableMessageDeleteZone',
    'scheduledMessageZone',
    'chat1ManateeZone',
  ];
  static const pageLimit = 1;
  static const changeLimit = 50;
  static const _maximumFetchTimeout = Duration(seconds: 45);
  static final journalBudget = CloudShadowJournalBudget(
    maximumEntriesPerScope: 512,
    maximumEstimatedBytesPerScope: 8 * 1024 * 1024,
    maximumPendingAge: const Duration(hours: 24),
  );

  final CloudSyncShadowPreflightReader _readPreflight;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudSyncShadowStoreFactory _createStore;
  final CloudSyncShadowRawTransportFactory _createRawTransport;
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

  Future<CloudSyncShadowReport> runConfirmed() async {
    if (!_enabled) throw StateError('cloud_sync_sampler_disabled');
    if (_active) throw StateError('cloud_sync_sampler_active');
    _active = true;
    try {
      return await _operationInterlock.runExclusive(
        kind: CloudKitOperationKind.v2ShadowRead,
        action: _runConfirmedUnderInterlock,
      );
    } finally {
      _active = false;
    }
  }

  Future<CloudSyncShadowReport> _runConfirmedUnderInterlock() async {
    final before = await _runStage(
      'cloud_sync_shadow_preflight_read_failed',
      _readPreflight,
    );
    _validatePreflight(before);
    final auth = await _runStage(
      'cloud_sync_shadow_auth_capture_failed',
      _readAuthSnapshot,
    );
    if (auth == null) throw StateError('account_unavailable');

    final reports = <CloudSyncShadowZoneReport>[];
    for (final zone in zones) {
      await _runStage(
        'cloud_sync_shadow_auth_revalidation_failed',
        () => _requireSameAuth(auth),
      );
      final scope = CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: container,
        database: database,
        zone: zone,
        persistenceLane: CloudSyncPersistenceLane.shadow,
      );
      final store = ShadowOnlyCloudSyncStore(
        await _runStage(
          'cloud_sync_shadow_store_open_failed',
          () => _createStore(scope),
        ),
      );
      final observer = await _runStage(
        'cloud_sync_shadow_observer_open_failed',
        () => _createObserver(scope),
      );
      final rawTransport = await _runStage(
        'cloud_sync_shadow_transport_open_failed',
        () => _createRawTransport(auth, scope),
      );
      CloudSyncShadowRuntime? runtime;
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
          coordinatorId: 'manual-shadow-${auth.nativeSessionId}-$zone',
          architectureName: architecture,
          store: store,
          transport: guardedTransport,
          inboxApplier: const RejectingShadowInboxApplier(),
          config: _config(),
          observer: observer,
        );
        runtime = CloudSyncShadowRuntime(
          engines: [engine],
          automaticTriggersEnabled: false,
          debounce: Duration.zero,
        );
        final result = await _runStage(
          'cloud_sync_shadow_synchronize_failed',
          () async => (await runtime!.synchronizeNow()).single,
        );
        await _runStage(
          'cloud_sync_shadow_observer_flush_failed',
          () => _flushObserver(observer),
        );
        _requireZeroMutationCounters(result.counters);
        reports.add(
          CloudSyncShadowZoneReport(
            zoneLabel: _zoneLabel(zone),
            status: result.status,
            fetched: result.counters.fetched,
            journaled: result.counters.shadowJournalEntries,
            rejected: result.counters.shadowJournalRejectedEntries,
            estimatedBytes: result.counters.shadowJournalEstimatedBytes,
            elapsedMilliseconds: result.finishedAt
                .difference(result.startedAt)
                .inMilliseconds,
            failureCategory: result.failureCategory,
            skipReason: result.skipReason,
            blockReason: result.shadowJournalBlockReason,
          ),
        );
      } catch (_) {
        await _flushObserverAfterFailure(observer);
        rethrow;
      } finally {
        await _runStage(
          'cloud_sync_shadow_cleanup_failed',
          () async => runtime?.dispose(),
        );
        if (rawTransport case CloudSyncNativeOperationQuiescence quiescence) {
          await _runStage(
            'cloud_sync_shadow_quiescence_failed',
            quiescence.quiesceNativeOperations,
          );
        }
      }
      await _runStage(
        'cloud_sync_shadow_auth_revalidation_failed',
        () => _requireSameAuth(auth),
      );
    }

    final after = await _runStage(
      'cloud_sync_shadow_preflight_read_failed',
      _readPreflight,
    );
    _validatePreflight(after);
    if (after.outboxCount != before.outboxCount) {
      throw StateError('cloud_sync_shadow_write_tripwire');
    }
    return CloudSyncShadowReport(
      runId: 'obcs2-shadow-${DateTime.now().microsecondsSinceEpoch}',
      correlationTag: _ephemeralCorrelationTag(),
      timestampUtc: DateTime.now().toUtc(),
      platform: platform,
      architecture: architecture,
      buildCommit: buildCommit,
      legacySyncEnabled: before.legacySyncEnabled,
      pageLimit: pageLimit,
      changeLimit: changeLimit,
      tripwiresArmed: true,
      outboxCountBefore: before.outboxCount,
      outboxCountAfter: after.outboxCount,
      zones: reports,
    );
  }

  Future<CloudSyncObserver> _createObserver(CloudSyncScope scope) async =>
      _observerFactory == null
      ? const NoopCloudSyncObserver()
      : _observerFactory(scope);

  Future<T> _runStage<T>(String safeCode, Future<T> Function() action) async {
    try {
      return await action();
    } on StateError {
      // The UI/log boundary still allowlists the message. Preserve reviewed
      // subcodes while arbitrary StateError text remains redacted there.
      rethrow;
    } catch (_) {
      // Collapse arbitrary dependency/native exception text into a reviewed,
      // content-free stage code. The original exception can contain account,
      // record, token, or server details and must never reach app logs.
      throw StateError(safeCode);
    }
  }

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
    shadowJournalBudget: journalBudget,
    flags: const CloudSyncFeatureFlags(
      readOnlyFetch: true,
      semanticApply: false,
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

  void _requireZeroMutationCounters(CloudSyncRunCounters counters) {
    if (counters.applied != 0 ||
        counters.confirmed != 0 ||
        counters.deferred != 0 ||
        counters.retried != 0) {
      throw StateError('cloud_sync_shadow_write_tripwire');
    }
  }

  String _ephemeralCorrelationTag() {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _zoneLabel(String zone) => switch (zone) {
    'chatManateeZone' => 'chats',
    'messageManateeZone' => 'messages',
    'attachmentManateeZone' => 'attachments',
    'messageUpdateZone' => 'message updates',
    'recoverableMessageDeleteZone' => 'recoverable deletes',
    'scheduledMessageZone' => 'scheduled messages',
    'chat1ManateeZone' => 'chat1 manatee',
    _ => throw StateError('unsupported_cloud_zone'),
  };
}
