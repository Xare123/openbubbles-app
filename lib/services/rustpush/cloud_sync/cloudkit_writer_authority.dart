// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloudkit_writer_ownership.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';

enum CloudKitWriterAuthorityState {
  stable,
  migrationPrepared,
  resetPrepared,
  resetUnknown,
  mutationUnknown,
}

enum LegacyMutationQueueDisposition { empty, quarantined }

final class CloudKitWriterScope {
  CloudKitWriterScope({
    required this.accountFingerprint,
    this.container = 'com.apple.messages.cloud',
    this.database = 'private',
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(accountFingerprint)) {
      throw ArgumentError('cloudkit_writer_account_fingerprint_invalid');
    }
    if (!RegExp(r'^[A-Za-z0-9.-]{1,128}$').hasMatch(container)) {
      throw ArgumentError('cloudkit_writer_container_invalid');
    }
    if (database != 'private') {
      throw ArgumentError('cloudkit_writer_database_invalid');
    }
  }

  final String accountFingerprint;
  final String container;
  final String database;

  String get storageKey => '$accountFingerprint\u001f$container\u001f$database';

  @override
  bool operator ==(Object other) =>
      other is CloudKitWriterScope &&
      other.accountFingerprint == accountFingerprint &&
      other.container == container &&
      other.database == database;

  @override
  int get hashCode => Object.hash(accountFingerprint, container, database);

  @override
  String toString() => 'CloudKitWriterScope(redacted)';
}

final class CloudKitWriterTransitionEvidence {
  const CloudKitWriterTransitionEvidence._({
    required this.operationsQuiesced,
    required this.activeIdentityRevalidated,
    required this.legacyMutationQueues,
    required bool productionMeasured,
  }) : _productionMeasured = productionMeasured;

  /// Synthetic evidence is available only to authorities created with
  /// [ObjectBoxCloudKitWriterAuthority.forTest]. Production authorities reject
  /// it even when every boolean is true.
  const CloudKitWriterTransitionEvidence.forTest({
    required bool operationsQuiesced,
    required bool activeIdentityRevalidated,
    required LegacyMutationQueueDisposition legacyMutationQueues,
  }) : this._(
         operationsQuiesced: operationsQuiesced,
         activeIdentityRevalidated: activeIdentityRevalidated,
         legacyMutationQueues: legacyMutationQueues,
         productionMeasured: false,
       );

  const CloudKitWriterTransitionEvidence._productionMeasured({
    required bool operationsQuiesced,
    required bool activeIdentityRevalidated,
    required LegacyMutationQueueDisposition legacyMutationQueues,
  }) : this._(
         operationsQuiesced: operationsQuiesced,
         activeIdentityRevalidated: activeIdentityRevalidated,
         legacyMutationQueues: legacyMutationQueues,
         productionMeasured: true,
       );

  final bool operationsQuiesced;
  final bool activeIdentityRevalidated;
  final LegacyMutationQueueDisposition legacyMutationQueues;
  final bool _productionMeasured;

  bool get isComplete =>
      operationsQuiesced &&
      activeIdentityRevalidated &&
      legacyMutationQueues == LegacyMutationQueueDisposition.empty;

  @override
  String toString() => 'CloudKitWriterTransitionEvidence(redacted)';
}

final class CloudKitWriterAuthoritySnapshot {
  const CloudKitWriterAuthoritySnapshot({
    required this.scope,
    required this.owner,
    required this.state,
    required this.epoch,
    this.targetOwner = CloudKitWriterOwner.none,
    this.transitionIdHash,
  });

  final CloudKitWriterScope scope;
  final CloudKitWriterOwner owner;
  final CloudKitWriterAuthorityState state;
  final CloudKitWriterOwner targetOwner;
  final int epoch;
  final String? transitionIdHash;

  @override
  String toString() =>
      'CloudKitWriterAuthoritySnapshot(owner=${owner.name}, state=${state.name}, epoch=$epoch, redacted)';
}

final class CloudKitWriterPermit {
  const CloudKitWriterPermit._({
    required this.scope,
    required this.owner,
    required this.epoch,
  });

  final CloudKitWriterScope scope;
  final CloudKitWriterOwner owner;
  final int epoch;

  @override
  String toString() =>
      'CloudKitWriterPermit(owner=${owner.name}, epoch=$epoch, redacted)';
}

final class CloudKitResetFence {
  const CloudKitResetFence._({
    required this.scope,
    required this.syncScope,
    required this.owner,
    required this.epoch,
    required this.expectedGeneration,
    required this.transitionIdHash,
    required this.proofReferenceHash,
  });

  final CloudKitWriterScope scope;
  final CloudSyncScope syncScope;
  final CloudKitWriterOwner owner;
  final int epoch;
  final int expectedGeneration;
  final String transitionIdHash;
  final String proofReferenceHash;

