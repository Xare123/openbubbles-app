import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_pcs_operation.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'cloud_sync_progress_test.dart' as fixtures;

void main() {
  test(
    'late PCS keeps the interlock against teardown and other reads',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'pcs-owned-operation-',
      );
      final lock = CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: InMemoryCloudSyncStore(),
      );
      final started = Completer<void>();
      final native = Completer<void>();
      final work = lock.runExclusive(
        kind: CloudKitOperationKind.identityMaintenance,
        action: () {
          started.complete();
          return awaitCloudSyncPcsOperation(
            native.future,
            const Duration(milliseconds: 1),
          );
        },
      );
      final failure = expectLater(work, throwsA(isA<TimeoutException>()));
      try {
        await started.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (final kind in [
          CloudKitOperationKind.destructiveReset,
          CloudKitOperationKind.v2SemanticRead,
        ]) {
          await expectLater(
            lock.runExclusive(
              kind: kind,
              action: () async => fail('must stay fenced'),
            ),
            throwsA(
              isA<CloudKitOperationInterlockException>().having(
                (e) => e.safeCode,
                'code',
                'cloudkit_interlock_busy',
              ),
            ),
          );
        }
        native.complete();
        await failure;
        expect(
          await lock.runExclusive(
            kind: CloudKitOperationKind.destructiveReset,
            action: () async => 'released',
          ),
          'released',
        );
      } finally {
        if (!native.isCompleted) native.complete();
        await failure;
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'one tap joins duplicate starts and prepares PCS before read-only catch-up',
    () async {
      final p = CloudSyncProgress();
      final pcs = Completer<bool>();
      final calls = <String>[];
      final run = p.startPrepared(
        CloudSyncSpeed.regular,
        validate: () {
          calls.add('validate');
        },
        preparePcs: () {
          calls.add('pcs');
          return pcs.future;
        },
        readOnlyCatchUp: () async {
          calls.add('read');
          return fixtures.result();
        },
      );
      final duplicate = p.startPrepared(
        CloudSyncSpeed.turbo,
        validate: () => fail('duplicate validation'),
        preparePcs: () async => throw StateError('duplicate preparation'),
        readOnlyCatchUp: () async => throw StateError('duplicate read'),
      );
      expect(identical(run, duplicate), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['validate', 'pcs']);
      expect(p.phase, CloudSyncProgressPhase.pcs);
      pcs.complete(true);
      await run;
      expect(calls, ['validate', 'pcs', 'validate', 'read']);
      expect(p.phase, CloudSyncProgressPhase.remoteHead);
    },
  );

  for (final outcome in ['cancel', 'failure', 'account-changed', 'pause']) {
    test('PCS $outcome cannot start a read or bypass ownership', () async {
      final p = CloudSyncProgress();
      final pcs = Completer<bool>();
      var accountChanged = false;
      final run = p.startPrepared(
        CloudSyncSpeed.regular,
        validate: () {
          if (accountChanged) {
            throw StateError('cloud_sync_native_auth_account_changed');
          }
        },
        preparePcs: () => pcs.future,
        readOnlyCatchUp: () async => throw TestFailure('must not read'),
      );
      await Future<void>.delayed(Duration.zero);
      if (outcome == 'account-changed') accountChanged = true;
      if (outcome == 'pause') p.pause();
      expect(p.active, isTrue);
      if (outcome == 'failure') {
        pcs.completeError(StateError('cloud_sync_v2_pcs_join_outcome_unknown'));
      } else {
        pcs.complete(outcome != 'cancel');
      }
      await run;
      expect(
        p.phase,
        outcome == 'pause' || outcome == 'cancel'
            ? CloudSyncProgressPhase.paused
            : CloudSyncProgressPhase.error,
      );
      expect(
        p.safeFailure,
        outcome == 'account-changed'
            ? 'cloud_sync_native_auth_account_changed'
            : outcome == 'failure'
            ? 'cloud_sync_v2_pcs_join_outcome_unknown'
            : null,
      );
      expect(p.active, isFalse);
    });
  }

  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    test(
      '$state pauses PCS continuation and resume does not auto-start',
      () async {
        final p = CloudSyncProgress();
        final pcs = Completer<bool>();
        final run = p.startPrepared(
          CloudSyncSpeed.turbo,
          validate: () {},
          preparePcs: () => pcs.future,
          readOnlyCatchUp: () async => throw TestFailure('background read'),
        );
        await Future<void>.delayed(Duration.zero);
        p.onAppLifecycleState(AppLifecycleState.inactive);
        expect(p.pauseRequested, isFalse);
        p.onAppLifecycleState(state);
        expect(p.active, isTrue);
        expect(p.phase, CloudSyncProgressPhase.pausing);
        p.onAppLifecycleState(AppLifecycleState.resumed);
        expect(p.pauseRequested, isTrue);
        pcs.complete(true);
        await run;
        expect(p.phase, CloudSyncProgressPhase.paused);
      },
    );
  }

  test(
    'PCS timeout retains ownership until late native success, never continues',
    () {
      fakeAsync((clock) {
        final native = Completer<bool>();
        Object? error;
        var released = false;
        awaitCloudSyncPcsOperation(native.future, const Duration(seconds: 30))
            .then<void>(
              (_) => fail('late success must not continue'),
              onError: (Object e) {
                error = e;
              },
            )
            .whenComplete(() {
              released = true;
            });
        clock.elapse(const Duration(seconds: 31));
        expect(released, isFalse);
        native.complete(true);
        clock.flushMicrotasks();
        expect(error, isA<TimeoutException>());
        expect(released, isTrue);
      });
    },
  );

  test('PCS timeout also waits for late failure without leaking it', () {
    fakeAsync((clock) {
      final native = Completer<void>();
      Object? error;
      awaitCloudSyncPcsOperation(
        native.future,
        const Duration(seconds: 30),
      ).then<void>(
        (_) => fail('unexpected success'),
        onError: (Object e) {
          error = e;
        },
      );
      clock.elapse(const Duration(seconds: 31));
      expect(error, isNull);
      native.completeError(StateError('private native error'));
      clock.flushMicrotasks();
      expect(error, isA<TimeoutException>());
      expect(error.toString(), isNot(contains('private native error')));
    });
  });

  test('timely PCS success and failure preserve their outcomes', () async {
    expect(
      await awaitCloudSyncPcsOperation(
        Future.value(7),
        const Duration(seconds: 30),
      ),
      7,
    );
    await expectLater(
      awaitCloudSyncPcsOperation(
        Future<void>.error(StateError('expected')),
        const Duration(seconds: 30),
      ),
      throwsStateError,
    );
  });

  test(
    'production composition explicitly prepares PCS, then uses no-wake read path',
    () {
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<void> startCloudSyncV2Progress(');
      final stop = source.indexOf('/// Content-free lifecycle state', start);
      final wrapper = source.substring(start, stop);
      expect(wrapper, contains('startPrepared('));
      expect(wrapper, contains('prepareCloudSyncV2PcsConfirmed('));
      expect(wrapper, contains('validateContinuation: validate'));
      expect(wrapper, contains('_validateCloudSyncV2QueuedRead('));
      expect(wrapper, contains('AppLifecycleState.resumed'));
      expect(wrapper, contains('CloudSyncV2PcsPreparationOutcome.cancelled'));
      expect(
        wrapper,
        contains('runCloudSyncV2AutomaticSemanticCatchUpReadOnly('),
      );
      expect(
        wrapper,
        isNot(contains('runCloudSyncV2AutomaticSemanticCatchUpConfirmed(')),
      );
      expect(wrapper, isNot(contains('_queueCloudSyncV2LocalSends')));
      final readStart = source.indexOf(
        'runCloudSyncV2AutomaticSemanticCatchUpReadOnly({',
      );
      final readStop = source.indexOf('/// One WorkManager-owned', readStart);
      final read = source.substring(readStart, readStop);
      expect(read, contains('progress: progress'));
      expect(read, isNot(contains('_queueCloudSyncV2LocalSends(')));
      final pcsStart = source.indexOf('prepareCloudSyncV2PcsConfirmed({');
      final pcsStop = source.indexOf(
        'Future<api.ViableBottle?> _promptCloudSyncV2BottleChoice(',
        pcsStart,
      );
      final pcs = source.substring(pcsStart, pcsStop);
      expect(pcs, contains('_runCloudKitIdentityMaintenance('));
      expect(pcs, contains('awaitCloudSyncPcsOperation('));
      expect(pcs, isNot(contains('.timeout(')));
      expect(pcs, isNot(contains('resetClique(')));
      expect(pcs, isNot(contains('_queueCloudSyncV2LocalSends(')));
      expect(
        source.substring(source.indexOf('void onClose()')),
        contains('cloudSyncV2Progress.pause()'),
      );
      final lifecycle = File(
        'lib/services/backend/lifecycle/lifecycle_service.dart',
      ).readAsStringSync();
      expect(
        lifecycle,
        contains('cloudSyncV2Progress.onAppLifecycleState(state)'),
      );
    },
  );
}
