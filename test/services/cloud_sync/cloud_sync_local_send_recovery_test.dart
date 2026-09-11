import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_consumer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final receipt in <bool?>[null, false, true]) {
    test(
      'receipt-only recovery before empty outbox, receipt=$receipt',
      () async {
        final calls = <String>[];
        Future<bool> run() => recoverCloudSyncLocalSendUploadFence(
          recoverProtectedStore: () async => calls.add('recover'),
          reconcileUpload: () async {
            calls.add('verify');
            return receipt;
          },
        );
        if (receipt == true) {
          await expectLater(
            run(),
            throwsA(isA<CloudSyncLocalSendRecoveredEpoch>()),
          );
        } else {
          expect(await run(), receipt == null);
        }
        expect(calls, ['recover', 'verify']);
      },
    );
  }

  test(
    'verified byte receipt ends pass before any child or parent write',
    () async {
      var stages = 0;
      final result = await runCloudSyncLocalSendRecoveryPass(
        action: () async {
          if (await recoverCloudSyncLocalSendUploadFence(
            recoverProtectedStore: () async {},
            reconcileUpload: () async => true,
          )) {
            stages++;
          }
          return const CloudSyncLocalSendConsumerResult();
        },
        quiesce: () async {},
        canRefreshAfterRecovery: () async => true,
      );
      expect(stages, 0);
      expect(result.outboxBlocked, isTrue);
      expect(result.admitted, 0);
    },
  );

  test(
    'does not recapture or schedule before blocked cleanup settles',
    () async {
      final cleanupStarted = Completer<void>();
      final cleanup = Completer<void>();
      var recaptured = false;
      var finished = false;
      final future =
          runCloudSyncLocalSendRecoveryPass(
            action: () async => throw const CloudSyncLocalSendRecoveredEpoch(),
            quiesce: () async {
              cleanupStarted.complete();
              await cleanup.future;
            },
            canRefreshAfterRecovery: () async {
              recaptured = true;
              return true;
            },
          ).then((result) {
            finished = true;
            return result;
          });
      await cleanupStarted.future;
      expect(recaptured, isFalse);
      expect(finished, isFalse);
      cleanup.complete();
      expect((await future).outboxBlocked, isTrue);
      expect(recaptured, isTrue);
    },
  );

  test(
    'changed identity or unstable owner cannot authorize rollover',
    () async {
      const original = CloudSyncLocalSendRecoveredEpoch();
      await expectLater(
        runCloudSyncLocalSendRecoveryPass(
          action: () async => throw original,
          quiesce: () async {},
          canRefreshAfterRecovery: () async => false,
        ),
        throwsA(same(original)),
      );
    },
  );

  test('remaining fence and cleanup failures are not suppressed', () async {
    for (final failCleanup in [true, false]) {
      final failure = StateError('still fenced');
      var recaptured = false;
      await expectLater(
        runCloudSyncLocalSendRecoveryPass(
          action: () async => throw const CloudSyncLocalSendRecoveredEpoch(),
          quiesce: () async {
            if (failCleanup) throw failure;
          },
          canRefreshAfterRecovery: () async {
            recaptured = true;
            throw failure;
          },
        ),
        throwsA(same(failure)),
      );
      expect(recaptured, !failCleanup);
    }
  });

  test('ordinary failures are never converted to an automatic retry', () async {
    var checked = false;
    final original = StateError('cloud_sync_attachment_source_changed');
    await expectLater(
      runCloudSyncLocalSendRecoveryPass(
        action: () async => throw original,
        quiesce: () async {},
        canRefreshAfterRecovery: () async {
          checked = true;
          return true;
        },
      ),
      throwsA(same(original)),
    );
    expect(checked, isFalse);
  });

  test('successful results retain counts and still await cleanup', () async {
    const result = CloudSyncLocalSendConsumerResult(admitted: 1, deferred: 2);
    var cleaned = false;
    expect(
      await runCloudSyncLocalSendRecoveryPass(
        action: () async => result,
        quiesce: () async {
          cleaned = true;
        },
        canRefreshAfterRecovery: () async => throw StateError('unexpected'),
      ),
      same(result),
    );
    expect(cleaned, isTrue);
  });
}
