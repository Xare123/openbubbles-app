import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cloud_sync_message_preparation_recovery_origin.dart';

/// Immutable admittedChatBinding version 6 syntax, NEVER native authority.
///
/// The journal/store must authenticate the retained preparation owner, complete
/// original/current snapshots, current auth/ownership and genuine committed
/// lease before atomically transferring ownership to the normal outbox row.
/// Neither this unkeyed digest nor the embedded retained phase grants archive,
/// send, save, consume, acknowledgment or disposal permission. localChatOrigin
/// and protectedSourceBinding must not change to install this wrapper.
///
/// The embedded v5 is historical evidence after transfer. Its retainsFreshLease
/// hint must not independently keep a normally released outbox receipt live.
final class CloudSyncMessageArchiveRecoveryOrigin {
  CloudSyncMessageArchiveRecoveryOrigin._({
    required this.preparationBinding,
    required this.preparation,
    required this.receipt,
    required this.canonicalReceipt,
    required this.receiptSha256,
  }) {
    _encoded = jsonEncode([
      6, preparationBinding, canonicalReceipt, receiptSha256,
    ]);
    _checkSize(_encoded);
  }

  static const maximumEncodedCodeUnits = 262144;
  static const maximumEncodedBytes = 524288;
  static const maximumJsonDepth = 16;
  static const maximumJsonNodes = 4096;
  static const reason = 'message-archive-recovery-v1';
  static const mode = 'normal-archive-handoff';
  static const invalidCode = 'cloud_sync_message_archive_recovery_origin_invalid';

  final String preparationBinding;
  final CloudSyncMessagePreparationRecoveryOrigin preparation;
  final Map<String, Object?> receipt;
  final String canonicalReceipt;
  final String receiptSha256;
  late final String _encoded;

  String get legacyBinding => preparation.legacyBinding;
  Map<String, Object?> get operation => _map(receipt['operation']);
  Map<String, Object?> get recordMap => _map(receipt['recordMap']);
  Map<String, Object?> get source => _map(receipt['source']);
  Map<String, Object?> get binding => _map(receipt['binding']);

  static CloudSyncMessageArchiveRecoveryOrigin create({
    required String preparationBinding,
    required Map<String, Object?> receipt,
  }) {
    final CloudSyncMessagePreparationRecoveryOrigin preparation;
    try {
      preparation = CloudSyncMessagePreparationRecoveryOrigin.decode(preparationBinding);
    } on StateError {
      _invalid();
    }
    if (preparation.phase != CloudSyncMessagePreparationRecoveryPhase.retained) {
      _invalid();
    }
    final value = _ReceiptCopy().copy(receipt, 1) as Map<String, Object?>;
    const keys = {
      'schema', 'reason', 'mode', 'preparationSha256',
      'operation', 'recordMap', 'source', 'binding',
    };
    if (value.length != keys.length || !value.keys.every(keys.contains) ||
        value['schema'] is! int || value['schema'] != 1 ||
        value['reason'] != reason || value['mode'] != mode ||
        value['preparationSha256'] != _sha(preparationBinding)) {
      _invalid();
    }

    // Exact scalar equality to the strictly decoded v5 inherits its COMPLETE
    // snapshot schemas, including typed nulls, prefixes and independent times.
    _requireSnapshot(value['operation'], preparation.operation);
    _requireSnapshot(value['recordMap'], preparation.recordMap);
    final currentSource = _map(value['source']);
    if (!_digest(currentSource['admittedBindingSha256']) ||
        currentSource['admittedChatBinding'] != preparationBinding) {
      _invalid();
    }
    _requireSnapshot(currentSource, {
      ...preparation.source,
      'admittedChatBinding': preparationBinding,
      'admittedBindingSha256': currentSource['admittedBindingSha256'],
    });

    final binding = _shape(value['binding'], _bindingFields);
    for (final key in [
      'scopeKey', 'accountFingerprint', 'checkpointGeneration',
      'chatId', 'intentId', 'localMessageId', 'protectedStoreIdentity',
    ]) {
      if (binding[key] != preparation.binding[key]) {
        _invalid();
      }
    }
    if ((binding['ownershipEpoch']! as int) > (binding['writerEpoch']! as int)) {
      _invalid();
    }
    // Session, writer/ownership epochs, owner digest and activation time belong
    // to the CURRENT owner. Syntax does not authenticate them or infer history.
    final canonical = jsonEncode(value);
    _checkSize(canonical);
    return CloudSyncMessageArchiveRecoveryOrigin._(
      preparationBinding: preparationBinding,
      preparation: preparation,
      receipt: value,
      canonicalReceipt: canonical,
      receiptSha256: _sha(canonical),
    );
  }

  static CloudSyncMessageArchiveRecoveryOrigin decode(String encoded) {
    final root = _decodeJson(encoded);
    if (root is! List || root.length != 4 || root[0] is! int || root[0] != 6 ||
        root[1] is! String || root[2] is! String || !_digest(root[3])) {
      _invalid();
    }
    final result = create(
      preparationBinding: root[1] as String,
      receipt: _map(_decodeJson(root[2] as String)),
    );
    // Reencoding rejects duplicate keys and noncanonical numbers, escapes or
    // whitespace, even if an attacker recomputed the unkeyed receipt digest.
    if (result.canonicalReceipt != root[2] || result.receiptSha256 != root[3] ||
        result.encode() != encoded) {
      _invalid();
    }
    return result;
  }

