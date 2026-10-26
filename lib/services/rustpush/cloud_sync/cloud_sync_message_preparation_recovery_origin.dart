import 'dart:convert';

import 'package:crypto/crypto.dart';

enum CloudSyncMessagePreparationRecoveryPhase {
  adopted,
  committed,
  retained,
  retired,
}

/// Bounded syntax for admittedChatBinding version 5, NEVER recovery authority.
///
/// The journal/store must authenticate the original persisted snapshots, legacy
/// adoption, native source and fresh stage, then adopt the new owner BEFORE
/// native commit. Neither this unkeyed receipt hash nor a phase proves that any
/// of those actions occurred. No phase permits save, consume, IDS or replay.
/// Retained means the committed preparation lease remains durably live; only a
/// separately authorized disposal may retire it. Do not change localChatOrigin
/// or protectedSourceBinding to install this wrapper.
final class CloudSyncMessagePreparationRecoveryOrigin {
  CloudSyncMessagePreparationRecoveryOrigin._({
    required this.legacyBinding,
    required this.receipt,
    required this.canonicalReceipt,
    required this.receiptSha256,
    required this.phase,
  }) {
    _encoded = jsonEncode([
      5, phase.index, legacyBinding, canonicalReceipt, receiptSha256,
    ]);
    _checkSize(_encoded, maximumEncodedCodeUnits, maximumEncodedBytes);
  }

  static const maximumEncodedCodeUnits = 65536;
  static const maximumEncodedBytes = 131072;
  static const maximumReceiptCodeUnits = 32768;
  static const maximumReceiptBytes = 65536;
  static const maximumLegacyBindingCodeUnits = 24576;
  static const maximumJsonDepth = 16;
  static const maximumJsonNodes = 4096;
  static const maximumAttachments = 64;
  static const reason = 'message-preparation-recovery-v1';
  static const mode = 'preparation-only';
  static const invalidCode = 'cloud_sync_message_preparation_recovery_origin_invalid';

  final String legacyBinding;
  final Map<String, Object?> receipt;
  final String canonicalReceipt;
  final String receiptSha256;
  final CloudSyncMessagePreparationRecoveryPhase phase;
  late final String _encoded;

  Map<String, Object?> get operation => _map(receipt['operation']);
  Map<String, Object?> get recordMap => _map(receipt['recordMap']);
  Map<String, Object?> get source => _map(receipt['source']);
  Map<String, Object?> get stage => _map(receipt['stage']);
  Map<String, Object?> get binding => _map(receipt['binding']);
  String get operationId => operation['operationId']! as String;
  String get freshLeaseReference => stage['leaseReference']! as String;
  String get freshProtectedReference => stage['protectedPayloadReference']! as String;
  String get payloadSha256 => stage['payloadSha256']! as String;
  String get logicalEntityKeyHash => stage['logicalEntityKeyHash']! as String;
  String get serverRecordIdHash => stage['serverRecordIdHash']! as String;
  String get legacyAdoptionSha256 => receipt['legacyAdoptionSha256']! as String;

  /// A liveness hint for an independently authenticated durable owner, not proof
  /// of commit and not permission to acknowledge, release or submit anything.
  bool get retainsFreshLease => phase != CloudSyncMessagePreparationRecoveryPhase.retired;

  static CloudSyncMessagePreparationRecoveryOrigin create({
    required String legacyBinding,
    required Map<String, Object?> receipt,
    CloudSyncMessagePreparationRecoveryPhase phase =
        CloudSyncMessagePreparationRecoveryPhase.adopted,
  }) {
    final data = _receipt(receipt);
    if (legacyBinding != _map(data.value['source'])['admittedChatBinding']) {
      _invalid();
    }
    return CloudSyncMessagePreparationRecoveryOrigin._(
      legacyBinding: legacyBinding,
      receipt: data.value,
      canonicalReceipt: data.canonical,
      receiptSha256: data.digest,
      phase: phase,
    );
  }

