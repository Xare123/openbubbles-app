import 'cloud_sync_attachment_upload_executor.dart';
import 'cloud_sync_attachment_upload_journal.dart';
import 'cloudkit_writer_mutation_guard.dart';
import 'cloudkit_writer_ownership.dart';
import 'objectbox_cloud_sync_store.dart';

/// Uses the existing production guard, including its durable unknown-outcome
/// fence. No substitute token or new ownership rules are introduced here.
final class GuardedCloudSyncAttachmentUploadMutationGate
    implements CloudSyncAttachmentUploadMutationGate {
  const GuardedCloudSyncAttachmentUploadMutationGate(this.guard);

  final CloudKitWriterMutationGuard guard;

  @override
  Future<T> runAuthorized<T>({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    String? expectedAccountFingerprint,
    required String? preparedHandleBindingSha256,
    String? reconciliationBindingSha256,
    required void Function() requireAdmission,
    required Future<void> Function() requireDurableAdmission,
    required Future<T> Function(String capabilityToken) action,
  }) => guard.runAuthorized(
    owner: owner,
    expectedClient: expectedClient,
    expectedAccountFingerprint: expectedAccountFingerprint,
    preparedHandleBindingSha256: preparedHandleBindingSha256,
    reconciliationBindingSha256: reconciliationBindingSha256,
    requireAdmission: requireAdmission,
    requireDurableAdmission: requireDurableAdmission,
    action: (capability) => action(capability.consumeForNative()),
  );

  @override
  Future<bool> reconcileAttachmentUpload({
    required Object expectedClient,
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
  }) => guard.reconcileAttachmentUpload(
    expectedClient: expectedClient,
    uploads: uploads,
    uploadId: uploadId,
  );

  @override
  void markActiveMutationUnknown() => guard.markActiveMutationUnknown();
}

/// Final-record admission uses the journal's exact attachment scope. The store
/// checks shared ownership, checkpoint generation, IDS proof and read readiness.
final class ObjectBoxCloudSyncCompletedUploadAdmitter
    implements CloudSyncCompletedUploadAdmitter {
  const ObjectBoxCloudSyncCompletedUploadAdmitter(this.store);

  final ObjectBoxCloudSyncStore store;

  @override
  CloudAttachmentUploadSnapshot admitCompletedAttachmentUpload({
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
    required DateTime createdAt,
  }) => store.admitCompletedAttachmentUpload(
    scope: uploads.scope,
    uploads: uploads,
    uploadId: uploadId,
    createdAt: createdAt,
  );
}
