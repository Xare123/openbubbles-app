/// One explicit retained-session login followed by proof on the original client.
/// Authentication of a separate account object is never itself readiness.
final class CloudSyncRetainedReadAuthentication {
  bool _attempted = false;
  bool _restartRequired = false;

  bool get attempted => _attempted;
  bool get restartRequired => _restartRequired;

  Future<void> run({
    required bool Function() stillCurrent,
    required Future<(String, String)> Function() capturePersistedOwner,
    required Future<void> Function() authenticate,
    required Future<(String, String)> Function() verifyActiveOwner,
  }) async {
    void validate() {
      if (!stillCurrent()) {
        throw StateError('cloud_sync_retained_read_auth_changed');
      }
    }

    if (_attempted) {
      throw StateError('cloud_sync_retained_read_auth_consumed');
    }
    validate();
    _attempted = true;
    final owner = await capturePersistedOwner();
    validate();
    if (owner.$1.isEmpty || owner.$2.isEmpty) {
      throw StateError('cloud_sync_retained_read_auth_changed');
    }
    try {
      // Login can advance native admission generations even when it fails.
      // Keep any subsequent failure fenced until this owned host is closed.
      await authenticate();
      validate();
      final verified = await verifyActiveOwner();
      validate();
      if (verified != owner) {
        throw StateError('cloud_sync_retained_read_auth_changed');
      }
    } catch (_) {
      _restartRequired = true;
      rethrow;
    }
  }
}
