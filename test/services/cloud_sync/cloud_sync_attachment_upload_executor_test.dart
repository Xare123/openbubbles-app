// Bounded synthetic coverage for CloudSyncAttachmentUploadExecutor.
//
// Real disposable ObjectBox store plus the established local-send attachment
// fixtures prove journal ordering; native, guard, staging, and admission are
// scripted fakes with fault injection. No real accounts, files, or network.
import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_executor.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudSyncLocalSendJournal localSends;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncAttachmentUploadJournal uploads;
  late Chat chat;
  late _FakeBridge bridge;
  late _FakeGate gate;
  late _FakeStaging staging;
  late _FakeAdmitter admitter;
  late CloudSyncAttachmentUploadExecutor executor;
  late List<String> order;

  void provisionJournal() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final existing = authority.read(_writerScope);
    if (existing == null) {
      final disabled = authority.initializeDisabled(
        _writerScope,
        now: _time(0),
      );
      authority.provisionInitialOwner(
        _writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: _completeEvidence,
        now: _time(1),
      );
    }
    localSends = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(_writerScope)!,
    );
  }

  void seedCheckpoint(int generation) {
    final box = store.box<CloudSyncCheckpointEntity>();
    final key = cloudSyncPersistentScopeKey(_uploadScope);
    final query = box
        .query(CloudSyncCheckpointEntity_.checkpointKey.equals(key))
        .build();
    try {
      final existing = query.findUnique();
      if (existing != null) {
        existing
          ..generation = generation
          ..updatedAtMs = _time(0).millisecondsSinceEpoch;
        box.put(existing);
        return;
      }
    } finally {
      query.close();
    }
    box.put(
      CloudSyncCheckpointEntity(
        checkpointKey: key,
        accountFingerprint: _accountA,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'attachmentManateeZone',
        streamKind: 'messages',
        schemaVersion: 2,
        persistenceLane: 'semantic',
        generation: generation,
        updatedAtMs: _time(0).millisecondsSinceEpoch,
      ),
    );
  }

  void buildExecutor() {
    uploads = CloudSyncAttachmentUploadJournal(
      store: store,
      localSends: localSends,
      scope: _uploadScope,
      checkpointGeneration: 1,
      currentAuth: auth,
    );
    bridge = _FakeBridge(order: order);
    gate = _FakeGate(order: order);
    staging = _FakeStaging(order: order);
    admitter = _FakeAdmitter(order: order);
    executor = CloudSyncAttachmentUploadExecutor(
      uploads: uploads,
      readLiveAuth: () async => auth,
      mutationGate: gate,
      bridge: bridge,
      staging: staging,
      completedAdmitter: admitter,
      privateStorageDirectory: directory.path,
      clock: () => _time(20),
    );
  }

  setUp(() async {
    order = <String>[];
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-attachment-upload-executor-',
    );
    store = await openStore(directory: directory.path);
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
    auth = _auth(Object());
    seedCheckpoint(1);
    buildExecutor();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  CloudSyncAttachmentUploadExecutionInput _input(int uploadId, {Set<String>? retainedKeys}) =>
      CloudSyncAttachmentUploadExecutionInput(
        uploadId: uploadId,
        originalAttachmentGuid: 'LOCAL-ATTACHMENT-A',
        sourcePath: '/tmp/attachment-source.bin',
        requestTimeoutSeconds: BigInt.from(30),
        retainedSourceAttachmentKeys: retainedKeys,
      );

  CloudSyncAttachmentUploadExecutor _executorWithReader(
    Future<CloudSyncNativeAuthSnapshot?> Function() reader,
  ) => CloudSyncAttachmentUploadExecutor(
    uploads: uploads,
    readLiveAuth: reader,
    mutationGate: gate,
    bridge: bridge,
    staging: staging,
    completedAdmitter: admitter,
    privateStorageDirectory: directory.path,
    clock: () => _time(20),
  );

  int _seedPrepared() => uploads
      .adoptPlan(
        localSendIntentId: _seedConfirmedIntent(
          store: store,
          chat: chat,
          localSends: localSends,
          auth: auth,
        ),
        plan: _planA(),
        now: _time(6),
      )
      .id;
  test('retained first attempt uses original plan after authority recovery and reopen', () async {
    final id = _seedPrepared();
    final original = uploads.read(id);
    final originalEpoch = authority.read(_writerScope)!.epoch;
    final permit = authority.issuePermit(_writerScope, expectedOwner: CloudKitWriterOwner.v2);
    authority.markMutationUnknown(permit, now: _time(30));
    authority.reconcileMutationFence(_writerScope,
        owner: CloudKitWriterOwner.v2, fencedEpoch: originalEpoch, now: _time(31));
    store.close();
    store = await openStore(directory: directory.path);
    provisionJournal();
    auth = _auth(Object());
    buildExecutor();
    final result = await executor.execute(_input(id,
        retainedKeys: {original.plan.logicalEntityKeyHash}));
    expect(result.status, CloudAttachmentUploadExecutionStatus.completed);
    expect(bridge.prepareCalls, 1);
    expect(bridge.consumeCalls, 1);
    expect(uploads.read(id).plan.protectedEnvelopeReference,
        original.plan.protectedEnvelopeReference);
    expect(store.box<CloudAttachmentUploadEntity>().get(id)!.writerEpoch, originalEpoch);
    expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
  });

  test('retained inventory cannot authorize an ambiguous byte retry', () async {
    final id = _seedPrepared();
    uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
    bridge.recoverReturnsNull = true;
    final result = await executor.execute(_input(id,
        retainedKeys: {uploads.read(id).plan.logicalEntityKeyHash}));
    expect(result.status, CloudAttachmentUploadExecutionStatus.awaitingReceipt);
    expect(bridge.prepareCalls, 0);
    expect(bridge.consumeCalls, 0);
    expect(uploads.read(id).attemptId, _attemptA);
  });

  test(
    'fresh prepared upload completes in journal order exactly once',
    () async {
      final id = _seedPrepared();
      final execution = await executor.execute(_input(id));
      expect(execution.status, CloudAttachmentUploadExecutionStatus.completed);
      expect(execution.admittedOperationId, _initialOperation(_resultA()));
      expect(execution.receiptVerified, isTrue);
      expect(order, ['prepare', 'authorize', 'consume', 'commit', 'admit']);
      expect(bridge.prepareCalls, 1);
      expect(bridge.consumeCalls, 1);
      expect(bridge.disposeCalls, 1);
      expect(staging.commits, [(_lease('1'), _ref('F'))]);
      expect(admitter.admits, [id]);
      final snapshot = uploads.read(id);
      expect(snapshot.state, CloudAttachmentUploadState.adopted);
      expect(snapshot.result!.leaseReference, _lease('1'));
      // Gate saw the original native attempt binding, not a substitute.
      expect(gate.preparedBinding, bridge.preparedBinding);
      expect(gate.fenceBinding, uploads.reconciliationBindingSha256(id));
    },
  );

  test(
    'unknown consume outcome marks unknown without commit or admit',
    () async {
      final id = _seedPrepared();
      bridge.consumeDisposition =
          frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome;
      final execution = await executor.execute(_input(id));
      expect(
        execution.status,
        CloudAttachmentUploadExecutionStatus.unknownOutcome,
      );
      expect(uploads.read(id).state, CloudAttachmentUploadState.unknown);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
      expect(bridge.consumeCalls, 1);
      expect(bridge.disposeCalls, 1);
    },
  );

  test(
    'failed consume leaves the started row untouched for the parent',
    () async {
      final id = _seedPrepared();
      bridge
        ..consumeDisposition = frb_api.CloudSyncOutboundSaveDisposition.failed
        ..failureClass = frb_api.CloudSyncOutboundFailureClass.permanent;
      final execution = await executor.execute(_input(id));
      expect(execution.status, CloudAttachmentUploadExecutionStatus.failed);
      expect(
        execution.failureClass,
        frb_api.CloudSyncOutboundFailureClass.permanent,
      );
      expect(uploads.read(id).state, CloudAttachmentUploadState.started);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
    },
  );

  test('guard unknown failure marks unknown and disposes the handle', () async {
    final id = _seedPrepared();
    gate.throwOutcomeUnknown = true;
    final execution = await executor.execute(_input(id));
    expect(
      execution.status,
      CloudAttachmentUploadExecutionStatus.unknownOutcome,
    );
    expect(uploads.read(id).state, CloudAttachmentUploadState.unknown);
    expect(bridge.consumeCalls, 0);
    expect(bridge.disposeCalls, 1);
    expect(staging.commits, isEmpty);
  });

  test('prepare failure never begins an attempt', () async {
    final id = _seedPrepared();
    bridge.throwOnPrepare = true;
    await expectLater(executor.execute(_input(id)), throwsA(isA<StateError>()));
    final snapshot = uploads.read(id);
    expect(snapshot.state, CloudAttachmentUploadState.prepared);
    expect(snapshot.attemptId, isNull);
    expect(admitter.admits, isEmpty);
  });
  test(
    'started row recovers from exact receipt, never prepares again',
    () async {
      final id = _seedPrepared();
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      gate.reconcileResult = true;
      final execution = await executor.execute(_input(id));
      expect(
        execution.status,
        CloudAttachmentUploadExecutionStatus.recoveredAndCompleted,
      );
      expect(execution.admittedOperationId, _initialOperation(_resultA()));
      expect(bridge.prepareCalls, 0);
      expect(bridge.consumeCalls, 0);
      expect(bridge.recoverCalls, 1);
      expect(order, ['reconcile', 'recover', 'commit', 'admit']);
      expect(uploads.read(id).state, CloudAttachmentUploadState.adopted);
    },
  );

  test(
    'started row with missing receipt waits without journal change',
    () async {
      final id = _seedPrepared();
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      gate.reconcileResult = false;
      final execution = await executor.execute(_input(id));
      expect(
        execution.status,
        CloudAttachmentUploadExecutionStatus.awaitingReceipt,
      );
      expect(execution.receiptVerified, isFalse);
      expect(uploads.read(id).state, CloudAttachmentUploadState.started);
      expect(bridge.prepareCalls, 0);
      expect(bridge.recoverCalls, 0);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
    },
  );

  test(
    'uploaded row reuses its result lease and verifies without restage',
    () async {
      final id = _seedPrepared();
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      uploads.recordUploaded(
        id: id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(8),
      );
      gate.reconcileResult = true;
      final execution = await executor.execute(_input(id));
      expect(execution.status, CloudAttachmentUploadExecutionStatus.completed);
      expect(bridge.prepareCalls, 0);
      expect(bridge.consumeCalls, 0);
      expect(bridge.recoverCalls, 0);
      expect(gate.reconcileCalls, 1);
      expect(staging.commits, [(_lease('1'), _ref('F'))]);
      expect(admitter.admits, [id]);
      expect(uploads.read(id).state, CloudAttachmentUploadState.adopted);
    },
  );

  test('adopted row is idempotent and never recommits or restages', () async {
    final id = _seedPrepared();
    final first = await executor.execute(_input(id));
    expect(first.status, CloudAttachmentUploadExecutionStatus.completed);
    order.clear();
    bridge.prepareCalls = 0;
    gate.reconcileCalls = 0;
    gate.reconcileResult = true;
    final second = await executor.execute(_input(id));
    expect(
      second.status,
      CloudAttachmentUploadExecutionStatus.alreadyCompleted,
    );
    expect(second.admittedOperationId, first.admittedOperationId);
    expect(bridge.prepareCalls, 0);
    expect(bridge.consumeCalls, 1);
    expect(bridge.recoverCalls, 0);
    expect(staging.commits, hasLength(1));
    expect(admitter.admits, hasLength(1));
    expect(order, ['reconcile']);
  });

  test('concurrent double call fails the second caller closed', () async {
    final id = _seedPrepared();
    final release = Completer<void>();
    gate.blockInAuthorize = release.future;
    final first = executor.execute(_input(id));
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      executor.execute(_input(id)),
      throwsA(_stateFailure('cloud_sync_attachment_upload_executor_busy')),
    );
    release.complete();
    final execution = await first;
    expect(execution.status, CloudAttachmentUploadExecutionStatus.completed);
    expect(bridge.consumeCalls, 1);
  });
  test(
    'auth drift after prepare fails closed and keeps the plan prepared',
    () async {
      final id = _seedPrepared();
      bridge.onPrepare = () {
        auth = _auth(Object());
      };
      await expectLater(
        executor.execute(_input(id)),
        throwsA(_stateFailure('cloud_sync_attachment_upload_auth_changed')),
      );
      final snapshot = uploads.read(id);
      expect(snapshot.state, CloudAttachmentUploadState.prepared);
      expect(snapshot.attemptId, isNull);
      expect(bridge.consumeCalls, 0);
      expect(bridge.disposeCalls, 1);
      expect(admitter.admits, isEmpty);
    },
  );

  test('unknown attempt completes after a process restart', () async {
    final id = _seedPrepared();
    bridge.consumeDisposition =
        frb_api.CloudSyncOutboundSaveDisposition.unknownOutcome;
    final first = await executor.execute(_input(id));
    expect(first.status, CloudAttachmentUploadExecutionStatus.unknownOutcome);
    store.close();
    store = await openStore(directory: directory.path);
    provisionJournal();
    auth = _auth(Object());
    seedCheckpoint(1);
    buildExecutor();
    gate.reconcileResult = true;
    final second = await executor.execute(_input(id));
    expect(
      second.status,
      CloudAttachmentUploadExecutionStatus.recoveredAndCompleted,
    );
    expect(second.admittedOperationId, _initialOperation(_resultA()));
    expect(bridge.prepareCalls, 0);
    expect(uploads.read(id).state, CloudAttachmentUploadState.adopted);
  });

  test(
    'mismatched native attempt marks the fence unknown inside action',
    () async {
      final id = _seedPrepared();
      bridge.consumeAttemptOverride = _attemptB;
      final execution = await executor.execute(_input(id));
      expect(
        execution.status,
        CloudAttachmentUploadExecutionStatus.unknownOutcome,
      );
      expect(gate.markCalled, isTrue);
      expect(uploads.read(id).state, CloudAttachmentUploadState.unknown);
      expect(uploads.read(id).attemptId, bridge.preparedAttemptId);
      expect(staging.commits, isEmpty);
      expect(staging.rollbacks, isEmpty);
      expect(admitter.admits, isEmpty);
      expect(bridge.disposeCalls, 1);
    },
  );

  test('succeeded consume without a stage never clears the fence', () async {
    final id = _seedPrepared();
    bridge.consumeStageNull = true;
    final execution = await executor.execute(_input(id));
    expect(
      execution.status,
      CloudAttachmentUploadExecutionStatus.unknownOutcome,
    );
    expect(gate.markCalled, isTrue);
    expect(uploads.read(id).state, CloudAttachmentUploadState.unknown);
    expect(staging.commits, isEmpty);
    expect(admitter.admits, isEmpty);
  });

  test(
    'drift after consume rolls back only the proven-unadopted lease',
    () async {
      final id = _seedPrepared();
      bridge.onConsume = () {
        auth = _auth(Object());
      };
      await expectLater(
        executor.execute(_input(id)),
        throwsA(_stateFailure('cloud_sync_attachment_upload_auth_changed')),
      );
      expect(staging.rollbacks, [_lease('1')]);
      expect(uploads.read(id).state, CloudAttachmentUploadState.started);
      expect(uploads.read(id).result, isNull);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
      expect(bridge.disposeCalls, 1);
    },
  );

  test('drift after commit never rolls back the recorded lease', () async {
    final id = _seedPrepared();
    staging.onCommit = () {
      auth = _auth(Object());
    };
    await expectLater(
      executor.execute(_input(id)),
      throwsA(_stateFailure('cloud_sync_attachment_upload_auth_changed')),
    );
    expect(staging.rollbacks, isEmpty);
    expect(staging.commits, [(_lease('1'), _ref('F'))]);
    final snapshot = uploads.read(id);
    expect(snapshot.state, CloudAttachmentUploadState.uploaded);
    expect(snapshot.result!.leaseReference, _lease('1'));
    expect(admitter.admits, isEmpty);
  });

  test('adopted row without verification is never called completed', () async {
    final id = _seedPrepared();
    final first = await executor.execute(_input(id));
    expect(first.status, CloudAttachmentUploadExecutionStatus.completed);
    gate.reconcileResult = false;
    final second = await executor.execute(_input(id));
    expect(second.status, CloudAttachmentUploadExecutionStatus.awaitingReceipt);
    expect(second.receiptVerified, isFalse);
    expect(staging.commits, hasLength(1));
    expect(admitter.admits, hasLength(1));
    expect(bridge.prepareCalls, 1);
    expect(bridge.consumeCalls, 1);
    expect(bridge.recoverCalls, 0);
    expect(uploads.read(id).state, CloudAttachmentUploadState.adopted);
    expect(uploads.read(id).admittedOperationId, first.admittedOperationId);
  });

  test(
    'uploaded row without verification waits instead of admitting',
    () async {
      final id = _seedPrepared();
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      uploads.recordUploaded(
        id: id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(8),
      );
      gate.reconcileResult = false;
      final execution = await executor.execute(_input(id));
      expect(
        execution.status,
        CloudAttachmentUploadExecutionStatus.awaitingReceipt,
      );
      expect(uploads.read(id).state, CloudAttachmentUploadState.uploaded);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
      expect(bridge.prepareCalls, 0);
    },
  );

  test('recovery path never requires local origin inputs', () async {
    final id = _seedPrepared();
    uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
    gate.reconcileResult = true;
    final execution = await executor.execute(
      CloudSyncAttachmentUploadExecutionInput(
        uploadId: id,
        originalAttachmentGuid: '',
        sourcePath: '',
        requestTimeoutSeconds: BigInt.from(30),
      ),
    );
    expect(
      execution.status,
      CloudAttachmentUploadExecutionStatus.recoveredAndCompleted,
    );
    expect(bridge.prepareCalls, 0);
  });

  test(
    'changed durable plan after prepare cannot authorize old bytes',
    () async {
      final id = _seedPrepared();
      bridge.onPrepare = () {
        final box = store.box<CloudAttachmentUploadEntity>();
        box.put(box.get(id)!..planLeaseReference = _lease('9'));
      };
      await expectLater(
        executor.execute(_input(id)),
        throwsA(_stateFailure('cloud_sync_attachment_upload_plan_changed')),
      );
      final snapshot = uploads.read(id);
      expect(snapshot.state, CloudAttachmentUploadState.prepared);
      expect(snapshot.attemptId, isNull);
      expect(bridge.consumeCalls, 0);
      expect(bridge.disposeCalls, 1);
      expect(admitter.admits, isEmpty);
    },
  );

  test(
    'recovered stage is released when auth capture fails after recover',
    () async {
      final id = _seedPrepared();
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      gate.reconcileResult = true;
      final strict = _executorWithReader(
        () async => bridge.recoverCalls > 0 ? null : auth,
      );
      await expectLater(
        strict.execute(_input(id)),
        throwsA(_stateFailure('cloud_sync_attachment_upload_auth_changed')),
      );
      expect(staging.rollbacks, [_lease('1')]);
      expect(uploads.read(id).state, CloudAttachmentUploadState.started);
      expect(uploads.read(id).result, isNull);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
    },
  );

  test('malformed success stage identity marks the fence unknown', () async {
    final id = _seedPrepared();
    bridge.corruptStageIdentity = true;
    final execution = await executor.execute(_input(id));
    expect(
      execution.status,
      CloudAttachmentUploadExecutionStatus.unknownOutcome,
    );
    expect(gate.markCalled, isTrue);
    expect(uploads.read(id).state, CloudAttachmentUploadState.unknown);
    expect(staging.commits, isEmpty);
    expect(staging.rollbacks, isEmpty);
    expect(admitter.admits, isEmpty);
    expect(bridge.disposeCalls, 1);
  });

  test(
    'missing-receipt arrival with drifted auth throws instead of waiting',
    () async {
      final id = _seedPrepared();
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      gate.reconcileResult = false;
      final strict = _executorWithReader(
        () async => gate.reconcileCalls > 0 ? _auth(Object()) : auth,
      );
      await expectLater(
        strict.execute(_input(id)),
        throwsA(_stateFailure('cloud_sync_attachment_upload_auth_changed')),
      );
      expect(uploads.read(id).state, CloudAttachmentUploadState.started);
      expect(bridge.recoverCalls, 0);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
    },
  );

  test(
    'null-recovery arrival with drifted auth throws instead of waiting',
    () async {
      final id = _seedPrepared();
      uploads.beginAttempt(id: id, attemptId: _attemptA, now: _time(7));
      gate.reconcileResult = true;
      bridge.recoverReturnsNull = true;
      final strict = _executorWithReader(
        () async => bridge.recoverCalls > 0 ? _auth(Object()) : auth,
      );
      await expectLater(
        strict.execute(_input(id)),
        throwsA(_stateFailure('cloud_sync_attachment_upload_auth_changed')),
      );
      expect(uploads.read(id).state, CloudAttachmentUploadState.started);
      expect(staging.commits, isEmpty);
      expect(admitter.admits, isEmpty);
    },
  );

  test('fresh timeout outside 1..300 never reaches native prepare', () async {
    final id = _seedPrepared();
    for (final timeout in [BigInt.zero, BigInt.from(301)]) {
      await expectLater(
        executor.execute(
          CloudSyncAttachmentUploadExecutionInput(
            uploadId: id,
            originalAttachmentGuid: 'LOCAL-ATTACHMENT-A',
            sourcePath: '/tmp/attachment-source.bin',
            requestTimeoutSeconds: timeout,
          ),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_input_invalid')),
      );
    }
    expect(bridge.prepareCalls, 0);
    expect(uploads.read(id).state, CloudAttachmentUploadState.prepared);
  });

  test('null auth after consume releases the newly staged result', () async {
    final id = _seedPrepared();
    final strict = _executorWithReader(
      () async => bridge.consumeCalls > 0 ? null : auth,
    );
    await expectLater(
      strict.execute(_input(id)),
      throwsA(_stateFailure('cloud_sync_attachment_upload_auth_changed')),
    );
    expect(staging.rollbacks, [_lease('1')]);
    expect(uploads.read(id).state, CloudAttachmentUploadState.started);
    expect(uploads.read(id).result, isNull);
    expect(staging.commits, isEmpty);
    expect(admitter.admits, isEmpty);
    expect(bridge.disposeCalls, 1);
  });

  test('throwing auth reader still releases and keeps the original', () async {
    final id = _seedPrepared();
    final strict = _executorWithReader(() async {
      if (bridge.consumeCalls > 0) {
        throw const CloudKitWriterAuthorityFailure('synthetic_auth_fault');
      }
      return auth;
    });
    await expectLater(
      strict.execute(_input(id)),
      throwsA(
        isA<CloudKitWriterAuthorityFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'synthetic_auth_fault',
        ),
      ),
    );
    expect(staging.rollbacks, [_lease('1')]);
    expect(uploads.read(id).state, CloudAttachmentUploadState.started);
    expect(uploads.read(id).result, isNull);
    expect(staging.commits, isEmpty);
    expect(admitter.admits, isEmpty);
  });
}

