import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_source_operations.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'quiesce waits for every admitted action through native cleanup',
    () async {
      final operations = CloudSyncLocalSourceOperations();
      final work = Completer<void>();
      final cleanup = Completer<void>();
      final cleanupEntered = Completer<void>();
      final secondWork = Completer<void>();
      final entered = Completer<void>();
      final first = operations.run<int>(
        validate: () {},
        action: () async {
          entered.complete();
          try {
            await work.future;
            return 7;
          } finally {
            await operations.release(() async {
              cleanupEntered.complete();
              await cleanup.future;
            });
          }
        },
      );
      final second = operations.run<void>(
        validate: () {},
        action: () => secondWork.future,
      );
      await entered.future;
      var drained = false;
      final drain = operations.quiesce().then((_) {
        drained = true;
      });
      expect(operations.reopen(), isFalse);
      secondWork.complete();
      await second;
      expect(drained, isFalse);
      work.complete();
      await cleanupEntered.future;
      expect(drained, isFalse);
      expect(operations.reopen(), isFalse);
      cleanup.complete();
      expect(await first, 7);
      await drain;
      expect(drained, isTrue);
      expect(operations.reopen(), isTrue);
    },
  );

  test('closed admission rejects work before validation or action', () async {
    final operations = CloudSyncLocalSourceOperations();
    final entered = Completer<void>();
    final finish = Completer<void>();
    final pending = operations.run<void>(
      validate: () {},
      action: () async {
        entered.complete();
        await finish.future;
      },
    );
    await entered.future;
    final drain = operations.quiesce();
    var validations = 0;
    var actions = 0;
    await expectLater(
      operations.run<void>(
        validate: () => validations++,
        action: () async {
          actions++;
        },
      ),
      throwsA(_quiescing),
    );
    expect(validations, 0);
    expect(actions, 0);
    expect(operations.reopen(), isFalse);
    finish.complete();
    await pending;
    await drain;
    await expectLater(
      operations.run<void>(
        validate: () {},
        action: () async {
          actions++;
        },
      ),
      throwsA(_quiescing),
    );
    expect(actions, 0);
  });

  test('invalid identity never reaches native action entry', () async {
    final operations = CloudSyncLocalSourceOperations();
    final failure = StateError('synthetic_identity_changed');
    var actions = 0;
    await expectLater(
      Future<void>.sync(
        () => operations.run<void>(
          validate: () => throw failure,
          action: () async {
            actions++;
          },
        ),
      ),
      throwsA(same(failure)),
    );
    expect(actions, 0);
    await operations.quiesce();
    expect(operations.reopen(), isTrue);
  });

  test(
    'changed identity at action entry never invokes the native callback',
    () async {
      final operations = CloudSyncLocalSourceOperations();
      final originalIdentity = Object();
      var currentIdentity = originalIdentity;
      final failure = StateError('synthetic_identity_changed');
      var validations = 0;
      var actions = 0;
      final pending = operations.run<void>(
        validate: () {
          validations++;
          if (!identical(currentIdentity, originalIdentity)) throw failure;
          // Model a transition after the initial check but before native entry.
          if (validations == 1) currentIdentity = Object();
        },
        action: () async {
          actions++;
        },
      );
      await expectLater(pending, throwsA(same(failure)));
      expect(validations, 2);
      expect(actions, 0);
      await operations.quiesce();
      expect(operations.reopen(), isTrue);
    },
  );

  test(
    'close during initial validation prevents native action entry',
    () async {
      final operations = CloudSyncLocalSourceOperations();
      Future<void>? drain;
      var actions = 0;
      final pending = operations.run<void>(
        validate: () {
          drain ??= operations.quiesce();
        },
        action: () async {
          actions++;
        },
      );
      await expectLater(pending, throwsA(_quiescing));
      await drain;
      await operations.quiesce();
      expect(actions, 0);
      expect(operations.reopen(), isTrue);
    },
  );

  test(
    'action entry is registered before a synchronous drain callback',
    () async {
      final operations = CloudSyncLocalSourceOperations();
      final entered = Completer<void>();
      final finish = Completer<void>();
      var drained = false;
      late Future<void> drain;
      final pending = operations.run<void>(
        validate: () {},
        action: () async {
          drain = operations.quiesce().then((_) {
            drained = true;
          });
          entered.complete();
          await finish.future;
        },
      );
      await entered.future;
      expect(drained, isFalse);
      expect(operations.reopen(), isFalse);
      finish.complete();
      await pending;
      await drain;
      expect(drained, isTrue);
      expect(operations.reopen(), isTrue);
    },
  );

  for (final synchronous in [true, false]) {
    test(
      'normal action failure still drains without poison (sync=$synchronous)',
      () async {
        final operations = CloudSyncLocalSourceOperations();
        final failure = StateError('synthetic_action_failure');
        final finish = Completer<void>();
        final failed = operations.run<void>(
          validate: () {},
          action: synchronous
              ? () => throw failure
              : () async {
                  await finish.future;
                  throw failure;
                },
        );
        final observed = expectLater(failed, throwsA(same(failure)));
        final drain = operations.quiesce();
        if (!synchronous) finish.complete();
        await observed;
        await drain;
        expect(operations.reopen(), isTrue);
        expect(
          await operations.run<int>(validate: () {}, action: () async => 9),
          9,
        );
        await operations.quiesce();
      },
    );
  }

  test(
    'failed native release remains sticky after its Future settles',
    () async {
      final operations = CloudSyncLocalSourceOperations();
      final finish = Completer<void>();
      final failure = StateError('synthetic_release_failure');
      var releases = 0;
      final pending = operations.run<void>(
        validate: () {},
        action: () async {
          try {
            await finish.future;
          } finally {
            await operations.release(() async {
              releases++;
              throw failure;
            });
          }
        },
      );
      final observed = expectLater(pending, throwsA(same(failure)));
      final drain = expectLater(operations.quiesce(), throwsA(_releaseFailed));
      finish.complete();
      await observed;
      await drain;
      expect(releases, 1);
      expect(operations.reopen(), isFalse);
      await expectLater(operations.quiesce(), throwsA(_releaseFailed));
      var actions = 0;
      await expectLater(
        operations.run<void>(
          validate: () {},
          action: () async {
            actions++;
          },
        ),
        throwsA(_quiescing),
      );
      // Later successful cleanup cannot erase the previous release failure.
      await operations.release(() async {
        releases++;
      });
      expect(releases, 2);
      expect(actions, 0);
      expect(operations.reopen(), isFalse);
      await expectLater(operations.quiesce(), throwsA(_releaseFailed));
    },
  );

  test(
    'timed-out teardown does not release or reopen the active owner',
    () async {
      final operations = CloudSyncLocalSourceOperations();
      final finish = Completer<void>();
      var finished = false;
      final pending = operations.run<void>(
        validate: () {},
        action: () async {
          await finish.future;
          finished = true;
        },
      );
      final drain = expectLater(operations.quiesce(), throwsA(_releaseFailed));
      operations.markQuiescenceTimeout();
      expect(finished, isFalse);
      expect(operations.restartRequired, isTrue);
      expect(operations.reopen(), isFalse);
      await expectLater(
        operations.run<void>(validate: () {}, action: () async {}),
        throwsA(_quiescing),
      );
      finish.complete();
      await pending;
      await drain;
      expect(finished, isTrue);
      expect(operations.restartRequired, isTrue);
      expect(operations.reopen(), isFalse);
    },
  );

  test(
    'healthy reopen revalidates the new identity and rejects the old one',
    () async {
      final operations = CloudSyncLocalSourceOperations();
      final oldIdentity = Object();
      var currentIdentity = oldIdentity;
      var validations = 0;
      var actions = 0;
      Future<void> runFor(Object expected) => operations.run<void>(
        validate: () {
          validations++;
          if (!identical(currentIdentity, expected)) {
            throw StateError('synthetic_identity_changed');
          }
        },
        action: () async {
          actions++;
        },
      );
      await runFor(oldIdentity);
      expect(validations, 2);
      expect(actions, 1);
      await operations.quiesce();
      final newIdentity = Object();
      currentIdentity = newIdentity;
      expect(operations.reopen(), isTrue);
      await expectLater(
        Future<void>.sync(() => runFor(oldIdentity)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'synthetic_identity_changed',
          ),
        ),
      );
      expect(actions, 1);
      await runFor(newIdentity);
      expect(validations, 5);
      expect(actions, 2);
      await operations.quiesce();
      expect(operations.reopen(), isTrue);
    },
  );
}

Matcher get _quiescing => isA<StateError>().having(
  (error) => error.message,
  'message',
  'cloud_sync_local_source_quiescing',
);

Matcher get _releaseFailed => isA<CloudSyncFailure>()
    .having(
      (error) => error.category,
      'category',
      CloudFailureCategory.localStorage,
    )
    .having(
      (error) => error.safeCode,
      'safeCode',
      'cloud_sync_local_source_quiescence_failed',
    );
