import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_read_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'cloud_sync_semantic_drain_controller_test.dart' as fixtures;

CloudSyncSemanticDrainResult result({
  bool head = true,
  bool projected = true,
}) => CloudSyncSemanticDrainResult(
  passes: 1,
  lastReport: fixtures.report(terminalEmpty: head),
  persistedReportReference: 'persisted',
  remoteDrained: head,
  projectionComplete: projected,
  retainedSaveProjectionComplete: projected,
  projectionSweepAttempted: true,
  reachedPassLimit: !head,
);

void main() {
  test(
    'Regular uses smaller sessions and longer gaps than Turbo',
    () {
      const regular = CloudSyncSpeed.regular;
      const turbo = CloudSyncSpeed.turbo;
      expect(regular.readBudget, same(CloudSyncReadBudget.regular));
      expect(turbo.readBudget, same(CloudSyncReadBudget.standard));
      expect(regular.readBudget.pagesPerPass, 1);
      expect(regular.readBudget.retainedReplayEntries, 32);
      expect(turbo.readBudget.pagesPerPass, 4);
      expect(turbo.readBudget.retainedReplayEntries, 150);
      expect(regular.passesPerBatch, 1);
      expect(turbo.passesPerBatch, 16);
      expect(regular.maximumBatches, 512);
      expect(turbo.maximumBatches, 16);
      expect(regular.pauseBetweenBatches, const Duration(milliseconds: 250));
      expect(turbo.pauseBetweenBatches, const Duration(milliseconds: 1));
    },
  );

  test('fresh page-volume caps remain 25600 Regular and 51200 Turbo per zone', () {
    int freshCap(CloudSyncSpeed speed) =>
        speed.maximumBatches *
        speed.passesPerBatch *
        speed.readBudget.freshEntriesPerPass;

    expect(CloudSyncReadBudget.regular.freshEntriesPerPass, 50);
    expect(CloudSyncReadBudget.standard.freshEntriesPerPass, 200);
    expect(freshCap(CloudSyncSpeed.regular), 25600);
    expect(freshCap(CloudSyncSpeed.turbo), 51200);
  });

  test('read budgets accept limits and reject invalid page or replay counts', () {
    for (final budget in const [
      CloudSyncReadBudget.standard,
      CloudSyncReadBudget.regular,
      CloudSyncReadBudget(pagesPerPass: 1, retainedReplayEntries: 0),
      CloudSyncReadBudget(pagesPerPass: 4, retainedReplayEntries: 150),
    ]) {
      expect(budget.validate, returnsNormally);
    }
    for (final budget in const [
      CloudSyncReadBudget(pagesPerPass: 0),
      CloudSyncReadBudget(pagesPerPass: 5),
      CloudSyncReadBudget(retainedReplayEntries: -1),
      CloudSyncReadBudget(retainedReplayEntries: 151),
    ]) {
      expect(budget.validate, throwsArgumentError);
    }
  });

  test(
    'one owner joins repeated starts and navigation does not own cancellation',
    () async {
      final p = CloudSyncProgress();
      final done = Completer<CloudSyncSemanticDrainResult>();
      var calls = 0;
      final first = p.start(CloudSyncSpeed.regular, () {
        calls++;
        return done.future;
      });
      final second = p.start(
        CloudSyncSpeed.turbo,
        () => throw StateError('duplicate'),
      );
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(p.speed, CloudSyncSpeed.regular);
      done.complete(result());
      await first;
      expect(p.phase, CloudSyncProgressPhase.remoteHead);
      expect(p.active, isFalse);
    },
  );

  test('immediate pause cancels admission before runner starts', () async {
    final p = CloudSyncProgress();
    final run = p.start(
      CloudSyncSpeed.regular,
      () => throw StateError('must not run'),
    );
    p.pause();
    await run;
    expect(p.phase, CloudSyncProgressPhase.paused);
    expect(p.safeFailure, isNull);
  });

  test(
    'pause waits for protected release and does not report early completion',
    () async {
      final p = CloudSyncProgress();
      final release = Completer<void>();
      var requests = 0;
      final run = p.start(CloudSyncSpeed.regular, () async {
        p.cancelWindow = () {
          requests++;
        };
        await release.future;
        p.checkPause();
        return result();
      });
      await Future<void>.delayed(Duration.zero);
      p.pause();
      p.pause();
      p.activity(CloudSyncProgressPhase.fetching, 'messageManateeZone');
      expect(requests, 1);
      expect(p.active, isTrue);
      expect(p.phase, CloudSyncProgressPhase.pausing);
      release.complete();
      await run;
      expect(p.active, isFalse);
      expect(p.phase, CloudSyncProgressPhase.paused);
    },
  );

  test(
    'a safety failure during pause is not disguised as successful cancellation',
    () async {
      final p = CloudSyncProgress();
      final release = Completer<void>();
      final run = p.start(CloudSyncSpeed.regular, () async {
        await release.future;
        throw StateError('cloud_sync_native_auth_account_changed');
      });
      await Future<void>.delayed(Duration.zero);
      p.pause();
      release.complete();
      await run;
      expect(p.phase, CloudSyncProgressPhase.error);
      expect(p.safeFailure, 'cloud_sync_native_auth_account_changed');
    },
  );

  test(
    'cap is paused, never 100 percent; head is distinct from local projection',
    () async {
      final p = CloudSyncProgress();
      await p.start(CloudSyncSpeed.regular, () async => result(head: false));
      expect(p.phase, CloudSyncProgressPhase.paused);
      expect(p.fraction, isNull);
      await p.start(
        CloudSyncSpeed.regular,
        () async => result(projected: false),
      );
      expect(p.title, contains('dependencies remain'));
      expect(p.fraction, isNull);
    },
  );

  test(
    'exact journal counters include empty pages but do not invent record totals',
    () async {
      final p = CloudSyncProgress();
      await p.start(CloudSyncSpeed.regular, () async {
        for (final count in [10, 0, 2]) {
          p.event(
            'messageManateeZone',
            CloudSyncEvent(
              type: CloudSyncEventType.fetchCompleted,
              scopeDiagnosticKey: 'redacted',
              at: DateTime.utc(2026),
              count: count,
            ),
          );
        }
        p.projectionWindow(8, 3);
        p.projectionWindow(8, 1);
        expect(p.pages, 3);
        expect(p.fetched, 12);
        expect(p.zoneFetched, {'Messages': 12});
        expect(p.projectionExamined, 16);
        expect(p.reprojected, 4);
        expect(p.fraction, isNull);
        return result();
      });
      await p.start(CloudSyncSpeed.regular, () async {
        expect(p.pages, 0);
        expect(p.hasReport, isFalse);
        return result();
      });
      expect(CloudSyncProgress().phase, CloudSyncProgressPhase.idle);
    },
  );

  test(
    'media completion and failure remain separate from remote history head',
    () async {
      final p = CloudSyncProgress();
      final media = Completer<String>();
      final work = p.materialize(() => media.future);
      expect(p.mediaActive, 1);
      await p.start(CloudSyncSpeed.regular, () async => result());
      expect(p.phase, CloudSyncProgressPhase.remoteHead);
      expect(p.mediaActive, 1);
      media.complete('local-file');
      expect(await work, 'local-file');
      expect(p.mediaCompleted, 1);
      await expectLater(
        p.materialize(() async => throw StateError('private error')),
        throwsStateError,
      );
      expect(p.mediaFailed, 1);
      expect(p.mediaActive, 0);
    },
  );

  test('arbitrary auth error is redacted and does not claim success', () async {
    final p = CloudSyncProgress();
    await p.start(
      CloudSyncSpeed.regular,
      () async => throw Exception('secret@example.org'),
    );
    expect(p.phase, CloudSyncProgressPhase.error);
    expect(p.safeFailure, isNot(contains('secret')));
  });

  test('progress observer preserves evidence flushing and events', () async {
    final p = CloudSyncProgress();
    final evidence = _Evidence();
    final observer = CloudSyncProgressObserver(p, 'chatManateeZone', evidence);
    await p.start(CloudSyncSpeed.regular, () async {
      observer.onEvent(
        CloudSyncEvent(
          type: CloudSyncEventType.fetchStarted,
          scopeDiagnosticKey: 'safe',
          at: DateTime.utc(2026),
        ),
      );
      expect(p.phase, CloudSyncProgressPhase.fetching);
      expect(p.zone, 'Chats');
      observer.onEvent(
        CloudSyncEvent(
          type: CloudSyncEventType.inboxApplyStarted,
          scopeDiagnosticKey: 'safe',
          at: DateTime.utc(2026),
        ),
      );
      expect(p.phase, CloudSyncProgressPhase.replaying);
      await observer.flush();
      expect(evidence.events, 2);
      expect(evidence.flushed, isTrue);
      return result();
    });
  });
}

class _Evidence implements FlushableCloudSyncObserver {
  int events = 0;
  bool flushed = false;
  @override
  void onEvent(CloudSyncEvent event) {
    events++;
  }

  @override
  Future<void> flush() async {
    flushed = true;
  }
}
