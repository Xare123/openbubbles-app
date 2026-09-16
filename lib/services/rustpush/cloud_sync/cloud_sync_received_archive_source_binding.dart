import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// Content-free ownership of the exact native protected incoming source.
///
/// This is not an IDS send receipt, upload permission, authentication proof,
/// or proof of a remote save. Version1 file leases must be committed under the
/// protected-store lock after journal adoption. Version2 encrypted retry seeds
/// are owned directly by ObjectBox and need no file lease during capture.
/// Native open authenticates either form; Dart validation alone grants nothing.
final class CloudSyncReceivedArchiveSourceBinding {
  factory CloudSyncReceivedArchiveSourceBinding.fromNative(
    api.CloudSyncNativeReceivedArchiveSourceBinding value,
  ) => CloudSyncReceivedArchiveSourceBinding(
    accountFingerprint: value.accountFingerprint,
    protectedStoreIdentity: value.protectedStoreIdentity,
    messageGuidHash: value.messageGuidHash,
    sourceSha256: value.sourceSha256,
    protectedReference: value.protectedReference,
    leaseReference: value.leaseReference,
    payloadSha256: value.payloadSha256,
    payloadLength: value.payloadLength,
  );

  CloudSyncReceivedArchiveSourceBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.messageGuidHash,
    required this.sourceSha256,
    required this.protectedReference,
    required this.leaseReference,
    required this.payloadSha256,
    required this.payloadLength,
    this.sealedSource,
  }) {
    if (!_token.hasMatch(accountFingerprint) ||
        !_store.hasMatch(protectedStoreIdentity) ||
        !_digest.hasMatch(messageGuidHash) ||
        !_digest.hasMatch(sourceSha256) ||
        (sealedSource == null &&
            (!_protectedRef.hasMatch(protectedReference) ||
                !_leaseRef.hasMatch(leaseReference))) ||
        !_digest.hasMatch(payloadSha256) ||
        payloadLength < 1 ||
        payloadLength >
            (sealedSource == null ? 1024 * 1024 : 2 * 1024 * 1024)) {
      throw StateError('cloud_sync_received_archive_protected_source_invalid');
    }
    if (sealedSource != null &&
        (protectedReference.isNotEmpty ||
            leaseReference.isNotEmpty ||
            sealedSource!.length > 2 * 1024 * 1024 ||
            !_ciphertext.hasMatch(sealedSource!) ||
            utf8.encode(sealedSource!).length != payloadLength ||
            sha256.convert(utf8.encode(sealedSource!)).toString() !=
                payloadSha256)) {
      throw StateError('cloud_sync_received_archive_protected_source_invalid');
    }
  }

  factory CloudSyncReceivedArchiveSourceBinding.sealed({
    required String accountFingerprint,
    required String protectedStoreIdentity,
    required String messageGuidHash,
    required String sourceSha256,
    required String ciphertext,
  }) => CloudSyncReceivedArchiveSourceBinding(
    accountFingerprint: accountFingerprint,
    protectedStoreIdentity: protectedStoreIdentity,
    messageGuidHash: messageGuidHash,
    sourceSha256: sourceSha256,
    protectedReference: '',
    leaseReference: '',
    payloadSha256: sha256.convert(utf8.encode(ciphertext)).toString(),
    payloadLength: utf8.encode(ciphertext).length,
    sealedSource: ciphertext,
  );

  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String messageGuidHash;
  final String sourceSha256;
  final String protectedReference;
  final String leaseReference;
  final String payloadSha256;
  final int payloadLength;

  /// Platform-encrypted retry seed, not plaintext. It is owned by ObjectBox,
  /// so it names no protected file/lease and is never inventoried as one.
  final String? sealedSource;
  bool get isSeed => sealedSource != null;

  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _store = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  static final _protectedRef = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
  static final _leaseRef = RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$');
  static final _ciphertext = RegExp(
    r'^obcs2\.(?:windows|android|test)\.[A-Za-z0-9_-]+$',
  );

  String encode() => jsonEncode(<Object>[
    isSeed ? 2 : 1,
    isSeed ? 'idsReceivedArchiveSeed' : 'idsReceivedArchiveSource',
    accountFingerprint,
    protectedStoreIdentity,
    messageGuidHash,
    sourceSha256,
    sealedSource ?? protectedReference,
    leaseReference,
    payloadSha256,
    payloadLength,
  ]);

  static CloudSyncReceivedArchiveSourceBinding decode(String encoded) {
    if (encoded.length > 2 * 1024 * 1024 + 2048) {
      throw StateError('cloud_sync_received_archive_protected_source_invalid');
    }
    final dynamic value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_received_archive_protected_source_invalid');
    }
    if (value is! List ||
        value.length != 10 ||
        !((value[0] == 1 && value[1] == 'idsReceivedArchiveSource') ||
            (value[0] == 2 && value[1] == 'idsReceivedArchiveSeed')) ||
        value.sublist(2, 9).any((field) => field is! String) ||
        value[9] is! int) {
      throw StateError('cloud_sync_received_archive_protected_source_invalid');
    }
    final binding = CloudSyncReceivedArchiveSourceBinding(
      accountFingerprint: value[2] as String,
      protectedStoreIdentity: value[3] as String,
      messageGuidHash: value[4] as String,
      sourceSha256: value[5] as String,
      protectedReference: value[0] == 2 ? '' : value[6] as String,
      leaseReference: value[7] as String,
      payloadSha256: value[8] as String,
      payloadLength: value[9] as int,
      sealedSource: value[0] == 2 ? value[6] as String : null,
    );
    // One stable representation makes immutable adoption comparison exact.
    if (binding.encode() != encoded) {
      throw StateError('cloud_sync_received_archive_protected_source_invalid');
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
      throw StateError('cloud_sync_received_archive_protected_source_changed');
    }
  }

  @override
  String toString() => 'CloudSyncReceivedArchiveSourceBinding(redacted)';
}
