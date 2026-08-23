import 'dart:async';

import 'cloud_sync_cancellation.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_observability.dart';

typedef CloudSyncScheduledRun =
    Future<CloudSyncRunResult> Function(
      CloudSyncTrigger trigger,
      CloudSyncCancellationToken cancellationToken,
    );

typedef CloudSyncSchedulerErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Coalesces Cloud Sync V2 triggers without delaying IDS delivery.
///
/// Callers enqueue work and return immediately. At most one run is active, and
/// a burst that arrives during a run becomes one follow-up run. The engine's
/// durable coordinator lease remains the cross-isolate and cross-process
/// correctness boundary.
class CloudSyncScheduler {
  CloudSyncScheduler({
    required this._run,
    this.debounce = const Duration(seconds: 15),
    this._onError,
  }) {
    if (debounce.isNegative) {
      throw ArgumentError.value(debounce, 'debounce');
    }
  }

  final Duration debounce;
  final CloudSyncScheduledRun _run;
  final CloudSyncSchedulerErrorHandler? _onError;

  Timer? _timer;
  CloudSyncTrigger? _pendingTrigger;
  CloudSyncCancellationToken? _activeCancellation;
  Completer<void>? _idleCompleter;
  Future<void>? _disposeFuture;
  bool _running = false;
  bool _disposed = false;

  bool get isRunning => _running;
  bool get hasPendingWork => _pendingTrigger != null || _timer != null;
  bool get isDisposed => _disposed;

  /// Schedules a synchronization and returns without waiting for network I/O.
  ///
  /// Manual sync and an observed IDS gap bypass the debounce because the user
  /// or integrity signal is already explicit. Other bursty triggers coalesce.
  void request(CloudSyncTrigger trigger) {
    if (_disposed) return;
    _markBusy();
    _pendingTrigger = _strongerTrigger(_pendingTrigger, trigger);

    if (_running) return;
    final immediate =
        trigger == CloudSyncTrigger.manual ||
        trigger == CloudSyncTrigger.detectedGap;
    _schedule(immediate ? Duration.zero : debounce);
  }

  /// Completes after the currently queued and active work becomes idle.
  ///
  /// This is intended for tests, diagnostics, and an explicit manual-sync UI.
  /// IDS and push handlers should only call [request].
  Future<void> waitUntilIdle() {
    if (!_running && !hasPendingWork) return Future.value();
    _markBusy();
    return _idleCompleter!.future;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pendingTrigger = null;
    _activeCancellation?.cancel();
    if (!_running) _completeIdle();
    await waitUntilIdle();
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _drainOne);
  }

  Future<void> _drainOne() async {
    _timer = null;
    if (_disposed || _running) {
      if (!_running) _completeIdle();
      return;
    }

    final trigger = _pendingTrigger;
    if (trigger == null) {
      _completeIdle();
      return;
    }
    _pendingTrigger = null;
    _running = true;
    final cancellation = CloudSyncCancellationToken();
    _activeCancellation = cancellation;

    try {
      await _run(trigger, cancellation);
    } catch (error, stackTrace) {
      try {
        _onError?.call(error, stackTrace);
      } catch (_) {
        // Diagnostics must never destabilize IDS or scheduler cleanup.
      }
    } finally {
      _activeCancellation = null;
      _running = false;
      if (_disposed) {
        _pendingTrigger = null;
        _completeIdle();
      } else if (_pendingTrigger != null) {
        _schedule(Duration.zero);
      } else {
        _completeIdle();
      }
    }
  }

  void _markBusy() {
    final completer = _idleCompleter;
    if (completer == null || completer.isCompleted) {
      _idleCompleter = Completer<void>();
    }
  }

  void _completeIdle() {
    final completer = _idleCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  CloudSyncTrigger _strongerTrigger(
    CloudSyncTrigger? current,
    CloudSyncTrigger incoming,
  ) {
    if (current == null) return incoming;
    return _priority(incoming) > _priority(current) ? incoming : current;
  }

  int _priority(CloudSyncTrigger trigger) => switch (trigger) {
    CloudSyncTrigger.detectedGap => 7,
    CloudSyncTrigger.manual => 6,
    CloudSyncTrigger.startup => 5,
    CloudSyncTrigger.networkReconnect => 4,
    CloudSyncTrigger.idsReconnect => 3,
    CloudSyncTrigger.localOutbox => 2,
    CloudSyncTrigger.notificationHint => 1,
  };
}
