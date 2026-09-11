import 'cloud_sync_local_send_consumer.dart';
import 'cloudkit_writer_authority.dart';

/// Receipt verification advanced the owner. The current pass cannot reuse its
/// old journal, transport or authority fence for another submission.
final class CloudSyncLocalSendRecoveredEpoch implements Exception {
  const CloudSyncLocalSendRecoveredEpoch();
}

/// Runs before record-queue admission, including when the outbox is empty.
/// Null means no byte fence, false means an exact upload is still unresolved.
/// A verified clearance ends the pass instead of granting it new authority.
Future<bool> recoverCloudSyncLocalSendUploadFence({
  required Future<void> Function() recoverProtectedStore,
  required Future<bool?> Function() reconcileUpload,
}) async {
  await recoverProtectedStore();
  final result = await reconcileUpload();
  if (result == true) throw const CloudSyncLocalSendRecoveredEpoch();
  return result == null;
}

/// After native settlement, scheduling requires either a stable recovered
/// owner or the guard's exact pending-upload proof for a receipt-only next pass.
/// Both callbacks must independently retain the same account/store context.
/// This never converts arbitrary identity, storage or cleanup errors to retry.
Future<CloudSyncLocalSendConsumerResult> runCloudSyncLocalSendRecoveryPass({
  required Future<CloudSyncLocalSendConsumerResult> Function() action,
  required Future<void> Function() quiesce,
  required Future<bool> Function() canRefreshAfterRecovery,
  Future<bool> Function()? canSchedulePendingUploadRecovery,
}) async {
  Object? failure;
  StackTrace? failureStack;
  CloudSyncLocalSendConsumerResult? result;
  try {
    result = await action();
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
  } finally {
    // Cleanup errors take precedence: a settled pass with a retained native
    // owner must never schedule another writer.
    await quiesce();
  }
  if (failure == null) return result!;
  final epochChanged =
      failure is CloudSyncLocalSendRecoveredEpoch ||
      (failure is StateError &&
          const {
            'cloud_sync_local_send_identity_changed',
            'cloud_sync_local_send_owner_changed',
          }.contains(failure.message));
  // A newly ambiguous byte upload keeps its E fence and unknown E+1 owner.
  // Only the guard's exact pass-local proof may schedule a receipt-first NEXT
  // invocation. Do not apply the stable-owner refresh check to this state.
  final newUnknown =
      failure is CloudKitWriterAuthorityFailure &&
      failure.safeCode == 'cloudkit_writer_mutation_outcome_unknown';
  if ((epochChanged || newUnknown) &&
      canSchedulePendingUploadRecovery != null &&
      await canSchedulePendingUploadRecovery()) {
    return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
  }
  if (epochChanged && await canRefreshAfterRecovery()) {
    return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
  }
  Error.throwWithStackTrace(failure, failureStack!);
}