  static CloudSyncMessagePreparationRecoveryOrigin decode(String encoded) {
    final root = _decodeJson(encoded, maximumEncodedCodeUnits, maximumEncodedBytes);
    if (root is! List || root.length != 5 || root[0] is! int || root[0] != 5 ||
        root[1] is! int || (root[1] as int) < 0 ||
        (root[1] as int) >= CloudSyncMessagePreparationRecoveryPhase.values.length ||
        root[2] is! String || root[3] is! String || !_digest(root[4])) {
      _invalid();
    }
    final decoded = _decodeJson(
      root[3] as String, maximumReceiptCodeUnits, maximumReceiptBytes,
    );
    final result = create(
      legacyBinding: root[2] as String,
      receipt: _map(decoded),
      phase: CloudSyncMessagePreparationRecoveryPhase.values[root[1] as int],
    );
    // Reject duplicate keys and alternative encodings even with a recomputed
    // hash. A canonical unkeyed hash still cannot authenticate an edited audit.
    if (result.canonicalReceipt != root[3] || result.receiptSha256 != root[4] ||
        result.encode() != encoded) {
      _invalid();
    }
    return result;
  }

  /// A discriminator only, including malformed version-five tuples.
  static bool isEncoded(String encoded) {
    try {
      final root = _decodeJson(encoded, maximumEncodedCodeUnits, maximumEncodedBytes);
      return root is List && root.isNotEmpty && root[0] is int && root[0] == 5;
    } on StateError {
      return false;
    }
  }

  static String canonicalReceiptFor(Map<String, Object?> receipt) =>
      _receipt(receipt).canonical;

  static String receiptDigestFor(Map<String, Object?> receipt) =>
      _receipt(receipt).digest;

  String encode() => _encoded;
  String unwrapLegacyBinding() => legacyBinding;

  /// Syntax permits forward lifecycle transitions only. The caller must prove
  /// commit/diagnostic/disposal and persist phase plus adoption binding together.
  CloudSyncMessagePreparationRecoveryOrigin withPhase(
    CloudSyncMessagePreparationRecoveryPhase next,
  ) {
    if (next == phase) {
      return this;
    }
    if (next.index != phase.index + 1) {
      _invalid();
    }
    return CloudSyncMessagePreparationRecoveryOrigin._(
      legacyBinding: legacyBinding,
      receipt: receipt,
      canonicalReceipt: canonicalReceipt,
      receiptSha256: receiptSha256,
      phase: next,
    );
  }

  static final _hex = RegExp(r'^[a-f0-9]{64}$');
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _scopePattern = RegExp(r'^scope2:[a-f0-9]{64}$');
  static final _operationPattern = RegExp(r'^op1:[a-f0-9]{64}$');
  static final _mapKeyPattern = RegExp(r'^record-map:[a-f0-9]{64}$');
  static final _referencePattern = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
  static final _leasePattern = RegExp(r'^obcs2\.lease\.[a-f0-9]{32}$');
  static final _storePattern = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static final _uuidPattern = RegExp(
    r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
  );
  static const _failures = {
    'network', 'throttled', 'server', 'authorization', 'pcsUnavailable',
    'malformedRecord', 'conflict', 'dependency', 'localStorage', 'cancelled',
    'unknown', 'unsupportedService', 'outOfScopeService',
  };