final class _FakePreparedUpload implements CloudSyncPreparedUpload {
  _FakePreparedUpload(this._bridge, this.attemptId, this.bindingSha256);

  final _FakeBridge _bridge;
  final String attemptId;
  final String bindingSha256;
  bool disposed = false;

  @override
  String get handleBindingSha256 => bindingSha256;

  @override
  String get uploadAttemptId => attemptId;

  @override
  Future<frb_api.CloudSyncAttachmentUploadConsumeResult> consume(
    String capabilityToken,
  ) async {
    _bridge.consumeCalls++;
    _bridge.order.add('consume');
    expect(capabilityToken, isNotEmpty);
    final fault = _bridge.throwOnConsume;
    if (fault != null) throw fault;
    _bridge.onConsume?.call();
    final attempt = _bridge.consumeAttemptOverride ?? attemptId;
    final base = _bridge.corruptStageIdentity ? _resultCorrupt() : _resultA();
    final stage =
        _bridge.consumeDisposition ==
                frb_api.CloudSyncOutboundSaveDisposition.succeeded &&
            !_bridge.consumeStageNull
        ? _frbStage(base)
        : null;
    return frb_api.CloudSyncAttachmentUploadConsumeResult(
      uploadAttemptId: attempt,
      disposition: _bridge.consumeDisposition,
      stage: stage,
      failureClass: _bridge.failureClass,
      retryAfterSeconds: _bridge.retryAfterSeconds,
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _bridge.disposeCalls++;
  }
}

final class _FakeBridge implements CloudSyncAttachmentUploadBridge {
  _FakeBridge({required this.order});

