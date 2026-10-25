import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_fresh_group_recovery_origin.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Pure codec tests: no models, Store, account, profile or native bridge.
String _hex(String char) => char * 64;
List<Object?> _parts() => [5, 1, 773, for (final c in ['a', 'b', 'c', 'd', 'e']) _hex(c)];
String _identity() => jsonEncode(_parts());
String _proof([int version = 2]) => jsonEncode([version, 18, _hex('f')]);
String _legacy() => jsonEncode([6, ..._parts().skip(1), _proof(1)]);

Map<String, Object?> _receipt() => {
  'schema': 1,
  'reason': 'fresh-group-purpose-v1',
  'operation': {
    'localChatOrigin': _legacy(), 'state': 4, 'attemptCount': 1,
    'lastErrorCategory': 'cancelled', 'appleRequestUuid': null,
  },
  'recordMap': {'etagHash': null, 'oldReference': 'synthetic-old'},
  'source': {'intentId': 18, 'state': 1, 'idsConfirmationVersion': 2},
  'conversion': {'oldLease': 'synthetic-old', 'newLease': 'synthetic-new'},
  'binding': <String, Object?>{},
};

CloudSyncFreshGroupRecoveryOrigin _origin({Map<String, Object?>? receipt}) =>
    CloudSyncFreshGroupRecoveryOrigin.create(
      identity: _identity(), receipt: receipt ?? _receipt(), proof: _proof(),
    );

List<dynamic> _root() => jsonDecode(_origin().encode()) as List<dynamic>;
String _changedRoot(int slot, Object? value) => jsonEncode(_root()..[slot] = value);

String _rawRoot(String canonical, {String? digest}) => jsonEncode([
  9, 0, _parts(), canonical,
  digest ?? sha256.convert(utf8.encode(canonical)).toString(), _proof(),
]);

Map<String, Object?> _padding(String padding) => _receipt()
  ..['binding'] = {'padding': padding};

