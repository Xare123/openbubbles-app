import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Local read scheduling consent, not a CloudKit credential or write capability.
final class CloudSyncBackgroundReadIdentity {
  CloudSyncBackgroundReadIdentity({
    required this.scopeHash,
    required String protectedStoreIdentity,
  }) {
    if (!_hash.hasMatch(scopeHash) ||
        !_storeIdentity.hasMatch(protectedStoreIdentity)) {
      throw StateError('cloud_sync_background_preference_identity_changed');
    }
    preferenceKey =
        'cloudSyncV2BackgroundRead.v1.${sha256.convert(utf8.encode(jsonEncode([scopeHash, protectedStoreIdentity])))}';
  }

  static final _hash = RegExp(r'^[a-f0-9]{64}$');
  static final _storeIdentity = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
  final String scopeHash;
  late final String preferenceKey;

  bool sameIdentity(CloudSyncBackgroundReadIdentity other) =>
      scopeHash == other.scopeHash && preferenceKey == other.preferenceKey;
}

final class CloudSyncBackgroundReadPreference {
  const CloudSyncBackgroundReadPreference({
    required this.identity,
    required this.enabled,
    this.explicitlyEnabled = false,
  });

  final CloudSyncBackgroundReadIdentity identity;
  final bool enabled;

  /// Server notification metadata requires saved opt-in, not a developer default.
  final bool explicitlyEnabled;
}

/// Uses injected local/native identity boundaries so persistence races can be
/// tested without an account. Existing developer qualification behavior remains
/// the default only when no account/store-specific choice has been saved.
final class CloudSyncBackgroundReadPreferences {
  CloudSyncBackgroundReadPreferences({
    required this.captureIdentity,
    required this.stillCurrent,
    required this.reload,
    required this.read,
    required this.write,
    required this.developerDefault,
  });

  final Future<CloudSyncBackgroundReadIdentity?> Function() captureIdentity;
  final bool Function() stillCurrent;
  final Future<void> Function() reload;
  final Object? Function(String) read;
  final Future<bool> Function(String, bool) write;
  final bool Function() developerDefault;

  void _validateCurrent() {
    if (!stillCurrent()) {
      throw StateError('cloud_sync_background_preference_identity_changed');
    }
  }

  Future<CloudSyncBackgroundReadPreference> load() async {
    _validateCurrent();
    final identity = await captureIdentity();
    _validateCurrent();
    if (identity == null) {
      throw StateError('cloud_sync_background_preference_unavailable');
    }
    // Headless isolates must not authorize work from a stale preferences cache.
    await reload();
    _validateCurrent();
    final revalidated = await captureIdentity();
    _validateCurrent();
    if (revalidated == null || !identity.sameIdentity(revalidated)) {
      throw StateError('cloud_sync_background_preference_identity_changed');
    }
    final stored = read(identity.preferenceKey);
    return CloudSyncBackgroundReadPreference(
      identity: identity,
      enabled: stored == null ? developerDefault() : stored == true,
      explicitlyEnabled: stored == true,
    );
  }

  Future<CloudSyncBackgroundReadPreference> setEnabled(
    CloudSyncBackgroundReadPreference expected,
    bool enabled,
  ) async {
    final current = await load();
    if (!expected.identity.sameIdentity(current.identity)) {
      throw StateError('cloud_sync_background_preference_identity_changed');
    }
    final persisted = await write(current.identity.preferenceKey, enabled);
    _validateCurrent();
    if (!persisted) {
      throw StateError('cloud_sync_background_preference_save_failed');
    }
    final saved = await load();
    if (!expected.identity.sameIdentity(saved.identity)) {
      throw StateError('cloud_sync_background_preference_identity_changed');
    }
    if (saved.enabled != enabled) {
      throw StateError('cloud_sync_background_preference_save_failed');
    }
    return saved;
  }
}
