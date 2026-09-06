import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_consumer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_runtime.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_dev_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'server retry-after is respected and logout cancels the delayed retry',
    () {
      fakeAsync((time) {
        var calls = 0;
        final runtime = CloudSyncLocalSendRuntime(
          debounce: Duration.zero,
          drain: () async {
            calls++;
            throw CloudSyncFailure(
              category: CloudFailureCategory.throttled,
              retryAfter: const Duration(minutes: 4),
            );
          },
          onError: (_, __) {},
        );
        runtime.request(CloudSyncTrigger.startup);
        time.elapse(const Duration(minutes: 3));
        expect(calls, 1);
        time.elapse(const Duration(minutes: 1));
        expect(calls, 2);
        unawaited(runtime.dispose());
        time.flushMicrotasks();
        time.elapse(const Duration(days: 1));
        expect(calls, 2);
      });
    },
  );

  for (final category in [
    CloudFailureCategory.authorization,
    CloudFailureCategory.pcsUnavailable,
    CloudFailureCategory.conflict,
    CloudFailureCategory.unknown,
    CloudFailureCategory.malformedRecord,
  ]) {
    test('${category.name} failures never get a generic automatic retry', () {
      fakeAsync((time) {
        var calls = 0;
        final runtime = CloudSyncLocalSendRuntime(
          debounce: Duration.zero,
          drain: () async {
            calls++;
            throw CloudSyncFailure(category: category);
          },
          onError: (_, __) {},
        );
        runtime.request(CloudSyncTrigger.startup);
        time.elapse(const Duration(days: 1));
        expect(calls, 1);
        unawaited(runtime.dispose());
        time.flushMicrotasks();
      });
    });
  }

  test('a busy preparation retries with backoff and keeps drains blocked', () {
    fakeAsync((time) {
      var prepares = 0;
      var drains = 0;
      var errors = 0;
      final runtime = CloudSyncLocalSendRuntime(
        debounce: Duration.zero,
        prepare: () async {
          if (++prepares <= 2) {
            throw const CloudKitOperationInterlockException(
              'cloudkit_interlock_busy',
            );
          }
        },
        drain: () async {
          drains++;
          return const CloudSyncLocalSendConsumerResult();
        },
        onError: (_, __) {
          errors++;
          throw StateError('observer_failure');
        },
      );
      runtime.request(CloudSyncTrigger.startup);
      time.elapse(const Duration(seconds: 59));
      expect((prepares, drains, errors), (1, 0, 1));
      time.elapse(const Duration(seconds: 1));
      expect((prepares, drains, errors), (2, 0, 2));
      time.elapse(const Duration(seconds: 119));
      expect(prepares, 2);
      time.elapse(const Duration(seconds: 1));
      expect((prepares, drains, errors), (3, 1, 2));
      time.elapse(const Duration(hours: 1));
      expect(prepares, 3);
      unawaited(runtime.dispose());
      time.flushMicrotasks();
    });
  });

  test(
    'automatic setup completes once before any drain in an account lifetime',
    () {
      fakeAsync((time) {
        final events = <String>[];
        final setup = Completer<void>();
        final runtime = CloudSyncLocalSendRuntime(
          debounce: Duration.zero,
          prepare: () {
            events.add('prepare');
            return setup.future;
          },
          drain: () async {
            events.add('drain');
            return const CloudSyncLocalSendConsumerResult();
          },
          onError: (_, __) => fail('unexpected failure'),
        );
        runtime.request(CloudSyncTrigger.startup);
        time.elapse(Duration.zero);
        runtime.request(CloudSyncTrigger.localOutbox);
        time.flushMicrotasks();
        expect(events, ['prepare']);
        setup.complete();
        time.elapse(Duration.zero);
        time.flushMicrotasks();
        expect(events, ['prepare', 'drain', 'drain']);
        unawaited(runtime.dispose());
        time.flushMicrotasks();
      });
    },
  );

  test(
    'failed setup never drains and a later explicit trigger rechecks it',
    () {
      fakeAsync((time) {
        var preparations = 0;
        var drains = 0;
        var errors = 0;
        final runtime = CloudSyncLocalSendRuntime(
          debounce: Duration.zero,
          prepare: () async {
            if (++preparations == 1) throw StateError('setup_blocked');
          },
          drain: () async {
            drains++;
            return const CloudSyncLocalSendConsumerResult();
          },
          onError: (_, __) => errors++,
        );
        runtime.request(CloudSyncTrigger.startup);
        time.elapse(const Duration(hours: 1));
        expect((preparations, drains, errors), (1, 0, 1));
        runtime.request(CloudSyncTrigger.networkReconnect);
        time.elapse(Duration.zero);
        expect((preparations, drains, errors), (2, 1, 1));
        unawaited(runtime.dispose());
        time.flushMicrotasks();
      });
    },
  );

  test('logout during preparation waits but never starts a drain', () {
    fakeAsync((time) {
      final setup = Completer<void>();
      var drained = false;
      var disposed = false;
      final runtime = CloudSyncLocalSendRuntime(
        debounce: Duration.zero,
        prepare: () => setup.future,
        drain: () async {
          drained = true;
          return const CloudSyncLocalSendConsumerResult();
        },
        onError: (_, __) => fail('unexpected failure'),
      );
      runtime.request(CloudSyncTrigger.startup);
      time.elapse(Duration.zero);
      unawaited(runtime.dispose().then((_) => disposed = true));
      time.flushMicrotasks();
      expect(disposed, false);
      setup.complete();
      time.flushMicrotasks();
      expect(disposed, true);
      expect(drained, false);
    });
  });

  test(
    'manual writer builds alone cannot start the automatic production adapter',
    () async {
      expect(CloudSyncDevGate.localSendRuntimeEnabled, isFalse);
      var clientReads = 0;
      final adapter = CloudSyncProductionLocalSendAdapter(
        readActiveClient: () {
          clientReads++;
          return null;
        },
        privateStorageDirectory: 'unused-gated-path',
        stillCurrent: () => true,
      );
      await expectLater(adapter.runOnce(), throwsStateError);
      expect(clientReads, 0);
    },
  );

  test('startup and send bursts coalesce without waiting on IDS', () {
    fakeAsync((time) {
      var calls = 0;
      final runtime = CloudSyncLocalSendRuntime(
        drain: () async {
          calls++;
          return const CloudSyncLocalSendConsumerResult();
        },
        onError: (_, __) => fail('unexpected worker failure'),
      );
      for (var i = 0; i < 20; i++) {
        runtime.request(CloudSyncTrigger.localOutbox);
      }
      expect(calls, 0);
      time.elapse(const Duration(seconds: 5));
      time.flushMicrotasks();
      expect(calls, 1);
      time.elapse(const Duration(hours: 1));
      expect(calls, 1);
      unawaited(runtime.dispose());
      time.flushMicrotasks();
    });
  });

  test('uncertain work is retried after delay, never a tight upload loop', () {
    fakeAsync((time) {
      var calls = 0;
      final runtime = CloudSyncLocalSendRuntime(
        debounce: Duration.zero,
        drain: () async =>
            CloudSyncLocalSendConsumerResult(outboxBlocked: ++calls == 1),
        onError: (_, __) => fail('unexpected failure'),
      );
      runtime.request(CloudSyncTrigger.startup);
      time.elapse(Duration.zero);
      time.flushMicrotasks();
      expect(calls, 1);
      time.elapse(const Duration(seconds: 59));
      expect(calls, 1);
      time.elapse(const Duration(seconds: 1));
      time.flushMicrotasks();
      expect(calls, 2);
      time.elapse(const Duration(hours: 1));
      expect(calls, 2);
      unawaited(runtime.dispose());
      time.flushMicrotasks();
    });
  });

  test('deferred origins and bounded batches retain a follow-up wakeup', () {
    fakeAsync((time) {
      var calls = 0;
      final runtime = CloudSyncLocalSendRuntime(
        debounce: Duration.zero,
        drain: () async => switch (++calls) {
          1 => const CloudSyncLocalSendConsumerResult(deferred: 1),
          2 => const CloudSyncLocalSendConsumerResult(admitted: 20),
          _ => const CloudSyncLocalSendConsumerResult(),
        },
        onError: (_, __) => fail('unexpected failure'),
      );
      runtime.request(CloudSyncTrigger.startup);
      time.elapse(const Duration(minutes: 3));
      time.flushMicrotasks();
      expect(calls, 3);
      unawaited(runtime.dispose());
      time.flushMicrotasks();
    });
  });

  test('identity failure is surfaced and waits for a new explicit trigger', () {
    fakeAsync((time) {
      var errors = 0;
      var calls = 0;
      final runtime = CloudSyncLocalSendRuntime(
        debounce: Duration.zero,
        drain: () async {
          calls++;
          throw StateError('identity_changed');
        },
        onError: (_, __) {
          errors++;
          throw StateError('observer_failed');
        },
      );
      runtime.request(CloudSyncTrigger.startup);
      time.elapse(const Duration(hours: 1));
      time.flushMicrotasks();
      expect(calls, 1);
      expect(errors, 1);
      runtime.request(CloudSyncTrigger.networkReconnect);
      time.elapse(Duration.zero);
      time.flushMicrotasks();
      expect(calls, 2);
      unawaited(runtime.dispose());
      time.flushMicrotasks();
    });
  });

  test(
    'logout waits for active work and cancels queued and delayed wakeups',
    () {
      fakeAsync((time) {
        final active = Completer<CloudSyncLocalSendConsumerResult>();
        var calls = 0;
        var disposed = false;
        final runtime = CloudSyncLocalSendRuntime(
          debounce: Duration.zero,
          drain: () {
            calls++;
            return active.future;
          },
          onError: (_, __) => fail('unexpected failure'),
        );
        runtime.request(CloudSyncTrigger.startup);
        time.elapse(Duration.zero);
        runtime.request(CloudSyncTrigger.localOutbox);
        unawaited(runtime.dispose().then((_) => disposed = true));
        time.flushMicrotasks();
        expect(disposed, false);
        active.complete(
          const CloudSyncLocalSendConsumerResult(outboxBlocked: true),
        );
        time.flushMicrotasks();
        expect(disposed, true);
        runtime.request(CloudSyncTrigger.localOutbox);
        time.elapse(const Duration(hours: 1));
        expect(calls, 1);
      });
    },
  );

  test(
    'new account lifetime discovers durable work rather than old timers',
    () {
      fakeAsync((time) {
        var calls = 0;
        Future<CloudSyncLocalSendConsumerResult> drain() async {
          calls++;
          return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
        }

        final first = CloudSyncLocalSendRuntime(
          debounce: Duration.zero,
          drain: drain,
          onError: (_, __) {},
        );
        first.request(CloudSyncTrigger.startup);
        time.elapse(Duration.zero);
        unawaited(first.dispose());
        time.flushMicrotasks();
        final second = CloudSyncLocalSendRuntime(
          debounce: Duration.zero,
          drain: drain,
          onError: (_, __) {},
        );
        second.request(CloudSyncTrigger.startup);
        time.elapse(Duration.zero);
        expect(calls, 2);
        unawaited(second.dispose());
        time.flushMicrotasks();
        time.elapse(const Duration(hours: 1));
        expect(calls, 2);
      });
    },
  );
}
