import 'dart:async';
import 'dart:math';

import 'cloud_shadow_journal_budget.dart';
import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_backoff.dart';
import 'cloud_sync_cancellation.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';

typedef CloudSyncClock = DateTime Function();

class CloudSyncFeatureFlags {
  const CloudSyncFeatureFlags({
    this.readOnlyFetch = true,
    this.semanticApply = false,
    this.saves = false,
    this.deletions = false,
    this.profiles = false,
    this.notificationHints = false,
  });

  final bool readOnlyFetch;
  final bool semanticApply;
  final bool saves;
  final bool deletions;
  final bool profiles;
  final bool notificationHints;
}

class CloudSyncEngineConfig {
  static const int maximumAllowedFetchPagesPerRun = 64;
  static const int maximumAllowedInboxEntriesPerRun = 4096;
  static const int maximumAllowedOutboxBatchesPerRun = 64;
  static const int maximumAllowedUnknownAttempts = 16;
  static const int maximumAllowedDeferredAttempts = 64;
  static const Duration maximumAllowedFetchOperationTimeout = Duration(
    minutes: 5,
  );
  static const Duration maximumAllowedCoordinatorLeaseDuration = Duration(
    minutes: 30,
  );
  static const Duration maximumAllowedOutboxLeaseDuration = Duration(
    minutes: 30,
  );
  static const Duration maximumAllowedPausedRetryDelay = Duration(days: 30);
  static const Duration maximumAllowedDeferredAge = Duration(days: 30);

  CloudSyncEngineConfig({
    this.maximumBatchSize = 256,
    this.maximumFetchPagesPerRun = 8,
    this.maximumInboxEntriesPerRun = 512,
    this.maximumOutboxBatchesPerRun = 8,
    this.fetchOperationTimeout = const Duration(seconds: 45),
    this.coordinatorLeaseDuration = const Duration(minutes: 5),
    this.outboxLeaseDuration = const Duration(minutes: 2),
    this.pausedRetryDelay = const Duration(hours: 6),
    this.maximumDeferredAttempts = 8,
    this.maximumDeferredAge = const Duration(days: 3),
    this.maximumUnknownAttempts = 3,
    CloudShadowJournalBudget? shadowJournalBudget,
    this.flags = const CloudSyncFeatureFlags(),
  }) : shadowJournalBudget = shadowJournalBudget ?? CloudShadowJournalBudget() {
    validate();
  }

  final int maximumBatchSize;
  final int maximumFetchPagesPerRun;
  final int maximumInboxEntriesPerRun;
  final int maximumOutboxBatchesPerRun;
  final Duration fetchOperationTimeout;
  final Duration coordinatorLeaseDuration;
  final Duration outboxLeaseDuration;
  final Duration pausedRetryDelay;
  final int maximumDeferredAttempts;
  final Duration maximumDeferredAge;
  final int maximumUnknownAttempts;
  final CloudShadowJournalBudget shadowJournalBudget;
  final CloudSyncFeatureFlags flags;

  void validate() {
    if (maximumBatchSize <= 0 || maximumBatchSize > 256) {
      throw ArgumentError('cloud_sync_config_batch_size_invalid');
    }
    if (maximumFetchPagesPerRun <= 0 ||
        maximumFetchPagesPerRun > maximumAllowedFetchPagesPerRun) {
      throw ArgumentError('cloud_sync_config_fetch_pages_invalid');
    }
    if (maximumInboxEntriesPerRun <= 0 ||
        maximumInboxEntriesPerRun > maximumAllowedInboxEntriesPerRun) {
      throw ArgumentError('cloud_sync_config_inbox_entries_invalid');
    }
    if (maximumOutboxBatchesPerRun <= 0 ||
        maximumOutboxBatchesPerRun > maximumAllowedOutboxBatchesPerRun) {
      throw ArgumentError('cloud_sync_config_outbox_batches_invalid');
    }
    if (maximumUnknownAttempts <= 0 ||
        maximumUnknownAttempts > maximumAllowedUnknownAttempts) {
      throw ArgumentError('cloud_sync_config_unknown_attempts_invalid');
    }
    if (maximumDeferredAttempts <= 0 ||
        maximumDeferredAttempts > maximumAllowedDeferredAttempts) {
      throw ArgumentError('cloud_sync_config_deferred_attempts_invalid');
    }
    if (fetchOperationTimeout.inMicroseconds <= 0 ||
        fetchOperationTimeout > maximumAllowedFetchOperationTimeout) {
      throw ArgumentError('cloud_sync_config_fetch_timeout_invalid');
    }
    if (coordinatorLeaseDuration.inMicroseconds <= 0 ||
        coordinatorLeaseDuration > maximumAllowedCoordinatorLeaseDuration) {
      throw ArgumentError('cloud_sync_config_coordinator_lease_invalid');
    }
    if (outboxLeaseDuration.inMicroseconds <= 0 ||
        outboxLeaseDuration > maximumAllowedOutboxLeaseDuration) {
      throw ArgumentError('cloud_sync_config_outbox_lease_invalid');
    }
    if (pausedRetryDelay.inMicroseconds <= 0 ||
        pausedRetryDelay > maximumAllowedPausedRetryDelay) {
      throw ArgumentError('cloud_sync_config_paused_retry_invalid');
    }
    if (maximumDeferredAge.inMicroseconds <= 0 ||
        maximumDeferredAge > maximumAllowedDeferredAge) {
      throw ArgumentError('cloud_sync_config_deferred_age_invalid');
    }
    shadowJournalBudget.validate();
  }
}

enum CloudSyncRunStatus { completed, degraded, skipped, cancelled, failed }

class CloudSyncRunResult {
  const CloudSyncRunResult({
    required this.status,
    required this.counters,
    required this.startedAt,
    required this.finishedAt,
    this.skipReason,
    this.failureCategory,
    this.shadowJournalBlockReason,
  });

  final CloudSyncRunStatus status;
  final CloudSyncRunCounters counters;
  final DateTime startedAt;
  final DateTime finishedAt;
  final CloudSyncSkipReason? skipReason;
  final CloudFailureCategory? failureCategory;
  final CloudShadowJournalBlockReason? shadowJournalBlockReason;
}

CloudProtectedPageLeaseTransport? _protectedLeaseTransportFor(
  CloudSyncTransport transport,
) {
  if (transport case CloudProtectedPageLeaseTransport protected) {
    return protected;
  }
  if (transport case CloudProtectedPageLeaseTransportProvider provider) {
    return provider.protectedPageLeaseTransport;
  }
  return null;
}

