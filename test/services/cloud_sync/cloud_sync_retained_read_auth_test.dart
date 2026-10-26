import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_retained_read_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const owner = ('account', 'store');

  test('readiness waits for proof on the original active owner after login', () async {
    final attempt = CloudSyncRetainedReadAuthentication();
    final events = <String>[];
    final proof = Completer<(String, String)>();
    var finished = false;
    final run = attempt.run(
      stillCurrent: () => true,
      capturePersistedOwner: () async { events.add('persisted'); return owner; },
      authenticate: () async { events.add('login'); },
      verifyActiveOwner: () { events.add('original-client'); return proof.future; },
    ).then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['persisted', 'login', 'original-client']);
    expect(finished, isFalse);
    proof.complete(owner);
    await run;
    expect(finished, isTrue);
    expect(attempt.attempted, isTrue);
    expect(attempt.restartRequired, isFalse);
  });

  for (final changed in [('different-account', 'store'), ('account', 'different-store')]) {
    test('fresh login cannot authorize changed owner $changed', () async {
      final attempt = CloudSyncRetainedReadAuthentication();
      await expectLater(attempt.run(
        stillCurrent: () => true,
        capturePersistedOwner: () async => owner,
        authenticate: () async {},
        verifyActiveOwner: () async => changed,
      ), throwsStateError);
      expect(attempt.restartRequired, isTrue);
    });
  }

  for (final stage in ['login', 'original-client']) {
    test('$stage failure remains fenced and cannot automatically retry', () async {
      final attempt = CloudSyncRetainedReadAuthentication();
      var logins = 0;
      var proofs = 0;
      Future<void> run() => attempt.run(
        stillCurrent: () => true,
        capturePersistedOwner: () async => owner,
        authenticate: () async { logins++; if (stage == 'login') throw StateError('failed'); },
        verifyActiveOwner: () async { proofs++; throw StateError('failed'); },
      );
      await expectLater(run(), throwsStateError);
      expect(attempt.restartRequired, isTrue);
      await expectLater(run(), throwsStateError);
      expect(logins, 1);
      expect(proofs, stage == 'login' ? 0 : 1);
    });
  }

  for (final stage in ['capture', 'login', 'original-client']) {
    test('identity loss during $stage refuses all later work', () async {
      final attempt = CloudSyncRetainedReadAuthentication();
      final events = <String>[];
      var current = true;
      await expectLater(attempt.run(
        stillCurrent: () => current,
        capturePersistedOwner: () async { events.add('capture'); current = stage != 'capture'; return owner; },
        authenticate: () async { events.add('login'); current = stage != 'login'; },
        verifyActiveOwner: () async { events.add('original-client'); current = false; return owner; },
      ), throwsStateError);
      expect(events, switch (stage) {
        'capture' => ['capture'],
        'login' => ['capture', 'login'],
        _ => ['capture', 'login', 'original-client'],
      });
      expect(attempt.restartRequired, stage != 'capture');
    });
  }

  test('unavailable initial host performs no capture or login', () async {
    final attempt = CloudSyncRetainedReadAuthentication();
    await expectLater(attempt.run(
      stillCurrent: () => false,
      capturePersistedOwner: () async => throw StateError('must not capture'),
      authenticate: () async => fail('must not login'),
      verifyActiveOwner: () async => throw StateError('must not prove'),
    ), throwsStateError);
    expect(attempt.attempted, isFalse);
    expect(attempt.restartRequired, isFalse);
  });

  for (final invalid in [('', 'store'), ('account', '')]) {
    test('missing persisted owner $invalid performs no authentication', () async {
      final attempt = CloudSyncRetainedReadAuthentication();
      await expectLater(attempt.run(
        stillCurrent: () => true,
        capturePersistedOwner: () async => invalid,
        authenticate: () async => fail('must not login'),
        verifyActiveOwner: () async => throw StateError('must not prove'),
      ), throwsStateError);
      expect(attempt.restartRequired, isFalse);
    });
  }

  test('a completed explicit repair is also consumed', () async {
    final attempt = CloudSyncRetainedReadAuthentication();
    var logins = 0;
    Future<void> run() => attempt.run(
      stillCurrent: () => true,
      capturePersistedOwner: () async => owner,
      authenticate: () async { logins++; },
      verifyActiveOwner: () async => owner,
    );
    await run();
    await expectLater(run(), throwsStateError);
    expect(logins, 1);
    expect(attempt.restartRequired, isFalse);
  });
}
