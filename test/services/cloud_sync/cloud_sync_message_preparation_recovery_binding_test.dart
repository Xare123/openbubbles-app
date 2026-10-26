import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_fresh_group_recovery_snapshot.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_preparation_recovery_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_preparation_recovery_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic model metadata only. No Store, native runtime, account or real pins.
String _hex(String c) => c * 64;
String _token(String c) => c * 43;
String _ref(String c) => 'obcs2.ref.${_token(c)}';
String _lease(String c) => 'obcs2.lease.${c * 32}';
String get _store => 'obcs2.store.${_token('P')}';
DateTime _time(int value) => DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);

final _changed = throwsA(isA<StateError>().having(
  (e) => e.message, 'fixed safe code', messagePreparationRecoveryChangedCode,
));

final class _Fixture {
  final scope = CloudSyncScope(
    accountFingerprint: _token('A'), container: 'com.apple.messages.cloud',
    database: 'private', zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  late final chatScope = CloudSyncScope(
    accountFingerprint: scope.accountFingerprint, container: scope.container,
    database: scope.database, zone: 'chatManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  late final attachmentScope = CloudSyncScope(
    accountFingerprint: scope.accountFingerprint, container: scope.container,
    database: scope.database, zone: 'attachmentManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  late final operationId = CloudOperationIdentity.forInitialCreate(
    scope: scope, logicalEntityKeyHash: _token('K'), payloadVersion: 2,
  );
  late final row = CloudOutboxOperationEntity(
    id: 101, operationId: operationId, scopeKey: cloudSyncPersistentScopeKey(scope),
    accountFingerprint: scope.accountFingerprint, zone: scope.zone,
    logicalEntityKeyHash: _token('K'), action: 0, payloadVersion: 2,
    mutationRevision: 0, checkpointGeneration: 1, encryptedPayloadRef: _ref('O'),
    payloadSha256: _hex('6'), serverRecordIdHash: _token('R'),
    state: 4, attemptCount: 3, lastErrorCategory: 'unknown', createdAtMs: 100, updatedAtMs: 200,
  );
  late final operation = CloudOutboxOperation(
    scope: scope, operationId: row.operationId, logicalEntityKeyHash: row.logicalEntityKeyHash,
    action: CloudOutboxAction.save, payloadVersion: row.payloadVersion,
    mutationRevision: row.mutationRevision, checkpointGeneration: row.checkpointGeneration,
    dependencyOperationIds: const {}, createdAt: _time(row.createdAtMs),
    encryptedPayloadReference: row.encryptedPayloadRef, payloadSha256: row.payloadSha256,
    serverRecordIdHash: row.serverRecordIdHash, protectedLeaseReference: row.protectedLeaseReference,
    appleRequestUuid: row.appleRequestUuid, appleOperationUuid: row.appleOperationUuid,
    status: CloudOutboxStatus.quarantined, attemptCount: row.attemptCount,
    lastFailure: CloudFailureCategory.unknown,
  );
  late final map = CloudRecordMapEntity(
    id: 401, mapKey: cloudSyncCanonicalRecordMapKey(scope, row.logicalEntityKeyHash),
    scopeKey: row.scopeKey, accountFingerprint: row.accountFingerprint, zone: row.zone,
    logicalEntityKeyHash: row.logicalEntityKeyHash, serverRecordIdHash: row.serverRecordIdHash!,
    generation: row.checkpointGeneration, encryptedServerRecordId: row.encryptedPayloadRef!,
    updatedAtMs: 201,
  );
  late final nativeSource = CloudSyncLocalSendSourceBinding(
    accountFingerprint: scope.accountFingerprint, protectedStoreIdentity: _store,
    messageGuidHash: _hex('f'), sourceSha256: _hex('1'), protectedReference: _ref('S'),
    leaseReference: _lease('a'), payloadSha256: _hex('3'), payloadLength: 512,
  );
  late final legacy = _legacyBinding();
  late final source = CloudSyncLocalSendIntentEntity(
    id: 201, intentKey: _hex('8'), accountFingerprint: scope.accountFingerprint,
    writerEpoch: 7, localMessageId: 301, messageGuidHash: nativeSource.messageGuidHash,
    sourceSha256: nativeSource.sourceSha256, state: 2, admittedOperationId: operationId,
    admittedBindingSha256: _hex('9'), admittedChatBinding: legacy,
    idsConfirmationVersion: 2, protectedSourceBinding: nativeSource.encode(),
    createdAtMs: 10, updatedAtMs: 20,
  );
  late final stage = CloudSyncProtectedOutboundStageData(
    logicalEntityKeyHash: row.logicalEntityKeyHash, protectedEnvelopeReference: _ref('N'),
    payloadSha256: row.payloadSha256!, serverRecordIdHash: row.serverRecordIdHash!,
    leaseReference: _lease('b'),
  );
  late final auth = CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: _token('C'), accountFingerprint: scope.accountFingerprint,
    protectedStoreIdentity: _store, cloudMessagesClient: Object(),
  );

