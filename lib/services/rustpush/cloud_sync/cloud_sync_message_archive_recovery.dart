import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_message_archive_recovery_binding.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'objectbox_cloud_sync_store.dart';

/// Local ownership handoff only. The existing lease is verified, never staged,
/// committed, acknowledged or consumed here. The normal writer later performs
/// fresh conditional preparation and persists its submission boundary.
final class CloudSyncMessageArchiveRecoveryCoordinator {
  const CloudSyncMessageArchiveRecoveryCoordinator({
    required this.store, required this.transport,
    required this.ensureProtectedStoreRecovered,
    required this.verifyRecoveredReceipts,
    required this.onUncertainRecovery,
  });

  final ObjectBoxCloudSyncStore store;
  final CloudSyncMessagePreparationRecoveryStagingTransport transport;
  final Future<void> Function() ensureProtectedStoreRecovered;
  final Future<void> Function() verifyRecoveredReceipts;
  final void Function() onUncertainRecovery;

  Future<CloudOutboxOperation> recover(CloudSyncScope scope, {
    required String operationId, required int chatId, required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required CloudSyncLocalSendAuthFence authFence,
    required DateTime now,
  }) => transport.runOutboundAdmissionExclusive(() async {
    authFence.requireCurrentBinding(currentAuth);
    await ensureProtectedStoreRecovered();
    final existing = await authFence.run(() => store.readRecoveredMessageArchive(scope,
      operationId: operationId, chatId: chatId, intentId: intentId, currentAuth: currentAuth),
      accountFingerprint: scope.accountFingerprint);
    if (existing != null) {
      await verifyRecoveredReceipts();
      authFence.requireCurrentBinding(currentAuth);
      return existing;
    }
    final claim = await authFence.run(() => store.captureMessageArchiveRecovery(scope,
      operationId: operationId, chatId: chatId, intentId: intentId, currentAuth: currentAuth),
      accountFingerprint: scope.accountFingerprint);
    // A parsed phase is not proof that a native committed receipt exists.
    await verifyRecoveredReceipts();
    authFence.requireCurrentBinding(currentAuth);
    var transferMayHaveCommitted = false;
    try {
      final operation = await authFence.run(() {
        transferMayHaveCommitted = true;
        return store.adoptMessageArchiveRecovery(claim: claim, currentAuth: currentAuth, now: now);
      }, accountFingerprint: scope.accountFingerprint);
      await verifyRecoveredReceipts();
      authFence.requireCurrentBinding(currentAuth);
      if (operation.operationId != claim.operation.operationId) {
        throw StateError(messageArchiveRecoveryChangedCode);
      }
      return operation;
    } catch (_) {
      if (transferMayHaveCommitted) onUncertainRecovery();
      rethrow; // No rollback/receipt acknowledgement after uncertain transfer.
    }
  });
}
