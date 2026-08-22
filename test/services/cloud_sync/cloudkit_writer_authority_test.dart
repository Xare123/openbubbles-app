import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloudkit-writer-authority-',
    );
    store = await openStore(directory: directory.path);
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
  }

  ObjectBoxCloudKitWriterAuthority authority(CloudKitWriterOwner owner) {
    return ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnershipDecision(
        owner: owner,
        configurationValid: true,
      ),
    );
  }

  CloudKitWriterAuthoritySnapshot initialize({CloudKitWriterScope? scope}) {
    scope ??= _scopeA;
    return authority(
      CloudKitWriterOwner.none,
    ).initializeDisabled(scope, now: _time(0));
  }

  CloudKitWriterAuthoritySnapshot provision({
    CloudKitWriterScope? scope,
    CloudKitWriterOwner owner = CloudKitWriterOwner.legacy,
  }) {
    scope ??= _scopeA;
    final initial = initialize(scope: scope);
    return authority(owner).provisionInitialOwner(
      scope,
      owner: owner,
      expectedEpoch: initial.epoch,
      evidence: _completeEvidence,
      now: _time(1),
    );
  }

  test(
    'disabled authority persists across reopen and issues no permit',
    () async {
      final initial = initialize();
      expect(initial.owner, CloudKitWriterOwner.none);
      expect(initial.state, CloudKitWriterAuthorityState.stable);
      expect(initial.epoch, 1);

      await reopen();
      final reopened = authority(CloudKitWriterOwner.none).read(_scopeA);
      expect(reopened?.owner, CloudKitWriterOwner.none);
      expect(reopened?.epoch, initial.epoch);
      expect(
        () => authority(
          CloudKitWriterOwner.none,
        ).issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.none),
        throwsA(_failure('cloudkit_writer_build_owner_mismatch')),
      );
    },
  );

  test(
    'initial provisioning requires matching build and complete evidence',
    () {
      final initial = initialize();
      expect(
        () => authority(CloudKitWriterOwner.v2).provisionInitialOwner(
          _scopeA,
          owner: CloudKitWriterOwner.legacy,
          expectedEpoch: initial.epoch,
          evidence: _completeEvidence,
          now: _time(1),
        ),
        throwsA(_failure('cloudkit_writer_build_owner_mismatch')),
      );
      expect(
        () => authority(CloudKitWriterOwner.legacy).provisionInitialOwner(
          _scopeA,
          owner: CloudKitWriterOwner.legacy,
          expectedEpoch: initial.epoch,
          evidence: const CloudKitWriterTransitionEvidence(
            operationsQuiesced: false,
            activeIdentityRevalidated: true,
            legacyMutationQueues: LegacyMutationQueueDisposition.quarantined,
          ),
          now: _time(1),
        ),
        throwsA(_failure('cloudkit_writer_transition_evidence_incomplete')),
      );
      expect(
        () => authority(CloudKitWriterOwner.legacy).provisionInitialOwner(
          _scopeA,
          owner: CloudKitWriterOwner.legacy,
          expectedEpoch: initial.epoch,
          evidence: const CloudKitWriterTransitionEvidence(
            operationsQuiesced: true,
            activeIdentityRevalidated: true,
            legacyMutationQueues: LegacyMutationQueueDisposition.quarantined,
          ),
          now: _time(1),
        ),
        throwsA(_failure('cloudkit_writer_transition_evidence_incomplete')),
      );

      final snapshot = authority(CloudKitWriterOwner.legacy)
          .provisionInitialOwner(
            _scopeA,
            owner: CloudKitWriterOwner.legacy,
            expectedEpoch: initial.epoch,
            evidence: _completeEvidence,
            now: _time(2),
          );
      expect(snapshot.owner, CloudKitWriterOwner.legacy);
      expect(snapshot.epoch, initial.epoch + 1);
    },
  );

  test('production authority transitions require the shared interlock', () {
    final production = ObjectBoxCloudKitWriterAuthority(store: store);
    final initial = production.initializeDisabled(_scopeA, now: _time(0));
    expect(
      () => production.provisionInitialOwner(
        _scopeA,
        owner: CloudKitWriterOwner.legacy,
        expectedEpoch: initial.epoch,
        evidence: _completeEvidence,
        now: _time(1),
      ),
      throwsA(
        isA<CloudKitOperationInterlockException>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_interlock_required',
        ),
      ),
    );
  });

  test('stable owner issues only matching epoch-bound permit', () {
    final snapshot = provision();
    final legacy = authority(CloudKitWriterOwner.legacy);
    final permit = legacy.issuePermit(
      _scopeA,
      expectedOwner: CloudKitWriterOwner.legacy,
    );
    expect(permit.owner, CloudKitWriterOwner.legacy);
    expect(permit.epoch, snapshot.epoch);
    expect(() => legacy.verifyPermit(permit), returnsNormally);
    expect(
      () => authority(
        CloudKitWriterOwner.v2,
      ).issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      throwsA(_failure('cloudkit_writer_owner_mismatch')),
    );
  });

  test(
    'ambiguous remote mutation durably revokes every writer permit',
    () async {
      provision();
      final legacy = authority(CloudKitWriterOwner.legacy);
      final permit = legacy.issuePermit(
        _scopeA,
        expectedOwner: CloudKitWriterOwner.legacy,
      );

      legacy.markMutationUnknown(permit, now: _time(2));
      expect(
        () => legacy.verifyPermit(permit),
        throwsA(_failure('cloudkit_writer_authority_not_stable')),
      );
      expect(
        store.box<CloudKitWriterAuthorityEntity>().getAll().single.state,
        4,
      );

      await reopen();
      final snapshot = authority(CloudKitWriterOwner.legacy).read(_scopeA)!;
      expect(snapshot.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(
        () => authority(
          CloudKitWriterOwner.legacy,
        ).issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.legacy),
        throwsA(_failure('cloudkit_writer_authority_not_stable')),
      );
    },
  );

  test('migration prepare revokes old permit and survives reopen', () async {
    final provisioned = provision();
    final legacy = authority(CloudKitWriterOwner.legacy);
    final oldPermit = legacy.issuePermit(
      _scopeA,
      expectedOwner: CloudKitWriterOwner.legacy,
    );
    final prepared = authority(CloudKitWriterOwner.v2).prepareMigration(
      _scopeA,
      from: CloudKitWriterOwner.legacy,
      to: CloudKitWriterOwner.v2,
      expectedEpoch: provisioned.epoch,
      transitionIdHash: _migrationId,
      evidence: _completeEvidence,
      now: _time(2),
    );
    expect(prepared.state, CloudKitWriterAuthorityState.migrationPrepared);
    expect(prepared.targetOwner, CloudKitWriterOwner.v2);
    expect(prepared.epoch, provisioned.epoch + 1);
    expect(
      () => legacy.verifyPermit(oldPermit),
      throwsA(_failure('cloudkit_writer_authority_not_stable')),
    );

    await reopen();
    final v2 = authority(CloudKitWriterOwner.v2);
    final reopened = v2.read(_scopeA)!;
    expect(reopened.state, CloudKitWriterAuthorityState.migrationPrepared);
    expect(reopened.targetOwner, CloudKitWriterOwner.v2);
    expect(
      () => v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      throwsA(_failure('cloudkit_writer_authority_not_stable')),
    );
  });

  test('migration commit switches owner and fences preparation epoch', () {
    final provisioned = provision();
    final v2 = authority(CloudKitWriterOwner.v2);
    final prepared = v2.prepareMigration(
      _scopeA,
      from: CloudKitWriterOwner.legacy,
      to: CloudKitWriterOwner.v2,
      expectedEpoch: provisioned.epoch,
      transitionIdHash: _migrationId,
      evidence: _completeEvidence,
      now: _time(2),
    );
    expect(
      () => v2.commitMigration(
        _scopeA,
        targetOwner: CloudKitWriterOwner.v2,
        expectedEpoch: provisioned.epoch,
        transitionIdHash: _migrationId,
        now: _time(3),
      ),
      throwsA(_failure('cloudkit_writer_migration_commit_precondition_failed')),
    );

    final committed = v2.commitMigration(
      _scopeA,
      targetOwner: CloudKitWriterOwner.v2,
      expectedEpoch: prepared.epoch,
      transitionIdHash: _migrationId,
      now: _time(3),
    );
    expect(committed.owner, CloudKitWriterOwner.v2);
    expect(committed.state, CloudKitWriterAuthorityState.stable);
    expect(committed.targetOwner, CloudKitWriterOwner.none);
    expect(committed.epoch, prepared.epoch + 1);
    expect(
      () => v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      returnsNormally,
    );
  });

  test('migration abort restores old owner with a new epoch', () {
    final provisioned = provision();
    final v2 = authority(CloudKitWriterOwner.v2);
    final prepared = v2.prepareMigration(
      _scopeA,
      from: CloudKitWriterOwner.legacy,
      to: CloudKitWriterOwner.v2,
      expectedEpoch: provisioned.epoch,
      transitionIdHash: _migrationId,
      evidence: _completeEvidence,
      now: _time(2),
    );
    final aborted = v2.abortMigration(
      _scopeA,
      targetOwner: CloudKitWriterOwner.v2,
      expectedEpoch: prepared.epoch,
      transitionIdHash: _migrationId,
      now: _time(3),
    );
    expect(aborted.owner, CloudKitWriterOwner.legacy);
    expect(aborted.state, CloudKitWriterAuthorityState.stable);
    expect(aborted.targetOwner, CloudKitWriterOwner.none);
    expect(aborted.epoch, prepared.epoch + 1);
    expect(
      () => v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      throwsA(_failure('cloudkit_writer_owner_mismatch')),
    );
  });

  test('reset preparation revokes permit and successful finish re-enables', () {
    provision(owner: CloudKitWriterOwner.v2);
    final v2 = authority(CloudKitWriterOwner.v2);
    final permit = v2.issuePermit(
      _scopeA,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    final fence = v2.prepareReset(
      permit,
      transitionIdHash: _resetId,
      now: _time(2),
    );
    expect(
      () => v2.verifyPermit(permit),
      throwsA(_failure('cloudkit_writer_authority_not_stable')),
    );
    final completed = v2.completeReset(fence, now: _time(3));
    expect(completed.state, CloudKitWriterAuthorityState.stable);
    expect(completed.owner, CloudKitWriterOwner.v2);
    expect(completed.epoch, fence.epoch + 1);
    expect(
      () => v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      returnsNormally,
    );
  });

  test(
    'unknown reset persists fail-closed until proven reconciliation',
    () async {
      provision(owner: CloudKitWriterOwner.v2);
      final v2 = authority(CloudKitWriterOwner.v2);
      final fence = v2.prepareReset(
        v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
        transitionIdHash: _resetId,
        now: _time(2),
      );
      final unknown = v2.markResetUnknown(fence, now: _time(3));
      expect(unknown.state, CloudKitWriterAuthorityState.resetUnknown);

      await reopen();
      final reopened = authority(CloudKitWriterOwner.v2);
      final recoveredFence = reopened.recoverResetFence(_scopeA)!;
      expect(recoveredFence.epoch, fence.epoch);
      expect(recoveredFence.transitionIdHash, _resetId);
      expect(
        () => reopened.issuePermit(
          _scopeA,
          expectedOwner: CloudKitWriterOwner.v2,
        ),
        throwsA(_failure('cloudkit_writer_authority_not_stable')),
      );
      expect(
        () => reopened.reconcileResetUnknown(
          recoveredFence,
          remoteStateReconciled: true,
          activeIdentityRevalidated: false,
          now: _time(4),
        ),
        throwsA(_failure('cloudkit_writer_reset_reconciliation_incomplete')),
      );
      final reconciled = reopened.reconcileResetUnknown(
        recoveredFence,
        remoteStateReconciled: true,
        activeIdentityRevalidated: true,
        now: _time(5),
      );
      expect(reconciled.state, CloudKitWriterAuthorityState.stable);
      expect(reconciled.epoch, recoveredFence.epoch + 1);
    },
  );

  test('authorities are isolated by complete account scope', () {
    provision(scope: _scopeA, owner: CloudKitWriterOwner.v2);
    initialize(scope: _scopeB);
    final v2 = authority(CloudKitWriterOwner.v2);
    expect(
      () => v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      returnsNormally,
    );
    expect(
      () => v2.issuePermit(_scopeB, expectedOwner: CloudKitWriterOwner.v2),
      throwsA(_failure('cloudkit_writer_owner_mismatch')),
    );
  });

  test('active account coordinator blocks every ownership transition', () {
    final provisioned = provision();
    store.box<CloudSyncLeaseEntity>().put(
      CloudSyncLeaseEntity(
        leaseKey: 'active-writer-transition-test',
        scopeKey: 'scope2:active-account-zone',
        accountFingerprint: _scopeA.accountFingerprint,
        ownerIdHash: 'owner-digest',
        generation: 1,
        acquiredAtMs: DateTime.now().millisecondsSinceEpoch,
        expiresAtMs: DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      ),
    );

    expect(
      () => authority(CloudKitWriterOwner.v2).prepareMigration(
        _scopeA,
        from: CloudKitWriterOwner.legacy,
        to: CloudKitWriterOwner.v2,
        expectedEpoch: provisioned.epoch,
        transitionIdHash: _migrationId,
        evidence: _completeEvidence,
        now: _time(2),
      ),
      throwsA(_failure('cloudkit_writer_transition_coordinator_active')),
    );
    expect(
      authority(CloudKitWriterOwner.legacy).read(_scopeA)?.epoch,
      provisioned.epoch,
    );
  });

  test('malformed epoch is rejected before any mutator changes the row', () {
    initialize();
    final box = store.box<CloudKitWriterAuthorityEntity>();
    final entity = box.getAll().single..epoch = 0;
    box.put(entity);

    expect(
      () => authority(CloudKitWriterOwner.legacy).provisionInitialOwner(
        _scopeA,
        owner: CloudKitWriterOwner.legacy,
        expectedEpoch: 0,
        evidence: _completeEvidence,
        now: _time(1),
      ),
      throwsA(_failure('cloudkit_writer_authority_epoch_invalid')),
    );
    final unchanged = box.get(entity.id)!;
    expect(unchanged.epoch, 0);
    expect(unchanged.owner, 0);
    expect(unchanged.state, 0);
  });

  test('persisted owner and state codes are explicit and transition-bound', () {
    final provisioned = provision();
    var entity = store.box<CloudKitWriterAuthorityEntity>().getAll().single;
    expect(entity.owner, 1);
    expect(entity.state, 0);
    expect(entity.targetOwner, 0);

    final v2 = authority(CloudKitWriterOwner.v2);
    final prepared = v2.prepareMigration(
      _scopeA,
      from: CloudKitWriterOwner.legacy,
      to: CloudKitWriterOwner.v2,
      expectedEpoch: provisioned.epoch,
      transitionIdHash: _migrationId,
      evidence: _completeEvidence,
      now: _time(2),
    );
    entity = store.box<CloudKitWriterAuthorityEntity>().get(entity.id)!;
    expect(entity.owner, 1);
    expect(entity.state, 1);
    expect(entity.targetOwner, 2);
    expect(entity.transitionIdHash, _migrationId);

    expect(
      () => authority(CloudKitWriterOwner.legacy).abortMigration(
        _scopeA,
        targetOwner: CloudKitWriterOwner.v2,
        expectedEpoch: prepared.epoch,
        transitionIdHash: _migrationId,
        now: _time(3),
      ),
      throwsA(_failure('cloudkit_writer_build_owner_mismatch')),
    );
    expect(
      v2.read(_scopeA)?.state,
      CloudKitWriterAuthorityState.migrationPrepared,
    );
  });

  test('malformed durable state and scope collisions fail closed', () {
    initialize();
    final box = store.box<CloudKitWriterAuthorityEntity>();
    final entity = box.getAll().single;
    entity.state = 999;
    box.put(entity);
    expect(
      () => authority(CloudKitWriterOwner.v2).read(_scopeA),
      throwsA(_failure('cloudkit_writer_authority_state_invalid')),
    );

    entity
      ..state = 0
      ..accountFingerprint = _scopeB.accountFingerprint;
    box.put(entity);
    expect(
      () => authority(CloudKitWriterOwner.v2).read(_scopeA),
      throwsA(_failure('cloudkit_writer_authority_scope_collision')),
    );
  });

  test('diagnostics never disclose account scope', () {
    final snapshot = provision(owner: CloudKitWriterOwner.v2);
    final permit = authority(
      CloudKitWriterOwner.v2,
    ).issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2);
    for (final value in <Object>[
      _scopeA,
      snapshot,
      permit,
      _completeEvidence,
    ]) {
      expect(value.toString(), isNot(contains(_scopeA.accountFingerprint)));
      expect(value.toString(), isNot(contains(_scopeA.container)));
    }
    const failure = CloudKitWriterAuthorityFailure('safe_code');
    expect(failure.toString(), 'CloudKitWriterAuthorityFailure(safe_code)');
  });

  test('scope validation rejects raw or malformed account identifiers', () {
    for (final fingerprint in <String>[
      '123456789',
      'person@example.com',
      '${_scopeA.accountFingerprint}x',
    ]) {
      expect(
        () => CloudKitWriterScope(accountFingerprint: fingerprint),
        throwsArgumentError,
      );
    }
    expect(
      () => CloudKitWriterScope(
        accountFingerprint: _scopeA.accountFingerprint,
        database: 'public',
      ),
      throwsArgumentError,
    );
  });
}

Matcher _failure(String safeCode) => isA<CloudKitWriterAuthorityFailure>()
    .having((value) => value.safeCode, 'safeCode', safeCode);

DateTime _time(int seconds) => DateTime.utc(2026, 8, 22, 12, 0, seconds);

const _completeEvidence = CloudKitWriterTransitionEvidence(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
const _migrationId =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _resetId =
    '2222222222222222222222222222222222222222222222222222222222222222';

final _scopeA = CloudKitWriterScope(
  accountFingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
);
final _scopeB = CloudKitWriterScope(
  accountFingerprint: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
);
