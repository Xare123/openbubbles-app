import 'dart:async';

import 'package:bluebubbles/services/rustpush/rustpush_receive_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'retained receive joins processing past its UI deadline and certification',
    () async {
      final processing = Completer<void>();
      final certification = Completer<void>();
      var certifyCalls = 0;
      var completed = false;
      final receive = completeRustPushReceive(
        process: () => processing.future,
        certify: () {
          certifyCalls++;
          return certification.future;
        },
        retainEnteredWork: true,
        processingTimeout: const Duration(milliseconds: 1),
      )..then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(completed, isFalse);
      expect(certifyCalls, 0);
      processing.complete();
      await Future<void>.delayed(Duration.zero);
      expect(certifyCalls, 1);
      expect(completed, isFalse);
      certification.complete();
      await receive;
      expect(completed, isTrue);
    },
  );

  test('ordinary receive retains its bounded processing timeout', () async {
    final processing = Completer<void>();
    var certifyCalls = 0;
    final receive = completeRustPushReceive(
      process: () => processing.future,
      certify: () async {
        certifyCalls++;
      },
      retainEnteredWork: false,
      processingTimeout: const Duration(milliseconds: 1),
    );
    await expectLater(receive, throwsA(isA<TimeoutException>()));
    processing.complete();
    await Future<void>.delayed(Duration.zero);
    expect(certifyCalls, 0);
  });

  test('ordinary receive keeps asynchronous delivery certification', () async {
    final certification = Completer<void>();
    var certifyCalls = 0;
    await completeRustPushReceive(
      process: () async {},
      certify: () {
        certifyCalls++;
        return certification.future;
      },
      retainEnteredWork: false,
    );
    expect(certifyCalls, 1);
    certification.complete();
  });

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
