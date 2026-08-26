import 'dart:async';

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;

import 'cloud_operation_identity.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_write_transport.dart';

const int _maximumChangesPerPage = 200;
const int _maximumProtectedReferencesPerLease =
    (_maximumChangesPerPage * 2) + 1;
const int _maximumAdmittedRawPageBytes = 24 * 1024 * 1024;
const int _maximumRecoveryReferences = 4096;
const int _maximumRecoveryResultsPerPass = 64;
const int _maximumLiveProtectedReferences = 131072;
const int _maximumGarbageCollectionResultsPerPass = 64;
const int _maximumProtectedStoreOperationsPerIdentity = 64;
const int _maximumRetryAfterSeconds = 7 * 24 * 60 * 60;

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
  });

  final NativeProtectedFailureCategory category;
  final String safeCode;
  final int? retryAfterSeconds;
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

final class _NativeCloudSyncPreparedSubmission
    extends CloudSyncPreparedSubmission {
  // Named superclass construction keeps the native handle explicit here.
  // ignore: use_super_parameters
  _NativeCloudSyncPreparedSubmission({
    required CloudSyncScope scope,
    required CloudOutboxSubmissionIdentity identity,
    required List<CloudSyncProtectedWriteOperation> operations,
    required this.handle,
  }) : super.fromProtectedPreflight(
         scope: scope,
         identity: identity,
         operations: operations,
       );

  final frb_api.CloudSyncPreparedMessageCreateHandle handle;
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
        CloudSyncOutboundStagingTransport,
        CloudSyncWriteTransport,
        CloudSyncWriteReceiptFinalizer,
        CloudSyncNativeOperationQuiescence {
  NativeProtectedCloudSyncTransport({
    required this._cloudMessagesClient,
    required String storageDirectory,
    required String protectedStoreIdentity,
    NativeProtectedCloudSyncBindings? bindings,
    this._refreshAuthentication,
    this._refreshPcsAccess,
  }) : _storageDirectory = storageDirectory,
       _protectedStoreIdentity = protectedStoreIdentity,
       _bindings = bindings ?? FrbNativeProtectedCloudSyncBindings() {
    if (storageDirectory.isEmpty) {
      throw ArgumentError.value(storageDirectory, 'storageDirectory');
    }
    if (!_nativeStoreIdentityPattern.hasMatch(protectedStoreIdentity)) {
      throw ArgumentError('protected_store_identity_invalid');
    }
  }

  final Object _cloudMessagesClient;
  final String _storageDirectory;
  final String _protectedStoreIdentity;
  final NativeProtectedCloudSyncBindings _bindings;
  final Future<bool> Function(CloudSyncScope scope)? _refreshAuthentication;
  final Future<bool> Function(CloudSyncScope scope)? _refreshPcsAccess;
  final Set<Future<void>> _activeNativeOperations = {};
  Future<void>? _nativeQuiescence;
  bool _nativeAdmissionClosed = false;

  @override
  String get protectedPageLeaseRecoveryIdentity => _protectedStoreIdentity;

  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      runProtectedStoreExclusive(action);

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
  Future<void> quiesceNativeOperations() {
    _nativeAdmissionClosed = true;
    return _nativeQuiescence ??= _waitForNativeQuiescence();
  }

  NativeProtectedCloudSyncWriteBindings _requireWriteBindings() {
    final bindings = _bindings;
    if (bindings is! NativeProtectedCloudSyncWriteBindings) {
      throw _readOnlyFailure();
    }
    return bindings as NativeProtectedCloudSyncWriteBindings;
  }

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  }) async {
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
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) => commitProtectedPageLease(leaseReference, {protectedEnvelopeReference});

  @override
  Future<void> rollbackOutboundLease(String leaseReference) =>
      rollbackProtectedPageLease(leaseReference);

  @override
  Future<CloudSyncPreparedSubmission> prepareSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required List<CloudSyncProtectedWriteOperation> operations,
  }) async {
    _validateOutboundMessageScope(scope);
    if (operations.isEmpty ||
        operations.length > _maximumChangesPerPage ||
        operations.any(
          (operation) =>
              operation.action != CloudOutboxAction.save ||
              !_isInitialCreateOperationIdentity(
                scope,
                operationId: operation.operationId,
                logicalEntityKeyHash: operation.logicalEntityKeyHash,
                payloadVersion: 1,
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
    final result = await _runProtectedStoreOperation(
      () => _requireWriteBindings().prepareMessageCreate(
        cloudMessagesClient: _cloudMessagesClient,
        storageDirectory: _storageDirectory,
        expectedAccountFingerprint: scope.accountFingerprint,
        expectedProtectedStoreIdentity: _protectedStoreIdentity,
        requestUuid: submissionIdentity.requestUuid,
        requestTimeout: const Duration(seconds: 45),
        inputs: operations
            .map(
              (operation) => frb_api.CloudSyncPreparedMessageCreateInput(
                localOperationId: operation.operationId,
                logicalEntityKeyHash: operation.logicalEntityKeyHash,
                protectedLeaseReference: operation.protectedLeaseReference!,
                protectedPayloadReference: operation.protectedPayloadReference!,
                payloadSha256: operation.payloadSha256!,
                protectedServerRecordReference:
                    operation.protectedServerRecordIdReference,
                serverRecordIdHash: operation.serverRecordIdHash,
                appleOperationUuid:
                    submissionIdentity.operationUuids[operation.operationId]!,
              ),
            )
            .toList(growable: false),
      ),
    );
    if ((result.handle == null) == (result.failure == null)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'cloud_sync_outbound_prepare_envelope_invalid',
      );
    }
    if (result.failure case final failure?) {
      throw _mapOutboundFailure(failure);
    }
    return _NativeCloudSyncPreparedSubmission(
      scope: scope,
      identity: submissionIdentity,
      operations: operations,
      handle: result.handle!,
    );
  }

  @override
  Future<CloudPushBatchResult> consumePreparedSubmission(
    CloudSyncScope scope, {
    required CloudSyncPreparedSubmission preparedSubmission,
    required CloudOutboxSubmissionIdentity persistedIdentity,
    required List<CloudSyncProtectedWriteOperation> protectedOperations,
    required List<CloudOutboxOperation> operations,
  }) async {
    _validateOutboundMessageScope(scope);
    if (preparedSubmission is! _NativeCloudSyncPreparedSubmission) {
      throw ArgumentError('cloud_sync_native_prepared_submission_required');
    }
    preparedSubmission.claimForConsumption(
      scope,
      persistedIdentity: persistedIdentity,
      protectedOperations: protectedOperations,
    );
    final result = await _runProtectedStoreOperation(
      () => _requireWriteBindings().consumePreparedMessageCreate(
        handle: preparedSubmission.handle,
      ),
    );
    if (result.failure case final failure?) {
      throw _mapOutboundFailure(failure);
    }
    if (result.outcomes.length != operations.length) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'cloud_sync_outbound_correlation_mismatch',
      );
    }
    final outcomes = <CloudPushOutcome>[];
    final seen = <String>{};
    for (final outcome in result.outcomes) {
      if (!seen.add(outcome.localOperationId) ||
          persistedIdentity.operationUuids[outcome.localOperationId] !=
              outcome.appleOperationUuid) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.unknown,
          safeCode: 'cloud_sync_outbound_correlation_mismatch',
        );
      }
      outcomes.add(_mapOutboundOutcome(outcome));
    }
    return CloudPushBatchResult(outcomes: outcomes);
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
      frb_api.CloudSyncOutboundSafeCode.correlationMismatch =>
        CloudFailureCategory.unknown,
      _ => CloudFailureCategory.cancelled,
    };
    return CloudSyncFailure(
      category: category,
      safeCode: 'cloud_sync_outbound_${failure.name}',
    );
  }

  CloudPushOutcome _mapOutboundOutcome(
    frb_api.CloudSyncOutboundSaveOutcome outcome,
  ) {
    final retryAfter = _boundedRetryAfter(outcome.retryAfterSeconds);
    return switch (outcome.disposition) {
      frb_api.CloudSyncOutboundSaveDisposition.succeeded => CloudPushOutcome(
        operationId: outcome.localOperationId,
        disposition: CloudPushDisposition.confirmed,
      ),
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
        disposition: CloudPushDisposition.serverRecordChanged,
        failureCategory: CloudFailureCategory.conflict,
      ),
      frb_api.CloudSyncOutboundFailureClass.resetRequired => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.pcsUnavailable,
        failureCategory: CloudFailureCategory.pcsUnavailable,
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
        .where(
          (transition) =>
              transition.type == CloudOutboxTransitionType.confirmed ||
              transition.type == CloudOutboxTransitionType.quarantined,
        )
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
    final result = await _runProtectedStoreOperation(
      () => _bindings.fetchProtectedPage(
        cloudMessagesClient: _cloudMessagesClient,
        storageDirectory: _storageDirectory,
        expectedAccountFingerprint: scope.accountFingerprint,
        stream: stream,
        generation: generation,
        previousCheckpointReference: previousToken,
        maximumChanges: maximumChanges,
      ),
    );
    final page = result.page;
    final failure = result.failure;
    if ((page == null) == (failure == null)) {
      throw _malformed('invalid_protected_fetch_envelope');
    }
    if (failure != null) throw _mapFailure(failure);
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
      CloudFailureCategory.pcsUnavailable,
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

  CloudSyncFailure _mapFailure(NativeProtectedFailure failure) {
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
    return CloudSyncFailure(
      category: category,
      retryAfter: retryAfter,
      safeCode: failure.safeCode,
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
    _validateOutboundMessageScope(scope);
    final payloadReference = operation.encryptedPayloadReference;
    final payloadSha256 = operation.payloadSha256;
    final serverRecordIdHash = operation.serverRecordIdHash;
    final leaseReference = operation.protectedLeaseReference;
    final requestUuid = operation.appleRequestUuid;
    final operationUuid = operation.appleOperationUuid;
    if (operation.scope != scope ||
        operation.status != CloudOutboxStatus.unknownOutcome ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != 1 ||
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
      throw _localStorage('cloud_sync_outbound_reconcile_operation_invalid');
    }

    final result = await _runProtectedStoreOperation(
      () => _requireWriteBindings().reconcileMessageCreate(
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
        ),
      ),
    );
    if (result.failure case final failure?) {
      if (result.disposition != null ||
          result.protectedProofReference != null ||
          result.failureClass != null ||
          result.retryAfterSeconds != null) {
        throw _localStorage('cloud_sync_outbound_reconcile_envelope_invalid');
      }
      throw _mapOutboundFailure(failure);
    }
    final disposition = result.disposition;
    if (disposition == null) {
      throw _localStorage('cloud_sync_outbound_reconcile_envelope_invalid');
    }
    final decisive =
        disposition != frb_api.CloudSyncOutboundReconcileDisposition.unresolved;
    if ((decisive && result.protectedProofReference != payloadReference) ||
        (!decisive && result.protectedProofReference != null) ||
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
      throw _localStorage('cloud_sync_outbound_reconcile_envelope_invalid');
    }

    CloudUnknownOutcomeProof proof() => CloudUnknownOutcomeProof(
      operationId: operation.operationId,
      appleRequestUuid: requestUuid,
      appleOperationUuid: operationUuid,
      scopeStorageKey: scope.storageKey,
      checkpointGeneration: operation.checkpointGeneration,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: serverRecordIdHash,
      action: operation.action,
      expectedPayloadSha256: payloadSha256,
      protectedProofReference: result.protectedProofReference!,
    );

    return switch (disposition) {
      frb_api.CloudSyncOutboundReconcileDisposition.committed =>
        CloudUnknownOutcomeResolution.committed(proof: proof()),
      frb_api.CloudSyncOutboundReconcileDisposition.notApplied =>
        CloudUnknownOutcomeResolution.notApplied(proof: proof()),
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
        NativeProtectedCloudSyncWriteBindings {
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
  }) => _api.crateApiApiCloudSyncConsumePreparedMessageCreate(handle: handle);

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
      safeCode: _safeCode(failure.safeCode),
      retryAfterSeconds: failure.retryAfterSeconds?.toInt(),
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

  String _safeCode(frb_api.CloudSyncProtectedSafeCode code) => switch (code) {
    frb_api.CloudSyncProtectedSafeCode.invalidScope => 'invalid_scope',
    frb_api.CloudSyncProtectedSafeCode.invalidRequest => 'invalid_request',
    frb_api.CloudSyncProtectedSafeCode.invalidCheckpoint =>
      'invalid_checkpoint',
    frb_api.CloudSyncProtectedSafeCode.checkpointContextMismatch =>
      'checkpoint_context_mismatch',
    frb_api.CloudSyncProtectedSafeCode.oversizedPage => 'oversized_page',
    frb_api.CloudSyncProtectedSafeCode.oversizedRecord => 'oversized_record',
    frb_api.CloudSyncProtectedSafeCode.protectionFailed => 'protection_failed',
    frb_api.CloudSyncProtectedSafeCode.localStoreFailed => 'local_store_failed',
    frb_api.CloudSyncProtectedSafeCode.fetchDeadline => 'fetch_deadline',
    frb_api.CloudSyncProtectedSafeCode.network => 'network',
    frb_api.CloudSyncProtectedSafeCode.cloudKitThrottled =>
      'cloudkit_throttled',
    frb_api.CloudSyncProtectedSafeCode.cloudKitServer => 'cloudkit_server',
    frb_api.CloudSyncProtectedSafeCode.cloudKitAuthorization =>
      'cloudkit_authorization',
    frb_api.CloudSyncProtectedSafeCode.cloudKitConflict => 'cloudkit_conflict',
    frb_api.CloudSyncProtectedSafeCode.cloudKitResetRequired =>
      'cloudkit_reset_required',
    frb_api.CloudSyncProtectedSafeCode.cloudKitPermanent =>
      'cloudkit_permanent',
    frb_api.CloudSyncProtectedSafeCode.cloudKitUnknown => 'cloudkit_unknown',
    frb_api.CloudSyncProtectedSafeCode.httpAuthorization =>
      'http_authorization',
    frb_api.CloudSyncProtectedSafeCode.httpTimeout => 'http_timeout',
    frb_api.CloudSyncProtectedSafeCode.httpThrottled => 'http_throttled',
    frb_api.CloudSyncProtectedSafeCode.httpServer => 'http_server',
    frb_api.CloudSyncProtectedSafeCode.httpUnknown => 'http_unknown',
    frb_api.CloudSyncProtectedSafeCode.pcsUnavailable => 'pcs_unavailable',
    frb_api.CloudSyncProtectedSafeCode.malformedResponse =>
      'malformed_response',
    frb_api.CloudSyncProtectedSafeCode.continuationNoProgress =>
      'continuation_no_progress',
    frb_api.CloudSyncProtectedSafeCode.nativeAuthUnavailable =>
      'native_auth_unavailable',
    frb_api.CloudSyncProtectedSafeCode.unknown => 'unknown',
  };
}
