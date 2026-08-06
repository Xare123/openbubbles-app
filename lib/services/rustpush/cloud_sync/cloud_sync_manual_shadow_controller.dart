import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_shadow_report.dart';
import 'cloud_sync_shadow_report_file.dart';

typedef CloudSyncConfirmedShadowRun = Future<CloudSyncShadowReport> Function();
typedef CloudSyncShadowReportPersist =
    Future<Object> Function(CloudSyncShadowReport report);

/// Account-lifecycle owner for the developer-only manual shadow run.
///
/// Disposal closes admission immediately and then waits for the bounded native
/// fetch to finish before the owning Rust client can be released. This avoids
/// a logout or account switch disposing credentials underneath an in-flight
/// CloudKit operation.
final class CloudSyncManualShadowController {
  factory CloudSyncManualShadowController({
    required CloudSyncConfirmedShadowRun runConfirmed,
    required CloudSyncShadowReportPersist persistReport,
  }) => CloudSyncManualShadowController._(runConfirmed, persistReport);

  CloudSyncManualShadowController._(this._runConfirmed, this._persistReport);

  factory CloudSyncManualShadowController.production({
    required CloudSyncManualShadowSampler sampler,
    required CloudSyncShadowReportFileWriter reportWriter,
  }) {
    return CloudSyncManualShadowController(
      runConfirmed: sampler.runConfirmed,
      persistReport: reportWriter.write,
    );
  }

  final CloudSyncConfirmedShadowRun _runConfirmed;
  final CloudSyncShadowReportPersist _persistReport;
  Future<CloudSyncShadowReport>? _inFlight;
  Future<void>? _disposeFuture;
  bool _admissionClosed = false;

  bool get isActive => _inFlight != null;
  bool get isDisposed => _admissionClosed;

  Future<CloudSyncShadowReport> runConfirmedAndPersist() {
    if (_admissionClosed) {
      throw StateError('cloud_sync_shadow_controller_disposed');
    }
    if (_inFlight != null) {
      throw StateError('cloud_sync_shadow_controller_active');
    }
    late final Future<CloudSyncShadowReport> operation;
    operation = _runAndPersist().whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
    _inFlight = operation;
    return operation;
  }

  Future<CloudSyncShadowReport> _runAndPersist() async {
    final report = await _runConfirmed();
    await _persistReport(report);
    return report;
  }

  Future<void> dispose() {
    _admissionClosed = true;
    return _disposeFuture ??= _waitForQuiescence();
  }

  Future<void> _waitForQuiescence() async {
    try {
      await _inFlight;
    } catch (_) {
      // The caller of runConfirmedAndPersist receives the original error.
      // Teardown cares only that the operation has stopped using credentials.
    }
  }
}
