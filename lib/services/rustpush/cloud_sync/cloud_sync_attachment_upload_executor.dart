/// Bounded production executor for one persisted attachment byte upload.
///
/// Owns exactly one durable upload lifecycle for an existing journal row:
/// prepare -> durable beginAttempt (original native attempt) -> mutation
/// authorization -> single consume -> recordUploaded -> result-lease commit ->
/// store.admitCompletedAttachmentUpload. Parent message dispatch stays with
/// the existing outbox; this executor never touches it.
///
/// Safety rules (all enforced below, none logged with content):
/// - started/unknown rows recover by exact native receipt only, never by
///   preparing again and never by treating a missing receipt as success.
/// - uploaded/adopted rows reuse the existing result lease and verify the
///   native receipt without restaging.
/// - Native auth is revalidated around every await; drift fails closed.
/// - Diagnostics carry only safe codes, never references, digests, or bytes.
// ignore_for_file: prefer_initializing_formals
library;

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;

import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Narrow outcome for the parent adapter. No payload, reference, or digest.
enum CloudAttachmentUploadExecutionStatus {
  /// Fresh prepare -> consume path reached durable admission.
  completed,

  /// started/unknown recovered from the exact native receipt, then admitted.
  recoveredAndCompleted,

  /// Row was already adopted; existing result lease reused, no restage.
  alreadyCompleted,

  /// Native outcome uncertain; row left started/unknown for receipt recovery.
  unknownOutcome,

  /// No native receipt; caller may retry later. Nothing restaged.
  awaitingReceipt,

  /// Native proved rejection; journal row left untouched for the parent.
  failed,
}

final class CloudAttachmentUploadExecution {
  const CloudAttachmentUploadExecution({
    required this.status,
    required this.uploadId,
    this.admittedOperationId,
    this.receiptVerified,
    this.failureClass,
    this.retryAfterSeconds,
  });

  final CloudAttachmentUploadExecutionStatus status;
  final int uploadId;
  final String? admittedOperationId;
  final bool? receiptVerified;
  final frb_api.CloudSyncOutboundFailureClass? failureClass;
  final BigInt? retryAfterSeconds;
}

/// Caller-supplied origin material the journal cannot provide. The plan
/// itself always comes from the persisted snapshot, never from the caller.
final class CloudSyncAttachmentUploadExecutionInput {
  const CloudSyncAttachmentUploadExecutionInput({
    required this.uploadId,
    required this.originalAttachmentGuid,
    required this.sourcePath,
    required this.requestTimeoutSeconds,
    this.retainedSourceAttachmentKeys,
  });

  final int uploadId;
  final String originalAttachmentGuid;
  final String sourcePath;
  final BigInt requestTimeoutSeconds;
  /// Complete native-derived inventory for a retained first attempt after
  /// authority recovery. Null preserves the ordinary current-epoch path.
  /// Started/unknown uploads never use this to authorize another attempt.
  final Set<String>? retainedSourceAttachmentKeys;
}

/// Single-use native preparation. The handle owner is noncloneable: exactly
/// one consume, then dispose. Implementations must not copy the handle.
abstract interface class CloudSyncPreparedUpload {
  String get handleBindingSha256;
  String get uploadAttemptId;

  Future<frb_api.CloudSyncAttachmentUploadConsumeResult> consume(
    String capabilityToken,
  );

  Future<void> dispose();
}

/// Testable native seam. Production uses [FrbCloudSyncAttachmentUploadBridge].
abstract interface class CloudSyncAttachmentUploadBridge {
  Future<CloudSyncPreparedUpload> prepare({
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
    required String originalAttachmentGuid,
    required String sourcePath,
    required BigInt requestTimeoutSeconds,
  });

  /// Reconstructs a lost bridge result from the original native receipt.
  /// Null means no receipt: the caller must wait, never restage.
  Future<frb_api.CloudSyncProtectedOutboundStage?> recover({
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
  });
}

/// Narrow mutation gate. The parent adapts the real guard to this shape by
/// running it with a token-forwarding action, so the single-consume token
/// crosses exactly once. Fakes use an opaque test token.
abstract interface class CloudSyncAttachmentUploadMutationGate {
  Future<T> runAuthorized<T>({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    String? expectedAccountFingerprint,
    required String? preparedHandleBindingSha256,
    String? reconciliationBindingSha256,
    required void Function() requireAdmission,
    required Future<void> Function() requireDurableAdmission,
    required Future<T> Function(String capabilityToken) action,
  });

