import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_models.dart';
import 'objectbox_cloud_semantic_store_gateway.dart';

/// The only converter correction currently admitted to the repair lane.
///
/// Add a new named value only with a separately reviewed converter change.
/// Do not turn this into a caller-controlled revision range.
final class CloudKitV2ConverterCorrection {
  const CloudKitV2ConverterCorrection({
    required this.converterRevision,
    required this.correctionName,
  });

  static const messageFamilyAssociation = CloudKitV2ConverterCorrection(
    converterRevision: 'cloud-canonical-converter-r2',
    correctionName: 'message-family-outer-class-association',
  );

  final String converterRevision;
  final String correctionName;

  @override
  bool operator ==(Object other) =>
      other is CloudKitV2ConverterCorrection &&
      other.converterRevision == converterRevision &&
      other.correctionName == correctionName;

  @override
  int get hashCode => Object.hash(converterRevision, correctionName);
}

/// Explicit allowlist for converter repairs. This is intentionally closed to
/// the reviewed correction above.
final class CloudKitV2QuarantineRepairAllowlist {
  const CloudKitV2QuarantineRepairAllowlist._();

  static const only = CloudKitV2ConverterCorrection.messageFamilyAssociation;

  static bool permits(CloudKitV2ConverterCorrection correction) =>
      correction == only;
}

final class CloudKitV2QuarantineRepairRequest {
  CloudKitV2QuarantineRepairRequest({
    required this.scope,
    required this.generation,
    required this.changeIdHash,
    required this.correction,
  }) {
    if (generation <= 0 || !_digestPattern.hasMatch(changeIdHash)) {
      throw ArgumentError('cloudkit_quarantine_repair_request_invalid');
    }
    if (!_revisionPattern.hasMatch(correction.converterRevision) ||
        !_safeCodePattern.hasMatch(correction.correctionName)) {
      throw ArgumentError('cloudkit_quarantine_repair_correction_invalid');
    }
  }

  static final _digestPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _revisionPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
  static final _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  final CloudSyncScope scope;
  final int generation;
  final String changeIdHash;
  final CloudKitV2ConverterCorrection correction;
}

enum CloudKitV2QuarantineRepairDisposition {
  disabled,
  retryable,
  repaired,
  alreadyRepaired,
  failed,
  alreadyFailed,
}

final class CloudKitV2QuarantineRepairResult {
  const CloudKitV2QuarantineRepairResult._({
    required this.disposition,
    required this.repairKey,
    this.failureCategory,
    this.safeCode,
  });

  const CloudKitV2QuarantineRepairResult.disabled(String repairKey)
    : this._(
        disposition: CloudKitV2QuarantineRepairDisposition.disabled,
        repairKey: repairKey,
      );

  const CloudKitV2QuarantineRepairResult.retryable(
    String repairKey, {
    required CloudFailureCategory failureCategory,
    required String safeCode,
  }) : this._(
         disposition: CloudKitV2QuarantineRepairDisposition.retryable,
         repairKey: repairKey,
         failureCategory: failureCategory,
         safeCode: safeCode,
       );

  final CloudKitV2QuarantineRepairDisposition disposition;
  final String repairKey;
  final CloudFailureCategory? failureCategory;
  final String? safeCode;

  bool get succeeded =>
      disposition == CloudKitV2QuarantineRepairDisposition.repaired ||
      disposition == CloudKitV2QuarantineRepairDisposition.alreadyRepaired;
}

/// Local-only, opt-in repair lane for terminal semantic quarantines.
///
/// The decoder runs before the ObjectBox write transaction. A successful
/// repair changes only canonical state, its semantic snapshot, and a new
/// immutable receipt. A deterministic failure changes only the failure
/// receipt; dependency and authorization failures remain retryable and do not
/// create a permanent receipt.
final class CloudKitV2QuarantineRepairGateway {
  CloudKitV2QuarantineRepairGateway({
    required Store store,
    required CloudCanonicalSemanticEntityAdapter canonicalAdapter,
    DateTime Function()? clock,
    this.enabled = false,
  }) : _store = store,
       _canonicalAdapter = canonicalAdapter,
       _clock = clock ?? DateTime.now,
       _inbox = store.box<CloudInboxChangeEntity>(),
       _replay = store.box<CloudSemanticReplayEntity>(),
       _recordMaps = store.box<CloudRecordMapEntity>(),
       _snapshots = store.box<CloudSemanticSnapshotEntity>(),
       _receipts = store.box<CloudKitV2QuarantineRepairReceiptEntity>() {
    if (!identical(canonicalAdapter.store, store)) {
      throw ArgumentError('canonical_adapter_store_mismatch');
    }
  }

  final Store _store;
  final CloudCanonicalSemanticEntityAdapter _canonicalAdapter;
  final DateTime Function() _clock;
  final bool enabled;
  final Box<CloudInboxChangeEntity> _inbox;
  final Box<CloudSemanticReplayEntity> _replay;
  final Box<CloudRecordMapEntity> _recordMaps;
  final Box<CloudSemanticSnapshotEntity> _snapshots;
  final Box<CloudKitV2QuarantineRepairReceiptEntity> _receipts;

