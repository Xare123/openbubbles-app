import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:flutter_test/flutter_test.dart';

String _repeat(String value, int count) => List.filled(count, value).join();
final _account = _repeat('A', 43);
final _store = 'obcs2.store.${_repeat('B', 43)}';
final _snapshot = _repeat('a', 64);
final _guidHash = _repeat('b', 64);
final _source = _repeat('c', 64);
final _protectedRef = 'obcs2.ref.${_repeat('C', 43)}';
final _leaseRef = 'obcs2.lease.${_repeat('d', 32)}';
final _payload = _repeat('e', 64);

CloudSyncHistoricalProtectedSourceBinding _binding() =>
    CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _store,
      snapshotSha256: _snapshot,
      messageGuidHash: _guidHash,
      sourceSha256: _source,
      protectedReference: _protectedRef,
      leaseReference: _leaseRef,
      payloadSha256: _payload,
      payloadLength: 512,
    );

void main() {
  test('roundtrip is deterministic and purpose-tagged historical', () {
    final binding = _binding();
    final encoded = binding.encode();
    expect(jsonDecode(encoded)[1], 'historicalArchiveSource');
    expect(
      CloudSyncHistoricalProtectedSourceBinding.decode(encoded).encode(),
      encoded,
    );
    expect(
      binding.toString(),
      'CloudSyncHistoricalProtectedSourceBinding(redacted)',
    );
    expect(binding.toString(), isNot(contains(_guidHash)));
  });

  test('malformed, missing, extra, and mistyped values fail closed', () {
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding.decode('not-json'),
      throwsStateError,
    );
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding.decode('x' * 5000),
      throwsStateError,
    );
    final good = jsonDecode(_binding().encode()) as List;
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding.decode(
        jsonEncode(good.sublist(0, 10)),
      ),
      throwsStateError,
    );
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding.decode(
        jsonEncode([...good, 'extra']),
      ),
      throwsStateError,
    );
    final mistyped = List.of(good)..[10] = '512';
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding.decode(
        jsonEncode(mistyped),
      ),
      throwsStateError,
    );
    final wrongVersion = List.of(good)..[0] = 2;
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding.decode(
        jsonEncode(wrongVersion),
      ),
      throwsStateError,
    );
    for (final purpose in [
      'idsMutationSource',
      'idsReceivedArchiveSource',
      'idsSendReceipt',
    ]) {
      final relabeled = List.of(good)..[1] = purpose;
      expect(
        () => CloudSyncHistoricalProtectedSourceBinding.decode(
          jsonEncode(relabeled),
        ),
        throwsStateError,
      );
    }
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding(
        accountFingerprint: 'short',
        protectedStoreIdentity: _store,
        snapshotSha256: _snapshot,
        messageGuidHash: _guidHash,
        sourceSha256: _source,
        protectedReference: _protectedRef,
        leaseReference: _leaseRef,
        payloadSha256: _payload,
        payloadLength: 512,
      ),
      throwsStateError,
    );
    expect(
      () => CloudSyncHistoricalProtectedSourceBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: _store,
        snapshotSha256: _snapshot.toUpperCase(),
        messageGuidHash: _guidHash,
        sourceSha256: _source,
        protectedReference: _protectedRef,
        leaseReference: _leaseRef,
        payloadSha256: _payload,
        payloadLength: 512,
      ),
      throwsStateError,
    );
    for (final length in [0, 1024 * 1024 + 1]) {
      expect(
        () => CloudSyncHistoricalProtectedSourceBinding(
          accountFingerprint: _account,
          protectedStoreIdentity: _store,
          snapshotSha256: _snapshot,
          messageGuidHash: _guidHash,
          sourceSha256: _source,
          protectedReference: _protectedRef,
          leaseReference: _leaseRef,
          payloadSha256: _payload,
          payloadLength: length,
        ),
        throwsStateError,
      );
    }
  });

  test('cross account, store, snapshot, and source are rejected', () {
    final binding = _binding();
    binding.requireOrigin(
      accountFingerprint: _account,
      protectedStoreIdentity: _store,
      snapshotSha256: _snapshot,
      messageGuidHash: _guidHash,
      sourceSha256: _source,
    );
    for (final overrides in [
      {'account': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'},
      {'store': 'obcs2.store.DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD'},
      {
        'snapshot':
            'bb12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34',
      },
      {
        'guid':
            'bd12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34',
      },
      {
        'source':
            'be12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34ab12cd34',
      },
    ]) {
      expect(
        () => binding.requireOrigin(
          accountFingerprint: overrides['account'] ?? _account,
          protectedStoreIdentity: overrides['store'] ?? _store,
          snapshotSha256: overrides['snapshot'] ?? _snapshot,
          messageGuidHash: overrides['guid'] ?? _guidHash,
          sourceSha256: overrides['source'] ?? _source,
        ),
        throwsStateError,
      );
    }
  });

  test(
    'each metadata field rejects a mistyped or malformed representation',
    () {
      final good = jsonDecode(_binding().encode()) as List;
      for (var index = 2; index < 10; index++) {
        for (final invalid in [
          null,
          42,
          true,
          <Object>[],
          <String, Object>{},
          '',
          'bad',
        ]) {
          final changed = List.of(good)..[index] = invalid;
          expect(
            () => CloudSyncHistoricalProtectedSourceBinding.decode(
              jsonEncode(changed),
            ),
            throwsStateError,
            reason: 'field $index rejects ${invalid.runtimeType}',
          );
        }
      }
      for (final value in [null, true, 1.5, '512', 0, -1, 1048577]) {
        final changed = List.of(good)..[10] = value;
        expect(
          () => CloudSyncHistoricalProtectedSourceBinding.decode(
            jsonEncode(changed),
          ),
          throwsStateError,
        );
      }
      for (final encoded in [
        'null',
        '{}',
        '[]',
        jsonEncode(good).replaceFirst('[', '[ '),
      ]) {
        expect(
          () => CloudSyncHistoricalProtectedSourceBinding.decode(encoded),
          throwsStateError,
        );
      }
    },
  );

  test('native payload-length endpoints are accepted', () {
    final good = jsonDecode(_binding().encode()) as List;
    for (final length in [1, 1048576]) {
      final changed = List.of(good)..[10] = length;
      expect(
        CloudSyncHistoricalProtectedSourceBinding.decode(
          jsonEncode(changed),
        ).payloadLength,
        length,
      );
    }
  });
}
