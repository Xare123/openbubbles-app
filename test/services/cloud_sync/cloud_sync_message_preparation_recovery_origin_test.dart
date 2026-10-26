import 'dart:collection';
import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_preparation_recovery_origin.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Pure syntax fixtures. No models, ObjectBox, profile, account or native calls.
String _hex(String c) => c * 64;
String _token(String c) => c * 43;
String _ref(String c) => 'obcs2.ref.${_token(c)}';
String _lease(String c) => 'obcs2.lease.${c * 32}';
String _op(String c) => 'op1:${_hex(c)}';
String _sha(String value) => sha256.convert(utf8.encode(value)).toString();
String get _store => 'obcs2.store.${_token('P')}';
String _scope(String c) => 'scope2:${_hex(c)}';
Map<String, Object?> _section(Map<String, Object?> receipt, String key) =>
    receipt[key]! as Map<String, Object?>;

String _legacy({bool direct = false, int attachments = 1}) {
  final chat = jsonEncode([
    direct ? 1 : 3, _scope('b'), 1, 773, _hex('c'), _hex('d'),
    _token('E'), _token('F'), _token('G'),
    if (!direct) ...[_token('H'), _hex('e')],
  ]);
  final keys = [
    for (var i = 0; i < attachments; i++)
      i.toRadixString(16).padLeft(43, '0'),
  ];
  final body = <Object?>[
    1,
    '${_token('A')}\u001fcom.apple.messages.cloud\u001fprivate\u001fattachmentManateeZone\u001fmessages\u001f2\u001fsemantic',
    1, 19, _hex('f'), _hex('1'), _store, 7, keys,
    [
      for (var i = 0; i < keys.length; i++)
        [2551 + i, keys[i], _token('J'), _hex('2'), 'op1:${i.toRadixString(16).padLeft(64, '0')}'],
    ],
  ];
  final proof = jsonEncode([...body, _sha(jsonEncode(body))]);
  return jsonEncode([4, chat, proof]);
}

String _nativeSource() => jsonEncode([
  1, 'idsAttachmentSource', _token('A'), _store, _hex('f'), _hex('1'),
  _ref('S'), _lease('a'), _hex('3'), 1009,
]);

Map<String, Object?> _receipt({String? legacy}) => {
  'schema': 1,
  'reason': CloudSyncMessagePreparationRecoveryOrigin.reason,
  'mode': CloudSyncMessagePreparationRecoveryOrigin.mode,
  'operation': {
    'id': 30, 'operationId': _op('4'), 'scopeKey': _scope('5'),
    'accountFingerprint': _token('A'), 'zone': 'messageManateeZone',
    'logicalEntityKeyHash': _token('K'), 'action': 0,
    'dependencyOperationIdsJson': '[]', 'payloadVersion': 2, 'mutationRevision': 0,
    'checkpointGeneration': 1, 'appleRequestUuid': null, 'appleOperationUuid': null,
    'encryptedPayloadRef': _ref('O'), 'payloadSha256': _hex('6'),
    'protectedLeaseReference': null, 'localChatOrigin': null, 'state': 4,
    'attemptCount': 3, 'nextEligibleAtMs': 0, 'lastErrorCategory': 'unknown',
    'serverRecordIdHash': _token('R'), 'leaseIdHash': null, 'leaseExpiresAtMs': 0,
    'confirmedAtMs': 0, 'createdAtMs': 100, 'updatedAtMs': 200,
  },
  'recordMap': {
    'id': 29119, 'mapKey': 'record-map:${_hex('7')}', 'scopeKey': _scope('5'),
    'accountFingerprint': _token('A'), 'zone': 'messageManateeZone',
    'logicalEntityKeyHash': _token('K'), 'serverRecordIdHash': _token('R'),
    'generation': 1, 'encryptedServerRecordId': _ref('O'), 'etagHash': null,
    'encryptedRawRecordRef': null, 'rawRecordGeneration': 0,
    'protectedReadbackLeaseReference': null, 'pendingUpdateOperationId': null,
    'pendingUpdatePredecessorEtagHash': null, 'updatedAtMs': 200,
  },
  'source': {
    'id': 19, 'intentKey': _hex('8'), 'accountFingerprint': _token('A'),
    'writerEpoch': 7, 'localMessageId': 14222, 'messageGuidHash': _hex('f'),
    'sourceSha256': _hex('1'), 'state': 2, 'admittedOperationId': _op('4'),
    'admittedBindingSha256': _hex('9'), 'admittedChatBinding': legacy ?? _legacy(),
    'confirmedReadbackBindingSha256': null, 'idsConfirmationVersion': 2,
    'protectedSourceBinding': _nativeSource(), 'createdAtMs': 100, 'updatedAtMs': 201,
  },
  'stage': {
    'protectedPayloadReference': _ref('N'), 'protectedServerRecordReference': _ref('N'),
    'leaseReference': _lease('b'), 'payloadSha256': _hex('6'),
    'logicalEntityKeyHash': _token('K'), 'serverRecordIdHash': _token('R'),
  },
  'binding': {
    'scopeKey': _scope('5'), 'accountFingerprint': _token('A'), 'checkpointGeneration': 1,
    'chatId': 773, 'intentId': 19, 'localMessageId': 14222,
    'nativeSessionId': _token('C'), 'protectedStoreIdentity': _store,
    'owner': 'v2', 'writerEpoch': 10, 'ownershipEpoch': 9,
    'ownershipSnapshotSha256': _hex('a'), 'recoveredAtMs': 300,
  },
  'legacyAdoptionSha256': _hex('9'),
};

