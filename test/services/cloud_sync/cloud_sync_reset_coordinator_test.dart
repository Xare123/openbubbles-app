import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_reset_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _accountFingerprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _otherAccountFingerprint = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _proofReference = 'obcs2.ref.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _transitionId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late Directory directory;
  late Store objectBox;
  late Object nativeClient;
  late CloudSyncNativeAuthSnapshot activeAuth;
  late ObjectBoxCloudKitWriterAuthority authority;
  late InMemoryCloudSyncStore syncStore;
  late _RecordingInterlock interlock;
  late _RecordingPause pause;
  late _TestClock clock;
  late CloudSyncResetCoordinator coordinator;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloudkit-reset-coordinator-',
    );
    objectBox = await openStore(directory: directory.path);
    nativeClient = Object();
    activeAuth = _auth(client: nativeClient);
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: objectBox,
      buildDecision: const CloudKitWriterOwnershipDecision(
        owner: CloudKitWriterOwner.v2,
        configurationValid: true,
      ),
    );
    final writerScope = _writerScope();
    final initial = authority.initializeDisabled(
      writerScope,
      now: DateTime.utc(2026, 9, 9),
    );
    authority.provisionInitialOwner(
      writerScope,
      owner: CloudKitWriterOwner.v2,
      expectedEpoch: initial.epoch,
      evidence: const CloudKitWriterTransitionEvidence.forTest(
        operationsQuiesced: true,
        activeIdentityRevalidated: true,
        legacyMutationQueues: LegacyMutationQueueDisposition.empty,
      ),
      now: DateTime.utc(2026, 9, 9, 0, 0, 1),
    );
    syncStore = InMemoryCloudSyncStore();
    interlock = _RecordingInterlock();
    pause = _RecordingPause();
    clock = _TestClock();
    coordinator = CloudSyncResetCoordinator(
      authority: authority,
      interlock: interlock,
      store: syncStore,
      readAuthSnapshot: () async => activeAuth,
      readPreflight: () async => _readyState(),
      nativeWriterPause: pause,
      clock: clock.call,
    );
  });

  tearDown(() async {
    if (!objectBox.isClosed()) objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'authenticated reset advances once and returns writer authority',
    () async {
      final scope = _scope('messageManateeZone');

      await coordinator.coordinate(
        expectedAuth: activeAuth,
        context: CloudSyncResetRequiredContext(
          scope: scope,
          expectedGeneration: 1,
          protectedRemoteStateProofReference: _proofReference,
        ),
      );

      expect((await syncStore.readCheckpoint(scope)).generation, 2);
      expect(
        authority.read(_writerScope())?.state,
        CloudKitWriterAuthorityState.stable,
      );
      expect(authority.read(_writerScope())?.owner, CloudKitWriterOwner.v2);
      expect(
        objectBox
            .box<CloudKitWriterAuthorityEntity>()
            .getAll()
            .single
            .resetProofReference,
        isNull,
      );
      expect(interlock.kinds, [CloudKitOperationKind.destructiveReset]);
      expect(pause.pauseCalls, 1);
      expect(pause.resumeCalls, 1);
    },
  );

  test('stable authority recovery is a no-op without a native pause', () async {
    final recovered = await coordinator.recoverPending(
      expectedAuth: activeAuth,
      candidateScopes: _candidateScopes(),
    );

    expect(recovered, isFalse);
    expect(pause.pauseCalls, 0);
    expect(pause.resumeCalls, 0);
  });

  test('pending recovery requires the complete unique semantic zone set', () {
    expect(
      () => coordinator.recoverPending(
        expectedAuth: activeAuth,
        candidateScopes: [
          _scope('messageManateeZone'),
          _scope('messageManateeZone'),
          _scope('attachmentManateeZone'),
        ],
      ),
      throwsA(
        isA<CloudSyncResetCoordinatorFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_reset_recovery_scope_set_invalid',
        ),
      ),
    );
  });

  test('post-reset outbox fencing does not strand writer authority', () async {
    var preflightReads = 0;
    final resetCoordinator = CloudSyncResetCoordinator(
      authority: authority,
      interlock: interlock,
      store: syncStore,
      readAuthSnapshot: () async => activeAuth,
      readPreflight: () async {
        preflightReads++;
        return _readyState(
          outboxCount: 1,
          settledOutboxFingerprint: preflightReads <= 2
              ? 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
              : null,
        );
      },
      nativeWriterPause: pause,
      clock: clock.call,
    );

    await resetCoordinator.coordinate(
      expectedAuth: activeAuth,
      context: CloudSyncResetRequiredContext(
        scope: _scope('messageManateeZone'),
        expectedGeneration: 1,
        protectedRemoteStateProofReference: _proofReference,
      ),
    );

    expect(preflightReads, 3);
    expect(
      authority.read(_writerScope())?.state,
      CloudKitWriterAuthorityState.stable,
    );
  });

  test('pending reset recovers after local generation committed', () async {
    final scope = _scope('attachmentManateeZone');
    final request = _request(scope);
    authority.prepareReset(
      authority.issuePermit(
        _writerScope(),
        expectedOwner: CloudKitWriterOwner.v2,
      ),
      request: request,
      now: clock(),
    );
    await syncStore.rebootstrapAfterReset(request, now: clock());

    final recovered = await coordinator.recoverPending(
      expectedAuth: activeAuth,
      candidateScopes: _candidateScopes(),
    );

    expect(recovered, isTrue);
    expect((await syncStore.readCheckpoint(scope)).generation, 2);
    expect(
      authority.read(_writerScope())?.state,
      CloudKitWriterAuthorityState.stable,
    );
    expect(pause.pauseCalls, 1);
    expect(pause.resumeCalls, 1);
  });

  test(
    'unknown reset recovers by completing the missing local generation',
    () async {
      final scope = _scope('chatManateeZone');
      final fence = authority.prepareReset(
        authority.issuePermit(
          _writerScope(),
          expectedOwner: CloudKitWriterOwner.v2,
        ),
        request: _request(scope),
        now: clock(),
      );
      authority.markResetUnknown(fence, now: clock());

      final recovered = await coordinator.recoverPending(
        expectedAuth: activeAuth,
        candidateScopes: _candidateScopes(),
      );

      expect(recovered, isTrue);
      expect((await syncStore.readCheckpoint(scope)).generation, 2);
      expect(
        authority.read(_writerScope())?.state,
        CloudKitWriterAuthorityState.stable,
      );
    },
  );

  test(
    'account replacement fails before pause or generation mutation',
    () async {
      final scope = _scope('messageManateeZone');
      activeAuth = _auth(
        fingerprint: _otherAccountFingerprint,
        client: Object(),
      );

      await expectLater(
        coordinator.coordinate(
          expectedAuth: _auth(client: nativeClient),
          context: CloudSyncResetRequiredContext(
            scope: scope,
            expectedGeneration: 1,
            protectedRemoteStateProofReference: _proofReference,
          ),
        ),
        throwsA(
          isA<CloudSyncResetCoordinatorFailure>().having(
            (error) => error.safeCode,
            'safeCode',
            'cloud_sync_auth_account_changed',
          ),
        ),
      );
      expect((await syncStore.readCheckpoint(scope)).generation, 1);
      expect(pause.pauseCalls, 0);
    },
  );

  test('account replacement after pause leaves authority stable', () async {
    final scope = _scope('messageManateeZone');
    var authReads = 0;
    final resetCoordinator = CloudSyncResetCoordinator(
      authority: authority,
      interlock: interlock,
      store: syncStore,
      readAuthSnapshot: () async {
        authReads++;
        return authReads == 1
            ? activeAuth
            : _auth(fingerprint: _otherAccountFingerprint, client: Object());
      },
      readPreflight: () async => _readyState(),
      nativeWriterPause: pause,
      clock: clock.call,
    );

    await expectLater(
      resetCoordinator.coordinate(
        expectedAuth: activeAuth,
        context: CloudSyncResetRequiredContext(
          scope: scope,
          expectedGeneration: 1,
          protectedRemoteStateProofReference: _proofReference,
        ),
      ),
      throwsA(
        isA<CloudSyncResetCoordinatorFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloud_sync_auth_account_changed',
        ),
      ),
    );
    expect(authReads, 2);
    expect(pause.pauseCalls, 1);
    expect(pause.resumeCalls, 1);
    expect((await syncStore.readCheckpoint(scope)).generation, 1);
    expect(
      authority.read(_writerScope())?.state,
      CloudKitWriterAuthorityState.stable,
    );
  });

  test('unresolved generation remains fail-closed as reset unknown', () async {
    final scope = _scope('messageManateeZone');
    final fence = authority.prepareReset(
      authority.issuePermit(
        _writerScope(),
        expectedOwner: CloudKitWriterOwner.v2,
      ),
      request: _request(scope),
      now: clock(),
    );
    await syncStore.advanceOutboxGeneration(scope, now: clock());
    await syncStore.advanceOutboxGeneration(scope, now: clock());

    await expectLater(
      coordinator.recoverPending(
        expectedAuth: activeAuth,
        candidateScopes: _candidateScopes(),
      ),
      throwsA(
        isA<CloudSyncResetCoordinatorFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'cloudkit_reset_generation_unresolved',
        ),
      ),
    );
    expect(
      authority.read(fence.scope)?.state,
      CloudKitWriterAuthorityState.resetUnknown,
    );
  });

  test('native resume uncertainty poisons the reset interlock', () async {
    final scope = _scope('messageManateeZone');
    pause.resumeError = StateError('bridge-disconnected');

    await expectLater(
      coordinator.coordinate(
        expectedAuth: activeAuth,
        context: CloudSyncResetRequiredContext(
          scope: scope,
          expectedGeneration: 1,
          protectedRemoteStateProofReference: _proofReference,
        ),
      ),
      throwsA(isA<CloudSyncNativeWriterPauseUncertain>()),
    );
    expect(interlock.poisoned, isTrue);
    expect((await syncStore.readCheckpoint(scope)).generation, 2);
  });
}

