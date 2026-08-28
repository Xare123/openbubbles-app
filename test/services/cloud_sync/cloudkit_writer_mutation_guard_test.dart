import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late Object activeClient;
  late _FakeAuthBinding binding;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloudkit-writer-mutation-guard-',
    );
    store = await openStore(directory: directory.path);
    activeClient = Object();
    binding = _FakeAuthBinding();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  CloudKitWriterOwnershipDecision decision(CloudKitWriterOwner owner) =>
      CloudKitWriterOwnershipDecision(owner: owner, configurationValid: true);

  ObjectBoxCloudKitWriterAuthority authority(CloudKitWriterOwner owner) =>
      ObjectBoxCloudKitWriterAuthority.forTest(
        store: store,
        buildDecision: decision(owner),
      );

  void provision(CloudKitWriterOwner owner) {
    final adapter = authority(CloudKitWriterOwner.none);
    final initial = adapter.initializeDisabled(_scope, now: _time(0));
    authority(owner).provisionInitialOwner(
      _scope,
      owner: owner,
      expectedEpoch: initial.epoch,
      evidence: _completeEvidence,
      now: _time(1),
    );
  }

  CloudKitWriterMutationGuard guard({
    CloudKitWriterOwner owner = CloudKitWriterOwner.legacy,
    Object? Function()? reader,
  }) => CloudKitWriterMutationGuard.forTest(
    store: store,
    readActiveClient: reader ?? () => activeClient,
    privateStorageDirectory: 'protected-test-directory',
    nativeAuthBinding: binding,
    buildDecision: decision(owner),
  );

  Future<T> runGuard<T>({
    Object? Function()? reader,
    required Future<T> Function() action,
  }) {
    return CloudKitOperationInterlock(
      privateStorageDirectory: directory.path,
      fenceStore: InMemoryCloudSyncStore(),
    ).runExclusive(
      kind: CloudKitOperationKind.legacyReadWrite,
      action: () => guard(
        reader: reader,
      ).run(owner: CloudKitWriterOwner.legacy, action: action),
    );
  }

  test(
    'matching durable owner uses lookup-only auth and permits one mutation',
    () async {
      provision(CloudKitWriterOwner.legacy);
      var actionCalls = 0;
      final value = await runGuard(
        action: () async {
          actionCalls++;
          return 42;
        },
      );

      expect(value, 42);
      expect(actionCalls, 1);
      expect(binding.captureCalls, 2);
      expect(binding.warmCalls, 0);
    },
  );

  test(
    'mutation guard refuses to run outside the operation interlock',
    () async {
      provision(CloudKitWriterOwner.legacy);
      var actionCalls = 0;
      await expectLater(
        guard().run(
          owner: CloudKitWriterOwner.legacy,
          action: () async => actionCalls++,
        ),
        throwsA(
          isA<CloudKitOperationInterlockException>().having(
            (value) => value.safeCode,
            'safeCode',
            'cloudkit_interlock_required',
          ),
        ),
      );
      expect(actionCalls, 0);
      expect(binding.captureCalls, 0);
      expect(binding.warmCalls, 0);
    },
  );

  test('missing authority fails before invoking the remote action', () async {
    var actionCalls = 0;
    await expectLater(
      runGuard(action: () async => actionCalls++),
      throwsA(_failure('cloudkit_writer_authority_missing')),
    );
    expect(actionCalls, 0);
  });

  test('missing active client fails before native capture or action', () async {
    var actionCalls = 0;
    await expectLater(
      runGuard(reader: () => null, action: () async => actionCalls++),
      throwsA(_failure('cloudkit_writer_active_client_missing')),
    );
    expect(binding.captureCalls, 0);
    expect(binding.warmCalls, 0);
    expect(actionCalls, 0);
  });

  test('client replacement during initial capture blocks the action', () async {
    provision(CloudKitWriterOwner.legacy);
    var actionCalls = 0;
    binding.afterCapture = (call) {
      if (call == 1) activeClient = Object();
    };
    await expectLater(
      runGuard(action: () async => actionCalls++),
      throwsA(_failure('cloudkit_writer_identity_changed_before_mutation')),
    );
    expect(actionCalls, 0);
  });

  test('client replacement after action becomes an unknown outcome', () async {
    provision(CloudKitWriterOwner.legacy);
    await expectLater(
      runGuard(
        action: () async {
          activeClient = Object();
        },
      ),
      throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
    );
  });

  test('native identity replacement after action becomes unknown', () async {
    provision(CloudKitWriterOwner.legacy);
    binding.metadataForCall = (call) => call == 1
        ? _metadataA
        : const CloudSyncNativeAuthMetadata(
            nativeSessionId: _digestB,
            accountFingerprint: _fingerprintB,
            protectedStoreIdentity: 'obcs2.store.$_digestB',
          );
    await expectLater(
      runGuard(action: () async {}),
      throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
    );
  });

  test('authority epoch replacement after action becomes unknown', () async {
    provision(CloudKitWriterOwner.legacy);
    await expectLater(
      runGuard(
        action: () async {
          final current = authority(CloudKitWriterOwner.legacy).read(_scope)!;
          authority(CloudKitWriterOwner.v2).prepareMigration(
            _scope,
            from: CloudKitWriterOwner.legacy,
            to: CloudKitWriterOwner.v2,
            expectedEpoch: current.epoch,
            transitionIdHash: _migrationId,
            evidence: _completeEvidence,
            now: _time(2),
          );
        },
      ),
      throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
    );
  });

  test(
    'remote action failure revokes authority as an unknown outcome',
    () async {
      provision(CloudKitWriterOwner.legacy);
      await expectLater(
        runGuard(action: () async => throw StateError('remote_failed')),
        throwsA(_failure('cloudkit_writer_mutation_outcome_unknown')),
      );
      expect(binding.captureCalls, 1);
      expect(binding.warmCalls, 0);
      final snapshot = authority(CloudKitWriterOwner.legacy).read(_scope)!;
      expect(snapshot.state, CloudKitWriterAuthorityState.mutationUnknown);
      expect(
        () => authority(
          CloudKitWriterOwner.legacy,
        ).issuePermit(_scope, expectedOwner: CloudKitWriterOwner.legacy),
        throwsA(_failure('cloudkit_writer_authority_not_stable')),
      );
    },
  );
}

final class _FakeAuthBinding implements CloudSyncNativeAuthBinding {
  int captureCalls = 0;
  int warmCalls = 0;
  void Function(int call)? afterCapture;
  CloudSyncNativeAuthMetadata Function(int call)? metadataForCall;

  @override
  Future<void> warmReadAuthentication({
    required Object cloudMessagesClient,
  }) async {
    warmCalls++;
  }

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async {
    captureCalls++;
    final metadata = metadataForCall?.call(captureCalls) ?? _metadataA;
    afterCapture?.call(captureCalls);
    return metadata;
  }
}

Matcher _failure(String safeCode) => isA<CloudKitWriterAuthorityFailure>()
    .having((value) => value.safeCode, 'safeCode', safeCode);

DateTime _time(int seconds) => DateTime.utc(2026, 8, 22, 12, 0, seconds);

const _digestA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _digestB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _fingerprintB = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _metadataA = CloudSyncNativeAuthMetadata(
  nativeSessionId: _digestA,
  accountFingerprint: _digestA,
  protectedStoreIdentity: 'obcs2.store.$_digestA',
);
final _scope = CloudKitWriterScope(accountFingerprint: _digestA);
const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
const _migrationId =
    '3333333333333333333333333333333333333333333333333333333333333333';
