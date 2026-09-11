import 'dart:async';

class FaceTimeOutgoingCall<T> {
  FaceTimeOutgoingCall(this.id, this.state);

  final String id;
  final T state;
  final Map<String, dynamic> metadata = {};
  bool _pending = true;
  Timer? _timer;
}

/// Owns only outgoing setup/ringing, not the connected native call.
class FaceTimeOutgoingLifecycle<T> {
  FaceTimeOutgoingLifecycle({
    Timer Function(Duration, void Function())? schedule,
  }) : _schedule = schedule ?? Timer.new;

  final Timer Function(Duration, void Function()) _schedule;
  FaceTimeOutgoingCall<T>? _current;
  FaceTimeOutgoingCall<T>? get current => _current;

  FaceTimeOutgoingCall<T>? begin(String id, T state) {
    // Do not orphan a ringing invitation by replacing its only timeout owner.
    // A terminal action has claimed its call before awaiting, so retry can start.
    if (current?._pending == true) return null;
    return _current = FaceTimeOutgoingCall(id, state);
  }

  bool isPending(FaceTimeOutgoingCall<T> call) =>
      identical(current, call) && call._pending;

  Future<bool> complete(
    FaceTimeOutgoingCall<T> call,
    Future<void> Function() action,
  ) async {
    if (!isPending(call)) return false;
    call._pending = false;
    call._timer?.cancel();
    try {
      await action();
    } finally {
      // The action can yield to a new call (including while cancellation fails).
      if (identical(current, call)) _current = null;
    }
    return true;
  }

  bool armTimeout(
    FaceTimeOutgoingCall<T> call,
    Future<void> Function() action,
  ) {
    if (!isPending(call) || call._timer != null) return false;
    call._timer = _schedule(const Duration(seconds: 30), () {
      // Recheck ownership even for a callback already queued when cancelled.
      unawaited(complete(call, action));
    });
    return true;
  }
}
