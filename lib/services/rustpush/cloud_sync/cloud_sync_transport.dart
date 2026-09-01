import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';

/// Apple protocol and cryptography boundary.
///
/// The Rust adapter is responsible for authentication, PCS, encryption, and
/// translating private CloudKit responses into the typed envelopes below.
abstract interface class CloudSyncTransport {
  Future<CloudFetchBatch> fetchChanges(
    CloudSyncScope scope, {
    required String? previousToken,
    required int generation,
    required int limit,
  });

  /// Must return one explicit outcome per attempted operation. An omitted,
  /// extra, or otherwise untrustworthy outcome set is ambiguous and remains
  /// frozen until server-state reconciliation proves what CloudKit committed.
  Future<CloudPushBatchResult> pushOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
  });

  /// Reads the current server record after an ambiguous write and compares it
  /// with the protected desired payload. `notApplied` may be returned only
  /// when the read proves that replaying this stable record operation cannot
  /// duplicate a committed mutation.
  Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  });

  /// Performs at most one credential refresh when requested by an engine run.
  Future<bool> refreshAuthentication(CloudSyncScope scope);

  /// Performs at most one PCS/clique refresh when requested by an engine run.
  Future<bool> refreshPcsAccess(CloudSyncScope scope);

  /// Allocates a cryptographically random Apple server record ID and returns
  /// its protected mapping. Local operation IDs are deterministic; Apple
  /// server record IDs are not.
  Future<CloudRecordMapEntry> allocateServerRecordMapping(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
  });

  /// Fetches the newer server record, semantically merges it, and prepares the
  /// existing local operation for retry after a server-record-changed result.
  Future<CloudServerConflictResolution> reconcileServerRecordChanged(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  });
}

/// Native protected-page crash lifecycle.
///
/// Implementations accept only opaque `obcs2.lease.*` references. Recovery
/// must complete before a fetch starts whenever the shared process barrier is
/// not valid, using the complete durable adoption and protected-reference
/// liveness sets from [CloudProtectedPageLeaseAdoptionStore].
abstract interface class CloudProtectedPageLeaseTransport {
  /// Stable, non-reversible identity for the native protected store.
  ///
  /// Recovery coordination uses this value across independently-created Dart
  /// wrappers. It must never contain a filesystem path.
  String get protectedPageLeaseRecoveryIdentity;

  /// Serializes one complete protected-store lifecycle for this native store.
  ///
  /// Calls made by [action] into this same transport identity are reentrant.
  /// A caller should use this around fetch, durable adoption, and native
  /// commit/rollback as one unit so recovery or maintenance cannot enter the
  /// crash window between those steps.
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action);

  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adoptedLeaseReferences,
    CloudProtectedReferenceSnapshot liveReferences,
  );

  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  );

  Future<void> acknowledgeCommittedPageLease(String leaseReference);

  Future<void> rollbackProtectedPageLease(String leaseReference);

  Future<int> retireProtectedReferences(Set<String> references);

  Future<CloudProtectedGarbageCollectionResult> collectProtectedGarbage(
    CloudProtectedReferenceSnapshot liveReferences,
  );
}

/// Join boundary for native operations that may outlive a Dart timeout wrapper.
///
/// Owners must await this before releasing credentials, native clients, or the
/// cross-process CloudKit interlock.
abstract interface class CloudSyncNativeOperationQuiescence {
  Future<void> quiesceNativeOperations();
}

/// Lets a read-only guard expose an underlying protected lifecycle without
/// weakening the guard's [CloudSyncTransport] fetch boundary.
abstract interface class CloudProtectedPageLeaseTransportProvider {
  CloudProtectedPageLeaseTransport? get protectedPageLeaseTransport;
}

final class CloudProtectedPageLeaseRecoveryResult {
  CloudProtectedPageLeaseRecoveryResult({
    required Iterable<String> finalizedAdoptedLeaseReferences,
    Iterable<String> absentAdoptedLeaseReferences = const [],
    this.rolledBackCount = 0,
    this.removedTemporaryFilesCount = 0,
    required this.hasMore,
  }) : finalizedAdoptedLeaseReferences = Set.unmodifiable(
         finalizedAdoptedLeaseReferences.toSet(),
       ),
       absentAdoptedLeaseReferences = Set.unmodifiable(
         absentAdoptedLeaseReferences.toSet(),
       );

  final Set<String> finalizedAdoptedLeaseReferences;
  final Set<String> absentAdoptedLeaseReferences;
  final int rolledBackCount;
  final int removedTemporaryFilesCount;
  final bool hasMore;
}