  // These are the COMPLETE persisted scalar snapshot field sets used by the
  // existing fresh-group snapshot helpers, with Message-specific value rules.
  static final _operationFields = <String, bool Function(Object?)>{
    'id': _positive, 'operationId': _operationId, 'scopeKey': _scope,
    'accountFingerprint': _token, 'zone': (v) => v == 'messageManateeZone',
    'logicalEntityKeyHash': _token, 'action': (v) => v is int && v == 0,
    'dependencyOperationIdsJson': (v) => v == '[]',
    'payloadVersion': (v) => v is int && v == 2,
    'mutationRevision': _unsigned, 'checkpointGeneration': _positive,
    'appleRequestUuid': _nullable(_uuid), 'appleOperationUuid': _nullable(_uuid),
    'encryptedPayloadRef': _reference, 'payloadSha256': _digest,
    'protectedLeaseReference': _nullable(_lease), 'localChatOrigin': (v) => v == null,
    'state': (v) => v is int && v == 4, 'attemptCount': _unsigned,
    'nextEligibleAtMs': _unsigned,
    'lastErrorCategory': _nullable((v) => v is String && _failures.contains(v)),
    'serverRecordIdHash': _token, 'leaseIdHash': _nullable(_digest),
    'leaseExpiresAtMs': _unsigned, 'confirmedAtMs': _unsigned,
    'createdAtMs': _positive, 'updatedAtMs': _positive,
  };
  static final _mapFields = <String, bool Function(Object?)>{
    'id': _positive, 'mapKey': (v) => _match(_mapKeyPattern, v), 'scopeKey': _scope,
    'accountFingerprint': _token, 'zone': (v) => v == 'messageManateeZone',
    'logicalEntityKeyHash': _token, 'serverRecordIdHash': _token,
    'generation': _positive, 'encryptedServerRecordId': _reference,
    'etagHash': _nullable(_token), 'encryptedRawRecordRef': _nullable(_reference),
    'rawRecordGeneration': _unsigned,
    'protectedReadbackLeaseReference': _nullable(_lease),
    'pendingUpdateOperationId': _nullable(_operationId),
    'pendingUpdatePredecessorEtagHash': _nullable(_token), 'updatedAtMs': _unsigned,
  };
  static final _sourceFields = <String, bool Function(Object?)>{
    'id': _positive, 'intentKey': _digest, 'accountFingerprint': _token,
    'writerEpoch': _positive, 'localMessageId': _positive,
    'messageGuidHash': _digest, 'sourceSha256': _digest,
    'state': (v) => v is int && v == 2, 'admittedOperationId': _operationId,
    'admittedBindingSha256': _digest, 'admittedChatBinding': _string,
    'confirmedReadbackBindingSha256': _nullable(_digest),
    'idsConfirmationVersion': (v) => v is int && v == 2,
    'protectedSourceBinding': _string, 'createdAtMs': _positive,
    'updatedAtMs': _positive,
  };
  static final _stageFields = <String, bool Function(Object?)>{
    'protectedPayloadReference': _reference, 'protectedServerRecordReference': _reference,
    'leaseReference': _lease, 'payloadSha256': _digest,
    'logicalEntityKeyHash': _token, 'serverRecordIdHash': _token,
  };
  static final _bindingFields = <String, bool Function(Object?)>{
    'scopeKey': _scope, 'accountFingerprint': _token, 'checkpointGeneration': _positive,
    'chatId': _positive, 'intentId': _positive, 'localMessageId': _positive,
    'nativeSessionId': _token, 'protectedStoreIdentity': _store,
    'owner': (v) => v == 'v2', 'writerEpoch': _positive, 'ownershipEpoch': _positive,
    'ownershipSnapshotSha256': _digest, 'recoveredAtMs': _positive,
  };

