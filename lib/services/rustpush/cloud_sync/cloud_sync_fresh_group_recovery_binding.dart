import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_fresh_group_recovery_origin.dart';
import 'cloud_sync_fresh_group_recovery_snapshot.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_outbound_group_origin.dart';
import 'cloud_sync_outbound_staging.dart';

/// A pinned read set, not authority. Adoption re-reads every scalar inside its
/// write transaction, including fields absent from CloudOutboxOperation.
final class CloudSyncFreshGroupRecoveryClaim {
  CloudSyncFreshGroupRecoveryClaim({
    required this.operation,
    required Map<String, Object?> operationSnapshot,
    required Map<String, Object?> recordMapSnapshot,
    required Map<String, Object?> sourceSnapshot,
    required this.identity,
    required this.chatId,
    required this.intentId,
    required this.origin,
  }) : operationSnapshot = Map.unmodifiable(operationSnapshot),
       recordMapSnapshot = Map.unmodifiable(recordMapSnapshot),
       sourceSnapshot = Map.unmodifiable(sourceSnapshot);

  final CloudOutboxOperation operation;
  final Map<String, Object?> operationSnapshot;
  final Map<String, Object?> recordMapSnapshot;
  final Map<String, Object?> sourceSnapshot;
  final String identity;
  final int chatId;
  final int intentId;
  final CloudSyncOutboundGroupOrigin origin;

  @override
  String toString() => 'CloudSyncFreshGroupRecoveryClaim(redacted)';
}

final _reference = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
final _lease = RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$');
final _nativeDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _contentDigest = RegExp(r'^[a-f0-9]{64}$');

Never _reject() => throw StateError('cloud_sync_fresh_group_recovery_changed');

Map<String, Object?> freshGroupRecoveryReceiptMap(
  CloudSyncFreshGroupRecoveryOrigin origin,
  String key,
) => origin.receipt[key] as Map<String, Object?>;

void _shape(
  Map<String, Object?> value, {
  required Set<String> integers,
  required Set<String> strings,
  required Set<String> optionalStrings,
}) {
  final keys = {...integers, ...strings, ...optionalStrings};
  if (value.length != keys.length ||
      !value.keys.every(keys.contains) ||
      integers.any((key) => value[key] is! int) ||
      strings.any((key) => value[key] is! String) ||
      optionalStrings.any(
        (key) => value[key] != null && value[key] is! String,
      )) {
    _reject();
  }
}