  Future<CloudKitV2QuarantineRepairResult> repair({
    required CloudKitV2QuarantineRepairRequest request,
    required CloudSemanticDecoder correctedDecoder,
  }) async {
    final context = _RepairContext(request);
    if (!enabled) {
      return CloudKitV2QuarantineRepairResult.disabled(context.repairKey);
    }
    if (!CloudKitV2QuarantineRepairAllowlist.permits(request.correction) ||
        request.scope.streamKind != CloudSyncStreamKind.messages ||
        request.scope.zone != 'messageManateeZone') {
      return _recordFailure(
        context,
        category: CloudFailureCategory.unsupportedService,
        safeCode: request.scope.zone == 'messageManateeZone'
            ? 'quarantine_repair_correction_not_allowlisted'
            : 'quarantine_repair_zone_not_allowlisted',
      );
    }

    final existing = _readReceipt(context);
    if (existing != null) {
      if (existing.outcome == 'repaired') {
        try {
          _validateExistingRepairedReceipt(context, existing);
        } on CloudSyncFailure catch (failure) {
          return CloudKitV2QuarantineRepairResult.retryable(
            context.repairKey,
            failureCategory: CloudFailureCategory.localStorage,
            safeCode:
                failure.safeCode ??
                'quarantine_repair_existing_artifacts_invalid',
          );
        } catch (_) {
          return CloudKitV2QuarantineRepairResult.retryable(
            context.repairKey,
            failureCategory: CloudFailureCategory.localStorage,
            safeCode: 'quarantine_repair_existing_artifacts_invalid',
          );
        }
      }
      return _resultFromReceipt(existing, existing: true);
    }

    late final CloudInboxEntry entry;
    try {
      entry = _readTerminalEntry(context);
    } on CloudSyncFailure catch (failure) {
      return _recordFailure(
        context,
        category: failure.category,
        safeCode: failure.safeCode ?? 'quarantine_repair_terminal_row_invalid',
      );
    } catch (_) {
      return _recordFailure(
        context,
        category: CloudFailureCategory.localStorage,
        safeCode: 'quarantine_repair_terminal_row_invalid',
      );
    }

    late final CloudDecodedMutation decoded;
    try {
      decoded = await correctedDecoder.decode(entry);
      _validateDecoded(context, entry, decoded);
    } on CloudSemanticDecodeFailure catch (failure) {
      return _recordFailure(
        context,
        category: failure.category,
        safeCode: 'quarantine_repair_decode_failed',
        expectedEntry: entry,
      );
    } on CloudSyncFailure catch (failure) {
      return _recordFailure(
        context,
        category: failure.category,
        safeCode: failure.safeCode ?? 'quarantine_repair_decode_failed',
        expectedEntry: entry,
      );
    } catch (_) {
      return _recordFailure(
        context,
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'quarantine_repair_decode_failed',
        expectedEntry: entry,
      );
    }

    try {
      return _commitRepair(context, entry, decoded);
    } on CloudSyncFailure catch (failure) {
      return _recordFailure(
        context,
        category: failure.category,
        safeCode: failure.safeCode ?? 'quarantine_repair_failed',
        expectedEntry: entry,
      );
    } catch (_) {
      return _recordFailure(
        context,
        category: CloudFailureCategory.localStorage,
        safeCode: 'quarantine_repair_failed',
        expectedEntry: entry,
      );
    }
  }

  CloudKitV2QuarantineRepairReceiptEntity? _readReceipt(
    _RepairContext context,
  ) {
    return _store.runInTransaction(TxMode.read, () {
      final query = _receipts
          .query(
            CloudKitV2QuarantineRepairReceiptEntity_.repairKey.equals(
              context.repairKey,
            ),
          )
          .build();
      try {
        final matches = query.find();
        if (matches.length > 1) {
          throw _failure('quarantine_repair_receipt_not_unique');
        }
        final receipt = matches.singleOrNull;
        if (receipt != null) _validateReceipt(context, receipt);
        return receipt;
      } finally {
        query.close();
      }
    });
  }

