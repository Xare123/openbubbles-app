import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_local_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_outbox_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart coverage for the historical outbox ownership binding.
/// No Store is opened, no native bridge is touched and no real messages
/// are read: the local guard is decoded from its synthetic
/// `[1, sendHash, receivedHash, 0, null]` form.
String _t(String c) => List.filled(43, c).join();
String _h(String c) => List.filled(64, c).join();
String _lease(String c) => 'obcs2.lease.${List.filled(32, c).join()}';

CloudSyncHistoricalProtectedSourceBinding _source({
  String? account,
  String? sourceSha,
}) => CloudSyncHistoricalProtectedSourceBinding(
  accountFingerprint: account ?? _t('A'),
  protectedStoreIdentity: 'obcs2.store.${_t('S')}',
  snapshotSha256: _h('a'),
  messageGuidHash: _h('b'),
  sourceSha256: sourceSha ?? _h('c'),
  protectedReference: 'obcs2.ref.${_t('R')}',
  leaseReference: _lease('a'),
  payloadSha256: _h('e'),
  payloadLength: 128,
);

CloudSyncHistoricalLocalGuard _guard({
  String? sendHash,
  String? receivedHash,
}) => CloudSyncHistoricalLocalGuard.decode(
  jsonEncode([1, sendHash ?? _h('1'), receivedHash ?? _h('2'), 0, null]),
);

CloudSyncScope _scope({String? account, String? zone}) => CloudSyncScope(
  accountFingerprint: account ?? _t('A'),
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone ?? 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

CloudSyncHistoricalCreateSource _createSource({
  CloudSyncHistoricalProtectedSourceBinding? source,
  CloudSyncHistoricalLocalGuard? guard,
  String? parentBinding,
  int? generation,
  String? logicalHash,
  String? serverHash,
  int? createdAtMs,
}) => CloudSyncHistoricalCreateSource(
  intentId: 1,
  source: source ?? _source(),
  localChatId: 7,
  parentBinding: parentBinding ?? 'parent-binding-1',
  generation: generation ?? 1,
  logicalEntityKeyHash: logicalHash ?? _t('L'),
  serverRecordIdHash: serverHash ?? _t('S'),
  createdAtMs: createdAtMs ?? 1700000000000,
  localGuard: guard ?? _guard(),
);

CloudOutboxOperation _operation(
  CloudSyncHistoricalCreateSource create, {
  CloudSyncScope? scope,
  String? logicalHash,
  String? serverHash,
  int? checkpointGeneration,
  String? payloadSha,
  String? payloadReference,
  int? createdAtMs,
}) {
  final effectiveScope = scope ?? _scope();
  final effectiveLogical = logicalHash ?? create.logicalEntityKeyHash;
  return CloudOutboxOperation(
    scope: effectiveScope,
    operationId: CloudOperationIdentity.forInitialCreate(
      scope: effectiveScope,
      logicalEntityKeyHash: effectiveLogical,
      payloadVersion: cloudSyncOutboundPayloadVersion,
    ),
    logicalEntityKeyHash: effectiveLogical,
    action: CloudOutboxAction.save,
    payloadVersion: cloudSyncOutboundPayloadVersion,
    mutationRevision: 1,
    checkpointGeneration: checkpointGeneration ?? create.generation,
    dependencyOperationIds: const {},
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      createdAtMs ?? create.createdAtMs,
      isUtc: true,
    ),
    encryptedPayloadReference: payloadReference ?? 'obcs2.ref.${_t('P')}',
    payloadSha256: payloadSha ?? _h('f'),
    serverRecordIdHash: serverHash ?? create.serverRecordIdHash,
    protectedLeaseReference: _lease('b'),
  );
}

CloudSyncHistoricalOutboxBinding _adopted() {
  final create = _createSource();
  return CloudSyncHistoricalOutboxBinding.adopt(
    source: create,
    operation: _operation(create),
  );
}

