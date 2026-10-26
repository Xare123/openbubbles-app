import 'dart:collection';
import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_archive_recovery_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_preparation_recovery_origin.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic syntax metadata only: no models, native DTOs, auth stubs or storage.
String _hex(String c) => c * 64;
String _token(String c) => c * 43;
String _ref(String c) => 'obcs2.ref.${_token(c)}';
String _lease(String c) => 'obcs2.lease.${c * 32}';
String _op(String c) => 'op1:${_hex(c)}';
String _scope(String c) => 'scope2:${_hex(c)}';
String _sha(String value) => sha256.convert(utf8.encode(value)).toString();
String get _store => 'obcs2.store.${_token('P')}';
Map<String, Object?> _section(Map<String, Object?> value, String key) =>
    value[key]! as Map<String, Object?>;

String _legacy() {
  final chat = jsonEncode([
    3, _scope('b'), 1, 55, _hex('c'), _hex('d'),
    _token('E'), _token('F'), _token('G'), _token('H'), _hex('e'),
  ]);
  final body = <Object?>[
    1,
    '${_token('A')}\u001fcom.apple.messages.cloud\u001fprivate\u001fattachmentManateeZone\u001fmessages\u001f2\u001fsemantic',
    1, 201, _hex('f'), _hex('1'), _store, 7, [_token('0')],
    [[501, _token('0'), _token('J'), _hex('2'), _op('0')]],
  ];
  return jsonEncode([4, chat, jsonEncode([...body, _sha(jsonEncode(body))])]);
}

Map<String, Object?> _preparationReceipt() => {
  'schema': 1, 'reason': CloudSyncMessagePreparationRecoveryOrigin.reason,
  'mode': CloudSyncMessagePreparationRecoveryOrigin.mode,
  'operation': {
    'id': 101, 'operationId': _op('4'), 'scopeKey': _scope('5'),
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
    'id': 401, 'mapKey': 'record-map:${_hex('7')}', 'scopeKey': _scope('5'),
    'accountFingerprint': _token('A'), 'zone': 'messageManateeZone',
    'logicalEntityKeyHash': _token('K'), 'serverRecordIdHash': _token('R'),
    'generation': 1, 'encryptedServerRecordId': _ref('O'), 'etagHash': null,
    'encryptedRawRecordRef': null, 'rawRecordGeneration': 0,
    'protectedReadbackLeaseReference': null, 'pendingUpdateOperationId': null,
    'pendingUpdatePredecessorEtagHash': null, 'updatedAtMs': 200,
  },
  'source': {
    'id': 201, 'intentKey': _hex('8'), 'accountFingerprint': _token('A'),
    'writerEpoch': 7, 'localMessageId': 301, 'messageGuidHash': _hex('f'),
    'sourceSha256': _hex('1'), 'state': 2, 'admittedOperationId': _op('4'),
    'admittedBindingSha256': _hex('9'), 'admittedChatBinding': _legacy(),
    'confirmedReadbackBindingSha256': null, 'idsConfirmationVersion': 2,
    'protectedSourceBinding': jsonEncode([
      1, 'idsAttachmentSource', _token('A'), _store, _hex('f'), _hex('1'),
      _ref('S'), _lease('a'), _hex('3'), 1009,
    ]),
    'createdAtMs': 11, 'updatedAtMs': 99,
  },
  'stage': {
    'protectedPayloadReference': _ref('N'), 'protectedServerRecordReference': _ref('N'),
    'leaseReference': _lease('b'), 'payloadSha256': _hex('6'),
    'logicalEntityKeyHash': _token('K'), 'serverRecordIdHash': _token('R'),
  },
  'binding': <String, Object?>{
    'scopeKey': _scope('5'), 'accountFingerprint': _token('A'), 'checkpointGeneration': 1,
    'chatId': 55, 'intentId': 201, 'localMessageId': 301,
    'nativeSessionId': _token('C'), 'protectedStoreIdentity': _store,
    'owner': 'v2', 'writerEpoch': 10, 'ownershipEpoch': 9,
    'ownershipSnapshotSha256': _hex('a'), 'recoveredAtMs': 300,
  },
  'legacyAdoptionSha256': _hex('9'),
};