  /// Exact-fence native receipt verification owned by the writer guard.
  /// Separates original evidence from fresh authority; missing or ambiguous
  /// completion stays unresolved (false), never retried or re-prepared here.
  Future<bool> reconcileAttachmentUpload({
    required Object expectedClient,
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
  });

  /// Marks the active native mutation unknown from inside the authorized
  /// action when the consume outcome is unknown or malformed. The parent
  /// maps this to the real guard, which then fails closed instead of
  /// disarming the fence as success.
  void markActiveMutationUnknown();
}

/// Durable handoff seam. Production passes the ObjectBox store, which already
/// exposes this exact method; tests substitute a journal-backed fake.
abstract interface class CloudSyncCompletedUploadAdmitter {
  CloudAttachmentUploadSnapshot admitCompletedAttachmentUpload({
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
    required DateTime createdAt,
  });
}

/// Concrete FRB adapter. No journal, guard, or outbox access. The receipt
/// context must carry this bridge storage directory; a mismatch fails fast
/// instead of staging under a foreign protected store.
final class FrbCloudSyncAttachmentUploadBridge
    implements CloudSyncAttachmentUploadBridge {
  FrbCloudSyncAttachmentUploadBridge({
    required frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider
    cloudMessagesClient,
    required String storageDirectory,
  }) : _client = cloudMessagesClient,
       _storageDirectory = storageDirectory {
    if (_storageDirectory.isEmpty) {
      throw ArgumentError.value(
        storageDirectory,
        'storageDirectory',
        'must not be empty',
      );
    }
  }

  final frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider _client;
  final String _storageDirectory;

  @override
  Future<CloudSyncPreparedUpload> prepare({
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
    required String originalAttachmentGuid,
    required String sourcePath,
    required BigInt requestTimeoutSeconds,
  }) async {
    _requireStorageDirectory(context);
    final prepared = await frb_api.cloudSyncPrepareAttachmentUpload(
      cloudMessagesClient: _client,
      context: context,
      planStage: planStage,
      originalAttachmentGuid: originalAttachmentGuid,
      sourcePath: sourcePath,
      requestTimeoutSeconds: requestTimeoutSeconds,
    );
    return _FrbPreparedUpload(prepared);
  }

  @override
  Future<frb_api.CloudSyncProtectedOutboundStage?> recover({
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
  }) {
    _requireStorageDirectory(context);
    return frb_api.cloudSyncRecoverAttachmentUpload(
      cloudMessagesClient: _client,
      context: context,
      planStage: planStage,
    );
  }

  void _requireStorageDirectory(
    frb_api.CloudSyncNativeSendReceiptContext context,
  ) {
    if (context.storageDirectory != _storageDirectory) {
      throw StateError('cloud_sync_attachment_upload_storage_changed');
    }
  }
}

final class _FrbPreparedUpload implements CloudSyncPreparedUpload {
  _FrbPreparedUpload(this._prepared);

  final frb_api.CloudSyncPreparedAttachmentUploadResult _prepared;
  bool _disposed = false;

  @override
  String get handleBindingSha256 => _prepared.handleBindingSha256;

  @override
  String get uploadAttemptId => _prepared.uploadAttemptId;

  @override
  Future<frb_api.CloudSyncAttachmentUploadConsumeResult> consume(
    String capabilityToken,
  ) => frb_api.cloudSyncConsumePreparedAttachmentUpload(
    handle: _prepared.handle,
    mutationCapabilityToken: capabilityToken,
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _prepared.handle.dispose();
  }
}

