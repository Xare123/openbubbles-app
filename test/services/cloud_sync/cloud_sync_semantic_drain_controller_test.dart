import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns after one persisted terminal-empty read', () async {
    final events = <String>[];
    final controller = _controller(
      runConfirmed: () async {
        events.add('run');
        return report(terminalEmpty: true);
      },
      persistReport: (_) async {
        events.add('persist');
        return 'report-1';
      },
    );

    final result = await controller.drainConfirmedAndPersist();

    expect(events, ['run', 'persist']);
    expect(result.passes, 1);
    expect(result.persistedReportReference, 'report-1');
    expect(result.remoteDrained, isTrue);
    expect(result.projectionComplete, isTrue);
    expect(result.reachedPassLimit, isFalse);
    expect(controller.isActive, isFalse);
  });

  test('continues in one process until a later terminal-empty read', () async {
    var runs = 0;
    final controller = _controller(
      runConfirmed: () async {
        runs++;
        return report(terminalEmpty: runs == 2, fetched: runs == 1 ? 50 : 0);
      },
      persistReport: (_) async => 'report-$runs',
    );

    final result = await controller.drainConfirmedAndPersist();

    expect(runs, 2);
    expect(result.passes, 2);
    expect(result.persistedReportReference, 'report-2');
    expect(result.remoteDrained, isTrue);
    expect(result.reachedPassLimit, isFalse);
  });

  test(
    'persists and decides while the confirmed session remains held',
    () async {
      final events = <String>[];
      var runs = 0;
      final controller = _controller(
        runConfirmed: () async => throw StateError('outside-session'),
        runSession: (action) async {
          events.add('session-enter');
          final result = await action(() async {
            runs++;
            events.add('pass-$runs');
            return report(
              terminalEmpty: runs == 2,
              fetched: runs == 1 ? 50 : 0,
            );
          });
          events.add('session-exit');
          return result;
        },
        persistReport: (_) async {
          events.add('persist-$runs');
          return 'report-$runs';
        },
      );

      final result = await controller.drainConfirmedAndPersist();

      expect(result.remoteDrained, isTrue);
      expect(events, [
        'session-enter',
        'pass-1',
        'persist-1',
        'pass-2',
        'persist-2',
        'session-exit',
      ]);
    },
  );

  test(
    'persists an unsafe report before aborting with a fixed error',
    () async {
      final events = <String>[];
      final controller = _controller(
        runConfirmed: () async {
          events.add('run');
          return report(outboxAfter: 1);
        },
        persistReport: (_) async {
          events.add('persist');
          return 'report';
        },
      );

      await expectLater(
        controller.drainConfirmedAndPersist(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_semantic_drain_unsafe_report',
          ),
        ),
      );
      expect(events, ['run', 'persist']);
    },
  );

  test('reports a safely resumable pass-limit outcome', () async {
    var runs = 0;
    final controller = _controller(
      maximumPasses: 2,
      runConfirmed: () async {
        runs++;
        return report(fetched: 50);
      },
      persistReport: (_) async => 'report-$runs',
    );

    final result = await controller.drainConfirmedAndPersist();

    expect(runs, 2);
    expect(result.passes, 2);
    expect(result.remoteDrained, isFalse);
    expect(result.reachedPassLimit, isTrue);
    expect(result.projectionComplete, isTrue);
  });

  test(
    'reports remote drain independently from partial local projection',
    () async {
      final controller = _controller(
        runConfirmed: () async =>
            report(terminalEmpty: true, retainedUnprojected: 3),
        persistReport: (_) async => 'report',
      );

      final result = await controller.drainConfirmedAndPersist();

      expect(result.remoteDrained, isTrue);
      expect(result.projectionComplete, isFalse);
      expect(result.reachedPassLimit, isFalse);
    },
  );

  test('does not inspect or repeat a report when persistence fails', () async {
    var runs = 0;
    final controller = _controller(
      runConfirmed: () async {
        runs++;
        return report(terminalEmpty: true);
      },
      persistReport: (_) async => throw StateError('persist-failure'),
    );

    await expectLater(controller.drainConfirmedAndPersist(), throwsStateError);
    expect(runs, 1);
  });

  test('does not persist when the confirmed run fails', () async {
    var persists = 0;
    final controller = _controller(
      runConfirmed: () async => throw StateError('run-failure'),
      persistReport: (_) async {
        persists++;
        return 'unexpected';
      },
    );

    await expectLater(controller.drainConfirmedAndPersist(), throwsStateError);
    expect(persists, 0);
  });

  test('rejects overlapping drains', () async {
    final release = Completer<void>();
    final controller = _controller(
      runConfirmed: () async {
        await release.future;
        return report(terminalEmpty: true);
      },
      persistReport: (_) async => 'report',
    );

    final first = controller.drainConfirmedAndPersist();
    expect(
      controller.drainConfirmedAndPersist,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_semantic_drain_controller_active',
        ),
      ),
    );
    release.complete();
    await first;
  });

  test('dispose closes admission and waits for the active drain', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final controller = _controller(
      runConfirmed: () async {
        entered.complete();
        await release.future;
        return report(terminalEmpty: true);
      },
      persistReport: (_) async => 'report',
    );

    final running = controller.drainConfirmedAndPersist();
    await entered.future;
    var disposed = false;
    final disposal = controller.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    expect(controller.isDisposed, isTrue);
    expect(
      controller.drainConfirmedAndPersist,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_semantic_drain_controller_disposed',
        ),
      ),
    );

    release.complete();
    await running;
    await disposal;
    expect(disposed, isTrue);
    await controller.dispose();
  });

  test(
    'dispose never admits another pass after the active report persists',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var runs = 0;
      final controller = _controller(
        runConfirmed: () async {
          runs++;
          if (runs == 1) {
            entered.complete();
            await release.future;
          }
          return report(fetched: 50);
        },
        persistReport: (_) async => 'report-$runs',
      );

      final running = controller.drainConfirmedAndPersist();
      await entered.future;
      final disposal = controller.dispose();
      release.complete();

      await expectLater(
        running,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_semantic_drain_cancelled',
          ),
        ),
      );
      await disposal;
      expect(runs, 1);
      expect(controller.isActive, isFalse);
    },
  );

  test('dispose before session admission performs no confirmed pass', () async {
    final sessionEntered = Completer<void>();
    final releaseSession = Completer<void>();
    var runs = 0;
    final controller = _controller(
      runConfirmed: () async {
        runs++;
        return report(terminalEmpty: true);
      },
      runSession: (action) async {
        sessionEntered.complete();
        await releaseSession.future;
        return action(() async {
          runs++;
          return report(terminalEmpty: true);
        });
      },
      persistReport: (_) async => 'report',
    );

    final running = controller.drainConfirmedAndPersist();
    await sessionEntered.future;
    final disposal = controller.dispose();
    releaseSession.complete();

    await expectLater(
      running,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_semantic_drain_cancelled',
        ),
      ),
    );
    await disposal;
    expect(runs, 0);
  });

  for (final invalidPassLimit in [0, 17]) {
    test(
      'rejects invalid pass limit $invalidPassLimit before starting a run',
      () async {
        var runs = 0;
        final controller = _controller(
          maximumPasses: invalidPassLimit,
          runConfirmed: () async {
            runs++;
            return report(terminalEmpty: true);
          },
          persistReport: (_) async => 'report',
        );

        expect(
          controller.drainConfirmedAndPersist,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'cloud_sync_semantic_drain_pass_limit_invalid',
            ),
          ),
        );
        expect(runs, 0);
      },
    );
  }
}