CloudSyncMessagePreparationRecoveryOrigin _preparation({
  CloudSyncMessagePreparationRecoveryPhase phase =
      CloudSyncMessagePreparationRecoveryPhase.retained,
  Map<String, Object?>? receipt,
}) => CloudSyncMessagePreparationRecoveryOrigin.create(
  legacyBinding: _legacy(), receipt: receipt ?? _preparationReceipt(), phase: phase,
);

Map<String, Object?> _receipt(CloudSyncMessagePreparationRecoveryOrigin preparation) => {
  'schema': 1, 'reason': CloudSyncMessageArchiveRecoveryOrigin.reason,
  'mode': CloudSyncMessageArchiveRecoveryOrigin.mode,
  'preparationSha256': _sha(preparation.encode()),
  'operation': {...preparation.operation},
  'recordMap': {...preparation.recordMap},
  'source': {
    ...preparation.source, 'admittedChatBinding': preparation.encode(),
    'admittedBindingSha256': _hex('b'),
  },
  'binding': <String, Object?>{
    'scopeKey': _scope('5'), 'accountFingerprint': _token('A'), 'checkpointGeneration': 1,
    'chatId': 55, 'intentId': 201, 'localMessageId': 301,
    'nativeSessionId': _token('D'), 'protectedStoreIdentity': _store,
    'writerEpoch': 20, 'ownershipEpoch': 17, 'ownershipSnapshotSha256': _hex('c'),
    'activatedAtMs': 400,
  },
};

CloudSyncMessageArchiveRecoveryOrigin _origin({
  CloudSyncMessagePreparationRecoveryOrigin? preparation,
  Map<String, Object?>? receipt,
}) {
  final previous = preparation ?? _preparation();
  return CloudSyncMessageArchiveRecoveryOrigin.create(
    preparationBinding: previous.encode(), receipt: receipt ?? _receipt(previous));
}

String _root(String receipt, {String? preparation, String? hash}) => jsonEncode([
  6, preparation ?? _preparation().encode(), receipt, hash ?? _sha(receipt),
]);

final _invalid = throwsA(isA<StateError>().having(
  (error) => error.message, 'fixed content-free code',
  CloudSyncMessageArchiveRecoveryOrigin.invalidCode,
));

final class _UnreadableOversizedList extends ListBase<Object?> {
  @override
  int get length => 4097;
  @override
  set length(int value) => throw StateError('private-container-access');
  @override
  Object? operator [](int index) => throw StateError('private-container-access');
  @override
  void operator []=(int index, Object? value) => throw StateError('private-container-access');
}

final class _UnreadableOversizedMap extends MapBase<String, Object?> {
  @override
  int get length => 4097;
  @override
  Iterable<String> get keys => throw StateError('private-container-access');
  @override
  Object? operator [](Object? key) => throw StateError('private-container-access');
  @override
  void operator []=(String key, Object? value) => throw StateError('private-container-access');
  @override
  void clear() => throw StateError('private-container-access');
  @override
  Object? remove(Object? key) => throw StateError('private-container-access');
}