  @override
  String toString() =>
      'CloudKitResetFence(owner=${owner.name}, epoch=$epoch, redacted)';
}

final class CloudKitWriterAuthorityFailure implements Exception {
  const CloudKitWriterAuthorityFailure(this.safeCode);

  final String safeCode;

  @override
  String toString() => 'CloudKitWriterAuthorityFailure($safeCode)';
}

/// Transactional, per-account single-writer authority.
///
/// A build-time owner selector is necessary but insufficient: a stale process
/// or a migration crash can otherwise keep writing. Durable epochs make every
/// permit revocable, while prepared/unknown states prevent either writer from
/// operating until the transition is explicitly completed or reconciled.
final class ObjectBoxCloudKitWriterAuthority {
  ObjectBoxCloudKitWriterAuthority({required Store store})
    : _store = store,
      _authorities = store.box<CloudKitWriterAuthorityEntity>(),
      _leases = store.box<CloudSyncLeaseEntity>(),
      _buildDecision = CloudKitWriterOwnership.decision,
      _requireInterlock = true;

  ObjectBoxCloudKitWriterAuthority.forTest({
    required Store store,
    required CloudKitWriterOwnershipDecision buildDecision,
  }) : _store = store,
       _authorities = store.box<CloudKitWriterAuthorityEntity>(),
       _leases = store.box<CloudSyncLeaseEntity>(),
       _buildDecision = buildDecision,
       _requireInterlock = false;

  final Store _store;
  final Box<CloudKitWriterAuthorityEntity> _authorities;
  final Box<CloudSyncLeaseEntity> _leases;
  final CloudKitWriterOwnershipDecision _buildDecision;
  final bool _requireInterlock;

  /// Joint persistence must consult authority in the same database transaction.
  bool isBoundToStore(Store store) => identical(store, _store);

