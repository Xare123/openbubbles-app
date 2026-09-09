import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_backoff.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

/// Lifecycle P0: a reset-required zone needs rebootstrap, never credential
/// or PCS refresh. These tests prove reset-required failures never trigger
/// auth/PCS refresh, never advance the checkpoint, and never resume the
/// outbox, while a genuine PCS outage keeps its refresh path.
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
  }) {
    return CloudSyncEngine(
      scope: scope,
      coordinatorId: 'coordinator-reset-guard',
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

  test('reset-required safe code helper matches every reset spelling', () {
    expect(
      cloudSyncIsResetRequiredSafeCode(
        CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitResetRequired,
      ),
      isTrue,
    );
    expect(cloudSyncIsResetRequiredSafeCode('cloudkit_reset_required'), isTrue);
    expect(
      cloudSyncIsResetRequiredSafeCode(
        CloudSyncResetRequiredSafeCodes.rawTransport,
      ),
      isTrue,
    );
    expect(
      cloudSyncIsResetRequiredSafeCode(
        CloudSyncResetRequiredSafeCodes.rawChangeTokenExpired,
      ),
      isTrue,
    );
    expect(
      cloudSyncIsResetRequiredSafeCode(
        CloudSyncV2ProtectedTransportSafeFailureCodes.pcsUnavailable,
      ),
      isFalse,
    );
    expect(cloudSyncIsResetRequiredSafeCode(null), isFalse);
    expect(
      cloudSyncIsResetRequiredSafeCode(
        'cloud_sync_outbound_create_preflight_unresolved',
      ),
      isFalse,
    );
  });

  test(
    'reset-required pull failure never refreshes, advances, or resumes',
    () async {
      final before = await store.readCheckpoint(scope);
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            throw CloudSyncFailure(
              category: CloudFailureCategory.pcsUnavailable,
              safeCode: CloudSyncV2ProtectedTransportSafeFailureCodes
                  .cloudKitResetRequired,
            );
          };
      transport.authenticationRefreshHandler = (_) async => true;
      transport.pcsRefreshHandler = (_) async => true;

      await engine().synchronize(trigger: CloudSyncTrigger.manual);

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
    'raw reset-required pull failure never refreshes even as authorization',
    () async {
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async {
            throw CloudSyncFailure(
              category: CloudFailureCategory.authorization,
              safeCode: CloudSyncResetRequiredSafeCodes.rawChangeTokenExpired,
            );
          };
      transport.authenticationRefreshHandler = (_) async => true;
      transport.pcsRefreshHandler = (_) async => true;

      await engine().synchronize(trigger: CloudSyncTrigger.manual);

      expect(transport.fetchCallCount, 1);
      expect(transport.authenticationRefreshCallCount, 0);
      expect(transport.pcsRefreshCallCount, 0);
      expect(await store.outboxEntries(scope), isEmpty);
    },
  );

  test(
    'reset-required semantic decode fails the run without quarantine',
    () async {
      transport.fetchHandler =
          (requestedScope, previousToken, generation, limit) async =>
              CloudFetchBatch(
                scope: requestedScope,
                changes: [testChange(1)],
                batchId: 'reset-required-semantic-page',
                generation: generation,
                nextToken: 'must-not-commit-reset-required-token',
                hasMore: false,
              );
      applier.resultsBySequence[1] = const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.unknown,
        safeCode:
            CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitResetRequired,
      );

      final result = await engine(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: true,
        ),
      ).synchronize(trigger: CloudSyncTrigger.manual);

      expect(result.status, CloudSyncRunStatus.failed);
      expect(result.failureCategory, CloudFailureCategory.unknown);
      expect(
        result.failureSafeCode,
        CloudSyncV2ProtectedTransportSafeFailureCodes.cloudKitResetRequired,
      );
      final checkpoint = await store.readCheckpoint(scope);
      expect(checkpoint.fetchedToken, isNull);
      expect(checkpoint.lastAppliedSequence, 0);
      expect(checkpoint.pendingBatchId, 'reset-required-semantic-page');
      expect(
        (await store.inboxEntries(scope)).single.status,
        CloudInboxStatus.pending,
      );
    },
  );

  test('reset-required prepare failure fences paused without retry', () async {
    final operation = testOutboxOperation(scope, 1);
    await store.enqueueOutbox(operation);
    transport.writePreflightHandler =
        (requestedScope, submissionIdentity, operations) async {
          throw CloudSyncFailure(
            category: CloudFailureCategory.unknown,
            safeCode: CloudSyncV2ProtectedTransportSafeFailureCodes
                .cloudKitResetRequired,
          );
        };
    transport.authenticationRefreshHandler = (_) async => true;
    transport.pcsRefreshHandler = (_) async => true;

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final stored = (await store.outboxEntries(scope)).single;
    // Durably fenced: paused under a non-refreshable category with no
    // next-eligible time, so it can neither retry nor auto-resume.
    expect(stored.status, CloudOutboxStatus.paused);
    expect(stored.lastFailure, CloudFailureCategory.unknown);
    expect(stored.nextEligibleAt, isNull);
    expect(transport.prepareSubmissionCallCount, 1);
    expect(transport.authenticationRefreshCallCount, 0);
    expect(transport.pcsRefreshCallCount, 0);
    expect(
      await store.readPausedOutboxFailureCategories(scope, now: clock.value),
      const {CloudFailureCategory.unknown},
    );

    await engine(
      flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
      maximumOutboxBatches: 1,
    ).synchronize(trigger: CloudSyncTrigger.localOutbox);

    final preserved = (await store.outboxEntries(scope)).single;
    expect(preserved.status, CloudOutboxStatus.paused);
    expect(preserved.lastFailure, CloudFailureCategory.unknown);
    expect(preserved.nextEligibleAt, isNull);
    expect(transport.prepareSubmissionCallCount, 1);
    expect(transport.authenticationRefreshCallCount, 0);
    expect(transport.pcsRefreshCallCount, 0);
  });

  test('genuine PCS pull failure still refreshes once', () async {
    var attempts = 0;
    transport.fetchHandler =
        (requestedScope, previousToken, generation, limit) async {
          attempts++;
          if (attempts == 1) {
            throw CloudSyncFailure(
              category: CloudFailureCategory.pcsUnavailable,
              safeCode:
                  CloudSyncV2ProtectedTransportSafeFailureCodes.pcsUnavailable,
            );
          }
          return CloudFetchBatch(
            scope: requestedScope,
            changes: const [],
            batchId: 'terminal-after-refresh',
            generation: generation,
            nextToken: 'terminal-empty-token',
            hasMore: false,
          );
        };
    transport.pcsRefreshHandler = (_) async => true;

    await engine().synchronize(trigger: CloudSyncTrigger.manual);

    expect(transport.pcsRefreshCallCount, 1);
    expect(transport.fetchCallCount, 2);
  });
}
