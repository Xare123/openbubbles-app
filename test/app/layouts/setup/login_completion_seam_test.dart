import 'dart:async';
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
  test('completion does not wait for background work', () async {
    final c = SetupViewController();
    final bg = Completer<void>();
    final done = c.completeLoginRegistration(ensureConfigured: () async {}, loadHandles: () async => <String>[], setupEncryption: () async {}, persistCompletion: () async {}, clearTransferMaterial: () {}, isHostedDevice: () => false, startBackground: () => bg.future);
    await done;
    expect(c.success, isTrue);
    expect(c.backgroundStartupError, isNull);
    bg.completeError(StateError('bg'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c.success, isTrue);
    expect(c.backgroundStartupError, isA<StateError>());
  });
  test('stale background failure does not overwrite newer attempt', () async {
    final c = SetupViewController();
    final first = c.beginLoginAttempt();
    final bg = Completer<void>();
    await c.completeLoginRegistration(attempt: first, ensureConfigured: () async {}, loadHandles: () async => <String>[], setupEncryption: () async {}, persistCompletion: () async {}, clearTransferMaterial: () {}, isHostedDevice: () => false, startBackground: () => bg.future);
    expect(c.success, isTrue);
    c.beginLoginAttempt();
    bg.completeError(StateError('old'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c.success, isTrue);
    expect(c.backgroundStartupError, isNull);
  });
  test('superseded attempt stops at a pending stage', () async {
    final c = SetupViewController();
    final attempt = c.beginLoginAttempt();
    final gate = Completer<void>();
    var configured = false;
    var handlesCalled = false;
    final pending = c.completeLoginRegistration(attempt: attempt, ensureConfigured: () { configured = true; return gate.future; }, loadHandles: () async { handlesCalled = true; return <String>[]; });
    await Future<void>.delayed(Duration.zero);
    expect(configured, isTrue);
    c.beginLoginAttempt();
    gate.complete();
    await pending;
    expect(c.success, isFalse);
    expect(handlesCalled, isFalse);
    expect(c.backgroundStartupError, isNull);
  });
  test('retry through the completion tail succeeds', () async {
    final c = SetupViewController();
    final first = c.beginLoginAttempt();
    await expectLater(c.completeLoginRegistration(attempt: first, ensureConfigured: () async {}, loadHandles: () async => <String>[], setupEncryption: () async {}, persistCompletion: () => throw StateError('persist'), clearTransferMaterial: () {}, isHostedDevice: () => false, startBackground: () async {}), throwsStateError);
    expect(c.success, isFalse);
    final retry = c.beginLoginAttempt();
    var launched = false;
    await c.completeLoginRegistration(attempt: retry, ensureConfigured: () async {}, loadHandles: () async => <String>[], setupEncryption: () async {}, persistCompletion: () async {}, clearTransferMaterial: () {}, isHostedDevice: () => false, startBackground: () async { launched = true; });
    expect(c.success, isTrue);
    expect(launched, isTrue);
    expect(c.backgroundStartupError, isNull);
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
    await c.completeLoginRegistration(ensureConfigured: () async { order.add('configured'); }, loadHandles: () async { order.add('handles'); return <String>['tel:+1555']; }, saveDefaultHandle: (String phone) async { order.add('handle'); }, setupEncryption: () async { order.add('encryption'); }, persistCompletion: () async { order.add('persist'); }, clearTransferMaterial: () {}, isHostedDevice: () => false, startBackground: () async { launched = true; });
    expect(c.success, isTrue);
    expect(order, <String>['configured', 'handles', 'handle', 'encryption', 'persist']);
    expect(launched, isTrue);
  });
}
