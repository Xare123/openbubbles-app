import 'dart:async';

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;
import 'package:bluebubbles/utils/logger/logger.dart';

import 'cloud_operation_identity.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_write_transport.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_mutation_guard.dart';
import 'cloudkit_writer_ownership.dart';

const int _maximumChangesPerPage = 200;
const int _maximumProtectedReferencesPerLease =
    (_maximumChangesPerPage * 2) + 1;
const int _maximumAdmittedRawPageBytes = 24 * 1024 * 1024;
const int _maximumIdsMutationSourceBytes = 1024 * 1024;
const int _maximumRecoveryReferences = 4096;
const int _maximumRecoveryResultsPerPass = 64;
const int _maximumLiveProtectedReferences = 131072;
const int _maximumGarbageCollectionResultsPerPass = 64;
const int _maximumProtectedStoreOperationsPerIdentity = 64;
const int _maximumRetryAfterSeconds = 7 * 24 * 60 * 60;
const Set<String> _semanticProtectedStreams = {
  'chats',
  'messages',
  'attachments',
};

/// Attachment-record initial-create payload version (v1), matching the
/// completed-upload/final-save journal contract. No other version is admitted
/// on the attachment initial-create path.
const int _attachmentCreatePayloadVersion = 1;

final RegExp _nativeDigestPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
final RegExp _contentDigestPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _protectedReferencePattern = RegExp(
  r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
);
final RegExp _leaseReferencePattern = RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$');
final RegExp _outboundOperationIdPattern = RegExp(r'^op1:[0-9a-f]{64}$');
final RegExp _canonicalAppleUuidPattern = RegExp(
  r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
);
final RegExp _nativeStoreIdentityPattern = RegExp(
  r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
);
final RegExp _idsReceiptReferencePattern = RegExp(
  r'^obcs2\.ids\.[A-Za-z0-9_-]{43}$',
);

final class _NativeProtectedStoreOperationFailure implements Exception {
  const _NativeProtectedStoreOperationFailure(this.safeCode);

  final String safeCode;
}

final class _NativeProtectedStoreOperationQueue {
  Future<void> tail = Future<void>.value();
  int outstanding = 0;
}

/// One isolate-local, process-wide gate shared by every protected transport.
///
/// The platform composition interlock remains responsible for cross-isolate
/// and cross-process exclusion. This gate closes same-isolate overlap between
/// a protected fetch lifecycle and recovery or maintenance. Same-identity
/// nesting is intentionally reentrant so a lifecycle may hold the gate while
/// its transport invokes one or more native bindings.
final class _NativeProtectedStoreOperationGate {
  static final Object _heldIdentityZoneKey = Object();
  static final Map<String, _NativeProtectedStoreOperationQueue> _queues = {};

  bool isHeldByCurrentZone(String identity) =>
      Zone.current[_heldIdentityZoneKey] == identity;

  Future<T> run<T>(String identity, FutureOr<T> Function() operation) {
    final heldIdentity = Zone.current[_heldIdentityZoneKey] as String?;
    if (heldIdentity == identity) {
      return Future<T>.sync(operation);
    }
    if (heldIdentity != null) {
      return Future<T>.error(
        const _NativeProtectedStoreOperationFailure(
          'protected_store_cross_identity_nesting',
        ),
      );
    }

    final queue = _queues.putIfAbsent(
      identity,
      _NativeProtectedStoreOperationQueue.new,
    );
    if (queue.outstanding >= _maximumProtectedStoreOperationsPerIdentity) {
      return Future<T>.error(
        const _NativeProtectedStoreOperationFailure(
          'protected_store_operation_queue_bound_exceeded',
        ),
      );
    }

    final predecessor = queue.tail;
    final release = Completer<void>();
    final tail = release.future;
    queue
      ..tail = tail
      ..outstanding += 1;

    return () async {
      await predecessor;
      try {
        return await runZoned<Future<T>>(
          () => Future<T>.sync(operation),
          zoneValues: {_heldIdentityZoneKey: identity},
        );
      } finally {
        queue.outstanding -= 1;
        release.complete();
        if (queue.outstanding == 0 && identical(queue.tail, tail)) {
          _queues.remove(identity);
        }
      }
    }();
  }
}

final _NativeProtectedStoreOperationGate _protectedStoreOperationGate =
    _NativeProtectedStoreOperationGate();

enum NativeProtectedChangeKind { save, delete, quarantined }

enum NativeProtectedPreflightCode {
  unsupportedRecordType,
  malformedMetadata,
  oversizedRecord,
  invalidChangeShape,
}

enum NativeProtectedFailureCategory {
  network,
  throttled,
  server,
  authorization,
  pcsUnavailable,
  malformedRecord,
  conflict,
  localStorage,
  unknown,
}

final class NativeProtectedFailure {
  const NativeProtectedFailure({
    required this.category,
    required this.safeCode,
    this.retryAfterSeconds,
    this.protectedResetProofReference,
  });

  final NativeProtectedFailureCategory category;
  final String safeCode;
  final int? retryAfterSeconds;
  final String? protectedResetProofReference;
}

final class NativeProtectedChange {
  const NativeProtectedChange({
    required this.changeId,
    required this.recordIdHash,
    required this.kind,
    required this.payloadSha256,
    required this.payloadLength,
    required this.protectedRecordIdentityReference,
    required this.protectedRawEnvelopeReference,
    required this.isTombstone,
    this.etagHash,
    this.serverModifiedAtMillis,
    this.preflightCode,
  });

  final String changeId;
  final String recordIdHash;
  final String? etagHash;
  final NativeProtectedChangeKind kind;
  final String payloadSha256;
  final int payloadLength;
  final String protectedRecordIdentityReference;
  final String protectedRawEnvelopeReference;
  final int? serverModifiedAtMillis;
  final NativeProtectedPreflightCode? preflightCode;
  final bool isTombstone;
}

final class NativeProtectedPage {
  const NativeProtectedPage({
    required this.changes,
    required this.batchId,
    required this.generation,
    required this.pageLeaseReference,
    required this.complete,
    required this.admittedRawBytes,
    this.protectedNextCheckpointReference,
  });

  final List<NativeProtectedChange> changes;
  final String batchId;
  final int generation;
  final String pageLeaseReference;
  final String? protectedNextCheckpointReference;
  final bool complete;
  final int admittedRawBytes;
}

final class NativeProtectedFetchResult {
  const NativeProtectedFetchResult({this.page, this.failure});

  final NativeProtectedPage? page;
  final NativeProtectedFailure? failure;
}

final class NativeProtectedLeaseResult {
  const NativeProtectedLeaseResult({this.failure});

  final NativeProtectedFailure? failure;
}

final class NativeProtectedRecovery {
  const NativeProtectedRecovery({
    required this.finalizedAdoptedLeaseReferences,
    required this.absentAdoptedLeaseReferences,
    required this.rolledBackCount,
    required this.removedTemporaryFilesCount,
    required this.hasMore,
  });

  final List<String> finalizedAdoptedLeaseReferences;
  final List<String> absentAdoptedLeaseReferences;
  final int rolledBackCount;
  final int removedTemporaryFilesCount;
  final bool hasMore;
}

final class NativeProtectedRecoveryResult {
  const NativeProtectedRecoveryResult({this.recovery, this.failure});

  final NativeProtectedRecovery? recovery;
  final NativeProtectedFailure? failure;
}

final class NativeProtectedRetirementResult {
  const NativeProtectedRetirementResult({
    required this.retiredCount,
    this.failure,
  });

  final int retiredCount;
  final NativeProtectedFailure? failure;
}

final class NativeProtectedGarbageCollection {
  const NativeProtectedGarbageCollection({
    required this.scannedCount,
    required this.firstObservedCount,
    required this.deletedCount,
    required this.preservedLiveCount,
    required this.preservedActiveLeaseCount,
    required this.hasMore,
  });

  final int scannedCount;
  final int firstObservedCount;
  final int deletedCount;
  final int preservedLiveCount;
  final int preservedActiveLeaseCount;
  final bool hasMore;
}

final class NativeProtectedGarbageCollectionResult {
  const NativeProtectedGarbageCollectionResult({this.collection, this.failure});

  final NativeProtectedGarbageCollection? collection;
  final NativeProtectedFailure? failure;
}

/// Narrow test seam around D0-only generated Flutter Rust Bridge calls.
abstract interface class NativeProtectedCloudSyncBindings {
  Future<NativeProtectedFetchResult> fetchProtectedPage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  });

  Future<NativeProtectedFetchResult> fetchProtectedPageUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt nativeWriterPauseToken,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  });

  Future<NativeProtectedLeaseResult> commitProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
    required List<String> retainedReferences,
  });

  Future<NativeProtectedLeaseResult> acknowledgeCommittedPageLease({
    required String storageDirectory,
    required String leaseReference,
  });

  Future<NativeProtectedLeaseResult> rollbackProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
  });

  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({
    required String storageDirectory,
    required List<String> adoptedLeaseReferences,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  });

  Future<NativeProtectedRetirementResult> retireProtectedReferences({
    required String storageDirectory,
    required List<String> references,
  });

  Future<NativeProtectedGarbageCollectionResult> collectProtectedGarbage({
    required String storageDirectory,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  });
}

abstract interface class NativeProtectedCloudSyncWriteBindings {
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundMessage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage message,
  });

  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  });

  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  });

  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  });
}

/// Explicit update-only authority for an already-adopted conditional Message
/// update.
///
/// This interface deliberately does not extend [NativeProtectedCloudSyncWriteBindings].
/// An update-lane owner can prepare, consume, and reconcile its exact
/// single-record update without acquiring message-create staging or preparation
/// authority. The prepared update reuses the native single-use create handle,
/// but consumption remains separately named at this boundary so callers never
/// need to cast to the create-capable interface.
abstract interface class NativeProtectedCloudSyncMessageUpdateBindings {
  /// Performs the initial lookup-only update preparation and returns only a
  /// protected, no-save stage. It grants neither create nor remote-save
  /// authority.
  Future<frb_api.CloudSyncPrepareMessageUpdateResult> prepareMessageUpdate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudSyncMessageUpdatePrepareInput input,
  });

  Future<frb_api.CloudSyncPreparedMessageCreateResult>
  prepareMessageUpdateSubmission({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required frb_api.CloudSyncMessageUpdateSubmissionInput input,
  });

  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageUpdate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  });

  Future<frb_api.CloudSyncMessageUpdateReconcileResult> reconcileMessageUpdate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncMessageUpdateSubmissionInput input,
  });
}

/// Explicit opt-in: existing Message-only bindings do not acquire Chat authority.
abstract interface class NativeProtectedCloudSyncChatWriteBindings
    implements NativeProtectedCloudSyncWriteBindings {
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundChat({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudChat chat,
  });

  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  });

  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  });
}

/// Explicit opt-in: existing Message- and Chat-only bindings do not acquire
/// Attachment authority.
///
/// Covers only the final attachment-record save for an already-completed
/// protected asset envelope (no blob upload, no retry admission). The native
/// prepare/reconcile pair takes the same input/result shape as Chat.
abstract interface class NativeProtectedCloudSyncAttachmentWriteBindings
    implements NativeProtectedCloudSyncWriteBindings {
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  });

  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  });
}

/// Explicit opt-in: existing Message-, Chat-, and Attachment-only bindings do
/// not acquire attachment-parent staging authority.
///
/// Covers only the parent message envelope staged under the exact source
/// receipt context supplied by the journal owner (no blob upload, no retry
/// admission, no final Attachment record save).
abstract interface class NativeProtectedCloudSyncAttachmentParentWriteBindings
    implements NativeProtectedCloudSyncWriteBindings {
  Future<frb_api.CloudSyncProtectedOutboundStageResult>
  stageOutboundAttachmentParent({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage messageHeaders,
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentParentGroupProof? groupProof,
  });
}

/// Narrow opt-in for releasing a prepared-but-unconsumed native owner.
/// Existing Message-, Chat-, Attachment-, and parent-only bindings do not
/// acquire release authority, so their mocks keep compiling unchanged.
abstract interface class NativeProtectedPreparedReleaseBindings {
  /// Drops only the unconsumed prepared owner for [handle]. Idempotent:
  /// an already-consumed or already-released handle reports false and an
  /// actively-taken consume is never disturbed.
  Future<bool> releasePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
  });
}

/// Synchronous journal lookup for the exact source receipt context of one
/// message-zone operation. Supplied by the production journal owner, which
/// reads the original adopted journal. A null return means the operation is
/// not an attachment parent and its native inputs stay context-free.
typedef CloudSyncAttachmentParentContextReader =
    frb_api.CloudSyncNativeSendReceiptContext? Function(
      CloudSyncScope scope,
      String operationId,
    );

/// Async journal lookup opening the ephemeral retained-Chat authority for
/// one group attachment parent. The journal reopens it from its pinned
/// source (never a transport cache) on every call; expiry and restart
/// reopen are the journal's job. Invoked only under the protected-store
/// exclusion, only for messageManateeZone, and only when the synchronous
/// context reader already returned a context for the same operation.
typedef CloudSyncAttachmentParentGroupProofReader =
    Future<frb_api.CloudSyncAttachmentParentGroupProof?> Function(
      CloudSyncScope scope,
      String operationId,
    );

enum _CreatePreflightDisposition { absent, alreadyPresent }

final class _NativeCloudSyncPreparedSubmission
    extends CloudSyncPreparedSubmission {
  // Named superclass construction keeps the native handle and the exact
  // remote/no-op partition explicit here.
  // ignore: use_super_parameters
  _NativeCloudSyncPreparedSubmission({
    required CloudSyncScope scope,
    required CloudOutboxSubmissionIdentity identity,
    required List<CloudSyncProtectedWriteOperation> operations,
    required this.handle,
    required this.handleBindingSha256,
    required Iterable<String> remoteOperationIds,
    required Iterable<CloudOutboxCreateReceipt> preconfirmedReceipts,
  }) : remoteOperationIds = List.unmodifiable(remoteOperationIds),
       preconfirmedReceipts = List.unmodifiable(preconfirmedReceipts),
       super.fromProtectedPreflight(
         scope: scope,
         identity: identity,
         operations: operations,
       ) {
    final expected = operationIds.toSet();
    final remote = this.remoteOperationIds.toSet();
    final preconfirmed = this.preconfirmedReceipts
        .map((receipt) => receipt.operationId)
        .toSet();
    if (remote.length != this.remoteOperationIds.length ||
        preconfirmed.length != this.preconfirmedReceipts.length ||
        remote.intersection(preconfirmed).isNotEmpty ||
        remote.union(preconfirmed).length != expected.length ||
        !remote.union(preconfirmed).containsAll(expected) ||
        ((handle == null) != remote.isEmpty) ||
        ((handleBindingSha256 == null) != remote.isEmpty) ||
        (handleBindingSha256 != null &&
            !_contentDigestPattern.hasMatch(handleBindingSha256!))) {
      throw ArgumentError('cloud_sync_native_prepared_partition_invalid');
    }
  }

  final frb_api.CloudSyncPreparedMessageCreateHandle? handle;
  final String? handleBindingSha256;
  final List<String> remoteOperationIds;
  final List<CloudOutboxCreateReceipt> preconfirmedReceipts;

  /// Per-submission memoized release. Lives and dies with this object, so
  /// no transport-wide handle registry can pin owners past their use.
  /// Taken-ness is decided natively per call, never inferred in Dart from
  /// a returned result: a failure result may leave the owner untaken.
  Future<bool>? _releaseFuture;

  Future<bool> releaseOnce(Future<bool> Function() release) =>
      _releaseFuture ??= release();
}

