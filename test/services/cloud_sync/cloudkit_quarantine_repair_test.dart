import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 27, 12);
  final scope = _scope();
  const leaseFence = CloudCoordinatorLeaseFence(
    ownerId: 'quarantine-repair-test-owner',
    generation: 7,
  );
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
    gateway = CloudKitV2QuarantineRepairGateway.testOnly(
      store: store,
      canonicalAdapter: adapter,
      clock: () => now,
    );
    final entry = _entry(scope, sequence: 1);
    _seed(store, scope, entry, now);
    request = CloudKitV2QuarantineRepairRequest(
      scope: scope,
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
      generation: entry.generation,
      changeIdHash: entry.change.changeId,
      correction: CloudKitV2QuarantineRepairAllowlist.only,
      leaseFence: leaseFence,
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
        testOnlyCapability: decoder,
      );
      expect(
        disabledResult.disposition,
        CloudKitV2QuarantineRepairDisposition.disabled,
      );
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);

      final unallowlisted = CloudKitV2QuarantineRepairRequest(
        scope: scope,
        persistenceLane: CloudSyncPersistenceLane.semanticV2,
        generation: request.generation,
        changeIdHash: request.changeIdHash,
        correction: const CloudKitV2ConverterCorrection(
          converterRevision: 'cloud-canonical-converter-r3',
          correctionName: 'unreviewed-correction',
          expectedOriginalTerminalSafeCode: 'semantic_conflict',
          expectedOriginalQuarantineReason: CloudFailureCategory.conflict,
        ),
        leaseFence: leaseFence,
      );
      final result = await gateway.repair(
        request: unallowlisted,
        testOnlyCapability: decoder,
      );
      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.safeCode, 'quarantine_repair_correction_not_allowlisted');
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    },
  );

  test('rejects out-of-scope service as a repair source category', () {
    expect(
      () => CloudKitV2QuarantineRepairRequest(
        scope: scope,
        persistenceLane: CloudSyncPersistenceLane.semanticV2,
        generation: request.generation,
        changeIdHash: request.changeIdHash,
        correction: const CloudKitV2ConverterCorrection(
          converterRevision: 'cloud-canonical-converter-r3',
          correctionName: 'out-of-scope-service-reclassification',
          expectedOriginalTerminalSafeCode: 'semantic_out_of_scope_sms_family',
          expectedOriginalQuarantineReason:
              CloudFailureCategory.outOfScopeService,
        ),
        leaseFence: leaseFence,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          'cloudkit_quarantine_repair_correction_invalid',
        ),
      ),
    );
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test(
    'repairs quarantine and advances its applied checkpoint atomically',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: decoder,
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.repaired,
      );
      expect(result.succeeded, isTrue);
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
      expect(receipt.originalPayloadSha256, _sha256('payload'));
      expect(
        receipt.originalQuarantineReason,
        CloudFailureCategory.conflict.name,
      );
      expect(receipt.originalTerminalSafeCode, 'semantic_conflict');
      expect(
        receipt.evidenceDigestVersion,
        'cloudkit-quarantine-repair-evidence-v2',
      );
      expect(receipt.evidenceDigestSha256, matches(RegExp(r'^[0-9a-f]{64}$')));

      final inbox = store.box<CloudInboxChangeEntity>().getAll().single;
      final replay = store.box<CloudSemanticReplayEntity>().getAll().single;
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
      expect(inbox.status, CloudInboxStatus.applied.index);
      expect(inbox.failureCategory, isNull);
      expect(inbox.nextEligibleAtMs, 0);
      expect(checkpoint.appliedSequence, 1);
      expect(checkpoint.fetchedTokenCiphertext, 'opaque-token-ciphertext');
      expect(checkpoint.pendingFetchedTokenCiphertext, isNull);
      expect(checkpoint.pendingBatchId, isNull);
      expect(replay.terminalOutcome, 'quarantined');
      expect(replay.terminalSafeCode, 'semantic_conflict');
    },
  );

  test('same receipt is idempotent and immutable', () async {
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));

    final first = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );
    final stored = store
        .box<CloudKitV2QuarantineRepairReceiptEntity>()
        .getAll()
        .single;
    final storedCreatedAt = stored.createdAtMs;
    final controlAfterFirstRepair = _controlState(store);
    final second = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );

    expect(first.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
    expect(
      second.disposition,
      CloudKitV2QuarantineRepairDisposition.alreadyRepaired,
    );
    expect(adapter.applyCalls, 1);
    expect(_controlState(store), controlAfterFirstRepair);
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

  test('rejects contradictory repaired receipt failure metadata', () async {
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
    final first = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );
    expect(first.disposition, CloudKitV2QuarantineRepairDisposition.repaired);

    final receiptBox = store.box<CloudKitV2QuarantineRepairReceiptEntity>();
    receiptBox.put(
      receiptBox.getAll().single
        ..failureCategory = CloudFailureCategory.conflict.name
        ..safeCode = 'contradictory_repaired_receipt',
    );
    final result = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.failureCategory, CloudFailureCategory.localStorage);
    expect(result.safeCode, 'quarantine_repair_receipt_binding_invalid');
    expect(adapter.applyCalls, 1);
    expect(receiptBox.count(), 1);
  });

  test('rejects a failed receipt with a logical entity binding', () async {
    final initial = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(
        _decoded(
          scope,
          request.changeIdHash,
          7,
          snapshotDigest: _digest('mismatched-content'),
        ),
      ),
    );
    expect(initial.disposition, CloudKitV2QuarantineRepairDisposition.failed);

    final receiptBox = store.box<CloudKitV2QuarantineRepairReceiptEntity>();
    receiptBox.put(
      receiptBox.getAll().single..logicalEntityKeyHash = _digest('logical'),
    );
    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.failureCategory, CloudFailureCategory.localStorage);
    expect(result.safeCode, 'quarantine_repair_receipt_binding_invalid');
    expect(adapter.applyCalls, 0);
    expect(receiptBox.count(), 1);
  });

  test(
    'repaired receipt is not trusted after its record map disappears',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
      final first = await gateway.repair(
        request: request,
        testOnlyCapability: decoder,
      );
      expect(first.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
      store.box<CloudRecordMapEntity>().removeAll();

      final second = await gateway.repair(
        request: request,
        testOnlyCapability: decoder,
      );

      expect(
        second.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(second.failureCategory, CloudFailureCategory.localStorage);
      expect(second.safeCode, 'quarantine_repair_record_mapping_missing');
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    },
  );

  test(
    'repaired receipt is not trusted after its terminal pair changes',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
      await gateway.repair(request: request, testOnlyCapability: decoder);
      final replay = store.box<CloudSemanticReplayEntity>().getAll().single
        ..terminalOutcome = 'applied';
      store.box<CloudSemanticReplayEntity>().put(replay);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: decoder,
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(result.safeCode, 'quarantine_repair_terminal_pair_invalid');
    },
  );

  test(
    'repaired receipt is not trusted after its original payload evidence changes',
    () async {
      final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
      await gateway.repair(request: request, testOnlyCapability: decoder);
      final changedPayloadHash = _sha256('changed-terminal-payload');
      final inbox = store.box<CloudInboxChangeEntity>().getAll().single
        ..payloadSha256 = changedPayloadHash;
      final replay = store.box<CloudSemanticReplayEntity>().getAll().single
        ..payloadSha256 = changedPayloadHash;
      store.box<CloudInboxChangeEntity>().put(inbox);
      store.box<CloudSemanticReplayEntity>().put(replay);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: decoder,
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.safeCode, 'quarantine_repair_existing_receipt_stale');
    },
  );

  test('repaired receipt detects non-key terminal evidence mutation', () async {
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
    await gateway.repair(request: request, testOnlyCapability: decoder);
    final inbox = store.box<CloudInboxChangeEntity>().getAll().single
      ..updatedAtMs += 1;
    store.box<CloudInboxChangeEntity>().put(inbox);

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_existing_evidence_stale');
    expect(adapter.applyCalls, 1);
  });

  test('repaired receipt detects snapshot evidence mutation', () async {
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
    await gateway.repair(request: request, testOnlyCapability: decoder);
    final snapshot = store.box<CloudSemanticSnapshotEntity>().getAll().single
      ..updatedAtMs += 1;
    store.box<CloudSemanticSnapshotEntity>().put(snapshot);

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_existing_evidence_stale');
    expect(adapter.applyCalls, 1);
  });

  test(
    'repair keys include the named correction as well as its revision',
    () async {
      final disabled = CloudKitV2QuarantineRepairGateway(
        store: store,
        canonicalAdapter: adapter,
      );
      final alternate = CloudKitV2QuarantineRepairRequest(
        scope: request.scope,
        persistenceLane: CloudSyncPersistenceLane.semanticV2,
        generation: request.generation,
        changeIdHash: request.changeIdHash,
        correction: const CloudKitV2ConverterCorrection(
          converterRevision: 'cloud-canonical-converter-r2',
          correctionName: 'another-reviewed-shape',
          expectedOriginalTerminalSafeCode: 'semantic_conflict',
          expectedOriginalQuarantineReason: CloudFailureCategory.conflict,
        ),
        leaseFence: leaseFence,
      );

      final first = await disabled.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      final second = await disabled.repair(
        request: alternate,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(first.repairKey, startsWith('semantic-repair2:'));
      expect(second.repairKey, isNot(first.repairKey));
    },
  );

  test(
    'noChange repair validates canonical and record-map artifacts',
    () async {
      final decoded = _decoded(scope, request.changeIdHash, 7);
      _seedLocalSnapshot(
        store,
        scope,
        request,
        now,
        parentKey: null,
        immutableContentDigest: decoded.snapshot!.immutableContentDigest,
      );
      adapter.existingEntityKeys.add(_digest('logical'));

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(decoded),
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.repaired,
      );
      expect(adapter.applyCalls, 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    },
  );

  test('noChange repair fails closed when its record map is absent', () async {
    final decoded = _decoded(scope, request.changeIdHash, 7);
    _seedLocalSnapshot(
      store,
      scope,
      request,
      now,
      parentKey: null,
      immutableContentDigest: decoded.snapshot!.immutableContentDigest,
    );
    store.box<CloudRecordMapEntity>().removeAll();
    adapter.existingEntityKeys.add(_digest('logical'));

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(decoded),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_record_mapping_missing');
    expect(adapter.applyCalls, 0);
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
    final decoded = _decoded(scope, request.changeIdHash, 7);
    _seedLocalSnapshot(
      store,
      scope,
      request,
      now,
      parentKey: null,
      immutableContentDigest: decoded.snapshot!.immutableContentDigest,
    );

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(decoded),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_canonical_artifact_missing');
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
    expect(store.box<CloudRecordMapEntity>().count(), 1);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
  });

  test(
    'invalid materialized correction writes only a bound failure receipt',
    () async {
      final decoder = _Decoder(
        _decoded(
          scope,
          request.changeIdHash,
          7,
          snapshotDigest: _digest('mismatched-content'),
        ),
      );
      final before = _controlState(store);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: decoder,
      );

      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.failureCategory, CloudFailureCategory.malformedRecord);
      expect(result.safeCode, 'quarantine_repair_payload_content_mismatch');
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
      expect(
        receipt.failureCategory,
        CloudFailureCategory.malformedRecord.name,
      );
      expect(receipt.inboxSequence, 1);
      expect(receipt.serverRecordIdHash, _digest('record'));
      expect(receipt.originalPayloadSha256, _sha256('payload'));
      expect(
        receipt.originalQuarantineReason,
        CloudFailureCategory.conflict.name,
      );
      expect(receipt.originalTerminalSafeCode, 'semantic_conflict');

      final retry = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      expect(
        retry.disposition,
        CloudKitV2QuarantineRepairDisposition.alreadyFailed,
      );
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    },
  );

  test(
    'rejects unknown or malformed persisted failed-receipt categories before terminal reuse',
    () async {
      final initial = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(
          _decoded(
            scope,
            request.changeIdHash,
            7,
            snapshotDigest: _digest('mismatched-content'),
          ),
        ),
      );
      expect(initial.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      final receiptBox = store.box<CloudKitV2QuarantineRepairReceiptEntity>();
      for (final invalidCategory in <String>[
        CloudFailureCategory.unknown.name,
        CloudFailureCategory.outOfScopeService.name,
        'unrecognized_persisted_category',
      ]) {
        final receipt = receiptBox.getAll().single
          ..failureCategory = invalidCategory;
        receiptBox.put(receipt);
        final before = _controlState(store);

        final retry = await gateway.repair(
          request: request,
          testOnlyCapability: _Decoder(
            _decoded(scope, request.changeIdHash, 7),
          ),
        );

        expect(
          retry.disposition,
          CloudKitV2QuarantineRepairDisposition.retryable,
        );
        expect(retry.failureCategory, CloudFailureCategory.localStorage);
        expect(retry.safeCode, 'quarantine_repair_receipt_binding_invalid');
        expect(adapter.applyCalls, 0);
        expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
        expect(store.box<CloudRecordMapEntity>().count(), 0);
        expect(receiptBox.count(), 1);
        expect(_controlState(store), before);
      }
    },
  );

  test('does not create an out-of-scope-service failure receipt', () async {
    adapter.applyFailureCategory = CloudFailureCategory.outOfScopeService;
    final before = _controlState(store);

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.failureCategory, CloudFailureCategory.localStorage);
    expect(result.safeCode, 'quarantine_repair_receipt_binding_invalid');
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
    expect(_controlState(store), before);
  });

  test(
    'rejects body, sender, timestamp, and flag content mismatches',
    () async {
      final baseline = _decoded(scope, request.changeIdHash, 7);
      final baselineDigest = baseline.snapshot!.immutableContentDigest!;
      final mismatches = <CloudDecodedMutation>[
        _decoded(
          scope,
          request.changeIdHash,
          7,
          body: 'changed body',
          snapshotDigest: baselineDigest,
        ),
        _decoded(
          scope,
          request.changeIdHash,
          7,
          senderHandle: 'other@example.com',
          snapshotDigest: baselineDigest,
        ),
        _decoded(
          scope,
          request.changeIdHash,
          7,
          createdAt: DateTime.utc(2026, 8, 27, 10, 1),
          snapshotDigest: baselineDigest,
        ),
        _decoded(
          scope,
          request.changeIdHash,
          7,
          knownFlags: const CloudSemanticKnownMessageFlags(
            fromMe: true,
            delivered: true,
            read: true,
            hasDataDetectorResults: true,
            deliveredQuietly: false,
            didNotifyRecipient: true,
          ),
          snapshotDigest: baselineDigest,
        ),
      ];
      for (final mutation in mismatches) {
        store.box<CloudKitV2QuarantineRepairReceiptEntity>().removeAll();
        final result = await gateway.repair(
          request: request,
          testOnlyCapability: _Decoder(mutation),
        );
        expect(
          result.disposition,
          CloudKitV2QuarantineRepairDisposition.failed,
        );
        expect(result.safeCode, 'quarantine_repair_payload_content_mismatch');
        expect(adapter.applyCalls, 0);
        expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
        expect(store.box<CloudRecordMapEntity>().count(), 0);
      }
    },
  );

  test(
    'old repaired receipts return a migration-safe retryable result',
    () async {
      final correction = _Decoder(_decoded(scope, request.changeIdHash, 7));
      final first = await gateway.repair(
        request: request,
        testOnlyCapability: correction,
      );
      expect(first.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
      final receipt =
          store.box<CloudKitV2QuarantineRepairReceiptEntity>().getAll().single
            ..evidenceDigestVersion = null
            ..evidenceDigestSha256 = null;
      store.box<CloudKitV2QuarantineRepairReceiptEntity>().put(receipt);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: correction,
      );
      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(result.safeCode, 'quarantine_repair_receipt_migration_required');
    },
  );

  test(
    'old failed receipts return a migration-safe retryable result',
    () async {
      final invalid = _Decoder(
        _decoded(
          scope,
          request.changeIdHash,
          7,
          snapshotDigest: _digest('mismatched-content'),
        ),
      );
      final first = await gateway.repair(
        request: request,
        testOnlyCapability: invalid,
      );
      expect(first.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      final receipt =
          store.box<CloudKitV2QuarantineRepairReceiptEntity>().getAll().single
            ..evidenceDigestVersion = null
            ..evidenceDigestSha256 = null;
      store.box<CloudKitV2QuarantineRepairReceiptEntity>().put(receipt);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.failureCategory, CloudFailureCategory.localStorage);
      expect(result.safeCode, 'quarantine_repair_receipt_migration_required');
    },
  );

  test(
    'stale failed receipts remain retryable after the lease expires',
    () async {
      final invalid = _Decoder(
        _decoded(
          scope,
          request.changeIdHash,
          7,
          snapshotDigest: _digest('mismatched-content'),
        ),
      );
      final first = await gateway.repair(
        request: request,
        testOnlyCapability: invalid,
      );
      expect(first.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      final lease = store.box<CloudSyncLeaseEntity>().getAll().single
        ..expiresAtMs = 0;
      store.box<CloudSyncLeaseEntity>().put(lease);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.safeCode, 'semantic_coordinator_lease_fence_lost');
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    },
  );

  test(
    'rejects a decoded payload whose parent disagrees with its snapshot',
    () async {
      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(
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
    _moveSeededTargetToSequence2(store);
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
      testOnlyCapability: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(
      result.safeCode,
      'quarantine_repair_sequence_predecessor_not_applied',
    );
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test(
    'rejects a missing predecessor even when the checkpoint passed it',
    () async {
      _moveSeededTargetToSequence2(store);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(
        result.safeCode,
        'quarantine_repair_sequence_gap_or_pruned_prefix',
      );
      expect(adapter.applyCalls, 0);
    },
  );

  test('rejects duplicate rows at the target sequence', () async {
    final duplicate = _entry(
      scope,
      sequence: 1,
      changeId: _digest('duplicate-target'),
    );
    _putInboxRow(
      store,
      scope,
      duplicate,
      now,
      status: CloudInboxStatus.applied,
    );

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_duplicate_target_sequence');
    expect(adapter.applyCalls, 0);
  });

  test('rejects duplicate rows at a predecessor sequence', () async {
    _moveSeededTargetToSequence2(store);
    _putInboxRow(
      store,
      scope,
      _entry(scope, sequence: 1, changeId: _digest('predecessor-a')),
      now,
      status: CloudInboxStatus.applied,
    );
    _putInboxRow(
      store,
      scope,
      _entry(scope, sequence: 1, changeId: _digest('predecessor-b')),
      now,
      status: CloudInboxStatus.applied,
    );

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_duplicate_predecessor_sequence');
    expect(adapter.applyCalls, 0);
  });

  test(
    'rejects a checkpoint that has not durably reached the target',
    () async {
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single
        ..fetchedSequence = 0
        ..appliedSequence = 0;
      store.box<CloudSyncCheckpointEntity>().put(checkpoint);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.safeCode, 'quarantine_repair_checkpoint_sequence_unproven');
      expect(adapter.applyCalls, 0);
    },
  );

  test(
    'fails closed when a legacy checkpoint advanced past quarantine',
    () async {
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single
        ..appliedSequence = 1;
      store.box<CloudSyncCheckpointEntity>().put(checkpoint);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(
        result.safeCode,
        'quarantine_repair_legacy_checkpoint_advanced_past_quarantine',
      );
      expect(adapter.applyCalls, 0);
      expect(
        store.box<CloudInboxChangeEntity>().getAll().single.status,
        CloudInboxStatus.quarantined.index,
      );
    },
  );

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
      testOnlyCapability: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_parent_not_ready');
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
      testOnlyCapability: decoder,
    );
    expect(first.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);

    adapter.parentExists = true;
    final second = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );
    expect(second.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
    expect(store.box<CloudRecordMapEntity>().count(), 1);
    expect(adapter.applyCalls, 1);
  });

  test('blocks every earlier non-applied inbox state', () async {
    _moveSeededTargetToSequence2(store);
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
      testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(
      result.safeCode,
      'quarantine_repair_sequence_predecessor_not_applied',
    );
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test('a repaired applied predecessor unblocks row N+1', () async {
    _moveSeededTargetToSequence2(store);
    final predecessor = _entry(
      scope,
      sequence: 1,
      changeId: _digest('repaired-prior'),
    );
    _seedTerminalPair(store, scope, predecessor, now);
    final predecessorRequest = CloudKitV2QuarantineRepairRequest(
      scope: scope,
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
      generation: predecessor.generation,
      changeIdHash: predecessor.change.changeId,
      correction: CloudKitV2QuarantineRepairAllowlist.only,
      leaseFence: leaseFence,
    );

    expect(
      (await gateway.repair(
        request: predecessorRequest,
        testOnlyCapability: _Decoder(
          _decoded(scope, predecessor.change.changeId, predecessor.generation),
        ),
      )).disposition,
      CloudKitV2QuarantineRepairDisposition.repaired,
    );

    final child = await gateway.repair(
      request: request,
      testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );
    expect(child.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
    final original = store.box<CloudInboxChangeEntity>().getAll().singleWhere(
      (row) => row.changeIdHash == predecessor.change.changeId,
    );
    expect(original.status, CloudInboxStatus.applied.index);
    expect(
      store.box<CloudSyncCheckpointEntity>().getAll().single.appliedSequence,
      2,
    );
  });

  test(
    'a retained predecessor is terminal without becoming a repair target',
    () async {
      _moveSeededTargetToSequence2(store);
      final predecessor = _entry(
        scope,
        sequence: 1,
        changeId: _digest('retained-prior'),
      );
      _putInboxRow(
        store,
        scope,
        predecessor,
        now,
        status: CloudInboxStatus.retainedUnprojected,
      );
      final before = store.box<CloudInboxChangeEntity>().getAll().singleWhere(
        (row) => row.changeIdHash == predecessor.change.changeId,
      );

      final child = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(child.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
      final retained = store.box<CloudInboxChangeEntity>().getAll().singleWhere(
        (row) => row.changeIdHash == predecessor.change.changeId,
      );
      expect(retained.status, CloudInboxStatus.retainedUnprojected.index);
      expect(retained.encryptedPayloadRef, before.encryptedPayloadRef);
      expect(retained.encryptedServerRecordId, before.encryptedServerRecordId);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 1);
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
      expect(checkpoint.appliedSequence, 2);
      expect(checkpoint.fetchedTokenCiphertext, 'opaque-token-ciphertext');
      expect(checkpoint.pendingBatchId, isNull);
    },
  );

  test(
    'an applied predecessor does not depend on a stale repair receipt',
    () async {
      _moveSeededTargetToSequence2(store);
      final predecessor = _entry(
        scope,
        sequence: 1,
        changeId: _digest('stale-repaired-prior'),
      );
      _seedTerminalPair(store, scope, predecessor, now);
      final predecessorRequest = CloudKitV2QuarantineRepairRequest(
        scope: scope,
        persistenceLane: CloudSyncPersistenceLane.semanticV2,
        generation: predecessor.generation,
        changeIdHash: predecessor.change.changeId,
        correction: CloudKitV2QuarantineRepairAllowlist.only,
        leaseFence: leaseFence,
      );
      await gateway.repair(
        request: predecessorRequest,
        testOnlyCapability: _Decoder(
          _decoded(scope, predecessor.change.changeId, predecessor.generation),
        ),
      );
      final receipt =
          store.box<CloudKitV2QuarantineRepairReceiptEntity>().getAll().single
            ..evidenceDigestSha256 = ''.padRight(64, '0');
      store.box<CloudKitV2QuarantineRepairReceiptEntity>().put(receipt);

      final child = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      expect(child.disposition, CloudKitV2QuarantineRepairDisposition.repaired);
    },
  );

  test('rejects a tombstone even when its correction is an upsert', () async {
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
      testOnlyCapability: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.failureCategory, CloudFailureCategory.malformedRecord);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
  });

  test('rejects a repair scope outside the message zone', () async {
    final wrongZone = CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: 'chatManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
    );
    final wrongRequest = CloudKitV2QuarantineRepairRequest(
      scope: wrongZone,
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
      generation: request.generation,
      changeIdHash: request.changeIdHash,
      correction: request.correction,
      leaseFence: leaseFence,
    );
    final decoder = _Decoder(_decoded(wrongZone, request.changeIdHash, 7));

    final result = await gateway.repair(
      request: wrongRequest,
      testOnlyCapability: decoder,
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_zone_not_allowlisted');
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
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );
      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.failureCategory, CloudFailureCategory.conflict);
      expect(result.safeCode, 'quarantine_repair_record_mapping_conflict');
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    },
  );

  test(
    'rejects an exact generation-zero record map without adopting it',
    () async {
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
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      final retained = store.box<CloudRecordMapEntity>().get(mapId)!;
      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.safeCode, 'quarantine_repair_record_map_scope_mismatch');
      expect(retained.id, mapId);
      expect(retained.generation, 0);
    },
  );

  test(
    'rejects a generation-zero map even when its old evidence is stale',
    () async {
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
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      final retained = store.box<CloudRecordMapEntity>().get(mapId)!;
      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.safeCode, 'quarantine_repair_record_map_scope_mismatch');
      expect(retained.id, mapId);
      expect(retained.generation, 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    },
  );

  test(
    'rejects missing terminal evidence before canonical or metadata writes',
    () async {
      final decoder = _staleDecoder(
        store,
        _decoded(scope, request.changeIdHash, 7),
        removeTerminal: true,
      );
      final result = await gateway.repair(
        request: request,
        testOnlyCapability: decoder,
      );
      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.safeCode, 'quarantine_repair_inbox_missing');
      expect(adapter.applyCalls, 0);
      expect(store.box<CloudRecordMapEntity>().count(), 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    },
  );

  test(
    'rejects a payload whose parent matches the incoming snapshot but not the final merge decision',
    () async {
      final localParent = _digest('local-parent');
      final incomingParent = _digest('incoming-parent');
      final incoming = _decoded(
        scope,
        request.changeIdHash,
        request.generation,
        parentKey: incomingParent,
      );
      _seedLocalSnapshot(
        store,
        scope,
        request,
        now,
        parentKey: localParent,
        immutableContentDigest: incoming.snapshot!.immutableContentDigest,
      );
      adapter
        ..parentExists = true
        ..existingEntityKeys.add(_digest('logical'));

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(incoming),
      );

      expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
      expect(result.safeCode, 'quarantine_repair_decoded_parent_mismatch');
      expect(adapter.applyCalls, 0);
      expect(store.box<CloudSemanticSnapshotEntity>().count(), 1);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
    },
  );

  test(
    'rejects legacy requests without decoding or writing any receipt',
    () async {
      final legacyScope = CloudSyncScope(
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        persistenceLane: CloudSyncPersistenceLane.legacy,
      );
      final legacyRequest = CloudKitV2QuarantineRepairRequest(
        scope: legacyScope,
        persistenceLane: CloudSyncPersistenceLane.legacy,
        generation: request.generation,
        changeIdHash: request.changeIdHash,
        correction: request.correction,
        leaseFence: leaseFence,
      );
      final decoder = _Decoder(_decoded(legacyScope, request.changeIdHash, 7));

      final result = await gateway.repair(
        request: legacyRequest,
        testOnlyCapability: decoder,
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.disabled,
      );
      expect(result.safeCode, 'quarantine_repair_semantic_lane_required');
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    },
  );

  test('rejects a coordinator lease lost before repair', () async {
    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _staleDecoder(
        store,
        _decoded(scope, request.changeIdHash, 7),
        expireLease: true,
      ),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'semantic_coordinator_lease_fence_lost');
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test('rejects a checkpoint fence changed before repair', () async {
    final result = await gateway.repair(
      request: request,
      testOnlyCapability: _staleDecoder(
        store,
        _decoded(scope, request.changeIdHash, 7),
        staleCheckpoint: true,
      ),
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_checkpoint_sequence_unproven');
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test('rejects a changed terminal status before canonical writes', () async {
    final inbox = store.box<CloudInboxChangeEntity>().getAll().single
      ..status = CloudInboxStatus.pending.index;
    store.box<CloudInboxChangeEntity>().put(inbox);
    final decoder = _Decoder(_decoded(scope, request.changeIdHash, 7));
    final result = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_terminal_pair_invalid');
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudRecordMapEntity>().count(), 0);
    expect(store.box<CloudSemanticSnapshotEntity>().count(), 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

  test(
    'keeps malformed terminal references retryable without a receipt',
    () async {
      final inbox = store.box<CloudInboxChangeEntity>().getAll().single
        ..protectedSystemFieldsRef = 'malformed-reference';
      store.box<CloudInboxChangeEntity>().put(inbox);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
      );

      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.retryable,
      );
      expect(result.safeCode, 'semantic_protected_reference_invalid');
      expect(adapter.applyCalls, 0);
      expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
    },
  );

  test('missing terminal row stays retryable without a receipt', () async {
    final decoder = _staleDecoder(
      store,
      _decoded(scope, request.changeIdHash, 7),
      removeTerminal: true,
    );

    final result = await gateway.repair(
      request: request,
      testOnlyCapability: decoder,
    );

    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.retryable);
    expect(result.safeCode, 'quarantine_repair_inbox_missing');
    expect(adapter.applyCalls, 0);
    expect(store.box<CloudKitV2QuarantineRepairReceiptEntity>().count(), 0);
  });

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
      testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
    );
    expect(result.disposition, CloudKitV2QuarantineRepairDisposition.failed);
    expect(result.safeCode, 'quarantine_repair_snapshot_scope_mismatch');
    expect(store.box<CloudRecordMapEntity>().count(), 0);
  });

  test(
    'rolls back map, inbox, checkpoint, and receipt when canonical apply fails',
    () async {
      adapter.failAfterMetadataWrite = true;
      final before = _controlState(store);

      final result = await gateway.repair(
        request: request,
        testOnlyCapability: _Decoder(_decoded(scope, request.changeIdHash, 7)),
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

// ignore: non_constant_identifier_names
CloudKitV2QuarantineRepairTestCapability _Decoder(CloudDecodedMutation value) =>
    CloudKitV2QuarantineRepairTestCapabilityFactory.create(value);

CloudKitV2QuarantineRepairTestCapability _staleDecoder(
  Store store,
  CloudDecodedMutation value, {
  bool removeTerminal = false,
  bool expireLease = false,
  bool staleCheckpoint = false,
}) {
  if (expireLease) {
    final lease = store.box<CloudSyncLeaseEntity>().getAll().single
      ..expiresAtMs = 0;
    store.box<CloudSyncLeaseEntity>().put(lease);
  } else if (staleCheckpoint) {
    final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
    checkpoint.generation += 1;
    store.box<CloudSyncCheckpointEntity>().put(checkpoint);
  } else if (removeTerminal) {
    store.box<CloudInboxChangeEntity>().removeAll();
  }
  return CloudKitV2QuarantineRepairTestCapabilityFactory.create(value);
}

final class _Adapter implements CloudCanonicalSemanticEntityAdapter {
  _Adapter(this.store);

  @override
  final Store store;

  int applyCalls = 0;
  bool parentExists = false;
  bool failAfterMetadataWrite = false;
  CloudFailureCategory? applyFailureCategory;
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
  void validateOwnershipEvidence({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {}

  @override
  CloudCanonicalSemanticMutationReceipt applyEntity({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    applyCalls++;
    final category = applyFailureCategory;
    if (category != null) {
      throw CloudSyncFailure(
        category: category,
        safeCode: 'test_canonical_apply_failed',
      );
    }
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
  persistenceLane: CloudSyncPersistenceLane.semanticV2,
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
  String body = 'transient body',
  String senderHandle = 'sender@example.com',
  DateTime? createdAt,
  CloudSemanticKnownMessageFlags? knownFlags,
  String? snapshotDigest,
}) {
  final key = _digest('logical');
  final payloadParentKey = mismatchPayloadParent
      ? _digest('different-parent')
      : parentKey;
  final payload = CloudMessageEntityPayload(
    logicalEntityKeyHash: key,
    canonicalGuid: 'message-guid',
    chatAliasKeyHash: _digest('chat'),
    chatIdentifier: 'iMessage;-;chat',
    body: body,
    senderHandle: senderHandle,
    createdAt: createdAt ?? DateTime.utc(2026, 8, 27, 10),
    knownFlags: knownFlags,
    replyParentLogicalKeyHash: payloadParentKey,
    replyParentCanonicalGuid: payloadParentKey == null ? null : 'parent-guid',
    replyParentPart: payloadParentKey == null ? null : '0',
  );
  return CloudDecodedMutation.upsert(
    scope: scope,
    generation: generation,
    changeId: changeId,
    snapshot: CloudSemanticSnapshot(
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: key,
      parentLogicalKeyHash: parentKey,
      immutableContentDigest:
          snapshotDigest ?? CloudKitV2SemanticContentDigest.forPayload(payload),
      createdAt: DateTime.utc(2026, 8, 27, 10),
      etagHash: _digest('etag'),
      encryptedRawRecordReference: _protected('payload'),
    ),
    payload: payload,
  );
}

void _seedLocalSnapshot(
  Store store,
  CloudSyncScope scope,
  CloudKitV2QuarantineRepairRequest request,
  DateTime now, {
  required String? parentKey,
  String? immutableContentDigest,
}) {
  final logicalKey = _digest('logical');
  store.runInTransaction(TxMode.write, () {
    store.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: _recordMapKey(scope, logicalKey),
        scopeKey: _scopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: logicalKey,
        serverRecordIdHash: _digest('record'),
        generation: request.generation,
        encryptedServerRecordId: _protected('server'),
        etagHash: _digest('etag'),
        encryptedRawRecordRef: _protected('payload'),
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    store.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey:
            'semantic-snapshot4:${_scopeGenerationKey(scope, request.generation)}:message:$logicalKey',
        scopeGenerationKey: _scopeGenerationKey(scope, request.generation),
        scopeKey: _scopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: request.generation,
        entityKind: CloudEntityKind.message.name,
        logicalEntityKeyHash: logicalKey,
        parentLogicalKeyHash: parentKey,
        immutableContentDigest: immutableContentDigest ?? _digest('immutable'),
        createdAtMs: DateTime.utc(2026, 8, 27, 10).millisecondsSinceEpoch,
        etagHash: _digest('etag'),
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
  });
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
    store.box<CloudSyncLeaseEntity>().put(
      CloudSyncLeaseEntity(
        leaseKey: _leaseKey(scope),
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        ownerIdHash: _sha256(
          'coordinator-owner\u001fquarantine-repair-test-owner',
        ),
        generation: entry.generation,
        acquiredAtMs: now.millisecondsSinceEpoch,
        expiresAtMs: now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      ),
    );
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        persistenceLane: scope.persistenceLane.name,
        generation: entry.generation,
        fetchedTokenCiphertext: 'opaque-old-token-ciphertext',
        pendingFetchedTokenCiphertext: 'opaque-token-ciphertext',
        pendingBatchId: entry.batchId,
        fetchedSequence: entry.sequence,
        appliedSequence: entry.sequence - 1,
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

void _moveSeededTargetToSequence2(Store store) {
  store.runInTransaction(TxMode.write, () {
    final inbox = store.box<CloudInboxChangeEntity>().getAll().single
      ..fetchSequence = 2;
    store.box<CloudInboxChangeEntity>().put(inbox);
    final replay = store.box<CloudSemanticReplayEntity>().getAll().single
      ..inboxSequence = 2;
    store.box<CloudSemanticReplayEntity>().put(replay);
    final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single
      ..fetchedSequence = 2
      ..appliedSequence = 0;
    store.box<CloudSyncCheckpointEntity>().put(checkpoint);
  });
}

void _putInboxRow(
  Store store,
  CloudSyncScope scope,
  CloudInboxEntry entry,
  DateTime now, {
  required CloudInboxStatus status,
}) {
  final change = entry.change;
  store.box<CloudInboxChangeEntity>().put(
    CloudInboxChangeEntity(
      changeKey: _changeKey(scope, change.changeId),
      changeIdHash: change.changeId,
      scopeKey: _scopeKey(scope),
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
      status: status.index,
      createdAtMs: entry.createdAt.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
      completedAtMs: status == CloudInboxStatus.pending
          ? 0
          : now.millisecondsSinceEpoch,
    ),
  );
}

void _seedTerminalPair(
  Store store,
  CloudSyncScope scope,
  CloudInboxEntry entry,
  DateTime now,
) {
  final change = entry.change;
  store.runInTransaction(TxMode.write, () {
    store.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: _changeKey(scope, change.changeId),
        changeIdHash: change.changeId,
        scopeKey: _scopeKey(scope),
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
            'semantic-replay4:${_scopeGenerationKey(scope, entry.generation)}:${_sha256(change.changeId)}',
        scopeGenerationKey: _scopeGenerationKey(scope, entry.generation),
        scopeKey: _scopeKey(scope),
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

String _leaseKey(CloudSyncScope scope) =>
    'coordinator-lease:${_sha256('${scope.storageKey}\u001fcoordinator-lease\u001fv1')}';

String _digest(String value) => base64Url
    .encode(sha256.convert(utf8.encode(value)).bytes)
    .replaceAll('=', '');

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();

String _protected(String value) => 'obcs2.ref.${_digest(value)}';
