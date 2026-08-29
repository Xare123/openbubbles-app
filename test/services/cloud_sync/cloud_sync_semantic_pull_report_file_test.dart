import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

CloudSyncSemanticPullZoneReport _zone(
  String label, {
  int fetched = 1,
  int applied = 0,
  int deferred = 0,
  int quarantined = 1,
  int preflightQuarantined = 0,
  int preflightUnsupportedRecordType = 0,
  int preflightMalformedMetadata = 0,
  int preflightOversizedRecord = 0,
  int preflightInvalidChangeShape = 0,
  int preflightUnknown = 0,
  int startupQuarantined = 0,
  int postFetchQuarantined = 1,
  int tombstoneQuarantined = 0,
  int tombstoneReadOnlyAcknowledged = 0,
  int semanticUnsupportedServiceQuarantined = 0,
  int semanticStageQuarantined = 1,
  int retried = 0,
  Map<String, int> diagnosticCounts = const {
    'canonical_chat_relation_unavailable': 1,
    'native_ready': 1,
  },
}) => CloudSyncSemanticPullZoneReport(
  zoneLabel: label,
  status: CloudSyncRunStatus.completed,
  fetched: fetched,
  applied: applied,
  deferred: deferred,
  quarantined: quarantined,
  preflightQuarantined: preflightQuarantined,
  preflightUnsupportedRecordType: preflightUnsupportedRecordType,
  preflightMalformedMetadata: preflightMalformedMetadata,
  preflightOversizedRecord: preflightOversizedRecord,
  preflightInvalidChangeShape: preflightInvalidChangeShape,
  preflightUnknown: preflightUnknown,
  startupQuarantined: startupQuarantined,
  postFetchQuarantined: postFetchQuarantined,
  tombstoneQuarantined: tombstoneQuarantined,
  tombstoneReadOnlyAcknowledged: tombstoneReadOnlyAcknowledged,
  semanticUnsupportedServiceQuarantined: semanticUnsupportedServiceQuarantined,
  semanticStageQuarantined: semanticStageQuarantined,
  retried: retried,
  elapsedMilliseconds: 5,
  diagnosticCounts: diagnosticCounts,
);

