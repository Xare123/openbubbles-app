import 'cloud_shadow_journal_budget.dart';
import 'cloud_inbox_applier.dart';
import 'cloud_sync_cancellation.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_safe_failure.dart';
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
typedef CloudSyncSemanticSessionReportPersist =
    Future<Object> Function(CloudSyncSemanticPullReport report);
typedef CloudSyncSemanticRetryWait =
    Future<void> Function(
      Duration delay,
      CloudSyncCancellationToken cancellationToken,
    );

final class CloudSyncConfirmedCatchUpResult {
  const CloudSyncConfirmedCatchUpResult({
    required this.remotePasses,
    required this.lastRemoteReport,
    required this.lastRemoteReportReference,
    required this.remoteDrained,
    required this.reachedRemotePassLimit,
    this.projectionReport,
    this.projectionReportReference,
  });

  final int remotePasses;
  final CloudSyncSemanticPullReport lastRemoteReport;
  final Object lastRemoteReportReference;
  final bool remoteDrained;
  final bool reachedRemotePassLimit;
  final CloudSyncSemanticPullReport? projectionReport;
  final Object? projectionReportReference;

  CloudSyncSemanticPullReport get latestReport =>
      projectionReport ?? lastRemoteReport;

  Object get latestReportReference =>
      projectionReportReference ?? lastRemoteReportReference;

