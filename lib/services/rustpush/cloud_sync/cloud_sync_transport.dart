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

  /// Must return one explicit outcome per attempted operation. The engine
  /// treats omitted outcomes as retryable failures.
  Future<CloudPushBatchResult> pushOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
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
