import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/src/rust/lib.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApsConnection implements ApsConnection {
  bool disposed = false;
  int disposeCount = 0;

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    disposeCount++;
  }

  @override
  bool get isDisposed => disposed;
}
void main() {
  test('only the newest login attempt remains current', () {
    final guard = LoginAttemptGuard();

    final first = guard.begin();
    expect(guard.isCurrent(first), isTrue);

    final second = guard.begin();
    expect(guard.isCurrent(first), isFalse);
    expect(guard.isCurrent(second), isTrue);

    guard.invalidate();
    expect(guard.isCurrent(second), isFalse);
    guard.invalidate();
    expect(guard.isCurrent(second), isFalse);
  });

  test(
    'resource disposal is deferred and idempotent during cancellation',
    () async {
      final controller = SetupViewController();
      final connection = _FakeApsConnection();
      controller.connection = connection;
      final attempt = controller.beginLoginAttempt();

      final result = await controller.withLoginAttemptResources(
        attempt,
        [connection],
        () async {
          controller.destroyConnection();
          controller.destroyConnection();
          expect(connection.disposeCount, 0);
          return 7;
        },
      );

      expect(result, 7);
      expect(connection.disposeCount, 1);
    },
  );

  test('canceling an attempt is safe to repeat', () {
    final controller = SetupViewController();
    final attempt = controller.beginLoginAttempt();

    controller.cancelLoginAttempt();
    controller.cancelLoginAttempt();

    expect(controller.isLoginAttemptCurrent(attempt), isFalse);
  });
}
