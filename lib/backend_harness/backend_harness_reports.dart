import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';

import 'backend_harness_protocol.dart';

/// Presentation of the actual current report. Counts are work units, not
/// unique-message totals. No filesystem lookup or cached previous run is used.
BackendHarnessPayload backendHarnessReportSnapshot(
  CloudSyncProgress progress,
  String expectedSource,
) {
  final report = progress.latestReport;
  if (report == null) {
    return const BackendHarnessPayload(flags: {'has_report': false});
  }
  final current =
      RegExp(r'^[a-f0-9]{40}$').hasMatch(expectedSource) &&
      report.buildCommit == expectedSource;
  return BackendHarnessPayload(
    phase: current ? BackendHarnessPhase.idle : BackendHarnessPhase.blocked,
    flags: {
      'has_report': true,
      'report_source_matches': current,
      'report_tripwires_intact': report.remoteWriteTripwiresIntact,
      'report_safe': current && report.safeToContinueDrain,
      'remote_head': current && report.allZonesObservedEmptyTerminalRead,
      'projection_complete': current && progress.projectionComplete,
    },
    counts: {
      'fetched': report.zones.fold(0, (n, zone) => n + zone.fetched),
      'reprojected': report.zones.fold(0, (n, zone) => n + zone.applied),
      'retained': report.zones.fold(
        0,
        (n, zone) => n + zone.retainedUnprojected,
      ),
      'deferred': report.zones.fold(0, (n, zone) => n + zone.deferred),
      'quarantined': report.zones.fold(0, (n, zone) => n + zone.quarantined),
      'outbox_before': report.outboxCountBefore,
      'outbox_after': report.outboxCountAfter,
    },
  );
}
