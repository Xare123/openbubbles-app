// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'cloud_shadow_journal_budget.dart';
import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_backoff.dart';
import 'cloud_sync_cancellation.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_observability.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_write_transport.dart';
import 'cloud_sync_writer_authority.dart';
import 'cloudkit_operation_interlock.dart';

typedef CloudSyncClock = DateTime Function();
typedef CloudSyncUuidFactory = String Function();

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
  static const Duration maximumAllowedWriteOperationTimeout = Duration(
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
    this.writeOperationTimeout = const Duration(seconds: 45),
    this.coordinatorLeaseDuration = const Duration(minutes: 5),
    this.outboxLeaseDuration = const Duration(minutes: 2),
    this.pausedRetryDelay = const Duration(hours: 6),
    this.maximumDeferredAttempts = 8,
    this.maximumDeferredAge = const Duration(days: 3),
    this.maximumUnknownAttempts = 3,
    this.allowManualPullBackoffOverride = false,
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
  final Duration writeOperationTimeout;
  final Duration coordinatorLeaseDuration;
  final Duration outboxLeaseDuration;
  final Duration pausedRetryDelay;
  final int maximumDeferredAttempts;
  final Duration maximumDeferredAge;
  final int maximumUnknownAttempts;
  final bool allowManualPullBackoffOverride;
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
    if (writeOperationTimeout.inMicroseconds <= 0 ||
        writeOperationTimeout > maximumAllowedWriteOperationTimeout) {
      throw ArgumentError('cloud_sync_config_write_timeout_invalid');
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
    if (allowManualPullBackoffOverride &&
        (!flags.readOnlyFetch ||
            flags.saves ||
            flags.deletions ||
            flags.profiles ||
            flags.notificationHints)) {
      throw ArgumentError('cloud_sync_config_manual_backoff_override_unsafe');
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
    CloudSyncWriterAuthority? writerAuthority,
    CloudKitOperationExclusion? writerExclusion,
    CloudSyncBackoffPolicy? backoff,
    this._observer = const NoopCloudSyncObserver(),
    CloudSyncClock? clock,
    CloudSyncUuidFactory? uuidFactory,
    CloudSyncEngineConfig? config,
  }) : config = config ?? CloudSyncEngineConfig(),
       _store = store,
       _transport = transport,
       _writeTransport = transport is CloudSyncWriteTransport
           ? transport as CloudSyncWriteTransport
           : null,
       _nativeOperationQuiescence =
           transport is CloudSyncNativeOperationQuiescence
           ? transport as CloudSyncNativeOperationQuiescence
           : null,
       _writerAuthority = writerAuthority,
       _writerExclusion = writerExclusion,
       _unknownOutcomeStore = store is CloudSyncUnknownOutcomeLeasingStore
           ? store as CloudSyncUnknownOutcomeLeasingStore
           : null,
       _protectedPageLeaseLifecycle =
           store is CloudProtectedPageLeaseAdoptionStore &&
               _protectedLeaseTransportFor(transport) != null
           ? CloudProtectedPageLeaseLifecycle(
               store: store as CloudProtectedPageLeaseAdoptionStore,
               transport: _protectedLeaseTransportFor(transport)!,
             )
           : null,
       _backoff = backoff ?? CloudSyncBackoffPolicy(),
       _clock = clock ?? DateTime.now,
       _uuidFactory = uuidFactory ?? (() => const Uuid().v4().toUpperCase()) {
    if (coordinatorId.isEmpty) {
      throw ArgumentError('cloud_sync_coordinator_id_invalid');
    }
    this.config.validate();
    if (this.config.flags.saves && _writerAuthority == null) {
      throw ArgumentError('cloud_sync_writer_authority_required');
    }
    if (this.config.flags.saves && _unknownOutcomeStore == null) {
      throw ArgumentError('cloud_sync_unknown_outcome_store_required');
    }
    if (this.config.flags.saves && _writerExclusion == null) {
      throw ArgumentError('cloud_sync_writer_exclusion_required');
    }
    if (this.config.flags.saves && _nativeOperationQuiescence == null) {
      throw ArgumentError('cloud_sync_native_operation_quiescence_required');
    }
    if (this.config.flags.saves && _writeTransport == null) {
      throw ArgumentError('cloud_sync_write_preflight_transport_required');
    }
    if (this.config.flags.saves &&
        _writeTransport != null &&
        _protectedLeaseTransportFor(transport) != null &&
        (_protectedPageLeaseLifecycle == null ||
            store is! CloudProtectedOutboundLeaseAdoptionStore)) {
      throw ArgumentError(
        'cloud_sync_native_protected_writer_recovery_required',
      );
    }
  }

  final CloudSyncScope scope;
  final String coordinatorId;
  final String architectureName;
  final CloudSyncStore _store;
  final CloudSyncTransport _transport;
  final CloudSyncWriteTransport? _writeTransport;
  final CloudSyncNativeOperationQuiescence? _nativeOperationQuiescence;
  final CloudSyncWriterAuthority? _writerAuthority;
  final CloudKitOperationExclusion? _writerExclusion;
  final CloudSyncUnknownOutcomeLeasingStore? _unknownOutcomeStore;
  final CloudProtectedPageLeaseLifecycle? _protectedPageLeaseLifecycle;
  final CloudInboxApplier _inboxApplier;
  final CloudSyncBackoffPolicy _backoff;
  final CloudSyncObserver _observer;
  final CloudSyncClock _clock;
  final CloudSyncUuidFactory _uuidFactory;
  final CloudSyncEngineConfig config;

  bool _runActive = false;
  int _runSerial = 0;
  DateTime? _lastCoordinatorLeaseRenewal;
  CloudCoordinatorLeaseFence? _activeLeaseFence;
  CloudSyncWriterPermit? _activeWriterPermit;

  Future<CloudSyncRunResult> synchronize({
    required CloudSyncTrigger trigger,
    CloudSyncCancellationToken? cancellationToken,
  }) {
    if (config.flags.saves) {
      return _writerExclusion!.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () => _synchronize(
          trigger: trigger,
          cancellationToken: cancellationToken,
        ),
      );
    }
    return _synchronize(trigger: trigger, cancellationToken: cancellationToken);
  }

  Future<CloudSyncRunResult> _synchronize({
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
        _activeWriterPermit = await _writerAuthority!.issue(scope);
        await _verifyWriterPermit();
        await _store.recoverExpiredOutboxLeases(scope, now: _clock());
      }
      var pullSucceeded = !config.flags.readOnlyFetch;
      CloudFailureCategory? degradedFailure;
      CloudShadowJournalBlockReason? shadowJournalBlockReason;
      var remainingInboxEntries = config.maximumInboxEntriesPerRun;
      var semanticInboxCounters = const CloudSyncRunCounters();
      var semanticInboxPhaseStarted = false;
      var pullAttempted = false;

      // A restart may leave semantic rows waiting in the durable inbox. Apply
      // the contiguous prefix before fetching so local state is repaired as
      // early as possible, while still allowing the fetch to bring in older
      // parent records needed by a deferred row.
      if (config.flags.semanticApply && !_isCancelled(cancellationToken)) {
        semanticInboxPhaseStarted = true;
        final startupApply = await _applyInbox(
          cancellationToken,
          maximumEntries: remainingInboxEntries,
          emitEvent: false,
        );
        semanticInboxCounters = semanticInboxCounters.add(
          applied: startupApply.counters.applied,
          deferred: startupApply.counters.deferred,
          quarantined: startupApply.counters.quarantined,
          preflightQuarantined: startupApply.counters.preflightQuarantined,
          preflightUnsupportedRecordType:
              startupApply.counters.preflightUnsupportedRecordType,
          preflightMalformedMetadata:
              startupApply.counters.preflightMalformedMetadata,
          preflightOversizedRecord:
              startupApply.counters.preflightOversizedRecord,
          preflightInvalidChangeShape:
              startupApply.counters.preflightInvalidChangeShape,
          preflightUnknown: startupApply.counters.preflightUnknown,
          startupQuarantined: startupApply.counters.quarantined,
          tombstoneQuarantined: startupApply.counters.tombstoneQuarantined,
          semanticUnsupportedServiceQuarantined:
              startupApply.counters.semanticUnsupportedServiceQuarantined,
          semanticStageQuarantined:
              startupApply.counters.semanticStageQuarantined,
          retried: startupApply.counters.retried,
        );
        counters = counters.add(
          applied: startupApply.counters.applied,
          deferred: startupApply.counters.deferred,
          quarantined: startupApply.counters.quarantined,
          preflightQuarantined: startupApply.counters.preflightQuarantined,
          preflightUnsupportedRecordType:
              startupApply.counters.preflightUnsupportedRecordType,
          preflightMalformedMetadata:
              startupApply.counters.preflightMalformedMetadata,
          preflightOversizedRecord:
              startupApply.counters.preflightOversizedRecord,
          preflightInvalidChangeShape:
              startupApply.counters.preflightInvalidChangeShape,
          preflightUnknown: startupApply.counters.preflightUnknown,
          startupQuarantined: startupApply.counters.quarantined,
          tombstoneQuarantined: startupApply.counters.tombstoneQuarantined,
          semanticUnsupportedServiceQuarantined:
              startupApply.counters.semanticUnsupportedServiceQuarantined,
          semanticStageQuarantined:
              startupApply.counters.semanticStageQuarantined,
          retried: startupApply.counters.retried,
        );
        remainingInboxEntries -= startupApply.processedEntries;
      }

      if (config.flags.readOnlyFetch &&
          !_isCancelled(cancellationToken) &&
          _notificationTriggerAllowed(trigger)) {
        pullAttempted = true;
        final pullResult = await _pullChanges(
          trigger: trigger,
          cancellationToken: cancellationToken,
          maximumInboxEntries: remainingInboxEntries,
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
        semanticInboxPhaseStarted =
            semanticInboxPhaseStarted ||
            pullResult.semanticProcessedEntries > 0;
        semanticInboxCounters = semanticInboxCounters.add(
          applied: pullResult.semanticCounters.applied,
          deferred: pullResult.semanticCounters.deferred,
          quarantined: pullResult.semanticCounters.quarantined,
          postFetchQuarantined:
              pullResult.semanticCounters.postFetchQuarantined,
          preflightQuarantined:
              pullResult.semanticCounters.preflightQuarantined,
          preflightUnsupportedRecordType:
              pullResult.semanticCounters.preflightUnsupportedRecordType,
          preflightMalformedMetadata:
              pullResult.semanticCounters.preflightMalformedMetadata,
          preflightOversizedRecord:
              pullResult.semanticCounters.preflightOversizedRecord,
          preflightInvalidChangeShape:
              pullResult.semanticCounters.preflightInvalidChangeShape,
          preflightUnknown: pullResult.semanticCounters.preflightUnknown,
          tombstoneQuarantined:
              pullResult.semanticCounters.tombstoneQuarantined,
          semanticUnsupportedServiceQuarantined:
              pullResult.semanticCounters.semanticUnsupportedServiceQuarantined,
          semanticStageQuarantined:
              pullResult.semanticCounters.semanticStageQuarantined,
          retried: pullResult.semanticCounters.retried,
        );
        counters = counters.add(
          applied: pullResult.semanticCounters.applied,
          deferred: pullResult.semanticCounters.deferred,
          quarantined: pullResult.semanticCounters.quarantined,
          postFetchQuarantined:
              pullResult.semanticCounters.postFetchQuarantined,
          preflightQuarantined:
              pullResult.semanticCounters.preflightQuarantined,
          preflightUnsupportedRecordType:
              pullResult.semanticCounters.preflightUnsupportedRecordType,
          preflightMalformedMetadata:
              pullResult.semanticCounters.preflightMalformedMetadata,
          preflightOversizedRecord:
              pullResult.semanticCounters.preflightOversizedRecord,
          preflightInvalidChangeShape:
              pullResult.semanticCounters.preflightInvalidChangeShape,
          preflightUnknown: pullResult.semanticCounters.preflightUnknown,
          tombstoneQuarantined:
              pullResult.semanticCounters.tombstoneQuarantined,
          semanticUnsupportedServiceQuarantined:
              pullResult.semanticCounters.semanticUnsupportedServiceQuarantined,
          semanticStageQuarantined:
              pullResult.semanticCounters.semanticStageQuarantined,
          retried: pullResult.semanticCounters.retried,
        );
        remainingInboxEntries -= pullResult.semanticProcessedEntries;
      }

      if (config.flags.semanticApply &&
          remainingInboxEntries > 0 &&
          pullAttempted &&
          !_isCancelled(cancellationToken)) {
        semanticInboxPhaseStarted = true;
        final postFetchApply = await _applyInbox(
          cancellationToken,
          maximumEntries: remainingInboxEntries,
          emitEvent: false,
        );
        semanticInboxCounters = semanticInboxCounters.add(
          applied: postFetchApply.counters.applied,
          deferred: postFetchApply.counters.deferred,
          quarantined: postFetchApply.counters.quarantined,
          preflightQuarantined: postFetchApply.counters.preflightQuarantined,
          preflightUnsupportedRecordType:
              postFetchApply.counters.preflightUnsupportedRecordType,
          preflightMalformedMetadata:
              postFetchApply.counters.preflightMalformedMetadata,
          preflightOversizedRecord:
              postFetchApply.counters.preflightOversizedRecord,
          preflightInvalidChangeShape:
              postFetchApply.counters.preflightInvalidChangeShape,
          preflightUnknown: postFetchApply.counters.preflightUnknown,
          postFetchQuarantined: postFetchApply.counters.quarantined,
          tombstoneQuarantined: postFetchApply.counters.tombstoneQuarantined,
          semanticUnsupportedServiceQuarantined:
              postFetchApply.counters.semanticUnsupportedServiceQuarantined,
          semanticStageQuarantined:
              postFetchApply.counters.semanticStageQuarantined,
          retried: postFetchApply.counters.retried,
        );
        counters = counters.add(
          applied: postFetchApply.counters.applied,
          deferred: postFetchApply.counters.deferred,
          quarantined: postFetchApply.counters.quarantined,
          preflightQuarantined: postFetchApply.counters.preflightQuarantined,
          preflightUnsupportedRecordType:
              postFetchApply.counters.preflightUnsupportedRecordType,
          preflightMalformedMetadata:
              postFetchApply.counters.preflightMalformedMetadata,
          preflightOversizedRecord:
              postFetchApply.counters.preflightOversizedRecord,
          preflightInvalidChangeShape:
              postFetchApply.counters.preflightInvalidChangeShape,
          preflightUnknown: postFetchApply.counters.preflightUnknown,
          postFetchQuarantined: postFetchApply.counters.quarantined,
          tombstoneQuarantined: postFetchApply.counters.tombstoneQuarantined,
          semanticUnsupportedServiceQuarantined:
              postFetchApply.counters.semanticUnsupportedServiceQuarantined,
          semanticStageQuarantined:
              postFetchApply.counters.semanticStageQuarantined,
          retried: postFetchApply.counters.retried,
        );
        remainingInboxEntries -= postFetchApply.processedEntries;
      }

      if (semanticInboxPhaseStarted) {
        _emit(
          CloudSyncEventType.inboxApplied,
          at: _clock(),
          count: semanticInboxCounters.applied,
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
        _activeWriterPermit = null;
        _runActive = false;
      }
    }
  }

  Future<_PullResult> _pullChanges({
    required CloudSyncTrigger trigger,
    CloudSyncCancellationToken? cancellationToken,
    required int maximumInboxEntries,
  }) {
    final lifecycle = _protectedPageLeaseLifecycle;
    if (lifecycle == null) {
      return _pullChangesWhileStoreExclusive(
        trigger: trigger,
        cancellationToken: cancellationToken,
        maximumInboxEntries: maximumInboxEntries,
      );
    }
    return lifecycle.runProtectedStoreExclusive(
      () => _pullChangesWhileStoreExclusive(
        trigger: trigger,
        cancellationToken: cancellationToken,
        maximumInboxEntries: maximumInboxEntries,
      ),
    );
  }

  Future<_PullResult> _pullChangesWhileStoreExclusive({
    required CloudSyncTrigger trigger,
    CloudSyncCancellationToken? cancellationToken,
    required int maximumInboxEntries,
  }) async {
    await _protectedPageLeaseLifecycle?.ensureRecoveredBeforeFetch();
    var checkpoint = await _store.readCheckpoint(scope);
    final initialNow = _clock();
    final nextEligible = checkpoint.nextPullEligibleAt;
    final manualBackoffOverride =
        trigger == CloudSyncTrigger.manual &&
        config.allowManualPullBackoffOverride;
    if (nextEligible != null &&
        nextEligible.isAfter(initialNow) &&
        !manualBackoffOverride) {
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
    var semanticCounters = const CloudSyncRunCounters();
    var semanticProcessedEntries = 0;
    var authenticationRefreshUsed = false;
    var pcsRefreshUsed = false;
    var journalUsage = CloudShadowJournalUsage.empty;
    final shadowMode =
        config.flags.readOnlyFetch && !config.flags.semanticApply;
    if (config.flags.semanticApply && maximumInboxEntries <= 0) {
      // A semantic page cannot be journaled safely without capacity to make
      // its rows terminal. Leave the committed token untouched for the next
      // run rather than creating an unserviceable pending page.
      return _PullResult(
        fetched: 0,
        succeeded: false,
        failureCategory: CloudFailureCategory.dependency,
      );
    }
    if (config.flags.semanticApply &&
        (checkpoint.pendingBatchId != null ||
            checkpoint.hasUnmarkedPendingInbox)) {
      // The startup inbox pass already attempted the page. Keeping the old
      // token means refetching here would be unsafe and would only create a
      // duplicate page while its predecessor is retryable/deferred.
      return _PullResult(
        fetched: 0,
        succeeded: false,
        failureCategory: CloudFailureCategory.dependency,
      );
    }
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

      // The journal is committed even if cancellation arrives while the
      // network request is in flight. A semantic page's continuation token is
      // held separately until its rows reach terminal state.
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
      if (!shadowMode && maximumInboxEntries > semanticProcessedEntries) {
        final pageApply = await _applyInbox(
          cancellationToken,
          maximumEntries: maximumInboxEntries - semanticProcessedEntries,
          emitEvent: false,
        );
        semanticCounters = semanticCounters.add(
          applied: pageApply.counters.applied,
          deferred: pageApply.counters.deferred,
          quarantined: pageApply.counters.quarantined,
          postFetchQuarantined: pageApply.counters.quarantined,
          preflightQuarantined: pageApply.counters.preflightQuarantined,
          preflightUnsupportedRecordType:
              pageApply.counters.preflightUnsupportedRecordType,
          preflightMalformedMetadata:
              pageApply.counters.preflightMalformedMetadata,
          preflightOversizedRecord: pageApply.counters.preflightOversizedRecord,
          preflightInvalidChangeShape:
              pageApply.counters.preflightInvalidChangeShape,
          preflightUnknown: pageApply.counters.preflightUnknown,
          tombstoneQuarantined: pageApply.counters.tombstoneQuarantined,
          semanticUnsupportedServiceQuarantined:
              pageApply.counters.semanticUnsupportedServiceQuarantined,
          semanticStageQuarantined: pageApply.counters.semanticStageQuarantined,
          retried: pageApply.counters.retried,
        );
        semanticProcessedEntries += pageApply.processedEntries;
        checkpoint = await _store.readCheckpoint(scope);
        // A retryable/deferred predecessor keeps the committed token at the
        // prior page. Do not fetch another page until this page is terminal.
        if (checkpoint.pendingBatchId != null ||
            semanticProcessedEntries >= maximumInboxEntries) {
          break;
        }
      }
      if (!batch.hasMore) break;
    }

    if (sawSuccessfulPage) {
      await _store.recordPullSuccess(scope, now: _clock());
    }
    final pageRemainsPending =
        config.flags.semanticApply &&
        (checkpoint.pendingBatchId != null ||
            checkpoint.hasUnmarkedPendingInbox);
    return _PullResult(
      fetched: fetched,
      succeeded: sawSuccessfulPage,
      failureCategory: pageRemainsPending
          ? CloudFailureCategory.dependency
          : null,
      journalUsage: journalUsage,
      semanticCounters: semanticCounters,
      semanticProcessedEntries: semanticProcessedEntries,
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

  Future<_InboxApplyResult> _applyInbox(
    CloudSyncCancellationToken? cancellationToken, {
    required int maximumEntries,
    required bool emitEvent,
  }) async {
    var counters = const CloudSyncRunCounters();
    var processedEntries = 0;
    while (processedEntries < maximumEntries) {
      if (_isCancelled(cancellationToken)) break;
      final entries = await _store.readEligibleInbox(
        scope,
        now: _clock(),
        limit: 1,
      );
      if (entries.isEmpty) break;
      final entry = entries.single;
      processedEntries++;
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
      var canApplyNextSequence = false;
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
          canApplyNextSequence = true;
          break;
        case CloudInboxApplyDisposition.deferred:
        case CloudInboxApplyDisposition.retryable:
          final category =
              result.failureCategory ?? CloudFailureCategory.dependency;
          final terminalBoundApplies =
              result.disposition == CloudInboxApplyDisposition.deferred ||
              (result.disposition == CloudInboxApplyDisposition.retryable &&
                  category == CloudFailureCategory.dependency);
          if (terminalBoundApplies &&
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
            counters = _addQuarantinedCounter(
              counters,
              entry,
              category: category,
            );
            canApplyNextSequence = true;
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
          counters = _addQuarantinedCounter(
            counters,
            entry,
            category: result.failureCategory ?? CloudFailureCategory.unknown,
          );
          canApplyNextSequence = true;
          break;
      }
      // A pending/deferred/retryable predecessor remains the causal barrier.
      // Do not let a later journal row mutate canonical state in this run.
      if (!canApplyNextSequence) break;
    }
    if (emitEvent) {
      _emit(
        CloudSyncEventType.inboxApplied,
        at: _clock(),
        count: counters.applied,
      );
    }
    return _InboxApplyResult(
      counters: counters,
      processedEntries: processedEntries,
    );
  }

  CloudSyncRunCounters _addQuarantinedCounter(
    CloudSyncRunCounters counters,
    CloudInboxEntry entry, {
    required CloudFailureCategory category,
  }) {
    final preflight = entry.change.preflightFailure != null;
    final tombstone = !preflight && entry.change.isTombstone;
    final preflightCode = entry.change.effectivePreflightCode;
    final unsupportedService =
        !preflight &&
        !tombstone &&
        category == CloudFailureCategory.unsupportedService;
    return counters.add(
      quarantined: 1,
      preflightQuarantined: preflight ? 1 : 0,
      preflightUnsupportedRecordType:
          preflightCode == CloudPreflightCode.unsupportedRecordType ? 1 : 0,
      preflightMalformedMetadata:
          preflightCode == CloudPreflightCode.malformedMetadata ? 1 : 0,
      preflightOversizedRecord:
          preflightCode == CloudPreflightCode.oversizedRecord ? 1 : 0,
      preflightInvalidChangeShape:
          preflightCode == CloudPreflightCode.invalidChangeShape ? 1 : 0,
      preflightUnknown: preflightCode == CloudPreflightCode.unknown ? 1 : 0,
      tombstoneQuarantined: tombstone ? 1 : 0,
      semanticUnsupportedServiceQuarantined: unsupportedService ? 1 : 0,
      semanticStageQuarantined: !preflight && !tombstone && !unsupportedService
          ? 1
          : 0,
    );
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

    // A push-only localOutbox run bypasses _pullChanges, which is otherwise
    // where the protected-store lifecycle recovers crash leftovers. Recovery
    // must therefore happen at the start of every protected native flush,
    // before either ambiguity reconciliation or write preflight can inspect
    // protected references.
    await _ensureProtectedStoreRecoveredBeforeOutboxFlush();

    final pausedCategories = await _store.readPausedOutboxFailureCategories(
      scope,
      now: _clock(),
    );
    if (pausedCategories.contains(CloudFailureCategory.authorization)) {
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

    final reconciliation = await _reconcileUnknownOutcomes(
      runNumber: runNumber,
      cancellationToken: cancellationToken,
    );
    final reconciliationCounters = reconciliation.counters;
    counters = counters.add(
      confirmed: reconciliationCounters.confirmed,
      quarantined: reconciliationCounters.quarantined,
      retried: reconciliationCounters.retried,
    );

    // Clearing an earlier submission identity is a durable decision boundary,
    // not permission to submit the operation again immediately. A later,
    // separately triggered run must make that new submission decision.
    if (reconciliation.requiresNewSubmissionDecision) return counters;

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
      var ready = preparation.ready;
      var outcomes = <String, CloudPushOutcome>{};
      if (ready.isNotEmpty) {
        await _verifyWriterPermit();
        final submissionIdentity = CloudOutboxSubmissionIdentity(
          requestUuid: _uuidFactory(),
          operationUuids: {
            for (final operation in ready)
              operation.operationId: _uuidFactory(),
          },
        );
        CloudSyncPreparedSubmission? preparedSubmission;
        List<CloudSyncProtectedWriteOperation>? protectedOperations;
        try {
          protectedOperations = List.unmodifiable(
            await _protectedWriteOperationsFor(ready),
          );
          preparedSubmission = await _withCoordinatorLeaseHeartbeat(
            () => _withWriteOperationTimeout(
              operationName: 'write_preflight',
              action: () => _writeTransport!.prepareSubmission(
                scope,
                submissionIdentity: submissionIdentity,
                operations: protectedOperations!,
              ),
            ),
          );
        } on CloudSyncFailure catch (error) {
          if (_isCoordinatorLeaseFailure(error)) rethrow;
          for (final operation in ready) {
            final transition = _transitionForFailure(operation, error);
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
          }
        } catch (_) {
          for (final operation in ready) {
            final transition = _retryOrQuarantineTransition(
              operation,
              category: CloudFailureCategory.unknown,
            );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
          }
        }

        if (preparedSubmission == null) {
          ready = const [];
        } else {
          await _verifyWriterPermit();
          // Persist the ambiguity boundary only after native authentication,
          // PCS lookup, protected payload compilation, and request creation
          // have completed without sending a remote mutation.
          ready = await _store.markOutboxSubmissionStarted(
            scope,
            leaseId: leaseId,
            submissionIdentity: submissionIdentity,
            now: _clock(),
          );
          final persistedIdentity = CloudOutboxSubmissionIdentity(
            requestUuid: ready.first.appleRequestUuid!,
            operationUuids: {
              for (final operation in ready)
                operation.operationId: operation.appleOperationUuid!,
            },
          );
          try {
            final result = await _withCoordinatorLeaseHeartbeat(
              () => _withWriteOperationTimeout(
                operationName: 'push',
                action: () async {
                  await _verifyWriterPermit();
                  return _writeTransport!.consumePreparedSubmission(
                    scope,
                    preparedSubmission: preparedSubmission!,
                    persistedIdentity: persistedIdentity,
                    protectedOperations: protectedOperations!,
                    operations: ready,
                  );
                },
              ),
            );
            await _verifyWriterPermitAfterRemote();
            outcomes = _requireExactPushOutcomes(ready, result);
          } on CloudSyncFailure catch (error) {
            if (_isCoordinatorLeaseFailure(error)) rethrow;
            for (final operation in ready) {
              outcomes[operation.operationId] = _outcomeForThrownFailure(
                operation.operationId,
              );
            }
          } catch (_) {
            for (final operation in ready) {
              outcomes[operation.operationId] = CloudPushOutcome(
                operationId: operation.operationId,
                disposition: CloudPushDisposition.unknownOutcome,
                failureCategory: CloudFailureCategory.unknown,
              );
            }
          }
        }
      }

      for (final operation in ready) {
        final outcome = outcomes[operation.operationId];
        if (outcome == null) {
          final transition = CloudOutboxTransition.unknownOutcome(
            operation.operationId,
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
            final transition = CloudOutboxTransition.unknownOutcome(
              operation.operationId,
              nextEligibleAt: _backoff.nextEligibleAt(
                now: _clock(),
                attempt: operation.attemptCount + 1,
                category: CloudFailureCategory.unknown,
                retryAfter: outcome.retryAfter,
              ),
            );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
          case CloudPushDisposition.unknownOutcome:
            final transition = CloudOutboxTransition.unknownOutcome(
              operation.operationId,
            );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
          case CloudPushDisposition.unauthorized:
            final transition = CloudOutboxTransition.provenNotAppliedPaused(
              operation.operationId,
              category: CloudFailureCategory.authorization,
              nextEligibleAt: _clock().add(config.pausedRetryDelay),
            );
            transitions.add(transition);
            counters = _countOutboxTransition(counters, transition);
            break;
          case CloudPushDisposition.pcsUnavailable:
            final transition = CloudOutboxTransition.provenNotAppliedPaused(
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
                ? CloudOutboxTransition.unknownOutcome(operation.operationId)
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
      await _acknowledgeDurableTerminalOutboxReceipts(
        operations: leased,
        transitions: transitions,
      );
      _emit(
        CloudSyncEventType.outboxFlushed,
        at: _clock(),
        count: ready.length,
      );
    }
    return counters;
  }

  Future<void> _ensureProtectedStoreRecoveredBeforeOutboxFlush() async {
    await _protectedPageLeaseLifecycle?.ensureRecoveredBeforeWrite();
  }

  Future<({CloudSyncRunCounters counters, bool requiresNewSubmissionDecision})>
  _reconcileUnknownOutcomes({
    required int runNumber,
    CloudSyncCancellationToken? cancellationToken,
  }) async {
    var counters = const CloudSyncRunCounters();
    var requiresNewSubmissionDecision = false;
    for (
      var batchIndex = 0;
      batchIndex < config.maximumOutboxBatchesPerRun &&
          !_isCancelled(cancellationToken);
      batchIndex++
    ) {
      final now = _clock();
      await _renewCoordinatorLeaseOrThrow();
      final leaseId =
          '$coordinatorId:$runNumber:reconcile:$batchIndex:'
          '${now.microsecondsSinceEpoch}';
      final operations = await _unknownOutcomeStore!.leaseUnknownOutcomes(
        scope,
        now: now,
        limit: config.maximumBatchSize,
        leaseId: leaseId,
        leaseDuration: config.outboxLeaseDuration,
      );
      if (operations.isEmpty) break;

      final transitions = <CloudOutboxTransition>[];
      for (final operation in operations) {
        CloudOutboxTransition transition;
        try {
          final resolution = await _withCoordinatorLeaseHeartbeat(
            () => _withWriteOperationTimeout(
              operationName: 'reconcile',
              action: () => _transport.reconcileUnknownOutcome(
                scope,
                operation: operation,
              ),
            ),
          );
          transition = await _transitionForUnknownResolution(
            operation,
            resolution,
          );
        } on CloudSyncFailure catch (error) {
          if (_isCoordinatorLeaseFailure(error)) rethrow;
          transition = _unresolvedUnknownTransition(operation, error);
        } catch (_) {
          transition = _unresolvedUnknownTransition(
            operation,
            CloudSyncFailure(
              category: CloudFailureCategory.unknown,
              safeCode: 'unknown_outcome_reconciliation_failed',
            ),
          );
        }
        transitions.add(transition);
        requiresNewSubmissionDecision |=
            transition.type == CloudOutboxTransitionType.retryable &&
            transition.clearSubmissionIdentity;
        counters = _countOutboxTransition(counters, transition);
      }

      await _store.applyOutboxTransitions(
        scope,
        leaseId: leaseId,
        transitions: transitions,
        now: _clock(),
      );
      await _acknowledgeDurableTerminalOutboxReceipts(
        operations: operations,
        transitions: transitions,
      );
    }
    return (
      counters: counters,
      requiresNewSubmissionDecision: requiresNewSubmissionDecision,
    );
  }

  Future<void> _acknowledgeDurableTerminalOutboxReceipts({
    required List<CloudOutboxOperation> operations,
    required List<CloudOutboxTransition> transitions,
  }) async {
    final transport = _writeTransport;
    if (transport is! CloudSyncWriteReceiptFinalizer) return;
    try {
      await (transport as CloudSyncWriteReceiptFinalizer)
          .acknowledgeDurableTerminalOperations(
            scope,
            operations: operations,
            transitions: transitions,
          );
    } catch (_) {
      // The outbox transition is already durable. A receipt leak is safe and
      // bounded recovery removes it after the terminal row leaves adoption.
    }
  }

  Future<CloudOutboxTransition> _transitionForUnknownResolution(
    CloudOutboxOperation operation,
    CloudUnknownOutcomeResolution resolution,
  ) async {
    final proofRequired = switch (resolution.disposition) {
      CloudUnknownOutcomeDisposition.committed ||
      CloudUnknownOutcomeDisposition.notApplied ||
      CloudUnknownOutcomeDisposition.serverRecordChanged => true,
      CloudUnknownOutcomeDisposition.unresolved ||
      CloudUnknownOutcomeDisposition.quarantined => false,
    };
    if (proofRequired && !(resolution.proof?.binds(operation) ?? false)) {
      return _unresolvedUnknownTransition(
        operation,
        CloudSyncFailure(
          category: CloudFailureCategory.unknown,
          safeCode: 'unknown_outcome_proof_mismatch',
        ),
      );
    }
    switch (resolution.disposition) {
      case CloudUnknownOutcomeDisposition.committed:
        return CloudOutboxTransition.confirmed(operation.operationId);
      case CloudUnknownOutcomeDisposition.notApplied:
        return CloudOutboxTransition.provenNotApplied(
          operation.operationId,
          category: CloudFailureCategory.server,
          nextEligibleAt: _clock(),
        );
      case CloudUnknownOutcomeDisposition.serverRecordChanged:
        return _resolveServerRecordChanged(operation);
      case CloudUnknownOutcomeDisposition.unresolved:
        return _unresolvedUnknownTransition(
          operation,
          CloudSyncFailure(
            category:
                resolution.failureCategory ?? CloudFailureCategory.unknown,
            retryAfter: resolution.retryAfter,
            safeCode: 'unknown_outcome_unresolved',
          ),
        );
      case CloudUnknownOutcomeDisposition.quarantined:
        final category =
            resolution.failureCategory ?? CloudFailureCategory.unknown;
        if (category == CloudFailureCategory.unknown || category.isRetryable) {
          return _unresolvedUnknownTransition(
            operation,
            CloudSyncFailure(
              category: category,
              safeCode: 'unknown_outcome_not_terminal',
            ),
          );
        }
        return CloudOutboxTransition.quarantined(
          operation.operationId,
          category: category,
        );
    }
  }

  CloudOutboxTransition _unresolvedUnknownTransition(
    CloudOutboxOperation operation,
    CloudSyncFailure error,
  ) {
    return CloudOutboxTransition.unknownOutcome(
      operation.operationId,
      nextEligibleAt: _backoff.nextEligibleAt(
        now: _clock(),
        attempt: operation.attemptCount + 1,
        category: error.category,
        retryAfter: error.retryAfter,
      ),
    );
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
          generation: operation.checkpointGeneration,
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
          await _store.upsertRecordMap(
            mapping,
            generation: operation.checkpointGeneration,
          );
        }
        await _store.attachOutboxRecordMapping(
          scope,
          leaseId: leaseId,
          operationId: operation.operationId,
          serverRecordIdHash: mapping.serverRecordIdHash,
          now: _clock(),
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

  Future<List<CloudSyncProtectedWriteOperation>> _protectedWriteOperationsFor(
    List<CloudOutboxOperation> operations,
  ) async {
    final protected = <CloudSyncProtectedWriteOperation>[];
    for (final operation in operations) {
      final mapping = await _store.readRecordMap(
        scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        generation: operation.checkpointGeneration,
      );
      if (mapping == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'write_preflight_record_mapping_missing',
        );
      }
      protected.add(
        CloudSyncProtectedWriteOperation.fromOutbox(
          operation,
          recordMapping: mapping,
        ),
      );
    }
    return protected;
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

  CloudPushOutcome _outcomeForThrownFailure(String operationId) {
    return CloudPushOutcome(
      operationId: operationId,
      disposition: CloudPushDisposition.unknownOutcome,
      failureCategory: CloudFailureCategory.unknown,
    );
  }

  Map<String, CloudPushOutcome> _requireExactPushOutcomes(
    List<CloudOutboxOperation> operations,
    CloudPushBatchResult result,
  ) {
    final expected = operations
        .map((operation) => operation.operationId)
        .toSet();
    final actual = result.outcomes.keys.toSet();
    if (expected.length != operations.length ||
        actual.length != expected.length ||
        !actual.containsAll(expected)) {
      // A missing result is ambiguous: the server may have committed the
      // operation before the response was lost. An unknown result can be
      // misattributed. Fail the complete batch closed and let later
      // reconciliation decide instead of confirming a subset.
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'push_outcome_set_mismatch',
      );
    }
    return Map<String, CloudPushOutcome>.of(result.outcomes);
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
            generation: operation.checkpointGeneration,
          );
          if (mapping == null ||
              mapping.serverRecordIdHash != resolution.serverRecordIdHash) {
            return _unresolvedUnknownTransition(
              operation,
              CloudSyncFailure(
                category: CloudFailureCategory.dependency,
                safeCode: 'server_conflict_mapping_missing',
              ),
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
            generation: operation.checkpointGeneration,
          );
          return CloudOutboxTransition.provenNotApplied(
            operation.operationId,
            category: CloudFailureCategory.conflict,
            nextEligibleAt: _clock(),
            encryptedPayloadReference: resolution.encryptedPayloadReference,
            payloadSha256: resolution.payloadSha256,
            serverRecordIdHash: resolution.serverRecordIdHash,
          );
        case CloudServerConflictDisposition.retryable:
          return _unresolvedUnknownTransition(
            operation,
            CloudSyncFailure(
              category:
                  resolution.failureCategory ?? CloudFailureCategory.network,
              retryAfter: resolution.retryAfter,
              safeCode: 'server_conflict_retryable',
            ),
          );
        case CloudServerConflictDisposition.quarantined:
          final category =
              resolution.failureCategory ?? CloudFailureCategory.unknown;
          return category == CloudFailureCategory.unknown ||
                  category.isRetryable
              ? _unresolvedUnknownTransition(
                  operation,
                  CloudSyncFailure(
                    category: category,
                    safeCode: 'server_conflict_not_terminal',
                  ),
                )
              : CloudOutboxTransition.quarantined(
                  operation.operationId,
                  category: category,
                );
      }
    } on CloudSyncFailure catch (error) {
      return error.category.isRetryable ||
              error.category == CloudFailureCategory.unknown ||
              error.category == CloudFailureCategory.authorization ||
              error.category == CloudFailureCategory.pcsUnavailable ||
              error.category == CloudFailureCategory.dependency
          ? _unresolvedUnknownTransition(operation, error)
          : CloudOutboxTransition.quarantined(
              operation.operationId,
              category: error.category,
            );
    } catch (_) {
      return _unresolvedUnknownTransition(
        operation,
        CloudSyncFailure(
          category: CloudFailureCategory.unknown,
          safeCode: 'server_conflict_reconciliation_failed',
        ),
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

  Future<T> _withCoordinatorLeaseHeartbeat<T>(
    Future<T> Function() action,
  ) async {
    await _renewCoordinatorLeaseOrThrow(force: true);
    final heartbeatInterval = Duration(
      microseconds: max(1, config.coordinatorLeaseDuration.inMicroseconds ~/ 3),
    );
    Object? renewalFailure;
    StackTrace? renewalFailureStack;
    Future<void>? renewalInFlight;
    late final Timer heartbeat;
    heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (renewalInFlight != null || renewalFailure != null) return;
      final renewal = _renewCoordinatorLeaseOrThrow(force: true);
      renewalInFlight = renewal
          .then<void>((_) {})
          .catchError((Object error, StackTrace stack) {
            renewalFailure = error;
            renewalFailureStack = stack;
          })
          .whenComplete(() {
            renewalInFlight = null;
          });
    });
    try {
      final result = await action();
      heartbeat.cancel();
      await renewalInFlight;
      final failure = renewalFailure;
      if (failure != null) {
        Error.throwWithStackTrace(failure, renewalFailureStack!);
      }
      // Covers an operation that completed before the first timer tick and
      // closes the takeover window immediately before outcome processing.
      await _renewCoordinatorLeaseOrThrow(force: true);
      return result;
    } finally {
      heartbeat.cancel();
      await renewalInFlight;
    }
  }

  Future<T> _withWriteOperationTimeout<T>({
    required String operationName,
    required Future<T> Function() action,
  }) async {
    try {
      return await action().timeout(config.writeOperationTimeout);
    } on TimeoutException {
      try {
        await _nativeOperationQuiescence!.quiesceNativeOperations();
      } catch (_) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.unknown,
          retryAfter: config.writeOperationTimeout,
          safeCode: 'cloud_sync_native_quiescence_failed',
        );
      }
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        retryAfter: config.writeOperationTimeout,
        safeCode: 'cloud_sync_${operationName}_timeout',
      );
    }
  }

  bool _isCoordinatorLeaseFailure(CloudSyncFailure error) =>
      error.safeCode == 'coordinator_lease_fence_missing' ||
      error.safeCode == 'coordinator_lease_lost';

  Future<void> _verifyWriterPermit() async {
    if (!config.flags.saves) return;
    final permit = _activeWriterPermit;
    if (permit == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'cloud_sync_writer_permit_missing',
      );
    }
    await permit.verify();
  }

  Future<void> _verifyWriterPermitAfterRemote() async {
    try {
      await _verifyWriterPermit();
    } catch (_) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.unknown,
        safeCode: 'cloud_sync_writer_post_push_verification_failed',
      );
    }
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
      CloudOutboxTransitionType.unknownOutcome => counters,
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
    this.semanticCounters = const CloudSyncRunCounters(),
    this.semanticProcessedEntries = 0,
  }) : journalUsage = journalUsage ?? CloudShadowJournalUsage.empty;

  final int fetched;
  final bool succeeded;
  final CloudFailureCategory? failureCategory;
  final CloudShadowJournalUsage journalUsage;
  final int rejectedEntries;
  final CloudShadowJournalBlockReason? journalBlockReason;
  final CloudSyncRunCounters semanticCounters;
  final int semanticProcessedEntries;
}

class _InboxApplyResult {
  const _InboxApplyResult({
    required this.counters,
    required this.processedEntries,
  });

  final CloudSyncRunCounters counters;
  final int processedEntries;
}

class _OutboxPreparation {
  const _OutboxPreparation({required this.ready, required this.transitions});

  final List<CloudOutboxOperation> ready;
  final List<CloudOutboxTransition> transitions;
}
