import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_backoff.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

/// Lifecycle P0: same-generation auth/PCS refresh is identity-bound. A
/// mid-run account replacement across the refresh (fingerprint or session
/// drift) must consume the single refresh without retrying the fetch,
/// advancing the checkpoint, or resuming the outbox.
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
    int maximumOutboxBatches = 8,
    CloudSyncRefreshIdentityReader? refreshIdentityReader,
  }) {
    return CloudSyncEngine(
      scope: scope,
      coordinatorId: 'coordinator-refresh-identity',
      store: store,
      transport: transport,
      inboxApplier: applier,
      writerAuthority: flags.saves ? writerAuthority : null,
      writerExclusion: flags.saves ? writerExclusion : null,
      backoff: CloudSyncBackoffPolicy(
        baseDelay: const Duration(seconds: 10),
        maximumDelay: const Duration(minutes: 1),
        randomUnit: () => 1,
      ),
      observer: MemoryCloudSyncObserver(),
      clock: clock.call,
      refreshIdentityReader: refreshIdentityReader,
      config: CloudSyncEngineConfig(
        maximumBatchSize: 256,
        maximumFetchPagesPerRun: 8,
        maximumInboxEntriesPerRun: 512,
        minimumInboxEntriesReservedForFetch: 0,
        maximumOutboxBatchesPerRun: maximumOutboxBatches,
        fetchOperationTimeout: const Duration(seconds: 45),
        writeOperationTimeout: const Duration(seconds: 45),
        maximumDeferredAttempts: 8,
        maximumDeferredAge: const Duration(days: 3),
        pausedRetryDelay: const Duration(hours: 6),
        coordinatorLeaseDuration: const Duration(minutes: 5),
        outboxLeaseDuration: const Duration(minutes: 2),
        allowManualPullBackoffOverride: false,
        shadowJournalBudget: CloudShadowJournalBudget(),
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

  test(
    'pull auth refresh fingerprint mismatch never retries or advances',
    () async {
      final before = await store.readCheckpoint(scope);
      var reads = 0;
      Future<CloudSyncRefreshIdentity?> readIdentity() async {
        reads++;
        final fingerprint = reads == 1
            ? testAccountFingerprintA
            : testAccountFingerprintB;
        return CloudSyncRefreshIdentity(
          accountFingerprint: fingerprint,
          generation: 0,
          nativeAccountFingerprint: fingerprint,
        );
      }

      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            throw CloudSyncFailure(
              category: CloudFailureCategory.authorization,
              safeCode: 'test_auth_failed',
            );
          };
      transport.authenticationRefreshHandler = (_) async => true;
      transport.pcsRefreshHandler = (_) async => true;

      await engine(
        refreshIdentityReader: readIdentity,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(reads, 2);
      expect(transport.fetchCallCount, 1);
      expect(transport.authenticationRefreshCallCount, 1);
      expect(transport.pcsRefreshCallCount, 0);
      final after = await store.readCheckpoint(scope);
      expect(after.generation, before.generation);
      expect(after.fetchedToken, before.fetchedToken);
      expect(await store.outboxEntries(scope), isEmpty);
      expect(
        await store.readPausedOutboxFailureCategories(scope, now: clock.value),
        isEmpty,
      );
    },
  );

  test('pull PCS refresh session mismatch never retries or advances', () async {
    final before = await store.readCheckpoint(scope);
    var reads = 0;
    Future<CloudSyncRefreshIdentity?> readIdentity() async {
      reads++;
      return CloudSyncRefreshIdentity(
        accountFingerprint: testAccountFingerprintA,
        generation: 0,
        nativeAccountFingerprint: testAccountFingerprintA,
        nativeSessionId: reads == 1 ? 'session-a' : 'session-b',
      );
    }

    transport.fetchHandler =
        (requestedScope, previousToken, generation, limit) async {
          throw CloudSyncFailure(
            category: CloudFailureCategory.pcsUnavailable,
            safeCode:
                CloudSyncV2ProtectedTransportSafeFailureCodes.pcsUnavailable,
          );
        };
    transport.pcsRefreshHandler = (_) async => true;

    await engine(
      refreshIdentityReader: readIdentity,
    ).synchronize(trigger: CloudSyncTrigger.manual);

    expect(reads, 2);
    expect(transport.fetchCallCount, 1);
    expect(transport.pcsRefreshCallCount, 1);
    expect(transport.authenticationRefreshCallCount, 0);
    final after = await store.readCheckpoint(scope);
    expect(after.generation, before.generation);
    expect(after.fetchedToken, before.fetchedToken);
    expect(await store.outboxEntries(scope), isEmpty);
    expect(
      await store.readPausedOutboxFailureCategories(scope, now: clock.value),
      isEmpty,
    );
  });

  test('flush auth refresh mismatch leaves paused work untouched', () async {
    final checkpointBefore = await store.readCheckpoint(scope);
    final paused = testOutboxOperation(scope, 1);
    await seedPausedOutbox(
      paused,
      category: CloudFailureCategory.authorization,
    );
    var reads = 0;
    Future<CloudSyncRefreshIdentity?> readIdentity() async {
      reads++;
      final fingerprint = reads == 1
          ? testAccountFingerprintA
          : testAccountFingerprintB;
      return CloudSyncRefreshIdentity(
        accountFingerprint: fingerprint,
        generation: 0,
        nativeAccountFingerprint: fingerprint,
      );
    }

    transport.authenticationRefreshHandler = (_) async => true;

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
      refreshIdentityReader: readIdentity,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    expect(transport.authenticationRefreshCallCount, 1);
    expect(transport.pushCallCount, 0);
    final stored = (await store.outboxEntries(scope)).single;
    expect(stored.status, CloudOutboxStatus.paused);
    expect(stored.lastFailure, CloudFailureCategory.authorization);
    expect(stored.nextEligibleAt, testEpoch.add(const Duration(hours: 6)));
    final checkpointAfter = await store.readCheckpoint(scope);
    expect(checkpointAfter.generation, checkpointBefore.generation);
  });

  test('fromNative binds only redacted snapshot fields', () {
    final identity = CloudSyncRefreshIdentity.fromNative(
      accountFingerprint: testAccountFingerprintA,
      nativeSessionId: 'session-a',
      protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'C').join()}',
    );
    expect(identity.accountFingerprint, testAccountFingerprintA);
    expect(identity.nativeAccountFingerprint, testAccountFingerprintA);
    expect(identity.nativeSessionId, 'session-a');
    expect(
      identity.protectedStoreIdentity,
      'obcs2.store.${List.filled(43, 'C').join()}',
    );
  });

  test(
    'production snapshot wiring fails closed on mid-refresh replacement',
    () async {
      final before = await store.readCheckpoint(scope);
      var live = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'session-a',
        accountFingerprint: testAccountFingerprintA,
        protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'C').join()}',
        cloudMessagesClient: Object(),
      );
      // Same shape as the production refreshIdentityReader closures: map
      // the live native snapshot through fromNative on every read.
      Future<CloudSyncRefreshIdentity?> readIdentity() async {
        final current = live;
        return CloudSyncRefreshIdentity.fromNative(
          accountFingerprint: current.accountFingerprint,
          nativeSessionId: current.nativeSessionId,
          protectedStoreIdentity: current.protectedStoreIdentity,
        );
      }

      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            throw CloudSyncFailure(
              category: CloudFailureCategory.authorization,
              safeCode: 'test_auth_failed',
            );
          };
      transport.authenticationRefreshHandler = (_) async {
        live = CloudSyncNativeAuthSnapshot.fromNative(
          nativeSessionId: 'session-b',
          accountFingerprint: testAccountFingerprintB,
          protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'D').join()}',
          cloudMessagesClient: Object(),
        );
        return true;
      };

      await engine(
        refreshIdentityReader: readIdentity,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(transport.fetchCallCount, 1);
      expect(transport.authenticationRefreshCallCount, 1);
      final after = await store.readCheckpoint(scope);
      expect(after.generation, before.generation);
      expect(after.fetchedToken, before.fetchedToken);
      expect(await store.outboxEntries(scope), isEmpty);
      expect(
        await store.readPausedOutboxFailureCategories(scope, now: clock.value),
        isEmpty,
      );
    },
  );

  test(
    'configured reader returning null fails closed without refreshing',
    () async {
      final before = await store.readCheckpoint(scope);
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            throw CloudSyncFailure(
              category: CloudFailureCategory.authorization,
              safeCode: 'test_auth_failed',
            );
          };
      transport.authenticationRefreshHandler = (_) async => true;

      await engine(
        refreshIdentityReader: () async => null,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(transport.fetchCallCount, 1);
      expect(transport.authenticationRefreshCallCount, 0);
      expect(transport.pcsRefreshCallCount, 0);
      final after = await store.readCheckpoint(scope);
      expect(after.generation, before.generation);
      expect(after.fetchedToken, before.fetchedToken);
      expect(await store.outboxEntries(scope), isEmpty);
      expect(
        await store.readPausedOutboxFailureCategories(scope, now: clock.value),
        isEmpty,
      );
    },
  );

  test(
    'stable post-refresh identity authorizes exactly one fetched batch',
    () async {
      var reads = 0;
      Future<CloudSyncRefreshIdentity?> readIdentity() async {
        reads++;
        return CloudSyncRefreshIdentity(
          accountFingerprint: testAccountFingerprintA,
          generation: 0,
          nativeAccountFingerprint: testAccountFingerprintA,
          nativeSessionId: 'session-a',
          protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'C').join()}',
        );
      }

      var attempts = 0;
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            attempts++;
            if (attempts == 1) {
              throw CloudSyncFailure(
                category: CloudFailureCategory.authorization,
                safeCode: 'test_auth_failed',
              );
            }
            return CloudFetchBatch(
              scope: requestedScope,
              changes: const [],
              batchId: 'stable-terminal-after-refresh',
              generation: generation,
              nextToken: 'stable-terminal-token',
              hasMore: false,
            );
          };
      transport.authenticationRefreshHandler = (_) async => true;

      final result = await engine(
        refreshIdentityReader: readIdentity,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(reads, 3);
      expect(transport.fetchCallCount, 2);
      expect(transport.authenticationRefreshCallCount, 1);
      expect(result.failureCategory, isNull);
      expect(
        (await store.readCheckpoint(scope)).fetchedToken,
        'stable-terminal-token',
      );
    },
  );

  test('post-refresh session flip blocks paused outbox resume', () async {
    final checkpointBefore = await store.readCheckpoint(scope);
    final paused = testOutboxOperation(scope, 1);
    await seedPausedOutbox(
      paused,
      category: CloudFailureCategory.authorization,
    );
    var reads = 0;
    Future<CloudSyncRefreshIdentity?> readIdentity() async {
      reads++;
      // Refresh observes the stable identity twice; the intervening fetch
      // sees a replaced session and store under the same fingerprint.
      final flipped = reads >= 3;
      return CloudSyncRefreshIdentity(
        accountFingerprint: testAccountFingerprintA,
        generation: 0,
        nativeAccountFingerprint: testAccountFingerprintA,
        nativeSessionId: flipped ? 'session-b' : 'session-a',
        protectedStoreIdentity: flipped
            ? 'obcs2.store.${List.filled(43, 'D').join()}'
            : 'obcs2.store.${List.filled(43, 'C').join()}',
      );
    }

    var attempts = 0;
    transport.fetchHandler =
        (requestedScope, previousToken, generation, limit) async {
          attempts++;
          if (attempts == 1) {
            throw CloudSyncFailure(
              category: CloudFailureCategory.authorization,
              safeCode: 'test_auth_failed',
            );
          }
          return CloudFetchBatch(
            scope: requestedScope,
            changes: const [],
            batchId: 'terminal-after-refresh',
            generation: generation,
            nextToken: 'terminal-token',
            hasMore: false,
          );
        };
    transport.authenticationRefreshHandler = (_) async => true;

    final result = await engine(
      flags: const CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: true,
      ),
      refreshIdentityReader: readIdentity,
    ).synchronize(trigger: CloudSyncTrigger.manual);

    expect(reads, 3);
    expect(transport.fetchCallCount, 2);
    expect(transport.authenticationRefreshCallCount, 1);
    // The flipped batch is rolled back, never journaled: nothing fetched,
    // an identity failure is recorded, and the paused row is retained.
    expect(result.counters.fetched, 0);
    expect(result.failureCategory, CloudFailureCategory.authorization);
    expect(result.failureSafeCode, 'cloud_sync_native_auth_identity_mismatch');
    final stored = (await store.outboxEntries(scope)).single;
    expect(stored.status, CloudOutboxStatus.paused);
    expect(stored.lastFailure, CloudFailureCategory.authorization);
    final checkpointAfter = await store.readCheckpoint(scope);
    expect(checkpointAfter.generation, checkpointBefore.generation);
    expect(checkpointAfter.fetchedToken, checkpointBefore.fetchedToken);
    expect(checkpointAfter.lastFailure, CloudFailureCategory.authorization);
    expect(
      checkpointAfter.consecutivePullFailures,
      checkpointBefore.consecutivePullFailures + 1,
    );
  });

  test(
    'post-refresh PCS flip rolls back the batch without journaling',
    () async {
      final checkpointBefore = await store.readCheckpoint(scope);
      final paused = testOutboxOperation(scope, 1);
      await seedPausedOutbox(
        paused,
        category: CloudFailureCategory.pcsUnavailable,
      );
      var reads = 0;
      Future<CloudSyncRefreshIdentity?> readIdentity() async {
        reads++;
        final flipped = reads >= 3;
        return CloudSyncRefreshIdentity(
          accountFingerprint: testAccountFingerprintA,
          generation: 0,
          nativeAccountFingerprint: testAccountFingerprintA,
          nativeSessionId: flipped ? 'session-b' : 'session-a',
          protectedStoreIdentity: flipped
              ? 'obcs2.store.${List.filled(43, 'D').join()}'
              : 'obcs2.store.${List.filled(43, 'C').join()}',
        );
      }

      var attempts = 0;
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            attempts++;
            if (attempts == 1) {
              throw CloudSyncFailure(
                category: CloudFailureCategory.pcsUnavailable,
                safeCode: CloudSyncV2ProtectedTransportSafeFailureCodes
                    .pcsUnavailable,
              );
            }
            return CloudFetchBatch(
              scope: requestedScope,
              changes: const [],
              batchId: 'terminal-after-refresh',
              generation: generation,
              nextToken: 'terminal-token',
              hasMore: false,
            );
          };
      transport.pcsRefreshHandler = (_) async => true;

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
        refreshIdentityReader: readIdentity,
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(reads, 3);
      expect(transport.fetchCallCount, 2);
      expect(transport.pcsRefreshCallCount, 1);
      expect(transport.authenticationRefreshCallCount, 0);
      expect(result.counters.fetched, 0);
      expect(result.failureCategory, CloudFailureCategory.pcsUnavailable);
      expect(
        result.failureSafeCode,
        'cloud_sync_native_auth_identity_mismatch',
      );
      final stored = (await store.outboxEntries(scope)).single;
      expect(stored.status, CloudOutboxStatus.paused);
      expect(stored.lastFailure, CloudFailureCategory.pcsUnavailable);
      final checkpointAfter = await store.readCheckpoint(scope);
      expect(checkpointAfter.generation, checkpointBefore.generation);
      expect(checkpointAfter.fetchedToken, checkpointBefore.fetchedToken);
      expect(checkpointAfter.lastFailure, CloudFailureCategory.pcsUnavailable);
      expect(
        checkpointAfter.consecutivePullFailures,
        checkpointBefore.consecutivePullFailures + 1,
      );
    },
  );
}
