// ignore_for_file: prefer_initializing_formals

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_models.dart';
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

  /// Concurrent triggers join this pass, not a second native upload. The OS
  /// interlock and durable outbox leases remain the cross-process boundaries.
  Future<CloudSyncLocalSendConsumerResult> runOnce({int maximumIntents = 20}) {
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
      } catch (_) {
        // Staging may have committed to ObjectBox before native lease commit
        // failed. Never assume a throw means no durable operation exists.
        // Recheck identity, then recover before considering any other origin.
        await _validateAccount();
        deferred++;
      }
      await _validateAccount();
      if (!await _drainExisting()) {
        await _validateAccount();
        return CloudSyncLocalSendConsumerResult(
          admitted: admitted,
          deferred: deferred,
          outboxBlocked: true,
        );
      }
      await _validateAccount();
    }
    return CloudSyncLocalSendConsumerResult(
      admitted: admitted,
      deferred: deferred,
    );
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
  });

  final int admitted;
  final int deferred;
  final bool outboxBlocked;
  /// Queue receipts are settled, but the ordinary semantic reader still needs
  /// to project the newly created Chat before its first Message can upload.
  final bool chatReadbackPending;
}