CloudSyncMessagePreparationRecoveryOrigin _origin({Map<String, Object?>? receipt}) {
  final value = receipt ?? _receipt();
  final source = value['source'];
  final legacy = source is Map && source['admittedChatBinding'] is String
      ? source['admittedChatBinding']! as String
      : _legacy();
  return CloudSyncMessagePreparationRecoveryOrigin.create(
    legacyBinding: legacy,
    receipt: value,
  );
}

String _rawRoot(String canonical, {String? hash, String? legacy, Object? phase = 0}) =>
    jsonEncode([5, phase, legacy ?? _legacy(), canonical, hash ?? _sha(canonical)]);

String _changedRoot(int index, Object? value) {
  final root = jsonDecode(_origin().encode()) as List;
  root[index] = value;
  return jsonEncode(root);
}

final _invalid = throwsA(isA<StateError>().having(
  (e) => e.message, 'fixed content-free code',
  CloudSyncMessagePreparationRecoveryOrigin.invalidCode,
));

// Detect accidental element traversal before the declared container-size fence.
final class _OversizedUnreadableList extends ListBase<Object?> {
  @override
  int get length => 4097;
  @override
  set length(int value) => throw StateError('private-length-access');
  @override
  Object? operator [](int index) => throw StateError('private-element-access');
  @override
  void operator []=(int index, Object? value) => throw StateError('private-write-access');
}

