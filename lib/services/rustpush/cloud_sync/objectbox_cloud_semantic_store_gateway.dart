import 'dart:collection';
import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';

/// Positive acknowledgement from a synchronous canonical ObjectBox mutation.
///
/// Returning a concrete enum instead of `void` prevents an async callback from
/// satisfying this contract accidentally.
enum CloudCanonicalSemanticMutationReceipt { committed }

/// Synchronous bridge to the app's canonical Message/Chat/Attachment boxes.
///
/// Implementations must mutate only boxes from [store]. Network, filesystem,
/// hashing, platform-keystore, isolate, and async work are forbidden. Because
/// the exact same Store instance is required, the canonical mutation joins the
/// gateway's ObjectBox write transaction and rolls back with its metadata.
abstract interface class CloudCanonicalSemanticEntityAdapter {
  Store get store;

  /// Revalidates the currently authenticated account immediately before any
  /// canonical mutation. Implementations must not perform async or I/O work.
  bool isActiveAccountScope({
    required CloudSyncScope scope,
    required int generation,
  });

  bool entityExists({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  });

  CloudCanonicalSemanticMutationReceipt applyEntity({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  });

  CloudCanonicalSemanticMutationReceipt applyTombstone({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticTombstone tombstone,
  });
}

enum _SemanticReplayOutcome { applied, appliedWithConflict, quarantined }

enum _SemanticTransactionPhase { open, appliedTerminal, quarantinedTerminal }

