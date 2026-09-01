import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_backoff.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_cancellation.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/shadow_only_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late CloudSyncScope scope;
  late InMemoryCloudSyncStore store;
  late FakeCloudSyncTransport transport;
  late FakeCloudInboxApplier applier;
  late FakeCloudSyncWriterAuthority writerAuthority;
  late FakeCloudKitOperationExclusion writerExclusion;
  late MutableTestClock clock;

  CloudSyncEngine engine({
    CloudSyncFeatureFlags flags = const CloudSyncFeatureFlags(
      readOnlyFetch: true,
      semanticApply: true,
      saves: true,
    ),
    int batchSize = 256,
    int maximumFetchPagesPerRun = 8,
    int maximumInboxEntriesPerRun = 512,
    int minimumInboxEntriesReservedForFetch = 0,
    int maximumOutboxBatches = 8,
    Duration fetchOperationTimeout = const Duration(seconds: 45),
    Duration writeOperationTimeout = const Duration(seconds: 45),
    int maximumDeferredAttempts = 8,
    Duration maximumDeferredAge = const Duration(days: 3),
    Duration pausedRetryDelay = const Duration(hours: 6),
    Duration coordinatorLeaseDuration = const Duration(minutes: 5),
    Duration outboxLeaseDuration = const Duration(minutes: 2),
    bool allowManualPullBackoffOverride = false,
    DateTime? unknownInboxBarrierRecoveryCutoff,
    bool retainKnownDependencyDeferralsForReadOnlySemanticCanary = false,
    bool reconcileUnknownOutcomesOnly = false,
    MemoryCloudSyncObserver? observer,
    String coordinatorId = 'coordinator-a',
    CloudShadowJournalBudget? shadowJournalBudget,
    CloudSyncWriterAuthority? writerAuthorityOverride,
    CloudInboxApplier? inboxApplierOverride,
  }) {
    return CloudSyncEngine(
      scope: scope,
      coordinatorId: coordinatorId,
      store: store,
      transport: transport,
      inboxApplier: inboxApplierOverride ?? applier,
      writerAuthority: flags.saves
          ? writerAuthorityOverride ?? writerAuthority
          : null,
      writerExclusion: flags.saves ? writerExclusion : null,
      backoff: CloudSyncBackoffPolicy(
        baseDelay: const Duration(seconds: 10),
        maximumDelay: const Duration(minutes: 1),
        randomUnit: () => 1,
      ),
      observer: observer ?? MemoryCloudSyncObserver(),
      clock: clock.call,
      config: CloudSyncEngineConfig(
        maximumBatchSize: batchSize,
        maximumFetchPagesPerRun: maximumFetchPagesPerRun,
        maximumInboxEntriesPerRun: maximumInboxEntriesPerRun,
        minimumInboxEntriesReservedForFetch:
            minimumInboxEntriesReservedForFetch,
        maximumOutboxBatchesPerRun: maximumOutboxBatches,
        fetchOperationTimeout: fetchOperationTimeout,
        writeOperationTimeout: writeOperationTimeout,
        maximumDeferredAttempts: maximumDeferredAttempts,
        maximumDeferredAge: maximumDeferredAge,
        pausedRetryDelay: pausedRetryDelay,
        coordinatorLeaseDuration: coordinatorLeaseDuration,
        outboxLeaseDuration: outboxLeaseDuration,
        allowManualPullBackoffOverride: allowManualPullBackoffOverride,
        unknownInboxBarrierRecoveryCutoff: unknownInboxBarrierRecoveryCutoff,
        retainKnownDependencyDeferralsForReadOnlySemanticCanary:
            retainKnownDependencyDeferralsForReadOnlySemanticCanary,
        reconcileUnknownOutcomesOnly: reconcileUnknownOutcomesOnly,
        shadowJournalBudget: shadowJournalBudget ?? CloudShadowJournalBudget(),
        flags: flags,
      ),
    );
  }

  setUp(() {
    scope = testScope();
    store = InMemoryCloudSyncStore();
    transport = FakeCloudSyncTransport();
    applier = FakeCloudInboxApplier();
    writerAuthority = FakeCloudSyncWriterAuthority();
    writerExclusion = FakeCloudKitOperationExclusion();
    clock = MutableTestClock(testEpoch);
  });

  Future<void> seedGeneralJournal(
    CloudFetchBatch batch, {
    required DateTime now,
  }) async {
    const ownerId = 'engine-test-seed';
    final fence = (await store.tryAcquireCoordinatorLease(
      batch.scope,
      ownerId: ownerId,
      now: now,
      leaseDuration: const Duration(minutes: 5),
    ))!;
    final checkpoint = await store.readCheckpoint(batch.scope);
    try {
      await store.journalFetchedBatch(
        batch,
        now: now,
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );
    } finally {
      await store.releaseCoordinatorLease(batch.scope, leaseFence: fence);
    }
  }

  Future<void> seedShadowJournal(
    CloudFetchBatch batch, {
    required DateTime now,
  }) async {
    const ownerId = 'engine-test-shadow-seed';
    final fence = (await store.tryAcquireCoordinatorLease(
      batch.scope,
      ownerId: ownerId,
      now: now,
      leaseDuration: const Duration(minutes: 5),
    ))!;
    final checkpoint = await store.readCheckpoint(batch.scope);
    try {
      await store.journalShadowFetchedBatch(
        batch,
        now: now,
        budget: CloudShadowJournalBudget(),
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );
    } finally {
      await store.releaseCoordinatorLease(batch.scope, leaseFence: fence);
    }
  }

  Future<void> seedPausedOutbox(
    CloudOutboxOperation operation, {
    required CloudFailureCategory category,
  }) async {
    await store.enqueueOutbox(operation);
    final leased = await store.leaseEligibleOutbox(
      operation.scope,
      now: clock.value,
      limit: 1,
      leaseId: 'seed-lease-${operation.operationId}',
      leaseDuration: const Duration(minutes: 2),
      allowedActions: {operation.action},
    );
    expect(leased.single.operationId, operation.operationId);
    await store.applyOutboxTransitions(
      operation.scope,
      leaseId: 'seed-lease-${operation.operationId}',
      transitions: [
        CloudOutboxTransition.paused(operation.operationId, category: category),
      ],
      now: clock.value,
    );
  }

  Future<CloudOutboxOperation> seedAmbiguousOutbox(int index) async {
    final operation = testOutboxOperation(scope, index);
    await store.enqueueOutbox(operation);
    transport.enqueuePushResult(
      CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: operation.operationId,
            disposition: CloudPushDisposition.unknownOutcome,
            failureCategory: CloudFailureCategory.unknown,
          ),
        ],
      ),
    );
    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.unknownOutcome,
    );
    return (await store.outboxEntries(scope)).single;
  }

  test('fetches, journals, applies, and advances checkpoint', () async {
    transport.enqueueFetchBatch(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1), testChange(2)],
        batchId: 'batch-1',
        generation: 1,
        nextToken: 'opaque-token',
        hasMore: false,
      ),
    );

    final result = await engine().synchronize(trigger: CloudSyncTrigger.manual);

    expect(
      result.status,
      CloudSyncRunStatus.completed,
      reason:
          'failure=${result.failureCategory?.name} safeCode=${result.failureSafeCode}',
    );
    expect(writerExclusion.runCallCount, 1);
    expect(writerExclusion.observedKinds, [CloudKitOperationKind.v2ReadWrite]);
    expect(result.counters.fetched, 2);
    expect(result.counters.applied, 2);
    expect(result.observedEmptyTerminalRead, isFalse);
    expect(applier.appliedLeaseFences, hasLength(2));
    expect(
      applier.appliedLeaseFences.every(
        (fence) => fence.ownerId.isNotEmpty && fence.generation > 0,
      ),
      isTrue,
    );
    final checkpoint = await store.readCheckpoint(scope);
    expect(checkpoint.fetchedToken, 'opaque-token');
    expect(checkpoint.lastAppliedSequence, 2);
    expect(store.runs, hasLength(1));
    expect(store.runs.single.architectureName, 'generic');
    expect(store.runs.single.modeName, 'durable-saves/completed');
  });

  test('a full nonterminal page is not terminal-empty', () async {
    transport.fetchHandler =
        (requestedScope, previousToken, generation, limit) async {
          expect(limit, 1);
          if (previousToken == null) {
            return CloudFetchBatch(
              scope: requestedScope,
              changes: [testChange(101)],
              batchId: 'full-nonterminal-page',
              generation: generation,
              nextToken: 'after-full-page',
              hasMore: true,
            );
          }
          expect(previousToken, 'after-full-page');
          return CloudFetchBatch(
            scope: requestedScope,
            changes: const [],
            batchId: 'terminal-empty-page',
            generation: generation,
            nextToken: 'terminal-empty-token',
            hasMore: false,
          );
        };

    final result = await engine(
      batchSize: 1,
      maximumFetchPagesPerRun: 2,
    ).synchronize(trigger: CloudSyncTrigger.manual);

    expect(result.status, CloudSyncRunStatus.completed);
    expect(result.counters.fetched, 1);
    expect(result.observedEmptyTerminalRead, isFalse);
    expect(transport.observedFetchTokens, [null, 'after-full-page']);
  });

  test(
    'a duplicate nonempty page with no new journal rows is not terminal-empty',
    () async {
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            if (previousToken == null) {
              return CloudFetchBatch(
                scope: requestedScope,
                changes: [testChange(102)],
                batchId: 'original-page',
                generation: generation,
                nextToken: 'after-original-page',
                hasMore: false,
              );
            }
            expect(previousToken, 'after-original-page');
            return CloudFetchBatch(
              scope: requestedScope,
              changes: [testChange(102)],
              batchId: 'duplicate-page',
              generation: generation,
              nextToken: 'after-duplicate-page',
              hasMore: false,
            );
          };

      final first = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );
      final second = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(first.counters.fetched, 1);
      expect(first.observedEmptyTerminalRead, isFalse);
      expect(second.status, CloudSyncRunStatus.completed);
      expect(second.counters.fetched, 0);
      expect(second.counters.applied, 0);
      expect(second.observedEmptyTerminalRead, isFalse);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'after-duplicate-page',
      );
    },
  );

  test(
    'a successful terminal empty read sets terminal-empty evidence',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: const [],
          batchId: 'terminal-empty-only-page',
          generation: 1,
          nextToken: 'terminal-empty-only-token',
          hasMore: false,
        ),
      );

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(result.status, CloudSyncRunStatus.completed);
      expect(result.counters.fetched, 0);
      expect(result.observedEmptyTerminalRead, isTrue);
    },
  );

  test(
    'holds the write exclusion through prepared remote submission consumption',
    () async {
      final operation = testOutboxOperation(scope, 990);
      await store.enqueueOutbox(operation);
      transport.writePreflightHandler = (_, _, _) async {
        expect(writerExclusion.isActive, isTrue);
      };
      transport.preparedSubmissionHandler =
          (_, preparedSubmission, persistedIdentity) async {
            expect(writerExclusion.isActive, isTrue);
            return CloudPushBatchResult(
              outcomes: [
                CloudPushOutcome(
                  operationId: preparedSubmission.operationIds.single,
                  disposition: CloudPushDisposition.confirmed,
                ),
              ],
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: false,
          semanticApply: false,
          saves: true,
        ),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(result.status, CloudSyncRunStatus.completed);
      expect(result.counters.confirmed, 1);
      expect(transport.prepareSubmissionCallCount, 1);
      expect(transport.consumePreparedSubmissionCallCount, 1);
      expect(writerExclusion.runCallCount, 1);
      expect(writerExclusion.isActive, isFalse);
    },
  );

  test(
    'retention-policy transport preserves a confirmed protected receipt',
    () async {
      transport = _RetainingFakeCloudSyncTransport();
      final operation = testOutboxOperation(scope, 991);
      await store.enqueueOutbox(operation);
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        ),
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: false,
          semanticApply: false,
          saves: true,
        ),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      final stored = (await store.outboxEntries(scope)).single;
      expect(result.counters.confirmed, 1);
      expect(stored.status, CloudOutboxStatus.confirmed);
      expect(stored.protectedLeaseReference, operation.protectedLeaseReference);
    },
  );

  test(
    'passes persisted tokens across four pages, renews, and applies in order',
    () async {
      final renewingStore = _CountingCoordinatorRenewalStore();
      store = renewingStore;
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(requestedScope, scope);
            expect(generation, 1);
            expect(limit, 50);
            switch (previousToken) {
              case null:
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(1)],
                  batchId: 'batch-page-one',
                  generation: generation,
                  nextToken: 'token-page-one',
                  hasMore: true,
                );
              case 'token-page-one':
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(2)],
                  batchId: 'batch-page-two',
                  generation: generation,
                  nextToken: 'token-page-two',
                  hasMore: true,
                );
              case 'token-page-two':
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(3)],
                  batchId: 'batch-page-three',
                  generation: generation,
                  nextToken: 'token-page-three',
                  hasMore: true,
                );
              case 'token-page-three':
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(4)],
                  batchId: 'batch-page-four',
                  generation: generation,
                  nextToken: 'token-page-four',
                  hasMore: true,
                );
              default:
                fail('unexpected continuation token: $previousToken');
            }
          };

      final result = await engine(
        batchSize: 50,
        maximumFetchPagesPerRun: 4,
        maximumInboxEntriesPerRun: 200,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.completed);
      expect(result.counters.fetched, 4);
      expect(result.counters.applied, 4);
      expect(transport.observedFetchTokens, [
        null,
        'token-page-one',
        'token-page-two',
        'token-page-three',
      ]);
      expect(applier.appliedSequences, [1, 2, 3, 4]);
      expect((await store.inboxEntries(scope)).map((entry) => entry.batchId), [
        'batch-page-one',
        'batch-page-two',
        'batch-page-three',
        'batch-page-four',
      ]);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'token-page-four');
      expect(checkpoint.lastAppliedSequence, 4);
      // The test clock is fixed, so interval-based renewals are coalesced.
      // Each fetched page still forces a renewal before its journal commit.
      expect(renewingStore.renewalCalls, greaterThanOrEqualTo(4));
    },
  );

  test(
    'restart resumes after a post-journal page-one crash without refetching it',
    () async {
      store = _CrashAfterFirstJournalStore();
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(requestedScope, scope);
            expect(generation, 1);
            expect(limit, 256);
            switch (previousToken) {
              case null:
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(1)],
                  batchId: 'batch-crash-page-one',
                  generation: generation,
                  nextToken: 'token-after-page-one',
                  hasMore: true,
                );
              case 'token-after-page-one':
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(2)],
                  batchId: 'batch-resumed-page-two',
                  generation: generation,
                  nextToken: 'token-after-page-two',
                  hasMore: false,
                );
              default:
                fail('unexpected continuation token: $previousToken');
            }
          };

      final crashed = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(crashed.status, CloudSyncRunStatus.failed);
      expect(transport.fetchCallCount, 1);
      expect(transport.observedFetchTokens, [null]);
      final checkpointAfterCrash = await store.readCheckpoint(scope);
      expect(checkpointAfterCrash.fetchedToken, isNull);
      expect(checkpointAfterCrash.pendingBatchId, 'batch-crash-page-one');
      expect(checkpointAfterCrash.lastAppliedSequence, 0);
      expect(await store.inboxEntries(scope), hasLength(1));
      expect(applier.appliedSequences, isEmpty);

      final resumed = await engine(
        coordinatorId: 'coordinator-after-crash',
      ).synchronize(trigger: CloudSyncTrigger.startup);

      expect(resumed.status, CloudSyncRunStatus.completed);
      expect(transport.fetchCallCount, 2);
      expect(transport.observedFetchTokens, [null, 'token-after-page-one']);
      expect(applier.appliedSequences, [1, 2]);
      final checkpointAfterResume = await store.readCheckpoint(scope);
      expect(checkpointAfterResume.fetchedToken, 'token-after-page-two');
      expect(checkpointAfterResume.lastAppliedSequence, 2);
      expect((await store.inboxEntries(scope)).map((entry) => entry.batchId), [
        'batch-crash-page-one',
        'batch-resumed-page-two',
      ]);
    },
  );

  test(
    'retryable page-one predecessor blocks page-two floor advancement',
    () async {
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(requestedScope, scope);
            expect(generation, 1);
            expect(limit, 256);
            switch (previousToken) {
              case null:
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(1)],
                  batchId: 'batch-retry-page-one',
                  generation: generation,
                  nextToken: 'token-retry-page-one',
                  hasMore: true,
                );
              case 'token-retry-page-one':
                return CloudFetchBatch(
                  scope: scope,
                  changes: [testChange(2)],
                  batchId: 'batch-retry-page-two',
                  generation: generation,
                  nextToken: 'token-retry-page-two',
                  hasMore: false,
                );
              case 'token-retry-page-two':
                return CloudFetchBatch(
                  scope: scope,
                  changes: const [],
                  batchId: 'batch-retry-after-resume',
                  generation: generation,
                  nextToken: previousToken,
                  hasMore: false,
                );
              default:
                fail('unexpected continuation token: $previousToken');
            }
          };
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.network,
      );

      final first = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(first.status, CloudSyncRunStatus.degraded);
      expect(first.failureCategory, CloudFailureCategory.network);
      expect(first.counters.retried, 1);
      expect(first.counters.applied, 0);
      expect(transport.observedFetchTokens, [null]);
      expect(applier.appliedSequences, [1]);
      final blockedCheckpoint = await store.readCheckpoint(scope);
      expect(blockedCheckpoint.fetchedToken, isNull);
      expect(blockedCheckpoint.pendingBatchId, 'batch-retry-page-one');
      expect(blockedCheckpoint.lastAppliedSequence, 0);
      expect((await store.inboxEntries(scope)).map((entry) => entry.status), [
        CloudInboxStatus.pending,
      ]);

      applier.resultsBySequence[1] = const CloudInboxApplyResult.applied();
      clock.advance(const Duration(seconds: 10));
      final second = await engine(
        coordinatorId: 'coordinator-after-retry',
      ).synchronize(trigger: CloudSyncTrigger.startup);

      expect(
        second.status,
        CloudSyncRunStatus.completed,
        reason:
            'failure=${second.failureCategory} safeCode=${second.failureSafeCode}',
      );
      expect(second.counters.applied, 2);
      expect(transport.observedFetchTokens, [null, 'token-retry-page-one']);
      expect(applier.appliedSequences, [1, 1, 2]);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 2);
    },
  );

  test(
    'legacy unmarked pending page blocks transport until its row is applied',
    () async {
      await seedShadowJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'legacy-unmarked-page',
          generation: 1,
          nextToken: 'legacy-advanced-token',
          hasMore: true,
        ),
        now: clock.value,
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.network,
      );
      transport.fetchHandler = (scope, token, generation, limit) async {
        fail('transport must remain fenced for an unmarked pending page');
      };

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.startup,
      );

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'checkpoint_pending_page_unresolved');
      expect(transport.fetchCallCount, 0);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'legacy-advanced-token');
      expect(checkpoint.hasUnmarkedPendingInbox, isTrue);
      expect(checkpoint.lastAppliedSequence, 0);
    },
  );

  test('semantic barrier safe code survives a matching pull fence', () async {
    await seedShadowJournal(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'legacy-message-barrier',
        generation: 1,
        nextToken: 'legacy-message-token',
        hasMore: true,
      ),
      now: clock.value,
    );
    applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
      failureCategory: CloudFailureCategory.dependency,
      safeCode: 'canonical_message_chat_unavailable',
    );
    transport.fetchHandler = (scope, token, generation, limit) async {
      fail('transport must remain fenced for an unmarked pending page');
    };

    final result = await engine().synchronize(
      trigger: CloudSyncTrigger.startup,
    );

    expect(result.status, CloudSyncRunStatus.degraded);
    expect(result.failureCategory, CloudFailureCategory.dependency);
    expect(result.failureSafeCode, 'canonical_message_chat_unavailable');
    expect(transport.fetchCallCount, 0);
    expect((await store.readCheckpoint(scope)).fetchedToken, isNotNull);
  });

  test('freshly fetched semantic barrier reports its safe code', () async {
    transport.enqueueFetchBatch(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'fresh-message-barrier',
        generation: 1,
        nextToken: 'fresh-message-token',
        hasMore: false,
      ),
    );
    applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
      failureCategory: CloudFailureCategory.dependency,
      safeCode: 'canonical_message_chat_unavailable',
    );

    final result = await engine(
      flags: const CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: true,
      ),
    ).synchronize(trigger: CloudSyncTrigger.manual);

    expect(result.status, CloudSyncRunStatus.degraded);
    expect(result.failureCategory, CloudFailureCategory.dependency);
    expect(result.failureSafeCode, 'canonical_message_chat_unavailable');
    expect(transport.fetchCallCount, 1);
  });

  test(
    'terminal retained row permits later projection and the next fetched page',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'retained-first-page',
          generation: 1,
          nextToken: 'after-retained-token',
          hasMore: true,
        ),
      );
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(3)],
          batchId: 'after-retained-page',
          generation: 1,
          nextToken: 'after-retained-final-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.malformedRecord,
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
      expect(result.counters.retainedUnprojected, 1);
      expect(result.counters.applied, 2);
      expect(transport.observedFetchTokens, [null, 'after-retained-token']);
      expect(applier.appliedSequences, [1, 2, 3]);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'after-retained-final-token');
      expect(checkpoint.pendingBatchId, isNull);
      expect(checkpoint.lastAppliedSequence, 0);
      expect(checkpoint.hasUnmarkedPendingInbox, isFalse);
    },
  );

  const preflightSafeCodeCases = <CloudPreflightCode, String>{
    CloudPreflightCode.unsupportedRecordType:
        'preflight_unsupported_record_type',
    CloudPreflightCode.malformedMetadata: 'preflight_malformed_metadata',
    CloudPreflightCode.oversizedRecord: 'preflight_oversized_record',
    CloudPreflightCode.invalidChangeShape: 'preflight_invalid_change_shape',
    CloudPreflightCode.unknown: 'preflight_unknown',
  };
  for (final preflightCase in preflightSafeCodeCases.entries) {
    test(
      'content-free ${preflightCase.key.name} preflight code survives a blocking failure',
      () async {
        transport.enqueueFetchBatch(
          CloudFetchBatch(
            scope: scope,
            changes: [
              testChange(
                1,
                preflightFailure: CloudFailureCategory.conflict,
                preflightCode: preflightCase.key,
              ),
            ],
            batchId: 'fresh-preflight-barrier',
            generation: 1,
            nextToken: 'fresh-preflight-token',
            hasMore: false,
          ),
        );

        final result = await engine(
          flags: const CloudSyncFeatureFlags(
            readOnlyFetch: true,
            semanticApply: true,
          ),
        ).synchronize(trigger: CloudSyncTrigger.manual);

        expect(result.status, CloudSyncRunStatus.degraded);
        expect(result.failureCategory, CloudFailureCategory.conflict);
        expect(result.failureSafeCode, preflightCase.value);
        expect(applier.appliedSequences, isEmpty);
      },
    );
  }

  test(
    'legacy deterministic quarantine becomes retained before fetch',
    () async {
      await seedShadowJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'legacy-quarantined-page',
          generation: 1,
          nextToken: 'legacy-advanced-token',
          hasMore: true,
        ),
        now: clock.value,
      );
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'legacy-quarantine-seed',
        now: clock.value,
        leaseDuration: const Duration(minutes: 5),
      ))!;
      await store.quarantineInbox(
        scope,
        sequence: 1,
        category: CloudFailureCategory.malformedRecord,
        now: clock.value,
        leaseFence: fence,
      );
      await store.releaseCoordinatorLease(scope, leaseFence: fence);

      transport.fetchHandler = (observedScope, token, generation, limit) async {
        expect(observedScope, scope);
        expect(token, 'legacy-advanced-token');
        return CloudFetchBatch(
          scope: scope,
          changes: const [],
          batchId: 'legacy-recovery-follow-up',
          generation: generation,
          nextToken: token,
          hasMore: false,
        );
      };

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.startup,
      );

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
      expect(result.counters.retainedUnprojected, 1);
      expect(transport.fetchCallCount, 1);
      expect(transport.pushCallCount, 0);
      expect(await store.outboxEntries(scope), isEmpty);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'legacy-advanced-token');
      expect(checkpoint.hasUnmarkedPendingInbox, isFalse);
      expect(checkpoint.lastAppliedSequence, 0);
      expect(
        (await store.inboxEntries(scope)).single.status,
        CloudInboxStatus.retainedUnprojected,
      );
    },
  );

  test(
    'marked pending page degrades and blocks transport while retry remains unresolved',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'marked-pending-page',
          generation: 1,
          nextToken: 'marked-pending-token',
          hasMore: true,
        ),
        now: clock.value,
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.network,
      );
      transport.fetchHandler = (scope, token, generation, limit) async {
        fail('transport must remain fenced for a marked pending page');
      };

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.startup,
      );

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(transport.fetchCallCount, 0);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, isNull);
      expect(checkpoint.pendingBatchId, 'marked-pending-page');
      expect(checkpoint.lastAppliedSequence, 0);
    },
  );

  test(
    'startup inbox budget exhaustion degrades without fetching another page',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'startup-budget-page',
          generation: 1,
          nextToken: 'startup-budget-token',
          hasMore: true,
        ),
        now: clock.value,
      );
      transport.fetchHandler = (scope, token, generation, limit) async {
        fail('transport must not run after the inbox budget is exhausted');
      };

      final result = await engine(
        batchSize: 1,
        maximumInboxEntriesPerRun: 1,
      ).synchronize(trigger: CloudSyncTrigger.startup);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.counters.applied, 1);
      expect(transport.fetchCallCount, 0);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'startup-budget-token');
      expect(checkpoint.pendingBatchId, isNull);
      expect(checkpoint.lastAppliedSequence, 1);
    },
  );

  test(
    'semantic startup applies existing inbox before transport fetch',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'batch-preexisting',
          generation: 1,
          nextToken: 'preexisting-token',
          hasMore: false,
        ),
        now: clock.value,
      );
      transport.fetchHandler = (scope, previousToken, generation, limit) async {
        expect(previousToken, 'preexisting-token');
        expect(applier.appliedSequences, [1]);
        return CloudFetchBatch(
          scope: scope,
          changes: const [],
          batchId: 'batch-after-startup-apply',
          generation: generation,
          nextToken: 'post-startup-token',
          hasMore: false,
        );
      };

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.startup,
      );

      expect(result.status, CloudSyncRunStatus.completed);
      expect(result.counters.applied, 1);
      expect(applier.appliedSequences, [1]);
      expect(transport.fetchCallCount, 1);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 1);
    },
  );

  test(
    'semantic inbox yields after every durable terminal entry without changing order',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2), testChange(3)],
          batchId: 'yield-test-batch',
          generation: 1,
          nextToken: null,
          hasMore: false,
        ),
        now: clock.value,
      );
      final observedAtEventTurns = <int>[];
      applier.handler = (entry) async {
        if (entry.sequence < 3) {
          Timer.run(
            () => observedAtEventTurns.add(applier.appliedSequences.length),
          );
        }
        return const CloudInboxApplyResult.applied();
      };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: false,
          semanticApply: true,
          saves: false,
        ),
        maximumInboxEntriesPerRun: 3,
      ).synchronize(trigger: CloudSyncTrigger.manual);
      await Future<void>.delayed(Duration.zero);

      expect(result.status, CloudSyncRunStatus.completed);
      expect(applier.appliedSequences, [1, 2, 3]);
      expect(observedAtEventTurns, [1, 2]);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.lastAppliedSequence, 3);
      expect(checkpoint.pendingBatchId, isNull);
    },
  );

  test('semantic inbox yields after a durable blocking failure', () async {
    await seedGeneralJournal(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1), testChange(2)],
        batchId: 'blocking-yield-test-batch',
        generation: 1,
        nextToken: null,
        hasMore: false,
      ),
      now: clock.value,
    );
    var eventTurnObserved = false;
    applier.handler = (_) async {
      Timer.run(() => eventTurnObserved = true);
      return const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.network,
        safeCode: 'test_blocking_retry',
      );
    };

    await engine(
      flags: const CloudSyncFeatureFlags(
        readOnlyFetch: false,
        semanticApply: true,
        saves: false,
      ),
      maximumInboxEntriesPerRun: 2,
    ).synchronize(trigger: CloudSyncTrigger.manual);

    expect(eventTurnObserved, isTrue);
    expect(applier.appliedSequences, [1]);
    expect((await store.readCheckpoint(scope)).lastAppliedSequence, 0);
  });

  test(
    'normal semantic startup reprojects retained rows before inbox and fetch',
    () async {
      final events = <String>[];
      final retainedApplier = _RetainedProjectionEngineApplier(
        onReproject: (requestedScope, generation, leaseFence, limit) async {
          events.add('retained');
          expect(requestedScope, scope);
          expect(generation, 1);
          expect(leaseFence.ownerId, isNotEmpty);
          expect(limit, 3);
          return const CloudRetainedProjectionResult(
            examined: 2,
            reprojected: 1,
            retained: 1,
          );
        },
      );
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            events.add('fetch');
            return CloudFetchBatch(
              scope: requestedScope,
              changes: const [],
              batchId: 'after-retained-reprojection',
              generation: generation,
              nextToken: previousToken,
              hasMore: false,
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
        maximumInboxEntriesPerRun: 3,
        inboxApplierOverride: retainedApplier,
      ).synchronize(trigger: CloudSyncTrigger.startup);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
      expect(result.counters.applied, 1);
      expect(result.counters.retainedUnprojected, 1);
      expect(retainedApplier.reprojectCalls, 1);
      expect(events, const ['retained', 'fetch']);
      expect(transport.fetchCallCount, 1);
    },
  );

  test(
    'retained reprojection preserves one complete page for remote progress',
    () async {
      var observedReprojectionLimit = 0;
      final retainedApplier = _RetainedProjectionEngineApplier(
        onReproject: (_, _, _, limit) async {
          observedReprojectionLimit = limit;
          return CloudRetainedProjectionResult(
            examined: limit,
            reprojected: 0,
            retained: limit,
            hasRemaining: true,
          );
        },
      );
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(limit, 1);
            return CloudFetchBatch(
              scope: requestedScope,
              changes: const [],
              batchId: 'terminal-after-retained-window',
              generation: generation,
              nextToken: previousToken,
              hasMore: false,
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
        batchSize: 1,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 1,
        inboxApplierOverride: retainedApplier,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(observedReprojectionLimit, 3);
      expect(transport.fetchCallCount, 1);
      expect(result.observedEmptyTerminalRead, isTrue);
      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
    },
  );

  test(
    'startup inbox work shrinks the reserved fetch request to exact capacity',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'startup-before-reserved-fetch',
          generation: 1,
          nextToken: 'startup-before-reserved-fetch-token',
          hasMore: true,
        ),
        now: clock.value,
      );
      final retainedApplier = _RetainedProjectionEngineApplier(
        onReproject: (_, _, _, limit) async {
          expect(limit, 2);
          return const CloudRetainedProjectionResult(
            examined: 2,
            reprojected: 0,
            retained: 2,
            hasRemaining: true,
          );
        },
      );
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(previousToken, 'startup-before-reserved-fetch-token');
            expect(limit, 1);
            return CloudFetchBatch(
              scope: requestedScope,
              changes: const [],
              batchId: 'terminal-after-startup-capacity',
              generation: generation,
              nextToken: previousToken,
              hasMore: false,
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
        batchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 2,
        inboxApplierOverride: retainedApplier,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
      expect(result.counters.applied, 1);
      expect(transport.fetchCallCount, 1);
    },
  );

  test(
    'short nonterminal page shrinks the next request to exact capacity',
    () async {
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            if (transport.fetchCallCount == 1) {
              expect(previousToken, isNull);
              expect(limit, 2);
              return CloudFetchBatch(
                scope: requestedScope,
                changes: [testChange(1)],
                batchId: 'short-first-page',
                generation: generation,
                nextToken: 'short-first-page-token',
                hasMore: true,
              );
            }
            expect(previousToken, 'short-first-page-token');
            expect(limit, 1);
            return CloudFetchBatch(
              scope: requestedScope,
              changes: [testChange(2)],
              batchId: 'bounded-second-page',
              generation: generation,
              nextToken: 'bounded-second-page-token',
              hasMore: false,
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
        batchSize: 2,
        maximumInboxEntriesPerRun: 2,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.completed);
      expect(result.counters.applied, 2);
      expect(transport.fetchCallCount, 2);
    },
  );

  test(
    'transport page cannot exceed exact remaining semantic capacity',
    () async {
      store = _ProtectedRecoveryTrackingStore();
      final events = <String>[];
      transport = _RecoveryOrderedProtectedWriteTransport(events: events);
      const leaseReference = 'obcs2.lease.11111111111111111111111111111111';
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            expect(limit, 1);
            return CloudFetchBatch(
              scope: requestedScope,
              changes: [testChange(1), testChange(2)],
              batchId: 'over-limit-page',
              generation: generation,
              nextToken: 'over-limit-token',
              hasMore: false,
              protectedPageLeaseReference: leaseReference,
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
        batchSize: 2,
        maximumInboxEntriesPerRun: 1,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.malformedRecord);
      expect(result.failureSafeCode, 'fetch_page_exceeds_requested_limit');
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect(events, contains('rollback:$leaseReference'));
    },
  );

  test(
    'scope-mismatched protected page is rolled back before journaling',
    () async {
      store = _ProtectedRecoveryTrackingStore();
      final events = <String>[];
      transport = _RecoveryOrderedProtectedWriteTransport(events: events);
      const leaseReference = 'obcs2.lease.22222222222222222222222222222222';
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            return CloudFetchBatch(
              scope: testScope(account: testAccountFingerprintB),
              changes: [testChange(1)],
              batchId: 'scope-mismatched-protected-page',
              generation: generation,
              nextToken: 'scope-mismatched-token',
              hasMore: false,
              protectedPageLeaseReference: leaseReference,
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.authorization);
      expect(result.failureSafeCode, 'cloud_sync_unknown_failure');
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect(events, contains('rollback:$leaseReference'));
    },
  );

  test(
    'generation-mismatched provider page without lifecycle rolls back',
    () async {
      final events = <String>[];
      final protectedTransport = _RecoveryOrderedProtectedWriteTransport(
        events: events,
      );
      transport = _ProtectedLeaseProviderTransport(protectedTransport);
      const leaseReference = 'obcs2.lease.33333333333333333333333333333333';
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            return CloudFetchBatch(
              scope: requestedScope,
              changes: [testChange(1)],
              batchId: 'generation-mismatched-protected-page',
              generation: generation + 1,
              nextToken: 'generation-mismatched-token',
              hasMore: false,
              protectedPageLeaseReference: leaseReference,
            );
          };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(result.failureSafeCode, 'generation_mismatch');
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect(events, contains('rollback:$leaseReference'));
    },
  );

  test(
    'retained reprojection failure fails closed before transport and releases lease',
    () async {
      final retainedApplier = _RetainedProjectionEngineApplier(
        onReproject: (_, _, _, _) async => throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'retained_projection_test_failure',
        ),
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
        inboxApplierOverride: retainedApplier,
      ).synchronize(trigger: CloudSyncTrigger.startup);

      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(result.failureSafeCode, 'cloud_sync_unknown_failure');
      expect(transport.fetchCallCount, 0);
      final replacementFence = await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'after-retained-projection-failure',
        now: clock.value,
        leaseDuration: const Duration(minutes: 1),
      );
      expect(replacementFence, isNotNull);
    },
  );

  test(
    'successful retained window reports a degraded run while backlog remains',
    () async {
      final retainedApplier = _RetainedProjectionEngineApplier(
        onReproject: (_, _, _, limit) async {
          expect(limit, 1);
          return const CloudRetainedProjectionResult(
            examined: 1,
            reprojected: 1,
            retained: 0,
            hasRemaining: true,
          );
        },
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: false,
          semanticApply: true,
          saves: false,
        ),
        maximumInboxEntriesPerRun: 1,
        inboxApplierOverride: retainedApplier,
      ).synchronize(trigger: CloudSyncTrigger.startup);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
      expect(result.counters.applied, 1);
      expect(retainedApplier.reprojectCalls, 1);
      expect(transport.fetchCallCount, 0);
    },
  );

  test(
    'semantic rows fetched in this run apply after transport fetch',
    () async {
      var fetchCompleted = false;
      transport.fetchHandler = (scope, previousToken, generation, limit) async {
        expect(applier.appliedSequences, isEmpty);
        fetchCompleted = true;
        return CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'batch-newly-fetched',
          generation: generation,
          nextToken: 'newly-fetched-token',
          hasMore: false,
        );
      };
      applier.handler = (entry) async {
        expect(fetchCompleted, isTrue);
        return const CloudInboxApplyResult.applied();
      };

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(result.status, CloudSyncRunStatus.completed);
      expect(result.counters.fetched, 1);
      expect(result.counters.applied, 1);
      expect(applier.appliedSequences, [1]);
    },
  );

  test('semantic inbox cap bounds fetch after startup processing', () async {
    await seedGeneralJournal(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'batch-cap-preexisting',
        generation: 1,
        nextToken: 'cap-preexisting-token',
        hasMore: false,
      ),
      now: clock.value,
    );
    transport.fetchHandler =
        (requestedScope, previousToken, generation, limit) async {
          expect(previousToken, 'cap-preexisting-token');
          expect(limit, 1);
          return CloudFetchBatch(
            scope: requestedScope,
            changes: [testChange(2)],
            batchId: 'batch-cap-new',
            generation: generation,
            nextToken: 'cap-new-token',
            hasMore: true,
          );
        };
    final observer = MemoryCloudSyncObserver();

    final result = await engine(
      maximumInboxEntriesPerRun: 2,
      observer: observer,
    ).synchronize(trigger: CloudSyncTrigger.manual);

    expect(result.status, CloudSyncRunStatus.completed);
    expect(result.failureCategory, isNull);
    expect(result.counters.applied, 2);
    expect(applier.appliedSequences, [1, 2]);
    expect(transport.fetchCallCount, 1);
    final entries = await store.inboxEntries(scope);
    expect(entries.map((entry) => entry.status), [
      CloudInboxStatus.applied,
      CloudInboxStatus.applied,
    ]);
    final checkpoint = await store.readCheckpoint(scope);
    expect(checkpoint.fetchedToken, 'cap-new-token');
    expect(checkpoint.pendingBatchId, isNull);
    final inboxEvents = observer.events
        .where((event) => event.type == CloudSyncEventType.inboxApplied)
        .toList();
    expect(inboxEvents, hasLength(1));
    expect(inboxEvents.single.count, 2);
  });

  test(
    'retained preflight permits fetch while conflict remains a barrier',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [
            testChange(
              1,
              preflightFailure: CloudFailureCategory.malformedRecord,
              preflightCode: CloudPreflightCode.invalidChangeShape,
            ),
          ],
          batchId: 'batch-staged-preflight',
          generation: 1,
          nextToken: 'staged-preflight-token',
          hasMore: false,
        ),
        now: clock.value,
      );
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(2, tombstone: true), testChange(3)],
          batchId: 'batch-staged-tombstone',
          generation: 1,
          nextToken: 'staged-tombstone-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[2] = const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.conflict,
      );
      applier.resultsBySequence[3] = const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.unsupportedService,
      );

      final result = await engine(
        maximumInboxEntriesPerRun: 3,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.counters.retainedUnprojected, 1);
      expect(result.counters.quarantined, 1);
      expect(result.counters.preflightQuarantined, 0);
      expect(result.counters.preflightInvalidChangeShape, 0);
      expect(result.counters.preflightUnsupportedRecordType, 0);
      expect(result.counters.preflightMalformedMetadata, 0);
      expect(result.counters.preflightOversizedRecord, 0);
      expect(result.counters.preflightUnknown, 0);
      expect(result.counters.startupQuarantined, 0);
      expect(result.counters.postFetchQuarantined, 1);
      expect(result.counters.tombstoneQuarantined, 1);
      expect(result.counters.semanticUnsupportedServiceQuarantined, 0);
      expect(result.counters.semanticStageQuarantined, 0);
      expect(transport.fetchCallCount, 1);
      expect(applier.appliedSequences, [2]);
      expect(
        result.counters.preflightQuarantined +
            result.counters.tombstoneQuarantined +
            result.counters.semanticUnsupportedServiceQuarantined +
            result.counters.semanticStageQuarantined,
        result.counters.quarantined,
      );
    },
  );

  test('semanticApply false keeps fetch-only behavior unchanged', () async {
    await seedShadowJournal(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'batch-semantic-disabled-existing',
        generation: 1,
        nextToken: 'semantic-disabled-token',
        hasMore: false,
      ),
      now: clock.value,
    );
    transport.enqueueFetchBatch(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(2)],
        batchId: 'batch-semantic-disabled-new',
        generation: 1,
        nextToken: 'semantic-disabled-new-token',
        hasMore: false,
      ),
    );
    const flags = CloudSyncFeatureFlags(
      readOnlyFetch: true,
      semanticApply: false,
      saves: false,
      deletions: false,
      profiles: false,
      notificationHints: false,
    );

    final result = await engine(
      flags: flags,
    ).synchronize(trigger: CloudSyncTrigger.startup);

    expect(result.status, CloudSyncRunStatus.completed);
    expect(result.counters.fetched, 1);
    expect(result.counters.applied, 0);
    expect(applier.appliedSequences, isEmpty);
    expect(
      (await store.inboxEntries(
        scope,
      )).every((entry) => entry.status == CloudInboxStatus.pending),
      isTrue,
    );
  });

  test('read-only shadow does not recover or inspect outbox leases', () async {
    final trackingStore = _RecoveryTrackingStore();
    final shadowEngine = CloudSyncEngine(
      scope: scope,
      coordinatorId: 'shadow-coordinator',
      store: trackingStore,
      transport: transport,
      inboxApplier: applier,
      clock: clock.call,
      config: CloudSyncEngineConfig(
        maximumFetchPagesPerRun: 1,
        maximumBatchSize: 50,
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: false,
          saves: false,
          deletions: false,
          profiles: false,
          notificationHints: false,
        ),
      ),
    );

    final result = await shadowEngine.synchronize(
      trigger: CloudSyncTrigger.manual,
    );

    expect(result.status, CloudSyncRunStatus.completed);
    expect(trackingStore.recoverExpiredOutboxLeaseCalls, 0);
    expect(transport.pushCallCount, 0);
    expect(applier.appliedSequences, isEmpty);
  });

  test('save-enabled engine requires an explicit writer authority', () {
    expect(
      () => CloudSyncEngine(
        scope: scope,
        coordinatorId: 'missing-writer-authority',
        store: store,
        transport: transport,
        inboxApplier: applier,
        config: CloudSyncEngineConfig(
          flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('save-enabled engine requires unknown-outcome leasing support', () {
    expect(
      () => CloudSyncEngine(
        scope: scope,
        coordinatorId: 'missing-unknown-outcome-store',
        store: ShadowOnlyCloudSyncStore(store),
        transport: transport,
        inboxApplier: applier,
        writerAuthority: writerAuthority,
        writerExclusion: writerExclusion,
        config: CloudSyncEngineConfig(
          flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('save-enabled engine requires the cross-process writer exclusion', () {
    expect(
      () => CloudSyncEngine(
        scope: scope,
        coordinatorId: 'missing-writer-exclusion',
        store: store,
        transport: transport,
        inboxApplier: applier,
        writerAuthority: writerAuthority,
        config: CloudSyncEngineConfig(
          flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('save-enabled engine requires native operation quiescence', () {
    final transportWithoutQuiescence = AccountBoundShadowTransport(
      delegate: transport,
      readActiveFingerprint: () async => scope.accountFingerprint,
      expectedFingerprint: scope.accountFingerprint,
    );

    expect(
      () => CloudSyncEngine(
        scope: scope,
        coordinatorId: 'missing-native-quiescence',
        store: store,
        transport: transportWithoutQuiescence,
        inboxApplier: applier,
        writerAuthority: writerAuthority,
        writerExclusion: writerExclusion,
        config: CloudSyncEngineConfig(
          flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        ),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_operation_quiescence_required',
        ),
      ),
    );
  });

  test('save-enabled protected writer requires durable recovery stores', () {
    transport = _RecoveryOrderedProtectedWriteTransport(events: []);

    expect(
      () => engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_native_protected_writer_recovery_required',
        ),
      ),
    );
  });

  test('push-only run is fenced by an unresolved checkpoint page', () async {
    store = _OutboxPresenceRaceStore();
    await seedShadowJournal(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'legacy-outbound-fence-page',
        generation: 1,
        nextToken: 'legacy-outbound-fence-token',
        hasMore: true,
      ),
      now: clock.value,
    );
    await store.enqueueOutbox(testOutboxOperation(scope, 710));
    transport.writePreflightHandler = (_, _, _) async {
      fail('writer preflight must remain fenced');
    };

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.status, CloudSyncRunStatus.failed);
    expect(result.failureCategory, CloudFailureCategory.localStorage);
    expect(result.failureSafeCode, 'checkpoint_pending_page_unresolved');
    expect(transport.prepareSubmissionCallCount, 0);
    expect(transport.pushCallCount, 0);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.pending,
    );
    expect((store as _OutboxPresenceRaceStore).hiddenPresenceChecks, 1);
  });

  test(
    'local outbox recovers protected store before reconcile and preflight',
    () async {
      store = _ProtectedRecoveryTrackingStore();
      final events = <String>[];
      transport = _RecoveryOrderedProtectedWriteTransport(events: events);

      // Prime the process-wide startup cache before creating the adopted
      // outbound rows. The write run must still perform a fresh pass.
      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: true, saves: false),
      ).synchronize(trigger: CloudSyncTrigger.startup);
      events.clear();

      final ambiguous = await seedAmbiguousOutbox(711);
      final ready = testOutboxOperation(scope, 712);
      await store.enqueueOutbox(ready);
      (store as _ProtectedRecoveryTrackingStore).outboundLeaseReferences.addAll(
        [ambiguous.protectedLeaseReference!, ready.protectedLeaseReference!],
      );
      events.clear();

      final result = await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(result.status, CloudSyncRunStatus.completed);
      expect(events, ['recover', 'reconcile', 'prepare']);
    },
  );

  test('write operation timeout is bounded and positive', () {
    expect(
      () => CloudSyncEngineConfig(writeOperationTimeout: Duration.zero),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_config_write_timeout_invalid',
        ),
      ),
    );
    expect(
      () => CloudSyncEngineConfig(
        writeOperationTimeout: const Duration(minutes: 5, microseconds: 1),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_config_write_timeout_invalid',
        ),
      ),
    );
  });

  test('revoked V2 permit blocks transport immediately before push', () async {
    await store.enqueueOutbox(testOutboxOperation(scope, 700));
    writerAuthority.verifyHandler = (call) async {
      if (call == 2) writerAuthority.allowVerify = false;
    };

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.status, CloudSyncRunStatus.failed);
    expect(result.failureCategory, CloudFailureCategory.authorization);
    expect(writerAuthority.issueCallCount, 1);
    expect(writerAuthority.verifyCallCount, 2);
    expect(transport.pushCallCount, 0);
  });

  test(
    'permit revocation after submission freezes the ambiguous operation',
    () async {
      final operation = testOutboxOperation(scope, 701);
      await store.enqueueOutbox(operation);
      writerAuthority.verifyHandler = (call) async {
        if (call == 5) writerAuthority.allowVerify = false;
      };
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        ),
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(result.counters.confirmed, 0);
      expect(transport.pushCallCount, 1);
      expect(writerAuthority.verifyCallCount, 5);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );

      writerAuthority
        ..allowVerify = true
        ..verifyHandler = null;
      clock.advance(const Duration(minutes: 3));
      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);
      expect(transport.pushCallCount, 1);
    },
  );

  test('failed write preflight never marks or sends the operation', () async {
    final operation = testOutboxOperation(scope, 702);
    await store.enqueueOutbox(operation);
    transport.writePreflightHandler = (_, _, _) async => throw CloudSyncFailure(
      category: CloudFailureCategory.authorization,
      safeCode: 'simulated_write_preflight_failure',
    );

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(result.status, CloudSyncRunStatus.completed);
    expect(stored.status, CloudOutboxStatus.paused);
    expect(stored.appleRequestUuid, isNull);
    expect(stored.appleOperationUuid, isNull);
    expect(transport.prepareSubmissionCallCount, 1);
    expect(transport.consumePreparedSubmissionCallCount, 0);
    expect(transport.pushCallCount, 0);
  });

  test('permit revocation at consume freezes without sending', () async {
    final operation = testOutboxOperation(scope, 704);
    await store.enqueueOutbox(operation);
    writerAuthority.verifyHandler = (call) async {
      if (call == 4) writerAuthority.allowVerify = false;
    };

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(result.status, CloudSyncRunStatus.completed);
    expect(stored.status, CloudOutboxStatus.unknownOutcome);
    expect(stored.appleRequestUuid, isNotNull);
    expect(stored.appleOperationUuid, isNotNull);
    expect(transport.prepareSubmissionCallCount, 1);
    expect(transport.consumePreparedSubmissionCallCount, 0);
    expect(transport.pushCallCount, 0);
  });

  test('failed submission marker drops the prepared request unsent', () async {
    store = _FailingSubmissionMarkerStore();
    final operation = testOutboxOperation(scope, 703);
    await store.enqueueOutbox(operation);
    transport.writePreflightHandler = (_, _, operations) async {
      expect(() => operations.clear(), throwsUnsupportedError);
    };

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(result.status, CloudSyncRunStatus.failed);
    expect(result.failureCategory, CloudFailureCategory.localStorage);
    expect(stored.appleRequestUuid, isNull);
    expect(stored.appleOperationUuid, isNull);
    expect(transport.prepareSubmissionCallCount, 1);
    expect(transport.consumePreparedSubmissionCallCount, 0);
    expect(transport.pushCallCount, 0);
  });

  test(
    'deterministic malformed record is retained and later rows proceed',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'batch-1',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.malformedRecord,
      );

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(result.counters.retainedUnprojected, 1);
      expect(result.counters.quarantined, 0);
      expect(result.counters.semanticStageQuarantined, 0);
      expect(result.counters.preflightQuarantined, 0);
      expect(result.counters.tombstoneQuarantined, 0);
      expect(result.counters.applied, 1);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 0);
      expect((await store.readCheckpoint(scope)).fetchedToken, 'opaque-token');
      expect(applier.appliedSequences, [1, 2]);
      final entries = await store.inboxEntries(scope);
      expect(entries[0].status, CloudInboxStatus.retainedUnprojected);
      expect(entries[1].status, CloudInboxStatus.applied);
    },
  );

  test(
    'read-only tombstone acknowledgement retains an exact mixed-history floor',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [
            testChange(1),
            testChange(2, tombstone: true),
            testChange(3),
          ],
          batchId: 'batch-mixed-terminal',
          generation: 1,
          nextToken: 'mixed-terminal-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.applied();
      applier.resultsBySequence[2] =
          const CloudInboxApplyResult.tombstoneReadOnlyAcknowledged();
      applier.resultsBySequence[3] = const CloudInboxApplyResult.applied();

      final first = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(first.counters.quarantined, 0);
      expect(first.counters.semanticUnsupportedServiceQuarantined, 0);
      expect(first.counters.tombstoneQuarantined, 0);
      expect(first.counters.tombstoneReadOnlyAcknowledged, 1);
      expect(first.counters.retainedUnprojected, 1);
      expect(first.counters.semanticStageQuarantined, 0);
      expect(first.counters.applied, 2);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 1);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'mixed-terminal-token',
      );
      expect((await store.inboxEntries(scope)).map((entry) => entry.status), [
        CloudInboxStatus.applied,
        CloudInboxStatus.retainedUnprojected,
        CloudInboxStatus.applied,
      ]);

      final appliedCallCount = applier.appliedSequences.length;
      final second = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(second.counters.quarantined, 0);
      expect(second.counters.semanticUnsupportedServiceQuarantined, 0);
      expect(second.counters.tombstoneQuarantined, 0);
      expect(second.counters.tombstoneReadOnlyAcknowledged, 0);
      expect(second.counters.semanticStageQuarantined, 0);
      expect(applier.appliedSequences.length, appliedCallCount);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 1);
    },
  );

  test(
    'typed out-of-scope save advances the remote token but not the exact floor',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'out-of-scope-terminal-page',
          generation: 1,
          nextToken: 'out-of-scope-terminal-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] =
          const CloudInboxApplyResult.outOfScopeService(
            outOfScopeService: CloudSemanticOutOfScopeService.smsFamily,
          );
      applier.resultsBySequence[2] = const CloudInboxApplyResult.applied();

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(result.counters.retainedUnprojected, 1);
      expect(result.counters.applied, 1);
      expect(result.counters.quarantined, 0);
      expect(result.counters.semanticUnsupportedServiceQuarantined, 0);
      expect(result.counters.semanticStageQuarantined, 0);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'out-of-scope-terminal-token');
      expect(checkpoint.lastAppliedSequence, 0);
      final entries = await store.inboxEntries(scope);
      expect(entries.map((entry) => entry.status), [
        CloudInboxStatus.retainedUnprojected,
        CloudInboxStatus.applied,
      ]);
      expect(entries.first.lastFailure, CloudFailureCategory.outOfScopeService);
      final summary = await store.readRetainedUnprojectedInboxSummary(scope);
      expect(summary.total, 1);
      expect(summary.saves, 1);
      expect(summary.outOfScopeServices, 1);
      expect(summary.blockingSaves, 0);
      expect(summary.byFailureCategory, <CloudFailureCategory, int>{
        CloudFailureCategory.outOfScopeService: 1,
      });
      expect(await store.outboxEntries(scope), isEmpty);
    },
  );

  test(
    'deferred predecessor blocks later sequence until it succeeds',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'batch-contiguous-deferred',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
        now: clock.value,
      );
      expect(
        (await store.readEligibleInbox(
          scope,
          now: clock.value,
          limit: 256,
        )).map((entry) => entry.sequence),
        [1],
      );

      applier.resultsBySequence[1] = const CloudInboxApplyResult.deferred();
      const readOnlySemanticFlags = CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: true,
        saves: false,
        deletions: false,
        profiles: false,
        notificationHints: false,
      );
      final first = await engine(
        flags: readOnlySemanticFlags,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(first.counters.deferred, 1);
      expect(applier.appliedSequences, [1]);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 0);

      applier.resultsBySequence[1] = const CloudInboxApplyResult.applied();
      clock.advance(const Duration(seconds: 10));
      final second = await engine(
        flags: readOnlySemanticFlags,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(second.counters.applied, 2);
      expect(applier.appliedSequences, [1, 1, 2]);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 2);
    },
  );

  test(
    'retryable predecessor also blocks later sequence until it succeeds',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'batch-contiguous-retryable',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
        now: clock.value,
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.network,
      );

      const readOnlySemanticFlags = CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: true,
        saves: false,
        deletions: false,
        profiles: false,
        notificationHints: false,
      );
      final first = await engine(
        flags: readOnlySemanticFlags,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(first.counters.retried, 1);
      expect(applier.appliedSequences, [1]);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 0);

      applier.resultsBySequence[1] = const CloudInboxApplyResult.applied();
      clock.advance(const Duration(seconds: 10));
      final second = await engine(
        flags: readOnlySemanticFlags,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(second.counters.applied, 2);
      expect(applier.appliedSequences, [1, 1, 2]);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 2);
    },
  );

  test(
    'preflight failure retains raw record without invoking decoder',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [
            testChange(
              1,
              preflightFailure: CloudFailureCategory.malformedRecord,
              preflightCode: CloudPreflightCode.oversizedRecord,
            ),
          ],
          batchId: 'batch-preflight-quarantine',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
      );

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(result.counters.retainedUnprojected, 1);
      expect(result.counters.quarantined, 0);
      expect(result.counters.preflightQuarantined, 0);
      expect(result.counters.preflightOversizedRecord, 0);
      expect(result.counters.preflightUnknown, 0);
      expect(result.counters.tombstoneQuarantined, 0);
      expect(result.counters.semanticStageQuarantined, 0);
      expect(applier.appliedSequences, isEmpty);
      final entries = await store.inboxEntries(scope);
      expect(entries.single.status, CloudInboxStatus.retainedUnprojected);
      expect(entries.single.lastFailure, CloudFailureCategory.malformedRecord);
    },
  );

  test(
    'tombstone quarantine is counted separately from semantic failures',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1, tombstone: true)],
          batchId: 'batch-tombstone-quarantine',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.conflict,
      );

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(result.counters.quarantined, 1);
      expect(result.counters.preflightQuarantined, 0);
      expect(result.counters.tombstoneQuarantined, 1);
      expect(result.counters.semanticStageQuarantined, 0);
    },
  );

  test(
    'deferred inbox entries are retained only after age and attempt thresholds',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'batch-deferred-parent',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.deferred();
      final syncEngine = engine(
        maximumDeferredAttempts: 1,
        maximumDeferredAge: const Duration(seconds: 1),
      );

      final first = await syncEngine.synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(first.counters.deferred, 1);
      expect(first.counters.quarantined, 0);
      var entries = await store.inboxEntries(scope);
      expect(entries.single.status, CloudInboxStatus.pending);
      expect(entries.single.attemptCount, 1);
      expect(entries.single.lastFailure, CloudFailureCategory.dependency);

      clock.advance(const Duration(seconds: 10));
      final second = await syncEngine.synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(second.counters.deferred, 0);
      expect(second.counters.quarantined, 0);
      expect(second.counters.retainedUnprojected, 1);
      entries = await store.inboxEntries(scope);
      expect(entries.single.status, CloudInboxStatus.retainedUnprojected);
      expect(entries.single.attemptCount, 2);
      expect(entries.single.lastFailure, CloudFailureCategory.dependency);
    },
  );

  test(
    'retryable inbox failures do not use the deferred terminal bound',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'batch-retryable-network',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.network,
      );
      final syncEngine = engine(
        maximumDeferredAttempts: 1,
        maximumDeferredAge: const Duration(seconds: 1),
      );

      await syncEngine.synchronize(trigger: CloudSyncTrigger.manual);
      clock.advance(const Duration(seconds: 10));
      final second = await syncEngine.synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      final stored = (await store.inboxEntries(scope)).single;
      expect(second.counters.retried, 1);
      expect(second.counters.quarantined, 0);
      expect(stored.status, CloudInboxStatus.pending);
      expect(stored.lastFailure, CloudFailureCategory.network);
    },
  );

  test(
    'ordinary semantic engine keeps a fresh dependency deferral pending',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'ordinary-dependency-page',
          generation: 1,
          nextToken: 'ordinary-dependency-token',
          hasMore: true,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.deferred(
        failureCategory: CloudFailureCategory.dependency,
        safeCode: 'semantic_parent_missing',
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
      ).synchronize(trigger: CloudSyncTrigger.manual);

      final entry = (await store.inboxEntries(scope)).single;
      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'semantic_parent_missing');
      expect(result.counters.deferred, 1);
      expect(result.counters.retainedUnprojected, 0);
      expect(entry.status, CloudInboxStatus.pending);
      expect(entry.attemptCount, 1);
      expect(
        (await store.readCheckpoint(scope)).pendingBatchId,
        'ordinary-dependency-page',
      );
      expect(transport.observedFetchTokens, [null]);
    },
  );

  test(
    'guarded Canary retains a known dependency and later reprojects it',
    () async {
      var parentAvailable = false;
      final retainedApplier = _RetainedProjectionEngineApplier(
        onReproject: (reprojectScope, generation, leaseFence, limit) async {
          final entries = await store.inboxEntries(reprojectScope);
          final retained = entries.where(
            (entry) => entry.status == CloudInboxStatus.retainedUnprojected,
          );
          if (!parentAvailable || retained.isEmpty) {
            return CloudRetainedProjectionResult(
              examined: retained.length,
              reprojected: 0,
              retained: retained.length,
            );
          }
          return CloudRetainedProjectionResult(
            examined: retained.length,
            reprojected: retained.length,
            retained: 0,
          );
        },
      );
      retainedApplier.handler = (entry) async {
        if (entry.sequence == 1) {
          return const CloudInboxApplyResult.deferred(
            failureCategory: CloudFailureCategory.dependency,
            safeCode: 'semantic_parent_missing',
          );
        }
        parentAvailable = true;
        return const CloudInboxApplyResult.applied();
      };
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            switch (previousToken) {
              case null:
                return CloudFetchBatch(
                  scope: requestedScope,
                  changes: [testChange(1)],
                  batchId: 'canary-dependency-page',
                  generation: generation,
                  nextToken: 'canary-parent-page',
                  hasMore: true,
                );
              case 'canary-parent-page':
                return CloudFetchBatch(
                  scope: requestedScope,
                  changes: [testChange(2)],
                  batchId: 'canary-parent-page-two',
                  generation: generation,
                  nextToken: 'canary-complete-token',
                  hasMore: false,
                );
              case 'canary-complete-token':
                return CloudFetchBatch(
                  scope: requestedScope,
                  changes: const [],
                  batchId: 'canary-reprojection-probe',
                  generation: generation,
                  nextToken: previousToken,
                  hasMore: false,
                );
              default:
                fail('unexpected continuation token: $previousToken');
            }
          };

      const flags = CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: true,
      );
      final first = await engine(
        flags: flags,
        inboxApplierOverride: retainedApplier,
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(
        first.status,
        CloudSyncRunStatus.degraded,
        reason:
            'failure=${first.failureCategory} safeCode=${first.failureSafeCode}',
      );
      expect(first.counters.retainedUnprojected, 1);
      expect(first.failureCategory, CloudFailureCategory.dependency);
      expect(first.failureSafeCode, 'retained_projection_incomplete');
      expect(first.counters.quarantined, 0);
      expect(first.counters.applied, 1);
      expect(transport.observedFetchTokens, [null, 'canary-parent-page']);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'canary-complete-token',
      );
      expect((await store.readCheckpoint(scope)).pendingBatchId, isNull);
      final retainedEntry = (await store.inboxEntries(
        scope,
      )).firstWhere((entry) => entry.sequence == 1);
      expect(retainedEntry.status, CloudInboxStatus.retainedUnprojected);

      final second = await engine(
        flags: flags,
        coordinatorId: 'canary-parent-now-available',
        inboxApplierOverride: retainedApplier,
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(
        second.status,
        CloudSyncRunStatus.degraded,
        reason:
            'failure=${second.failureCategory} safeCode=${second.failureSafeCode}',
      );
      expect(second.failureCategory, CloudFailureCategory.dependency);
      expect(second.failureSafeCode, 'retained_projection_incomplete');
      expect(second.counters.applied, 1);
      expect(retainedApplier.reprojectCalls, 2);
      expect(transport.observedFetchTokens, [
        null,
        'canary-parent-page',
        'canary-complete-token',
      ]);
      expect(
        (await store.inboxEntries(
          scope,
        )).where((entry) => entry.status == CloudInboxStatus.quarantined),
        isEmpty,
      );
    },
  );

  test(
    'guarded Canary evaluates all 50 rows after a known retryable dependency',
    () async {
      final changes = List.generate(50, (index) => testChange(index + 1));
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: changes,
          batchId: 'canary-retryable-dependency-page',
          generation: 1,
          nextToken: 'canary-retryable-dependency-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_chat_alias_ambiguous',
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
      expect(result.counters.retainedUnprojected, 1);
      expect(result.counters.retried, 0);
      expect(result.counters.applied, 49);
      expect((await store.readCheckpoint(scope)).pendingBatchId, isNull);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'canary-retryable-dependency-token',
      );
      final entries = await store.inboxEntries(scope);
      expect(entries, hasLength(50));
      expect(entries[0].status, CloudInboxStatus.retainedUnprojected);
      expect(
        entries.skip(1),
        everyElement(
          predicate<CloudInboxEntry>(
            (entry) => entry.status == CloudInboxStatus.applied,
          ),
        ),
      );
    },
  );

  for (final safeCode
      in CloudSyncV2DecoderSafeFailureCodes
          .readOnlyCanaryRetainableDependencies) {
    test(
      'guarded Canary retains deterministic decoder dependency $safeCode',
      () async {
        transport.enqueueFetchBatch(
          CloudFetchBatch(
            scope: scope,
            changes: [testChange(1), testChange(2)],
            batchId: 'canary-decoder-dependency-page',
            generation: 1,
            nextToken: 'canary-decoder-dependency-token',
            hasMore: false,
          ),
        );
        applier.resultsBySequence[1] = CloudInboxApplyResult.retryable(
          failureCategory: CloudFailureCategory.dependency,
          safeCode: safeCode,
        );

        final result = await engine(
          flags: const CloudSyncFeatureFlags(
            readOnlyFetch: true,
            semanticApply: true,
          ),
          retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
        ).synchronize(trigger: CloudSyncTrigger.manual);

        expect(result.status, CloudSyncRunStatus.degraded);
        expect(result.failureCategory, CloudFailureCategory.dependency);
        expect(result.failureSafeCode, 'retained_projection_incomplete');
        expect(result.counters.retainedUnprojected, 1);
        expect(result.counters.retried, 0);
        expect(result.counters.applied, 1);
        expect(applier.appliedSequences, [1, 2]);
        expect((await store.readCheckpoint(scope)).pendingBatchId, isNull);
        final entries = await store.inboxEntries(scope);
        expect(entries[0].status, CloudInboxStatus.retainedUnprojected);
        expect(entries[1].status, CloudInboxStatus.applied);
      },
    );
  }

  test(
    'guarded Canary retains a reviewed native deferral and continues the page',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2), testChange(3)],
          batchId: 'canary-native-deferred-page',
          generation: 1,
          nextToken: 'canary-native-deferred-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[2] = const CloudInboxApplyResult.deferred(
        failureCategory: CloudFailureCategory.dependency,
        safeCode: 'native_deferred_unsupported_media_credentials',
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.dependency);
      expect(result.failureSafeCode, 'retained_projection_incomplete');
      expect(result.counters.retainedUnprojected, 1);
      expect(result.counters.retried, 0);
      expect(result.counters.applied, 2);
      expect(applier.appliedSequences, [1, 2, 3]);
      expect((await store.readCheckpoint(scope)).pendingBatchId, isNull);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'canary-native-deferred-token',
      );
      final entries = await store.inboxEntries(scope);
      expect(entries[0].status, CloudInboxStatus.applied);
      expect(entries[1].status, CloudInboxStatus.retainedUnprojected);
      expect(entries[2].status, CloudInboxStatus.applied);
    },
  );

  test(
    'Canary flag disabled keeps decoder dependency as page barrier',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'ordinary-retryable-dependency-page',
          generation: 1,
          nextToken: 'ordinary-retryable-dependency-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.dependency,
        safeCode: 'decoder_reaction_shape_unsupported',
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.counters.retried, 1);
      expect(result.counters.retainedUnprojected, 0);
      expect(applier.appliedSequences, [1]);
      expect((await store.readCheckpoint(scope)).pendingBatchId, isNotNull);
    },
  );

  test(
    'Canary does not retain a dependency with a merely diagnostic-safe code',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'unreviewed-dependency-code-page',
          generation: 1,
          nextToken: 'unreviewed-dependency-code-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.dependency,
        safeCode: 'checkpoint_pending_page_unresolved',
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.counters.retried, 1);
      expect(result.counters.retainedUnprojected, 0);
      expect(applier.appliedSequences, [1]);
      expect((await store.readCheckpoint(scope)).pendingBatchId, isNotNull);
    },
  );

  for (final category in const <CloudFailureCategory>[
    CloudFailureCategory.network,
    CloudFailureCategory.authorization,
    CloudFailureCategory.localStorage,
  ]) {
    test(
      'Canary does not retain retryable ${category.name} failures',
      () async {
        transport.enqueueFetchBatch(
          CloudFetchBatch(
            scope: scope,
            changes: [testChange(1), testChange(2)],
            batchId: 'nondependency-${category.name}-page',
            generation: 1,
            nextToken: 'nondependency-${category.name}-token',
            hasMore: false,
          ),
        );
        applier.resultsBySequence[1] = CloudInboxApplyResult.retryable(
          failureCategory: category,
          safeCode: 'canonical_message_chat_unavailable',
        );

        final result = await engine(
          flags: const CloudSyncFeatureFlags(
            readOnlyFetch: true,
            semanticApply: true,
          ),
          retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
        ).synchronize(trigger: CloudSyncTrigger.manual);

        expect(result.status, CloudSyncRunStatus.degraded);
        expect(result.counters.retried, 1);
        expect(result.counters.retainedUnprojected, 0);
        expect(applier.appliedSequences, [1]);
        expect((await store.readCheckpoint(scope)).pendingBatchId, isNotNull);
      },
    );
  }

  test(
    'persistent dependency failures retain evidence after attempt and age bounds',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'batch-retryable-dependency',
          generation: 1,
          nextToken: 'opaque-token',
          hasMore: false,
        ),
      );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.retryable(
        failureCategory: CloudFailureCategory.dependency,
      );
      final syncEngine = engine(
        maximumDeferredAttempts: 1,
        maximumDeferredAge: const Duration(seconds: 1),
      );

      await syncEngine.synchronize(trigger: CloudSyncTrigger.manual);
      clock.advance(const Duration(seconds: 10));
      final second = await syncEngine.synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      final stored = (await store.inboxEntries(scope)).single;
      expect(second.counters.quarantined, 0);
      expect(second.counters.retainedUnprojected, 1);
      expect(second.counters.retried, 0);
      expect(stored.status, CloudInboxStatus.retainedUnprojected);
      expect(stored.lastFailure, CloudFailureCategory.dependency);
    },
  );

  test('persists pull backoff and suppresses restart retry storm', () async {
    transport.enqueueFetchFailure(
      CloudSyncFailure(category: CloudFailureCategory.network),
    );
    final first = await engine().synchronize(trigger: CloudSyncTrigger.startup);
    expect(first.status, CloudSyncRunStatus.degraded);
    expect(first.failureCategory, CloudFailureCategory.network);
    expect(transport.fetchCallCount, 1);

    final checkpoint = await store.readCheckpoint(scope);
    expect(checkpoint.consecutivePullFailures, 1);
    expect(
      checkpoint.nextPullEligibleAt,
      testEpoch.add(const Duration(seconds: 10)),
    );

    final restarted = engine(coordinatorId: 'coordinator-after-restart');
    await restarted.synchronize(trigger: CloudSyncTrigger.startup);
    expect(transport.fetchCallCount, 1);
  });

  test('backlog read failure preserves an existing degraded cause', () async {
    store = _FailingRetainedBacklogReadStore();
    transport.enqueueFetchFailure(
      CloudSyncFailure(
        category: CloudFailureCategory.network,
        safeCode: 'fetch_timeout',
      ),
    );

    final result = await engine().synchronize(trigger: CloudSyncTrigger.manual);

    expect(result.status, CloudSyncRunStatus.degraded);
    expect(result.failureCategory, CloudFailureCategory.network);
    expect(result.failureSafeCode, 'fetch_timeout');
    expect(result.retainedUnprojectedBacklog, 0);
    expect((store as _FailingRetainedBacklogReadStore).readCalls, 1);
  });

  test(
    'backlog read failure prevents an otherwise successful completion',
    () async {
      store = _FailingRetainedBacklogReadStore();
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          batchId: 'successful-page-before-backlog-read-failure',
          generation: 1,
          changes: const [],
          nextToken: 'durable-token',
          hasMore: false,
        ),
      );

      final result = await engine().synchronize(
        trigger: CloudSyncTrigger.manual,
      );

      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(
        result.failureSafeCode,
        'retained_unprojected_backlog_read_failed',
      );
      expect((store as _FailingRetainedBacklogReadStore).readCalls, 1);
    },
  );

  test(
    'explicit read-only manual run can probe through durable pull backoff',
    () async {
      transport.enqueueFetchFailure(
        CloudSyncFailure(category: CloudFailureCategory.authorization),
      );
      const flags = CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: false,
      );
      final first = await engine(
        flags: flags,
      ).synchronize(trigger: CloudSyncTrigger.startup);
      expect(first.failureCategory, CloudFailureCategory.authorization);
      expect(transport.fetchCallCount, 1);

      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          batchId: 'manual-backoff-probe',
          generation: 1,
          changes: const [],
          nextToken: 'fresh-token',
          hasMore: false,
        ),
      );
      final manual = await engine(
        flags: flags,
        allowManualPullBackoffOverride: true,
        coordinatorId: 'manual-diagnostic',
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(manual.status, CloudSyncRunStatus.completed);
      expect(transport.fetchCallCount, 2);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.consecutivePullFailures, 0);
      expect(checkpoint.nextPullEligibleAt, isNull);
    },
  );

  test('manual pull backoff override rejects write-capable configs', () {
    expect(
      () => CloudSyncEngineConfig(
        allowManualPullBackoffOverride: true,
        flags: const CloudSyncFeatureFlags(saves: true),
      ),
      throwsArgumentError,
    );
  });

  test(
    'unknown reconciliation-only lane rejects every mutation-capable shape',
    () {
      expect(
        () => CloudSyncEngineConfig(reconcileUnknownOutcomesOnly: true),
        throwsArgumentError,
      );
      expect(
        () => CloudSyncEngineConfig(
          reconcileUnknownOutcomesOnly: true,
          flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        ),
        throwsArgumentError,
      );
      expect(
        () => CloudSyncEngineConfig(
          maximumBatchSize: 1,
          maximumOutboxBatchesPerRun: 1,
          reconcileUnknownOutcomesOnly: true,
          flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        ),
        returnsNormally,
      );
    },
  );

  test('fresh fetch reserve holds at least one complete transport page', () {
    const readOnlySemanticFlags = CloudSyncFeatureFlags(
      readOnlyFetch: true,
      semanticApply: true,
      saves: false,
      deletions: false,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 1,
        flags: readOnlySemanticFlags,
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 5,
        flags: readOnlySemanticFlags,
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 4,
        flags: readOnlySemanticFlags,
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: -1,
        flags: readOnlySemanticFlags,
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 2,
        flags: readOnlySemanticFlags,
      ),
      returnsNormally,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 2,
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: true,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        maximumBatchSize: 2,
        maximumInboxEntriesPerRun: 4,
        minimumInboxEntriesReservedForFetch: 2,
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          deletions: true,
        ),
      ),
      throwsArgumentError,
    );
    for (final flags in const [
      CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: true,
        profiles: true,
      ),
      CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: true,
        notificationHints: true,
      ),
    ]) {
      expect(
        () => CloudSyncEngineConfig(
          maximumBatchSize: 2,
          maximumInboxEntriesPerRun: 4,
          minimumInboxEntriesReservedForFetch: 2,
          flags: flags,
        ),
        throwsArgumentError,
      );
    }
  });

  test('Canary dependency retention rejects non-semantic or write configs', () {
    expect(
      () => CloudSyncEngineConfig(
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: true,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        retainKnownDependencyDeferralsForReadOnlySemanticCanary: true,
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
      ),
      returnsNormally,
    );
  });

  test(
    'manual semantic run invokes fenced unknown barrier recovery before apply',
    () async {
      final recoveryStore = _UnknownBarrierRecoveryTrackingStore();
      store = recoveryStore;
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          batchId: 'post-recovery-empty-page',
          generation: 1,
          changes: const [],
          nextToken: 'post-recovery-token',
          hasMore: false,
        ),
      );
      final cutoff = testEpoch.subtract(const Duration(seconds: 1));

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: false,
        ),
        unknownInboxBarrierRecoveryCutoff: cutoff,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.completed);
      expect(recoveryStore.calls, 1);
      expect(recoveryStore.scope, scope);
      expect(recoveryStore.now, testEpoch);
      expect(recoveryStore.cutoff, cutoff);
      expect(recoveryStore.leaseFence, isNotNull);
    },
  );

  test('unknown barrier recovery rejects non-semantic or write configs', () {
    final cutoff = DateTime.utc(2026, 8, 29);
    expect(
      () => CloudSyncEngineConfig(unknownInboxBarrierRecoveryCutoff: cutoff),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        unknownInboxBarrierRecoveryCutoff: cutoff,
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
          saves: true,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => CloudSyncEngineConfig(
        unknownInboxBarrierRecoveryCutoff: DateTime(2026, 8, 29),
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
      ),
      throwsArgumentError,
    );
  });

  test(
    'bounds a stalled read-only fetch and persists network backoff',
    () async {
      final fetchStarted = Completer<void>();
      transport.fetchHandler =
          (requestedScope, token, generation, limit) async {
            fetchStarted.complete();
            return Completer<CloudFetchBatch>().future;
          };

      final run = engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: false,
        ),
        fetchOperationTimeout: const Duration(milliseconds: 20),
      ).synchronize(trigger: CloudSyncTrigger.manual);
      await fetchStarted.future;

      final result = await run.timeout(const Duration(seconds: 1));

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(result.failureCategory, CloudFailureCategory.network);
      expect(transport.fetchCallCount, 1);
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.consecutivePullFailures, 1);
      expect(
        checkpoint.nextPullEligibleAt,
        testEpoch.add(const Duration(seconds: 10)),
      );
    },
  );

  test(
    'local and durable coordinator guards reject overlapping runs',
    () async {
      final fetchStarted = Completer<void>();
      final releaseFetch = Completer<void>();
      transport.fetchHandler =
          (requestedScope, token, generation, limit) async {
            fetchStarted.complete();
            await releaseFetch.future;
            return CloudFetchBatch(
              scope: requestedScope,
              changes: const [],
              batchId: 'overlap-batch',
              generation: 1,
              nextToken: token,
              hasMore: false,
            );
          };
      final firstEngine = engine();
      final firstRun = firstEngine.synchronize(
        trigger: CloudSyncTrigger.manual,
      );
      await fetchStarted.future;

      final localOverlap = await firstEngine.synchronize(
        trigger: CloudSyncTrigger.manual,
      );
      expect(localOverlap.status, CloudSyncRunStatus.skipped);
      expect(localOverlap.skipReason, CloudSyncSkipReason.localRunActive);

      final otherEngine = engine(coordinatorId: 'coordinator-b');
      final durableOverlap = await otherEngine.synchronize(
        trigger: CloudSyncTrigger.manual,
      );
      expect(durableOverlap.status, CloudSyncRunStatus.skipped);
      expect(
        durableOverlap.skipReason,
        CloudSyncSkipReason.coordinatorLeaseUnavailable,
      );

      releaseFetch.complete();
      await firstRun;
    },
  );

  test(
    'cancellation after fetch journals without promoting a nonterminal page',
    () async {
      final fetchStarted = Completer<void>();
      final releaseFetch = Completer<void>();
      transport.fetchHandler =
          (requestedScope, token, generation, limit) async {
            fetchStarted.complete();
            await releaseFetch.future;
            return CloudFetchBatch(
              scope: requestedScope,
              changes: [testChange(1)],
              batchId: 'cancelled-batch',
              generation: 1,
              nextToken: 'opaque-token-after-cancel',
              hasMore: false,
            );
          };
      final cancellation = CloudSyncCancellationToken();
      final run = engine().synchronize(
        trigger: CloudSyncTrigger.manual,
        cancellationToken: cancellation,
      );
      await fetchStarted.future;
      cancellation.cancel();
      releaseFetch.complete();

      final result = await run;
      expect(result.status, CloudSyncRunStatus.cancelled);
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect(
        (await store.readCheckpoint(scope)).pendingBatchId,
        'cancelled-batch',
      );
      expect(await store.inboxEntries(scope), hasLength(1));
      expect(applier.appliedSequences, isEmpty);
    },
  );

  test(
    'read-only shadow rejects an oversized page without advancing token',
    () async {
      final observer = MemoryCloudSyncObserver();
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1), testChange(2)],
          batchId: 'shadow-over-budget',
          generation: 1,
          nextToken: 'must-not-commit',
          hasMore: false,
        ),
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: false,
        ),
        shadowJournalBudget: CloudShadowJournalBudget(
          maximumEntriesPerScope: 1,
        ),
        observer: observer,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.degraded);
      expect(
        result.shadowJournalBlockReason,
        CloudShadowJournalBlockReason.maximumEntries,
      );
      expect(result.counters.fetched, 0);
      expect(result.counters.shadowJournalRejectedEntries, 2);
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect(await store.inboxEntries(scope), isEmpty);
      final blocked = observer.events.singleWhere(
        (event) => event.type == CloudSyncEventType.shadowJournalBlocked,
      );
      expect(
        blocked.shadowJournalBlockReason,
        CloudShadowJournalBlockReason.maximumEntries,
      );
      expect(blocked.toString(), isNot(contains('must-not-commit')));
    },
  );

  test(
    'migrated stale pending journal blocks before the network request',
    () async {
      await seedGeneralJournal(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(1)],
          batchId: 'pre-budget-shadow-page',
          generation: 1,
          nextToken: 'preserved-token',
          hasMore: false,
        ),
        now: testEpoch.subtract(const Duration(days: 2)),
      );
      final observer = MemoryCloudSyncObserver();

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: false,
        ),
        shadowJournalBudget: CloudShadowJournalBudget(
          maximumPendingAge: const Duration(days: 1),
        ),
        observer: observer,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(transport.fetchCallCount, 0);
      expect(result.status, CloudSyncRunStatus.degraded);
      expect(
        result.shadowJournalBlockReason,
        CloudShadowJournalBlockReason.maximumAge,
      );
      expect(result.counters.shadowJournalEntries, 1);
      expect(result.counters.shadowJournalEstimatedBytes, greaterThan(0));
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
      expect(await store.inboxEntries(scope), hasLength(1));
    },
  );

  test('missing upload outcome rejects the complete batch', () async {
    final confirmed = testOutboxOperation(scope, 1);
    final omitted = testOutboxOperation(scope, 2);
    await store.enqueueOutbox(confirmed);
    await store.enqueueOutbox(omitted);
    transport.enqueuePushResult(
      CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: confirmed.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
        ],
      ),
    );

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.counters.confirmed, 0);
    expect(result.counters.retried, 0);
    final outbox = await store.outboxEntries(scope);
    for (final operation in outbox) {
      expect(operation.status, CloudOutboxStatus.unknownOutcome);
      expect(operation.attemptCount, 1);
      expect(operation.lastFailure, CloudFailureCategory.unknown);
    }
  });

  test(
    'timed-out push remains unknown until native operations quiesce',
    () async {
      final operation = testOutboxOperation(scope, 807);
      await store.enqueueOutbox(operation);
      final pushEntered = Completer<void>();
      final quiescenceStarted = Completer<void>();
      final nativePushResult = Completer<CloudPushBatchResult>();
      transport.pushHandler = (_, operations) {
        pushEntered.complete();
        return nativePushResult.future;
      };
      transport.quiescenceHandler = () async {
        quiescenceStarted.complete();
        await nativePushResult.future;
      };

      final run = engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
        writeOperationTimeout: const Duration(milliseconds: 5),
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);
      var runReturned = false;
      final completion = run.then<void>((_) {
        runReturned = true;
      });

      await pushEntered.future;
      await quiescenceStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runReturned, isFalse);
      expect(transport.quiescenceCallCount, 1);
      expect(transport.mutationUnknownSignalCount, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );

      nativePushResult.complete(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        ),
      );
      await completion;
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );
      expect(transport.mutationUnknownSignalCount, 1);
    },
  );

  test(
    'thrown transport failure is frozen before it can be replayed',
    () async {
      final operation = testOutboxOperation(scope, 3);
      await store.enqueueOutbox(operation);
      transport.pushHandler = (_, _) async => throw StateError('response lost');

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      var stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.unknownOutcome);
      expect(stored.lastFailure, CloudFailureCategory.unknown);
      expect(transport.pushCallCount, 1);

      clock.advance(const Duration(minutes: 3));
      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);
      stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.unknownOutcome);
      expect(transport.pushCallCount, 1);
    },
  );

  test('thrown conflict is ambiguous and cannot enter merge retry', () async {
    final operation = testOutboxOperation(scope, 4);
    await store.enqueueOutbox(operation);
    transport.pushHandler = (_, _) async => throw CloudSyncFailure(
      category: CloudFailureCategory.conflict,
      safeCode: 'simulated_unproven_conflict',
    );

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.unknownOutcome,
    );
    expect(transport.pushCallCount, 1);
    expect(transport.conflictCallCount, 0);

    clock.advance(const Duration(minutes: 3));
    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);
    expect(transport.pushCallCount, 1);
    expect(transport.conflictCallCount, 0);
  });

  test(
    'thrown authorization failure cannot clear submission identity',
    () async {
      final operation = testOutboxOperation(scope, 5);
      await store.enqueueOutbox(operation);
      transport.pushHandler = (_, _) async => throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'simulated_unproven_authorization_failure',
      );

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      final stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.unknownOutcome);
      expect(stored.lastFailure, CloudFailureCategory.unknown);
      expect(stored.appleRequestUuid, isNotNull);
      expect(stored.appleOperationUuid, isNotNull);
      expect(transport.authenticationRefreshCallCount, 0);
      expect(transport.pushCallCount, 1);
    },
  );

  test('thrown PCS failure cannot clear submission identity', () async {
    final operation = testOutboxOperation(scope, 7);
    await store.enqueueOutbox(operation);
    transport.pushHandler = (_, _) async => throw CloudSyncFailure(
      category: CloudFailureCategory.pcsUnavailable,
      safeCode: 'simulated_unproven_pcs_failure',
    );

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(stored.status, CloudOutboxStatus.unknownOutcome);
    expect(stored.lastFailure, CloudFailureCategory.unknown);
    expect(stored.appleRequestUuid, isNotNull);
    expect(stored.appleOperationUuid, isNotNull);
    expect(transport.pcsRefreshCallCount, 0);
    expect(transport.pushCallCount, 1);
  });

  test(
    'generic retryable result remains frozen with its exact identity',
    () async {
      final operation = testOutboxOperation(scope, 6);
      await store.enqueueOutbox(operation);
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.retryable,
              failureCategory: CloudFailureCategory.server,
            ),
          ],
        ),
      );

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      final stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.unknownOutcome);
      expect(stored.appleRequestUuid, isNotNull);
      expect(stored.appleOperationUuid, isNotNull);
      expect(transport.pushCallCount, 1);
    },
  );

  test('unknown upload outcome rejects the complete batch', () async {
    final first = testOutboxOperation(scope, 1);
    final second = testOutboxOperation(scope, 2);
    final unknown = testOutboxOperation(scope, 99);
    await store.enqueueOutbox(first);
    await store.enqueueOutbox(second);
    transport.enqueuePushResult(
      CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: first.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
          CloudPushOutcome(
            operationId: second.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
          CloudPushOutcome(
            operationId: unknown.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
        ],
      ),
    );

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.counters.confirmed, 0);
    expect(result.counters.retried, 0);
    for (final operation in await store.outboxEntries(scope)) {
      expect(operation.status, CloudOutboxStatus.unknownOutcome);
      expect(operation.attemptCount, 1);
      expect(operation.lastFailure, CloudFailureCategory.unknown);
    }
  });

  test('server read confirms an ambiguous write without replay', () async {
    await seedAmbiguousOutbox(801);
    transport.unknownOutcomeHandler = (_, operation) async =>
        const CloudUnknownOutcomeResolution.committed();

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.counters.confirmed, 1);
    expect(transport.unknownOutcomeCallCount, 1);
    expect(transport.pushCallCount, 1);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.confirmed,
    );
  });

  test('reconciliation timeout never replays the write', () async {
    await seedAmbiguousOutbox(808);
    final nativeResolution = Completer<CloudUnknownOutcomeResolution>();
    final quiescenceStarted = Completer<void>();
    transport.unknownOutcomeHandler = (_, _) => nativeResolution.future;
    transport.quiescenceHandler = () async {
      quiescenceStarted.complete();
      await nativeResolution.future;
    };

    final run = engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
      writeOperationTimeout: const Duration(milliseconds: 5),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);
    var runReturned = false;
    final completion = run.then<void>((_) {
      runReturned = true;
    });

    await quiescenceStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runReturned, isFalse);
    expect(transport.pushCallCount, 1);

    nativeResolution.complete(const CloudUnknownOutcomeResolution.committed());
    await completion;
    expect(transport.unknownOutcomeCallCount, 1);
    expect(transport.pushCallCount, 1);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.unknownOutcome,
    );

    clock.advance(const Duration(minutes: 1));
    transport.quiescenceHandler = null;
    transport.unknownOutcomeHandler = (_, _) async =>
        const CloudUnknownOutcomeResolution.unresolved(
          failureCategory: CloudFailureCategory.network,
        );
    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
      writeOperationTimeout: const Duration(milliseconds: 5),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);
    expect(transport.pushCallCount, 1);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.unknownOutcome,
    );
  });

  test(
    'server-proven absence requires a later run before one resubmission',
    () async {
      final operation = await seedAmbiguousOutbox(802);
      transport.unknownOutcomeHandler = (_, operation) async =>
          const CloudUnknownOutcomeResolution.notApplied();
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        ),
      );

      final first = await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(first.counters.retried, 1);
      expect(first.counters.confirmed, 0);
      expect(transport.unknownOutcomeCallCount, 1);
      expect(transport.pushCallCount, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.pending,
      );

      final second = await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(second.counters.retried, 0);
      expect(second.counters.confirmed, 1);
      expect(transport.pushCallCount, 2);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.confirmed,
      );
    },
  );

  test(
    'unresolved server read backs off without replaying the write',
    () async {
      await seedAmbiguousOutbox(803);
      transport.unknownOutcomeHandler = (_, _) async =>
          const CloudUnknownOutcomeResolution.unresolved(
            failureCategory: CloudFailureCategory.network,
            retryAfter: Duration(seconds: 30),
          );

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);
      var stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.unknownOutcome);
      expect(stored.attemptCount, 2);
      expect(
        stored.nextEligibleAt,
        clock.value.add(const Duration(seconds: 30)),
      );
      expect(transport.pushCallCount, 1);
      expect(transport.unknownOutcomeCallCount, 1);

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);
      expect(transport.unknownOutcomeCallCount, 1);
      expect(transport.pushCallCount, 1);

      clock.advance(const Duration(seconds: 30));
      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);
      stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.unknownOutcome);
      expect(transport.unknownOutcomeCallCount, 2);
      expect(transport.pushCallCount, 1);
    },
  );

  test(
    'divergent server state merges but waits for a later submission run',
    () async {
      final operation = await seedAmbiguousOutbox(804);
      transport.unknownOutcomeHandler = (_, operation) async =>
          const CloudUnknownOutcomeResolution.serverRecordChanged();
      transport.conflictHandler = (_, leasedOperation) async {
        return CloudServerConflictResolution.mergedForRetry(
          encryptedPayloadReference: testProtectedReference('M'),
          payloadSha256: testSha256('a'),
          serverRecordIdHash: leasedOperation.serverRecordIdHash!,
          encryptedRawRecordReference: 'protected:ambiguous-server-record',
        );
      };
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        ),
      );

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(transport.unknownOutcomeCallCount, 1);
      expect(transport.conflictCallCount, 1);
      expect(transport.pushCallCount, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.pending,
      );

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(transport.pushCallCount, 2);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.confirmed,
      );
    },
  );

  test(
    'reconciliation-only lane keeps divergent state fenced and never merges',
    () async {
      await seedAmbiguousOutbox(812);
      transport.unknownOutcomeHandler = (_, operation) async =>
          const CloudUnknownOutcomeResolution.serverRecordChanged();
      transport.conflictHandler = (_, operation) async =>
          CloudServerConflictResolution.mergedForRetry(
            encryptedPayloadReference: testProtectedReference('M'),
            payloadSha256: testSha256('a'),
            serverRecordIdHash: operation.serverRecordIdHash!,
            encryptedRawRecordReference: 'protected:should-not-be-read',
          );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        batchSize: 1,
        maximumOutboxBatches: 1,
        reconcileUnknownOutcomesOnly: true,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(result.counters.confirmed, 0);
      expect(result.counters.quarantined, 0);
      expect(transport.unknownOutcomeCallCount, 1);
      expect(transport.conflictCallCount, 0);
      expect(transport.pushCallCount, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.unknownOutcome,
      );
    },
  );

  test('retryable conflict reconciliation stays unknown', () async {
    await seedAmbiguousOutbox(809);
    transport.unknownOutcomeHandler = (_, operation) async =>
        const CloudUnknownOutcomeResolution.serverRecordChanged();
    transport.conflictHandler = (_, _) async =>
        const CloudServerConflictResolution.retryable(
          failureCategory: CloudFailureCategory.network,
        );

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(stored.status, CloudOutboxStatus.unknownOutcome);
    expect(stored.appleRequestUuid, isNotNull);
    expect(stored.appleOperationUuid, isNotNull);
    expect(transport.conflictCallCount, 1);
    expect(transport.pushCallCount, 1);
  });

  test('retryable conflict quarantine stays unknown', () async {
    await seedAmbiguousOutbox(810);
    transport.unknownOutcomeHandler = (_, operation) async =>
        const CloudUnknownOutcomeResolution.serverRecordChanged();
    transport.conflictHandler = (_, _) async =>
        const CloudServerConflictResolution.quarantined(
          failureCategory: CloudFailureCategory.throttled,
        );

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(stored.status, CloudOutboxStatus.unknownOutcome);
    expect(stored.appleRequestUuid, isNotNull);
    expect(stored.appleOperationUuid, isNotNull);
    expect(transport.conflictCallCount, 1);
    expect(transport.pushCallCount, 1);
  });

  test('terminal reconciliation failure quarantines without replay', () async {
    await seedAmbiguousOutbox(805);
    transport.unknownOutcomeHandler = (_, _) async =>
        const CloudUnknownOutcomeResolution.quarantined(
          failureCategory: CloudFailureCategory.malformedRecord,
        );

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.counters.quarantined, 1);
    expect(transport.pushCallCount, 1);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.quarantined,
    );
  });

  test(
    'lost coordinator lease during push cannot confirm the outbox',
    () async {
      store = _RejectingCoordinatorRenewalStore();
      final operation = testOutboxOperation(scope, 1);
      await store.enqueueOutbox(operation);
      transport.pushHandler = (scope, operations) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operations.single.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        );
      };

      final result = await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
        coordinatorLeaseDuration: const Duration(milliseconds: 60),
        outboxLeaseDuration: const Duration(seconds: 1),
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      final stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.unknownOutcome);
      expect(stored.confirmedAt, isNull);
    },
  );

  test('generation advance cannot overtake an in-flight remote push', () async {
    final operation = testOutboxOperation(scope, 44);
    await store.enqueueOutbox(operation);
    final pushStarted = Completer<void>();
    final releasePush = Completer<void>();
    transport.pushHandler = (requestedScope, operations) async {
      pushStarted.complete();
      await releasePush.future;
      return CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: operations.single.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
        ],
      );
    };

    final run = engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);
    await pushStarted.future;

    await expectLater(
      store.advanceOutboxGeneration(scope, now: clock.value),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'generation_advance_coordinator_active',
        ),
      ),
    );
    expect((await store.readCheckpoint(scope)).generation, 1);

    releasePush.complete();
    await run;
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.confirmed,
    );
    expect(
      (await store.advanceOutboxGeneration(scope, now: clock.value)).generation,
      2,
    );
  });

  test(
    'authorization response pauses before a later refreshed attempt',
    () async {
      final operation = testOutboxOperation(scope, 1);
      await store.enqueueOutbox(operation);
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.unauthorized,
              failureCategory: CloudFailureCategory.authorization,
            ),
          ],
        ),
      );
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        ),
      );
      transport.authenticationRefreshHandler = (_) async => true;

      final syncEngine = engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        pausedRetryDelay: const Duration(hours: 6),
      );
      final first = await syncEngine.synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );

      expect(first.counters.confirmed, 0);
      expect(transport.authenticationRefreshCallCount, 0);
      expect(transport.pushCallCount, 1);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.paused,
      );

      clock.advance(const Duration(hours: 6));
      final second = await syncEngine.synchronize(
        trigger: CloudSyncTrigger.localOutbox,
      );
      expect(second.counters.confirmed, 1);
      expect(transport.authenticationRefreshCallCount, 1);
      expect(transport.pushCallCount, 2);
      expect(transport.observedAppleRequestUuids[0].single, isNotNull);
      expect(transport.observedAppleOperationUuids[0].single, isNotNull);
      expect(
        transport.observedAppleRequestUuids[1].single,
        isNot(transport.observedAppleRequestUuids[0].single),
      );
      expect(
        transport.observedAppleOperationUuids[1].single,
        isNot(transport.observedAppleOperationUuids[0].single),
      );
    },
  );

  test('authorization response cannot trigger a same-run replay', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    transport.enqueuePushResult(
      CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: operation.operationId,
            disposition: CloudPushDisposition.unauthorized,
            failureCategory: CloudFailureCategory.authorization,
          ),
        ],
      ),
    );
    transport.authenticationRefreshHandler = (_) async => true;

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.counters.confirmed, 0);
    expect(result.counters.retried, 0);
    expect(transport.authenticationRefreshCallCount, 0);
    expect(transport.pushCallCount, 1);
    final stored = (await store.outboxEntries(scope)).single;
    expect(stored.status, CloudOutboxStatus.paused);
    expect(stored.lastFailure, CloudFailureCategory.authorization);
    expect(stored.appleRequestUuid, isNull);
    expect(stored.appleOperationUuid, isNull);
  });

  test('uploads attachment dependency before its owning message', () async {
    final attachment = testOutboxOperation(scope, 1);
    final message = testOutboxOperation(
      scope,
      2,
      dependencies: [attachment.operationId],
    );
    await store.enqueueOutbox(message);
    await store.enqueueOutbox(attachment);
    transport.pushHandler = (requestedScope, operations) async {
      return CloudPushBatchResult(
        outcomes: operations.map(
          (operation) => CloudPushOutcome(
            operationId: operation.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
        ),
      );
    };

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.counters.confirmed, 2);
    expect(transport.observedPushOperationIds, [
      [attachment.operationId],
      [message.operationId],
    ]);
  });

  test('bounds each upload batch and total batches', () async {
    for (var index = 0; index < 5; index++) {
      await store.enqueueOutbox(testOutboxOperation(scope, index));
    }
    transport.pushHandler = (requestedScope, operations) async {
      return CloudPushBatchResult(
        outcomes: operations.map(
          (operation) => CloudPushOutcome(
            operationId: operation.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
        ),
      );
    };

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      batchSize: 2,
      maximumOutboxBatches: 2,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(result.counters.confirmed, 4);
    expect(
      transport.observedPushOperationIds.every((batch) => batch.length <= 2),
      isTrue,
    );
    expect(
      (await store.outboxEntries(
        scope,
      )).where((operation) => operation.status == CloudOutboxStatus.pending),
      hasLength(1),
    );
  });

  test(
    'authorization refresh sends an all-paused outbox without a pull',
    () async {
      final paused = testOutboxOperation(scope, 1);
      await seedPausedOutbox(
        paused,
        category: CloudFailureCategory.authorization,
      );
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: paused.operationId,
              disposition: CloudPushDisposition.confirmed,
            ),
          ],
        ),
      );
      transport.authenticationRefreshHandler = (_) async => true;

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        maximumOutboxBatches: 1,
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      final entries = await store.outboxEntries(scope);
      expect(transport.authenticationRefreshCallCount, 1);
      expect(transport.pushCallCount, 1);
      expect(entries.single.status, CloudOutboxStatus.confirmed);
      expect(entries.single.lastFailure, isNull);
    },
  );

  test('PCS refresh sends an all-paused outbox without a pull', () async {
    final paused = testOutboxOperation(scope, 1);
    await seedPausedOutbox(
      paused,
      category: CloudFailureCategory.pcsUnavailable,
    );
    transport.enqueuePushResult(
      CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: paused.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
        ],
      ),
    );
    transport.pcsRefreshHandler = (_) async => true;

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final entries = await store.outboxEntries(scope);
    expect(transport.pcsRefreshCallCount, 1);
    expect(transport.pushCallCount, 1);
    expect(entries.single.status, CloudOutboxStatus.confirmed);
    expect(entries.single.lastFailure, isNull);
  });

  test('failed push-only refresh leaves paused work untouched', () async {
    final paused = testOutboxOperation(scope, 1);
    await seedPausedOutbox(
      paused,
      category: CloudFailureCategory.authorization,
    );
    transport.authenticationRefreshHandler = (_) async => false;

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(transport.authenticationRefreshCallCount, 1);
    expect(transport.pushCallCount, 0);
    expect(stored.status, CloudOutboxStatus.paused);
    expect(stored.lastFailure, CloudFailureCategory.authorization);
    expect(stored.nextEligibleAt, testEpoch.add(const Duration(hours: 6)));

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(transport.authenticationRefreshCallCount, 1);
  });

  test(
    'paused authorization refresh respects its durable retry delay',
    () async {
      final operation = testOutboxOperation(scope, 1);
      await store.enqueueOutbox(operation);
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.unauthorized,
              failureCategory: CloudFailureCategory.authorization,
            ),
          ],
        ),
      );
      transport.authenticationRefreshHandler = (_) async => false;
      final syncEngine = engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
        pausedRetryDelay: const Duration(hours: 6),
      );

      await syncEngine.synchronize(trigger: CloudSyncTrigger.localOutbox);
      await syncEngine.synchronize(trigger: CloudSyncTrigger.localOutbox);

      final stored = (await store.outboxEntries(scope)).single;
      expect(transport.authenticationRefreshCallCount, 0);
      expect(transport.pushCallCount, 1);
      expect(stored.status, CloudOutboxStatus.paused);
      expect(stored.nextEligibleAt, testEpoch.add(const Duration(hours: 6)));
    },
  );

  test('server-record-changed fetches, merges, and retries', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    transport.enqueuePushResult(
      CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: operation.operationId,
            disposition: CloudPushDisposition.serverRecordChanged,
            failureCategory: CloudFailureCategory.conflict,
          ),
        ],
      ),
    );
    transport.enqueuePushResult(
      CloudPushBatchResult(
        outcomes: [
          CloudPushOutcome(
            operationId: operation.operationId,
            disposition: CloudPushDisposition.confirmed,
          ),
        ],
      ),
    );
    transport.conflictHandler = (requestedScope, leasedOperation) async {
      return CloudServerConflictResolution.mergedForRetry(
        encryptedPayloadReference: testProtectedReference('N'),
        payloadSha256: testSha256('b'),
        serverRecordIdHash: leasedOperation.serverRecordIdHash!,
        encryptedRawRecordReference: 'protected:merged-raw-record',
        etagHash: 'merged-etag-digest',
      );
    };

    final result = await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(transport.conflictCallCount, 1);
    expect(transport.pushCallCount, 2);
    expect(result.counters.confirmed, 1);
    expect(stored.status, CloudOutboxStatus.confirmed);
    expect(stored.payloadSha256, testSha256('b'));
    expect(
      (await store.readRecordMap(
        scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        generation: operation.checkpointGeneration,
      ))!.encryptedRawRecordReference,
      'protected:merged-raw-record',
    );
  });

  test('unknown upload failures freeze without automatic replay', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    transport.pushHandler = (requestedScope, operations) async {
      return CloudPushBatchResult(
        outcomes: operations.map(
          (item) => CloudPushOutcome(
            operationId: item.operationId,
            disposition: CloudPushDisposition.quarantined,
            failureCategory: CloudFailureCategory.unknown,
          ),
        ),
      );
    };
    final syncEngine = engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
    );

    await syncEngine.synchronize(trigger: CloudSyncTrigger.localOutbox);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.unknownOutcome,
    );
    clock.advance(const Duration(seconds: 10));
    await syncEngine.synchronize(trigger: CloudSyncTrigger.localOutbox);
    final stored = (await store.outboxEntries(scope)).single;
    expect(stored.status, CloudOutboxStatus.unknownOutcome);
    expect(stored.attemptCount, 2);
    expect(transport.recordMappingCallCount, 1);
    expect(transport.pushCallCount, 1);
    expect(transport.unknownOutcomeCallCount, 1);
  });

  test(
    'profile stream is inert until its independent flag is enabled',
    () async {
      scope = testScope(streamKind: CloudSyncStreamKind.profiles);
      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          profiles: false,
        ),
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.skipped);
      expect(result.skipReason, CloudSyncSkipReason.featureDisabled);
      expect(transport.fetchCallCount, 0);
      expect(transport.pushCallCount, 0);
    },
  );
}

