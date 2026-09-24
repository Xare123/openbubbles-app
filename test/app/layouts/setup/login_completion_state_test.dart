import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('doRegister with no users fails without publishing success', () async {
    final controller = SetupViewController();
    controller.success = true;
    await expectLater(controller.doRegister(), throwsA(isA<Exception>()));
    expect(controller.success, isFalse);
  });
  test('superseded attempt cannot publish success', () {
    final controller = SetupViewController();
    final stale = controller.beginLoginAttempt();
    controller.beginLoginAttempt();
    expect(controller.publishLoginSuccess(attempt: stale), isFalse);
    expect(controller.success, isFalse);
  });
  test('retry starts clean after a failed attempt', () async {
    final controller = SetupViewController();
    controller.success = true;
    await expectLater(controller.doRegister(), throwsA(isA<Exception>()));
    expect(controller.success, isFalse);
    final retry = controller.beginLoginAttempt();
    expect(controller.publishLoginSuccess(attempt: retry), isTrue);
    expect(controller.success, isTrue);
  });
  test('background startup errors record distinctly from credentials', () {
    final controller = SetupViewController();
    controller.noteBackgroundStartupError(StateError('boom'));
    expect(controller.backgroundStartupError, isA<StateError>());
    expect(controller.success, isFalse);
    expect(controller.error, isEmpty);
  });
}
