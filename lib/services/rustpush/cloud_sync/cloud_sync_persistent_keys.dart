import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cloud_sync_models.dart';

/// Canonical durable key for a Cloud Sync scope.
///
/// Keep every ObjectBox producer and query on this helper. Comparing a raw
/// [CloudSyncScope.storageKey] with the persisted digest silently misses the
/// same scope.
String cloudSyncPersistentScopeKey(CloudSyncScope scope) =>
    'scope2:${sha256.convert(utf8.encode(scope.storageKey))}';