  CloudInboxEntry _readTerminalEntry(_RepairContext context) {
    return _store.runInTransaction(TxMode.read, () {
      final inbox = _inbox.getAll().where(
        (row) => row.changeKey == context.changeKey,
      );
      final row = inbox.singleOrNull;
      if (row == null) throw _failure('quarantine_repair_inbox_missing');
      final replay = _replay
          .getAll()
          .where((candidate) => candidate.replayKey == context.replayKey)
          .singleOrNull;
      _validateTerminalPair(context, row, replay);

      final changeType = switch (row.changeType) {
        'save' => CloudChangeType.save,
        'delete' => CloudChangeType.delete,
        _ => throw _failure('quarantine_repair_change_type_invalid'),
      };
      return CloudInboxEntry(
        scope: context.scope,
        sequence: row.fetchSequence,
        change: CloudFetchedChange(
          changeId: row.changeIdHash,
          recordIdHash: row.serverRecordIdHash,
          etagHash: row.etagHash,
          type: changeType,
          encryptedServerRecordId: row.encryptedServerRecordId,
          protectedSystemFieldsReference: row.protectedSystemFieldsRef,
          encryptedPayloadReference: row.encryptedPayloadRef,
          payloadSha256: row.payloadSha256,
          isTombstone: row.isTombstone,
          serverModifiedAt: row.serverModifiedAtMs == 0
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  row.serverModifiedAtMs,
                  isUtc: true,
                ),
        ),
        status: CloudInboxStatus.quarantined,
        attemptCount: row.retryCount,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row.createdAtMs,
          isUtc: true,
        ),
        batchId: row.batchId,
        generation: row.generation,
        nextEligibleAt: row.nextEligibleAtMs == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                row.nextEligibleAtMs,
                isUtc: true,
              ),
        lastFailure: _failureCategory(row.failureCategory),
        completedAt: row.completedAtMs == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                row.completedAtMs,
                isUtc: true,
              ),
      );
    });
  }

  CloudKitV2QuarantineRepairResult _commitRepair(
    _RepairContext context,
    CloudInboxEntry entry,
    CloudDecodedMutation decoded,
  ) {
    return _store.runInTransaction(TxMode.write, () {
      final existing = _findReceipt(context);
      if (existing != null) {
        _validateReceipt(context, existing);
        return _resultFromReceipt(existing, existing: true);
      }

      final inbox = _inbox
          .getAll()
          .where((row) => row.changeKey == context.changeKey)
          .singleOrNull;
      final replay = _replay
          .getAll()
          .where((row) => row.replayKey == context.replayKey)
          .singleOrNull;
      _validateTerminalPair(context, inbox, replay, expectedEntry: entry);
      if (_inbox.getAll().any(
        (row) =>
            row.scopeKey == context.scopeKey &&
            row.generation == context.generation &&
            row.fetchSequence < entry.sequence &&
            row.status != CloudInboxStatus.applied.index,
      )) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'quarantine_repair_sequence_predecessor_not_applied',
        );
      }
      if (!_canonicalAdapter.isActiveAccountScope(
        scope: context.scope,
        generation: context.generation,
      )) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.authorization,
          safeCode: 'quarantine_repair_active_scope_changed',
        );
      }

      final snapshot = decoded.snapshot!;
      final payload = decoded.payload!;
      final existingSnapshot = _findSnapshot(
        context,
        snapshot.kind,
        snapshot.logicalEntityKeyHash,
      );
      final local = existingSnapshot == null
          ? null
          : _snapshotFromEntity(context, entry, existingSnapshot);
      final parentExists =
          snapshot.parentLogicalKeyHash == null ||
          _canonicalAdapter.entityExists(
            scope: context.scope,
            generation: context.generation,
            kind: _parentKind(snapshot.kind),
            logicalEntityKeyHash: snapshot.parentLogicalKeyHash!,
          );
      final decision = const CloudMergePolicy().merge(
        local: local,
        incoming: snapshot,
        parentExists: parentExists,
      );
      if (decision.action == CloudMergeAction.defer) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'quarantine_repair_parent_not_ready',
        );
      }
      if (decision.action == CloudMergeAction.quarantine ||
          decision.conflicts.contains(
            CloudMergeConflict.immutableContentMismatch,
          ) ||
          decision.conflicts.contains(
            CloudMergeConflict.editRevisionMismatch,
          )) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'quarantine_repair_merge_conflict',
        );
      }

      final merged = decision.snapshot!;
      if (decision.action == CloudMergeAction.noChange) {
        if (existingSnapshot == null ||
            !_canonicalAdapter.entityExists(
              scope: context.scope,
              generation: context.generation,
              kind: merged.kind,
              logicalEntityKeyHash: merged.logicalEntityKeyHash,
            )) {
          throw _failure('quarantine_repair_canonical_artifact_missing');
        }
        _bindRecordIdentity(
          context: context,
          entry: entry,
          logicalEntityKeyHash: merged.logicalEntityKeyHash,
          encryptedRawRecordReference: merged.encryptedRawRecordReference,
          requireExisting: true,
        );
      } else if (decision.action == CloudMergeAction.create ||
          decision.action == CloudMergeAction.update) {
        _bindRecordIdentity(
          context: context,
          entry: entry,
          logicalEntityKeyHash: merged.logicalEntityKeyHash,
          encryptedRawRecordReference: merged.encryptedRawRecordReference,
        );
        final receipt = _canonicalAdapter.applyEntity(
          scope: context.scope,
          generation: context.generation,
          payload: payload,
          snapshot: merged,
        );
        if (receipt != CloudCanonicalSemanticMutationReceipt.committed) {
          throw _failure('quarantine_repair_canonical_uncommitted');
        }
        _snapshots.put(
          _snapshotEntity(
            context,
            merged,
            existingId: existingSnapshot?.id ?? 0,
          ),
        );
      }

      final receipt = CloudKitV2QuarantineRepairReceiptEntity(
        repairKey: context.repairKey,
        scopeGenerationKey: context.scopeGenerationKey,
        changeIdHash: context.changeIdHash,
        converterRevision: context.correction.converterRevision,
        correctionName: context.correction.correctionName,
        scopeKey: context.scopeKey,
        accountFingerprint: context.scope.accountFingerprint,
        container: context.scope.container,
        database: context.scope.database,
        zone: context.scope.zone,
        streamKind: context.scope.streamKind.name,
        schemaVersion: context.scope.schemaVersion,
        generation: context.generation,
        inboxSequence: entry.sequence,
        serverRecordIdHash: entry.change.recordIdHash,
        outcome: 'repaired',
        logicalEntityKeyHash: merged.logicalEntityKeyHash,
        createdAtMs: _clock().toUtc().millisecondsSinceEpoch,
      );
      _receipts.put(receipt);
      return _resultFromReceipt(receipt);
    });
  }

  Future<CloudKitV2QuarantineRepairResult> _recordFailure(
    _RepairContext context, {
    required CloudFailureCategory category,
    required String safeCode,
    CloudInboxEntry? expectedEntry,
  }) async {
    if (category.isRetryable) {
      final existing = _readReceipt(context);
      if (existing != null) {
        return _resultFromReceipt(existing, existing: true);
      }
      return CloudKitV2QuarantineRepairResult.retryable(
        context.repairKey,
        failureCategory: category,
        safeCode: safeCode,
      );
    }
    return _store.runInTransaction(TxMode.write, () {
      final existing = _findReceipt(context);
      if (existing != null) {
        _validateReceipt(context, existing);
        return _resultFromReceipt(existing, existing: true);
      }
      final terminal = _inbox
          .getAll()
          .where((row) => row.changeKey == context.changeKey)
          .singleOrNull;
      if (expectedEntry != null) {
        final replay = _replay
            .getAll()
            .where((row) => row.replayKey == context.replayKey)
            .singleOrNull;
        try {
          _validateTerminalPair(
            context,
            terminal,
            replay,
            expectedEntry: expectedEntry,
          );
        } on CloudSyncFailure {
          return CloudKitV2QuarantineRepairResult.retryable(
            context.repairKey,
            failureCategory: CloudFailureCategory.dependency,
            safeCode: 'quarantine_repair_terminal_state_changed',
          );
        }
      }
      final receipt = CloudKitV2QuarantineRepairReceiptEntity(
        repairKey: context.repairKey,
        scopeGenerationKey: context.scopeGenerationKey,
        changeIdHash: context.changeIdHash,
        converterRevision: context.correction.converterRevision,
        correctionName: context.correction.correctionName,
        scopeKey: context.scopeKey,
        accountFingerprint: context.scope.accountFingerprint,
        container: context.scope.container,
        database: context.scope.database,
        zone: context.scope.zone,
        streamKind: context.scope.streamKind.name,
        schemaVersion: context.scope.schemaVersion,
        generation: context.generation,
        inboxSequence: terminal?.fetchSequence ?? 0,
        serverRecordIdHash: terminal?.serverRecordIdHash ?? '',
        outcome: 'failed',
        failureCategory: category.name,
        safeCode: safeCode,
        createdAtMs: _clock().toUtc().millisecondsSinceEpoch,
      );
      _receipts.put(receipt);
      return _resultFromReceipt(receipt);
    });
  }

  CloudKitV2QuarantineRepairReceiptEntity? _findReceipt(
    _RepairContext context,
  ) {
    final query = _receipts
        .query(
          CloudKitV2QuarantineRepairReceiptEntity_.repairKey.equals(
            context.repairKey,
          ),
        )
        .build();
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw _failure('quarantine_repair_receipt_not_unique');
      }
      return matches.singleOrNull;
    } finally {
      query.close();
    }
  }

  void _validateExistingRepairedReceipt(
    _RepairContext context,
    CloudKitV2QuarantineRepairReceiptEntity receipt,
  ) {
    final entry = _readTerminalEntry(context);
    if (receipt.inboxSequence != entry.sequence ||
        receipt.serverRecordIdHash != entry.change.recordIdHash ||
        receipt.logicalEntityKeyHash == null) {
      throw _failure('quarantine_repair_existing_receipt_stale');
    }
    final logicalEntityKeyHash = receipt.logicalEntityKeyHash!;
    final candidates = _snapshots
        .getAll()
        .where(
          (snapshot) =>
              snapshot.scopeGenerationKey == context.scopeGenerationKey &&
              snapshot.logicalEntityKeyHash == logicalEntityKeyHash,
        )
        .toList(growable: false);
    if (candidates.length != 1) {
      throw _failure('quarantine_repair_existing_snapshot_missing');
    }
    final snapshotEntity = candidates.single;
    final kind = _entityKind(snapshotEntity.entityKind);
    final snapshot = _snapshotFromEntity(context, entry, snapshotEntity);
    if (snapshot.kind != kind ||
        snapshot.logicalEntityKeyHash != logicalEntityKeyHash ||
        !_canonicalAdapter.entityExists(
          scope: context.scope,
          generation: context.generation,
          kind: kind,
          logicalEntityKeyHash: logicalEntityKeyHash,
        )) {
      throw _failure('quarantine_repair_existing_canonical_missing');
    }
    final recordMap = _findRecordMap(
      context.recordMapKey(logicalEntityKeyHash),
    );
    if (recordMap == null ||
        recordMap.serverRecordIdHash != entry.change.recordIdHash ||
        recordMap.encryptedServerRecordId !=
            entry.change.encryptedServerRecordId ||
        recordMap.etagHash != entry.change.etagHash ||
        recordMap.encryptedRawRecordRef !=
            entry.change.encryptedPayloadReference) {
      throw _failure('quarantine_repair_existing_record_map_invalid');
    }
  }

  CloudSemanticSnapshotEntity? _findSnapshot(
    _RepairContext context,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) {
    final snapshotKey = context.snapshotKey(kind, logicalEntityKeyHash);
    final query = _snapshots
        .query(CloudSemanticSnapshotEntity_.snapshotKey.equals(snapshotKey))
        .build();
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw _failure('quarantine_repair_snapshot_key_not_unique');
      }
      final snapshot = matches.singleOrNull;
      if (snapshot != null) {
        _validateSnapshotEntity(context, snapshot, kind, logicalEntityKeyHash);
      }
      return snapshot;
    } finally {
      query.close();
    }
  }

  CloudSemanticSnapshotEntity _snapshotEntity(
    _RepairContext context,
    CloudSemanticSnapshot snapshot, {
    required int existingId,
  }) {
    _validateSnapshotValues(snapshot);
    return CloudSemanticSnapshotEntity(
      id: existingId,
      snapshotKey:
          'semantic-snapshot4:${context.scopeGenerationKey}:${snapshot.kind.name}:${snapshot.logicalEntityKeyHash}',
      scopeGenerationKey: context.scopeGenerationKey,
      scopeKey: context.scopeKey,
      accountFingerprint: context.scope.accountFingerprint,
      container: context.scope.container,
      database: context.scope.database,
      zone: context.scope.zone,
      streamKind: context.scope.streamKind.name,
      schemaVersion: context.scope.schemaVersion,
      generation: context.generation,
      entityKind: snapshot.kind.name,
      logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
      parentLogicalKeyHash: snapshot.parentLogicalKeyHash,
      immutableContentDigest: snapshot.immutableContentDigest,
      createdAtMs: _millisecondsOrSentinel(snapshot.createdAt),
      readAtMs: _millisecondsOrSentinel(snapshot.readAt),
      deliveredAtMs: _millisecondsOrSentinel(snapshot.deliveredAt),
      editPartsJson: _encodeEditParts(snapshot.editParts),
      retractedAtMs: _millisecondsOrSentinel(snapshot.retractedAt),
      groupVersion: snapshot.groupVersion,
      groupMetadataDigest: snapshot.groupMetadataDigest,
      etagHash: snapshot.etagHash,
      updatedAtMs: _clock().toUtc().millisecondsSinceEpoch,
    );
  }

  void _bindRecordIdentity({
    required _RepairContext context,
    required CloudInboxEntry entry,
    required String logicalEntityKeyHash,
    required String? encryptedRawRecordReference,
    bool requireExisting = false,
  }) {
    _validateHashedValue(logicalEntityKeyHash);
    _validateProtectedReference(encryptedRawRecordReference);
    final expectedRawReference = entry.change.encryptedPayloadReference;
    if (expectedRawReference == null ||
        encryptedRawRecordReference != expectedRawReference) {
      throw _failure('quarantine_repair_raw_record_reference_mismatch');
    }
    final encryptedServerRecordId = entry.change.encryptedServerRecordId;
    if (encryptedServerRecordId == null) {
      throw _failure('quarantine_repair_server_record_reference_missing');
    }
    _validateProtectedReference(encryptedServerRecordId);
    _validateHashedValue(entry.change.recordIdHash);
    _validateOptionalHashedValue(entry.change.etagHash);

    final mapKey = context.recordMapKey(logicalEntityKeyHash);
    final existing = _findRecordMap(mapKey);
    if (existing == null && requireExisting) {
      throw _failure('quarantine_repair_record_mapping_missing');
    }
    if (existing != null) {
      _validateRecordMap(
        context,
        existing,
        logicalEntityKeyHash,
        expectedChange: entry.change,
      );
      if (existing.serverRecordIdHash != entry.change.recordIdHash ||
          existing.encryptedServerRecordId != encryptedServerRecordId ||
          existing.etagHash != entry.change.etagHash ||
          existing.encryptedRawRecordRef != expectedRawReference) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'quarantine_repair_record_mapping_conflict',
        );
      }
    }

    final collisions = _recordMaps
        .query(
          CloudRecordMapEntity_.scopeKey
              .equals(context.scopeKey)
              .and(
                CloudRecordMapEntity_.serverRecordIdHash.equals(
                  entry.change.recordIdHash,
                ),
              ),
        )
        .build();
    try {
      for (final collision in collisions.find()) {
        _validateRecordMap(
          context,
          collision,
          collision.logicalEntityKeyHash,
          expectedChange: entry.change,
        );
        if (collision.mapKey != mapKey ||
            collision.logicalEntityKeyHash != logicalEntityKeyHash) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'quarantine_repair_record_mapping_conflict',
          );
        }
      }
    } finally {
      collisions.close();
    }

    _recordMaps.put(
      CloudRecordMapEntity(
        id: existing?.id ?? 0,
        mapKey: mapKey,
        scopeKey: context.scopeKey,
        accountFingerprint: context.scope.accountFingerprint,
        zone: context.scope.zone,
        logicalEntityKeyHash: logicalEntityKeyHash,
        serverRecordIdHash: entry.change.recordIdHash,
        generation: context.generation,
        encryptedServerRecordId: encryptedServerRecordId,
        etagHash: entry.change.etagHash,
        encryptedRawRecordRef: expectedRawReference,
        updatedAtMs: _clock().toUtc().millisecondsSinceEpoch,
      ),
    );
  }

  CloudRecordMapEntity? _findRecordMap(String mapKey) {
    final query = _recordMaps
        .query(CloudRecordMapEntity_.mapKey.equals(mapKey))
        .build();
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw _failure('quarantine_repair_record_map_not_unique');
      }
      return matches.singleOrNull;
    } finally {
      query.close();
    }
  }

  void _validateRecordMap(
    _RepairContext context,
    CloudRecordMapEntity entity,
    String logicalEntityKeyHash, {
    required CloudFetchedChange expectedChange,
  }) {
    _validateHashedValue(entity.serverRecordIdHash);
    _validateProtectedReference(entity.encryptedServerRecordId);
    _validateOptionalHashedValue(entity.etagHash);
    _validateProtectedReference(entity.encryptedRawRecordRef);
    if (entity.mapKey != context.recordMapKey(logicalEntityKeyHash) ||
        entity.scopeKey != context.scopeKey ||
        entity.accountFingerprint != context.scope.accountFingerprint ||
        entity.zone != context.scope.zone ||
        entity.logicalEntityKeyHash != logicalEntityKeyHash ||
        (entity.generation != context.generation && entity.generation != 0)) {
      throw _failure('quarantine_repair_record_map_scope_mismatch');
    }
    if (entity.generation == 0 &&
        (entity.serverRecordIdHash != expectedChange.recordIdHash ||
            entity.encryptedServerRecordId !=
                expectedChange.encryptedServerRecordId ||
            entity.etagHash != expectedChange.etagHash ||
            entity.encryptedRawRecordRef !=
                expectedChange.encryptedPayloadReference)) {
      throw _failure('quarantine_repair_record_map_legacy_reproof_failed');
    }
  }

  void _validateSnapshotEntity(
    _RepairContext context,
    CloudSemanticSnapshotEntity entity,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) {
    if (entity.snapshotKey != context.snapshotKey(kind, logicalEntityKeyHash) ||
        entity.scopeGenerationKey != context.scopeGenerationKey ||
        entity.scopeKey != context.scopeKey ||
        entity.accountFingerprint != context.scope.accountFingerprint ||
        entity.container != context.scope.container ||
        entity.database != context.scope.database ||
        entity.zone != context.scope.zone ||
        entity.streamKind != context.scope.streamKind.name ||
        entity.schemaVersion != context.scope.schemaVersion ||
        entity.generation != context.generation ||
        entity.entityKind != kind.name ||
        entity.logicalEntityKeyHash != logicalEntityKeyHash) {
      throw _failure('quarantine_repair_snapshot_scope_mismatch');
    }
  }

  CloudSemanticSnapshot _snapshotFromEntity(
    _RepairContext context,
    CloudInboxEntry entry,
    CloudSemanticSnapshotEntity entity,
  ) {
    try {
      final kind = _entityKind(entity.entityKind);
      final recordMap = _findRecordMap(
        context.recordMapKey(entity.logicalEntityKeyHash),
      );
      if (recordMap == null) {
        throw _failure('quarantine_repair_record_mapping_missing');
      }
      _validateRecordMap(
        context,
        recordMap,
        entity.logicalEntityKeyHash,
        expectedChange: entry.change,
      );
      final editParts = jsonDecode(entity.editPartsJson);
      if (editParts is! List ||
          editParts.length > 1024 ||
          utf8.encode(entity.editPartsJson).length > 256 * 1024) {
        throw const FormatException();
      }
      final parts = <String, CloudEditPart>{};
      for (final raw in editParts) {
        if (raw is! Map<String, dynamic> ||
            raw.length != 5 ||
            raw['mapKeyHash'] is! String ||
            raw['partKeyHash'] is! String ||
            raw['revision'] is! int ||
            raw['contentDigest'] is! String ||
            raw['modifiedAtMs'] is! int) {
          throw const FormatException();
        }
        final mapKeyHash = raw['mapKeyHash'] as String;
        final partKeyHash = raw['partKeyHash'] as String;
        final revision = raw['revision'] as int;
        final contentDigest = raw['contentDigest'] as String;
        if (mapKeyHash != partKeyHash ||
            revision < 0 ||
            parts.containsKey(mapKeyHash)) {
          throw const FormatException();
        }
        _validateHashedValue(mapKeyHash);
        _validateHashedValue(partKeyHash);
        _validateContentDigest(contentDigest);
        parts[mapKeyHash] = CloudEditPart(
          partKeyHash: partKeyHash,
          revision: revision,
          contentDigest: contentDigest,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(
            raw['modifiedAtMs'] as int,
            isUtc: true,
          ),
        );
      }
      final snapshot = CloudSemanticSnapshot(
        kind: kind,
        logicalEntityKeyHash: entity.logicalEntityKeyHash,
        parentLogicalKeyHash: entity.parentLogicalKeyHash,
        immutableContentDigest: entity.immutableContentDigest,
        createdAt: _dateOrNull(entity.createdAtMs),
        readAt: _dateOrNull(entity.readAtMs),
        deliveredAt: _dateOrNull(entity.deliveredAtMs),
        editParts: parts,
        retractedAt: _dateOrNull(entity.retractedAtMs),
        groupVersion: entity.groupVersion,
        groupMetadataDigest: entity.groupMetadataDigest,
        etagHash: entity.etagHash,
        encryptedRawRecordReference: recordMap.encryptedRawRecordRef,
      );
      if (_encodeEditParts(parts) != entity.editPartsJson) {
        throw const FormatException();
      }
      _validateSnapshotValues(snapshot);
      if (snapshot.etagHash != recordMap.etagHash ||
          snapshot.encryptedRawRecordReference !=
              recordMap.encryptedRawRecordRef) {
        throw const FormatException();
      }
      return snapshot;
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw _failure('quarantine_repair_snapshot_invalid');
    }
  }

  void _validateDecoded(
    _RepairContext context,
    CloudInboxEntry entry,
    CloudDecodedMutation decoded,
  ) {
    if (decoded.scope != context.scope ||
        decoded.generation != context.generation ||
        decoded.changeId != context.changeIdHash ||
        decoded.kind != CloudDecodedMutationKind.upsert ||
        decoded.snapshot == null ||
        decoded.payload == null) {
      throw _failure('quarantine_repair_decoded_binding_invalid');
    }
    final snapshot = decoded.snapshot!;
    final payload = decoded.payload!;
    if (snapshot.kind != payload.kind ||
        snapshot.logicalEntityKeyHash != payload.logicalEntityKeyHash ||
        snapshot.encryptedRawRecordReference !=
            entry.change.encryptedPayloadReference ||
        snapshot.etagHash != entry.change.etagHash) {
      throw _failure('quarantine_repair_decoded_shape_invalid');
    }
    final payloadParent = switch (payload) {
      CloudMessageEntityPayload value => value.replyParentLogicalKeyHash,
      CloudReactionEntityPayload value => value.parentLogicalKeyHash,
      _ => null,
    };
    if (snapshot.parentLogicalKeyHash != payloadParent) {
      throw _failure('quarantine_repair_decoded_parent_mismatch');
    }
    if (context.scope.zone != 'messageManateeZone' ||
        (snapshot.kind != CloudEntityKind.message &&
            snapshot.kind != CloudEntityKind.reaction)) {
      throw _failure('quarantine_repair_entity_kind_not_allowlisted');
    }
    _validateSnapshotValues(snapshot);
  }

  void _validateTerminalPair(
    _RepairContext context,
    CloudInboxChangeEntity? inbox,
    CloudSemanticReplayEntity? replay, {
    CloudInboxEntry? expectedEntry,
  }) {
    if (inbox == null || replay == null) {
      throw _failure('quarantine_repair_terminal_pair_missing');
    }
    final scope = context.scope;
    final expectedRecordIdHash =
        expectedEntry?.change.recordIdHash ?? inbox.serverRecordIdHash;
    final expectedPayloadSha256 =
        expectedEntry?.change.payloadSha256 ?? inbox.payloadSha256;
    if (inbox.changeKey != context.changeKey ||
        inbox.changeIdHash != context.changeIdHash ||
        inbox.scopeKey != context.scopeKey ||
        inbox.accountFingerprint != scope.accountFingerprint ||
        inbox.zone != scope.zone ||
        inbox.generation != context.generation ||
        inbox.status != CloudInboxStatus.quarantined.index ||
        inbox.changeType != CloudChangeType.save.name ||
        inbox.isTombstone ||
        inbox.completedAtMs == 0 ||
        replay.replayKey != context.replayKey ||
        replay.scopeGenerationKey != context.scopeGenerationKey ||
        replay.scopeKey != context.scopeKey ||
        replay.accountFingerprint != scope.accountFingerprint ||
        replay.container != scope.container ||
        replay.database != scope.database ||
        replay.zone != scope.zone ||
        replay.streamKind != scope.streamKind.name ||
        replay.schemaVersion != scope.schemaVersion ||
        replay.generation != context.generation ||
        replay.changeIdHash != context.changeIdHash ||
        replay.serverRecordIdHash != expectedRecordIdHash ||
        replay.payloadSha256 != expectedPayloadSha256 ||
        inbox.payloadSha256 == null ||
        inbox.encryptedPayloadRef == null ||
        replay.protectedPayloadReferenceHash !=
            _protectedPayloadReferenceHash(inbox.encryptedPayloadRef!) ||
        replay.inboxSequence != inbox.fetchSequence ||
        replay.changeType != CloudChangeType.save.name ||
        replay.terminalOutcome != 'quarantined') {
      throw _failure('quarantine_repair_terminal_pair_invalid');
    }
    if (expectedEntry != null) {
      _validateRereadEntry(expectedEntry, inbox, replay);
    }
  }

  static void _validateRereadEntry(
    CloudInboxEntry expected,
    CloudInboxChangeEntity inbox,
    CloudSemanticReplayEntity replay,
  ) {
    final change = expected.change;
    if (expected.status != CloudInboxStatus.quarantined ||
        expected.completedAt == null ||
        inbox.changeIdHash != change.changeId ||
        inbox.serverRecordIdHash != change.recordIdHash ||
        inbox.etagHash != change.etagHash ||
        inbox.changeType != change.type.name ||
        inbox.encryptedServerRecordId != change.encryptedServerRecordId ||
        inbox.protectedSystemFieldsRef !=
            change.protectedSystemFieldsReference ||
        inbox.encryptedPayloadRef != change.encryptedPayloadReference ||
        inbox.payloadSha256 != change.payloadSha256 ||
        inbox.isTombstone != change.isTombstone ||
        inbox.serverModifiedAtMs !=
            (change.serverModifiedAt?.toUtc().millisecondsSinceEpoch ?? 0) ||
        inbox.scopeKey != _RepairContext._scopeKey(expected.scope) ||
        inbox.accountFingerprint != expected.scope.accountFingerprint ||
        inbox.zone != expected.scope.zone ||
        inbox.generation != expected.generation ||
        inbox.fetchSequence != expected.sequence ||
        inbox.status != expected.status.index ||
        inbox.retryCount != expected.attemptCount ||
        inbox.nextEligibleAtMs !=
            (expected.nextEligibleAt?.toUtc().millisecondsSinceEpoch ?? 0) ||
        inbox.failureCategory != expected.lastFailure?.name ||
        inbox.completedAtMs !=
            expected.completedAt!.toUtc().millisecondsSinceEpoch ||
        inbox.createdAtMs !=
            expected.createdAt.toUtc().millisecondsSinceEpoch ||
        inbox.batchId != expected.batchId ||
        replay.changeIdHash != change.changeId ||
        replay.serverRecordIdHash != change.recordIdHash ||
        replay.payloadSha256 != change.payloadSha256 ||
        replay.inboxSequence != expected.sequence ||
        replay.changeType != change.type.name) {
      throw _failure('quarantine_repair_predecoded_entry_stale');
    }
  }

  static void _validateReceipt(
    _RepairContext context,
    CloudKitV2QuarantineRepairReceiptEntity receipt,
  ) {
    if (receipt.repairKey != context.repairKey ||
        receipt.scopeGenerationKey != context.scopeGenerationKey ||
        receipt.changeIdHash != context.changeIdHash ||
        receipt.converterRevision != context.correction.converterRevision ||
        receipt.correctionName != context.correction.correctionName ||
        receipt.scopeKey != context.scopeKey ||
        receipt.accountFingerprint != context.scope.accountFingerprint ||
        receipt.container != context.scope.container ||
        receipt.database != context.scope.database ||
        receipt.zone != context.scope.zone ||
        receipt.streamKind != context.scope.streamKind.name ||
        receipt.schemaVersion != context.scope.schemaVersion ||
        receipt.generation != context.generation ||
        (receipt.outcome != 'repaired' && receipt.outcome != 'failed') ||
        (receipt.outcome == 'repaired' &&
            (receipt.inboxSequence <= 0 ||
                receipt.serverRecordIdHash.isEmpty ||
                receipt.logicalEntityKeyHash == null)) ||
        (receipt.outcome == 'failed' &&
            (receipt.failureCategory == null ||
                receipt.safeCode == null ||
                !_safeCodePattern.hasMatch(receipt.safeCode!)))) {
      throw _failure('quarantine_repair_receipt_binding_invalid');
    }
  }

  static CloudKitV2QuarantineRepairResult _resultFromReceipt(
    CloudKitV2QuarantineRepairReceiptEntity receipt, {
    bool existing = false,
  }) {
    final category = _failureCategory(receipt.failureCategory);
    return CloudKitV2QuarantineRepairResult._(
      disposition: receipt.outcome == 'repaired'
          ? (existing
                ? CloudKitV2QuarantineRepairDisposition.alreadyRepaired
                : CloudKitV2QuarantineRepairDisposition.repaired)
          : (existing
                ? CloudKitV2QuarantineRepairDisposition.alreadyFailed
                : CloudKitV2QuarantineRepairDisposition.failed),
      repairKey: receipt.repairKey,
      failureCategory: category,
      safeCode: receipt.safeCode,
    );
  }

  static CloudSyncFailure _failure(String safeCode) => CloudSyncFailure(
    category: CloudFailureCategory.malformedRecord,
    safeCode: safeCode,
  );

  static CloudFailureCategory? _failureCategory(String? value) {
    if (value == null) return null;
    for (final category in CloudFailureCategory.values) {
      if (category.name == value) return category;
    }
    return CloudFailureCategory.unknown;
  }

  static CloudEntityKind _entityKind(String value) {
    for (final kind in CloudEntityKind.values) {
      if (kind.name == value) return kind;
    }
    throw const FormatException();
  }

  static CloudEntityKind _parentKind(CloudEntityKind kind) => switch (kind) {
    CloudEntityKind.message => CloudEntityKind.message,
    CloudEntityKind.attachment ||
    CloudEntityKind.reaction => CloudEntityKind.message,
    CloudEntityKind.groupPhoto => CloudEntityKind.chat,
    _ => throw _failure('quarantine_repair_parent_kind_invalid'),
  };

  static void _validateSnapshotValues(CloudSemanticSnapshot snapshot) {
    _validateHashedValue(snapshot.logicalEntityKeyHash);
    _validateOptionalHashedValue(snapshot.parentLogicalKeyHash);
    _validateOptionalContentDigest(snapshot.immutableContentDigest);
    _validateOptionalContentDigest(snapshot.groupMetadataDigest);
    _validateOptionalHashedValue(snapshot.etagHash);
    for (final part in snapshot.editParts.entries) {
      _validateHashedValue(part.key);
      _validateHashedValue(part.value.partKeyHash);
      _validateContentDigest(part.value.contentDigest);
    }
  }

  static String _encodeEditParts(Map<String, CloudEditPart> parts) {
    final keys = parts.keys.toList()..sort();
    final encoded = jsonEncode([
      for (final key in keys)
        <String, Object>{
          'mapKeyHash': key,
          'partKeyHash': parts[key]!.partKeyHash,
          'revision': parts[key]!.revision,
          'contentDigest': parts[key]!.contentDigest,
          'modifiedAtMs': parts[key]!.modifiedAt.toUtc().millisecondsSinceEpoch,
        },
    ]);
    if (utf8.encode(encoded).length > 256 * 1024) {
      throw _failure('quarantine_repair_edit_parts_oversized');
    }
    return encoded;
  }

  static void _validateHashedValue(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      throw _failure('quarantine_repair_digest_invalid');
    }
  }

  static void _validateContentDigest(String value) {
    if (!RegExp(r'^(?:[A-Za-z0-9_-]{43}|[0-9a-f]{64})$').hasMatch(value)) {
      throw _failure('quarantine_repair_digest_invalid');
    }
  }

  static void _validateOptionalHashedValue(String? value) {
    if (value != null) _validateHashedValue(value);
  }

  static void _validateOptionalContentDigest(String? value) {
    if (value != null) _validateContentDigest(value);
  }

  static void _validateProtectedReference(String? value) {
    if (value == null ||
        !RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      throw _failure('quarantine_repair_protected_reference_invalid');
    }
  }

  static String _protectedPayloadReferenceHash(String reference) => sha256
      .convert(utf8.encode('semantic-payload-reference\u001f$reference'))
      .toString();

  static final _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  static int _millisecondsOrSentinel(DateTime? value) =>
      value?.toUtc().millisecondsSinceEpoch ?? -9223372036854775808;

  static DateTime? _dateOrNull(int value) => value == -9223372036854775808
      ? null
      : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

