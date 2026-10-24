import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/backend_harness/backend_harness_interactions.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher failure(String code) =>
    isA<BackendHarnessFailure>().having((error) => error.code, 'code', code);

void main() {
  test(
    'secret challenge publishes no secret and is consumed exactly once',
    () async {
      final broker = BackendHarnessInteractions(random: Random(1));
      final secret = broker.secret(
        BackendHarnessChallengeKind.passcode,
        stillCurrent: () => true,
      );
      final challenge = broker.pending!;
      expect(challenge.toJson().keys.toSet(), {'id', 'kind', 'options'});
      const value = 'private passcode';
      broker.answerSecret(challenge.id, value);
      expect(await secret, value);
      expect(broker.pending, null);
      expect(jsonEncode(challenge.toJson()), isNot(contains(value)));
      expect(
        () => broker.answerSecret(challenge.id, value),
        throwsA(failure('backend_stale_session')),
      );
    },
  );

  test(
    'unknown handle and wrong input kind leave the original prompt pending',
    () async {
      final broker = BackendHarnessInteractions();
      final choice = broker.chooseDevice(count: 2, stillCurrent: () => true);
      final id = broker.pending!.id;
      expect(
        () => broker.answerChoice('foreign-handle', 0),
        throwsA(failure('backend_stale_session')),
      );
      expect(
        () => broker.answerSecret(id, 'secret'),
        throwsA(failure('backend_invalid_arguments')),
      );
      expect(
        () => broker.answerChoice(id, 2),
        throwsA(failure('backend_invalid_arguments')),
      );
      expect(broker.pending!.id, id);
      broker.answerChoice(id, 1);
      expect(await choice, 1);
    },
  );

  test(
    'account change cancels the prompt instead of delivering its answer',
    () async {
      var current = true;
      final broker = BackendHarnessInteractions();
      final secret = broker.secret(
        BackendHarnessChallengeKind.pin,
        stillCurrent: () => current,
      );
      final id = broker.pending!.id;
      current = false;
      expect(
        () => broker.answerSecret(id, '123456'),
        throwsA(failure('backend_identity_changed')),
      );
      expect(await secret, null);
      expect(broker.pending, null);
    },
  );

  test(
    'expiry cooperatively returns cancel and cannot consume a later prompt',
    () {
      fakeAsync((clock) {
        final broker = BackendHarnessInteractions();
        Object? outcome = 'not-complete';
        broker
            .secret(
              BackendHarnessChallengeKind.pin,
              stillCurrent: () => true,
              deadline: const Duration(seconds: 1),
            )
            .then((value) => outcome = value);
        final expired = broker.pending!.id;
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        expect(outcome, null);
        expect(broker.pending, null);
        unawaited(broker.chooseDevice(count: 1, stillCurrent: () => true));
        final next = broker.pending!.id;
        expect(next, isNot(expired));
        expect(
          () => broker.answerSecret(expired, 'wrong'),
          throwsA(failure('backend_stale_session')),
        );
        expect(broker.pending!.id, next);
        broker.close();
        clock.flushMicrotasks();
      });
    },
  );

  test('one outstanding prompt and app teardown preserve ownership', () async {
    final broker = BackendHarnessInteractions();
    final secret = broker.secret(
      BackendHarnessChallengeKind.passcode,
      stillCurrent: () => true,
    );
    await expectLater(
      broker.chooseDevice(count: 1, stillCurrent: () => true),
      throwsA(failure('backend_busy')),
    );
    broker.close();
    expect(await secret, null);
    expect(broker.pending, null);
  });

  test(
    'bad live progress cannot erase an accepted operation receipt',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      final runner = BackendHarnessEngine(
        enabled: true,
        source: List.filled(40, 'a').join(),
        platform: 'android',
        package: 'com.bluebubbles.messaging.cloudkitcanary',
        operations: {
          'sync.start': BackendHarnessOperation(
            handler: (_) => completion.future,
            validate: (_) => true,
            background: true,
            snapshot: () => throw StateError('private data'),
          ),
        },
      );
      final accepted = await runner.execute({
        'protocol': 1,
        'requestId': 'once',
        'action': 'sync.start',
        'arguments': <String, Object>{},
      });
      expect(accepted['state'], 'accepted');
      expect(accepted['jobId'], isA<String>());
      expect(jsonEncode(accepted), isNot(contains('private data')));
      completion.complete(const BackendHarnessPayload());
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'running operations expose typed challenges without claiming completion',
    () async {
      final broker = BackendHarnessInteractions();
      final completion = Completer<BackendHarnessPayload>();
      final runner = BackendHarnessEngine(
        enabled: true,
        source: List.filled(40, 'a').join(),
        platform: 'android',
        package: 'com.bluebubbles.messaging.cloudkitcanary',
        operations: {
          'sync.start': BackendHarnessOperation(
            handler: (_) => completion.future,
            validate: (_) => true,
            background: true,
            snapshot: () => BackendHarnessPayload(
              phase: BackendHarnessPhase.needs_passcode,
              challenge: broker.pending,
            ),
          ),
        },
      );
      final accepted = await runner.execute({
        'protocol': 1,
        'requestId': 'once',
        'action': 'sync.start',
        'arguments': <String, Object>{},
      });
      final secret = broker.secret(
        BackendHarnessChallengeKind.passcode,
        stillCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      final pending = await runner.execute({
        'protocol': 1,
        'requestId': 'poll',
        'action': 'job.status',
        'arguments': {'jobId': accepted['jobId']},
      });
      expect(pending['state'], 'running');
      expect(pending['code'], 'backend_auth_challenge');
      expect(
        ((pending['data']! as Map)['challenge'] as Map)['id'],
        broker.pending!.id,
      );
      broker.cancel(broker.pending!.id);
      expect(await secret, null);
      completion.complete(const BackendHarnessPayload());
      await Future<void>.delayed(Duration.zero);
    },
  );
}
