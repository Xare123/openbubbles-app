import 'dart:async';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_source_runtime.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bursts coalesce and resume all bounded pages without a new user tap',
    () {
      fakeAsync((time) {
        var calls = 0;
        final runtime = CloudSyncReceivedSourceRuntime(
          debounce: Duration.zero,
          drain: () async => (more: ++calls < 3, deferred: false),
          onError: (_, __) => fail('unexpected'),
        );
        for (var i = 0; i < 8; i++) {
          runtime.request(CloudSyncTrigger.startup);
        }
        time.elapse(Duration.zero);
        expect(calls, 3);
        unawaited(runtime.dispose());
        time.flushMicrotasks();
      });
    },
  );
  test('transient staged-source failures back off; disposal cancels retry', () {
    fakeAsync((time) {
      var calls = 0;
      final runtime = CloudSyncReceivedSourceRuntime(
        debounce: Duration.zero,
        drain: () async {
          calls++;
          return (more: false, deferred: true);
        },
        onError: (_, __) {},
      );
      runtime.request(CloudSyncTrigger.startup);
      time.elapse(Duration.zero);
      expect(calls, 1);
      time.elapse(const Duration(minutes: 1));
      expect(calls, 2);
      time.elapse(const Duration(minutes: 1));
      expect(calls, 2);
      time.elapse(const Duration(minutes: 1));
      expect(calls, 3);
      unawaited(runtime.dispose());
      time.flushMicrotasks();
      time.elapse(const Duration(days: 1));
      expect(calls, 3);
    });
  });
  test('identity failure does not self-retry until a fresh event', () {
    fakeAsync((time) {
      var calls = 0, errors = 0;
      final runtime = CloudSyncReceivedSourceRuntime(
        debounce: Duration.zero,
        drain: () async {
          calls++;
          throw StateError('identity changed');
        },
        onError: (_, __) {
          errors++;
        },
      );
      runtime.request(CloudSyncTrigger.startup);
      time.elapse(const Duration(days: 1));
      expect(calls, 1);
      expect(errors, 1);
      runtime.request(CloudSyncTrigger.networkReconnect);
      time.elapse(Duration.zero);
      expect(calls, 2);
      unawaited(runtime.dispose());
      time.flushMicrotasks();
    });
  });
  test(
    'disposal joins the running local pass instead of dropping ownership',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final runtime = CloudSyncReceivedSourceRuntime(
        debounce: Duration.zero,
        drain: () async {
          entered.complete();
          await release.future;
          return (more: true, deferred: true);
        },
        onError: (_, __) {},
      );
      runtime.request(CloudSyncTrigger.startup);
      await entered.future;
      var disposed = false;
      final drain = runtime.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      release.complete();
      await drain;
      expect(disposed, isTrue);
    },
  );
}
