import 'dart:async';

import 'cloud_sync_models.dart';

/// Tracks local source work and native dispatch independently of CloudKit sessions.
/// It grants no writer authority and does not replace the native store lease.
/// Account transition closes admission and joins work through native cleanup.
final class CloudSyncLocalSourceOperations {
  final Set<Future<void>> _active = {};
  bool _quiescing = false;
  bool _releaseFailed = false;
  bool _quiescenceTimedOut = false;

  bool get restartRequired => _releaseFailed || _quiescenceTimedOut;

  Future<T> run<T>({
    required void Function() validate,
    required Future<T> Function() action,
  }) {
    if (_quiescing || restartRequired) {
      return Future<T>.error(StateError('cloud_sync_local_source_quiescing'));
    }
    validate();
    // Register before action entry, including a synchronous native callback.
    final admitted = Completer<T>();
    late final Future<void> completion;
    completion = admitted.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() => _active.remove(completion));
    _active.add(completion);
    Future<T>.sync(() {
      // An identity transition can occur in the caller's first validation.
      // No entered action is cancelled or repeated by this lifetime barrier.
      if (_quiescing || restartRequired) {
        throw StateError('cloud_sync_local_source_quiescing');
      }
      validate();
      return action();
    }).then(admitted.complete, onError: admitted.completeError);
    return admitted.future;
  }

  /// Explicit native cleanup belongs inside the tracked action's finally.
  /// A completed Future is not proof that a failed native lease was released.
  Future<void> release(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _releaseFailed = true;
      _quiescing = true;
      rethrow;
    }
  }

  Future<void> quiesce() async {
    _quiescing = true;
    while (_active.isNotEmpty) {
      await Future.wait(_active.toList(growable: false));
    }
    if (restartRequired) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'cloud_sync_local_source_quiescence_failed',
      );
    }
  }

  /// A bounded teardown wait does not cancel or release its native owner.
  /// Keep admission closed and expose the unresolved lifetime to Profile.
  void markQuiescenceTimeout() {
    _quiescenceTimedOut = true;
    _quiescing = true;
  }

  /// Only a drained healthy lifetime can admit a new account generation.
  /// Callers still have to validate the exact account/client/store each time.
  bool reopen() {
    if (_active.isNotEmpty || restartRequired) return false;
    _quiescing = false;
    return true;
  }
}