  final List<String> order;
  int prepareCalls = 0;
  int consumeCalls = 0;
  int disposeCalls = 0;
  int recoverCalls = 0;
  bool throwOnPrepare = false;
  Object? throwOnConsume;
  String preparedAttemptId = _attemptA;
  String preparedBinding = _digest('1');
  frb_api.CloudSyncOutboundSaveDisposition consumeDisposition =
      frb_api.CloudSyncOutboundSaveDisposition.succeeded;
  frb_api.CloudSyncOutboundFailureClass? failureClass;
  BigInt? retryAfterSeconds;
  bool recoverReturnsNull = false;
  void Function()? onPrepare;
  void Function()? onConsume;
  String? consumeAttemptOverride;
  bool consumeStageNull = false;
  bool corruptStageIdentity = false;

  @override
  Future<CloudSyncPreparedUpload> prepare({
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
    required String originalAttachmentGuid,
    required String sourcePath,
    required BigInt requestTimeoutSeconds,
  }) async {
    prepareCalls++;
    order.add('prepare');
    expect(planStage.payloadSha256, _planA().payloadSha256);
    onPrepare?.call();
    if (throwOnPrepare) throw StateError('synthetic_prepare_fault');
    return _FakePreparedUpload(this, preparedAttemptId, preparedBinding);
  }