  static _MessageRecoveryReceipt _receipt(Map<String, Object?> input) {
    final value = _ReceiptCopy().copy(input, 1) as Map<String, Object?>;
    const keys = {
      'schema', 'reason', 'mode', 'operation', 'recordMap', 'source', 'stage',
      'binding', 'legacyAdoptionSha256',
    };
    if (value.length != keys.length || !value.keys.every(keys.contains) ||
        value['schema'] is! int || value['schema'] != 1 ||
        value['reason'] != reason || value['mode'] != mode ||
        !_digest(value['legacyAdoptionSha256'])) {
      _invalid();
    }
    final operation = _shape(value['operation'], _operationFields);
    final map = _shape(value['recordMap'], _mapFields);
    final source = _shape(value['source'], _sourceFields);
    final stage = _shape(value['stage'], _stageFields);
    final binding = _shape(value['binding'], _bindingFields);
    final legacy = _legacy(source['admittedChatBinding']! as String);
    final chat = legacy.$1;
    final childProof = legacy.$2;
    final nativeSource = _sourceBinding(source['protectedSourceBinding']! as String);
    // Syntactic self-consistency is not journal/native authentication. In
    // particular, neither null nor present Apple IDs imply execution history.
    if (map['scopeKey'] != operation['scopeKey'] ||
        map['accountFingerprint'] != operation['accountFingerprint'] ||
        map['logicalEntityKeyHash'] != operation['logicalEntityKeyHash'] ||
        map['serverRecordIdHash'] != operation['serverRecordIdHash'] ||
        map['generation'] != operation['checkpointGeneration'] ||
        map['encryptedServerRecordId'] != operation['encryptedPayloadRef'] ||
        source['accountFingerprint'] != operation['accountFingerprint'] ||
        source['admittedOperationId'] != operation['operationId'] ||
        source['admittedBindingSha256'] != value['legacyAdoptionSha256'] ||
        binding['scopeKey'] != operation['scopeKey'] ||
        binding['accountFingerprint'] != operation['accountFingerprint'] ||
        binding['checkpointGeneration'] != operation['checkpointGeneration'] ||
        binding['intentId'] != source['id'] ||
        binding['localMessageId'] != source['localMessageId'] ||
        binding['chatId'] != chat[3] ||
        (binding['ownershipEpoch']! as int) > (binding['writerEpoch']! as int) ||
        stage['payloadSha256'] != operation['payloadSha256'] ||
        stage['logicalEntityKeyHash'] != operation['logicalEntityKeyHash'] ||
        stage['serverRecordIdHash'] != operation['serverRecordIdHash'] ||
        stage['protectedPayloadReference'] != stage['protectedServerRecordReference'] ||
        stage['protectedPayloadReference'] == operation['encryptedPayloadRef'] ||
        stage['leaseReference'] == operation['protectedLeaseReference'] ||
        stage['protectedPayloadReference'] == nativeSource[6] ||
        stage['leaseReference'] == nativeSource[7] ||
        nativeSource[2] != source['accountFingerprint'] ||
        nativeSource[3] != binding['protectedStoreIdentity'] ||
        nativeSource[4] != source['messageGuidHash'] ||
        nativeSource[5] != source['sourceSha256'] ||
        childProof[1] != _storageKey(source['accountFingerprint']! as String, 'attachmentManateeZone') ||
        childProof[3] != source['id'] || childProof[4] != source['messageGuidHash'] ||
        childProof[5] != source['sourceSha256'] || childProof[6] != nativeSource[3]) {
      _invalid();
    }
    for (final row in [operation, source]) {
      if ((row['updatedAtMs']! as int) < (row['createdAtMs']! as int)) {
        _invalid();
      }
    }
    final canonical = jsonEncode(value);
    _checkSize(canonical, maximumReceiptCodeUnits, maximumReceiptBytes);
    return _MessageRecoveryReceipt(value, canonical, _sha(canonical));
  }

  /// Accept exactly a legacy v4 parent binding, never another recovery wrapper.
  static (List<dynamic>, List<dynamic>) _legacy(String encoded) {
    final root = _decodeJson(encoded, maximumLegacyBindingCodeUnits, maximumReceiptBytes);
    if (root is! List || root.length != 3 || root[0] is! int || root[0] != 4 ||
        root[1] is! String || root[2] is! String || jsonEncode(root) != encoded) {
      _invalid();
    }
    final chat = _decodeJson(root[1] as String, 1536, 1536);
    if (chat is! List || chat.isEmpty || chat[0] is! int ||
        !((chat[0] == 1 && chat.length == 9) || (chat[0] == 3 && chat.length == 11)) ||
        !_scope(chat[1]) || !_positive(chat[2]) || !_positive(chat[3]) ||
        !_digest(chat[4]) || !_digest(chat[5]) ||
        chat.skip(6).take(3).any((v) => !_token(v)) ||
        (chat[0] == 3 && (!_token(chat[9]) || !_digest(chat[10]))) ||
        jsonEncode(chat) != root[1]) {
      _invalid();
    }
    final proof = _decodeJson(root[2] as String, maximumLegacyBindingCodeUnits, maximumReceiptBytes);
    if (proof is! List || proof.length != 11 || proof[0] is! int || proof[0] != 1 ||
        !_attachmentScope(proof[1]) || !_positive(proof[2]) || !_positive(proof[3]) ||
        !_digest(proof[4]) || !_digest(proof[5]) || !_store(proof[6]) ||
        !_positive(proof[7]) || proof[8] is! List || proof[9] is! List ||
        !_digest(proof[10]) || jsonEncode(proof) != root[2]) {
      _invalid();
    }
    final keys = proof[8] as List;
    final children = proof[9] as List;
    if (keys.isEmpty || keys.length > maximumAttachments || children.length != keys.length) {
      _invalid();
    }
    final rowIds = <int>{};
    final operationIds = <String>{};
    for (var i = 0; i < keys.length; i++) {
      if (!_token(keys[i]) || (i > 0 && (keys[i - 1] as String).compareTo(keys[i] as String) >= 0)) {
        _invalid();
      }
      final child = children[i];
      if (child is! List || child.length != 5 || !_positive(child[0]) ||
          child[1] != keys[i] || !_token(child[2]) || !_digest(child[3]) ||
          !_operationId(child[4]) || !rowIds.add(child[0] as int) ||
          !operationIds.add(child[4] as String)) {
        _invalid();
      }
    }
    if (_sha(jsonEncode(proof.take(10).toList())) != proof[10]) {
      _invalid();
    }
    return (chat, proof);
  }