CloudSyncSemanticPullReport _report(
  DateTime timestamp, {
  int outboxCountAfter = 0,
  int pageLimit = 4,
  int changeLimit = 50,
  int chatFetched = 1,
  Map<String, int>? chatDiagnosticCounts,
}) => CloudSyncSemanticPullReport(
  timestampUtc: timestamp,
  platform: 'windows',
  architecture: 'arm64',
  buildCommit: 'test-commit',
  pageLimit: pageLimit,
  changeLimit: changeLimit,
  outboxCountBefore: 0,
  outboxCountAfter: outboxCountAfter,
  zones: [
    _zone(
      'chats',
      fetched: chatFetched,
      diagnosticCounts:
          chatDiagnosticCounts ??
          const {'canonical_chat_relation_unavailable': 1, 'native_ready': 1},
    ),
    _zone('messages'),
    _zone('attachments'),
  ],
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
    expect(json['schemaVersion'], 3);
    expect(json['tombstoneSemanticDeletesEnabled'], isFalse);
    expect(json['tombstoneReadOnlyAcknowledgementsEnabled'], isTrue);
    expect(json, isNot(contains('tombstonesEnabled')));
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

  test('accepts the four-page 200-record contract', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    await writer.write(
      _report(
        DateTime.utc(2026, 8, 29, 1, 2, 3),
        pageLimit: 4,
        changeLimit: 50,
        chatFetched: 200,
        chatDiagnosticCounts: const {'native_ready': 1},
      ),
    );
  });

  test('rejects non-four page limits and counters above 200', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    for (final candidate in [
      _report(DateTime.utc(2026, 8, 29, 1, 2, 3), pageLimit: 1),
      _report(
        DateTime.utc(2026, 8, 29, 1, 2, 4),
        pageLimit: 4,
        changeLimit: 50,
        chatFetched: 201,
      ),
    ]) {
      await expectLater(
        writer.write(candidate),
        throwsA(isA<CloudSyncSemanticPullReportFileException>()),
      );
    }
  });

  test('bounds retry and quarantine subtype counters at 200', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final invalidZones = [
      _zone('chats', fetched: 201),
      _zone('chats', applied: 201),
      _zone('chats', deferred: 201),
      _zone('chats', quarantined: 201),
      _zone('chats', retried: 201),
      _zone('chats', preflightQuarantined: 201),
      _zone('chats', preflightUnsupportedRecordType: 201),
      _zone('chats', preflightMalformedMetadata: 201),
      _zone('chats', preflightOversizedRecord: 201),
      _zone('chats', preflightInvalidChangeShape: 201),
      _zone('chats', preflightUnknown: 201),
      _zone('chats', startupQuarantined: 201),
      _zone('chats', postFetchQuarantined: 201),
      _zone('chats', tombstoneQuarantined: 201),
      _zone('chats', tombstoneReadOnlyAcknowledged: 201),
      _zone('chats', semanticUnsupportedServiceQuarantined: 201),
      _zone('chats', semanticStageQuarantined: 201),
    ];
    for (var index = 0; index < invalidZones.length; index++) {
      final zone = invalidZones[index];
      await expectLater(
        writer.write(
          CloudSyncSemanticPullReport(
            timestampUtc: DateTime.utc(2026, 8, 29, 1, 3, index),
            platform: 'windows',
            architecture: 'arm64',
            buildCommit: 'test-commit',
            pageLimit: 4,
            changeLimit: 50,
            outboxCountBefore: 0,
            outboxCountAfter: 0,
            zones: [zone, _zone('messages'), _zone('attachments')],
          ),
        ),
        throwsA(isA<CloudSyncSemanticPullReportFileException>()),
      );
    }
  });

  test('accepts diagnostic counts above the one-page fetch limit', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );

    final file = await writer.write(
      _report(
        DateTime.utc(2026, 8, 29, 1, 2, 3),
        chatDiagnosticCounts: const {'projection_repaired_chat_alias': 74},
      ),
    );
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final zones = json['zones'] as List<dynamic>;
    expect(
      (zones.first as Map<String, dynamic>)['semanticDiagnostics'],
      <String, dynamic>{'projection_repaired_chat_alias': 74},
    );
  });

  test('rejects non-positive semantic diagnostic counts', () {
    for (final count in <int>[0, -1]) {
      expect(
        () => _zone(
          'chats',
          diagnosticCounts: <String, int>{'native_ready': count},
        ),
        throwsArgumentError,
      );
    }
  });

  test('rejects a corrupt semantic diagnostic aggregate', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );

    await expectLater(
      writer.write(
        _report(
          DateTime.utc(2026, 8, 29, 1, 2, 3),
          chatDiagnosticCounts: const {
            'projection_repaired_chat_alias':
                CloudSyncSemanticPullReportFileWriter.maximumDiagnosticCount +
                1,
          },
        ),
      ),
      throwsA(
        isA<CloudSyncSemanticPullReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_semantic_report_zone_invalid',
        ),
      ),
    );
  });

  test('rejects an oversized semantic diagnostic map', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final suffix = List<String>.filled(70, 'x').join();
    final diagnostics = <String, int>{
      for (var index = 0; index < 5000; index++)
        'diagnostic_${index.toString().padLeft(4, '0')}_$suffix': 1,
    };

    await expectLater(
      writer.write(
        _report(
          DateTime.utc(2026, 8, 29, 1, 2, 3),
          chatDiagnosticCounts: diagnostics,
        ),
      ),
      throwsA(
        isA<CloudSyncSemanticPullReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_semantic_report_too_large',
        ),
      ),
    );
  });

  test('rejects a report directory outside the trusted root', () {
    expect(
      () => CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: root.parent.path,
        trustedStorageRoot: root.path,
      ),
      throwsA(
        isA<CloudSyncSemanticPullReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_semantic_report_directory_invalid',
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
