import 'dart:async';

import 'package:bluebubbles/services/rustpush/rustpush_receive_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('readiness waits for native state and database only', () async {
    final nativeStateReady = Completer<void>();
    final databaseReady = Completer<void>();
    final state = Object();

    final ready = waitForRustPushReceiveReadiness<Object>(
      nativeStateReady: nativeStateReady.future,
      databaseReady: databaseReady.future,
      currentState: () => state,
    );

    nativeStateReady.complete();
    databaseReady.complete();

    await expectLater(ready, completion(same(state)));
  });

  test('readiness fails when native state is unavailable', () async {
    await expectLater(
      waitForRustPushReceiveReadiness<Object>(
        nativeStateReady: Future<void>.value(),
        databaseReady: Future<void>.value(),
        currentState: () => null,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('readiness wait is bounded', () async {
    await expectLater(
      waitForRustPushReceiveReadiness<Object>(
        nativeStateReady: Completer<void>().future,
        databaseReady: Future<void>.value(),
        currentState: () => Object(),
        timeout: const Duration(milliseconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}