  String _legacyBinding() {
    final chat = jsonEncode([
      3, cloudSyncPersistentScopeKey(chatScope), 1, 55, _hex('c'), _hex('d'),
      _token('E'), _token('F'), _token('G'), _token('H'), _hex('e'),
    ]);
    final body = <Object?>[
      1, attachmentScope.storageKey, 1, 201, nativeSource.messageGuidHash,
      nativeSource.sourceSha256, _store, 7, [_token('J')],
      [[501, _token('J'), _token('B'), _hex('2'), 'op1:${_hex('4')}']],
    ];
    return jsonEncode([4, chat, jsonEncode([
      ...body, sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    ])]);
  }

  CloudSyncMessagePreparationRecoveryClaim claim({
    CloudOutboxOperation? original,
    Map<String, Object?>? operationSnapshot,
    Map<String, Object?>? mapSnapshot,
    Map<String, Object?>? sourceSnapshot,
    int chatId = 55,
    int intentId = 201,
  }) => CloudSyncMessagePreparationRecoveryClaim(
    operation: original ?? operation,
    operationSnapshot: operationSnapshot ?? freshGroupRecoveryOperationSnapshot(row),
    recordMapSnapshot: mapSnapshot ?? freshGroupRecoveryMapSnapshot(map),
    sourceSnapshot: sourceSnapshot ?? freshGroupRecoverySourceSnapshot(source),
    chatId: chatId, intentId: intentId,
  );

  Map<String, Object?> receipt({
    CloudSyncProtectedOutboundStageData? freshStage,
    CloudSyncNativeAuthSnapshot? currentAuth,
    int writerEpoch = 10,
    int ownershipEpoch = 9,
  }) => messagePreparationRecoveryBuildReceipt(
    claim: claim(), stage: freshStage ?? stage, currentAuth: currentAuth ?? auth,
    writerEpoch: writerEpoch, ownershipEpoch: ownershipEpoch,
    ownershipSnapshotSha256: _hex('a'), now: _time(300),
  );

  CloudSyncMessagePreparationRecoveryOrigin origin({
    CloudSyncMessagePreparationRecoveryPhase phase = CloudSyncMessagePreparationRecoveryPhase.adopted,
  }) => CloudSyncMessagePreparationRecoveryOrigin.create(
    legacyBinding: legacy, receipt: receipt(), phase: phase,
  );
}

Map<String, Object?> _copy(Map<String, Object?> value) => Map<String, Object?>.of(value);
Map<String, Object?> _receiptCopy(CloudSyncMessagePreparationRecoveryOrigin origin) => {
  for (final entry in origin.receipt.entries)
    entry.key: entry.value is Map<String, Object?>
        ? _copy(entry.value! as Map<String, Object?>) : entry.value,
};

