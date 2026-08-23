import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_owner.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds lazily and reuses one account controller', () async {
    var builds = 0;
    final owner = CloudSyncManualShadowOwner(
      buildController: () async {
        builds++;
        return controller(report: report('run-$builds'));
      },
    );

    expect(builds, 0);
    expect((await owner.runConfirmedAndPersist()).runId, 'run-1');
    expect((await owner.runConfirmedAndPersist()).runId, 'run-1');
    expect(builds, 1);
  });

  test('account quiescence waits for an active run', () async {
    final runStarted = Completer<void>();
    final finishRun = Completer<CloudSyncShadowReport>();
    final owner = CloudSyncManualShadowOwner(
      buildController: () async => CloudSyncManualShadowController(
        runConfirmed: () {
          runStarted.complete();
          return finishRun.future;
        },
        persistReport: (_) async => Object(),
      ),
    );

    final run = owner.runConfirmedAndPersist();
    await runStarted.future;
    var quiesced = false;
    final quiesce = owner.quiesceForAccountTransition().then((_) {
      quiesced = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(quiesced, isFalse);
    await expectLater(
      owner.runConfirmedAndPersist(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_shadow_owner_quiescing',
        ),
      ),
    );

    finishRun.complete(report('active'));
    await run;
    await quiesce;
    expect(quiesced, isTrue);
  });

  test(
    'a construction race is superseded and its controller is disposed',
    () async {
      final buildStarted = Completer<void>();
      final finishBuild = Completer<CloudSyncManualShadowController>();
      final owner = CloudSyncManualShadowOwner(
        buildController: () {
          buildStarted.complete();
          return finishBuild.future;
        },
      );

      final run = owner.runConfirmedAndPersist();
      await buildStarted.future;
      final quiesce = owner.quiesceForAccountTransition();
      final candidate = controller(report: report('superseded'));
      finishBuild.complete(candidate);

      await expectLater(
        run,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_shadow_owner_superseded',
          ),
        ),
      );
      await quiesce;
      expect(candidate.isDisposed, isTrue);
    },
  );

  test('resume creates a fresh controller for the next account', () async {
    var builds = 0;
    final owner = CloudSyncManualShadowOwner(
      buildController: () async {
        builds++;
        return controller(report: report('run-$builds'));
      },
    );

    expect((await owner.runConfirmedAndPersist()).runId, 'run-1');
    await owner.quiesceForAccountTransition();
    await owner.resumeAfterAccountTransition();
    expect((await owner.runConfirmedAndPersist()).runId, 'run-2');
    expect(builds, 2);
  });

  test('dispose is idempotent and permanently closes admission', () async {
    final owner = CloudSyncManualShadowOwner(
      buildController: () async => controller(report: report('unused')),
    );

    await owner.dispose();
    await owner.dispose();
    expect(owner.isDisposed, isTrue);
    await expectLater(
      owner.runConfirmedAndPersist(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_shadow_owner_disposed',
        ),
      ),
    );
  });
}

CloudSyncManualShadowController controller({
  required CloudSyncShadowReport report,
}) {
  return CloudSyncManualShadowController(
    runConfirmed: () async => report,
    persistReport: (_) async => Object(),
  );
}

CloudSyncShadowReport report(String runId) {
  return CloudSyncShadowReport(
    runId: runId,
    correlationTag: 'ephemeral',
    timestampUtc: DateTime.utc(2026, 8, 2),
    platform: 'android',
    architecture: 'arm64',
    buildCommit: 'test',
    legacySyncEnabled: false,
    pageLimit: 1,
    changeLimit: 50,
    tripwiresArmed: true,
    outboxCountBefore: 0,
    outboxCountAfter: 0,
    zones: const [
      CloudSyncShadowZoneReport(
        zoneLabel: 'messages',
        status: CloudSyncRunStatus.completed,
        fetched: 0,
        journaled: 0,
        rejected: 0,
        estimatedBytes: 0,
        elapsedMilliseconds: 1,
      ),
    ],
  );
}
