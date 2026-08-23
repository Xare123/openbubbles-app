import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cloud_sync_models.dart';

/// Builds deterministic operation IDs without placing raw entity identifiers
/// or payloads in the outbox key.
abstract final class CloudOperationIdentity {
  /// Stable identity for the one initial create of a logical cloud entity.
  /// Retries and crash recovery must find this same row before allocating a
  /// new mutation revision or CloudKit record name.
  static String forInitialCreate({
    required CloudSyncScope scope,
    required String logicalEntityKeyHash,
    required int payloadVersion,
  }) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError.value(logicalEntityKeyHash, 'logicalEntityKeyHash');
    }
    if (payloadVersion <= 0) {
      throw ArgumentError.value(payloadVersion, 'payloadVersion');
    }
    final canonical = [
      'cloud-sync-initial-create-v1',
      scope.storageKey,
      logicalEntityKeyHash,
      CloudOutboxAction.save.name,
      payloadVersion.toString(),
    ].join('\u001f');
    return 'op1:${sha256.convert(utf8.encode(canonical))}';
  }

  static String forMutation({
    required CloudSyncScope scope,
    required String logicalEntityKeyHash,
    required CloudOutboxAction action,
    required int payloadVersion,
    required int mutationRevision,
    String? payloadSha256,
  }) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError.value(
        logicalEntityKeyHash,
        'logicalEntityKeyHash',
        'must be a non-empty one-way digest',
      );
    }
    if (payloadVersion <= 0) {
      throw ArgumentError.value(payloadVersion, 'payloadVersion');
    }
    if (action == CloudOutboxAction.save &&
        (payloadSha256 == null || payloadSha256.isEmpty)) {
      throw ArgumentError.value(
        payloadSha256,
        'payloadSha256',
        'save operations require a protected payload digest',
      );
    }
    if (mutationRevision < 0) {
      throw ArgumentError.value(mutationRevision, 'mutationRevision');
    }

    final canonical = [
      'cloud-sync-operation-v1',
      scope.storageKey,
      logicalEntityKeyHash,
      action.name,
      payloadVersion.toString(),
      mutationRevision.toString(),
      payloadSha256 ?? 'tombstone',
    ].join('\u001f');
    return 'op1:${sha256.convert(utf8.encode(canonical))}';
  }
}