final class CloudProtectedGarbageCollectionResult {
  const CloudProtectedGarbageCollectionResult({
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

/// Shared semantic-upsert boundary used by both IDS and CloudKit.
///
/// Implementations decrypt the protected payload reference within the Rust /
/// keystore boundary and commit the local mutation before returning `applied`.
abstract interface class CloudInboxApplier {
  Future<CloudInboxApplyResult> apply(
    CloudInboxEntry entry, {
    required CloudCoordinatorLeaseFence leaseFence,
  });
}

/// Optional local-only recovery surface for durable source records that were
/// retained after the transport cursor advanced but were never projected into
/// the canonical store.
///
/// Implementations must not fetch, write CloudKit, apply tombstones, or mutate
/// checkpoint tokens. A row may leave [CloudInboxStatus.retainedUnprojected]
/// only in the same transaction that commits its complete local projection.
abstract interface class CloudRetainedProjectionReprocessor {
  Future<CloudRetainedProjectionResult> reprojectRetainedUnprojected({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  });
}

/// Local-only, cursor-bounded replay for retained save rows that existed when
/// the caller proved a terminal CloudKit head.
///
/// Unlike [CloudRetainedProjectionReprocessor], this capability never rotates
/// failed rows back into the current sweep. A successful sweep therefore
/// examines every retained save in the immutable sequence bound at most once,
/// without constructing a transport or entering the engine fetch pipeline.
abstract interface class CloudRetainedProjectionWindowReprocessor {
  Future<CloudRetainedProjectionWindowResult> reprojectRetainedSaveWindow({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int afterFetchSequence,
    required int throughFetchSequence,
    required int limit,
  });
}

final class CloudRetainedProjectionResult {
  const CloudRetainedProjectionResult({
    required this.examined,
    required this.reprojected,
    required this.retained,
    bool? hasRemaining,
  }) : assert(examined >= 0),
       assert(reprojected >= 0),
       assert(retained >= 0),
       assert(examined == reprojected + retained),
       hasRemaining = hasRemaining ?? retained > 0;

  final int examined;
  final int reprojected;
  final int retained;

  /// True when at least one replayable retained save row still awaits local
  /// projection, including rows beyond this run's bounded candidate window.
  /// Non-save retained debt is accounted by the engine's full backlog read.
  final bool hasRemaining;
}

final class CloudRetainedProjectionWindowResult {
  const CloudRetainedProjectionWindowResult({
    required this.examined,
    required this.reprojected,
    required this.retained,
    required this.lastExaminedSequence,
    required this.hasMoreWithinBound,
  }) : assert(examined >= 0),
       assert(reprojected >= 0),
       assert(retained >= 0),
       assert(examined == reprojected + retained),
       assert(lastExaminedSequence >= 0),
       assert(examined > 0 || !hasMoreWithinBound);

  final int examined;
  final int reprojected;
  final int retained;

  /// Sequence cursor for the next window. It is content-free and is never
  /// emitted in a persisted report.
  final int lastExaminedSequence;
  final bool hasMoreWithinBound;
}

/// Optional semantic policy exposed to the engine for legacy recovery only.
///
/// A current read-only applier can acknowledge a protected CloudKit tombstone
/// without decoding it or deleting canonical state. The store uses this
/// capability only to repair checkpoints written by an older build that had
/// already advanced its applied floor across quarantined tombstones.
abstract interface class CloudReadOnlyTombstoneAcknowledgementPolicy {
  bool get readOnlyTombstoneAcknowledgementsEnabled;
}

enum CloudServerConflictDisposition { mergedForRetry, retryable, quarantined }

class CloudServerConflictResolution {
  const CloudServerConflictResolution._({
    required this.disposition,
    this.encryptedPayloadReference,
    this.payloadSha256,
    this.serverRecordIdHash,
    this.retryAfter,
    this.failureCategory,
    this.encryptedRawRecordReference,
    this.etagHash,
  });

  const CloudServerConflictResolution.mergedForRetry({
    required String encryptedPayloadReference,
    required String payloadSha256,
    required String serverRecordIdHash,
    required String encryptedRawRecordReference,
    String? etagHash,
  }) : this._(
         disposition: CloudServerConflictDisposition.mergedForRetry,
         encryptedPayloadReference: encryptedPayloadReference,
         payloadSha256: payloadSha256,
         serverRecordIdHash: serverRecordIdHash,
         encryptedRawRecordReference: encryptedRawRecordReference,
         etagHash: etagHash,
         failureCategory: CloudFailureCategory.conflict,
       );

  const CloudServerConflictResolution.retryable({
    required CloudFailureCategory failureCategory,
    Duration? retryAfter,
  }) : this._(
         disposition: CloudServerConflictDisposition.retryable,
         failureCategory: failureCategory,
         retryAfter: retryAfter,
       );

  const CloudServerConflictResolution.quarantined({
    required CloudFailureCategory failureCategory,
  }) : this._(
         disposition: CloudServerConflictDisposition.quarantined,
         failureCategory: failureCategory,
       );

  final CloudServerConflictDisposition disposition;
  final String? encryptedPayloadReference;
  final String? payloadSha256;
  final String? serverRecordIdHash;
  final Duration? retryAfter;
  final CloudFailureCategory? failureCategory;
  final String? encryptedRawRecordReference;
  final String? etagHash;
}
