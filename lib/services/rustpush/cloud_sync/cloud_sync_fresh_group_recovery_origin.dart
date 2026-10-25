import 'dart:convert';

import 'package:crypto/crypto.dart';

enum CloudSyncFreshGroupRecoveryPhase { ready, submitted, retired }

/// Immutable syntax for an audited legacy fresh-group repair, never authority.
/// The journal must authenticate the source, receipt, proof and both leases.
/// This module deliberately imports no models, legacy codecs or native APIs.
final class CloudSyncFreshGroupRecoveryOrigin {
  CloudSyncFreshGroupRecoveryOrigin._({
    required this.identityParts,
    required this.receipt,
    required this.canonicalReceipt,
    required this.receiptSha256,
    required this.proof,
    required this.phase,
  }) : identity = jsonEncode(identityParts) {
    _encoded = _encodePhase(phase);
    _checkSize(_encoded, maximumEncodedCodeUnits, maximumEncodedBytes);
  }

  static const maximumEncodedCodeUnits = 65536;
  static const maximumEncodedBytes = 131072;
  static const maximumReceiptCodeUnits = 32768;
  static const maximumReceiptBytes = 65536;
  // Count containers, scalar values and map keys. The root is depth one.
  static const maximumJsonDepth = 16;
  static const maximumJsonNodes = 4096;

  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static const _receiptKeys = {
    'schema', 'reason', 'operation', 'recordMap', 'source', 'conversion', 'binding',
  };

  final String identity;
  final List<Object?> identityParts;
  final Map<String, Object?> receipt;
  final String canonicalReceipt;
  final String receiptSha256;
  final String proof;
  final CloudSyncFreshGroupRecoveryPhase phase;
  late final String _encoded;

  static CloudSyncFreshGroupRecoveryOrigin create({
    required String identity,
    required Map<String, Object?> receipt,
    required String proof,
    CloudSyncFreshGroupRecoveryPhase phase = CloudSyncFreshGroupRecoveryPhase.ready,
  }) {
    final parts = _identity(identity);
    final data = _receipt(receipt);
    if (jsonEncode(data.legacyIdentity) != identity) _invalid();
    _proof(proof, 2);
    return CloudSyncFreshGroupRecoveryOrigin._(
      identityParts: parts,
      receipt: data.value,
      canonicalReceipt: data.canonical,
      receiptSha256: data.digest,
      proof: proof,
      phase: phase,
    );
  }

  static CloudSyncFreshGroupRecoveryOrigin decode(String encoded) {
    final root = _decodeJson(encoded, maximumEncodedCodeUnits, maximumEncodedBytes);
    if (root is! List || root.length != 6 || root[0] is! int || root[0] != 9 ||
        root[1] is! int || (root[1] as int) < 0 ||
        (root[1] as int) >= CloudSyncFreshGroupRecoveryPhase.values.length ||
        root[2] is! List || root[3] is! String || root[4] is! String ||
        root[5] is! String || !_digest.hasMatch(root[4] as String)) {
      _invalid();
    }
    final canonicalReceipt = root[3] as String;
    final decodedReceipt = _decodeJson(
      canonicalReceipt, maximumReceiptCodeUnits, maximumReceiptBytes,
    );
    if (decodedReceipt is! Map<String, dynamic>) _invalid();
    final result = create(
      identity: jsonEncode(root[2]),
      receipt: decodedReceipt,
      proof: root[5] as String,
      phase: CloudSyncFreshGroupRecoveryPhase.values[root[1] as int],
    );
    // Exact canonical comparison also rejects duplicate keys and alternate
    // whitespace, escaping or numeric spellings, including inside the receipt.
    if (result.canonicalReceipt != canonicalReceipt ||
        result.receiptSha256 != root[4] || result.encode() != encoded) {
      _invalid();
    }
    return result;
  }

  /// Bounded version discriminator, including malformed version-nine tuples.
  /// A true result requires [decode], not acceptance or dispatch eligibility.
  static bool isEncoded(String encoded) {
    try {
      final root = _decodeJson(encoded, maximumEncodedCodeUnits, maximumEncodedBytes);
      return root is List && root.isNotEmpty && root[0] is int && root[0] == 9;
    } on StateError {
      return false;
    }
  }

