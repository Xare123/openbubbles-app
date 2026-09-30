import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloudkit_writer_authority.dart';

/// Read-only bridge from a confirmed own-message receipt to the semantic
/// reader. It never stages, submits, retries, writes snapshots or changes an
/// authority. The caller pins native auth before construction and revalidates
/// it around decoding; [stillCurrent] reads loaded process state only.
final class ObjectBoxConfirmedMessageDependencyReader {
  ObjectBoxConfirmedMessageDependencyReader({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot authoritySnapshot,
    required CloudSyncNativeAuthSnapshot auth,
    required CloudSyncScope attachmentScope,
    required int attachmentGeneration,
    required bool Function() stillCurrent,
  }) : _store = store,
       _auth = auth,
       // Keep the public callback name while storing it privately.
       // ignore: prefer_initializing_formals
       _stillCurrent = stillCurrent {
    if (authoritySnapshot.scope.accountFingerprint != auth.accountFingerprint) {
      throw StateError('cloud_sync_local_send_auth_changed');
    }
    late final CloudSyncAttachmentUploadJournal uploads;
    _journal = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authoritySnapshot,
      attachmentParentReadback: (intentId, retainedProof) {
        // Reading must never capture a replacement proof or a native inventory.
        if (retainedProof == null) {
          throw StateError('cloud_sync_attachment_parent_readback_required');
        }
        uploads.requireParentReadbackProof(
          localSendIntentId: intentId,
          proof: retainedProof,
        );
        return retainedProof;
      },
    );
    uploads = CloudSyncAttachmentUploadJournal(
      store: store,
      localSends: _journal,
      scope: attachmentScope,
      checkpointGeneration: attachmentGeneration,
      currentAuth: auth,
    );
  }

  final Store _store;
  final CloudSyncNativeAuthSnapshot _auth;
  final bool Function() _stillCurrent;
  late final CloudSyncLocalSendJournal _journal;

  List<Object>? read(CloudSyncScope scope, Message parent) =>
      _store.runInTransaction(TxMode.read, () {
        if (!_stillCurrent() ||
            scope.accountFingerprint != _auth.accountFingerprint) {
          throw StateError('cloud_sync_local_send_identity_changed');
        }
        return _journal.readConfirmedParentDependency(_store, scope, parent);
      });
}
