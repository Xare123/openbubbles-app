import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_backoff.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_cancellation.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late CloudSyncScope scope;
  late InMemoryCloudSyncStore store;
  late FakeCloudSyncTransport transport;
  late FakeCloudInboxApplier applier;
  late MutableTestClock clock;

  CloudSyncEngine engine({
    CloudSyncFeatureFlags flags = const CloudSyncFeatureFlags(
      readOnlyFetch: true,
      semanticApply: true,
      saves: true,
    ),
    int batchSize = 256,
    int maximumOutboxBatches = 8,
    Duration fetchOperationTimeout = const Duration(seconds: 45),
    MemoryCloudSyncObserver? observer,
    String coordinatorId = 'coordinator-a',
    CloudShadowJournalBudget? shadowJournalBudget,
  }) {
    return CloudSyncEngine(
      scope: scope,
      coordinatorId: coordinatorId,
      store: store,
      transport: transport,
      inboxApplier: applier,
      backoff: CloudSyncBackoffPolicy(
        baseDelay: const Duration(seconds: 10),
        maximumDelay: const Duration(minutes: 1),
        randomUnit: () => 1,
      ),
      observer: observer ?? MemoryCloudSyncObserver(),
      clock: clock.call,
      config: CloudSyncEngineConfig(
        maximumBatchSize: batchSize,
        maximumOutboxBatchesPerRun: maximumOutboxBatches,
        fetchOperationTimeout: fetchOperationTimeout,
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

    expect(result.status, CloudSyncRunStatus.completed);
    expect(result.counters.fetched, 2);
    expect(result.counters.applied, 2);
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

  test(
    'quarantine blocks contiguous checkpoint without dropping later data',
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

      expect(result.counters.quarantined, 1);
      expect(result.counters.applied, 1);
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 0);
      final entries = await store.inboxEntries(scope);
      expect(entries[0].status, CloudInboxStatus.quarantined);
      expect(entries[1].status, CloudInboxStatus.applied);
    },
  );

  test(
    'preflight failure quarantines raw record without invoking decoder',
    () async {
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [
            testChange(
              1,
              preflightFailure: CloudFailureCategory.malformedRecord,
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

      expect(result.counters.quarantined, 1);
      expect(applier.appliedSequences, isEmpty);
      final entries = await store.inboxEntries(scope);
      expect(entries.single.status, CloudInboxStatus.quarantined);
      expect(entries.single.lastFailure, CloudFailureCategory.malformedRecord);
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
    'cancellation after fetch still journals token and payload reference',
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
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'opaque-token-after-cancel',
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
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'preserved-token',
      );
      expect(await store.inboxEntries(scope), hasLength(1));
    },
  );

  test('only explicit upload success confirms an outbox operation', () async {
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

    expect(result.counters.confirmed, 1);
    expect(result.counters.retried, 1);
    final outbox = await store.outboxEntries(scope);
    expect(
      outbox
          .singleWhere((item) => item.operationId == confirmed.operationId)
          .status,
      CloudOutboxStatus.confirmed,
    );
    final retry = outbox.singleWhere(
      (item) => item.operationId == omitted.operationId,
    );
    expect(retry.status, CloudOutboxStatus.pending);
    expect(retry.attemptCount, 1);
  });

  test(
    'refreshes authorization once and retries only unauthorized records',
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

      final result = await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      expect(result.counters.confirmed, 1);
      expect(transport.authenticationRefreshCallCount, 1);
      expect(transport.pushCallCount, 2);
    },
  );

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
    'authorization refresh runs once then leaves the operation paused',
    () async {
      final operation = testOutboxOperation(scope, 1);
      await store.enqueueOutbox(operation);
      for (var attempt = 0; attempt < 2; attempt++) {
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
      }
      transport.authenticationRefreshHandler = (_) async => true;

      await engine(
        flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      ).synchronize(trigger: CloudSyncTrigger.localOutbox);

      final stored = (await store.outboxEntries(scope)).single;
      expect(transport.authenticationRefreshCallCount, 1);
      expect(transport.pushCallCount, 2);
      expect(stored.status, CloudOutboxStatus.paused);
      expect(stored.lastFailure, CloudFailureCategory.authorization);
    },
  );

  test('PCS refresh runs once then leaves the operation paused', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    for (var attempt = 0; attempt < 2; attempt++) {
      transport.enqueuePushResult(
        CloudPushBatchResult(
          outcomes: [
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.pcsUnavailable,
              failureCategory: CloudFailureCategory.pcsUnavailable,
            ),
          ],
        ),
      );
    }
    transport.pcsRefreshHandler = (_) async => true;

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    expect(transport.pcsRefreshCallCount, 1);
    expect(transport.pushCallCount, 2);
    expect(stored.status, CloudOutboxStatus.paused);
    expect(stored.lastFailure, CloudFailureCategory.pcsUnavailable);
  });

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
        encryptedPayloadReference: 'protected:merged-payload',
        payloadSha256: 'merged-payload-digest',
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
    expect(stored.payloadSha256, 'merged-payload-digest');
    expect(
      (await store.readRecordMap(
        scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
      ))!.encryptedRawRecordReference,
      'protected:merged-raw-record',
    );
  });

  test(
    'unknown upload failures retry a bounded number then quarantine',
    () async {
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
        CloudOutboxStatus.pending,
      );
      clock.advance(const Duration(seconds: 10));
      await syncEngine.synchronize(trigger: CloudSyncTrigger.localOutbox);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.pending,
      );
      clock.advance(const Duration(seconds: 20));
      await syncEngine.synchronize(trigger: CloudSyncTrigger.localOutbox);

      final stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.quarantined);
      expect(stored.attemptCount, 3);
      expect(transport.recordMappingCallCount, 1);
    },
  );

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