  CloudKitWriterAuthoritySnapshot initializeDisabled(
    CloudKitWriterScope scope, {
    required DateTime now,
  }) {
    try {
      return _store.runInTransaction(TxMode.write, () {
        final existing = _find(scope);
        if (existing != null) return _snapshot(scope, existing);
        final created = CloudKitWriterAuthorityEntity(
          authorityKey: _authorityKey(scope),
          accountFingerprint: scope.accountFingerprint,
          container: scope.container,
          database: scope.database,
          updatedAtMs: now.millisecondsSinceEpoch,
        );
        _authorities.put(created);
        return _snapshot(scope, created);
      });
    } on UniqueViolationException {
      final raced = read(scope);
      if (raced != null) return raced;
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_initialize_race',
      );
    }
  }

  CloudKitWriterAuthoritySnapshot? read(CloudKitWriterScope scope) {
    return _store.runInTransaction(TxMode.read, () {
      final entity = _find(scope);
      return entity == null ? null : _snapshot(scope, entity);
    });
  }

  CloudKitWriterAuthoritySnapshot provisionInitialOwner(
    CloudKitWriterScope scope, {
    required CloudKitWriterOwner owner,
    required int expectedEpoch,
    required CloudKitWriterTransitionEvidence evidence,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    _requireSelectedOwner(owner);
    _requireEvidence(evidence);
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(scope);
      final current = _requireStable(scope, entity);
      _requireNoActiveCoordinator(scope, now: now);
      if (current.owner != CloudKitWriterOwner.none ||
          current.epoch != expectedEpoch) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_initial_owner_precondition_failed',
        );
      }
      entity
        ..owner = _ownerCode(owner)
        ..targetOwner = _ownerCode(CloudKitWriterOwner.none)
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return _snapshot(scope, entity);
    });
  }

  CloudKitWriterPermit issuePermit(
    CloudKitWriterScope scope, {
    required CloudKitWriterOwner expectedOwner,
  }) {
    _requireSelectedOwner(expectedOwner);
    return _store.runInTransaction(TxMode.read, () {
      final entity = _require(scope);
      final current = _requireStable(scope, entity);
      if (current.owner != expectedOwner) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_owner_mismatch',
        );
      }
      return CloudKitWriterPermit._(
        scope: scope,
        owner: expectedOwner,
        epoch: current.epoch,
      );
    });
  }

  void verifyPermit(CloudKitWriterPermit permit) {
    _store.runInTransaction(TxMode.read, () {
      final entity = _require(permit.scope);
      final current = _requireStable(permit.scope, entity);
      if (current.owner != permit.owner || current.epoch != permit.epoch) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_permit_stale',
        );
      }
    });
  }

  void markMutationUnknown(
    CloudKitWriterPermit permit, {
    required DateTime now,
  }) {
    _requireMutationInterlock(permit.owner);
    _store.runInTransaction(TxMode.write, () {
      final entity = _require(permit.scope);
      final current = _requireStable(permit.scope, entity);
      if (current.owner != permit.owner || current.epoch != permit.epoch) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_permit_stale',
        );
      }
      entity
        ..state = _stateCode(CloudKitWriterAuthorityState.mutationUnknown)
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
    });
  }

  /// Restores a writer to a fresh stable epoch only after an exact remote
  /// readback has resolved the mutation protected by the filesystem fence.
  ///
  /// A process can die before [markMutationUnknown] runs, leaving the original
  /// stable epoch beside an armed fence, or after this transaction commits but
  /// before that fence is removed. Both states are accepted idempotently. No
  /// other epoch or authority state may be repaired through this path.
  CloudKitWriterAuthoritySnapshot reconcileMutationFence(
    CloudKitWriterScope scope, {
    required CloudKitWriterOwner owner,
    required int fencedEpoch,
    required DateTime now,
  }) {
    _requireMutationInterlock(owner);
    _requireSelectedOwner(owner);
    if (fencedEpoch < 0) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_reconciliation_epoch_invalid',
      );
    }
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(scope);
      final current = _snapshot(scope, entity);
      if (current.owner != owner ||
          current.targetOwner != CloudKitWriterOwner.none ||
          current.transitionIdHash != null) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_reconciliation_precondition_failed',
        );
      }

      final unresolvedStable =
          current.state == CloudKitWriterAuthorityState.stable &&
          current.epoch == fencedEpoch;
      final explicitlyUnknown =
          current.state == CloudKitWriterAuthorityState.mutationUnknown &&
          current.epoch == fencedEpoch + 1;
      final alreadyReconciled =
          current.state == CloudKitWriterAuthorityState.stable &&
          current.epoch == fencedEpoch + 2;
      if (alreadyReconciled) return current;
      if (!unresolvedStable && !explicitlyUnknown) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_reconciliation_precondition_failed',
        );
      }

      entity
        ..state = _stateCode(CloudKitWriterAuthorityState.stable)
        ..targetOwner = _ownerCode(CloudKitWriterOwner.none)
        ..transitionIdHash = null
        // Always converge on one deterministic post-reconciliation epoch.
        // This invalidates the permit which armed the fence even when the
        // process died before it could mark the mutation unknown.
        ..epoch = fencedEpoch + 2
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return _snapshot(scope, entity);
    });
  }

  CloudKitWriterAuthoritySnapshot prepareMigration(
    CloudKitWriterScope scope, {
    required CloudKitWriterOwner from,
    required CloudKitWriterOwner to,
    required int expectedEpoch,
    required String transitionIdHash,
    required CloudKitWriterTransitionEvidence evidence,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    if (from == CloudKitWriterOwner.none || from == to) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_migration_invalid',
      );
    }
    _requireSelectedOwner(to);
    _requireTransitionIdHash(transitionIdHash);
    _requireEvidence(evidence);
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(scope);
      final current = _requireStable(scope, entity);
      _requireNoActiveCoordinator(scope, now: now);
      if (current.owner != from || current.epoch != expectedEpoch) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_migration_precondition_failed',
        );
      }
      entity
        ..state = _stateCode(CloudKitWriterAuthorityState.migrationPrepared)
        ..targetOwner = _ownerCode(to)
        ..transitionIdHash = transitionIdHash
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return _snapshot(scope, entity);
    });
  }

  CloudKitWriterAuthoritySnapshot commitMigration(
    CloudKitWriterScope scope, {
    required CloudKitWriterOwner targetOwner,
    required int expectedEpoch,
    required String transitionIdHash,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    _requireSelectedOwner(targetOwner);
    _requireTransitionIdHash(transitionIdHash);
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(scope);
      final current = _snapshot(scope, entity);
      _requireNoActiveCoordinator(scope, now: now);
      if (current.state != CloudKitWriterAuthorityState.migrationPrepared ||
          current.targetOwner != targetOwner ||
          current.epoch != expectedEpoch ||
          current.transitionIdHash != transitionIdHash) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_migration_commit_precondition_failed',
        );
      }
      entity
        ..owner = _ownerCode(targetOwner)
        ..state = _stateCode(CloudKitWriterAuthorityState.stable)
        ..targetOwner = _ownerCode(CloudKitWriterOwner.none)
        ..transitionIdHash = null
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return _snapshot(scope, entity);
    });
  }

  CloudKitWriterAuthoritySnapshot abortMigration(
    CloudKitWriterScope scope, {
    required CloudKitWriterOwner targetOwner,
    required int expectedEpoch,
    required String transitionIdHash,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    _requireSelectedOwner(targetOwner);
    _requireTransitionIdHash(transitionIdHash);
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(scope);
      final current = _snapshot(scope, entity);
      _requireNoActiveCoordinator(scope, now: now);
      if (current.state != CloudKitWriterAuthorityState.migrationPrepared ||
          current.targetOwner != targetOwner ||
          current.epoch != expectedEpoch ||
          current.transitionIdHash != transitionIdHash) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_migration_abort_precondition_failed',
        );
      }
      entity
        ..state = _stateCode(CloudKitWriterAuthorityState.stable)
        ..targetOwner = _ownerCode(CloudKitWriterOwner.none)
        ..transitionIdHash = null
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return _snapshot(scope, entity);
    });
  }

  CloudKitResetFence prepareReset(
    CloudKitWriterPermit permit, {
    required CloudSyncResetRebootstrapRequest request,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    _requireResetRequest(permit.scope, request);
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(permit.scope);
      final current = _requireStable(permit.scope, entity);
      _requireNoActiveCoordinator(permit.scope, now: now);
      if (current.owner != permit.owner || current.epoch != permit.epoch) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_reset_precondition_failed',
        );
      }
      entity
        ..state = _stateCode(CloudKitWriterAuthorityState.resetPrepared)
        ..transitionIdHash = request.transitionIdHash
        ..resetScopeKeyHash = _scopeDigest(request.scope)
        ..resetProofReferenceHash = _digest(
          'cloudkit-reset-proof\u001f${request.protectedRemoteStateProofReference}',
        )
        ..resetGeneration = request.expectedGeneration
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return CloudKitResetFence._(
        scope: permit.scope,
        syncScope: request.scope,
        owner: permit.owner,
        epoch: entity.epoch,
        expectedGeneration: request.expectedGeneration,
        transitionIdHash: request.transitionIdHash,
        proofReferenceHash: entity.resetProofReferenceHash!,
      );
    });
  }

  /// Reconstructs an interrupted reset strictly from durable state.
  CloudKitResetFence? recoverResetFence(
    CloudKitWriterScope scope, {
    required CloudSyncScope syncScope,
  }) {
    return _store.runInTransaction(TxMode.read, () {
      final entity = _find(scope);
      if (entity == null) return null;
      final snapshot = _snapshot(scope, entity);
      if (snapshot.state != CloudKitWriterAuthorityState.resetPrepared &&
          snapshot.state != CloudKitWriterAuthorityState.resetUnknown) {
        return null;
      }
      if (entity.resetScopeKeyHash != _scopeDigest(syncScope)) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_reset_scope_mismatch',
        );
      }
      if (entity.resetProofReferenceHash == null) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_reset_proof_binding_missing',
        );
      }
      return CloudKitResetFence._(
        scope: scope,
        syncScope: syncScope,
        owner: snapshot.owner,
        epoch: snapshot.epoch,
        expectedGeneration: entity.resetGeneration,
        transitionIdHash: snapshot.transitionIdHash!,
        proofReferenceHash: entity.resetProofReferenceHash!,
      );
    });
  }

  CloudKitWriterAuthoritySnapshot completeReset(
    CloudKitResetFence fence, {
    required CloudSyncResetCompletionProof proof,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    _requireResetCompletionProof(fence, proof);
    return _finishReset(
      fence,
      expectedState: CloudKitWriterAuthorityState.resetPrepared,
      now: now,
    );
  }

  CloudKitWriterAuthoritySnapshot markResetUnknown(
    CloudKitResetFence fence, {
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(fence.scope);
      final current = _snapshot(fence.scope, entity);
      _requireNoActiveCoordinator(fence.scope, now: now);
      if (current.state != CloudKitWriterAuthorityState.resetPrepared ||
          current.owner != fence.owner ||
          current.epoch != fence.epoch ||
          current.transitionIdHash != fence.transitionIdHash) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_reset_unknown_precondition_failed',
        );
      }
      entity
        ..state = _stateCode(CloudKitWriterAuthorityState.resetUnknown)
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return _snapshot(fence.scope, entity);
    });
  }

  CloudKitWriterAuthoritySnapshot reconcileResetUnknown(
    CloudKitResetFence fence, {
    required CloudSyncResetCompletionProof proof,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    _requireResetCompletionProof(fence, proof);
    return _finishReset(
      fence,
      expectedState: CloudKitWriterAuthorityState.resetUnknown,
      now: now,
    );
  }

  CloudKitWriterAuthoritySnapshot _finishReset(
    CloudKitResetFence fence, {
    required CloudKitWriterAuthorityState expectedState,
    required DateTime now,
  }) {
    return _store.runInTransaction(TxMode.write, () {
      final entity = _require(fence.scope);
      final current = _snapshot(fence.scope, entity);
      _requireNoActiveCoordinator(fence.scope, now: now);
      if (current.state != expectedState ||
          current.owner != fence.owner ||
          current.epoch != fence.epoch ||
          current.transitionIdHash != fence.transitionIdHash) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_reset_finish_precondition_failed',
        );
      }
      entity
        ..state = _stateCode(CloudKitWriterAuthorityState.stable)
        ..transitionIdHash = null
        ..resetScopeKeyHash = null
        ..resetProofReferenceHash = null
        ..resetGeneration = 0
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return _snapshot(fence.scope, entity);
    });
  }

  void _requireTransitionInterlock() {
    if (!_requireInterlock) return;
    CloudKitOperationInterlock.requireActiveAny(const {
      CloudKitOperationKind.writerTransition,
      CloudKitOperationKind.destructiveReset,
    });
  }

  void _requireMutationInterlock(CloudKitWriterOwner owner) {
    if (!_requireInterlock) return;
    CloudKitOperationInterlock.requireActive(switch (owner) {
      CloudKitWriterOwner.legacy => CloudKitOperationKind.legacyReadWrite,
      CloudKitWriterOwner.v2 => CloudKitOperationKind.v2ReadWrite,
      CloudKitWriterOwner.none => throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_owner_invalid',
      ),
    });
  }

  void _requireSelectedOwner(CloudKitWriterOwner owner) {
    if (owner == CloudKitWriterOwner.none ||
        !_buildDecision.configurationValid ||
        _buildDecision.owner != owner) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_build_owner_mismatch',
      );
    }
  }

  void _requireEvidence(CloudKitWriterTransitionEvidence evidence) {
    if (!evidence.isComplete) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_transition_evidence_incomplete',
      );
    }
    if (_requireInterlock && !evidence._productionMeasured) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_transition_evidence_untrusted',
      );
    }
  }

  void _requireResetRequest(
    CloudKitWriterScope writerScope,
    CloudSyncResetRebootstrapRequest request,
  ) {
    if (request.scope.accountFingerprint != writerScope.accountFingerprint ||
        request.scope.container != writerScope.container ||
        request.scope.database != writerScope.database) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reset_scope_mismatch',
      );
    }
  }

  void _requireResetCompletionProof(
    CloudKitResetFence fence,
    CloudSyncResetCompletionProof proof,
  ) {
    if (proof.scope != fence.syncScope ||
        proof.transitionIdHash != fence.transitionIdHash ||
        proof.activeIdentityFingerprint != fence.scope.accountFingerprint ||
        proof.previousGeneration != fence.expectedGeneration ||
        proof.generation != fence.expectedGeneration + 1 ||
        _digest(
              'cloudkit-reset-proof\u001f${proof.protectedRemoteStateProofReference}',
            ) !=
            fence.proofReferenceHash) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reset_completion_proof_mismatch',
      );
    }
  }

  CloudKitWriterAuthoritySnapshot _requireStable(
    CloudKitWriterScope scope,
    CloudKitWriterAuthorityEntity entity,
  ) {
    final snapshot = _snapshot(scope, entity);
    if (snapshot.state != CloudKitWriterAuthorityState.stable ||
        snapshot.targetOwner != CloudKitWriterOwner.none) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_not_stable',
      );
    }
    return snapshot;
  }

  void _requireNoActiveCoordinator(
    CloudKitWriterScope scope, {
    required DateTime now,
  }) {
    final nowMs = now.millisecondsSinceEpoch;
    final query = _leases
        .query(
          CloudSyncLeaseEntity_.accountFingerprint.equals(
            scope.accountFingerprint,
          ),
        )
        .build();
    try {
      if (query.find().any((lease) => lease.expiresAtMs > nowMs)) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_transition_coordinator_active',
        );
      }
    } finally {
      query.close();
    }
  }

  void _requireTransitionIdHash(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_transition_id_invalid',
      );
    }
  }

  CloudKitWriterAuthorityEntity _require(CloudKitWriterScope scope) {
    final entity = _find(scope);
    if (entity == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_missing',
      );
    }
    return entity;
  }

  CloudKitWriterAuthorityEntity? _find(CloudKitWriterScope scope) {
    final query =
        _authorities
            .query(
              CloudKitWriterAuthorityEntity_.authorityKey.equals(
                _authorityKey(scope),
              ),
            )
            .build()
          ..limit = 2;
    try {
      final values = query.find();
      if (values.length > 1) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_authority_ambiguous',
        );
      }
      if (values.isEmpty) return null;
      final entity = values.single;
      if (entity.accountFingerprint != scope.accountFingerprint ||
          entity.container != scope.container ||
          entity.database != scope.database) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_authority_scope_collision',
        );
      }
      return entity;
    } finally {
      query.close();
    }
  }

  CloudKitWriterAuthoritySnapshot _snapshot(
    CloudKitWriterScope scope,
    CloudKitWriterAuthorityEntity entity,
  ) {
    if (entity.epoch <= 0) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_epoch_invalid',
      );
    }
    final state = _state(entity.state);
    final owner = _owner(entity.owner);
    final target = _owner(entity.targetOwner);
    final transitionIdHash = entity.transitionIdHash;
    if (state == CloudKitWriterAuthorityState.migrationPrepared) {
      if (owner == CloudKitWriterOwner.none ||
          target == CloudKitWriterOwner.none ||
          target == owner ||
          transitionIdHash == null) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_authority_state_invalid',
        );
      }
    } else if (state == CloudKitWriterAuthorityState.resetPrepared ||
        state == CloudKitWriterAuthorityState.resetUnknown) {
      if (target != CloudKitWriterOwner.none ||
          transitionIdHash == null ||
          entity.resetScopeKeyHash == null ||
          entity.resetProofReferenceHash == null ||
          entity.resetGeneration <= 0) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_authority_state_invalid',
        );
      }
    } else if (state == CloudKitWriterAuthorityState.mutationUnknown) {
      if (owner == CloudKitWriterOwner.none ||
          target != CloudKitWriterOwner.none ||
          transitionIdHash != null) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_authority_state_invalid',
        );
      }
    } else if (target != CloudKitWriterOwner.none || transitionIdHash != null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_state_invalid',
      );
    }
    if (transitionIdHash != null) {
      _requireTransitionIdHash(transitionIdHash);
    }
    if (state != CloudKitWriterAuthorityState.resetPrepared &&
        state != CloudKitWriterAuthorityState.resetUnknown &&
        (entity.resetScopeKeyHash != null ||
            entity.resetProofReferenceHash != null ||
            entity.resetGeneration != 0)) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_state_invalid',
      );
    }
    return CloudKitWriterAuthoritySnapshot(
      scope: scope,
      owner: owner,
      state: state,
      targetOwner: target,
      epoch: entity.epoch,
      transitionIdHash: transitionIdHash,
    );
  }

  CloudKitWriterOwner _owner(int value) {
    if (value < 0 || value >= CloudKitWriterOwner.values.length) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_owner_invalid',
      );
    }
    return switch (value) {
      0 => CloudKitWriterOwner.none,
      1 => CloudKitWriterOwner.legacy,
      2 => CloudKitWriterOwner.v2,
      _ => throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_owner_invalid',
      ),
    };
  }

  CloudKitWriterAuthorityState _state(int value) {
    if (value < 0 || value >= CloudKitWriterAuthorityState.values.length) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_state_invalid',
      );
    }
    return switch (value) {
      0 => CloudKitWriterAuthorityState.stable,
      1 => CloudKitWriterAuthorityState.migrationPrepared,
      2 => CloudKitWriterAuthorityState.resetPrepared,
      3 => CloudKitWriterAuthorityState.resetUnknown,
      4 => CloudKitWriterAuthorityState.mutationUnknown,
      _ => throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_state_invalid',
      ),
    };
  }

  int _ownerCode(CloudKitWriterOwner value) => switch (value) {
    CloudKitWriterOwner.none => 0,
    CloudKitWriterOwner.legacy => 1,
    CloudKitWriterOwner.v2 => 2,
  };

  int _stateCode(CloudKitWriterAuthorityState value) => switch (value) {
    CloudKitWriterAuthorityState.stable => 0,
    CloudKitWriterAuthorityState.migrationPrepared => 1,
    CloudKitWriterAuthorityState.resetPrepared => 2,
    CloudKitWriterAuthorityState.resetUnknown => 3,
    CloudKitWriterAuthorityState.mutationUnknown => 4,
  };

  String _authorityKey(CloudKitWriterScope scope) => sha256
      .convert(
        utf8.encode('cloudkit-writer-authority\u001f${scope.storageKey}'),
      )
      .toString();

  String _scopeDigest(CloudSyncScope scope) => sha256
      .convert(utf8.encode('cloudkit-reset-scope\u001f${scope.storageKey}'))
      .toString();

  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
}