  /// Compute before constructing the journal proof; neither helper grants auth.
  static String canonicalReceiptFor(Map<String, Object?> receipt) =>
      _receipt(receipt).canonical;

  static String receiptDigestFor(Map<String, Object?> receipt) =>
      _receipt(receipt).digest;

  String encode() => _encoded;

  /// Selection binding only. Actual submitted state is never changed by this.
  String get normalizedForBinding => phase == CloudSyncFreshGroupRecoveryPhase.submitted
      ? _encodePhase(CloudSyncFreshGroupRecoveryPhase.ready)
      : _encoded;

  CloudSyncFreshGroupRecoveryOrigin withPhase(CloudSyncFreshGroupRecoveryPhase next) {
    if (next == phase) return this;
    if (phase != CloudSyncFreshGroupRecoveryPhase.ready) _invalid();
    return CloudSyncFreshGroupRecoveryOrigin._(
      identityParts: identityParts,
      receipt: receipt,
      canonicalReceipt: canonicalReceipt,
      receiptSha256: receiptSha256,
      proof: proof,
      phase: next,
    );
  }

  String _encodePhase(CloudSyncFreshGroupRecoveryPhase value) => jsonEncode([
    9, value.index, identityParts, canonicalReceipt, receiptSha256, proof,
  ]);

  static List<Object?> _identity(String encoded) {
    final value = _decodeJson(encoded, 768, 768);
    if (value is! List || value.length != 8 || value[0] is! int || value[0] != 5 ||
        !_positiveInt(value[1]) || !_positiveInt(value[2]) ||
        value.skip(3).any((v) => v is! String || !_digest.hasMatch(v)) ||
        jsonEncode(value) != encoded) {
      _invalid();
    }
    return List<Object?>.unmodifiable(value);
  }

  static List<Object?> _legacyIdentity(Object? encoded) {
    if (encoded is! String) _invalid();
    final value = _decodeJson(encoded, 768, 768);
    if (value is! List || value.length != 9 || value[0] is! int || value[0] != 6 ||
        !_positiveInt(value[1]) || !_positiveInt(value[2]) ||
        value.skip(3).take(5).any((v) => v is! String || !_digest.hasMatch(v)) ||
        value[8] is! String || jsonEncode(value) != encoded) {
      _invalid();
    }
    _proof(value[8] as String, 1);
    return List<Object?>.unmodifiable([5, ...value.skip(1).take(7)]);
  }

  static void _proof(String encoded, int version) {
    final value = _decodeJson(encoded, 256, 256);
    if (value is! List || value.length != 3 || value[0] is! int ||
        value[0] != version || !_positiveInt(value[1]) || value[2] is! String ||
        !_digest.hasMatch(value[2] as String) || jsonEncode(value) != encoded) {
      _invalid();
    }
  }

  static _RecoveryReceipt _receipt(Map<String, Object?> input) {
    final value = _JsonCopy().copy(input, 1) as Map<String, Object?>;
    if (value.length != _receiptKeys.length ||
        !value.keys.every(_receiptKeys.contains) ||
        value['schema'] is! int || value['schema'] != 1 ||
        value['reason'] != 'fresh-group-purpose-v1' ||
        ['operation', 'recordMap', 'source', 'conversion', 'binding']
            .any((key) => value[key] is! Map<String, Object?>)) {
      _invalid();
    }
    final legacyIdentity = _legacyIdentity(
      (value['operation'] as Map<String, Object?>)['localChatOrigin'],
    );
    final canonical = jsonEncode(value);
    _checkSize(canonical, maximumReceiptCodeUnits, maximumReceiptBytes);
    return _RecoveryReceipt(
      value, canonical, sha256.convert(utf8.encode(canonical)).toString(), legacyIdentity,
    );
  }

  static bool _positiveInt(Object? value) => value is int && value > 0;

