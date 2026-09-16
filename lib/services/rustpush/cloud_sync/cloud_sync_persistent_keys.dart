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

/// Matches the durable journal's original key format. Generation one keeps
/// its historical key; a reset starts a distinct namespace without rewriting
/// or accepting evidence from older generations. Producers and readers must
/// use the same calculation, including repair and attachment resolution.
String cloudSyncPersistentChangeKey(
  CloudSyncScope scope,
  int generation,
  String changeId,
) {
  if (generation < 1) throw ArgumentError.value(generation, 'generation');
  final purpose = generation == 1 ? 'change' : 'change-generation-$generation';
  return '$purpose:${sha256.convert(utf8.encode('${scope.storageKey}\u001f$purpose\u001f$changeId'))}';
}

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
