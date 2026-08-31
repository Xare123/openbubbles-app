import 'package:bluebubbles/app/layouts/settings/pages/misc/troubleshoot_panel.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncSemanticPullZoneReport _zone(
  String zoneLabel, {
  CloudSyncRunStatus status = CloudSyncRunStatus.completed,
  int retainedUnprojected = 0,
  int deferred = 0,
  int quarantined = 0,
  int unsupportedServiceQuarantined = 0,
  int tombstoneQuarantined = 0,
  int retried = 0,
}) => CloudSyncSemanticPullZoneReport(
  zoneLabel: zoneLabel,
  status: status,
  fetched: 1,
  applied: retainedUnprojected == 0 ? 1 : 0,
  deferred: deferred,
  quarantined: quarantined,
  preflightQuarantined: 0,
  preflightUnsupportedRecordType: 0,
  preflightMalformedMetadata: 0,
  preflightOversizedRecord: 0,
  preflightInvalidChangeShape: 0,
  preflightUnknown: 0,
  startupQuarantined: 0,
  postFetchQuarantined: 0,
  tombstoneQuarantined: tombstoneQuarantined,
  tombstoneReadOnlyAcknowledged: 0,
  retainedUnprojected: retainedUnprojected,
  semanticUnsupportedServiceQuarantined: unsupportedServiceQuarantined,
  semanticStageQuarantined: 0,
  retried: retried,
  elapsedMilliseconds: 1,
);

CloudSyncSemanticPullReport _report({
  List<String> zoneLabels = const <String>['chats', 'messages', 'attachments'],
  CloudSyncRunStatus status = CloudSyncRunStatus.completed,
  int retainedUnprojected = 0,
  int deferred = 0,
  int quarantined = 0,
  int unsupportedServiceQuarantined = 0,
  int tombstoneQuarantined = 0,
  int retried = 0,
  int outboxCountAfter = 0,
}) => CloudSyncSemanticPullReport(
  timestampUtc: DateTime.utc(2026),
  platform: 'android',
  architecture: 'arm64',
  buildCommit: 'test',
  pageLimit: 1,
  changeLimit: 1,
  outboxCountBefore: 0,
  outboxCountAfter: outboxCountAfter,
  zones: <CloudSyncSemanticPullZoneReport>[
    for (var index = 0; index < zoneLabels.length; index++)
      _zone(
        zoneLabels[index],
        status: index == 0 ? status : CloudSyncRunStatus.completed,
        retainedUnprojected: index == 0 ? retainedUnprojected : 0,
        deferred: index == 0 ? deferred : 0,
        quarantined: index == 0 ? quarantined : 0,
        unsupportedServiceQuarantined: index == 0
            ? unsupportedServiceQuarantined
            : 0,
        tombstoneQuarantined: index == 0 ? tombstoneQuarantined : 0,
        retried: index == 0 ? retried : 0,
      ),
  ],
);

void main() {
  test('zero retained rows can report complete and totals show the count', () {
    final presentation = cloudSyncV2SemanticCanaryPresentation(_report());

    expect(presentation.outcome, CloudSyncV2SemanticCanaryOutcome.complete);
    expect(presentation.title, 'Cloud Sync V2 Complete');
    expect(presentation.message, contains('retained-unprojected 0'));
    expect(
      presentation.message,
      contains('No CloudKit uploads or deletes occurred.'),
    );
  });

  test('retained rows across all zones report partial, never complete', () {
    final report = CloudSyncSemanticPullReport(
      timestampUtc: DateTime.utc(2026),
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'test',
      pageLimit: 1,
      changeLimit: 1,
      outboxCountBefore: 0,
      outboxCountAfter: 0,
      zones: <CloudSyncSemanticPullZoneReport>[
        _zone('chats', retainedUnprojected: 1),
        _zone('messages', retainedUnprojected: 2),
        _zone('attachments', retainedUnprojected: 4),
      ],
    );

    final presentation = cloudSyncV2SemanticCanaryPresentation(report);

    expect(presentation.outcome, CloudSyncV2SemanticCanaryOutcome.partial);
    expect(presentation.title, 'Cloud Sync V2 Partial');
    expect(presentation.title, isNot('Cloud Sync V2 Complete'));
    expect(presentation.message, contains('retained-unprojected 7'));
    expect(
      presentation.message,
      contains('7 records remain retained and have not been projected'),
    );
    expect(
      presentation.message,
      contains('No CloudKit uploads or deletes occurred.'),
    );
  });

  test('existing completion gates still stop the canary safely', () {
    final blockedReports = <String, CloudSyncSemanticPullReport>{
      'exact three zones': _report(
        zoneLabels: const <String>['chats', 'messages'],
      ),
      'unique expected zones': _report(
        zoneLabels: const <String>['chats', 'messages', 'messages'],
      ),
      'completed zone status': _report(status: CloudSyncRunStatus.degraded),
      'deferred': _report(deferred: 1),
      'quarantined': _report(quarantined: 1),
      'unsupported service quarantine': _report(
        unsupportedServiceQuarantined: 1,
      ),
      'tombstone quarantine': _report(tombstoneQuarantined: 1),
      'retry': _report(retried: 1),
      'write tripwire': _report(outboxCountAfter: 1),
    };

    for (final MapEntry(key: gate, value: report) in blockedReports.entries) {
      final presentation = cloudSyncV2SemanticCanaryPresentation(report);
      expect(
        presentation.outcome,
        CloudSyncV2SemanticCanaryOutcome.stoppedSafely,
        reason: gate,
      );
      expect(presentation.title, 'Cloud Sync V2 Stopped Safely', reason: gate);
    }
  });
}