  @override
  Future<frb_api.CloudSyncProtectedOutboundStage?> recover({
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
  }) async {
    recoverCalls++;
    order.add('recover');
    if (recoverReturnsNull) return null;
    return _frbStage(_resultA());
  }
}

final class _FakeGate implements CloudSyncAttachmentUploadMutationGate {
  _FakeGate({required this.order});

  final List<String> order;
  int reconcileCalls = 0;
  bool reconcileResult = false;
  bool throwOutcomeUnknown = false;
  Future<void>? blockInAuthorize;
  String? preparedBinding;
  String? fenceBinding;
  bool markCalled = false;
  bool _marked = false;

  @override
  Future<T> runAuthorized<T>({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    String? expectedAccountFingerprint,
    required String? preparedHandleBindingSha256,
    String? reconciliationBindingSha256,
    required void Function() requireAdmission,
    required Future<void> Function() requireDurableAdmission,
    required Future<T> Function(String capabilityToken) action,
  }) async {
    order.add('authorize');
    expect(owner, CloudKitWriterOwner.v2);
    expect(expectedAccountFingerprint, _accountA);
    preparedBinding = preparedHandleBindingSha256;
    fenceBinding = reconciliationBindingSha256;
    requireAdmission();
    await requireDurableAdmission();
    final block = blockInAuthorize;
    if (block != null) await block;
    if (throwOutcomeUnknown) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_outcome_unknown',
      );
    }
    // Mimic the real guard: once marked inside the action, the fence can
    // only resolve as outcome-unknown, whatever the action threw or
    // returned.
    try {
      final value = await action('fake-capability-token');
      if (_marked) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_outcome_unknown',
        );
      }
      return value;
    } catch (error) {
      if (error is CloudKitWriterAuthorityFailure) rethrow;
      if (_marked) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_outcome_unknown',
        );
      }
      rethrow;
    } finally {
      _marked = false;
    }
  }

  @override
  void markActiveMutationUnknown() {
    markCalled = true;
    _marked = true;
  }

  @override
  Future<bool> reconcileAttachmentUpload({
    required Object expectedClient,
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
  }) async {
    reconcileCalls++;
    order.add('reconcile');
    return reconcileResult;
  }
}