/// Domain validation in addition to the codec's bounded JSON validation. This
/// proves relationships, not source ownership; the journal authenticates that.
CloudOutboxOperationEntity validateFreshGroupRecoveryReceipt(
  CloudSyncFreshGroupRecoveryOrigin recovery,
) {
  final old = freshGroupRecoveryOperationFromSnapshot(
    freshGroupRecoveryReceiptMap(recovery, 'operation'),
  );
  final map = freshGroupRecoveryReceiptMap(recovery, 'recordMap');
  final source = freshGroupRecoveryReceiptMap(recovery, 'source');
  final conversion = freshGroupRecoveryReceiptMap(recovery, 'conversion');
  final binding = freshGroupRecoveryReceiptMap(recovery, 'binding');
  _shape(
    map,
    integers: {'id', 'generation', 'rawRecordGeneration', 'updatedAtMs'},
    strings: {
      'mapKey',
      'scopeKey',
      'accountFingerprint',
      'zone',
      'logicalEntityKeyHash',
      'serverRecordIdHash',
      'encryptedServerRecordId',
    },
    optionalStrings: {
      'etagHash',
      'encryptedRawRecordRef',
      'protectedReadbackLeaseReference',
      'pendingUpdateOperationId',
      'pendingUpdatePredecessorEtagHash',
    },
  );
  _shape(
    source,
    integers: {
      'id',
      'writerEpoch',
      'localMessageId',
      'state',
      'idsConfirmationVersion',
      'createdAtMs',
      'updatedAtMs',
    },
    strings: {
      'intentKey',
      'accountFingerprint',
      'messageGuidHash',
      'sourceSha256',
    },
    optionalStrings: {
      'admittedOperationId',
      'admittedBindingSha256',
      'admittedChatBinding',
      'confirmedReadbackBindingSha256',
      'protectedSourceBinding',
    },
  );
  _shape(
    conversion,
    integers: {},
    optionalStrings: {},
    strings: {
      'previousPayloadReference',
      'previousServerRecordReference',
      'previousLeaseReference',
      'protectedPayloadReference',
      'protectedServerRecordReference',
      'leaseReference',
      'logicalEntityKeyHash',
      'payloadSha256',
      'serverRecordIdHash',
    },
  );
  _shape(
    binding,
    integers: {'checkpointGeneration', 'chatId', 'intentId', 'recoveredAtMs'},
    strings: {
      'scopeKey',
      'accountFingerprint',
      'originIdentity',
      'nativeSessionId',
      'protectedStoreIdentity',
    },
    optionalStrings: {},
  );
  if (old.id <= 0 ||
      map['id']! as int <= 0 ||
      source['id']! as int <= 0 ||
      old.state != CloudOutboxStatus.quarantined.index ||
      old.lastErrorCategory != CloudFailureCategory.cancelled.name ||
      old.leaseIdHash != null ||
      old.leaseExpiresAtMs != 0 ||
      old.nextEligibleAtMs != 0 ||
      old.appleRequestUuid != null ||
      old.appleOperationUuid != null ||
      old.confirmedAtMs != 0 ||
      source['state'] != 1 ||
      source['idsConfirmationVersion'] != 2 ||
      source['admittedOperationId'] != null ||
      source['confirmedReadbackBindingSha256'] != null ||
      binding['scopeKey'] != old.scopeKey ||
      binding['accountFingerprint'] != old.accountFingerprint ||
      binding['checkpointGeneration'] != old.checkpointGeneration ||
      binding['chatId'] != recovery.identityParts[2] ||
      binding['intentId'] != source['id'] ||
      binding['originIdentity'] != recovery.identity ||
      (binding['recoveredAtMs']! as int) < old.updatedAtMs ||
      !_nativeDigest.hasMatch(binding['nativeSessionId']! as String) ||
      !RegExp(
        r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
      ).hasMatch(binding['protectedStoreIdentity']! as String) ||
      source['accountFingerprint'] != old.accountFingerprint ||
      map['scopeKey'] != old.scopeKey ||
      map['zone'] != old.zone ||
      map['accountFingerprint'] != old.accountFingerprint ||
      map['generation'] != old.checkpointGeneration ||
      map['logicalEntityKeyHash'] != old.logicalEntityKeyHash ||
      map['serverRecordIdHash'] != old.serverRecordIdHash ||
      map['encryptedServerRecordId'] != old.encryptedPayloadRef ||
      map['etagHash'] != null ||
      map['encryptedRawRecordRef'] != null ||
      map['rawRecordGeneration'] != 0 ||
      map['protectedReadbackLeaseReference'] != null ||
      map['pendingUpdateOperationId'] != null ||
      map['pendingUpdatePredecessorEtagHash'] != null ||
      conversion['previousPayloadReference'] != old.encryptedPayloadRef ||
      conversion['previousServerRecordReference'] !=
          map['encryptedServerRecordId'] ||
      conversion['previousLeaseReference'] != old.protectedLeaseReference ||
      conversion['logicalEntityKeyHash'] != old.logicalEntityKeyHash ||
      conversion['payloadSha256'] != old.payloadSha256 ||
      conversion['serverRecordIdHash'] != old.serverRecordIdHash ||
      conversion['protectedPayloadReference'] !=
          conversion['protectedServerRecordReference'] ||
      conversion['protectedPayloadReference'] == old.encryptedPayloadRef ||
      conversion['leaseReference'] == old.protectedLeaseReference ||
      !_reference.hasMatch(
        conversion['protectedPayloadReference']! as String,
      ) ||
      !_reference.hasMatch(old.encryptedPayloadRef ?? '') ||
      !_lease.hasMatch(conversion['leaseReference']! as String) ||
      !_lease.hasMatch(old.protectedLeaseReference ?? '') ||
      !_nativeDigest.hasMatch(old.logicalEntityKeyHash) ||
      !_nativeDigest.hasMatch(old.serverRecordIdHash ?? '') ||
      !_contentDigest.hasMatch(old.payloadSha256 ?? '')) {
    _reject();
  }
  return old;
}

CloudOutboxOperationEntity validateFreshGroupRecoveryEntity(
  CloudSyncFreshGroupRecoveryOrigin recovery,
  CloudOutboxOperationEntity current,
) {
  final old = validateFreshGroupRecoveryReceipt(recovery);
  final before = freshGroupRecoveryOperationSnapshot(old);
  final after = freshGroupRecoveryOperationSnapshot(current);
  final conversion = freshGroupRecoveryReceiptMap(recovery, 'conversion');
  if ([
        'id',
        'operationId',
        'scopeKey',
        'accountFingerprint',
        'zone',
        'logicalEntityKeyHash',
        'action',
        'dependencyOperationIdsJson',
        'payloadVersion',
        'mutationRevision',
        'checkpointGeneration',
        'payloadSha256',
        'serverRecordIdHash',
        'createdAtMs',
      ].any((key) => before[key] != after[key]) ||
      current.localChatOrigin != recovery.encode() ||
      current.encryptedPayloadRef != conversion['protectedPayloadReference'] ||
      current.attemptCount < old.attemptCount ||
      current.updatedAtMs <
          (freshGroupRecoveryReceiptMap(recovery, 'binding')['recoveredAtMs']!
              as int) ||
      (current.protectedLeaseReference != null &&
          current.protectedLeaseReference != conversion['leaseReference']) ||
      (current.protectedLeaseReference == null &&
          current.state != CloudOutboxStatus.confirmed.index)) {
    _reject();
  }
  return old;
}

