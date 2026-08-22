import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_backoff.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_cancellation.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
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
    int maximumInboxEntriesPerRun = 512,
    int maximumOutboxBatches = 8,
    Duration fetchOperationTimeout = const Duration(seconds: 45),
    Duration writeOperationTimeout = const Duration(seconds: 45),
    int maximumDeferredAttempts = 8,
    Duration maximumDeferredAge = const Duration(days: 3),
    Duration pausedRetryDelay = const Duration(hours: 6),
    Duration coordinatorLeaseDuration = const Duration(minutes: 5),
    Duration outboxLeaseDuration = const Duration(minutes: 2),
    MemoryCloudSyncObserver? observer,
    String coordinatorId = 'coordinator-a',
    CloudShadowJournalBudget? shadowJournalBudget,
    CloudSyncWriterAuthority? writerAuthorityOverride,
  }) {
    return CloudSyncEngine(
      scope: scope,
      coordinatorId: coordinatorId,
      store: store,
      transport: transport,
      inboxApplier: applier,
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
        maximumInboxEntriesPerRun: maximumInboxEntriesPerRun,
        maximumOutboxBatchesPerRun: maximumOutboxBatches,
        fetchOperationTimeout: fetchOperationTimeout,
        writeOperationTimeout: writeOperationTimeout,
        maximumDeferredAttempts: maximumDeferredAttempts,
        maximumDeferredAge: maximumDeferredAge,
        pausedRetryDelay: pausedRetryDelay,
        coordinatorLeaseDuration: coordinatorLeaseDuration,
        outboxLeaseDuration: outboxLeaseDuration,
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

  CloudUnknownOutcomeProof proofFor(
    CloudOutboxOperation operation, {
    String? operationId,
    String? appleRequestUuid,
    String? appleOperationUuid,
  }) {
    return CloudUnknownOutcomeProof(
      operationId: operationId ?? operation.operationId,
      appleRequestUuid: appleRequestUuid ?? operation.appleRequestUuid!,
      appleOperationUuid: appleOperationUuid ?? operation.appleOperationUuid!,
      scopeStorageKey: operation.scope.storageKey,
      checkpointGeneration: operation.checkpointGeneration,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: operation.serverRecordIdHash!,
      action: operation.action,
      expectedPayloadSha256: operation.payloadSha256,
      protectedProofReference: 'obcs2.reconcile.test-proof',
      observedEtagHash: 'test-observed-etag-hash',
    );
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
    expect(writerExclusion.runCallCount, 1);
    expect(writerExclusion.observedKinds, [CloudKitOperationKind.v2ReadWrite]);
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

  test(
    'semantic inbox cap is shared across startup and post-fetch phases',
    () async {
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
      transport.enqueueFetchBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [testChange(2), testChange(3)],
          batchId: 'batch-cap-new',
          generation: 1,
          nextToken: 'cap-new-token',
          hasMore: false,
        ),
      );
      final observer = MemoryCloudSyncObserver();

      final result = await engine(
        maximumInboxEntriesPerRun: 2,
        observer: observer,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.completed);
      expect(result.counters.applied, 2);
      expect(applier.appliedSequences, [1, 2]);
      expect(transport.fetchCallCount, 1);
      final entries = await store.inboxEntries(scope);
      expect(entries.map((entry) => entry.status), [
        CloudInboxStatus.applied,
        CloudInboxStatus.applied,
        CloudInboxStatus.pending,
      ]);
      final inboxEvents = observer.events
          .where((event) => event.type == CloudSyncEventType.inboxApplied)
          .toList();
      expect(inboxEvents, hasLength(1));
      expect(inboxEvents.single.count, 2);
    },
  );

  test('semanticApply false keeps fetch-only behavior unchanged', () async {
    await seedGeneralJournal(
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
        if (call == 3) writerAuthority.allowVerify = false;
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
      expect(writerAuthority.verifyCallCount, 3);
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

  test(
    'terminal quarantine advances the floor without dropping later data',
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
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 2);
      final entries = await store.inboxEntries(scope);
      expect(entries[0].status, CloudInboxStatus.quarantined);
      expect(entries[1].status, CloudInboxStatus.applied);
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

  test(
    'deferred inbox entries quarantine only after age and attempt thresholds',
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
      expect(second.counters.quarantined, 1);
      entries = await store.inboxEntries(scope);
      expect(entries.single.status, CloudInboxStatus.quarantined);
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
    'persistent dependency failures dead-letter after attempt and age bounds',
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
      expect(second.counters.quarantined, 1);
      expect(second.counters.retried, 0);
      expect(stored.status, CloudInboxStatus.quarantined);
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
        CloudUnknownOutcomeResolution.committed(proof: proofFor(operation));

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
    final storedOperation = (await store.outboxEntries(scope)).single;
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

    nativeResolution.complete(
      CloudUnknownOutcomeResolution.committed(proof: proofFor(storedOperation)),
    );
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

  test('mismatched reconciliation proof cannot confirm or replay', () async {
    await seedAmbiguousOutbox(806);
    transport.unknownOutcomeHandler = (_, operation) async =>
        CloudUnknownOutcomeResolution.committed(
          proof: proofFor(
            operation,
            appleRequestUuid: '99999999-2222-4ABC-8DEF-555555555555',
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
    expect(transport.pushCallCount, 1);
  });

  test('mismatched operation UUID proof cannot confirm or replay', () async {
    await seedAmbiguousOutbox(807);
    transport.unknownOutcomeHandler = (_, operation) async =>
        CloudUnknownOutcomeResolution.committed(
          proof: proofFor(
            operation,
            appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-999999999999',
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
  });

  test('server-proven absence requeues and sends exactly once', () async {
    final operation = await seedAmbiguousOutbox(802);
    transport.unknownOutcomeHandler = (_, operation) async =>
        CloudUnknownOutcomeResolution.notApplied(proof: proofFor(operation));
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

    expect(result.counters.retried, 1);
    expect(result.counters.confirmed, 1);
    expect(transport.unknownOutcomeCallCount, 1);
    expect(transport.pushCallCount, 2);
    expect(
      (await store.outboxEntries(scope)).single.status,
      CloudOutboxStatus.confirmed,
    );
  });

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
    'divergent server state enters the existing semantic merge path',
    () async {
      final operation = await seedAmbiguousOutbox(804);
      transport.unknownOutcomeHandler = (_, operation) async =>
          CloudUnknownOutcomeResolution.serverRecordChanged(
            proof: proofFor(operation),
          );
      transport.conflictHandler = (_, leasedOperation) async {
        return CloudServerConflictResolution.mergedForRetry(
          encryptedPayloadReference: 'protected:ambiguous-merged',
          payloadSha256: 'ambiguous-merged-digest',
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
      expect(transport.pushCallCount, 2);
      expect(
        (await store.outboxEntries(scope)).single.status,
        CloudOutboxStatus.confirmed,
      );
    },
  );

  test('retryable conflict reconciliation stays unknown', () async {
    await seedAmbiguousOutbox(809);
    transport.unknownOutcomeHandler = (_, operation) async =>
        CloudUnknownOutcomeResolution.serverRecordChanged(
          proof: proofFor(operation),
        );
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
        CloudUnknownOutcomeResolution.serverRecordChanged(
          proof: proofFor(operation),
        );
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
    if (renewalCalls > 1) return Future.value(false);
    return super.renewCoordinatorLease(
      scope,
      leaseFence: leaseFence,
      now: now,
      leaseDuration: leaseDuration,
    );
  }
}
