import 'cloud_sync_engine.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';

/// Content-free result for one developer-confirmed local semantic projection.
final class CloudSyncSemanticPullZoneReport {
  const CloudSyncSemanticPullZoneReport({
    required this.zoneLabel,
    required this.status,
    required this.fetched,
    required this.applied,
    required this.deferred,
    required this.quarantined,
    required this.retried,
    required this.elapsedMilliseconds,
    this.failureCategory,
    this.skipReason,
  });

  final String zoneLabel;
  final CloudSyncRunStatus status;
  final int fetched;
  final int applied;
  final int deferred;
  final int quarantined;
  final int retried;
  final int elapsedMilliseconds;
  final CloudFailureCategory? failureCategory;
  final CloudSyncSkipReason? skipReason;

  Map<String, Object?> toJson() => {
    'zone': zoneLabel,
    'status': status.name,
    'fetched': fetched,
    'applied': applied,
    'deferred': deferred,
    'quarantined': quarantined,
    'retried': retried,
    'elapsedMilliseconds': elapsedMilliseconds,
    'failureCategory': failureCategory?.name,
    'skipReason': skipReason?.name,
  };
}

final class CloudSyncSemanticPullReport {
  CloudSyncSemanticPullReport({
    required this.timestampUtc,
    required this.platform,
    required this.architecture,
    required this.buildCommit,
    required this.pageLimit,
    required this.changeLimit,
    required this.outboxCountBefore,
    required this.outboxCountAfter,
    required Iterable<CloudSyncSemanticPullZoneReport> zones,
  }) : zones = List.unmodifiable(zones);

  static const schemaVersion = 1;
  final DateTime timestampUtc;
  final String platform;
  final String architecture;
  final String buildCommit;
  final int pageLimit;
  final int changeLimit;
  final int outboxCountBefore;
  final int outboxCountAfter;
  final List<CloudSyncSemanticPullZoneReport> zones;

  bool get remoteWriteTripwiresIntact =>
      outboxCountBefore == 0 && outboxCountAfter == 0;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'timestampUtc': timestampUtc.toUtc().toIso8601String(),
    'platform': platform,
    'architecture': architecture,
    'buildCommit': buildCommit,
    'mode': 'manual-semantic-read-only-cloudkit',
    'automaticTriggersEnabled': false,
    'remoteSavesEnabled': false,
    'remoteDeletesEnabled': false,
    'tombstonesEnabled': false,
    'pageLimit': pageLimit,
    'changeLimit': changeLimit,
    'outboxCountBefore': outboxCountBefore,
    'outboxCountAfter': outboxCountAfter,
    'zones': zones.map((zone) => zone.toJson()).toList(growable: false),
  };
}
