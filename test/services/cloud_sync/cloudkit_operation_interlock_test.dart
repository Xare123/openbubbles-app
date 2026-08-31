import 'dart:async';
import 'dart:isolate';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

void main() {
  late Directory temporaryDirectory;
  late CloudKitOperationInterlock interlock;
  late InMemoryCloudSyncStore fenceStore;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'cloudkit-interlock-',
    );
    fenceStore = InMemoryCloudSyncStore();
    interlock = CloudKitOperationInterlock(
      privateStorageDirectory: temporaryDirectory.path,
      fenceStore: fenceStore,
    );
  });

  tearDown(() async {
    await CloudKitOperationInterlock.debugResetPoisonedLocksForTesting();
    temporaryDirectory.deleteSync(recursive: true);
  });

  test(
    'poisoned operation retains cross-isolate exclusion until process restart',
    () async {
      await interlock.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: () async {
          interlock.poisonUntilProcessRestart();
        },
      );

      final secondInterlock = CloudKitOperationInterlock(
        privateStorageDirectory: temporaryDirectory.path,
        fenceStore: fenceStore,
      );
      await expectLater(
        secondInterlock.runExclusive(
          kind: CloudKitOperationKind.v2SemanticRead,
          action: () async {},
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_busy',
          ),
        ),
      );

      final lockDirectory = temporaryDirectory.path;
      final isolateOutcome = await Isolate.run<String>(() async {
        final isolateInterlock = CloudKitOperationInterlock(
          privateStorageDirectory: lockDirectory,
          fenceStore: InMemoryCloudSyncStore(),
        );
        try {
          await isolateInterlock.runExclusive(
            kind: CloudKitOperationKind.v2SemanticRead,
            action: () async {},
          );
          return 'entered';
        } on CloudKitOperationInterlockException catch (error) {
          return error.safeCode;
        }
      });
      expect(isolateOutcome, 'cloudkit_interlock_busy');
    },
  );

  test('active operation blocks another isolate until release', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = interlock.runExclusive(
      kind: CloudKitOperationKind.v2SemanticRead,
      action: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;

    expect(
      await _attemptIsolateOperation(temporaryDirectory.path),
      'cloudkit_interlock_busy',
    );
    release.complete();
    await first;
    expect(await _attemptIsolateOperation(temporaryDirectory.path), 'entered');
  });

  test('same-kind nested work reuses the active lease', () async {
    final result = await interlock.runExclusive(
      kind: CloudKitOperationKind.legacyReadWrite,
      action: () => interlock.runExclusive(
        kind: CloudKitOperationKind.legacyReadWrite,
        action: () async => 'nested-complete',
      ),
    );

    expect(result, 'nested-complete');
  });

  test('different-kind nested work fails closed', () async {
    await expectLater(
      interlock.runExclusive(
        kind: CloudKitOperationKind.v2ShadowRead,
        action: () => interlock.runExclusive(
          kind: CloudKitOperationKind.legacyReadWrite,
          action: () async {},
        ),
      ),
      throwsA(
        isA<CloudKitOperationInterlockException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_interlock_mode_violation',
        ),
      ),
    );
  });

  test(
    'destructive reset cannot nest inside another CloudKit operation',
    () async {
      await expectLater(
        interlock.runExclusive(
          kind: CloudKitOperationKind.legacyReadWrite,
          action: () => interlock.runExclusive(
            kind: CloudKitOperationKind.destructiveReset,
            action: () async {},
          ),
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_mode_violation',
          ),
        ),
      );
    },
  );

  test('a concurrent operation on the profile is rejected', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = interlock.runExclusive(
      kind: CloudKitOperationKind.v2ShadowRead,
      action: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;

    final secondInterlock = CloudKitOperationInterlock(
      privateStorageDirectory: temporaryDirectory.path,
      fenceStore: fenceStore,
    );
    await expectLater(
      secondInterlock.runExclusive(
        kind: CloudKitOperationKind.legacyReadWrite,
        action: () async {},
      ),
      throwsA(
        isA<CloudKitOperationInterlockException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_interlock_busy',
        ),
      ),
    );

    release.complete();
    await first;
  });

  test(
    'writer transition cannot overlap an in-flight legacy mutation',
    () async {
      final legacyEntered = Completer<void>();
      final releaseLegacy = Completer<void>();
      var transitionRuns = 0;
      final legacyMutation = interlock.runExclusive(
        kind: CloudKitOperationKind.legacyReadWrite,
        action: () async {
          legacyEntered.complete();
          await releaseLegacy.future;
        },
      );
      await legacyEntered.future;

      final transitionInterlock = CloudKitOperationInterlock(
        privateStorageDirectory: temporaryDirectory.path,
        fenceStore: fenceStore,
      );
      await expectLater(
        transitionInterlock.runExclusive(
          kind: CloudKitOperationKind.writerTransition,
          action: () async {
            transitionRuns += 1;
          },
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_busy',
          ),
        ),
      );
      expect(transitionRuns, 0);

      releaseLegacy.complete();
      await legacyMutation;

      await transitionInterlock.runExclusive(
        kind: CloudKitOperationKind.writerTransition,
        action: () async {
          transitionRuns += 1;
        },
      );
      expect(transitionRuns, 1);
    },
  );

  test('an action failure releases the lease', () async {
    await expectLater(
      interlock.runExclusive<void>(
        kind: CloudKitOperationKind.legacyReadWrite,
        action: () async => throw StateError('expected-test-failure'),
      ),
      throwsStateError,
    );

    expect(
      await interlock.runExclusive(
        kind: CloudKitOperationKind.v2ShadowRead,
        action: () async => 7,
      ),
      7,
    );
  });

  test(
    'a rejected fence acquisition releases the isolate reservation',
    () async {
      final rejectingInterlock = CloudKitOperationInterlock(
        privateStorageDirectory: temporaryDirectory.path,
        fenceStore: _RejectingAcquisitionStore(),
      );

      await expectLater(
        rejectingInterlock.runExclusive(
          kind: CloudKitOperationKind.v2SemanticRead,
          action: () async {},
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloudkit_interlock_busy',
          ),
        ),
      );
      expect(
        await _attemptIsolateOperation(temporaryDirectory.path),
        'entered',
      );
    },
  );

  test('a lost database fence fails the operation closed', () async {
    final rejectingStore = _RejectingRenewalStore();
    final fencedInterlock = CloudKitOperationInterlock(
      privateStorageDirectory: temporaryDirectory.path,
      fenceStore: rejectingStore,
      leaseDuration: const Duration(milliseconds: 100),
      heartbeatInterval: const Duration(milliseconds: 5),
    );

    await expectLater(
      fencedInterlock.runExclusive(
        kind: CloudKitOperationKind.v2ShadowRead,
        action: () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          CloudKitOperationInterlock.throwIfActiveFenceLost();
        },
      ),
      throwsA(
        isA<CloudKitOperationInterlockException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_interlock_fence_lost',
        ),
      ),
    );
  });

  test('same-kind nested work cannot enter after fence loss', () async {
    final rejectingStore = _RejectingRenewalStore();
    final fencedInterlock = CloudKitOperationInterlock(
      privateStorageDirectory: temporaryDirectory.path,
      fenceStore: rejectingStore,
      leaseDuration: const Duration(milliseconds: 100),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    var nestedEntered = false;

    await expectLater(
      fencedInterlock.runExclusive(
        kind: CloudKitOperationKind.v2ShadowRead,
        action: () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await fencedInterlock.runExclusive(
            kind: CloudKitOperationKind.v2ShadowRead,
            action: () async {
              nestedEntered = true;
            },
          );
        },
      ),
      throwsA(
        isA<CloudKitOperationInterlockException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_interlock_fence_lost',
        ),
      ),
    );
    expect(nestedEntered, isFalse);
  });

  test('an in-flight rejected renewal fails session exit closed', () async {
    final controlledStore = _ControlledRenewalStore();
    final fencedInterlock = CloudKitOperationInterlock(
      privateStorageDirectory: temporaryDirectory.path,
      fenceStore: controlledStore,
      leaseDuration: const Duration(milliseconds: 100),
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    final allowActionToFinish = Completer<void>();

    final operation = fencedInterlock.runExclusive(
      kind: CloudKitOperationKind.v2ShadowRead,
      action: () async {
        await controlledStore.renewalStarted.future;
        await allowActionToFinish.future;
        return 'must-not-return';
      },
    );
    await controlledStore.renewalStarted.future;
    allowActionToFinish.complete();
    await Future<void>.delayed(Duration.zero);
    controlledStore.renewalResult.complete(false);

    await expectLater(
      operation,
      throwsA(
        isA<CloudKitOperationInterlockException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_interlock_fence_lost',
        ),
      ),
    );
  });

  test('constructor rejects a missing storage directory', () {
    final missing =
        '${temporaryDirectory.path}${Platform.pathSeparator}missing';

    expect(
      () => CloudKitOperationInterlock(
        privateStorageDirectory: missing,
        fenceStore: fenceStore,
      ),
      throwsArgumentError,
    );
  });
}

Future<String> _attemptIsolateOperation(String lockDirectory) =>
    Isolate.run<String>(() async {
      final isolateInterlock = CloudKitOperationInterlock(
        privateStorageDirectory: lockDirectory,
        fenceStore: InMemoryCloudSyncStore(),
      );
      try {
        await isolateInterlock.runExclusive(
          kind: CloudKitOperationKind.v2SemanticRead,
          action: () async {},
        );
        return 'entered';
      } on CloudKitOperationInterlockException catch (error) {
        return error.safeCode;
      }
    });

final class _RejectingRenewalStore extends InMemoryCloudSyncStore {
  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) async => false;
}

final class _ControlledRenewalStore extends InMemoryCloudSyncStore {
  final renewalStarted = Completer<void>();
  final renewalResult = Completer<bool>();

  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) {
    if (!renewalStarted.isCompleted) renewalStarted.complete();
    return renewalResult.future;
  }
}

final class _RejectingAcquisitionStore extends InMemoryCloudSyncStore {
  @override
  Future<CloudCoordinatorLeaseFence?> tryAcquireCoordinatorLease(
    CloudSyncScope scope, {
    required String ownerId,
    required DateTime now,
    required Duration leaseDuration,
  }) async => null;
}
