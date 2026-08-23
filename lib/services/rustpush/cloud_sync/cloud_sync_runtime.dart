import 'dart:collection';

import 'cloud_sync_cancellation.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_scheduler.dart';

/// Safe Phase 1 facade for running the same Cloud Sync V2 engine across the
/// Android foreground/background engines and Windows ARM64/x64 processes.
///
/// This facade intentionally accepts only read-only shadow engines. Semantic
/// apply, CloudKit saves, deletes, profiles, and notification hints remain
/// blocked until their later rollout gates pass.
class CloudSyncShadowRuntime {
  CloudSyncShadowRuntime({
    required Iterable<CloudSyncEngine> engines,
    Duration debounce = const Duration(seconds: 15),
    this.automaticTriggersEnabled = false,
    CloudSyncSchedulerErrorHandler? onError,
  }) : _engines = List.unmodifiable(engines) {
    if (_engines.isEmpty) {
      throw ArgumentError.value(engines, 'engines', 'must not be empty');
    }
    for (final engine in _engines) {
      _requireShadowFlags(engine);
    }
    _scheduler = CloudSyncScheduler(
      debounce: debounce,
      onError: onError,
      run: _runAll,
    );
  }

  final List<CloudSyncEngine> _engines;
  final bool automaticTriggersEnabled;
  late final CloudSyncScheduler _scheduler;
  List<CloudSyncRunResult> _lastResults = const [];
  Future<void>? _disposeFuture;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get isRunning => _scheduler.isRunning;
  bool get hasPendingWork => _scheduler.hasPendingWork;
  UnmodifiableListView<CloudSyncRunResult> get lastResults =>
      UnmodifiableListView(_lastResults);

  /// Queues one non-blocking startup reconciliation pass only after a future
  /// rollout explicitly enables automatic triggers. The safe default is a
  /// dormant, user-requested shadow sampler.
  void onStartup() {
    if (automaticTriggersEnabled) _request(CloudSyncTrigger.startup);
  }

  /// Queues one pass after the active route changes.
  void onNetworkReconnect() {
    if (automaticTriggersEnabled) {
      _request(CloudSyncTrigger.networkReconnect);
    }
  }

  /// Queues one pass after IDS reconnects. IDS remains the live delivery path.
  void onIdsReconnect() {
    if (automaticTriggersEnabled) _request(CloudSyncTrigger.idsReconnect);
  }

  /// Queues one immediate integrity pass after an observed local gap.
  void onDetectedGap() {
    if (automaticTriggersEnabled) _request(CloudSyncTrigger.detectedGap);
  }

  /// Runs an immediate user-requested shadow pass and returns after all scoped
  /// engines become idle.
  Future<List<CloudSyncRunResult>> synchronizeNow() async {
    _request(CloudSyncTrigger.manual);
    await _scheduler.waitUntilIdle();
    return List.unmodifiable(_lastResults);
  }

  Future<void> waitUntilIdle() => _scheduler.waitUntilIdle();

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() {
    _disposed = true;
    return _scheduler.dispose();
  }

  void _request(CloudSyncTrigger trigger) {
    if (_disposed) return;
    _scheduler.request(trigger);
  }

  Future<CloudSyncRunResult> _runAll(
    CloudSyncTrigger trigger,
    CloudSyncCancellationToken cancellationToken,
  ) async {
    final results = <CloudSyncRunResult>[];
    for (final engine in _engines) {
      if (cancellationToken.isCancelled) break;
      results.add(
        await engine.synchronize(
          trigger: trigger,
          cancellationToken: cancellationToken,
        ),
      );
    }
    _lastResults = List.unmodifiable(results);
    return _aggregate(results, cancellationToken);
  }

  static void _requireShadowFlags(CloudSyncEngine engine) {
    final flags = engine.config.flags;
    if (!flags.readOnlyFetch ||
        flags.semanticApply ||
        flags.saves ||
        flags.deletions ||
        flags.profiles ||
        flags.notificationHints) {
      throw ArgumentError.value(
        flags,
        'engines',
        'CloudSyncShadowRuntime accepts read-only Phase 1 flags only',
      );
    }
  }

  static CloudSyncRunResult _aggregate(
    List<CloudSyncRunResult> results,
    CloudSyncCancellationToken cancellationToken,
  ) {
    if (results.isEmpty) {
      final now = DateTime.now();
      return CloudSyncRunResult(
        status: cancellationToken.isCancelled
            ? CloudSyncRunStatus.cancelled
            : CloudSyncRunStatus.skipped,
        counters: const CloudSyncRunCounters(),
        startedAt: now,
        finishedAt: now,
        failureCategory: cancellationToken.isCancelled
            ? CloudFailureCategory.cancelled
            : null,
      );
    }

    var counters = const CloudSyncRunCounters();
    var startedAt = results.first.startedAt;
    var finishedAt = results.first.finishedAt;
    var worst = results.first;
    var shadowJournalBlockReason = results.first.shadowJournalBlockReason;
    for (final result in results) {
      counters = counters.add(
        fetched: result.counters.fetched,
        applied: result.counters.applied,
        deferred: result.counters.deferred,
        quarantined: result.counters.quarantined,
        confirmed: result.counters.confirmed,
        retried: result.counters.retried,
        shadowJournalEntries: result.counters.shadowJournalEntries,
        shadowJournalEstimatedBytes:
            result.counters.shadowJournalEstimatedBytes,
        shadowJournalRejectedEntries:
            result.counters.shadowJournalRejectedEntries,
      );
      shadowJournalBlockReason ??= result.shadowJournalBlockReason;
      if (result.startedAt.isBefore(startedAt)) startedAt = result.startedAt;
      if (result.finishedAt.isAfter(finishedAt)) {
        finishedAt = result.finishedAt;
      }
      if (_statusPriority(result.status) > _statusPriority(worst.status)) {
        worst = result;
      }
    }

    return CloudSyncRunResult(
      status: worst.status,
      counters: counters,
      startedAt: startedAt,
      finishedAt: finishedAt,
      skipReason: worst.skipReason,
      failureCategory: worst.failureCategory,
      shadowJournalBlockReason: shadowJournalBlockReason,
    );
  }

  static int _statusPriority(CloudSyncRunStatus status) => switch (status) {
    CloudSyncRunStatus.failed => 5,
    CloudSyncRunStatus.cancelled => 4,
    CloudSyncRunStatus.degraded => 3,
    CloudSyncRunStatus.completed => 2,
    CloudSyncRunStatus.skipped => 1,
  };
}
