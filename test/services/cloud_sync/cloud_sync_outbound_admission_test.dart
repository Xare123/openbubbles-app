import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late Directory directory;
  late Store objectBox;
  late ObjectBoxCloudSyncStore store;
  late _StagingTransport transport;
  late List<String> timeline;
  late CloudSyncOutboundAdmissionCoordinator coordinator;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-outbound-admission-',
    );
    objectBox = await openStore(directory: directory.path);
    store = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: _Protector(),
      clock: () => testEpoch,
    );
    timeline = [];
    transport = _StagingTransport(timeline);
    coordinator = CloudSyncOutboundAdmissionCoordinator(
      store: store,
      transport: transport,
      ensureProtectedStoreRecovered: () async {
        timeline.add('recover');
      },
    );
  });

  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('persists adoption before committing the exact native lease', () async {
    final stage = _stage('a', 'P', 'L', 'S');
    transport.stages.add(stage);

    final operation = await coordinator.admitMessage(
      testScope(),
      message: _FakeCloudMessage(),
      createdAt: testEpoch,
    );

    expect(timeline, ['recover', 'stage', 'commit:${stage.leaseReference}']);
    expect(operation.protectedLeaseReference, stage.leaseReference);
    expect(
      await store.readLiveProtectedOutboundLeaseReferences(maximumCount: 4096),
      {stage.leaseReference},
    );
    final mapping = await store.readRecordMap(
      testScope(),
      logicalEntityKeyHash: stage.logicalEntityKeyHash,
      generation: 1,
    );
    expect(mapping?.encryptedServerRecordId, stage.protectedEnvelopeReference);
  });

  test(
    'restaged retry keeps the durable identity and rolls back only the new lease',
    () async {
      final first = _stage('a', 'P', 'L', 'S');
      final retry = _stage('b', 'Q', 'L', 'S');
      transport.stages.addAll([first, retry]);
      final initial = await coordinator.admitMessage(
        testScope(),
        message: _FakeCloudMessage(),
        createdAt: testEpoch,
      );
      final repeated = await coordinator.admitMessage(
        testScope(),
        message: _FakeCloudMessage(),
        createdAt: testEpoch,
      );

      expect(repeated.operationId, initial.operationId);
      expect(repeated.protectedLeaseReference, first.leaseReference);
      expect(transport.committed, [first.leaseReference]);
      expect(transport.rolledBack, [retry.leaseReference]);
    },
  );

  test('commit failure preserves adopted data for startup recovery', () async {
    final stage = _stage('a', 'P', 'L', 'S');
    transport
      ..stages.add(stage)
      ..commitFailure = StateError('commit failed');

    await expectLater(
      coordinator.admitMessage(
        testScope(),
        message: _FakeCloudMessage(),
        createdAt: testEpoch,
      ),
      throwsStateError,
    );

    expect(transport.rolledBack, isEmpty);
    expect(
      await store.readLiveProtectedOutboundLeaseReferences(maximumCount: 4096),
      {stage.leaseReference},
    );
  });

  test(
    'recovery cannot enter between native stage and durable adoption',
    () async {
      final stage = _stage('a', 'P', 'L', 'S');
      final stageEntered = Completer<void>();
      final releaseStage = Completer<void>();
      transport
        ..stages.add(stage)
        ..stageEntered = stageEntered
        ..releaseStage = releaseStage;

      final admission = coordinator.admitMessage(
        testScope(),
        message: _FakeCloudMessage(),
        createdAt: testEpoch,
      );
      await stageEntered.future;
      final concurrentRecovery = transport.runOutboundAdmissionExclusive(
        () async {
          timeline.add('concurrent-recovery');
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(timeline, ['recover', 'stage']);

      releaseStage.complete();
      await admission;
      await concurrentRecovery;
      expect(timeline, [
        'recover',
        'stage',
        'commit:${stage.leaseReference}',
        'concurrent-recovery',
      ]);
    },
  );
}

CloudSyncProtectedOutboundStageData _stage(
  String leaseCharacter,
  String referenceCharacter,
  String logicalCharacter,
  String serverCharacter,
) => CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: List.filled(43, logicalCharacter).join(),
  protectedEnvelopeReference: testProtectedReference(referenceCharacter),
  payloadSha256: testSha256('a'),
  serverRecordIdHash: List.filled(43, serverCharacter).join(),
  leaseReference: testProtectedLeaseReference(leaseCharacter),
);

final class _FakeCloudMessage implements frb_api.CloudMessage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StagingTransport implements CloudSyncOutboundStagingTransport {
  _StagingTransport(this.timeline);

  final List<String> timeline;
  final List<CloudSyncProtectedOutboundStageData> stages = [];
  final List<String> committed = [];
  final List<String> rolledBack = [];
  Object? commitFailure;
  Completer<void>? stageEntered;
  Completer<void>? releaseStage;
  Future<void> _exclusiveTail = Future<void>.value();

  @override
  Future<T> runOutboundAdmissionExclusive<T>(
    Future<T> Function() action,
  ) async {
    final previous = _exclusiveTail;
    final released = Completer<void>();
    _exclusiveTail = previous.then((_) => released.future);
    await previous;
    try {
      return await action();
    } finally {
      released.complete();
    }
  }

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  }) async {
    timeline.add('stage');
    stageEntered?.complete();
    await releaseStage?.future;
    return stages.removeAt(0);
  }

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) async {
    timeline.add('commit:$leaseReference');
    if (commitFailure case final failure?) throw failure;
    committed.add(leaseReference);
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
    timeline.add('rollback:$leaseReference');
    rolledBack.add(leaseReference);
  }
}

final class _Protector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      sha256.convert(utf8.encode(rawAccountIdentifier)).toString();

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'protected:$plaintext';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext.substring('protected:'.length);
}
