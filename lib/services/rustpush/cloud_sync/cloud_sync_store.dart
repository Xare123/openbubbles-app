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

  /// Atomically inserts unseen inbox changes and allocates their monotonically
  /// increasing sequence numbers. For a non-empty semantic page, the new
  /// continuation token is held as pending until the complete journal is
  /// durably terminal. Retained-unprojected rows are terminal for fetch
  /// progress but do not advance the exact-applied projection floor;
  /// quarantined rows remain barriers.
  ///
  /// A crash must commit the journal and its pending-token state together.
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
  /// contiguous applied position where possible. Fallback transitions must
  /// match the exact active coordinator owner and generation. An applied row
  /// may be repeated idempotently, but must never be regressed or replaced.
  Future<void> markInboxApplied(
    CloudSyncScope scope, {
    required int sequence,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  });

  /// Marks one protected inbox row as locally retained but unprojected. This
  /// is a terminal local disposition only: it must preserve the protected raw
  /// record and must not mutate canonical state or contact CloudKit.
  Future<void> markInboxRetainedUnprojected(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory? category,
    required DateTime now,
    required int maximumDeferredAttempts,
    required Duration maximumDeferredAge,
    required CloudCoordinatorLeaseFence leaseFence,
  });

  /// Reconciles legacy quarantine barriers created by builds that committed a
  /// CloudKit token before persisting an explicit local terminal disposition.
  /// Implementations must validate a complete, unambiguous current-generation
  /// journal before changing any status and must retain every protected row.
  Future<CloudInboxRetentionRecovery> recoverRetainedInboxBarriers(
    CloudSyncScope scope, {
    required DateTime now,
    required int maximumDeferredAttempts,
    required Duration maximumDeferredAge,
    required CloudCoordinatorLeaseFence leaseFence,
    bool allowLegacyReadOnlyTombstoneAcknowledgement = false,
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

  /// Atomically starts a new reset generation.
  ///
  /// The transaction fences every old-generation outbox operation and record
  /// mapping, preserves old inbox evidence outside the active generation,
  /// clears the continuation/checkpoint sequencing and pull backoff state,
  /// and returns a proof tied to the exact request. No network or protected
  /// reference resolution is permitted while the transaction is open.
  Future<CloudSyncResetCompletionProof> rebootstrapAfterReset(
    CloudSyncResetRebootstrapRequest request, {
    required DateTime now,
  });

  /// Atomically advances the account/scope checkpoint generation and fences
  /// every non-terminal outbox row admitted under an older generation.
  ///
  /// This is the required rebootstrap boundary for account-reset recovery.
  /// Fenced rows are terminal and cannot lease, block later work, attach a
  /// record map, or accept a late transition.
  ///
  /// The advance fails while the exact scope has an active coordinator lease.
  /// A reset must first quiesce and release the writer coordinator, which
  /// closes the race where an already-leased operation reaches CloudKit after
  /// its local generation has been fenced.
  Future<CloudSyncCheckpoint> advanceOutboxGeneration(
    CloudSyncScope scope, {
    required DateTime now,
  });

  /// Atomically leases eligible operations. Confirmed dependencies are
  /// enforced by the store so callers cannot upload a message before its
  /// attachments.
  ///
  /// This method is the outbound checkpoint safety boundary. In the same
  /// transaction or critical section that changes a row to `leased`, an
  /// implementation must reject with `checkpoint_pending_page_unresolved`
  /// whenever the scope has both a non-terminal outbox row and either a
  /// pending page or unmarked pending inbox evidence. A separate presence or
  /// checkpoint probe is only an early-exit optimization and cannot satisfy
  /// this invariant.
  Future<List<CloudOutboxOperation>> leaseEligibleOutbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
    required Set<CloudOutboxAction> allowedActions,
  });

  /// Marks rows as having been submitted before the remote request begins.
  ///
  /// This is a crash-safety boundary: the rows become non-leasable while the
  /// original live lease is retained, so a process restart cannot replay an
  /// ambiguous submission as a fresh upload. A returned remote response may
  /// still resolve the rows through [applyOutboxTransitions].
  Future<List<CloudOutboxOperation>> markOutboxSubmissionStarted(
    CloudSyncScope scope, {
    required String leaseId,
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required DateTime now,
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
    required DateTime now,
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
    required int generation,
  });

  Future<void> upsertRecordMap(
    CloudRecordMapEntry entry, {
    required int generation,
  });

  /// Appends a bounded, content-free diagnostic run record.
  Future<void> recordRun(CloudSyncRunRecord run);
}

