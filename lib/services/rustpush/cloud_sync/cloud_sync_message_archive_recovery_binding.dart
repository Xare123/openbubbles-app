import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_fresh_group_recovery_snapshot.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_message_archive_recovery_origin.dart';
import 'cloud_sync_message_preparation_recovery_binding.dart';
import 'cloud_sync_message_preparation_recovery_origin.dart';
import 'cloud_sync_models.dart';

const messageArchiveRecoveryChangedCode = 'cloud_sync_message_archive_recovery_changed';

/// Frozen read set, never write or native-lease authority. The journal must
/// authenticate the retained preparation owner and current source separately.
final class CloudSyncMessageArchiveRecoveryClaim {
  CloudSyncMessageArchiveRecoveryClaim({
    required this.operation,
    required this.preparation,
    required Map<String, Object?> operationSnapshot,
    required Map<String, Object?> recordMapSnapshot,
    required Map<String, Object?> sourceSnapshot,
  }) : operationSnapshot = Map.unmodifiable(operationSnapshot),
       recordMapSnapshot = Map.unmodifiable(recordMapSnapshot),
       sourceSnapshot = Map.unmodifiable(sourceSnapshot) {
    final original = validateMessagePreparationRecoveryReceipt(preparation);
    if (preparation.phase != CloudSyncMessagePreparationRecoveryPhase.retained ||
        !operation.sameDurableSnapshotAs(original) ||
        !_same(this.operationSnapshot, preparation.operation) ||
        !_same(this.recordMapSnapshot, preparation.recordMap) ||
        this.sourceSnapshot['admittedChatBinding'] != preparation.encode()) {
      _reject();
    }
    final expected = Map<String, Object?>.of(preparation.source)
      ..['admittedChatBinding'] = preparation.encode()
      ..['admittedBindingSha256'] = this.sourceSnapshot['admittedBindingSha256'];
    if (!_same(expected, this.sourceSnapshot)) _reject();
  }

  final CloudOutboxOperation operation;
  final CloudSyncMessagePreparationRecoveryOrigin preparation;
  final Map<String, Object?> operationSnapshot;
  final Map<String, Object?> recordMapSnapshot;
  final Map<String, Object?> sourceSnapshot;
  int get chatId => preparation.binding['chatId']! as int;
  int get intentId => preparation.binding['intentId']! as int;

  @override
  String toString() => 'CloudSyncMessageArchiveRecoveryClaim(redacted)';
}

Map<String, Object?> messageArchiveRecoveryBuildReceipt({
  required CloudSyncMessageArchiveRecoveryClaim claim,
  required CloudSyncNativeAuthSnapshot currentAuth,
  required int writerEpoch,
  required int ownershipEpoch,
  required String ownershipSnapshotSha256,
  required DateTime now,
}) {
  if (currentAuth.accountFingerprint != claim.operation.scope.accountFingerprint ||
      currentAuth.protectedStoreIdentity != claim.preparation.binding['protectedStoreIdentity'] ||
      !now.isUtc || now.millisecondsSinceEpoch <
          (claim.preparation.binding['recoveredAtMs']! as int)) {
    _reject();
  }
  return CloudSyncMessageArchiveRecoveryOrigin.create(
    preparationBinding: claim.preparation.encode(),
    receipt: {
      'schema': 1,
      'reason': 'message-archive-recovery-v1',
      'mode': 'normal-archive-handoff',
      'preparationSha256': sha256.convert(utf8.encode(claim.preparation.encode())).toString(),
      'operation': claim.operationSnapshot,
      'recordMap': claim.recordMapSnapshot,
      'source': claim.sourceSnapshot,
      'binding': {
        'scopeKey': claim.operationSnapshot['scopeKey'],
        'accountFingerprint': currentAuth.accountFingerprint,
        'checkpointGeneration': claim.operation.checkpointGeneration,
        'chatId': claim.chatId,
        'intentId': claim.intentId,
        'localMessageId': claim.sourceSnapshot['localMessageId'],
        'nativeSessionId': currentAuth.nativeSessionId,
        'protectedStoreIdentity': currentAuth.protectedStoreIdentity,
        'writerEpoch': writerEpoch,
        'ownershipEpoch': ownershipEpoch,
        'ownershipSnapshotSha256': ownershipSnapshotSha256,
        'activatedAtMs': now.millisecondsSinceEpoch,
      },
    },
  ).receipt;
}

