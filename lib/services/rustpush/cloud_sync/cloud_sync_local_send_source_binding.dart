import 'dart:convert';

/// Content-free ownership of the exact native IDS attachment source.
/// This is not an IDS receipt, upload permission, or proof of a remote save.
/// The envelope remains native-protected; its lease must be committed under
/// the protected-store lock after the journal adopts this binding.
final class CloudSyncLocalSendSourceBinding {
  CloudSyncLocalSendSourceBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.messageGuidHash,
    required this.sourceSha256,
    required this.protectedReference,
    required this.leaseReference,
    required this.payloadSha256,
    required this.payloadLength,
  }) {
    if (!_token.hasMatch(accountFingerprint) ||
        !RegExp(
          r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(protectedStoreIdentity) ||
        !_digest.hasMatch(messageGuidHash) ||
        !_digest.hasMatch(sourceSha256) ||
        !RegExp(
          r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(protectedReference) ||
        !RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(leaseReference) ||
        !_digest.hasMatch(payloadSha256) ||
        payloadLength < 1 ||
        payloadLength > 1024 * 1024) {
      throw StateError('cloud_sync_local_send_protected_source_invalid');
    }
  }

  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String messageGuidHash;
  final String sourceSha256;
  final String protectedReference;
  final String leaseReference;
  final String payloadSha256;
  final int payloadLength;

  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');

  String encode() => jsonEncode([
    1,
    'idsAttachmentSource',
    accountFingerprint,
    protectedStoreIdentity,
    messageGuidHash,
    sourceSha256,
    protectedReference,
    leaseReference,
    payloadSha256,
    payloadLength,
  ]);

  static CloudSyncLocalSendSourceBinding decode(String encoded) {
    if (encoded.length > 2048) {
      throw StateError('cloud_sync_local_send_protected_source_invalid');
    }
    final dynamic value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_local_send_protected_source_invalid');
    }
    if (value is! List ||
        value.length != 10 ||
        value[0] != 1 ||
        value[1] != 'idsAttachmentSource' ||
        value.sublist(2, 9).any((field) => field is! String) ||
        value[9] is! int) {
      throw StateError('cloud_sync_local_send_protected_source_invalid');
    }
    final binding = CloudSyncLocalSendSourceBinding(
      accountFingerprint: value[2] as String,
      protectedStoreIdentity: value[3] as String,
      messageGuidHash: value[4] as String,
      sourceSha256: value[5] as String,
      protectedReference: value[6] as String,
      leaseReference: value[7] as String,
      payloadSha256: value[8] as String,
      payloadLength: value[9] as int,
    );
    // One stable representation makes immutable adoption comparison exact.
    if (binding.encode() != encoded) {
      throw StateError('cloud_sync_local_send_protected_source_invalid');
    }
    return binding;
  }

  void requireOrigin({
    required String accountFingerprint,
    required String messageGuidHash,
    required String sourceSha256,
    String? protectedStoreIdentity,
  }) {
    if (this.accountFingerprint != accountFingerprint ||
        this.messageGuidHash != messageGuidHash ||
        this.sourceSha256 != sourceSha256 ||
        (protectedStoreIdentity != null &&
            this.protectedStoreIdentity != protectedStoreIdentity)) {
      throw StateError('cloud_sync_local_send_protected_source_changed');
    }
  }

  @override
  String toString() => 'CloudSyncLocalSendSourceBinding(redacted)';
}