typedef CloudKitWriterProvisioningMeasurementsReader =
    FutureOr<CloudKitWriterProvisioningMeasurements> Function(
      CloudKitWriterScope scope,
    );
typedef CloudKitWriterLegacyQueueQuarantine = FutureOr<void> Function();
typedef CloudKitWriterProvisioningClock = DateTime Function();

/// Direct, read-only measurements used before changing durable writer owner.
///
/// Counts are deliberately retained instead of collapsed into caller-supplied
/// booleans. A transition can be authorized only by the production provisioner
/// after it has obtained a complete zero-risk snapshot under the shared writer
/// interlock.
final class CloudKitWriterProvisioningMeasurements {
  const CloudKitWriterProvisioningMeasurements({
    required this.objectBoxReady,
    required this.legacySyncEnabled,
    required this.legacySyncActive,
    required this.backgroundSyncActive,
    required this.coordinatorLeaseActive,
    required this.pendingLegacyDeletionIntents,
    required this.legacyPreferenceQueueEntries,
    required this.unsyncedLegacyMessages,
    required this.unsyncedLegacyChats,
    required this.existingV2OutboxOperations,
  });

  final bool objectBoxReady;
  final bool legacySyncEnabled;
  final bool legacySyncActive;
  final bool backgroundSyncActive;
  final bool coordinatorLeaseActive;
  final int pendingLegacyDeletionIntents;
  final int legacyPreferenceQueueEntries;