/// Validate immutable recovery identity while allowing normal outbox lease,
/// submission, confirmation, retry, and record-readback fields to advance.
/// The journal independently checks the normal adoption digest and authority.
void validateMessageArchiveRecoveryCurrentState({
  required CloudSyncMessageArchiveRecoveryOrigin origin,
  required CloudOutboxOperationEntity operation,
  required CloudRecordMapEntity mapping,
  required CloudSyncLocalSendIntentEntity intent,
}) {
  validateMessageArchiveRecoveryOperationAndSource(origin: origin,
    operation: operation, intent: intent);
  final released = operation.protectedLeaseReference == null;
  final map = freshGroupRecoveryMapSnapshot(mapping);
  for (final key in ['id', 'mapKey', 'scopeKey', 'accountFingerprint', 'zone',
      'logicalEntityKeyHash', 'serverRecordIdHash', 'generation']) {
    if (map[key] != origin.recordMap[key]) _reject();
  }
  if (!RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$').hasMatch(mapping.encryptedServerRecordId) ||
      (!released && mapping.encryptedServerRecordId != origin.preparation.freshProtectedReference)) {
    _reject();
  }
}

void validateMessageArchiveRecoveryOperationAndSource({
  required CloudSyncMessageArchiveRecoveryOrigin origin,
  required CloudOutboxOperationEntity operation,
  required CloudSyncLocalSendIntentEntity intent,
}) {
  final preparation = origin.preparation;
  validateMessagePreparationRecoveryReceipt(preparation);
  final row = freshGroupRecoveryOperationSnapshot(operation);
  const mutable = {
    'state', 'attemptCount', 'nextEligibleAtMs', 'lastErrorCategory',
    'leaseIdHash', 'leaseExpiresAtMs', 'confirmedAtMs', 'updatedAtMs',
    'appleRequestUuid', 'appleOperationUuid', 'protectedLeaseReference',
    'encryptedPayloadRef',
  };
  for (final entry in origin.operation.entries) {
    if (!mutable.contains(entry.key) && row[entry.key] != entry.value) _reject();
  }
  if (operation.encryptedPayloadRef != preparation.freshProtectedReference ||
      operation.localChatOrigin != null || operation.state < 0 ||
      operation.state >= CloudOutboxStatus.values.length ||
      operation.attemptCount < (origin.operation['attemptCount']! as int) ||
      operation.updatedAtMs < (origin.binding['activatedAtMs']! as int) ||
      operation.nextEligibleAtMs < 0 || operation.leaseExpiresAtMs < 0 ||
      (operation.appleRequestUuid == null) != (operation.appleOperationUuid == null) ||
      (operation.protectedLeaseReference != null &&
        operation.protectedLeaseReference != preparation.freshLeaseReference)) {
    _reject();
  }
  final source = freshGroupRecoverySourceSnapshot(intent);
  final expectedSource = Map<String, Object?>.of(origin.source)
    ..['admittedChatBinding'] = origin.encode()
    ..['admittedBindingSha256'] = intent.admittedBindingSha256
    ..['confirmedReadbackBindingSha256'] = intent.confirmedReadbackBindingSha256;
  if (!_same(source, expectedSource) ||
      intent.admittedBindingSha256 == null ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(intent.admittedBindingSha256!)) {
    _reject();
  }
  final released = operation.protectedLeaseReference == null;
  if (released &&
      (operation.state != CloudOutboxStatus.confirmed.index ||
       operation.appleRequestUuid == null || operation.confirmedAtMs <= 0 ||
       operation.lastErrorCategory != null || operation.nextEligibleAtMs != 0 ||
       operation.leaseIdHash != null || operation.leaseExpiresAtMs != 0 ||
       intent.confirmedReadbackBindingSha256 != intent.admittedBindingSha256)) {
    _reject();
  }
  if (!released && intent.confirmedReadbackBindingSha256 != null) _reject();
}

/// Recovery history owns its original/fresh/source bytes permanently. Normal
/// exact readback remains responsible for releasing source and active leases.
Set<String> messageArchiveRecoveryAuditProtectedReferences(
  CloudSyncMessageArchiveRecoveryOrigin origin,
) => messagePreparationRecoveryAuditProtectedReferences(origin.preparationBinding);

Set<String> messageArchiveRecoveryAuditLeaseReferences({
  required CloudSyncMessageArchiveRecoveryOrigin origin,
  required CloudOutboxOperationEntity currentOperation,
}) {
  if (currentOperation.protectedLeaseReference == null) return const {};
  if (currentOperation.protectedLeaseReference != origin.preparation.freshLeaseReference) _reject();
  return {origin.preparation.freshLeaseReference};
}

bool _same(Map<String, Object?> a, Map<String, Object?> b) =>
    freshGroupRecoverySnapshotFingerprint(a) == freshGroupRecoverySnapshotFingerprint(b);
Never _reject() => throw StateError(messageArchiveRecoveryChangedCode);