  static void _checkSize(String value, int codeUnits, int bytes) {
    if (value.length > codeUnits || utf8.encode(value).length > bytes) _invalid();
  }

  static Object? _decodeJson(String encoded, int codeUnits, int bytes) {
    _checkSize(encoded, codeUnits, bytes);
    // Bound nesting and token count before asking the JSON parser to allocate.
    _scanJson(encoded);
    try {
      return jsonDecode(encoded);
    } on FormatException {
      _invalid();
    }
  }

  static void _scanJson(String encoded) {
    var depth = 0;
    var nodes = 0;
    var inString = false;
    var escaped = false;
    var inAtom = false;
    void node(int nodeDepth) {
      if (++nodes > maximumJsonNodes || nodeDepth > maximumJsonDepth) _invalid();
    }
    for (final unit in encoded.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          inString = false;
        }
        continue;
      }
      if (unit == 34) {
        node(depth + 1);
        inString = true;
        inAtom = false;
      } else if (unit == 123 || unit == 91) {
        node(++depth);
        inAtom = false;
      } else if (unit == 125 || unit == 93) {
        if (--depth < 0) _invalid();
        inAtom = false;
      } else if (unit == 44 || unit == 58 || unit == 32 ||
          unit == 9 || unit == 10 || unit == 13) {
        inAtom = false;
      } else if (!inAtom) {
        node(depth + 1);
        inAtom = true;
      }
    }
    if (inString || depth != 0) _invalid();
  }

  static Never _invalid() => throw StateError('cloud_sync_fresh_group_recovery_origin_invalid');

  @override
  String toString() => 'CloudSyncFreshGroupRecoveryOrigin(redacted)';
}

final class _RecoveryReceipt {
  const _RecoveryReceipt(this.value, this.canonical, this.digest, this.legacyIdentity);
  final Map<String, Object?> value;
  final String canonical;
  final String digest;
  final List<Object?> legacyIdentity;
}

/// Copies only finite JSON, sorting every map and freezing every container.
final class _JsonCopy {
  var _nodes = 0;

  void _node(int depth) {
    if (++_nodes > CloudSyncFreshGroupRecoveryOrigin.maximumJsonNodes ||
        depth > CloudSyncFreshGroupRecoveryOrigin.maximumJsonDepth) {
      CloudSyncFreshGroupRecoveryOrigin._invalid();
    }
  }

  Object? copy(Object? value, int depth) {
    _node(depth);
    if (value == null || value is bool || value is int) return value;
    if (value is double && value.isFinite) return value;
    if (value is String) {
      _string(value);
      return value;
    }
    if (value is List) {
      if (value.length > CloudSyncFreshGroupRecoveryOrigin.maximumJsonNodes) {
        CloudSyncFreshGroupRecoveryOrigin._invalid();
      }
      return List<Object?>.unmodifiable(value.map((v) => copy(v, depth + 1)));
    }
    if (value is Map) {
      if (value.length > CloudSyncFreshGroupRecoveryOrigin.maximumJsonNodes ||
          value.keys.any((key) => key is! String)) {
        CloudSyncFreshGroupRecoveryOrigin._invalid();
      }
      final keys = value.keys.cast<String>().toList()..sort();
      final result = <String, Object?>{};
      for (final key in keys) {
        _node(depth + 1);
        _string(key);
        result[key] = copy(value[key], depth + 1);
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    CloudSyncFreshGroupRecoveryOrigin._invalid();
  }

  // Avoid replacement-character hashing of ill-formed UTF-16 input strings.
  void _string(String value) {
    if (value.length > CloudSyncFreshGroupRecoveryOrigin.maximumReceiptCodeUnits) {
      CloudSyncFreshGroupRecoveryOrigin._invalid();
    }
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length) CloudSyncFreshGroupRecoveryOrigin._invalid();
        final low = value.codeUnitAt(i);
        if (low < 0xdc00 || low > 0xdfff) CloudSyncFreshGroupRecoveryOrigin._invalid();
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        CloudSyncFreshGroupRecoveryOrigin._invalid();
      }
    }
  }
}