  /// `ckSyncState == false/null` marks a record as a possible input to the old
  /// uploader; it is not itself durable queued work. These counts are retained
  /// for migration diagnostics while the V2-only build keeps those rows inert.
  final int unsyncedLegacyMessages;
  final int unsyncedLegacyChats;
  final int existingV2OutboxOperations;

  bool get hasValidCounts =>
      pendingLegacyDeletionIntents >= 0 &&
      legacyPreferenceQueueEntries >= 0 &&
      unsyncedLegacyMessages >= 0 &&
      unsyncedLegacyChats >= 0 &&
      existingV2OutboxOperations >= 0;

  bool get operationsQuiesced =>
      objectBoxReady &&
      !legacySyncEnabled &&
      !legacySyncActive &&
      !backgroundSyncActive &&
      !coordinatorLeaseActive;

  bool get legacyMutationQueuesEmpty =>
      pendingLegacyDeletionIntents == 0 && legacyPreferenceQueueEntries == 0;

  bool get safeForTransition =>
      hasValidCounts &&
      operationsQuiesced &&
      legacyMutationQueuesEmpty &&
      existingV2OutboxOperations == 0;

  /// Once V2 already owns the profile, its durable outbox and newly received
  /// local rows are expected. Legacy execution and deletion queues must still
  /// remain absent on every permit restoration.
  bool get safeForStableV2 =>
      hasValidCounts &&
      operationsQuiesced &&
      pendingLegacyDeletionIntents == 0 &&
      legacyPreferenceQueueEntries == 0;

