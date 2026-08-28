import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';
import 'cloudkit_repair_content_digest.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';
import 'objectbox_cloud_semantic_store_gateway.dart';

/// The only converter correction currently admitted to the repair lane.
///
/// Add a new named value only with a separately reviewed converter change.
/// Do not turn this into a caller-controlled revision range.
final class CloudKitV2ConverterCorrection {
  const CloudKitV2ConverterCorrection({
    required this.converterRevision,
    required this.correctionName,
    required this.expectedOriginalTerminalSafeCode,
    required this.expectedOriginalQuarantineReason,
  });

  static const messageFamilyAssociation = CloudKitV2ConverterCorrection(
    converterRevision: 'cloud-canonical-converter-r2',
    correctionName: 'message-family-outer-class-association',
    expectedOriginalTerminalSafeCode: 'semantic_conflict',
    expectedOriginalQuarantineReason: CloudFailureCategory.conflict,
  );

  final String converterRevision;
  final String correctionName;
  final String expectedOriginalTerminalSafeCode;
  final CloudFailureCategory expectedOriginalQuarantineReason;

  @override
  bool operator ==(Object other) =>
      other is CloudKitV2ConverterCorrection &&
      other.converterRevision == converterRevision &&
      other.correctionName == correctionName &&
      other.expectedOriginalTerminalSafeCode ==
          expectedOriginalTerminalSafeCode &&
      other.expectedOriginalQuarantineReason ==
          expectedOriginalQuarantineReason;

  @override
  int get hashCode => Object.hash(
    converterRevision,
    correctionName,
    expectedOriginalTerminalSafeCode,
    expectedOriginalQuarantineReason,
  );
}

/// Explicit allowlist for converter repairs. This is intentionally closed to
/// the reviewed correction above.
final class CloudKitV2QuarantineRepairAllowlist {
  const CloudKitV2QuarantineRepairAllowlist._();

  static const only = CloudKitV2ConverterCorrection.messageFamilyAssociation;

  static bool permits(CloudKitV2ConverterCorrection correction) =>
      correction == only;
}

/// Opaque test-only stand-in for the native one-shot repair capability.
///
/// Production composition cannot enable the repair gateway and product-mode
/// builds cannot mint this value. Delete this type when Rust exposes a
/// redeemable capability bound to the protected decoder output.
final class CloudKitV2QuarantineRepairTestCapability {
  const CloudKitV2QuarantineRepairTestCapability._(this._mutation);

  final CloudDecodedMutation _mutation;
}

final class CloudKitV2QuarantineRepairTestCapabilityFactory {
  const CloudKitV2QuarantineRepairTestCapabilityFactory._();

  static CloudKitV2QuarantineRepairTestCapability create(
    CloudDecodedMutation mutation,
  ) {
    if (const bool.fromEnvironment('dart.vm.product')) {
      throw UnsupportedError('cloudkit_quarantine_repair_test_capability');
    }
    return CloudKitV2QuarantineRepairTestCapability._(mutation);
  }
}

/// Compatibility entry point for the versioned Rust/Dart repair digest.
final class CloudKitV2SemanticContentDigest {
  const CloudKitV2SemanticContentDigest._();

  static String forPayload(CloudSemanticEntityPayload payload) {
    return CloudKitV2CanonicalRepairDigest.forPayload(payload);
  }
}

final class CloudKitV2QuarantineRepairRequest {
  CloudKitV2QuarantineRepairRequest({
    required this.scope,
    required this.persistenceLane,
    required this.generation,
    required this.changeIdHash,
    required this.correction,
    required this.leaseFence,
  }) {
    if (generation <= 0 || !_digestPattern.hasMatch(changeIdHash)) {
      throw ArgumentError('cloudkit_quarantine_repair_request_invalid');
    }
    if (!_revisionPattern.hasMatch(correction.converterRevision) ||
        !_safeCodePattern.hasMatch(correction.correctionName) ||
        !_safeCodePattern.hasMatch(
          correction.expectedOriginalTerminalSafeCode,
        ) ||
        persistenceLane != scope.persistenceLane ||
        leaseFence.ownerId.isEmpty ||
        leaseFence.ownerId.length > 256 ||
        leaseFence.generation <= 0 ||
        leaseFence.generation != generation) {
      throw ArgumentError('cloudkit_quarantine_repair_correction_invalid');
    }
  }

  static final _digestPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _revisionPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
  static final _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  final CloudSyncScope scope;
  final CloudSyncPersistenceLane persistenceLane;
  final int generation;
  final String changeIdHash;
  final CloudKitV2ConverterCorrection correction;
  final CloudCoordinatorLeaseFence leaseFence;
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