final class _FakeStaging implements CloudSyncOutboundStagingTransport {
  _FakeStaging({required this.order});

  final List<String> order;
  final List<(String, String)> commits = [];
  final List<String> rollbacks = [];
  void Function()? onCommit;

  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      action();

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  }) => throw UnimplementedError();

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) async {
    order.add('commit');
    commits.add((leaseReference, protectedEnvelopeReference));
    onCommit?.call();
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
    order.add('rollback');
    rollbacks.add(leaseReference);
  }
}

final class _FakeAdmitter implements CloudSyncCompletedUploadAdmitter {
  _FakeAdmitter({required this.order});

  final List<String> order;
  final List<int> admits = [];

  @override
  CloudAttachmentUploadSnapshot admitCompletedAttachmentUpload({
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
    required DateTime createdAt,
  }) {
    order.add('admit');
    admits.add(uploadId);
    return uploads.adoptRecordCreate(
      id: uploadId,
      admit: (tx, result) {
        _persistFinalOperation(tx, result);
        return _finalOperation(result);
      },
      now: createdAt,
    );
  }
}

int _seedConfirmedIntent({
  // fixture scope
  required Store store,
  required Chat chat,
  required CloudSyncLocalSendJournal localSends,
  required CloudSyncNativeAuthSnapshot auth,
}) {
  final attachment = Attachment(
    guid: 'LOCAL-ATTACHMENT-A',
    metadata: const {'rustpush': '<attachment><id>A</id></attachment>'},
  );
  store.box<Attachment>().put(attachment);
  final message = _attachmentMessage(
    stableGuid: _guidA,
    attachmentGuid: 'LOCAL-ATTACHMENT-A',
  );
  message.chat.target = chat;
  message.dbAttachments.add(attachment);
  final identity = CloudSyncLocalSendIdentity.captureAttachment(
    message,
    chat,
    _guidA,
  )!;
  localSends.saveSubmission(
    identity: identity,
    newlyGeneratedGuid: true,
    persistMessage: () => store.box<Message>().put(message),
    now: _time(2),
  );
  final source = CloudSyncLocalSendSourceBinding(
    accountFingerprint: _accountA,
    protectedStoreIdentity: _storeA,
    messageGuidHash: identity.guidHash,
    sourceSha256: identity.sourceSha256,
    protectedReference: _ref('A'),
    leaseReference: _lease('a'),
    payloadSha256: _digest('b'),
    payloadLength: 512,
  );
  localSends.adoptProtectedSource(
    identity: identity,
    source: source,
    capturedAuth: auth,
    stillCurrent: () => true,
    now: _time(3),
  );
  attachment.guid = '${_guidA}_0';
  store.box<Attachment>().put(attachment);
  message
    ..guid = _guidA
    ..stagingGuid = null
    ..text = ' '
    ..attributedBody = [
      AttributedBody(
        string: ' ',
        runs: [
          Run(
            range: const [0, 1],
            attributes: Attributes(
              messagePart: 0,
              attachmentGuid: attachment.guid,
            ),
          ),
        ],
      ),
    ];
  store.box<Message>().put(message);
  final intentId = localSends.recordNativeSendConfirmation(
    stableGuid: _guidA,
    succeeded: true,
    capturedAuth: auth,
    stillCurrent: () => true,
    now: _time(4),
    protectedSource: source,
  )!;
  localSends.promoteIdsConfirmedDeferred(
    intentId: intentId,
    currentAuth: auth,
    now: _time(5),
  );
  return intentId;
}

