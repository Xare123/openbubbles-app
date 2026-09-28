import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_historical_import.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'cloud_sync_historical_import_controller_test.dart' as fixtures;

final class _EmptyRegistry extends HistoricalOwnershipRegistry {
  @override
  Set<String> get ownedGuids => const {};
  @override
  Set<String> get conflictGuids => const {};
}

void main() {
  final snapshot = fixtures.historicalImportTestSnapshot();
  Map<String, dynamic> input({bool execute = false}) => {
    'version': 1,
    'action': execute ? 'archive' : 'preview',
    'sourceDirectory': path.join(
      Directory.systemTemp.path,
      'qualified-alpha-fixture',
    ),
    'databaseSha256': 'd' * 64,
    'sourceLabel': 'Alpha history',
    'accountLabel': 'Example Account',
    'accountFingerprint': snapshot.account.accountFingerprint,
    'protectedStoreIdentity': snapshot.account.protectedStoreIdentity,
    'accountHandles': snapshot.manifest.accountHandles,
    'capturedAtMs': snapshot.manifest.capturedAtMs,
    'snapshotSha256': execute ? snapshot.manifest.snapshotSha256 : null,
    'maximumAssessed': 20,
    'maximumCreates': 1,
  };
  late MemoryHistoricalCursorStore cursors;
  late List<String> calls;
  late bool current;
  CloudSyncHistoricalImportPlan plan() => CloudSyncHistoricalImportPlan(
    snapshot: snapshot,
    sourceLabel: 'Alpha history',
    accountLabel: 'Example Account',
    archiveCursors: cursors,
    registry: _EmptyRegistry(),
    stillCurrent: () => current,
    validateIdentity: () async {},
    archive: (request, bytes) async {
      calls.add(request.guid);
      return (
        source: StagedHistoricalSource(
          key: request.sourceSha256,
          sha256: historicalBytesSha256(bytes),
          byteLength: bytes.length,
          guid: request.guid,
        ),
        disposition: CloudSyncHistoricalArchiveDisposition.confirmedCreate,
      );
    },
  );
  setUp(() {
    cursors = MemoryHistoricalCursorStore();
    calls = [];
    current = true;
  });

  test('request is explicit, bounded and redacts operator context', () {
    final request = CloudSyncWindowsHistoricalRequest.parse(input());
    expect(request.execute, isFalse);
    expect(request.toString(), 'CloudSyncWindowsHistoricalRequest(redacted)');
    expect(
      () => request.accountHandles.add('other@example.com'),
      throwsUnsupportedError,
    );
    expect(
      CloudSyncWindowsHistoricalRequest.parse(input(execute: true)).execute,
      isTrue,
    );
    for (final update in <Map<String, dynamic>>[
      {'action': 'send'},
      {'action': 'archive'},
      {'version': 2},
      {'sourceDirectory': '../other'},
      {'databaseSha256': 'D' * 64},
      {'accountFingerprint': 'short'},
      {'protectedStoreIdentity': 'invalid'},
      {'accountHandles': []},
      {
        'accountHandles': ['same', 'same'],
      },
      {
        'accountHandles': ['tel:+15550000000'],
      },
      {
        'accountHandles': [1],
      },
      {'sourceLabel': 'source\nchanged'},
      {'accountLabel': ''},
      {'maximumAssessed': 0},
      {'maximumAssessed': 201},
      {'maximumAssessed': 1.5},
      {'maximumCreates': 0},
      {'maximumCreates': 21},
      {'capturedAtMs': -1},
      {'extra': 'not understood'},
      {'snapshotSha256': 'a' * 64},
    ]) {
      expect(
        () => CloudSyncWindowsHistoricalRequest.parse({...input(), ...update}),
        throwsStateError,
        reason: update.keys.join(','),
      );
    }
  });

  test(
    'preview uses the real controller without any archive callback',
    () async {
      final result = await runCloudSyncWindowsHistoricalPlan(
        request: CloudSyncWindowsHistoricalRequest.parse(input()),
        prepare: () async => plan(),
      );
      expect(calls, isEmpty);
      expect(result['snapshot_sha256'], snapshot.manifest.snapshotSha256);
      expect(result['source_rows'], 3);
      expect(result['confirmed_creates_this_session'], 0);
      expect(result['scan_complete'], isFalse);
    },
  );

  test(
    'create budget drains the admitted row and resumes the same cursor',
    () async {
      final request = CloudSyncWindowsHistoricalRequest.parse(
        input(execute: true),
      );
      for (var pass = 0; pass < 2; pass++) {
        final result = await runCloudSyncWindowsHistoricalPlan(
          request: request,
          prepare: () async => plan(),
        );
        expect(result['confirmed_creates_this_session'], 1);
        expect(result['budget_paused'], isTrue);
        expect(result['scan_complete'], isFalse);
        expect(calls.length, pass + 1);
      }
      expect(calls.toSet().length, 2);
    },
  );

  test(
    'single-row budgets make durable progress through the snapshot',
    () async {
      final request = CloudSyncWindowsHistoricalRequest.parse({
        ...input(execute: true),
        'maximumAssessed': 1,
        'maximumCreates': 20,
      });
      for (var pass = 0; pass < 3; pass++) {
        final result = await runCloudSyncWindowsHistoricalPlan(
          request: request,
          prepare: () async => plan(),
        );
        expect(calls.length, pass + 1);
        expect(result['assessed_this_session'], 1);
        expect(result['budget_paused'], isTrue);
        expect(result['scan_complete'], pass == 2);
        expect(calls.toSet().length, pass + 1);
        expect(await cursors.load(), isNotNull);
      }
      expect((await cursors.load())!.done, isTrue);
      final finished = await runCloudSyncWindowsHistoricalPlan(
        request: request,
        prepare: () async => plan(),
      );
      expect(finished['assessed_this_session'], 0);
      expect(finished['confirmed_creates_this_session'], 0);
      expect(finished['scan_complete'], isTrue);
      expect(calls.length, 3);
    },
  );

  test('changed exact source or destination never reaches archive', () async {
    for (final update in <Map<String, dynamic>>[
      {'snapshotSha256': '0' * 64},
      {'accountFingerprint': 'B' * 43},
      {'protectedStoreIdentity': 'obcs2.store.${'T' * 43}'},
      {'sourceLabel': 'Other history'},
      {'accountLabel': 'Other account'},
      {'capturedAtMs': snapshot.manifest.capturedAtMs - 1},
      {
        'accountHandles': ['other@example.com'],
      },
    ]) {
      await expectLater(
        runCloudSyncWindowsHistoricalPlan(
          request: CloudSyncWindowsHistoricalRequest.parse({
            ...input(execute: true),
            ...update,
          }),
          prepare: () async => plan(),
        ),
        throwsStateError,
      );
      expect(calls, isEmpty);
    }
  });

  test(
    'identity loss and private preparation errors remain safe and unsent',
    () async {
      current = false;
      final request = CloudSyncWindowsHistoricalRequest.parse(
        input(execute: true),
      );
      await expectLater(
        runCloudSyncWindowsHistoricalPlan(
          request: request,
          prepare: () async => plan(),
        ),
        throwsStateError,
      );
      await expectLater(
        runCloudSyncWindowsHistoricalPlan(
          request: request,
          prepare: () async => throw Exception('private content and path'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'safe message',
            'cloud_sync_historical_import_failed',
          ),
        ),
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'private request reader rejects missing, oversized and malformed files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'historical-request-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File(
        path.join(root.path, CloudSyncWindowsHistoricalRequest.fileName),
      );
      await expectLater(
        CloudSyncWindowsHistoricalRequest.read(root),
        throwsStateError,
      );
      for (final body in ['private invalid JSON', 'a' * 16385]) {
        await file.writeAsString(body);
        await expectLater(
          CloudSyncWindowsHistoricalRequest.read(root),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'safe message',
              'cloud_sync_windows_historical_request_invalid',
            ),
          ),
        );
      }
      await file.writeAsString(jsonEncode(input()));
      expect(
        (await CloudSyncWindowsHistoricalRequest.read(root)).execute,
        isFalse,
      );
    },
  );
}