  static List<dynamic> _sourceBinding(String encoded) {
    final v = _decodeJson(encoded, 2048, 2048);
    if (v is! List || v.length != 10 || v[0] is! int || v[0] != 1 ||
        v[1] != 'idsAttachmentSource' || !_token(v[2]) || !_store(v[3]) ||
        !_digest(v[4]) || !_digest(v[5]) || !_reference(v[6]) || !_lease(v[7]) ||
        !_digest(v[8]) || !_positive(v[9]) || (v[9] as int) > 1024 * 1024 ||
        jsonEncode(v) != encoded) {
      _invalid();
    }
    return v;
  }

  static String _storageKey(String account, String zone) =>
      '$account\u001fcom.apple.messages.cloud\u001fprivate\u001f$zone\u001fmessages\u001f2\u001fsemantic';

  static bool _attachmentScope(Object? v) {
    if (v is! String) {
      return false;
    }
    final parts = v.split('\u001f');
    return parts.length == 7 && _token(parts[0]) && v == _storageKey(parts[0], 'attachmentManateeZone');
  }

  static Map<String, Object?> _map(Object? v) {
    if (v is! Map<String, Object?>) {
      _invalid();
    }
    return v;
  }

  static Map<String, Object?> _shape(Object? v, Map<String, bool Function(Object?)> fields) {
    final map = _map(v);
    if (map.length != fields.length || !map.keys.every(fields.containsKey) ||
        fields.entries.any((entry) => !entry.value(map[entry.key]))) {
      _invalid();
    }
    return map;
  }

  static bool _match(RegExp pattern, Object? v) {
    if (v is! String) {
      return false;
    }
    final match = pattern.firstMatch(v);
    return match != null && match.start == 0 && match.end == v.length;
  }

  static bool _positive(Object? v) => v is int && v > 0 && v <= 9007199254740991;
  static bool _unsigned(Object? v) => v is int && v >= 0 && v <= 9007199254740991;
  static bool _string(Object? v) => v is String;
  static bool _digest(Object? v) => _match(_hex, v);
  static bool _token(Object? v) => _match(_tokenPattern, v);
  static bool _scope(Object? v) => _match(_scopePattern, v);
  static bool _operationId(Object? v) => _match(_operationPattern, v);
  static bool _reference(Object? v) => _match(_referencePattern, v);
  static bool _lease(Object? v) => _match(_leasePattern, v);
  static bool _store(Object? v) => _match(_storePattern, v);
  static bool _uuid(Object? v) => _match(_uuidPattern, v);
  static bool Function(Object?) _nullable(bool Function(Object?) rule) =>
      (v) => v == null || rule(v);
  static String _sha(String v) => sha256.convert(utf8.encode(v)).toString();

