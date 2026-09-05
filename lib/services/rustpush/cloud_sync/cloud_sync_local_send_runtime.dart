// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'cloud_sync_engine.dart';
import 'cloud_sync_local_send_consumer.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_scheduler.dart';

/// Foreground account lifetime for the durable local-send worker. It never
/// awaits CloudKit in an IDS send, does not invent origins, and coalesces bursty
/// wakeups. Process restart discovers work from the journal/outbox, not timers.
final class CloudSyncLocalSendRuntime {
  CloudSyncLocalSendRuntime({
    required Future<CloudSyncLocalSendConsumerResult> Function() drain,
    required void Function(Object, StackTrace) onError,
    Duration debounce = const Duration(seconds: 5),
    this.retryDelay = const Duration(minutes: 1),
  }) : _drain = drain {
    if (retryDelay <= Duration.zero) {
      throw ArgumentError('cloud_sync_local_send_retry_delay_invalid');
    }
    _scheduler = CloudSyncScheduler(
      debounce: debounce,
      onError: onError,
      run: (trigger, cancellation) async {
        final started = DateTime.now().toUtc();
        final result = await _drain();
        if (!_disposed &&
            !cancellation.isCancelled &&
            (result.outboxBlocked ||
                result.admitted > 0 ||
                result.deferred > 0)) {
          _retry?.cancel();
          _retry = Timer(
            retryDelay,
            () => request(CloudSyncTrigger.localOutbox),
          );
        }
        return CloudSyncRunResult(
          status: result.outboxBlocked
              ? CloudSyncRunStatus.degraded
              : CloudSyncRunStatus.completed,
          // Admission is not remote confirmation. The engine owns counts for
          // saves/readbacks; this scheduling layer never reports them itself.
          counters: const CloudSyncRunCounters(),
          startedAt: started,
          finishedAt: DateTime.now().toUtc(),
        );
      },
    );
  }

  final Future<CloudSyncLocalSendConsumerResult> Function() _drain;
  final Duration retryDelay;
  late final CloudSyncScheduler _scheduler;
  Timer? _retry;
  bool _disposed = false;

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
