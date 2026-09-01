import 'cloud_sync_manual_semantic_pull_sampler.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_semantic_pull_report.dart';
import 'cloud_sync_semantic_pull_report_file.dart';

typedef CloudSyncSemanticPullReportPersist =
    Future<Object> Function(CloudSyncSemanticPullReport report);
typedef CloudSyncSemanticDrainSessionRun =
    Future<CloudSyncSemanticDrainResult> Function(
      Future<CloudSyncSemanticDrainResult> Function(
        CloudSyncConfirmedSemanticPullPass runPass,
      )
      action,
    );
typedef CloudSyncSemanticCatchUpRun =
    Future<CloudSyncConfirmedCatchUpResult> Function();

/// Content-free result of a bounded, in-process semantic catch-up drain.
///
/// The persisted report reference is intentionally opaque. Callers may expose
/// a local path only through their existing diagnostics UI; the controller
/// never logs report contents or creates a separate checkpoint.
final class CloudSyncSemanticDrainResult {
  const CloudSyncSemanticDrainResult({
    required this.passes,
    required this.lastReport,
    required this.persistedReportReference,
    required this.remoteDrained,
    required this.projectionComplete,
    required this.retainedSaveProjectionComplete,
    required this.projectionSweepAttempted,
    required this.reachedPassLimit,
  });

  final int passes;
  final CloudSyncSemanticPullReport lastReport;
  final Object persistedReportReference;
  final bool remoteDrained;
  final bool projectionComplete;
  final bool retainedSaveProjectionComplete;
  final bool projectionSweepAttempted;
  final bool reachedPassLimit;
}

/// Repeats developer-confirmed semantic pulls in one authenticated process.
///
/// ObjectBox's existing durable checkpoints remain authoritative. Every run
/// report is persisted before it is inspected, so an interrupted or unsafe
/// drain remains diagnosable and the next invocation resumes from those
/// checkpoints rather than from a controller-owned cursor.
final class CloudSyncSemanticDrainController {
  factory CloudSyncSemanticDrainController({
    required CloudSyncSemanticPullReportPersist persistReport,
    required CloudSyncSemanticDrainSessionRun runSession,
    CloudSyncSemanticCatchUpRun? runCatchUp,
    int maximumPasses = defaultMaximumPasses,
  }) => CloudSyncSemanticDrainController._(
    persistReport,
    maximumPasses,
    runSession,
    runCatchUp,
  );

  CloudSyncSemanticDrainController._(
    this._persistReport,
    this.maximumPasses,
    this._runSession,
    this._runCatchUp,
  );

  factory CloudSyncSemanticDrainController.production({
    required CloudSyncManualSemanticPullSampler sampler,
    required CloudSyncSemanticPullReportFileWriter reportWriter,
    int maximumPasses = defaultMaximumPasses,
  }) {
    return CloudSyncSemanticDrainController(
      persistReport: reportWriter.write,
      maximumPasses: maximumPasses,
      runSession: (action) => sampler.runConfirmedSession(action),
      runCatchUp: () => sampler.runConfirmedCatchUpAndPersist(
        persistReport: reportWriter.write,
        maximumRemotePasses: maximumPasses,
      ),
    );
  }

  static const defaultMaximumPasses = 16;

  final CloudSyncSemanticPullReportPersist _persistReport;
  final CloudSyncSemanticDrainSessionRun _runSession;
  final CloudSyncSemanticCatchUpRun? _runCatchUp;
  final int maximumPasses;
  Future<CloudSyncSemanticDrainResult>? _inFlight;
  Future<void>? _disposeFuture;
  bool _admissionClosed = false;

  bool get isActive => _inFlight != null;
  bool get isDisposed => _admissionClosed;

  /// Drains until all expected zones prove a terminal empty read or the
  /// configured cap is reached. A cap result is safe to resume later, never a
  /// successful remote-drain claim.
  Future<CloudSyncSemanticDrainResult> drainConfirmedAndPersist() {
    if (_admissionClosed) {
      throw StateError('cloud_sync_semantic_drain_controller_disposed');
    }
    if (_inFlight != null) {
      throw StateError('cloud_sync_semantic_drain_controller_active');
    }
    if (maximumPasses < 1 || maximumPasses > defaultMaximumPasses) {
      throw StateError('cloud_sync_semantic_drain_pass_limit_invalid');
    }

    late final Future<CloudSyncSemanticDrainResult> operation;
    operation = _drain().whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
    _inFlight = operation;
    return operation;
  }

  Future<CloudSyncSemanticDrainResult> _drain() {
    final runCatchUp = _runCatchUp;
    return runCatchUp == null
        ? _runSession(_drainWithinConfirmedSession)
        : _drainWithExactProjectionSweep(runCatchUp);
  }

  Future<CloudSyncSemanticDrainResult> _drainWithExactProjectionSweep(
    CloudSyncSemanticCatchUpRun runCatchUp,
  ) async {
    final result = await runCatchUp();
    return CloudSyncSemanticDrainResult(
      passes: result.remotePasses,
      lastReport: result.latestReport,
      persistedReportReference: result.latestReportReference,
      remoteDrained: result.remoteDrained,
      projectionComplete: result.latestReport.projectionComplete,
      retainedSaveProjectionComplete: result.retainedSaveProjectionComplete,
      projectionSweepAttempted: result.projectionReport != null,
      reachedPassLimit: result.reachedRemotePassLimit,
    );
  }

  Future<CloudSyncSemanticDrainResult> _drainWithinConfirmedSession(
    CloudSyncConfirmedSemanticPullPass runPass,
  ) async {
    for (var pass = 1; pass <= maximumPasses; pass++) {
      if (_admissionClosed) {
        throw StateError('cloud_sync_semantic_drain_cancelled');
      }
      final report = await runPass();
      final persistedReference = await _persistReport(report);

      // Persistence deliberately precedes every safety decision.
      if (!report.safeToContinueDrain) {
        final zoneFailureSafeCode =
            report.unambiguousRejectedZoneFailureSafeCode;
        if (zoneFailureSafeCode != null) {
          throw CloudSyncSemanticDrainUnsafeReportException(
            zoneFailureSafeCode,
          );
        }
        throw StateError('cloud_sync_semantic_drain_unsafe_report');
      }

      final remoteDrained = report.allZonesObservedEmptyTerminalRead;
      if (remoteDrained || pass == maximumPasses) {
        return CloudSyncSemanticDrainResult(
          passes: pass,
          lastReport: report,
          persistedReportReference: persistedReference,
          remoteDrained: remoteDrained,
          projectionComplete: report.projectionComplete,
          retainedSaveProjectionComplete: report.retainedSaveProjectionComplete,
          projectionSweepAttempted: false,
          reachedPassLimit: !remoteDrained,
        );
      }
      if (_admissionClosed) {
        throw StateError('cloud_sync_semantic_drain_cancelled');
      }
    }

    // The loop always returns at the configured cap. This is defensive only.
    throw StateError('cloud_sync_semantic_drain_pass_limit_unreachable');
  }

  /// Closes admission immediately and waits for the active native read to
  /// quiesce before callers dispose account credentials.
  Future<void> dispose() {
    _admissionClosed = true;
    return _disposeFuture ??= _waitForQuiescence();
  }

  Future<void> _waitForQuiescence() async {
    try {
      await _inFlight;
    } catch (_) {
      // The original caller receives the safe failure. Teardown only needs
      // assurance that this controller no longer owns an active operation.
    }
  }
}