  const CloudKitV2QuarantineRepairResult.disabled(
    String repairKey, {
    String? safeCode,
  }) : this._(
         disposition: CloudKitV2QuarantineRepairDisposition.disabled,
         repairKey: repairKey,
         safeCode: safeCode,
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

  const CloudKitV2QuarantineRepairResult.failed(
    String repairKey, {
    required CloudFailureCategory failureCategory,
    required String safeCode,
  }) : this._(
         disposition: CloudKitV2QuarantineRepairDisposition.failed,
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
/// The correction is materialized before the ObjectBox write transaction. A
/// successful repair changes only canonical state, its semantic snapshot, and
/// a new immutable receipt. A deterministic failure changes only the failure
/// receipt; dependency and authorization failures remain retryable and do not
/// create a permanent receipt.
final class CloudKitV2QuarantineRepairGateway {
  CloudKitV2QuarantineRepairGateway({
    required Store store,
    required CloudCanonicalSemanticEntityAdapter canonicalAdapter,
    DateTime Function()? clock,
  }) : _store = store,
       _canonicalAdapter = canonicalAdapter,
       _clock = clock ?? DateTime.now,
       enabled = false,
       _testOnlyGateway = false,
       _inbox = store.box<CloudInboxChangeEntity>(),
       _replay = store.box<CloudSemanticReplayEntity>(),
       _recordMaps = store.box<CloudRecordMapEntity>(),
       _snapshots = store.box<CloudSemanticSnapshotEntity>(),
       _receipts = store.box<CloudKitV2QuarantineRepairReceiptEntity>() {
    if (!identical(canonicalAdapter.store, store)) {
      throw ArgumentError('canonical_adapter_store_mismatch');
    }
  }

  /// Test harness for the local transaction engine. Product-mode builds refuse
  /// construction, and production composition has no path to enable repair.
  CloudKitV2QuarantineRepairGateway.testOnly({
    required Store store,
    required CloudCanonicalSemanticEntityAdapter canonicalAdapter,
    DateTime Function()? clock,
    this.enabled = true,
  }) : _store = store,
       _canonicalAdapter = canonicalAdapter,
       _clock = clock ?? DateTime.now,
       _testOnlyGateway = true,
       _inbox = store.box<CloudInboxChangeEntity>(),
       _replay = store.box<CloudSemanticReplayEntity>(),
       _recordMaps = store.box<CloudRecordMapEntity>(),
       _snapshots = store.box<CloudSemanticSnapshotEntity>(),
       _receipts = store.box<CloudKitV2QuarantineRepairReceiptEntity>() {
    if (const bool.fromEnvironment('dart.vm.product')) {
      throw UnsupportedError('cloudkit_quarantine_repair_test_gateway');
    }
    if (!identical(canonicalAdapter.store, store)) {
      throw ArgumentError('canonical_adapter_store_mismatch');
    }
  }

  final Store _store;
  final CloudCanonicalSemanticEntityAdapter _canonicalAdapter;
  final DateTime Function() _clock;
  final bool enabled;
  final bool _testOnlyGateway;
  final Box<CloudInboxChangeEntity> _inbox;
  final Box<CloudSemanticReplayEntity> _replay;
  final Box<CloudRecordMapEntity> _recordMaps;
  final Box<CloudSemanticSnapshotEntity> _snapshots;
  final Box<CloudKitV2QuarantineRepairReceiptEntity> _receipts;

  Future<CloudKitV2QuarantineRepairResult> repair({
    required CloudKitV2QuarantineRepairRequest request,
    CloudKitV2QuarantineRepairTestCapability? testOnlyCapability,
  }) async {
    final context = _RepairContext(request);
    if (!enabled || !_testOnlyGateway || testOnlyCapability == null) {
      return CloudKitV2QuarantineRepairResult.disabled(
        context.repairKey,
        safeCode: 'quarantine_repair_native_capability_unavailable',
      );
    }
    if (request.persistenceLane != CloudSyncPersistenceLane.semanticV2 ||
        request.scope.persistenceLane != CloudSyncPersistenceLane.semanticV2) {
      return CloudKitV2QuarantineRepairResult.disabled(
        context.repairKey,
        safeCode: 'quarantine_repair_semantic_lane_required',
      );
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

    CloudKitV2QuarantineRepairReceiptEntity? existing;
    try {
      existing = _readReceipt(context);
    } on CloudSyncFailure catch (failure) {
      return _retryableResult(
        context,
        category: failure.category.isRetryable
            ? failure.category
            : CloudFailureCategory.localStorage,
        safeCode: failure.safeCode ?? 'quarantine_repair_receipt_invalid',
      );
    } catch (_) {
      return _retryableResult(
        context,
        category: CloudFailureCategory.localStorage,
        safeCode: 'quarantine_repair_receipt_invalid',
      );
    }
    if (existing != null) {
      return _revalidateExistingReceipt(context, existing);
    }

    late final CloudInboxEntry entry;
    try {
      entry = _readTerminalEntry(context);
    } on CloudSyncFailure catch (failure) {
      return _retryableResult(
        context,
        category: failure.category,
        safeCode: failure.safeCode ?? 'quarantine_repair_terminal_row_invalid',
      );
    } catch (_) {
      return _retryableResult(
        context,
        category: CloudFailureCategory.localStorage,
        safeCode: 'quarantine_repair_terminal_row_invalid',
      );
    }

    final decoded = testOnlyCapability._mutation;
    try {
      _validateDecoded(context, entry, decoded);
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
      final query =
          _receipts
              .query(
                CloudKitV2QuarantineRepairReceiptEntity_.repairKey.equals(
                  context.repairKey,
                ),
              )
              .build()
            ..limit = 2;
      try {
        final matches = query.find();
        if (matches.length > 1) {
          throw _failure('quarantine_repair_receipt_not_unique');
        }
        final receipt = matches.singleOrNull;
        return receipt;
      } finally {
        query.close();
      }
    });
  }

  CloudInboxEntry _readTerminalEntry(_RepairContext context) {
    return _store.runInTransaction(
      TxMode.read,
      () => _readTerminalEntryLocked(context),
    );
  }

  CloudInboxEntry _readTerminalEntryLocked(_RepairContext context) {
    final row = _findInboxByChangeKey(context.changeKey);
    if (row == null) throw _failure('quarantine_repair_inbox_missing');
    final replay = _findReplayByKey(context.replayKey);
    _validateTerminalPair(context, row, replay);

    final changeType = switch (row.changeType) {
      'save' => CloudChangeType.save,
      'delete' => CloudChangeType.delete,
      _ => throw _failure('quarantine_repair_change_type_invalid'),
    };
    final entry = CloudInboxEntry(
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
          : DateTime.fromMillisecondsSinceEpoch(row.completedAtMs, isUtc: true),
    );
    // Validate the persisted envelope before any decoder result can become a
    // permanent receipt. Malformed references remain retryable and cannot
    // poison the repair ledger.
    ObjectBoxCloudSemanticFence.validateEntryContext(
      entry: entry,
      leaseFence: context.leaseFence,
      expectedInboxStatus: CloudInboxStatus.quarantined,
    );
    return entry;
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
        final currentEntry = _readTerminalEntryLocked(context);
        if (existing.outcome == 'repaired') {
          _validateExistingRepairedReceiptLocked(
            context,
            existing,
            currentEntry,
          );
        } else {
          _validateExistingFailedReceiptLocked(context, existing, currentEntry);
        }
        ObjectBoxCloudSemanticFence.validateLocked(
          store: _store,
          entry: currentEntry,
          leaseFence: context.leaseFence,
          nowMs: _clock().toUtc().millisecondsSinceEpoch,
          expectedInboxStatus: CloudInboxStatus.quarantined,
          canonicalAdapter: _canonicalAdapter,
        );
        return _resultFromReceipt(existing, existing: true);
      }

      final inbox = _findInboxByChangeKey(context.changeKey);
      final replay = _findReplayByKey(context.replayKey);
      _validateTerminalPair(context, inbox, replay, expectedEntry: entry);
      _validatePredecessorsLocked(context, entry);
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
      // This must precede every repair-lane metadata write. In particular,
      // noChange repairs otherwise bind a record map before the canonical
      // adapter can reject a legacy or re-homed ownership proof.
      _canonicalAdapter.validateOwnershipEvidence(
        scope: context.scope,
        generation: context.generation,
        kind: snapshot.kind,
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
      );
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
      // A merge can retain local parent/scope metadata. The payload must bind
      // to that final canonical decision, not merely the incoming snapshot.
      _validatePayloadAgainstSnapshot(payload, merged);
      ObjectBoxCloudSemanticFence.validateLocked(
        store: _store,
        entry: entry,
        leaseFence: context.leaseFence,
        nowMs: _clock().toUtc().millisecondsSinceEpoch,
        expectedInboxStatus: CloudInboxStatus.quarantined,
        canonicalAdapter: _canonicalAdapter,
      );
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
            canonicalGuidHash: CloudCanonicalIdentityDigest.forPayload(
              scope: context.scope,
              generation: context.generation,
              payload: payload,
            ),
            canonicalGuidLookupHash:
                CloudCanonicalIdentityDigest.forPayloadLookup(
                  scope: context.scope,
                  generation: context.generation,
                  payload: payload,
                ),
            existingId: existingSnapshot?.id ?? 0,
          ),
        );
      }
      if (!_canonicalAdapter.entityExists(
        scope: context.scope,
        generation: context.generation,
        kind: merged.kind,
        logicalEntityKeyHash: merged.logicalEntityKeyHash,
      )) {
        throw _failure('quarantine_repair_canonical_artifact_missing');
      }

