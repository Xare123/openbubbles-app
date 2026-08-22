import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late Directory directory;
  late Store objectBox;
  late _TestCloudSyncProtector protector;
  late ObjectBoxCloudSyncStore store;
  late DateTime currentTime;
  final coordinatorFences = <String, CloudCoordinatorLeaseFence>{};

  Future<void> reopen() async {
    objectBox.close();
    objectBox = await openStore(directory: directory.path);
    store = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: protector,
      clock: () => currentTime,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-v2-objectbox-',
    );
    objectBox = await openStore(directory: directory.path);
    protector = _TestCloudSyncProtector();
    currentTime = testEpoch;
    store = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: protector,
      clock: () => currentTime,
    );
    coordinatorFences.clear();
  });

  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  CloudFetchBatch batch(
    CloudSyncScope scope, {
    int generation = 1,
    String batchId = 'batch-digest-1',
    String? token = 'opaque-token-1',
    List<CloudFetchedChange>? changes,
  }) {
    return CloudFetchBatch(
      scope: scope,
      changes: changes ?? [testChange(1), testChange(2)],
      batchId: batchId,
      generation: generation,
      nextToken: token,
      hasMore: false,
    );
  }

  Future<CloudShadowJournalAdmission> journalShadow(
    CloudFetchBatch value, {
    required DateTime now,
    required CloudShadowJournalBudget budget,
  }) async {
    currentTime = now;
    final scope = value.scope;
    final fence = coordinatorFences[scope.storageKey] ??= (await store
        .tryAcquireCoordinatorLease(
          scope,
          ownerId: 'objectbox-test-${scope.accountFingerprint}',
          now: now,
          leaseDuration: const Duration(days: 1),
        ))!;
    final checkpoint = await store.readCheckpoint(scope);
    return store.journalShadowFetchedBatch(
      value,
      now: now,
      budget: budget,
      leaseFence: fence,
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
  }

  Future<int> journal(CloudFetchBatch value, {DateTime? now}) async {
    final journalNow = now ?? testEpoch;
    currentTime = journalNow;
    final scope = value.scope;
    final fence = coordinatorFences[scope.storageKey] ??= (await store
        .tryAcquireCoordinatorLease(
          scope,
          ownerId: 'objectbox-general-${scope.accountFingerprint}',
          now: journalNow,
          leaseDuration: const Duration(days: 1),
        ))!;
    final checkpoint = await store.readCheckpoint(scope);
    return store.journalFetchedBatch(
      value,
      now: journalNow,
      leaseFence: fence,
      expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken,
    );
  }

  CloudOutboxDraft draft(
    CloudSyncScope scope,
    int index, {
    CloudOutboxAction action = CloudOutboxAction.save,
    DateTime? createdAt,
    Set<String> dependencies = const {},
  }) {
    final payloadSha256 = action == CloudOutboxAction.save
        ? 'payload-digest-$index'
        : null;
    return CloudOutboxDraft(
      scope: scope,
      logicalEntityKeyHash: 'logical-key-digest-$index',
      action: action,
      payloadVersion: 1,
      dependencyOperationIds: dependencies,
      createdAt: createdAt ?? testEpoch,
      encryptedPayloadReference: action == CloudOutboxAction.save
          ? 'protected:payload-$index'
          : null,
      payloadSha256: payloadSha256,
    );
  }

  test(
    'atomically journals an ordered page and protects its token at rest',
    () async {
      final scope = testScope();
      expect(await journal(batch(scope)), 2);

      final persisted = objectBox
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .single;
      expect(persisted.fetchedTokenCiphertext, isNot('opaque-token-1'));
      expect(
        persisted.fetchedTokenCiphertext,
        isNot(contains('opaque-token-1')),
      );
      expect(persisted.checkpointKey, isNot(contains(scope.storageKey)));

      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'opaque-token-1');
      expect(checkpoint.fetchedSequence, 2);
      expect(
        (await store.readEligibleInbox(
          scope,
          now: testEpoch,
          limit: 256,
        )).map((entry) => entry.sequence),
        [1],
      );

      await reopen();
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'opaque-token-1',
      );
      expect(await journal(batch(scope)), 0);
    },
  );

  test('duplicate inbox sequence lookup fails closed', () async {
    final scope = testScope();
    await journal(batch(scope, changes: [testChange(1)]));
    final original = objectBox.box<CloudInboxChangeEntity>().getAll().single;
    objectBox.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: 'duplicate-${original.changeKey}',
        changeIdHash: testChange(2).changeId,
        scopeKey: original.scopeKey,
        accountFingerprint: original.accountFingerprint,
        zone: original.zone,
        serverRecordIdHash: testChange(2).recordIdHash,
        etagHash: original.etagHash,
        changeType: original.changeType,
        encryptedServerRecordId: original.encryptedServerRecordId,
        protectedSystemFieldsRef: original.protectedSystemFieldsRef,
        encryptedPayloadRef: original.encryptedPayloadRef,
        payloadSha256: original.payloadSha256,
        batchId: 'duplicate-sequence-batch',
        generation: original.generation,
        fetchSequence: original.fetchSequence,
        status: original.status,
        isTombstone: original.isTombstone,
        createdAtMs: original.createdAtMs,
        updatedAtMs: original.updatedAtMs,
      ),
    );

    await expectLater(
      store.markInboxApplied(
        scope,
        sequence: original.fetchSequence,
        now: testEpoch,
        leaseFence: coordinatorFences[scope.storageKey]!,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'inbox_sequence_ambiguous',
        ),
      ),
    );
  });

  test('retry fallback is monotonic and idempotent', () async {
    final scope = testScope();
    await journal(batch(scope, changes: [testChange(1)]));
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
        leaseFence: coordinatorFences[scope.storageKey]!,
      );
    }

    final row = objectBox.box<CloudInboxChangeEntity>().getAll().single;
    expect(row.retryCount, 1);
    expect(row.nextEligibleAtMs, later.millisecondsSinceEpoch);
  });

  test('generation mismatch rolls back both the page and checkpoint', () async {
    final scope = testScope();
    await journal(batch(scope));

    await expectLater(
      journal(
        batch(
          scope,
          generation: 2,
          batchId: 'wrong-generation-page',
          token: 'must-not-commit',
          changes: [testChange(3)],
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'generation_mismatch',
        ),
      ),
    );

    expect(objectBox.box<CloudInboxChangeEntity>().count(), 2);
    final checkpoint = await store.readCheckpoint(scope);
    expect(checkpoint.fetchedToken, 'opaque-token-1');
    expect(checkpoint.fetchedSequence, 2);
  });

  test(
    'pre-budget journal migration blocks safely after reopen without pruning',
    () async {
      final scope = testScope();
      await journal(
        batch(
          scope,
          batchId: 'legacy-unbounded-page',
          token: 'legacy-token',
          changes: [testChange(1), testChange(2)],
        ),
      );
      await reopen();
      protector.failProtection = true;

      final admission = await journalShadow(
        batch(
          scope,
          batchId: 'must-not-commit',
          token: 'must-not-protect',
          changes: [testChange(3)],
        ),
        now: testEpoch,
        budget: CloudShadowJournalBudget(maximumEntriesPerScope: 1),
      );

      expect(
        admission.blockReason,
        CloudShadowJournalBlockReason.maximumEntries,
      );
      expect(objectBox.box<CloudInboxChangeEntity>().count(), 2);
      protector.failProtection = false;
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, 'legacy-token');
      expect(checkpoint.fetchedSequence, 2);
    },
  );

  test(
    'checkpoint protection fault cannot partially admit a shadow page',
    () async {
      final scope = testScope();
      protector.failProtection = true;

      await expectLater(
        journalShadow(
          batch(
            scope,
            batchId: 'protection-fault-page',
            token: 'must-not-commit',
            changes: [testChange(1)],
          ),
          now: testEpoch,
          budget: CloudShadowJournalBudget(),
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'checkpoint_protect_failed',
          ),
        ),
      );

      expect(objectBox.box<CloudInboxChangeEntity>().count(), 0);
      protector.failProtection = false;
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, isNull);
      expect(checkpoint.fetchedSequence, 0);
    },
  );

  test(
    'general journal rejects a lease that expires during async protection',
    () async {
      final scope = testScope();
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'delayed-general-owner',
        now: testEpoch,
        leaseDuration: const Duration(seconds: 1),
      ))!;
      final checkpoint = await store.readCheckpoint(scope);
      protector.beforeProtect = () async {
        currentTime = testEpoch.add(const Duration(seconds: 2));
      };

      await expectLater(
        store.journalFetchedBatch(
          batch(
            scope,
            batchId: 'must-not-commit-after-delay',
            token: 'must-not-commit',
            changes: [testChange(1)],
          ),
          now: testEpoch,
          leaseFence: fence,
          expectedGeneration: checkpoint.generation,
          expectedFetchedToken: checkpoint.fetchedToken,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'coordinator_lease_fence_lost',
          ),
        ),
      );

      expect(objectBox.box<CloudInboxChangeEntity>().count(), 0);
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
    },
  );

  test(
    'general journal uses one post-protection transaction timestamp',
    () async {
      final scope = testScope();
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'transaction-clock-owner',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 1),
      ))!;
      final checkpoint = await store.readCheckpoint(scope);
      final transactionTime = testEpoch.add(const Duration(seconds: 5));
      protector.beforeProtect = () async {
        currentTime = transactionTime;
      };

      await store.journalFetchedBatch(
        batch(
          scope,
          batchId: 'transaction-clock-page',
          token: 'transaction-clock-token',
          changes: [testChange(1)],
        ),
        now: testEpoch,
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );

      final expectedMs = transactionTime.millisecondsSinceEpoch;
      final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single;
      final persistedCheckpoint = objectBox
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .single;
      expect(inbox.createdAtMs, expectedMs);
      expect(inbox.updatedAtMs, expectedMs);
      expect(persistedCheckpoint.lastAttemptAtMs, expectedMs);
      expect(persistedCheckpoint.updatedAtMs, expectedMs);
    },
  );

  test(
    'shadow journal rejects a lease that expires during async protection',
    () async {
      final scope = testScope();
      final fence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'delayed-shadow-owner',
        now: testEpoch,
        leaseDuration: const Duration(seconds: 1),
      ))!;
      final checkpoint = await store.readCheckpoint(scope);
      protector.beforeProtect = () async {
        currentTime = testEpoch.add(const Duration(seconds: 2));
      };

      await expectLater(
        store.journalShadowFetchedBatch(
          batch(
            scope,
            batchId: 'must-not-shadow-commit-after-delay',
            token: 'must-not-commit',
            changes: [testChange(1)],
          ),
          now: testEpoch,
          budget: CloudShadowJournalBudget(),
          leaseFence: fence,
          expectedGeneration: checkpoint.generation,
          expectedFetchedToken: checkpoint.fetchedToken,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'coordinator_lease_fence_lost',
          ),
        ),
      );

      expect(objectBox.box<CloudInboxChangeEntity>().count(), 0);
      expect((await store.readCheckpoint(scope)).fetchedToken, isNull);
    },
  );

  test('tombstones persist without invented etag or payload', () async {
    final scope = testScope();
    await journal(batch(scope, changes: [testChange(1, tombstone: true)]));

    final entry = (await store.readEligibleInbox(
      scope,
      now: testEpoch,
      limit: 1,
    )).single;
    expect(entry.change.isTombstone, isTrue);
    expect(entry.change.etagHash, isNull);
    expect(entry.change.encryptedPayloadReference, isNull);
    expect(entry.change.payloadSha256, isNull);
  });

  test('full scope prevents account, stream, or zone state bleed', () async {
    final messages = testScope();
    final profiles = testScope(streamKind: CloudSyncStreamKind.profiles);
    final otherAccount = testScope(account: testAccountFingerprintB);
    await journal(batch(messages));

    expect((await store.readCheckpoint(profiles)).fetchedToken, isNull);
    expect((await store.readCheckpoint(otherAccount)).fetchedToken, isNull);
    expect(
      await store.readEligibleInbox(profiles, now: testEpoch, limit: 10),
      isEmpty,
    );
  });

  test(
    'allocates monotonic revisions even when wall clock moves backward',
    () async {
      final scope = testScope();
      final first = await store.enqueueOutboxMutation(
        draft(scope, 1, createdAt: testEpoch),
      );
      final second = await store.enqueueOutboxMutation(
        draft(scope, 1, createdAt: testEpoch.subtract(const Duration(days: 1))),
      );

      expect(first.mutationRevision, 1);
      expect(second.mutationRevision, 2);
      final rows = objectBox.box<CloudOutboxOperationEntity>().getAll();
      expect(rows, hasLength(1));
      expect(rows.single.operationId, second.operationId);
      expect(rows.single.mutationRevision, 2);
      expect((await store.readCheckpoint(scope)).mutationRevisionCounter, 2);
    },
  );

  test('stale worker cannot partially transition a newer lease', () async {
    final scope = testScope();
    final first = await store.enqueueOutboxMutation(draft(scope, 1));
    final second = await store.enqueueOutboxMutation(draft(scope, 2));
    final leased = await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 2,
      leaseId: 'lease-current',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    expect(leased, hasLength(2));

    await expectLater(
      store.applyOutboxTransitions(
        scope,
        leaseId: 'lease-current',
        transitions: [
          CloudOutboxTransition.confirmed(first.operationId),
          const CloudOutboxTransition.confirmed('missing-operation'),
        ],
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'stale_outbox_lease',
        ),
      ),
    );

    final states = {
      for (final row in objectBox.box<CloudOutboxOperationEntity>().getAll())
        row.operationId: row.state,
    };
    expect(states[first.operationId], 1);
    expect(states[second.operationId], 1);
  });

  test('reports and resumes only paused outbox failure categories', () async {
    final scope = testScope();
    final operation = await store.enqueueOutboxMutation(draft(scope, 1));
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 1,
      leaseId: 'lease-paused',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    await store.applyOutboxTransitions(
      scope,
      leaseId: 'lease-paused',
      transitions: [
        CloudOutboxTransition.paused(
          operation.operationId,
          category: CloudFailureCategory.authorization,
          nextEligibleAt: testEpoch.add(const Duration(hours: 1)),
        ),
      ],
      now: testEpoch,
    );

    expect(
      await store.readPausedOutboxFailureCategories(scope, now: testEpoch),
      isEmpty,
    );
    final eligibleAt = testEpoch.add(const Duration(hours: 1));
    expect(
      await store.readPausedOutboxFailureCategories(scope, now: eligibleAt),
      {CloudFailureCategory.authorization},
    );
    final postponedUntil = eligibleAt.add(const Duration(hours: 6));
    expect(
      await store.postponeEligiblePausedOutbox(
        scope,
        categories: const {CloudFailureCategory.authorization},
        now: eligibleAt,
        nextEligibleAt: postponedUntil,
      ),
      1,
    );
    expect(
      await store.readPausedOutboxFailureCategories(scope, now: eligibleAt),
      isEmpty,
    );
    expect(
      await store.readPausedOutboxFailureCategories(scope, now: postponedUntil),
      {CloudFailureCategory.authorization},
    );
    expect(
      await store.resumePausedOutbox(
        scope,
        categories: const {CloudFailureCategory.pcsUnavailable},
        now: postponedUntil,
      ),
      0,
    );
    expect(
      await store.readPausedOutboxFailureCategories(scope, now: postponedUntil),
      {CloudFailureCategory.authorization},
    );
    expect(
      await store.resumePausedOutbox(
        scope,
        categories: const {CloudFailureCategory.authorization},
        now: postponedUntil,
      ),
      1,
    );
    expect(
      await store.readPausedOutboxFailureCategories(scope, now: postponedUntil),
      isEmpty,
    );
  });

  test(
    'newer delete waits behind a leased save and the batch keeps scanning',
    () async {
      final scope = testScope();
      final saveA = await store.enqueueOutboxMutation(draft(scope, 1));
      final deleteA = await store.enqueueOutboxMutation(
        draft(
          scope,
          1,
          action: CloudOutboxAction.delete,
          createdAt: testEpoch.add(const Duration(microseconds: 1)),
        ),
      );
      final saveB = await store.enqueueOutboxMutation(
        draft(
          scope,
          2,
          createdAt: testEpoch.add(const Duration(microseconds: 2)),
        ),
      );

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

  test(
    'expired outbox lease can recover but old owner cannot confirm',
    () async {
      final scope = testScope();
      final operation = await store.enqueueOutboxMutation(draft(scope, 1));
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: 'lease-old',
        leaseDuration: const Duration(seconds: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      final recovered = await store.recoverExpiredOutboxLeases(
        scope,
        now: testEpoch.add(const Duration(seconds: 2)),
      );
      expect(recovered, 1);
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch.add(const Duration(seconds: 2)),
        limit: 1,
        leaseId: 'lease-new',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );

      await expectLater(
        store.applyOutboxTransitions(
          scope,
          leaseId: 'lease-old',
          transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
          now: testEpoch,
        ),
        throwsA(isA<CloudSyncFailure>()),
      );
      await store.applyOutboxTransitions(
        scope,
        leaseId: 'lease-new',
        transitions: [CloudOutboxTransition.confirmed(operation.operationId)],
        now: testEpoch,
      );
      expect(
        objectBox.box<CloudOutboxOperationEntity>().getAll().single.state,
        2,
      );
    },
  );

  test('coordinator lease renews across adapter instances', () async {
    final scope = testScope();
    final secondAdapter = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: protector,
      clock: () => currentTime,
    );
    final firstFence = await store.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'owner-a',
      now: testEpoch,
      leaseDuration: const Duration(minutes: 1),
    );
    expect(firstFence, isNotNull);
    expect(
      await secondAdapter.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'owner-b',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 1),
      ),
      isNull,
    );
    expect(
      await store.renewCoordinatorLease(
        scope,
        leaseFence: firstFence!,
        now: testEpoch.add(const Duration(seconds: 30)),
        leaseDuration: const Duration(minutes: 1),
      ),
      isTrue,
    );
    expect(
      await secondAdapter.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'owner-b',
        now: testEpoch.add(const Duration(seconds: 61)),
        leaseDuration: const Duration(minutes: 1),
      ),
      isNull,
    );
    expect(
      await store.renewCoordinatorLease(
        scope,
        leaseFence: CloudCoordinatorLeaseFence(
          ownerId: 'wrong-owner',
          generation: firstFence.generation,
        ),
        now: testEpoch.add(const Duration(seconds: 40)),
        leaseDuration: const Duration(minutes: 1),
      ),
      isFalse,
    );
    await store.releaseCoordinatorLease(scope, leaseFence: firstFence);
    expect(
      await secondAdapter.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'owner-b',
        now: testEpoch.add(const Duration(seconds: 41)),
        leaseDuration: const Duration(minutes: 1),
      ),
      isNotNull,
    );
  });

  test(
    'same-owner lease ABA cannot renew or release a newer generation',
    () async {
      final scope = testScope();
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
      expect(currentFence.generation, greaterThan(staleFence.generation));

      expect(
        await store.renewCoordinatorLease(
          scope,
          leaseFence: staleFence,
          now: testEpoch.add(const Duration(seconds: 1)),
          leaseDuration: const Duration(minutes: 1),
        ),
        isFalse,
      );
      await store.releaseCoordinatorLease(scope, leaseFence: staleFence);
      expect(
        await store.renewCoordinatorLease(
          scope,
          leaseFence: currentFence,
          now: testEpoch.add(const Duration(seconds: 1)),
          leaseDuration: const Duration(minutes: 1),
        ),
        isTrue,
      );
    },
  );

  test(
    'takeover survives reopen and stale fallback cannot overwrite terminal inbox',
    () async {
      final scope = testScope();
      final firstFence = (await store.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'same-worker-name',
        now: testEpoch,
        leaseDuration: const Duration(seconds: 1),
      ))!;
      final checkpoint = await store.readCheckpoint(scope);
      await store.journalFetchedBatch(
        batch(
          scope,
          batchId: 'takeover-page',
          token: 'takeover-token',
          changes: [testChange(1)],
        ),
        now: testEpoch,
        leaseFence: firstFence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );

      currentTime = testEpoch.add(const Duration(seconds: 2));
      final secondAdapter = ObjectBoxCloudSyncStore(
        store: objectBox,
        protector: protector,
        clock: () => currentTime,
      );
      final currentFence = (await secondAdapter.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'same-worker-name',
        now: currentTime,
        leaseDuration: const Duration(minutes: 1),
      ))!;
      expect(currentFence.generation, greaterThan(firstFence.generation));
      await reopen();

      await expectLater(
        store.markInboxApplied(
          scope,
          sequence: 1,
          now: currentTime,
          leaseFence: firstFence,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'coordinator_lease_fence_lost',
          ),
        ),
      );
      await store.quarantineInbox(
        scope,
        sequence: 1,
        category: CloudFailureCategory.malformedRecord,
        now: currentTime,
        leaseFence: currentFence,
      );
      await store.quarantineInbox(
        scope,
        sequence: 1,
        category: CloudFailureCategory.malformedRecord,
        now: currentTime,
        leaseFence: currentFence,
      );
      await expectLater(
        store.markInboxApplied(
          scope,
          sequence: 1,
          now: currentTime,
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

      final row = objectBox.box<CloudInboxChangeEntity>().getAll().single;
      expect(row.status, CloudInboxStatus.quarantined.index);
      expect(row.retryCount, 1);
    },
  );

  test('stale coordinator cannot regress token after lease takeover', () async {
    final scope = testScope();
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
      batch(
        scope,
        batchId: 'second-owner-page',
        token: 'token-newer',
        changes: [testChange(2)],
      ),
      now: testEpoch.add(const Duration(seconds: 61)),
      budget: CloudShadowJournalBudget(),
      leaseFence: secondFence,
      expectedGeneration: initial.generation,
      expectedFetchedToken: initial.fetchedToken,
    );

    await expectLater(
      store.journalShadowFetchedBatch(
        batch(
          scope,
          batchId: 'stale-first-owner-page',
          token: 'token-stale',
          changes: [testChange(1)],
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
    expect(objectBox.box<CloudInboxChangeEntity>().count(), 1);
  });

  test('server record mapping is single-assignment', () async {
    final scope = testScope();
    final original = CloudRecordMapEntry(
      scope: scope,
      logicalEntityKeyHash: 'logical-key-digest',
      serverRecordIdHash: 'server-record-hash-a',
      encryptedServerRecordId: 'protected:server-record-a',
      etagHash: 'etag-a',
      encryptedRawRecordReference: 'protected:raw-a',
      updatedAt: testEpoch,
    );
    await store.upsertRecordMap(original);
    await store.upsertRecordMap(
      CloudRecordMapEntry(
        scope: scope,
        logicalEntityKeyHash: original.logicalEntityKeyHash,
        serverRecordIdHash: original.serverRecordIdHash,
        encryptedServerRecordId: 'protected:replacement-is-ignored',
        etagHash: 'etag-b',
        encryptedRawRecordReference: 'protected:raw-b',
        updatedAt: testEpoch.add(const Duration(seconds: 1)),
      ),
    );
    final updated = await store.readRecordMap(
      scope,
      logicalEntityKeyHash: original.logicalEntityKeyHash,
    );
    expect(updated!.encryptedServerRecordId, 'protected:server-record-a');
    expect(updated.etagHash, 'etag-b');

    await expectLater(
      store.upsertRecordMap(
        CloudRecordMapEntry(
          scope: scope,
          logicalEntityKeyHash: original.logicalEntityKeyHash,
          serverRecordIdHash: 'server-record-hash-b',
          encryptedServerRecordId: 'protected:server-record-b',
          updatedAt: testEpoch,
        ),
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'server_mapping_changed',
        ),
      ),
    );
  });

  test(
    'live protected-reference scan preserves applied inbox rows and checkpoint',
    () async {
      final scope = testScope();
      final serverReference = _nativeReference('S');
      final systemFieldsReference = _nativeReference('F');
      final payloadReference = _nativeReference('P');
      final checkpointReference = _nativeReference('C');
      final change = CloudFetchedChange(
        changeId: 'applied-live-change',
        recordIdHash: 'applied-live-record',
        type: CloudChangeType.save,
        encryptedServerRecordId: serverReference,
        protectedSystemFieldsReference: systemFieldsReference,
        encryptedPayloadReference: payloadReference,
        payloadSha256: 'applied-live-payload',
      );
      await journal(
        batch(scope, token: checkpointReference, changes: [change]),
      );
      await store.markInboxApplied(
        scope,
        sequence: 1,
        now: testEpoch,
        leaseFence: coordinatorFences[scope.storageKey]!,
      );

      final snapshot = await store.readLiveProtectedReferences(
        maximumCount: 16,
      );

      expect(snapshot.isComplete, isTrue);
      expect(snapshot.references, {
        serverReference,
        systemFieldsReference,
        payloadReference,
        checkpointReference,
      });
      expect(
        objectBox.box<CloudInboxChangeEntity>().getAll().single.status,
        1,
        reason:
            'applied terminal rows remain protected-reference roots until a '
            'separately reviewed compaction policy exists',
      );
    },
  );

  test(
    'live protected-reference scan crosses the 1024-row page boundary',
    () async {
      final scope = testScope();
      final references = List.generate(
        1025,
        (index) => _nativeReferenceForIndex(index),
      );
      final changes = List.generate(
        references.length,
        (index) => CloudFetchedChange(
          changeId: 'paged-live-change-$index',
          recordIdHash: 'paged-live-record-$index',
          type: CloudChangeType.save,
          encryptedPayloadReference: references[index],
          payloadSha256: 'paged-live-payload-$index',
        ),
      );

      expect(
        await journal(batch(scope, token: null, changes: changes)),
        references.length,
      );
      final bounded = await store.readLiveProtectedReferences(
        maximumCount: 100,
      );
      expect(bounded.isComplete, isFalse);
      expect(bounded.references, isEmpty);

      final snapshot = await store.readLiveProtectedReferences(
        maximumCount: 4096,
      );

      expect(snapshot.isComplete, isTrue);
      expect(snapshot.references, references.toSet());
    },
  );
}

String _nativeReference(String character) =>
    'obcs2.ref.${List.filled(43, character).join()}';

String _nativeReferenceForIndex(int index) {
  final token = base64Url
      .encode(sha256.convert(utf8.encode('protected-reference-$index')).bytes)
      .replaceAll('=', '');
  return 'obcs2.ref.$token';
}

class _TestCloudSyncProtector implements CloudSyncProtector {
  bool failProtection = false;
  Future<void> Function()? beforeProtect;

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async {
    return sha256
        .convert(utf8.encode('test-hmac\u001f$rawAccountIdentifier'))
        .toString();
  }

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async {
    await beforeProtect?.call();
    if (failProtection) throw StateError('injected protection failure');
    final bound = '${scope.storageKey}\u001f${kind.name}\u001f$plaintext';
    return 'test-v1:${base64UrlEncode(utf8.encode(bound))}';
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    if (!ciphertext.startsWith('test-v1:')) throw const FormatException();
    final decoded = utf8.decode(
      base64Url.decode(ciphertext.substring('test-v1:'.length)),
    );
    final prefix = '${scope.storageKey}\u001f${kind.name}\u001f';
    if (!decoded.startsWith(prefix)) throw const FormatException();
    return decoded.substring(prefix.length);
  }
}
