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

String cloudSyncCanonicalRecordMapKey(
  CloudSyncScope scope,
  String logicalKey,
) =>
    'record-map:${sha256.convert(utf8.encode('${scope.storageKey}\u001frecord-map\u001f$logicalKey'))}';

/// A Chat's physical CloudKit record, independent of its canonical owner.
/// Never use this key as a create receipt or as evidence of a remote deletion.
String cloudSyncChatRecordMemberKey(
  CloudSyncScope scope,
  int generation,
  String serverRecordIdHash,
) =>
    'record-member-v1:${sha256.convert(utf8.encode('${scope.storageKey}\u001f$generation\u001f$serverRecordIdHash'))}';
