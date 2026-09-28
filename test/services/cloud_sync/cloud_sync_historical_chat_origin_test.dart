import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_chat_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure codec tests: no Store is opened and no native bridge is touched.
String _t(String c) => List.filled(43, c).join();
String _h(String c) => List.filled(64, c).join();

CloudSyncHistoricalProtectedSourceBinding _source() =>
    CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: _t('A'),
      protectedStoreIdentity: 'obcs2.store.${_t('S')}',
      snapshotSha256: _h('a'),
      messageGuidHash: _h('b'),
      sourceSha256: _h('c'),
      protectedReference: 'obcs2.ref.${_t('R')}',
      leaseReference: 'obcs2.lease.${'d' * 32}',
      payloadSha256: _h('e'),
      payloadLength: 128,
    );

CloudSyncHistoricalChatOrigin _origin({int? localChatId = 7}) =>
    CloudSyncHistoricalChatOrigin(
      generation: 2,
      intentId: 9,
      localChatId: localChatId,
      sourceChatGuidSha256: _h('f'),
      source: _source(),
      parentPayloadLength: 1024,
    );

void main() {
  test('absent and present rows roundtrip exactly', () {
    for (final origin in [_origin(localChatId: null), _origin()]) {
      final encoded = origin.encode();
      final decoded = CloudSyncHistoricalChatOrigin.decode(encoded);
      expect(decoded.encode(), encoded);
      expect(decoded.generation, origin.generation);
      expect(decoded.intentId, origin.intentId);
      expect(decoded.localChatId, origin.localChatId);
      expect(decoded.sourceChatGuidSha256, origin.sourceChatGuidSha256);
      expect(decoded.source.encode(), origin.source.encode());
      expect(decoded.parentPayloadLength, 1024);
      expect(isCloudSyncHistoricalChatOrigin(encoded), isTrue);
    }
  });

  test('invalid fields are rejected', () {
    final valid = _origin();
    List<dynamic> mutate(int slot, Object? value) {
      final copy = List<dynamic>.of(jsonDecode(valid.encode()) as List);
      copy[slot] = value;
      return copy;
    }

    String reencode(List<dynamic> fields) => jsonEncode(fields);
    // Malformed historical payloads are still recognized so decode owns
    // them; only non-historical shapes are discriminated away.
    final malformedHistorical = <String>[
      reencode((jsonDecode(valid.encode()) as List).sublist(0, 6)),
      reencode([...jsonDecode(valid.encode()) as List, 'extra']),
      reencode(mutate(2, 0)),
      reencode(mutate(3, 0)),
      reencode(mutate(4, 0)),
      reencode(mutate(4, 'seven')),
      reencode(mutate(5, 'not-a-digest')),
      reencode(mutate(6, 'not-a-source')),
      reencode(mutate(7, 0)),
      reencode(mutate(7, 2 * 1024 * 1024 + 1)),
      reencode(mutate(7, '1024')),
    ];
    final nonHistorical = <String>[
      reencode(mutate(0, 2)),
      reencode(mutate(1, 'wrongTag')),
      'not json at all',
      '',
      'x' * 9000,
    ];
    for (final encoded in [...malformedHistorical, ...nonHistorical]) {
      expect(
        () => CloudSyncHistoricalChatOrigin.decode(encoded),
        throwsStateError,
      );
    }
    for (final encoded in malformedHistorical) {
      expect(isCloudSyncHistoricalChatOrigin(encoded), isTrue);
    }
    for (final encoded in nonHistorical) {
      expect(isCloudSyncHistoricalChatOrigin(encoded), isFalse);
    }
    expect(
      () => CloudSyncHistoricalChatOrigin(
        generation: 0,
        intentId: 1,
        localChatId: null,
        sourceChatGuidSha256: _h('f'),
        source: _source(),
        parentPayloadLength: 1024,
      ),
      throwsStateError,
    );
    expect(
      () => CloudSyncHistoricalChatOrigin(
        generation: 1,
        intentId: 1,
        localChatId: -2,
        sourceChatGuidSha256: _h('f'),
        source: _source(),
        parentPayloadLength: 1024,
      ),
      throwsStateError,
    );
  });

  test('noncanonical encodings are rejected', () {
    final fields = List<dynamic>.of(jsonDecode(_origin().encode()) as List);
    // Swapped well-formed values decode positionally to a different valid
    // object; the canonical gate only rejects shapes that cannot roundtrip.
    final reordered = [
      fields[0],
      fields[1],
      fields[3],
      fields[2],
      ...fields.skip(4),
    ];
    final swapped = CloudSyncHistoricalChatOrigin.decode(jsonEncode(reordered));
    expect(swapped.generation, 9);
    expect(swapped.intentId, 2);
    expect(swapped.encode(), jsonEncode(reordered));
    // Identical values in non-compact whitespace cannot roundtrip.
    final spaced = _origin().encode().replaceAll(',', ', ');
    expect(
      () => CloudSyncHistoricalChatOrigin.decode(spaced),
      throwsStateError,
    );
    expect(isCloudSyncHistoricalChatOrigin(spaced), isTrue);
  });

  test('legacy direct tuples are never historical', () {
    // Outbound chat-origin bindings carry an integer generation in the tag
    // position, never the historical purpose string.
    for (final encoded in [
      jsonEncode([1, 3, 9, 'a', 'b']),
      jsonEncode([2, 1, 7, 'a', 'b', 'c']),
      jsonEncode([1, 'HistoricalChatOrigin', 2, 9, null, _h('f'), 'x']),
      jsonEncode([]),
      jsonEncode({'tag': 'historicalChatOrigin'}),
    ]) {
      expect(isCloudSyncHistoricalChatOrigin(encoded), isFalse);
      expect(
        () => CloudSyncHistoricalChatOrigin.decode(encoded),
        throwsStateError,
      );
    }
  });

  test('serialization carries no plaintext and toString is redacted', () {
    final origin = _origin();
    expect(origin.toString(), 'CloudSyncHistoricalChatOrigin(redacted)');
    for (final probe in ['alpha-guid-secret', 'historical-synthetic']) {
      expect(origin.encode().contains(probe), isFalse, reason: probe);
    }
    expect(origin.encode().contains(_h('f')), isTrue);
  });
}
