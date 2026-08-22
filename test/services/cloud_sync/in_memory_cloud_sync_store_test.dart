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

  test(
    'journals page and token atomically while deduplicating replay',
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
      expect(await _journal(store, batch), 0);

      final checkpoint = await store.readCheckpoint(scope);
      final inbox = await store.inboxEntries(scope);
      expect(checkpoint.fetchedToken, 'opaque-token-1');
      expect(checkpoint.fetchedSequence, 2);
      expect(checkpoint.lastBatchId, 'batch-1');
      expect(inbox.map((entry) => entry.sequence), [1, 2]);
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
    'terminal checkpoint advances through applied and quarantined rows',
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
      expect((await store.readCheckpoint(scope)).lastAppliedSequence, 3);
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
      expect(entries.single.payloadSha256, 'payload-digest-1-2');
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
      await store.upsertRecordMap(original);
      await store.upsertRecordMap(
        CloudRecordMapEntry(
          scope: scope,
          logicalEntityKeyHash: 'logical-key-digest',
          serverRecordIdHash: 'server-record-hash',
          encryptedServerRecordId: 'protected:server-record',
          etagHash: 'etag-b',
          updatedAt: testEpoch.add(const Duration(minutes: 1)),
        ),
      );
      expect(
        (await store.readRecordMap(
          scope,
          logicalEntityKeyHash: 'logical-key-digest',
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
