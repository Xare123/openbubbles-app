import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

import 'cloud_sync_attachment_plan_coordinator.dart';
import 'cloud_sync_attachment_upload_executor.dart';
import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloud_sync_safe_failure.dart';
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

/// Native counterpart of the plan coordinator's callbacks. The caller supplies
/// a path from the exact journal-validated local attachment, not a global search.
/// Native preparation independently verifies those bytes against the retained
/// IDS descriptor before staging a plan. It neither adopts nor uploads here.
final class FrbCloudSyncAttachmentPlanSource {
  FrbCloudSyncAttachmentPlanSource({required this.storageDirectory}) {
    if (storageDirectory.isEmpty) {
      throw ArgumentError('cloud_sync_attachment_plan_storage_invalid');
    }
  }

  final String storageDirectory;

  Future<List<CloudSyncAttachmentPlanInventoryItem>> inspect(
    CloudSyncLocalSendSourceBinding source,
    CloudSyncNativeAuthSnapshot auth,
  ) async {
    final context = receiptContext(source, auth);
    final entries = await _nativePlanCall(
      'cloud_sync_attachment_plan_inventory_failed',
      () => api.cloudSyncInspectAttachmentSources(
        cloudMessagesClient: _client(auth),
        context: context,
      ),
    );
    return List.unmodifiable(
      entries.map(
        (item) => CloudSyncAttachmentPlanInventoryItem(
          originalAttachmentGuid: item.originalAttachmentGuid,
          reflectedAttachmentGuid: item.reflectedAttachmentGuid,
          logicalEntityKeyHash: item.logicalEntityKeyHash,
        ),
      ),
    );
  }

  Future<CloudSyncProtectedOutboundStageData> stage(
    CloudSyncAttachmentPlanInventoryItem item,
    CloudSyncLocalSendSourceBinding source,
    CloudSyncNativeAuthSnapshot auth, {
    required String sourcePath,
    required int startDateNanoseconds,
    required int createdDateNanoseconds,
  }) async {
    final context = receiptContext(source, auth);
    if (sourcePath.isEmpty) {
      throw StateError('cloud_sync_attachment_plan_source_unavailable');
    }
    final result = await _nativePlanCall(
      'cloud_sync_attachment_plan_native_stage_failed',
      () => api.cloudSyncStageAttachmentUploadPlan(
        cloudMessagesClient: _client(auth),
        context: context,
        originalAttachmentGuid: item.originalAttachmentGuid,
        sourcePath: sourcePath,
        startDateNs: startDateNanoseconds,
        createdDateNs: createdDateNanoseconds,
      ),
    );
    final stage = result.stage;
    // The coordinator checks identity, adopts and commits this exact lease.
    // Keep failures in that owner so an unadopted returned stage can be released.
    return CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: stage.logicalEntityKeyHash,
      protectedEnvelopeReference: stage.protectedPayloadReference,
      payloadSha256: stage.payloadSha256,
      serverRecordIdHash: stage.serverRecordIdHash,
      leaseReference: stage.leaseReference,
    );
  }

  // The native preparation already emits fixed failures, but FRB wraps them
  // in AnyhowException. Preserve only exact reviewed values before the outer
  // consumer redacts errors. No prefix matching, server text, or source paths.
  Future<T> _nativePlanCall<T>(
    String fallback,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on AnyhowException catch (error, stack) {
      final candidate = switch (error.message) {
        'attachment source preparation unavailable' =>
          'cloud_sync_attachment_preparation_unavailable',
        'attachment source unavailable or does not match original IDS bytes' =>
          'cloud_sync_attachment_source_mismatch',
        'attachment upload source invalid' =>
          'cloud_sync_attachment_source_invalid',
        _ => error.message,
      };
      final code = cloudSyncV2SafeFailureCodeForCandidate(candidate);
      Error.throwWithStackTrace(
        StateError(code == 'cloud_sync_unknown_failure' ? fallback : code),
        stack,
      );
    }
  }

  native.ArcCloudMessagesClientDefaultAnisetteProvider _client(
    CloudSyncNativeAuthSnapshot auth,
  ) {
    final client = auth.cloudMessagesClient;
    if (client is! native.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw StateError('cloud_sync_attachment_plan_client_invalid');
    }
    return client;
  }

  /// Same exact context for inventory, upload plans and the containing Message.
  /// Native callers still capture live auth and reopen the committed source.
  api.CloudSyncNativeSendReceiptContext receiptContext(
    CloudSyncLocalSendSourceBinding source,
    CloudSyncNativeAuthSnapshot auth,
  ) {
    source.requireOrigin(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      messageGuidHash: source.messageGuidHash,
      sourceSha256: source.sourceSha256,
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
}
