import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/shadow_only_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  final scope = testScope();
  final now = DateTime.utc(2026, 8, 1);

  test('delegates only shadow journal and checkpoint capabilities', () async {
    final delegate = InMemoryCloudSyncStore();
    final store = ShadowOnlyCloudSyncStore(delegate);
    final fence = await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'shadow-owner',
      now: now,
      leaseDuration: const Duration(minutes: 5),
    );
    expect(fence, isNotNull);

    final batch = CloudFetchBatch(
      scope: scope,
      changes: [testChange(1)],
      batchId: 'shadow-batch-1',
      generation: 1,
      nextToken: 'token-1',
      hasMore: false,
    );
    final admission = await store.journalShadowFetchedBatch(
      batch,
      now: now,
      budget: CloudShadowJournalBudget(),
      leaseFence: fence!,
      expectedGeneration: 1,
      expectedFetchedToken: null,
    );

    expect(admission.insertedEntries, 1);
    expect((await store.readCheckpoint(scope)).fetchedToken, 'token-1');
    await store.releaseCoordinatorLease(scope, leaseFence: fence);
  });

  test(
    'blocks the general journal even when the delegate supports it',
    () async {
      final store = ShadowOnlyCloudSyncStore(InMemoryCloudSyncStore());

      await expectLater(
        store.journalFetchedBatch(
          CloudFetchBatch(
            scope: scope,
            changes: [testChange(1)],
            batchId: 'general-batch-1',
            generation: 1,
            nextToken: 'token-1',
            hasMore: false,
          ),
          now: now,
          leaseFence: const CloudCoordinatorLeaseFence(
            ownerId: 'blocked-owner',
            generation: 1,
          ),
          expectedGeneration: 1,
          expectedFetchedToken: null,
        ),
        throwsA(isA<CloudSyncShadowStoreTripwireException>()),
      );
    },
  );

  test('blocks semantic inbox and record-map capabilities', () async {
    final store = ShadowOnlyCloudSyncStore(InMemoryCloudSyncStore());

    await expectLater(
      store.readEligibleInbox(scope, now: now, limit: 1),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
    await expectLater(
      store.markInboxApplied(
        scope,
        sequence: 1,
        now: now,
        leaseFence: const CloudCoordinatorLeaseFence(
          ownerId: 'blocked-owner',
          generation: 1,
        ),
      ),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
    await expectLater(
      store.markInboxRetainedUnprojected(
        scope,
        sequence: 1,
        category: CloudFailureCategory.malformedRecord,
        now: now,
        maximumDeferredAttempts: 1,
        maximumDeferredAge: Duration.zero,
        leaseFence: const CloudCoordinatorLeaseFence(
          ownerId: 'blocked-owner',
          generation: 1,
        ),
      ),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
    await expectLater(
      store.recoverRetainedInboxBarriers(
        scope,
        now: now,
        maximumDeferredAttempts: 1,
        maximumDeferredAge: Duration.zero,
        leaseFence: const CloudCoordinatorLeaseFence(
          ownerId: 'blocked-owner',
          generation: 1,
        ),
      ),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
    await expectLater(
      store.readRecordMap(scope, logicalEntityKeyHash: 'entity', generation: 1),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
  });

  test('blocks every outbox entry point', () async {
    final store = ShadowOnlyCloudSyncStore(InMemoryCloudSyncStore());
    final operation = testOutboxOperation(scope, 1);

    await expectLater(
      store.enqueueOutbox(operation),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
    await expectLater(
      store.leaseEligibleOutbox(
        scope,
        now: now,
        limit: 1,
        leaseId: 'lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      ),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
    await expectLater(
      store.recoverExpiredOutboxLeases(scope, now: now),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
  });
}
