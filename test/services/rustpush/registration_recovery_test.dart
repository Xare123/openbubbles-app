import 'package:bluebubbles/services/rustpush/registration_recovery.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const terminal = api.RegisterState.failed(error: 'Bad auth cert 6005');
  final transient = api.RegisterState.failed(
    error: 'Relay device offline!',
    retryWait: BigInt.from(300),
  );

  test('terminal failure preserves the cause without declaring logout', () {
    final notice = RegistrationFailureNotice.fromState(
      terminal as api.RegisterState_Failed,
    );
    expect(notice.requiresRepair, isTrue);
    expect(notice.statusText((seconds) => '${seconds}s'), contains('6005'));
    expect(notice.title, isNot(contains('Logged out')));
    expect(notice.body, isNot(contains('receive')));
    expect(RegistrationFailureNotice.profilePayload, '-51');
    // Detailed account errors belong in Profile, not on the lock screen.
    expect('${notice.title} ${notice.body}', isNot(contains('6005')));
  });

  test('retryable relay failure keeps retry and neutral relay wording', () {
    final notice = RegistrationFailureNotice.fromState(
      transient as api.RegisterState_Failed,
    );
    expect(notice.requiresRepair, isFalse);
    expect(notice.retryWaitSeconds, 300);
    expect(
      notice.statusText((seconds) => '${seconds}s'),
      'Deregistered (waiting 300s; error: Relay service unavailable!)',
    );
  });

  test('closed and other non-retryable failures also do not imply logout', () {
    for (final error in ['Closed', 'Validation unavailable', '6005']) {
      final notice = RegistrationFailureNotice(
        error: error,
        retryWaitSeconds: null,
      );
      expect(notice.requiresRepair, isTrue);
      expect(notice.statusText((seconds) => '$seconds'), contains(error));
      expect(notice.title.toLowerCase(), isNot(contains('logout')));
    }
  });

  test('initial failed state uses the same observer as live failures', () {
    final notices = <RegistrationFailureNotice>[];
    final observer = RegistrationStateObserver(
      onRegistered: (_) => fail('failure must not be reported as ready'),
      onRegistering: () => fail('failure must not start a retry'),
      onFailed: notices.add,
    );
    observer.accept(terminal);
    observer.accept(terminal);
    expect(notices, hasLength(1));
    expect(notices.single.error, 'Bad auth cert 6005');
    expect(notices.single.requiresRepair, isTrue);
  });

  test(
    'terminal failure after a transient failure gets a new notification',
    () {
      final notices = <RegistrationFailureNotice>[];
      var registering = 0;
      final observer = RegistrationStateObserver(
        onRegistered: (_) => fail('not registered'),
        onRegistering: () => registering++,
        onFailed: notices.add,
      );
      observer.accept(transient);
      observer.accept(const api.RegisterState.registering());
      observer.accept(transient);
      observer.accept(terminal);
      expect(registering, 1);
      expect(notices.map((n) => n.requiresRepair), [false, true]);
    },
  );

  test('successful registration clears suppression for the next failure', () {
    final notices = <RegistrationFailureNotice>[];
    final renewals = <int>[];
    final observer = RegistrationStateObserver(
      onRegistered: renewals.add,
      onRegistering: () {},
      onFailed: notices.add,
    );
    observer.accept(terminal);
    observer.accept(const api.RegisterState.registered(nextS: 3600));
    observer.accept(terminal);
    expect(renewals, [3600]);
    expect(notices, hasLength(2));
  });
}