/// Executes one persisted upload to durable admission. The caller holds the
/// CloudKit interlock and the protected-store exclusion across the call.
/// Exactly one [execute] per upload id may run at a time.
final class CloudSyncAttachmentUploadExecutor {
  CloudSyncAttachmentUploadExecutor({
    required CloudSyncAttachmentUploadJournal uploads,
    required CloudSyncNativeAuthSnapshotReader readLiveAuth,
    required CloudSyncAttachmentUploadMutationGate mutationGate,
    required CloudSyncAttachmentUploadBridge bridge,
    required CloudSyncOutboundStagingTransport staging,
    required CloudSyncCompletedUploadAdmitter completedAdmitter,
    required String privateStorageDirectory,
    DateTime Function()? clock,
  }) : _uploads = uploads,
       _readLiveAuth = readLiveAuth,
       _mutationGate = mutationGate,
       _bridge = bridge,
       _staging = staging,
       _completedAdmitter = completedAdmitter,
       _privateStorageDirectory = privateStorageDirectory,
       _clock = clock ?? DateTime.now {
    if (privateStorageDirectory.isEmpty) {
      throw ArgumentError.value(
        privateStorageDirectory,
        'privateStorageDirectory',
        'must not be empty',
      );
    }
  }

  final CloudSyncAttachmentUploadJournal _uploads;
  final CloudSyncNativeAuthSnapshotReader _readLiveAuth;
  final CloudSyncAttachmentUploadMutationGate _mutationGate;
  final CloudSyncAttachmentUploadBridge _bridge;
  final CloudSyncOutboundStagingTransport _staging;
  final CloudSyncCompletedUploadAdmitter _completedAdmitter;
  final String _privateStorageDirectory;
  final DateTime Function() _clock;
  final Set<int> _active = <int>{};

  Future<CloudAttachmentUploadExecution> execute(
    CloudSyncAttachmentUploadExecutionInput input,
  ) async {
    // Only the upload id is required here. Fresh-path origin inputs are
    // validated on the prepared branch; recovery must not require them.
    if (input.uploadId <= 0) {
      throw StateError('cloud_sync_attachment_upload_input_invalid');
    }
    if (!_active.add(input.uploadId)) {
      throw StateError('cloud_sync_attachment_upload_executor_busy');
    }
    try {
      final retainedKeys = input.retainedSourceAttachmentKeys == null
          ? null : Set<String>.unmodifiable(input.retainedSourceAttachmentKeys!);
      final auth = await _liveAuth();
      final snapshot = _uploads.read(input.uploadId);
      switch (snapshot.state) {
        case CloudAttachmentUploadState.prepared:
          return await _uploadFresh(input, auth, retainedKeys);
        case CloudAttachmentUploadState.started:
        case CloudAttachmentUploadState.unknown:
          return await _recoverExact(input.uploadId, auth);
        case CloudAttachmentUploadState.uploaded:
          return await _completeExistingResult(
            input.uploadId,
            auth,
            alreadyAdmitted: false,
          );
        case CloudAttachmentUploadState.adopted:
          return await _completeExistingResult(
            input.uploadId,
            auth,
            alreadyAdmitted: true,
          );
      }
    } finally {
      _active.remove(input.uploadId);
    }
  }

