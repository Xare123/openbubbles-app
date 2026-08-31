import 'cloud_shadow_journal_budget.dart';
import 'cloud_inbox_applier.dart';
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
      Object nativeWriterPauseToken,
    );
typedef CloudSyncSemanticInboxApplierFactory =
    Future<CloudInboxApplier> Function(
      CloudSyncNativeAuthSnapshot authSnapshot,
      CloudSyncScope scope,
      int generation,
      Object nativeWriterPauseToken,
    );
typedef CloudSyncSemanticDiagnosticSnapshotReader =
    Map<String, int> Function(CloudSyncScope scope);
typedef CloudSyncPausedPreparedAuthSnapshotReader =
    Future<CloudSyncNativeAuthSnapshot?> Function(Object pauseToken);
typedef CloudSyncSemanticPausedPreparedAuthSnapshotReader =
    Future<CloudSyncNativeAuthSnapshot?> Function(
      Object pauseToken,
      CloudSyncNativeAuthSnapshot expectedAuth,
    );
typedef CloudSyncEnsuredAuthSnapshotReader =
    Future<CloudSyncNativeAuthSnapshot?> Function();
typedef CloudSyncConfirmedSemanticPullPass =
    Future<CloudSyncSemanticPullReport> Function();
typedef CloudSyncConfirmedSemanticPullSessionAction<T> =
    Future<T> Function(CloudSyncConfirmedSemanticPullPass runPass);

/// Native exclusion for every CloudKit-capable writer workflow.
///
/// The Dart operation interlock covers app-owned CloudKit entry points, but
/// APS handlers can start inside Rust without crossing that boundary. A
/// semantic pull must hold this pause for its complete authenticated run.
abstract interface class CloudSyncNativeWriterPause {
  Future<Object> pause();

  Future<void> resume(Object token);
}

/// The bridge could not confirm whether a caller-owned native pause token was
/// canceled or released. The sampler remains active until process restart so
/// it cannot start another pull against an uncertain native gate.
final class CloudSyncNativeWriterPauseUncertain implements Exception {
  const CloudSyncNativeWriterPauseUncertain();

  @override
  String toString() => 'cloud_sync_native_writer_pause_resume_unconfirmed';
}

