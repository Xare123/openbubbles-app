import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_admission.dart';
import 'cloud_sync_outbound_staging.dart';
import 'objectbox_cloud_sync_store.dart';

/// One local-only exact recovery under the existing admission/store gate.
/// Dispatch requires a fresh selection and fresh Chat identity observation.
final class CloudSyncFreshGroupRecoveryCoordinator {
  const CloudSyncFreshGroupRecoveryCoordinator({
    required this.store,
    required this.transport,
    required this.ensureProtectedStoreRecovered,
    required this.verifyRecoveredReceipts,
  });

  final ObjectBoxCloudSyncStore store;
  final CloudSyncFreshGroupRecoveryStagingTransport transport;
  final Future<void> Function() ensureProtectedStoreRecovered;
  /// Strict native recovery after exact restoration and durable lease adoption.
  /// Failure preserves the adopted audit/leases and grants no remote dispatch.
  final Future<void> Function() verifyRecoveredReceipts;

  Future<CloudOutboxOperation> recover(
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
    final existing = await authFence.run(
      () => store.readRecoveredFreshGroupChat(
        scope,
        operationId: operationId,
        chatId: chatId,
        intentId: intentId,
      ),
      accountFingerprint: scope.accountFingerprint,
    );
    if (existing != null) {
      await verifyRecoveredReceipts();
      return existing;
    }
    final claim = await authFence.run(
      () => store.captureFreshGroupChatRecovery(
        scope,
        operationId: operationId,
        chatId: chatId,
        intentId: intentId,
      ),
      accountFingerprint: scope.accountFingerprint,
    );
    final stage = await transport.stageExactFreshGroupChatRecovery(
      scope,
      previous: claim.operation,
      expectedAuth: api.CloudSyncNativeAuthMetadata(
        nativeSessionId: currentAuth.nativeSessionId,
        accountFingerprint: currentAuth.accountFingerprint,
        protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      ),
      expectedChat: CloudSyncOutboundChatAdmissionCoordinator.encodeGroupOrigin(
        claim.origin,
      ),
    );
    var adopted = false;
    try {
      final operation = await authFence.run(
        () => store.adoptFreshGroupChatRecovery(
          claim: claim,
          stage: stage,
          nativeSessionId: currentAuth.nativeSessionId,
          protectedStoreIdentity: currentAuth.protectedStoreIdentity,
          now: now,
        ),
        accountFingerprint: scope.accountFingerprint,
      );
      adopted = true;
      await transport.commitOutboundLease(
        stage.leaseReference,
        stage.protectedEnvelopeReference,
      );
      await verifyRecoveredReceipts();
      return operation;
    } catch (_) {
      if (!adopted) {
        try {
          await transport.rollbackOutboundLease(stage.leaseReference);
        } catch (_) {
          // Startup recovery may reclaim an unadopted stage. Never roll back
          // the old lease or a replacement already adopted by the transaction.
        }
      }
      rethrow;
    }
  });
}
