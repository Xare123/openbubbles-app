import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';

/// Allowlisted, content-free result for a one-shot read-only shadow sample.
///
/// Keep serialization here explicit. Do not add generic object serialization:
/// CloudKit identifiers, tokens, protected values, and message data must never
/// enter this report.
class CloudSyncShadowZoneReport {
  const CloudSyncShadowZoneReport({
    required this.zoneLabel,
    required this.status,
    required this.fetched,
    required this.journaled,
    required this.rejected,
    required this.estimatedBytes,
    required this.elapsedMilliseconds,
    this.failureCategory,
    this.skipReason,
    this.blockReason,
  });

  final String zoneLabel;
  final CloudSyncRunStatus status;
  final int fetched;
  final int journaled;
  final int rejected;
  final int estimatedBytes;
  final int elapsedMilliseconds;
  final CloudFailureCategory? failureCategory;
  final CloudSyncSkipReason? skipReason;
  final CloudShadowJournalBlockReason? blockReason;

  Map<String, Object?> toJson() => {
    'zone': zoneLabel,
    'status': status.name,
    'fetched': fetched,
    'journaled': journaled,
    'rejected': rejected,
    'estimatedBytes': estimatedBytes,
    'elapsedMilliseconds': elapsedMilliseconds,
    'failureCategory': failureCategory?.name,
    'skipReason': skipReason?.name,
    'blockReason': blockReason?.name,
  };
}

class CloudSyncShadowReport {
  CloudSyncShadowReport({
    required this.runId,
    required this.correlationTag,
    required this.timestampUtc,
    required this.platform,
    required this.architecture,
    required this.buildCommit,
    required this.legacySyncEnabled,
    required this.pageLimit,
    required this.changeLimit,
    required this.tripwiresArmed,
    required this.outboxCountBefore,
    required this.outboxCountAfter,
    required Iterable<CloudSyncShadowZoneReport> zones,
  }) : zones = List.unmodifiable(zones);

  static const int schemaVersion = 1;
  final String runId;

  /// Random per-run tag. It is not stable across runs or derived from account
  /// identity, so exported reports cannot be correlated to an Apple account.
  final String correlationTag;
  final DateTime timestampUtc;
  final String platform;
  final String architecture;
  final String buildCommit;
  final bool legacySyncEnabled;
  final int pageLimit;
  final int changeLimit;
  final bool tripwiresArmed;
  final int outboxCountBefore;
  final int outboxCountAfter;
  final List<CloudSyncShadowZoneReport> zones;

  bool get isValidReadOnlySuccess =>
      tripwiresArmed &&
      !legacySyncEnabled &&
      outboxCountBefore == outboxCountAfter &&
      zones.every((zone) => zone.status == CloudSyncRunStatus.completed);

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'runId': runId,
    'timestampUtc': timestampUtc.toUtc().toIso8601String(),
    'platform': platform,
    'architecture': architecture,
    'buildCommit': buildCommit,
    'mode': 'manual-read-only',
    'automaticTriggersEnabled': false,
    'correlationTag': correlationTag,
    'legacySyncEnabled': legacySyncEnabled,
    'pageLimit': pageLimit,
    'changeLimit': changeLimit,
    'tripwiresArmed': tripwiresArmed,
    'outboxCountBefore': outboxCountBefore,
    'outboxCountAfter': outboxCountAfter,
    'zones': zones.map((zone) => zone.toJson()).toList(growable: false),
  };
}
