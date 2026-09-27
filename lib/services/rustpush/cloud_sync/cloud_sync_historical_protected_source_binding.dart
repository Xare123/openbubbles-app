library;

import 'dart:convert';

import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// Content-free ownership of one exact native protected historical source.
///
/// Metadata only: this names references and digests, never plaintext, GUIDs,
/// bodies, or handles. It is not an IDS receipt, upload permission,
/// authentication proof, or evidence of a remote save or successful upload.
/// The envelope stays native-protected; its lease must be committed under
/// the protected-store lock after the future durable journal adopts this
/// binding. Version and purpose are explicitly historical, distinct from
/// the outgoing, live-received, and mutation bindings.

final class CloudSyncHistoricalProtectedSourceBinding {
  factory CloudSyncHistoricalProtectedSourceBinding.fromNative(
    api.CloudSyncNativeHistoricalArchiveSourceBinding value,
  ) => CloudSyncHistoricalProtectedSourceBinding(
    accountFingerprint: value.accountFingerprint,
    protectedStoreIdentity: value.protectedStoreIdentity,
    snapshotSha256: value.snapshotSha256,
    messageGuidHash: value.messageGuidHash,
    sourceSha256: value.sourceSha256,
    protectedReference: value.protectedReference,
    leaseReference: value.leaseReference,
    payloadSha256: value.payloadSha256,
    payloadLength: value.payloadLength,
  );

  CloudSyncHistoricalProtectedSourceBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.snapshotSha256,
    required this.messageGuidHash,
    required this.sourceSha256,
    required this.protectedReference,
    required this.leaseReference,
    required this.payloadSha256,
    required this.payloadLength,
  }) {
    if (!_token.hasMatch(accountFingerprint) ||
        !_store.hasMatch(protectedStoreIdentity) ||
        !_digest.hasMatch(snapshotSha256) ||
        !_digest.hasMatch(messageGuidHash) ||
        !_digest.hasMatch(sourceSha256) ||
        !_protectedRef.hasMatch(protectedReference) ||
        !_leaseRef.hasMatch(leaseReference) ||
        !_digest.hasMatch(payloadSha256) ||
        payloadLength < 1 ||
        payloadLength > 1024 * 1024) {
      throw StateError('cloud_sync_historical_protected_source_invalid');
    }
  }

  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String snapshotSha256;
  final String messageGuidHash;
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

  String encode() => jsonEncode(<Object>[
    1,
    'historicalArchiveSource',
    accountFingerprint,
    protectedStoreIdentity,
    snapshotSha256,
    messageGuidHash,
    sourceSha256,
    protectedReference,
    leaseReference,
    payloadSha256,
    payloadLength,
  ]);

  static CloudSyncHistoricalProtectedSourceBinding decode(String encoded) {
    if (encoded.length > 4096) {
      throw StateError('cloud_sync_historical_protected_source_invalid');
    }
    final dynamic value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_historical_protected_source_invalid');
    }
    if (value is! List ||
        value.length != 11 ||
        value[0] != 1 ||
        value[1] != 'historicalArchiveSource' ||
        value.sublist(2, 10).any((field) => field is! String) ||
        value[10] is! int) {
      throw StateError('cloud_sync_historical_protected_source_invalid');
    }
    final binding = CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: value[2] as String,
      protectedStoreIdentity: value[3] as String,
      snapshotSha256: value[4] as String,
      messageGuidHash: value[5] as String,
      sourceSha256: value[6] as String,
      protectedReference: value[7] as String,
      leaseReference: value[8] as String,
      payloadSha256: value[9] as String,
      payloadLength: value[10] as int,
    );
    // One stable representation makes immutable adoption comparison exact.
    if (binding.encode() != encoded) {
      throw StateError('cloud_sync_historical_protected_source_invalid');
    }
    return binding;
  }

  void requireOrigin({
    required String accountFingerprint,
    required String protectedStoreIdentity,
    required String snapshotSha256,
    required String messageGuidHash,
    required String sourceSha256,
  }) {
    if (this.accountFingerprint != accountFingerprint ||
        this.protectedStoreIdentity != protectedStoreIdentity ||
        this.snapshotSha256 != snapshotSha256 ||
        this.messageGuidHash != messageGuidHash ||
        this.sourceSha256 != sourceSha256) {
      throw StateError('cloud_sync_historical_protected_source_changed');
    }
  }

  @override
  String toString() => 'CloudSyncHistoricalProtectedSourceBinding(redacted)';
}
