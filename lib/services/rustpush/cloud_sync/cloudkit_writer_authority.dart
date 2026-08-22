// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloudkit_writer_ownership.dart';
import 'cloudkit_operation_interlock.dart';

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
  const CloudKitWriterTransitionEvidence({
    required this.operationsQuiesced,
    required this.activeIdentityRevalidated,
    required this.legacyMutationQueues,
  });

  final bool operationsQuiesced;
  final bool activeIdentityRevalidated;
  final LegacyMutationQueueDisposition legacyMutationQueues;

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
    required this.owner,
    required this.epoch,
    required this.transitionIdHash,
  });

  final CloudKitWriterScope scope;
  final CloudKitWriterOwner owner;
  final int epoch;
  final String transitionIdHash;

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
    required String transitionIdHash,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    _requireTransitionIdHash(transitionIdHash);
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
        ..transitionIdHash = transitionIdHash
        ..epoch += 1
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _authorities.put(entity);
      return CloudKitResetFence._(
        scope: permit.scope,
        owner: permit.owner,
        epoch: entity.epoch,
        transitionIdHash: transitionIdHash,
      );
    });
  }

  /// Reconstructs an interrupted reset strictly from durable state.
  CloudKitResetFence? recoverResetFence(CloudKitWriterScope scope) {
    return _store.runInTransaction(TxMode.read, () {
      final entity = _find(scope);
      if (entity == null) return null;
      final snapshot = _snapshot(scope, entity);
      if (snapshot.state != CloudKitWriterAuthorityState.resetPrepared &&
          snapshot.state != CloudKitWriterAuthorityState.resetUnknown) {
        return null;
      }
      return CloudKitResetFence._(
        scope: scope,
        owner: snapshot.owner,
        epoch: snapshot.epoch,
        transitionIdHash: snapshot.transitionIdHash!,
      );
    });
  }

  CloudKitWriterAuthoritySnapshot completeReset(
    CloudKitResetFence fence, {
    required DateTime now,
  }) {
    _requireTransitionInterlock();
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
    required bool remoteStateReconciled,
    required bool activeIdentityRevalidated,
    required DateTime now,
  }) {
    _requireTransitionInterlock();
    if (!remoteStateReconciled || !activeIdentityRevalidated) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reset_reconciliation_incomplete',
      );
    }
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
      if (target != CloudKitWriterOwner.none || transitionIdHash == null) {
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
}