/// Platform-neutral Cloud Sync V2 coordinator.
///
/// One instance is scoped to one account/container/database/zone. Platform
/// differences are confined to [CloudSyncTransport] and [CloudSyncStore].
class CloudSyncEngine {
  CloudSyncEngine({
    required this.scope,
    required this.coordinatorId,
    this.architectureName = 'generic',
    required CloudSyncStore store,
    required CloudSyncTransport transport,
    required this._inboxApplier,
    CloudSyncBackoffPolicy? backoff,
    this._observer = const NoopCloudSyncObserver(),
    CloudSyncClock? clock,
    CloudSyncEngineConfig? config,
  }) : config = config ?? CloudSyncEngineConfig(),
       _store = store,
       _transport = transport,
       _protectedPageLeaseLifecycle =
           store is CloudProtectedPageLeaseAdoptionStore &&
               _protectedLeaseTransportFor(transport) != null
           ? CloudProtectedPageLeaseLifecycle(
               store: store as CloudProtectedPageLeaseAdoptionStore,
               transport: _protectedLeaseTransportFor(transport)!,
             )
           : null,
       _backoff = backoff ?? CloudSyncBackoffPolicy(),
       _clock = clock ?? DateTime.now {
    if (coordinatorId.isEmpty) {
      throw ArgumentError('cloud_sync_coordinator_id_invalid');
    }
    this.config.validate();
  }

  final CloudSyncScope scope;
  final String coordinatorId;
  final String architectureName;
  final CloudSyncStore _store;
  final CloudSyncTransport _transport;
  final CloudProtectedPageLeaseLifecycle? _protectedPageLeaseLifecycle;
  final CloudInboxApplier _inboxApplier;
  final CloudSyncBackoffPolicy _backoff;
  final CloudSyncObserver _observer;
  final CloudSyncClock _clock;
  final CloudSyncEngineConfig config;

  bool _runActive = false;
  int _runSerial = 0;
  DateTime? _lastCoordinatorLeaseRenewal;
  CloudCoordinatorLeaseFence? _activeLeaseFence;

  Future<CloudSyncRunResult> synchronize({
    required CloudSyncTrigger trigger,
    CloudSyncCancellationToken? cancellationToken,
  }) async {
    final startedAt = _clock();
    if (scope.streamKind == CloudSyncStreamKind.profiles &&
        !config.flags.profiles) {
      _emit(
        CloudSyncEventType.runSkipped,
        at: startedAt,
        trigger: trigger,
        skipReason: CloudSyncSkipReason.featureDisabled,
      );
      return _finishRun(
        runId: 'profile-disabled-${startedAt.microsecondsSinceEpoch}',
        trigger: trigger,
        status: CloudSyncRunStatus.skipped,
        counters: const CloudSyncRunCounters(),
        startedAt: startedAt,
        finishedAt: startedAt,
        skipReason: CloudSyncSkipReason.featureDisabled,
      );
    }
    if (_runActive) {
      _emit(
        CloudSyncEventType.runSkipped,
        at: startedAt,
        trigger: trigger,
        skipReason: CloudSyncSkipReason.localRunActive,
      );
      return _finishRun(
        runId: 'overlap-${startedAt.microsecondsSinceEpoch}',
        trigger: trigger,
        status: CloudSyncRunStatus.skipped,
        counters: const CloudSyncRunCounters(),
        startedAt: startedAt,
        finishedAt: startedAt,
        skipReason: CloudSyncSkipReason.localRunActive,
      );
    }

    _runActive = true;
    final runNumber = ++_runSerial;
    CloudCoordinatorLeaseFence? leaseFence;
    var counters = const CloudSyncRunCounters();
    _emit(CloudSyncEventType.runStarted, at: startedAt, trigger: trigger);

    try {
      final leaseOwnerId = _newLeaseOwnerId(runNumber);
      leaseFence = await _store.tryAcquireCoordinatorLease(
        scope,
        ownerId: leaseOwnerId,
        now: startedAt,
        leaseDuration: config.coordinatorLeaseDuration,
      );
      if (leaseFence == null) {
        final finishedAt = _clock();
        _emit(
          CloudSyncEventType.runSkipped,
          at: finishedAt,
          trigger: trigger,
          skipReason: CloudSyncSkipReason.coordinatorLeaseUnavailable,
        );
        return await _finishRun(
          runId: 'run-$runNumber-${startedAt.microsecondsSinceEpoch}',
          trigger: trigger,
          status: CloudSyncRunStatus.skipped,
          counters: counters,
          startedAt: startedAt,
          finishedAt: finishedAt,
          skipReason: CloudSyncSkipReason.coordinatorLeaseUnavailable,
        );
      }
      _activeLeaseFence = leaseFence;
      _lastCoordinatorLeaseRenewal = startedAt;

      // A read-only shadow pass must not inspect or mutate durable outbox
      // state. Lease recovery is part of the write pipeline, even though it
      // does not contact CloudKit.
      if (config.flags.saves) {
        await _store.recoverExpiredOutboxLeases(scope, now: _clock());
      }
      var pullSucceeded = !config.flags.readOnlyFetch;
      CloudFailureCategory? degradedFailure;
      CloudShadowJournalBlockReason? shadowJournalBlockReason;
      if (config.flags.readOnlyFetch &&
          !_isCancelled(cancellationToken) &&
          _notificationTriggerAllowed(trigger)) {
        final pullResult = await _pullChanges(
          trigger: trigger,
          cancellationToken: cancellationToken,
        );
        counters = counters.add(
          fetched: pullResult.fetched,
          shadowJournalEntries: pullResult.journalUsage.pendingEntries,
          shadowJournalEstimatedBytes: pullResult.journalUsage.estimatedBytes,
          shadowJournalRejectedEntries: pullResult.rejectedEntries,
        );
        pullSucceeded = pullResult.succeeded;
        degradedFailure = pullResult.failureCategory;
        shadowJournalBlockReason = pullResult.journalBlockReason;
      }

      if (config.flags.semanticApply && !_isCancelled(cancellationToken)) {
        final applyCounters = await _applyInbox(cancellationToken);
        counters = counters.add(
          applied: applyCounters.applied,
          deferred: applyCounters.deferred,
          quarantined: applyCounters.quarantined,
          retried: applyCounters.retried,
        );
      }

      final pullRequired = _requiresPullBeforePush(trigger);
      if (config.flags.saves &&
          !_isCancelled(cancellationToken) &&
          (!pullRequired || pullSucceeded)) {
        final pushCounters = await _flushOutbox(
          runNumber: runNumber,
          cancellationToken: cancellationToken,
        );
        counters = counters.add(
          confirmed: pushCounters.confirmed,
          quarantined: pushCounters.quarantined,
          retried: pushCounters.retried,
        );
      }

      final finishedAt = _clock();
      if (_isCancelled(cancellationToken)) {
        _emit(
          CloudSyncEventType.runCancelled,
          at: finishedAt,
          trigger: trigger,
          elapsed: finishedAt.difference(startedAt),
        );
        return await _finishRun(
          runId: 'run-$runNumber-${startedAt.microsecondsSinceEpoch}',
          trigger: trigger,
          status: CloudSyncRunStatus.cancelled,
          counters: counters,
          startedAt: startedAt,
          finishedAt: finishedAt,
          failureCategory: CloudFailureCategory.cancelled,
          shadowJournalBlockReason: shadowJournalBlockReason,
        );
      }

      _emit(
        CloudSyncEventType.runCompleted,
        at: finishedAt,
        trigger: trigger,
        elapsed: finishedAt.difference(startedAt),
      );
      return await _finishRun(
        runId: 'run-$runNumber-${startedAt.microsecondsSinceEpoch}',
        trigger: trigger,
        status: degradedFailure == null && shadowJournalBlockReason == null
            ? CloudSyncRunStatus.completed
            : CloudSyncRunStatus.degraded,
        counters: counters,
        startedAt: startedAt,
        finishedAt: finishedAt,
        failureCategory: degradedFailure,
        shadowJournalBlockReason: shadowJournalBlockReason,
      );
    } on CloudSyncFailure catch (error) {
      final finishedAt = _clock();
      _emit(
        CloudSyncEventType.runFailed,
        at: finishedAt,
        trigger: trigger,
        failureCategory: error.category,
        elapsed: finishedAt.difference(startedAt),
      );
      return await _finishRun(
        runId: 'run-$runNumber-${startedAt.microsecondsSinceEpoch}',
        trigger: trigger,
        status: CloudSyncRunStatus.failed,
        counters: counters,
        startedAt: startedAt,
        finishedAt: finishedAt,
        failureCategory: error.category,
      );
    } catch (_) {
      final finishedAt = _clock();
      _emit(
        CloudSyncEventType.runFailed,
        at: finishedAt,
        trigger: trigger,
        failureCategory: CloudFailureCategory.unknown,
        elapsed: finishedAt.difference(startedAt),
      );
      return await _finishRun(
        runId: 'run-$runNumber-${startedAt.microsecondsSinceEpoch}',
        trigger: trigger,
        status: CloudSyncRunStatus.failed,
        counters: counters,
        startedAt: startedAt,
        finishedAt: finishedAt,
        failureCategory: CloudFailureCategory.unknown,
      );
    } finally {
      try {
        if (leaseFence != null) {
          await _store.releaseCoordinatorLease(scope, leaseFence: leaseFence);
        }
      } catch (_) {
        // The durable lease has an expiry. A release failure must not wedge
        // this engine instance or change an already persisted sync outcome.
      } finally {
        _lastCoordinatorLeaseRenewal = null;
        _activeLeaseFence = null;
        _runActive = false;
      }
    }
  }

