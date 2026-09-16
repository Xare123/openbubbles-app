import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:flutter/widgets.dart';

/// Failure recovery copy, double-tap gate, and owned-dialog tracker for
/// edit/unsend UI.
///
/// Feedback strings stay content-free and actionable. Classification reuses
/// [cloudSyncV2SafeFailureCode], the existing Cloud Sync V2 convention, so
/// `cloudkit_interlock_busy` maps to a "busy" message and everything else
/// collapses to a generic message. Copy never claims a mutation was (or was
/// not) dispatched: a generic failure can surface after dispatch, so titles
/// say "not confirmed" and every message advises checking the latest
/// message status before retrying. No retry, no resend, no IDS-only fallback
/// here; the caller only reports and keeps state safe.
class MutationUiGate {
  bool _busy = false;

  bool get isBusy => _busy;

  /// Returns false when an attempt is already in flight (double-tap).
  bool tryAcquire() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  /// Always call in `finally` so failure releases the UI for retry.
  /// Plain field write: safe even after widget disposal (no setState).
  void release() {
    _busy = false;
  }
}

/// Allowlisted diagnostic code for logs. Never message content.
String mutationSafeCode(Object error) => cloudSyncV2SafeFailureCode(error);

/// True only for an active-sync busy failure.
bool isMutationBusy(Object error) =>
    cloudSyncV2SafeFailureCode(error) == 'cloudkit_interlock_busy';

/// Content-free, actionable snackbar copy. Busy and generic stay distinct.
/// Edit copy keeps the draft. Unsend copy keeps the original untouched on
/// screen; it never claims the remote message was (or was not) removed.
/// Callers show this on failure only; success is signaled by the updated
/// message itself.
MutationFailureFeedback mutationFailureFeedback(
  Object error, {
  required bool isEdit,
}) {
  if (isMutationBusy(error)) {
    if (isEdit) {
      return const MutationFailureFeedback(
        'Edit not confirmed',
        'Another iCloud operation blocked completion. Your edit draft was kept. Check the latest message status before retrying.',
      );
    }
    return const MutationFailureFeedback(
      'Unsend not confirmed',
      'Another iCloud operation blocked completion. Check the latest message status before retrying.',
    );
  }
  if (isEdit) {
    return const MutationFailureFeedback(
      'Edit not confirmed',
      'The edit outcome is unknown. Your draft was kept. Check the latest message status before retrying.',
    );
  }
  return const MutationFailureFeedback(
    'Unsend not confirmed',
    'The unsend outcome is unknown. Check the latest message status before retrying.',
  );
}

class MutationFailureFeedback {
  final String title;
  final String message;
  const MutationFailureFeedback(this.title, this.message);
}

/// Tracks one owned dialog route so failure cleanup removes only that route.
///
/// Capture inside the dialog builder with the dialog's own [BuildContext];
/// [close] then removes exactly the captured route while it is still
/// attached. It never touches the (possibly disposed) widget context, so it
/// is safe to call after disposal, and an unrelated route pushed above or
/// below is left alone. Use a fresh instance for each dialog. A close requested
/// before the first build is latched and applied after that build, when it is
/// safe to change the navigator.
class OwnedDialog {
  ModalRoute<dynamic>? _route;
  NavigatorState? _navigator;
  bool _closeRequested = false;

  bool get isArmed => _route != null;

  void capture(BuildContext dialogContext) {
    _route ??= ModalRoute.of(dialogContext);
    _navigator ??= Navigator.of(dialogContext);
    if (_closeRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
    }
  }

  void close() {
    _closeRequested = true;
    final route = _route;
    final navigator = _navigator;
    _route = null;
    _navigator = null;
    if (route == null ||
        navigator == null ||
        !navigator.mounted ||
        !route.isActive ||
        route.navigator != navigator) {
      return;
    }
    // Exact removal also handles a still-entering dialog and never pops a
    // newer route. No user-dismissal/back-stack inference is needed.
    navigator.removeRoute(route);
  }
}
