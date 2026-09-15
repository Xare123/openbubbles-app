import 'cloud_sync_production_preflight.dart';

/// A short-lived display cache, never authorization to start an operation.
/// Account/client/store changes invalidate it. Start must use [readFresh].
final class CloudSyncProfilePreflightCache {
  CloudSyncProfilePreflightCache({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  Object? _client;
  Object? _store;
  String? _storage;
  DateTime? _checkedAt;
  CloudSyncLocalPreflightState? _value;

  CloudSyncLocalPreflightState readForDisplay({
    required Object client,
    required Object store,
    required String storage,
    required CloudSyncLocalPreflightState Function() read,
  }) {
    final checked = _checkedAt;
    final age = checked == null ? null : _clock().difference(checked);
    if (_value != null &&
        identical(client, _client) &&
        identical(store, _store) &&
        storage == _storage &&
        age != null &&
        !age.isNegative &&
        age < const Duration(seconds: 5)) {
      return _value!;
    }
    return readFresh(
      client: client,
      store: store,
      storage: storage,
      read: read,
    );
  }

  CloudSyncLocalPreflightState readFresh({
    required Object client,
    required Object store,
    required String storage,
    required CloudSyncLocalPreflightState Function() read,
  }) {
    CloudSyncLocalPreflightState value;
    try {
      value = read();
    } catch (_) {
      value = const CloudSyncLocalPreflightState.blocked();
    }
    _client = client;
    _store = store;
    _storage = storage;
    _checkedAt = _clock();
    return _value = value;
  }
}

/// Presentation/admission for the ordinary Profile entry point. Developer Mode
/// is deliberately not an input. Build, identity, lifecycle and ownership still
/// gate the operation; this result is not a native read or writer capability.
enum CloudSyncProfileReadiness {
  ready,
  buildUnavailable,
  platformUnsupported,
  restartRequired,
  accountRequired,
  foregroundRequired,
  legacySyncActive,
  anotherOperation,
  localStateUnavailable,
  unfinishedUploads;

  static CloudSyncProfileReadiness evaluate({
    required bool featureAvailable,
    required bool platformSupported,
    required bool restartNeeded,
    required bool accountReady,
    required bool foreground,
    required bool legacyEnabledOrRunning,
    required bool operationActive,
    required bool localStateReady,
    required bool coordinatorActive,
    required bool outboxSettled,
  }) {
    if (!featureAvailable) return buildUnavailable;
    if (!platformSupported) return platformUnsupported;
    if (restartNeeded) return restartRequired;
    if (!accountReady) return accountRequired;
    if (!foreground) return foregroundRequired;
    if (legacyEnabledOrRunning) return legacySyncActive;
    if (operationActive) return anotherOperation;
    if (!localStateReady) return localStateUnavailable;
    if (coordinatorActive) return anotherOperation;
    if (!outboxSettled) return unfinishedUploads;
    return ready;
  }

  String? get message => switch (this) {
    ready => null,
    buildUnavailable => 'iCloud Message Sync is not available in this build.',
    platformUnsupported =>
      'iCloud Message Sync is not available on this device.',
    restartRequired =>
      'Close and reopen OpenBubbles before resuming. Your saved history is kept.',
    accountRequired =>
      'Finish signing in to your Apple Account before syncing.',
    foregroundRequired => 'Open OpenBubbles to start or resume history sync.',
    legacySyncActive =>
      'The existing iCloud sync is enabled. Keep using its controls below. '
          'It will not be switched or reset automatically.',
    anotherOperation =>
      'Another iCloud operation is finishing. Start / resume will become '
          'available when it is safe to continue.',
    localStateUnavailable =>
      'Saved sync status is not available yet. Wait for OpenBubbles to finish opening.',
    unfinishedUploads =>
      'Outgoing iCloud updates still need confirmation. Let them finish before '
          'starting history sync. Do not resend those messages.',
  };

  String get safeCode => switch (this) {
    ready => 'cloud_sync_profile_ready',
    buildUnavailable => 'cloud_sync_semantic_pull_disabled',
    platformUnsupported => 'unsupported_platform',
    restartRequired => 'cloud_sync_v2_pcs_restart_required',
    accountRequired => 'cloud_sync_native_auth_account_unavailable',
    foregroundRequired => 'cloud_sync_v2_pcs_ui_required',
    legacySyncActive => 'legacy_sync_active',
    anotherOperation => 'cloudkit_interlock_busy',
    localStateUnavailable => 'objectbox_not_ready',
    unfinishedUploads => 'outbox_not_settled',
  };
}