  Future<CloudAttachmentUploadExecution> _uploadFresh(
    CloudSyncAttachmentUploadExecutionInput input,
    CloudSyncNativeAuthSnapshot auth,
    Set<String>? retainedKeys,
  ) async {
    // Fresh-path-only input limits: recovery never requires these. The
    // native timeout is explicitly bounded to 1..300 seconds.
    if (input.originalAttachmentGuid.isEmpty ||
        input.sourcePath.isEmpty ||
        input.requestTimeoutSeconds < BigInt.one ||
        input.requestTimeoutSeconds > BigInt.from(300)) {
      throw StateError('cloud_sync_attachment_upload_input_invalid');
    }
    // Pin original evidence BEFORE prepare: a changed durable plan must
    // never authorize previously prepared bytes. requireOrigin runs here,
    // ahead of any native staging.
    final pinnedSource = _uploads.readOriginalSource(input.uploadId);
    final pinnedSnapshot = _uploads.read(input.uploadId);
    final pinnedPlan = pinnedSnapshot.plan;
    final pinnedSourceCode = pinnedSource.encode();
    // Actual account/store origin gate BEFORE any native staging: the
    // pinned source must belong to the live auth, not merely to the auth
    // the journal was bound with. Guid/sha equality to the durable row is
    // enforced separately by the encode pin checks.
    _requireLiveOrigin(pinnedSource, auth);
    final context = _receiptContext(auth, pinnedSource);
    final planStage = _planReference(pinnedSnapshot);
    final prepared = await _bridge.prepare(
      context: context,
      planStage: planStage,
      originalAttachmentGuid: input.originalAttachmentGuid,
      sourcePath: input.sourcePath,
      requestTimeoutSeconds: input.requestTimeoutSeconds,
    );
    try {
      final current = await _liveAuth();
      _requireSameAuth(auth, current);
      _requirePinnedEvidence(
        input.uploadId,
        pinnedPlan,
        pinnedSourceCode,
        current,
      );
      // Durable attempt BEFORE the single native consume. The original
      // native attempt id binds journal, fence, and receipt together.
      if (retainedKeys == null) {
        _uploads.beginAttempt(
          id: input.uploadId, attemptId: prepared.uploadAttemptId, now: _clock());
      } else {
        _uploads.beginRetainedAttempt(
          id: input.uploadId, attemptId: prepared.uploadAttemptId,
          sourceAttachmentKeys: retainedKeys, now: _clock());
      }
      final fenceBinding = _uploads.reconciliationBindingSha256(input.uploadId);
      late final frb_api.CloudSyncAttachmentUploadConsumeResult consumed;
      try {
        consumed = await _mutationGate.runAuthorized(
          owner: CloudKitWriterOwner.v2,
          expectedClient: current.cloudMessagesClient,
          expectedAccountFingerprint: current.accountFingerprint,
          preparedHandleBindingSha256: prepared.handleBindingSha256,
          reconciliationBindingSha256: fenceBinding,
          requireAdmission: () => _requireStartedAttempt(
            input.uploadId,
            prepared.uploadAttemptId,
            current,
            pinnedPlan,
            pinnedSourceCode,
          ),
          requireDurableAdmission: () async => _requireStartedAttempt(
            input.uploadId,
            prepared.uploadAttemptId,
            current,
            pinnedPlan,
            pinnedSourceCode,
          ),
          action: (token) async {
            final result = await prepared.consume(token);
            final stage = result.stage;
            // Correlate the success stage to the pinned plan inside the
            // action: logical/server identity is what the journal binds.
            // protectedServerRecordReference is not projected into the
            // journal envelope, matching the recordUploaded contract.
            final identityChanged =
                stage != null &&
                (stage.logicalEntityKeyHash !=
                        pinnedPlan.logicalEntityKeyHash ||
                    stage.serverRecordIdHash != pinnedPlan.serverRecordIdHash);
            final malformed =
                result.uploadAttemptId != prepared.uploadAttemptId ||
                identityChanged ||
                (result.disposition ==
                        frb_api.CloudSyncOutboundSaveDisposition.succeeded &&
                    stage == null) ||
                (result.disposition !=
                        frb_api.CloudSyncOutboundSaveDisposition.succeeded &&
                    stage != null);
            if (result.disposition ==
                    frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome ||
                malformed) {
              // Inside the authorized action: an unknown or malformed
              // native outcome must never disarm the fence as success.
              _mutationGate.markActiveMutationUnknown();
              throw StateError(
                malformed
                    ? 'cloud_sync_attachment_upload_result_changed'
                    : 'cloud_sync_attachment_upload_outcome_unknown',
              );
            }
            return result;
          },
        );
      } on CloudKitWriterAuthorityFailure catch (error) {
        if (error.safeCode == 'cloudkit_writer_mutation_outcome_unknown') {
          _markUnknownBestEffort(input.uploadId, prepared.uploadAttemptId);
          return CloudAttachmentUploadExecution(
            status: CloudAttachmentUploadExecutionStatus.unknownOutcome,
            uploadId: input.uploadId,
          );
        }
        rethrow;
      }
      // Capture inside the cleanup scope: a null or throwing auth read
      // after a successful consume must still release the newly staged
      // result, which is recorded nowhere yet and therefore proven
      // unadopted. Only a success stage exists natively; other
      // dispositions leak nothing.
      final CloudSyncNativeAuthSnapshot afterConsume;
      try {
        afterConsume = await _liveAuth();
        _requireSameAuth(current, afterConsume);
      } on Object {
        final stray =
            consumed.disposition ==
            frb_api.CloudSyncOutboundSaveDisposition.succeeded;
        await _rollbackBestEffort(stray ? _stageData(consumed.stage!) : null);
        rethrow;
      }
      // Attempt identity is enforced inside the authorized action above,
      // before the guard can disarm the fence.
      switch (consumed.disposition) {
        case frb_api.CloudSyncOutboundSaveDisposition.succeeded:
          // A null stage cannot reach here: the authorized action rejects
          // it before the guard can disarm the fence.
          return await _recordCommitAdmit(
            input.uploadId,
            prepared.uploadAttemptId,
            _stageData(consumed.stage!),
            afterConsume,
            recovered: false,
          );
        case frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome:
          // Unreachable through the real guard, which converts the
          // in-action rejection into outcome-unknown. A lenient fake takes
          // this branch; fail closed identically.
          _mutationGate.markActiveMutationUnknown();
          _markUnknownBestEffort(input.uploadId, prepared.uploadAttemptId);
          return CloudAttachmentUploadExecution(
            status: CloudAttachmentUploadExecutionStatus.unknownOutcome,
            uploadId: input.uploadId,
          );
        case frb_api.CloudSyncOutboundSaveDisposition.failed:
          return CloudAttachmentUploadExecution(
            status: CloudAttachmentUploadExecutionStatus.failed,
            uploadId: input.uploadId,
            failureClass: consumed.failureClass,
            retryAfterSeconds: consumed.retryAfterSeconds,
          );
      }
    } finally {
      await prepared.dispose();
    }
  }