/// Read-only capability for reporting the current durable semantic backlog.
///
/// This is a state snapshot, not the number of rows newly retained by the
/// current run. Implementations must scope it to the active checkpoint
/// generation and must not project, delete, or mutate retained rows.
abstract interface class CloudRetainedUnprojectedBacklogStore {
  Future<int> readRetainedUnprojectedInboxCount(CloudSyncScope scope);
}

/// Narrow, local-only migration surface for retrying an unknown semantic
/// quarantine created by an older decoder build.
///
/// Implementations may reopen only the first unresolved current-generation
/// save row, must require the active coordinator fence, and must not alter a
/// checkpoint, protected reference, payload digest, or remote CloudKit state.
abstract interface class CloudUnknownInboxBarrierRecoveryStore {
  Future<bool> requeueUnknownInboxBarrier(
    CloudSyncScope scope, {
    required DateTime now,
    required DateTime quarantinedBefore,
    required CloudCoordinatorLeaseFence leaseFence,
  });
}

/// Optional outbox capability used by the reconciliation worker.
///
/// The read-only shadow wrapper deliberately does not expose this mutation
/// surface. Keeping it as a capability instead of adding it to
/// [CloudSyncStore] preserves that compile-time restriction while still
/// allowing production stores to share the same leasing contract.
abstract interface class CloudSyncUnknownOutcomeLeasingStore {
  /// Atomically leases current-generation unknown-outcome rows that are due.
  ///
  /// A live lease is never taken over. An expired lease may be replaced. The
  /// rows remain [CloudOutboxStatus.unknownOutcome] for the entire operation.
  Future<List<CloudOutboxOperation>> leaseUnknownOutcomes(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
  });
}

/// Read-only optimization used to avoid entering an outbound path when a
/// semantic checkpoint is known to contain an unresolved page.
///
/// This probe is deliberately not a write-safety boundary. Implementations of
/// [CloudSyncStore.leaseEligibleOutbox] must independently enforce the atomic
/// checkpoint fence documented on that method.
abstract interface class CloudSyncOutboxPresenceStore {
  Future<bool> hasNonterminalOutbox(CloudSyncScope scope);
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

/// Optional capability for native protected leases owned by non-terminal
/// outbound operations. These are intentionally separate from page leases so
/// page cleanup can never acknowledge an outbox receipt prematurely.
abstract interface class CloudProtectedOutboundLeaseAdoptionStore {
  Future<Set<String>> readNonterminalProtectedOutboundLeaseReferences({
    required int maximumCount,
  });
}

final class CloudProtectedReferenceSnapshot {
  CloudProtectedReferenceSnapshot({
    required Iterable<String> references,
    required this.isComplete,
  }) : references = Set.unmodifiable(references.toSet());

  final Set<String> references;
  final bool isComplete;
}

enum CloudOutboxTransitionType {
  confirmed,
  retryable,
  paused,
  quarantined,
  unknownOutcome,
}

class CloudOutboxTransition {
  const CloudOutboxTransition._({
    required this.operationId,
    required this.type,
    this.category,
    this.nextEligibleAt,
    this.encryptedPayloadReference,
    this.payloadSha256,
    this.serverRecordIdHash,
    this.clearSubmissionIdentity = false,
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

  /// Opens a new submission attempt only after authoritative reconciliation
  /// proved that the prior identified request did not commit this operation.
  const CloudOutboxTransition.provenNotApplied(
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
         clearSubmissionIdentity: true,
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

  /// Pauses for credential or PCS recovery after an authoritative response
  /// proved that the prior identified operation was not committed.
  const CloudOutboxTransition.provenNotAppliedPaused(
    String operationId, {
    required CloudFailureCategory category,
    DateTime? nextEligibleAt,
  }) : this._(
         operationId: operationId,
         type: CloudOutboxTransitionType.paused,
         category: category,
         nextEligibleAt: nextEligibleAt,
         clearSubmissionIdentity: true,
       );

  const CloudOutboxTransition.quarantined(
    String operationId, {
    required CloudFailureCategory category,
  }) : this._(
         operationId: operationId,
         type: CloudOutboxTransitionType.quarantined,
         category: category,
       );

  const CloudOutboxTransition.unknownOutcome(
    String operationId, {
    DateTime? nextEligibleAt,
  }) : this._(
         operationId: operationId,
         type: CloudOutboxTransitionType.unknownOutcome,
         category: CloudFailureCategory.unknown,
         nextEligibleAt: nextEligibleAt,
       );

  final String operationId;
  final CloudOutboxTransitionType type;
  final CloudFailureCategory? category;
  final DateTime? nextEligibleAt;
  final String? encryptedPayloadReference;
  final String? payloadSha256;
  final String? serverRecordIdHash;
  final bool clearSubmissionIdentity;
}