void main() {
  test('canonical roundtrip has the exact version-nine root and retained audit', () {
    final origin = _origin();
    final root = jsonDecode(origin.encode()) as List;
    expect(root, [9, 0, _parts(), origin.canonicalReceipt, origin.receiptSha256, _proof()]);
    expect(origin.identity, _identity());
    expect(origin.identityParts, _parts());
    expect(origin.receipt, _receipt());
    expect((origin.receipt['operation'] as Map)['lastErrorCategory'], 'cancelled');
    expect((origin.receipt['recordMap'] as Map).containsKey('etagHash'), isTrue);
    expect((origin.receipt['recordMap'] as Map)['etagHash'], isNull);
    expect(CloudSyncFreshGroupRecoveryOrigin.decode(origin.encode()).encode(), origin.encode());
    expect(CloudSyncFreshGroupRecoveryOrigin.isEncoded(origin.encode()), isTrue);
  });

  test('receipt helpers canonicalize recursively before proof construction', () {
    final receipt = _receipt()..['binding'] = {
      'z': [{'z': null, 'a': true}], 'a': {'z': 1.5, 'a': -2},
    };
    final reordered = Map<String, Object?>.fromEntries(receipt.entries.toList().reversed);
    reordered['binding'] = {
      'a': {'a': -2, 'z': 1.5}, 'z': [{'a': true, 'z': null}],
    };
    final canonical = CloudSyncFreshGroupRecoveryOrigin.canonicalReceiptFor(receipt);
    expect(canonical, CloudSyncFreshGroupRecoveryOrigin.canonicalReceiptFor(reordered));
    expect(canonical, contains('"binding":{"a":{"a":-2,"z":1.5},"z":[{"a":true,"z":null}]}'));
    final digest = CloudSyncFreshGroupRecoveryOrigin.receiptDigestFor(receipt);
    expect(digest, sha256.convert(utf8.encode(canonical)).toString());
    final origin = CloudSyncFreshGroupRecoveryOrigin.create(
      identity: _identity(), receipt: receipt, proof: jsonEncode([2, 18, digest]),
    );
    expect(origin.canonicalReceipt, canonical);
    expect(origin.receiptSha256, digest);
  });

  test('input mutation and mutation through nested getters cannot change evidence', () {
    final nested = <String, Object?>{'a': null};
    final list = <Object?>[nested];
    final input = _receipt()..['binding'] = {'list': list};
    final origin = _origin(receipt: input);
    final before = origin.encode();
    nested['a'] = 'changed';
    list.add('changed');
    input.clear();
    expect(origin.encode(), before);
    expect(() => origin.identityParts[1] = 9, throwsUnsupportedError);
    expect(() => origin.receipt.clear(), throwsUnsupportedError);
    final binding = origin.receipt['binding'] as Map;
    expect(() => binding['new'] = 1, throwsUnsupportedError);
    final frozenList = binding['list'] as List;
    expect(() => frozenList.add(null), throwsUnsupportedError);
    expect(() => (frozenList.single as Map).clear(), throwsUnsupportedError);
    final decoded = CloudSyncFreshGroupRecoveryOrigin.decode(before);
    expect(() => (decoded.receipt['operation'] as Map).clear(), throwsUnsupportedError);
  });

  test('identity must match the complete base identity in legacy origin6', () {
    for (var slot = 1; slot < 8; slot++) {
      final changed = _parts()..[slot] = slot < 3 ? 99 : _hex('f');
      expect(() => CloudSyncFreshGroupRecoveryOrigin.create(
        identity: jsonEncode(changed), receipt: _receipt(), proof: _proof(),
      ), throwsStateError, reason: 'identity slot $slot');
      expect(() => CloudSyncFreshGroupRecoveryOrigin.decode(_changedRoot(2, changed)), throwsStateError);
    }
  });

  test('rejects malformed, noncanonical and unsupported base identities', () {
    for (final identity in [
      ' ${_identity()}', jsonEncode([6, ..._parts().skip(1)]),
      jsonEncode(_parts()..[1] = 0), jsonEncode(_parts()..[2] = 773.0),
      jsonEncode(_parts()..[3] = _hex('A')), jsonEncode([..._parts(), null]),
      '{}', 'x' * 769,
    ]) {
      expect(() => CloudSyncFreshGroupRecoveryOrigin.create(
        identity: identity, receipt: _receipt(), proof: _proof(),
      ), throwsStateError);
    }
  });

  for (final legacyVersion in [5, 7, 8, 9, 10]) {
    test('receipt rejects non-legacy-ready group version $legacyVersion', () {
      final receipt = _receipt();
      (receipt['operation'] as Map)['localChatOrigin'] = jsonEncode([
        legacyVersion, ..._parts().skip(1), _proof(1),
      ]);
      expect(() => _origin(receipt: receipt), throwsStateError);
    });
  }

  test('receipt rejects historical, actual identity-only and recovered origins', () {
    for (final origin in [
      jsonEncode([1, 'historicalChatOrigin', 1, 18, null, _hex('a'), 'source', 128]),
      _identity(), _origin().encode(), '{}', 'not JSON', 'x' * 769,
    ]) {
      final receipt = _receipt();
      (receipt['operation'] as Map)['localChatOrigin'] = origin;
      expect(() => _origin(receipt: receipt), throwsStateError);
    }
  });

  test('legacy proof syntax and canonical legacy JSON are required', () {
    for (final legacy in [
      ' ${_legacy()}',
      jsonEncode([6, ..._parts().skip(1), _proof(2)]),
      jsonEncode([6, ..._parts().skip(1), jsonEncode([1, 0, _hex('f')])]),
      jsonEncode([6, ..._parts().skip(1), jsonEncode([1, 18, _hex('F')])]),
      jsonEncode([6, ..._parts().skip(1), ' ${_proof(1)}']),
      jsonEncode([6, ..._parts().skip(1), _proof(1), null]),
    ]) {
      final receipt = _receipt();
      (receipt['operation'] as Map)['localChatOrigin'] = legacy;
      expect(() => _origin(receipt: receipt), throwsStateError);
    }
  });

  test('receipt requires the exact schema, reason and five map fields', () {
    for (final key in _receipt().keys) {
      expect(() => _origin(receipt: _receipt()..remove(key)), throwsStateError, reason: key);
    }
    for (final mutation in <void Function(Map<String, Object?>)>[
      (r) => r['extra'] = null,
      (r) => r['schema'] = 1.0,
      (r) => r['schema'] = 2,
      (r) => r['reason'] = 'historical',
      for (final key in ['operation', 'recordMap', 'source', 'conversion', 'binding'])
        (r) => r[key] = [],
      (r) => (r['operation'] as Map).remove('localChatOrigin'),
    ]) {
      final receipt = _receipt();
      mutation(receipt);
      expect(() => _origin(receipt: receipt), throwsStateError);
    }
  });

  test('rejects receipt/hash disagreement and noncanonical or duplicate keys', () {
    final canonical = _origin().canonicalReceipt;
    final changed = canonical.replaceFirst('cancelled', 'changed');
    expect(() => CloudSyncFreshGroupRecoveryOrigin.decode(
      _rawRoot(changed, digest: _origin().receiptSha256),
    ), throwsStateError);
    for (final malformed in [
      ' $canonical',
      jsonEncode(Map<String, Object?>.fromEntries(_receipt().entries.toList().reversed)),
      canonical.replaceFirst('"schema":1', '"schema":1,"schema":1'),
      canonical.replaceFirst('"attemptCount":1', '"attemptCount":0,"attemptCount":1'),
      canonical.replaceFirst('"schema":1', '"schema":1e0'),
    ]) {
      // Recompute the hash: canonicality/duplicates must still be rejected.
      expect(() => CloudSyncFreshGroupRecoveryOrigin.decode(_rawRoot(malformed)), throwsStateError);
    }
  });

  test('rejects invalid root versions, phases, fields and noncanonical text', () {
    for (final encoded in [
      '{}', 'null', '', '[', jsonEncode([5, ..._parts().skip(1)]),
      jsonEncode([1, 'historicalChatOrigin']),
      _changedRoot(0, 8), _changedRoot(0, 10), _changedRoot(0, 9.0),
      _changedRoot(1, -1), _changedRoot(1, 3), _changedRoot(1, 0.0),
      _changedRoot(2, _identity()), _changedRoot(3, _receipt()),
      _changedRoot(4, _hex('A')), _changedRoot(4, _hex('a')),
      _changedRoot(5, null), jsonEncode(_root().sublist(0, 5)),
      jsonEncode([..._root(), null]), ' ${_origin().encode()}',
      _origin().encode().replaceFirst('[9,', '[9, '),
      _origin().encode().replaceFirst('fresh-group', r'fresh\u002dgroup'),
    ]) {
      expect(() => CloudSyncFreshGroupRecoveryOrigin.decode(encoded), throwsStateError);
    }
  });

  test('recovery proof must be canonical version2 with positive intent and lowercase digest', () {
    for (final proof in [
      _proof(1), _proof(3), ' ${_proof()}',
      jsonEncode([2, 0, _hex('a')]), jsonEncode([2, -1, _hex('a')]),
      jsonEncode([2, 18.0, _hex('a')]), jsonEncode([2, 18, _hex('A')]),
      jsonEncode([2, 18, 'a' * 63]), jsonEncode([2, 18, _hex('a'), null]),
      'x' * 257,
    ]) {
      expect(() => CloudSyncFreshGroupRecoveryOrigin.create(
        identity: _identity(), receipt: _receipt(), proof: proof,
      ), throwsStateError);
      expect(() => CloudSyncFreshGroupRecoveryOrigin.decode(_changedRoot(5, proof)), throwsStateError);
    }
  });

  test('valid syntax cannot authenticate a proof or a changed audit', () {
    final receipt = _receipt();
    (receipt['source'] as Map)['idsConfirmationVersion'] = 0;
    (receipt['operation'] as Map)['state'] = 99;
    final origin = CloudSyncFreshGroupRecoveryOrigin.create(
      identity: _identity(), receipt: receipt,
      proof: jsonEncode([2, 999, _hex('a')]),
    );
    // Parent domain validation must reject these ownership/state claims.
    expect(CloudSyncFreshGroupRecoveryOrigin.decode(origin.encode()).receipt, receipt);
    expect(origin.proof, jsonEncode([2, 999, _hex('a')]));
  });

  test('isEncoded discriminates version9 without validating or granting authority', () {
    expect(CloudSyncFreshGroupRecoveryOrigin.isEncoded('[9]'), isTrue);
    expect(() => CloudSyncFreshGroupRecoveryOrigin.decode('[9]'), throwsStateError);
    for (final encoded in ['[8]', '[10]', '[9.0]', '{}', '[', 'x' * 65537]) {
      expect(CloudSyncFreshGroupRecoveryOrigin.isEncoded(encoded), isFalse);
    }
  });

  test('phases are monotonic and normalization preserves every receipt/proof byte', () {
    final ready = _origin();
    final submitted = ready.withPhase(CloudSyncFreshGroupRecoveryPhase.submitted);
    final retired = ready.withPhase(CloudSyncFreshGroupRecoveryPhase.retired);
    for (final origin in [ready, submitted, retired]) {
      expect(identical(origin.withPhase(origin.phase), origin), isTrue);
      expect(origin.canonicalReceipt, ready.canonicalReceipt);
      expect(origin.receiptSha256, ready.receiptSha256);
      expect(origin.proof, ready.proof);
      expect(identical(origin.receipt, ready.receipt), isTrue);
      expect(CloudSyncFreshGroupRecoveryOrigin.decode(origin.encode()).phase, origin.phase);
    }
    expect(submitted.normalizedForBinding, ready.encode());
    expect(submitted.phase, CloudSyncFreshGroupRecoveryPhase.submitted);
    expect(ready.normalizedForBinding, ready.encode());
    expect(retired.normalizedForBinding, retired.encode());
    expect(retired.normalizedForBinding, isNot(ready.normalizedForBinding));
    for (final pair in [
      [submitted, CloudSyncFreshGroupRecoveryPhase.ready],
      [submitted, CloudSyncFreshGroupRecoveryPhase.retired],
      [retired, CloudSyncFreshGroupRecoveryPhase.ready],
      [retired, CloudSyncFreshGroupRecoveryPhase.submitted],
    ]) {
      expect(() => (pair[0] as CloudSyncFreshGroupRecoveryOrigin)
          .withPhase(pair[1] as CloudSyncFreshGroupRecoveryPhase), throwsStateError);
    }
    final changed = _origin(receipt: _receipt()..['binding'] = {'audit': 'changed'});
    expect(changed.normalizedForBinding, isNot(ready.normalizedForBinding));
  });

  test('receipt UTF16 boundary is inclusive without truncation', () {
    final base = CloudSyncFreshGroupRecoveryOrigin.canonicalReceiptFor(_padding(''));
    final receipt = _padding('x' * (32768 - base.length));
    expect(_origin(receipt: receipt).canonicalReceipt.length, 32768);
    expect(() => _origin(receipt: _padding('x' * (32769 - base.length))), throwsStateError);
  });

  test('receipt UTF8 boundary is inclusive independently of UTF16', () {
    final base = utf8.encode(CloudSyncFreshGroupRecoveryOrigin.canonicalReceiptFor(_padding(''))).length;
    final available = 65536 - base;
    final text = '界' * (available ~/ 3) + 'x' * (available % 3);
    final origin = _origin(receipt: _padding(text));
    expect(utf8.encode(origin.canonicalReceipt).length, 65536);
    expect(origin.canonicalReceipt.length, lessThan(32768));
    expect(() => _origin(receipt: _padding('${text}x')), throwsStateError);
    expect(CloudSyncFreshGroupRecoveryOrigin.decode(origin.encode()).encode(), origin.encode());
  });

  test('whole-root UTF16 bound accounts for escaped receipt expansion', () {
    Map<String, Object?> compact(String padding) => {
      'schema': 1, 'reason': 'fresh-group-purpose-v1',
      'operation': {'localChatOrigin': _legacy()},
      'recordMap': <String, Object?>{}, 'source': <String, Object?>{},
      'conversion': <String, Object?>{}, 'binding': {'': padding},
    };
    final base = CloudSyncFreshGroupRecoveryOrigin.canonicalReceiptFor(compact(''));
    final available = 32768 - base.length;
    final text = '"' * (available ~/ 2) + 'x' * (available % 2);
    final origin = _origin(receipt: compact(text));
    expect(origin.canonicalReceipt.length, 32768);
    expect(origin.encode().length, inInclusiveRange(65000, 65536));
    expect(CloudSyncFreshGroupRecoveryOrigin.decode(origin.encode()).encode(), origin.encode());
    // This fixture reaches the receipt cap before the enclosing root cap.
    expect(() => _origin(receipt: compact('${text}x')), throwsStateError);
    final oversized = origin.encode() + ' ' * (65537 - origin.encode().length);
    expect(oversized.length, 65537);
    expect(() => CloudSyncFreshGroupRecoveryOrigin.decode(oversized), throwsStateError);
    expect(CloudSyncFreshGroupRecoveryOrigin.isEncoded(oversized), isFalse);
  });

  test('whole-root UTF8 bound rejects oversized multibyte input', () {
    final encoded = jsonEncode([9, 0, _parts(), '界' * 45000, _hex('a'), _proof()]);
    expect(encoded.length, lessThan(65536));
    expect(utf8.encode(encoded).length, greaterThan(131072));
    expect(() => CloudSyncFreshGroupRecoveryOrigin.decode(encoded), throwsStateError);
    expect(CloudSyncFreshGroupRecoveryOrigin.isEncoded(encoded), isFalse);
  });

  test('finite depth and node bounds reject typed and encoded hostile trees', () {
    Object? nested = null;
    for (var i = 0; i < 20; i++) { nested = [nested]; }
    expect(() => _origin(receipt: _receipt()..['binding'] = {'deep': nested}), throwsStateError);
    expect(() => _origin(receipt: _receipt()..['binding'] = {'nodes': List.filled(4096, null)}), throwsStateError);
    expect(() => CloudSyncFreshGroupRecoveryOrigin.decode('[9,${'[' * 100}0${']' * 100}]'), throwsStateError);
    expect(() => CloudSyncFreshGroupRecoveryOrigin.decode('[9,${jsonEncode(List.filled(4096, null))}]'), throwsStateError);
    final cycle = <String, Object?>{};
    cycle['self'] = cycle;
    expect(() => _origin(receipt: _receipt()..['binding'] = cycle), throwsStateError);
  });

  test('documented JSON depth and node limits are inclusive', () {
    Object? deepest = null;
    // Receipt root=1, binding=2, thirteen lists=3..15, null=16.
    for (var i = 0; i < 13; i++) { deepest = [deepest]; }
    final depthOrigin = _origin(receipt: _receipt()..['binding'] = {'deep': deepest});
    expect(CloudSyncFreshGroupRecoveryOrigin.decode(depthOrigin.encode()).encode(), depthOrigin.encode());
    expect(() => _origin(receipt: _receipt()..['binding'] = {'deep': [deepest]}), throwsStateError);
    // This fixture has 41 containers/keys/scalars before the list's nulls.
    final nodeOrigin = _origin(receipt: _receipt()
      ..['binding'] = {'nodes': List.filled(4055, null)});
    expect(CloudSyncFreshGroupRecoveryOrigin.decode(nodeOrigin.encode()).encode(), nodeOrigin.encode());
    expect(() => _origin(receipt: _receipt()
      ..['binding'] = {'nodes': List.filled(4056, null)}), throwsStateError);
  });

  test('rejects unsupported values and malformed UTF16; preserves valid Unicode', () {
    for (final value in [double.nan, double.infinity, <Object>{}, Object(), {1: 'bad'}, '\ud800', '\udc00']) {
      expect(() => _origin(receipt: _receipt()..['binding'] = {'value': value}), throwsStateError);
    }
    final origin = _origin(receipt: _receipt()..['binding'] = {'value': '界😀\u0000'});
    expect((CloudSyncFreshGroupRecoveryOrigin.decode(origin.encode()).receipt['binding'] as Map)['value'], '界😀\u0000');
  });

  test('toString and refusal errors reveal no receipt or proof content', () {
    final origin = _origin(receipt: _receipt()..['binding'] = {'private': 'synthetic-secret'});
    expect(origin.toString(), 'CloudSyncFreshGroupRecoveryOrigin(redacted)');
    try {
      CloudSyncFreshGroupRecoveryOrigin.decode('${origin.encode()} trailing');
      fail('expected refusal');
    } on StateError catch (error) {
      expect(error.message, 'cloud_sync_fresh_group_recovery_origin_invalid');
      expect(error.toString(), isNot(contains('synthetic-secret')));
    }
  });
}
