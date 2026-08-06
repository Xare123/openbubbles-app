import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('report exposes only the explicit redacted contract', () {
    const forbiddenFingerprint = '0123456789abcdef';
    final report = CloudSyncShadowReport(
      runId: 'local-random-run',
      correlationTag: 'ephemeral-run-tag',
      timestampUtc: DateTime.utc(2026, 8, 1),
      platform: 'windows',
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
          fetched: 2,
          journaled: 2,
          rejected: 0,
          estimatedBytes: 4096,
          elapsedMilliseconds: 25,
        ),
      ],
    );

    final encoded = jsonEncode(report.toJson());
    expect(encoded, contains('"correlationTag":"ephemeral-run-tag"'));
    expect(encoded, isNot(contains(forbiddenFingerprint)));
    expect(encoded, isNot(contains('token')));
    expect(encoded, isNot(contains('recordId')));
    expect(encoded, isNot(contains('etag')));
    expect(encoded, isNot(contains('ciphertext')));
    expect(report.isValidReadOnlySuccess, isTrue);
  });

  test(
    'report cannot claim success when legacy sync or tripwire is unsafe',
    () {
      CloudSyncShadowReport build({
        required bool legacySyncEnabled,
        required bool tripwiresArmed,
      }) => CloudSyncShadowReport(
        runId: 'run',
        correlationTag: 'ephemeral',
        timestampUtc: DateTime.utc(2026),
        platform: 'android',
        architecture: 'arm64',
        buildCommit: 'test',
        legacySyncEnabled: legacySyncEnabled,
        pageLimit: 1,
        changeLimit: 50,
        tripwiresArmed: tripwiresArmed,
        outboxCountBefore: 0,
        outboxCountAfter: 0,
        zones: const [
          CloudSyncShadowZoneReport(
            zoneLabel: 'messages',
            status: CloudSyncRunStatus.completed,
            fetched: 0,
            journaled: 0,
            rejected: 0,
            estimatedBytes: 0,
            elapsedMilliseconds: 1,
          ),
        ],
      );

      expect(
        build(
          legacySyncEnabled: true,
          tripwiresArmed: true,
        ).isValidReadOnlySuccess,
        isFalse,
      );
      expect(
        build(
          legacySyncEnabled: false,
          tripwiresArmed: false,
        ).isValidReadOnlySuccess,
        isFalse,
      );
    },
  );
}
