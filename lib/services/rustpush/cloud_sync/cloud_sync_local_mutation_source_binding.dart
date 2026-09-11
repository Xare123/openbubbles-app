import 'dart:convert';

/// Content-free ownership of the exact native IDS mutation source.
/// This is not an IDS receipt, upload permission, or proof of a remote save.
/// The envelope remains native-protected; its lease must be committed under
/// the protected-store lock after the journal adopts this binding.
final class CloudSyncLocalMutationSourceBinding {
  CloudSyncLocalMutationSourceBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.mutationGuidHash,
    required this.targetGuidHash,
    required this.targetPart,
    required this.sourceSha256,
    required this.protectedReference,
    required this.leaseReference,
    required this.payloadSha256,
    required this.payloadLength,
  }) {
    if (!_token.hasMatch(accountFingerprint) ||
        !_store.hasMatch(protectedStoreIdentity) ||
        !_digest.hasMatch(mutationGuidHash) ||
        !_digest.hasMatch(targetGuidHash) ||
        mutationGuidHash == targetGuidHash ||
        targetPart < 0 ||
        targetPart > _maxSafePart ||
        !_digest.hasMatch(sourceSha256) ||
        !_protectedRef.hasMatch(protectedReference) ||
        !_leaseRef.hasMatch(leaseReference) ||
        !_digest.hasMatch(payloadSha256) ||
        payloadLength < 1 ||
        payloadLength > 1024 * 1024) {
      throw StateError('cloud_sync_local_mutation_protected_source_invalid');
    }
  }

  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String mutationGuidHash;
  final String targetGuidHash;
  final int targetPart;
  final String sourceSha256;
  final String protectedReference;
  final String leaseReference;
  final String payloadSha256;
  final int payloadLength;

  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _store = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static final _protectedRef = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
  static final _leaseRef = RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$');

  /// Cross-platform exact integer bound for a native u64 part. Native Dart
  /// integers support values beyond the JavaScript safe bound.
  static const int _maxSafePart = 9007199254740991;

  String encode() => jsonEncode(<Object>[
    1,
    'idsMutationSource',
    accountFingerprint,
    protectedStoreIdentity,
    mutationGuidHash,
    targetGuidHash,
    targetPart,
    sourceSha256,
    protectedReference,
    leaseReference,
    payloadSha256,
    payloadLength,
  ]);

  static CloudSyncLocalMutationSourceBinding decode(String encoded) {
    if (encoded.length > 4096) {
      throw StateError('cloud_sync_local_mutation_protected_source_invalid');
    }
    final dynamic value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_local_mutation_protected_source_invalid');
    }
    if (value is! List ||
        value.length != 12 ||
        value[0] != 1 ||
        value[1] != 'idsMutationSource' ||
        value.sublist(2, 6).any((field) => field is! String) ||
        value[6] is! int ||
        value.sublist(7, 11).any((field) => field is! String) ||
        value[11] is! int) {
      throw StateError('cloud_sync_local_mutation_protected_source_invalid');
    }
    final binding = CloudSyncLocalMutationSourceBinding(
      accountFingerprint: value[2] as String,
      protectedStoreIdentity: value[3] as String,
      mutationGuidHash: value[4] as String,
      targetGuidHash: value[5] as String,
      targetPart: value[6] as int,
      sourceSha256: value[7] as String,
      protectedReference: value[8] as String,
      leaseReference: value[9] as String,
      payloadSha256: value[10] as String,
      payloadLength: value[11] as int,
    );
    // One stable representation makes immutable adoption comparison exact.
    if (binding.encode() != encoded) {
      throw StateError('cloud_sync_local_mutation_protected_source_invalid');
    }
    return binding;
  }

  void requireOrigin({
    required String accountFingerprint,
    required String mutationGuidHash,
    required String targetGuidHash,
    required int targetPart,
    required String sourceSha256,
    String? protectedStoreIdentity,
  }) {
    if (this.accountFingerprint != accountFingerprint ||
        this.mutationGuidHash != mutationGuidHash ||
        this.targetGuidHash != targetGuidHash ||
        this.targetPart != targetPart ||
        this.sourceSha256 != sourceSha256 ||
        (protectedStoreIdentity != null &&
            this.protectedStoreIdentity != protectedStoreIdentity)) {
      throw StateError('cloud_sync_local_mutation_protected_source_changed');
    }
  }

  @override
  String toString() => 'CloudSyncLocalMutationSourceBinding(redacted)';
}
