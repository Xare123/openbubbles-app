import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';

/// Capability-restricted store exposed to the V2 read-only shadow sampler.
///
/// The delegate can durably journal protected raw pages and maintain its
/// checkpoint/lease diagnostics. Every semantic, record-map, or outbox method
/// fails closed even if a future engine regression attempts to call it while
/// the feature flags still claim to be read-only.
final class ShadowOnlyCloudSyncStore
    implements CloudSyncStore, CloudProtectedPageLeaseAdoptionStore {
  const ShadowOnlyCloudSyncStore(this._delegate);

  final CloudSyncStore _delegate;

  CloudProtectedPageLeaseAdoptionStore get _adoptionStore {
    final delegate = _delegate;
    if (delegate is CloudProtectedPageLeaseAdoptionStore) {
      return delegate as CloudProtectedPageLeaseAdoptionStore;
    }
    throw CloudSyncFailure(
      category: CloudFailureCategory.localStorage,
      safeCode: 'protected_page_lease_adoption_store_unavailable',
    );
  }

  @override
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  }) => _adoptionStore.readAdoptedProtectedPageLeaseReferences(
    maximumCount: maximumCount,
  );

  @override
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  }) => _adoptionStore.readLiveProtectedReferences(maximumCount: maximumCount);

  @override
  Future<void> releaseAdoptedProtectedPageLeaseReferences(
    Iterable<String> leaseReferences,
  ) => _adoptionStore.releaseAdoptedProtectedPageLeaseReferences(
    leaseReferences,
  );

  @override
  Future<CloudSyncCheckpoint> readCheckpoint(CloudSyncScope scope) =>
      _delegate.readCheckpoint(scope);

  @override
  Future<CloudShadowJournalUsage> readShadowJournalUsage(
    CloudSyncScope scope, {
    required CloudShadowJournalBudget budget,
  }) => _delegate.readShadowJournalUsage(scope, budget: budget);

  @override
  Future<CloudShadowJournalAdmission> journalShadowFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudShadowJournalBudget budget,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  }) => _delegate.journalShadowFetchedBatch(
    batch,
    now: now,
    budget: budget,
    leaseFence: leaseFence,
    expectedGeneration: expectedGeneration,
    expectedFetchedToken: expectedFetchedToken,
  );

  @override
  Future<void> recordPullFailure(
    CloudSyncScope scope, {
    required CloudFailureCategory category,
    required DateTime nextEligibleAt,
  }) => _delegate.recordPullFailure(
    scope,
    category: category,
    nextEligibleAt: nextEligibleAt,
  );

  @override
  Future<void> recordPullSuccess(
    CloudSyncScope scope, {
    required DateTime now,
  }) => _delegate.recordPullSuccess(scope, now: now);

  @override
  Future<CloudCoordinatorLeaseFence?> tryAcquireCoordinatorLease(
    CloudSyncScope scope, {
    required String ownerId,
    required DateTime now,
    required Duration leaseDuration,
  }) => _delegate.tryAcquireCoordinatorLease(
    scope,
    ownerId: ownerId,
    now: now,
    leaseDuration: leaseDuration,
  );

  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) => _delegate.renewCoordinatorLease(
    scope,
    leaseFence: leaseFence,
    now: now,
    leaseDuration: leaseDuration,
  );

  @override
  Future<void> releaseCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) => _delegate.releaseCoordinatorLease(scope, leaseFence: leaseFence);

  @override
  Future<void> recordRun(CloudSyncRunRecord run) => _delegate.recordRun(run);

  @override
  Future<int> journalFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  }) => _blocked();

  @override
  Future<List<CloudInboxEntry>> readEligibleInbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
  }) => _blocked();

  @override
  Future<void> markInboxApplied(
    CloudSyncScope scope, {
    required int sequence,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  }) => _blocked();

  @override
  Future<void> markInboxRetryable(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory category,
    required DateTime now,
    required DateTime nextEligibleAt,
    required CloudCoordinatorLeaseFence leaseFence,
  }) => _blocked();

  @override
  Future<void> quarantineInbox(
    CloudSyncScope scope, {
    required int sequence,
    required CloudFailureCategory category,
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
  }) => _blocked();

  @override
  Future<void> enqueueOutbox(CloudOutboxOperation operation) => _blocked();

  @override
  Future<CloudOutboxOperation> enqueueOutboxMutation(CloudOutboxDraft draft) =>
      _blocked();

  @override
  Future<CloudSyncResetCompletionProof> rebootstrapAfterReset(
    CloudSyncResetRebootstrapRequest request, {
    required DateTime now,
  }) => _blocked();

  @override
  Future<CloudSyncCheckpoint> advanceOutboxGeneration(
    CloudSyncScope scope, {
    required DateTime now,
  }) => _blocked();

  @override
  Future<List<CloudOutboxOperation>> leaseEligibleOutbox(
    CloudSyncScope scope, {
    required DateTime now,
    required int limit,
    required String leaseId,
    required Duration leaseDuration,
    required Set<CloudOutboxAction> allowedActions,
  }) => _blocked();

  @override
  Future<List<CloudOutboxOperation>> markOutboxSubmissionStarted(
    CloudSyncScope scope, {
    required String leaseId,
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required DateTime now,
  }) => _blocked();

  @override
  Future<void> applyOutboxTransitions(
    CloudSyncScope scope, {
    required String leaseId,
    required Iterable<CloudOutboxTransition> transitions,
    required DateTime now,
  }) => _blocked();

  @override
  Future<int> recoverExpiredOutboxLeases(
    CloudSyncScope scope, {
    required DateTime now,
  }) => _blocked();

  @override
  Future<void> attachOutboxRecordMapping(
    CloudSyncScope scope, {
    required String leaseId,
    required String operationId,
    required String serverRecordIdHash,
    required DateTime now,
  }) => _blocked();

  @override
  Future<int> resumePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
  }) => _blocked();

  @override
  Future<Set<CloudFailureCategory>> readPausedOutboxFailureCategories(
    CloudSyncScope scope, {
    required DateTime now,
  }) => _blocked();

  @override
  Future<int> postponeEligiblePausedOutbox(
    CloudSyncScope scope, {
    required Set<CloudFailureCategory> categories,
    required DateTime now,
    required DateTime nextEligibleAt,
  }) => _blocked();

  @override
  Future<CloudRecordMapEntry?> readRecordMap(
    CloudSyncScope scope, {
    required String logicalEntityKeyHash,
    required int generation,
  }) => _blocked();

  @override
  Future<void> upsertRecordMap(
    CloudRecordMapEntry entry, {
    required int generation,
  }) => _blocked();

  Future<T> _blocked<T>() =>
      Future<T>.error(const CloudSyncShadowStoreTripwireException());
}

final class CloudSyncShadowStoreTripwireException implements Exception {
  const CloudSyncShadowStoreTripwireException();

  static const safeCode = 'cloud_sync_shadow_store_tripwire';

  @override
  String toString() => 'CloudSyncShadowStoreTripwireException($safeCode)';
}
