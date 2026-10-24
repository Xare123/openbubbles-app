import 'dart:async';

import 'package:bluebubbles/backend_harness/backend_harness_reports.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_drain_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/cloud_sync/cloud_sync_semantic_drain_controller_test.dart'
    as fixtures;

void main() {
  final source = 'a' * 40;
  CloudSyncSemanticDrainResult result({int fetched = 0}) {
    final base = fixtures.report(terminalEmpty: fetched == 0, fetched: fetched);
    final report = CloudSyncSemanticPullReport(
      timestampUtc: base.timestampUtc,
      platform: base.platform,
      architecture: base.architecture,
      buildCommit: source,
      pageLimit: base.pageLimit,
      changeLimit: base.changeLimit,
      outboxCountBefore: base.outboxCountBefore,
      outboxCountAfter: base.outboxCountAfter,
      zones: base.zones,
    );
    return CloudSyncSemanticDrainResult(
      passes: 1,
      lastReport: report,
      persistedReportReference: 'synthetic',
      remoteDrained: fetched == 0,
      projectionComplete: true,
      retainedSaveProjectionComplete: true,
      projectionSweepAttempted: true,
      reachedPassLimit: fetched != 0,
    );
  }

  test(
    'a new run cannot report the previous run as its current result',
    () async {
      final progress = CloudSyncProgress();
      expect(
        backendHarnessReportSnapshot(progress, source).flags['has_report'],
        isFalse,
      );
      await progress.start(CloudSyncSpeed.regular, () async => result());
      expect(
        backendHarnessReportSnapshot(progress, source).flags['report_safe'],
        isTrue,
      );
      final next = Completer<CloudSyncSemanticDrainResult>();
      final running = progress.start(CloudSyncSpeed.regular, () => next.future);
      expect(progress.latestReport, isNull);
      expect(
        backendHarnessReportSnapshot(progress, source).flags['has_report'],
        isFalse,
      );
      next.complete(result(fetched: 2));
      await running;
      final current = backendHarnessReportSnapshot(progress, source);
      expect(current.counts['fetched'], 6);
      expect(current.flags['remote_head'], isFalse);
    },
  );

  test(
    'a report from another source remains visible but never qualifies',
    () async {
      final progress = CloudSyncProgress();
      await progress.start(CloudSyncSpeed.regular, () async => result());
      final stale = backendHarnessReportSnapshot(progress, 'b' * 40);
      expect(stale.phase, BackendHarnessPhase.blocked);
      expect(stale.flags['has_report'], isTrue);
      expect(stale.flags['report_source_matches'], isFalse);
      expect(stale.flags['report_safe'], isFalse);
      expect(stale.flags['projection_complete'], isFalse);
      expect(stale.flags['remote_head'], isFalse);
    },
  );
}