void main() {
  test('build and model conversion preserve complete original held metadata', () {
    final f = _Fixture();
    final origin = f.origin();
    final original = validateMessagePreparationRecoveryReceipt(origin);
    expect(original.sameDurableSnapshotAs(f.operation), isTrue);
    expect(original.status, CloudOutboxStatus.quarantined);
    expect(original.protectedLeaseReference, isNull);
    expect(original.attemptCount, 3);
    expect(original.lastFailure, CloudFailureCategory.unknown);
    expect(origin.operation, freshGroupRecoveryOperationSnapshot(f.row));
    expect(origin.recordMap, freshGroupRecoveryMapSnapshot(f.map));
    expect(origin.source, freshGroupRecoverySourceSnapshot(f.source));
    expect(origin.legacyBinding, f.legacy);
    expect(origin.source['protectedSourceBinding'], f.nativeSource.encode());
    expect(origin.recordMap['mapKey'], startsWith('record-map:'));
    expect(origin.operation['scopeKey'], startsWith('scope2:'));
    expect(original.createdAt.millisecondsSinceEpoch, 100);
    expect(origin.source['createdAtMs'], 10); // Independent capture/admission.
  });

  test('claim snapshots and built receipt remain immutable after caller mutation', () {
    final f = _Fixture();
    final operation = _copy(freshGroupRecoveryOperationSnapshot(f.row));
    final map = _copy(freshGroupRecoveryMapSnapshot(f.map));
    final source = _copy(freshGroupRecoverySourceSnapshot(f.source));
    final claim = f.claim(operationSnapshot: operation, mapSnapshot: map, sourceSnapshot: source);
    operation['attemptCount'] = 91;
    map['mapKey'] = 'private replacement';
    source['protectedSourceBinding'] = 'private source';
    expect(claim.operationSnapshot['attemptCount'], 3);
    expect(claim.recordMapSnapshot['mapKey'], f.map.mapKey);
    expect(claim.sourceSnapshot['protectedSourceBinding'], f.nativeSource.encode());
    for (final snapshot in [claim.operationSnapshot, claim.recordMapSnapshot, claim.sourceSnapshot]) {
      expect(() => snapshot.clear(), throwsUnsupportedError);
    }
    final receipt = f.receipt();
    expect(() => receipt.clear(), throwsUnsupportedError);
    expect(() => (receipt['stage']! as Map<String, Object?>).clear(), throwsUnsupportedError);
  });

  test('domain conversion requires the actual derived scope map and initial operation keys', () {
    final f = _Fixture();
    final origin = f.origin();
    for (final change in ['scope', 'map', 'operation']) {
      final receipt = _receiptCopy(origin);
      final operation = receipt['operation']! as Map<String, Object?>;
      final map = receipt['recordMap']! as Map<String, Object?>;
      final source = receipt['source']! as Map<String, Object?>;
      final binding = receipt['binding']! as Map<String, Object?>;
      if (change == 'scope') {
        operation['scopeKey'] = 'scope2:${_hex('0')}';
        map['scopeKey'] = operation['scopeKey'];
        binding['scopeKey'] = operation['scopeKey'];
      } else if (change == 'map') {
        map['mapKey'] = 'record-map:${_hex('0')}';
      } else {
        operation['operationId'] = 'op1:${_hex('0')}';
        source['admittedOperationId'] = operation['operationId'];
      }
      // Each mutation remains valid codec syntax but is the wrong model key.
      final syntactic = CloudSyncMessagePreparationRecoveryOrigin.create(
        legacyBinding: f.legacy, receipt: receipt,
      );
      expect(() => validateMessagePreparationRecoveryReceipt(syntactic), _changed);
    }
  });

  test('partial historical Apple identities fail model conversion without being invented', () {
    final f = _Fixture();
    final receipt = _receiptCopy(f.origin());
    (receipt['operation']! as Map<String, Object?>)['appleRequestUuid'] =
        '11111111-2222-3333-4444-555555555555';
    final syntactic = CloudSyncMessagePreparationRecoveryOrigin.create(
      legacyBinding: f.legacy, receipt: receipt,
    );
    expect(() => validateMessagePreparationRecoveryReceipt(syntactic), _changed);
  });

  test('present historical UUIDs survive and do not confer submission authority', () {
    final f = _Fixture();
    f.row.appleRequestUuid = '11111111-2222-3333-4444-555555555555';
    f.row.appleOperationUuid = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    final original = validateMessagePreparationRecoveryReceipt(f.origin());
    expect(original.appleRequestUuid, f.row.appleRequestUuid);
    expect(original.appleOperationUuid, f.row.appleOperationUuid);
    expect(original.status, CloudOutboxStatus.quarantined);
    final dto = resolveMessagePreparationRecoveryOperation(
      f.origin(phase: CloudSyncMessagePreparationRecoveryPhase.committed),
      originalOperation: f.operation,
    );
    expect(dto.operationId, f.operationId);
    expect(f.row.state, 4);
  });

  test('retained source epoch is independent of current recovery ownership epoch', () {
    final f = _Fixture();
    final receipt = f.receipt(writerEpoch: 10, ownershipEpoch: 9);
    expect((receipt['source']! as Map)['writerEpoch'], 7);
    expect((receipt['binding']! as Map)['writerEpoch'], 10);
    expect((receipt['binding']! as Map)['ownershipEpoch'], 9);
    expect(() => f.receipt(writerEpoch: 8, ownershipEpoch: 9), _changed);
    expect(() => f.receipt(writerEpoch: 10, ownershipEpoch: 0), _changed);
  });

  test('receipt builder refuses another account or protected store', () {
    final f = _Fixture();
    for (final auth in [
      CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: _token('C'), accountFingerprint: _token('Z'),
        protectedStoreIdentity: _store, cloudMessagesClient: Object(),
      ),
      CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: _token('C'), accountFingerprint: f.scope.accountFingerprint,
        protectedStoreIdentity: 'obcs2.store.${_token('Z')}', cloudMessagesClient: Object(),
      ),
    ]) {
      expect(() => f.receipt(currentAuth: auth), _changed);
    }
  });

  test('fresh stage mismatches and old/source lease aliases are refused', () {
    final f = _Fixture();
    for (final field in ['logical', 'payload', 'server', 'oldReference', 'sourceLease']) {
      final stage = CloudSyncProtectedOutboundStageData(
        logicalEntityKeyHash: field == 'logical' ? _token('Z') : f.stage.logicalEntityKeyHash,
        payloadSha256: field == 'payload' ? _hex('0') : f.stage.payloadSha256,
        serverRecordIdHash: field == 'server' ? _token('Z') : f.stage.serverRecordIdHash,
        protectedEnvelopeReference: field == 'oldReference' ? f.row.encryptedPayloadRef! :
            f.stage.protectedEnvelopeReference,
        leaseReference: field == 'sourceLease' ? f.nativeSource.leaseReference : f.stage.leaseReference,
      );
      expect(() => f.receipt(freshStage: stage), _changed);
    }
  });

  test('claim refuses stale original model exact Chat and intent identities', () {
    final f = _Fixture();
    for (final old in [
      f.operation.copyWith(status: CloudOutboxStatus.pending),
      f.operation.copyWith(attemptCount: 4),
      f.operation.copyWith(encryptedPayloadReference: _ref('X')),
      f.operation.copyWith(protectedLeaseReference: _lease('e')),
    ]) {
      expect(() => f.claim(original: old), _changed);
    }
    expect(() => f.claim(chatId: 56), _changed);
    expect(() => f.claim(intentId: 202), _changed);
    final foreignMap = _copy(freshGroupRecoveryMapSnapshot(f.map))
      ..['serverRecordIdHash'] = _token('Z');
    expect(() => f.claim(mapSnapshot: foreignMap), _changed);
    final foreignSource = _copy(freshGroupRecoverySourceSnapshot(f.source))
      ..['admittedOperationId'] = 'op1:${_hex('0')}';
    expect(() => f.claim(sourceSnapshot: foreignSource), _changed);
  });

  test('claim requires every persisted scalar and never silently defaults missing nullables', () {
    final f = _Fixture();
    for (final section in ['operation', 'map', 'source']) {
      final snapshot = switch (section) {
        'operation' => freshGroupRecoveryOperationSnapshot(f.row),
        'map' => freshGroupRecoveryMapSnapshot(f.map),
        _ => freshGroupRecoverySourceSnapshot(f.source),
      };
      final missing = _copy(snapshot)..remove(section == 'operation' ? 'appleRequestUuid' :
          section == 'map' ? 'etagHash' : 'confirmedReadbackBindingSha256');
      final extra = _copy(snapshot)..['private'] = 'private payload';
      for (final bad in [missing, extra]) {
        expect(() => f.claim(
          operationSnapshot: section == 'operation' ? bad : null,
          mapSnapshot: section == 'map' ? bad : null,
          sourceSnapshot: section == 'source' ? bad : null,
        ), _changed);
      }
    }
    final active = _copy(freshGroupRecoveryOperationSnapshot(f.row))
      ..['leaseIdHash'] = _hex('a')..['leaseExpiresAtMs'] = 400;
    expect(() => f.claim(operationSnapshot: active), _changed);
  });

  test('resolver uses actual fresh references without changing original operation or mapping', () {
    final f = _Fixture();
    final before = freshGroupRecoveryOperationSnapshot(f.row);
    final mapping = freshGroupRecoveryMapSnapshot(f.map);
    final source = freshGroupRecoverySourceSnapshot(f.source);
    for (final phase in [
      CloudSyncMessagePreparationRecoveryPhase.committed,
      CloudSyncMessagePreparationRecoveryPhase.retained,
    ]) {
      final dto = resolveMessagePreparationRecoveryOperation(f.origin(phase: phase), originalOperation: f.operation);
      expect(dto.operationId, f.operationId);
      expect(dto.action, CloudOutboxAction.save); // Input shape, not a permit.
      expect(dto.logicalEntityKeyHash, f.row.logicalEntityKeyHash);
      expect(dto.serverRecordIdHash, f.row.serverRecordIdHash);
      expect(dto.payloadSha256, f.row.payloadSha256);
      expect(dto.protectedPayloadReference, f.stage.protectedEnvelopeReference);
      expect(dto.protectedServerRecordIdReference, f.stage.protectedEnvelopeReference);
      expect(dto.protectedLeaseReference, f.stage.leaseReference);
      expect(f.operation.status, CloudOutboxStatus.quarantined);
      expect(f.operation.protectedLeaseReference, isNull);
    }
    expect(freshGroupRecoveryOperationSnapshot(f.row), before);
    expect(freshGroupRecoveryMapSnapshot(f.map), mapping);
    expect(freshGroupRecoverySourceSnapshot(f.source), source);
  });

  test('resolver refuses adopted retired and stale originals even with valid phase syntax', () {
    final f = _Fixture();
    for (final phase in [
      CloudSyncMessagePreparationRecoveryPhase.adopted,
      CloudSyncMessagePreparationRecoveryPhase.retired,
    ]) {
      expect(() => resolveMessagePreparationRecoveryOperation(f.origin(phase: phase), originalOperation: f.operation), _changed);
    }
    final retained = f.origin(phase: CloudSyncMessagePreparationRecoveryPhase.retained);
    expect(() => resolveMessagePreparationRecoveryOperation(
      retained, originalOperation: f.operation.copyWith(attemptCount: 4),
    ), _changed);
  });

  test('validated liveness keeps old fresh and source bytes and only the new active lease', () {
    final f = _Fixture();
    for (final phase in CloudSyncMessagePreparationRecoveryPhase.values) {
      final encoded = f.origin(phase: phase).encode();
      final refs = messagePreparationRecoveryAuditProtectedReferences(encoded);
      expect(refs, {f.row.encryptedPayloadRef, f.stage.protectedEnvelopeReference, f.nativeSource.protectedReference});
      final leases = messagePreparationRecoveryAuditLeaseReferences(encoded);
      expect(leases, phase == CloudSyncMessagePreparationRecoveryPhase.retired ? <String>{} : {f.stage.leaseReference});
      expect(leases, isNot(contains(f.nativeSource.leaseReference)));
      expect(() => refs.clear(), throwsUnsupportedError);
      expect(() => leases.clear(), throwsUnsupportedError);
    }
  });

  test('unknown malformed tampered and domain-invalid liveness throws rather than returning none', () {
    final f = _Fixture();
    final origin = f.origin(phase: CloudSyncMessagePreparationRecoveryPhase.retired);
    final badReceipt = _receiptCopy(origin);
    (badReceipt['recordMap']! as Map<String, Object?>)['mapKey'] = 'record-map:${_hex('0')}';
    final domainInvalid = CloudSyncMessagePreparationRecoveryOrigin.create(
      legacyBinding: f.legacy, receipt: badReceipt,
      phase: CloudSyncMessagePreparationRecoveryPhase.retired,
    );
    final root = jsonDecode(origin.encode()) as List;
    root[4] = _hex('0');
    for (final encoded in ['', '[4]', '[5]', 'private exception', jsonEncode(root), domainInvalid.encode()]) {
      expect(() => messagePreparationRecoveryAuditProtectedReferences(encoded), _changed);
      expect(() => messagePreparationRecoveryAuditLeaseReferences(encoded), _changed);
    }
  });

  test('claim rendering and domain refusals expose no protected audit values', () {
    final f = _Fixture();
    expect(f.claim().toString(), 'CloudSyncMessagePreparationRecoveryClaim(redacted)');
    try {
      f.claim(mapSnapshot: _copy(freshGroupRecoveryMapSnapshot(f.map))..['private'] = 'private message body');
      fail('expected refusal');
    } on StateError catch (error) {
      expect(error.message, messagePreparationRecoveryChangedCode);
      expect(error.toString(), isNot(contains('private message body')));
      expect(error.toString(), isNot(contains(f.row.encryptedPayloadRef!)));
    }
  });
}
