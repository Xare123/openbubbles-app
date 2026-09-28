import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_local_send_source_binding.dart';

/// Read-only source evidence for the shared byte-upload lifecycle. Historical
/// sources retain their snapshot and purpose; they never become IDS receipts.
final class CloudSyncAttachmentUploadOrigin {
  CloudSyncAttachmentUploadOrigin.local(CloudSyncLocalSendSourceBinding source)
    : _local = source,
      _historical = null;
  CloudSyncAttachmentUploadOrigin.historical(
    CloudSyncHistoricalProtectedSourceBinding source,
  ) : _historical = source,
      _local = null;

  factory CloudSyncAttachmentUploadOrigin.read({
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
    CloudSyncHistoricalArchiveJournal? historicalJournal,
  }) => historicalJournal == null
      ? CloudSyncAttachmentUploadOrigin.local(
          uploads.readOriginalSource(uploadId),
        )
      : CloudSyncAttachmentUploadOrigin.historical(
          uploads.readHistoricalOriginalSource(uploadId, historicalJournal),
        );

  final CloudSyncLocalSendSourceBinding? _local;
  final CloudSyncHistoricalProtectedSourceBinding? _historical;

  bool get isHistorical => _historical != null;
  String get encoded => _historical?.encode() ?? _local!.encode();
  String get accountFingerprint =>
      _historical?.accountFingerprint ?? _local!.accountFingerprint;
  String get protectedStoreIdentity =>
      _historical?.protectedStoreIdentity ?? _local!.protectedStoreIdentity;

  void requireIdentity({
    required String accountFingerprint,
    required String protectedStoreIdentity,
  }) {
    if (this.accountFingerprint != accountFingerprint ||
        this.protectedStoreIdentity != protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
  }

  api.CloudSyncNativeSendReceiptContext localContext({
    required String storageDirectory,
    required api.CloudSyncNativeAuthMetadata auth,
  }) {
    final source = _local;
    if (source == null) throw StateError(cloudSyncAttachmentOwnerChangedCode);
    requireIdentity(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
    );
    return api.CloudSyncNativeSendReceiptContext(
      storageDirectory: storageDirectory,
      guidHash: source.messageGuidHash,
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      nativeSessionId: auth.nativeSessionId,
      sourceBinding: api.CloudSyncNativeSendSourceBinding(
        sourceSha256: source.sourceSha256,
        protectedReference: source.protectedReference,
        leaseReference: source.leaseReference,
        payloadSha256: source.payloadSha256,
        payloadLength: BigInt.from(source.payloadLength),
      ),
    );
  }

  api.CloudSyncHistoricalAttachmentContext historicalContext({
    required String storageDirectory,
    required api.CloudSyncNativeAuthMetadata auth,
  }) {
    final source = _historical;
    if (source == null) throw StateError(cloudSyncAttachmentOwnerChangedCode);
    requireIdentity(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
    );
    return api.CloudSyncHistoricalAttachmentContext(
      storageDirectory: storageDirectory,
      expectedAuth: auth,
      source: api.CloudSyncNativeHistoricalArchiveSourceBinding(
        accountFingerprint: source.accountFingerprint,
        protectedStoreIdentity: source.protectedStoreIdentity,
        snapshotSha256: source.snapshotSha256,
        messageGuidHash: source.messageGuidHash,
        sourceSha256: source.sourceSha256,
        protectedReference: source.protectedReference,
        leaseReference: source.leaseReference,
        payloadSha256: source.payloadSha256,
        payloadLength: source.payloadLength,
      ),
    );
  }

  @override
  String toString() => 'CloudSyncAttachmentUploadOrigin(redacted)';
}
