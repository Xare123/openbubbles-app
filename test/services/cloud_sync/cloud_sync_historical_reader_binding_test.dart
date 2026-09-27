import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

String _hash(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

final _source = CloudSyncHistoricalProtectedSourceBinding(
  accountFingerprint: 'A' * 43,
  protectedStoreIdentity: 'obcs2.store.${'S' * 43}',
  snapshotSha256: 'a' * 64,
  messageGuidHash: 'b' * 64,
  sourceSha256: 'c' * 64,
  protectedReference: 'obcs2.ref.${'R' * 43}',
  leaseReference: 'obcs2.lease.${'d' * 32}',
  payloadSha256: 'e' * 64,
  payloadLength: 128,
);

List<Object> _observation() => [
  1,
  sha256.convert(utf8.encode(_source.encode())).toString(),
  'C' * 43,
  'R' * 43,
  'E' * 43,
  'f' * 64,
  1,
];

CloudSyncHistoricalArchiveIntentEntity _row({int state = 2}) {
  final scope = _hash([
    'historical-archive-scope-v1',
    _source.accountFingerprint,
    _source.protectedStoreIdentity,
    _source.snapshotSha256,
  ]);
  return CloudSyncHistoricalArchiveIntentEntity(
    id: 1,
    intentKey: _hash([
      'historical-archive-intent-v1',
      scope,
      _source.messageGuidHash,
    ]),
    scopeKey: scope,
    protectedSourceBinding: _source.encode(),
    state: state,
    readerObservationBinding: state == 2 ? jsonEncode(_observation()) : null,
    createdAtMs: 1000,
    updatedAtMs: 1000,
  );
}

void main() {
  test(
    'staged, committed and reader-owned metadata retain the same source',
    () {
      for (final state in [0, 1, 2]) {
        expect(
          validateCloudSyncHistoricalArchiveRow(_row(state: state)).encode(),
          _source.encode(),
        );
      }
    },
  );

  for (final state in [0, 1]) {
    test('state $state cannot carry fabricated reader ownership', () {
      final row = _row(state: state)
        ..readerObservationBinding = jsonEncode(_observation());
      expect(
        () => validateCloudSyncHistoricalArchiveRow(row),
        throwsStateError,
      );
    });
  }

  for (final entry in <String, String?>{
    'missing': null,
    'truncated': '[1,',
    'wrong type': '{}',
    'extra fields': jsonEncode([..._observation(), 'extra']),
    'noncanonical': ' ${jsonEncode(_observation())}',
    'oversized': 'x' * 1025,
  }.entries) {
    test('reader binding rejects ${entry.key} without rewriting evidence', () {
      final row = _row()..readerObservationBinding = entry.value;
      expect(
        () => validateCloudSyncHistoricalArchiveRow(row),
        throwsStateError,
      );
      expect(row.readerObservationBinding, entry.value);
      expect(row.protectedSourceBinding, _source.encode());
    });
  }

  for (final entry in <String, (int, Object)>{
    'version': (0, 2),
    'foreign source': (1, 'a' * 64),
    'malformed change': (2, 'bad'),
    'malformed record': (3, 'bad'),
    'missing etag': (4, ''),
    'wrong payload digest': (5, 'G' * 64),
    'zero generation': (6, 0),
    'negative generation': (6, -1),
    'noninteger generation': (6, 1.5),
  }.entries) {
    test('reader binding rejects ${entry.key}', () {
      final values = _observation()..[entry.value.$1] = entry.value.$2;
      final row = _row()..readerObservationBinding = jsonEncode(values);
      expect(
        () => validateCloudSyncHistoricalArchiveRow(row),
        throwsStateError,
      );
    });
  }
}