Message _attachmentMessage({
  required String stableGuid,
  required String attachmentGuid,
}) {
  return Message(
    guid: 'local-$stableGuid',
    text: ' ',
    dateCreated: _time(1),
    isFromMe: true,
    hasAttachments: true,
    attributedBody: [
      AttributedBody(
        string: ' ',
        runs: [
          Run(
            range: const [0, 1],
            attributes: Attributes(attachmentGuid: attachmentGuid),
          ),
        ],
      ),
    ],
    stagingGuid: stableGuid,
  );
}

Chat _chat() {
  final handle = Handle(
    address: 'person@example.com',
    service: 'iMessage',
    uniqueAddressAndService: 'person@example.com/iMessage',
  );
  final chat = Chat(
    guid: 'iMessage;-;person@example.com',
    chatIdentifier: 'person@example.com',
    usingHandle: 'me@example.com',
    isRpSms: false,
    style: 45,
    participants: [handle],
  );
  chat.handles.addAll([handle]);
  return chat;
}

void _persistChat(Store store, Chat chat) {
  store.box<Handle>().putMany(chat.handles.toList());
  store.box<Chat>().put(chat);
}

CloudSyncNativeAuthSnapshot _auth(Object client) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'native-session',
      accountFingerprint: _accountA,
      protectedStoreIdentity: _storeA,
      cloudMessagesClient: client,
    );

