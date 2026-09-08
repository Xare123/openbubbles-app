// ignore_for_file: prefer_initializing_formals

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloudkit_operation_interlock.dart';

/// One bounded pass over actual, confirmed local origins. The supplied drain
/// must recover existing remote outcomes and acknowledge confirmed receipts
/// before reporting that another create can be admitted. It must never infer
/// an IDS success or scan ordinary Message rows for upload candidates.
final class CloudSyncLocalSendConsumer {
  CloudSyncLocalSendConsumer({
    required this.scope,
    required CloudSyncLocalSendJournal journal,
    required Future<CloudOutboxOperation> Function(int intentId) admit,
    required CloudSyncLocalSendAuthFence authFence,
    required CloudKitOperationExclusion exclusion,
    required Future<bool> Function() drainExisting,
    DateTime Function()? clock,
  }) : _journal = journal,
       _admit = admit,
       _authFence = authFence,
       _exclusion = exclusion,
       _drainExisting = drainExisting,
       _clock = clock ?? DateTime.now {
    if (scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw ArgumentError('cloud_sync_local_send_scope_invalid');
    }
  }

  final CloudSyncScope scope;
  final CloudSyncLocalSendJournal _journal;
  final Future<CloudOutboxOperation> Function(int intentId) _admit;
  final CloudSyncLocalSendAuthFence _authFence;
  final CloudKitOperationExclusion _exclusion;
  final Future<bool> Function() _drainExisting;
  final DateTime Function() _clock;
  Future<CloudSyncLocalSendConsumerResult>? _running;
  bool _runningExact = false;

  /// Concurrent triggers join this pass, not a second native upload. The OS
  /// interlock and durable outbox leases remain the cross-process boundaries.
  Future<CloudSyncLocalSendConsumerResult> runOnce({int maximumIntents = 20}) {
    if (_runningExact) {
      throw StateError('cloud_sync_local_send_consumer_busy');
    }
    if (maximumIntents < 1 || maximumIntents > 50) {
      throw ArgumentError('cloud_sync_local_send_consumer_limit_invalid');
    }
    return _running ??= _exclusion
        .runExclusive(
          kind: CloudKitOperationKind.v2ReadWrite,
          action: () => _drain(maximumIntents),
        )
        .whenComplete(() => _running = null);
  }

  Future<CloudSyncLocalSendConsumerResult> _drain(int maximumIntents) async {
    await _validateAccount();
    if (!await _drainExisting()) {
      await _validateAccount();
      return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
    }
    final candidates = await _authFence.run(
      () => _journal.readReady(limit: maximumIntents),
      accountFingerprint: scope.accountFingerprint,
    );
    var admitted = 0;
    var deferred = 0;
    final deferredReasons = <String, int>{};
    for (final intent in candidates) {
      // Persist fair selection independently of staging. An unsupported or
      // dependency-blocked first row must not starve all later local sends.
      await _authFence.run(
        () =>
            _journal.markAdmissionConsidered(intent.id, now: _clock().toUtc()),
        accountFingerprint: scope.accountFingerprint,
      );
      try {
        await _admit(intent.id);
        admitted++;
      } catch (error) {
        // Staging may have committed to ObjectBox before native lease commit
        // failed. Never assume a throw means no durable operation exists.
        // Recheck identity, then recover before considering any other origin.
        await _validateAccount();
        deferred++;
        final code = cloudSyncV2SafeFailureCode(error);
        deferredReasons.update(code, (count) => count + 1, ifAbsent: () => 1);
      }
      await _validateAccount();
      if (!await _drainExisting()) {
        await _validateAccount();
        return CloudSyncLocalSendConsumerResult(
          admitted: admitted,
          deferred: deferred,
          outboxBlocked: true,
          deferredReasons: Map.unmodifiable(deferredReasons),
        );
      }
      await _validateAccount();
    }
    return CloudSyncLocalSendConsumerResult(
      admitted: admitted,
      deferred: deferred,
      candidateLimitReached: candidates.length == maximumIntents,
      deferredReasons: Map.unmodifiable(deferredReasons),
    );
  }

  /// Explicit one-intent pass. The production selection callback verifies the
  /// entire outbox and the pinned origin before any shared drain is entered.
  /// Never join a different running pass, scan readReady, or rotate candidates.
  Future<CloudSyncLocalSendConsumerResult> runExactIntent({
    required int intentId,
    required Future<void> Function() validateSelection,
  }) {
    if (_running != null) {
      throw StateError('cloud_sync_local_send_consumer_busy');
    }
    _runningExact = true;
    Future<void> validate() async {
      await _validateAccount();
      await validateSelection();
    }

    return _running = _exclusion
        .runExclusive(
          kind: CloudKitOperationKind.v2ReadWrite,
          action: () async {
            await validate();
            if (!await _drainExisting()) {
              await validate();
              return const CloudSyncLocalSendConsumerResult(
                outboxBlocked: true,
              );
            }
            await validate();
            final source = _journal.readForAdmission(intentId);
            if (source.admittedOperationId != null) {
              return const CloudSyncLocalSendConsumerResult();
            }
            var admitted = 0;
            var deferred = 0;
            String? deferredReason;
            try {
              await _admit(intentId);
              admitted = 1;
            } catch (error) {
              // An adopted envelope can survive native commit failure. Validate
              // its exact linkage before using the same recovery pipeline.
              deferred = 1;
              deferredReason = cloudSyncV2SafeFailureCode(error);
            }
            await validate();
            final settled = await _drainExisting();
            await validate();
            return CloudSyncLocalSendConsumerResult(
              admitted: admitted,
              deferred: deferred,
              outboxBlocked: !settled,
              deferredReasons: deferredReason == null
                  ? const {}
                  : Map.unmodifiable({deferredReason: 1}),
            );
          },
        )
        .whenComplete(() {
          _running = null;
          _runningExact = false;
        });
  }

  Future<void> _validateAccount() =>
      _authFence.run(() {}, accountFingerprint: scope.accountFingerprint);
}

final class CloudSyncLocalSendConsumerResult {
  const CloudSyncLocalSendConsumerResult({
    this.admitted = 0,
    this.deferred = 0,
    this.outboxBlocked = false,
    this.chatReadbackPending = false,
    this.candidateLimitReached = false,
    this.deferredReasons = const {},
    this.existingHistoryDiagnostics = const {},
  });

  final int admitted;
  final int deferred;
  final bool outboxBlocked;

  /// A full, completely examined batch may leave eligible origins beyond the
  /// selection limit. Continue fair rotation without no-progress backoff.
  final bool candidateLimitReached;

  /// Fixed, allowlisted codes only, aggregated per pass. Never identifiers,
  /// message text or raw exception/server content.
  final Map<String, int> deferredReasons;

  /// Fixed, content-free cause counts from the actual Chat history admission
  /// predicates. Counts are per rejected admission attempt, never row counts.
  final Map<String, int> existingHistoryDiagnostics;

  /// Queue receipts are settled, but the ordinary semantic reader still needs
  /// to project the newly created Chat before its first Message can upload.
  final bool chatReadbackPending;
}
