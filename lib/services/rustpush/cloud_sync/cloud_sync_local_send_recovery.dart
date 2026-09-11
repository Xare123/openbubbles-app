import 'cloud_sync_local_send_consumer.dart';

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

/// A new scheduling pass is allowed only after native settlement and an
/// independent check of the same account/store and a stable newer V2 owner.
/// This never converts arbitrary identity, storage or cleanup errors to retry.
Future<CloudSyncLocalSendConsumerResult> runCloudSyncLocalSendRecoveryPass({
  required Future<CloudSyncLocalSendConsumerResult> Function() action,
  required Future<void> Function() quiesce,
  required Future<bool> Function() canRefreshAfterRecovery,
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
  if (epochChanged && await canRefreshAfterRecovery()) {
    return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
  }
  Error.throwWithStackTrace(failure, failureStack!);
}
