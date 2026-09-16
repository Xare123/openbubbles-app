import 'dart:async';

import 'cloud_sync_engine.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_scheduler.dart';

/// Local-only bounded encrypted-seed drain. It neither owns a network writer
/// permit nor reports uploads. The callback resumes from the durable journal;
/// coalescing timers are not the recovery source of truth.
final class CloudSyncReceivedSourceRuntime {
  CloudSyncReceivedSourceRuntime({
    required Future<({bool more, bool deferred})> Function() drain,
    required void Function(Object, StackTrace) onError,
    Duration debounce = const Duration(seconds: 3),
    this.retryDelay = const Duration(minutes: 1),
  }) {
    if (retryDelay <= Duration.zero) {
      throw ArgumentError('received_source_retry_invalid');
    }
    _scheduler = CloudSyncScheduler(
      debounce: debounce,
      // Ownership/identity/engine admission failures require a fresh event,
      // not an autonomous loop. Per-row transient failures return deferred.
      onError: onError,
      run: (trigger, cancellation) async {
        final started = DateTime.now().toUtc();
        final result = await drain();
        if (!_disposed && !cancellation.isCancelled) {
          if (result.more) {
            _scheduler.request(CloudSyncTrigger.localOutbox);
          } else if (result.deferred) {
            _retryLater();
          } else {
            _attempt = 0;
          }
        }
        return CloudSyncRunResult(
          status: result.deferred
              ? CloudSyncRunStatus.degraded
              : CloudSyncRunStatus.completed,
          counters: const CloudSyncRunCounters(),
          startedAt: started,
          finishedAt: DateTime.now().toUtc(),
        );
      },
    );
  }
  final Duration retryDelay;
  late final CloudSyncScheduler _scheduler;
  Timer? _retry;
  bool _disposed = false;
  int _attempt = 0;

  void _retryLater() {
    if (_disposed) return;
    final delay = retryDelay * (1 << _attempt);
    if (_attempt < 4) _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, () => request(CloudSyncTrigger.localOutbox));
  }

  void request(CloudSyncTrigger trigger) {
    if (_disposed) return;
    _retry?.cancel();
    _retry = null;
    _scheduler.request(trigger);
  }

  Future<void> waitUntilIdle() => _scheduler.waitUntilIdle();
  Future<void> dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    return _scheduler.dispose();
  }
}
