import 'dart:async';

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

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
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

final class _RejectingRenewalStore extends InMemoryCloudSyncStore {
  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) async => false;
}