CloudSyncNativeAuthSnapshot _auth({
  String fingerprint = _accountFingerprint,
  required Object client,
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: 'session-a',
  accountFingerprint: fingerprint,
  protectedStoreIdentity:
      'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  cloudMessagesClient: client,
);

CloudKitWriterScope _writerScope() => CloudKitWriterScope(
  accountFingerprint: _accountFingerprint,
  container: CloudSyncManualSemanticPullSampler.container,
  database: CloudSyncManualSemanticPullSampler.database,
);

CloudSyncScope _scope(String zone) => CloudSyncScope(
  accountFingerprint: _accountFingerprint,
  container: CloudSyncManualSemanticPullSampler.container,
  database: CloudSyncManualSemanticPullSampler.database,
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

List<CloudSyncScope> _candidateScopes() => [
  for (final zone in CloudSyncManualSemanticPullSampler.zones) _scope(zone),
];

CloudSyncResetRebootstrapRequest _request(CloudSyncScope scope) =>
    CloudSyncResetRebootstrapRequest(
      scope: scope,
      transitionIdHash: _transitionId,
      activeIdentityFingerprint: _accountFingerprint,
      expectedGeneration: 1,
      protectedRemoteStateProofReference: _proofReference,
    );

CloudSyncShadowPreflightState _readyState({
  int outboxCount = 0,
  String? settledOutboxFingerprint,
}) => CloudSyncShadowPreflightState(
  platformSupported: true,
  uiIsolate: true,
  rustPushReady: true,
  objectBoxReady: true,
  privateStorageExists: true,
  logoutActive: false,
  legacySyncEnabled: false,
  legacySyncActive: false,
  coordinatorLeaseActive: false,
  outboxCount: outboxCount,
  protectorSentinelValid: true,
  settledOutboxFingerprint: settledOutboxFingerprint,
);

final class _RecordingInterlock implements CloudKitOperationExclusion {
  final kinds = <CloudKitOperationKind>[];
  bool poisoned = false;

  @override
  Future<T> runExclusive<T>({
    required CloudKitOperationKind kind,
    required CloudKitOperationBody<T> action,
  }) async {
    kinds.add(kind);
    return action();
  }

  @override
  void poisonUntilProcessRestart() => poisoned = true;
}

final class _RecordingPause implements CloudSyncNativeWriterPause {
  int pauseCalls = 0;
  int resumeCalls = 0;
  Object? resumeError;

  @override
  Future<Object> pause() async {
    pauseCalls++;
    return Object();
  }

  @override
  Future<void> resume(Object token) async {
    resumeCalls++;
    final error = resumeError;
    if (error != null) throw error;
  }
}

final class _TestClock {
  var _offset = 2;

  DateTime call() => DateTime.utc(2026, 9, 9, 0, 0, _offset++);
}
