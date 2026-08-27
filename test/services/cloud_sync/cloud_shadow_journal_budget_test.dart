import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late InMemoryCloudSyncStore store;
  late CloudSyncScope scope;
  final fences = <String, CloudCoordinatorLeaseFence>{};

  setUp(() {
    store = InMemoryCloudSyncStore();
    scope = testScope();
    fences.clear();
  });

  Future<CloudShadowJournalAdmission> journalShadow(
    CloudFetchBatch value, {
    required DateTime now,
    required CloudShadowJournalBudget budget,
  }) async {
    final scoped = value.scope;
    final fence = fences[scoped.storageKey] ??= (await store
        .tryAcquireCoordinatorLease(
          scoped,
          ownerId: 'budget-test-${scoped.accountFingerprint}',
          now: now,
          leaseDuration: const Duration(days: 1),
        ))!;
    final checkpoint = await store.readCheckpoint(scoped);
    return store.journalShadowFetchedBatch(
      value,
      now: now,
      budget: budget,
      leaseFence: fence,
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
  }

  CloudFetchBatch batch({
    required String id,
    required String? token,
    required List<CloudFetchedChange> changes,
    CloudSyncScope? scoped,
  }) {
    return CloudFetchBatch(
      scope: scoped ?? scope,
      changes: changes,
      batchId: id,
      generation: 1,
      nextToken: token,
      hasMore: false,
    );
  }

  test(
    'accepts exact entry and byte boundaries, then blocks without mutation',
    () async {
      final estimator = CloudShadowJournalBudget();
      final change = testChange(1);
      const batchId = 'exact-boundary';
      final exactBytes = estimator.estimateEntryBytes(
        scope: scope,
        batchId: batchId,
        change: change,
      );
      final budget = CloudShadowJournalBudget(
        maximumEntriesPerScope: 1,
        maximumEstimatedBytesPerScope: exactBytes,
      );

      final accepted = await journalShadow(
        batch(id: batchId, token: 'token-1', changes: [change]),
        now: testEpoch,
        budget: budget,
      );
      expect(accepted.admitted, isTrue);
      expect(accepted.usage.pendingEntries, 1);
      expect(accepted.usage.estimatedBytes, exactBytes);

      final blocked = await journalShadow(
        batch(
          id: 'must-not-commit',
          token: 'token-2',
          changes: [testChange(2)],
        ),
        now: testEpoch,
        budget: budget,
      );
      expect(blocked.blockReason, CloudShadowJournalBlockReason.maximumEntries);
      expect((await store.readCheckpoint(scope)).fetchedToken, 'token-1');
      expect(await store.inboxEntries(scope), hasLength(1));
    },
  );

  test(
    'rejects a page that would cross the entry boundary atomically',
    () async {
      final budget = CloudShadowJournalBudget(
        maximumEntriesPerScope: 1,
        maximumEstimatedBytesPerScope: 1024 * 1024,
      );

      final admission = await journalShadow(
        batch(
          id: 'oversized-page',
          token: 'must-not-commit',
          changes: [testChange(1), testChange(2)],
        ),
        now: testEpoch,
        budget: budget,
      );

      expect(
        admission.blockReason,
        CloudShadowJournalBlockReason.maximumEntries,
      );
      expect(admission.rejectedEntries, 2);
      expect(await store.inboxEntries(scope), isEmpty);
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect((await store.readCheckpoint(scope)).fetchedSequence, 0);
    },
  );

  test('rejects one byte over the deterministic estimate boundary', () async {
    final estimator = CloudShadowJournalBudget();
    final change = testChange(1);
    const batchId = 'byte-boundary';
    final estimated = estimator.estimateEntryBytes(
      scope: scope,
      batchId: batchId,
      change: change,
    );
    final budget = CloudShadowJournalBudget(
      maximumEstimatedBytesPerScope: estimated - 1,
    );

    final admission = await journalShadow(
      batch(id: batchId, token: 'must-not-commit', changes: [change]),
      now: testEpoch,
      budget: budget,
    );

    expect(
      admission.blockReason,
      CloudShadowJournalBlockReason.maximumEstimatedBytes,
    );
    expect(admission.rejectedEntries, 1);
    expect(await store.inboxEntries(scope), isEmpty);
    expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
  });

  test('age boundary is deterministic and never prunes pending data', () async {
    final budget = CloudShadowJournalBudget(
      maximumPendingAge: const Duration(days: 1),
    );
    await journalShadow(
      batch(id: 'legacy-page', token: 'legacy-token', changes: [testChange(1)]),
      now: testEpoch,
      budget: budget,
    );
    final usage = await store.readShadowJournalUsage(scope, budget: budget);

    expect(
      budget.blockReasonForCurrentUsage(
        usage,
        now: testEpoch.add(const Duration(days: 1)),
      ),
      isNull,
    );
    expect(
      budget.blockReasonForCurrentUsage(
        usage,
        now: testEpoch.add(const Duration(days: 1, microseconds: 1)),
      ),
      CloudShadowJournalBlockReason.maximumAge,
    );
    expect(await store.inboxEntries(scope), hasLength(1));
    expect((await store.readCheckpoint(scope)).fetchedToken, 'legacy-token');
  });

  test(
    'usage and admission limits are isolated by full account scope',
    () async {
      final other = testScope(account: testAccountFingerprintB);
      final budget = CloudShadowJournalBudget(maximumEntriesPerScope: 1);
      await journalShadow(
        batch(id: 'scope-a', token: 'token-a', changes: [testChange(1)]),
        now: testEpoch,
        budget: budget,
      );

      final otherAdmission = await journalShadow(
        batch(
          id: 'scope-b',
          token: 'token-b',
          changes: [testChange(2)],
          scoped: other,
        ),
        now: testEpoch,
        budget: budget,
      );

      expect(otherAdmission.admitted, isTrue);
      expect(
        (await store.readShadowJournalUsage(
          scope,
          budget: budget,
        )).pendingEntries,
        1,
      );
      expect(
        (await store.readShadowJournalUsage(
          other,
          budget: budget,
        )).pendingEntries,
        1,
      );
    },
  );

  test(
    'applied records are retained but no longer consume pending budget',
    () async {
      final budget = CloudShadowJournalBudget(maximumEntriesPerScope: 1);
      await journalShadow(
        batch(id: 'applied-page', token: 'token-1', changes: [testChange(1)]),
        now: testEpoch,
        budget: budget,
      );
      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: fences[scope.storageKey]!,
      );

      final usage = await store.readShadowJournalUsage(scope, budget: budget);
      expect(usage.pendingEntries, 0);
      expect(usage.estimatedBytes, 0);
      expect(usage.oldestPendingAt, isNull);
      expect(await store.inboxEntries(scope), hasLength(1));
      expect(
        (await store.inboxEntries(scope)).single.status,
        CloudInboxStatus.applied,
      );
    },
  );
}
