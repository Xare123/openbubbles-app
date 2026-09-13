import 'dart:async';

/// A deadline is not native cancellation. Keep the caller's interlock and
/// in-flight ownership until the native operation actually settles, then report
/// the timeout. Never retry a possibly submitted clique join on that timeout.
Future<T> awaitCloudSyncPcsOperation<T>(
  Future<T> operation,
  Duration deadline,
) async {
  try {
    return await operation.timeout(deadline);
  } on TimeoutException {
    try {
      await operation;
    } catch (_) {
      // The deadline remains the caller's result, not arbitrary native text.
    }
    rethrow;
  }
}