CloudSyncSemanticDrainController _controller({
  required CloudSyncConfirmedSemanticPullPass runConfirmed,
  required CloudSyncSemanticPullReportPersist persistReport,
  int maximumPasses = CloudSyncSemanticDrainController.defaultMaximumPasses,
  CloudSyncSemanticDrainSessionRun? runSession,
}) {
  return CloudSyncSemanticDrainController(
    persistReport: persistReport,
    maximumPasses: maximumPasses,
    runSession: runSession ?? ((action) => action(runConfirmed)),
  );
}

CloudSyncSemanticPullReport report({
  bool terminalEmpty = false,
  int fetched = 0,
  int retainedUnprojected = 0,
  int outboxAfter = 0,
}) {
  return CloudSyncSemanticPullReport(
    timestampUtc: DateTime.utc(2026, 8, 31),
    platform: 'windows',
    architecture: 'windows_arm64',
    buildCommit: 'test',
    pageLimit: CloudSyncManualSemanticPullSampler.pageLimit,
    changeLimit: CloudSyncManualSemanticPullSampler.changeLimit,
    outboxCountBefore: 0,
    outboxCountAfter: outboxAfter,
    zones: [
      for (final label in CloudSyncSemanticPullReport.expectedZoneLabels)
        CloudSyncSemanticPullZoneReport(
          zoneLabel: label,
          status: CloudSyncRunStatus.completed,
          fetched: terminalEmpty ? 0 : fetched,
          applied: 0,
          deferred: 0,
          quarantined: 0,
          preflightQuarantined: 0,
          preflightUnsupportedRecordType: 0,
          preflightMalformedMetadata: 0,
          preflightOversizedRecord: 0,
          preflightInvalidChangeShape: 0,
          preflightUnknown: 0,
          startupQuarantined: 0,
          postFetchQuarantined: 0,
          tombstoneQuarantined: 0,
          tombstoneReadOnlyAcknowledged: 0,
          retainedUnprojected: retainedUnprojected,
          semanticUnsupportedServiceQuarantined: 0,
          semanticStageQuarantined: 0,
          retried: 0,
          elapsedMilliseconds: 1,
          observedEmptyTerminalRead: terminalEmpty,
        ),
    ],
  );
}
