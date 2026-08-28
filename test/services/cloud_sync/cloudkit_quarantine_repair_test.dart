import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 27, 12);
  final scope = _scope();
  late Directory directory;
  late Store store;
  Store? storeForCleanup;
  late _Adapter adapter;
  late CloudKitV2QuarantineRepairGateway gateway;
  late CloudKitV2QuarantineRepairRequest request;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cloud-repair-');
    store = await openStore(directory: directory.path);
    storeForCleanup = store;
    adapter = _Adapter(store);
    gateway = CloudKitV2QuarantineRepairGateway(
      store: store,
      canonicalAdapter: adapter,
      enabled: true,
      clock: () => now,
    );
    final entry = _entry(scope, sequence: 2);
    _seed(store, scope, entry, now);
    request = CloudKitV2QuarantineRepairRequest(
      scope: scope,
      generation: entry.generation,
      changeIdHash: entry.change.changeId,
      correction: CloudKitV2QuarantineRepairAllowlist.only,
    );
  });

  tearDown(() async {
    storeForCleanup?.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'is opt-in and rejects corrections outside the named allowlist',
    () async {
      final disabled = CloudKitV2QuarantineRepairGateway(
        store: store,
        canonicalAdapter: adapter,
      );
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));

      final disabledResult = await disabled.repair(
        request: request,
        correctedDecoder: decoder,
      );
      expect(
        disabledResult.disposition,
        CloudKitV2QuarantineRepairDisposition.disabled,
      );
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
      expect(decoder.calls, 0);

      final unallowlisted = CloudKitV2QuarantineRepairRequest(
        scope: scope,
        generation: request.generation,
        changeIdHash: request.changeIdHash,
        correction: const CloudKitV2ConverterCorrection(
          converterRevision: 'cloud-canonical-converter-r3',
          correctionName: 'unreviewed-correction',
        ),
      );
      final result = await gateway.repair(
        request: unallowlisted,
        correctedDecoder: decoder,
      );
      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.safeCode, 'quarantine_repair_correction_not_allowlisted');
      expect(decoder.calls, 0);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    },
  );

  test(
    'repairs terminal quarantine without changing original or sync control rows',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
      final before = _controlState(store);

      final result = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.repaired,
      );
      expect(result.succeeded, isTrue);
      expect(decoder.calls, 1);
      expect(adapter.applyCalls, 1);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      final recordMap = store.box<CloudRecordMapEntity>().getAll().single;
      expect(recordMap.scopeKey, _scopeKey(scope));
      expect(recordMap.generation, request.generation);
      expect(recordMap.logicalEntityKeyHash, _digest('logical'));
      expect(recordMap.serverRecordIdHash, _digest('record'));
      expect(recordMap.encryptedServerRecordId, _protected('server'));
      expect(recordMap.encryptedRawRecordRef, _protected('payload'));
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
      expect(_controlState(store), before);

      final receipt = store
          .box<CloudKitV2QuarantineRepairReceiptEntity>()
          .getAll()
          .single;
      expect(receipt.scopeGenerationKey, _scopeGenerationKey(scope, 7));
      expect(receipt.changeIdHash, request.changeIdHash);
      expect(
        receipt.converterRevision,
        CloudKitV2QuarantineRepairAllowlist.only.converterRevision,
      );
      expect(
        receipt.correctionName,
        CloudKitV2QuarantineRepairAllowlist.only.correctionName,
      );
      expect(receipt.outcome, 'repaired');

      final inbox = store.box<CloudInboxChangeEntity>().getAll().single;
      final replay = store.box<CloudSemanticReplayEntity>().getAll().single;
      expect(inbox.status, CloudInboxStatus.quarantined.index);
      expect(replay.terminalOutcome, 'quarantined');
      expect(replay.terminalSafeCode, 'semantic_conflict');
    },
  );

  test('same receipt is idempotent and immutable', () async {
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));

    final first = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );
    final stored = store
        .box<CloudKitV2QuarantineRepairReceiptEntity>()
        .getAll()
        .single;
    final storedCreatedAt = stored.createdAtMs;
    final second = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );

    expect(first.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
    expect(
      second.disposition,
      CloudKitV2QuarantineRepairDisposition.alreadyRepaired,
    );
    expect(decoder.calls, 1);
    expect(adapter.applyCalls, 1);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    expect(
      store
          .box<CloudKitV2QuarantineRepairReceiptEntity>()
          .getAll()
          .single
          .createdAtMs,
      storedCreatedAt,
    );
  });

  test(
    'repaired receipt is not trusted after its record map disappears',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
      final first = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );
      expect(first.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
      store.box<CloudRecordMapEntity>().removeAll();

      final second = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );

      expect(
        second.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(second.failureCategory, CloudFailureCategory.localStorage);
      expect(second.safeCode, 'quarantine_repair_record_mapping_missing');
      expect(decoder.calls, 1);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    },
  );

  test(
    'repaired receipt is not trusted after its terminal pair changes',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
      await gateway.repair(request: request, correctedDecoder: decoder);
      final replay = store.box<CloudSemanticReplayEntity>().getAll().single
        ..terminalOutcome = 'applied';
      store.box<CloudSemanticReplayEntity>().put(replay);

      final result = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(result.safeCode, 'quarantine_repair_terminal_pair_invalid');
      expect(decoder.calls, 1);
    },
  );

  test(
    'repair keys include the named correction as well as its revision',
    () async {
      final disabled = CloudKitV2QuarantineRepairGateway(
        store: store,
        canonicalAdapter: adapter,
      );
      final alternate = CloudKitV2QuarantineRepairRequest(
        scope: request.scope,
        generation: request.generation,
        changeIdHash: request.changeIdHash,
        correction: const CloudKitV2ConverterCorrection(
          converterRevision: 'cloud-canonical-converter-r2',
          correctionName: 'another-reviewed-shape',
        ),
      );

      final first = await disabled.repair(
        request: request,
        correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      final second = await disabled.repair(
        request: alternate,
        correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(first.repairKey, startsWith('semantic-repair2:'));
      expect(second.repairKey, isNot(first.repairKey));
    },
  );

  test(
    'noChange repair validates canonical and record-map artifacts',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
      final first = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );
      expect(first.disposition, CloudKitV2QuarantineRepairDisposition.repaired);

      store.box<CloudKitV2QuarantineRepairReceiptEntity>().removeAll();
      adapter.parentExists = true;
      final second = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );

      expect(
        second.disposition,
        CloudKitV2QuarantineRepairDisposition.repaired,
      );
      expect(decoder.calls, 2);
      expect(adapter.applyCalls, 1);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    },
  );

  test('noChange repair fails closed when its record map is absent', () async {
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
    await gateway.repair(request: request, correctedDecoder: decoder);
    store.box<CloudKitV2QuarantineRepairReceiptEntity>().removeAll();
    store.box<CloudRecordMapEntity>().removeAll();
    adapter.parentExists = true;

    final result = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_record_mapping_missing');
    expect(adapter.applyCalls, 1);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    expect(
      store
          .box<CloudKitV2QuarantineRepairReceiptEntity>()
          .getAll()
          .single
          .outcome,
      'failed',
    );
  });

  test('noChange repair fails closed when canonical state is absent', () async {
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
    await gateway.repair(request: request, correctedDecoder: decoder);
    store.box<CloudKitV2QuarantineRepairReceiptEntity>().removeAll();
    adapter.existingEntityKeys.clear();

    final result = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_canonical_artifact_missing');
    expect(adapter.applyCalls, 1);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
    expect(store.box<CloudRecordMapEntity>().count(), 1);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
  });

  test('decoder failure writes only a failure receipt', () async {
    final decoder = _Decoder.failure();
    final before = _controlState(store);

    final result = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.failureCategory, CloudFailureCategory.malformedRecord);
    expect(result.safeCode, 'quarantine_repair_decode_failed');
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    expect(_controlState(store), before);
    final receipt = store
        .box<CloudKitV2QuarantineRepairReceiptEntity>()
        .getAll()
        .single;
    expect(receipt.outcome, 'failed');
    expect(receipt.failureCategory, CloudFailureCategory.malformedRecord.name);

    final retry = await gateway.repair(
      request: request,
      correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );
    expect(
      retry.disposition,
      CloudKitV2QuarantineRepairDisposition.alreadyFailed,
    );
    expect(decoder.calls, 1);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
  });

  test(
    'rejects a decoded payload whose parent disagrees with its snapshot',
    () async {
      final result = await gateway.repair(
        request: request,
        correctedDecoder: _Decoder(
          _decoded(
            scope,
            request.changeIdHash,
            7,
            parentKey: _digest('parent'),
            mismatchPayloadParent: true,
          ),
        ),
      );

      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.safeCode, 'quarantine_repair_decoded_parent_mismatch');
      expect(adapter.applyCalls, 0);
      expect(store.box<CloudRecordMapEntity>().count(), 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    },
  );

  test('does not repair across a pending sequence predecessor', () async {
    final predecessor = _entry(scope, sequence: 1, changeId: _digest('prior'));
    final predecessorRow = CloudInboxChangeEntity(
      changeKey: _changeKey(scope, predecessor.change.changeId),
      changeIdHash: predecessor.change.changeId,
      scopeKey: _scopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      serverRecordIdHash: predecessor.change.recordIdHash,
      etagHash: predecessor.change.etagHash,
      changeType: predecessor.change.type.name,
      encryptedServerRecordId: predecessor.change.encryptedServerRecordId,
      protectedSystemFieldsRef:
          predecessor.change.protectedSystemFieldsReference,
      encryptedPayloadRef: predecessor.change.encryptedPayloadReference,
      payloadSha256: predecessor.change.payloadSha256,
      batchId: predecessor.batchId,
      generation: predecessor.generation,
      fetchSequence: predecessor.sequence,
      status: CloudInboxStatus.pending.index,
      createdAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
    store.box<CloudInboxChangeEntity>().put(predecessorRow);
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));

    final result = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(
      result.safeCode,
      'quarantine_repair_sequence_predecessor_not_applied',
    );
    expect(decoder.calls, 1);
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test('defers a repaired child until its parent is present', () async {
    final decoder = _Decoder(
      _decoded(
        scope,
        request.changeIdHash,
        7,
        parentKey: _digest('missing-parent'),
      ),
    );

    final result = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_parent_not_ready');
    expect(decoder.calls, 1);
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test('retries a dependency after the parent becomes available', () async {
    final decoder = _Decoder(
      _decoded(scope, request.changeIdHash, 7, parentKey: _digest('parent')),
    );

    final first = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );
    expect(first.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);

    adapter.parentExists = true;
    final second = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );
    expect(second.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    expect(store.box<CloudRecordMapEntity>().count(), 1);
    expect(adapter.applyCalls, 1);
  });

  test('blocks every earlier non-applied inbox state', () async {
    final predecessor = _entry(
      scope,
      sequence: 1,
      changeId: _digest('quarantined-prior'),
    );
    store.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: _changeKey(scope, predecessor.change.changeId),
        changeIdHash: predecessor.change.changeId,
        scopeKey: _scopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        serverRecordIdHash: predecessor.change.recordIdHash,
        etagHash: predecessor.change.etagHash,
        changeType: predecessor.change.type.name,
        encryptedServerRecordId: predecessor.change.encryptedServerRecordId,
        protectedSystemFieldsRef:
            predecessor.change.protectedSystemFieldsReference,
        encryptedPayloadRef: predecessor.change.encryptedPayloadReference,
        payloadSha256: predecessor.change.payloadSha256,
        batchId: predecessor.batchId,
        generation: predecessor.generation,
        fetchSequence: predecessor.sequence,
        status: CloudInboxStatus.quarantined.index,
        createdAtMs: now.millisecondsSinceEpoch,
        updatedAtMs: now.millisecondsSinceEpoch,
        completedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final result = await gateway.repair(
      request: request,
      correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(
      result.safeCode,
      'quarantine_repair_sequence_predecessor_not_applied',
    );
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test('rejects a tombstone even when its decoder returns an upsert', () async {
    final inbox = store.box<CloudInboxChangeEntity>().getAll().single
      ..changeType = CloudChangeType.delete.name
      ..isTombstone = true;
    store.box<CloudInboxChangeEntity>().put(inbox);
    final replay = store.box<CloudSemanticReplayEntity>().getAll().single
      ..changeType = CloudChangeType.delete.name;
    store.box<CloudSemanticReplayEntity>().put(replay);

    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
    final result = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.failureCategory, CloudFailureCategory.malformedRecord);
    expect(decoder.calls, 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
  });

  test('rejects a repair scope outside the message zone', () async {
    final wrongZone = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'chatManateeZone',
    );
    final wrongRequest = CloudKitV2QuarantineRepairRequest(
      scope: wrongZone,
      generation: request.generation,
      changeIdHash: request.changeIdHash,
      correction: request.correction,
    );
    final decoder = _Decoder(_decoded(wrongZone, request.changeIdHash, 7));

    final result = await gateway.repair(
      request: wrongRequest,
      correctedDecoder: decoder,
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_zone_not_allowlisted');
    expect(decoder.calls, 0);
  });

  test(
    'rejects a record-map collision and keeps the collision intact',
    () async {
      final otherKey = _digest('other-logical');
      store.box<CloudRecordMapEntity>().put(
        CloudRecordMapEntity(
          mapKey: _recordMapKey(scope, otherKey),
          scopeKey: _scopeKey(scope),
          accountFingerprint: scope.accountFingerprint,
          zone: scope.zone,
          logicalEntityKeyHash: otherKey,
          serverRecordIdHash: _digest('record'),
          generation: request.generation,
          encryptedServerRecordId: _protected('server'),
          etagHash: _digest('etag'),
          encryptedRawRecordRef: _protected('payload'),
          updatedAtMs: now.millisecondsSinceEpoch,
        ),
      );

      final result = await gateway.repair(
        request: request,
        correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.failureCategory, CloudFailureCategory.conflict);
      expect(result.safeCode, 'quarantine_repair_record_mapping_conflict');
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    },
  );

  test('reproves and upgrades an exact generation-zero record map', () async {
    final map = CloudRecordMapEntity(
      mapKey: _recordMapKey(scope, _digest('logical')),
      scopeKey: _scopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      logicalEntityKeyHash: _digest('logical'),
      serverRecordIdHash: _digest('record'),
      generation: 0,
      encryptedServerRecordId: _protected('server'),
      etagHash: _digest('etag'),
      encryptedRawRecordRef: _protected('payload'),
      updatedAtMs: now.millisecondsSinceEpoch,
    );
    final mapId = store.box<CloudRecordMapEntity>().put(map);

    final result = await gateway.repair(
      request: request,
      correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );

    final upgraded = store.box<CloudRecordMapEntity>().get(mapId)!;
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
    expect(upgraded.id, mapId);
    expect(upgraded.generation, request.generation);
  });

  test('rejects a generation-zero map that fails exact reproof', () async {
    final map = CloudRecordMapEntity(
      mapKey: _recordMapKey(scope, _digest('logical')),
      scopeKey: _scopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      logicalEntityKeyHash: _digest('logical'),
      serverRecordIdHash: _digest('record'),
      generation: 0,
      encryptedServerRecordId: _protected('server'),
      etagHash: _digest('wrong-etag'),
      encryptedRawRecordRef: _protected('payload'),
      updatedAtMs: now.millisecondsSinceEpoch,
    );
    final mapId = store.box<CloudRecordMapEntity>().put(map);

    final result = await gateway.repair(
      request: request,
      correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );

    final retained = store.box<CloudRecordMapEntity>().get(mapId)!;
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(
      result.safeCode,
      'quarantine_repair_record_map_legacy_reproof_failed',
    );
    expect(retained.id, mapId);
    expect(retained.generation, 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
  });

  test(
    'rejects a stale decoded entry before canonical or metadata writes',
    () async {
      final decoder = _StaleDecoder(
        store,
        _decoded(scope, request.changeIdHash, 7),
      );
      final result = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );
      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.safeCode, 'quarantine_repair_terminal_state_changed');
      expect(adapter.applyCalls, 0);
      expect(store.box<CloudRecordMapEntity>().count(), 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    },
  );

  test('rejects a server timestamp change between decode and commit', () async {
    final decoder = _StaleDecoder(
      store,
      _decoded(scope, request.changeIdHash, 7),
      mutateServerModifiedAt: true,
    );
    final result = await gateway.repair(
      request: request,
      correctedDecoder: decoder,
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_terminal_state_changed');
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test(
    'missing terminal row after decode stays retryable without a receipt',
    () async {
      final decoder = _StaleDecoder(
        store,
        _decoded(scope, request.changeIdHash, 7),
        removeTerminal: true,
      );

      final result = await gateway.repair(
        request: request,
        correctedDecoder: decoder,
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.safeCode, 'quarantine_repair_terminal_state_changed');
      expect(adapter.applyCalls, 0);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    },
  );

  test('fails closed on an inconsistent exact snapshot key', () async {
    store.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey:
            'semantic-snapshot4:${_scopeGenerationKey(scope, 7)}:message:${_digest('logical')}',
        scopeGenerationKey: _scopeGenerationKey(scope, 7),
        scopeKey: _scopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: 6,
        entityKind: CloudEntityKind.message.name,
        logicalEntityKeyHash: _digest('logical'),
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    final result = await gateway.repair(
      request: request,
      correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_snapshot_scope_mismatch');
    expect(store.box<CloudRecordMapEntity>().count(), 0);
  });

  test(
    'rolls back the record map when canonical apply fails after a write',
    () async {
      adapter.failAfterMetadataWrite = true;
      final before = _controlState(store);

      final result = await gateway.repair(
        request: request,
        correctedDecoder: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(store.box<CloudRecordMapEntity>().count(), 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
      expect(_controlState(store), before);
    },
  );
}

final class _Decoder implements CloudSemanticDecoder {
  _Decoder(this.value) : failureValue = null;
  _Decoder.failure() : value = null, failureValue = true;

  final CloudDecodedMutation? value;
  final bool? failureValue;
  int calls = 0;

  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async {
    calls++;
    if (failureValue == true) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    return value!;
  }
}

final class _StaleDecoder implements CloudSemanticDecoder {
  _StaleDecoder(
    this.store,
    this.value, {
    this.mutateServerModifiedAt = false,
    this.removeTerminal = false,
  });

  final Store store;
  final CloudDecodedMutation value;
  final bool mutateServerModifiedAt;
  final bool removeTerminal;

  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async {
    if (removeTerminal) {
      store.box<CloudInboxChangeEntity>().removeAll();
      return value;
    }
    final row = store.box<CloudInboxChangeEntity>().getAll().single;
    if (mutateServerModifiedAt) {
      row.serverModifiedAtMs++;
    } else {
      row.payloadSha256 = _sha256('changed-after-decode');
    }
    store.box<CloudInboxChangeEntity>().put(row);
    return value;
  }
}

final class _Adapter implements CloudCanonicalSemanticEntityAdapter {
  _Adapter(this.store);

  @override
  final Store store;

  int applyCalls = 0;
  bool parentExists = false;
  bool failAfterMetadataWrite = false;
  final Set<String> existingEntityKeys = <String>{};

  @override
  bool isActiveAccountScope({
    required CloudSyncScope scope,
    required int generation,
  }) => true;

  @override
  bool entityExists({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) => parentExists || existingEntityKeys.contains(logicalEntityKeyHash);

  @override
  CloudCanonicalSemanticMutationReceipt applyEntity({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    applyCalls++;
    if (failAfterMetadataWrite) {
      final row = store.box<CloudInboxChangeEntity>().getAll().single
        ..retryCount = 99;
      store.box<CloudInboxChangeEntity>().put(row);
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'test_canonical_apply_failed',
      );
    }
    existingEntityKeys.add(snapshot.logicalEntityKeyHash);
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  @override
  CloudCanonicalSemanticMutationReceipt applyTombstone({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticTombstone tombstone,
  }) => throw StateError('tombstones are outside this repair lane');
}

CloudSyncScope _scope() => CloudSyncScope(
  accountFingerprint: _digest('account'),
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
);

CloudInboxEntry _entry(
  CloudSyncScope scope, {
  required int sequence,
  String? changeId,
}) {
  final change = CloudFetchedChange(
    changeId: changeId ?? _digest('change'),
    recordIdHash: _digest('record'),
    etagHash: _digest('etag'),
    type: CloudChangeType.save,
    encryptedServerRecordId: _protected('server'),
    protectedSystemFieldsReference: _protected('system'),
    encryptedPayloadReference: _protected('payload'),
    payloadSha256: _sha256('payload'),
  );
  return CloudInboxEntry(
    scope: scope,
    sequence: sequence,
    change: change,
    status: CloudInboxStatus.quarantined,
    attemptCount: 1,
    createdAt: DateTime.utc(2026, 8, 27, 11),
    batchId: 'batch-1',
    generation: 7,
    completedAt: DateTime.utc(2026, 8, 27, 11, 30),
    lastFailure: CloudFailureCategory.conflict,
  );
}

CloudDecodedMutation _decoded(
  CloudSyncScope scope,
  String changeId,
  int generation, {
  String? parentKey,
  bool mismatchPayloadParent = false,
}) {
  final key = _digest('logical');
  final payloadParentKey = mismatchPayloadParent
      ? _digest('different-parent')
      : parentKey;
  return CloudDecodedMutation.upsert(
    scope: scope,
    generation: generation,
    changeId: changeId,
    snapshot: CloudSemanticSnapshot(
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: key,
      parentLogicalKeyHash: parentKey,
      immutableContentDigest: _digest('immutable'),
      createdAt: DateTime.utc(2026, 8, 27, 10),
      etagHash: _digest('etag'),
      encryptedRawRecordReference: _protected('payload'),
    ),
    payload: CloudMessageEntityPayload(
      logicalEntityKeyHash: key,
      canonicalGuid: 'message-guid',
      chatAliasKeyHash: _digest('chat'),
      chatIdentifier: 'iMessage;-;chat',
      body: 'transient body',
      senderHandle: 'sender@example.com',
      replyParentLogicalKeyHash: payloadParentKey,
      replyParentCanonicalGuid: payloadParentKey == null ? null : 'parent-guid',
      replyParentPart: payloadParentKey == null ? null : '0',
    ),
  );
}

void _seed(
  Store store,
  CloudSyncScope scope,
  CloudInboxEntry entry,
  DateTime now,
) {
  final scopeKey = _scopeKey(scope);
  final scopeGenerationKey = _scopeGenerationKey(scope, entry.generation);
  final change = entry.change;
  store.runInTransaction(TxMode.write, () {
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: entry.generation,
        fetchedTokenCiphertext: 'opaque-token-ciphertext',
        fetchedSequence: entry.sequence,
        appliedSequence: entry.sequence,
        mutationRevisionCounter: 9,
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    store.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: 'op1:${'a'.padRight(64, 'a')}',
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: _digest('outbox'),
        action: CloudOutboxAction.save.index,
        mutationRevision: 9,
        checkpointGeneration: entry.generation,
        encryptedPayloadRef: _protected('outbox'),
        payloadSha256: _sha256('outbox'),
        createdAtMs: now.millisecondsSinceEpoch,
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    store.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: _changeKey(scope, change.changeId),
        changeIdHash: change.changeId,
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        serverRecordIdHash: change.recordIdHash,
        etagHash: change.etagHash,
        changeType: change.type.name,
        encryptedServerRecordId: change.encryptedServerRecordId,
        protectedSystemFieldsRef: change.protectedSystemFieldsReference,
        encryptedPayloadRef: change.encryptedPayloadReference,
        payloadSha256: change.payloadSha256,
        batchId: entry.batchId,
        generation: entry.generation,
        fetchSequence: entry.sequence,
        status: CloudInboxStatus.quarantined.index,
        isTombstone: false,
        failureCategory: CloudFailureCategory.conflict.name,
        retryCount: 1,
        createdAtMs: entry.createdAt.millisecondsSinceEpoch,
        updatedAtMs: now.millisecondsSinceEpoch,
        completedAtMs: entry.completedAt!.millisecondsSinceEpoch,
      ),
    );
    store.box<CloudSemanticReplayEntity>().put(
      CloudSemanticReplayEntity(
        replayKey:
            'semantic-replay4:$scopeGenerationKey:${_sha256(change.changeId)}',
        scopeGenerationKey: scopeGenerationKey,
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: entry.generation,
        changeIdHash: change.changeId,
        serverRecordIdHash: change.recordIdHash,
        payloadSha256: change.payloadSha256,
        protectedPayloadReferenceHash: _sha256(
          'semantic-payload-reference\u001f${change.encryptedPayloadReference}',
        ),
        inboxSequence: entry.sequence,
        changeType: change.type.name,
        terminalOutcome: 'quarantined',
        terminalSafeCode: 'semantic_conflict',
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
  });
}

List<Object?> _controlState(Store store) => [
  ...store.box<CloudSyncCheckpointEntity>().getAll().expand(
    (row) => [
      row.checkpointKey,
      row.fetchedTokenCiphertext,
      row.pendingFetchedTokenCiphertext,
      row.generation,
      row.fetchedSequence,
      row.appliedSequence,
      row.mutationRevisionCounter,
    ],
  ),
  ...store.box<CloudOutboxOperationEntity>().getAll().expand(
    (row) => [
      row.operationId,
      row.state,
      row.encryptedPayloadRef,
      row.payloadSha256,
      row.checkpointGeneration,
    ],
  ),
  ...store.box<CloudInboxChangeEntity>().getAll().expand(
    (row) => [
      row.changeKey,
      row.status,
      row.failureCategory,
      row.retryCount,
      row.completedAtMs,
      row.encryptedPayloadRef,
      row.protectedSystemFieldsRef,
    ],
  ),
  ...store.box<CloudSemanticReplayEntity>().getAll().expand(
    (row) => [
      row.replayKey,
      row.terminalOutcome,
      row.terminalSafeCode,
      row.changeIdHash,
      row.protectedPayloadReferenceHash,
    ],
  ),
];

String _scopeKey(CloudSyncScope scope) => 'scope2:${_sha256(scope.storageKey)}';

String _scopeGenerationKey(CloudSyncScope scope, int generation) =>
    'semantic-generation4:${_sha256('${_scopeKey(scope)}\u001f$generation')}';

String _changeKey(CloudSyncScope scope, String changeId) =>
    'change:${_sha256('${scope.storageKey}\u001fchange\u001f$changeId')}';

String _recordMapKey(CloudSyncScope scope, String logicalEntityKeyHash) =>
    'record-map:${_sha256('${scope.storageKey}\u001frecord-map\u001f$logicalEntityKeyHash')}';

String _digest(String value) => base64Url
    .encode(sha256.convert(utf8.encode(value)).bytes)
    .replaceAll('=', '');

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();

String _protected(String value) => 'obcs2.ref.${_digest(value)}';