frb_api.CloudSyncProtectedOutboundStage _frbStage(
  CloudSyncProtectedOutboundStageData data,
) => frb_api.CloudSyncProtectedOutboundStage(
  logicalEntityKeyHash: data.logicalEntityKeyHash,
  protectedPayloadReference: data.protectedEnvelopeReference,
  payloadSha256: data.payloadSha256,
  payloadLength: BigInt.from(8),
  protectedServerRecordReference: data.protectedEnvelopeReference,
  serverRecordIdHash: data.serverRecordIdHash,
  leaseReference: data.leaseReference,
);

CloudSyncProtectedOutboundStageData _planA() =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('C'),
      protectedEnvelopeReference: _ref('E'),
      payloadSha256: _digest('c'),
      serverRecordIdHash: _token('D'),
      leaseReference: _lease('d'),
    );

CloudSyncProtectedOutboundStageData _resultCorrupt() =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('Z'),
      protectedEnvelopeReference: _ref('F'),
      payloadSha256: _digest('e'),
      serverRecordIdHash: _token('D'),
      leaseReference: _lease('1'),
    );

CloudSyncProtectedOutboundStageData _resultA() =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('C'),
      protectedEnvelopeReference: _ref('F'),
      payloadSha256: _digest('e'),
      serverRecordIdHash: _token('D'),
      leaseReference: _lease('1'),
    );

