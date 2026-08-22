import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_models.dart';

class CloudCoordinatorLeaseFence {
  const CloudCoordinatorLeaseFence({
    required this.ownerId,
    required this.generation,
  });

  final String ownerId;
  final int generation;
}

/// Durable persistence boundary for Cloud Sync V2.
///
/// Production implementations should use ObjectBox transactions for every
/// method documented as atomic. The interface intentionally carries no
/// decrypted message body or Apple credential.
abstract interface class CloudSyncStore {
  /// Returns the account-scoped checkpoint, creating an empty one if needed.
  Future<CloudSyncCheckpoint> readCheckpoint(CloudSyncScope scope);

  /// Atomically inserts unseen inbox changes, allocates their monotonically
  /// increasing sequence numbers, and advances the fetched token.
  ///
  /// A crash must commit both the journal and token, or neither.
  Future<int> journalFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  });

  /// Returns deterministic pending-journal usage for one full account scope.
  ///
  /// This is an admission gauge only. Implementations must not prune records
  /// while measuring usage.
  Future<CloudShadowJournalUsage> readShadowJournalUsage(
    CloudSyncScope scope, {
    required CloudShadowJournalBudget budget,
  });

  /// Atomically admits a read-only shadow page under [budget].
  ///
  /// On rejection, neither inbox rows nor the continuation token may change.
  /// This method never deletes old, applied, quarantined, or pending records.
  /// The commit must atomically verify [leaseFence], [expectedGeneration], and
  /// [expectedFetchedToken]. A fetch that completes after lease takeover or
  /// checkpoint advancement is a stale writer and must fail without mutation.
  Future<CloudShadowJournalAdmission> journalShadowFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudShadowJournalBudget budget,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  });

  /// Persists pull backoff so a process restart cannot create a retry storm.
  Future<void> recordPullFailure(
    CloudSyncScope scope, {
    required CloudFailureCategory category,
    required DateTime nextEligibleAt,
  });

  Future<void> recordPullSuccess(CloudSyncScope scope, {required DateTime now});

  Future<List<CloudInboxEntry>> readEligibleInbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
  });

  /// Atomically updates the journal entry and advances the checkpoint's
  /// contiguous terminal position where possible. Fallback transitions must
  /// match the exact active coordinator owner and generation. A terminal row
  /// may be repeated idempotently, but must never be regressed or replaced.
  Future<void> markInboxApplied(
    CloudSyncScope scope, {
    required int sequence,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  });

  Future<void> markInboxRetryable(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory category,
    required DateTime now,
    required DateTime nextEligibleAt,
    required CloudCoordinatorLeaseFence leaseFence,
  });

  Future<void> quarantineInbox(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory category,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  });

  /// Atomically creates or coalesces a pending save for the same logical
  /// entity. A production adapter should invoke this in the same transaction
  /// as the local semantic mutation that created it.
  Future<void> enqueueOutbox(CloudOutboxOperation operation);

  /// Production enqueue path. Allocates the per-scope mutation revision,
  /// builds the deterministic local operation ID, and persists/coalesces the
  /// operation in one transaction.
  Future<CloudOutboxOperation> enqueueOutboxMutation(CloudOutboxDraft draft);

  /// Atomically leases eligible operations. Confirmed dependencies are
  /// enforced by the store so callers cannot upload a message before its
  /// attachments.
  Future<List<CloudOutboxOperation>> leaseEligibleOutbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
    required Set<CloudOutboxAction> allowedActions,
  });

  /// Applies all per-record outcomes atomically. Every transition must match
  /// [leaseId], preventing a stale worker from confirming another run's work.
  Future<void> applyOutboxTransitions(
    CloudSyncScope scope, {
    required String leaseId,
    required Iterable<CloudOutboxTransition> transitions,
    required DateTime now,
  });

  /// Returns abandoned leases to pending state after process death.
  Future<int> recoverExpiredOutboxLeases(
    CloudSyncScope scope, {
    required DateTime now,
  });

  Future<void> attachOutboxRecordMapping(
    CloudSyncScope scope, {
    required String leaseId,
    required String operationId,
    required String serverRecordIdHash,
  });

  /// Resumes deliberately paused authorization or PCS operations only after
  /// the owning subsystem has signaled that access is healthy again.
  Future<int> resumePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
  });

  /// Returns failure categories holding paused operations whose durable retry
  /// delay has elapsed. This lets a push-only run refresh only blocked systems.
  Future<Set<CloudFailureCategory>> readPausedOutboxFailureCategories(
    CloudSyncScope scope, {
    required DateTime now,
  });

  /// Moves only currently eligible paused operations back behind a durable
  /// retry boundary after their subsystem refresh fails. Rows whose existing
  /// delay has not elapsed are left unchanged.
  Future<int> postponeEligiblePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
    required DateTime nextEligibleAt,
  });

  /// Cross-process coordinator lease. This supplements the engine's in-memory
  /// reentrancy guard and must be implemented transactionally. Renewal and
  /// release require the exact returned fence, not merely the owner string;
  /// released generations must remain unavailable to prevent same-owner ABA.
  Future<CloudCoordinatorLeaseFence?> tryAcquireCoordinatorLease(
    CloudSyncScope scope, {
    required String ownerId,
    required DateTime now,
    required Duration leaseDuration,
  });

  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  });

  Future<void> releaseCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
  });

  Future<CloudRecordMapEntry?> readRecordMap(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
  });

  Future<void> upsertRecordMap(CloudRecordMapEntry entry);

  /// Appends a bounded, content-free diagnostic run record.
  Future<void> recordRun(CloudSyncRunRecord run);
}