void main() {
  test('synthetic local guard decodes [1,sendHash,receivedHash,0,null]', () {
    final encoded = jsonEncode([1, _h('1'), _h('2'), 0, null]);
    final guard = CloudSyncHistoricalLocalGuard.decode(encoded);
    expect(guard.localSendGuidHash, _h('1'));
    expect(guard.receivedGuidHash, _h('2'));
    expect(guard.localMessageId, 0);
    expect(guard.localMessageSnapshot, isNull);
    expect(guard.encode(), encoded);
    expect(guard.toString(), 'CloudSyncHistoricalLocalGuard(redacted)');
  });

  test('adopted binding canonical roundtrip keeps operation proof', () {
    final binding = _adopted();
    expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(binding.operationDigest), isTrue);
    final decoded = CloudSyncHistoricalOutboxBinding.decode(binding.encode());
    expect(decoded.encode(), binding.encode());
    expect(decoded.operationDigest, binding.operationDigest);
    expect(decoded.source.sameSourceAs(binding.source), isTrue);
    expect(binding.source.sameSourceAs(decoded.source), isTrue);
    decoded.requireOperation(_operation(decoded.source));
    expect(decoded.toString(), 'CloudSyncHistoricalOutboxBinding(redacted)');
    expect(
      decoded.source.toString(),
      'CloudSyncHistoricalCreateSource(redacted)',
    );
  });

  test('immutable source drift is rejected', () {
    final binding = _adopted();
    final drifted = _createSource(source: _source(sourceSha: _h('9')));
    expect(drifted.sameSourceAs(binding.source), isFalse);
    expect(binding.source.sameSourceAs(drifted), isFalse);
    final tampered = List<dynamic>.of(jsonDecode(binding.encode()) as List);
    tampered[3] = drifted.source.encode();
    // Decode alone only checks canonical shape; the operation proof below
    // is what rejects the swapped source segment.
    final decodedTampered = CloudSyncHistoricalOutboxBinding.decode(
      jsonEncode(tampered),
    );
    expect(decodedTampered.source.sameSourceAs(binding.source), isFalse);
    expect(
      () =>
          decodedTampered.requireOperation(_operation(decodedTampered.source)),
      throwsStateError,
    );
    final foreign = _createSource(source: _source(account: _t('Z')));
    expect(foreign.sameSourceAs(binding.source), isFalse);
    expect(
      () => foreign.requireOperation(_operation(_createSource())),
      throwsStateError,
    );
  });

  test('parent, generation and operation identity drift rejected', () {
    final binding = _adopted();
    expect(
      _createSource(
        parentBinding: 'parent-binding-2',
      ).sameSourceAs(binding.source),
      isFalse,
    );
    expect(
      _createSource(
        guard: _guard(sendHash: _h('9')),
      ).sameSourceAs(binding.source),
      isFalse,
    );
    final drifts = <CloudOutboxOperation>[
      _operation(binding.source, logicalHash: _t('Q')),
      _operation(binding.source, serverHash: _t('Q')),
      _operation(binding.source, checkpointGeneration: 2),
      _operation(binding.source, payloadSha: _h('9')),
      _operation(binding.source, payloadReference: 'obcs2.ref.${_t('Q')}'),
      _operation(binding.source, createdAtMs: 1700000000001),
      _operation(binding.source, scope: _scope(zone: 'otherZone')),
    ];
    for (final drift in drifts) {
      expect(() => binding.requireOperation(drift), throwsStateError);
    }
    for (final slot in [5, 10]) {
      final tampered = List<dynamic>.of(jsonDecode(binding.encode()) as List);
      tampered[slot] = slot == 5
          ? 'changed-parent-binding'
          : _guard(sendHash: _h('9')).encode();
      final decoded = CloudSyncHistoricalOutboxBinding.decode(
        jsonEncode(tampered),
      );
      expect(
        () => decoded.requireOperation(_operation(binding.source)),
        throwsStateError,
      );
    }
  });

  test('mixed and invalid state metadata rejected', () {
    final base = List<dynamic>.of(jsonDecode(_adopted().encode()) as List);
    String withVersion(Object version) {
      final copy = List<dynamic>.of(base);
      copy[0] = version;
      return jsonEncode(copy);
    }

    String withSlot(int slot, Object? value) {
      final copy = List<dynamic>.of(base);
      copy[slot] = value;
      return jsonEncode(copy);
    }

    final bad = <String>[
      withVersion(2),
      withSlot(1, 'wrongTag'),
      jsonEncode(base.sublist(0, 11)),
      jsonEncode([...base, 'extra']),
      withSlot(11, 'not-a-digest'),
      withSlot(10, 'not-a-guard'),
      withSlot(3, 'not-a-source'),
      withSlot(2, 0),
      withSlot(9, 0),
      'not json at all',
      'x' * 9000,
    ];
    for (final encoded in bad) {
      expect(
        () => CloudSyncHistoricalOutboxBinding.decode(encoded),
        throwsStateError,
      );
    }
    for (final encoded in <String>[
      jsonEncode([1, _h('1'), _h('2'), 1, null]),
      jsonEncode([1, _h('1'), _h('2'), 0, 'x']),
      jsonEncode([1, 'zz', _h('2'), 0, null]),
      jsonEncode([1, _h('1'), _h('2')]),
    ]) {
      expect(
        () => CloudSyncHistoricalLocalGuard.decode(encoded),
        throwsStateError,
      );
    }
    expect(() => _createSource(parentBinding: ''), throwsStateError);
    expect(() => _createSource(logicalHash: 'not a token!'), throwsStateError);
    final leased = _operation(
      _createSource(),
    ).copyWith(status: CloudOutboxStatus.leased);
    expect(
      () => CloudSyncHistoricalOutboxBinding.adopt(
        source: _createSource(),
        operation: leased,
      ),
      throwsStateError,
    );
  });

  test(
    'mutable attempt, unknown-outcome and confirmation fields stay recoverable',
    () {
      final binding = _adopted();
      final progressed = _operation(binding.source).copyWith(
        status: CloudOutboxStatus.unknownOutcome,
        attemptCount: 2,
        appleRequestUuid: '11111111-2222-4ABC-8DEF-555555555555',
        appleOperationUuid: 'AAAAAAAA-BBBB-4CCC-8DDD-000000000001',
        leaseId: 'lease-1',
        leaseExpiresAt: DateTime.utc(2026, 1, 2),
        nextEligibleAt: DateTime.utc(2026, 1, 3),
        lastFailure: CloudFailureCategory.network,
      );
      binding.requireOperation(progressed);
      final confirmed = progressed.copyWith(
        status: CloudOutboxStatus.confirmed,
        confirmedAt: DateTime.utc(2026, 1, 4),
      );
      binding.requireOperation(confirmed);
      expect(
        CloudSyncHistoricalOutboxBinding.decode(
          binding.encode(),
        ).operationDigest,
        binding.operationDigest,
      );
      expect(
        () => CloudSyncHistoricalOutboxBinding.adopt(
          source: binding.source,
          operation: progressed,
        ),
        throwsStateError,
      );
    },
  );
}