/// Durable ObjectBox implementation of [CloudSemanticStoreGateway].
///
/// This gateway remains default-off outside the separately compile-gated
/// manual semantic pull canary. When enabled, it fences the active account,
/// coordinator lease, checkpoint, and exact inbox row inside the same
/// ObjectBox write transaction as canonical state, snapshot metadata, record
/// mapping, replay outcome, and inbox terminal status.
final class ObjectBoxCloudSemanticStoreGateway
    implements CloudSemanticStoreGateway {
  ObjectBoxCloudSemanticStoreGateway({
    required Store store,
    required CloudCanonicalSemanticEntityAdapter canonicalAdapter,
    DateTime Function()? clock,
    this._allowTombstones = false,
  }) : _store = store,
       _canonicalAdapter = canonicalAdapter,
       _clock = clock ?? DateTime.now,
       _checkpoints = store.box<CloudSyncCheckpointEntity>(),
       _inbox = store.box<CloudInboxChangeEntity>(),
       _leases = store.box<CloudSyncLeaseEntity>(),
       _recordMaps = store.box<CloudRecordMapEntity>(),
       _snapshots = store.box<CloudSemanticSnapshotEntity>(),
       _replay = store.box<CloudSemanticReplayEntity>() {
    if (!identical(canonicalAdapter.store, store)) {
      throw ArgumentError('canonical_adapter_store_mismatch');
    }
  }

  factory ObjectBoxCloudSemanticStoreGateway.fromDatabase({
    required CloudCanonicalSemanticEntityAdapter canonicalAdapter,
    DateTime Function()? clock,
    bool allowTombstones = false,
  }) {
    return ObjectBoxCloudSemanticStoreGateway(
      store: Database.store,
      canonicalAdapter: canonicalAdapter,
      clock: clock,
      allowTombstones: allowTombstones,
    );
  }

  static const int _maximumEditParts = 1024;
  static const int _maximumEditPartsBytes = 256 * 1024;
  static const int _nullDateSentinel = -9223372036854775808;
  static final RegExp _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');
  static final RegExp _base64UrlDigestPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _lowerHexDigestPattern = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _protectedReferencePattern = RegExp(
    r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
  );
  static final HashSet<Store> _activeStores = HashSet<Store>.identity();

  final Store _store;
  final CloudCanonicalSemanticEntityAdapter _canonicalAdapter;
  final DateTime Function() _clock;
  final bool _allowTombstones;
  final Box<CloudSyncCheckpointEntity> _checkpoints;
  final Box<CloudInboxChangeEntity> _inbox;
  final Box<CloudSyncLeaseEntity> _leases;
  final Box<CloudRecordMapEntity> _recordMaps;
  final Box<CloudSemanticSnapshotEntity> _snapshots;
  final Box<CloudSemanticReplayEntity> _replay;

  @override
  Future<T> writeTransaction<T>({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
    required T Function(CloudSemanticStoreTransaction transaction) action,
  }) {
    _validateEntryContext(entry, leaseFence);
    if (!_activeStores.add(_store)) {
      throw _failure('semantic_nested_transaction_forbidden');
    }

    try {
      final context = _SemanticTransactionContext.prepare(
        entry: entry,
        leaseFence: leaseFence,
      );
      final result = _store.runInTransaction(TxMode.write, () {
        // Sample time only after ObjectBox grants the write transaction. A
        // process can wait behind another writer long enough for its lease to
        // expire, so a pre-lock timestamp is not a truthful fencing check.
        final updatedAtMs = _clock().toUtc().millisecondsSinceEpoch;
        final durable = _validateDurableFenceLocked(
          context: context,
          nowMs: updatedAtMs,
        );
        final transaction = _ObjectBoxCloudSemanticStoreTransaction(
          context: context,
          updatedAtMs: updatedAtMs,
          inboxEntity: durable.inbox,
          checkpointEntity: durable.checkpoint,
          checkpoints: _checkpoints,
          inbox: _inbox,
          recordMaps: _recordMaps,
          snapshots: _snapshots,
          replay: _replay,
          canonicalAdapter: _canonicalAdapter,
          allowTombstones: _allowTombstones,
        );
        try {
          final value = action(transaction);
          if (value is Future) {
            throw _failure('semantic_async_transaction_forbidden');
          }
          transaction.validateCompletion();
          return value;
        } finally {
          transaction.invalidate();
        }
      });
      return Future<T>.value(result);
    } on CloudSyncFailure catch (failure) {
      return Future<T>.error(failure);
    } catch (_) {
      return Future<T>.error(_failure('semantic_canonical_write_failed'));
    } finally {
      _activeStores.remove(_store);
    }
  }

  _DurableSemanticFence _validateDurableFenceLocked({
    required _SemanticTransactionContext context,
    required int nowMs,
  }) {
    final leaseQuery =
        _leases
            .query(CloudSyncLeaseEntity_.leaseKey.equals(context.leaseKey))
            .build()
          ..limit = 1;
    final CloudSyncLeaseEntity? lease;
    try {
      lease = leaseQuery.findFirst();
    } finally {
      leaseQuery.close();
    }
    if (lease == null ||
        lease.scopeKey != context.scopeKey ||
        lease.accountFingerprint != context.entry.scope.accountFingerprint ||
        lease.ownerIdHash != context.ownerIdHash ||
        lease.generation != context.leaseFence.generation ||
        lease.expiresAtMs <= nowMs) {
      throw _failure('semantic_coordinator_lease_fence_lost');
    }

    final checkpointQuery =
        _checkpoints
            .query(
              CloudSyncCheckpointEntity_.checkpointKey.equals(context.scopeKey),
            )
            .build()
          ..limit = 1;
    final CloudSyncCheckpointEntity? checkpoint;
    try {
      checkpoint = checkpointQuery.findFirst();
    } finally {
      checkpointQuery.close();
    }
    if (checkpoint == null ||
        checkpoint.checkpointKey != context.scopeKey ||
        checkpoint.accountFingerprint !=
            context.entry.scope.accountFingerprint ||
        checkpoint.container != context.entry.scope.container ||
        checkpoint.database != context.entry.scope.database ||
        checkpoint.zone != context.entry.scope.zone ||
        checkpoint.streamKind != context.entry.scope.streamKind.name ||
        checkpoint.schemaVersion != context.entry.scope.schemaVersion ||
        checkpoint.generation != context.entry.generation ||
        checkpoint.appliedSequence < 0 ||
        checkpoint.appliedSequence > checkpoint.fetchedSequence ||
        checkpoint.fetchedSequence < context.entry.sequence) {
      throw _failure('semantic_checkpoint_fence_lost');
    }

    final inboxQuery =
        _inbox
            .query(CloudInboxChangeEntity_.changeKey.equals(context.changeKey))
            .build()
          ..limit = 1;
    final CloudInboxChangeEntity? inbox;
    try {
      inbox = inboxQuery.findFirst();
    } finally {
      inboxQuery.close();
    }
    final change = context.entry.change;
    if (inbox == null ||
        inbox.changeKey != context.changeKey ||
        inbox.changeIdHash != change.changeId ||
        inbox.scopeKey != context.scopeKey ||
        inbox.accountFingerprint != context.entry.scope.accountFingerprint ||
        inbox.zone != context.entry.scope.zone ||
        inbox.serverRecordIdHash != change.recordIdHash ||
        inbox.etagHash != change.etagHash ||
        inbox.changeType != change.type.name ||
        inbox.encryptedServerRecordId != change.encryptedServerRecordId ||
        inbox.protectedSystemFieldsRef !=
            change.protectedSystemFieldsReference ||
        inbox.encryptedPayloadRef != change.encryptedPayloadReference ||
        inbox.payloadSha256 != change.payloadSha256 ||
        inbox.batchId != context.entry.batchId ||
        inbox.generation != context.entry.generation ||
        inbox.fetchSequence != context.entry.sequence ||
        inbox.status != CloudInboxStatus.pending.index ||
        inbox.isTombstone != change.isTombstone) {
      throw _failure('semantic_inbox_fence_lost');
    }

    if (!_canonicalAdapter.isActiveAccountScope(
      scope: context.entry.scope,
      generation: context.entry.generation,
    )) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'semantic_active_account_scope_changed',
      );
    }
    return _DurableSemanticFence(checkpoint: checkpoint, inbox: inbox);
  }

  static void _validateEntryContext(
    CloudInboxEntry entry,
    CloudCoordinatorLeaseFence leaseFence,
  ) {
    _validateExternalDigest(entry.scope.accountFingerprint);
    _validateExternalDigest(entry.change.changeId);
    _validateExternalDigest(entry.change.recordIdHash);
    _validateOptionalExternalDigest(entry.change.etagHash);
    _validateOptionalContentDigest(entry.change.payloadSha256);
    _validateProtectedReference(entry.change.encryptedServerRecordId);
    _validateProtectedReference(entry.change.protectedSystemFieldsReference);
    _validateProtectedReference(entry.change.encryptedPayloadReference);
    if (entry.change.encryptedServerRecordId == null ||
        entry.change.encryptedPayloadReference == null) {
      throw _malformed('semantic_protected_reference_missing');
    }
    if (entry.sequence <= 0 ||
        entry.generation <= 0 ||
        entry.status != CloudInboxStatus.pending ||
        entry.batchId.isEmpty ||
        entry.batchId.length > 256 ||
        leaseFence.ownerId.isEmpty ||
        leaseFence.ownerId.length > 256 ||
        leaseFence.generation <= 0) {
      throw _failure('semantic_transaction_context_invalid');
    }
  }

  static void _validateProtectedReference(String? value) {
    if (value == null) return;
    if (!_protectedReferencePattern.hasMatch(value)) {
      throw _malformed('semantic_protected_reference_invalid');
    }
  }

  static void _validateOptionalExternalDigest(String? value) {
    if (value != null) _validateExternalDigest(value);
  }

  static void _validateOptionalContentDigest(String? value) {
    if (value != null) _validateContentDigest(value);
  }

  static void _validateExternalDigest(String value) {
    if (!_base64UrlDigestPattern.hasMatch(value)) {
      throw _malformed('semantic_digest_invalid');
    }
  }

  static void _validateContentDigest(String value) {
    if (!_base64UrlDigestPattern.hasMatch(value) &&
        !_lowerHexDigestPattern.hasMatch(value)) {
      throw _malformed('semantic_digest_invalid');
    }
  }

  static CloudSyncFailure _failure(String safeCode) => CloudSyncFailure(
    category: CloudFailureCategory.localStorage,
    safeCode: safeCode,
  );

  static CloudSyncFailure _malformed(String safeCode) => CloudSyncFailure(
    category: CloudFailureCategory.malformedRecord,
    safeCode: safeCode,
  );
}