final class _UnknownBarrierRecoveryTrackingStore extends InMemoryCloudSyncStore
    implements CloudUnknownInboxBarrierRecoveryStore {
  int calls = 0;
  CloudSyncScope? scope;
  DateTime? now;
  DateTime? cutoff;
  CloudCoordinatorLeaseFence? leaseFence;

  @override
  Future<bool> requeueUnknownInboxBarrier(
    CloudSyncScope scope, {
    required DateTime now,
    required DateTime quarantinedBefore,
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    calls++;
    this.scope = scope;
    this.now = now;
    cutoff = quarantinedBefore;
    this.leaseFence = leaseFence;
    return true;
  }
}

class _RecoveryTrackingStore extends InMemoryCloudSyncStore {
  int recoverExpiredOutboxLeaseCalls = 0;

  @override
  Future<int> recoverExpiredOutboxLeases(
    CloudSyncScope scope, {
    required DateTime now,
  }) {
    recoverExpiredOutboxLeaseCalls++;
    return super.recoverExpiredOutboxLeases(scope, now: now);
  }
}

class _FailingRetainedBacklogReadStore extends InMemoryCloudSyncStore {
  int readCalls = 0;

  @override
  Future<int> readRetainedUnprojectedInboxCount(CloudSyncScope scope) async {
    readCalls++;
    throw StateError('simulated_retained_backlog_read_failure');
  }
}

typedef _RetainedProjectionEngineCallback =
    Future<CloudRetainedProjectionResult> Function(
      CloudSyncScope scope,
      int generation,
      CloudCoordinatorLeaseFence leaseFence,
      int limit,
    );

final class _RetainedProjectionEngineApplier extends FakeCloudInboxApplier
    implements CloudRetainedProjectionReprocessor {
  _RetainedProjectionEngineApplier({required this.onReproject});

  final _RetainedProjectionEngineCallback onReproject;
  int reprojectCalls = 0;

  @override
  Future<CloudRetainedProjectionResult> reprojectRetainedUnprojected({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  }) async {
    reprojectCalls++;
    return onReproject(scope, generation, leaseFence, limit);
  }
}

class _OutboxPresenceRaceStore extends InMemoryCloudSyncStore {
  int hiddenPresenceChecks = 0;

  @override
  Future<bool> hasNonterminalOutbox(CloudSyncScope scope) async {
    hiddenPresenceChecks++;
    return false;
  }
}

final class _RetainingFakeCloudSyncTransport extends FakeCloudSyncTransport
    implements CloudSyncConfirmedReceiptRetentionPolicy {
  @override
  bool get retainConfirmedReceiptsForReplay => true;
}

class _ProtectedRecoveryTrackingStore extends InMemoryCloudSyncStore
    implements
        CloudProtectedPageLeaseAdoptionStore,
        CloudProtectedOutboundLeaseAdoptionStore {
  final Set<String> outboundLeaseReferences = {};

  @override
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  }) async => {};

  @override
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  }) async =>
      CloudProtectedReferenceSnapshot(references: const {}, isComplete: true);

  @override
  Future<void> releaseAdoptedProtectedPageLeaseReferences(
    Iterable<String> leaseReferences,
  ) async {}

  @override
  Future<Set<String>> readLiveProtectedOutboundLeaseReferences({
    required int maximumCount,
  }) async => Set.unmodifiable(outboundLeaseReferences);
}

