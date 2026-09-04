import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/shadow_only_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

const _leaseId = 'create-receipt-lease';
const _serverHash = 'SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS';
const _otherServerHash = 'TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT';
const _etag = 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE';
const _otherEtag = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';
const _otherLogicalHash = 'MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM';

void main() {
  group('InMemoryCloudSyncStore create receipt', () {
    late InMemoryCloudSyncStore store;
    setUp(() {
      store = InMemoryCloudSyncStore();
    });
    _defineCreateReceiptTests(
      load: () => store,
      readOutbox: (scope) => store.outboxEntries(scope),
    );
  });

  group('ObjectBoxCloudSyncStore create receipt', () {
    Directory? directory;
    Store? box;
    late ObjectBoxCloudSyncStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'openbubbles-create-receipt-',
      );
      box = await openStore(directory: directory!.path);
      store = ObjectBoxCloudSyncStore(
        store: box!,
        protector: _FakeProtector(),
        clock: () => testEpoch,
      );
    });
    tearDown(() async {
      box?.close();
      box = null;
      if (directory != null && directory!.existsSync()) {
        await directory!.delete(recursive: true);
      }
      directory = null;
    });
    _defineCreateReceiptTests(
      load: () => store,
      readOutbox: (scope) => store.readOutboxEntries(scope),
    );
  });

  test('shadow store denies the create receipt path', () async {
    final store = ShadowOnlyCloudSyncStore(InMemoryCloudSyncStore());
    final scope = testScope();
    await expectLater(
      store.commitOutboxCreateReceipt(
        scope,
        leaseId: _leaseId,
        receipt: CloudOutboxCreateReceipt(
          operationId:
              'op1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          logicalEntityKeyHash: 'LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL',
          serverRecordIdHash: _serverHash,
          etagHash: _etag,
        ),
        now: testEpoch,
      ),
      throwsA(isA<CloudSyncShadowStoreTripwireException>()),
    );
  });
}