/// Crash-recovery metadata for native protected page blobs.
///
/// Implementations must never return a truncated set: native recovery treats
/// every lease omitted from the adopted set as abandoned and may delete its
/// blobs. Release methods are called only after native finalization succeeds.
abstract interface class CloudProtectedPageLeaseAdoptionStore {
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  });

  /// Returns every native `obcs2.ref.*` capability still referenced by
  /// ObjectBox. Applied and quarantined inbox rows remain live until a
  /// separately reviewed compaction policy explicitly removes them.
  ///
  /// A truncated result must set [CloudProtectedReferenceSnapshot.isComplete]
  /// to false. Native recovery and garbage collection fail closed on an
  /// incomplete snapshot.
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  });

  Future<void> releaseAdoptedProtectedPageLeaseReferences(
    Iterable<String> leaseReferences,
  );
}

final class CloudProtectedReferenceSnapshot {
  CloudProtectedReferenceSnapshot({
    required Iterable<String> references,
    required this.isComplete,
  }) : references = Set.unmodifiable(references.toSet());

  final Set<String> references;
  final bool isComplete;
}

enum CloudOutboxTransitionType { confirmed, retryable, paused, quarantined }

class CloudOutboxTransition {
  const CloudOutboxTransition._({
    required this.operationId,
    required this.type,
    this.category,
    this.nextEligibleAt,
    this.encryptedPayloadReference,
    this.payloadSha256,
    this.serverRecordIdHash,
  });

  const CloudOutboxTransition.confirmed(String operationId)
    : this._(
        operationId: operationId,
        type: CloudOutboxTransitionType.confirmed,
      );

  const CloudOutboxTransition.retryable(
    String operationId, {
    required CloudFailureCategory category,
    required DateTime nextEligibleAt,
    String? encryptedPayloadReference,
    String? payloadSha256,
    String? serverRecordIdHash,
  }) : this._(
         operationId: operationId,
         type: CloudOutboxTransitionType.retryable,
         category: category,
         nextEligibleAt: nextEligibleAt,
         encryptedPayloadReference: encryptedPayloadReference,
         payloadSha256: payloadSha256,
         serverRecordIdHash: serverRecordIdHash,
       );

  const CloudOutboxTransition.paused(
    String operationId, {
    required CloudFailureCategory category,
    DateTime? nextEligibleAt,
  }) : this._(
         operationId: operationId,
         type: CloudOutboxTransitionType.paused,
         category: category,
         nextEligibleAt: nextEligibleAt,
       );

  const CloudOutboxTransition.quarantined(
    String operationId, {
    required CloudFailureCategory category,
  }) : this._(
         operationId: operationId,
         type: CloudOutboxTransitionType.quarantined,
         category: category,
       );

  final String operationId;
  final CloudOutboxTransitionType type;
  final CloudFailureCategory? category;
  final DateTime? nextEligibleAt;
  final String? encryptedPayloadReference;
  final String? payloadSha256;
  final String? serverRecordIdHash;
}
