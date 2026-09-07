import 'cloud_sync_manual_semantic_pull_sampler.dart';
import 'cloudkit_operation_interlock.dart';

/// A read-auth window inside an already selected V2 write operation. Unlike a
/// semantic pull it accepts a queued outbox, but never fetches or applies pages.
/// All native reads finish and the pause is released before leasing/submitting.
final class CloudSyncWriteChatIdentitySession {
  const CloudSyncWriteChatIdentitySession({
    required this.exclusion,
    required this.nativePause,
    required this.validate,
    required this.ensureReadAuthentication,
    required this.warmReadAuthentication,
  });

  final CloudKitOperationExclusion exclusion;
  final CloudSyncNativeWriterPause nativePause;
  final Future<void> Function() validate;
  final Future<void> Function() ensureReadAuthentication;
  final Future<void> Function(BigInt token) warmReadAuthentication;

  Future<void> _validate() async {
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await validate();
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
  }

  Future<T> run<T>(Future<T> Function(BigInt pauseToken) observe) async {
    await _validate();
    // Refresh, if needed, before acquiring the native pause. This API takes
    // the native writer gate itself and rejects refresh while paused.
    await ensureReadAuthentication();
    await _validate();
    var pauseMayRemainActive = false;
    try {
      late final Object token;
      try {
        token = await nativePause.pause();
        pauseMayRemainActive = true;
      } on CloudSyncNativeWriterPauseUncertain {
        pauseMayRemainActive = true;
        rethrow;
      }
      late final T result;
      try {
        if (token is! BigInt || token <= BigInt.zero || token.bitLength > 64) {
          throw StateError('cloud_sync_native_auth_writer_pause_scope_failed');
        }
        await _validate();
        await warmReadAuthentication(token);
        await _validate();
        result = await observe(token);
        await _validate();
      } finally {
        await nativePause.resume(token);
        pauseMayRemainActive = false;
      }
      // A changed account/owner during release must not return usable proof.
      await _validate();
      return result;
    } finally {
      if (pauseMayRemainActive) exclusion.poisonUntilProcessRestart();
    }
  }
}
