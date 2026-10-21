import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Exact inline native-encrypted event. Never an original-source descriptor,
/// file lease, positive outgoing receipt or remote mutation permission.
final class CloudSyncReceivedMutationSourceBinding {
  CloudSyncReceivedMutationSourceBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.mutationGuidHash,
    required this.sourceSha256,
    required this.ciphertext,
  }) {
    if (!_token.hasMatch(accountFingerprint) ||
        !_store.hasMatch(protectedStoreIdentity) ||
        !_digest.hasMatch(mutationGuidHash) ||
        !_digest.hasMatch(sourceSha256) ||
        ciphertext.length > 2 * 1024 * 1024 ||
        !_ciphertext.hasMatch(ciphertext)) {
      throw StateError('cloud_sync_received_mutation_source_invalid');
    }
  }
  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String mutationGuidHash;
  final String sourceSha256;
  final String ciphertext;

  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _store = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _ciphertext = RegExp(
    r'^obcs2\.(?:windows|android|test)\.[A-Za-z0-9_-]+$',
  );

  String encode() => jsonEncode([
    1,
    'idsReceivedMutationSeed',
    accountFingerprint,
    protectedStoreIdentity,
    mutationGuidHash,
    sourceSha256,
    ciphertext,
    sha256.convert(utf8.encode(ciphertext)).toString(),
  ]);

  static CloudSyncReceivedMutationSourceBinding decode(String encoded) {
    try {
      if (encoded.length > 2 * 1024 * 1024 + 1024) {
        throw const FormatException();
      }
      final value = jsonDecode(encoded);
      if (value is! List ||
          value.length != 8 ||
          value[0] != 1 ||
          value[1] != 'idsReceivedMutationSeed' ||
          value.skip(2).any((v) => v is! String)) {
        throw const FormatException();
      }
      final result = CloudSyncReceivedMutationSourceBinding(
        accountFingerprint: value[2],
        protectedStoreIdentity: value[3],
        mutationGuidHash: value[4],
        sourceSha256: value[5],
        ciphertext: value[6],
      );
      if (result.encode() != encoded) throw const FormatException();
      return result;
    } on FormatException {
      throw StateError('cloud_sync_received_mutation_source_invalid');
    }
  }

  void requireOrigin({
    required String account,
    required String store,
    required String eventGuidHash,
    required String sourceDigest,
  }) {
    if (accountFingerprint != account ||
        protectedStoreIdentity != store ||
        mutationGuidHash != eventGuidHash ||
        sourceSha256 != sourceDigest) {
      throw StateError('cloud_sync_received_mutation_source_changed');
    }
  }

  @override
  String toString() => 'CloudSyncReceivedMutationSourceBinding(redacted)';
}
