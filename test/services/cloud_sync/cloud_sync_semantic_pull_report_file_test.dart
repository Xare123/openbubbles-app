import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

CloudSyncSemanticPullZoneReport _zone(String label) =>
    CloudSyncSemanticPullZoneReport(
      zoneLabel: label,
      status: CloudSyncRunStatus.completed,
      fetched: 1,
      applied: 0,
      deferred: 0,
      quarantined: 1,
      preflightQuarantined: 0,
      preflightUnsupportedRecordType: 0,
      preflightMalformedMetadata: 0,
      preflightOversizedRecord: 0,
      preflightInvalidChangeShape: 0,
      preflightUnknown: 0,
      startupQuarantined: 0,
      postFetchQuarantined: 1,
      tombstoneQuarantined: 0,
      semanticUnsupportedServiceQuarantined: 0,
      semanticStageQuarantined: 1,
      retried: 0,
      elapsedMilliseconds: 5,
      diagnosticCounts: const {
        'canonical_chat_relation_unavailable': 1,
        'native_ready': 1,
      },
    );

CloudSyncSemanticPullReport _report(
  DateTime timestamp, {
  int outboxCountAfter = 0,
}) => CloudSyncSemanticPullReport(
  timestampUtc: timestamp,
  platform: 'windows',
  architecture: 'arm64',
  buildCommit: 'test-commit',
  pageLimit: 1,
  changeLimit: 50,
  outboxCountBefore: 0,
  outboxCountAfter: outboxCountAfter,
  zones: [_zone('chats'), _zone('messages'), _zone('attachments')],
);

void main() {
  late Directory root;
  late Directory reports;

  setUp(() {
    root = Directory.systemTemp.createTempSync('semantic-report-root-');
    reports = Directory('${root.path}${Platform.pathSeparator}reports');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('atomically persists only the typed content-free report', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final file = await writer.write(
      _report(DateTime.utc(2026, 8, 29, 1, 2, 3)),
    );

    expect(file.path, contains('obcs2-semantic-'));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['schemaVersion'], 2);
    final zones = json['zones'] as List<dynamic>;
    expect(
      (zones.first as Map<String, dynamic>)['semanticDiagnostics'],
      <String, dynamic>{
        'canonical_chat_relation_unavailable': 1,
        'native_ready': 1,
      },
    );
    final encoded = jsonEncode(json);
    expect(encoded, isNot(contains('record-id')));
    expect(encoded, isNot(contains('message-body')));
    expect(encoded, isNot(contains('account@example.com')));
    expect(encoded, isNot(contains('obcs2.ref.')));
  });

  test('rejects a report whose read-only outbox tripwire moved', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );

    await expectLater(
      writer.write(
        _report(DateTime.utc(2026, 8, 29, 1, 2, 3), outboxCountAfter: 1),
      ),
      throwsA(
        isA<CloudSyncSemanticPullReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_semantic_report_read_only_invariant_invalid',
        ),
      ),
    );
  });

  test('retains only owned reports within the configured bound', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
      maximumRetainedReports: 2,
    );
    for (var second = 1; second <= 3; second++) {
      await writer.write(_report(DateTime.utc(2026, 8, 29, 1, 2, second)));
    }

    final owned = reports.listSync().whereType<File>().where(
      (file) => file.path.contains('obcs2-semantic-'),
    );
    expect(owned.length, 2);
  });
}