CloudOutboxOperation _finalOperation(
  CloudSyncProtectedOutboundStageData result,
) => CloudOutboxOperation(
  scope: _uploadScope,
  operationId: _initialOperation(result),
  logicalEntityKeyHash: result.logicalEntityKeyHash,
  action: CloudOutboxAction.save,
  payloadVersion: 1,
  mutationRevision: 1,
  checkpointGeneration: 1,
  dependencyOperationIds: const [],
  createdAt: _time(9),
  encryptedPayloadReference: result.protectedEnvelopeReference,
  payloadSha256: result.payloadSha256,
  serverRecordIdHash: result.serverRecordIdHash,
  protectedLeaseReference: result.leaseReference,
);

void _persistFinalOperation(
  Store tx,
  CloudSyncProtectedOutboundStageData result,
) {
  tx.box<CloudOutboxOperationEntity>().put(
    CloudOutboxOperationEntity(
      operationId: _initialOperation(result),
      scopeKey: cloudSyncPersistentScopeKey(_uploadScope),
      accountFingerprint: _accountA,
      zone: 'attachmentManateeZone',
      logicalEntityKeyHash: result.logicalEntityKeyHash,
      action: CloudOutboxAction.save.index,
      checkpointGeneration: 1,
      mutationRevision: 1,
      encryptedPayloadRef: result.protectedEnvelopeReference,
      payloadSha256: result.payloadSha256,
      protectedLeaseReference: result.leaseReference,
      serverRecordIdHash: result.serverRecordIdHash,
      createdAtMs: _time(9).millisecondsSinceEpoch,
      updatedAtMs: _time(9).millisecondsSinceEpoch,
    ),
  );
}

Matcher _stateFailure(String message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

String _initialOperation(CloudSyncProtectedOutboundStageData stage) =>
    CloudOperationIdentity.forInitialCreate(
      scope: _uploadScope,
      logicalEntityKeyHash: stage.logicalEntityKeyHash,
      payloadVersion: 1,
    );

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);
String _token(String char) => List.filled(43, char).join();
String _digest(String char) => List.filled(64, char).join();
String _ref(String char) => 'obcs2.ref.${_token(char)}';
String _lease(String char) => 'obcs2.lease.${List.filled(32, char).join()}';

const _accountA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _storeA = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _attemptA = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _attemptB = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';

final _writerScope = CloudKitWriterScope(accountFingerprint: _accountA);
final _uploadScope = CloudSyncScope(
  accountFingerprint: _accountA,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'attachmentManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);
