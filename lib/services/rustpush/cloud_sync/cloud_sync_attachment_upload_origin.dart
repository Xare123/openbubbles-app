import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_received_archive_journal.dart';
import 'cloud_sync_received_archive_source_binding.dart';

/// Read-only source evidence for the shared byte-upload lifecycle. Historical
/// and received sources retain their snapshot and purpose; they never become
/// IDS receipts.
final class CloudSyncAttachmentUploadOrigin {
  CloudSyncAttachmentUploadOrigin.local(CloudSyncLocalSendSourceBinding source)
    : _local = source,
      _historical = null,
      _received = null;
  CloudSyncAttachmentUploadOrigin.historical(
    CloudSyncHistoricalProtectedSourceBinding source,
  ) : _historical = source,
      _local = null,
      _received = null;
  CloudSyncAttachmentUploadOrigin.received(
    CloudSyncReceivedArchiveSourceBinding source,
  ) : _received = source,
      _local = null,
      _historical = null;

  /// Routes by the row's actual durable owner kind, never by which journals
  /// the caller wired. A non-local row without its matching journal fails
  /// closed instead of resolving through another lane. Depends on the upload
  /// journal's scoped readOwnerKind plus ownerKindReceived and the received
  /// original-source reader (journal worker owned).
  factory CloudSyncAttachmentUploadOrigin.read({
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
    CloudSyncHistoricalArchiveJournal? historicalJournal,
    CloudSyncReceivedArchiveJournal? receivedJournal,
  }) {
    switch (uploads.readOwnerKind(uploadId)) {
      case cloudSyncAttachmentOwnerKindReceived:
        final received = receivedJournal;
        if (received == null) {
          throw StateError(cloudSyncAttachmentOwnerChangedCode);
        }
        return CloudSyncAttachmentUploadOrigin.received(
          uploads.readReceivedOriginalSource(uploadId, received),
        );
      case cloudSyncAttachmentOwnerKindHistorical:
        final historical = historicalJournal;
        if (historical == null) {
          throw StateError(cloudSyncAttachmentOwnerChangedCode);
        }
        return CloudSyncAttachmentUploadOrigin.historical(
          uploads.readHistoricalOriginalSource(uploadId, historical),
        );
      case cloudSyncAttachmentOwnerKindLocalSend:
        return CloudSyncAttachmentUploadOrigin.local(
          uploads.readOriginalSource(uploadId),
        );
    }
    throw StateError(cloudSyncAttachmentOwnerChangedCode);
  }

  final CloudSyncLocalSendSourceBinding? _local;
  final CloudSyncHistoricalProtectedSourceBinding? _historical;
  final CloudSyncReceivedArchiveSourceBinding? _received;

  bool get isHistorical => _historical != null;
  bool get isReceived => _received != null;
  String get encoded =>
      _received?.encode() ?? _historical?.encode() ?? _local!.encode();
  String get accountFingerprint =>
      _received?.accountFingerprint ??
      _historical?.accountFingerprint ??
      _local!.accountFingerprint;
  String get protectedStoreIdentity =>
      _received?.protectedStoreIdentity ??
      _historical?.protectedStoreIdentity ??
      _local!.protectedStoreIdentity;

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

  /// Distinct received origin for the shared byte-upload lifecycle. The
  /// received source keeps its committed native receive evidence and is
  /// never promoted to an IDS send receipt.
  ///
  /// Depends on the generated `CloudSyncReceivedAttachmentContext` plus the
  /// existing `CloudSyncNativeReceivedArchiveSourceBinding`. Both arrive
  /// with the parent's coherent binding import; no analyzer/test/build
  /// until then.
  api.CloudSyncReceivedAttachmentContext receivedContext({
    required String storageDirectory,
    required api.CloudSyncNativeAuthMetadata auth,
  }) {
    final source = _received;
    if (source == null) throw StateError(cloudSyncAttachmentOwnerChangedCode);
    requireIdentity(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
    );
    return api.CloudSyncReceivedAttachmentContext(
      storageDirectory: storageDirectory,
      expectedAuth: auth,
      source: api.CloudSyncNativeReceivedArchiveSourceBinding(
        accountFingerprint: source.accountFingerprint,
        protectedStoreIdentity: source.protectedStoreIdentity,
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