  /// Bounded version discriminator only, including malformed version-six tuples.
  /// A false result never authorizes a caller to ignore an unknown audit owner.
  static bool isEncoded(String encoded) {
    try {
      final root = _decodeJson(encoded);
      return root is List && root.isNotEmpty && root[0] is int && root[0] == 6;
    } on StateError {
      return false;
    }
  }

  String encode() => _encoded;

  static final _hex = RegExp(r'^[a-f0-9]{64}$');
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _scopePattern = RegExp(r'^scope2:[a-f0-9]{64}$');
  static final _storePattern = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static final _bindingFields = <String, bool Function(Object?)>{
    'scopeKey': (v) => _match(_scopePattern, v), 'accountFingerprint': _token,
    'checkpointGeneration': _positive, 'chatId': _positive, 'intentId': _positive,
    'localMessageId': _positive, 'nativeSessionId': _token,
    'protectedStoreIdentity': (v) => _match(_storePattern, v),
    'writerEpoch': _positive, 'ownershipEpoch': _positive,
    'ownershipSnapshotSha256': _digest, 'activatedAtMs': _positive,
  };

  static void _requireSnapshot(Object? value, Map<String, Object?> expected) {
    final actual = _map(value);
    if (actual.length != expected.length || !actual.keys.every(expected.containsKey) ||
        actual.entries.any((entry) => entry.value != expected[entry.key])) {
      _invalid();
    }
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map<String, Object?>) {
      _invalid();
    }
    return value;
  }

  static Map<String, Object?> _shape(
    Object? value, Map<String, bool Function(Object?)> fields,
  ) {
    final map = _map(value);
    if (map.length != fields.length || !map.keys.every(fields.containsKey) ||
        fields.entries.any((entry) => !entry.value(map[entry.key]))) {
      _invalid();
    }
    return map;
  }

  static bool _match(RegExp pattern, Object? value) {
    if (value is! String) {
      return false;
    }
    final match = pattern.firstMatch(value);
    return match != null && match.start == 0 && match.end == value.length;
  }

  static bool _positive(Object? value) =>
      value is int && value > 0 && value <= 9007199254740991;
  static bool _digest(Object? value) => _match(_hex, value);
  static bool _token(Object? value) => _match(_tokenPattern, value);
  static String _sha(String value) => sha256.convert(utf8.encode(value)).toString();

  // Count UTF8 without allocating an encoded copy, and reject invalid UTF16
  // rather than hashing replacement characters. Check before parsing/copying.
  static int _checkSize(String value) {
    if (value.length > maximumEncodedCodeUnits) {
      _invalid();
    }
    var bytes = 0;
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
        bytes += 4;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        _invalid();
      } else {
        bytes += unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
      }
      if (bytes > maximumEncodedBytes) {
        _invalid();
      }
    }
    return bytes;
  }

  static Object? _decodeJson(String encoded) {
    _checkSize(encoded);
    var depth = 0;
    var nodes = 0;
    var inString = false;
    var escaped = false;
    var inAtom = false;
    void node(int nodeDepth) {
      if (++nodes > maximumJsonNodes || nodeDepth > maximumJsonDepth) {
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
  String toString() => 'CloudSyncMessageArchiveRecoveryOrigin(redacted)';
}

/// Bound containers before traversal, then canonicalize and deeply freeze them.
final class _ReceiptCopy {
  var _nodes = 0;
  var _textUnits = 0;
  var _textBytes = 0;

  Object? copy(Object? value, int depth) {
    if (++_nodes > CloudSyncMessageArchiveRecoveryOrigin.maximumJsonNodes ||
        depth > CloudSyncMessageArchiveRecoveryOrigin.maximumJsonDepth) {
      CloudSyncMessageArchiveRecoveryOrigin._invalid();
    }
    if (value == null || value is bool || value is int) {
      return value;
    }
    if (value is String) {
      _string(value);
      return value;
    }
    if (value is List) {
      if (value.length > CloudSyncMessageArchiveRecoveryOrigin.maximumJsonNodes) {
        CloudSyncMessageArchiveRecoveryOrigin._invalid();
      }
      return List<Object?>.unmodifiable(value.map((v) => copy(v, depth + 1)));
    }
    if (value is Map) {
      if (value.length > CloudSyncMessageArchiveRecoveryOrigin.maximumJsonNodes ||
          value.keys.any((key) => key is! String)) {
        CloudSyncMessageArchiveRecoveryOrigin._invalid();
      }
      final keys = value.keys.cast<String>().toList()..sort();
      final result = <String, Object?>{};
      for (final key in keys) {
        if (++_nodes > CloudSyncMessageArchiveRecoveryOrigin.maximumJsonNodes) {
          CloudSyncMessageArchiveRecoveryOrigin._invalid();
        }
        _string(key);
        result[key] = copy(value[key], depth + 1);
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    CloudSyncMessageArchiveRecoveryOrigin._invalid();
  }

  void _string(String value) {
    _textUnits += value.length;
    if (_textUnits > CloudSyncMessageArchiveRecoveryOrigin.maximumEncodedCodeUnits) {
      CloudSyncMessageArchiveRecoveryOrigin._invalid();
    }
    _textBytes += CloudSyncMessageArchiveRecoveryOrigin._checkSize(value);
    if (_textBytes > CloudSyncMessageArchiveRecoveryOrigin.maximumEncodedBytes) {
      CloudSyncMessageArchiveRecoveryOrigin._invalid();
    }
  }
}