  @override
  String toString() => 'CloudKitWriterProvisioningMeasurements(redacted)';
}

enum CloudKitV2WriterProvisioningDisposition {
  provisioned,
  migrated,
  alreadyOwned,
}

final class CloudKitV2WriterProvisioningResult {
  const CloudKitV2WriterProvisioningResult({
    required this.snapshot,
    required this.permit,
    required this.disposition,
  });

  final CloudKitWriterAuthoritySnapshot snapshot;
  final CloudKitWriterPermit permit;
  final CloudKitV2WriterProvisioningDisposition disposition;
}

/// The sole production entry point for establishing V2 writer ownership.
///
/// Every probe and identity read occurs while the cross-process writer
/// transition interlock is held. Probe errors, account replacement, non-stable
/// authority state, pending legacy work, and stale permits all fail closed.
final class CloudKitV2WriterProvisioner {
  CloudKitV2WriterProvisioner({
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitOperationExclusion interlock,
    required CloudSyncNativeAuthSnapshotReader readAuthSnapshot,
    required CloudKitWriterLegacyQueueQuarantine quarantineLegacyDeletionQueues,
    required CloudKitWriterProvisioningMeasurementsReader readMeasurements,
    CloudKitWriterProvisioningClock? clock,
  }) : _authority = authority,
       _interlock = interlock,
       _readAuthSnapshot = readAuthSnapshot,
       _quarantineLegacyDeletionQueues = quarantineLegacyDeletionQueues,
       _readMeasurements = readMeasurements,
       _clock = clock ?? DateTime.now;

  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitOperationExclusion _interlock;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudKitWriterLegacyQueueQuarantine _quarantineLegacyDeletionQueues;
  final CloudKitWriterProvisioningMeasurementsReader _readMeasurements;
  final CloudKitWriterProvisioningClock _clock;

