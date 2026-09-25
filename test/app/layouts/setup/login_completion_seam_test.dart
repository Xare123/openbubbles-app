import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('required persist failure is not background', () async {
    final c = SetupViewController();
    await expectLater(c.completeLoginRegistration(ensureConfigured: () async {}, loadHandles: () async => <String>[], setupEncryption: () async {}, persistCompletion: () => throw StateError('persist')), throwsStateError);
    expect(c.success, isFalse);
    expect(c.backgroundStartupError, isNull);
  });
  test('required configured failure keeps success false', () async {
    final c = SetupViewController();
    await expectLater(c.completeLoginRegistration(ensureConfigured: () => throw StateError('cfg')), throwsStateError);
    expect(c.success, isFalse);
    expect(c.backgroundStartupError, isNull);
  });
  test('required handles failure keeps success false', () async {
    final c = SetupViewController();
    await expectLater(c.completeLoginRegistration(ensureConfigured: () async {}, loadHandles: () => throw StateError('handles')), throwsStateError);
    expect(c.success, isFalse);
    expect(c.backgroundStartupError, isNull);
  });
  test('required encryption failure keeps success false', () async {
    final c = SetupViewController();
    await expectLater(c.completeLoginRegistration(ensureConfigured: () async {}, loadHandles: () async => <String>[], setupEncryption: () => throw StateError('clique')), throwsStateError);
    expect(c.success, isFalse);
    expect(c.backgroundStartupError, isNull);
  });
  test('background failure records distinctly without clearing success', () async {
    final c = SetupViewController();
    var launched = false;
    await c.completeLoginRegistration(ensureConfigured: () async {}, loadHandles: () async => <String>[], setupEncryption: () async {}, persistCompletion: () async {}, clearTransferMaterial: () {}, isHostedDevice: () => false, startBackground: () { launched = true; c.noteBackgroundStartupError(StateError('bg')); });
    expect(c.success, isTrue);
    expect(launched, isTrue);
    expect(c.backgroundStartupError, isA<StateError>());
  });
  test('stale attempt completes nothing', () async {
    final c = SetupViewController();
    final stale = c.beginLoginAttempt();
    c.beginLoginAttempt();
    var called = false;
    Future<void> mark() async { called = true; }
    await c.completeLoginRegistration(attempt: stale, ensureConfigured: mark, loadHandles: () async { called = true; return <String>[]; }, setupEncryption: mark, persistCompletion: mark);
    expect(c.success, isFalse);
    expect(called, isFalse);
  });
  test('success publishes only after required stages', () async {
    final c = SetupViewController();
    final order = <String>[];
    var launched = false;
    await c.completeLoginRegistration(ensureConfigured: () async { order.add('configured'); }, loadHandles: () async { order.add('handles'); return <String>['tel:+1555']; }, saveDefaultHandle: (String phone) async { order.add('handle'); }, setupEncryption: () async { order.add('encryption'); }, persistCompletion: () async { order.add('persist'); }, clearTransferMaterial: () {}, isHostedDevice: () => false, startBackground: () { launched = true; });
    expect(c.success, isTrue);
    expect(order, <String>['configured', 'handles', 'handle', 'encryption', 'persist']);
    expect(launched, isTrue);
  });
}