  Future<_PullResult> _pullChanges({
    required CloudSyncTrigger trigger,
    CloudSyncCancellationToken? cancellationToken,
  }) {
    final lifecycle = _protectedPageLeaseLifecycle;
    if (lifecycle == null) {
      return _pullChangesWhileStoreExclusive(
        trigger: trigger,
        cancellationToken: cancellationToken,
      );
    }
    return lifecycle.runProtectedStoreExclusive(
      () => _pullChangesWhileStoreExclusive(
        trigger: trigger,
        cancellationToken: cancellationToken,
      ),
    );
  }

  Future<_PullResult> _pullChangesWhileStoreExclusive({
    required CloudSyncTrigger trigger,
    CloudSyncCancellationToken? cancellationToken,
  }) async {
    await _protectedPageLeaseLifecycle?.ensureRecoveredBeforeFetch();
    var checkpoint = await _store.readCheckpoint(scope);
    final initialNow = _clock();
    final nextEligible = checkpoint.nextPullEligibleAt;
    if (nextEligible != null && nextEligible.isAfter(initialNow)) {
      _emit(
        CloudSyncEventType.runSkipped,
        at: initialNow,
        trigger: trigger,
        skipReason: CloudSyncSkipReason.pullBackoffActive,
      );
      return _PullResult(
        fetched: 0,
        succeeded: false,
        failureCategory: checkpoint.lastFailure ?? CloudFailureCategory.network,
      );
    }

    var fetched = 0;
    var sawSuccessfulPage = false;
    var authenticationRefreshUsed = false;
    var pcsRefreshUsed = false;
    var journalUsage = CloudShadowJournalUsage.empty;
    final shadowMode =
        config.flags.readOnlyFetch && !config.flags.semanticApply;
    if (shadowMode) {
      journalUsage = await _store.readShadowJournalUsage(
        scope,
        budget: config.shadowJournalBudget,
      );
      final blockReason = config.shadowJournalBudget.blockReasonForCurrentUsage(
        journalUsage,
        now: initialNow,
      );
      if (blockReason != null) {
        _emitShadowJournalBlocked(
          blockReason,
          usage: journalUsage,
          rejectedEntries: 0,
          at: initialNow,
        );
        return _PullResult(
          fetched: 0,
          succeeded: false,
          journalUsage: journalUsage,
          journalBlockReason: blockReason,
        );
      }
    }
    for (
      var page = 0;
      page < config.maximumFetchPagesPerRun && !_isCancelled(cancellationToken);
      page++
    ) {
      CloudFetchBatch batch;
      while (true) {
        await _renewCoordinatorLeaseOrThrow();
        try {
          batch = await _transport
              .fetchChanges(
                scope,
                previousToken: checkpoint.fetchedToken,
                generation: checkpoint.generation,
                limit: config.maximumBatchSize,
              )
              .timeout(
                config.fetchOperationTimeout,
                onTimeout: () => throw CloudSyncFailure(
                  category: CloudFailureCategory.network,
                  safeCode: 'fetch_timeout',
                ),
              );
          break;
        } on CloudSyncFailure catch (error) {
          if (error.category == CloudFailureCategory.authorization &&
              !authenticationRefreshUsed) {
            authenticationRefreshUsed = true;
            final refreshed = await _tryRefreshAuthentication();
            if (refreshed) {
              continue;
            }
          } else if (error.category == CloudFailureCategory.pcsUnavailable &&
              !pcsRefreshUsed) {
            pcsRefreshUsed = true;
            final refreshed = await _tryRefreshPcs();
            if (refreshed) {
              continue;
            }
          }
          final pausedError =
              error.category == CloudFailureCategory.authorization ||
                  error.category == CloudFailureCategory.pcsUnavailable
              ? CloudSyncFailure(
                  category: error.category,
                  retryAfter: config.pausedRetryDelay,
                  safeCode: error.safeCode,
                )
              : error;
          await _recordPullFailure(checkpoint, pausedError);
          return _PullResult(
            fetched: fetched,
            succeeded: false,
            failureCategory: pausedError.category,
            journalUsage: journalUsage,
          );
        } catch (_) {
          final attempt = checkpoint.consecutivePullFailures + 1;
          final unknown = CloudSyncFailure(
            category: CloudFailureCategory.unknown,
            retryAfter: attempt >= config.maximumUnknownAttempts
                ? config.pausedRetryDelay
                : null,
          );
          await _recordPullFailure(checkpoint, unknown);
          return _PullResult(
            fetched: fetched,
            succeeded: false,
            failureCategory: CloudFailureCategory.unknown,
            journalUsage: journalUsage,
          );
        }
      }
      _requireMatchingScope(batch.scope);
      if (batch.generation != checkpoint.generation) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'generation_mismatch',
        );
      }
      if (authenticationRefreshUsed) {
        await _store.resumePausedOutbox(
          scope,
          categories: const {CloudFailureCategory.authorization},
          now: _clock(),
        );
      }
      if (pcsRefreshUsed) {
        await _store.resumePausedOutbox(
          scope,
          categories: const {CloudFailureCategory.pcsUnavailable},
          now: _clock(),
        );
      }