final class _DurableSemanticFence {
  const _DurableSemanticFence({required this.checkpoint, required this.inbox});

  final CloudSyncCheckpointEntity checkpoint;
  final CloudInboxChangeEntity inbox;
}

final class _SemanticTransactionContext {
  const _SemanticTransactionContext({
    required this.entry,
    required this.leaseFence,
    required this.scopeKey,
    required this.scopeGenerationKey,
    required this.changeKey,
    required this.changeIdHash,
    required this.leaseKey,
    required this.ownerIdHash,
    required this.payloadReferenceHash,
    required this.replayKey,
  });

  factory _SemanticTransactionContext.prepare({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
  }) {
    final scopeKey = 'scope2:${_digest(entry.scope.storageKey)}';
    final scopeGenerationKey =
        'semantic-generation4:${_digest('$scopeKey\u001f${entry.generation}')}';
    final changeIdHash = _digest(entry.change.changeId);
    final payloadReferenceHash = entry.change.encryptedPayloadReference == null
        ? null
        : _digest(
            'semantic-payload-reference\u001f'
            '${entry.change.encryptedPayloadReference}',
          );
    return _SemanticTransactionContext(
      entry: entry,
      leaseFence: leaseFence,
      scopeKey: scopeKey,
      scopeGenerationKey: scopeGenerationKey,
      changeKey: _scopedDigest(entry.scope, 'change', entry.change.changeId),
      changeIdHash: changeIdHash,
      leaseKey: _scopedDigest(entry.scope, 'coordinator-lease', 'v1'),
      ownerIdHash: _digest('coordinator-owner\u001f${leaseFence.ownerId}'),
      payloadReferenceHash: payloadReferenceHash,
      replayKey: 'semantic-replay4:$scopeGenerationKey:$changeIdHash',
    );
  }

  final CloudInboxEntry entry;
  final CloudCoordinatorLeaseFence leaseFence;
  final String scopeKey;
  final String scopeGenerationKey;
  final String changeKey;
  final String changeIdHash;
  final String leaseKey;
  final String ownerIdHash;
  final String? payloadReferenceHash;
  final String replayKey;

  String snapshotKey(CloudEntityKind kind, String logicalEntityKeyHash) =>
      'semantic-snapshot4:$scopeGenerationKey:${kind.name}:'
      '$logicalEntityKeyHash';

  String recordMapKey(String logicalEntityKeyHash) =>
      _scopedDigest(entry.scope, 'record-map', logicalEntityKeyHash);

  static String _scopedDigest(
    CloudSyncScope scope,
    String purpose,
    String value,
  ) => '$purpose:${_digest('${scope.storageKey}\u001f$purpose\u001f$value')}';

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}

