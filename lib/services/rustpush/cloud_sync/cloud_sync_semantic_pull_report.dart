import 'cloud_sync_engine.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_semantic_diagnostics.dart';

/// Content-free result for one developer-confirmed local semantic projection.
final class CloudSyncSemanticPullZoneReport {
  CloudSyncSemanticPullZoneReport({
    required this.zoneLabel,
    required this.status,
    required this.fetched,
    required this.applied,
    required this.deferred,
    required this.quarantined,
    required this.preflightQuarantined,
    required this.preflightUnsupportedRecordType,
    required this.preflightMalformedMetadata,
    required this.preflightOversizedRecord,
    required this.preflightInvalidChangeShape,
    required this.preflightUnknown,
    required this.startupQuarantined,
    required this.postFetchQuarantined,
    required this.tombstoneQuarantined,
    required this.tombstoneReadOnlyAcknowledged,
    this.retainedUnprojected = 0,
    required this.semanticUnsupportedServiceQuarantined,
    required this.semanticStageQuarantined,
    required this.retried,
    required this.elapsedMilliseconds,
    Map<String, int> diagnosticCounts = const <String, int>{},
    this.failureCategory,
    String? failureSafeCode,
    this.skipReason,
  }) : diagnosticCounts =
           CloudSyncSemanticDiagnosticCollector.validatedSnapshot(
             diagnosticCounts,
           ),
       failureSafeCode = failureCategory == null
           ? null
           : cloudSyncV2SafeFailureCodeForCandidate(failureSafeCode);

  final String zoneLabel;
  final CloudSyncRunStatus status;
  final int fetched;
  final int applied;
  final int deferred;
  final int quarantined;
  final int preflightQuarantined;
  final int preflightUnsupportedRecordType;
  final int preflightMalformedMetadata;
  final int preflightOversizedRecord;
  final int preflightInvalidChangeShape;
  final int preflightUnknown;
  final int startupQuarantined;
  final int postFetchQuarantined;
  final int tombstoneQuarantined;
  final int tombstoneReadOnlyAcknowledged;

  /// Current-generation durable backlog at the end of the zone run, not only
  /// rows newly retained during that run.
  final int retainedUnprojected;
  final int semanticUnsupportedServiceQuarantined;
  final int semanticStageQuarantined;
  final int retried;
  final int elapsedMilliseconds;
  final Map<String, int> diagnosticCounts;
  final CloudFailureCategory? failureCategory;
  final String? failureSafeCode;
  final CloudSyncSkipReason? skipReason;

  Map<String, Object?> toJson() => {
    'zone': zoneLabel,
    'status': status.name,
    'fetched': fetched,
    'applied': applied,
    'deferred': deferred,
    'quarantined': quarantined,
    'preflightQuarantined': preflightQuarantined,
    'preflightReasons': <String, int>{
      'unsupportedRecordType': preflightUnsupportedRecordType,
      'malformedMetadata': preflightMalformedMetadata,
      'oversizedRecord': preflightOversizedRecord,
      'invalidChangeShape': preflightInvalidChangeShape,
      'unknown': preflightUnknown,
    },
    'quarantinePhases': <String, int>{
      'startup': startupQuarantined,
      'postFetch': postFetchQuarantined,
    },
    'tombstoneQuarantined': tombstoneQuarantined,
    'tombstoneReadOnlyAcknowledged': tombstoneReadOnlyAcknowledged,
    'retainedUnprojected': retainedUnprojected,
    'semanticUnsupportedServiceQuarantined':
        semanticUnsupportedServiceQuarantined,
    'semanticStageQuarantined': semanticStageQuarantined,
    'retried': retried,
    'elapsedMilliseconds': elapsedMilliseconds,
    'semanticDiagnostics': diagnosticCounts,
    'failureCategory': failureCategory?.name,
    'failureSafeCode': failureSafeCode,
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

  static const schemaVersion = 4;
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
    'tombstoneSemanticDeletesEnabled': false,
    'tombstoneReadOnlyAcknowledgementsEnabled': true,
    'retainedUnprojectedEvidencePreserved': true,
    'pageLimit': pageLimit,
    'changeLimit': changeLimit,
    'outboxCountBefore': outboxCountBefore,
    'outboxCountAfter': outboxCountAfter,
    'zones': zones.map((zone) => zone.toJson()).toList(growable: false),
  };
}
