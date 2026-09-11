import 'dart:async';

enum FaceTimeOutgoingPhase {
  started,
  link_before,
  link_after,
  handles_before,
  handles_after,
  create_before,
  create_after,
  timer_before,
  timer_armed,
  timer_skipped,
  rejected,
  terminal_cleanup,
  terminal_released,
}

class FaceTimeOutgoingCall<T> {
  FaceTimeOutgoingCall(this.id, this.state);

  final String id;
  final T state;
  final Map<String, dynamic> metadata = {};
  bool _pending = true;
  Timer? _timer;
  int _diagnosticAttempt = 0;
  FaceTimeOutgoingPhase _diagnosticPhase = FaceTimeOutgoingPhase.started;
  final _diagnosticEvents = <FaceTimeOutgoingPhase>{};
}

/// Owns only outgoing setup/ringing, not the connected native call.
class FaceTimeOutgoingLifecycle<T> {
  FaceTimeOutgoingLifecycle({
    Timer Function(Duration, void Function())? schedule,
    void Function(int, FaceTimeOutgoingPhase, FaceTimeOutgoingPhase)? diagnostic,
  }) : _schedule = schedule ?? Timer.new,
       _diagnostic = diagnostic;

  final Timer Function(Duration, void Function()) _schedule;
  final void Function(int, FaceTimeOutgoingPhase, FaceTimeOutgoingPhase)?
      _diagnostic;
  int _diagnosticAttempt = 0;
  FaceTimeOutgoingCall<T>? _current;
  FaceTimeOutgoingCall<T>? get current => _current;

  FaceTimeOutgoingCall<T>? begin(String id, T state) {
    // Do not orphan a ringing invitation by replacing its only timeout owner.
    // A terminal action has claimed its call before awaiting, so retry can start.
    if (current?._pending == true) {
      observe(current!, FaceTimeOutgoingPhase.rejected);
      return null;
    }
    final call = _current = FaceTimeOutgoingCall(id, state);
    // Process-local ordinal only, never derived from a call/account identifier.
    _diagnosticAttempt = (_diagnosticAttempt % 0x7fffffff) + 1;
    call._diagnosticAttempt = _diagnosticAttempt;
    observe(call, FaceTimeOutgoingPhase.started);
    return call;
  }

  // At most one marker per finite event per ticket, including rejected retries.
  // Late setup completions report their event without overwriting terminal phase.
  void observe(FaceTimeOutgoingCall<T> call, FaceTimeOutgoingPhase event) {
    if (_diagnostic == null) return;
    if (event != FaceTimeOutgoingPhase.rejected &&
        (call._pending ||
            event == FaceTimeOutgoingPhase.terminal_cleanup ||
            event == FaceTimeOutgoingPhase.terminal_released)) {
      call._diagnosticPhase = event;
    }
    if (!call._diagnosticEvents.add(event)) return;
    try {
      _diagnostic(call._diagnosticAttempt, event, call._diagnosticPhase);
    } catch (_) {
      // Diagnostic failure must never change call handling or expose errors.
    }
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
    observe(call, FaceTimeOutgoingPhase.terminal_cleanup);
    try {
      await action();
    } finally {
      // The action can yield to a new call (including while cancellation fails).
      if (identical(current, call)) _current = null;
      observe(call, FaceTimeOutgoingPhase.terminal_released);
    }
    return true;
  }

  bool armTimeout(
    FaceTimeOutgoingCall<T> call,
    Future<void> Function() action,
  ) {
    observe(call, FaceTimeOutgoingPhase.timer_before);
    if (!isPending(call) || call._timer != null) {
      observe(call, FaceTimeOutgoingPhase.timer_skipped);
      return false;
    }
    call._timer = _schedule(const Duration(seconds: 30), () {
      // Recheck ownership even for a callback already queued when cancelled.
      unawaited(complete(call, action));
    });
    observe(call, FaceTimeOutgoingPhase.timer_armed);
    return true;
  }
}