final class _RepairContext {
  _RepairContext(CloudKitV2QuarantineRepairRequest request)
    : scope = request.scope,
      generation = request.generation,
      changeIdHash = request.changeIdHash,
      correction = request.correction,
      scopeKey = _scopeKey(request.scope),
      scopeGenerationKey =
          'semantic-generation4:${_digest('${_scopeKey(request.scope)}\u001f${request.generation}')}',
      changeKey =
          'change:${_digest('${request.scope.storageKey}\u001fchange\u001f${request.changeIdHash}')}',
      replayKey =
          'semantic-replay4:semantic-generation4:${_digest('${_scopeKey(request.scope)}\u001f${request.generation}')}:'
          '${_digest(request.changeIdHash)}',
      repairKey =
          'semantic-repair2:semantic-generation4:${_digest('${_scopeKey(request.scope)}\u001f${request.generation}')}:'
          '${_digest(request.changeIdHash)}:${request.correction.converterRevision}:'
          '${request.correction.correctionName}';

  final CloudSyncScope scope;
  final int generation;
  final String changeIdHash;
  final CloudKitV2ConverterCorrection correction;
  final String scopeKey;
  final String scopeGenerationKey;
  final String changeKey;
  final String replayKey;
  final String repairKey;

  String snapshotKey(CloudEntityKind kind, String logicalEntityKeyHash) =>
      'semantic-snapshot4:$scopeGenerationKey:${kind.name}:$logicalEntityKeyHash';

  String recordMapKey(String logicalEntityKeyHash) =>
      'record-map:${_digest('${scope.storageKey}\u001frecord-map\u001f$logicalEntityKeyHash')}';

  static String _scopeKey(CloudSyncScope scope) =>
      'scope2:${_digest(scope.storageKey)}';

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}

extension<T> on Iterable<T> {
  T? get singleOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    final value = iterator.current;
    if (iterator.moveNext()) throw StateError('expected at most one item');
    return value;
  }
}
