import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_message_preparation_recovery_origin.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'objectbox_cloud_sync_store.dart';

/// Recover exact local preparation authority while preserving the original
/// quarantine. This object has no save, consume, upload, send or receipt-apply
/// capability. The caller may separately prepare and release the exact DTO.
final class CloudSyncMessagePreparationRecoveryCoordinator {
  const CloudSyncMessagePreparationRecoveryCoordinator({
    required this.store,
    required this.transport,
    required this.ensureProtectedStoreRecovered,
    required this.verifyRecoveredReceipts,
    required this.onUncertainRecovery,
  });

  final ObjectBoxCloudSyncStore store;
  final CloudSyncMessagePreparationRecoveryStagingTransport transport;
  final Future<void> Function() ensureProtectedStoreRecovered;
  final Future<void> Function() verifyRecoveredReceipts;

  /// The owner must synchronously fence further operations and retain durable
  /// state for stopped-host recovery. It must never acknowledge or roll back
  /// a possibly adopted lease, retry a save, or send another IDS message.
  final void Function() onUncertainRecovery;

  Future<CloudSyncMessagePreparationRecoveryOrigin> recover(
    CloudSyncScope scope, {
    required String operationId,
    required int chatId,
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required CloudSyncLocalSendAuthFence authFence,
    required DateTime now,
  }) => transport.runOutboundAdmissionExclusive(() async {
    authFence.requireCurrentBinding(currentAuth);
    await ensureProtectedStoreRecovered();
    var origin = await authFence.run(
      () => store.readMessagePreparationRecovery(scope, operationId: operationId,
        chatId: chatId, intentId: intentId, currentAuth: currentAuth),
      accountFingerprint: scope.accountFingerprint);
    CloudSyncProtectedOutboundStageData? stage;
    // A throwing transaction/auth postcheck is not proof of non-adoption.
    var adoptionMayOwnStage = origin != null;
    try {
      if (origin == null) {
        final claim = await authFence.run(
          () => store.captureMessagePreparationRecovery(scope, operationId: operationId,
            chatId: chatId, intentId: intentId, currentAuth: currentAuth),
          accountFingerprint: scope.accountFingerprint);
        stage = await transport.stageExactMessagePreparationRecovery(scope,
          original: claim.operation,
          expectedAuth: api.CloudSyncNativeAuthMetadata(nativeSessionId: currentAuth.nativeSessionId,
            accountFingerprint: currentAuth.accountFingerprint,
            protectedStoreIdentity: currentAuth.protectedStoreIdentity));
        final fresh = stage;
        origin = await authFence.run(() {
          // Set BEFORE invoking the transaction, including its possible commit
          // and a subsequent auth-fence refusal. Uncertainty preserves ownership.
          adoptionMayOwnStage = true;
          return store.adoptMessagePreparationRecovery(claim: claim, stage: fresh,
            currentAuth: currentAuth, now: now);
        }, accountFingerprint: scope.accountFingerprint);
      }
      final adoptedOrigin = origin;
      if (adoptedOrigin == null) {
        throw StateError('cloud_sync_message_preparation_recovery_changed');
      }
      var retained = adoptedOrigin;
      authFence.requireCurrentBinding(currentAuth);
      if (retained.phase == CloudSyncMessagePreparationRecoveryPhase.adopted) {
        // Native commit is idempotent. A restart reuses this exact owner/stage,
        // never allocates another one or reconstructs the old Message lease.
        await transport.commitOutboundLease(retained.freshLeaseReference, retained.freshProtectedReference);
        authFence.requireCurrentBinding(currentAuth);
        final expected = retained;
        retained = await authFence.run(() => store.advanceMessagePreparationRecoveryPhase(scope,
          expected: expected, next: CloudSyncMessagePreparationRecoveryPhase.committed,
          currentAuth: currentAuth), accountFingerprint: scope.accountFingerprint);
      }
      await verifyRecoveredReceipts();
      authFence.requireCurrentBinding(currentAuth);
      return retained;
    } catch (_) {
      if (!adoptionMayOwnStage && stage != null) {
        try {
          await transport.rollbackOutboundLease(stage.leaseReference);
        } catch (_) {
          onUncertainRecovery();
        }
      } else if (adoptionMayOwnStage) {
        onUncertainRecovery();
      }
      rethrow;
    }
  });
}
