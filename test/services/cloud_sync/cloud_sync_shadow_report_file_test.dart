import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

void main() {
  late Directory temporaryDirectory;
  late CloudShadowJournalBudget journalBudget;

  setUp(() {
    journalBudget = CloudShadowJournalBudget();
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'cloud-sync-shadow-report-',
    );
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  CloudSyncShadowReport report({
    String runId = 'obcs2-shadow-20260802-1',
    int messageFetched = 2,
    int messageJournaled = 2,
    int messageEstimatedBytes = 2048,
  }) {
    return CloudSyncShadowReport(
      runId: runId,
      correlationTag: 'ephemeral-tag',
      timestampUtc: DateTime.utc(2026, 8, 2),
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'test-build',
      legacySyncEnabled: false,
      pageLimit: 1,
      changeLimit: 50,
      tripwiresArmed: true,
      outboxCountBefore: 0,
      outboxCountAfter: 0,
      zones: [
        const CloudSyncShadowZoneReport(
          zoneLabel: 'chats',
          status: CloudSyncRunStatus.completed,
          fetched: 0,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 3,
        ),
        CloudSyncShadowZoneReport(
          zoneLabel: 'messages',
          status: CloudSyncRunStatus.completed,
          fetched: messageFetched,
          journaled: messageJournaled,
          rejected: 0,
          estimatedBytes: messageEstimatedBytes,
          elapsedMilliseconds: 12,
        ),
        const CloudSyncShadowZoneReport(
          zoneLabel: 'attachments',
          status: CloudSyncRunStatus.completed,
          fetched: 0,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 4,
        ),
        const CloudSyncShadowZoneReport(
          zoneLabel: 'message updates',
          status: CloudSyncRunStatus.completed,
          fetched: 0,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 5,
        ),
        const CloudSyncShadowZoneReport(
          zoneLabel: 'recoverable deletes',
          status: CloudSyncRunStatus.completed,
          fetched: 0,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 6,
        ),
        const CloudSyncShadowZoneReport(
          zoneLabel: 'scheduled messages',
          status: CloudSyncRunStatus.completed,
          fetched: 0,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 7,
        ),
        const CloudSyncShadowZoneReport(
          zoneLabel: 'chat1 manatee',
          status: CloudSyncRunStatus.completed,
          fetched: 0,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 8,
        ),
      ],
    );
  }

  test('writes only the allowlisted redacted report contract', () async {
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
    );

    final file = await writer.write(report());
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;

    expect(decoded['runId'], 'obcs2-shadow-20260802-1');
    expect(decoded['mode'], 'manual-read-only');
    expect(decoded['automaticTriggersEnabled'], isFalse);
    expect(decoded, isNot(contains('accountFingerprint')));
    expect(decoded, isNot(contains('continuationToken')));
    expect(decoded, isNot(contains('recordId')));
    expect(
      temporaryDirectory.listSync().whereType<File>().map(
        (entry) => entry.path,
      ),
      everyElement(endsWith('.json')),
    );
  });

  test('will not overwrite an existing report', () async {
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
    );
    await writer.write(report());

    await expectLater(
      writer.write(report()),
      throwsA(
        isA<CloudSyncShadowReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_report_already_exists',
        ),
      ),
    );
  });

  test('retains a bounded number of owned reports', () async {
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
      maximumRetainedReports: 2,
    );
    final first = await writer.write(report(runId: 'obcs2-shadow-1'));
    await first.setLastModified(DateTime.utc(2026, 8, 2, 1));
    final second = await writer.write(report(runId: 'obcs2-shadow-2'));
    await second.setLastModified(DateTime.utc(2026, 8, 2, 2));
    await writer.write(report(runId: 'obcs2-shadow-3'));

    final names = temporaryDirectory
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .toSet();
    expect(names, {'obcs2-shadow-2.json', 'obcs2-shadow-3.json'});
  });

  test('retention never deletes unrelated files', () async {
    final unrelated = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}notes.txt',
    )..writeAsStringSync('preserve');
    final unrelatedJson = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}notes.json',
    )..writeAsStringSync('{"preserve":true}');
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
      maximumRetainedReports: 1,
    );
    await writer.write(report(runId: 'obcs2-shadow-1'));
    await writer.write(report(runId: 'obcs2-shadow-2'));

    expect(unrelated.readAsStringSync(), 'preserve');
    expect(unrelatedJson.readAsStringSync(), '{"preserve":true}');
    expect(
      temporaryDirectory.listSync().whereType<File>().where(
        (file) =>
            file.path.contains('obcs2-shadow-') && file.path.endsWith('.json'),
      ),
      hasLength(1),
    );
  });

  test('reclaims only old writer-owned temporary files', () async {
    final now = DateTime.utc(2026, 8, 2, 12);
    final oldOwned = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      '.obcs2-shadow-old.0123456789abcdef01234567.tmp',
    )..writeAsStringSync('incomplete');
    final recentOwned = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      '.obcs2-shadow-recent.0123456789abcdef01234567.tmp',
    )..writeAsStringSync('active');
    final unrelatedTemporary = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}.unrelated.tmp',
    )..writeAsStringSync('preserve');
    oldOwned.setLastModifiedSync(now.subtract(const Duration(days: 2)));
    recentOwned.setLastModifiedSync(now.subtract(const Duration(hours: 1)));

    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
      now: () => now,
    );
    await writer.write(report(runId: 'obcs2-shadow-cleanup'));

    expect(oldOwned.existsSync(), isFalse);
    expect(recentOwned.existsSync(), isTrue);
    expect(unrelatedTemporary.readAsStringSync(), 'preserve');
  });

  test(
    'rejects a report directory redirected outside trusted storage',
    () async {
      final outside = Directory.systemTemp.createTempSync(
        'cloud-sync-shadow-outside-',
      );
      final linkedReports = Link(
        '${temporaryDirectory.path}${Platform.pathSeparator}reports-link',
      );
      try {
        try {
          await linkedReports.create(outside.path);
        } on FileSystemException {
          // Some Windows hosts do not permit symlink creation. Linux CI and
          // developer-enabled Windows hosts exercise the rejection path.
          return;
        }
        final writer = CloudSyncShadowReportFileWriter(
          privateReportDirectory: linkedReports.path,
          trustedStorageRoot: temporaryDirectory.path,
          journalBudget: journalBudget,
        );

        await expectLater(
          writer.write(report(runId: 'obcs2-shadow-redirected')),
          throwsA(
            isA<CloudSyncShadowReportFileException>().having(
              (error) => error.safeCode,
              'safeCode',
              'cloud_sync_report_directory_unsafe',
            ),
          ),
        );
        expect(outside.listSync(), isEmpty);
      } finally {
        if (await linkedReports.exists()) await linkedReports.delete();
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      }
    },
  );

  test('rejects traversal and secret-bearing run identifiers', () async {
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
    );

    for (final invalid in [
      '../outside',
      r'..\outside',
      'raw-account@example.com',
      'contains whitespace',
      'shadow-missing-owned-prefix',
      '',
    ]) {
      await expectLater(
        writer.write(report(runId: invalid)),
        throwsA(
          isA<CloudSyncShadowReportFileException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloud_sync_report_run_id_invalid',
          ),
        ),
      );
    }
    expect(temporaryDirectory.listSync(), isEmpty);
  });

  test('rejects non-allowlisted report strings before writing', () async {
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
    );
    final unsafe = CloudSyncShadowReport(
      runId: 'obcs2-shadow-safe-name',
      correlationTag: 'ephemeral-tag',
      timestampUtc: DateTime.utc(2026, 8, 2),
      platform: 'raw-account@example.com',
      architecture: 'arm64',
      buildCommit: 'test-build',
      legacySyncEnabled: false,
      pageLimit: 1,
      changeLimit: 50,
      tripwiresArmed: true,
      outboxCountBefore: 0,
      outboxCountAfter: 0,
      zones: report().zones,
    );

    await expectLater(
      writer.write(unsafe),
      throwsA(
        isA<CloudSyncShadowReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_report_metadata_invalid',
        ),
      ),
    );
    expect(temporaryDirectory.listSync(), isEmpty);
  });

  test('rejects an incomplete zone set', () async {
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
    );
    final invalid = CloudSyncShadowReport(
      runId: 'obcs2-shadow-invalid-counts',
      correlationTag: 'ephemeral-tag',
      timestampUtc: DateTime.utc(2026, 8, 2),
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'test-build',
      legacySyncEnabled: false,
      pageLimit: 1,
      changeLimit: 50,
      tripwiresArmed: true,
      outboxCountBefore: 0,
      outboxCountAfter: 0,
      zones: const [
        CloudSyncShadowZoneReport(
          zoneLabel: 'messages',
          status: CloudSyncRunStatus.completed,
          fetched: 51,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 1,
        ),
      ],
    );

    await expectLater(
      writer.write(invalid),
      throwsA(
        isA<CloudSyncShadowReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_report_zone_count_invalid',
        ),
      ),
    );
  });

  test('rejects impossible zone counters', () async {
    final writer = CloudSyncShadowReportFileWriter(
      privateReportDirectory: temporaryDirectory.path,
      journalBudget: journalBudget,
    );
    final validZones = report().zones;
    final invalid = CloudSyncShadowReport(
      runId: 'obcs2-shadow-invalid-counter',
      correlationTag: 'ephemeral-tag',
      timestampUtc: DateTime.utc(2026, 8, 2),
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'test-build',
      legacySyncEnabled: false,
      pageLimit: 1,
      changeLimit: 50,
      tripwiresArmed: true,
      outboxCountBefore: 0,
      outboxCountAfter: 0,
      zones: [
        validZones.first,
        const CloudSyncShadowZoneReport(
          zoneLabel: 'messages',
          status: CloudSyncRunStatus.completed,
          fetched: 51,
          journaled: 0,
          rejected: 0,
          estimatedBytes: 0,
          elapsedMilliseconds: 1,
        ),
        ...validZones.skip(2),
      ],
    );

    await expectLater(
      writer.write(invalid),
      throwsA(
        isA<CloudSyncShadowReportFileException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_report_zone_counter_invalid',
        ),
      ),
    );
  });

  test(
    'accepts cumulative journal usage within the configured budget',
    () async {
      final budget = CloudShadowJournalBudget(
        maximumEntriesPerScope: 512,
        maximumEstimatedBytesPerScope: 8 * 1024 * 1024,
        maximumPendingAge: const Duration(hours: 24),
      );
      final writer = CloudSyncShadowReportFileWriter(
        privateReportDirectory: temporaryDirectory.path,
        journalBudget: budget,
      );

      final file = await writer.write(
        report(
          runId: 'obcs2-shadow-cumulative-journal',
          messageFetched: 50,
          messageJournaled: 512,
          messageEstimatedBytes: 8 * 1024 * 1024,
        ),
      );

      expect(await file.exists(), isTrue);
    },
  );

  test(
    'rejects cumulative journal entries beyond the configured budget',
    () async {
      final budget = CloudShadowJournalBudget(maximumEntriesPerScope: 512);
      final writer = CloudSyncShadowReportFileWriter(
        privateReportDirectory: temporaryDirectory.path,
        journalBudget: budget,
      );

      await expectLater(
        writer.write(
          report(
            runId: 'obcs2-shadow-journal-over-budget',
            messageFetched: 0,
            messageJournaled: 513,
          ),
        ),
        throwsA(
          isA<CloudSyncShadowReportFileException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloud_sync_report_zone_counter_invalid',
          ),
        ),
      );
    },
  );

  test(
    'rejects cumulative journal bytes beyond the configured budget',
    () async {
      final budget = CloudShadowJournalBudget(
        maximumEstimatedBytesPerScope: 8 * 1024 * 1024,
      );
      final writer = CloudSyncShadowReportFileWriter(
        privateReportDirectory: temporaryDirectory.path,
        journalBudget: budget,
      );

      await expectLater(
        writer.write(
          report(
            runId: 'obcs2-shadow-journal-bytes-over-budget',
            messageFetched: 0,
            messageJournaled: 0,
            messageEstimatedBytes: 8 * 1024 * 1024 + 1,
          ),
        ),
        throwsA(
          isA<CloudSyncShadowReportFileException>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloud_sync_report_zone_bytes_invalid',
          ),
        ),
      );
    },
  );
}