void main() {
  test('version6 retains complete original snapshots and full current v5 source', () {
    final preparation = _preparation();
    final receipt = _receipt(preparation);
    final origin = _origin(preparation: preparation, receipt: receipt);
    final decoded = CloudSyncMessageArchiveRecoveryOrigin.decode(origin.encode());
    expect(jsonDecode(origin.encode()), [
      6, preparation.encode(), origin.canonicalReceipt, origin.receiptSha256,
    ]);
    expect(decoded.encode(), origin.encode());
    expect(decoded.preparationBinding, preparation.encode());
    expect(decoded.preparation.encode(), preparation.encode());
    expect(decoded.preparation.phase, CloudSyncMessagePreparationRecoveryPhase.retained);
    expect(decoded.legacyBinding, preparation.legacyBinding);
    expect(decoded.operation, preparation.operation);
    expect(decoded.recordMap, preparation.recordMap);
    expect(decoded.source, receipt['source']);
    expect(decoded.source['admittedChatBinding'], preparation.encode());
    expect(decoded.source['admittedBindingSha256'], _hex('b'));
    expect(decoded.operation['state'], 4);
    expect(decoded.operation['localChatOrigin'], isNull);
    expect(decoded.operation['encryptedPayloadRef'], _ref('O'));
    expect(decoded.preparation.freshProtectedReference, _ref('N'));
    expect(decoded.preparation.stage['protectedServerRecordReference'], _ref('N'));
    expect(decoded.receiptSha256, _sha(decoded.canonicalReceipt));
  });

  test('current owner metadata and independent source times do not pretend old auth', () {
    final origin = _origin();
    expect(origin.source['writerEpoch'], 7);
    expect(origin.preparation.binding['writerEpoch'], 10);
    expect(origin.binding['writerEpoch'], 20);
    expect(origin.binding['ownershipEpoch'], 17);
    expect(origin.binding['nativeSessionId'], isNot(origin.preparation.binding['nativeSessionId']));
    expect(origin.source['createdAtMs'], 11);
    expect(origin.operation['createdAtMs'], 100);
    expect(origin.source['updatedAtMs'], 99);
    expect(origin.binding['activatedAtMs'], 400);
  });

  test('nullable old Apple IDs are preserved without inferring execution history', () {
    final receipt = _preparationReceipt();
    _section(receipt, 'operation')
      ..['appleRequestUuid'] = '11111111-1111-1111-1111-111111111111'
      ..['appleOperationUuid'] = '22222222-2222-2222-2222-222222222222';
    final preparation = _preparation(receipt: receipt);
    final origin = _origin(preparation: preparation);
    expect(origin.operation, preparation.operation);
    expect(CloudSyncMessageArchiveRecoveryOrigin.decode(origin.encode()).operation,
      preparation.operation);
  });

  test('only a retained v5 may be embedded, with no nested archive wrapper', () {
    for (final phase in CloudSyncMessagePreparationRecoveryPhase.values) {
      if (phase != CloudSyncMessagePreparationRecoveryPhase.retained) {
        expect(() => _origin(preparation: _preparation(phase: phase)), _invalid);
      }
    }
    for (final previous in ['[5]', '[6]', _origin().encode(), _legacy(), 'private invalid text']) {
      expect(() => CloudSyncMessageArchiveRecoveryOrigin.create(
        preparationBinding: previous, receipt: _receipt(_preparation())), _invalid);
    }
  });

  test('current source cannot be substituted with the pre-v5 source or a hash placeholder', () {
    final preparation = _preparation();
    for (final source in [preparation.source, _sha(preparation.encode()), null]) {
      final receipt = _receipt(preparation)..['source'] = source;
      expect(() => _origin(receipt: receipt), _invalid);
    }
    final missingProtectedSource = _receipt(preparation);
    _section(missingProtectedSource, 'source')['protectedSourceBinding'] = null;
    expect(() => _origin(receipt: missingProtectedSource), _invalid);
    for (final field in preparation.source.keys.where(
      (key) => key != 'admittedChatBinding' && key != 'admittedBindingSha256',
    )) {
      final receipt = _receipt(preparation);
      _section(receipt, 'source')[field] = 'changed';
      expect(() => _origin(receipt: receipt), _invalid, reason: field);
    }
  });

  for (final section in ['operation', 'recordMap', 'source', 'binding']) {
    test('$section has a closed complete schema including nullable fields', () {
      final preparation = _preparation();
      final receipt = _receipt(preparation);
      for (final field in _section(receipt, section).keys) {
        final missing = _receipt(preparation);
        _section(missing, section).remove(field);
        expect(() => _origin(receipt: missing), _invalid, reason: field);
      }
      final extra = _receipt(preparation);
      _section(extra, section)['privateText'] = 'private message';
      expect(() => _origin(receipt: extra), _invalid);
    });
  }

  test('operation and mapping must remain the original v5 snapshots', () {
    final preparation = _preparation();
    for (final section in ['operation', 'recordMap']) {
      for (final entry in _section(_receipt(preparation), section).entries) {
        final changed = _receipt(preparation);
        _section(changed, section)[entry.key] = switch (entry.value) {
          final int n => n + 1,
          final String s => '$s-changed',
          _ => false,
        };
        expect(() => _origin(receipt: changed), _invalid, reason: entry.key);
      }
    }
  });

  test('binding pins original scope store generation and all local IDs', () {
    for (final entry in {
      'scopeKey': _scope('a'), 'accountFingerprint': _token('B'),
      'checkpointGeneration': 2, 'chatId': 56, 'intentId': 202, 'localMessageId': 302,
      'protectedStoreIdentity': 'obcs2.store.${_token('Q')}',
    }.entries) {
      final receipt = _receipt(_preparation());
      _section(receipt, 'binding')[entry.key] = entry.value;
      expect(() => _origin(receipt: receipt), _invalid, reason: entry.key);
    }
  });

  test('current binding and adoption SHA enforce exact scalar grammars', () {
    for (final key in ['nativeSessionId', 'ownershipSnapshotSha256', 'writerEpoch',
      'ownershipEpoch', 'activatedAtMs']) {
      for (final value in [null, false, 0, -1, 1.0, 9007199254740992, 'private text']) {
        final receipt = _receipt(_preparation());
        _section(receipt, 'binding')[key] = value;
        expect(() => _origin(receipt: receipt), _invalid, reason: '$key=$value');
      }
    }
    final swappedEpochs = _receipt(_preparation());
    _section(swappedEpochs, 'binding')['ownershipEpoch'] = 21;
    expect(() => _origin(receipt: swappedEpochs), _invalid);
    for (final value in [null, _hex('A'), '${_hex('b')}\n', _hex('b').substring(1), false]) {
      final receipt = _receipt(_preparation());
      _section(receipt, 'source')['admittedBindingSha256'] = value;
      expect(() => _origin(receipt: receipt), _invalid);
    }
  });

  test('root receipt schema mode reason and preparation digest are exact', () {
    final receipt = _receipt(_preparation());
    for (final field in receipt.keys) {
      expect(() => _origin(receipt: {...receipt}..remove(field)), _invalid, reason: field);
    }
    for (final extra in ['phase', 'stage', 'consume', 'save', 'auth', 'rawGuid']) {
      expect(() => _origin(receipt: {...receipt, extra: 'private'}), _invalid);
    }
    for (final change in [
      {'schema': 1.0}, {'reason': 'message-preparation-recovery-v1'},
      {'mode': 'preparation-only'}, {'preparationSha256': _hex('0')},
    ]) {
      expect(() => _origin(receipt: {...receipt, ...change}), _invalid);
    }
  });

  test('receipt and root tampering including duplicate keys never normalizes silently', () {
    final origin = _origin();
    final changed = origin.canonicalReceipt.replaceFirst('"attemptCount":3', '"attemptCount":4');
    for (final encoded in [
      _root(changed, hash: origin.receiptSha256),
      _root(changed),
      _root(origin.canonicalReceipt, hash: _hex('0')),
      _root(' ${origin.canonicalReceipt}'),
      _root(origin.canonicalReceipt.replaceFirst('"schema":1', '"schema":1,"schema":1')),
      _root(origin.canonicalReceipt.replaceFirst('"id":101', '"id":101,"id":101')),
      ' ${origin.encode()}',
      origin.encode().replaceFirst('[6,', '[6.0,'),
      origin.encode().replaceFirst('[6,', '[7,'),
      jsonEncode([6, origin.preparationBinding, origin.canonicalReceipt, origin.receiptSha256, null]),
    ]) {
      expect(() => CloudSyncMessageArchiveRecoveryOrigin.decode(encoded), _invalid);
    }
  });

  test('input map order is canonical and input mutation cannot alter frozen evidence', () {
    Object? reversed(Object? value) => value is Map<String, Object?>
        ? {for (final key in value.keys.toList().reversed) key: reversed(value[key])} : value;
    final preparation = _preparation();
    final receipt = _receipt(preparation);
    final origin = _origin(receipt: receipt);
    final encoded = origin.encode();
    expect(_origin(receipt: reversed(receipt)! as Map<String, Object?>).encode(), encoded);
    _section(receipt, 'source')['admittedBindingSha256'] = _hex('f');
    _section(receipt, 'operation')['state'] = 0;
    receipt.clear();
    expect(origin.encode(), encoded);
    expect(() => origin.receipt.clear(), throwsUnsupportedError);
    expect(() => origin.operation['state'] = 0, throwsUnsupportedError);
    expect(() => origin.recordMap.clear(), throwsUnsupportedError);
    expect(() => origin.source.clear(), throwsUnsupportedError);
    expect(() => origin.binding.clear(), throwsUnsupportedError);
    expect(() => origin.preparation.receipt.clear(), throwsUnsupportedError);
  });

  test('discriminator identifies version6 without authenticating its shape', () {
    expect(CloudSyncMessageArchiveRecoveryOrigin.isEncoded(_origin().encode()), isTrue);
    expect(CloudSyncMessageArchiveRecoveryOrigin.isEncoded('[6]'), isTrue);
    expect(() => CloudSyncMessageArchiveRecoveryOrigin.decode('[6]'), _invalid);
    for (final encoded in ['[6.0]', '[5]', '[7]', '[', 'null', 'private']) {
      expect(CloudSyncMessageArchiveRecoveryOrigin.isEncoded(encoded), isFalse);
      expect(() => CloudSyncMessageArchiveRecoveryOrigin.decode(encoded), _invalid);
    }
  });

  test('encoded UTF16 UTF8 depth and node limits apply before JSON allocation', () {
    expect(CloudSyncMessageArchiveRecoveryOrigin.maximumEncodedCodeUnits, 262144);
    expect(CloudSyncMessageArchiveRecoveryOrigin.maximumEncodedBytes, 524288);
    for (final encoded in [
      'x' * 262145, '"${'中' * 180000}"',
      '${'[' * 17}0${']' * 17}', '[${List.filled(4097, '0').join(',')}]',
      String.fromCharCode(0xd800), String.fromCharCode(0xdc00),
    ]) {
      expect(() => CloudSyncMessageArchiveRecoveryOrigin.decode(encoded), _invalid);
      expect(CloudSyncMessageArchiveRecoveryOrigin.isEncoded(encoded), isFalse);
    }
  });

  test('typed containers and invalid UTF16 are bounded before copying or sorting', () {
    final receipt = _receipt(_preparation());
    for (final value in [_UnreadableOversizedList(), _UnreadableOversizedMap()]) {
      expect(() => _origin(receipt: {...receipt, 'private': value}), _invalid);
    }
    expect(() => _origin(receipt: _UnreadableOversizedMap()), _invalid);
    final cycle = <Object?>[];
    cycle.add(cycle);
    expect(() => _origin(receipt: {...receipt, 'private': cycle}), _invalid);
    for (final value in ['x' * 262145, String.fromCharCode(0xd800)]) {
      expect(() => _origin(receipt: {...receipt, 'private': value}), _invalid);
    }
  });

  test('toString and failures expose only fixed redacted text', () {
    final origin = _origin();
    expect(origin.toString(), 'CloudSyncMessageArchiveRecoveryOrigin(redacted)');
    try {
      _origin(receipt: _receipt(_preparation())..['private'] = 'private message');
      fail('invalid receipt accepted');
    } on StateError catch (error) {
      expect(error.message, CloudSyncMessageArchiveRecoveryOrigin.invalidCode);
      for (final private in ['private message', _ref('O'), _lease('b'),
        origin.preparationBinding, origin.canonicalReceipt]) {
        expect(error.toString(), isNot(contains(private)));
        expect(origin.toString(), isNot(contains(private)));
      }
    }
  });
}
