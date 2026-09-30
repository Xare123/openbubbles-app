import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_sync_gate.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only CloudKit lanes wait for a semantic pull', () {
    expect(
      cloudAttachmentLaneWaitsForSemanticPull(
        CloudAttachmentDownloadLane.cloudSyncV2,
      ),
      isTrue,
    );
    expect(
      cloudAttachmentLaneWaitsForSemanticPull(
        CloudAttachmentDownloadLane.legacyCloudKit,
      ),
      isTrue,
    );
    expect(
      cloudAttachmentLaneWaitsForSemanticPull(CloudAttachmentDownloadLane.ids),
      isFalse,
    );
    expect(
      cloudAttachmentLaneWaitsForSemanticPull(
        CloudAttachmentDownloadLane.unavailable,
      ),
      isFalse,
    );
  });

  test('queued media runs between semantic batches without overlap', () async {
    final gate = CloudAttachmentSyncGate();
    final batchAStarted = Completer<void>();
    final releaseBatchA = Completer<void>();
    final events = <String>[];
    var activeOperations = 0;
    var maximumActiveOperations = 0;

    Future<void> operation(String name, [Future<void>? release]) async {
      activeOperations++;
      maximumActiveOperations = activeOperations > maximumActiveOperations
          ? activeOperations
          : maximumActiveOperations;
      events.add('$name:start');
      if (name == 'batch-a') batchAStarted.complete();
      if (release != null) await release;
      events.add('$name:end');
      activeOperations--;
    }

    Future<void> runCatchUp() async {
      await gate.run<void>(
        validate: () {},
        action: () => operation('batch-a', releaseBatchA.future),
      );
      await gate.run<void>(validate: () {}, action: () => operation('batch-b'));
    }

    final catchUp = runCatchUp();
    await batchAStarted.future;
    final media = gate.run<void>(
      validate: () {},
      action: () => operation('media'),
    );

    releaseBatchA.complete();
    await Future.wait<void>(<Future<void>>[catchUp, media]);

    expect(events, <String>[
      'batch-a:start',
      'batch-a:end',
      'media:start',
      'media:end',
      'batch-b:start',
      'batch-b:end',
    ]);
    expect(maximumActiveOperations, 1);
  });

  test(
    'failed action releases the queue without poisoning the next action',
    () async {
      final gate = CloudAttachmentSyncGate();
      final failedActionStarted = Completer<void>();
      final releaseFailedAction = Completer<void>();
      var nextActionRan = false;

      final failed = gate.run<void>(
        validate: () {},
        action: () async {
          failedActionStarted.complete();
          await releaseFailedAction.future;
          throw StateError('batch failed');
        },
      );
      final failedExpectation = expectLater(failed, throwsA(isA<StateError>()));
      await failedActionStarted.future;

      final next = gate.run<String>(
        validate: () {},
        action: () async {
          nextActionRan = true;
          return 'next-result';
        },
      );

      releaseFailedAction.complete();

      await failedExpectation;
      await expectLater(next, completion('next-result'));
      expect(nextActionRan, isTrue);
    },
  );

  test(
    'queued validators reject account changes and cancellation before body',
    () async {
      final gate = CloudAttachmentSyncGate();
      final blockerStarted = Completer<void>();
      final releaseBlocker = Completer<void>();
      var account = 'account-a';
      var cancelled = false;
      var accountBodyRan = false;
      var cancelledBodyRan = false;

      final blocker = gate.run<void>(
        validate: () {},
        action: () async {
          blockerStarted.complete();
          await releaseBlocker.future;
        },
      );
      await blockerStarted.future;

      final accountRun = gate.run<void>(
        validate: () {
          if (account != 'account-a') throw StateError('account changed');
        },
        action: () async {
          accountBodyRan = true;
        },
      );
      final accountExpectation = expectLater(
        accountRun,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'account changed',
          ),
        ),
      );

      final cancelledRun = gate.run<void>(
        validate: () {
          if (cancelled) throw StateError('cancelled');
        },
        action: () async {
          cancelledBodyRan = true;
        },
      );
      final cancelledExpectation = expectLater(
        cancelledRun,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cancelled',
          ),
        ),
      );

      account = 'account-b';
      cancelled = true;
      releaseBlocker.complete();

      await blocker;
      await accountExpectation;
      await cancelledExpectation;
      expect(accountBodyRan, isFalse);
      expect(cancelledBodyRan, isFalse);
    },
  );

  test('drain waits for active and already queued work', () async {
    final gate = CloudAttachmentSyncGate();
    final activeStarted = Completer<void>();
    final releaseActive = Completer<void>();
    final queuedStarted = Completer<void>();
    final releaseQueued = Completer<void>();
    var drainCompleted = false;

    final active = gate.run<void>(
      validate: () {},
      action: () async {
        activeStarted.complete();
        await releaseActive.future;
      },
    );
    await activeStarted.future;

    final queued = gate.run<void>(
      validate: () {},
      action: () async {
        queuedStarted.complete();
        await releaseQueued.future;
      },
    );
    final drain = gate.drain().then((_) {
      drainCompleted = true;
    });

    await _pumpEventTurns();
    expect(drainCompleted, isFalse);

    releaseActive.complete();
    await queuedStarted.future;
    expect(drainCompleted, isFalse);

    releaseQueued.complete();
    await Future.wait<void>(<Future<void>>[active, queued, drain]);
    expect(drainCompleted, isTrue);
  });

  test('observer timeout does not release the active operation', () async {
    final gate = CloudAttachmentSyncGate();
    final activeStarted = Completer<void>();
    final releaseActive = Completer<void>();
    var activeCompleted = false;
    var nextActionRan = false;

    final active = gate.run<void>(
      validate: () {},
      action: () async {
        activeStarted.complete();
        await releaseActive.future;
        activeCompleted = true;
      },
    );
    await activeStarted.future;

    final observer = active.timeout(Duration.zero);
    final next = gate.run<void>(
      validate: () {},
      action: () async {
        nextActionRan = true;
      },
    );

    await expectLater(observer, throwsA(isA<TimeoutException>()));
    await _pumpEventTurns();
    expect(activeCompleted, isFalse);
    expect(nextActionRan, isFalse);

    releaseActive.complete();
    await Future.wait<void>(<Future<void>>[active, next]);
    expect(activeCompleted, isTrue);
    expect(nextActionRan, isTrue);
  });

  test(
    'queued mutation waits for the background owner then validates fresh state once',
    () async {
      final gate = CloudAttachmentSyncGate();
      final ownerStarted = Completer<void>();
      final releaseOwner = Completer<void>();
      var validations = 0;
      var bodies = 0;
      var observedPhase = '';

      final owner = gate.run<String>(
        validate: () {},
        action: () async {
          ownerStarted.complete();
          await releaseOwner.future;
          return 'owner-done';
        },
      );
      await ownerStarted.future;

      var phase = 'stale';
      final queued = gate.run<String>(
        waitTimeout: const Duration(seconds: 5),
        validate: () {
          validations++;
          observedPhase = phase;
          if (phase != 'fresh') throw StateError('stale validation');
        },
        action: () async {
          bodies++;
          return 'queued-done';
        },
      );

      await _pumpEventTurns();
      expect(validations, 0);
      expect(bodies, 0);

      phase = 'fresh';
      releaseOwner.complete();
      await expectLater(owner, completion('owner-done'));
      await expectLater(queued, completion('queued-done'));
      expect(validations, 1);
      expect(observedPhase, 'fresh');
      expect(bodies, 1);
    },
  );

  test(
    'admission timeout reports busy without running the body later or unlocking the owner',
    () async {
      final gate = CloudAttachmentSyncGate();
      final ownerStarted = Completer<void>();
      final releaseOwner = Completer<void>();
      final events = <String>[];
      var timedOutBodyRan = false;
      var timedOutValidations = 0;

      final owner = gate.run<String>(
        validate: () {},
        action: () async {
          ownerStarted.complete();
          await releaseOwner.future;
          events.add('owner:end');
          return 'owner-result';
        },
      );
      await ownerStarted.future;

      final timedOut = gate.run<String>(
        waitTimeout: const Duration(milliseconds: 20),
        validate: () {
          timedOutValidations++;
        },
        action: () async {
          timedOutBodyRan = true;
          return 'late-body';
        },
      );
      final next = gate.run<String>(
        validate: () {},
        action: () async {
          events.add('next:end');
          return 'next-result';
        },
      );

      await expectLater(
        timedOut,
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_busy',
          ),
        ),
      );

      releaseOwner.complete();
      await expectLater(owner, completion('owner-result'));
      await expectLater(next, completion('next-result'));
      await _pumpEventTurns(10);
      expect(timedOutBodyRan, isFalse);
      expect(timedOutValidations, 0);
      expect(events, <String>['owner:end', 'next:end']);
    },
  );

  test('entered errors propagate unchanged without replay or remap', () async {
    final gate = CloudAttachmentSyncGate();
    const enteredBusy = CloudKitOperationInterlockException(
      'cloudkit_interlock_busy',
    );
    var actionCalls = 0;
    var validateCalls = 0;

    final enteredTimeout = gate.run<void>(
      validate: () {},
      action: () async {
        actionCalls++;
        throw TimeoutException('entered facing timeout');
      },
    );
    await expectLater(enteredTimeout, throwsA(isA<TimeoutException>()));

    final enteredBusyAction = gate.run<void>(
      validate: () {},
      action: () async {
        actionCalls++;
        throw enteredBusy;
      },
    );
    await expectLater(enteredBusyAction, throwsA(same(enteredBusy)));

    final enteredBusyValidate = gate.run<void>(
      validate: () {
        validateCalls++;
        throw enteredBusy;
      },
      action: () async {},
    );
    await expectLater(enteredBusyValidate, throwsA(same(enteredBusy)));
    expect(actionCalls, 2);
    expect(validateCalls, 1);

    final next = gate.run<String>(
      validate: () {},
      action: () async => 'still-open',
    );
    await expectLater(next, completion('still-open'));
  });

  test('entered action outlasts its wait timeout and still returns normally',
      () async {
    final gate = CloudAttachmentSyncGate();
    final bodyStarted = Completer<void>();
    final releaseBody = Completer<void>();
    var validations = 0;
    var completed = false;

    final entered = gate.run<String>(
      waitTimeout: const Duration(milliseconds: 20),
      validate: () {
        validations++;
      },
      action: () async {
        bodyStarted.complete();
        await releaseBody.future;
        completed = true;
        return 'entered-result';
      },
    );
    final enteredExpectation = expectLater(entered, completion('entered-result'));

    await bodyStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(completed, isFalse);
    releaseBody.complete();
    await enteredExpectation;
    expect(validations, 1);
  });

  test('non-positive wait timeout is rejected before queueing', () async {
    final gate = CloudAttachmentSyncGate();
    var bodyRan = false;
    await expectLater(
      gate.run<void>(
        waitTimeout: Duration.zero,
        validate: () {},
        action: () async {
          bodyRan = true;
        },
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(bodyRan, isFalse);
  });
}

Future<void> _pumpEventTurns([int count = 2]) async {
  for (var turn = 0; turn < count; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}