  static int _checkSize(String value, int codeUnits, int bytes) {
    if (value.length > codeUnits) {
      _invalid();
    }
    var count = 0;
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length) {
          _invalid();
        }
        final low = value.codeUnitAt(i);
        if (low < 0xdc00 || low > 0xdfff) {
          _invalid();
        }
        count += 4;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        _invalid();
      } else {
        count += unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
      }
      if (count > bytes) {
        _invalid();
      }
    }
    return count;
  }

  static Object? _decodeJson(String encoded, int codeUnits, int bytes) {
    _checkSize(encoded, codeUnits, bytes);
    // Scan before jsonDecode allocates any containers. Strings containing JSON
    // are independently scanned when their exact legacy schema is opened.
    var depth = 0;
    var nodes = 0;
    var inString = false;
    var escaped = false;
    var inAtom = false;
    void node(int d) {
      if (++nodes > maximumJsonNodes || d > maximumJsonDepth) {
        _invalid();
      }
    }
    for (var i = 0; i < encoded.length; i++) {
      final unit = encoded.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          inString = false;
        }
      } else if (unit == 34) {
        node(depth + 1);
        inString = true;
        inAtom = false;
      } else if (unit == 123 || unit == 91) {
        node(++depth);
        inAtom = false;
      } else if (unit == 125 || unit == 93) {
        if (--depth < 0) {
          _invalid();
        }
        inAtom = false;
      } else if (unit == 44 || unit == 58 || unit == 32 || unit == 9 || unit == 10 || unit == 13) {
        inAtom = false;
      } else if (!inAtom) {
        node(depth + 1);
        inAtom = true;
      }
    }
    if (inString || depth != 0) {
      _invalid();
    }
    try {
      return jsonDecode(encoded);
    } on FormatException {
      _invalid();
    }
  }

  static Never _invalid() => throw StateError(invalidCode);

  @override
  String toString() => 'CloudSyncMessagePreparationRecoveryOrigin(redacted)';
}

final class _MessageRecoveryReceipt {
  const _MessageRecoveryReceipt(this.value, this.canonical, this.digest);
  final Map<String, Object?> value;
  final String canonical;
  final String digest;
}

/// Bound typed inputs before sorting/copying containers or encoding JSON. Copy
/// and freeze every container, including hostile values later refused by shape.
final class _ReceiptCopy {
  var _nodes = 0;
  var _textUnits = 0;
  var _textBytes = 0;

  Object? copy(Object? value, int depth) {
    if (++_nodes > CloudSyncMessagePreparationRecoveryOrigin.maximumJsonNodes ||
        depth > CloudSyncMessagePreparationRecoveryOrigin.maximumJsonDepth) {
      CloudSyncMessagePreparationRecoveryOrigin._invalid();
    }
    if (value == null || value is bool || value is int) {
      return value;
    }
    if (value is String) {
      _string(value);
      return value;
    }
    if (value is List) {
      if (value.length > CloudSyncMessagePreparationRecoveryOrigin.maximumJsonNodes) {
        CloudSyncMessagePreparationRecoveryOrigin._invalid();
      }
      return List<Object?>.unmodifiable(value.map((v) => copy(v, depth + 1)));
    }
    if (value is Map) {
      if (value.length > CloudSyncMessagePreparationRecoveryOrigin.maximumJsonNodes ||
          value.keys.any((key) => key is! String)) {
        CloudSyncMessagePreparationRecoveryOrigin._invalid();
      }
      final keys = value.keys.cast<String>().toList()..sort();
      final result = <String, Object?>{};
      for (final key in keys) {
        if (++_nodes > CloudSyncMessagePreparationRecoveryOrigin.maximumJsonNodes) {
          CloudSyncMessagePreparationRecoveryOrigin._invalid();
        }
        _string(key);
        result[key] = copy(value[key], depth + 1);
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    CloudSyncMessagePreparationRecoveryOrigin._invalid();
  }

  void _string(String value) {
    _textUnits += value.length;
    if (_textUnits > CloudSyncMessagePreparationRecoveryOrigin.maximumReceiptCodeUnits) {
      CloudSyncMessagePreparationRecoveryOrigin._invalid();
    }
    _textBytes += CloudSyncMessagePreparationRecoveryOrigin._checkSize(
      value,
      CloudSyncMessagePreparationRecoveryOrigin.maximumReceiptCodeUnits,
      CloudSyncMessagePreparationRecoveryOrigin.maximumReceiptBytes,
    );
    if (_textBytes > CloudSyncMessagePreparationRecoveryOrigin.maximumReceiptBytes) {
      CloudSyncMessagePreparationRecoveryOrigin._invalid();
    }
  }
}
