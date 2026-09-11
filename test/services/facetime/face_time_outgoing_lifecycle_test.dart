import 'dart:async';

import '../../../lib/services/rustpush/face_time_outgoing_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

class ManualTimer implements Timer {
  ManualTimer(this.callback);
  final void Function() callback;
  bool active = true;
  @override
  void cancel() => active = false;
  @override
  bool get isActive => active;
  @override
  int get tick => active ? 0 : 1;
  void fire({bool evenIfCancelled = false}) {
    if (active || evenIfCancelled) {
      active = false;
      callback();
    }
  }
}

class Harness {
  final timers = <ManualTimer>[];
  late final calls = FaceTimeOutgoingLifecycle<String>(
    schedule: (delay, action) {
      expect(delay, const Duration(seconds: 30));
      final timer = ManualTimer(action);
      timers.add(timer);
      return timer;
    },
  );
}

void main() {
  test(
    'early JoinEvent before create completes cannot arm an accepted-call timeout',
    () async {
      final h = Harness();
      final call = h.calls.begin('a', 'ringing')!;
      final created = Completer<void>();
      final launch = Completer<void>();
      var cancellations = 0;
      final start = () async {
        await created.future;
        h.calls.armTimeout(call, () async {
          cancellations++;
        });
      }();
      final joined = h.calls.complete(call, () => launch.future);
      created.complete();
      await start;
      for (final timer in h.timers) {
        timer.fire();
      }
      expect(cancellations, 0);
      expect(h.timers, isEmpty);
      launch.complete();
      await joined;
    },
  );

  test(
    'old asynchronous finally cannot clear a newer call or its metadata',
    () async {
      final h = Harness();
      final oldCall = h.calls.begin('a', 'ringing')!;
      final cancelled = Completer<void>();
      final ending = h.calls.complete(oldCall, () => cancelled.future);
      final nextCall = h.calls.begin('b', 'ringing')!;
      nextCall.metadata['link'] = 'synthetic-b';
      cancelled.complete();
      await ending;
      expect(h.calls.current, same(nextCall));
      expect(h.calls.current?.metadata['link'], 'synthetic-b');
      expect(h.calls.isPending(nextCall), isTrue);
    },
  );

  test(
    'queued old timer cannot cancel or publish status into a newer call',
    () async {
      final h = Harness();
      final old = h.calls.begin('a', 'ringing')!;
      var oldTimeouts = 0;
      h.calls.armTimeout(old, () async {
        oldTimeouts++;
      });
      final oldTimer = h.timers.single;
      final launch = Completer<void>();
      final accepted = h.calls.complete(old, () => launch.future);
      final next = h.calls.begin('b', 'ringing')!;
      var nextTimeouts = 0;
      h.calls.armTimeout(next, () async {
        nextTimeouts++;
      });
      expect(oldTimer.isActive, isFalse);
      oldTimer.fire(evenIfCancelled: true);
      await Future<void>.value();
      expect(oldTimeouts, 0);
      expect(nextTimeouts, 0);
      expect(h.calls.current, same(next));
      expect(h.timers.last.isActive, isTrue);
      launch.complete();
      await accepted;
    },
  );

  test(
    'timeout claims once and cleanup preserves a manual retry during cancellation',
    () async {
      final h = Harness();
      final old = h.calls.begin('a', 'ringing')!;
      final cancellation = Completer<void>();
      var timeoutStatusCount = 0;
      h.calls.armTimeout(old, () async {
        timeoutStatusCount++;
        await cancellation.future;
      });
      h.timers.single.fire();
      h.timers.single.fire(evenIfCancelled: true);
      expect(timeoutStatusCount, 1);
      expect(h.calls.isPending(old), isFalse);
      final retry = h.calls.begin('b', 'ringing')!;
      cancellation.complete();
      await Future<void>.value();
      await Future<void>.value();
      expect(h.calls.current, same(retry));
    },
  );

  test(
    'failed old launch or cancellation cannot clear the new timer or metadata',
    () async {
      for (final operation in ['launch', 'cancel']) {
        final h = Harness();
        final old = h.calls.begin('a', 'ringing')!;
        final action = Completer<void>();
        final ending = h.calls.complete(old, () => action.future);
        final assertion = expectLater(ending, throwsStateError);
        final next = h.calls.begin('b', 'ringing')!;
        next.metadata['link'] = 'synthetic-b';
        h.calls.armTimeout(next, () async {});
        action.completeError(StateError(operation));
        await assertion;
        expect(h.calls.current, same(next));
        expect(next.metadata['link'], 'synthetic-b');
        expect(h.timers.single.isActive, isTrue);
      }
    },
  );

  test(
    'ordinary timeout releases its call even if cancellation throws',
    () async {
      final h = Harness();
      final call = h.calls.begin('a', 'ringing')!;
      final action = Completer<void>();
      final ending = h.calls.complete(call, () => action.future);
      final assertion = expectLater(ending, throwsStateError);
      action.completeError(StateError('synthetic cancellation failure'));
      await assertion;
      expect(h.calls.current, isNull);
    },
  );

  test(
    'late creation failure and duplicate terminal events cannot claim an accepted call',
    () async {
      final h = Harness();
      final call = h.calls.begin('a', 'ringing')!;
      var launches = 0;
      var failureNotices = 0;
      final launch = Completer<void>();
      final accepted = h.calls.complete(call, () async {
        launches++;
        await launch.future;
      });
      expect(
        await h.calls.complete(call, () async {
          failureNotices++;
        }),
        isFalse,
      );
      expect(
        h.calls.armTimeout(call, () async {
          failureNotices++;
        }),
        isFalse,
      );
      launch.complete();
      await accepted;
      expect(
        await h.calls.complete(call, () async {
          launches++;
        }),
        isFalse,
      );
      expect(launches, 1);
      expect(failureNotices, 0);
    },
  );

  test(
    'timer installation is idempotent and decline cancels only its owner',
    () async {
      final h = Harness();
      final call = h.calls.begin('a', 'ringing')!;
      var timeouts = 0;
      expect(
        h.calls.armTimeout(call, () async {
          timeouts++;
        }),
        isTrue,
      );
      expect(
        h.calls.armTimeout(call, () async {
          timeouts++;
        }),
        isFalse,
      );
      expect(h.timers, hasLength(1));
      await h.calls.complete(call, () async {});
      h.timers.single.fire(evenIfCancelled: true);
      await Future<void>.value();
      expect(timeouts, 0);
      expect(h.calls.current, isNull);
    },
  );

  test('same visible ID still requires object identity for cleanup', () async {
    final h = Harness();
    final old = h.calls.begin('same-id', 'ringing')!;
    final action = Completer<void>();
    final ending = h.calls.complete(old, () => action.future);
    final next = h.calls.begin('same-id', 'ringing')!;
    action.complete();
    await ending;
    expect(h.calls.current, same(next));
    expect(h.calls.isPending(old), isFalse);
  });

  test(
    'duplicate setup cannot orphan the pending invitation or its timeout',
    () {
      final h = Harness();
      final call = h.calls.begin('a', 'ringing')!;
      h.calls.armTimeout(call, () async {});
      expect(h.calls.begin('b', 'ringing'), isNull);
      expect(h.calls.current, same(call));
      expect(h.timers.single.isActive, isTrue);
    },
  );
}