/// Compare immutable operation identity to the old receipt and the active native
/// conversion. Mutable status/UUIDs are checked by the normal dispatch protocol.
CloudOutboxOperation freshGroupRecoveryPreviousOperation(
  CloudSyncFreshGroupRecoveryOrigin recovery,
  CloudOutboxOperation current,
) {
  final old = validateFreshGroupRecoveryReceipt(recovery);
  final conversion = freshGroupRecoveryReceiptMap(recovery, 'conversion');
  if (current.operationId != old.operationId ||
      current.scope.accountFingerprint != old.accountFingerprint ||
      current.scope.zone != old.zone ||
      current.logicalEntityKeyHash != old.logicalEntityKeyHash ||
      current.action.index != old.action ||
      current.payloadVersion != old.payloadVersion ||
      current.mutationRevision != old.mutationRevision ||
      current.checkpointGeneration != old.checkpointGeneration ||
      current.createdAt.millisecondsSinceEpoch != old.createdAtMs ||
      current.dependencyOperationIds.isNotEmpty ||
      current.payloadSha256 != old.payloadSha256 ||
      current.serverRecordIdHash != old.serverRecordIdHash ||
      current.encryptedPayloadReference !=
          conversion['protectedPayloadReference'] ||
      (current.protectedLeaseReference != null &&
          current.protectedLeaseReference != conversion['leaseReference']) ||
      (current.protectedLeaseReference == null &&
          current.status != CloudOutboxStatus.confirmed)) {
    _reject();
  }
  return current.copyWith(
    encryptedPayloadReference: old.encryptedPayloadRef,
    protectedLeaseReference: old.protectedLeaseReference,
  );
}

Map<String, Object?> freshGroupRecoveryBuildReceipt({
  required CloudSyncFreshGroupRecoveryClaim claim,
  required CloudSyncProtectedOutboundStageData stage,
  required String nativeSessionId,
  required String protectedStoreIdentity,
  required DateTime now,
}) => {
  'schema': 1,
  'reason': 'fresh-group-purpose-v1',
  'operation': claim.operationSnapshot,
  'recordMap': claim.recordMapSnapshot,
  'source': claim.sourceSnapshot,
  'conversion': {
    'previousPayloadReference': claim.operation.encryptedPayloadReference,
    'previousServerRecordReference':
        claim.recordMapSnapshot['encryptedServerRecordId'],
    'previousLeaseReference': claim.operation.protectedLeaseReference,
    'protectedPayloadReference': stage.protectedEnvelopeReference,
    'protectedServerRecordReference': stage.protectedEnvelopeReference,
    'leaseReference': stage.leaseReference,
    'logicalEntityKeyHash': stage.logicalEntityKeyHash,
    'payloadSha256': stage.payloadSha256,
    'serverRecordIdHash': stage.serverRecordIdHash,
  },
  'binding': {
    'scopeKey': claim.operationSnapshot['scopeKey'],
    'accountFingerprint': claim.operation.scope.accountFingerprint,
    'checkpointGeneration': claim.operation.checkpointGeneration,
    'chatId': claim.chatId,
    'intentId': claim.intentId,
    'originIdentity': claim.identity,
    'nativeSessionId': nativeSessionId,
    'protectedStoreIdentity': protectedStoreIdentity,
    'recoveredAtMs': now.toUtc().millisecondsSinceEpoch,
  },
};

Set<String> freshGroupRecoveryAuditLeaseReferences(
  String encoded, {
  required bool retainReplacementLease,
}) {
  final recovery = CloudSyncFreshGroupRecoveryOrigin.decode(encoded);
  validateFreshGroupRecoveryReceipt(recovery);
  final conversion = freshGroupRecoveryReceiptMap(recovery, 'conversion');
  final source = freshGroupRecoveryReceiptMap(recovery, 'source');
  return {
    conversion['previousLeaseReference']! as String,
    if (retainReplacementLease) conversion['leaseReference']! as String,
    if (source['protectedSourceBinding'] case final String binding)
      CloudSyncLocalSendSourceBinding.decode(binding).leaseReference,
  };
}

Set<String> freshGroupRecoveryAuditProtectedReferences(String encoded) {
  final recovery = CloudSyncFreshGroupRecoveryOrigin.decode(encoded);
  validateFreshGroupRecoveryReceipt(recovery);
  final conversion = freshGroupRecoveryReceiptMap(recovery, 'conversion');
  final source = freshGroupRecoveryReceiptMap(recovery, 'source');
  final values = <String>{
    conversion['previousPayloadReference']! as String,
    conversion['protectedPayloadReference']! as String,
  };
  if (source['protectedSourceBinding'] case final String binding) {
    values.add(
      CloudSyncLocalSendSourceBinding.decode(binding).protectedReference,
    );
  }
  return values;
}
