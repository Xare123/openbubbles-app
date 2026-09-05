import 'package:bluebubbles/src/rust/api/api.dart' as api;

/// A stopped retry loop is not evidence of an Apple Account logout.
class RegistrationFailureNotice {
  const RegistrationFailureNotice({
    required this.error,
    required this.retryWaitSeconds,
  });

  final String error;
  final int? retryWaitSeconds;

  bool get requiresRepair => retryWaitSeconds == null;

  String get title => requiresRepair
      ? 'iMessage registration needs attention'
      : 'Failed to renew registration';

  String get body => requiresRepair
      ? 'Sending is unavailable. Tap to review the error and repair registration.'
      : 'Sending may be unavailable while registration retries. Tap for details.';

  static const profilePayload = '-51';

  String statusText(String Function(int) formatDuration) {
    final displayError = error.replaceAll(
      'Relay device offline!',
      'Relay service unavailable!',
    );
    final retry = retryWaitSeconds;
    return retry == null
        ? 'Deregistered (repair required; error: $displayError)'
        : 'Deregistered (waiting ${formatDuration(retry)}; error: $displayError)';
  }

  factory RegistrationFailureNotice.fromState(api.RegisterState_Failed state) =>
      RegistrationFailureNotice(
        error: state.error,
        retryWaitSeconds: state.retryWait?.toInt(),
      );
}

/// Startup and live events share this non-destructive observation path.
/// Repair is a separate, user-confirmed action, never an observation.
class RegistrationStateObserver {
  RegistrationStateObserver({
    required this.onRegistered,
    required this.onRegistering,
    required this.onFailed,
  });

  final void Function(int nextSeconds) onRegistered;
  final void Function() onRegistering;
  final void Function(RegistrationFailureNotice notice) onFailed;
  bool? _lastFailureRequiresRepair;

  void accept(api.RegisterState state) {
    if (state is api.RegisterState_Registered) {
      _lastFailureRequiresRepair = null;
      onRegistered(state.nextS);
    } else if (state is api.RegisterState_Registering) {
      onRegistering();
    } else if (state is api.RegisterState_Failed) {
      final notice = RegistrationFailureNotice.fromState(state);
      // A terminal failure after a retryable failure must still notify.
      if (_lastFailureRequiresRepair == notice.requiresRepair) return;
      _lastFailureRequiresRepair = notice.requiresRepair;
      onFailed(notice);
    }
  }
}
