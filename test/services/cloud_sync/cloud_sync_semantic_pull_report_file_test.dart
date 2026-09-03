import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
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
  int retainedUnprojected = 0,
  int semanticUnsupportedServiceQuarantined = 0,
  int semanticStageQuarantined = 1,
  int retried = 0,
  int elapsedMilliseconds = 5,
  CloudSyncRunStatus status = CloudSyncRunStatus.completed,
  CloudFailureCategory? failureCategory,
  String? failureSafeCode,
  CloudSyncSkipReason? skipReason,
  bool observedEmptyTerminalRead = false,
  int projectionExamined = 0,
  int projectionRetained = 0,
  int projectionBatches = 0,
  Map<String, int> diagnosticCounts = const {
    'canonical_chat_relation_unavailable': 1,
    'native_ready': 1,
  },
}) => CloudSyncSemanticPullZoneReport(
  zoneLabel: label,
  status: status,
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
  retainedUnprojected: retainedUnprojected,
  semanticUnsupportedServiceQuarantined: semanticUnsupportedServiceQuarantined,
  semanticStageQuarantined: semanticStageQuarantined,
  retried: retried,
  elapsedMilliseconds: elapsedMilliseconds,
  observedEmptyTerminalRead: observedEmptyTerminalRead,
  projectionExamined: projectionExamined,
  projectionRetained: projectionRetained,
  projectionBatches: projectionBatches,
  failureCategory: failureCategory,
  failureSafeCode: failureSafeCode,
  skipReason: skipReason,
  diagnosticCounts: diagnosticCounts,
);

CloudSyncSemanticPullZoneReport _cleanZone(
  String label, {
  CloudSyncRunStatus status = CloudSyncRunStatus.completed,
  CloudFailureCategory? failureCategory,
  String? failureSafeCode,
  CloudSyncSkipReason? skipReason,
  int fetched = 0,
  int applied = 0,
  bool observedEmptyTerminalRead = true,
  int retainedUnprojected = 0,
  int deferred = 0,
  int quarantined = 0,
  int preflightQuarantined = 0,
  int preflightUnsupportedRecordType = 0,
  int preflightMalformedMetadata = 0,
  int preflightOversizedRecord = 0,
  int preflightInvalidChangeShape = 0,
  int preflightUnknown = 0,
  int startupQuarantined = 0,
  int postFetchQuarantined = 0,
  int tombstoneQuarantined = 0,
  int tombstoneReadOnlyAcknowledged = 0,
  int semanticUnsupportedServiceQuarantined = 0,
  int semanticStageQuarantined = 0,
  int retried = 0,
  int elapsedMilliseconds = 5,
  int projectionExamined = 0,
  int projectionRetained = 0,
  int projectionBatches = 0,
  Map<String, int> diagnosticCounts = const {
    'retained_backlog_summary_ready': 1,
  },
}) => _zone(
  label,
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
  retainedUnprojected: retainedUnprojected,
  semanticUnsupportedServiceQuarantined: semanticUnsupportedServiceQuarantined,
  semanticStageQuarantined: semanticStageQuarantined,
  retried: retried,
  elapsedMilliseconds: elapsedMilliseconds,
  status: status,
  failureCategory: failureCategory,
  failureSafeCode: failureSafeCode,
  skipReason: skipReason,
  observedEmptyTerminalRead: observedEmptyTerminalRead,
  projectionExamined: projectionExamined,
  projectionRetained: projectionRetained,
  projectionBatches: projectionBatches,
  diagnosticCounts: diagnosticCounts,
);