  /// started/unknown: exact native receipt recovery only. Never prepares
  /// again; a missing receipt defers without touching the journal.
  Future<CloudAttachmentUploadExecution> _recoverExact(
    int uploadId,
    CloudSyncNativeAuthSnapshot auth,
  ) async {
    final snapshot = _uploads.read(uploadId);
    final attemptId = snapshot.attemptId;
    if (attemptId == null) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    final verified = await _mutationGate.reconcileAttachmentUpload(
      expectedClient: auth.cloudMessagesClient,
      uploads: _uploads,
      uploadId: uploadId,
    );
    final current = await _liveAuth();
    _requireSameAuth(auth, current);
    if (!verified) {
      return CloudAttachmentUploadExecution(
        status: CloudAttachmentUploadExecutionStatus.awaitingReceipt,
        uploadId: uploadId,
        receiptVerified: false,
      );
    }
    final source = _uploads.readOriginalSource(uploadId);
    _requireLiveOrigin(source, current);
    final planStage = _planReference(_uploads.read(uploadId));
    final recovered = await _bridge.recover(
      context: _receiptContext(current, source),
      planStage: planStage,
    );
    if (recovered == null) {
      final afterNull = await _liveAuth();
      _requireSameAuth(current, afterNull);
      return CloudAttachmentUploadExecution(
        status: CloudAttachmentUploadExecutionStatus.awaitingReceipt,
        uploadId: uploadId,
        receiptVerified: true,
      );
    }
    // Non-null recovery delegates its post-recover auth gate to
    // _recordCommitAdmit, which releases the newly staged lease when the
    // capture fails or drifts before anything is recorded.
    return await _recordCommitAdmit(
      uploadId,
      attemptId,
      _stageData(recovered),
      current,
      recovered: true,
    );
  }

  /// uploaded/adopted: reuse the existing result lease, verify the receipt
  /// without restaging, never prepare or consume.
  Future<CloudAttachmentUploadExecution> _completeExistingResult(
    int uploadId,
    CloudSyncNativeAuthSnapshot auth, {
    required bool alreadyAdmitted,
  }) async {
    final snapshot = _uploads.read(uploadId);
    final result = snapshot.result;
    if (result == null) {
      throw StateError('cloud_sync_attachment_upload_result_missing');
    }
    final verified = await _mutationGate.reconcileAttachmentUpload(
      expectedClient: auth.cloudMessagesClient,
      uploads: _uploads,
      uploadId: uploadId,
    );
    final current = await _liveAuth();
    _requireSameAuth(auth, current);
    final fresh = _uploads.read(uploadId);
    if (alreadyAdmitted) {
      // Never call an admission completed without receipt verification.
      // Validate the existing admission idempotently; restage nothing.
      if (!verified || fresh.admittedOperationId == null) {
        return CloudAttachmentUploadExecution(
          status: CloudAttachmentUploadExecutionStatus.awaitingReceipt,
          uploadId: uploadId,
          receiptVerified: verified,
        );
      }
      return CloudAttachmentUploadExecution(
        status: CloudAttachmentUploadExecutionStatus.alreadyCompleted,
        uploadId: uploadId,
        admittedOperationId: fresh.admittedOperationId,
        receiptVerified: true,
      );
    }
    if (!verified) {
      return CloudAttachmentUploadExecution(
        status: CloudAttachmentUploadExecutionStatus.awaitingReceipt,
        uploadId: uploadId,
        receiptVerified: false,
      );
    }
    await _staging.commitOutboundLease(
      result.leaseReference,
      result.protectedEnvelopeReference,
    );
    final afterCommit = await _liveAuth();
    _requireSameAuth(current, afterCommit);
    final admitted = _completedAdmitter.admitCompletedAttachmentUpload(
      uploads: _uploads,
      uploadId: uploadId,
      createdAt: _clock(),
    );
    return CloudAttachmentUploadExecution(
      status: CloudAttachmentUploadExecutionStatus.completed,
      uploadId: uploadId,
      admittedOperationId: admitted.admittedOperationId,
      receiptVerified: true,
    );
  }