  Future<CloudKitV2WriterProvisioningResult> ensureV2Owned({
    required CloudSyncNativeAuthSnapshot expectedAuth,
  }) {
    if (!_authority._buildDecision.configurationValid ||
        _authority._buildDecision.owner != CloudKitWriterOwner.v2) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_build_owner_mismatch',
      );
    }
    final scope = CloudKitWriterScope(
      accountFingerprint: expectedAuth.accountFingerprint,
    );
    return _interlock.runExclusive(
      kind: CloudKitOperationKind.writerTransition,
      action: () => _ensureV2OwnedInsideInterlock(
        scope: scope,
        expectedAuth: expectedAuth,
      ),
    );
  }

  Future<CloudKitV2WriterProvisioningResult> _ensureV2OwnedInsideInterlock({
    required CloudKitWriterScope scope,
    required CloudSyncNativeAuthSnapshot expectedAuth,
  }) async {
    await _requireSameAuth(expectedAuth);
    final initial = _authority.initializeDisabled(scope, now: _clock());
    await _quarantineLegacyQueuesFailClosed();
    var measurements = await _readMeasurementsFailClosed(scope);
    await _requireSameAuth(expectedAuth);

    if (initial.owner == CloudKitWriterOwner.v2) {
      if (initial.state != CloudKitWriterAuthorityState.stable ||
          initial.targetOwner != CloudKitWriterOwner.none ||
          !measurements.safeForStableV2) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_v2_restore_precondition_failed',
        );
      }
      return _finish(
        scope,
        expectedAuth,
        disposition: CloudKitV2WriterProvisioningDisposition.alreadyOwned,
      );
    }

    if (!measurements.safeForTransition) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_transition_precondition_failed',
      );
    }
    final evidence = _productionEvidence(measurements);
    CloudKitV2WriterProvisioningDisposition disposition;
    if (initial.owner == CloudKitWriterOwner.none &&
        initial.state == CloudKitWriterAuthorityState.stable &&
        initial.targetOwner == CloudKitWriterOwner.none) {
      _authority.provisionInitialOwner(
        scope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: initial.epoch,
        evidence: evidence,
        now: _clock(),
      );
      disposition = CloudKitV2WriterProvisioningDisposition.provisioned;
    } else if (initial.owner == CloudKitWriterOwner.legacy &&
        initial.state == CloudKitWriterAuthorityState.stable &&
        initial.targetOwner == CloudKitWriterOwner.none) {
      final transitionIdHash = _migrationTransitionId(
        scope,
        expectedAuth,
        initial.epoch,
      );
      final prepared = _authority.prepareMigration(
        scope,
        from: CloudKitWriterOwner.legacy,
        to: CloudKitWriterOwner.v2,
        expectedEpoch: initial.epoch,
        transitionIdHash: transitionIdHash,
        evidence: evidence,
        now: _clock(),
      );
      await _requireSameAuth(expectedAuth);
      measurements = await _readMeasurementsFailClosed(scope);
      if (!measurements.safeForTransition) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_migration_commit_precondition_failed',
        );
      }
      _authority.commitMigration(
        scope,
        targetOwner: CloudKitWriterOwner.v2,
        expectedEpoch: prepared.epoch,
        transitionIdHash: transitionIdHash,
        now: _clock(),
      );
      disposition = CloudKitV2WriterProvisioningDisposition.migrated;
    } else {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_authority_requires_manual_recovery',
      );
    }

    return _finish(scope, expectedAuth, disposition: disposition);
  }

  Future<CloudKitV2WriterProvisioningResult> _finish(
    CloudKitWriterScope scope,
    CloudSyncNativeAuthSnapshot expectedAuth, {
    required CloudKitV2WriterProvisioningDisposition disposition,
  }) async {
    await _requireSameAuth(expectedAuth);
    final snapshot = _authority.read(scope);
    if (snapshot == null ||
        snapshot.owner != CloudKitWriterOwner.v2 ||
        snapshot.state != CloudKitWriterAuthorityState.stable ||
        snapshot.targetOwner != CloudKitWriterOwner.none) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_v2_readback_failed',
      );
    }
    final permit = _authority.issuePermit(
      scope,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    _authority.verifyPermit(permit);
    await _requireSameAuth(expectedAuth);
    return CloudKitV2WriterProvisioningResult(
      snapshot: snapshot,
      permit: permit,
      disposition: disposition,
    );
  }

  Future<void> _quarantineLegacyQueuesFailClosed() async {
    try {
      await _quarantineLegacyDeletionQueues();
    } catch (_) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_legacy_queue_quarantine_failed',
      );
    }
  }

  Future<CloudKitWriterProvisioningMeasurements> _readMeasurementsFailClosed(
    CloudKitWriterScope scope,
  ) async {
    try {
      final measurements = await _readMeasurements(scope);
      if (!measurements.hasValidCounts) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_provisioning_measurements_invalid',
        );
      }
      return measurements;
    } on CloudKitWriterAuthorityFailure {
      rethrow;
    } catch (_) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_provisioning_probe_failed',
      );
    }
  }

  Future<void> _requireSameAuth(
    CloudSyncNativeAuthSnapshot expectedAuth,
  ) async {
    CloudSyncNativeAuthSnapshot? current;
    try {
      current = await _readAuthSnapshot();
    } catch (_) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_identity_revalidation_failed',
      );
    }
    if (!expectedAuth.sameIdentity(current)) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_identity_changed',
      );
    }
  }

  CloudKitWriterTransitionEvidence _productionEvidence(
    CloudKitWriterProvisioningMeasurements measurements,
  ) => CloudKitWriterTransitionEvidence._productionMeasured(
    operationsQuiesced: measurements.operationsQuiesced,
    activeIdentityRevalidated: true,
    legacyMutationQueues: measurements.legacyMutationQueuesEmpty
        ? LegacyMutationQueueDisposition.empty
        : LegacyMutationQueueDisposition.quarantined,
  );

  String _migrationTransitionId(
    CloudKitWriterScope scope,
    CloudSyncNativeAuthSnapshot auth,
    int epoch,
  ) => sha256
      .convert(
        utf8.encode(
          'cloudkit-v2-writer-migration\u001f${scope.storageKey}\u001f'
          '${auth.nativeSessionId}\u001f$epoch\u001f'
          '${_clock().microsecondsSinceEpoch}',
        ),
      )
      .toString();
}
