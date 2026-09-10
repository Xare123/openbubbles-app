import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:crypto/crypto.dart';

/// Wire outcomes understood by Android's bounded WorkManager adapter.
///
/// These values intentionally carry no account, record, chat, or error data.
enum CloudSyncAndroidBackgroundOutcome {
  complete,
  retry,
  stale;

  String get wireValue => name;
}

/// Pure identity and classification policy for the Android read-only wake.
abstract final class CloudSyncAndroidBackgroundPolicy {
  static final RegExp _scopeHashPattern = RegExp(r'^[a-f0-9]{64}$');

  static const String metadataWorkKind = 'METADATA';

  static CloudSyncScope semanticMessageScope(String accountFingerprint) =>
      CloudSyncScope(
        accountFingerprint: accountFingerprint,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: 2,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );

  static String scopeHash(CloudSyncScope scope) =>
      sha256.convert(utf8.encode(scope.storageKey)).toString();

  static bool isCanonicalScopeHash(Object? value) =>
      value is String && _scopeHashPattern.hasMatch(value);

  static bool isSupportedWorkKind(Object? value) => value == metadataWorkKind;

  /// Identity/gate replacement is terminal for this durable wake. Everything
  /// else is retried only within Android's bounded attempt budget.
  static CloudSyncAndroidBackgroundOutcome classifyFailure(Object error) {
    final value = error.toString();
    const staleCodes = <String>{
      'cloud_sync_android_background_disabled',
      'cloud_sync_android_background_scope_mismatch',
      'cloud_sync_android_background_work_kind_invalid',
      'cloud_sync_canary_package_required',
      'cloud_sync_developer_mode_required',
      'cloud_sync_native_auth_account_changed',
      'cloud_sync_semantic_pull_disabled',
    };
    for (final code in staleCodes) {
      if (value.contains(code)) {
        return CloudSyncAndroidBackgroundOutcome.stale;
      }
    }
    return CloudSyncAndroidBackgroundOutcome.retry;
  }
}