class _RecoveryOrderedProtectedWriteTransport extends FakeCloudSyncTransport
    implements CloudProtectedPageLeaseTransport {
  _RecoveryOrderedProtectedWriteTransport({required this.events});

  final List<String> events;

  @override
  String get protectedPageLeaseRecoveryIdentity =>
      'obcs2.store.${List.filled(43, 'R').join()}';

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();

  @override
  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adoptedLeaseReferences,
    CloudProtectedReferenceSnapshot liveReferences,
  ) async {
    events.add('recover');
    return CloudProtectedPageLeaseRecoveryResult(
      finalizedAdoptedLeaseReferences: const {},
      hasMore: false,
    );
  }

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async {}

  @override
  Future<void> acknowledgeCommittedPageLease(String leaseReference) async {}

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async {
    events.add('rollback:$leaseReference');
  }

  @override
  Future<int> retireProtectedReferences(Set<String> references) async => 0;

  @override
  Future<CloudProtectedGarbageCollectionResult> collectProtectedGarbage(
    CloudProtectedReferenceSnapshot liveReferences,
  ) async => const CloudProtectedGarbageCollectionResult(
    scannedCount: 0,
    firstObservedCount: 0,
    deletedCount: 0,
    preservedLiveCount: 0,
    preservedActiveLeaseCount: 0,
    hasMore: false,
  );

  @override
  Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  }) {
    events.add('reconcile');
    return super.reconcileUnknownOutcome(scope, operation: operation);
  }

  @override
  Future<CloudSyncPreparedSubmission> prepareSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required List<CloudSyncProtectedWriteOperation> operations,
  }) {
    events.add('prepare');
    return super.prepareSubmission(
      scope,
      submissionIdentity: submissionIdentity,
      operations: operations,
    );
  }
}

