import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protocol_evidence.dart';

Directory? _testRoot;
Directory? _testEvidenceDirectory;

void main() {
  setUp(() async {
    _testRoot = await Directory.systemTemp.createTemp(
      'cloud-sync-evidence-root-',
    );
    _testEvidenceDirectory = Directory(path.join(_testRoot!.path, 'private'));
  });

  tearDown(() async {
    if (await _testRoot!.exists()) await _testRoot!.delete(recursive: true);
  });

  test('uses the exact fixed JSON key allowlist and excludes scope', () {
    final record = CloudSyncProtocolEvidenceRecord.fromEvent(
      _event(scope: 'scope:SECRET-identifier'),
      zoneLabel: 'messageManateeZone',
      streamKindLabel: 'messages',
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'abc123',
    );

    final json = jsonDecode(record.toJsonLine()) as Map<String, dynamic>;
    expect(json.keys.toSet(), CloudSyncProtocolEvidenceRecord.jsonKeys);
    expect(json['scopeDiagnosticKey'], isNull);
    expect(json['eventType'], 'fetchCompleted');
    expect(json['trigger'], 'manual');
    expect(json['failure'], 'none');
    expect(json['timestampUtc'], '2026-08-22T12:00:00.000Z');
    expect(record.toJsonLine(), isNot(contains('SECRET')));
    expect(record.toJsonLine(), isNot(contains('message text')));
  });

  test('accepts the fixed unsupported-service failure label', () {
    final record = CloudSyncProtocolEvidenceRecord.fromEvent(
      _event(failureCategory: CloudFailureCategory.unsupportedService),
      zoneLabel: 'messageManateeZone',
      streamKindLabel: 'messages',
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'abc123',
    );

    final json = jsonDecode(record.toJsonLine()) as Map<String, dynamic>;
    expect(json['failure'], 'unsupportedService');
  });

  test('accepts the appended out-of-scope-service failure label', () {
    expect(
      CloudFailureCategory.values.last,
      CloudFailureCategory.outOfScopeService,
    );
    final record = CloudSyncProtocolEvidenceRecord.fromEvent(
      _event(failureCategory: CloudFailureCategory.outOfScopeService),
      zoneLabel: 'messageManateeZone',
      streamKindLabel: 'messages',
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'abc123',
    );

    final json = jsonDecode(record.toJsonLine()) as Map<String, dynamic>;
    expect(json['failure'], 'outOfScopeService');
  });

  test('rejects invalid metadata and numeric ranges with fixed safe codes', () {
    CloudSyncProtocolEvidenceRecord build({
      String zone = 'messageManateeZone',
      int count = 0,
      int estimatedBytes = 0,
      int attempt = 0,
      int elapsedMilliseconds = 0,
    }) {
      return CloudSyncProtocolEvidenceRecord(
        zoneLabel: zone,
        streamKindLabel: 'messages',
        platform: 'android',
        architecture: 'arm64',
        buildCommit: 'abc123',
        eventType: 'fetchCompleted',
        timestampUtc: DateTime.utc(2026, 8, 22),
        count: count,
        estimatedBytes: estimatedBytes,
        attempt: attempt,
        elapsedMilliseconds: elapsedMilliseconds,
      );
    }

    expect(
      () => build(zone: 'arbitrary-zone'),
      throwsA(_safeCode('cloud_sync_protocol_evidence_zone_invalid')),
    );
    expect(
      () => build(count: -1),
      throwsA(_safeCode('cloud_sync_protocol_evidence_count_invalid')),
    );
    expect(
      () => build(estimatedBytes: -1),
      throwsA(
        _safeCode('cloud_sync_protocol_evidence_estimated_bytes_invalid'),
      ),
    );
    expect(
      () => build(attempt: CloudSyncProtocolEvidenceRecord.maximumAttempt + 1),
      throwsA(_safeCode('cloud_sync_protocol_evidence_attempt_invalid')),
    );
    expect(
      () => build(
        elapsedMilliseconds:
            CloudSyncProtocolEvidenceRecord.maximumElapsedMilliseconds + 1,
      ),
      throwsA(_safeCode('cloud_sync_protocol_evidence_elapsed_ms_invalid')),
    );
    expect(
      () => CloudSyncProtocolEvidenceRecord(
        zoneLabel: 'messageManateeZone',
        streamKindLabel: 'messages',
        platform: 'android',
        architecture: 'arm64',
        buildCommit: 'abc123',
        eventType: 'fetchCompleted',
        timestampUtc: DateTime(2026, 8, 22),
      ),
      throwsA(_safeCode('cloud_sync_protocol_evidence_timestamp_invalid')),
    );
  });

  test('observer preserves event order through append and flush', () async {
    final writer = await _openWriter();
    final observer = CloudSyncProtocolEvidenceObserver(
      writer: writer,
      zoneLabel: 'messageManateeZone',
      streamKindLabel: 'messages',
      platform: 'android',
      architecture: 'arm64',
      buildCommit: 'abc123',
    );

    observer.onEvent(_event(type: CloudSyncEventType.runStarted));
    observer.onEvent(_event(type: CloudSyncEventType.fetchCompleted));
    observer.onEvent(_event(type: CloudSyncEventType.runCompleted));
    await observer.flush();

    final lines = await _readLines(writer.currentFilePath);
    expect(lines.map((line) => (jsonDecode(line) as Map)['eventType']), [
      'runStarted',
      'fetchCompleted',
      'runCompleted',
    ]);
  });

  test('append flushes and a reopened writer continues the file', () async {
    var writer = await _openWriter();
    await writer.append(_record(count: 1));
    await writer.flush();
    writer = await _openWriter();
    await writer.append(_record(count: 2));
    await writer.flush();

    final lines = await _readLines(writer.currentFilePath);
    expect(lines, hasLength(2));
    expect((jsonDecode(lines[0]) as Map)['count'], 1);
    expect((jsonDecode(lines[1]) as Map)['count'], 2);
  });

  test(
    'rotates at the hard size cap and retains unrelated files',
    () async {
      final unrelated = File(
        path.join(_testEvidenceDirectory!.path, 'keep.txt'),
      );
      await _testEvidenceDirectory!.create(recursive: true);
      await unrelated.writeAsString('keep');
      final writer = await _openWriter();
      for (var index = 0; index < 2700; index++) {
        await writer.append(_record(count: index));
      }
      await writer.flush();

      final owned = <File>[];
      for (var index = 0; index < 3; index++) {
        final file = File(
          path.join(
            _testEvidenceDirectory!.path,
            'cloud-sync-v2-evidence-$index.jsonl',
          ),
        );
        if (await file.exists()) owned.add(file);
      }
      expect(owned, hasLength(3));
      for (final file in owned) {
        expect(await file.length(), lessThanOrEqualTo(256 * 1024));
      }
      expect(await unrelated.readAsString(), 'keep');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('rejects a private directory outside the trusted root', () async {
    final outside = path.join(
      _testRoot!.parent.path,
      'cloud-sync-evidence-outside',
    );
    expect(
      () => CloudSyncProtocolEvidenceWriter.open(
        privateDirectory: outside,
        trustedRoot: _testRoot!.path,
      ),
      throwsA(_safeCode('cloud_sync_protocol_evidence_path_escape')),
    );
  });

  test('recovers an incomplete final line on reopen', () async {
    final writer = await _openWriter();
    await writer.append(_record(count: 1));
    final file = File(writer.currentFilePath);
    final handle = await file.open(mode: FileMode.append);
    await handle.writeFrom(utf8.encode('{"partial":'));
    await handle.flush();
    await handle.close();

    final reopened = await _openWriter();
    await reopened.append(_record(count: 2));
    await reopened.flush();
    final lines = await _readLines(reopened.currentFilePath);
    expect(lines, hasLength(2));
    expect((jsonDecode(lines.last) as Map)['count'], 2);
  });

  test('fixed exceptions never include paths or arbitrary error text', () {
    const error = CloudSyncProtocolEvidenceException(
      'cloud_sync_protocol_evidence_write_failed',
    );
    expect(error.safeCode, 'cloud_sync_protocol_evidence_write_failed');
    expect(
      error.toString(),
      'CloudSyncProtocolEvidenceException(cloud_sync_protocol_evidence_write_failed)',
    );
    expect(error.toString(), isNot(contains(_testRoot!.path)));
    expect(error.toString(), isNot(contains('secret message')));
  });
}

CloudSyncEvent _event({
  CloudSyncEventType type = CloudSyncEventType.fetchCompleted,
  String scope = 'safe-scope',
  CloudFailureCategory? failureCategory,
}) {
  return CloudSyncEvent(
    type: type,
    scopeDiagnosticKey: scope,
    at: DateTime.utc(2026, 8, 22, 12),
    trigger: CloudSyncTrigger.manual,
    failureCategory: failureCategory,
    count: 4,
    estimatedBytes: 128,
    attempt: 2,
    elapsed: const Duration(milliseconds: 18),
  );
}

CloudSyncProtocolEvidenceRecord _record({int count = 0}) {
  return CloudSyncProtocolEvidenceRecord.fromEvent(
    _event(),
    zoneLabel: 'messageManateeZone',
    streamKindLabel: 'messages',
    platform: 'android',
    architecture: 'arm64',
    buildCommit: 'abc123',
  ).copyWithCountForTest(count);
}

Future<CloudSyncProtocolEvidenceWriter> _openWriter() {
  return CloudSyncProtocolEvidenceWriter.open(
    privateDirectory: _testEvidenceDirectory!.path,
    trustedRoot: _testRoot!.path,
  );
}

Future<List<String>> _readLines(String filePath) async {
  final contents = await File(filePath).readAsString();
  return contents.split('\n').where((line) => line.isNotEmpty).toList();
}

Matcher _safeCode(String code) => isA<CloudSyncProtocolEvidenceException>()
    .having((error) => error.safeCode, 'safeCode', code);

extension on CloudSyncProtocolEvidenceRecord {
  CloudSyncProtocolEvidenceRecord copyWithCountForTest(int value) {
    return CloudSyncProtocolEvidenceRecord(
      zoneLabel: zoneLabel,
      streamKindLabel: streamKindLabel,
      platform: platform,
      architecture: architecture,
      buildCommit: buildCommit,
      eventType: eventType,
      timestampUtc: timestampUtc,
      triggerLabel: triggerLabel,
      failureLabel: failureLabel,
      skipLabel: skipLabel,
      journalBlockLabel: journalBlockLabel,
      count: value,
      estimatedBytes: estimatedBytes,
      attempt: attempt,
      elapsedMilliseconds: elapsedMilliseconds,
    );
  }
}