  Future<CloudAttachmentUploadExecution> _recordCommitAdmit(
    int uploadId,
    String attemptId,
    CloudSyncProtectedOutboundStageData result,
    CloudSyncNativeAuthSnapshot auth, {
    required bool recovered,
  }) async {
    // The incoming result is newly staged and recorded nowhere yet: an
    // auth capture failure or mismatch here must release it. Once
    // recordUploaded succeeds the lease belongs to the journal and is
    // never rolled back on this path.
    final CloudSyncNativeAuthSnapshot current;
    try {
      current = await _liveAuth();
      _requireSameAuth(auth, current);
    } on Object {
      // The reader may fail with any Object, not just StateError. Release
      // the still-unrecorded lease, then rethrow the original failure
      // intact. After recordUploaded this never runs.
      await _rollbackBestEffort(result);
      rethrow;
    }
    final uploaded = _uploads.recordUploaded(
      id: uploadId,
      attemptId: attemptId,
      result: result,
      now: _clock(),
    );
    final resultLease = uploaded.result;
    if (resultLease == null) {
      throw StateError('cloud_sync_attachment_upload_result_missing');
    }
    await _staging.commitOutboundLease(
      resultLease.leaseReference,
      resultLease.protectedEnvelopeReference,
    );
    // The lease is now committed and the result durably recorded: never
    // roll back from here. Revalidate before the final admission instead.
    final afterCommit = await _liveAuth();
    _requireSameAuth(current, afterCommit);
    final admitted = _completedAdmitter.admitCompletedAttachmentUpload(
      uploads: _uploads,
      uploadId: uploadId,
      createdAt: _clock(),
    );
    return CloudAttachmentUploadExecution(
      status: recovered
          ? CloudAttachmentUploadExecutionStatus.recoveredAndCompleted
          : CloudAttachmentUploadExecutionStatus.completed,
      uploadId: uploadId,
      admittedOperationId: admitted.admittedOperationId,
      receiptVerified: true,
    );
  }

