import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_cancellation.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudSyncRunResult completedResult() {
    final now = DateTime.utc(2026, 7, 31);
    return CloudSyncRunResult(
      status: CloudSyncRunStatus.completed,
      counters: const CloudSyncRunCounters(),
      startedAt: now,
      finishedAt: now,
    );
  }

  test(
    'coalesces a burst and retains the strongest integrity trigger',
    () async {
      final observed = <CloudSyncTrigger>[];
      final scheduler = CloudSyncScheduler(
        debounce: const Duration(milliseconds: 5),
        run: (trigger, cancellation) async {
          observed.add(trigger);
          return completedResult();
        },
      );

      scheduler.request(CloudSyncTrigger.notificationHint);
      scheduler.request(CloudSyncTrigger.localOutbox);
      scheduler.request(CloudSyncTrigger.networkReconnect);
      await scheduler.waitUntilIdle();

      expect(observed, [CloudSyncTrigger.networkReconnect]);
      await scheduler.dispose();
    },
  );

  test('a burst during an active run becomes one follow-up run', () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final observed = <CloudSyncTrigger>[];
    final scheduler = CloudSyncScheduler(
      debounce: Duration.zero,
      run: (trigger, cancellation) async {
        observed.add(trigger);
        if (observed.length == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        }
        return completedResult();
      },
    );

    scheduler.request(CloudSyncTrigger.startup);
    await firstStarted.future;
    scheduler.request(CloudSyncTrigger.notificationHint);
    scheduler.request(CloudSyncTrigger.localOutbox);
    scheduler.request(CloudSyncTrigger.idsReconnect);
    releaseFirst.complete();
    await scheduler.waitUntilIdle();

    expect(observed, [CloudSyncTrigger.startup, CloudSyncTrigger.idsReconnect]);
    await scheduler.dispose();
  });

  test('dispose cancels an active run and ignores later triggers', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    var runCount = 0;
    final scheduler = CloudSyncScheduler(
      debounce: Duration.zero,
      run:
          (
            CloudSyncTrigger trigger,
            CloudSyncCancellationToken cancellation,
          ) async {
            runCount++;
            started.complete();
            while (!cancellation.isCancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
            cancelled.complete();
            return completedResult();
          },
    );

    scheduler.request(CloudSyncTrigger.manual);
    await started.future;
    final firstDispose = scheduler.dispose();
    final repeatedDispose = scheduler.dispose();

    expect(identical(firstDispose, repeatedDispose), isTrue);
    await repeatedDispose;

    expect(cancelled.isCompleted, isTrue);
    expect(scheduler.isRunning, isFalse);
    expect(scheduler.hasPendingWork, isFalse);
    scheduler.request(CloudSyncTrigger.startup);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(runCount, 1);
  });

  test('run errors are contained and scheduler becomes idle', () async {
    final errors = <Object>[];
    final scheduler = CloudSyncScheduler(
      debounce: Duration.zero,
      run: (trigger, cancellation) async => throw StateError('synthetic'),
      onError: (error, stackTrace) => errors.add(error),
    );

    scheduler.request(CloudSyncTrigger.manual);
    await scheduler.waitUntilIdle();

    expect(errors.single, isA<StateError>());
    expect(scheduler.isRunning, isFalse);
    expect(scheduler.hasPendingWork, isFalse);
    await scheduler.dispose();
  });
}
