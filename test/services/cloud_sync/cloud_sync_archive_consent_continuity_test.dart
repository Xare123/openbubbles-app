// Regression tests for same-owner archive consent across N -> N+1 -> N+2.
// Per-operation authority still revokes permits; ownership consent is durable.
// Synthetic identities only. No native, Apple, network, or private data.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-archive-consent-continuity-',
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

  CloudKitWriterAuthoritySnapshot initialize() {
    return authority(
      CloudKitWriterOwner.none,
    ).initializeDisabled(_scopeA, now: _time(0));
  }

  CloudKitWriterAuthoritySnapshot provisionV2() {
    final initial = initialize();
    return authority(CloudKitWriterOwner.v2).provisionInitialOwner(
      _scopeA,
      owner: CloudKitWriterOwner.v2,
      expectedEpoch: initial.epoch,
      evidence: _completeEvidence,
      now: _time(1),
    );
  }

  // Preference harness bound to the authoritative snapshot. Every identity
  // capture and currency check reads automaticArchiveEpoch live.
  _ContinuityHarness harness() {
    int readArchiveEpoch() =>
        authority(
          CloudKitWriterOwner.v2,
        ).read(_scopeA)?.automaticArchiveEpoch ??
        0;
    return _ContinuityHarness(
      captureIdentity: () async => _identity(readArchiveEpoch()),
      currentOwnershipEpoch: readArchiveEpoch,
    );
  }

  test(
    'enable at stable N binds the stored grant to automaticArchiveEpoch',
    () async {
      final provisioned = provisionV2();
      expect(provisioned.ownershipEpoch, provisioned.epoch);
      expect(provisioned.automaticArchiveEpoch, provisioned.epoch);

      final prefsHarness = harness();
      final prefs = prefsHarness.prefs();
      final expected = await prefs.load();
      expect(expected.enabled, isFalse);

      final saved = await prefs.setEnabled(
        expected,
        true,
        acknowledgeQueuedUploads: true,
      );
      expect(saved.enabled, isTrue);
      expect(
        saved.identity.matchesBinding(
          accountFingerprint: _account,
          protectedStoreIdentity: _storeId,
          ownershipEpoch: provisioned.automaticArchiveEpoch,
        ),
        isTrue,
      );
      final decoded = jsonDecode(saved.storedValue! as String) as List;
      expect(decoded[2], provisioned.automaticArchiveEpoch);
      expect(prefs.isGranted(saved), isTrue);
    },
  );

  test(
    'mutationUnknown N+1 preserves opt-in while permits fail closed',
    () async {
      final provisioned = provisionV2();
      final prefsHarness = harness();
      final prefs = prefsHarness.prefs();
      final saved = await prefs.setEnabled(
        await prefs.load(),
        true,
        acknowledgeQueuedUploads: true,
      );
      expect(saved.enabled, isTrue);

      final v2 = authority(CloudKitWriterOwner.v2);
      final permit = v2.issuePermit(
        _scopeA,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      v2.markMutationUnknown(permit, now: _time(2));

      final unknown = v2.read(_scopeA)!;
      expect(unknown.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(unknown.epoch, provisioned.epoch + 1);
      expect(unknown.automaticArchiveEpoch, provisioned.automaticArchiveEpoch);

      final reloaded = await prefs.load();
      expect(reloaded.enabled, isTrue);
      expect(reloaded.storedValue, saved.storedValue);
      expect(prefs.isGranted(reloaded), isTrue);
      expect(
        () => v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
        throwsA(_failure('cloudkit_writer_authority_not_stable')),
      );
      expect(
        () => v2.verifyPermit(permit),
        throwsA(_failure('cloudkit_writer_authority_not_stable')),
      );
    },
  );

  test(
    'exact reconcile N+2 preserves the same grant; old permit is stale',
    () async {
      final provisioned = provisionV2();
      final prefsHarness = harness();
      final prefs = prefsHarness.prefs();
      final saved = await prefs.setEnabled(
        await prefs.load(),
        true,
        acknowledgeQueuedUploads: true,
      );
      final v2 = authority(CloudKitWriterOwner.v2);
      final permit = v2.issuePermit(
        _scopeA,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      v2.markMutationUnknown(permit, now: _time(2));

      final recovered = v2.reconcileMutationFence(
        _scopeA,
        owner: CloudKitWriterOwner.v2,
        fencedEpoch: provisioned.epoch,
        now: _time(3),
      );
      expect(recovered.state, CloudKitWriterAuthorityState.stable);
      expect(recovered.epoch, provisioned.epoch + 2);
      expect(
        recovered.automaticArchiveEpoch,
        provisioned.automaticArchiveEpoch,
      );
      expect(recovered.ownershipEpoch, provisioned.ownershipEpoch);

      final reloaded = await prefs.load();
      expect(reloaded.enabled, isTrue);
      expect(reloaded.storedValue, saved.storedValue);
      expect(prefsHarness.writes, 1);
      expect(prefs.isGranted(reloaded), isTrue);
      expect(
        () => v2.verifyPermit(permit),
        throwsA(_failure('cloudkit_writer_permit_stale')),
      );

      final replay = v2.reconcileMutationFence(
        _scopeA,
        owner: CloudKitWriterOwner.v2,
        fencedEpoch: provisioned.epoch,
        now: _time(4),
      );
      expect(replay.epoch, recovered.epoch);
      expect(replay.automaticArchiveEpoch, recovered.automaticArchiveEpoch);
      expect((await prefs.load()).storedValue, saved.storedValue);
    },
  );

  test('reopen persists the continuity epoch and grant', () async {
    final provisioned = provisionV2();
    final prefsHarness = harness();
    final prefs = prefsHarness.prefs();
    final saved = await prefs.setEnabled(
      await prefs.load(),
      true,
      acknowledgeQueuedUploads: true,
    );
    final v2 = authority(CloudKitWriterOwner.v2);
    final permit = v2.issuePermit(
      _scopeA,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    v2.markMutationUnknown(permit, now: _time(2));
    v2.reconcileMutationFence(
      _scopeA,
      owner: CloudKitWriterOwner.v2,
      fencedEpoch: provisioned.epoch,
      now: _time(3),
    );

    await reopen();

    final snapshot = authority(CloudKitWriterOwner.v2).read(_scopeA)!;
    expect(snapshot.state, CloudKitWriterAuthorityState.stable);
    expect(snapshot.automaticArchiveEpoch, provisioned.automaticArchiveEpoch);
    final reloaded = await prefs.load();
    expect(reloaded.enabled, isTrue);
    expect(reloaded.storedValue, saved.storedValue);
    expect(prefs.isGranted(reloaded), isTrue);
    expect(
      () => authority(
        CloudKitWriterOwner.v2,
      ).issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      returnsNormally,
    );
  });

  test('opt-out during unknown stays off with no auto-grant', () async {
    final provisioned = provisionV2();
    final prefsHarness = harness();
    final prefs = prefsHarness.prefs();
    final saved = await prefs.setEnabled(
      await prefs.load(),
      true,
      acknowledgeQueuedUploads: true,
    );
    final v2 = authority(CloudKitWriterOwner.v2);
    final permit = v2.issuePermit(
      _scopeA,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    v2.markMutationUnknown(permit, now: _time(2));

    final off = await prefs.setEnabled(
      await prefs.load(),
      false,
      acknowledgeQueuedUploads: false,
    );
    expect(off.enabled, isFalse);
    expect(prefsHarness.writes, 2);
    expect(
      jsonDecode(prefsHarness.values[off.identity.preferenceKey] as String),
      [1, 'off'],
    );
    expect(prefs.isGranted(saved), isFalse);

    v2.reconcileMutationFence(
      _scopeA,
      owner: CloudKitWriterOwner.v2,
      fencedEpoch: provisioned.epoch,
      now: _time(3),
    );
    final after = await prefs.load();
    expect(after.enabled, isFalse);
    expect(after.storedValue, off.storedValue);
    expect(prefsHarness.writes, 2);
  });

  test('reset finish revokes the pre-reset grant', () async {
    provisionV2();
    final prefsHarness = harness();
    final prefs = prefsHarness.prefs();
    final saved = await prefs.setEnabled(
      await prefs.load(),
      true,
      acknowledgeQueuedUploads: true,
    );
    final v2 = authority(CloudKitWriterOwner.v2);
    final fence = v2.prepareReset(
      v2.issuePermit(_scopeA, expectedOwner: CloudKitWriterOwner.v2),
      request: _resetRequest(),
      now: _time(2),
    );
    expect(v2.read(_scopeA)!.automaticArchiveEpoch, 0);
    final completed = v2.completeReset(
      fence,
      proof: _completionProof(),
      now: _time(3),
    );
    expect(completed.state, CloudKitWriterAuthorityState.stable);
    expect(completed.ownershipEpoch, completed.epoch);
    expect(completed.automaticArchiveEpoch, completed.epoch);
    expect(
      completed.automaticArchiveEpoch,
      isNot(saved.identity.ownershipEpoch),
    );
    final reloaded = await prefs.load();
    expect(reloaded.enabled, isFalse);
    expect(prefs.isGranted(saved), isFalse);
  });

  test(
    'migration prepare revokes; abort seeds a new epoch without resurrecting',
    () async {
      final provisioned = provisionV2();
      final prefsHarness = harness();
      final prefs = prefsHarness.prefs();
      final saved = await prefs.setEnabled(
        await prefs.load(),
        true,
        acknowledgeQueuedUploads: true,
      );

      final legacy = authority(CloudKitWriterOwner.legacy);
      final prepared = legacy.prepareMigration(
        _scopeA,
        from: CloudKitWriterOwner.v2,
        to: CloudKitWriterOwner.legacy,
        expectedEpoch: provisioned.epoch,
        transitionIdHash: _migrationId,
        evidence: _completeEvidence,
        now: _time(2),
      );
      expect(prepared.ownershipEpoch, prepared.epoch);
      expect(
        authority(CloudKitWriterOwner.v2).read(_scopeA)!.automaticArchiveEpoch,
        0,
      );
      expect((await prefs.load()).enabled, isFalse);

      final aborted = legacy.abortMigration(
        _scopeA,
        targetOwner: CloudKitWriterOwner.legacy,
        expectedEpoch: prepared.epoch,
        transitionIdHash: _migrationId,
        now: _time(3),
      );
      expect(aborted.state, CloudKitWriterAuthorityState.stable);
      expect(aborted.ownershipEpoch, aborted.epoch);
      expect(aborted.automaticArchiveEpoch, aborted.epoch);
      expect(
        aborted.automaticArchiveEpoch,
        isNot(saved.identity.ownershipEpoch),
      );
      final after = await prefs.load();
      expect(after.enabled, isFalse);
      expect(prefs.isGranted(saved), isFalse);
    },
  );

  test(
    'legacy V2 stable row with missing ownershipEpoch backfills exact epoch only',
    () async {
      final provisioned = provisionV2();
      final box = store.box<CloudKitWriterAuthorityEntity>();
      final entity = box.getAll().single..ownershipEpoch = 0;
      box.put(entity);

      final backfilled = authority(CloudKitWriterOwner.v2).read(_scopeA)!;
      expect(backfilled.ownershipEpoch, 0);
      expect(backfilled.automaticArchiveEpoch, backfilled.epoch);

      final v2 = authority(CloudKitWriterOwner.v2);
      final permit = v2.issuePermit(
        _scopeA,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      v2.markMutationUnknown(permit, now: _time(2));
      final unknown = v2.read(_scopeA)!;
      expect(unknown.ownershipEpoch, provisioned.epoch);
      expect(unknown.automaticArchiveEpoch, provisioned.epoch);
    },
  );

  test(
    'missing ownershipEpoch on unknown N+1 settles on N+2; stale N grant stays disabled',
    () async {
      final provisioned = provisionV2();
      final prefsHarness = harness();
      final prefs = prefsHarness.prefs();
      final saved = await prefs.setEnabled(
        await prefs.load(),
        true,
        acknowledgeQueuedUploads: true,
      );

      final box = store.box<CloudKitWriterAuthorityEntity>();
      final entity = box.getAll().single
        ..state = 4
        ..epoch = provisioned.epoch + 1
        ..ownershipEpoch = 0
        ..targetOwner = 0
        ..transitionIdHash = null;
      box.put(entity);

      final pre = authority(CloudKitWriterOwner.v2).read(_scopeA)!;
      expect(pre.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(pre.automaticArchiveEpoch, 0);
      expect((await prefs.load()).enabled, isFalse);

      final recovered = authority(CloudKitWriterOwner.v2)
          .reconcileMutationFence(
            _scopeA,
            owner: CloudKitWriterOwner.v2,
            fencedEpoch: provisioned.epoch,
            now: _time(3),
          );
      expect(recovered.epoch, provisioned.epoch + 2);
      expect(recovered.ownershipEpoch, provisioned.epoch + 2);
      expect(recovered.automaticArchiveEpoch, provisioned.epoch + 2);

      final reloaded = await prefs.load();
      expect(reloaded.enabled, isFalse);
      expect(prefs.isGranted(saved), isFalse);
    },
  );

  test(
    'already-advanced legacy stable row never inherits an older grant',
    () async {
      final provisioned = provisionV2();
      final prefsHarness = harness();
      final prefs = prefsHarness.prefs();
      final saved = await prefs.setEnabled(
        await prefs.load(),
        true,
        acknowledgeQueuedUploads: true,
      );
      final box = store.box<CloudKitWriterAuthorityEntity>();
      box.put(
        box.getAll().single
          ..epoch = provisioned.epoch + 2
          ..ownershipEpoch = 0,
      );
      expect((await prefs.load()).enabled, isFalse);
      expect(prefs.isGranted(saved), isFalse);
      final v2 = authority(CloudKitWriterOwner.v2);
      final permit = v2.issuePermit(
        _scopeA,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      v2.markMutationUnknown(permit, now: _time(2));
      v2.reconcileMutationFence(
        _scopeA,
        owner: CloudKitWriterOwner.v2,
        fencedEpoch: permit.epoch,
        now: _time(3),
      );
      expect(v2.read(_scopeA)!.automaticArchiveEpoch, permit.epoch);
      expect((await prefs.load()).enabled, isFalse);
      expect(prefs.isGranted(saved), isFalse);
      expect(prefsHarness.writes, 1);
    },
  );
}

final class _ContinuityHarness {
  _ContinuityHarness({
    required this.captureIdentity,
    required this.currentOwnershipEpoch,
  });

  final Future<CloudSyncAutomaticArchiveIdentity?> Function() captureIdentity;
  final int Function() currentOwnershipEpoch;
  final Map<String, Object?> values = {};
  int writes = 0;
  int prepares = 0;

  CloudSyncAutomaticArchivePreferences prefs() {
    return CloudSyncAutomaticArchivePreferences(
      captureIdentity: captureIdentity,
      currentOwnershipEpoch: currentOwnershipEpoch,
      stillCurrent: () => true,
      reload: () async {},
      read: (key) => values[key],
      write: (key, value) async {
        writes++;
        values[key] = value;
        return true;
      },
      prepareWriter: () async {
        prepares++;
      },
    );
  }
}

Matcher _failure(String safeCode) => isA<CloudKitWriterAuthorityFailure>()
    .having((value) => value.safeCode, 'safeCode', safeCode);

DateTime _time(int seconds) => DateTime.utc(2026, 8, 22, 12, 0, seconds);

const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);

const _migrationId =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _resetId =
    '2222222222222222222222222222222222222222222222222222222222222222';

final CloudKitWriterScope _scopeA = CloudKitWriterScope(
  accountFingerprint: 'A' * 43,
);

final _resetScopeA = CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: _scopeA.container,
  database: _scopeA.database,
  zone: 'message-zone',
);

const _resetProofReference =
    'obcs2.ref.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

CloudSyncResetRebootstrapRequest _resetRequest({int generation = 1}) =>
    CloudSyncResetRebootstrapRequest(
      scope: _resetScopeA,
      transitionIdHash: _resetId,
      activeIdentityFingerprint: _scopeA.accountFingerprint,
      expectedGeneration: generation,
      protectedRemoteStateProofReference: _resetProofReference,
    );

CloudSyncResetCompletionProof _completionProof({int generation = 2}) =>
    CloudSyncResetCompletionProof(
      scope: _resetScopeA,
      transitionIdHash: _resetId,
      activeIdentityFingerprint: _scopeA.accountFingerprint,
      previousGeneration: generation - 1,
      generation: generation,
      protectedRemoteStateProofReference: _resetProofReference,
    );

String get _account => 'A' * 43;
String get _storeId => 'obcs2.store.${'S' * 43}';

CloudSyncAutomaticArchiveIdentity _identity(int ownershipEpoch) =>
    CloudSyncAutomaticArchiveIdentity(
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      ownershipEpoch: ownershipEpoch,
    );
