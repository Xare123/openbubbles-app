// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'cloud_sync_engine.dart';
import 'cloud_sync_local_send_consumer.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_scheduler.dart';
import 'cloudkit_operation_interlock.dart';

/// Foreground account lifetime for the durable local-send worker. It never
/// awaits CloudKit in an IDS send, does not invent origins, and coalesces bursty
/// wakeups. Process restart discovers work from the journal/outbox, not timers.
final class CloudSyncLocalSendRuntime {
  CloudSyncLocalSendRuntime({
    required Future<CloudSyncLocalSendConsumerResult> Function() drain,
    required void Function(Object, StackTrace) onError,
    Future<void> Function()? prepare,
    Duration debounce = const Duration(seconds: 5),
    this.retryDelay = const Duration(minutes: 1),
  }) : _drain = drain {
    if (retryDelay <= Duration.zero) {
      throw ArgumentError('cloud_sync_local_send_retry_delay_invalid');
    }
    _scheduler = CloudSyncScheduler(
      debounce: debounce,
      onError: (error, stack) {
        final delay = _retryableErrorDelay(error);
        if (delay != null) _scheduleRetry(delay);
        onError(error, stack);
      },
      run: (trigger, cancellation) async {
        final started = DateTime.now().toUtc();
        if (!_prepared) {
          await prepare?.call();
          if (_disposed || cancellation.isCancelled) {
            return CloudSyncRunResult(
              status: CloudSyncRunStatus.cancelled,
              counters: const CloudSyncRunCounters(),
              startedAt: started,
              finishedAt: DateTime.now().toUtc(),
            );
          }
          _prepared = true;
        }
        final result = await _drain();
        // Admission progress or an empty queue resets backoff. A retained,
        // dependency-blocked origin must not poll every minute forever.
        final progressed = result.admitted > 0 ||
            (result.candidateLimitReached && !result.outboxBlocked);
        if (progressed ||
            (!result.outboxBlocked && result.deferred == 0)) {
          _retryExponent = 0;
        }
        if (!_disposed &&
            !cancellation.isCancelled &&
            (result.outboxBlocked ||
                result.admitted > 0 ||
                result.deferred > 0)) {
          _scheduleRetry(progressed ? retryDelay : _nextRetryDelay());
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
  bool _prepared = false;
  int _retryExponent = 0;

  Duration? _retryableErrorDelay(Object error) {
    Duration? hint;
    if (error is CloudKitOperationInterlockException &&
        error.safeCode == 'cloudkit_interlock_busy') {
      hint = error.retryAt?.difference(DateTime.now().toUtc());
    } else if (error is CloudSyncFailure &&
        const {
          CloudFailureCategory.network,
          CloudFailureCategory.server,
          CloudFailureCategory.throttled,
        }.contains(error.category)) {
      hint = error.retryAfter;
    } else {
      // Auth/identity, unknown outcomes, and failed safety checks require their
      // existing recovery path or a fresh explicit event, not a generic retry.
      return null;
    }
    final delay = _nextRetryDelay();
    return hint != null && hint > delay ? hint : delay;
  }

  Duration _nextRetryDelay() {
    final delay = retryDelay * (1 << _retryExponent);
    if (_retryExponent < 4) _retryExponent++;
    return delay;
  }

  void _scheduleRetry(Duration delay) {
    if (_disposed) return;
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