  void _requireStartedAttempt(
    int uploadId,
    String attemptId,
    CloudSyncNativeAuthSnapshot auth,
    CloudSyncProtectedOutboundStageData pinnedPlan,
    String pinnedSourceCode,
  ) {
    final snapshot = _uploads.read(uploadId);
    if (snapshot.state != CloudAttachmentUploadState.started ||
        snapshot.attemptId != attemptId ||
        !_sameStageData(snapshot.plan, pinnedPlan)) {
      throw StateError('cloud_sync_attachment_upload_attempt_changed');
    }
    final live = _uploads.readOriginalSource(uploadId);
    if (live.encode() != pinnedSourceCode ||
        live.accountFingerprint != auth.accountFingerprint ||
        live.protectedStoreIdentity != auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
  }

  void _requirePinnedEvidence(
    int uploadId,
    CloudSyncProtectedOutboundStageData pinnedPlan,
    String pinnedSourceCode,
    CloudSyncNativeAuthSnapshot auth,
  ) {
    final snapshot = _uploads.read(uploadId);
    if (snapshot.state != CloudAttachmentUploadState.prepared ||
        !_sameStageData(snapshot.plan, pinnedPlan)) {
      throw StateError('cloud_sync_attachment_upload_plan_changed');
    }
    final live = _uploads.readOriginalSource(uploadId);
    if (live.encode() != pinnedSourceCode ||
        live.accountFingerprint != auth.accountFingerprint ||
        live.protectedStoreIdentity != auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
  }

  bool _sameStageData(
    CloudSyncProtectedOutboundStageData left,
    CloudSyncProtectedOutboundStageData right,
  ) =>
      left.logicalEntityKeyHash == right.logicalEntityKeyHash &&
      left.protectedEnvelopeReference == right.protectedEnvelopeReference &&
      left.payloadSha256 == right.payloadSha256 &&
      left.serverRecordIdHash == right.serverRecordIdHash &&
      left.leaseReference == right.leaseReference;

  /// Releases a newly staged but provably unadopted lease. Never called
  /// after recordUploaded: a recorded lease belongs to the journal and is
  /// completed idempotently by a later run, never rolled back here.
  Future<void> _rollbackBestEffort(
    CloudSyncProtectedOutboundStageData? stage,
  ) async {
    final lease = stage?.leaseReference;
    if (lease == null) return;
    try {
      await _staging.rollbackOutboundLease(lease);
    } on Object {
      // Best effort only; the original failure stays authoritative.
    }
  }

  void _requireLiveOrigin(
    CloudSyncLocalSendSourceBinding source,
    CloudSyncNativeAuthSnapshot auth,
  ) {
    try {
      source.requireOrigin(
        accountFingerprint: auth.accountFingerprint,
        messageGuidHash: source.messageGuidHash,
        sourceSha256: source.sourceSha256,
        protectedStoreIdentity: auth.protectedStoreIdentity,
      );
    } on StateError {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
  }

  void _markUnknownBestEffort(int uploadId, String attemptId) {
    try {
      _uploads.markUnknown(id: uploadId, attemptId: attemptId, now: _clock());
    } on StateError {
      // Terminal rows (uploaded/adopted) keep their stronger state.
    }
  }

  Future<CloudSyncNativeAuthSnapshot> _liveAuth() async {
    final auth = await _readLiveAuth();
    if (auth == null) {
      throw StateError('cloud_sync_attachment_upload_auth_changed');
    }
    return auth;
  }

  void _requireSameAuth(
    CloudSyncNativeAuthSnapshot before,
    CloudSyncNativeAuthSnapshot after,
  ) {
    if (!before.sameIdentity(after)) {
      throw StateError('cloud_sync_attachment_upload_auth_changed');
    }
  }

  frb_api.CloudSyncNativeSendReceiptContext _receiptContext(
    CloudSyncNativeAuthSnapshot auth,
    CloudSyncLocalSendSourceBinding source,
  ) => frb_api.CloudSyncNativeSendReceiptContext(
    storageDirectory: _privateStorageDirectory,
    guidHash: source.messageGuidHash,
    accountFingerprint: auth.accountFingerprint,
    protectedStoreIdentity: auth.protectedStoreIdentity,
    nativeSessionId: auth.nativeSessionId,
    sourceBinding: frb_api.CloudSyncNativeSendSourceBinding(
      sourceSha256: source.sourceSha256,
      protectedReference: source.protectedReference,
      leaseReference: source.leaseReference,
      payloadSha256: source.payloadSha256,
      payloadLength: BigInt.from(source.payloadLength),
    ),
  );

  frb_api.CloudSyncAttachmentUploadPlanReference _planReference(
    CloudAttachmentUploadSnapshot snapshot,
  ) => frb_api.CloudSyncAttachmentUploadPlanReference(
    logicalEntityKeyHash: snapshot.plan.logicalEntityKeyHash,
    protectedPayloadReference: snapshot.plan.protectedEnvelopeReference,
    payloadSha256: snapshot.plan.payloadSha256,
    serverRecordIdHash: snapshot.plan.serverRecordIdHash,
    leaseReference: snapshot.plan.leaseReference,
  );

  CloudSyncProtectedOutboundStageData _stageData(
    frb_api.CloudSyncProtectedOutboundStage stage,
  ) => CloudSyncProtectedOutboundStageData(
    logicalEntityKeyHash: stage.logicalEntityKeyHash,
    protectedEnvelopeReference: stage.protectedPayloadReference,
    payloadSha256: stage.payloadSha256,
    serverRecordIdHash: stage.serverRecordIdHash,
    leaseReference: stage.leaseReference,
  );
}
