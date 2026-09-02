import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late InMemoryCloudSyncStore store;
  late CloudSyncScope scope;

  setUp(() {
    store = InMemoryCloudSyncStore();
    scope = testScope();
  });

  test('unknown push outcomes require a diagnostic failure category', () {
    final operationId = testOutboxOperation(scope, 1).operationId;
    expect(
      () => CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.unknownOutcome,
      ),
      throwsArgumentError,
    );
    expect(
      CloudPushOutcome(
        operationId: operationId,
        disposition: CloudPushDisposition.unknownOutcome,
        failureCategory: CloudFailureCategory.authorization,
      ).failureCategory,
      CloudFailureCategory.authorization,
    );
  });

  test(
    'journals page durably, promotes only after applied, and deduplicates',
    () async {
      final batch = CloudFetchBatch(
        scope: scope,
        changes: [testChange(1), testChange(2)],
        batchId: 'batch-1',
        generation: 1,
        nextToken: 'opaque-token-1',
        hasMore: false,
      );

      expect(await _journal(store, batch), 2);

      final checkpoint = await store.readCheckpoint(scope);
      final inbox = await store.inboxEntries(scope);
      expect(checkpoint.fetchedToken, isNull);
      expect(checkpoint.pendingBatchId, 'batch-1');
      expect(checkpoint.fetchedSequence, 2);
      expect(checkpoint.lastBatchId, 'batch-1');
      expect(inbox.map((entry) => entry.sequence), [1, 2]);

      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'terminal-page-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 5),
      ))!;
      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      await store.markInboxApplied(
        scope,
        sequence: 2,
        now: testEpoch,
        leaseFence: fence,
      );
      final promoted = await store.readCheckpoint(scope);
      expect(promoted.fetchedToken, 'opaque-token-1');
      expect(promoted.pendingBatchId, isNull);
      await store.releaseCoordinatorLease(scope, leaseFence: fence);

      // A refetched page is now safe to deduplicate against the applied
      // journal and advance its continuation token exactly once.
      expect(await _journal(store, batch), 0);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'opaque-token-1',
      );
    },
  );

  test('journals a tombstone without inventing an etag or payload', () async {
    await _journal(
      store,
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1, tombstone: true)],
        batchId: 'tombstone-batch',
        generation: 1,
        nextToken: 'opaque-token',
        hasMore: false,
      ),
    );

    final entry = (await store.inboxEntries(scope)).single;
    expect(entry.change.isTombstone, isTrue);
    expect(entry.change.etagHash, isNull);
    expect(entry.change.encryptedPayloadReference, isNull);
    expect(entry.change.payloadSha256, isNull);
    expect(entry.change.encryptedServerRecordId, isNotNull);
    expect(entry.batchId, 'tombstone-batch');
    expect(entry.generation, 1);
  });

  test('rejects a fetched page from the wrong checkpoint generation', () async {
    await expectLater(
      _journal(
        store,
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'stale-generation-batch',
          generation: 2,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'generation_mismatch',
        ),
      ),
    );
  });

  test(
    'quarantined rows block the applied floor and page-token promotion',
    () async {
      await _journal(
        store,
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2), testChange(3)],
          batchId: 'batch-1',
          generation: 1,
          nextToken: 'token',
          hasMore: false,
        ),
      );
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);

      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'inbox-transition-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 5),
      ))!;
      await store.markInboxApplied(
        scope,
        sequence: 2,
        now: testEpoch,
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 0);

      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 2);

      await store.quarantineInbox(
        scope,
        sequence: 3,
        category: CloudFailureCategory.malformedRecord,
        now: testEpoch,
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 2);
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect((await store.readCheckpoint(scope)).pendingBatchId, 'batch-1');
    },
  );

  test(
    'retained deterministic failure releases the terminal token without advancing the exact floor',
    () async {
      await _journal(
        store,
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'retained-page',
          generation: 1,
          nextToken: 'retained-token',
          hasMore: false,
        ),
      );
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'retained-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 5),
      ))!;

      await expectLater(
        store.markInboxRetainedUnprojected(
          scope,
          sequence: 1,
          category: CloudFailureCategory.conflict,
          now: testEpoch,
          maximumDeferredAttempts: 8,
          maximumDeferredAge: const Duration(days: 3),
          leaseFence: fence,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (error) => error.safeCode,
            'safeCode',
            'inbox_retention_policy_rejected',
          ),
        ),
      );
      await store.markInboxRetainedUnprojected(
        scope,
        sequence: 1,
        category: CloudFailureCategory.malformedRecord,
        now: testEpoch,
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
      );
      final eligibleAfterRetained = await store.readEligibleInbox(
        scope,
        now: testEpoch,
        limit: 1,
      );
      expect(eligibleAfterRetained.map((entry) => entry.sequence), [2]);
      await store.markInboxApplied(
        scope,
        sequence: 2,
        now: testEpoch,
        leaseFence: fence,
      );

      final entries = await store.inboxEntries(scope);
      expect(entries.first.status, CloudInboxStatus.retainedUnprojected);
      expect(entries.last.status, CloudInboxStatus.applied);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.lastAppliedSequence, 0);
      expect(checkpoint.fetchedToken, 'retained-token');
      expect(checkpoint.pendingBatchId, isNull);
      expect(checkpoint.hasUnmarkedPendingInbox, isFalse);
      expect(
        await store.readEligibleInbox(scope, now: testEpoch, limit: 1),
        isEmpty,
      );
      final summary = await store.readRetainedUnprojectedInboxSummary(scope);
      expect(summary.total, 1);
      expect(summary.saves, 1);
      expect(summary.tombstones, 0);
      expect(summary.unclassified, 0);
      expect(summary.byFailureCategory, <CloudFailureCategory, int>{
        CloudFailureCategory.malformedRecord: 1,
      });
    },
  );

  test('out-of-scope retention accepts only clean save rows', () async {
    await _journal(
      store,
      CloudFetchBatch(
        scope: scope,
        changes: [
          testChange(1),
          testChange(2, tombstone: true),
          testChange(
            3,
            preflightFailure: CloudFailureCategory.unsupportedService,
            preflightCode: CloudPreflightCode.unsupportedRecordType,
          ),
        ],
        batchId: 'out-of-scope-shape-page',
        generation: 1,
        nextToken: 'out-of-scope-shape-token',
        hasMore: false,
      ),
    );
    final fence = (await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'out-of-scope-shape-owner',
      now: testEpoch,
      leaseDuration: const Duration(minutes: 5),
    ))!;

    await store.markInboxRetainedUnprojected(
      scope,
      sequence: 1,
      category: CloudFailureCategory.outOfScopeService,
      now: testEpoch,
      maximumDeferredAttempts: 8,
      maximumDeferredAge: const Duration(days: 3),
      leaseFence: fence,
    );
    for (final sequence in [2, 3]) {
      await expectLater(
        store.markInboxRetainedUnprojected(
          scope,
          sequence: sequence,
          category: CloudFailureCategory.outOfScopeService,
          now: testEpoch,
          maximumDeferredAttempts: 8,
          maximumDeferredAge: const Duration(days: 3),
          leaseFence: fence,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'inbox_retention_policy_rejected',
          ),
        ),
      );
    }

    final entries = await store.inboxEntries(scope);
    expect(entries[0].status, CloudInboxStatus.retainedUnprojected);
    expect(entries[1].status, CloudInboxStatus.pending);
    expect(entries[2].status, CloudInboxStatus.pending);
    final summary = await store.readRetainedUnprojectedInboxSummary(scope);
    expect(summary.outOfScopeServices, 1);
    expect(summary.blockingSaves, 0);
  });

  test(
    'retained terminal rows remain projection-unresolved during recovery',
    () async {
      await _journal(
        store,
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'retained-recovery-page',
          generation: 1,
          nextToken: 'retained-recovery-token',
          hasMore: false,
        ),
      );
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'retained-recovery-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 5),
      ))!;
      await store.markInboxRetainedUnprojected(
        scope,
        sequence: 1,
        category: CloudFailureCategory.malformedRecord,
        now: testEpoch,
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
      );
      await store.markInboxApplied(
        scope,
        sequence: 2,
        now: testEpoch,
        leaseFence: fence,
      );

      final recovered = await store.recoverRetainedInboxBarriers(
        scope,
        now: testEpoch,
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
      );

      expect(recovered.previousAppliedSequence, 0);
      expect(recovered.recomputedAppliedSequence, 0);
      expect(recovered.legacyFloorInflated, isFalse);
      expect(recovered.firstUnresolvedSequence, 1);
      expect(
        recovered.firstUnresolvedStatus,
        CloudInboxStatus.retainedUnprojected,
      );
      expect(
        recovered.firstUnresolvedCategory,
        CloudFailureCategory.malformedRecord,
      );
      expect(recovered.recoveryComplete, isFalse);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'retained-recovery-token');
      expect(checkpoint.lastAppliedSequence, 0);
      expect(checkpoint.hasUnmarkedPendingInbox, isFalse);
    },
  );

  test('recovery preserves a conflict tombstone as a barrier', () async {
    await _journal(
      store,
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1, tombstone: true)],
        batchId: 'conflict-tombstone-page',
        generation: 1,
        nextToken: 'conflict-tombstone-token',
        hasMore: false,
      ),
    );
    final fence = (await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'conflict-tombstone-owner',
      now: testEpoch,
      leaseDuration: const Duration(days: 40),
    ))!;
    await store.quarantineInbox(
      scope,
      sequence: 1,
      category: CloudFailureCategory.conflict,
      now: testEpoch,
      leaseFence: fence,
    );

    await expectLater(
      store.markInboxRetainedUnprojected(
        scope,
        sequence: 1,
        category: CloudFailureCategory.malformedRecord,
        now: testEpoch,
        maximumDeferredAttempts: 1,
        maximumDeferredAge: Duration.zero,
        leaseFence: fence,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'inbox_retention_category_mismatch',
        ),
      ),
    );

    final recovered = await store.recoverRetainedInboxBarriers(
      scope,
      now: testEpoch.add(const Duration(days: 30)),
      maximumDeferredAttempts: 1,
      maximumDeferredAge: Duration.zero,
      leaseFence: fence,
    );

    expect(recovered.retainedUnprojected, 0);
    expect(recovered.tombstoneReadOnlyAcknowledged, 0);
    expect(recovered.previousAppliedSequence, 0);
    expect(recovered.recomputedAppliedSequence, 0);
    expect(recovered.legacyFloorInflated, isFalse);
    expect(recovered.firstUnresolvedSequence, 1);
    expect(recovered.firstUnresolvedStatus, CloudInboxStatus.quarantined);
    expect(recovered.firstUnresolvedCategory, CloudFailureCategory.conflict);
    expect(recovered.recoveryComplete, isFalse);
    expect(
      (await store.inboxEntries(scope)).single.status,
      CloudInboxStatus.quarantined,
    );
    final checkpoint = await store.readCheckpoint(scope);
    expect(checkpoint.lastAppliedSequence, 0);
    expect(checkpoint.fetchedToken, isNull);
  });

  test(
    'read-only tombstone acknowledgement requires proof of an inflated floor',
    () async {
      final batch = CloudFetchBatch(
        scope: scope,
        changes: [testChange(1), testChange(2, tombstone: true), testChange(3)],
        batchId: 'policy-gated-tombstone-page',
        generation: 1,
        nextToken: 'policy-gated-tombstone-token',
        hasMore: false,
      );
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'policy-gated-tombstone-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 5),
      ))!;
      final checkpoint = await store.readCheckpoint(scope);
      final admission = await store.journalShadowFetchedBatch(
        batch,
        now: testEpoch,
        budget: CloudShadowJournalBudget(),
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );
      expect(admission.insertedEntries, 3);

      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: fence,
      );
      await store.quarantineInbox(
        scope,
        sequence: 2,
        category: CloudFailureCategory.conflict,
        now: testEpoch,
        leaseFence: fence,
      );
      final before = (await store.inboxEntries(
        scope,
      )).singleWhere((entry) => entry.sequence == 2);

      final recovered = await store.recoverRetainedInboxBarriers(
        scope,
        now: testEpoch,
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
        allowLegacyReadOnlyTombstoneAcknowledgement: true,
      );

      expect(recovered.retainedUnprojected, 0);
      expect(recovered.tombstoneReadOnlyAcknowledged, 0);
      expect(recovered.previousAppliedSequence, 1);
      expect(recovered.recomputedAppliedSequence, 1);
      expect(recovered.legacyFloorInflated, isFalse);
      expect(recovered.firstUnresolvedSequence, 2);
      expect(recovered.firstUnresolvedStatus, CloudInboxStatus.quarantined);
      expect(recovered.firstUnresolvedCategory, CloudFailureCategory.conflict);
      expect(recovered.recoveryComplete, isFalse);

      final after = (await store.inboxEntries(
        scope,
      )).singleWhere((entry) => entry.sequence == 2);
      expect(after.status, CloudInboxStatus.quarantined);
      expect(after.lastFailure, CloudFailureCategory.conflict);
      expect(after.change.changeId, before.change.changeId);
      expect(after.change.recordIdHash, before.change.recordIdHash);
      expect(
        after.change.encryptedServerRecordId,
        before.change.encryptedServerRecordId,
      );
      expect(
        after.change.protectedSystemFieldsReference,
        before.change.protectedSystemFieldsReference,
      );
      expect(after.change.isTombstone, isTrue);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'policy-gated-tombstone-token',
      );

      final repeated = await store.recoverRetainedInboxBarriers(
        scope,
        now: testEpoch.add(const Duration(minutes: 1)),
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
        allowLegacyReadOnlyTombstoneAcknowledgement: true,
      );
      expect(repeated.retainedUnprojected, 0);
      expect(repeated.tombstoneReadOnlyAcknowledged, 0);
      expect(repeated.previousAppliedSequence, 1);
      expect(repeated.recomputedAppliedSequence, 1);
      expect(repeated.legacyFloorInflated, isFalse);
      expect(repeated.firstUnresolvedSequence, 2);
      expect(repeated.firstUnresolvedStatus, CloudInboxStatus.quarantined);
      expect(repeated.firstUnresolvedCategory, CloudFailureCategory.conflict);
      expect(repeated.recoveryComplete, isFalse);
    },
  );

  test(
    'mixed conflict tombstone and non-tombstone stay barriers without legacy proof',
    () async {
      final batch = CloudFetchBatch(
        scope: scope,
        changes: [
          testChange(1),
          testChange(2, tombstone: true),
          testChange(3),
          testChange(4),
        ],
        batchId: 'mixed-conflict-page',
        generation: 1,
        nextToken: 'mixed-conflict-token',
        hasMore: false,
      );
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'mixed-conflict-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 5),
      ))!;
      final checkpoint = await store.readCheckpoint(scope);
      final admission = await store.journalShadowFetchedBatch(
        batch,
        now: testEpoch,
        budget: CloudShadowJournalBudget(),
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );
      expect(admission.insertedEntries, 4);
      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: fence,
      );
      for (final sequence in [2, 3]) {
        await store.quarantineInbox(
          scope,
          sequence: sequence,
          category: CloudFailureCategory.conflict,
          now: testEpoch,
          leaseFence: fence,
        );
      }

      final recovered = await store.recoverRetainedInboxBarriers(
        scope,
        now: testEpoch,
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
        allowLegacyReadOnlyTombstoneAcknowledgement: true,
      );

      expect(recovered.retainedUnprojected, 0);
      expect(recovered.tombstoneReadOnlyAcknowledged, 0);
      expect(recovered.previousAppliedSequence, 1);
      expect(recovered.recomputedAppliedSequence, 1);
      expect(recovered.legacyFloorInflated, isFalse);
      expect(recovered.firstUnresolvedSequence, 2);
      expect(recovered.firstUnresolvedStatus, CloudInboxStatus.quarantined);
      expect(recovered.firstUnresolvedCategory, CloudFailureCategory.conflict);
      expect(recovered.recoveryComplete, isFalse);
      final entries = await store.inboxEntries(scope);
      expect(
        entries
            .where((entry) => entry.sequence == 2 || entry.sequence == 3)
            .map((entry) => entry.status),
        everyElement(CloudInboxStatus.quarantined),
      );
    },
  );

  test('dependency retention requires both attempt and age bounds', () async {
    await _journal(
      store,
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1), testChange(2), testChange(3)],
        batchId: 'dependency-bounds-page',
        generation: 1,
        nextToken: 'dependency-bounds-token',
        hasMore: false,
      ),
    );
    final fence = (await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'dependency-bounds-owner',
      now: testEpoch,
      leaseDuration: const Duration(days: 10),
    ))!;

    await expectLater(
      store.markInboxRetainedUnprojected(
        scope,
        sequence: 1,
        category: CloudFailureCategory.dependency,
        now: testEpoch.add(const Duration(days: 4)),
        maximumDeferredAttempts: 2,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'inbox_retention_policy_rejected',
        ),
      ),
    );
    await expectLater(
      store.markInboxRetainedUnprojected(
        scope,
        sequence: 2,
        category: CloudFailureCategory.dependency,
        now: testEpoch.add(const Duration(days: 2)),
        maximumDeferredAttempts: 1,
        maximumDeferredAge: const Duration(days: 3),
        leaseFence: fence,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'inbox_retention_policy_rejected',
        ),
      ),
    );
    await store.markInboxRetainedUnprojected(
      scope,
      sequence: 3,
      category: CloudFailureCategory.dependency,
      now: testEpoch.add(const Duration(days: 4)),
      maximumDeferredAttempts: 1,
      maximumDeferredAge: const Duration(days: 3),
      leaseFence: fence,
    );

    final entries = await store.inboxEntries(scope);
    expect(entries[0].status, CloudInboxStatus.pending);
    expect(entries[1].status, CloudInboxStatus.pending);
    expect(entries[2].status, CloudInboxStatus.retainedUnprojected);
  });

  test(
    'failed first record retains the old token until every row is applied',
    () async {
      await _journal(
        store,
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'failed-first-page',
          generation: 1,
          nextToken: 'new-token',
          hasMore: true,
        ),
      );
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'failed-first-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 5),
      ))!;

      await store.markInboxApplied(
        scope,
        sequence: 2,
        now: testEpoch,
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      await store.markInboxRetryable(
        scope,
        sequence: 1,
        category: CloudFailureCategory.network,
        now: testEpoch,
        nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);

      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).fetchedToken, 'new-token');
      // A repeated applied transition cannot promote a second time or alter
      // the already committed token.
      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: fence,
      );
      expect((await store.readCheckpoint(scope)).fetchedToken, 'new-token');
    },
  );

  test('retry fallback is monotonic and idempotent', () async {
    await _journal(
      store,
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'retry-fallback-page',
        generation: 1,
        nextToken: 'retry-token',
        hasMore: false,
      ),
    );
    final fence = (await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'retry-fallback-owner',
      now: testEpoch,
      leaseDuration: const Duration(minutes: 5),
    ))!;
    final later = testEpoch.add(const Duration(minutes: 10));
    for (final nextEligibleAt in [
      later,
      later,
      testEpoch.add(const Duration(minutes: 5)),
    ]) {
      await store.markInboxRetryable(
        scope,
        sequence: 1,
        category: CloudFailureCategory.network,
        now: testEpoch,
        nextEligibleAt: nextEligibleAt,
        leaseFence: fence,
      );
    }

    final entry = (await store.inboxEntries(scope)).single;
    expect(entry.attemptCount, 1);
    expect(entry.nextEligibleAt, later);
  });

  test('account-scoped journals cannot bleed into another account', () async {
    final otherScope = testScope(account: testAccountFingerprintB);
    await _journal(
      store,
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'batch-a',
        generation: 1,
        nextToken: 'token-a',
        hasMore: false,
      ),
    );

    expect(await store.inboxEntries(otherScope), isEmpty);
    expect((await store.readCheckpoint(otherScope)).fetchedToken, isNull);
  });

  test(
    'coalesces pending saves by logical entity and keeps latest revision',
    () async {
      final first = testOutboxOperation(scope, 1, revision: 1);
      final latest = testOutboxOperation(scope, 1, revision: 2);
      await store.enqueueOutbox(first);
      await store.enqueueOutbox(first);
      await store.enqueueOutbox(latest);

      final entries = await store.outboxEntries(scope);
      expect(entries, hasLength(1));
      expect(entries.single.operationId, latest.operationId);
      expect(
        entries.single.payloadSha256,
        testOutboxOperation(scope, 1, revision: 2).payloadSha256,
      );
    },
  );

  test(
    'production enqueue allocates monotonic revisions despite clock rollback',
    () async {
      final first = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'logical-key-digest',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:first',
          payloadSha256: 'payload-digest-first',
          dependencyOperationIds: const [],
          createdAt: testEpoch.add(const Duration(days: 1)),
        ),
      );
      final second = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'logical-key-digest',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:second',
          payloadSha256: 'payload-digest-second',
          dependencyOperationIds: const [],
          createdAt: testEpoch.subtract(const Duration(days: 1)),
        ),
      );

      expect(first.mutationRevision, 1);
      expect(second.mutationRevision, 2);
      expect((await store.readCheckpoint(scope)).mutationRevisionCounter, 2);
      expect(
        (await store.outboxEntries(scope)).single.operationId,
        second.operationId,
      );
    },
  );

  test(
    'outbox enqueue is bound to the current checkpoint generation',
    () async {
      final admitted = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'generation-bound-key',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:generation-bound',
          payloadSha256: 'payload-digest-generation-bound',
          dependencyOperationIds: const [],
          createdAt: testEpoch,
        ),
      );
      expect(admitted.checkpointGeneration, 1);

      await expectLater(
        store.enqueueOutbox(
          testOutboxOperation(scope, 2, checkpointGeneration: 2),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'outbox_generation_mismatch',
          ),
        ),
      );
      expect(await store.outboxEntries(scope), hasLength(1));
    },
  );

  test(
    'advance fences every stale outbox row and admits only new generation',
    () async {
      final leased = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'leased-generation-key',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:leased-generation',
          payloadSha256: 'payload-digest-leased-generation',
          dependencyOperationIds: const [],
          createdAt: testEpoch,
        ),
      );
      final pending = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'pending-generation-key',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:pending-generation',
          payloadSha256: 'payload-digest-pending-generation',
          dependencyOperationIds: const [],
          createdAt: testEpoch,
        ),
      );
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'generation-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );

      final advanced = await store.advanceOutboxGeneration(
        scope,
        now: testEpoch,
      );
      expect(advanced.generation, 2);
      final fenced = await store.outboxEntries(scope);
      expect(
        fenced
            .where(
              (row) =>
                  row.operationId == leased.operationId ||
                  row.operationId == pending.operationId,
            )
            .map((row) => row.status),
        everyElement(CloudOutboxStatus.quarantined),
      );
      await expectLater(
        store.applyOutboxTransitions(
          scope,
          leaseId: 'generation-lease',
          transitions: [CloudOutboxTransition.confirmed(leased.operationId)],
          now: testEpoch,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'stale_outbox_generation',
          ),
        ),
      );

      final fresh = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'fresh-generation-key',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:fresh-generation',
          payloadSha256: 'payload-digest-fresh-generation',
          dependencyOperationIds: const [],
          createdAt: testEpoch,
        ),
      );
      expect(fresh.checkpointGeneration, 2);
      expect(
        (await store.leaseEligibleOutbox(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'fresh-generation-lease',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        )).single.operationId,
        fresh.operationId,
      );
    },
  );

  test(
    'reset rebootstrap clears the active in-memory generation state',
    () async {
      final scope = testScope();
      await _journal(
        store,
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'reset-batch',
          generation: 1,
          nextToken: 'reset-token',
          hasMore: false,
        ),
      );
      final oldOperation = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'reset-old-operation',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:reset-old',
          payloadSha256: 'payload-digest-reset-old',
          dependencyOperationIds: const [],
          createdAt: testEpoch,
        ),
      );

      final completion = await store.rebootstrapAfterReset(
        CloudSyncResetRebootstrapRequest(
          scope: scope,
          transitionIdHash:
              '2222222222222222222222222222222222222222222222222222222222222222',
          activeIdentityFingerprint: scope.accountFingerprint,
          expectedGeneration: 1,
          protectedRemoteStateProofReference:
              'obcs2.ref.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ),
        now: testEpoch.add(const Duration(seconds: 1)),
      );
      expect(completion.previousGeneration, 1);
      expect(completion.generation, 2);
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect((await store.readCheckpoint(scope)).fetchedSequence, 0);
      expect(await store.inboxEntries(scope), isEmpty);
      expect(
        (await store.outboxEntries(scope))
            .singleWhere((row) => row.operationId == oldOperation.operationId)
            .status,
        CloudOutboxStatus.quarantined,
      );
    },
  );

  test('advancing one account scope does not fence another account', () async {
    final otherScope = testScope(account: testAccountFingerprintB);
    final first = await store.enqueueOutboxMutation(
      CloudOutboxDraft(
        scope: scope,
        logicalEntityKeyHash: 'account-a-key',
        action: CloudOutboxAction.save,
        payloadVersion: 1,
        encryptedPayloadReference: 'protected:account-a',
        payloadSha256: 'payload-digest-account-a',
        dependencyOperationIds: const [],
        createdAt: testEpoch,
      ),
    );
    final second = await store.enqueueOutboxMutation(
      CloudOutboxDraft(
        scope: otherScope,
        logicalEntityKeyHash: 'account-b-key',
        action: CloudOutboxAction.save,
        payloadVersion: 1,
        encryptedPayloadReference: 'protected:account-b',
        payloadSha256: 'payload-digest-account-b',
        dependencyOperationIds: const [],
        createdAt: testEpoch,
      ),
    );

    await store.advanceOutboxGeneration(scope, now: testEpoch);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.quarantined,
    );
    expect(
      (await store.outboxEntries(otherScope)).single.checkpointGeneration,
      1,
    );
    expect(
      (await store.leaseEligibleOutbox(
        otherScope,
        now: testEpoch,
        limit: 1,
        leaseId: 'other-account-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      )).single.operationId,
      second.operationId,
    );
    expect(first.checkpointGeneration, 1);
  });

  test(
    'generation cannot advance while its coordinator may be writing',
    () async {
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'active-generation-writer',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 1),
      ))!;

      await expectLater(
        store.advanceOutboxGeneration(scope, now: testEpoch),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'generation_advance_coordinator_active',
          ),
        ),
      );
      expect((await store.readCheckpoint(scope)).generation, 1);

      await store.releaseCoordinatorLease(scope, leaseFence: fence);
      expect(
        (await store.advanceOutboxGeneration(scope, now: testEpoch)).generation,
        2,
      );
    },
  );

  test('caller-supplied operation ID cannot collide across scopes', () async {
    final first = testOutboxOperation(scope, 91);
    final otherScope = testScope(account: testAccountFingerprintB);
    final collision = CloudOutboxOperation(
      scope: otherScope,
      operationId: first.operationId,
      logicalEntityKeyHash: first.logicalEntityKeyHash,
      action: first.action,
      payloadVersion: first.payloadVersion,
      mutationRevision: first.mutationRevision,
      checkpointGeneration: 1,
      encryptedPayloadReference: first.encryptedPayloadReference,
      payloadSha256: first.payloadSha256,
      dependencyOperationIds: first.dependencyOperationIds,
      createdAt: first.createdAt,
    );
    await store.enqueueOutbox(first);

    await expectLater(
      store.enqueueOutbox(collision),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'outbox_operation_scope_collision',
        ),
      ),
    );
    expect(await store.outboxEntries(otherScope), isEmpty);
  });

  test(
    'confirmed dependency from an older generation cannot unlock work',
    () async {
      final dependency = await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'old-generation-dependency',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:old-generation-dependency',
          payloadSha256: 'digest-old-generation-dependency',
          dependencyOperationIds: const [],
          createdAt: testEpoch,
        ),
      );
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'old-generation-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'old-generation-lease',
        transitions: [CloudOutboxTransition.confirmed(dependency.operationId)],
        now: testEpoch,
      );
      await store.advanceOutboxGeneration(scope, now: testEpoch);
      await store.enqueueOutboxMutation(
        CloudOutboxDraft(
          scope: scope,
          logicalEntityKeyHash: 'new-generation-dependent',
          action: CloudOutboxAction.save,
          payloadVersion: 1,
          encryptedPayloadReference: 'protected:new-generation-dependent',
          payloadSha256: 'digest-new-generation-dependent',
          dependencyOperationIds: {dependency.operationId},
          createdAt: testEpoch,
        ),
      );

      expect(
        await store.leaseEligibleOutbox(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'new-generation-lease',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        ),
        isEmpty,
      );
    },
  );

  test('stale save cannot replace a newer save or strand dependents', () async {
    final originalDependency = testOutboxOperation(scope, 1, revision: 1);
    final dependentMessage = testOutboxOperation(
      scope,
      2,
      dependencies: [originalDependency.operationId],
    );
    final newerDependency = testOutboxOperation(scope, 1, revision: 2);
    final staleDependency = testOutboxOperation(scope, 1, revision: 0);
    await store.enqueueOutbox(originalDependency);
    await store.enqueueOutbox(dependentMessage);
    await store.enqueueOutbox(newerDependency);
    await store.enqueueOutbox(staleDependency);

    final entries = await store.outboxEntries(scope);
    expect(entries, hasLength(2));
    expect(
      entries.any((entry) => entry.operationId == newerDependency.operationId),
      isTrue,
    );
    expect(
      entries
          .singleWhere(
            (entry) => entry.operationId == dependentMessage.operationId,
          )
          .dependencyOperationIds,
      {newerDependency.operationId},
    );
  });

  test('dependencies and feature gates control outbox leasing', () async {
    final attachment = testOutboxOperation(scope, 1);
    final message = testOutboxOperation(
      scope,
      2,
      dependencies: [attachment.operationId],
    );
    final deletion = testOutboxOperation(
      scope,
      3,
      action: CloudOutboxAction.delete,
    );
    await store.enqueueOutbox(attachment);
    await store.enqueueOutbox(message);
    await store.enqueueOutbox(deletion);

    final firstLease = await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 256,
      leaseId: 'lease-1',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    expect(firstLease.map((operation) => operation.operationId), [
      attachment.operationId,
    ]);

    await store.applyOutboxTransitions(
      scope,
      leaseId: 'lease-1',
      transitions: [CloudOutboxTransition.confirmed(attachment.operationId)],
      now: testEpoch,
    );
    final secondLease = await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 256,
      leaseId: 'lease-2',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    expect(secondLease.map((operation) => operation.operationId), [
      message.operationId,
    ]);
  });

  test(
    'newer delete waits behind a leased save and the batch keeps scanning',
    () async {
      final saveA = testOutboxOperation(scope, 1, revision: 1);
      final deleteA = testOutboxOperation(
        scope,
        1,
        action: CloudOutboxAction.delete,
        revision: 2,
        createdAt: testEpoch.add(const Duration(microseconds: 1)),
      );
      final saveB = testOutboxOperation(
        scope,
        2,
        revision: 3,
        createdAt: testEpoch.add(const Duration(microseconds: 2)),
      );
      await store.enqueueOutbox(saveA);
      await store.enqueueOutbox(deleteA);
      await store.enqueueOutbox(saveB);

      final firstLease = await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'lease-save-a',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: CloudOutboxAction.values.toSet(),
      );
      expect(firstLease.map((operation) => operation.operationId), [
        saveA.operationId,
      ]);

      final secondLease = await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'lease-save-b',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: CloudOutboxAction.values.toSet(),
      );
      expect(secondLease.map((operation) => operation.operationId), [
        saveB.operationId,
      ]);

      await store.applyOutboxTransitions(
        scope,
        leaseId: 'lease-save-a',
        transitions: [CloudOutboxTransition.confirmed(saveA.operationId)],
        now: testEpoch,
      );

      final thirdLease = await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'lease-delete-a',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: CloudOutboxAction.values.toSet(),
      );
      expect(thirdLease.map((operation) => operation.operationId), [
        deleteA.operationId,
      ]);
    },
  );

  test('stale worker cannot confirm a newer lease', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'old-lease',
      leaseDuration: const Duration(seconds: 1),
      allowedActions: CloudOutboxAction.values.toSet(),
    );
    await store.recoverExpiredOutboxLeases(
      scope,
      now: testEpoch.add(const Duration(seconds: 2)),
    );
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch.add(const Duration(seconds: 2)),
      limit: 1,
      leaseId: 'new-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: CloudOutboxAction.values.toSet(),
    );

    await expectLater(
      store.applyOutboxTransitions(
        scope,
        leaseId: 'old-lease',
        transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'stale_outbox_lease',
        ),
      ),
    );
  });

  test('expired outbox lease cannot map or confirm before recovery', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'expired-lease',
      leaseDuration: const Duration(seconds: 1),
      allowedActions: CloudOutboxAction.values.toSet(),
    );

    await expectLater(
      store.attachOutboxRecordMapping(
        scope,
        leaseId: 'expired-lease',
        operationId: operation.operationId,
        serverRecordIdHash: 'server-record-hash',
        now: testEpoch.add(const Duration(seconds: 1)),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'stale_outbox_lease',
        ),
      ),
    );

    await expectLater(
      store.applyOutboxTransitions(
        scope,
        leaseId: 'expired-lease',
        transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        now: testEpoch.add(const Duration(seconds: 1)),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'stale_outbox_lease',
        ),
      ),
    );
  });

  test('resume keeps future paused rows behind their retry boundary', () async {
    final eligible = testOutboxOperation(scope, 1);
    final future = testOutboxOperation(scope, 2);
    await store.enqueueOutbox(eligible);
    await store.enqueueOutbox(future);
    final leased = await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 2,
      leaseId: 'pause-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: CloudOutboxAction.values.toSet(),
    );
    expect(leased, hasLength(2));
    await store.applyOutboxTransitions(
      scope,
      leaseId: 'pause-lease',
      transitions: [
        CloudOutboxTransition.paused(
          eligible.operationId,
          category: CloudFailureCategory.authorization,
          nextEligibleAt: testEpoch,
        ),
        CloudOutboxTransition.paused(
          future.operationId,
          category: CloudFailureCategory.authorization,
          nextEligibleAt: testEpoch.add(const Duration(hours: 1)),
        ),
      ],
      now: testEpoch,
    );

    expect(
      await store.resumePausedOutbox(
        scope,
        categories: const {CloudFailureCategory.authorization},
        now: testEpoch,
      ),
      1,
    );
    final rows = await store.outboxEntries(scope);
    expect(
      rows.singleWhere((row) => row.operationId == eligible.operationId).status,
      CloudOutboxStatus.pending,
    );
    expect(
      rows.singleWhere((row) => row.operationId == future.operationId).status,
      CloudOutboxStatus.paused,
    );
  });

  test('duplicate outbox transitions fail before mutation', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'duplicate-transition-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: CloudOutboxAction.values.toSet(),
    );

    await expectLater(
      store.applyOutboxTransitions(
        scope,
        leaseId: 'duplicate-transition-lease',
        transitions: [
          CloudOutboxTransition.confirmed(operation.operationId),
          CloudOutboxTransition.confirmed(operation.operationId),
        ],
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'duplicate_outbox_transition',
        ),
      ),
    );

    final leased = await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'replacement-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: CloudOutboxAction.values.toSet(),
    );
    expect(leased, isEmpty);
  });

  test(
    'submission marker makes a leased row unknown and non-leasable through recovery',
    () async {
      final operation = testOutboxOperation(scope, 1);
      await store.enqueueOutbox(operation);
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'submission-marker-lease',
        leaseDuration: const Duration(seconds: 1),
        allowedActions: const {CloudOutboxAction.save},
      );

      final submitted = await store.markOutboxSubmissionStarted(
        scope,
        leaseId: 'submission-marker-lease',
        submissionIdentity: testSubmissionIdentity([operation.operationId]),
        now: testEpoch,
      );
      expect(submitted.single.appleRequestUuid, isNotNull);
      expect(submitted.single.appleOperationUuid, isNotNull);

      var marked = (await store.outboxEntries(scope)).single;
      expect(marked.status, CloudOutboxStatus.unknownOutcome);
      expect(marked.lastFailure, CloudFailureCategory.unknown);
      expect(marked.appleRequestUuid, submitted.single.appleRequestUuid);
      expect(marked.appleOperationUuid, submitted.single.appleOperationUuid);
      expect(marked.attemptCount, 0);
      expect(marked.leaseId, 'submission-marker-lease');
      expect(
        await store.leaseEligibleOutbox(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'replay-lease',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        ),
        isEmpty,
      );

      expect(
        await store.recoverExpiredOutboxLeases(
          scope,
          now: testEpoch.add(const Duration(seconds: 2)),
        ),
        0,
      );
      marked = (await store.outboxEntries(scope)).single;
      expect(marked.status, CloudOutboxStatus.unknownOutcome);
      expect(
        await store.leaseEligibleOutbox(
          scope,
          now: testEpoch.add(const Duration(seconds: 2)),
          limit: 1,
          leaseId: 'replay-after-recovery-lease',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        ),
        isEmpty,
      );
    },
  );

  test('submission identity assignment is atomic across the batch', () async {
    final first = testOutboxOperation(scope, 31);
    final second = testOutboxOperation(scope, 32);
    await store.enqueueOutbox(first);
    await store.enqueueOutbox(second);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 2,
      leaseId: 'atomic-submission-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );

    final invalid = CloudOutboxSubmissionIdentity(
      requestUuid: '11111111-2222-4ABC-8DEF-555555555555',
      operationUuids: {
        first.operationId: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
        'missing-operation': 'AAAAAAAA-BBBB-4CCC-8DDD-000000000002',
      },
    );
    await expectLater(
      store.markOutboxSubmissionStarted(
        scope,
        leaseId: 'atomic-submission-lease',
        submissionIdentity: invalid,
        now: testEpoch,
      ),
      throwsA(isA<CloudSyncFailure>()),
    );

    final rows = await store.outboxEntries(scope);
    expect(rows.every((row) => row.status == CloudOutboxStatus.leased), isTrue);
    expect(rows.every((row) => row.appleRequestUuid == null), isTrue);
    expect(rows.every((row) => row.appleOperationUuid == null), isTrue);
  });

  test(
    'legacy unknown outcome without Apple identities stays frozen',
    () async {
      final legacy = testOutboxOperation(
        scope,
        33,
      ).copyWith(status: CloudOutboxStatus.unknownOutcome);
      await store.enqueueOutbox(legacy);

      expect(
        await store.leaseUnknownOutcomes(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'legacy-unknown-lease',
          leaseDuration: const Duration(minutes: 1),
        ),
        isEmpty,
      );
    },
  );

  test('Canary confirmation retains its protected replay receipt', () async {
    final protectedReceipt = testProtectedLeaseReference('a');
    final operation = testOutboxOperation(
      scope,
      2,
    ).copyWith(protectedLeaseReference: protectedReceipt);
    await store.enqueueOutbox(operation);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'submission-confirm-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    await store.attachOutboxRecordMapping(
      scope,
      leaseId: 'submission-confirm-lease',
      operationId: operation.operationId,
      serverRecordIdHash: List.filled(43, 'S').join(),
      now: testEpoch,
    );
    await store.markOutboxSubmissionStarted(
      scope,
      leaseId: 'submission-confirm-lease',
      submissionIdentity: testSubmissionIdentity([operation.operationId]),
      now: testEpoch,
    );

    await store.applyOutboxTransitions(
      scope,
      leaseId: 'submission-confirm-lease',
      transitions: [
        CloudOutboxTransition.confirmed(
          operation.operationId,
          retainProtectedLeaseReference: true,
        ),
      ],
      now: testEpoch.add(const Duration(seconds: 1)),
    );
    final resolved = (await store.outboxEntries(scope)).single;
    expect(resolved.status, CloudOutboxStatus.confirmed);
    expect(resolved.protectedLeaseReference, protectedReceipt);
    expect(resolved.leaseId, isNull);
    expect(resolved.attemptCount, 0);

    await expectLater(
      store.clearConfirmedProtectedOutboundLeaseReference(
        expectedOperation: resolved.copyWith(attemptCount: 1),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'confirmed_outbound_receipt_snapshot_changed',
        ),
      ),
    );
    expect(
      (await store.outboxEntries(scope)).single.protectedLeaseReference,
      protectedReceipt,
    );

    await store.clearConfirmedProtectedOutboundLeaseReference(
      expectedOperation: resolved,
    );
    expect(
      (await store.outboxEntries(scope)).single.protectedLeaseReference,
      isNull,
    );
  });

  test('protected receipt release rejects a pending row', () async {
    final operation = testOutboxOperation(
      scope,
      2001,
    ).copyWith(protectedLeaseReference: testProtectedLeaseReference('e'));
    await store.enqueueOutbox(operation);

    await expectLater(
      store.clearConfirmedProtectedOutboundLeaseReference(
        expectedOperation: operation,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'confirmed_outbound_receipt_release_invalid',
        ),
      ),
    );
    expect(
      (await store.outboxEntries(scope)).single.protectedLeaseReference,
      isNotNull,
    );
  });

  test(
    'ordinary confirmation clears its protected receipt reference',
    () async {
      final operation = testOutboxOperation(
        scope,
        2002,
      ).copyWith(protectedLeaseReference: testProtectedLeaseReference('b'));
      await store.enqueueOutbox(operation);
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'ordinary-confirm-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'ordinary-confirm-lease',
        transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        now: testEpoch.add(const Duration(seconds: 1)),
      );

      expect(
        (await store.outboxEntries(scope)).single.protectedLeaseReference,
        isNull,
      );
    },
  );

  test(
    'explicit unknown transition clears the live lease and increments attempts',
    () async {
      final operation = testOutboxOperation(scope, 3);
      await store.enqueueOutbox(operation);
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'explicit-unknown-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'explicit-unknown-lease',
        transitions: [
          CloudOutboxTransition.unknownOutcome(operation.operationId),
        ],
        now: testEpoch,
      );
      final unknown = (await store.outboxEntries(scope)).single;
      expect(unknown.status, CloudOutboxStatus.unknownOutcome);
      expect(unknown.lastFailure, CloudFailureCategory.unknown);
      expect(unknown.attemptCount, 1);
      expect(unknown.leaseId, isNull);
      expect(unknown.nextEligibleAt, isNull);
    },
  );

  test(
    'unknown outcome blocks newer mutation for the same logical key',
    () async {
      const logicalKeyHash = 'shared-unknown-logical-key';

      Future<CloudOutboxOperation> enqueue(int revision) {
        return store.enqueueOutboxMutation(
          CloudOutboxDraft(
            scope: scope,
            logicalEntityKeyHash: logicalKeyHash,
            action: CloudOutboxAction.save,
            payloadVersion: 1,
            encryptedPayloadReference: 'protected:shared-$revision',
            payloadSha256: 'digest:shared-$revision',
            dependencyOperationIds: const [],
            createdAt: testEpoch.add(Duration(seconds: revision)),
          ),
        );
      }

      final first = await enqueue(1);
      expect(first.mutationRevision, 1);
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'shared-unknown-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'shared-unknown-lease',
        transitions: [CloudOutboxTransition.unknownOutcome(first.operationId)],
        now: testEpoch,
      );
      final second = await enqueue(2);
      expect(second.mutationRevision, 2);

      expect(
        await store.leaseEligibleOutbox(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'shared-newer-lease',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        ),
        isEmpty,
      );
      await store.advanceOutboxGeneration(scope, now: testEpoch);
      expect(
        (await store.outboxEntries(scope))
            .where(
              (row) =>
                  row.operationId == first.operationId ||
                  row.operationId == second.operationId,
            )
            .map((row) => row.status),
        everyElement(CloudOutboxStatus.quarantined),
      );
    },
  );

  test('coordinator lease renews and cannot be stolen before expiry', () async {
    final fence = await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'owner-a',
      now: testEpoch,
      leaseDuration: const Duration(minutes: 1),
    );
    expect(fence, isNotNull);
    expect(
      await store.renewCoordinatorLease(
        scope,
        leaseFence: fence!,
        now: testEpoch.add(const Duration(seconds: 30)),
        leaseDuration: const Duration(minutes: 1),
      ),
      isTrue,
    );
    expect(
      await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'owner-b',
        now: testEpoch.add(const Duration(seconds: 61)),
        leaseDuration: const Duration(minutes: 1),
      ),
      isNull,
    );
    final takeoverFence = await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'owner-b',
      now: testEpoch.add(const Duration(seconds: 91)),
      leaseDuration: const Duration(minutes: 1),
    );
    expect(takeoverFence, isNotNull);
    await store.releaseCoordinatorLease(scope, leaseFence: fence);
    expect(
      await store.renewCoordinatorLease(
        scope,
        leaseFence: takeoverFence!,
        now: testEpoch.add(const Duration(seconds: 92)),
        leaseDuration: const Duration(minutes: 1),
      ),
      isTrue,
    );
  });

  test('coordinator lease status reports only an active expiry', () async {
    expect(
      await store.readActiveCoordinatorLeaseExpiry(scope, now: testEpoch),
      isNull,
    );
    await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'owner-a',
      now: testEpoch,
      leaseDuration: const Duration(minutes: 1),
    );
    expect(
      await store.readActiveCoordinatorLeaseExpiry(scope, now: testEpoch),
      testEpoch.add(const Duration(minutes: 1)),
    );
    expect(
      await store.readActiveCoordinatorLeaseExpiry(
        scope,
        now: testEpoch.add(const Duration(minutes: 1)),
      ),
      isNull,
    );
  });

  test('stale coordinator cannot regress token after lease takeover', () async {
    final firstFence = (await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'owner-first',
      now: testEpoch,
      leaseDuration: const Duration(minutes: 1),
    ))!;
    final initial = await store.readCheckpoint(scope);
    final secondFence = (await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'owner-second',
      now: testEpoch.add(const Duration(seconds: 61)),
      leaseDuration: const Duration(minutes: 1),
    ))!;
    expect(secondFence.generation, greaterThan(firstFence.generation));

    await store.journalShadowFetchedBatch(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(2)],
        batchId: 'second-owner-page',
        generation: initial.generation,
        nextToken: 'token-newer',
        hasMore: false,
      ),
      now: testEpoch.add(const Duration(seconds: 61)),
      budget: CloudShadowJournalBudget(),
      leaseFence: secondFence,
      expectedGeneration: initial.generation,
      expectedFetchedToken: initial.fetchedToken,
    );

    await expectLater(
      store.journalShadowFetchedBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'stale-first-owner-page',
          generation: initial.generation,
          nextToken: 'token-stale',
          hasMore: false,
        ),
        now: testEpoch.add(const Duration(seconds: 62)),
        budget: CloudShadowJournalBudget(),
        leaseFence: firstFence,
        expectedGeneration: initial.generation,
        expectedFetchedToken: initial.fetchedToken,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'coordinator_lease_fence_lost',
        ),
      ),
    );

    expect((await store.readCheckpoint(scope)).fetchedToken, 'token-newer');
    expect(await store.inboxEntries(scope), hasLength(1));
  });

  test(
    'same-owner takeover fences fallback inbox transitions and release',
    () async {
      await _journal(
        store,
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'fallback-fence-page',
          generation: 1,
          nextToken: 'fallback-token',
          hasMore: false,
        ),
      );
      final staleFence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'same-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 1),
      ))!;
      await store.releaseCoordinatorLease(scope, leaseFence: staleFence);
      final currentFence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'same-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 1),
      ))!;

      await expectLater(
        store.markInboxApplied(
          scope,
          sequence: 1,
          now: testEpoch,
          leaseFence: staleFence,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'coordinator_lease_fence_lost',
          ),
        ),
      );
      await store.releaseCoordinatorLease(scope, leaseFence: staleFence);
      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: currentFence,
      );
      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: currentFence,
      );
      await expectLater(
        store.quarantineInbox(
          scope,
          sequence: 1,
          category: CloudFailureCategory.malformedRecord,
          now: testEpoch,
          leaseFence: currentFence,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'inbox_transition_not_pending',
          ),
        ),
      );
      expect((await store.inboxEntries(scope)).single.attemptCount, 0);
    },
  );

  test('pull failure state survives a new engine instance', () async {
    final nextTime = testEpoch.add(const Duration(minutes: 1));
    await store.recordPullFailure(
      scope,
      category: CloudFailureCategory.network,
      nextEligibleAt: nextTime,
    );

    final checkpoint = await store.readCheckpoint(scope);
    expect(checkpoint.consecutivePullFailures, 1);
    expect(checkpoint.nextPullEligibleAt, nextTime);

    await store.recordPullSuccess(scope, now: nextTime);
    final recovered = await store.readCheckpoint(scope);
    expect(recovered.consecutivePullFailures, 0);
    expect(recovered.nextPullEligibleAt, isNull);
  });

  test(
    'server record mapping is assigned once but metadata may advance',
    () async {
      final original = CloudRecordMapEntry(
        scope: scope,
        logicalEntityKeyHash: 'logical-key-digest',
        serverRecordIdHash: 'server-record-hash',
        encryptedServerRecordId: 'protected:server-record',
        etagHash: 'etag-a',
        updatedAt: testEpoch,
      );
      await store.upsertRecordMap(original, generation: 1);
      await store.upsertRecordMap(
        CloudRecordMapEntry(
          scope: scope,
          logicalEntityKeyHash: 'logical-key-digest',
          serverRecordIdHash: 'server-record-hash',
          encryptedServerRecordId: 'protected:server-record',
          etagHash: 'etag-b',
          updatedAt: testEpoch.add(const Duration(minutes: 1)),
        ),
        generation: 1,
      );
      expect(
        (await store.readRecordMap(
          scope,
          logicalEntityKeyHash: 'logical-key-digest',
          generation: 1,
        ))!.etagHash,
        'etag-b',
      );

      await expectLater(
        store.upsertRecordMap(
          CloudRecordMapEntry(
            scope: scope,
            logicalEntityKeyHash: 'logical-key-digest',
            serverRecordIdHash: 'different-server-record-hash',
            encryptedServerRecordId: 'protected:different-server-record',
            updatedAt: testEpoch,
          ),
          generation: 1,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (error) => error.safeCode,
            'safeCode',
            'server_mapping_changed',
          ),
        ),
      );
    },
  );

  test('record mappings cannot cross a checkpoint generation', () async {
    final generationOne = CloudRecordMapEntry(
      scope: scope,
      logicalEntityKeyHash: 'generation-bound-logical-key',
      serverRecordIdHash: 'generation-one-server-record',
      encryptedServerRecordId: 'protected:generation-one-record',
      updatedAt: testEpoch,
    );
    await store.upsertRecordMap(generationOne, generation: 1);
    await store.advanceOutboxGeneration(scope, now: testEpoch);

    await expectLater(
      store.readRecordMap(
        scope,
        logicalEntityKeyHash: generationOne.logicalEntityKeyHash,
        generation: 1,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'record_map_generation_mismatch',
        ),
      ),
    );
    expect(
      await store.readRecordMap(
        scope,
        logicalEntityKeyHash: generationOne.logicalEntityKeyHash,
        generation: 2,
      ),
      isNull,
    );

    final generationTwo = CloudRecordMapEntry(
      scope: scope,
      logicalEntityKeyHash: generationOne.logicalEntityKeyHash,
      serverRecordIdHash: 'generation-two-server-record',
      encryptedServerRecordId: 'protected:generation-two-record',
      updatedAt: testEpoch,
    );
    await store.upsertRecordMap(generationTwo, generation: 2);
    expect(
      (await store.readRecordMap(
        scope,
        logicalEntityKeyHash: generationOne.logicalEntityKeyHash,
        generation: 2,
      ))?.serverRecordIdHash,
      generationTwo.serverRecordIdHash,
    );
  });

  test('leases only due unknown outcomes in deterministic order', () async {
    Future<void> makeUnknown(
      CloudOutboxOperation operation, {
      DateTime? nextEligibleAt,
    }) async {
      await store.enqueueOutbox(operation);
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'seed-${operation.operationId}',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await store.markOutboxSubmissionStarted(
        scope,
        leaseId: 'seed-${operation.operationId}',
        submissionIdentity: testSubmissionIdentity([operation.operationId]),
        now: testEpoch,
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'seed-${operation.operationId}',
        transitions: [
          CloudOutboxTransition.unknownOutcome(
            operation.operationId,
            nextEligibleAt: nextEligibleAt,
          ),
        ],
        now: testEpoch,
      );
    }

    final live = testOutboxOperation(scope, 102, revision: 2);
    final expired = testOutboxOperation(scope, 105, revision: 5);
    await makeUnknown(live);
    await store.leaseUnknownOutcomes(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'live-unknown-lease',
      leaseDuration: const Duration(hours: 1),
    );

    final backoff = testOutboxOperation(scope, 103, revision: 3);
    final backoffUntil = testEpoch.add(const Duration(hours: 1));
    await makeUnknown(backoff, nextEligibleAt: backoffUntil);
    await makeUnknown(expired);
    await store.leaseUnknownOutcomes(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'expired-unknown-lease',
      leaseDuration: const Duration(seconds: 1),
    );
    final due = testOutboxOperation(scope, 101, revision: 1);
    await makeUnknown(due);
    final pending = testOutboxOperation(scope, 104, revision: 4);
    await store.enqueueOutbox(pending);

    final takeoverAt = testEpoch.add(const Duration(seconds: 2));
    final leased = await store.leaseUnknownOutcomes(
      scope,
      now: takeoverAt,
      limit: 10,
      leaseId: 'reconcile-lease',
      leaseDuration: const Duration(minutes: 1),
    );

    expect(leased.map((operation) => operation.operationId), [
      due.operationId,
      expired.operationId,
    ]);
    expect(
      leased,
      everyElement(
        isA<CloudOutboxOperation>()
            .having(
              (operation) => operation.status,
              'status',
              CloudOutboxStatus.unknownOutcome,
            )
            .having(
              (operation) => operation.leaseId,
              'leaseId',
              'reconcile-lease',
            ),
      ),
    );
    final rows = await store.outboxEntries(scope);
    expect(
      rows.singleWhere((row) => row.operationId == live.operationId).leaseId,
      'live-unknown-lease',
    );
    expect(
      rows.singleWhere((row) => row.operationId == backoff.operationId).leaseId,
      isNull,
    );
    expect(
      rows.singleWhere((row) => row.operationId == pending.operationId).status,
      CloudOutboxStatus.pending,
    );
  });

  test(
    'unknown transition persists reconciliation backoff and clears its lease',
    () async {
      final operation = testOutboxOperation(scope, 106);
      await store.enqueueOutbox(operation);
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'seed-backoff-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await store.markOutboxSubmissionStarted(
        scope,
        leaseId: 'seed-backoff-lease',
        submissionIdentity: testSubmissionIdentity([operation.operationId]),
        now: testEpoch,
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'seed-backoff-lease',
        transitions: [
          CloudOutboxTransition.unknownOutcome(operation.operationId),
        ],
        now: testEpoch,
      );

      final retryAt = testEpoch.add(const Duration(minutes: 5));
      await store.leaseUnknownOutcomes(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'reconcile-backoff-lease',
        leaseDuration: const Duration(minutes: 1),
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'reconcile-backoff-lease',
        transitions: [
          CloudOutboxTransition.unknownOutcome(
            operation.operationId,
            nextEligibleAt: retryAt,
          ),
        ],
        now: testEpoch,
      );

      var row = (await store.outboxEntries(scope)).single;
      expect(row.status, CloudOutboxStatus.unknownOutcome);
      expect(row.nextEligibleAt, retryAt);
      expect(row.leaseId, isNull);
      expect(
        await store.leaseUnknownOutcomes(
          scope,
          now: retryAt.subtract(const Duration(seconds: 1)),
          limit: 1,
          leaseId: 'too-early-lease',
          leaseDuration: const Duration(minutes: 1),
        ),
        isEmpty,
      );
      final eligible = await store.leaseUnknownOutcomes(
        scope,
        now: retryAt,
        limit: 1,
        leaseId: 'due-again-lease',
        leaseDuration: const Duration(minutes: 1),
      );
      expect(eligible.single.operationId, operation.operationId);
      row = (await store.outboxEntries(scope)).single;
      expect(row.status, CloudOutboxStatus.unknownOutcome);
      expect(row.leaseId, 'due-again-lease');
    },
  );

  test('unknown-outcome leasing isolates account and generation', () async {
    final otherScope = testScope(account: testAccountFingerprintB);
    final other = testOutboxOperation(otherScope, 107);
    await store.enqueueOutbox(other);
    await store.leaseEligibleOutbox(
      otherScope,
      now: testEpoch,
      limit: 1,
      leaseId: 'other-seed-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    await store.markOutboxSubmissionStarted(
      otherScope,
      leaseId: 'other-seed-lease',
      submissionIdentity: testSubmissionIdentity([other.operationId]),
      now: testEpoch,
    );
    await store.applyOutboxTransitions(
      otherScope,
      leaseId: 'other-seed-lease',
      transitions: [CloudOutboxTransition.unknownOutcome(other.operationId)],
      now: testEpoch,
    );

    final stale = testOutboxOperation(scope, 108);
    await store.enqueueOutbox(stale);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'stale-seed-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    await store.markOutboxSubmissionStarted(
      scope,
      leaseId: 'stale-seed-lease',
      submissionIdentity: testSubmissionIdentity([stale.operationId]),
      now: testEpoch,
    );
    await store.applyOutboxTransitions(
      scope,
      leaseId: 'stale-seed-lease',
      transitions: [CloudOutboxTransition.unknownOutcome(stale.operationId)],
      now: testEpoch,
    );
    await store.advanceOutboxGeneration(scope, now: testEpoch);

    expect(
      await store.leaseUnknownOutcomes(
        scope,
        now: testEpoch,
        limit: 10,
        leaseId: 'scope-lease',
        leaseDuration: const Duration(minutes: 1),
      ),
      isEmpty,
    );
    final otherLeased = await store.leaseUnknownOutcomes(
      otherScope,
      now: testEpoch,
      limit: 1,
      leaseId: 'other-reconcile-lease',
      leaseDuration: const Duration(minutes: 1),
    );
    expect(otherLeased.single.operationId, other.operationId);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.quarantined,
    );
  });
}

Future<int> _journal(
  InMemoryCloudSyncStore store,
  CloudFetchBatch batch,
) async {
  const ownerId = 'general-journal-owner';
  final fence = (await store.tryAcquireCoordinatorLease(
    batch.scope,
    ownerId: ownerId,
    now: testEpoch,
    leaseDuration: const Duration(hours: 1),
  ))!;
  final checkpoint = await store.readCheckpoint(batch.scope);
  try {
    return await store.journalFetchedBatch(
      batch,
      now: testEpoch,
      leaseFence: fence,
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
  } finally {
    await store.releaseCoordinatorLease(batch.scope, leaseFence: fence);
  }
}