final class _ObjectBoxCloudSemanticStoreTransaction
    implements CloudSemanticStoreTransaction {
  _ObjectBoxCloudSemanticStoreTransaction({
    required this._context,
    required this._updatedAtMs,
    required this._inboxEntity,
    required this._checkpointEntity,
    required this._checkpoints,
    required this._inbox,
    required this._recordMaps,
    required this._snapshots,
    required this._replay,
    required this._canonicalAdapter,
    required this._allowTombstones,
  });

  final _SemanticTransactionContext _context;
  final int _updatedAtMs;
  final CloudInboxChangeEntity _inboxEntity;
  final CloudSyncCheckpointEntity _checkpointEntity;
  final Box<CloudSyncCheckpointEntity> _checkpoints;
  final Box<CloudInboxChangeEntity> _inbox;
  final Box<CloudRecordMapEntity> _recordMaps;
  final Box<CloudSemanticSnapshotEntity> _snapshots;
  final Box<CloudSemanticReplayEntity> _replay;
  final CloudCanonicalSemanticEntityAdapter _canonicalAdapter;
  final bool _allowTombstones;

  bool _active = true;
  bool _canonicalMutationPerformed = false;
  bool _recordMapWritten = false;
  _SemanticTransactionPhase _phase = _SemanticTransactionPhase.open;
  String? _boundLogicalEntityKeyHash;
  String? _pendingConflictSafeCode;

  @override
  CloudSyncScope get activeScope {
    _ensureActive();
    return _context.entry.scope;
  }

  @override
  int get activeGeneration {
    _ensureActive();
    return _context.entry.generation;
  }

  @override
  bool hasAppliedChange(String changeId) {
    _ensureActive();
    _requireActiveChange(changeId);
    final entity = _findReplay();
    if (entity == null) return false;
    _validateReplayScope(entity);
    final outcome = _replayOutcome(entity.terminalOutcome);
    return outcome == _SemanticReplayOutcome.applied ||
        outcome == _SemanticReplayOutcome.appliedWithConflict;
  }

  @override
  CloudSemanticSnapshot? readSnapshot({
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    _ensureActive();
    _validateEntityKindForStream(kind);
    _validateHashedValue(logicalEntityKeyHash);
    final entity = _findSnapshot(
      _context.snapshotKey(kind, logicalEntityKeyHash),
    );
    if (entity == null) return null;
    _validateSnapshotScope(
      entity,
      expectedKind: kind,
      expectedLogicalKeyHash: logicalEntityKeyHash,
    );
    return _snapshotFromEntity(entity);
  }

  @override
  bool entityExists({
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    _ensureActive();
    _validateHashedValue(logicalEntityKeyHash);
    if (_context.entry.scope.streamKind != CloudSyncStreamKind.messages ||
        (kind != CloudEntityKind.chat && kind != CloudEntityKind.message)) {
      throw ObjectBoxCloudSemanticStoreGateway._malformed(
        'semantic_parent_kind_invalid',
      );
    }
    return _canonicalAdapter.entityExists(
      scope: _context.entry.scope,
      generation: _context.entry.generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
    );
  }

  @override
  void bindRecordIdentity({
    required String logicalEntityKeyHash,
    String? encryptedRawRecordReference,
  }) {
    _ensureActive();
    _ensureOpen();
    _validateHashedValue(logicalEntityKeyHash);
    ObjectBoxCloudSemanticStoreGateway._validateProtectedReference(
      encryptedRawRecordReference,
    );
    final expectedRawReference =
        _context.entry.change.encryptedPayloadReference!;
    if (encryptedRawRecordReference != expectedRawReference) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'semantic_raw_record_reference_mismatch',
      );
    }
    if (_boundLogicalEntityKeyHash != null &&
        _boundLogicalEntityKeyHash != logicalEntityKeyHash) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_record_binding_changed',
      );
    }

    final mapKey = _context.recordMapKey(logicalEntityKeyHash);
    final existing = _findRecordMapByKey(mapKey);
    if (existing != null) {
      _validateRecordMapScope(existing, logicalEntityKeyHash);
      if (existing.serverRecordIdHash != _context.entry.change.recordIdHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'semantic_record_mapping_conflict',
        );
      }
    }

    final collisions = _findRecordMapsByServerHash(
      _context.entry.change.recordIdHash,
    );
    for (final collision in collisions) {
      if (collision.mapKey != mapKey ||
          collision.logicalEntityKeyHash != logicalEntityKeyHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'semantic_record_mapping_conflict',
        );
      }
    }

    final encryptedServerRecordId =
        _context.entry.change.encryptedServerRecordId!;
    _recordMaps.put(
      CloudRecordMapEntity(
        id: existing?.id ?? 0,
        mapKey: mapKey,
        scopeKey: _context.scopeKey,
        accountFingerprint: _context.entry.scope.accountFingerprint,
        zone: _context.entry.scope.zone,
        logicalEntityKeyHash: logicalEntityKeyHash,
        serverRecordIdHash: _context.entry.change.recordIdHash,
        encryptedServerRecordId: encryptedServerRecordId,
        etagHash: _context.entry.change.etagHash,
        encryptedRawRecordRef: expectedRawReference,
        updatedAtMs: _updatedAtMs,
      ),
    );
    _recordMapWritten = true;
    _boundLogicalEntityKeyHash = logicalEntityKeyHash;
  }

  @override
  void applyEntity({
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    _ensureActive();
    _ensureOpen();
    if (_canonicalMutationPerformed) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_multiple_canonical_mutations_forbidden',
      );
    }
    if (payload.kind != snapshot.kind ||
        payload.logicalEntityKeyHash != snapshot.logicalEntityKeyHash) {
      throw ObjectBoxCloudSemanticStoreGateway._malformed(
        'semantic_payload_snapshot_mismatch',
      );
    }
    _validateEntityKindForStream(snapshot.kind);
    _validatePayloadParent(payload, snapshot);
    _validateSnapshot(snapshot);
    bindRecordIdentity(
      logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
      encryptedRawRecordReference: snapshot.encryptedRawRecordReference,
    );
    final receipt = _canonicalAdapter.applyEntity(
      scope: _context.entry.scope,
      generation: _context.entry.generation,
      payload: payload,
      snapshot: snapshot,
    );
    if (receipt != CloudCanonicalSemanticMutationReceipt.committed) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_canonical_apply_uncommitted',
      );
    }
    _canonicalMutationPerformed = true;

    final key = _context.snapshotKey(
      snapshot.kind,
      snapshot.logicalEntityKeyHash,
    );
    final existing = _findSnapshot(key);
    if (existing != null) {
      _validateSnapshotScope(
        existing,
        expectedKind: snapshot.kind,
        expectedLogicalKeyHash: snapshot.logicalEntityKeyHash,
      );
    }
    _snapshots.put(
      _snapshotEntity(
        snapshot,
        snapshotKey: key,
        existingId: existing?.id ?? 0,
      ),
    );
  }

  @override
  void applyTombstone(CloudSemanticTombstone tombstone) {
    _ensureActive();
    _ensureOpen();
    if (_canonicalMutationPerformed) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_multiple_canonical_mutations_forbidden',
      );
    }
    if (!_allowTombstones) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'semantic_tombstones_disabled',
      );
    }
    if (!tombstone.serverConfirmed || tombstone.deletedAt == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'semantic_tombstone_order_unproven',
      );
    }
    _validateEntityKindForStream(tombstone.kind);
    _validateHashedValue(tombstone.logicalEntityKeyHash);
    bindRecordIdentity(
      logicalEntityKeyHash: tombstone.logicalEntityKeyHash,
      encryptedRawRecordReference:
          _context.entry.change.encryptedPayloadReference,
    );
    final receipt = _canonicalAdapter.applyTombstone(
      scope: _context.entry.scope,
      generation: _context.entry.generation,
      tombstone: tombstone,
    );
    if (receipt != CloudCanonicalSemanticMutationReceipt.committed) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_canonical_tombstone_uncommitted',
      );
    }
    _canonicalMutationPerformed = true;
    final existing = _findSnapshot(
      _context.snapshotKey(tombstone.kind, tombstone.logicalEntityKeyHash),
    );
    if (existing != null) {
      _validateSnapshotScope(
        existing,
        expectedKind: tombstone.kind,
        expectedLogicalKeyHash: tombstone.logicalEntityKeyHash,
      );
      _snapshots.remove(existing.id);
    }
  }

  @override
  void markChangeApplied(String changeId) {
    _ensureActive();
    _ensureOpen();
    _requireActiveChange(changeId);
    final existing = _findReplay();
    if (existing != null) {
      _validateReplayScope(existing);
      final existingOutcome = _replayOutcome(existing.terminalOutcome);
      if (existingOutcome == _SemanticReplayOutcome.quarantined) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'semantic_replay_terminal_conflict',
        );
      }
      _writeInboxTerminal(existingOutcome);
      _phase = _SemanticTransactionPhase.appliedTerminal;
      return;
    }
    final logicalEntityKeyHash = _boundLogicalEntityKeyHash;
    if (logicalEntityKeyHash == null) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_record_binding_missing',
      );
    }
    final outcome = _pendingConflictSafeCode == null
        ? _SemanticReplayOutcome.applied
        : _SemanticReplayOutcome.appliedWithConflict;
    _replay.put(
      _newReplayEntity(
        outcome: outcome,
        terminalSafeCode: _pendingConflictSafeCode,
        logicalEntityKeyHash: logicalEntityKeyHash,
      ),
    );
    _writeInboxTerminal(outcome);
    _phase = _SemanticTransactionPhase.appliedTerminal;
  }

  @override
  void quarantineChange(String changeId, String safeCode) {
    _ensureActive();
    _ensureOpen();
    _requireActiveChange(changeId);
    _validateSafeCode(safeCode);
    if (_canonicalMutationPerformed || _recordMapWritten) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'semantic_quarantine_after_mutation_forbidden',
      );
    }
    final existing = _findReplay();
    if (existing != null) {
      _validateReplayScope(existing);
      if (_replayOutcome(existing.terminalOutcome) !=
              _SemanticReplayOutcome.quarantined ||
          existing.terminalSafeCode != safeCode) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'semantic_replay_terminal_conflict',
        );
      }
    } else {
      _replay.put(
        _newReplayEntity(
          outcome: _SemanticReplayOutcome.quarantined,
          terminalSafeCode: safeCode,
          logicalEntityKeyHash: _boundLogicalEntityKeyHash,
        ),
      );
    }
    _writeInboxTerminal(_SemanticReplayOutcome.quarantined);
    _phase = _SemanticTransactionPhase.quarantinedTerminal;
  }

  @override
  void recordConflict(String changeId, String safeCode) {
    _ensureActive();
    _ensureOpen();
    _requireActiveChange(changeId);
    _validateSafeCode(safeCode);
    if (_pendingConflictSafeCode != null &&
        _pendingConflictSafeCode != safeCode) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'semantic_replay_terminal_conflict',
      );
    }
    _pendingConflictSafeCode = safeCode;
  }

  void validateCompletion() {
    _ensureActive();
    if ((_canonicalMutationPerformed || _recordMapWritten) &&
        _phase == _SemanticTransactionPhase.open) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_terminal_outcome_missing',
      );
    }
    if (_phase != _SemanticTransactionPhase.open &&
        _inboxEntity.status == CloudInboxStatus.pending.index) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_inbox_terminal_missing',
      );
    }
  }

  void invalidate() {
    _active = false;
  }

  void _ensureActive() {
    if (!_active) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_transaction_inactive',
      );
    }
  }

  void _ensureOpen() {
    if (_phase != _SemanticTransactionPhase.open) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_transaction_terminal',
      );
    }
  }

  void _writeInboxTerminal(_SemanticReplayOutcome outcome) {
    final alreadyApplied =
        _inboxEntity.status == CloudInboxStatus.applied.index;
    final alreadyQuarantined =
        _inboxEntity.status == CloudInboxStatus.quarantined.index;
    if (outcome == _SemanticReplayOutcome.quarantined) {
      if (alreadyApplied) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'semantic_inbox_terminal_conflict',
        );
      }
      _inboxEntity
        ..status = CloudInboxStatus.quarantined.index
        ..retryCount += alreadyQuarantined ? 0 : 1
        ..failureCategory = CloudFailureCategory.conflict.name
        ..nextEligibleAtMs = 0
        ..completedAtMs = _updatedAtMs
        ..updatedAtMs = _updatedAtMs;
      _inbox.put(_inboxEntity);
      _advanceContiguousApplied();
      return;
    }
    if (alreadyQuarantined) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'semantic_inbox_terminal_conflict',
      );
    }
    _inboxEntity
      ..status = CloudInboxStatus.applied.index
      ..failureCategory = null
      ..nextEligibleAtMs = 0
      ..completedAtMs = _updatedAtMs
      ..updatedAtMs = _updatedAtMs;
    _inbox.put(_inboxEntity);
    _advanceContiguousApplied();
  }

  void _advanceContiguousApplied() {
    var next = _checkpointEntity.appliedSequence + 1;
    while (next <= _checkpointEntity.fetchedSequence) {
      final query =
          _inbox
              .query(
                CloudInboxChangeEntity_.scopeKey
                    .equals(_context.scopeKey)
                    .and(CloudInboxChangeEntity_.fetchSequence.equals(next)),
              )
              .build()
            ..limit = 2;
      final List<CloudInboxChangeEntity> rows;
      try {
        rows = query.find();
      } finally {
        query.close();
      }
      if (rows.length > 1) {
        throw ObjectBoxCloudSemanticStoreGateway._failure(
          'semantic_inbox_sequence_ambiguous',
        );
      }
      if (rows.isEmpty) break;
      final row = rows.single;
      if (row.scopeKey != _context.scopeKey ||
          row.accountFingerprint != _context.entry.scope.accountFingerprint ||
          row.generation != _context.entry.generation ||
          row.fetchSequence != next) {
        throw ObjectBoxCloudSemanticStoreGateway._failure(
          'semantic_inbox_sequence_scope_mismatch',
        );
      }
      if (row.status != CloudInboxStatus.applied.index &&
          row.status != CloudInboxStatus.quarantined.index) {
        break;
      }
      next++;
    }
    final appliedThrough = next - 1;
    if (appliedThrough > _checkpointEntity.fetchedSequence) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_checkpoint_advance_invalid',
      );
    }
    if (appliedThrough != _checkpointEntity.appliedSequence) {
      _checkpointEntity
        ..appliedSequence = appliedThrough
        ..updatedAtMs = _updatedAtMs;
      _checkpoints.put(_checkpointEntity);
    }
    _promotePendingFetchedTokenIfTerminal();
  }

  void _promotePendingFetchedTokenIfTerminal() {
    final pendingBatchId = _checkpointEntity.pendingBatchId;
    if (pendingBatchId == null) return;

    final batchQuery =
        _inbox
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(_context.scopeKey)
                  .and(
                    CloudInboxChangeEntity_.generation.equals(
                      _context.entry.generation,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.batchId.equals(pendingBatchId)),
            )
            .build()
          ..limit = 1;
    try {
      if (batchQuery.findFirst() == null) return;
    } finally {
      batchQuery.close();
    }

    final nonterminalQuery =
        _inbox
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(_context.scopeKey)
                  .and(
                    CloudInboxChangeEntity_.generation.equals(
                      _context.entry.generation,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.batchId.equals(pendingBatchId))
                  .and(
                    CloudInboxChangeEntity_.status.notEquals(
                      CloudInboxStatus.applied.index,
                    ),
                  )
                  .and(
                    CloudInboxChangeEntity_.status.notEquals(
                      CloudInboxStatus.quarantined.index,
                    ),
                  ),
            )
            .build()
          ..limit = 1;
    try {
      if (nonterminalQuery.findFirst() != null) return;
    } finally {
      nonterminalQuery.close();
    }

    _checkpointEntity
      ..fetchedTokenCiphertext = _checkpointEntity.pendingFetchedTokenCiphertext
      ..pendingFetchedTokenCiphertext = null
      ..pendingBatchId = null
      ..updatedAtMs = _updatedAtMs;
    _checkpoints.put(_checkpointEntity);
  }

  CloudSemanticReplayEntity _newReplayEntity({
    required _SemanticReplayOutcome outcome,
    required String? terminalSafeCode,
    required String? logicalEntityKeyHash,
  }) {
    final scope = _context.entry.scope;
    return CloudSemanticReplayEntity(
      replayKey: _context.replayKey,
      scopeGenerationKey: _context.scopeGenerationKey,
      scopeKey: _context.scopeKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: _context.entry.generation,
      changeIdHash: _context.changeIdHash,
      serverRecordIdHash: _context.entry.change.recordIdHash,
      logicalEntityKeyHash: logicalEntityKeyHash,
      payloadSha256: _context.entry.change.payloadSha256,
      protectedPayloadReferenceHash: _context.payloadReferenceHash,
      inboxSequence: _context.entry.sequence,
      changeType: _context.entry.change.type.name,
      terminalOutcome: outcome.name,
      terminalSafeCode: terminalSafeCode,
      updatedAtMs: _updatedAtMs,
    );
  }

  CloudSemanticSnapshotEntity _snapshotEntity(
    CloudSemanticSnapshot snapshot, {
    required String snapshotKey,
    required int existingId,
  }) {
    final scope = _context.entry.scope;
    return CloudSemanticSnapshotEntity(
      id: existingId,
      snapshotKey: snapshotKey,
      scopeGenerationKey: _context.scopeGenerationKey,
      scopeKey: _context.scopeKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: _context.entry.generation,
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
      updatedAtMs: _updatedAtMs,
    );
  }

  CloudSemanticSnapshot _snapshotFromEntity(
    CloudSemanticSnapshotEntity entity,
  ) {
    final recordMap = _findRecordMapByKey(
      _context.recordMapKey(entity.logicalEntityKeyHash),
    );
    if (recordMap != null) {
      _validateRecordMapScope(recordMap, entity.logicalEntityKeyHash);
    }
    return CloudSemanticSnapshot(
      kind: _entityKind(entity.entityKind),
      logicalEntityKeyHash: entity.logicalEntityKeyHash,
      parentLogicalKeyHash: entity.parentLogicalKeyHash,
      immutableContentDigest: entity.immutableContentDigest,
      createdAt: _dateOrNull(entity.createdAtMs),
      readAt: _dateOrNull(entity.readAtMs),
      deliveredAt: _dateOrNull(entity.deliveredAtMs),
      editParts: _decodeEditParts(entity.editPartsJson),
      retractedAt: _dateOrNull(entity.retractedAtMs),
      groupVersion: entity.groupVersion,
      groupMetadataDigest: entity.groupMetadataDigest,
      etagHash: entity.etagHash,
      encryptedRawRecordReference: recordMap?.encryptedRawRecordRef,
    );
  }

  CloudSemanticSnapshotEntity? _findSnapshot(String snapshotKey) {
    final query =
        _snapshots
            .query(CloudSemanticSnapshotEntity_.snapshotKey.equals(snapshotKey))
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudSemanticReplayEntity? _findReplay() {
    final query =
        _replay
            .query(
              CloudSemanticReplayEntity_.replayKey.equals(_context.replayKey),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudRecordMapEntity? _findRecordMapByKey(String mapKey) {
    final query =
        _recordMaps.query(CloudRecordMapEntity_.mapKey.equals(mapKey)).build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  List<CloudRecordMapEntity> _findRecordMapsByServerHash(
    String serverRecordIdHash,
  ) {
    final query = _recordMaps
        .query(
          CloudRecordMapEntity_.scopeKey
              .equals(_context.scopeKey)
              .and(
                CloudRecordMapEntity_.serverRecordIdHash.equals(
                  serverRecordIdHash,
                ),
              ),
        )
        .build();
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  void _validateRecordMapScope(
    CloudRecordMapEntity entity,
    String logicalEntityKeyHash,
  ) {
    final scope = _context.entry.scope;
    ObjectBoxCloudSemanticStoreGateway._validateExternalDigest(
      entity.serverRecordIdHash,
    );
    ObjectBoxCloudSemanticStoreGateway._validateProtectedReference(
      entity.encryptedServerRecordId,
    );
    ObjectBoxCloudSemanticStoreGateway._validateOptionalExternalDigest(
      entity.etagHash,
    );
    ObjectBoxCloudSemanticStoreGateway._validateProtectedReference(
      entity.encryptedRawRecordRef,
    );
    if (entity.mapKey != _context.recordMapKey(logicalEntityKeyHash) ||
        entity.scopeKey != _context.scopeKey ||
        entity.accountFingerprint != scope.accountFingerprint ||
        entity.zone != scope.zone ||
        entity.logicalEntityKeyHash != logicalEntityKeyHash) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_record_map_scope_mismatch',
      );
    }
  }

  void _validateSnapshot(CloudSemanticSnapshot snapshot) {
    _validateHashedValue(snapshot.logicalEntityKeyHash);
    _validateOptionalHashedValue(snapshot.parentLogicalKeyHash);
    _validateOptionalContentDigest(snapshot.immutableContentDigest);
    _validateOptionalContentDigest(snapshot.groupMetadataDigest);
    ObjectBoxCloudSemanticStoreGateway._validateOptionalExternalDigest(
      snapshot.etagHash,
    );
    ObjectBoxCloudSemanticStoreGateway._validateProtectedReference(
      snapshot.encryptedRawRecordReference,
    );
    if (snapshot.encryptedRawRecordReference !=
            _context.entry.change.encryptedPayloadReference ||
        snapshot.etagHash != _context.entry.change.etagHash) {
      throw ObjectBoxCloudSemanticStoreGateway._malformed(
        'semantic_snapshot_envelope_mismatch',
      );
    }
    if (snapshot.editParts.length >
        ObjectBoxCloudSemanticStoreGateway._maximumEditParts) {
      throw ObjectBoxCloudSemanticStoreGateway._malformed(
        'semantic_edit_parts_oversized',
      );
    }
    for (final entry in snapshot.editParts.entries) {
      _validateHashedValue(entry.key);
      _validateHashedValue(entry.value.partKeyHash);
      _validateContentDigest(entry.value.contentDigest);
      if (entry.key != entry.value.partKeyHash || entry.value.revision < 0) {
        throw ObjectBoxCloudSemanticStoreGateway._malformed(
          'semantic_edit_part_invalid',
        );
      }
    }
  }

  void _validatePayloadParent(
    CloudSemanticEntityPayload payload,
    CloudSemanticSnapshot snapshot,
  ) {
    final expectedParent = switch (payload) {
      CloudMessageEntityPayload value => value.replyParentLogicalKeyHash,
      CloudAttachmentEntityPayload value => value.ownerLogicalKeyHash,
      CloudReactionEntityPayload value => value.parentLogicalKeyHash,
      CloudGroupPhotoEntityPayload value => value.ownerLogicalKeyHash,
      _ => null,
    };
    if (expectedParent != null &&
        snapshot.parentLogicalKeyHash != expectedParent) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'semantic_parent_identity_mismatch',
      );
    }
    if (expectedParent == null && snapshot.parentLogicalKeyHash != null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'semantic_parent_identity_invalid',
      );
    }
    final (CloudEntityKind, String)? requiredParent = switch (payload) {
      CloudMessageEntityPayload value
          when value.replyParentLogicalKeyHash != null =>
        (CloudEntityKind.message, value.replyParentLogicalKeyHash!),
      CloudMessageEntityPayload _ => null,
      CloudAttachmentEntityPayload value
          when value.ownerLogicalKeyHash != null =>
        (CloudEntityKind.message, value.ownerLogicalKeyHash!),
      CloudAttachmentEntityPayload _ => null,
      CloudReactionEntityPayload value => (
        CloudEntityKind.message,
        value.parentLogicalKeyHash,
      ),
      CloudGroupPhotoEntityPayload value => (
        CloudEntityKind.chat,
        value.ownerLogicalKeyHash,
      ),
      _ => null,
    };
    if (requiredParent != null) {
      _validateHashedValue(requiredParent.$2);
      if (!_canonicalAdapter.entityExists(
        scope: _context.entry.scope,
        generation: _context.entry.generation,
        kind: requiredParent.$1,
        logicalEntityKeyHash: requiredParent.$2,
      )) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'semantic_parent_missing',
        );
      }
    }
    if (payload case CloudMessageEntityPayload value) {
      _validateHashedValue(value.chatAliasKeyHash);
    }
  }

  void _validateEntityKindForStream(CloudEntityKind kind) {
    final scope = _context.entry.scope;
    final allowed = switch (scope.streamKind) {
      CloudSyncStreamKind.messages => switch (scope.zone) {
        'chatManateeZone' =>
          kind == CloudEntityKind.chat || kind == CloudEntityKind.groupPhoto,
        'messageManateeZone' =>
          kind == CloudEntityKind.message || kind == CloudEntityKind.reaction,
        'attachmentManateeZone' => kind == CloudEntityKind.attachment,
        _ => false,
      },
      CloudSyncStreamKind.profiles => kind == CloudEntityKind.sharedProfile,
    };
    if (!allowed) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'semantic_stream_entity_mismatch',
      );
    }
  }

  void _validateSnapshotScope(
    CloudSemanticSnapshotEntity entity, {
    required CloudEntityKind expectedKind,
    required String expectedLogicalKeyHash,
  }) {
    final scope = _context.entry.scope;
    if (entity.scopeGenerationKey != _context.scopeGenerationKey ||
        entity.scopeKey != _context.scopeKey ||
        entity.accountFingerprint != scope.accountFingerprint ||
        entity.container != scope.container ||
        entity.database != scope.database ||
        entity.zone != scope.zone ||
        entity.streamKind != scope.streamKind.name ||
        entity.schemaVersion != scope.schemaVersion ||
        entity.generation != _context.entry.generation ||
        entity.entityKind != expectedKind.name ||
        entity.logicalEntityKeyHash != expectedLogicalKeyHash) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_snapshot_scope_mismatch',
      );
    }
  }

  void _validateReplayScope(CloudSemanticReplayEntity entity) {
    final scope = _context.entry.scope;
    ObjectBoxCloudSemanticStoreGateway._validateOptionalExternalDigest(
      entity.logicalEntityKeyHash,
    );
    if (entity.replayKey != _context.replayKey ||
        entity.scopeGenerationKey != _context.scopeGenerationKey ||
        entity.scopeKey != _context.scopeKey ||
        entity.accountFingerprint != scope.accountFingerprint ||
        entity.container != scope.container ||
        entity.database != scope.database ||
        entity.zone != scope.zone ||
        entity.streamKind != scope.streamKind.name ||
        entity.schemaVersion != scope.schemaVersion ||
        entity.generation != _context.entry.generation ||
        entity.changeIdHash != _context.changeIdHash ||
        entity.serverRecordIdHash != _context.entry.change.recordIdHash ||
        entity.payloadSha256 != _context.entry.change.payloadSha256 ||
        entity.protectedPayloadReferenceHash != _context.payloadReferenceHash ||
        entity.inboxSequence != _context.entry.sequence ||
        entity.changeType != _context.entry.change.type.name) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_replay_binding_mismatch',
      );
    }
    final outcome = _replayOutcome(entity.terminalOutcome);
    if (outcome != _SemanticReplayOutcome.quarantined) {
      final logicalEntityKeyHash = entity.logicalEntityKeyHash;
      if (logicalEntityKeyHash == null) {
        throw ObjectBoxCloudSemanticStoreGateway._failure(
          'semantic_replay_record_binding_missing',
        );
      }
      final recordMap = _findRecordMapByKey(
        _context.recordMapKey(logicalEntityKeyHash),
      );
      if (recordMap == null) {
        throw ObjectBoxCloudSemanticStoreGateway._failure(
          'semantic_replay_record_binding_missing',
        );
      }
      _validateRecordMapScope(recordMap, logicalEntityKeyHash);
      if (recordMap.serverRecordIdHash != entity.serverRecordIdHash ||
          recordMap.encryptedServerRecordId !=
              _context.entry.change.encryptedServerRecordId ||
          recordMap.etagHash != _context.entry.change.etagHash ||
          recordMap.encryptedRawRecordRef !=
              _context.entry.change.encryptedPayloadReference) {
        throw ObjectBoxCloudSemanticStoreGateway._failure(
          'semantic_replay_record_binding_mismatch',
        );
      }
    }
    if ((outcome == _SemanticReplayOutcome.applied &&
            entity.terminalSafeCode != null) ||
        (outcome != _SemanticReplayOutcome.applied &&
            (entity.terminalSafeCode == null ||
                !ObjectBoxCloudSemanticStoreGateway._safeCodePattern.hasMatch(
                  entity.terminalSafeCode!,
                )))) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_replay_outcome_invalid',
      );
    }
  }

  void _requireActiveChange(String changeId) {
    if (changeId != _context.entry.change.changeId) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_change_context_mismatch',
      );
    }
  }

  static void _validateSafeCode(String safeCode) {
    if (!ObjectBoxCloudSemanticStoreGateway._safeCodePattern.hasMatch(
      safeCode,
    )) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_safe_code_invalid',
      );
    }
  }

  static void _validateOptionalHashedValue(String? value) {
    if (value != null) _validateHashedValue(value);
  }

  static void _validateOptionalContentDigest(String? value) {
    if (value != null) _validateContentDigest(value);
  }

  static void _validateHashedValue(String value) {
    ObjectBoxCloudSemanticStoreGateway._validateExternalDigest(value);
  }

  static void _validateContentDigest(String value) {
    ObjectBoxCloudSemanticStoreGateway._validateContentDigest(value);
  }

  static int _millisecondsOrSentinel(DateTime? value) =>
      value?.toUtc().millisecondsSinceEpoch ??
      ObjectBoxCloudSemanticStoreGateway._nullDateSentinel;

  static DateTime? _dateOrNull(int value) {
    if (value == ObjectBoxCloudSemanticStoreGateway._nullDateSentinel) {
      return null;
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    } catch (_) {
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_timestamp_invalid',
      );
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
    if (utf8.encode(encoded).length >
        ObjectBoxCloudSemanticStoreGateway._maximumEditPartsBytes) {
      throw ObjectBoxCloudSemanticStoreGateway._malformed(
        'semantic_edit_parts_oversized',
      );
    }
    return encoded;
  }

  static Map<String, CloudEditPart> _decodeEditParts(String encoded) {
    try {
      if (utf8.encode(encoded).length >
          ObjectBoxCloudSemanticStoreGateway._maximumEditPartsBytes) {
        throw const FormatException();
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! List ||
          decoded.length >
              ObjectBoxCloudSemanticStoreGateway._maximumEditParts) {
        throw const FormatException();
      }
      final result = <String, CloudEditPart>{};
      for (final raw in decoded) {
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
        final modifiedAtMs = raw['modifiedAtMs'] as int;
        _validateHashedValue(mapKeyHash);
        _validateHashedValue(partKeyHash);
        _validateHashedValue(raw['contentDigest'] as String);
        if (mapKeyHash != partKeyHash ||
            revision < 0 ||
            result.containsKey(mapKeyHash)) {
          throw const FormatException();
        }
        result[mapKeyHash] = CloudEditPart(
          partKeyHash: partKeyHash,
          revision: revision,
          contentDigest: raw['contentDigest'] as String,
          modifiedAt: _dateOrNull(modifiedAtMs)!,
        );
      }
      if (_encodeEditParts(result) != encoded) {
        throw const FormatException();
      }
      return result;
    } catch (error) {
      if (error is CloudSyncFailure) rethrow;
      throw ObjectBoxCloudSemanticStoreGateway._failure(
        'semantic_edit_parts_invalid',
      );
    }
  }

  static CloudEntityKind _entityKind(String name) {
    for (final kind in CloudEntityKind.values) {
      if (kind.name == name) return kind;
    }
    throw ObjectBoxCloudSemanticStoreGateway._failure(
      'semantic_entity_kind_invalid',
    );
  }

  static _SemanticReplayOutcome _replayOutcome(String name) {
    for (final outcome in _SemanticReplayOutcome.values) {
      if (outcome.name == name) return outcome;
    }
    throw ObjectBoxCloudSemanticStoreGateway._failure(
      'semantic_replay_outcome_invalid',
    );
  }
}