      final evidenceSnapshot = _findSnapshot(
        context,
        merged.kind,
        merged.logicalEntityKeyHash,
      );
      final evidenceRecordMap = _findRecordMap(
        context.recordMapKey(merged.logicalEntityKeyHash),
      );
      if (evidenceSnapshot == null || evidenceRecordMap == null) {
        throw _failure('quarantine_repair_evidence_artifact_missing');
      }
      final receiptCreatedAtMs = _clock().toUtc().millisecondsSinceEpoch;
      final evidenceDigest = _CloudKitV2RepairEvidenceDigest.compute(
        context: context,
        inbox: inbox!,
        replay: replay!,
        outcome: 'repaired',
        failureCategory: null,
        safeCode: null,
        logicalEntityKeyHash: merged.logicalEntityKeyHash,
        snapshot: evidenceSnapshot,
        recordMap: evidenceRecordMap,
        canonicalOwnerExists: true,
        receiptCreatedAtMs: receiptCreatedAtMs,
      );

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
        originalPayloadSha256: entry.change.payloadSha256,
        originalQuarantineReason:
            context.correction.expectedOriginalQuarantineReason.name,
        originalTerminalSafeCode:
            context.correction.expectedOriginalTerminalSafeCode,
        evidenceDigestVersion: _CloudKitV2RepairEvidenceDigest.version,
        evidenceDigestSha256: evidenceDigest,
        outcome: 'repaired',
        logicalEntityKeyHash: merged.logicalEntityKeyHash,
        createdAtMs: receiptCreatedAtMs,
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
      CloudKitV2QuarantineRepairReceiptEntity? existing;
      try {
        existing = _readReceipt(context);
      } on CloudSyncFailure catch (failure) {
        return _retryableResult(
          context,
          category: failure.category.isRetryable
              ? failure.category
              : CloudFailureCategory.localStorage,
          safeCode: failure.safeCode ?? 'quarantine_repair_receipt_invalid',
        );
      } catch (_) {
        return _retryableResult(
          context,
          category: CloudFailureCategory.localStorage,
          safeCode: 'quarantine_repair_receipt_invalid',
        );
      }
      if (existing != null) {
        return _revalidateExistingReceipt(context, existing);
      }
      return _retryableResult(context, category: category, safeCode: safeCode);
    }
    // A permanent receipt is meaningful only when the exact terminal evidence
    // has been re-read under the current coordinator fence. In particular, do
    // not poison a future repair when the terminal row is merely missing or
    // stale.
    if (expectedEntry == null) {
      return CloudKitV2QuarantineRepairResult.failed(
        context.repairKey,
        failureCategory: category,
        safeCode: safeCode,
      );
    }
    try {
      return _store.runInTransaction(TxMode.write, () {
        final existing = _findReceipt(context);
        if (existing != null) {
          try {
            _validateReceipt(context, existing);
            final entry = _readTerminalEntryLocked(context);
            if (existing.outcome == 'repaired') {
              _validateExistingRepairedReceiptLocked(context, existing, entry);
            } else {
              _validateExistingFailedReceiptLocked(context, existing, entry);
            }
            ObjectBoxCloudSemanticFence.validateLocked(
              store: _store,
              entry: entry,
              leaseFence: context.leaseFence,
              nowMs: _clock().toUtc().millisecondsSinceEpoch,
              expectedInboxStatus: CloudInboxStatus.quarantined,
              canonicalAdapter: _canonicalAdapter,
            );
            return _resultFromReceipt(existing, existing: true);
          } on CloudSyncFailure catch (failure) {
            return _retryableResult(
              context,
              category: failure.category.isRetryable
                  ? failure.category
                  : CloudFailureCategory.localStorage,
              safeCode: failure.safeCode ?? 'quarantine_repair_receipt_invalid',
            );
          } catch (_) {
            return _retryableResult(
              context,
              category: CloudFailureCategory.localStorage,
              safeCode: 'quarantine_repair_receipt_invalid',
            );
          }
        }
        final terminal = _findInboxByChangeKey(context.changeKey);
        final replay = _findReplayByKey(context.replayKey);
        try {
          _validateTerminalPair(
            context,
            terminal,
            replay,
            expectedEntry: expectedEntry,
          );
          ObjectBoxCloudSemanticFence.validateLocked(
            store: _store,
            entry: expectedEntry,
            leaseFence: context.leaseFence,
            nowMs: _clock().toUtc().millisecondsSinceEpoch,
            expectedInboxStatus: CloudInboxStatus.quarantined,
            canonicalAdapter: _canonicalAdapter,
          );
        } on CloudSyncFailure {
          return _retryableResult(
            context,
            category: CloudFailureCategory.dependency,
            safeCode: 'quarantine_repair_terminal_state_changed',
          );
        }
        final receiptCreatedAtMs = _clock().toUtc().millisecondsSinceEpoch;
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
          inboxSequence: expectedEntry.sequence,
          serverRecordIdHash: expectedEntry.change.recordIdHash,
          originalPayloadSha256: expectedEntry.change.payloadSha256,
          originalQuarantineReason:
              context.correction.expectedOriginalQuarantineReason.name,
          originalTerminalSafeCode:
              context.correction.expectedOriginalTerminalSafeCode,
          evidenceDigestVersion: _CloudKitV2RepairEvidenceDigest.version,
          evidenceDigestSha256: _CloudKitV2RepairEvidenceDigest.compute(
            context: context,
            inbox: terminal!,
            replay: replay!,
            outcome: 'failed',
            failureCategory: category.name,
            safeCode: safeCode,
            logicalEntityKeyHash: null,
            snapshot: null,
            recordMap: null,
            canonicalOwnerExists: false,
            receiptCreatedAtMs: receiptCreatedAtMs,
          ),
          outcome: 'failed',
          failureCategory: category.name,
          safeCode: safeCode,
          createdAtMs: receiptCreatedAtMs,
        );
        _receipts.put(receipt);
        return _resultFromReceipt(receipt);
      });
    } on CloudSyncFailure catch (failure) {
      return _retryableResult(
        context,
        category: failure.category.isRetryable
            ? failure.category
            : CloudFailureCategory.localStorage,
        safeCode: failure.safeCode ?? 'quarantine_repair_receipt_invalid',
      );
    } catch (_) {
      return _retryableResult(
        context,
        category: CloudFailureCategory.localStorage,
        safeCode: 'quarantine_repair_receipt_invalid',
      );
    }
  }

  CloudKitV2QuarantineRepairResult _retryableResult(
    _RepairContext context, {
    required CloudFailureCategory category,
    required String safeCode,
  }) => CloudKitV2QuarantineRepairResult.retryable(
    context.repairKey,
    failureCategory: category,
    safeCode: safeCode,
  );

  CloudKitV2QuarantineRepairReceiptEntity? _findReceipt(
    _RepairContext context,
  ) {
    final query =
        _receipts
            .query(
              CloudKitV2QuarantineRepairReceiptEntity_.repairKey.equals(
                context.repairKey,
              ),
            )
            .build()
          ..limit = 2;
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

  CloudInboxChangeEntity? _findInboxByChangeKey(String changeKey) {
    final query =
        _inbox
            .query(CloudInboxChangeEntity_.changeKey.equals(changeKey))
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw _failure('quarantine_repair_inbox_change_not_unique');
      }
      return matches.singleOrNull;
    } finally {
      query.close();
    }
  }

  CloudSemanticReplayEntity? _findReplayByKey(String replayKey) {
    final query =
        _replay
            .query(CloudSemanticReplayEntity_.replayKey.equals(replayKey))
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw _failure('quarantine_repair_replay_not_unique');
      }
      return matches.singleOrNull;
    } finally {
      query.close();
    }
  }

  CloudSyncCheckpointEntity? _findCheckpoint(_RepairContext context) {
    final query =
        _store
            .box<CloudSyncCheckpointEntity>()
            .query(
              CloudSyncCheckpointEntity_.checkpointKey.equals(context.scopeKey),
            )
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw _failure('quarantine_repair_checkpoint_not_unique');
      }
      return matches.singleOrNull;
    } finally {
      query.close();
    }
  }

  List<CloudInboxChangeEntity> _findInboxAtSequence(
    _RepairContext context,
    int sequence,
  ) {
    final query =
        _inbox
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(context.scopeKey)
                  .and(
                    CloudInboxChangeEntity_.generation.equals(
                      context.generation,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.fetchSequence.equals(sequence)),
            )
            .build()
          ..limit = 2;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudInboxChangeEntity> _findPredecessorInboxRows(
    _RepairContext context,
    int targetSequence,
  ) {
    final builder = _inbox.query(
      CloudInboxChangeEntity_.scopeKey
          .equals(context.scopeKey)
          .and(CloudInboxChangeEntity_.generation.equals(context.generation))
          .and(CloudInboxChangeEntity_.fetchSequence.lessThan(targetSequence)),
    )..order(CloudInboxChangeEntity_.fetchSequence);
    final query = builder.build()..limit = _maxRepairSequenceSpan + 1;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  /// A repaired predecessor remains quarantined by design: the original
  /// evidence is immutable. It may satisfy ordering only when its exact
  /// durable receipt still proves that original terminal pair, snapshot, map,
  /// and canonical owner have not changed.
  void _validatePredecessorsLocked(
    _RepairContext context,
    CloudInboxEntry entry,
  ) {
    if (entry.sequence <= 0 || entry.sequence > _maxRepairSequenceSpan) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'quarantine_repair_sequence_window_unbounded',
      );
    }
    final checkpoint = _findCheckpoint(context);
    if (checkpoint == null ||
        checkpoint.accountFingerprint != context.scope.accountFingerprint ||
        checkpoint.container != context.scope.container ||
        checkpoint.database != context.scope.database ||
        checkpoint.zone != context.scope.zone ||
        checkpoint.streamKind != context.scope.streamKind.name ||
        checkpoint.schemaVersion != context.scope.schemaVersion ||
        checkpoint.persistenceLane != context.scope.persistenceLane.name ||
        checkpoint.generation != context.generation ||
        checkpoint.fetchedSequence < entry.sequence ||
        checkpoint.appliedSequence < entry.sequence) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'quarantine_repair_checkpoint_sequence_unproven',
      );
    }

    final targetRows = _findInboxAtSequence(context, entry.sequence);
    if (targetRows.length != 1 ||
        targetRows.single.changeIdHash != context.changeIdHash) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: targetRows.length > 1
            ? 'quarantine_repair_duplicate_target_sequence'
            : 'quarantine_repair_target_sequence_unproven',
      );
    }

    final predecessors = _findPredecessorInboxRows(context, entry.sequence);
    for (var index = 0; index < predecessors.length; index++) {
      final row = predecessors[index];
      final expectedSequence = index + 1;
      if (row.fetchSequence != expectedSequence) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: row.fetchSequence < expectedSequence
              ? 'quarantine_repair_duplicate_predecessor_sequence'
              : 'quarantine_repair_sequence_gap_or_pruned_prefix',
        );
      }
      if (row.status == CloudInboxStatus.applied.index) continue;
      if (row.status != CloudInboxStatus.quarantined.index) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'quarantine_repair_sequence_predecessor_not_applied',
        );
      }
      try {
        _validateHashedValue(row.changeIdHash);
        final predecessor = context.forChange(row.changeIdHash);
        final receipt = _findReceipt(predecessor);
        if (receipt == null || receipt.outcome != 'repaired') {
          throw const _PredecessorNotRepaired();
        }
        if (_receiptRequiresMigration(receipt)) {
          throw _failure(
            'quarantine_repair_predecessor_receipt_migration_required',
          );
        }
        _validateReceipt(predecessor, receipt);
        final predecessorEntry = _readTerminalEntryLocked(predecessor);
        if (predecessorEntry.sequence != row.fetchSequence) {
          throw _failure('quarantine_repair_predecessor_sequence_stale');
        }
        _validateExistingRepairedReceiptLocked(
          predecessor,
          receipt,
          predecessorEntry,
        );
        ObjectBoxCloudSemanticFence.validateLocked(
          store: _store,
          entry: predecessorEntry,
          leaseFence: predecessor.leaseFence,
          nowMs: _clock().toUtc().millisecondsSinceEpoch,
          expectedInboxStatus: CloudInboxStatus.quarantined,
          canonicalAdapter: _canonicalAdapter,
        );
      } on _PredecessorNotRepaired {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'quarantine_repair_sequence_predecessor_not_applied',
        );
      } on CloudSyncFailure {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'quarantine_repair_predecessor_receipt_invalid',
        );
      } catch (_) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'quarantine_repair_predecessor_receipt_invalid',
        );
      }
    }
    if (predecessors.length != entry.sequence - 1) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'quarantine_repair_sequence_gap_or_pruned_prefix',
      );
    }
  }

  CloudKitV2QuarantineRepairResult _revalidateExistingReceipt(
    _RepairContext context,
    CloudKitV2QuarantineRepairReceiptEntity receipt,
  ) {
    if (_receiptRequiresMigration(receipt)) {
      return _retryableResult(
        context,
        category: CloudFailureCategory.localStorage,
        safeCode: 'quarantine_repair_receipt_migration_required',
      );
    }
    try {
      _validateReceipt(context, receipt);
      _store.runInTransaction(TxMode.read, () {
        final entry = _readTerminalEntryLocked(context);
        if (receipt.outcome == 'repaired') {
          _validateExistingRepairedReceiptLocked(context, receipt, entry);
        } else {
          _validateExistingFailedReceiptLocked(context, receipt, entry);
        }
        ObjectBoxCloudSemanticFence.validateLocked(
          store: _store,
          entry: entry,
          leaseFence: context.leaseFence,
          nowMs: _clock().toUtc().millisecondsSinceEpoch,
          expectedInboxStatus: CloudInboxStatus.quarantined,
          canonicalAdapter: _canonicalAdapter,
        );
      });
      return _resultFromReceipt(receipt, existing: true);
    } on CloudSyncFailure catch (failure) {
      return _retryableResult(
        context,
        category: failure.category.isRetryable
            ? failure.category
            : CloudFailureCategory.localStorage,
        safeCode: failure.safeCode ?? 'quarantine_repair_receipt_invalid',
      );
    } catch (_) {
      return _retryableResult(
        context,
        category: CloudFailureCategory.localStorage,
        safeCode: 'quarantine_repair_receipt_invalid',
      );
    }
  }

  static bool _receiptRequiresMigration(
    CloudKitV2QuarantineRepairReceiptEntity receipt,
  ) =>
      receipt.originalPayloadSha256 == null ||
      receipt.originalQuarantineReason == null ||
      receipt.originalTerminalSafeCode == null ||
      receipt.evidenceDigestVersion !=
          _CloudKitV2RepairEvidenceDigest.version ||
      receipt.evidenceDigestSha256 == null;

  void _validateExistingRepairedReceiptLocked(
    _RepairContext context,
    CloudKitV2QuarantineRepairReceiptEntity receipt,
    CloudInboxEntry entry,
  ) {
    if (receipt.inboxSequence != entry.sequence ||
        receipt.serverRecordIdHash != entry.change.recordIdHash ||
        receipt.originalPayloadSha256 != entry.change.payloadSha256 ||
        receipt.originalQuarantineReason !=
            context.correction.expectedOriginalQuarantineReason.name ||
        receipt.originalTerminalSafeCode !=
            context.correction.expectedOriginalTerminalSafeCode ||
        receipt.logicalEntityKeyHash == null) {
      throw _failure('quarantine_repair_existing_receipt_stale');
    }
    final logicalEntityKeyHash = receipt.logicalEntityKeyHash!;
    final candidates = _findSnapshotsByLogicalKey(
      context,
      logicalEntityKeyHash,
    );
    if (candidates.length != 1) {
      throw _failure('quarantine_repair_existing_snapshot_missing');
    }
    final snapshotEntity = candidates.single;
    final kind = _entityKind(snapshotEntity.entityKind);
    _validateSnapshotEntity(
      context,
      snapshotEntity,
      kind,
      logicalEntityKeyHash,
    );
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
    final inbox = _findInboxByChangeKey(context.changeKey);
    final replay = _findReplayByKey(context.replayKey);
    if (inbox == null || replay == null) {
      throw _failure('quarantine_repair_existing_terminal_missing');
    }
    final evidenceDigest = _CloudKitV2RepairEvidenceDigest.compute(
      context: context,
      inbox: inbox,
      replay: replay,
      outcome: receipt.outcome,
      failureCategory: receipt.failureCategory,
      safeCode: receipt.safeCode,
      logicalEntityKeyHash: logicalEntityKeyHash,
      snapshot: snapshotEntity,
      recordMap: recordMap,
      canonicalOwnerExists: true,
      receiptCreatedAtMs: receipt.createdAtMs,
    );
    if (receipt.evidenceDigestSha256 != evidenceDigest) {
      throw _failure('quarantine_repair_existing_evidence_stale');
    }
  }

  void _validateExistingFailedReceiptLocked(
    _RepairContext context,
    CloudKitV2QuarantineRepairReceiptEntity receipt,
    CloudInboxEntry entry,
  ) {
    if (receipt.inboxSequence != entry.sequence ||
        receipt.serverRecordIdHash != entry.change.recordIdHash ||
        receipt.originalPayloadSha256 != entry.change.payloadSha256 ||
        receipt.originalQuarantineReason !=
            context.correction.expectedOriginalQuarantineReason.name ||
        receipt.originalTerminalSafeCode !=
            context.correction.expectedOriginalTerminalSafeCode) {
      throw _failure('quarantine_repair_existing_failed_receipt_stale');
    }
    final inbox = _findInboxByChangeKey(context.changeKey);
    final replay = _findReplayByKey(context.replayKey);
    if (inbox == null || replay == null) {
      throw _failure('quarantine_repair_existing_terminal_missing');
    }
    final evidenceDigest = _CloudKitV2RepairEvidenceDigest.compute(
      context: context,
      inbox: inbox,
      replay: replay,
      outcome: receipt.outcome,
      failureCategory: receipt.failureCategory,
      safeCode: receipt.safeCode,
      logicalEntityKeyHash: null,
      snapshot: null,
      recordMap: null,
      canonicalOwnerExists: false,
      receiptCreatedAtMs: receipt.createdAtMs,
    );
    if (receipt.evidenceDigestSha256 != evidenceDigest) {
      throw _failure('quarantine_repair_existing_evidence_stale');
    }
  }

  List<CloudSemanticSnapshotEntity> _findSnapshotsByLogicalKey(
    _RepairContext context,
    String logicalEntityKeyHash,
  ) {
    final query =
        _snapshots
            .query(
              CloudSemanticSnapshotEntity_.scopeGenerationKey
                  .equals(context.scopeGenerationKey)
                  .and(
                    CloudSemanticSnapshotEntity_.logicalEntityKeyHash.equals(
                      logicalEntityKeyHash,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  CloudSemanticSnapshotEntity? _findSnapshot(
    _RepairContext context,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) {
    final snapshotKey = context.snapshotKey(kind, logicalEntityKeyHash);
    final query =
        _snapshots
            .query(CloudSemanticSnapshotEntity_.snapshotKey.equals(snapshotKey))
            .build()
          ..limit = 2;
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
    required String canonicalGuidHash,
    required String canonicalGuidLookupHash,
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
      canonicalGuidHash: canonicalGuidHash,
      canonicalGuidLookupHash: canonicalGuidLookupHash,
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

    final collisions =
        _recordMaps
            .query(
              CloudRecordMapEntity_.scopeKey
                  .equals(context.scopeKey)
                  .and(
                    CloudRecordMapEntity_.serverRecordIdHash.equals(
                      entry.change.recordIdHash,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      final matches = collisions.find();
      if (matches.length > 1) {
        throw _failure('quarantine_repair_record_mapping_not_unique');
      }
      for (final collision in matches) {
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
    final query =
        _recordMaps.query(CloudRecordMapEntity_.mapKey.equals(mapKey)).build()
          ..limit = 2;
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
        entity.generation != context.generation ||
        entity.serverRecordIdHash != expectedChange.recordIdHash ||
        entity.encryptedServerRecordId !=
            expectedChange.encryptedServerRecordId ||
        entity.etagHash != expectedChange.etagHash ||
        entity.encryptedRawRecordRef !=
            expectedChange.encryptedPayloadReference) {
      throw _failure('quarantine_repair_record_map_scope_mismatch');
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
    _validatePayloadAgainstSnapshot(payload, snapshot);
    if (context.scope.zone != 'messageManateeZone' ||
        (snapshot.kind != CloudEntityKind.message &&
            snapshot.kind != CloudEntityKind.reaction)) {
      throw _failure('quarantine_repair_entity_kind_not_allowlisted');
    }
    _validateSnapshotValues(snapshot);
  }

  void _validatePayloadAgainstSnapshot(
    CloudSemanticEntityPayload payload,
    CloudSemanticSnapshot snapshot,
  ) {
    if (snapshot.kind != payload.kind ||
        snapshot.logicalEntityKeyHash != payload.logicalEntityKeyHash) {
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
    final payloadDigest = CloudKitV2SemanticContentDigest.forPayload(payload);
    if (snapshot.immutableContentDigest != payloadDigest) {
      throw _failure('quarantine_repair_payload_content_mismatch');
    }
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
        replay.terminalOutcome != 'quarantined' ||
        inbox.failureCategory !=
            context.correction.expectedOriginalQuarantineReason.name ||
        replay.terminalSafeCode !=
            context.correction.expectedOriginalTerminalSafeCode) {
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
        receipt.inboxSequence <= 0 ||
        receipt.serverRecordIdHash.isEmpty ||
        receipt.originalPayloadSha256 == null ||
        receipt.originalQuarantineReason == null ||
        receipt.originalTerminalSafeCode == null ||
        receipt.evidenceDigestVersion !=
            _CloudKitV2RepairEvidenceDigest.version ||
        receipt.evidenceDigestSha256 == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(receipt.evidenceDigestSha256!) ||
        (receipt.outcome == 'repaired' &&
            receipt.logicalEntityKeyHash == null) ||
        (receipt.outcome == 'failed' &&
            (receipt.failureCategory == null ||
                !_isTerminalFailureCategory(receipt.failureCategory!) ||
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

  static bool _isTerminalFailureCategory(String value) =>
      CloudFailureCategory.values.any(
        (category) =>
            category.name == value &&
            category != CloudFailureCategory.unknown &&
            !category.isRetryable,
      );

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

  static const _maxRepairSequenceSpan = 4096;
  static final _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  static int _millisecondsOrSentinel(DateTime? value) =>
      value?.toUtc().millisecondsSinceEpoch ?? -9223372036854775808;

  static DateTime? _dateOrNull(int value) => value == -9223372036854775808
      ? null
      : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

final class _CloudKitV2RepairEvidenceDigest {
  const _CloudKitV2RepairEvidenceDigest._();

  static const version = 'cloudkit-quarantine-repair-evidence-v1';

  static String compute({
    required _RepairContext context,
    required CloudInboxChangeEntity inbox,
    required CloudSemanticReplayEntity replay,
    required String outcome,
    required String? failureCategory,
    required String? safeCode,
    required String? logicalEntityKeyHash,
    required CloudSemanticSnapshotEntity? snapshot,
    required CloudRecordMapEntity? recordMap,
    required bool canonicalOwnerExists,
    required int receiptCreatedAtMs,
  }) {
    final writer = _RepairEvidenceWriter()
      ..string('domain', 'bluebubbles.cloudkit.quarantine-repair.evidence')
      ..string('version', version)
      ..string('outcome', outcome)
      ..nullableString('failureCategory', failureCategory)
      ..nullableString('safeCode', safeCode)
      ..nullableString('logicalEntityKeyHash', logicalEntityKeyHash)
      ..string('scope.storageKey', context.scope.storageKey)
      ..string('scope.key', context.scopeKey)
      ..string('scope.generationKey', context.scopeGenerationKey)
      ..string('scope.accountFingerprint', context.scope.accountFingerprint)
      ..string('scope.container', context.scope.container)
      ..string('scope.database', context.scope.database)
      ..string('scope.zone', context.scope.zone)
      ..string('scope.streamKind', context.scope.streamKind.name)
      ..integer('scope.schemaVersion', context.scope.schemaVersion)
      ..string('scope.persistenceLane', context.scope.persistenceLane.name)
      ..integer('generation', context.generation)
      ..string('changeIdHash', context.changeIdHash)
      ..string(
        'correction.converterRevision',
        context.correction.converterRevision,
      )
      ..string('correction.name', context.correction.correctionName)
      ..string(
        'correction.originalSafeCode',
        context.correction.expectedOriginalTerminalSafeCode,
      )
      ..string(
        'correction.originalCategory',
        context.correction.expectedOriginalQuarantineReason.name,
      )
      ..string(
        'lease.ownerHash',
        sha256
            .convert(
              utf8.encode(
                'quarantine-repair-owner\u001f${context.leaseFence.ownerId}',
              ),
            )
            .toString(),
      )
      ..integer('lease.generation', context.leaseFence.generation);

    writer.integer('receipt.createdAtMs', receiptCreatedAtMs);

    _inbox(writer, inbox);
    _replay(writer, replay);
    _snapshot(writer, snapshot);
    _recordMap(writer, recordMap);
    writer.boolean('canonicalOwnerExists', canonicalOwnerExists);
    return writer.finish();
  }

  static void _inbox(
    _RepairEvidenceWriter writer,
    CloudInboxChangeEntity value,
  ) {
    writer
      ..string('inbox.changeKey', value.changeKey)
      ..string('inbox.changeIdHash', value.changeIdHash)
      ..string('inbox.scopeKey', value.scopeKey)
      ..string('inbox.accountFingerprint', value.accountFingerprint)
      ..string('inbox.zone', value.zone)
      ..string('inbox.serverRecordIdHash', value.serverRecordIdHash)
      ..nullableString('inbox.etagHash', value.etagHash)
      ..string('inbox.changeType', value.changeType)
      ..nullableString(
        'inbox.encryptedServerRecordId',
        value.encryptedServerRecordId,
      )
      ..nullableString(
        'inbox.protectedSystemFieldsRef',
        value.protectedSystemFieldsRef,
      )
      ..nullableString('inbox.encryptedPayloadRef', value.encryptedPayloadRef)
      ..nullableString('inbox.payloadSha256', value.payloadSha256)
      ..string('inbox.batchId', value.batchId)
      ..integer('inbox.generation', value.generation)
      ..integer('inbox.fetchSequence', value.fetchSequence)
      ..integer('inbox.status', value.status)
      ..boolean('inbox.isTombstone', value.isTombstone)
      ..nullableString('inbox.preflightCategory', value.preflightCategory)
      ..nullableString('inbox.failureCategory', value.failureCategory)
      ..nullableString('inbox.preflightCode', value.preflightCode)
      ..integer('inbox.retryCount', value.retryCount)
      ..integer('inbox.nextEligibleAtMs', value.nextEligibleAtMs)
      ..integer('inbox.serverModifiedAtMs', value.serverModifiedAtMs)
      ..integer('inbox.createdAtMs', value.createdAtMs)
      ..integer('inbox.updatedAtMs', value.updatedAtMs)
      ..integer('inbox.completedAtMs', value.completedAtMs);
  }

  static void _replay(
    _RepairEvidenceWriter writer,
    CloudSemanticReplayEntity value,
  ) {
    writer
      ..string('replay.replayKey', value.replayKey)
      ..string('replay.scopeGenerationKey', value.scopeGenerationKey)
      ..string('replay.scopeKey', value.scopeKey)
      ..string('replay.accountFingerprint', value.accountFingerprint)
      ..string('replay.container', value.container)
      ..string('replay.database', value.database)
      ..string('replay.zone', value.zone)
      ..string('replay.streamKind', value.streamKind)
      ..integer('replay.schemaVersion', value.schemaVersion)
      ..integer('replay.generation', value.generation)
      ..string('replay.changeIdHash', value.changeIdHash)
      ..string('replay.serverRecordIdHash', value.serverRecordIdHash)
      ..nullableString(
        'replay.logicalEntityKeyHash',
        value.logicalEntityKeyHash,
      )
      ..nullableString('replay.payloadSha256', value.payloadSha256)
      ..nullableString(
        'replay.protectedPayloadReferenceHash',
        value.protectedPayloadReferenceHash,
      )
      ..integer('replay.inboxSequence', value.inboxSequence)
      ..string('replay.changeType', value.changeType)
      ..string('replay.terminalOutcome', value.terminalOutcome)
      ..nullableString('replay.terminalSafeCode', value.terminalSafeCode)
      ..integer('replay.updatedAtMs', value.updatedAtMs);
  }

  static void _snapshot(
    _RepairEvidenceWriter writer,
    CloudSemanticSnapshotEntity? value,
  ) {
    writer.boolean('snapshot.present', value != null);
    if (value == null) return;
    writer
      ..string('snapshot.snapshotKey', value.snapshotKey)
      ..string('snapshot.scopeGenerationKey', value.scopeGenerationKey)
      ..string('snapshot.scopeKey', value.scopeKey)
      ..string('snapshot.accountFingerprint', value.accountFingerprint)
      ..string('snapshot.container', value.container)
      ..string('snapshot.database', value.database)
      ..string('snapshot.zone', value.zone)
      ..string('snapshot.streamKind', value.streamKind)
      ..integer('snapshot.schemaVersion', value.schemaVersion)
      ..integer('snapshot.generation', value.generation)
      ..string('snapshot.entityKind', value.entityKind)
      ..string('snapshot.logicalEntityKeyHash', value.logicalEntityKeyHash)
      ..nullableString('snapshot.canonicalGuidHash', value.canonicalGuidHash)
      ..nullableString(
        'snapshot.canonicalGuidLookupHash',
        value.canonicalGuidLookupHash,
      )
      ..nullableString(
        'snapshot.parentLogicalKeyHash',
        value.parentLogicalKeyHash,
      )
      ..nullableString(
        'snapshot.immutableContentDigest',
        value.immutableContentDigest,
      )
      ..integer('snapshot.createdAtMs', value.createdAtMs)
      ..integer('snapshot.readAtMs', value.readAtMs)
      ..integer('snapshot.deliveredAtMs', value.deliveredAtMs)
      ..string('snapshot.editPartsJson', value.editPartsJson)
      ..integer('snapshot.retractedAtMs', value.retractedAtMs)
      ..nullableInteger('snapshot.groupVersion', value.groupVersion)
      ..nullableString(
        'snapshot.groupMetadataDigest',
        value.groupMetadataDigest,
      )
      ..nullableString('snapshot.etagHash', value.etagHash)
      ..integer('snapshot.updatedAtMs', value.updatedAtMs);
  }

  static void _recordMap(
    _RepairEvidenceWriter writer,
    CloudRecordMapEntity? value,
  ) {
    writer.boolean('recordMap.present', value != null);
    if (value == null) return;
    writer
      ..string('recordMap.mapKey', value.mapKey)
      ..string('recordMap.scopeKey', value.scopeKey)
      ..string('recordMap.accountFingerprint', value.accountFingerprint)
      ..string('recordMap.zone', value.zone)
      ..string('recordMap.logicalEntityKeyHash', value.logicalEntityKeyHash)
      ..string('recordMap.serverRecordIdHash', value.serverRecordIdHash)
      ..integer('recordMap.generation', value.generation)
      ..string(
        'recordMap.encryptedServerRecordId',
        value.encryptedServerRecordId,
      )
      ..nullableString('recordMap.etagHash', value.etagHash)
      ..nullableString(
        'recordMap.encryptedRawRecordRef',
        value.encryptedRawRecordRef,
      )
      ..integer('recordMap.updatedAtMs', value.updatedAtMs);
  }
}

final class _RepairEvidenceWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void string(String name, String value) => _add(name, 1, utf8.encode(value));
  void nullableString(String name, String? value) =>
      value == null ? _add(name, 0, const <int>[]) : string(name, value);
  void integer(String name, int value) => _add(name, 2, utf8.encode('$value'));
  void nullableInteger(String name, int? value) =>
      value == null ? _add(name, 0, const <int>[]) : integer(name, value);
  void boolean(String name, bool value) => _add(name, 3, <int>[value ? 1 : 0]);

  void _add(String name, int typeTag, List<int> value) {
    _framed(utf8.encode(name));
    _framed(<int>[typeTag, ...value]);
  }

  void _framed(List<int> value) {
    final length = ByteData(8)..setUint64(0, value.length, Endian.big);
    _bytes
      ..add(length.buffer.asUint8List())
      ..add(value);
  }

  String finish() => sha256.convert(_bytes.takeBytes()).toString();
}

final class _RepairContext {
  _RepairContext(CloudKitV2QuarantineRepairRequest request)
    : scope = request.scope,
      generation = request.generation,
      changeIdHash = request.changeIdHash,
      correction = request.correction,
      leaseFence = request.leaseFence,
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
  final CloudCoordinatorLeaseFence leaseFence;
  final String scopeKey;
  final String scopeGenerationKey;
  final String changeKey;
  final String replayKey;
  final String repairKey;

  String snapshotKey(CloudEntityKind kind, String logicalEntityKeyHash) =>
      'semantic-snapshot4:$scopeGenerationKey:${kind.name}:$logicalEntityKeyHash';

  String recordMapKey(String logicalEntityKeyHash) =>
      'record-map:${_digest('${scope.storageKey}\u001frecord-map\u001f$logicalEntityKeyHash')}';

  _RepairContext forChange(String predecessorChangeIdHash) => _RepairContext(
    CloudKitV2QuarantineRepairRequest(
      scope: scope,
      persistenceLane: scope.persistenceLane,
      generation: generation,
      changeIdHash: predecessorChangeIdHash,
      correction: correction,
      leaseFence: leaseFence,
    ),
  );

  static String _scopeKey(CloudSyncScope scope) =>
      'scope2:${_digest(scope.storageKey)}';

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}

final class _PredecessorNotRepaired implements Exception {
  const _PredecessorNotRepaired();
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