CloudSyncSemanticPullReport _report(
  DateTime timestamp, {
  int outboxCountAfter = 0,
  int pageLimit = 4,
  int changeLimit = 50,
  int chatFetched = 1,
  int chatRetainedUnprojected = 0,
  Map<String, int>? chatDiagnosticCounts,
  Iterable<CloudSyncSemanticPullZoneReport>? zoneReports,
  CloudSyncSemanticReportMode mode =
      CloudSyncSemanticReportMode.readOnlyCloudKit,
}) => CloudSyncSemanticPullReport(
  timestampUtc: timestamp,
  platform: 'windows',
  architecture: 'arm64',
  buildCommit: 'test-commit',
  pageLimit: pageLimit,
  changeLimit: changeLimit,
  outboxCountBefore: 0,
  outboxCountAfter: outboxCountAfter,
  mode: mode,
  zones:
      zoneReports ??
      [
        _zone(
          'chats',
          fetched: chatFetched,
          retainedUnprojected: chatRetainedUnprojected,
          diagnosticCounts:
              chatDiagnosticCounts ??
              const {
                'canonical_chat_relation_unavailable': 1,
                'native_ready': 1,
              },
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
      _report(DateTime.utc(2026, 8, 29, 1, 2, 3), chatRetainedUnprojected: 3),
    );

    expect(file.path, contains('obcs2-semantic-'));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['schemaVersion'], 6);
    expect(json['tombstoneSemanticDeletesEnabled'], isFalse);
    expect(json['tombstoneReadOnlyAcknowledgementsEnabled'], isTrue);
    expect(json['retainedUnprojectedEvidencePreserved'], isTrue);
    expect(json, isNot(contains('tombstonesEnabled')));
    final zones = json['zones'] as List<dynamic>;
    expect((zones.first as Map<String, dynamic>)['retainedUnprojected'], 3);
    expect(
      (zones.first as Map<String, dynamic>)['observedEmptyTerminalRead'],
      isFalse,
    );
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

  test('serializes both schema-6 report modes', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final remote = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 3),
      zoneReports: [
        _cleanZone('chats'),
        _cleanZone('messages'),
        _cleanZone('attachments'),
      ],
    );
    final sweep = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 4),
      mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
      zoneReports: [
        for (final label in const ['chats', 'messages', 'attachments'])
          _cleanZone(
            label,
            applied: 2,
            observedEmptyTerminalRead: false,
            projectionExamined: 3,
            projectionRetained: 1,
            projectionBatches: 1,
          ),
      ],
    );

    final remoteJson =
        jsonDecode(await (await writer.write(remote)).readAsString())
            as Map<String, dynamic>;
    final sweepJson =
        jsonDecode(await (await writer.write(sweep)).readAsString())
            as Map<String, dynamic>;

    expect(remoteJson['schemaVersion'], 6);
    expect(
      remoteJson['mode'],
      CloudSyncSemanticReportMode.readOnlyCloudKit.wireName,
    );
    expect(sweepJson['schemaVersion'], 6);
    expect(
      sweepJson['mode'],
      CloudSyncSemanticReportMode.retainedProjectionSweep.wireName,
    );
  });

  test('remote reports reject nonzero projection counters', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final invalidZones = <String, CloudSyncSemanticPullZoneReport>{
      'projectionExamined': _cleanZone('messages', projectionExamined: 1),
      'projectionRetained': _cleanZone(
        'messages',
        projectionExamined: 1,
        projectionRetained: 1,
      ),
      'projectionBatches': _cleanZone('messages', projectionBatches: 1),
    };

    for (final entry in invalidZones.entries) {
      await expectLater(
        writer.write(
          _report(
            DateTime.utc(
              2026,
              8,
              29,
              1,
              3,
              invalidZones.keys.toList().indexOf(entry.key),
            ),
            zoneReports: [
              _cleanZone('chats'),
              entry.value,
              _cleanZone('attachments'),
            ],
          ),
        ),
        throwsA(
          isA<CloudSyncSemanticPullReportFileException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloud_sync_semantic_report_zone_invalid',
          ),
        ),
        reason: entry.key,
      );
    }
  });

  test(
    'projection-sweep reports reject fetch and terminal-read evidence',
    () async {
      final writer = CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: reports.path,
        trustedStorageRoot: root.path,
      );
      CloudSyncSemanticPullZoneReport validSweepZone(String label) =>
          _cleanZone(
            label,
            applied: 1,
            observedEmptyTerminalRead: false,
            projectionExamined: 1,
            projectionBatches: 1,
          );
      final invalidZones = <String, CloudSyncSemanticPullZoneReport>{
        'fetched': _cleanZone(
          'messages',
          fetched: 1,
          applied: 1,
          observedEmptyTerminalRead: false,
          projectionExamined: 1,
          projectionBatches: 1,
        ),
        'terminal-read': _cleanZone(
          'messages',
          applied: 1,
          observedEmptyTerminalRead: true,
          projectionExamined: 1,
          projectionBatches: 1,
        ),
      };

      for (final entry in invalidZones.entries) {
        final candidate = _report(
          DateTime.utc(
            2026,
            8,
            29,
            1,
            4,
            invalidZones.keys.toList().indexOf(entry.key),
          ),
          mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
          zoneReports: [
            validSweepZone('chats'),
            entry.value,
            validSweepZone('attachments'),
          ],
        );
        expect(candidate.safeToPersistProjectionSweep, isFalse);
        await expectLater(
          writer.write(candidate),
          throwsA(
            isA<CloudSyncSemanticPullReportFileException>().having(
              (error) => error.safeCode,
              'safeCode',
              'cloud_sync_semantic_report_zone_invalid',
            ),
          ),
          reason: entry.key,
        );
      }
    },
  );

  test(
    'persists a measured 40-minute projection sweep within its batch budget',
    () async {
      final writer = CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: reports.path,
        trustedStorageRoot: root.path,
      );
      final candidate = _report(
        DateTime.utc(2026, 8, 29, 1, 4, 30),
        mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
        zoneReports: [
          _cleanZone('chats', observedEmptyTerminalRead: false),
          _cleanZone(
            'messages',
            applied: 35,
            observedEmptyTerminalRead: false,
            projectionExamined: 35,
            projectionBatches: 35,
            elapsedMilliseconds: const Duration(minutes: 40).inMilliseconds,
          ),
          _cleanZone('attachments', observedEmptyTerminalRead: false),
        ],
      );

      expect(candidate.safeToPersistProjectionSweep, isTrue);
      final file = await writer.write(candidate);
      expect(await file.exists(), isTrue);
    },
  );

  test('rejects projection elapsed time beyond its batch budget', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final candidate = _report(
      DateTime.utc(2026, 8, 29, 1, 4, 31),
      mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
      zoneReports: [
        _cleanZone('chats', observedEmptyTerminalRead: false),
        _cleanZone(
          'messages',
          applied: 1,
          observedEmptyTerminalRead: false,
          projectionExamined: 1,
          projectionBatches: 1,
          elapsedMilliseconds: const Duration(minutes: 33).inMilliseconds,
        ),
        _cleanZone('attachments', observedEmptyTerminalRead: false),
      ],
    );

    await expectLater(
      writer.write(candidate),
      throwsA(
        isA<CloudSyncSemanticPullReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_semantic_report_zone_invalid',
        ),
      ),
    );
  });

  test(
    'projection sweep enforces examined equals applied plus retained',
    () async {
      final writer = CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: reports.path,
        trustedStorageRoot: root.path,
      );
      final candidate = _report(
        DateTime.utc(2026, 8, 29, 1, 5),
        mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
        zoneReports: [
          _cleanZone(
            'chats',
            applied: 1,
            observedEmptyTerminalRead: false,
            projectionExamined: 3,
            projectionRetained: 1,
            projectionBatches: 1,
          ),
          for (final label in const ['messages', 'attachments'])
            _cleanZone(
              label,
              applied: 1,
              observedEmptyTerminalRead: false,
              projectionExamined: 1,
              projectionBatches: 1,
            ),
        ],
      );

      expect(candidate.safeToPersistProjectionSweep, isFalse);
      await expectLater(
        writer.write(candidate),
        throwsA(
          isA<CloudSyncSemanticPullReportFileException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloud_sync_semantic_report_zone_invalid',
          ),
        ),
      );
    },
  );

  test('retained-save projection is complete when only tombstones remain', () {
    final candidate = _report(
      DateTime.utc(2026, 8, 29, 1, 6),
      mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
      zoneReports: [
        _cleanZone('chats', observedEmptyTerminalRead: false),
        _cleanZone(
          'messages',
          observedEmptyTerminalRead: false,
          retainedUnprojected: 3,
          tombstoneReadOnlyAcknowledged: 3,
        ),
        _cleanZone('attachments', observedEmptyTerminalRead: false),
      ],
    );

    expect(candidate.projectionComplete, isFalse);
    expect(candidate.hasRetainedSaveBacklog, isFalse);
    expect(candidate.retainedSaveProjectionComplete, isTrue);
    expect(candidate.safeToPersistProjectionSweep, isTrue);
  });

  test(
    'out-of-scope saves finish iMessage projection but not account projection',
    () {
      final candidate = _report(
        DateTime.utc(2026, 8, 29, 1, 6, 1),
        mode: CloudSyncSemanticReportMode.retainedProjectionSweep,
        zoneReports: [
          _cleanZone('chats', observedEmptyTerminalRead: false),
          _cleanZone(
            'messages',
            observedEmptyTerminalRead: false,
            retainedUnprojected: 1,
            diagnosticCounts: const {
              'retained_backlog_summary_ready': 1,
              'retained_backlog_total': 1,
              'retained_backlog_saves': 1,
              'retained_backlog_out_of_scope_services': 1,
              'retained_backlog_failure_out_of_scope_service': 1,
            },
          ),
          _cleanZone('attachments', observedEmptyTerminalRead: false),
        ],
      );

      expect(candidate.projectionComplete, isFalse);
      expect(candidate.hasRetainedSaveBacklog, isFalse);
      expect(candidate.retainedSaveProjectionComplete, isTrue);
      expect(candidate.safeToPersistProjectionSweep, isTrue);
    },
  );

  test(
    'persists a content-free report whose read-only outbox tripwire moved',
    () async {
      final writer = CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: reports.path,
        trustedStorageRoot: root.path,
      );
      final candidate = _report(
        DateTime.utc(2026, 8, 29, 1, 2, 3),
        outboxCountAfter: 1,
      );

      final file = await writer.write(candidate);
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(json['outboxCountAfter'], 1);
      expect(candidate.safeToContinueDrain, isFalse);
    },
  );

  test(
    'persists bounded duplicate-zone evidence for fail-closed diagnosis',
    () async {
      final writer = CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: reports.path,
        trustedStorageRoot: root.path,
      );
      final candidate = _report(
        DateTime.utc(2026, 8, 29, 1, 2, 4),
        zoneReports: [
          _cleanZone('chats'),
          _cleanZone('messages'),
          _cleanZone('messages'),
        ],
      );

      final file = await writer.write(candidate);
      expect(await file.exists(), isTrue);
      expect(candidate.hasExactThreeZoneStructure, isFalse);
      expect(candidate.safeToContinueDrain, isFalse);
    },
  );

  test(
    'rejects terminal-empty evidence when fetched rows are nonzero',
    () async {
      final writer = CloudSyncSemanticPullReportFileWriter(
        privateReportDirectory: reports.path,
        trustedStorageRoot: root.path,
      );

      await expectLater(
        writer.write(
          _report(
            DateTime.utc(2026, 8, 29, 1, 2, 3),
            zoneReports: [
              _zone('chats', fetched: 1, observedEmptyTerminalRead: true),
              _zone('messages'),
              _zone('attachments'),
            ],
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
    },
  );

  test('evaluates the three-zone drain and projection gates', () {
    final clean = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 3),
      zoneReports: [
        _cleanZone('chats'),
        _cleanZone('messages'),
        _cleanZone('attachments'),
      ],
    );
    expect(clean.hasExactThreeZoneStructure, isTrue);
    expect(clean.allZonesObservedEmptyTerminalRead, isTrue);
    expect(clean.safeToContinueDrain, isTrue);
    expect(clean.projectionComplete, isTrue);

    final retainedProjection = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 4),
      zoneReports: [
        _cleanZone('chats'),
        _cleanZone(
          'messages',
          status: CloudSyncRunStatus.degraded,
          failureCategory: CloudFailureCategory.dependency,
          failureSafeCode: 'retained_projection_incomplete',
          retainedUnprojected: 1,
        ),
        _cleanZone('attachments'),
      ],
    );
    expect(retainedProjection.hasExactThreeZoneStructure, isTrue);
    expect(retainedProjection.allZonesObservedEmptyTerminalRead, isTrue);
    expect(retainedProjection.safeToContinueDrain, isTrue);
    expect(retainedProjection.projectionComplete, isFalse);

    final mixedDegraded = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 5),
      zoneReports: [
        _cleanZone('chats'),
        _cleanZone(
          'messages',
          status: CloudSyncRunStatus.degraded,
          failureCategory: CloudFailureCategory.network,
          failureSafeCode: 'network',
        ),
        _cleanZone('attachments'),
      ],
    );
    expect(mixedDegraded.hasExactThreeZoneStructure, isTrue);
    expect(mixedDegraded.safeToContinueDrain, isFalse);

    final quarantined = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 6),
      zoneReports: [
        _cleanZone('chats'),
        _zone('messages', quarantined: 1),
        _cleanZone('attachments'),
      ],
    );
    expect(quarantined.hasExactThreeZoneStructure, isTrue);
    expect(quarantined.safeToContinueDrain, isFalse);

    final outboxMoved = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 7),
      outboxCountAfter: 1,
      zoneReports: [
        _cleanZone('chats'),
        _cleanZone('messages'),
        _cleanZone('attachments'),
      ],
    );
    expect(outboxMoved.hasExactThreeZoneStructure, isTrue);
    expect(outboxMoved.safeToContinueDrain, isFalse);

    final invalidStructure = _report(
      DateTime.utc(2026, 8, 29, 1, 2, 8),
      zoneReports: [
        _cleanZone('chats'),
        _cleanZone('chats'),
        _cleanZone('attachments'),
      ],
    );
    expect(invalidStructure.hasExactThreeZoneStructure, isFalse);
    expect(invalidStructure.allZonesObservedEmptyTerminalRead, isFalse);
    expect(invalidStructure.safeToContinueDrain, isFalse);
    expect(invalidStructure.projectionComplete, isFalse);
  });

  test('admits only clean transient transport failures for session retry', () {
    CloudSyncSemanticPullReport transient(
      CloudFailureCategory category,
      String safeCode, {
      int retried = 0,
    }) => _report(
      DateTime.utc(2026, 9, 3),
      zoneReports: [
        _cleanZone('chats'),
        _cleanZone(
          'messages',
          status: CloudSyncRunStatus.degraded,
          failureCategory: category,
          failureSafeCode: safeCode,
          observedEmptyTerminalRead: false,
          retried: retried,
        ),
        _cleanZone('attachments'),
      ],
    );

    expect(
      transient(
        CloudFailureCategory.server,
        'native_auth_unavailable',
      ).unambiguousTransientTransportFailure,
      (category: CloudFailureCategory.server, safeCode: 'cloudkit_server'),
    );
    expect(
      transient(
        CloudFailureCategory.network,
        'http_timeout',
      ).unambiguousTransientTransportFailure,
      (category: CloudFailureCategory.network, safeCode: 'http_timeout'),
    );
    expect(
      transient(
        CloudFailureCategory.throttled,
        'http_throttled',
      ).unambiguousTransientTransportFailure,
      (category: CloudFailureCategory.throttled, safeCode: 'http_throttled'),
    );

    for (final category in CloudFailureCategory.values.where(
      (value) =>
          value != CloudFailureCategory.network &&
          value != CloudFailureCategory.throttled &&
          value != CloudFailureCategory.server,
    )) {
      expect(
        transient(
          category,
          'cloud_sync_unknown_failure',
        ).unambiguousTransientTransportFailure,
        isNull,
        reason: category.name,
      );
    }
    expect(
      transient(
        CloudFailureCategory.server,
        'http_server',
        retried: 1,
      ).unambiguousTransientTransportFailure,
      isNull,
    );
  });

  test('rejects every unsafe zone condition independently', () {
    final unsafeZones = <String, CloudSyncSemanticPullZoneReport>{
      'completed-with-failure': _cleanZone(
        'messages',
        failureCategory: CloudFailureCategory.network,
        failureSafeCode: 'network',
      ),
      'skip': _cleanZone(
        'messages',
        skipReason: CloudSyncSkipReason.pullBackoffActive,
      ),
      'deferred': _cleanZone('messages', deferred: 1),
      'quarantined': _cleanZone('messages', quarantined: 1),
      'preflight-total': _cleanZone('messages', preflightQuarantined: 1),
      'preflight-unsupported': _cleanZone(
        'messages',
        preflightUnsupportedRecordType: 1,
      ),
      'preflight-malformed': _cleanZone(
        'messages',
        preflightMalformedMetadata: 1,
      ),
      'preflight-oversized': _cleanZone(
        'messages',
        preflightOversizedRecord: 1,
      ),
      'preflight-shape': _cleanZone('messages', preflightInvalidChangeShape: 1),
      'preflight-unknown': _cleanZone('messages', preflightUnknown: 1),
      'startup-quarantine': _cleanZone('messages', startupQuarantined: 1),
      'post-fetch-quarantine': _cleanZone('messages', postFetchQuarantined: 1),
      'tombstone-quarantine': _cleanZone('messages', tombstoneQuarantined: 1),
      'unsupported-service': _cleanZone(
        'messages',
        semanticUnsupportedServiceQuarantined: 1,
      ),
      'semantic-stage': _cleanZone('messages', semanticStageQuarantined: 1),
      'retry': _cleanZone('messages', retried: 1),
      'generic-diagnostic': _cleanZone(
        'messages',
        diagnosticCounts: const {
          'retained_backlog_summary_ready': 1,
          'cloud_sync_unknown_failure': 1,
        },
      ),
      'invalid-diagnostic': _cleanZone(
        'messages',
        diagnosticCounts: const {
          'retained_backlog_summary_ready': 1,
          'diagnostic_code_invalid': 1,
        },
      ),
      'retained-summary-missing': _cleanZone(
        'messages',
        diagnosticCounts: const {},
      ),
      'retained-summary-unavailable': _cleanZone(
        'messages',
        diagnosticCounts: const {'retained_backlog_summary_unavailable': 1},
      ),
      'retained-summary-mismatch': _cleanZone(
        'messages',
        diagnosticCounts: const {'retained_backlog_summary_mismatch': 1},
      ),
    };

    for (final entry in unsafeZones.entries) {
      final candidate = _report(
        DateTime.utc(2026, 8, 29, 2),
        zoneReports: [
          _cleanZone('chats'),
          entry.value,
          _cleanZone('attachments'),
        ],
      );
      expect(candidate.safeToContinueDrain, isFalse, reason: entry.key);
    }
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

  test('accepts the bounded 350-record local work contract', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final boundaryZones = [
      _zone('chats', applied: 350),
      _zone('chats', deferred: 350),
      _zone('chats', quarantined: 350),
      _zone('chats', retried: 350),
      _zone('chats', preflightQuarantined: 350),
      _zone('chats', preflightUnsupportedRecordType: 350),
      _zone('chats', preflightMalformedMetadata: 350),
      _zone('chats', preflightOversizedRecord: 350),
      _zone('chats', preflightInvalidChangeShape: 350),
      _zone('chats', preflightUnknown: 350),
      _zone('chats', startupQuarantined: 350),
      _zone('chats', postFetchQuarantined: 350),
      _zone('chats', tombstoneQuarantined: 350),
      _zone('chats', tombstoneReadOnlyAcknowledged: 350),
      _zone('chats', semanticUnsupportedServiceQuarantined: 350),
      _zone('chats', semanticStageQuarantined: 350),
    ];
    for (var index = 0; index < boundaryZones.length; index++) {
      await writer.write(
        _report(
          DateTime.utc(2026, 8, 29, 1, 4, index),
          zoneReports: [
            boundaryZones[index],
            _zone('messages'),
            _zone('attachments'),
          ],
        ),
      );
    }
  });

  test('rejects non-four page limits and fetched counters above 200', () async {
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

  test('bounds local work counters at 350', () async {
    final writer = CloudSyncSemanticPullReportFileWriter(
      privateReportDirectory: reports.path,
      trustedStorageRoot: root.path,
    );
    final invalidZones = [
      _zone('chats', fetched: 201),
      _zone('chats', applied: 351),
      _zone('chats', deferred: 351),
      _zone('chats', quarantined: 351),
      _zone('chats', retried: 351),
      _zone('chats', preflightQuarantined: 351),
      _zone('chats', preflightUnsupportedRecordType: 351),
      _zone('chats', preflightMalformedMetadata: 351),
      _zone('chats', preflightOversizedRecord: 351),
      _zone('chats', preflightInvalidChangeShape: 351),
      _zone('chats', preflightUnknown: 351),
      _zone('chats', startupQuarantined: 351),
      _zone('chats', postFetchQuarantined: 351),
      _zone('chats', tombstoneQuarantined: 351),
      _zone('chats', tombstoneReadOnlyAcknowledged: 351),
      _zone('chats', semanticUnsupportedServiceQuarantined: 351),
      _zone('chats', semanticStageQuarantined: 351),
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

  test('rejects an oversized unreviewed diagnostic map before persistence', () {
    final suffix = List<String>.filled(70, 'x').join();
    final diagnostics = <String, int>{
      for (var index = 0; index < 5000; index++)
        'diagnostic_${index.toString().padLeft(4, '0')}_$suffix': 1,
    };

    expect(
      () => _report(
        DateTime.utc(2026, 8, 29, 1, 2, 3),
        chatDiagnosticCounts: diagnostics,
      ),
      throwsArgumentError,
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