/// Developer-only one-shot CloudKit reader that may project supported records
/// into canonical local ObjectBox entities but has no remote write capability.
final class CloudSyncManualSemanticPullSampler {
  CloudSyncManualSemanticPullSampler({
    required this._readPreflight,
    required this._ensureAuthSnapshot,
    required this._prepareAuthSnapshot,
    required this._readAuthSnapshot,
    required this._createStore,
    required this._createRawTransport,
    required this._createInboxApplier,
    required this._nativeWriterPause,
    required CloudSyncStore operationFenceStore,
    required String privateStorageDirectory,
    required this.platform,
    required this.architecture,
    required this.buildCommit,
    this._observerFactory,
    this._readDiagnosticCounts,
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
  static const pageLimit = 4;
  static const changeLimit = 50;
  static const projectionRepairLimit = 256;
  static const _maximumFetchTimeout = Duration(seconds: 45);
  static final _journalBudget = CloudShadowJournalBudget(
    maximumEntriesPerScope: 512,
    maximumEstimatedBytesPerScope: 8 * 1024 * 1024,
    maximumPendingAge: const Duration(hours: 24),
  );

  final CloudSyncShadowPreflightReader _readPreflight;
  final CloudSyncEnsuredAuthSnapshotReader _ensureAuthSnapshot;
  final CloudSyncSemanticPausedPreparedAuthSnapshotReader _prepareAuthSnapshot;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudSyncSemanticStoreFactory _createStore;
  final CloudSyncSemanticRawTransportFactory _createRawTransport;
  final CloudSyncSemanticInboxApplierFactory _createInboxApplier;
  final CloudSyncNativeWriterPause _nativeWriterPause;
  final CloudKitOperationInterlock _operationInterlock;
  final String platform;
  final String architecture;
  final String buildCommit;
  final CloudSyncObserverFactory? _observerFactory;
  final CloudSyncSemanticDiagnosticSnapshotReader? _readDiagnosticCounts;
  final Duration _fetchTimeout;
  final bool _enabled;
  bool _active = false;

  bool get isActive => _active;

  CloudSyncFeatureFlags get debugFlags => _config().flags;

  Future<CloudSyncSemanticPullReport> runConfirmed() =>
      runConfirmedSession((runPass) => runPass());

  /// Runs one or more confirmed reads under one operation interlock and one
  /// native-writer pause.
  ///
  /// The session action may persist and inspect each returned report before it
  /// requests another pass. This keeps writers paused through the terminal
  /// empty-read decision instead of reopening a mutation window between
  /// otherwise safe one-shot reads.
  Future<T> runConfirmedSession<T>(
    CloudSyncConfirmedSemanticPullSessionAction<T> action,
  ) async {
    if (!_enabled) throw StateError('cloud_sync_semantic_pull_disabled');
    if (_active) throw StateError('cloud_sync_semantic_pull_active');
    _active = true;
    var pauseMayRemainActive = false;
    try {
      return await _operationInterlock.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: () async {
          for (
            var authenticationAttempt = 0;
            authenticationAttempt < 2;
            authenticationAttempt++
          ) {
            var completedPass = false;
            try {
              final ensuredAuth = await _ensureAuthSnapshot();
              if (ensuredAuth == null) throw StateError('account_unavailable');
              late final Object pauseToken;
              try {
                pauseToken = await _nativeWriterPause.pause();
                pauseMayRemainActive = true;
              } on CloudSyncNativeWriterPauseUncertain {
                pauseMayRemainActive = true;
                rethrow;
              }
              try {
                var passActive = false;
                var sessionClosed = false;
                Future<CloudSyncSemanticPullReport> runPass() async {
                  if (sessionClosed) {
                    throw StateError('cloud_sync_semantic_pull_session_closed');
                  }
                  if (passActive) {
                    throw StateError(
                      'cloud_sync_semantic_pull_session_pass_active',
                    );
                  }
                  passActive = true;
                  try {
                    final report = await _runConfirmedUnderInterlock(
                      pauseToken,
                      ensuredAuth,
                    );
                    completedPass = true;
                    return report;
                  } finally {
                    passActive = false;
                  }
                }

                try {
                  final result = await action(runPass);
                  if (passActive) {
                    throw StateError(
                      'cloud_sync_semantic_pull_session_pass_unawaited',
                    );
                  }
                  return result;
                } finally {
                  sessionClosed = true;
                  while (passActive) {
                    await Future<void>.delayed(Duration.zero);
                  }
                }
              } finally {
                await _nativeWriterPause.resume(pauseToken);
                pauseMayRemainActive = false;
              }
            } catch (error) {
              if (authenticationAttempt == 0 &&
                  !completedPass &&
                  _isRefreshableReadAuthenticationFailure(error)) {
                continue;
              }
              rethrow;
            }
          }
          throw StateError('cloud_sync_native_auth_refresh_failed');
        },
      );
    } finally {
      if (!pauseMayRemainActive) {
        _active = false;
      }
    }
  }

  static bool _isRefreshableReadAuthenticationFailure(Object error) {
    if (error is! StateError) return false;
    final code = error.message.toString();
    return code == 'cloud_sync_native_auth_credentials_unavailable' ||
        code == 'cloud_sync_native_auth_credentials_rejected';
  }

  Future<CloudSyncSemanticPullReport> _runConfirmedUnderInterlock(
    Object pauseToken,
    CloudSyncNativeAuthSnapshot ensuredAuth,
  ) async {
    await _requireSameAuth(ensuredAuth);
    final before = await _readPreflight();
    _validatePreflight(before);
    await _requireSameAuth(ensuredAuth);
    final auth = await _prepareAuthSnapshot(pauseToken, ensuredAuth);
    if (auth == null) throw StateError('account_unavailable');
    if (!ensuredAuth.sameIdentity(auth)) {
      throw StateError('account_changed');
    }

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
        pauseToken,
      );
      final config = _config();
      await _repairAppliedProjections(
        auth: auth,
        scope: scope,
        generation: checkpoint.generation,
        store: store,
        inboxApplier: inboxApplier,
        leaseDuration: config.coordinatorLeaseDuration,
      );
      final rawTransport = await _createRawTransport(auth, scope, pauseToken);
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
          config: config,
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
            tombstoneReadOnlyAcknowledged:
                result.counters.tombstoneReadOnlyAcknowledged,
            retainedUnprojected: result.retainedUnprojectedBacklog,
            semanticUnsupportedServiceQuarantined:
                result.counters.semanticUnsupportedServiceQuarantined,
            semanticStageQuarantined: result.counters.semanticStageQuarantined,
            retried: result.counters.retried,
            elapsedMilliseconds: result.finishedAt
                .difference(result.startedAt)
                .inMilliseconds,
            observedEmptyTerminalRead: result.observedEmptyTerminalRead,
            diagnosticCounts:
                _readDiagnosticCounts?.call(scope) ?? const <String, int>{},
            failureCategory: result.failureCategory,
            failureSafeCode: result.failureSafeCode,
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

  Future<void> _repairAppliedProjections({
    required CloudSyncNativeAuthSnapshot auth,
    required CloudSyncScope scope,
    required int generation,
    required CloudSyncStore store,
    required CloudInboxApplier inboxApplier,
    required Duration leaseDuration,
  }) async {
    if (scope.zone != 'chatManateeZone' ||
        inboxApplier is! CloudAppliedProjectionRepairer) {
      return;
    }
    final repairer = inboxApplier as CloudAppliedProjectionRepairer;
    final leaseFence = await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'manual-semantic-projection-repair-${auth.nativeSessionId}',
      now: DateTime.now().toUtc(),
      leaseDuration: leaseDuration,
    );
    if (leaseFence == null) {
      throw StateError('cloud_sync_projection_repair_lease_unavailable');
    }
    try {
      await repairer.repairAppliedProjections(
        scope: scope,
        generation: generation,
        leaseFence: leaseFence,
        limit: projectionRepairLimit,
      );
    } finally {
      await store.releaseCoordinatorLease(scope, leaseFence: leaseFence);
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
    maximumInboxEntriesPerRun: pageLimit * changeLimit,
    minimumInboxEntriesReservedForFetch: changeLimit,
    maximumOutboxBatchesPerRun: 1,
    fetchOperationTimeout: _fetchTimeout,
    allowManualPullBackoffOverride: true,
    unknownInboxBarrierRecoveryCutoff: DateTime.utc(2026, 8, 30, 4),
    retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
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