final class _NativeConfirmedReplayProof
    implements CloudSyncConfirmedReplayProof {
  _NativeConfirmedReplayProof(this._operation, this._protectedLeaseReference);

  final CloudOutboxOperation _operation;
  final String _protectedLeaseReference;
  bool consumed = false;

  bool binds(CloudOutboxOperation operation) =>
      _operation.sameDurableSnapshotAs(operation) &&
      _protectedLeaseReference == operation.protectedLeaseReference;

  @override
  String toString() => 'CloudSyncConfirmedReplayProof(redacted)';
}

/// Default-off Cloud Sync V2 transport whose bridge surface contains
/// only keyed hashes and opaque protected-local references.
///
/// This class is intentionally absent from production runtime composition.
/// Periodic maintenance scheduling and cross-platform process-kill/endurance
/// testing remain rollout blockers.
final class NativeProtectedCloudSyncTransport
    implements
        CloudSyncTransport,
        CloudProtectedPageLeaseTransport,
        CloudSyncOutboundChatStagingTransport,
        CloudSyncOutboundAttachmentParentStagingTransport,
        CloudSyncWriteTransport,
        CloudSyncPreparedSubmissionReleaser,
        CloudSyncWriteReceiptFinalizer,
        CloudSyncConfirmedReceiptRetentionPolicy,
        CloudSyncNativeOperationQuiescence,
        CloudSyncMutationUncertaintyBoundary {
  NativeProtectedCloudSyncTransport({
    required this._cloudMessagesClient,
    required String storageDirectory,
    required String protectedStoreIdentity,
    BigInt? nativeWriterPauseToken,
    NativeProtectedCloudSyncBindings? bindings,
    this._writerMutationGuard,
    this._readCheckpointGeneration,
    this._refreshAuthentication,
    this._refreshPcsAccess,
    this._retainConfirmedReceiptsForReplay = false,
    this.readAttachmentParentContext,
    this.readAttachmentParentGroupProof,
  }) : _storageDirectory = storageDirectory,
       _protectedStoreIdentity = protectedStoreIdentity,
       _nativeWriterPauseToken = nativeWriterPauseToken,
       _bindings = bindings ?? FrbNativeProtectedCloudSyncBindings() {
    if (storageDirectory.isEmpty) {
      throw ArgumentError.value(storageDirectory, 'storageDirectory');
    }
    if (!_nativeStoreIdentityPattern.hasMatch(protectedStoreIdentity)) {
      throw ArgumentError('protected_store_identity_invalid');
    }
    if (nativeWriterPauseToken != null &&
        (nativeWriterPauseToken <= BigInt.zero ||
            nativeWriterPauseToken.bitLength > 64)) {
      throw ArgumentError('native_writer_pause_token_invalid');
    }
    if ((_writerMutationGuard == null) != (_readCheckpointGeneration == null)) {
      throw ArgumentError('cloud_sync_writer_generation_fence_invalid');
    }
  }

  final Object _cloudMessagesClient;
  final String _storageDirectory;
  final String _protectedStoreIdentity;
  final BigInt? _nativeWriterPauseToken;
  final NativeProtectedCloudSyncBindings _bindings;
  final CloudKitWriterMutationRunner? _writerMutationGuard;
  final Future<int> Function(CloudSyncScope scope)? _readCheckpointGeneration;
  final Future<bool> Function(CloudSyncScope scope)? _refreshAuthentication;
  final Future<bool> Function(CloudSyncScope scope)? _refreshPcsAccess;
  final bool _retainConfirmedReceiptsForReplay;

  /// Journal-owned lookup for the exact source receipt context of an
  /// attachment-parent message. Invoked only for messageManateeZone
  /// operations, only under the protected-store exclusion, and only with
  /// the exact submission scope. Null means non-parent: native inputs stay
  /// context-free and existing no-callback paths are unchanged.
  final CloudSyncAttachmentParentContextReader? readAttachmentParentContext;

  /// Journal-owned opener for the ephemeral group-parent proof. Per-pass
  /// authority: resolved on every prepare and every readback, never cached.
  /// Null means direct parent: native inputs stay proof-free.
  final CloudSyncAttachmentParentGroupProofReader?
  readAttachmentParentGroupProof;
  final Set<Future<void>> _activeNativeOperations = {};
  Future<void>? _nativeQuiescence;
  bool _nativeAdmissionClosed = false;
  bool _preparedReleaseFailed = false;
  bool _mutationAdmissionPoisoned = false;

  @override
  bool get retainConfirmedReceiptsForReplay =>
      _retainConfirmedReceiptsForReplay;

  @override
  String get protectedPageLeaseRecoveryIdentity => _protectedStoreIdentity;

  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) {
    _requireV2WriterInterlock();
    return runProtectedStoreExclusive(action);
  }

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      _runProtectedStoreOperation(action);

  Future<T> _runProtectedStoreOperation<T>(FutureOr<T> Function() operation) {
    if (_nativeAdmissionClosed &&
        !_protectedStoreOperationGate.isHeldByCurrentZone(
          _protectedStoreIdentity,
        )) {
      return Future<T>.error(
        _localStorage('protected_store_operation_admission_closed'),
      );
    }
    final nativeOperation = () async {
      try {
        return await _protectedStoreOperationGate.run(
          _protectedStoreIdentity,
          operation,
        );
      } on _NativeProtectedStoreOperationFailure catch (failure) {
        throw _localStorage(failure.safeCode);
      }
    }();
    late final Future<void> completion;
    completion = nativeOperation
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
          _activeNativeOperations.remove(completion);
        });
    _activeNativeOperations.add(completion);
    return nativeOperation;
  }

  @override
  Future<void> quiesceNativeOperations() async {
    _nativeAdmissionClosed = true;
    await (_nativeQuiescence ??= _waitForNativeQuiescence());
    // A settled future is not proof that its retained native owner was
    // released. Preserve cleanup failure even after quiescence was memoized.
    if (_preparedReleaseFailed) {
      throw _localStorage('cloud_sync_prepared_release_failed');
    }
  }

  @override
  void markActiveMutationUnknown() {
    _mutationAdmissionPoisoned = true;
    _writerMutationGuard?.markActiveMutationUnknown();
  }

  NativeProtectedCloudSyncWriteBindings _requireWriteBindings() {
    final bindings = _bindings;
    if (bindings is! NativeProtectedCloudSyncWriteBindings) {
      throw _readOnlyFailure();
    }
    return bindings as NativeProtectedCloudSyncWriteBindings;
  }

  NativeProtectedCloudSyncChatWriteBindings _requireChatWriteBindings() {
    final bindings = _bindings;
    if (bindings is! NativeProtectedCloudSyncChatWriteBindings) {
      throw _readOnlyFailure();
    }
    return bindings as NativeProtectedCloudSyncChatWriteBindings;
  }

  NativeProtectedCloudSyncAttachmentWriteBindings
  _requireAttachmentWriteBindings() {
    final bindings = _bindings;
    if (bindings is! NativeProtectedCloudSyncAttachmentWriteBindings) {
      throw _readOnlyFailure();
    }
    return bindings as NativeProtectedCloudSyncAttachmentWriteBindings;
  }

  NativeProtectedCloudSyncAttachmentParentWriteBindings
  _requireAttachmentParentWriteBindings() {
    final bindings = _bindings;
    if (bindings is! NativeProtectedCloudSyncAttachmentParentWriteBindings) {
      throw _readOnlyFailure();
    }
    return bindings as NativeProtectedCloudSyncAttachmentParentWriteBindings;
  }

  NativeProtectedPreparedReleaseBindings _requireReleaseBindings() {
    final bindings = _bindings;
    if (bindings is! NativeProtectedPreparedReleaseBindings) {
      throw _readOnlyFailure();
    }
    return bindings as NativeProtectedPreparedReleaseBindings;
  }

  /// Drops the native owner of a prepared-but-unconsumed submission.
  ///
  /// Foreign or non-native submissions fail closed. A null handle (the
  /// all-preconfirmed path allocated no owner) reports false with no
  /// native call. Every other submission invokes the idempotent native
  /// release exactly once per object (concurrent releases share the
  /// memoized future): native itself reports false for an already-taken
  /// consume owner. Taken-ness is never inferred from a returned consume
  /// result, because a failure result can leave the owner untaken. A
  /// failed release closes native admission, poisons the mutation fence,
  /// and throws a safe diagnostic: no new calls may proceed under a
  /// retained lock.
  @override
  Future<bool> releasePreparedSubmission(
    CloudSyncPreparedSubmission preparedSubmission,
  ) {
    // Exact-handle cleanup grants no mutation authority. It must remain
    // possible after the caller loses its interlock fence or admission closes.
    // The caller still joins native settlement before releasing this owner.
    if (preparedSubmission is! _NativeCloudSyncPreparedSubmission) {
      throw ArgumentError('cloud_sync_native_prepared_submission_required');
    }
    if (preparedSubmission.handle == null) {
      return Future<bool>.value(false);
    }
    return preparedSubmission.releaseOnce(
      () => _releasePreparedHandle(preparedSubmission.handle!),
    );
  }

  Future<bool> _releasePreparedHandle(
    frb_api.CloudSyncPreparedMessageCreateHandle handle,
  ) => _runPreparedReleaseOperation(
    () =>
        _requireReleaseBindings().releasePreparedMessageCreate(handle: handle),
  );

  /// Dedicated exact-handle cleanup under the protected-store gate.
  ///
  /// Unlike [_runProtectedStoreOperation] this stays available after
  /// admission close (quiesce), because timeout and cancellation cleanup
  /// must release abandoned owners. It is still serialized on the store
  /// identity gate and tracked in [_activeNativeOperations] so quiesce
  /// covers the cleanup itself. General operations must never use this;
  /// it does not reopen admission.
  Future<T> _runPreparedReleaseOperation<T>(FutureOr<T> Function() operation) {
    final cleanup = () async {
      try {
        return await _protectedStoreOperationGate.run(
          _protectedStoreIdentity,
          operation,
        );
      } catch (_) {
        // Publish the failure before the tracked future completes; quiescence
        // must not race a later continuation that discovers a retained owner.
        _preparedReleaseFailed = true;
        _nativeAdmissionClosed = true;
        markActiveMutationUnknown();
        throw _localStorage('cloud_sync_prepared_release_failed');
      }
    }();
    late final Future<void> completion;
    completion = cleanup
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
          _activeNativeOperations.remove(completion);
        });
    _activeNativeOperations.add(completion);
    return cleanup;
  }

  void _requireV2WriterInterlock() {
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
  }

  void _requireMutationAdmission() {
    _requireV2WriterInterlock();
    if (_mutationAdmissionPoisoned) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'cloud_sync_mutation_timeout_poisoned',
      );
    }
  }

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  }) async {
    _requireV2WriterInterlock();
    _validateOutboundMessageScope(scope);
    final result = await _runProtectedStoreOperation(
      () => _requireWriteBindings().stageOutboundMessage(
        cloudMessagesClient: _cloudMessagesClient,
        storageDirectory: _storageDirectory,
        expectedAccountFingerprint: scope.accountFingerprint,
        expectedProtectedStoreIdentity: _protectedStoreIdentity,
        message: message,
      ),
    );
    return _toMessageSizedOutboundStageData(result);
  }

  /// Stages one attachment-parent message envelope under the exact source
  /// receipt context supplied by the journal owner. The context is the
  /// authority: no body or GUID sniffing infers parenthood. Result
  /// validation is the existing message-size validation; plaintext and
  /// reaction behavior are unchanged.
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundAttachmentParent(
    CloudSyncScope scope, {
    required frb_api.CloudMessage messageHeaders,
    required frb_api.CloudSyncNativeSendReceiptContext context,
    frb_api.CloudSyncAttachmentParentGroupProof? groupProof,
  }) async {
    _requireV2WriterInterlock();
    _validateOutboundMessageScope(scope);
    _validateAttachmentParentContext(scope, context);
    final result = await _runProtectedStoreOperation(
      () =>
          _requireAttachmentParentWriteBindings().stageOutboundAttachmentParent(
            cloudMessagesClient: _cloudMessagesClient,
            storageDirectory: _storageDirectory,
            expectedAccountFingerprint: scope.accountFingerprint,
            expectedProtectedStoreIdentity: _protectedStoreIdentity,
            messageHeaders: messageHeaders,
            context: context,
            groupProof: groupProof,
          ),
    );
    return _toMessageSizedOutboundStageData(result);
  }

  /// Rejects a parent context that does not belong to this transport and
  /// scope before any native call. Pure field comparison: the journal owns
  /// admission, this gate only proves the context matches.
  void _validateAttachmentParentContext(
    CloudSyncScope scope,
    frb_api.CloudSyncNativeSendReceiptContext context,
  ) {
    if (context.storageDirectory != _storageDirectory ||
        context.accountFingerprint != scope.accountFingerprint ||
        context.protectedStoreIdentity != _protectedStoreIdentity) {
      throw _localStorage('cloud_sync_outbound_parent_context_invalid');
    }
  }

  CloudSyncProtectedOutboundStageData _toMessageSizedOutboundStageData(
    frb_api.CloudSyncProtectedOutboundStageResult result,
  ) {
    if ((result.stage == null) == (result.failure == null)) {
      throw _localStorage('cloud_sync_outbound_stage_envelope_invalid');
    }
    if (result.failure case final failure?) {
      throw _mapOutboundFailure(failure);
    }
    final stage = result.stage!;
    if (!_nativeDigestPattern.hasMatch(stage.logicalEntityKeyHash) ||
        !_protectedReferencePattern.hasMatch(stage.protectedPayloadReference) ||
        stage.protectedPayloadReference !=
            stage.protectedServerRecordReference ||
        !_contentDigestPattern.hasMatch(stage.payloadSha256) ||
        !_nativeDigestPattern.hasMatch(stage.serverRecordIdHash) ||
        !_leaseReferencePattern.hasMatch(stage.leaseReference) ||
        stage.payloadLength <= BigInt.zero ||
        stage.payloadLength > BigInt.from(_maximumAdmittedRawPageBytes)) {
      throw _localStorage('cloud_sync_outbound_stage_invalid');
    }
    return CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: stage.logicalEntityKeyHash,
      protectedEnvelopeReference: stage.protectedPayloadReference,
      payloadSha256: stage.payloadSha256,
      serverRecordIdHash: stage.serverRecordIdHash,
      leaseReference: stage.leaseReference,
    );
  }

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundChat(
    CloudSyncScope scope, {
    required frb_api.CloudChat chat,
  }) async {
    _requireV2WriterInterlock();
    _validateOutboundChatScope(scope);
    final result = await _runProtectedStoreOperation(
      () => _requireChatWriteBindings().stageOutboundChat(
        cloudMessagesClient: _cloudMessagesClient,
        storageDirectory: _storageDirectory,
        expectedAccountFingerprint: scope.accountFingerprint,
        expectedProtectedStoreIdentity: _protectedStoreIdentity,
        chat: chat,
      ),
    );
    if ((result.stage == null) == (result.failure == null)) {
      throw _localStorage('cloud_sync_outbound_stage_envelope_invalid');
    }
    if (result.failure case final failure?) {
      throw _mapOutboundFailure(failure);
    }
    final stage = result.stage!;
    if (!_nativeDigestPattern.hasMatch(stage.logicalEntityKeyHash) ||
        !_protectedReferencePattern.hasMatch(stage.protectedPayloadReference) ||
        stage.protectedPayloadReference !=
            stage.protectedServerRecordReference ||
        !_contentDigestPattern.hasMatch(stage.payloadSha256) ||
        !_nativeDigestPattern.hasMatch(stage.serverRecordIdHash) ||
        !_leaseReferencePattern.hasMatch(stage.leaseReference) ||
        stage.payloadLength <= BigInt.zero ||
        stage.payloadLength > BigInt.from(256 * 1024)) {
      throw _localStorage('cloud_sync_outbound_stage_invalid');
    }
    return CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: stage.logicalEntityKeyHash,
      protectedEnvelopeReference: stage.protectedPayloadReference,
      payloadSha256: stage.payloadSha256,
      serverRecordIdHash: stage.serverRecordIdHash,
      leaseReference: stage.leaseReference,
    );
  }

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) {
    _requireV2WriterInterlock();
    return commitProtectedPageLease(leaseReference, {
      protectedEnvelopeReference,
    });
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) {
    _requireV2WriterInterlock();
    return rollbackProtectedPageLease(leaseReference);
  }

  @override
  Future<CloudSyncPreparedSubmission> prepareSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required List<CloudSyncProtectedWriteOperation> operations,
  }) async {
    _requireV2WriterInterlock();
    final payloadVersion = _outboundCreatePayloadVersion(scope);
    final isChat = scope.zone == 'chatManateeZone';
    final isAttachment = scope.zone == 'attachmentManateeZone';
    if (operations.isEmpty ||
        operations.length > _maximumChangesPerPage ||
        ((isChat || isAttachment) && operations.length != 1) ||
        operations.any(
          (operation) =>
              operation.action != CloudOutboxAction.save ||
              !_isInitialCreateOperationIdentity(
                scope,
                operationId: operation.operationId,
                logicalEntityKeyHash: operation.logicalEntityKeyHash,
                payloadVersion: payloadVersion,
              ) ||
              operation.protectedPayloadReference == null ||
              operation.payloadSha256 == null ||
              operation.protectedPayloadReference !=
                  operation.protectedServerRecordIdReference,
        )) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'cloud_sync_outbound_create_only',
      );
    }
    submissionIdentity.validateOperationIds(
      operations.map((operation) => operation.operationId),
    );
    final bindings = _requireWriteBindings();
    final reconcile = isChat
        ? _requireChatWriteBindings().reconcileChatCreate
        : isAttachment
        ? _requireAttachmentWriteBindings().reconcileAttachmentCreate
        : bindings.reconcileMessageCreate;
    final prepare = isChat
        ? _requireChatWriteBindings().prepareChatCreate
        : isAttachment
        ? _requireAttachmentWriteBindings().prepareAttachmentCreate
        : bindings.prepareMessageCreate;
    return _runProtectedStoreOperation(() async {
      // Parent contexts resolve here, under the protected-store exclusion,
      // so the journal read and the native reconcile/prepare pair share one
      // admission window. Only messageManateeZone operations consult the
      // callback; Chat and Attachment inputs never carry a parent context.
      // Without a callback every input builds exactly as before.
      // Parent attachment authority resolves here, under the protected-store
      // exclusion and before any native writer permit is acquired. The sync
      // context is captured first; the async group-proof opener runs only
      // when a context exists, and the context is reread after the await
      // with an exact-equality demand, so a journal ownership change across
      // the await fails closed instead of pairing a proof with a new source.
      final inputs = <frb_api.CloudSyncPreparedMessageCreateInput>[];
      for (final operation in operations) {
        final parentContext = _readParentContextForPrepare(
          scope,
          operation.operationId,
        );
        inputs.add(
          _preparedCreateInput(
            operation,
            submissionIdentity: submissionIdentity,
            attachmentParentContext: parentContext,
            attachmentParentGroupProof: await _readParentGroupProofForPrepare(
              scope,
              operation.operationId,
              parentContext,
            ),
          ),
        );
      }
      final remoteInputs = <frb_api.CloudSyncPreparedMessageCreateInput>[];
      final preconfirmedReceipts = <CloudOutboxCreateReceipt>[];
      for (final input in inputs) {
        final lookup = await reconcile(
          cloudMessagesClient: _cloudMessagesClient,
          storageDirectory: _storageDirectory,
          expectedAccountFingerprint: scope.accountFingerprint,
          expectedProtectedStoreIdentity: _protectedStoreIdentity,
          requestUuid: submissionIdentity.requestUuid,
          input: input,
        );
        switch (_classifyCreatePreflight(
          lookup,
          expectedProtectedProofReference: input.protectedPayloadReference,
        )) {
          case _CreatePreflightDisposition.absent:
            remoteInputs.add(input);
          case _CreatePreflightDisposition.alreadyPresent:
            preconfirmedReceipts.add(
              _createReceiptFromPreflight(result: lookup, input: input),
            );
        }
      }
      final result = remoteInputs.isEmpty
          ? null
          : await prepare(
              cloudMessagesClient: _cloudMessagesClient,
              storageDirectory: _storageDirectory,
              expectedAccountFingerprint: scope.accountFingerprint,
              expectedProtectedStoreIdentity: _protectedStoreIdentity,
              requestUuid: submissionIdentity.requestUuid,
              requestTimeout: const Duration(seconds: 45),
              inputs: remoteInputs,
            );
      if (_nativeAdmissionClosed) {
        // Admission closed while this preparation was in flight (engine
        // timeout/cancellation followed by quiescence, or a prior release
        // failure). The caller has abandoned or cannot use this
        // preparation: drop any allocated owner inside this same tracked
        // operation so quiescence covers the cleanup, then fail closed.
        // A late handle is never handed out for nobody to consume.
        final abandonedHandle = result?.handle;
        if (abandonedHandle != null) {
          await _releasePreparedHandle(abandonedHandle);
        }
        throw _localStorage('protected_store_operation_admission_closed');
      }
      if (result != null &&
          ((result.handle == null) == (result.failure == null) ||
              (result.handleBindingSha256 == null) != (result.handle == null) ||
              (result.handleBindingSha256 != null &&
                  !_contentDigestPattern.hasMatch(
                    result.handleBindingSha256!,
                  )))) {
        // Validation and construction share the tracked preparation boundary:
        // no rejected handle may outlive quiescence or depend on engine cleanup.
        final abandonedHandle = result.handle;
        if (abandonedHandle != null) {
          await _releasePreparedHandle(abandonedHandle);
        }
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'cloud_sync_outbound_prepare_envelope_invalid',
        );
      }
      if (result?.failure case final failure?) {
        throw _mapOutboundFailure(failure);
      }
      try {
        return _NativeCloudSyncPreparedSubmission(
          scope: scope,
          identity: submissionIdentity,
          operations: operations,
          handle: result?.handle,
          handleBindingSha256: result?.handleBindingSha256,
          remoteOperationIds: remoteInputs.map(
            (input) => input.localOperationId,
          ),
          preconfirmedReceipts: preconfirmedReceipts,
        );
      } catch (_) {
        final abandonedHandle = result?.handle;
        if (abandonedHandle != null) {
          await _releasePreparedHandle(abandonedHandle);
        }
        rethrow;
      }
    });
  }

  @override
  Future<CloudPushBatchResult> consumePreparedSubmission(
    CloudSyncScope scope, {
    required CloudSyncPreparedSubmission preparedSubmission,
    required CloudOutboxSubmissionIdentity persistedIdentity,
    required List<CloudSyncProtectedWriteOperation> protectedOperations,
    required List<CloudOutboxOperation> operations,
  }) async {
    _requireV2WriterInterlock();
    _outboundCreatePayloadVersion(scope);
    if (preparedSubmission is! _NativeCloudSyncPreparedSubmission) {
      throw ArgumentError('cloud_sync_native_prepared_submission_required');
    }
    if (scope.zone == 'chatManateeZone') {
      _requireChatWriteBindings();
      if (preparedSubmission.operationCount != 1) {
        throw _localStorage('cloud_sync_outbound_create_only');
      }
    }
    if (scope.zone == 'attachmentManateeZone') {
      _requireAttachmentWriteBindings();
      if (preparedSubmission.operationCount != 1) {
        throw _localStorage('cloud_sync_outbound_create_only');
      }
    }
    final outcomes = <CloudPushOutcome>[
      for (final receipt in preparedSubmission.preconfirmedReceipts)
        CloudPushOutcome(
          operationId: receipt.operationId,
          disposition: CloudPushDisposition.confirmed,
          createReceipt: receipt,
        ),
    ];
    final expectedRemote = preparedSubmission.remoteOperationIds.toSet();
    final handle = preparedSubmission.handle;
    if (handle == null) {
      preparedSubmission.claimForConsumption(
        scope,
        persistedIdentity: persistedIdentity,
        protectedOperations: protectedOperations,
      );
    } else {
      final mutationGuard = _writerMutationGuard;
      if (mutationGuard == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.authorization,
          safeCode: 'cloud_sync_writer_mutation_guard_required',
        );
      }
      final remoteOperations = operations
          .where((operation) => expectedRemote.contains(operation.operationId))
          .toList(growable: false);
      if (remoteOperations.length != 1 || expectedRemote.length != 1) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.authorization,
          safeCode: 'cloud_sync_outbound_reconciliation_batch_unsupported',
        );
      }
      final reconciliationBindingSha256 =
          cloudKitWriterReconciliationBindingSha256(
            remoteOperations.single,
            appleRequestUuid: persistedIdentity.requestUuid,
            appleOperationUuid: persistedIdentity
                .operationUuids[remoteOperations.single.operationId],
          );
      final bindings = _requireWriteBindings();
      final readCheckpointGeneration = _readCheckpointGeneration;
      if (readCheckpointGeneration == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.authorization,
          safeCode: 'cloud_sync_writer_generation_fence_required',
        );
      }
      final remoteOutcomes = await _runProtectedStoreOperation(() async {
        // The queue may have waited long enough for the cross-process lease to
        // be lost. Recheck it at the final admission point, before claiming
        // the single-use submission or arming any mutation state.
        _requireMutationAdmission();
        mutationGuard.requireClear();
        CloudFailureCategory? ambiguousFailureCategory;
        Duration? ambiguousRetryAfter;
        try {
          return await mutationGuard.runAuthorized(
            owner: CloudKitWriterOwner.v2,
            expectedClient: _cloudMessagesClient,
            expectedAccountFingerprint: scope.accountFingerprint,
            preparedHandleBindingSha256: preparedSubmission.handleBindingSha256,
            reconciliationBindingSha256: reconciliationBindingSha256,
            requireAdmission: _requireMutationAdmission,
            requireDurableAdmission: () async {
              _requireMutationAdmission();
              final currentGeneration = await readCheckpointGeneration(scope);
              _requireMutationAdmission();
              if (currentGeneration <= 0 ||
                  remoteOperations.any(
                    (operation) =>
                        operation.checkpointGeneration != currentGeneration,
                  )) {
                throw CloudSyncFailure(
                  category: CloudFailureCategory.cancelled,
                  safeCode: 'cloud_sync_outbound_stale_checkpoint_generation',
                );
              }
              // A bad UUID, changed binding, or repeated local claim has not
              // sent anything. Reject it before the guard arms its durable
              // ambiguity fence, while preserving the generation recheck.
              preparedSubmission.claimForConsumption(
                scope,
                persistedIdentity: persistedIdentity,
                protectedOperations: protectedOperations,
              );
            },
            action: (capability) async {
              _requireV2WriterInterlock();
              final result = await bindings.consumePreparedMessageCreate(
                handle: handle,
                mutationCapabilityToken: capability.consumeForNative(),
              );
              _requireV2WriterInterlock();
              if (result.failure case final failure?) {
                throw _mapOutboundFailure(failure);
              }
              if (result.outcomes.length != expectedRemote.length) {
                throw CloudSyncFailure(
                  category: CloudFailureCategory.unknown,
                  safeCode: 'cloud_sync_outbound_correlation_mismatch',
                );
              }
              final seenRemote = <String>{};
              final mapped = <CloudPushOutcome>[];
              for (final outcome in result.outcomes) {
                if (!expectedRemote.contains(outcome.localOperationId) ||
                    !seenRemote.add(outcome.localOperationId) ||
                    persistedIdentity.operationUuids[outcome
                            .localOperationId] !=
                        outcome.appleOperationUuid) {
                  throw CloudSyncFailure(
                    category: CloudFailureCategory.unknown,
                    safeCode: 'cloud_sync_outbound_correlation_mismatch',
                  );
                }
                final mappedOutcome = _mapOutboundOutcome(
                  outcome,
                  remoteOperations.single,
                );
                mapped.add(mappedOutcome);
              }
              if (mapped.any(
                (outcome) =>
                    outcome.disposition != CloudPushDisposition.confirmed,
              )) {
                // Once the native capability was consumed, a classified
                // non-success is not proof that CloudKit rejected the save.
                // Preserve only its diagnostic category and retry hint; the
                // durable operation must remain outcome-unknown with the exact
                // Apple UUIDs and protected receipt intact until readback.
                final diagnostic = mapped.single;
                ambiguousFailureCategory = diagnostic.failureCategory;
                ambiguousRetryAfter = diagnostic.retryAfter;
                throw CloudSyncFailure(
                  category: CloudFailureCategory.unknown,
                  safeCode:
                      'cloud_sync_outbound_mutation_reconciliation_required',
                );
              }
              return mapped;
            },
          );
        } on CloudKitWriterAuthorityFailure catch (error) {
          if (!_isAmbiguousMutationGuardFailure(error.safeCode)) rethrow;
          return <CloudPushOutcome>[
            for (final operationId in expectedRemote)
              CloudPushOutcome(
                operationId: operationId,
                disposition: CloudPushDisposition.unknownOutcome,
                failureCategory:
                    ambiguousFailureCategory ?? CloudFailureCategory.unknown,
                retryAfter: ambiguousRetryAfter,
              ),
          ];
        }
      });
      outcomes.addAll(remoteOutcomes);
    }
    final expectedAll = operations
        .map((operation) => operation.operationId)
        .toSet();
    final actualAll = outcomes.map((outcome) => outcome.operationId).toSet();
    if (expectedAll.length != operations.length ||
        actualAll.length != outcomes.length ||
        actualAll.length != expectedAll.length ||
        !actualAll.containsAll(expectedAll)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'cloud_sync_outbound_correlation_mismatch',
      );
    }
    return CloudPushBatchResult(outcomes: outcomes);
  }

  bool _isAmbiguousMutationGuardFailure(String safeCode) =>
      safeCode == 'cloudkit_writer_mutation_outcome_unknown' ||
      safeCode == 'cloudkit_writer_mutation_fence_release_failed' ||
      safeCode == 'cloudkit_writer_mutation_authority_fence_failed';

  frb_api.CloudSyncPreparedMessageCreateInput _preparedCreateInput(
    CloudSyncProtectedWriteOperation operation, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    frb_api.CloudSyncNativeSendReceiptContext? attachmentParentContext,
    frb_api.CloudSyncAttachmentParentGroupProof? attachmentParentGroupProof,
  }) => frb_api.CloudSyncPreparedMessageCreateInput(
    localOperationId: operation.operationId,
    logicalEntityKeyHash: operation.logicalEntityKeyHash,
    protectedLeaseReference: operation.protectedLeaseReference!,
    protectedPayloadReference: operation.protectedPayloadReference!,
    payloadSha256: operation.payloadSha256!,
    protectedServerRecordReference: operation.protectedServerRecordIdReference,
    serverRecordIdHash: operation.serverRecordIdHash,
    appleOperationUuid:
        submissionIdentity.operationUuids[operation.operationId]!,
    attachmentParentContext: attachmentParentContext,
    attachmentParentGroupProof: attachmentParentGroupProof,
  );

  /// Journal-owned parent context for one message-zone prepare/reconcile
  /// input. Executes only under the protected-store exclusion (all callers
  /// run inside [_runProtectedStoreOperation]) and only for
  /// messageManateeZone; Chat and Attachment zones never invoke the
  /// callback and never leak a context into their native inputs. A null
  /// journal answer means non-parent and preserves the context-free input.
  /// A mismatched context fails closed before any native call; a missing
  /// context for a true parent is rejected natively downstream.
  frb_api.CloudSyncNativeSendReceiptContext? _readParentContextForPrepare(
    CloudSyncScope scope,
    String operationId,
  ) {
    final reader = readAttachmentParentContext;
    if (scope.zone != 'messageManateeZone' || reader == null) {
      return null;
    }
    final context = reader(scope, operationId);
    if (context == null) {
      return null;
    }
    _validateAttachmentParentContext(scope, context);
    return context;
  }

  /// Opens the ephemeral group-parent proof for one message-zone operation.
  /// The sync [contextBefore] must already be captured; a null context
  /// means direct parent and the opener is never consulted, so a proof can
  /// never ride without its source context. After the await the sync
  /// context is reread and must compare exactly equal: a journal ownership
  /// or auth change across the await fails closed before any native call.
  /// The proof itself is opaque and never cached; every prepare and every
  /// readback reopens it through the journal.
  Future<frb_api.CloudSyncAttachmentParentGroupProof?>
  _readParentGroupProofForPrepare(
    CloudSyncScope scope,
    String operationId,
    frb_api.CloudSyncNativeSendReceiptContext? contextBefore,
  ) async {
    final reader = readAttachmentParentGroupProof;
    if (scope.zone != 'messageManateeZone' ||
        reader == null ||
        contextBefore == null) {
      return null;
    }
    final proof = await reader(scope, operationId);
    if (proof == null) {
      return null;
    }
    final contextAfter = _readParentContextForPrepare(scope, operationId);
    if (contextAfter != contextBefore) {
      throw _localStorage('cloud_sync_outbound_parent_context_changed');
    }
    return proof;
  }

  _CreatePreflightDisposition _classifyCreatePreflight(
    frb_api.CloudSyncOutboundReconcileResult result, {
    required String expectedProtectedProofReference,
  }) {
    final disposition = _requireOutboundReconcileDisposition(
      result,
      expectedProtectedProofReference: expectedProtectedProofReference,
      invalidEnvelopeCode:
          'cloud_sync_outbound_create_preflight_envelope_invalid',
    );
    return switch (disposition) {
      frb_api.CloudSyncOutboundReconcileDisposition.notApplied =>
        _CreatePreflightDisposition.absent,
      frb_api.CloudSyncOutboundReconcileDisposition.committed =>
        _CreatePreflightDisposition.alreadyPresent,
      frb_api.CloudSyncOutboundReconcileDisposition.diverged =>
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'cloud_sync_outbound_create_preflight_conflict',
        ),
      frb_api.CloudSyncOutboundReconcileDisposition.unresolved =>
        throw _unresolvedCreatePreflightFailure(result),
    };
  }

  /// Maps an unresolved create preflight to a fail-closed [CloudSyncFailure].
  ///
  /// A reset-required zone needs rebootstrap, never credential or PCS
  /// refresh: its safe code is preserved while the category stays
  /// non-retryable, so the engine fences it paused under unknown instead of
  /// pausing for recovery or resuming it after a refresh.
  CloudSyncFailure _unresolvedCreatePreflightFailure(
    frb_api.CloudSyncOutboundReconcileResult result,
  ) {
    if (result.failureClass ==
        frb_api.CloudSyncOutboundFailureClass.resetRequired) {
      return CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        retryAfter: _boundedRetryAfter(result.retryAfterSeconds),
        safeCode:
            CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitResetRequired,
      );
    }
    return CloudSyncFailure(
      category: switch (_mapOutboundFailureClass(result.failureClass)) {
        CloudFailureCategory.authorization =>
          CloudFailureCategory.authorization,
        CloudFailureCategory.pcsUnavailable =>
          CloudFailureCategory.pcsUnavailable,
        CloudFailureCategory.throttled => CloudFailureCategory.throttled,
        CloudFailureCategory.server => CloudFailureCategory.server,
        _ => CloudFailureCategory.unknown,
      },
      retryAfter: _boundedRetryAfter(result.retryAfterSeconds),
      safeCode: 'cloud_sync_outbound_create_preflight_unresolved',
    );
  }

  CloudOutboxCreateReceipt _createReceiptFromPreflight({
    required frb_api.CloudSyncOutboundReconcileResult result,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) {
    final serverRecordIdHash = result.serverRecordIdHash;
    final etagHash = result.etagHash;
    if (serverRecordIdHash == null ||
        etagHash == null ||
        !_nativeDigestPattern.hasMatch(input.logicalEntityKeyHash) ||
        !_nativeDigestPattern.hasMatch(serverRecordIdHash) ||
        !_nativeDigestPattern.hasMatch(etagHash)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'cloud_sync_outbound_create_preflight_receipt_invalid',
      );
    }
    if (serverRecordIdHash != input.serverRecordIdHash) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'cloud_sync_outbound_create_preflight_receipt_mismatch',
      );
    }
    return CloudOutboxCreateReceipt(
      operationId: input.localOperationId,
      logicalEntityKeyHash: input.logicalEntityKeyHash,
      serverRecordIdHash: serverRecordIdHash,
      etagHash: etagHash,
    );
  }

  frb_api.CloudSyncOutboundReconcileDisposition
  _requireOutboundReconcileDisposition(
    frb_api.CloudSyncOutboundReconcileResult result, {
    required String expectedProtectedProofReference,
    required String invalidEnvelopeCode,
  }) {
    if (result.failure case final failure?) {
      if (result.disposition != null ||
          result.protectedProofReference != null ||
          result.failureClass != null ||
          result.retryAfterSeconds != null ||
          result.serverRecordIdHash != null ||
          result.etagHash != null) {
        throw _localStorage(invalidEnvelopeCode);
      }
      throw _mapOutboundFailure(failure);
    }
    final disposition = result.disposition;
    if (disposition == null) {
      throw _localStorage(invalidEnvelopeCode);
    }
    final decisive =
        disposition != frb_api.CloudSyncOutboundReconcileDisposition.unresolved;
    final hasReceiptField =
        result.serverRecordIdHash != null || result.etagHash != null;
    if ((decisive &&
            result.protectedProofReference !=
                expectedProtectedProofReference) ||
        (!decisive && result.protectedProofReference != null) ||
        (disposition !=
                frb_api.CloudSyncOutboundReconcileDisposition.committed &&
            hasReceiptField) ||
        (disposition !=
                frb_api.CloudSyncOutboundReconcileDisposition.unresolved &&
            result.retryAfterSeconds != null) ||
        ((disposition ==
                    frb_api.CloudSyncOutboundReconcileDisposition.committed ||
                disposition ==
                    frb_api.CloudSyncOutboundReconcileDisposition.notApplied) &&
            result.failureClass != null) ||
        (disposition ==
                frb_api.CloudSyncOutboundReconcileDisposition.diverged &&
            result.failureClass !=
                frb_api.CloudSyncOutboundFailureClass.conflict)) {
      throw _localStorage(invalidEnvelopeCode);
    }
    return disposition;
  }

  CloudSyncFailure _mapOutboundFailure(
    frb_api.CloudSyncOutboundSafeCode failure,
  ) {
    final category = switch (failure) {
      frb_api.CloudSyncOutboundSafeCode.invalidScope ||
      frb_api.CloudSyncOutboundSafeCode.nativeAuthUnavailable =>
        CloudFailureCategory.authorization,
      frb_api.CloudSyncOutboundSafeCode.protectedStorage =>
        CloudFailureCategory.localStorage,
      frb_api.CloudSyncOutboundSafeCode.nativePrepareFailed =>
        CloudFailureCategory.server,
      frb_api.CloudSyncOutboundSafeCode.alreadyConsumed ||
      frb_api.CloudSyncOutboundSafeCode.correlationMismatch ||
      frb_api.CloudSyncOutboundSafeCode.mutationCapabilityInvalid =>
        CloudFailureCategory.unknown,
      _ => CloudFailureCategory.cancelled,
    };
    return CloudSyncFailure(
      category: category,
      safeCode:
          'cloud_sync_outbound_${switch (failure) {
            frb_api.CloudSyncOutboundSafeCode.invalidScope => 'invalid_scope',
            frb_api.CloudSyncOutboundSafeCode.invalidRequest => 'invalid_request',
            frb_api.CloudSyncOutboundSafeCode.unsupportedMessage => 'unsupported_message',
            frb_api.CloudSyncOutboundSafeCode.malformedMessage => 'malformed_message',
            frb_api.CloudSyncOutboundSafeCode.oversizedMessage => 'oversized_message',
            frb_api.CloudSyncOutboundSafeCode.protectedStorage => 'protected_storage',
            frb_api.CloudSyncOutboundSafeCode.bindingMismatch => 'binding_mismatch',
            frb_api.CloudSyncOutboundSafeCode.nativeAuthUnavailable => 'native_auth_unavailable',
            frb_api.CloudSyncOutboundSafeCode.nativePrepareFailed => 'native_prepare_failed',
            frb_api.CloudSyncOutboundSafeCode.alreadyConsumed => 'already_consumed',
            frb_api.CloudSyncOutboundSafeCode.correlationMismatch => 'correlation_mismatch',
            frb_api.CloudSyncOutboundSafeCode.mutationCapabilityInvalid => 'mutation_capability_invalid',
          }}',
    );
  }

  CloudPushOutcome _mapOutboundOutcome(
    frb_api.CloudSyncOutboundSaveOutcome outcome,
    CloudOutboxOperation expectedOperation,
  ) {
    final retryAfter = _boundedRetryAfter(outcome.retryAfterSeconds);
    return switch (outcome.disposition) {
      frb_api.CloudSyncOutboundSaveDisposition.succeeded =>
        _mapConfirmedOutboundOutcome(outcome, expectedOperation, retryAfter),
      frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome =>
        CloudPushOutcome(
          operationId: outcome.localOperationId,
          disposition: CloudPushDisposition.unknownOutcome,
          failureCategory: CloudFailureCategory.unknown,
          retryAfter: retryAfter,
        ),
      frb_api.CloudSyncOutboundSaveDisposition.failed =>
        _mapProvenFailedOutboundOutcome(outcome, retryAfter),
    };
  }

  Duration? _boundedRetryAfter(BigInt? seconds) {
    if (seconds == null) return null;
    if (seconds < BigInt.zero) {
      throw _localStorage('cloud_sync_outbound_retry_after_invalid');
    }
    final maximum = BigInt.from(_maximumRetryAfterSeconds);
    final bounded = seconds > maximum ? maximum : seconds;
    return Duration(seconds: bounded.toInt());
  }

  /// Accepts a native success only with a bound create receipt.
  ///
  /// The native save must echo both opaque digests and the server digest must
  /// exactly match the expected operation. Anything else is not proof of a
  /// commit: the consumed mutation stays reconciliation-only so the exact
  /// readback path must still prove the remote state.
  CloudPushOutcome _mapConfirmedOutboundOutcome(
    frb_api.CloudSyncOutboundSaveOutcome outcome,
    CloudOutboxOperation expectedOperation,
    Duration? retryAfter,
  ) {
    final serverRecordIdHash = outcome.serverRecordIdHash;
    final etagHash = outcome.etagHash;
    if (serverRecordIdHash == null ||
        etagHash == null ||
        expectedOperation.serverRecordIdHash == null ||
        !_nativeDigestPattern.hasMatch(serverRecordIdHash) ||
        !_nativeDigestPattern.hasMatch(etagHash) ||
        !_nativeDigestPattern.hasMatch(
          expectedOperation.logicalEntityKeyHash,
        ) ||
        serverRecordIdHash != expectedOperation.serverRecordIdHash) {
      return CloudPushOutcome(
        operationId: outcome.localOperationId,
        disposition: CloudPushDisposition.unknownOutcome,
        failureCategory: CloudFailureCategory.unknown,
        retryAfter: retryAfter,
      );
    }
    return CloudPushOutcome(
      operationId: outcome.localOperationId,
      disposition: CloudPushDisposition.confirmed,
      createReceipt: CloudOutboxCreateReceipt(
        operationId: outcome.localOperationId,
        logicalEntityKeyHash: expectedOperation.logicalEntityKeyHash,
        serverRecordIdHash: serverRecordIdHash,
        etagHash: etagHash,
      ),
    );
  }

  CloudPushOutcome _mapProvenFailedOutboundOutcome(
    frb_api.CloudSyncOutboundSaveOutcome outcome,
    Duration? retryAfter,
  ) {
    final operationId = outcome.localOperationId;
    return switch (outcome.failureClass) {
      frb_api.CloudSyncOutboundFailureClass.throttled => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.retryable,
        failureCategory: CloudFailureCategory.throttled,
        retryAfter: retryAfter,
      ),
      frb_api.CloudSyncOutboundFailureClass.transientServer => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.retryable,
        failureCategory: CloudFailureCategory.server,
        retryAfter: retryAfter,
      ),
      frb_api.CloudSyncOutboundFailureClass.authentication => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.unauthorized,
        failureCategory: CloudFailureCategory.authorization,
      ),
      frb_api.CloudSyncOutboundFailureClass.conflict => CloudPushOutcome(
        operationId: operationId,
        // This transport supports only first-create semantics. A record that
        // appeared after the exact absence lookup is a create race, not an
        // update/merge invitation. Persist it as outcome-unknown so the exact
        // create reconciler can prove identical, divergent, or unresolved on
        // the next run. Never route it through update-conflict merge logic.
        disposition: CloudPushDisposition.unknownOutcome,
        failureCategory: CloudFailureCategory.unknown,
      ),
      frb_api.CloudSyncOutboundFailureClass.resetRequired => CloudPushOutcome(
        operationId: operationId,
        // Fail closed: a reset-required zone needs rebootstrap, never
        // credential or PCS refresh. Unknown keeps the operation out of the
        // paused-for-recovery set; the reset identity is preserved on the
        // preflight throw matched by cloudSyncIsResetRequiredSafeCode.
        disposition: CloudPushDisposition.unknownOutcome,
        failureCategory: CloudFailureCategory.unknown,
      ),
      _ => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.unknownOutcome,
        failureCategory: CloudFailureCategory.unknown,
      ),
    };
  }

  @override
  Future<void> acknowledgeDurableTerminalOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
    required List<CloudOutboxTransition> transitions,
  }) async {
    _requireV2WriterInterlock();
    final operationsById = <String, CloudOutboxOperation>{};
    for (final operation in operations) {
      if (operation.scope != scope ||
          operationsById.containsKey(operation.operationId)) {
        throw _localStorage('cloud_sync_outbound_receipt_scope_invalid');
      }
      operationsById[operation.operationId] = operation;
    }
    final seenTransitionIds = <String>{};
    for (final transition in transitions) {
      if (!seenTransitionIds.add(transition.operationId) ||
          !operationsById.containsKey(transition.operationId)) {
        throw _localStorage('cloud_sync_outbound_receipt_transition_invalid');
      }
    }
    final terminalIds = transitions
        .where((transition) {
          if (transition.type == CloudOutboxTransitionType.confirmed) {
            return !_retainConfirmedReceiptsForReplay;
          }
          return transition.type == CloudOutboxTransitionType.quarantined;
        })
        .map((transition) => transition.operationId)
        .toSet();
    final leases = operations
        .where((operation) => terminalIds.contains(operation.operationId))
        .map((operation) => operation.protectedLeaseReference)
        .whereType<String>()
        .toSet();
    for (final lease in leases) {
      _validateLeaseReference(lease);
      final result = await _runProtectedStoreOperation(
        () => _bindings.acknowledgeCommittedPageLease(
          storageDirectory: _storageDirectory,
          leaseReference: lease,
        ),
      );
      if (result.failure != null) {
        throw _mapFailure(result.failure!);
      }
    }
  }

  Future<void> _waitForNativeQuiescence() async {
    while (_activeNativeOperations.isNotEmpty) {
      await Future.wait<void>(_activeNativeOperations.toList(growable: false));
    }
  }

  @override
  Future<CloudFetchBatch> fetchChanges(
    CloudSyncScope scope, {
    required String? previousToken,
    required int generation,
    required int limit,
  }) async {
    final stream = _validateScopeAndStream(scope);
    final pauseToken = _nativeWriterPauseToken;
    if (pauseToken == null) {
      if (scope.persistenceLane != CloudSyncPersistenceLane.shadow) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.cancelled,
          safeCode: 'cloud_sync_native_writer_pause_capability_required',
        );
      }
    } else {
      if (scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.cancelled,
          safeCode: 'unsupported_semantic_persistence_lane',
        );
      }
      if (!_semanticProtectedStreams.contains(stream)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.cancelled,
          safeCode: 'unsupported_semantic_cloud_zone',
        );
      }
    }
    if (generation <= 0) {
      throw _malformed('invalid_generation');
    }
    if (previousToken != null &&
        !_protectedReferencePattern.hasMatch(previousToken)) {
      throw _localStorage('invalid_checkpoint_reference');
    }
    if (limit <= 0) {
      throw _malformed('invalid_fetch_limit');
    }
    final maximumChanges = limit.clamp(1, _maximumChangesPerPage);
    final result = await _runProtectedStoreOperation(() {
      if (pauseToken != null) {
        return _bindings.fetchProtectedPageUnderWriterPause(
          cloudMessagesClient: _cloudMessagesClient,
          nativeWriterPauseToken: pauseToken,
          storageDirectory: _storageDirectory,
          expectedAccountFingerprint: scope.accountFingerprint,
          stream: stream,
          generation: generation,
          previousCheckpointReference: previousToken,
          maximumChanges: maximumChanges,
        );
      }
      return _bindings.fetchProtectedPage(
        cloudMessagesClient: _cloudMessagesClient,
        storageDirectory: _storageDirectory,
        expectedAccountFingerprint: scope.accountFingerprint,
        stream: stream,
        generation: generation,
        previousCheckpointReference: previousToken,
        maximumChanges: maximumChanges,
      );
    });
    final page = result.page;
    final failure = result.failure;
    if ((page == null) == (failure == null)) {
      throw _malformed('invalid_protected_fetch_envelope');
    }
    if (failure != null) {
      final mapped = _mapFailure(
        failure,
        resetScope: scope,
        resetGeneration: generation,
      );
      Logger.warn(
        'Cloud Sync V2 protected fetch failed '
        'category=${mapped.category.name} code=${mapped.safeCode ?? 'none'}',
      );
      throw mapped;
    }
    return _mapPage(scope, page!, generation, maximumChanges);
  }

  CloudFetchBatch _mapPage(
    CloudSyncScope scope,
    NativeProtectedPage page,
    int expectedGeneration,
    int maximumChanges,
  ) {
    if (page.generation != expectedGeneration ||
        page.changes.length > maximumChanges ||
        page.changes.length > _maximumChangesPerPage ||
        page.admittedRawBytes < 0 ||
        page.admittedRawBytes > _maximumAdmittedRawPageBytes ||
        !_nativeDigestPattern.hasMatch(page.batchId) ||
        !_leaseReferencePattern.hasMatch(page.pageLeaseReference) ||
        (page.protectedNextCheckpointReference != null &&
            !_protectedReferencePattern.hasMatch(
              page.protectedNextCheckpointReference!,
            )) ||
        (!page.complete && page.protectedNextCheckpointReference == null)) {
      throw _malformed('invalid_protected_page');
    }
    final changes = page.changes.map(_mapChange).toList(growable: false);
    return CloudFetchBatch(
      scope: scope,
      changes: changes,
      batchId: page.batchId,
      generation: page.generation,
      nextToken: page.protectedNextCheckpointReference,
      hasMore: !page.complete,
      protectedPageLeaseReference: page.pageLeaseReference,
    );
  }

  CloudFetchedChange _mapChange(NativeProtectedChange change) {
    final preflight = change.preflightCode;
    final validKind = switch (change.kind) {
      NativeProtectedChangeKind.save =>
        !change.isTombstone && preflight == null,
      NativeProtectedChangeKind.delete =>
        change.isTombstone && preflight == null,
      NativeProtectedChangeKind.quarantined => preflight != null,
    };
    if (!validKind ||
        !_nativeDigestPattern.hasMatch(change.changeId) ||
        !_nativeDigestPattern.hasMatch(change.recordIdHash) ||
        (change.etagHash != null &&
            !_nativeDigestPattern.hasMatch(change.etagHash!)) ||
        !_contentDigestPattern.hasMatch(change.payloadSha256) ||
        change.payloadLength < 0 ||
        change.payloadLength > _maximumAdmittedRawPageBytes ||
        !_protectedReferencePattern.hasMatch(
          change.protectedRecordIdentityReference,
        ) ||
        !_protectedReferencePattern.hasMatch(
          change.protectedRawEnvelopeReference,
        )) {
      throw _malformed('invalid_protected_change');
    }
    DateTime? modifiedAt;
    final modifiedMillis = change.serverModifiedAtMillis;
    if (modifiedMillis != null) {
      try {
        modifiedAt = DateTime.fromMillisecondsSinceEpoch(
          modifiedMillis,
          isUtc: true,
        );
      } on RangeError {
        throw _malformed('invalid_server_modified_time');
      }
    }
    return CloudFetchedChange(
      changeId: change.changeId,
      recordIdHash: change.recordIdHash,
      etagHash: change.etagHash,
      type: change.isTombstone ? CloudChangeType.delete : CloudChangeType.save,
      encryptedServerRecordId: change.protectedRecordIdentityReference,
      encryptedPayloadReference: change.protectedRawEnvelopeReference,
      payloadSha256: change.payloadSha256,
      isTombstone: change.isTombstone,
      serverModifiedAt: modifiedAt,
      preflightFailure: preflight == null
          ? null
          : CloudFailureCategory.malformedRecord,
      preflightCode: preflight == null
          ? null
          : switch (preflight) {
              NativeProtectedPreflightCode.unsupportedRecordType =>
                CloudPreflightCode.unsupportedRecordType,
              NativeProtectedPreflightCode.malformedMetadata =>
                CloudPreflightCode.malformedMetadata,
              NativeProtectedPreflightCode.oversizedRecord =>
                CloudPreflightCode.oversizedRecord,
              NativeProtectedPreflightCode.invalidChangeShape =>
                CloudPreflightCode.invalidChangeShape,
            },
    );
  }

  @override
  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adoptedLeaseReferences,
    CloudProtectedReferenceSnapshot liveReferences,
  ) async {
    if (adoptedLeaseReferences.length > _maximumRecoveryReferences ||
        adoptedLeaseReferences.any(
          (reference) => !_leaseReferencePattern.hasMatch(reference),
        )) {
      throw _localStorage('invalid_adopted_lease_set');
    }
    _validateLiveReferenceSnapshot(liveReferences);
    final sorted = adoptedLeaseReferences.toList()..sort();
    final sortedLive = liveReferences.references.toList()..sort();
    final result = await _runProtectedStoreOperation(
      () => _bindings.recoverProtectedPageLeases(
        storageDirectory: _storageDirectory,
        adoptedLeaseReferences: sorted,
        liveReferences: sortedLive,
        liveReferenceEnumerationComplete: liveReferences.isComplete,
      ),
    );
    final recovery = result.recovery;
    final failure = result.failure;
    if ((recovery == null) == (failure == null)) {
      throw _localStorage('invalid_lease_recovery_envelope');
    }
    if (failure != null) throw _mapFailure(failure);
    final finalized = recovery!.finalizedAdoptedLeaseReferences.toSet();
    final absent = recovery.absentAdoptedLeaseReferences.toSet();
    if (finalized.length != recovery.finalizedAdoptedLeaseReferences.length ||
        absent.length != recovery.absentAdoptedLeaseReferences.length ||
        finalized.length > _maximumRecoveryResultsPerPass ||
        absent.length > _maximumRecoveryReferences ||
        recovery.rolledBackCount < 0 ||
        recovery.rolledBackCount > _maximumRecoveryResultsPerPass ||
        recovery.removedTemporaryFilesCount < 0 ||
        recovery.removedTemporaryFilesCount > _maximumRecoveryResultsPerPass ||
        finalized.any(
          (reference) => !adoptedLeaseReferences.contains(reference),
        ) ||
        absent.any(
          (reference) => !adoptedLeaseReferences.contains(reference),
        ) ||
        finalized.intersection(absent).isNotEmpty ||
        (recovery.hasMore && absent.isNotEmpty)) {
      throw _localStorage('invalid_lease_recovery_result');
    }
    return CloudProtectedPageLeaseRecoveryResult(
      finalizedAdoptedLeaseReferences: finalized,
      absentAdoptedLeaseReferences: absent,
      rolledBackCount: recovery.rolledBackCount,
      removedTemporaryFilesCount: recovery.removedTemporaryFilesCount,
      hasMore: recovery.hasMore,
    );
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async {
    _validateLeaseReference(leaseReference);
    _validateProtectedReferences(
      retainedReferences,
      maximumCount: _maximumProtectedReferencesPerLease,
    );
    final sorted = retainedReferences.toList()..sort();
    final result = await _runProtectedStoreOperation(
      () => _bindings.commitProtectedPageLease(
        storageDirectory: _storageDirectory,
        leaseReference: leaseReference,
        retainedReferences: sorted,
      ),
    );
    final failure = result.failure;
    if (failure != null) throw _mapFailure(failure);
  }

  @override
  Future<void> acknowledgeCommittedPageLease(String leaseReference) async {
    _validateLeaseReference(leaseReference);
    final result = await _runProtectedStoreOperation(
      () => _bindings.acknowledgeCommittedPageLease(
        storageDirectory: _storageDirectory,
        leaseReference: leaseReference,
      ),
    );
    final failure = result.failure;
    if (failure != null) throw _mapFailure(failure);
  }

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async {
    _validateLeaseReference(leaseReference);
    final result = await _runProtectedStoreOperation(
      () => _bindings.rollbackProtectedPageLease(
        storageDirectory: _storageDirectory,
        leaseReference: leaseReference,
      ),
    );
    final failure = result.failure;
    if (failure != null) throw _mapFailure(failure);
  }

  @override
  Future<int> retireProtectedReferences(Set<String> references) async {
    _validateProtectedReferences(
      references,
      maximumCount: _maximumGarbageCollectionResultsPerPass,
    );
    if (references.isEmpty) return 0;
    final sorted = references.toList()..sort();
    final result = await _runProtectedStoreOperation(
      () => _bindings.retireProtectedReferences(
        storageDirectory: _storageDirectory,
        references: sorted,
      ),
    );
    final failure = result.failure;
    if (failure != null) throw _mapFailure(failure);
    if (result.retiredCount < 0 || result.retiredCount > references.length) {
      throw _localStorage('invalid_retirement_result');
    }
    return result.retiredCount;
  }

  @override
  Future<CloudProtectedGarbageCollectionResult> collectProtectedGarbage(
    CloudProtectedReferenceSnapshot liveReferences,
  ) async {
    _validateLiveReferenceSnapshot(liveReferences);
    final sorted = liveReferences.references.toList()..sort();
    final result = await _runProtectedStoreOperation(
      () => _bindings.collectProtectedGarbage(
        storageDirectory: _storageDirectory,
        liveReferences: sorted,
        liveReferenceEnumerationComplete: liveReferences.isComplete,
      ),
    );
    final collection = result.collection;
    final failure = result.failure;
    if ((collection == null) == (failure == null)) {
      throw _localStorage('invalid_garbage_collection_envelope');
    }
    if (failure != null) throw _mapFailure(failure);
    final value = collection!;
    final counts = [
      value.scannedCount,
      value.firstObservedCount,
      value.deletedCount,
      value.preservedLiveCount,
      value.preservedActiveLeaseCount,
    ];
    if (counts.any(
          (count) =>
              count < 0 || count > _maximumGarbageCollectionResultsPerPass,
        ) ||
        value.firstObservedCount > value.scannedCount ||
        value.deletedCount > value.scannedCount ||
        value.preservedLiveCount > value.scannedCount ||
        value.preservedActiveLeaseCount > value.scannedCount ||
        value.firstObservedCount +
                value.deletedCount +
                value.preservedLiveCount +
                value.preservedActiveLeaseCount >
            value.scannedCount) {
      throw _localStorage('invalid_garbage_collection_result');
    }
    return CloudProtectedGarbageCollectionResult(
      scannedCount: value.scannedCount,
      firstObservedCount: value.firstObservedCount,
      deletedCount: value.deletedCount,
      preservedLiveCount: value.preservedLiveCount,
      preservedActiveLeaseCount: value.preservedActiveLeaseCount,
      hasMore: value.hasMore,
    );
  }

  void _validateLeaseReference(String reference) {
    if (!_leaseReferencePattern.hasMatch(reference)) {
      throw _localStorage('invalid_lease_reference');
    }
  }

  void _validateLiveReferenceSnapshot(
    CloudProtectedReferenceSnapshot snapshot,
  ) {
    if (!snapshot.isComplete) {
      throw _localStorage('protected_reference_enumeration_incomplete');
    }
    _validateProtectedReferences(snapshot.references);
  }

  void _validateProtectedReferences(
    Set<String> references, {
    int maximumCount = _maximumLiveProtectedReferences,
  }) {
    if (references.length > maximumCount ||
        references.any(
          (reference) => !_protectedReferencePattern.hasMatch(reference),
        )) {
      throw _localStorage('invalid_protected_reference_set');
    }
  }

  void _validateOutboundMessageScope(CloudSyncScope scope) {
    if (_validateScopeAndStream(scope) != 'messages') {
      throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'unsupported_protected_outbound_scope',
      );
    }
  }

  void _validateOutboundChatScope(CloudSyncScope scope) {
    if (_validateScopeAndStream(scope) != 'chats' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'unsupported_protected_outbound_scope',
      );
    }
  }

  void _validateOutboundAttachmentScope(CloudSyncScope scope) {
    if (_validateScopeAndStream(scope) != 'attachments' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'unsupported_protected_outbound_scope',
      );
    }
  }

  int _outboundCreatePayloadVersion(CloudSyncScope scope) {
    if (scope.zone == 'chatManateeZone') {
      _validateOutboundChatScope(scope);
      return cloudSyncOutboundChatPayloadVersion;
    }
    if (scope.zone == 'attachmentManateeZone') {
      _validateOutboundAttachmentScope(scope);
      return _attachmentCreatePayloadVersion;
    }
    // The existing Message-v2 validation remains unchanged.
    _validateOutboundMessageScope(scope);
    return cloudSyncOutboundPayloadVersion;
  }

  bool _isInitialCreateOperationIdentity(
    CloudSyncScope scope, {
    required String operationId,
    required String logicalEntityKeyHash,
    required int payloadVersion,
  }) {
    if (!_outboundOperationIdPattern.hasMatch(operationId) ||
        !_nativeDigestPattern.hasMatch(logicalEntityKeyHash)) {
      return false;
    }
    return operationId ==
        CloudOperationIdentity.forInitialCreate(
          scope: scope,
          logicalEntityKeyHash: logicalEntityKeyHash,
          payloadVersion: payloadVersion,
        );
  }

  CloudFailureCategory _mapOutboundFailureClass(
    frb_api.CloudSyncOutboundFailureClass? failure,
  ) => switch (failure) {
    frb_api.CloudSyncOutboundFailureClass.throttled =>
      CloudFailureCategory.throttled,
    frb_api.CloudSyncOutboundFailureClass.transientServer =>
      CloudFailureCategory.server,
    frb_api.CloudSyncOutboundFailureClass.authentication =>
      CloudFailureCategory.authorization,
    frb_api.CloudSyncOutboundFailureClass.conflict =>
      CloudFailureCategory.conflict,
    frb_api.CloudSyncOutboundFailureClass.resetRequired =>
      // Fail closed and non-retryable: reset-required must never enter the
      // PCS refresh path. The reset identity travels on the safe code.
      CloudFailureCategory.unknown,
    frb_api.CloudSyncOutboundFailureClass.permanent ||
    frb_api.CloudSyncOutboundFailureClass.unknown ||
    null => CloudFailureCategory.unknown,
  };

  String _validateScopeAndStream(CloudSyncScope scope) {
    if (!_nativeDigestPattern.hasMatch(scope.accountFingerprint) ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'unsupported_protected_cloud_scope',
      );
    }
    return switch (scope.zone) {
      'chatManateeZone' => 'chats',
      'messageManateeZone' => 'messages',
      'attachmentManateeZone' => 'attachments',
      'messageUpdateZone' => 'messageUpdateZone',
      'recoverableMessageDeleteZone' => 'recoverableMessageDeleteZone',
      'scheduledMessageZone' => 'scheduledMessageZone',
      'chat1ManateeZone' => 'chat1ManateeZone',
      _ => throw CloudSyncFailure(
        category: CloudFailureCategory.cancelled,
        safeCode: 'unsupported_protected_cloud_zone',
      ),
    };
  }

  CloudSyncFailure _mapFailure(
    NativeProtectedFailure failure, {
    CloudSyncScope? resetScope,
    int? resetGeneration,
  }) {
    final retryAfter = failure.retryAfterSeconds == null
        ? null
        : Duration(seconds: failure.retryAfterSeconds!);
    final category = switch (failure.category) {
      NativeProtectedFailureCategory.network => CloudFailureCategory.network,
      NativeProtectedFailureCategory.throttled =>
        CloudFailureCategory.throttled,
      NativeProtectedFailureCategory.server => CloudFailureCategory.server,
      NativeProtectedFailureCategory.authorization =>
        CloudFailureCategory.authorization,
      NativeProtectedFailureCategory.pcsUnavailable =>
        CloudFailureCategory.pcsUnavailable,
      NativeProtectedFailureCategory.malformedRecord =>
        CloudFailureCategory.malformedRecord,
      NativeProtectedFailureCategory.conflict => CloudFailureCategory.conflict,
      NativeProtectedFailureCategory.localStorage =>
        CloudFailureCategory.localStorage,
      NativeProtectedFailureCategory.unknown => CloudFailureCategory.unknown,
    };
    final resetReference = failure.protectedResetProofReference;
    final isResetFailure = failure.safeCode == 'cloudkit_reset_required';
    final hasResetCoordinates = resetScope != null && resetGeneration != null;
    if (resetReference != null &&
        (!isResetFailure ||
            !hasResetCoordinates ||
            !_protectedReferencePattern.hasMatch(resetReference))) {
      return _localStorage('invalid_protected_reset_proof');
    }
    final resetContext = resetReference == null
        ? null
        : CloudSyncResetRequiredContext(
            scope: resetScope!,
            expectedGeneration: resetGeneration!,
            protectedRemoteStateProofReference: resetReference,
          );
    return CloudSyncFailure(
      category: category,
      retryAfter: retryAfter,
      safeCode: failure.safeCode,
      resetContext: resetContext,
    );
  }

  CloudSyncFailure _malformed(String code) => CloudSyncFailure(
    category: CloudFailureCategory.malformedRecord,
    safeCode: code,
  );

  CloudSyncFailure _localStorage(String code) => CloudSyncFailure(
    category: CloudFailureCategory.localStorage,
    safeCode: code,
  );

  @override
  Future<bool> refreshAuthentication(CloudSyncScope scope) async {
    final callback = _refreshAuthentication;
    return callback == null ? false : await callback(scope);
  }

  @override
  Future<bool> refreshPcsAccess(CloudSyncScope scope) async {
    final callback = _refreshPcsAccess;
    return callback == null ? false : await callback(scope);
  }

  @override
  Future<CloudPushBatchResult> pushOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
  }) => throw _readOnlyFailure();

  @override
  Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) async {
    _requireV2WriterInterlock();
    if (operation.scope != scope) {
      throw _localStorage('cloud_sync_outbound_reconcile_operation_invalid');
    }
    if (scope.zone == 'chatManateeZone') {
      _validateOutboundChatScope(scope);
      _requireChatWriteBindings();
    }
    if (scope.zone == 'attachmentManateeZone') {
      _validateOutboundAttachmentScope(scope);
      _requireAttachmentWriteBindings();
    }
    final mutationGuard = _writerMutationGuard;
    if (mutationGuard == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'cloud_sync_writer_mutation_guard_required',
      );
    }
    return _runProtectedStoreOperation(
      () => mutationGuard.reconcileUnknownOutcome(
        owner: CloudKitWriterOwner.v2,
        expectedClient: _cloudMessagesClient,
        operation: operation,
      ),
    );
  }

  /// Verifies an already-confirmed create through the exact protected remote
  /// digest lookup. This path never calls native prepare or consume and cannot
  /// submit a CloudKit mutation.
  Future<CloudSyncConfirmedReplayProof> verifyConfirmedMessageCreateNoSave(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) {
    _requireV2WriterInterlock();
    _validateOutboundMessageScope(scope);
    return _verifyConfirmedCreateNoSave(scope, operation: operation);
  }

  /// Chat-specific no-save readback retains the same proof/receipt fences.
  Future<CloudSyncConfirmedReplayProof> verifyConfirmedChatCreateNoSave(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) {
    _requireV2WriterInterlock();
    _validateOutboundChatScope(scope);
    _requireChatWriteBindings();
    return _verifyConfirmedCreateNoSave(scope, operation: operation);
  }

  /// Attachment-specific no-save readback retains the same proof/receipt
  /// fences. This path never calls native prepare or consume and cannot
  /// upload bytes.
  Future<CloudSyncConfirmedReplayProof> verifyConfirmedAttachmentCreateNoSave(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) {
    _requireV2WriterInterlock();
    _validateOutboundAttachmentScope(scope);
    _requireAttachmentWriteBindings();
    return _verifyConfirmedCreateNoSave(scope, operation: operation);
  }

  Future<CloudSyncConfirmedReplayProof> _verifyConfirmedCreateNoSave(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) async {
    final resolution = await _reconcileCreateOutcome(
      scope,
      operation: operation,
      expectedStatus: CloudOutboxStatus.confirmed,
      invalidOperationCode: 'cloud_sync_outbound_replay_operation_invalid',
      invalidEnvelopeCode: 'cloud_sync_outbound_replay_envelope_invalid',
    );
    switch (resolution.disposition) {
      case CloudUnknownOutcomeDisposition.committed:
        return _NativeConfirmedReplayProof(
          operation,
          operation.protectedLeaseReference!,
        );
      case CloudUnknownOutcomeDisposition.notApplied:
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'cloud_sync_outbound_replay_record_missing',
        );
      case CloudUnknownOutcomeDisposition.serverRecordChanged:
      case CloudUnknownOutcomeDisposition.quarantined:
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'cloud_sync_outbound_replay_conflict',
        );
      case CloudUnknownOutcomeDisposition.unresolved:
        throw CloudSyncFailure(
          category: resolution.failureCategory ?? CloudFailureCategory.unknown,
          retryAfter: resolution.retryAfter,
          safeCode: 'cloud_sync_outbound_replay_unresolved',
        );
    }
  }

  /// Durably releases adoption, then removes the retained local receipt, only
  /// after an exact remote digest replay has succeeded.
  ///
  /// The proof is consumed before the first await. The durable marker callback
  /// runs before native acknowledgement: if the process dies after that local
  /// transaction, startup recovery sees the receipt as unadopted and removes
  /// it while the operation's protected payload reference remains live. No
  /// CloudKit operation is performed here.
  Future<void> releaseConfirmedReplayReceipt(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required CloudSyncConfirmedReplayProof proof,
    required Future<void> Function() clearDurableAdoptionMarker,
  }) async {
    _requireV2WriterInterlock();
    final payloadVersion = _outboundCreatePayloadVersion(scope);
    final payloadReference = operation.encryptedPayloadReference;
    final payloadSha256 = operation.payloadSha256;
    final serverRecordIdHash = operation.serverRecordIdHash;
    final leaseReference = operation.protectedLeaseReference;
    final requestUuid = operation.appleRequestUuid;
    final operationUuid = operation.appleOperationUuid;
    if (proof is! _NativeConfirmedReplayProof ||
        proof.consumed ||
        !proof.binds(operation) ||
        operation.scope != scope ||
        operation.status != CloudOutboxStatus.confirmed ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != payloadVersion ||
        !_isInitialCreateOperationIdentity(
          scope,
          operationId: operation.operationId,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          payloadVersion: operation.payloadVersion,
        ) ||
        payloadReference == null ||
        !_protectedReferencePattern.hasMatch(payloadReference) ||
        payloadSha256 == null ||
        !_contentDigestPattern.hasMatch(payloadSha256) ||
        serverRecordIdHash == null ||
        !_nativeDigestPattern.hasMatch(serverRecordIdHash) ||
        leaseReference == null ||
        !_leaseReferencePattern.hasMatch(leaseReference) ||
        requestUuid == null ||
        !_canonicalAppleUuidPattern.hasMatch(requestUuid) ||
        operationUuid == null ||
        !_canonicalAppleUuidPattern.hasMatch(operationUuid) ||
        requestUuid == operationUuid) {
      throw _localStorage('cloud_sync_outbound_replay_operation_invalid');
    }

    proof.consumed = true;
    await clearDurableAdoptionMarker();
    final result = await _runProtectedStoreOperation(
      () => _bindings.acknowledgeCommittedPageLease(
        storageDirectory: _storageDirectory,
        leaseReference: leaseReference,
      ),
    );
    if (result.failure != null) {
      throw _mapFailure(result.failure!);
    }
  }

  Future<CloudUnknownOutcomeResolution> _reconcileCreateOutcome(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required CloudOutboxStatus expectedStatus,
    required String invalidOperationCode,
    required String invalidEnvelopeCode,
  }) async {
    _requireV2WriterInterlock();
    final payloadVersion = _outboundCreatePayloadVersion(scope);
    final reconcile = scope.zone == 'chatManateeZone'
        ? _requireChatWriteBindings().reconcileChatCreate
        : scope.zone == 'attachmentManateeZone'
        ? _requireAttachmentWriteBindings().reconcileAttachmentCreate
        : _requireWriteBindings().reconcileMessageCreate;
    final payloadReference = operation.encryptedPayloadReference;
    final payloadSha256 = operation.payloadSha256;
    final serverRecordIdHash = operation.serverRecordIdHash;
    final leaseReference = operation.protectedLeaseReference;
    final requestUuid = operation.appleRequestUuid;
    final operationUuid = operation.appleOperationUuid;
    if (operation.scope != scope ||
        operation.status != expectedStatus ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != payloadVersion ||
        !_isInitialCreateOperationIdentity(
          scope,
          operationId: operation.operationId,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          payloadVersion: operation.payloadVersion,
        ) ||
        payloadReference == null ||
        !_protectedReferencePattern.hasMatch(payloadReference) ||
        payloadSha256 == null ||
        !_contentDigestPattern.hasMatch(payloadSha256) ||
        serverRecordIdHash == null ||
        !_nativeDigestPattern.hasMatch(serverRecordIdHash) ||
        leaseReference == null ||
        !_leaseReferencePattern.hasMatch(leaseReference) ||
        requestUuid == null ||
        !_canonicalAppleUuidPattern.hasMatch(requestUuid) ||
        operationUuid == null ||
        !_canonicalAppleUuidPattern.hasMatch(operationUuid) ||
        requestUuid == operationUuid) {
      throw _localStorage(invalidOperationCode);
    }

    final result = await _runProtectedStoreOperation(() async {
      // Post-restart readback (verify/reconcile) builds its own input
      // rather than reusing the prepare preflight one. Parent authority
      // resolves here, inside the protected-store exclusion, with the
      // same capture-await-reread discipline as prepare: only
      // messageManateeZone operations receive a context or proof.
      final parentContext = _readParentContextForPrepare(
        scope,
        operation.operationId,
      );
      return reconcile(
        cloudMessagesClient: _cloudMessagesClient,
        storageDirectory: _storageDirectory,
        expectedAccountFingerprint: scope.accountFingerprint,
        expectedProtectedStoreIdentity: _protectedStoreIdentity,
        requestUuid: requestUuid,
        input: frb_api.CloudSyncPreparedMessageCreateInput(
          localOperationId: operation.operationId,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          protectedLeaseReference: leaseReference,
          protectedPayloadReference: payloadReference,
          payloadSha256: payloadSha256,
          protectedServerRecordReference: payloadReference,
          serverRecordIdHash: serverRecordIdHash,
          appleOperationUuid: operationUuid,
          attachmentParentContext: parentContext,
          attachmentParentGroupProof: await _readParentGroupProofForPrepare(
            scope,
            operation.operationId,
            parentContext,
          ),
        ),
      );
    });
    final disposition = _requireOutboundReconcileDisposition(
      result,
      expectedProtectedProofReference: payloadReference,
      invalidEnvelopeCode: invalidEnvelopeCode,
    );

    return switch (disposition) {
      frb_api.CloudSyncOutboundReconcileDisposition.committed =>
        _requireReplayCommittedReceipt(result, operation),
      frb_api.CloudSyncOutboundReconcileDisposition.notApplied =>
        const CloudUnknownOutcomeResolution.notApplied(),
      frb_api.CloudSyncOutboundReconcileDisposition.diverged =>
        const CloudUnknownOutcomeResolution.quarantined(
          failureCategory: CloudFailureCategory.conflict,
        ),
      frb_api.CloudSyncOutboundReconcileDisposition.unresolved =>
        CloudUnknownOutcomeResolution.unresolved(
          failureCategory: _mapOutboundFailureClass(result.failureClass),
          retryAfter: _boundedRetryAfter(result.retryAfterSeconds),
        ),
    };
  }

  @override
  Future<CloudRecordMapEntry> allocateServerRecordMapping(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
  }) => throw _readOnlyFailure();

  /// Binds a committed replay readback to an exact create receipt.
  ///
  /// A missing, malformed, or mismatched receipt fails closed: no proof is
  /// issued and the retained local receipt stays in place for a later retry.
  /// All failures use content-free safe codes and carry no identifiers.
  CloudUnknownOutcomeResolution _requireReplayCommittedReceipt(
    frb_api.CloudSyncOutboundReconcileResult result,
    CloudOutboxOperation operation,
  ) {
    final serverRecordIdHash = result.serverRecordIdHash;
    final etagHash = result.etagHash;
    if (serverRecordIdHash == null ||
        etagHash == null ||
        !_nativeDigestPattern.hasMatch(serverRecordIdHash) ||
        !_nativeDigestPattern.hasMatch(etagHash) ||
        !_nativeDigestPattern.hasMatch(operation.logicalEntityKeyHash)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'cloud_sync_outbound_replay_receipt_invalid',
      );
    }
    if (serverRecordIdHash != operation.serverRecordIdHash) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'cloud_sync_outbound_replay_receipt_mismatch',
      );
    }
    return CloudUnknownOutcomeResolution.committed(
      createReceipt: CloudOutboxCreateReceipt(
        operationId: operation.operationId,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        serverRecordIdHash: serverRecordIdHash,
        etagHash: etagHash,
      ),
    );
  }

  @override
  Future<CloudServerConflictResolution> reconcileServerRecordChanged(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) => throw _readOnlyFailure();

  CloudSyncFailure _readOnlyFailure() => CloudSyncFailure(
    category: CloudFailureCategory.cancelled,
    safeCode: 'cloud_sync_protected_read_only',
  );
}

