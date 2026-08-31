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
    this.observedEmptyTerminalRead = false,
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
  final bool observedEmptyTerminalRead;
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
    'observedEmptyTerminalRead': observedEmptyTerminalRead,
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

  static const schemaVersion = 5;
  static const expectedZoneLabels = <String>{
    'attachments',
    'chats',
    'messages',
  };
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

  bool get hasExactThreeZoneStructure {
    final labels = zones.map((zone) => zone.zoneLabel).toSet();
    return zones.length == expectedZoneLabels.length &&
        labels.length == expectedZoneLabels.length &&
        labels.containsAll(expectedZoneLabels);
  }

  /// True only when every zone completed a durable terminal CloudKit read that
  /// contained no server changes. The fetched counter alone is insufficient:
  /// duplicate nonempty pages can insert zero new journal rows.
  bool get allZonesObservedEmptyTerminalRead =>
      hasExactThreeZoneStructure &&
      zones.every(
        (zone) => zone.fetched == 0 && zone.observedEmptyTerminalRead,
      );

  /// The drain may continue only through a clean read or the one explicitly
  /// non-destructive degraded state: retained rows awaiting local projection.
  bool get safeToContinueDrain {
    if (!remoteWriteTripwiresIntact || !hasExactThreeZoneStructure) {
      return false;
    }
    for (final zone in zones) {
      final acceptedStatus =
          (zone.status == CloudSyncRunStatus.completed &&
              zone.failureCategory == null &&
              zone.failureSafeCode == null) ||
          (zone.status == CloudSyncRunStatus.degraded &&
              zone.failureCategory == CloudFailureCategory.dependency &&
              zone.failureSafeCode == 'retained_projection_incomplete');
      if (!acceptedStatus ||
          zone.skipReason != null ||
          zone.deferred != 0 ||
          zone.quarantined != 0 ||
          zone.preflightQuarantined != 0 ||
          zone.preflightUnsupportedRecordType != 0 ||
          zone.preflightMalformedMetadata != 0 ||
          zone.preflightOversizedRecord != 0 ||
          zone.preflightInvalidChangeShape != 0 ||
          zone.preflightUnknown != 0 ||
          zone.startupQuarantined != 0 ||
          zone.postFetchQuarantined != 0 ||
          zone.tombstoneQuarantined != 0 ||
          zone.semanticUnsupportedServiceQuarantined != 0 ||
          zone.semanticStageQuarantined != 0 ||
          zone.retried != 0) {
        return false;
      }
    }
    return true;
  }

  bool get projectionComplete =>
      hasExactThreeZoneStructure &&
      zones.every((zone) => zone.retainedUnprojected == 0);

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
