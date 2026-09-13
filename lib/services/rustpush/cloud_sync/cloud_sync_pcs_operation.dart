import 'dart:async';

class CloudSyncPcsRestartRequired extends StateError {
  CloudSyncPcsRestartRequired() : super('cloud_sync_v2_pcs_restart_required');
}

/// A deadline is not native cancellation. Bound caller feedback, but retain
/// exclusion until process restart. Late native completion must not continue
/// preparation, retry a join, or release the poisoned lock.
Future<T> awaitCloudSyncPcsOperation<T>(
  Future<T> operation,
  Duration deadline, {
  required void Function() poisonUntilProcessRestart,
}) async {
  try {
    return await operation.timeout(deadline);
  } on TimeoutException {
    poisonUntilProcessRestart();
    // Future.timeout observes late errors without propagating their contents.
    throw CloudSyncPcsRestartRequired();
  }
}
