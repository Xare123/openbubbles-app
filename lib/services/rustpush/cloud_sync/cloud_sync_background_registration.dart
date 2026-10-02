import 'cloud_sync_background_read_preference.dart';

enum CloudSyncBackgroundRegistrationOutcome {
  registered,
  disabled,
  rejected,
  unavailable,
  stale,
}

/// Fences asynchronous scheduling results, not CloudKit operations or consent.
/// Native durable scheduling and the reader's identity/lease checks still own
/// those boundaries. A newer configure/disable invalidates every older reply.
final class CloudSyncBackgroundRegistration {
  int _operation = 0;
  bool _registered = false;
  bool _locallyRegistered = false;

  bool get registered => _registered;

  /// Local metadata wakes remain usable while server notification setup retries.
  bool get locallyRegistered => _locallyRegistered;

  void invalidate() {
    _begin();
  }

  int _begin() {
    _registered = false;
    _locallyRegistered = false;
    return ++_operation;
  }

  bool _current(int operation, bool Function() stillCurrent) {
    if (operation != _operation) return false;
    try {
      return stillCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<CloudSyncBackgroundRegistrationOutcome> configure({
    required CloudSyncBackgroundReadPreferences preferences,
    required Future<bool> Function(String scopeHash) configureNative,
    required Future<bool> Function() disableNative,
    Future<bool> Function(
      CloudSyncBackgroundReadPreference preference,
      bool Function() stillCurrent,
    )?
    prepareNotifications,
  }) async {
    final operation = _begin();
    try {
      final preference = await preferences.load();
      if (!_current(operation, preferences.stillCurrent)) {
        return CloudSyncBackgroundRegistrationOutcome.stale;
      }
      final accepted = preference.enabled
          ? await configureNative(preference.identity.scopeHash)
          : await disableNative();
      if (!_current(operation, preferences.stillCurrent)) {
        return CloudSyncBackgroundRegistrationOutcome.stale;
      }
      if (!accepted) return CloudSyncBackgroundRegistrationOutcome.rejected;
      _locallyRegistered = preference.enabled;
      if (preference.enabled && prepareNotifications != null) {
        final ready = await prepareNotifications(
          preference,
          () => _current(operation, preferences.stillCurrent),
        );
        if (!_current(operation, preferences.stillCurrent)) {
          return CloudSyncBackgroundRegistrationOutcome.stale;
        }
        if (!ready) return CloudSyncBackgroundRegistrationOutcome.unavailable;
      }
      _registered = preference.enabled;
      return preference.enabled
          ? CloudSyncBackgroundRegistrationOutcome.registered
          : CloudSyncBackgroundRegistrationOutcome.disabled;
    } catch (_) {
      return _current(operation, preferences.stillCurrent)
          ? CloudSyncBackgroundRegistrationOutcome.unavailable
          : CloudSyncBackgroundRegistrationOutcome.stale;
    }
  }

  Future<CloudSyncBackgroundRegistrationOutcome> disable({
    required Future<bool> Function() disableNative,
  }) async {
    final operation = _begin();
    try {
      final accepted = await disableNative();
      if (operation != _operation) {
        return CloudSyncBackgroundRegistrationOutcome.stale;
      }
      return accepted
          ? CloudSyncBackgroundRegistrationOutcome.disabled
          : CloudSyncBackgroundRegistrationOutcome.rejected;
    } catch (_) {
      return operation == _operation
          ? CloudSyncBackgroundRegistrationOutcome.unavailable
          : CloudSyncBackgroundRegistrationOutcome.stale;
    }
  }
}