  bool get retainedSaveProjectionComplete =>
      latestReport.retainedSaveProjectionComplete;
}

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
    CloudSyncSemanticRetryWait? retryWaitOverrideForTest,
    CloudSyncClock? clockOverrideForTest,
  }) : _operationInterlock = CloudKitOperationInterlock(
         privateStorageDirectory: privateStorageDirectory,
         fenceStore: operationFenceStore,
       ),
       _fetchTimeout = fetchTimeoutOverrideForTest ?? _maximumFetchTimeout,
       _retryWait = retryWaitOverrideForTest ?? _defaultRetryWait,
       _clock = clockOverrideForTest ?? _utcNow,
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
  static const retainedProjectionAllowance =
      pageLimit * changeLimit - changeLimit;
  static const projectionRepairLimit = 256;
  static const maximumLegacyOwnershipRepairCandidates = 4096;
  static const retainedProjectionSweepBatchSize = 256;
  static const maximumRetainedProjectionSweepBatches = 4096;
  static const maximumConfirmedRemotePasses = 16;
  static const maximumTransientSessionRetries = 2;
  static const maximumTransientRetryWait = Duration(seconds: 60);
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
  final CloudSyncSemanticRetryWait _retryWait;
  final CloudSyncClock _clock;
  final bool _enabled;
  bool _active = false;
  bool _nativePauseUncertain = false;
  CloudSyncCancellationToken? _activeCatchUpCancellation;

  bool get isActive => _active;

  void cancelActiveCatchUp() => _activeCatchUpCancellation?.cancel();

  CloudSyncFeatureFlags get debugFlags => _config().flags;

  Future<CloudSyncSemanticPullReport> runConfirmed() =>
      runConfirmedSession((runPass) => runPass());

  /// Proves remote head, persists that proof, and then performs one exact
  /// local-only sweep of every retained save that existed at the proof bound.
  ///
  /// The complete operation uses one auth admission, one operation interlock,
  /// and one native-writer pause. The sweep never constructs a CloudKit
  /// transport and never enters [CloudSyncEngine.synchronize].
  Future<CloudSyncConfirmedCatchUpResult> runConfirmedCatchUpAndPersist({
    required CloudSyncSemanticSessionReportPersist persistReport,
    int maximumRemotePasses = maximumConfirmedRemotePasses,
    int projectionBatchSize = retainedProjectionSweepBatchSize,
  }) async {
    if (maximumRemotePasses < 1 ||
        maximumRemotePasses > maximumConfirmedRemotePasses) {
      throw ArgumentError('cloud_sync_semantic_remote_pass_limit_invalid');
    }
    if (projectionBatchSize < 1 || projectionBatchSize > 4096) {
      throw ArgumentError('cloud_sync_projection_sweep_batch_size_invalid');
    }
    if (!_enabled) throw StateError('cloud_sync_semantic_pull_disabled');
    if (_active) throw StateError('cloud_sync_semantic_pull_active');

    _active = true;
    final cancellationToken = CloudSyncCancellationToken();
    _activeCatchUpCancellation = cancellationToken;
    var completedRemotePasses = 0;
    var retries = 0;
    var cumulativeWait = Duration.zero;
    _CloudSyncSemanticRetryFence? retryFence;
    try {
      while (true) {
        _throwIfCancelled(cancellationToken);
        try {
          final result = await _executeConfirmedSessionWithContext((
            session,
          ) async {
            final expectedFence = retryFence;
            if (expectedFence != null) {
              await _validateRetryFence(session, expectedFence);
            }
            return _catchUpWithinConfirmedSession(
              session: session,
              persistReport: persistReport,
              maximumRemotePasses: maximumRemotePasses - completedRemotePasses,
              projectionBatchSize: projectionBatchSize,
              cancellationToken: cancellationToken,
            );
          }, cancellationToken: cancellationToken);
          if (completedRemotePasses == 0) return result;
          return CloudSyncConfirmedCatchUpResult(
            remotePasses: completedRemotePasses + result.remotePasses,
            lastRemoteReport: result.lastRemoteReport,
            lastRemoteReportReference: result.lastRemoteReportReference,
            remoteDrained: result.remoteDrained,
            reachedRemotePassLimit: result.reachedRemotePassLimit,
            projectionReport: result.projectionReport,
            projectionReportReference: result.projectionReportReference,
          );
        } on _CloudSyncSemanticTransientInterruption catch (failure) {
          completedRemotePasses += failure.remotePasses;
          final exhausted =
              retries >= maximumTransientSessionRetries ||
              completedRemotePasses >= maximumRemotePasses;
          if (exhausted) {
            throw CloudSyncSemanticDrainUnsafeReportException(failure.safeCode);
          }

          final now = _clock().toUtc();
          final delay = failure.fence.nextEligibleAt.isAfter(now)
              ? failure.fence.nextEligibleAt.difference(now)
              : Duration.zero;
          if (cumulativeWait + delay > maximumTransientRetryWait) {
            throw CloudSyncSemanticDrainUnsafeReportException(failure.safeCode);
          }
          retries++;
          cumulativeWait += delay;
          retryFence = failure.fence;
          await _retryWait(delay, cancellationToken);
          _throwIfCancelled(cancellationToken);
        }
      }
    } finally {
      if (identical(_activeCatchUpCancellation, cancellationToken)) {
        _activeCatchUpCancellation = null;
      }
      if (!_nativePauseUncertain) _active = false;
    }
  }

  Future<CloudSyncConfirmedCatchUpResult> _catchUpWithinConfirmedSession({
    required _CloudSyncConfirmedSessionContext session,
    required CloudSyncSemanticSessionReportPersist persistReport,
    required int maximumRemotePasses,
    required int projectionBatchSize,
    required CloudSyncCancellationToken cancellationToken,
  }) async {
    for (var pass = 1; pass <= maximumRemotePasses; pass++) {
      _throwIfCancelled(cancellationToken);
      final report = await session.runRemotePass();
      // Persistence deliberately precedes every safety and completion claim.
      final reportReference = await persistReport(report);
      if (!report.safeToContinueDrain) {
        final transient = report.unambiguousTransientTransportFailure;
        if (transient != null && !cancellationToken.isCancelled) {
          final fence = await _captureRetryFence(
            session: session,
            report: report,
            category: transient.category,
          );
          if (fence != null) {
            throw _CloudSyncSemanticTransientInterruption(
              remotePasses: pass,
              safeCode: transient.safeCode,
              fence: fence,
            );
          }
        }
        final safeCode = report.unambiguousRejectedZoneFailureSafeCode;
        if (safeCode != null) {
          throw CloudSyncSemanticDrainUnsafeReportException(safeCode);
        }
        throw StateError('cloud_sync_semantic_drain_unsafe_report');
      }
      if (!report.allZonesObservedEmptyTerminalRead) {
        if (pass == maximumRemotePasses) {
          return CloudSyncConfirmedCatchUpResult(
            remotePasses: pass,
            lastRemoteReport: report,
            lastRemoteReportReference: reportReference,
            remoteDrained: false,
            reachedRemotePassLimit: true,
          );
        }
        continue;
      }

      if (!report.hasRetainedSaveBacklog) {
        return CloudSyncConfirmedCatchUpResult(
          remotePasses: pass,
          lastRemoteReport: report,
          lastRemoteReportReference: reportReference,
          remoteDrained: true,
          reachedRemotePassLimit: false,
        );
      }

      final proof = await _capturePersistedRemoteHeadProof(
        session: session,
        report: report,
      );
      final projectionReport = await _sweepRetainedSavesAtHead(
        session: session,
        proof: proof,
        batchSize: projectionBatchSize,
      );
      final projectionReference = await persistReport(projectionReport);
      if (!projectionReport.safeToPersistProjectionSweep) {
        throw StateError('cloud_sync_projection_sweep_unsafe_report');
      }
      return CloudSyncConfirmedCatchUpResult(
        remotePasses: pass,
        lastRemoteReport: report,
        lastRemoteReportReference: reportReference,
        remoteDrained: true,
        reachedRemotePassLimit: false,
        projectionReport: projectionReport,
        projectionReportReference: projectionReference,
      );
    }
    throw StateError('cloud_sync_semantic_remote_pass_limit_unreachable');
  }

  /// Runs one or more confirmed reads under one operation interlock and one
  /// native-writer pause.
  ///
  /// The session action may persist and inspect each returned report before it
  /// requests another pass. This keeps writers paused through the terminal
  /// empty-read decision instead of reopening a mutation window between
  /// otherwise safe one-shot reads.
  Future<T> runConfirmedSession<T>(
    CloudSyncConfirmedSemanticPullSessionAction<T> action,
  ) => _runConfirmedSessionWithContext(
    (session) => action(session.runRemotePass),
  );

  Future<T> _runConfirmedSessionWithContext<T>(
    Future<T> Function(_CloudSyncConfirmedSessionContext session) action,
  ) async {
    if (!_enabled) throw StateError('cloud_sync_semantic_pull_disabled');
    if (_active) throw StateError('cloud_sync_semantic_pull_active');
    _active = true;
    try {
      return await _executeConfirmedSessionWithContext(action);
    } finally {
      if (!_nativePauseUncertain) _active = false;
    }
  }

  Future<T> _executeConfirmedSessionWithContext<T>(
    Future<T> Function(_CloudSyncConfirmedSessionContext session) action, {
    CloudSyncCancellationToken? cancellationToken,
  }) async {
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
                      cancellationToken,
                    );
                    completedPass = true;
                    return report;
                  } finally {
                    passActive = false;
                  }
                }

                try {
                  final result = await action(
                    _CloudSyncConfirmedSessionContext(
                      runRemotePass: runPass,
                      pauseToken: pauseToken,
                      ensuredAuth: ensuredAuth,
                      nonce: Object(),
                    ),
                  );
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
      if (pauseMayRemainActive) _nativePauseUncertain = true;
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
    CloudSyncCancellationToken? cancellationToken,
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
          cancellationToken: cancellationToken,
        );
        await _flushObserver(observer);
        if (result.counters.confirmed != 0) {
          throw StateError('cloud_sync_semantic_remote_write_tripwire');
        }
        final diagnosticCounts = await _diagnosticCountsForReport(
          scope: scope,
          store: store,
          retainedBacklog: result.retainedUnprojectedBacklog,
        );
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
            diagnosticCounts: diagnosticCounts,
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

  Future<_CloudSyncPersistedRemoteHeadProof> _capturePersistedRemoteHeadProof({
    required _CloudSyncConfirmedSessionContext session,
    required CloudSyncSemanticPullReport report,
  }) async {
    if (!report.safeToContinueDrain ||
        !report.allZonesObservedEmptyTerminalRead ||
        report.mode != CloudSyncSemanticReportMode.readOnlyCloudKit) {
      throw StateError('cloud_sync_remote_head_proof_unavailable');
    }
    await _requireSameAuth(session.ensuredAuth);
    final bounds = <String, _CloudSyncRemoteHeadZoneBound>{};
    for (final zone in zones) {
      final scope = CloudSyncScope(
        accountFingerprint: session.ensuredAuth.accountFingerprint,
        container: container,
        database: database,
        zone: zone,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final store = await _createStore(scope);
      final checkpoint = await store.readCheckpoint(scope);
      if (checkpoint.scope != scope ||
          checkpoint.generation <= 0 ||
          checkpoint.fetchedSequence < 0 ||
          checkpoint.pendingBatchId != null ||
          checkpoint.hasUnmarkedPendingInbox) {
        throw StateError('cloud_sync_remote_head_checkpoint_unstable');
      }
      bounds[zone] = _CloudSyncRemoteHeadZoneBound(
        scope: scope,
        generation: checkpoint.generation,
        throughFetchSequence: checkpoint.fetchedSequence,
      );
    }
    await _requireSameAuth(session.ensuredAuth);
    return _CloudSyncPersistedRemoteHeadProof(
      sessionNonce: session.nonce,
      pauseToken: session.pauseToken,
      auth: session.ensuredAuth,
      bounds: bounds,
    );
  }

  Future<CloudSyncSemanticPullReport> _sweepRetainedSavesAtHead({
    required _CloudSyncConfirmedSessionContext session,
    required _CloudSyncPersistedRemoteHeadProof proof,
    required int batchSize,
  }) async {
    if (!identical(proof.sessionNonce, session.nonce) ||
        proof.pauseToken != session.pauseToken ||
        !proof.auth.sameIdentity(session.ensuredAuth) ||
        proof.bounds.length != zones.length) {
      throw StateError('cloud_sync_projection_sweep_proof_invalid');
    }
    await _requireSameAuth(proof.auth);
    final before = await _readPreflight();
    _validatePreflight(before);
    final reports = <CloudSyncSemanticPullZoneReport>[];

    for (final zone in zones) {
      final bound = proof.bounds[zone];
      if (bound == null || bound.scope.zone != zone) {
        throw StateError('cloud_sync_projection_sweep_bound_missing');
      }
      await _requireSameAuth(proof.auth);
      final startedAt = DateTime.now().toUtc();
      final store = await _createStore(bound.scope);
      await _validateProjectionSweepCheckpoint(store, bound);
      final inboxApplier = await _createInboxApplier(
        proof.auth,
        bound.scope,
        bound.generation,
        session.pauseToken,
      );
      if (inboxApplier is! CloudRetainedProjectionWindowReprocessor) {
        throw StateError('cloud_sync_projection_sweep_applier_unavailable');
      }
      final projectionSweeper =
          inboxApplier as CloudRetainedProjectionWindowReprocessor;
      final diagnosticsBefore =
          _readDiagnosticCounts?.call(bound.scope) ?? const <String, int>{};
      final leaseFence = await store.tryAcquireCoordinatorLease(
        bound.scope,
        ownerId:
            'manual-semantic-sweep-${proof.auth.nativeSessionId}-${identityHashCode(session.nonce)}-$zone',
        now: DateTime.now().toUtc(),
        leaseDuration: _config().coordinatorLeaseDuration,
      );
      if (leaseFence == null) {
        throw StateError('cloud_sync_projection_sweep_lease_unavailable');
      }

      var cursor = 0;
      var batches = 0;
      var examined = 0;
      var reprojected = 0;
      var retained = 0;
      try {
        while (cursor < bound.throughFetchSequence) {
          if (batches >= maximumRetainedProjectionSweepBatches) {
            throw StateError('cloud_sync_projection_sweep_batch_limit');
          }
          await _requireSameAuth(proof.auth);
          await _validateProjectionSweepCheckpoint(store, bound);
          final renewed = await store.renewCoordinatorLease(
            bound.scope,
            leaseFence: leaseFence,
            now: DateTime.now().toUtc(),
            leaseDuration: _config().coordinatorLeaseDuration,
          );
          if (!renewed) {
            throw StateError('cloud_sync_projection_sweep_lease_lost');
          }
          final result = await projectionSweeper.reprojectRetainedSaveWindow(
            scope: bound.scope,
            generation: bound.generation,
            leaseFence: leaseFence,
            afterFetchSequence: cursor,
            throughFetchSequence: bound.throughFetchSequence,
            limit: batchSize,
          );
          batches++;
          if (result.examined < 0 ||
              result.examined > batchSize ||
              result.reprojected < 0 ||
              result.retained < 0 ||
              result.examined != result.reprojected + result.retained ||
              result.lastExaminedSequence < cursor ||
              result.lastExaminedSequence > bound.throughFetchSequence ||
              (result.examined == 0 &&
                  (result.lastExaminedSequence != cursor ||
                      result.hasMoreWithinBound)) ||
              (result.examined > 0 && result.lastExaminedSequence <= cursor)) {
            throw StateError('cloud_sync_projection_sweep_result_invalid');
          }
          examined += result.examined;
          reprojected += result.reprojected;
          retained += result.retained;
          cursor = result.lastExaminedSequence;
          if (!result.hasMoreWithinBound) break;
        }
      } finally {
        await store.releaseCoordinatorLease(
          bound.scope,
          leaseFence: leaseFence,
        );
      }
      await _requireSameAuth(proof.auth);
      await _validateProjectionSweepCheckpoint(store, bound);
      final diagnosticsAfter =
          _readDiagnosticCounts?.call(bound.scope) ?? const <String, int>{};
      final backlogStore = store is CloudRetainedUnprojectedBacklogStore
          ? store as CloudRetainedUnprojectedBacklogStore
          : null;
      final retainedBacklog = backlogStore != null
          ? await backlogStore.readRetainedUnprojectedInboxCount(bound.scope)
          : 0;
      final diagnosticCounts = await _diagnosticCountsForReport(
        scope: bound.scope,
        store: store,
        retainedBacklog: retainedBacklog,
        projectionDiagnosticsOverride: _positiveDiagnosticDelta(
          diagnosticsBefore,
          diagnosticsAfter,
        ),
      );
      // If the typed summary cannot be read, every retained row remains
      // blocking. Only an exact durable out-of-scope count may be subtracted.
      final hasTypedBacklogSummary =
          diagnosticCounts['retained_backlog_summary_ready'] == 1 &&
          !diagnosticCounts.containsKey(
            'retained_backlog_summary_unavailable',
          ) &&
          !diagnosticCounts.containsKey('retained_backlog_summary_mismatch');
      final blockingRetainedSaves = hasTypedBacklogSummary
          ? diagnosticCounts['retained_backlog_blocking_saves'] ?? 0
          : retainedBacklog;
      final incomplete = blockingRetainedSaves > 0;
      reports.add(
        CloudSyncSemanticPullZoneReport(
          zoneLabel: _zoneLabel(zone),
          status: incomplete
              ? CloudSyncRunStatus.degraded
              : CloudSyncRunStatus.completed,
          fetched: 0,
          applied: reprojected,
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
          retainedUnprojected: retainedBacklog,
          semanticUnsupportedServiceQuarantined: 0,
          semanticStageQuarantined: 0,
          retried: 0,
          elapsedMilliseconds: DateTime.now()
              .toUtc()
              .difference(startedAt)
              .inMilliseconds,
          projectionExamined: examined,
          projectionRetained: retained,
          projectionBatches: batches,
          diagnosticCounts: diagnosticCounts,
          failureCategory: incomplete ? CloudFailureCategory.dependency : null,
          failureSafeCode: incomplete ? 'retained_projection_incomplete' : null,
        ),
      );
    }

    await _requireSameAuth(proof.auth);
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
      mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
    );
  }

  Future<void> _validateProjectionSweepCheckpoint(
    CloudSyncStore store,
    _CloudSyncRemoteHeadZoneBound bound,
  ) async {
    final checkpoint = await store.readCheckpoint(bound.scope);
    if (checkpoint.scope != bound.scope ||
        checkpoint.generation != bound.generation ||
        checkpoint.fetchedSequence != bound.throughFetchSequence ||
        checkpoint.pendingBatchId != null ||
        checkpoint.hasUnmarkedPendingInbox) {
      throw StateError('cloud_sync_projection_sweep_checkpoint_changed');
    }
  }

  static Map<String, int> _positiveDiagnosticDelta(
    Map<String, int> before,
    Map<String, int> after,
  ) {
    final delta = <String, int>{};
    for (final entry in after.entries) {
      final difference = entry.value - (before[entry.key] ?? 0);
      if (difference > 0) delta[entry.key] = difference;
    }
    return delta;
  }

  Future<CloudSyncObserver> _createObserver(CloudSyncScope scope) async =>
      _observerFactory == null
      ? const NoopCloudSyncObserver()
      : _observerFactory(scope);

  Future<Map<String, int>> _diagnosticCountsForReport({
    required CloudSyncScope scope,
    required CloudSyncStore store,
    required int retainedBacklog,
    Map<String, int>? projectionDiagnosticsOverride,
  }) async {
    final result = <String, int>{};
    final projectionDiagnostics =
        projectionDiagnosticsOverride ??
        _readDiagnosticCounts?.call(scope) ??
        const <String, int>{};
    for (final entry in projectionDiagnostics.entries) {
      result.update(
        entry.key,
        (count) => count + entry.value,
        ifAbsent: () => entry.value,
      );
    }

    if (store is! CloudRetainedUnprojectedBacklogSummaryStore) {
      result['retained_backlog_summary_unavailable'] = 1;
      return result;
    }

    final CloudRetainedUnprojectedBacklogSummary summary;
    try {
      summary = await (store as CloudRetainedUnprojectedBacklogSummaryStore)
          .readRetainedUnprojectedInboxSummary(scope);
    } catch (_) {
      result['retained_backlog_summary_unavailable'] = 1;
      return result;
    }
    result['retained_backlog_summary_ready'] = 1;
    if (summary.total != retainedBacklog) {
      result['retained_backlog_summary_mismatch'] = 1;
    }
    _putPositiveDiagnostic(result, 'retained_backlog_total', summary.total);
    _putPositiveDiagnostic(result, 'retained_backlog_saves', summary.saves);
    _putPositiveDiagnostic(
      result,
      'retained_backlog_out_of_scope_services',
      summary.outOfScopeServices,
    );
    _putPositiveDiagnostic(
      result,
      'retained_backlog_blocking_saves',
      summary.blockingSaves,
    );
    _putPositiveDiagnostic(
      result,
      'retained_backlog_tombstones',
      summary.tombstones,
    );
    _putPositiveDiagnostic(
      result,
      'retained_backlog_unclassified',
      summary.unclassified,
    );
    for (final entry in summary.byFailureCategory.entries) {
      _putPositiveDiagnostic(
        result,
        'retained_backlog_failure_${_safeCategorySegment(entry.key)}',
        entry.value,
      );
    }
    return result;
  }

  static void _putPositiveDiagnostic(
    Map<String, int> target,
    String code,
    int count,
  ) {
    if (count > 0) target[code] = count;
  }

  static String _safeCategorySegment(CloudFailureCategory category) => category
      .name
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)}_${match.group(2)}',
      )
      .toLowerCase();

  Future<void> _repairAppliedProjections({
    required CloudSyncNativeAuthSnapshot auth,
    required CloudSyncScope scope,
    required int generation,
    required CloudSyncStore store,
    required CloudInboxApplier inboxApplier,
    required Duration leaseDuration,
  }) async {
    final repairsLegacyOwnership = inboxApplier is CloudLegacyOwnershipRepairer;
    final repairsAppliedProjection =
        (scope.zone == 'chatManateeZone' ||
            scope.zone == 'attachmentManateeZone') &&
        inboxApplier is CloudAppliedProjectionRepairer;
    if (!repairsLegacyOwnership && !repairsAppliedProjection) {
      return;
    }
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
      if (repairsLegacyOwnership) {
        final ownershipRepairer = inboxApplier as CloudLegacyOwnershipRepairer;
        await ownershipRepairer.repairLegacyOwnershipEvidence(
          scope: scope,
          generation: generation,
          leaseFence: leaseFence,
          limit: maximumLegacyOwnershipRepairCandidates,
        );
      }
      if (repairsAppliedProjection) {
        final projectionRepairer =
            inboxApplier as CloudAppliedProjectionRepairer;
        await projectionRepairer.repairAppliedProjections(
          scope: scope,
          generation: generation,
          leaseFence: leaseFence,
          limit: projectionRepairLimit,
        );
      }
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

  Future<_CloudSyncSemanticRetryFence?> _captureRetryFence({
    required _CloudSyncConfirmedSessionContext session,
    required CloudSyncSemanticPullReport report,
    required CloudFailureCategory category,
  }) async {
    final reportsByLabel = {
      for (final zoneReport in report.zones) zoneReport.zoneLabel: zoneReport,
    };
    final generations = <String, int>{};
    DateTime? nextEligibleAt;
    for (final zone in zones) {
      final zoneReport = reportsByLabel[_zoneLabel(zone)];
      if (zoneReport == null) return null;
      final scope = _semanticScope(session.ensuredAuth, zone);
      final checkpoint = await (await _createStore(
        scope,
      )).readCheckpoint(scope);
      if (checkpoint.scope != scope ||
          checkpoint.generation <= 0 ||
          checkpoint.pendingBatchId != null ||
          checkpoint.hasUnmarkedPendingInbox) {
        return null;
      }
      generations[zone] = checkpoint.generation;
      if (zoneReport.failureCategory == category) {
        final eligibleAt = checkpoint.nextPullEligibleAt;
        if (checkpoint.lastFailure != category || eligibleAt == null) {
          return null;
        }
        final normalized = eligibleAt.toUtc();
        if (nextEligibleAt == null || normalized.isAfter(nextEligibleAt)) {
          nextEligibleAt = normalized;
        }
      }
    }
    await _requireSameAuth(session.ensuredAuth);
    if (nextEligibleAt == null) return null;
    return _CloudSyncSemanticRetryFence(
      auth: session.ensuredAuth,
      generations: generations,
      nextEligibleAt: nextEligibleAt,
    );
  }

  Future<void> _validateRetryFence(
    _CloudSyncConfirmedSessionContext session,
    _CloudSyncSemanticRetryFence fence,
  ) async {
    if (!fence.auth.sameIdentity(session.ensuredAuth)) {
      throw StateError('account_changed');
    }
    await _requireSameAuth(fence.auth);
    for (final zone in zones) {
      final scope = _semanticScope(session.ensuredAuth, zone);
      final checkpoint = await (await _createStore(
        scope,
      )).readCheckpoint(scope);
      if (checkpoint.scope != scope ||
          checkpoint.generation != fence.generations[zone] ||
          checkpoint.pendingBatchId != null ||
          checkpoint.hasUnmarkedPendingInbox) {
        throw StateError('cloud_sync_remote_head_checkpoint_unstable');
      }
    }
    await _requireSameAuth(fence.auth);
  }

  CloudSyncScope _semanticScope(
    CloudSyncNativeAuthSnapshot auth,
    String zone,
  ) => CloudSyncScope(
    accountFingerprint: auth.accountFingerprint,
    container: container,
    database: database,
    zone: zone,
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );

  static DateTime _utcNow() => DateTime.now().toUtc();

  static Future<void> _defaultRetryWait(
    Duration delay,
    CloudSyncCancellationToken cancellationToken,
  ) async {
    _throwIfCancelled(cancellationToken);
    if (delay > Duration.zero) {
      await Future.any<void>([
        Future<void>.delayed(delay),
        cancellationToken.whenCancelled,
      ]);
    }
    _throwIfCancelled(cancellationToken);
  }

  static void _throwIfCancelled(CloudSyncCancellationToken cancellationToken) {
    if (cancellationToken.isCancelled) {
      throw StateError('cloud_sync_semantic_drain_cancelled');
    }
  }

  CloudSyncEngineConfig _config() => CloudSyncEngineConfig(
    maximumBatchSize: changeLimit,
    maximumFetchPagesPerRun: pageLimit,
    maximumInboxEntriesPerRun:
        pageLimit * changeLimit + retainedProjectionAllowance,
    minimumInboxEntriesReservedForFetch: pageLimit * changeLimit,
    maximumOutboxBatchesPerRun: 1,
    fetchOperationTimeout: _fetchTimeout,
    allowManualPullBackoffOverride: true,
    unknownInboxBarrierRecoveryCutoff: DateTime.utc(2026, 8, 30, 4),
    legacyOwnershipConflictRecoveryCutoff: DateTime.utc(2026, 9, 2, 10, 30),
    pretransactionChatConflictRecoveryCutoff: DateTime.utc(2026, 9, 3, 6),
    pretransactionAttachmentConflictRecoveryCutoff: DateTime.utc(
      2026,
      9,
      3,
      10,
      40,
    ),
    retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
    retainKnownAttachmentProjectionConflictsForReadOnlySemanticCanary: true,
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

final class _CloudSyncConfirmedSessionContext {
  const _CloudSyncConfirmedSessionContext({
    required this.runRemotePass,
    required this.pauseToken,
    required this.ensuredAuth,
    required this.nonce,
  });

  final CloudSyncConfirmedSemanticPullPass runRemotePass;
  final Object pauseToken;
  final CloudSyncNativeAuthSnapshot ensuredAuth;
  final Object nonce;
}

final class _CloudSyncPersistedRemoteHeadProof {
  _CloudSyncPersistedRemoteHeadProof({
    required this.sessionNonce,
    required this.pauseToken,
    required this.auth,
    required Map<String, _CloudSyncRemoteHeadZoneBound> bounds,
  }) : bounds = Map.unmodifiable(bounds);

  final Object sessionNonce;
  final Object pauseToken;
  final CloudSyncNativeAuthSnapshot auth;
  final Map<String, _CloudSyncRemoteHeadZoneBound> bounds;
}

final class _CloudSyncRemoteHeadZoneBound {
  const _CloudSyncRemoteHeadZoneBound({
    required this.scope,
    required this.generation,
    required this.throughFetchSequence,
  });

  final CloudSyncScope scope;
  final int generation;
  final int throughFetchSequence;
}

final class _CloudSyncSemanticRetryFence {
  _CloudSyncSemanticRetryFence({
    required this.auth,
    required Map<String, int> generations,
    required this.nextEligibleAt,
  }) : generations = Map.unmodifiable(generations);

  final CloudSyncNativeAuthSnapshot auth;
  final Map<String, int> generations;
  final DateTime nextEligibleAt;
}

final class _CloudSyncSemanticTransientInterruption implements Exception {
  const _CloudSyncSemanticTransientInterruption({
    required this.remotePasses,
    required this.safeCode,
    required this.fence,
  });

  final int remotePasses;
  final String safeCode;
  final _CloudSyncSemanticRetryFence fence;
}