      // The journal and fetched token are committed even if cancellation
      // arrives while the network request is in flight.
      final journalNow = _clock();
      await _renewCoordinatorLeaseOrThrow(force: true);
      if (batch.protectedPageLeaseReference != null &&
          _protectedPageLeaseLifecycle == null) {
        if (_transport case CloudProtectedPageLeaseTransport transport) {
          await transport.rollbackProtectedPageLease(
            batch.protectedPageLeaseReference!,
          );
        }
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'protected_page_lease_lifecycle_unavailable',
        );
      }
      int inserted;
      try {
        if (shadowMode) {
          final leaseFence = _activeLeaseFence;
          if (leaseFence == null) {
            throw CloudSyncFailure(
              category: CloudFailureCategory.localStorage,
              safeCode: 'coordinator_lease_fence_missing',
            );
          }
          final admission = await _store.journalShadowFetchedBatch(
            batch,
            now: journalNow,
            budget: config.shadowJournalBudget,
            leaseFence: leaseFence,
            expectedGeneration: checkpoint.generation,
            expectedFetchedToken: checkpoint.fetchedToken,
          );
          journalUsage = admission.usage;
          final blockReason = admission.blockReason;
          if (blockReason != null) {
            await _protectedPageLeaseLifecycle?.rollbackUnjournaledPage(batch);
            _emitShadowJournalBlocked(
              blockReason,
              usage: admission.usage,
              rejectedEntries: admission.rejectedEntries,
              at: journalNow,
            );
            return _PullResult(
              fetched: fetched,
              succeeded: sawSuccessfulPage,
              journalUsage: admission.usage,
              rejectedEntries: admission.rejectedEntries,
              journalBlockReason: blockReason,
            );
          }
          inserted = admission.insertedEntries;
        } else {
          final leaseFence = _activeLeaseFence;
          if (leaseFence == null) {
            throw CloudSyncFailure(
              category: CloudFailureCategory.localStorage,
              safeCode: 'coordinator_lease_fence_missing',
            );
          }
          inserted = await _store.journalFetchedBatch(
            batch,
            now: journalNow,
            leaseFence: leaseFence,
            expectedGeneration: checkpoint.generation,
            expectedFetchedToken: checkpoint.fetchedToken,
          );
        }
      } catch (_) {
        await _protectedPageLeaseLifecycle?.rollbackUnjournaledPage(batch);
        rethrow;
      }
      await _protectedPageLeaseLifecycle?.commitJournaledPage(
        batch,
        previousCheckpointReference: checkpoint.fetchedToken,
      );
      fetched += inserted;
      sawSuccessfulPage = true;
      _emit(CloudSyncEventType.fetchCompleted, at: _clock(), count: inserted);
      checkpoint = await _store.readCheckpoint(scope);
      if (!batch.hasMore) break;
    }

    if (sawSuccessfulPage) {
      await _store.recordPullSuccess(scope, now: _clock());
    }
    return _PullResult(
      fetched: fetched,
      succeeded: sawSuccessfulPage,
      journalUsage: journalUsage,
    );
  }

  Future<void> _recordPullFailure(
    CloudSyncCheckpoint checkpoint,
    CloudSyncFailure error,
  ) async {
    final attempt = checkpoint.consecutivePullFailures + 1;
    final now = _clock();
    final nextEligibleAt = _backoff.nextEligibleAt(
      now: now,
      attempt: attempt,
      category: error.category,
      retryAfter: error.retryAfter,
    );
    await _store.recordPullFailure(
      scope,
      category: error.category,
      nextEligibleAt: nextEligibleAt,
    );
    _emit(
      CloudSyncEventType.backoffScheduled,
      at: now,
      failureCategory: error.category,
      attempt: attempt,
    );
  }

  Future<CloudSyncRunCounters> _applyInbox(
    CloudSyncCancellationToken? cancellationToken,
  ) async {
    final entries = await _store.readEligibleInbox(
      scope,
      now: _clock(),
      limit: config.maximumInboxEntriesPerRun,
    );
    var counters = const CloudSyncRunCounters();
    for (final entry in entries) {
      if (_isCancelled(cancellationToken)) break;
      await _renewCoordinatorLeaseOrThrow();

      CloudInboxApplyResult result;
      final preflightFailure = entry.change.preflightFailure;
      if (preflightFailure != null) {
        result = CloudInboxApplyResult.quarantined(
          failureCategory: preflightFailure,
        );
      } else {
        try {
          final leaseFence = _activeLeaseFence;
          if (leaseFence == null) {
            throw CloudSyncFailure(
              category: CloudFailureCategory.localStorage,
              safeCode: 'coordinator_lease_fence_missing',
            );
          }
          result = await _inboxApplier.apply(entry, leaseFence: leaseFence);
        } on CloudSyncFailure catch (error) {
          result =
              error.category.isRetryable ||
                  (error.category == CloudFailureCategory.unknown &&
                      entry.attemptCount + 1 < config.maximumUnknownAttempts)
              ? CloudInboxApplyResult.retryable(
                  failureCategory: error.category,
                  retryAfter: error.retryAfter,
                )
              : CloudInboxApplyResult.quarantined(
                  failureCategory: error.category,
                );
        } catch (_) {
          result = entry.attemptCount + 1 < config.maximumUnknownAttempts
              ? const CloudInboxApplyResult.retryable(
                  failureCategory: CloudFailureCategory.unknown,
                )
              : const CloudInboxApplyResult.quarantined(
                  failureCategory: CloudFailureCategory.unknown,
                );
        }
      }

      if (result.disposition == CloudInboxApplyDisposition.quarantined &&
          result.failureCategory == CloudFailureCategory.unknown &&
          entry.attemptCount + 1 < config.maximumUnknownAttempts) {
        result = const CloudInboxApplyResult.retryable(
          failureCategory: CloudFailureCategory.unknown,
        );
      }

      final now = _clock();
      switch (result.disposition) {
        case CloudInboxApplyDisposition.applied:
          if (!result.inboxStatusPersisted) {
            await _store.markInboxApplied(
              scope,
              sequence: entry.sequence,
              now: now,
              leaseFence: _requireActiveLeaseFence(),
            );
          }
          counters = counters.add(applied: 1);
          break;
        case CloudInboxApplyDisposition.deferred:
        case CloudInboxApplyDisposition.retryable:
          final category =
              result.failureCategory ?? CloudFailureCategory.dependency;
          if (result.disposition == CloudInboxApplyDisposition.deferred &&
              _shouldQuarantineDeferredInboxEntry(entry, now)) {
            if (!result.inboxStatusPersisted) {
              await _store.quarantineInbox(
                scope,
                sequence: entry.sequence,
                category: category,
                now: now,
                leaseFence: _requireActiveLeaseFence(),
              );
            }
            counters = counters.add(quarantined: 1);
            break;
          }
          final nextEligibleAt = _backoff.nextEligibleAt(
            now: now,
            attempt: entry.attemptCount + 1,
            category: category,
            retryAfter: result.retryAfter,
          );
          await _store.markInboxRetryable(
            scope,
            sequence: entry.sequence,
            category: category,
            now: now,
            nextEligibleAt: nextEligibleAt,
            leaseFence: _requireActiveLeaseFence(),
          );
          counters = counters.add(
            deferred: result.disposition == CloudInboxApplyDisposition.deferred
                ? 1
                : 0,
            retried: result.disposition == CloudInboxApplyDisposition.retryable
                ? 1
                : 0,
          );
          break;
        case CloudInboxApplyDisposition.quarantined:
          if (!result.inboxStatusPersisted) {
            await _store.quarantineInbox(
              scope,
              sequence: entry.sequence,
              category: result.failureCategory ?? CloudFailureCategory.unknown,
              now: now,
              leaseFence: _requireActiveLeaseFence(),
            );
          }
          counters = counters.add(quarantined: 1);
          break;
      }
    }
    _emit(
      CloudSyncEventType.inboxApplied,
      at: _clock(),
      count: counters.applied,
    );
    return counters;
  }

  bool _shouldQuarantineDeferredInboxEntry(
    CloudInboxEntry entry,
    DateTime now,
  ) {
    final age = now.difference(entry.createdAt);
    return entry.attemptCount + 1 >= config.maximumDeferredAttempts &&
        !age.isNegative &&
        age >= config.maximumDeferredAge;
  }

  Future<CloudSyncRunCounters> _flushOutbox({
    required int runNumber,
    CloudSyncCancellationToken? cancellationToken,
  }) async {
    var counters = const CloudSyncRunCounters();
    var authenticationRefreshUsed = false;
    var pcsRefreshUsed = false;

    final pausedCategories = await _store.readPausedOutboxFailureCategories(
      scope,
      now: _clock(),
    );
    if (pausedCategories.contains(CloudFailureCategory.authorization)) {
      authenticationRefreshUsed = true;
      final refreshed = await _tryRefreshAuthentication();
      _emit(
        CloudSyncEventType.authenticationRefreshed,
        at: _clock(),
        count: refreshed ? 1 : 0,
      );
      if (refreshed) {
        await _resumePausedOutbox(
          categories: const {CloudFailureCategory.authorization},
        );
      } else {
        await _postponeEligiblePausedOutbox(
          categories: const {CloudFailureCategory.authorization},
        );
      }
    }
    if (pausedCategories.contains(CloudFailureCategory.pcsUnavailable)) {
      pcsRefreshUsed = true;
      final refreshed = await _tryRefreshPcs();
      _emit(
        CloudSyncEventType.pcsRefreshed,
        at: _clock(),
        count: refreshed ? 1 : 0,
      );
      if (refreshed) {
        await _resumePausedOutbox(
          categories: const {CloudFailureCategory.pcsUnavailable},
        );
      } else {
        await _postponeEligiblePausedOutbox(
          categories: const {CloudFailureCategory.pcsUnavailable},
        );
      }
    }

    final allowedActions = <CloudOutboxAction>{
      CloudOutboxAction.save,
      if (config.flags.deletions) CloudOutboxAction.delete,
    };
    for (
      var batchIndex = 0;
      batchIndex < config.maximumOutboxBatchesPerRun &&
          !_isCancelled(cancellationToken);
      batchIndex++
    ) {
      final now = _clock();
      await _renewCoordinatorLeaseOrThrow();
      final leaseId =
          '$coordinatorId:$runNumber:$batchIndex:'
          '${now.microsecondsSinceEpoch}';
      final leased = await _store.leaseEligibleOutbox(
        scope,
        now: now,
        limit: config.maximumBatchSize,
        leaseId: leaseId,
        leaseDuration: config.outboxLeaseDuration,
        allowedActions: allowedActions,
      );
      if (leased.isEmpty) break;

      final preparation = await _prepareOutboxMappings(leased, leaseId);
      final transitions = <CloudOutboxTransition>[...preparation.transitions];
      for (final transition in preparation.transitions) {
        counters = _countOutboxTransition(counters, transition);
      }
      final ready = preparation.ready;
      var outcomes = <String, CloudPushOutcome>{};
      if (ready.isNotEmpty) {
        try {
          final result = await _transport.pushOperations(
            scope,
            operations: ready,
          );
          outcomes = Map.of(result.outcomes);
        } on CloudSyncFailure catch (error) {
          for (final operation in ready) {
            outcomes[operation.operationId] = _outcomeForThrownFailure(
              operation.operationId,
              error,
            );
          }
        } catch (_) {
          for (final operation in ready) {
            outcomes[operation.operationId] = CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.retryable,
              failureCategory: CloudFailureCategory.unknown,
            );
          }
        }
      }

      final unauthorized = ready
          .where(
            (operation) =>
                outcomes[operation.operationId]?.disposition ==
                CloudPushDisposition.unauthorized,
          )
          .toList();
      if (unauthorized.isNotEmpty && !authenticationRefreshUsed) {
        authenticationRefreshUsed = true;
        final refreshed = await _tryRefreshAuthentication();
        _emit(
          CloudSyncEventType.authenticationRefreshed,
          at: _clock(),
          count: refreshed ? 1 : 0,
        );
        if (refreshed) {
          await _resumePausedOutbox(
            categories: const {CloudFailureCategory.authorization},
          );
          await _repushAfterRefresh(unauthorized, outcomes);
        }
      }

      final pcsUnavailable = ready
          .where(
            (operation) =>
                outcomes[operation.operationId]?.disposition ==
                CloudPushDisposition.pcsUnavailable,
          )
          .toList();
      if (pcsUnavailable.isNotEmpty && !pcsRefreshUsed) {
        pcsRefreshUsed = true;
        final refreshed = await _tryRefreshPcs();
        _emit(
          CloudSyncEventType.pcsRefreshed,
          at: _clock(),
          count: refreshed ? 1 : 0,
        );
        if (refreshed) {
          await _resumePausedOutbox(
            categories: const {CloudFailureCategory.pcsUnavailable},
          );
          await _repushAfterRefresh(pcsUnavailable, outcomes);
        }
      }

      for (final operation in ready) {
        final outcome = outcomes[operation.operationId];
        if (outcome == null) {
          final transition = _retryOrQuarantineTransition(
            operation,
            category: CloudFailureCategory.network,
          );
          transitions.add(transition);
          counters = _countOutboxTransition(counters, transition);
          continue;
        }
        switch (outcome.disposition) {
          case CloudPushDisposition.confirmed:
            transitions.add(
              CloudOutboxTransition.confirmed(operation.operationId),
            );
            counters = counters.add(confirmed: 1);
            break;
          case CloudPushDisposition.retryable:
            final transition = _retryOrQuarantineTransition(
              operation,
              category: outcome.failureCategory ?? CloudFailureCategory.network,
              retryAfter: outcome.retryAfter,
            );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
          case CloudPushDisposition.unauthorized:
            final transition = CloudOutboxTransition.paused(
              operation.operationId,
              category: CloudFailureCategory.authorization,
              nextEligibleAt: _clock().add(config.pausedRetryDelay),
            );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
          case CloudPushDisposition.pcsUnavailable:
            final transition = CloudOutboxTransition.paused(
              operation.operationId,
              category: CloudFailureCategory.pcsUnavailable,
              nextEligibleAt: _clock().add(config.pausedRetryDelay),
            );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
          case CloudPushDisposition.serverRecordChanged:
            final transition = await _resolveServerRecordChanged(operation);
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
          case CloudPushDisposition.quarantined:
            final category =
                outcome.failureCategory ?? CloudFailureCategory.unknown;
            final transition = category == CloudFailureCategory.unknown
                ? _retryOrQuarantineTransition(operation, category: category)
                : CloudOutboxTransition.quarantined(
                    operation.operationId,
                    category: category,
                  );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
        }
      }

      // Outcomes are durable even if cancellation arrives during upload.
      await _store.applyOutboxTransitions(
        scope,
        leaseId: leaseId,
        transitions: transitions,
        now: _clock(),
      );
      _emit(
        CloudSyncEventType.outboxFlushed,
        at: _clock(),
        count: ready.length,
      );
    }
    return counters;
  }

  Future<_OutboxPreparation> _prepareOutboxMappings(
    List<CloudOutboxOperation> leased,
    String leaseId,
  ) async {
    final ready = <CloudOutboxOperation>[];
    final transitions = <CloudOutboxTransition>[];
    for (final operation in leased) {
      try {
        var mapping = await _store.readRecordMap(
          scope,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
        );
        if (operation.serverRecordIdHash != null) {
          if (mapping == null) {
            transitions.add(
              CloudOutboxTransition.paused(
                operation.operationId,
                category: CloudFailureCategory.dependency,
              ),
            );
            continue;
          }
          if (mapping.serverRecordIdHash != operation.serverRecordIdHash) {
            transitions.add(
              CloudOutboxTransition.quarantined(
                operation.operationId,
                category: CloudFailureCategory.conflict,
              ),
            );
            continue;
          }
          ready.add(operation);
          continue;
        }

        if (mapping == null) {
          if (operation.action == CloudOutboxAction.delete) {
            transitions.add(
              CloudOutboxTransition.paused(
                operation.operationId,
                category: CloudFailureCategory.dependency,
              ),
            );
            continue;
          }
          mapping = await _transport.allocateServerRecordMapping(
            scope,
            logicalEntityKeyHash: operation.logicalEntityKeyHash,
          );
          if (mapping.scope != scope ||
              mapping.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
              mapping.serverRecordIdHash.isEmpty ||
              mapping.encryptedServerRecordId.isEmpty) {
            throw CloudSyncFailure(
              category: CloudFailureCategory.conflict,
              safeCode: 'invalid_server_mapping',
            );
          }
          await _store.upsertRecordMap(mapping);
        }
        await _store.attachOutboxRecordMapping(
          scope,
          leaseId: leaseId,
          operationId: operation.operationId,
          serverRecordIdHash: mapping.serverRecordIdHash,
        );
        ready.add(
          operation.copyWith(serverRecordIdHash: mapping.serverRecordIdHash),
        );
      } on CloudSyncFailure catch (error) {
        transitions.add(_transitionForFailure(operation, error));
      } catch (_) {
        transitions.add(
          _retryOrQuarantineTransition(
            operation,
            category: CloudFailureCategory.unknown,
          ),
        );
      }
    }
    return _OutboxPreparation(ready: ready, transitions: transitions);
  }

  CloudOutboxTransition _transitionForFailure(
    CloudOutboxOperation operation,
    CloudSyncFailure error,
  ) {
    if (error.category == CloudFailureCategory.authorization ||
        error.category == CloudFailureCategory.pcsUnavailable ||
        error.category == CloudFailureCategory.dependency) {
      return CloudOutboxTransition.paused(
        operation.operationId,
        category: error.category,
        nextEligibleAt: error.category == CloudFailureCategory.dependency
            ? null
            : _clock().add(config.pausedRetryDelay),
      );
    }
    if (error.category.isRetryable ||
        error.category == CloudFailureCategory.unknown) {
      return _retryOrQuarantineTransition(
        operation,
        category: error.category,
        retryAfter: error.retryAfter,
      );
    }
    return CloudOutboxTransition.quarantined(
      operation.operationId,
      category: error.category,
    );
  }

  CloudPushOutcome _outcomeForThrownFailure(
    String operationId,
    CloudSyncFailure error,
  ) {
    final disposition = switch (error.category) {
      CloudFailureCategory.authorization => CloudPushDisposition.unauthorized,
      CloudFailureCategory.pcsUnavailable =>
        CloudPushDisposition.pcsUnavailable,
      CloudFailureCategory.conflict => CloudPushDisposition.serverRecordChanged,
      CloudFailureCategory.network ||
      CloudFailureCategory.throttled ||
      CloudFailureCategory.server ||
      CloudFailureCategory.localStorage ||
      CloudFailureCategory.dependency ||
      CloudFailureCategory.unknown => CloudPushDisposition.retryable,
      CloudFailureCategory.malformedRecord ||
      CloudFailureCategory.cancelled => CloudPushDisposition.quarantined,
    };
    return CloudPushOutcome(
      operationId: operationId,
      disposition: disposition,
      failureCategory: error.category,
      retryAfter: error.retryAfter,
    );
  }

  Future<void> _repushAfterRefresh(
    List<CloudOutboxOperation> operations,
    Map<String, CloudPushOutcome> outcomes,
  ) async {
    try {
      final retryResult = await _transport.pushOperations(
        scope,
        operations: operations,
      );
      for (final operation in operations) {
        outcomes[operation.operationId] =
            retryResult.outcomes[operation.operationId] ??
            CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.retryable,
              failureCategory: CloudFailureCategory.network,
            );
      }
    } on CloudSyncFailure catch (error) {
      for (final operation in operations) {
        outcomes[operation.operationId] = _outcomeForThrownFailure(
          operation.operationId,
          error,
        );
      }
    } catch (_) {
      for (final operation in operations) {
        outcomes[operation.operationId] = CloudPushOutcome(
          operationId: operation.operationId,
          disposition: CloudPushDisposition.retryable,
          failureCategory: CloudFailureCategory.unknown,
        );
      }
    }
  }

  Future<void> _resumePausedOutbox({
    required Set<CloudFailureCategory> categories,
  }) async {
    await _store.resumePausedOutbox(
      scope,
      categories: categories,
      now: _clock(),
    );
  }

  Future<void> _postponeEligiblePausedOutbox({
    required Set<CloudFailureCategory> categories,
  }) async {
    final now = _clock();
    await _store.postponeEligiblePausedOutbox(
      scope,
      categories: categories,
      now: now,
      nextEligibleAt: now.add(config.pausedRetryDelay),
    );
  }

  Future<CloudOutboxTransition> _resolveServerRecordChanged(
    CloudOutboxOperation operation,
  ) async {
    try {
      final resolution = await _transport.reconcileServerRecordChanged(
        scope,
        operation: operation,
      );
      _emit(
        CloudSyncEventType.serverConflictReconciled,
        at: _clock(),
        count:
            resolution.disposition ==
                CloudServerConflictDisposition.mergedForRetry
            ? 1
            : 0,
      );
      switch (resolution.disposition) {
        case CloudServerConflictDisposition.mergedForRetry:
          if (resolution.encryptedPayloadReference == null ||
              resolution.encryptedPayloadReference!.isEmpty ||
              resolution.payloadSha256 == null ||
              resolution.payloadSha256!.isEmpty ||
              resolution.serverRecordIdHash == null ||
              resolution.serverRecordIdHash != operation.serverRecordIdHash ||
              resolution.encryptedRawRecordReference == null ||
              resolution.encryptedRawRecordReference!.isEmpty) {
            return CloudOutboxTransition.quarantined(
              operation.operationId,
              category: CloudFailureCategory.conflict,
            );
          }
          final mapping = await _store.readRecordMap(
            scope,
            logicalEntityKeyHash: operation.logicalEntityKeyHash,
          );
          if (mapping == null ||
              mapping.serverRecordIdHash != resolution.serverRecordIdHash) {
            return CloudOutboxTransition.paused(
              operation.operationId,
              category: CloudFailureCategory.dependency,
            );
          }
          await _store.upsertRecordMap(
            CloudRecordMapEntry(
              scope: scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              serverRecordIdHash: mapping.serverRecordIdHash,
              encryptedServerRecordId: mapping.encryptedServerRecordId,
              etagHash: resolution.etagHash,
              encryptedRawRecordReference:
                  resolution.encryptedRawRecordReference,
              updatedAt: _clock(),
            ),
          );
          return CloudOutboxTransition.retryable(
            operation.operationId,
            category: CloudFailureCategory.conflict,
            nextEligibleAt: _clock(),
            encryptedPayloadReference: resolution.encryptedPayloadReference,
            payloadSha256: resolution.payloadSha256,
            serverRecordIdHash: resolution.serverRecordIdHash,
          );
        case CloudServerConflictDisposition.retryable:
          return _retryOrQuarantineTransition(
            operation,
            category:
                resolution.failureCategory ?? CloudFailureCategory.network,
            retryAfter: resolution.retryAfter,
          );
        case CloudServerConflictDisposition.quarantined:
          final category =
              resolution.failureCategory ?? CloudFailureCategory.unknown;
          return category == CloudFailureCategory.unknown
              ? _retryOrQuarantineTransition(operation, category: category)
              : CloudOutboxTransition.quarantined(
                  operation.operationId,
                  category: category,
                );
      }
    } on CloudSyncFailure catch (error) {
      return _transitionForFailure(operation, error);
    } catch (_) {
      return _retryOrQuarantineTransition(
        operation,
        category: CloudFailureCategory.unknown,
      );
    }
  }

  Future<bool> _tryRefreshAuthentication() async {
    try {
      return await _transport.refreshAuthentication(scope);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryRefreshPcs() async {
    try {
      return await _transport.refreshPcsAccess(scope);
    } catch (_) {
      return false;
    }
  }

  Future<void> _renewCoordinatorLeaseOrThrow({bool force = false}) async {
    final now = _clock();
    final lastRenewal = _lastCoordinatorLeaseRenewal;
    final renewalInterval = Duration(
      microseconds: config.coordinatorLeaseDuration.inMicroseconds ~/ 3,
    );
    if (!force &&
        lastRenewal != null &&
        !now.isBefore(lastRenewal) &&
        now.difference(lastRenewal) < renewalInterval) {
      return;
    }
    final leaseFence = _activeLeaseFence;
    if (leaseFence == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'coordinator_lease_fence_missing',
      );
    }
    final renewed = await _store.renewCoordinatorLease(
      scope,
      leaseFence: leaseFence,
      now: now,
      leaseDuration: config.coordinatorLeaseDuration,
    );
    if (!renewed) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'coordinator_lease_lost',
      );
    }
    _lastCoordinatorLeaseRenewal = now;
  }

  CloudCoordinatorLeaseFence _requireActiveLeaseFence() {
    final leaseFence = _activeLeaseFence;
    if (leaseFence == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'coordinator_lease_fence_missing',
      );
    }
    return leaseFence;
  }

  String _newLeaseOwnerId(int runNumber) {
    final random = Random.secure();
    final nonce = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '$coordinatorId:$runNumber:$nonce';
  }

  CloudSyncRunCounters _countOutboxTransition(
    CloudSyncRunCounters counters,
    CloudOutboxTransition transition,
  ) {
    return switch (transition.type) {
      CloudOutboxTransitionType.confirmed => counters.add(confirmed: 1),
      CloudOutboxTransitionType.retryable => counters.add(retried: 1),
      CloudOutboxTransitionType.paused => counters,
      CloudOutboxTransitionType.quarantined => counters.add(quarantined: 1),
    };
  }

  CloudOutboxTransition _retryOrQuarantineTransition(
    CloudOutboxOperation operation, {
    required CloudFailureCategory category,
    Duration? retryAfter,
    String? encryptedPayloadReference,
    String? payloadSha256,
    String? serverRecordIdHash,
  }) {
    if (category == CloudFailureCategory.unknown &&
        operation.attemptCount + 1 >= config.maximumUnknownAttempts) {
      return CloudOutboxTransition.quarantined(
        operation.operationId,
        category: category,
      );
    }
    return CloudOutboxTransition.retryable(
      operation.operationId,
      category: category,
      nextEligibleAt: _backoff.nextEligibleAt(
        now: _clock(),
        attempt: operation.attemptCount + 1,
        category: category,
        retryAfter: retryAfter,
      ),
      encryptedPayloadReference: encryptedPayloadReference,
      payloadSha256: payloadSha256,
      serverRecordIdHash: serverRecordIdHash,
    );
  }

  bool _notificationTriggerAllowed(CloudSyncTrigger trigger) =>
      trigger != CloudSyncTrigger.notificationHint ||
      config.flags.notificationHints;

  bool _requiresPullBeforePush(CloudSyncTrigger trigger) => switch (trigger) {
    CloudSyncTrigger.localOutbox || CloudSyncTrigger.notificationHint => false,
    CloudSyncTrigger.startup ||
    CloudSyncTrigger.networkReconnect ||
    CloudSyncTrigger.idsReconnect ||
    CloudSyncTrigger.detectedGap ||
    CloudSyncTrigger.manual => true,
  };

  bool _isCancelled(CloudSyncCancellationToken? token) =>
      token?.isCancelled ?? false;

  void _requireMatchingScope(CloudSyncScope received) {
    if (received != scope) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'scope_mismatch',
      );
    }
  }

  void _emit(
    CloudSyncEventType type, {
    required DateTime at,
    CloudSyncTrigger? trigger,
    CloudFailureCategory? failureCategory,
    CloudSyncSkipReason? skipReason,
    CloudShadowJournalBlockReason? shadowJournalBlockReason,
    int count = 0,
    int estimatedBytes = 0,
    int attempt = 0,
    Duration elapsed = Duration.zero,
  }) {
    _observer.onEvent(
      CloudSyncEvent(
        type: type,
        scopeDiagnosticKey: scope.diagnosticKey,
        at: at,
        trigger: trigger,
        failureCategory: failureCategory,
        skipReason: skipReason,
        shadowJournalBlockReason: shadowJournalBlockReason,
        count: count,
        estimatedBytes: estimatedBytes,
        attempt: attempt,
        elapsed: elapsed,
      ),
    );
  }

  void _emitShadowJournalBlocked(
    CloudShadowJournalBlockReason reason, {
    required CloudShadowJournalUsage usage,
    required int rejectedEntries,
    required DateTime at,
  }) {
    _emit(
      CloudSyncEventType.shadowJournalBlocked,
      at: at,
      shadowJournalBlockReason: reason,
      count: usage.pendingEntries + rejectedEntries,
      estimatedBytes: usage.estimatedBytes,
    );
  }

  Future<CloudSyncRunResult> _finishRun({
    required String runId,
    required CloudSyncTrigger trigger,
    required CloudSyncRunStatus status,
    required CloudSyncRunCounters counters,
    required DateTime startedAt,
    required DateTime finishedAt,
    CloudSyncSkipReason? skipReason,
    CloudFailureCategory? failureCategory,
    CloudShadowJournalBlockReason? shadowJournalBlockReason,
  }) async {
    final result = CloudSyncRunResult(
      status: status,
      counters: counters,
      startedAt: startedAt,
      finishedAt: finishedAt,
      skipReason: skipReason,
      failureCategory: failureCategory,
      shadowJournalBlockReason: shadowJournalBlockReason,
    );
    try {
      await _store.recordRun(
        CloudSyncRunRecord(
          scope: scope,
          runId: runId,
          triggerName: trigger.name,
          architectureName: architectureName,
          startedAt: startedAt,
          finishedAt: finishedAt,
          counters: counters,
          modeName:
              '${_configuredModeName()}/${status.name}'
              '${shadowJournalBlockReason == null ? '' : '/journal-${shadowJournalBlockReason.name}'}',
          failureCategory: failureCategory,
        ),
      );
    } catch (_) {
      // Diagnostic retention must never delay IDS or change sync correctness.
    }
    return result;
  }

  String _configuredModeName() {
    if (config.flags.deletions) return 'guarded-deletes';
    if (config.flags.saves) return 'durable-saves';
    if (config.flags.semanticApply) return 'semantic-pull';
    if (config.flags.readOnlyFetch) return 'read-only-shadow';
    return 'disabled';
  }
}

class _PullResult {
  _PullResult({
    required this.fetched,
    required this.succeeded,
    this.failureCategory,
    CloudShadowJournalUsage? journalUsage,
    this.rejectedEntries = 0,
    this.journalBlockReason,
  }) : journalUsage = journalUsage ?? CloudShadowJournalUsage.empty;

  final int fetched;
  final bool succeeded;
  final CloudFailureCategory? failureCategory;
  final CloudShadowJournalUsage journalUsage;
  final int rejectedEntries;
  final CloudShadowJournalBlockReason? journalBlockReason;
}

class _OutboxPreparation {
  const _OutboxPreparation({required this.ready, required this.transitions});

  final List<CloudOutboxOperation> ready;
  final List<CloudOutboxTransition> transitions;
}
