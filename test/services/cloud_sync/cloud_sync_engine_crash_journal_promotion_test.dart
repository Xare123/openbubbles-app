import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_backoff.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

/// Focused crash/restart test for the seam between inbox journal commit and
/// continuation-token promotion.
///
/// A non-terminal page holds its continuation token as pending until every
/// journaled row reaches a terminal inbox state. This test crashes
/// deterministically right after the journal commit, then proves:
/// 1. a second writer's fresh fetch stays fenced while the pending page is
///    unresolved (no new transport fetch, no token movement);
/// 2. reopening applies each journaled row exactly once and continues from
///    the pending token without refetching the crashed page;
/// 3. a stale writer retrying with pre-crash generation/fetched-token
///    observations is rejected by compare-and-swap with no new projection;
/// 4. a further restart re-projects nothing.
///
/// Uses only FakeCloudSyncTransport and the in-memory store. No credentials,
/// user data, live Apple services, or network.
void main() {
  late CloudSyncScope scope;
  late _CrashOnceAfterJournalStore store;
  late FakeCloudSyncTransport transport;
  late FakeCloudInboxApplier applier;
  late FakeCloudSyncWriterAuthority writerAuthority;
  late FakeCloudKitOperationExclusion writerExclusion;
  late MutableTestClock clock;

  CloudSyncEngine engine({
    String coordinatorId = 'coordinator-a',
    FakeCloudInboxApplier? inboxApplier,
  }) {
    return CloudSyncEngine(
      scope: scope,
      coordinatorId: coordinatorId,
      store: store,
      transport: transport,
      inboxApplier: inboxApplier ?? applier,
      writerAuthority: writerAuthority,
      writerExclusion: writerExclusion,
      backoff: CloudSyncBackoffPolicy(
        baseDelay: const Duration(seconds: 10),
        maximumDelay: const Duration(minutes: 1),
        randomUnit: () => 1,
      ),
      observer: MemoryCloudSyncObserver(),
      clock: clock.call,
      config: CloudSyncEngineConfig(
        maximumBatchSize: 256,
        maximumFetchPagesPerRun: 8,
        maximumInboxEntriesPerRun: 512,
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: true,
        ),
      ),
    );
  }

  setUp(() {
    scope = testScope();
    store = _CrashOnceAfterJournalStore();
    transport = FakeCloudSyncTransport();
    applier = FakeCloudInboxApplier();
    writerAuthority = FakeCloudSyncWriterAuthority();
    writerExclusion = FakeCloudKitOperationExclusion();
    clock = MutableTestClock(testEpoch);
  });

  Future<void> expectStaleJournalRejected({
    required int expectedGeneration,
    required String? expectedFetchedToken,
  }) async {
    final fence = (await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'stale-writer-retry',
      now: clock.value,
      leaseDuration: const Duration(minutes: 5),
    ))!;
    try {
      await expectLater(
        store.journalFetchedBatch(
          CloudFetchBatch(
            scope: scope,
            changes: [testChange(1)],
            batchId: 'batch-crash-page-one',
            generation: 1,
            nextToken: 'token-after-page-one',
            hasMore: true,
          ),
          now: clock.value,
          leaseFence: fence,
          expectedGeneration: expectedGeneration,
          expectedFetchedToken: expectedFetchedToken,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'checkpoint_compare_and_swap_failed',
          ),
        ),
      );
    } finally {
      await store.releaseCoordinatorLease(scope, leaseFence: fence);
    }
  }

  test(
    'crash between journal commit and token promotion reopens exactly once',
    () async {
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(requestedScope, scope);
            expect(generation, 1);
            if (previousToken != null) {
              fail('crashed page must never be refetched');
            }
            return CloudFetchBatch(
              scope: scope,
              changes: [testChange(1)],
              batchId: 'batch-crash-page-one',
              generation: generation,
              nextToken: 'token-after-page-one',
              hasMore: true,
            );
          };

      final crashed = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      // Phase 1: the process dies after the journal commit, before any row
      // is applied and before the pending token promotes.
      expect(crashed.status, CloudSyncRunStatus.failed);
      expect(transport.fetchCallCount, 1);
      expect(transport.observedFetchTokens, [null]);
      var checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.pendingBatchId, 'batch-crash-page-one');
      expect(checkpoint.fetchedToken, isNull);
      expect(checkpoint.lastAppliedSequence, 0);
      expect(await store.inboxEntries(scope), hasLength(1));
      expect(applier.appliedSequences, isEmpty);

      // Phase 2: while the pending page is unresolved, a second writer's
      // fresh fetch stays fenced. No new transport call, no token movement.
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.network,
      );
      transport.fetchHandler = (_, _, _, _) async =>
          fail('fresh fetch must stay fenced behind the pending page');

      final blocked = await engine(
        coordinatorId: 'coordinator-second-writer',
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(blocked.status, CloudSyncRunStatus.degraded);
      expect(blocked.failureCategory, CloudFailureCategory.dependency);
      expect(blocked.failureSafeCode, 'checkpoint_pending_page_unresolved');
      expect(blocked.counters.fetched, 0);
      expect(transport.fetchCallCount, 1);
      expect(transport.observedFetchTokens, [null]);
      checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.pendingBatchId, 'batch-crash-page-one');
      expect(checkpoint.fetchedToken, isNull);
      expect(checkpoint.lastAppliedSequence, 0);

      // Phase 3: reopening applies each journaled row exactly once, promotes
      // the pending token, and continues from it without refetching page one.
      applier.resultsBySequence[1] = const CloudInboxApplyResult.applied();
      clock.advance(const Duration(seconds: 60));
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(requestedScope, scope);
            expect(previousToken, 'token-after-page-one');
            return CloudFetchBatch(
              scope: scope,
              changes: [testChange(2)],
              batchId: 'batch-resumed-page-two',
              generation: generation,
              nextToken: 'token-after-page-two',
              hasMore: false,
            );
          };

      final resumed = await engine(
        coordinatorId: 'coordinator-after-crash',
      ).synchronize(trigger: CloudSyncTrigger.startup);

      expect(resumed.status, CloudSyncRunStatus.completed);
      expect(transport.fetchCallCount, 2);
      expect(transport.observedFetchTokens, [null, 'token-after-page-one']);
      // Row 1 was attempted once while unresolved and applied once after
      // recovery; row 2 was fetched and applied once. No row projects twice.
      expect(applier.appliedSequences, [1, 1, 2]);
      final rows = await store.inboxEntries(scope);
      expect(rows, hasLength(2));
      expect(
        rows.map((entry) => entry.status),
        everyElement(CloudInboxStatus.applied),
      );
      expect(rows.map((entry) => entry.change.changeId).toSet(), hasLength(2));
      checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.pendingBatchId, isNull);
      expect(checkpoint.fetchedToken, 'token-after-page-two');
      expect(checkpoint.lastAppliedSequence, 2);

      // Phase 4: the crashed writer's stale observations (pre-crash token
      // and a wrong generation) are both rejected by compare-and-swap with
      // no new rows projected.
      clock.advance(const Duration(minutes: 6));
      await expectStaleJournalRejected(
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: null,
      );
      await expectStaleJournalRejected(
        expectedGeneration: checkpoint.generation + 1,
        expectedFetchedToken: checkpoint.fetchedToken,
      );
      expect(await store.inboxEntries(scope), hasLength(2));
      final after = await store.readCheckpoint(scope);
      expect(after.fetchedToken, 'token-after-page-two');
      expect(after.pendingBatchId, isNull);
      expect(after.lastAppliedSequence, 2);

      // Phase 5: a further restart re-projects nothing.
      final steadyApplier = FakeCloudInboxApplier();
      final fetchesBeforeSteady = transport.fetchCallCount;
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(previousToken, 'token-after-page-two');
            return CloudFetchBatch(
              scope: scope,
              changes: const [],
              batchId: 'steady-empty-page',
              generation: generation,
              nextToken: previousToken,
              hasMore: false,
            );
          };
      final steady = await engine(
        coordinatorId: 'coordinator-steady',
        inboxApplier: steadyApplier,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(steadyApplier.appliedSequences, isEmpty);
      expect(transport.fetchCallCount, fetchesBeforeSteady + 1);
      expect(await store.inboxEntries(scope), hasLength(2));
      final steadyCheckpoint = await store.readCheckpoint(scope);
      expect(steadyCheckpoint.fetchedToken, 'token-after-page-two');
      expect(steadyCheckpoint.pendingBatchId, isNull);
      expect(steadyCheckpoint.lastAppliedSequence, 2);
    },
  );
}

/// Commits the first journal normally, then throws to simulate a process
/// crash between the inbox journal commit and continuation-token promotion.
class _CrashOnceAfterJournalStore extends InMemoryCloudSyncStore {
  int journalCallCount = 0;

  @override
  Future<int> journalFetchedBatch(
    CloudFetchBatch batch, {
    required DateTime now,
    required CloudCoordinatorLeaseFence leaseFence,
    required int expectedGeneration,
    required String? expectedFetchedToken,
  }) async {
    journalCallCount++;
    final inserted = await super.journalFetchedBatch(
      batch,
      now: now,
      leaseFence: leaseFence,
      expectedGeneration: expectedGeneration,
      expectedFetchedToken: expectedFetchedToken,
    );
    if (journalCallCount == 1) {
      throw StateError('simulated_process_crash_after_journal_commit');
    }
    return inserted;
  }
}