/// Typed façade over the generated protected FRB surface.
final class FrbNativeProtectedCloudSyncBindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedCloudSyncWriteBindings,
        NativeProtectedCloudSyncMessageUpdateBindings,
        CloudKitWriterChatReconciliationBinding,
        NativeProtectedCloudSyncChatWriteBindings,
        NativeProtectedCloudSyncAttachmentParentWriteBindings,
        NativeProtectedCloudSyncAttachmentWriteBindings,
        NativeProtectedPreparedReleaseBindings,
        CloudKitWriterUploadReconciliationBinding,
        CloudKitWriterAttachmentReconciliationBinding {
  FrbNativeProtectedCloudSyncBindings({RustLibApi? api})
    // ignore: invalid_use_of_internal_member
    : _api = api ?? RustLib.instance.api;

  final RustLibApi _api;

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundMessage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage message,
  }) => _api.crateApiApiCloudSyncStageOutboundMessage(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    message: message,
  );

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) => _api.crateApiApiCloudSyncPrepareMessageCreate(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    requestUuid: requestUuid,
    requestTimeoutSeconds: BigInt.from(requestTimeout.inSeconds),
    inputs: inputs,
  );

  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) => _api.crateApiApiCloudSyncConsumePreparedMessageCreate(
    handle: handle,
    mutationCapabilityToken: mutationCapabilityToken,
  );

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) => _api.crateApiApiCloudSyncReconcileMessageCreate(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    requestUuid: requestUuid,
    input: input,
  );

  @override
  Future<frb_api.CloudSyncPrepareMessageUpdateResult> prepareMessageUpdate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudSyncMessageUpdatePrepareInput input,
  }) async {
    _validateMessageUpdateStageCall(
      storageDirectory: storageDirectory,
      expectedAccountFingerprint: expectedAccountFingerprint,
      expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
      input: input,
    );
    final result = await _api.crateApiApiCloudSyncPrepareMessageUpdate(
      cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
      storageDirectory: storageDirectory,
      expectedAccountFingerprint: expectedAccountFingerprint,
      expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
      input: input,
    );
    _validateMessageUpdateStageEnvelope(result, input: input);
    return result;
  }

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult>
  prepareMessageUpdateSubmission({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required frb_api.CloudSyncMessageUpdateSubmissionInput input,
  }) async {
    _validateMessageUpdateSubmissionCall(
      storageDirectory: storageDirectory,
      expectedAccountFingerprint: expectedAccountFingerprint,
      expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
      requestUuid: requestUuid,
      requestTimeout: requestTimeout,
      input: input,
    );
    final result = await _api
        .crateApiApiCloudSyncPrepareMessageUpdateSubmission(
          cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
          storageDirectory: storageDirectory,
          expectedAccountFingerprint: expectedAccountFingerprint,
          expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
          requestUuid: requestUuid,
          requestTimeoutSeconds: BigInt.from(requestTimeout.inSeconds),
          input: input,
        );
    _validateMessageUpdateSubmissionPrepareEnvelope(result);
    return result;
  }

  @override
  Future<frb_api.CloudSyncOutboundConsumeResult> consumePreparedMessageUpdate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
    required String mutationCapabilityToken,
  }) {
    if (mutationCapabilityToken.isEmpty) {
      throw ArgumentError('cloud_sync_message_update_consume_invalid');
    }
    return _api.crateApiApiCloudSyncConsumePreparedMessageCreate(
      handle: handle,
      mutationCapabilityToken: mutationCapabilityToken,
    );
  }

  @override
  Future<frb_api.CloudSyncMessageUpdateReconcileResult> reconcileMessageUpdate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncMessageUpdateSubmissionInput input,
  }) async {
    _validateMessageUpdateSubmissionCall(
      storageDirectory: storageDirectory,
      expectedAccountFingerprint: expectedAccountFingerprint,
      expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
      requestUuid: requestUuid,
      input: input,
    );
    final result = await _api.crateApiApiCloudSyncReconcileMessageUpdate(
      cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
      storageDirectory: storageDirectory,
      expectedAccountFingerprint: expectedAccountFingerprint,
      expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
      requestUuid: requestUuid,
      input: input,
    );
    _validateMessageUpdateReconcileEnvelope(result, input: input);
    return result;
  }

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult> stageOutboundChat({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudChat chat,
  }) => _api.crateApiApiCloudSyncStageOutboundChat(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    chat: chat,
  );

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) => _api.crateApiApiCloudSyncPrepareChatCreate(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    requestUuid: requestUuid,
    requestTimeoutSeconds: BigInt.from(requestTimeout.inSeconds),
    inputs: inputs,
  );

  @override
  Future<frb_api.CloudSyncProtectedOutboundStageResult>
  stageOutboundAttachmentParent({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudMessage messageHeaders,
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentParentGroupProof? groupProof,
  }) {
    // The native parent stage takes only the client, the exact source
    // receipt context, the headers, and the optional ephemeral group proof.
    // Account/store/directory binding is enforced locally by
    // [_validateAttachmentParentContext] before this point, so the extra
    // seam parameters are intentionally not forwarded.
    return _api.crateApiApiCloudSyncStageOutboundAttachmentParent(
      cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
      messageHeaders: messageHeaders,
      context: context,
      attachmentParentGroupProof: groupProof,
    );
  }

  @override
  Future<bool> releasePreparedMessageCreate({
    required frb_api.CloudSyncPreparedMessageCreateHandle handle,
  }) => _api.crateApiApiCloudSyncReleasePreparedMessageCreate(handle: handle);

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileChatCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) => _api.crateApiApiCloudSyncReconcileChatCreate(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    requestUuid: requestUuid,
    input: input,
  );

  @override
  Future<frb_api.CloudSyncPreparedMessageCreateResult> prepareAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required Duration requestTimeout,
    required List<frb_api.CloudSyncPreparedMessageCreateInput> inputs,
  }) => _api.crateApiApiCloudSyncPrepareAttachmentCreate(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    requestUuid: requestUuid,
    requestTimeoutSeconds: BigInt.from(requestTimeout.inSeconds),
    inputs: inputs,
  );

  @override
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileAttachmentCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  }) => _api.crateApiApiCloudSyncReconcileAttachmentCreate(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    storageDirectory: storageDirectory,
    expectedAccountFingerprint: expectedAccountFingerprint,
    expectedProtectedStoreIdentity: expectedProtectedStoreIdentity,
    requestUuid: requestUuid,
    input: input,
  );

  @override
  Future<frb_api.CloudSyncAttachmentUploadReceiptEvidence?>
  verifyAttachmentUploadReceipt({
    required Object cloudMessagesClient,
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
    required String expectedAttemptId,
  }) => _api.crateApiApiCloudSyncVerifyAttachmentUploadReceipt(
    cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
    context: context,
    planStage: planStage,
    expectedAttemptId: expectedAttemptId,
  );

  @override
  Future<NativeProtectedFetchResult> fetchProtectedPage({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  }) async {
    final result = await _api.crateApiApiCloudSyncFetchProtectedPage(
      cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
      storageDirectory: storageDirectory,
      expectedAccountFingerprint: expectedAccountFingerprint,
      stream: stream,
      generation: BigInt.from(generation),
      previousCheckpointReference: previousCheckpointReference,
      maximumChanges: maximumChanges,
    );
    return NativeProtectedFetchResult(
      page: result.page == null ? null : _pageFromFrb(result.page!),
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  @override
  Future<NativeProtectedFetchResult> fetchProtectedPageUnderWriterPause({
    required Object cloudMessagesClient,
    required BigInt nativeWriterPauseToken,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String stream,
    required int generation,
    required String? previousCheckpointReference,
    required int maximumChanges,
  }) async {
    final result = await _api
        .crateApiApiCloudSyncFetchProtectedPageUnderWriterPause(
          cloudMessagesClient: _requireCloudMessagesClient(cloudMessagesClient),
          nativeWriterPauseToken: nativeWriterPauseToken,
          storageDirectory: storageDirectory,
          expectedAccountFingerprint: expectedAccountFingerprint,
          stream: stream,
          generation: BigInt.from(generation),
          previousCheckpointReference: previousCheckpointReference,
          maximumChanges: maximumChanges,
        );
    return NativeProtectedFetchResult(
      page: result.page == null ? null : _pageFromFrb(result.page!),
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  @override
  Future<NativeProtectedLeaseResult> commitProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
    required List<String> retainedReferences,
  }) async {
    final result = _api.crateApiApiCloudSyncCommitProtectedPageLease(
      storageDirectory: storageDirectory,
      pageLeaseReference: leaseReference,
      retainedReferences: retainedReferences,
    );
    return NativeProtectedLeaseResult(
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  @override
  Future<NativeProtectedLeaseResult> acknowledgeCommittedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) async {
    final result = _api.crateApiApiCloudSyncAcknowledgeCommittedPageLease(
      storageDirectory: storageDirectory,
      pageLeaseReference: leaseReference,
    );
    return NativeProtectedLeaseResult(
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  @override
  Future<NativeProtectedLeaseResult> rollbackProtectedPageLease({
    required String storageDirectory,
    required String leaseReference,
  }) async {
    final result = _api.crateApiApiCloudSyncRollbackProtectedPageLease(
      storageDirectory: storageDirectory,
      pageLeaseReference: leaseReference,
    );
    return NativeProtectedLeaseResult(
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  @override
  Future<NativeProtectedRecoveryResult> recoverProtectedPageLeases({
    required String storageDirectory,
    required List<String> adoptedLeaseReferences,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) async {
    final result = _api.crateApiApiCloudSyncRecoverAbandonedPageLeases(
      storageDirectory: storageDirectory,
      adoptedLeaseReferences: adoptedLeaseReferences,
      liveReferences: liveReferences,
      liveReferenceEnumerationComplete: liveReferenceEnumerationComplete,
    );
    return NativeProtectedRecoveryResult(
      recovery: result.recovery == null
          ? null
          : _recoveryFromFrb(result.recovery!),
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  @override
  Future<NativeProtectedRetirementResult> retireProtectedReferences({
    required String storageDirectory,
    required List<String> references,
  }) async {
    final result = _api.crateApiApiCloudSyncRetireProtectedReferences(
      storageDirectory: storageDirectory,
      references: references,
    );
    return NativeProtectedRetirementResult(
      retiredCount: result.retiredCount,
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  @override
  Future<NativeProtectedGarbageCollectionResult> collectProtectedGarbage({
    required String storageDirectory,
    required List<String> liveReferences,
    required bool liveReferenceEnumerationComplete,
  }) async {
    final result = _api.crateApiApiCloudSyncCollectProtectedGarbage(
      storageDirectory: storageDirectory,
      liveReferences: liveReferences,
      liveReferenceEnumerationComplete: liveReferenceEnumerationComplete,
    );
    return NativeProtectedGarbageCollectionResult(
      collection: result.collection == null
          ? null
          : NativeProtectedGarbageCollection(
              scannedCount: result.collection!.scannedCount,
              firstObservedCount: result.collection!.firstObservedCount,
              deletedCount: result.collection!.deletedCount,
              preservedLiveCount: result.collection!.preservedLiveCount,
              preservedActiveLeaseCount:
                  result.collection!.preservedActiveLeaseCount,
              hasMore: result.collection!.hasMore,
            ),
      failure: result.failure == null ? null : _failureFromFrb(result.failure!),
    );
  }

  frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider
  _requireCloudMessagesClient(Object value) {
    if (value is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw ArgumentError(
        'cloudMessagesClient must be the generated FRB Cloud Messages client',
      );
    }
    return value;
  }

  void _validateMessageUpdateStageCall({
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required frb_api.CloudSyncMessageUpdatePrepareInput input,
  }) {
    final context = input.mutationContext;
    final contextBinding = context.sourceBinding;
    final receipt = input.mutationReceipt;
    final receiptBinding = receipt.sourceBinding;
    final preparedSentTimestampMs = receipt.preparedSentTimestampMs;
    if (storageDirectory.isEmpty ||
        !_nativeDigestPattern.hasMatch(expectedAccountFingerprint) ||
        !_nativeStoreIdentityPattern.hasMatch(expectedProtectedStoreIdentity) ||
        !_nativeDigestPattern.hasMatch(input.expectedLogicalEntityKeyHash) ||
        !_nativeDigestPattern.hasMatch(input.expectedServerRecordIdHash) ||
        !_nativeDigestPattern.hasMatch(input.expectedEtagHash) ||
        !_protectedReferencePattern.hasMatch(
          input.protectedRawRecordReference,
        ) ||
        input.rawGeneration <= BigInt.zero ||
        input.rawGeneration.bitLength > 64 ||
        !_contentDigestPattern.hasMatch(input.expectedReceiptBindingSha256) ||
        !_contentDigestPattern.hasMatch(input.reflectedSnapshotSha256) ||
        input.writerEpoch <= BigInt.zero ||
        input.writerEpoch.bitLength > 64 ||
        context.storageDirectory != storageDirectory ||
        context.accountFingerprint != expectedAccountFingerprint ||
        context.protectedStoreIdentity != expectedProtectedStoreIdentity ||
        !_contentDigestPattern.hasMatch(context.guidHash) ||
        !_nativeDigestPattern.hasMatch(context.nativeSessionId) ||
        !_isValidMessageUpdateMutationSourceBinding(contextBinding) ||
        !_idsReceiptReferencePattern.hasMatch(receipt.receiptId) ||
        receipt.guidHash != context.guidHash ||
        !_contentDigestPattern.hasMatch(receipt.guidHash) ||
        !_nativeDigestPattern.hasMatch(receipt.nativeSessionId) ||
        receiptBinding != contextBinding ||
        preparedSentTimestampMs == null ||
        preparedSentTimestampMs <= BigInt.zero ||
        preparedSentTimestampMs.bitLength > 63) {
      throw ArgumentError('cloud_sync_message_update_stage_invalid');
    }
  }

  bool _isValidMessageUpdateMutationSourceBinding(
    frb_api.CloudSyncNativeSendSourceBinding? binding,
  ) =>
      binding != null &&
      binding.kind == frb_api.CloudSyncNativeSendSourceKind.mutation &&
      _contentDigestPattern.hasMatch(binding.sourceSha256) &&
      _protectedReferencePattern.hasMatch(binding.protectedReference) &&
      _leaseReferencePattern.hasMatch(binding.leaseReference) &&
      _contentDigestPattern.hasMatch(binding.payloadSha256) &&
      binding.payloadLength > BigInt.zero &&
      binding.payloadLength <= BigInt.from(_maximumIdsMutationSourceBytes);

  void _validateMessageUpdateStageEnvelope(
    frb_api.CloudSyncPrepareMessageUpdateResult result, {
    required frb_api.CloudSyncMessageUpdatePrepareInput input,
  }) {
    final prepared = result.prepared;
    if ((prepared == null) == (result.failure == null) ||
        (prepared != null &&
            (!_protectedReferencePattern.hasMatch(
                  prepared.protectedReference,
                ) ||
                !_leaseReferencePattern.hasMatch(prepared.leaseReference) ||
                !_contentDigestPattern.hasMatch(prepared.payloadSha256) ||
                prepared.logicalEntityKeyHash !=
                    input.expectedLogicalEntityKeyHash ||
                !_nativeDigestPattern.hasMatch(prepared.logicalEntityKeyHash) ||
                prepared.serverRecordIdHash !=
                    input.expectedServerRecordIdHash ||
                !_nativeDigestPattern.hasMatch(prepared.serverRecordIdHash)))) {
      throw StateError('cloud_sync_message_update_stage_envelope_invalid');
    }
  }

  void _validateMessageUpdateSubmissionCall({
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    Duration? requestTimeout,
    required frb_api.CloudSyncMessageUpdateSubmissionInput input,
  }) {
    final timeoutSeconds = requestTimeout?.inSeconds;
    if (storageDirectory.isEmpty ||
        !_nativeDigestPattern.hasMatch(expectedAccountFingerprint) ||
        !_nativeStoreIdentityPattern.hasMatch(expectedProtectedStoreIdentity) ||
        !_canonicalAppleUuidPattern.hasMatch(requestUuid) ||
        (timeoutSeconds != null &&
            (timeoutSeconds < 1 || timeoutSeconds > 300)) ||
        !_outboundOperationIdPattern.hasMatch(input.localOperationId) ||
        !_nativeDigestPattern.hasMatch(input.logicalEntityKeyHash) ||
        !_nativeDigestPattern.hasMatch(input.serverRecordIdHash) ||
        !_nativeDigestPattern.hasMatch(input.predecessorEtagHash) ||
        !_leaseReferencePattern.hasMatch(input.protectedLeaseReference) ||
        !_protectedReferencePattern.hasMatch(input.protectedPayloadReference) ||
        !_contentDigestPattern.hasMatch(input.payloadSha256) ||
        !_contentDigestPattern.hasMatch(input.mutationSourceSha256) ||
        !_contentDigestPattern.hasMatch(input.idsReceiptBindingSha256) ||
        !_contentDigestPattern.hasMatch(input.reflectedSnapshotSha256) ||
        input.writerEpoch <= BigInt.zero ||
        input.writerEpoch.bitLength > 64 ||
        input.rawGeneration <= BigInt.zero ||
        input.rawGeneration.bitLength > 64 ||
        !_canonicalAppleUuidPattern.hasMatch(input.appleOperationUuid) ||
        requestUuid == input.appleOperationUuid) {
      throw ArgumentError('cloud_sync_message_update_submission_invalid');
    }
  }

  void _validateMessageUpdateSubmissionPrepareEnvelope(
    frb_api.CloudSyncPreparedMessageCreateResult result,
  ) {
    final successful = result.handle != null;
    if (successful == (result.failure != null) ||
        (successful &&
            (result.handleBindingSha256 == null ||
                !_contentDigestPattern.hasMatch(
                  result.handleBindingSha256!,
                ))) ||
        (!successful && result.handleBindingSha256 != null)) {
      throw StateError('cloud_sync_message_update_prepare_envelope_invalid');
    }
  }

  void _validateMessageUpdateReconcileEnvelope(
    frb_api.CloudSyncMessageUpdateReconcileResult result, {
    required frb_api.CloudSyncMessageUpdateSubmissionInput input,
  }) {
    final disposition = result.disposition;
    if ((disposition == null) == (result.failure == null)) {
      throw StateError('cloud_sync_message_update_reconcile_envelope_invalid');
    }
    if (result.failure != null) {
      if (result.protectedProofReference != null ||
          result.receipt != null ||
          result.failureClass != null ||
          result.retryAfterSeconds != null) {
        throw StateError(
          'cloud_sync_message_update_reconcile_envelope_invalid',
        );
      }
      return;
    }

    final decisive =
        disposition != frb_api.CloudSyncOutboundReconcileDisposition.unresolved;
    final retryAfterSeconds = result.retryAfterSeconds;
    if ((decisive &&
            result.protectedProofReference !=
                input.protectedPayloadReference) ||
        (!decisive && result.protectedProofReference != null) ||
        (retryAfterSeconds != null &&
            (retryAfterSeconds < BigInt.zero ||
                retryAfterSeconds > BigInt.from(_maximumRetryAfterSeconds))) ||
        (decisive && retryAfterSeconds != null)) {
      throw StateError('cloud_sync_message_update_reconcile_envelope_invalid');
    }

    switch (disposition!) {
      case frb_api.CloudSyncOutboundReconcileDisposition.committed:
        if (result.failureClass != null ||
            !_isValidMessageUpdateReadbackReceipt(result.receipt, input)) {
          throw StateError(
            'cloud_sync_message_update_reconcile_envelope_invalid',
          );
        }
        break;
      case frb_api.CloudSyncOutboundReconcileDisposition.notApplied:
        if (result.receipt != null || result.failureClass != null) {
          throw StateError(
            'cloud_sync_message_update_reconcile_envelope_invalid',
          );
        }
        break;
      case frb_api.CloudSyncOutboundReconcileDisposition.diverged:
        if (result.receipt != null ||
            result.failureClass !=
                frb_api.CloudSyncOutboundFailureClass.conflict) {
          throw StateError(
            'cloud_sync_message_update_reconcile_envelope_invalid',
          );
        }
        break;
      case frb_api.CloudSyncOutboundReconcileDisposition.unresolved:
        if (result.receipt != null) {
          throw StateError(
            'cloud_sync_message_update_reconcile_envelope_invalid',
          );
        }
        break;
    }
  }

  bool _isValidMessageUpdateReadbackReceipt(
    frb_api.CloudSyncMessageUpdateReadbackReceipt? receipt,
    frb_api.CloudSyncMessageUpdateSubmissionInput input,
  ) =>
      receipt != null &&
      receipt.serverRecordIdHash == input.serverRecordIdHash &&
      _nativeDigestPattern.hasMatch(receipt.serverRecordIdHash) &&
      receipt.predecessorEtagHash == input.predecessorEtagHash &&
      _nativeDigestPattern.hasMatch(receipt.predecessorEtagHash) &&
      _nativeDigestPattern.hasMatch(receipt.resultingEtagHash) &&
      _protectedReferencePattern.hasMatch(
        receipt.protectedCurrentRawRecordReference,
      ) &&
      _leaseReferencePattern.hasMatch(
        receipt.protectedCurrentRawRecordLeaseReference,
      ) &&
      receipt.rawGeneration == input.rawGeneration &&
      receipt.rawGeneration > BigInt.zero &&
      receipt.rawGeneration.bitLength <= 64;

  NativeProtectedPage _pageFromFrb(frb_api.CloudSyncProtectedPage page) {
    return NativeProtectedPage(
      changes: page.changes.map(_changeFromFrb).toList(growable: false),
      batchId: page.batchId,
      generation: page.generation.toInt(),
      pageLeaseReference: page.pageLeaseReference,
      protectedNextCheckpointReference: page.protectedNextCheckpointReference,
      complete: page.complete,
      admittedRawBytes: page.admittedRawBytes.toInt(),
    );
  }

  NativeProtectedChange _changeFromFrb(
    frb_api.CloudSyncProtectedChange change,
  ) {
    return NativeProtectedChange(
      changeId: change.changeId,
      recordIdHash: change.recordIdHash,
      etagHash: change.etagHash,
      kind: _changeKind(change.kind),
      payloadSha256: change.payloadSha256,
      payloadLength: change.payloadLength.toInt(),
      protectedRecordIdentityReference: change.protectedRecordIdentityReference,
      protectedRawEnvelopeReference: change.protectedRawEnvelopeReference,
      serverModifiedAtMillis: change.serverModifiedAtMillis?.toInt(),
      preflightCode: change.preflightCode == null
          ? null
          : _preflightCode(change.preflightCode!),
      isTombstone: change.isTombstone,
    );
  }

  NativeProtectedRecovery _recoveryFromFrb(
    frb_api.CloudSyncProtectedRecovery recovery,
  ) {
    return NativeProtectedRecovery(
      finalizedAdoptedLeaseReferences: recovery.finalizedAdoptedLeaseReferences,
      absentAdoptedLeaseReferences: recovery.absentAdoptedLeaseReferences,
      rolledBackCount: recovery.rolledBackCount,
      removedTemporaryFilesCount: recovery.removedTemporaryFilesCount,
      hasMore: recovery.hasMore,
    );
  }

  NativeProtectedFailure _failureFromFrb(
    frb_api.CloudSyncProtectedFailure failure,
  ) {
    return NativeProtectedFailure(
      category: _failureCategory(failure.category),
      safeCode: cloudSyncV2ProtectedTransportSafeCode(failure.safeCode),
      retryAfterSeconds: failure.retryAfterSeconds?.toInt(),
      protectedResetProofReference: failure.protectedResetProofReference,
    );
  }

  NativeProtectedChangeKind _changeKind(
    frb_api.CloudSyncProtectedChangeKind kind,
  ) => switch (kind) {
    frb_api.CloudSyncProtectedChangeKind.save => NativeProtectedChangeKind.save,
    frb_api.CloudSyncProtectedChangeKind.delete =>
      NativeProtectedChangeKind.delete,
    frb_api.CloudSyncProtectedChangeKind.quarantined =>
      NativeProtectedChangeKind.quarantined,
  };

  NativeProtectedPreflightCode _preflightCode(
    frb_api.CloudSyncProtectedPreflightCode code,
  ) => switch (code) {
    frb_api.CloudSyncProtectedPreflightCode.unsupportedRecordType =>
      NativeProtectedPreflightCode.unsupportedRecordType,
    frb_api.CloudSyncProtectedPreflightCode.malformedMetadata =>
      NativeProtectedPreflightCode.malformedMetadata,
    frb_api.CloudSyncProtectedPreflightCode.oversizedRecord =>
      NativeProtectedPreflightCode.oversizedRecord,
    frb_api.CloudSyncProtectedPreflightCode.invalidChangeShape =>
      NativeProtectedPreflightCode.invalidChangeShape,
  };

  NativeProtectedFailureCategory _failureCategory(
    frb_api.CloudSyncProtectedFailureCategory category,
  ) => switch (category) {
    frb_api.CloudSyncProtectedFailureCategory.network =>
      NativeProtectedFailureCategory.network,
    frb_api.CloudSyncProtectedFailureCategory.throttled =>
      NativeProtectedFailureCategory.throttled,
    frb_api.CloudSyncProtectedFailureCategory.server =>
      NativeProtectedFailureCategory.server,
    frb_api.CloudSyncProtectedFailureCategory.authorization =>
      NativeProtectedFailureCategory.authorization,
    frb_api.CloudSyncProtectedFailureCategory.pcsUnavailable =>
      NativeProtectedFailureCategory.pcsUnavailable,
    frb_api.CloudSyncProtectedFailureCategory.malformedRecord =>
      NativeProtectedFailureCategory.malformedRecord,
    frb_api.CloudSyncProtectedFailureCategory.conflict =>
      NativeProtectedFailureCategory.conflict,
    frb_api.CloudSyncProtectedFailureCategory.localStorage =>
      NativeProtectedFailureCategory.localStorage,
    frb_api.CloudSyncProtectedFailureCategory.unknown =>
      NativeProtectedFailureCategory.unknown,
  };
}

String cloudSyncV2ProtectedTransportSafeCode(
  frb_api.CloudSyncProtectedSafeCode code,
) => switch (code) {
  frb_api.CloudSyncProtectedSafeCode.invalidScope =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.invalidScope,
  frb_api.CloudSyncProtectedSafeCode.invalidRequest =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.invalidRequest,
  frb_api.CloudSyncProtectedSafeCode.invalidCheckpoint =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.invalidCheckpoint,
  frb_api.CloudSyncProtectedSafeCode.checkpointContextMismatch =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.checkpointContextMismatch,
  frb_api.CloudSyncProtectedSafeCode.oversizedPage =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.oversizedPage,
  frb_api.CloudSyncProtectedSafeCode.oversizedRecord =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.oversizedRecord,
  frb_api.CloudSyncProtectedSafeCode.protectionFailed =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.protectionFailed,
  frb_api.CloudSyncProtectedSafeCode.localStoreFailed =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.localStoreFailed,
  frb_api.CloudSyncProtectedSafeCode.fetchDeadline =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.fetchDeadline,
  frb_api.CloudSyncProtectedSafeCode.network =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.network,
  frb_api.CloudSyncProtectedSafeCode.cloudKitThrottled =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitThrottled,
  frb_api.CloudSyncProtectedSafeCode.cloudKitServer =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitServer,
  frb_api.CloudSyncProtectedSafeCode.cloudKitAuthorization =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitAuthorization,
  frb_api.CloudSyncProtectedSafeCode.cloudKitConflict =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitConflict,
  frb_api.CloudSyncProtectedSafeCode.cloudKitResetRequired =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitResetRequired,
  frb_api.CloudSyncProtectedSafeCode.cloudKitPermanent =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitPermanent,
  frb_api.CloudSyncProtectedSafeCode.cloudKitUnknown =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitUnknown,
  frb_api.CloudSyncProtectedSafeCode.httpAuthorization =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.httpAuthorization,
  frb_api.CloudSyncProtectedSafeCode.httpTimeout =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.httpTimeout,
  frb_api.CloudSyncProtectedSafeCode.httpThrottled =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.httpThrottled,
  frb_api.CloudSyncProtectedSafeCode.httpServer =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.httpServer,
  frb_api.CloudSyncProtectedSafeCode.httpUnknown =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.httpUnknown,
  frb_api.CloudSyncProtectedSafeCode.pcsUnavailable =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.pcsUnavailable,
  frb_api.CloudSyncProtectedSafeCode.malformedResponse =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.malformedResponse,
  frb_api.CloudSyncProtectedSafeCode.continuationNoProgress =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.continuationNoProgress,
  frb_api.CloudSyncProtectedSafeCode.readAuthenticationScope =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.readAuthenticationScope,
  frb_api.CloudSyncProtectedSafeCode.nativeAuthUnavailable =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.nativeAuthUnavailable,
  frb_api.CloudSyncProtectedSafeCode.unknown =>
    CloudSyncV2ProtectedTransportSafeFailureCodes.unknown,
};