void _defineCreateReceiptTests({
  required CloudSyncStore Function() load,
  required Future<List<CloudOutboxOperation>> Function(CloudSyncScope scope)
  readOutbox,
}) {
  late CloudSyncScope scope;
  setUp(() {
    scope = testScope();
  });

  Future<CloudOutboxOperation> leasedSave(int index) async {
    final operation = testOutboxOperation(scope, index);
    await load().enqueueOutbox(operation);
    await load().leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 10,
      leaseId: _leaseId,
      leaseDuration: const Duration(minutes: 5),
      allowedActions: const {CloudOutboxAction.save},
    );
    return operation;
  }

  Future<void> putMap({
    required String logical,
    required String server,
    String? etag,
  }) {
    return load().upsertRecordMap(
      CloudRecordMapEntry(
        scope: scope,
        logicalEntityKeyHash: logical,
        serverRecordIdHash: server,
        encryptedServerRecordId: testProtectedReference('A'),
        etagHash: etag,
        updatedAt: testEpoch,
      ),
      generation: 1,
    );
  }

  Future<void> bindServerHash(
    CloudOutboxOperation operation, {
    String server = _serverHash,
  }) {
    return load().attachOutboxRecordMapping(
      scope,
      leaseId: _leaseId,
      operationId: operation.operationId,
      serverRecordIdHash: server,
      now: testEpoch,
    );
  }

  CloudOutboxCreateReceipt receiptFor(
    CloudOutboxOperation operation, {
    String? server,
    String? etag,
    String? logical,
  }) {
    return CloudOutboxCreateReceipt(
      operationId: operation.operationId,
      logicalEntityKeyHash: logical ?? operation.logicalEntityKeyHash,
      serverRecordIdHash: server ?? _serverHash,
      etagHash: etag ?? _etag,
    );
  }

  Future<void> expectRejectedUnchanged({
    required CloudOutboxOperation operation,
    required CloudOutboxCreateReceipt receipt,
    required String leaseId,
    required DateTime now,
    required String safeCode,
  }) async {
    final store = load();
    final beforeOp = (await readOutbox(
      scope,
    )).singleWhere((row) => row.operationId == operation.operationId);
    final beforeMap = await store.readRecordMap(
      scope,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      generation: 1,
    );
    await expectLater(
      store.commitOutboxCreateReceipt(
        scope,
        leaseId: leaseId,
        receipt: receipt,
        now: now,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          safeCode,
        ),
      ),
    );
    final afterOp = (await readOutbox(
      scope,
    )).singleWhere((row) => row.operationId == operation.operationId);
    expect(afterOp.status, beforeOp.status);
    expect(afterOp.leaseId, beforeOp.leaseId);
    expect(afterOp.leaseExpiresAt, beforeOp.leaseExpiresAt);
    expect(afterOp.serverRecordIdHash, beforeOp.serverRecordIdHash);
    expect(afterOp.protectedLeaseReference, beforeOp.protectedLeaseReference);
    expect(afterOp.confirmedAt, beforeOp.confirmedAt);
    final afterMap = await store.readRecordMap(
      scope,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      generation: 1,
    );
    expect(afterMap?.etagHash, beforeMap?.etagHash);
    expect(afterMap?.serverRecordIdHash, beforeMap?.serverRecordIdHash);
    expect(
      afterMap?.encryptedServerRecordId,
      beforeMap?.encryptedServerRecordId,
    );
  }

  test('commits a leased create against the existing map', () async {
    final store = load();
    final operation = await leasedSave(1);
    await bindServerHash(operation);
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);

    await store.commitOutboxCreateReceipt(
      scope,
      leaseId: _leaseId,
      receipt: receiptFor(operation),
      now: testEpoch,
    );

    final confirmed = (await readOutbox(
      scope,
    )).singleWhere((row) => row.operationId == operation.operationId);
    expect(confirmed.status, CloudOutboxStatus.confirmed);
    expect(confirmed.leaseId, isNull);
    expect(confirmed.leaseExpiresAt, isNull);
    expect(confirmed.confirmedAt, testEpoch);
    expect(confirmed.serverRecordIdHash, _serverHash);
    expect(confirmed.protectedLeaseReference, isNull);
    expect(confirmed.lastFailure, isNull);
    expect(confirmed.nextEligibleAt, isNull);
    final map = await store.readRecordMap(
      scope,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      generation: 1,
    );
    expect(map, isNotNull);
    expect(map!.etagHash, _etag);
    expect(map.serverRecordIdHash, _serverHash);
    expect(map.encryptedServerRecordId, testProtectedReference('A'));
    expect(map.updatedAt, testEpoch);
  });

  test('retains the protected receipt only for confirmed replay', () async {
    final store = load();
    final operation = await leasedSave(101);
    await bindServerHash(operation);
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);

    await store.commitOutboxCreateReceipt(
      scope,
      leaseId: _leaseId,
      receipt: receiptFor(operation),
      retainProtectedLeaseReference: true,
      now: testEpoch,
    );

    final confirmed = (await readOutbox(
      scope,
    )).singleWhere((row) => row.operationId == operation.operationId);
    expect(confirmed.status, CloudOutboxStatus.confirmed);
    expect(
      confirmed.protectedLeaseReference,
      operation.protectedLeaseReference,
    );
    expect(confirmed.leaseId, isNull);
    expect(confirmed.leaseExpiresAt, isNull);
  });

  test(
    'commits after submission started without replaying the create',
    () async {
      final store = load();
      final operation = await leasedSave(2);
      await bindServerHash(operation);
      final submitted = await store.markOutboxSubmissionStarted(
        scope,
        leaseId: _leaseId,
        submissionIdentity: testSubmissionIdentity([operation.operationId]),
        now: testEpoch,
      );
      expect(submitted.single.status, CloudOutboxStatus.unknownOutcome);
      await putMap(
        logical: operation.logicalEntityKeyHash,
        server: _serverHash,
      );

      await store.commitOutboxCreateReceipt(
        scope,
        leaseId: _leaseId,
        receipt: receiptFor(operation),
        now: testEpoch,
      );

      final confirmed = (await readOutbox(
        scope,
      )).singleWhere((row) => row.operationId == operation.operationId);
      expect(confirmed.status, CloudOutboxStatus.confirmed);
      expect(confirmed.leaseId, isNull);
      expect(confirmed.appleRequestUuid, submitted.single.appleRequestUuid);
      expect(confirmed.appleOperationUuid, submitted.single.appleOperationUuid);
      expect(
        await store.readRecordMap(
          scope,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          generation: 1,
        ),
        isNotNull,
      );
    },
  );

  test('accepts an already-recorded etag as the same receipt', () async {
    final store = load();
    final operation = await leasedSave(3);
    await bindServerHash(operation);
    await putMap(
      logical: operation.logicalEntityKeyHash,
      server: _serverHash,
      etag: _etag,
    );

    await store.commitOutboxCreateReceipt(
      scope,
      leaseId: _leaseId,
      receipt: receiptFor(operation),
      now: testEpoch,
    );

    expect(
      (await readOutbox(
        scope,
      )).singleWhere((row) => row.operationId == operation.operationId).status,
      CloudOutboxStatus.confirmed,
    );
  });

  test('retry after success fails closed without mutation', () async {
    final store = load();
    final operation = await leasedSave(4);
    await bindServerHash(operation);
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);
    final receipt = receiptFor(operation);
    await store.commitOutboxCreateReceipt(
      scope,
      leaseId: _leaseId,
      receipt: receipt,
      now: testEpoch,
    );

    await expectLater(
      store.commitOutboxCreateReceipt(
        scope,
        leaseId: _leaseId,
        receipt: receipt,
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'stale_outbox_lease',
        ),
      ),
    );
    final afterOp = (await readOutbox(
      scope,
    )).singleWhere((row) => row.operationId == operation.operationId);
    expect(afterOp.status, CloudOutboxStatus.confirmed);
    expect(afterOp.confirmedAt, testEpoch);
    expect(
      (await store.readRecordMap(
        scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        generation: 1,
      ))!.etagHash,
      _etag,
    );
  });

  test('receipt value rejects an empty etag before store access', () {
    final operation = testOutboxOperation(scope, 5);
    expect(() => receiptFor(operation, etag: ''), throwsArgumentError);
  });

  test('receipt value rejects an empty operation id before store access', () {
    final operation = testOutboxOperation(scope, 6);
    expect(
      () => CloudOutboxCreateReceipt(
        operationId: '',
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        serverRecordIdHash: _serverHash,
        etagHash: _etag,
      ),
      throwsArgumentError,
    );
  });

  test('rejects a foreign lease without mutation', () async {
    final operation = await leasedSave(7);
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);
    await expectRejectedUnchanged(
      operation: operation,
      receipt: receiptFor(operation),
      leaseId: 'foreign-lease',
      now: testEpoch,
      safeCode: 'stale_outbox_lease',
    );
  });

  test('rejects an expired lease without mutation', () async {
    final store = load();
    final operation = testOutboxOperation(scope, 8);
    await store.enqueueOutbox(operation);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 10,
      leaseId: _leaseId,
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);
    await expectRejectedUnchanged(
      operation: operation,
      receipt: receiptFor(operation),
      leaseId: _leaseId,
      now: testEpoch.add(const Duration(minutes: 2)),
      safeCode: 'stale_outbox_lease',
    );
  });

  test('rejects a stale generation without mutation', () async {
    final store = load();
    final operation = await leasedSave(9);
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);
    await store.advanceOutboxGeneration(scope, now: testEpoch);
    await expectLater(
      store.commitOutboxCreateReceipt(
        scope,
        leaseId: _leaseId,
        receipt: receiptFor(operation),
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'stale_outbox_generation',
        ),
      ),
    );
    expect(
      (await readOutbox(
        scope,
      )).singleWhere((row) => row.operationId == operation.operationId).status,
      CloudOutboxStatus.quarantined,
    );
  });

  test('rejects a non-save operation without creating a map', () async {
    final store = load();
    final operation = testOutboxOperation(
      scope,
      10,
      action: CloudOutboxAction.delete,
    );
    await store.enqueueOutbox(operation);
    await store.leaseEligibleOutbox(
      scope,
      now: testEpoch,
      limit: 10,
      leaseId: _leaseId,
      leaseDuration: const Duration(minutes: 5),
      allowedActions: const {CloudOutboxAction.delete},
    );
    await expectLater(
      store.commitOutboxCreateReceipt(
        scope,
        leaseId: _leaseId,
        receipt: receiptFor(operation),
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'outbox_receipt_action_unsupported',
        ),
      ),
    );
    expect(
      await store.readRecordMap(
        scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        generation: 1,
      ),
      isNull,
    );
  });

  test('rejects a logical key mismatch without mutation', () async {
    final operation = await leasedSave(11);
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);
    await expectRejectedUnchanged(
      operation: operation,
      receipt: receiptFor(operation, logical: _otherLogicalHash),
      leaseId: _leaseId,
      now: testEpoch,
      safeCode: 'outbox_receipt_logical_key_mismatch',
    );
  });

  test('rejects an outbox server-hash change without mutation', () async {
    final store = load();
    final operation = await leasedSave(12);
    await store.attachOutboxRecordMapping(
      scope,
      leaseId: _leaseId,
      operationId: operation.operationId,
      serverRecordIdHash: _otherServerHash,
      now: testEpoch,
    );
    await putMap(
      logical: operation.logicalEntityKeyHash,
      server: _otherServerHash,
    );
    await expectLater(
      store.commitOutboxCreateReceipt(
        scope,
        leaseId: _leaseId,
        receipt: receiptFor(operation),
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'server_mapping_changed',
        ),
      ),
    );
    final afterOp = (await readOutbox(
      scope,
    )).singleWhere((row) => row.operationId == operation.operationId);
    expect(afterOp.status, CloudOutboxStatus.leased);
    expect(afterOp.serverRecordIdHash, _otherServerHash);
  });

  test('rejects a missing map without creating one', () async {
    final store = load();
    final operation = await leasedSave(13);
    await bindServerHash(operation);
    await expectLater(
      store.commitOutboxCreateReceipt(
        scope,
        leaseId: _leaseId,
        receipt: receiptFor(operation),
        now: testEpoch,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'outbox_receipt_map_missing',
        ),
      ),
    );
    expect(
      (await readOutbox(
        scope,
      )).singleWhere((row) => row.operationId == operation.operationId).status,
      CloudOutboxStatus.leased,
    );
    expect(
      await store.readRecordMap(
        scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        generation: 1,
      ),
      isNull,
    );
  });

  test('rejects a map server-hash mismatch without mutation', () async {
    final operation = await leasedSave(14);
    await bindServerHash(operation);
    await putMap(
      logical: operation.logicalEntityKeyHash,
      server: _otherServerHash,
    );
    await expectRejectedUnchanged(
      operation: operation,
      receipt: receiptFor(operation),
      leaseId: _leaseId,
      now: testEpoch,
      safeCode: 'server_mapping_changed',
    );
  });

  test('rejects a changed etag without mutation', () async {
    final operation = await leasedSave(15);
    await bindServerHash(operation);
    await putMap(
      logical: operation.logicalEntityKeyHash,
      server: _serverHash,
      etag: _otherEtag,
    );
    await expectRejectedUnchanged(
      operation: operation,
      receipt: receiptFor(operation),
      leaseId: _leaseId,
      now: testEpoch,
      safeCode: 'outbox_receipt_changed',
    );
    expect(
      (await load().readRecordMap(
        scope,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        generation: 1,
      ))!.etagHash,
      _otherEtag,
    );
  });

  test('rejects an unbound operation server hash without mutation', () async {
    final operation = await leasedSave(16);
    await putMap(logical: operation.logicalEntityKeyHash, server: _serverHash);
    await expectRejectedUnchanged(
      operation: operation,
      receipt: receiptFor(operation),
      leaseId: _leaseId,
      now: testEpoch,
      safeCode: 'server_mapping_changed',
    );
  });
}

final class _FakeProtector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async {
    return sha256
        .convert(utf8.encode('fake-receipt-hmac\u001f$rawAccountIdentifier'))
        .toString();
  }

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async {
    return plaintext;
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    return ciphertext;
  }
}