void main() {
  test('source capture and later protected admission retain independent times and epochs', () {
    final receipt = _receipt();
    _section(receipt, 'source')['createdAtMs'] = 1;
    _section(receipt, 'source')['updatedAtMs'] = 50;
    final origin = _origin(receipt: receipt);
    expect(origin.source['createdAtMs'], 1);
    expect(origin.operation['createdAtMs'], 100);
    expect(origin.source['writerEpoch'], 7);
    expect(origin.binding['writerEpoch'], 10);
    expect(origin.binding['ownershipEpoch'], 9);
    expect(CloudSyncMessagePreparationRecoveryOrigin.decode(origin.encode()).receipt, receipt);
  });

  test('version5 preserves the exact legacy v4 and complete immutable snapshots', () {
    final receipt = _receipt();
    final origin = _origin(receipt: receipt);
    expect(jsonDecode(origin.encode()), [
      5, 0, _legacy(), origin.canonicalReceipt, origin.receiptSha256,
    ]);
    expect(origin.receipt, receipt);
    expect(origin.unwrapLegacyBinding(), _legacy());
    expect(origin.legacyBinding, _section(receipt, 'source')['admittedChatBinding']);
    expect(origin.operationId, _op('4'));
    expect(origin.freshLeaseReference, _lease('b'));
    expect(origin.freshProtectedReference, _ref('N'));
    expect(origin.payloadSha256, _hex('6'));
    expect(origin.logicalEntityKeyHash, _token('K'));
    expect(origin.serverRecordIdHash, _token('R'));
    expect(origin.legacyAdoptionSha256, _hex('9'));
    expect(origin.operation['state'], 4);
    expect(origin.source['state'], 2);
    expect(origin.source['protectedSourceBinding'], _nativeSource());
    expect(CloudSyncMessagePreparationRecoveryOrigin.decode(origin.encode()).encode(), origin.encode());
  });

  test('phase updates retain every receipt and legacy byte and never release early', () {
    var origin = _origin();
    final first = origin;
    for (final phase in CloudSyncMessagePreparationRecoveryPhase.values) {
      if (phase != origin.phase) {
        origin = origin.withPhase(phase);
      }
      expect(identical(origin.withPhase(phase), origin), isTrue);
      expect(origin.legacyBinding, first.legacyBinding);
      expect(origin.canonicalReceipt, first.canonicalReceipt);
      expect(origin.receiptSha256, first.receiptSha256);
      expect(identical(origin.receipt, first.receipt), isTrue);
      expect(origin.retainsFreshLease, phase != CloudSyncMessagePreparationRecoveryPhase.retired);
      expect(CloudSyncMessagePreparationRecoveryOrigin.decode(origin.encode()).phase, phase);
    }
    expect(() => first.withPhase(CloudSyncMessagePreparationRecoveryPhase.retained), _invalid);
    expect(() => origin.withPhase(CloudSyncMessagePreparationRecoveryPhase.adopted), _invalid);
    expect(() => first.withPhase(CloudSyncMessagePreparationRecoveryPhase.committed)
        .withPhase(CloudSyncMessagePreparationRecoveryPhase.retired), _invalid);
  });

  test('receipt canonicalization sorts maps independently of input insertion order', () {
    final value = _receipt();
    final reordered = <String, Object?>{
      for (final entry in value.entries.toList().reversed)
        entry.key: entry.value is Map<String, Object?>
            ? Map<String, Object?>.fromEntries((entry.value! as Map<String, Object?>).entries.toList().reversed)
            : entry.value,
    };
    expect(_origin(receipt: reordered).encode(), _origin(receipt: value).encode());
    expect(CloudSyncMessagePreparationRecoveryOrigin.canonicalReceiptFor(value), _origin().canonicalReceipt);
    expect(CloudSyncMessagePreparationRecoveryOrigin.receiptDigestFor(value), _sha(_origin().canonicalReceipt));
  });

  test('mutating input or nested getters cannot alter captured evidence', () {
    final value = _receipt();
    final origin = _origin(receipt: value);
    final encoded = origin.encode();
    _section(value, 'operation')['attemptCount'] = 77;
    _section(value, 'stage')['leaseReference'] = _lease('c');
    value['source'] = <String, Object?>{};
    expect(origin.encode(), encoded);
    expect(origin.operation['attemptCount'], 3);
    expect(origin.freshLeaseReference, _lease('b'));
    for (final map in [origin.receipt, origin.operation, origin.recordMap, origin.source, origin.stage, origin.binding]) {
      expect(() => map['private'] = 'not writable', throwsUnsupportedError);
      expect(() => map.clear(), throwsUnsupportedError);
    }
  });

  test('stale or tampered receipt hashes and noncanonical encodings are rejected', () {
    final origin = _origin();
    final changed = origin.canonicalReceipt.replaceFirst('"attemptCount":3', '"attemptCount":4');
    for (final text in [
      _rawRoot(changed, hash: origin.receiptSha256),
      _changedRoot(4, _hex('A')), _changedRoot(4, _hex('0')),
      _rawRoot(' ${origin.canonicalReceipt}'),
      _rawRoot(origin.canonicalReceipt.replaceFirst('"schema":1', '"schema":1,"schema":1')),
      ' ${origin.encode()}', origin.encode().replaceFirst('[5,', '[5, '),
    ]) {
      expect(() => CloudSyncMessagePreparationRecoveryOrigin.decode(text), _invalid);
    }
    // A newly self-consistent hash is syntax only. The journal must still
    // authenticate this altered snapshot against the actual original row.
    expect(CloudSyncMessagePreparationRecoveryOrigin.decode(_rawRoot(changed)).operation['attemptCount'], 4);
  });

  test('no phase syntax authenticates commit or grants save capability', () {
    final origin = _origin();
    final syntacticRetained = CloudSyncMessagePreparationRecoveryOrigin.decode(
      _rawRoot(origin.canonicalReceipt, phase: 2),
    );
    expect(syntacticRetained.phase, CloudSyncMessagePreparationRecoveryPhase.retained);
    expect(syntacticRetained.retainsFreshLease, isTrue);
    expect(syntacticRetained.receipt['mode'], 'preparation-only');
    expect(syntacticRetained.receipt.containsKey('saveAllowed'), isFalse);
  });

  for (final section in ['operation', 'recordMap', 'source', 'stage', 'binding']) {
    test('$section refuses unknown and omitted fields, including nullable fields', () {
      final extra = _receipt();
      _section(extra, section)['privateMessageText'] = 'private body';
      expect(() => _origin(receipt: extra), _invalid);
      for (final key in _section(_receipt(), section).keys) {
        final missing = _receipt();
        _section(missing, section).remove(key);
        expect(() => _origin(receipt: missing), _invalid, reason: '$section.$key');
      }
    });
  }

  test('root schema reason and mode are closed and do not accept authority fields', () {
    for (final entry in <MapEntry<String, Object?>>[
      const MapEntry('schema', 1.0), const MapEntry('schema', 2),
      const MapEntry('reason', 'fresh-group-purpose-v1'), const MapEntry('mode', 'save'),
      const MapEntry('saveAllowed', true), const MapEntry('message', 'private body'),
      const MapEntry('rawGuid', '11111111-1111-4111-8111-111111111111'),
    ]) {
      expect(() => _origin(receipt: _receipt()..[entry.key] = entry.value), _invalid);
    }
    for (final key in _receipt().keys) {
      expect(() => _origin(receipt: _receipt()..remove(key)), _invalid);
    }
  });

  test('malformed root versions phases types and arity fail content-free', () {
    for (final text in [
      '', '[', '{}', 'null', '[5]', '[5.0]',
      _changedRoot(0, 4), _changedRoot(0, 5.0),
      _changedRoot(1, -1), _changedRoot(1, 4), _changedRoot(1, 1.0),
      _changedRoot(2, null), _changedRoot(3, _receipt()), _changedRoot(4, null),
      jsonEncode([...(jsonDecode(_origin().encode()) as List), null]),
    ]) {
      expect(() => CloudSyncMessagePreparationRecoveryOrigin.decode(text), _invalid);
    }
    expect(CloudSyncMessagePreparationRecoveryOrigin.isEncoded('[5]'), isTrue);
    expect(CloudSyncMessagePreparationRecoveryOrigin.isEncoded(_origin().encode()), isTrue);
    for (final text in ['[4]', '[5.0]', '{}', '[']) {
      expect(CloudSyncMessagePreparationRecoveryOrigin.isEncoded(text), isFalse);
    }
  });

  test('recovery nesting and replacement legacy bytes are refused', () {
    final nested = _receipt();
    _section(nested, 'source')['admittedChatBinding'] = _origin().encode();
    expect(() => _origin(receipt: nested), _invalid);
    expect(() => CloudSyncMessagePreparationRecoveryOrigin.create(
      legacyBinding: _legacy(direct: true), receipt: _receipt(),
    ), _invalid);
    for (final legacy in [
      jsonEncode([4, _legacy(), (jsonDecode(_legacy()) as List)[2]]),
      ' ${_legacy()}', jsonEncode([4, 'private raw group', 'private body']),
    ]) {
      final value = _receipt();
      _section(value, 'source')['admittedChatBinding'] = legacy;
      expect(() => _origin(receipt: value), _invalid);
    }
  });

  test('legacy direct and group grammar both preserve bytes without normalizing', () {
    for (final direct in [false, true]) {
      final legacy = _legacy(direct: direct);
      final origin = _origin(receipt: _receipt(legacy: legacy));
      expect(origin.legacyBinding, legacy);
      expect(CloudSyncMessagePreparationRecoveryOrigin.decode(origin.encode()).legacyBinding, legacy);
    }
  });

  test('child proof content inventory digest and source remain exact', () {
    for (final field in [0, 1, 3, 4, 5, 6, 8, 9, 10]) {
      final legacy = jsonDecode(_legacy()) as List;
      final proof = jsonDecode(legacy[2] as String) as List;
      proof[field] = field == 0 ? 2 : 'private-replacement';
      legacy[2] = jsonEncode(proof);
      final receipt = _receipt(legacy: jsonEncode(legacy));
      expect(() => _origin(receipt: receipt), _invalid);
    }
    final legacy = jsonDecode(_legacy()) as List;
    final proof = jsonDecode(legacy[2] as String) as List;
    (proof[9] as List)[0][4] = 'private raw GUID';
    proof[10] = _sha(jsonEncode(proof.take(10).toList()));
    legacy[2] = jsonEncode(proof);
    expect(() => _origin(receipt: _receipt(legacy: jsonEncode(legacy))), _invalid);
    final maximum = _origin(receipt: _receipt(legacy: _legacy(attachments: 64)));
    expect(CloudSyncMessagePreparationRecoveryOrigin.decode(maximum.encode()).encode(), maximum.encode());
    expect(() => _origin(receipt: _receipt(legacy: _legacy(attachments: 65))), _invalid);
  });

  test('nullable historical metadata accepts typed values without submission inference', () {
    final receipt = _receipt();
    _section(receipt, 'operation').addAll({
      'appleRequestUuid': '11111111-2222-3333-4444-555555555555',
      'appleOperationUuid': 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
      'protectedLeaseReference': _lease('c'), 'leaseIdHash': _hex('d'),
      'leaseExpiresAtMs': 120, 'confirmedAtMs': 130,
    });
    _section(receipt, 'recordMap').addAll({
      'etagHash': _token('T'), 'encryptedRawRecordRef': _ref('U'),
      'rawRecordGeneration': 1, 'protectedReadbackLeaseReference': _lease('d'),
      'pendingUpdateOperationId': _op('e'), 'pendingUpdatePredecessorEtagHash': _token('V'),
    });
    _section(receipt, 'source')['confirmedReadbackBindingSha256'] = _hex('b');
    expect(_origin(receipt: receipt).operation['appleRequestUuid'], isNotNull);
    expect(_origin(receipt: receipt).operation['state'], 4);
    for (final section in ['operation', 'recordMap', 'source']) {
      for (final key in _section(_receipt(), section).keys.where(
        (key) => _section(_receipt(), section)[key] == null,
      )) {
        for (final wrong in [false, 1, 1.0, 'private text', <Object?>[]]) {
          final bad = _receipt();
          _section(bad, section)[key] = wrong;
          expect(() => _origin(receipt: bad), _invalid, reason: '$section.$key');
        }
      }
    }
  });

  test('strict IDs references and numeric types reject private or ambiguous inputs', () {
    final changes = <String, Map<String, Object?>>{
      'operation': {
        'id': 30.0, 'operationId': 'op1:${_hex('A')}', 'scopeKey': _hex('5'),
        'accountFingerprint': '${_token('A')}\n', 'zone': 'chatManateeZone',
        'payloadVersion': 1, 'action': 1, 'state': 5, 'localChatOrigin': '[5]',
        'encryptedPayloadRef': 'obcs2.ref.short', 'lastErrorCategory': 'private exception',
        'attemptCount': -1, 'mutationRevision': 9007199254740992,
        'dependencyOperationIdsJson': '["private operation"]',
      },
      'recordMap': {'mapKey': 'private record', 'etagHash': _hex('e'), 'generation': 0},
      'source': {'idsConfirmationVersion': 1, 'state': 1, 'messageGuidHash': 'raw GUID'},
      'stage': {'leaseReference': 'obcs2.lease.${'B' * 32}', 'payloadSha256': '${_hex('6')}\n'},
      'binding': {'owner': 'legacy', 'nativeSessionId': _hex('a'), 'writerEpoch': true},
    };
    for (final section in changes.entries) {
      for (final field in section.value.entries) {
        final bad = _receipt();
        _section(bad, section.key)[field.key] = field.value;
        expect(() => _origin(receipt: bad), _invalid, reason: '${section.key}.${field.key}');
      }
    }
  });

  test('stage cannot change payload key record identity or reuse original ownership', () {
    for (final entry in <MapEntry<String, Object?>>[
      MapEntry('payloadSha256', _hex('a')), MapEntry('logicalEntityKeyHash', _token('X')),
      MapEntry('serverRecordIdHash', _token('Y')), MapEntry('leaseReference', _lease('a')),
      MapEntry('protectedPayloadReference', _ref('O')),
    ]) {
      final bad = _receipt();
      _section(bad, 'stage')[entry.key] = entry.value;
      if (entry.key == 'protectedPayloadReference') {
        _section(bad, 'stage')['protectedServerRecordReference'] = entry.value;
      }
      expect(() => _origin(receipt: bad), _invalid);
    }
    for (final section in ['recordMap', 'source', 'binding']) {
      final bad = _receipt();
      _section(bad, section)['accountFingerprint'] = _token('Z');
      expect(() => _origin(receipt: bad), _invalid);
    }
    final bad = _receipt()..['legacyAdoptionSha256'] = _hex('a');
    expect(() => _origin(receipt: bad), _invalid);
  });

  test('native protected source is validated rather than accepting arbitrary JSON', () {
    final source = jsonDecode(_nativeSource()) as List;
    for (var i = 0; i < source.length; i++) {
      final altered = [...source]..[i] = i == 0 ? 1.0 : 'private source text';
      final bad = _receipt();
      _section(bad, 'source')['protectedSourceBinding'] = jsonEncode(altered);
      expect(() => _origin(receipt: bad), _invalid);
    }
  });

  test('encoded depth node UTF16 and UTF8 bounds fail before JSON allocation', () {
    for (final encoded in [
      '[5,${'[' * 10000}0${']' * 10000}]',
      '[5,${List.filled(4097, '0').join(',')}]',
      'x' * 65537,
      jsonEncode([5, 0, '界' * 45000, '', _hex('a')]),
      _rawRoot(' ' * 32769),
      _rawRoot('界' * 22000),
      '\ud800', '\udc00',
    ]) {
      expect(() => CloudSyncMessagePreparationRecoveryOrigin.decode(encoded), _invalid);
    }
    expect(CloudSyncMessagePreparationRecoveryOrigin.isEncoded('x' * 65537), isFalse);
  });

  test('typed container bounds precede element reads and cycles remain bounded', () {
    expect(() => _origin(receipt: _receipt()..['private'] = _OversizedUnreadableList()), _invalid);
    final cycle = <String, Object?>{};
    cycle['self'] = cycle;
    expect(() => _origin(receipt: _receipt()..['private'] = cycle), _invalid);
    for (final text in ['x' * 32769, '界' * 22000, '\ud800', '\udc00']) {
      final receipt = _receipt();
      _section(receipt, 'binding')['ownershipSnapshotSha256'] = text;
      expect(() => _origin(receipt: receipt), _invalid);
    }
    for (final value in [double.nan, double.infinity, <Object?>{}, Object(), {1: 'private'}]) {
      expect(() => _origin(receipt: _receipt()..['private'] = value), _invalid);
    }
  });

  test('toString and errors redact every audit and embedded source value', () {
    final origin = _origin();
    expect(origin.toString(), 'CloudSyncMessagePreparationRecoveryOrigin(redacted)');
    try {
      CloudSyncMessagePreparationRecoveryOrigin.decode('${origin.encode()} private payload');
      fail('expected fixed refusal');
    } on StateError catch (error) {
      expect(error.message, CloudSyncMessagePreparationRecoveryOrigin.invalidCode);
      for (final private in ['private payload', _ref('O'), _lease('b'), _token('A'), origin.canonicalReceipt]) {
        expect(error.toString(), isNot(contains(private)));
        expect(origin.toString(), isNot(contains(private)));
      }
    }
  });
}