final class _ProtectedLeaseProviderTransport extends FakeCloudSyncTransport
    implements CloudProtectedPageLeaseTransportProvider {
  _ProtectedLeaseProviderTransport(this.protectedPageLeaseTransport);

  @override
  final CloudProtectedPageLeaseTransport protectedPageLeaseTransport;
}

class _CountingCoordinatorRenewalStore extends InMemoryCloudSyncStore {
  int renewalCalls = 0;

  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) {
    renewalCalls++;
    return super.renewCoordinatorLease(
      scope,
      leaseFence: leaseFence,
      now: now,
      leaseDuration: leaseDuration,
    );
  }
}

class _RejectingCoordinatorRenewalStore extends InMemoryCloudSyncStore {
  int renewalCalls = 0;

  @override
  Future<bool> renewCoordinatorLease(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
    required DateTime now,
    required Duration leaseDuration,
  }) {
    renewalCalls++;
    if (renewalCalls > 3) return Future.value(false);
    return super.renewCoordinatorLease(
      scope,
      leaseFence: leaseFence,
      now: now,
      leaseDuration: leaseDuration,
    );
  }
}

class _FailingSubmissionMarkerStore extends InMemoryCloudSyncStore {
  @override
  Future<List<CloudOutboxOperation>> markOutboxSubmissionStarted(
    CloudSyncScope scope, {
    required String leaseId,
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required DateTime now,
  }) {
    throw CloudSyncFailure(
      category: CloudFailureCategory.localStorage,
      safeCode: 'simulated_submission_marker_failure',
    );
  }
}

class _CrashAfterFirstJournalStore extends InMemoryCloudSyncStore {
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
      throw StateError('simulated_process_crash_after_page_one_journal');
    }
    return inserted;
  }
}
