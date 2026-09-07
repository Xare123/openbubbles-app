import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';
import 'cloud_sync_restored_chat_test_fixture.dart';

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

  test('rejects unjournaled reaction before staging or recovery', () async {
    await expectLater(
      coordinator.admitMessage(
        testScope(),
        message: _FakeCloudMessage(type: 2),
        createdAt: testEpoch,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'code',
          'cloud_sync_reaction_requires_local_send',
        ),
      ),
    );
    expect(timeline, isEmpty);
    expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
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

  group('durable local send handoff', () {
    late CloudSyncLocalSendJournal journal;
    late ObjectBoxCloudKitWriterAuthority authority;
    late CloudSyncLocalSendAuthFence authFence;
    late CloudSyncNativeAuthSnapshot currentAuth;
    late Message local;
    late int intentId;
    var encodes = 0;
    final scope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintA,
      container: 'com.apple.messages.cloud',
      database: 'private',
      zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages,
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final writerScope = CloudKitWriterScope(
      accountFingerprint: testAccountFingerprintA,
    );

    CloudSyncScope siblingScope(String zone) => CloudSyncScope(
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: zone,
      streamKind: scope.streamKind,
      schemaVersion: scope.schemaVersion,
      persistenceLane: scope.persistenceLane,
    );

    Future<void> seedCompleteAccount() async {
      for (final zone in const [
        'chatManateeZone',
        'messageManateeZone',
        'attachmentManateeZone',
      ]) {
        // Synthetic successful empty-zone baseline. Non-empty and unsafe
        // journals are installed through the production journal API below.
        await store.recordPullSuccess(siblingScope(zone), now: testEpoch);
      }
    }

    Future<void> addSiblingDebt({
      bool tombstone = false,
      bool retain = true,
    }) async {
      final sibling = siblingScope('attachmentManateeZone');
      final checkpoint = await store.readCheckpoint(sibling);
      final fence = (await store.tryAcquireCoordinatorLease(
        sibling,
        ownerId: 'admission-history-fixture',
        now: testEpoch,
        leaseDuration: const Duration(minutes: 1),
      ))!;
      await store.journalFetchedBatch(
        CloudFetchBatch(
          scope: sibling,
          changes: [testChange(1, tombstone: tombstone)],
          batchId: 'admission-history-batch',
          generation: checkpoint.generation,
          nextToken: 'admission-history-token',
          hasMore: false,
        ),
        now: testEpoch,
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );
      if (retain) {
        await store.markInboxRetainedUnprojected(
          sibling,
          sequence: 1,
          category: CloudFailureCategory.malformedRecord,
          now: testEpoch,
          maximumDeferredAttempts: 8,
          maximumDeferredAge: const Duration(days: 3),
          leaseFence: fence,
        );
      }
    }

    Matcher projectionFailure({bool tombstone = false}) => throwsA(
      isA<CloudSyncFailure>().having(
        (error) => error.safeCode,
        'safe code',
        tombstone
            ? 'messages_cloud_tombstone_projection_unavailable'
            : 'messages_cloud_account_projection_incomplete',
      ),
    );

    void bindJournal() {
      authority = ObjectBoxCloudKitWriterAuthority.forTest(
        store: objectBox,
        buildDecision: CloudKitWriterOwnership.resolve('v2'),
      );
      if (authority.read(writerScope) == null) {
        final disabled = authority.initializeDisabled(
          writerScope,
          now: testEpoch,
        );
        authority.provisionInitialOwner(
          writerScope,
          owner: CloudKitWriterOwner.v2,
          expectedEpoch: disabled.epoch,
          evidence: const CloudKitWriterTransitionEvidence.forTest(
            operationsQuiesced: true,
            activeIdentityRevalidated: true,
            legacyMutationQueues: LegacyMutationQueueDisposition.empty,
          ),
          now: testEpoch,
        );
      }
      journal = CloudSyncLocalSendJournal(
        store: objectBox,
        authority: authority,
        authoritySnapshot: authority.read(writerScope)!,
      );
    }

    CloudSyncLocalSendIntentEntity intent() =>
        objectBox.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;

    void confirm() {
      final identity = CloudSyncLocalSendIdentity.capture(
        local,
        local.chat.target!,
        _localGuid,
      )!;
      local
        ..guid = _localGuid
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: identity,
        persistMessage: () => objectBox.box<Message>().put(local),
        now: testEpoch,
      );
    }

    Future<CloudOutboxOperation> admit({
      frb_api.CloudMessage Function(Message)? encoder,
    }) => coordinator.admitLocalSend(
      scope,
      intentId: intentId,
      journal: journal,
      authFence: authFence,
      encodeMessage:
          encoder ??
          (message) {
            encodes++;
            return _LocalCloudMessage(message);
          },
    );

    Future<CloudOutboxOperation> confirmCloudSave() async {
      transport.stages.add(_stage('a', 'P', 'L', 'S'));
      final operation = await admit();
      store = ObjectBoxCloudSyncStore(
        store: objectBox,
        protector: _Protector(),
        clock: () => testEpoch,
        localSendJournal: journal,
      );
      const leaseId = 'synthetic-exact-readback-save';
      await store.leaseEligibleOutbox(
        scope,
        now: testEpoch,
        limit: 1,
        leaseId: leaseId,
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await store.markOutboxSubmissionStarted(
        scope,
        leaseId: leaseId,
        submissionIdentity: testSubmissionIdentity([operation.operationId]),
        now: testEpoch,
      );
      await store.commitOutboxCreateReceipt(
        scope,
        leaseId: leaseId,
        receipt: CloudOutboxCreateReceipt(
          operationId: operation.operationId,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          serverRecordIdHash: operation.serverRecordIdHash!,
          etagHash: 'E' * 43,
        ),
        retainProtectedLeaseReference: true,
        now: testEpoch.add(const Duration(seconds: 1)),
      );
      return (await store.readOutboxEntries(scope)).single;
    }

    Future<void> prepareReaction({bool restoreParent = true}) async {
      final parent = local;
      if (restoreParent) {
        await _seedRestoredParent(objectBox, store, scope, parent);
      }
      local = Message(
        guid: 'temp-Rxn12345',
        stagingGuid: _reactionGuid,
        associatedMessageGuid: parent.guid,
        associatedMessagePart: 0,
        associatedMessageType: 'like',
        isFromMe: true,
        dateCreated: testEpoch,
      )..chat.target = parent.chat.target;
      final identity = CloudSyncLocalSendIdentity.captureReaction(
        local,
        local.chat.target!,
        _reactionGuid,
      )!;
      journal.saveSubmission(
        identity: identity,
        newlyGeneratedGuid: true,
        persistMessage: () => objectBox.box<Message>().put(local),
        now: testEpoch,
      );
      intentId = objectBox
          .box<CloudSyncLocalSendIntentEntity>()
          .getAll()
          .singleWhere((row) => row.localMessageId == local.id)
          .id;
      local
        ..guid = _reactionGuid
        ..stagingGuid = null;
      journal.saveConfirmedSubmission(
        identity: identity,
        persistMessage: () => objectBox.box<Message>().put(local),
        now: testEpoch,
      );
    }

    setUp(() async {
      await seedCompleteAccount();
      bindJournal();
      encodes = 0;
      currentAuth = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'synthetic-session',
        accountFingerprint: testAccountFingerprintA,
        protectedStoreIdentity: 'obcs2.store.$testAccountFingerprintA',
        cloudMessagesClient: Object(),
      );
      authFence = CloudSyncLocalSendAuthFence(
        expected: currentAuth,
        capture: () async => currentAuth,
        stillCurrent: () => true,
      );
      final handle = Handle(
        address: 'recipient@example.com',
        service: 'iMessage',
        uniqueAddressAndService: 'recipient@example.com/iMessage',
      );
      objectBox.box<Handle>().put(handle);
      final chat = Chat(
        guid: 'iMessage;-;recipient@example.com',
        chatIdentifier: 'recipient@example.com',
        usingHandle: 'mailto:sender@example.com',
        style: 45,
        participants: [handle],
      )..handles.add(handle);
      objectBox.box<Chat>().put(chat);
      local = Message(
        guid: 'temp-Abc12345',
        stagingGuid: _localGuid,
        text: 'synthetic local message',
        isFromMe: true,
        dateCreated: testEpoch,
        attributedBody: [AttributedBody.raw('synthetic local message')],
      )..chat.target = chat;
      journal.saveSubmission(
        identity: CloudSyncLocalSendIdentity.capture(local, chat, _localGuid)!,
        newlyGeneratedGuid: true,
        persistMessage: () => objectBox.box<Message>().put(local),
        now: testEpoch,
      );
      intentId = objectBox
          .box<CloudSyncLocalSendIntentEntity>()
          .getAll()
          .single
          .id;
      confirm();
      final chatScope = siblingScope('chatManateeZone');
      final restoredSource = await seedSyntheticRestoredChatAppliedSource(
        objectBox: objectBox,
        store: store,
        chatScope: chatScope,
        now: testEpoch,
      );
      await seedSyntheticRestoredChatProof(
        objectBox: objectBox,
        store: store,
        chatScope: chatScope,
        chat: chat,
        appliedSource: restoredSource,
        now: testEpoch,
      );
    });

    test(
      'save confirmation and generic receipt cleanup do not prove readback',
      () async {
        expect(intent().confirmedReadbackBindingSha256, isNull);
        final operation = await confirmCloudSave();
        expect(intent().state, 2);
        expect(intent().confirmedReadbackBindingSha256, isNull);
        await store.clearConfirmedProtectedOutboundLeaseReference(
          expectedOperation: operation,
        );
        expect(intent().confirmedReadbackBindingSha256, isNull);
      },
    );

    test(
      'verified replay persists the immutable binding with receipt release',
      () async {
        final operation = await confirmCloudSave();
        final binding = intent().admittedBindingSha256;
        await store.clearConfirmedProtectedOutboundLeaseReference(
          expectedOperation: operation,
          recordVerifiedLocalSendReadback: true,
        );
        expect(intent().confirmedReadbackBindingSha256, binding);
        expect(
          (await store.readOutboxEntries(scope)).single.protectedLeaseReference,
          isNull,
        );
        objectBox.close();
        objectBox = await openStore(directory: directory.path);
        bindJournal();
        expect(intent().confirmedReadbackBindingSha256, binding);
        expect(journal.readForAdmission(intentId).state, 2);
      },
    );

    test(
      'changed adopted binding rolls back proof and preserves the receipt',
      () async {
        final operation = await confirmCloudSave();
        objectBox.box<CloudSyncLocalSendIntentEntity>().put(
          intent()..admittedBindingSha256 = '0' * 64,
        );
        await expectLater(
          store.clearConfirmedProtectedOutboundLeaseReference(
            expectedOperation: operation,
            recordVerifiedLocalSendReadback: true,
          ),
          throwsStateError,
        );
        expect(intent().confirmedReadbackBindingSha256, isNull);
        expect(
          (await store.readOutboxEntries(scope)).single.protectedLeaseReference,
          operation.protectedLeaseReference,
        );
      },
    );

    test('changed receipt snapshot cannot commit readback evidence', () async {
      final operation = await confirmCloudSave();
      await expectLater(
        store.clearConfirmedProtectedOutboundLeaseReference(
          expectedOperation: operation.copyWith(
            attemptCount: operation.attemptCount + 1,
          ),
          recordVerifiedLocalSendReadback: true,
        ),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(intent().confirmedReadbackBindingSha256, isNull);
      expect(
        (await store.readOutboxEntries(scope)).single.protectedLeaseReference,
        operation.protectedLeaseReference,
      );
    });

    test(
      'generic store cannot discard a local-owned verified receipt',
      () async {
        final operation = await confirmCloudSave();
        final unbound = ObjectBoxCloudSyncStore(
          store: objectBox,
          protector: _Protector(),
          clock: () => testEpoch,
        );
        await expectLater(
          unbound.clearConfirmedProtectedOutboundLeaseReference(
            expectedOperation: operation,
            recordVerifiedLocalSendReadback: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'code',
              'cloud_sync_local_send_journal_required',
            ),
          ),
        );
        expect(intent().confirmedReadbackBindingSha256, isNull);
        expect(
          (await store.readOutboxEntries(scope)).single.protectedLeaseReference,
          operation.protectedLeaseReference,
        );
      },
    );

    test(
      'readback marker cannot bless a different immutable adoption',
      () async {
        final operation = await confirmCloudSave();
        await store.clearConfirmedProtectedOutboundLeaseReference(
          expectedOperation: operation,
          recordVerifiedLocalSendReadback: true,
        );
        objectBox.box<CloudSyncLocalSendIntentEntity>().put(
          intent()..confirmedReadbackBindingSha256 = '0' * 64,
        );
        expect(() => journal.readForAdmission(intentId), throwsStateError);
      },
    );

    test(
      'older released receipt cannot be retroactively declared verified',
      () async {
        final operation = await confirmCloudSave();
        await store.clearConfirmedProtectedOutboundLeaseReference(
          expectedOperation: operation,
        );
        final settled = (await store.readOutboxEntries(scope)).single;
        await expectLater(
          store.clearConfirmedProtectedOutboundLeaseReference(
            expectedOperation: settled,
            recordVerifiedLocalSendReadback: true,
          ),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(intent().confirmedReadbackBindingSha256, isNull);
      },
    );

    test('local-only reaction parent blocks staging', () async {
      await prepareReaction(restoreParent: false);
      await expectLater(
        admit(encoder: (message) => _LocalCloudMessage(message, type: 2)),
        throwsA(
          isA<CloudSyncFailure>().having(
            (error) => error.safeCode,
            'code',
            'cloud_sync_local_send_parent_not_ready',
          ),
        ),
      );
      expect(timeline, ['recover']);
      expect(intent().state, 1);
      expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
    });

    test(
      'outer transaction failure rolls back both readback proof and receipt release',
      () async {
        final operation = await confirmCloudSave();
        late Future<void> cleared;
        expect(
          () => objectBox.runInTransaction<void>(TxMode.write, () {
            cleared = store.clearConfirmedProtectedOutboundLeaseReference(
              expectedOperation: operation,
              recordVerifiedLocalSendReadback: true,
            );
            expect(intent().confirmedReadbackBindingSha256, isNotNull);
            expect(
              objectBox
                  .box<CloudOutboxOperationEntity>()
                  .getAll()
                  .single
                  .protectedLeaseReference,
              isNull,
            );
            throw StateError('synthetic transaction interruption');
          }),
          throwsStateError,
        );
        await cleared;
        expect(intent().confirmedReadbackBindingSha256, isNull);
        expect(
          (await store.readOutboxEntries(scope)).single.protectedLeaseReference,
          operation.protectedLeaseReference,
        );
      },
    );

    Future<CloudOutboxOperation> verifyOwnParent() async {
      final parentOperation = await confirmCloudSave();
      await store.clearConfirmedProtectedOutboundLeaseReference(
        expectedOperation: parentOperation,
        recordVerifiedLocalSendReadback: true,
      );
      return parentOperation;
    }

    Future<CloudOutboxOperation> admitOwnParentReaction() async {
      await prepareReaction(restoreParent: false);
      transport.stages.add(_stage('b', 'Q', 'N', 'T'));
      return admit(encoder: (message) => _LocalCloudMessage(message, type: 2));
    }

    test(
      'exact own-parent readback permits reaction without a change-feed echo',
      () async {
        final parentOperation = await verifyOwnParent();
        expect(
          objectBox.box<CloudInboxChangeEntity>().getAll().where(
            (row) =>
                row.serverRecordIdHash == parentOperation.serverRecordIdHash,
          ),
          isEmpty,
        );
        final reaction = await admitOwnParentReaction();
        final binding = jsonDecode(intent().admittedChatBinding!) as List;
        expect(binding[0], 2);
        expect(binding[2][0], 2);
        expect(binding[2][7], parentOperation.serverRecordIdHash);
        objectBox.close();
        objectBox = await openStore(directory: directory.path);
        bindJournal();
        store = ObjectBoxCloudSyncStore(
          store: objectBox,
          protector: _Protector(),
          clock: () => testEpoch,
          localSendJournal: journal,
        );
        final leased = await store.leaseEligibleOutbox(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'own-parent-restart',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        expect(leased.single.operationId, reaction.operationId);
        expect(transport.committed, hasLength(2));
      },
    );

    for (final clearGenericReceipt in [false, true]) {
      test(
        'save-only own parent remains blocked (generic cleanup $clearGenericReceipt)',
        () async {
          final operation = await confirmCloudSave();
          if (clearGenericReceipt) {
            await store.clearConfirmedProtectedOutboundLeaseReference(
              expectedOperation: operation,
            );
          }
          await prepareReaction(restoreParent: false);
          final stagedBefore = transport.committed.length;
          await expectLater(admit(), throwsA(isA<CloudSyncFailure>()));
          expect(transport.committed, hasLength(stagedBefore));
          expect(intent().state, 1);
        },
      );
    }

    for (final mutation in [
      'marker',
      'payload',
      'map',
      'generation',
      'parent text',
      'parent guid',
    ]) {
      test('own-parent $mutation drift blocks reaction dispatch', () async {
        await verifyOwnParent();
        final parentIntentId = intentId;
        final parentId = local.id!;
        await admitOwnParentReaction();
        switch (mutation) {
          case 'marker':
            final box = objectBox.box<CloudSyncLocalSendIntentEntity>();
            box.put(
              box.get(parentIntentId)!
                ..confirmedReadbackBindingSha256 = '0' * 64,
            );
          case 'payload':
            final box = objectBox.box<CloudOutboxOperationEntity>();
            box.put(
              box.getAll().singleWhere(
                (row) => row.state == CloudOutboxStatus.confirmed.index,
              )..payloadSha256 = '0' * 64,
            );
          case 'map':
            final box = objectBox.box<CloudRecordMapEntity>();
            box.put(
              box.getAll().singleWhere(
                (row) => row.logicalEntityKeyHash == 'L' * 43,
              )..serverRecordIdHash = 'Z' * 43,
            );
          case 'generation':
            final box = objectBox.box<CloudSyncCheckpointEntity>();
            box.put(
              box.getAll().singleWhere(
                (row) =>
                    row.checkpointKey == cloudSyncPersistentScopeKey(scope),
              )..generation = 2,
            );
          case 'parent text':
            objectBox.box<Message>().put(
              objectBox.box<Message>().get(parentId)!..text = 'changed',
            );
          case 'parent guid':
            objectBox.box<Message>().put(
              objectBox.box<Message>().get(parentId)!
                ..guid = '33333333-3333-4333-8333-333333333333',
            );
        }
        final lease = store.leaseEligibleOutbox(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'own-parent-drift',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        if (mutation == 'generation') {
          // Old-generation rows are deliberately excluded before admission.
          expect(await lease, isEmpty);
        } else {
          await expectLater(
            lease,
            throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())),
          );
        }
        expect(
          objectBox.box<CloudOutboxOperationEntity>().getAll().where(
            (row) => row.state == CloudOutboxStatus.leased.index,
          ),
          isEmpty,
        );
      });
    }

    for (final status in CloudInboxStatus.values) {
      test(
        'own readback cannot override an incoming ${status.name} parent record',
        () async {
          final operation = await verifyOwnParent();
          final parent = local;
          await admitOwnParentReaction();
          await _seedRestoredParent(
            objectBox,
            store,
            scope,
            parent,
            origin: operation,
          );
          final box = objectBox.box<CloudInboxChangeEntity>();
          final latest = box.getAll().singleWhere(
            (row) => row.serverRecordIdHash == operation.serverRecordIdHash,
          );
          // Applied-but-tombstoned must not resurrect from the earlier save proof.
          box.put(
            latest
              ..status = status.index
              ..isTombstone = status == CloudInboxStatus.applied,
          );
          await expectLater(
            store.leaseEligibleOutbox(
              scope,
              now: testEpoch,
              limit: 1,
              leaseId: 'inbox-parent-contradiction',
              leaseDuration: const Duration(minutes: 1),
              allowedActions: const {CloudOutboxAction.save},
            ),
            throwsA(isA<CloudSyncFailure>()),
          );
        },
      );
    }

    test(
      'fully applied same-parent echo replaces local proof without retargeting',
      () async {
        final operation = await verifyOwnParent();
        final parent = local;
        final reaction = await admitOwnParentReaction();
        final originalBinding = intent().admittedChatBinding;
        await _seedRestoredParent(
          objectBox,
          store,
          scope,
          parent,
          origin: operation,
        );
        final leased = await store.leaseEligibleOutbox(
          scope,
          now: testEpoch,
          limit: 1,
          leaseId: 'applied-parent-echo',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        expect(leased.single.operationId, reaction.operationId);
        expect(intent().admittedChatBinding, originalBinding);
      },
    );

    test(
      'reaction adopts once and rechecks pinned parent after restart',
      () async {
        await prepareReaction();
        transport.stages.add(_stage('a', 'P', 'L', 'S'));
        final first = await admit(
          encoder: (message) {
            encodes++;
            return _LocalCloudMessage(message, type: 2);
          },
        );
        expect(jsonDecode(intent().admittedChatBinding!)[0], 2);
        objectBox.close();
        objectBox = await openStore(directory: directory.path);
        store = ObjectBoxCloudSyncStore(
          store: objectBox,
          protector: _Protector(),
          clock: () => testEpoch,
        );
        bindJournal();
        coordinator = CloudSyncOutboundAdmissionCoordinator(
          store: store,
          transport: transport,
          ensureProtectedStoreRecovered: () async => timeline.add('recover'),
        );
        final replay = await admit(
          encoder: (_) => throw StateError('no re-encoding'),
        );
        expect(replay.operationId, first.operationId);
        expect(encodes, 1);
        expect(transport.committed, hasLength(1));
        await expectLater(
          store.leaseEligibleOutbox(
            scope,
            now: testEpoch,
            limit: 1,
            leaseId: 'missing-reaction-journal',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'code',
              'cloud_sync_local_send_journal_required',
            ),
          ),
        );
        store = ObjectBoxCloudSyncStore(
          store: objectBox,
          protector: _Protector(),
          clock: () => testEpoch,
          localSendJournal: journal,
        );
        // No mutable source is needed to recover the envelope, but its parent
        // must still exist when the recovered operation is actually leased.
        final parent = objectBox.box<Message>().getAll().singleWhere(
          (row) => row.guid == _localGuid,
        );
        objectBox.box<Message>().put(parent..dateDeleted = testEpoch);
        await expectLater(
          store.leaseEligibleOutbox(
            scope,
            now: testEpoch,
            limit: 1,
            leaseId: 'reaction-parent-recheck',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          ),
          throwsA(
            isA<CloudSyncFailure>().having(
              (error) => error.safeCode,
              'code',
              'cloud_sync_local_send_parent_not_ready',
            ),
          ),
        );
      },
    );

    test(
      'reaction parent is rechecked after asynchronous native staging',
      () async {
        await prepareReaction();
        final stage = _stage('a', 'P', 'L', 'S');
        final entered = Completer<void>();
        final release = Completer<void>();
        transport
          ..stages.add(stage)
          ..stageEntered = entered
          ..releaseStage = release;
        final pending = admit(
          encoder: (message) => _LocalCloudMessage(message, type: 2),
        );
        final rejected = expectLater(pending, throwsA(isA<CloudSyncFailure>()));
        await entered.future;
        final parent = objectBox.box<Message>().getAll().singleWhere(
          (row) => row.guid == _localGuid,
        );
        objectBox.box<Message>().put(parent..dateDeleted = testEpoch);
        release.complete();
        await rejected;
        expect(transport.rolledBack, [stage.leaseReference]);
        expect(transport.committed, isEmpty);
        expect(intent().state, 1);
        expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test('encoder cannot turn a journaled text into a reaction', () async {
      await expectLater(
        admit(encoder: (message) => _LocalCloudMessage(message, type: 2)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'code',
            'cloud_sync_local_send_encoded_identity_changed',
          ),
        ),
      );
      expect(timeline, ['recover']);
      expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      expect(intent().state, 1);
    });

    for (final debt in const [
      'missing sibling',
      'retained save',
      'retained tombstone',
      'pending page',
      'backoff',
    ]) {
      test('keeps a ready local send outside the outbox with $debt', () async {
        final sibling = siblingScope('attachmentManateeZone');
        switch (debt) {
          case 'missing sibling':
            final row = objectBox
                .box<CloudSyncCheckpointEntity>()
                .getAll()
                .singleWhere((row) => row.zone == sibling.zone);
            objectBox.box<CloudSyncCheckpointEntity>().remove(row.id);
          case 'retained save':
            await addSiblingDebt();
          case 'retained tombstone':
            await addSiblingDebt(tombstone: true);
          case 'pending page':
            await addSiblingDebt(retain: false);
          case 'backoff':
            await store.recordPullFailure(
              sibling,
              category: CloudFailureCategory.network,
              nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
            );
        }
        transport.stages.add(_stage('a', 'P', 'L', 'S'));
        final original = intent();

        await expectLater(
          admit(),
          projectionFailure(tombstone: debt == 'retained tombstone'),
        );

        expect(encodes, 0);
        expect(timeline, ['recover']);
        expect(transport.committed, isEmpty);
        expect(transport.rolledBack, isEmpty);
        expect(intent().state, 1);
        expect(intent().sourceSha256, original.sourceSha256);
        expect(intent().admittedOperationId, isNull);
        expect(await store.hasNonterminalOutbox(scope), isFalse);
        expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
        expect(recordMapCountForZone(objectBox, scope.zone), 0);
        expect((await store.readCheckpoint(scope)).mutationRevisionCounter, 0);
      });
    }

    test(
      'rechecks sibling projection atomically after native staging',
      () async {
        final stage = _stage('a', 'P', 'L', 'S');
        final entered = Completer<void>();
        final release = Completer<void>();
        transport
          ..stages.add(stage)
          ..stageEntered = entered
          ..releaseStage = release;
        final admission = admit();
        final rejected = expectLater(
          admission,
          projectionFailure(tombstone: true),
        );
        await entered.future;
        await addSiblingDebt(tombstone: true);
        release.complete();
        await rejected;

        expect(transport.committed, isEmpty);
        expect(transport.rolledBack, [stage.leaseReference]);
        expect(intent().state, 1);
        expect(intent().admittedOperationId, isNull);
        expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
        expect(recordMapCountForZone(objectBox, scope.zone), 0);
        expect((await store.readCheckpoint(scope)).mutationRevisionCounter, 0);
        final sibling = await store.readCheckpoint(
          siblingScope('attachmentManateeZone'),
        );
        expect(sibling.fetchedSequence, 1);
        expect(sibling.lastAppliedSequence, 0);
        expect(sibling.hasUnmarkedPendingInbox, isFalse);
      },
    );

    test(
      'direct protected admission cannot strand a new outbox behind history',
      () async {
        await addSiblingDebt(tombstone: true);
        final stage = _stage('a', 'P', 'L', 'S');
        transport.stages.add(stage);
        await expectLater(
          coordinator.admitMessage(
            scope,
            message: _FakeCloudMessage(),
            createdAt: testEpoch,
          ),
          projectionFailure(tombstone: true),
        );
        expect(transport.committed, isEmpty);
        expect(transport.rolledBack, [stage.leaseReference]);
        expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
        expect(recordMapCountForZone(objectBox, scope.zone), 0);
        expect(intent().state, 1);
      },
    );

    test(
      'ready send survives restart and admits once after read backoff clears',
      () async {
        final sibling = siblingScope('attachmentManateeZone');
        transport.stages.add(_stage('a', 'P', 'L', 'S'));
        await store.recordPullFailure(
          sibling,
          category: CloudFailureCategory.network,
          nextEligibleAt: testEpoch.add(const Duration(minutes: 1)),
        );
        await expectLater(admit(), projectionFailure());
        objectBox.close();
        objectBox = await openStore(directory: directory.path);
        store = ObjectBoxCloudSyncStore(
          store: objectBox,
          protector: _Protector(),
          clock: () => testEpoch,
        );
        bindJournal();
        coordinator = CloudSyncOutboundAdmissionCoordinator(
          store: store,
          transport: transport,
          ensureProtectedStoreRecovered: () async {
            timeline.add('recover');
          },
        );
        expect(intent().state, 1);
        expect(await store.hasNonterminalOutbox(scope), isFalse);
        await store.recordPullSuccess(
          sibling,
          now: testEpoch.add(const Duration(minutes: 2)),
        );
        final first = await admit();
        final replay = await admit();
        expect(replay.operationId, first.operationId);
        expect(encodes, 1);
        expect(transport.committed, hasLength(1));
        expect(objectBox.box<CloudOutboxOperationEntity>().count(), 1);
      },
    );

    test(
      'later projection debt does not prevent exact adopted-envelope recovery',
      () async {
        transport.stages.add(_stage('a', 'P', 'L', 'S'));
        final first = await admit();
        await addSiblingDebt(tombstone: true);
        objectBox.box<Message>().remove(local.id!);
        final recovered = await admit();
        expect(recovered.operationId, first.operationId);
        expect(encodes, 1);
        expect(transport.committed, hasLength(1));
        expect(intent().state, 2);
        await expectLater(
          store.leaseEligibleOutbox(
            scope,
            now: testEpoch,
            limit: 1,
            leaseId: 'projection-remains-required',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: const {CloudOutboxAction.save},
          ),
          projectionFailure(tombstone: true),
        );
      },
    );

    test(
      'adopts the journal, mapping and outbox before native commit',
      () async {
        final stage = _stage('a', 'P', 'L', 'S');
        transport.stages.add(stage);
        transport.onCommit = () {
          expect(intent().state, 2);
          expect(intent().admittedOperationId, isNotNull);
          expect(objectBox.box<CloudOutboxOperationEntity>().count(), 1);
          expect(recordMapCountForZone(objectBox, scope.zone), 1);
        };
        final operation = await admit();
        expect(intent().admittedOperationId, operation.operationId);
        expect(journal.readReady(), isEmpty);
        expect(encodes, 1);
        expect(transport.committed, [stage.leaseReference]);
        confirm();
        expect(
          intent().state,
          2,
          reason: 'A repeated IDS callback cannot downgrade adoption',
        );
        expect(intent().admittedOperationId, operation.operationId);
      },
    );

    test(
      'reopen after commit failure reuses the original envelope without a Message',
      () async {
        final stage = _stage('a', 'P', 'L', 'S');
        transport
          ..stages.add(stage)
          ..commitFailure = StateError('synthetic commit failure');
        await expectLater(admit(), throwsStateError);
        final operationId = intent().admittedOperationId!;
        expect(intent().state, 2);
        expect(transport.rolledBack, isEmpty);
        objectBox.box<Message>().remove(local.id!);
        objectBox.close();
        objectBox = await openStore(directory: directory.path);
        store = ObjectBoxCloudSyncStore(
          store: objectBox,
          protector: _Protector(),
        );
        bindJournal();
        coordinator = CloudSyncOutboundAdmissionCoordinator(
          store: store,
          transport: transport,
          ensureProtectedStoreRecovered: () async {
            timeline.add('recover');
          },
        );
        final original = await admit(
          encoder: (_) => throw StateError('must not encode'),
        );
        expect(original.operationId, operationId);
        expect(
          original.encryptedPayloadReference,
          stage.protectedEnvelopeReference,
        );
        expect(original.protectedLeaseReference, stage.leaseReference);
        expect(original.status, CloudOutboxStatus.pending);
        expect(original.attemptCount, 0);
        expect(encodes, 1);
        expect(timeline.where((entry) => entry == 'stage'), hasLength(1));
        expect(timeline.where((entry) => entry == 'recover'), hasLength(2));
        expect(objectBox.box<CloudOutboxOperationEntity>().count(), 1);
      },
    );

    test('pending IDS submission is never encoded or adopted', () async {
      objectBox.box<CloudSyncLocalSendIntentEntity>().put(intent()..state = 0);
      await expectLater(admit(), throwsStateError);
      expect(encodes, 0);
      expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
      expect(timeline, ['recover']);
    });

    for (final change in ['text', 'route', 'epoch', 'session', 'journal']) {
      test(
        '$change drift during staging rolls back the complete adoption',
        () async {
          final stage = _stage('a', 'P', 'L', 'S');
          final entered = Completer<void>();
          final release = Completer<void>();
          transport
            ..stages.add(stage)
            ..stageEntered = entered
            ..releaseStage = release;
          final failureCode = switch (change) {
            'epoch' => 'cloud_sync_local_send_owner_changed',
            'session' => 'cloud_sync_local_send_identity_changed',
            'journal' => 'cloud_sync_local_send_adoption_changed',
            _ => 'cloud_sync_local_send_source_changed',
          };
          final rejected = expectLater(
            admit(),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'safe code',
                failureCode,
              ),
            ),
          );
          await entered.future;
          switch (change) {
            case 'text':
              local.text = 'synthetic edited text';
              objectBox.box<Message>().put(local);
            case 'route':
              final chat = local.chat.target!
                ..usingHandle = 'mailto:other@example.com';
              objectBox.box<Chat>().put(chat);
            case 'epoch':
              final row = objectBox
                  .box<CloudKitWriterAuthorityEntity>()
                  .getAll()
                  .single;
              row.epoch++;
              objectBox.box<CloudKitWriterAuthorityEntity>().put(row);
            case 'session':
              currentAuth = CloudSyncNativeAuthSnapshot.fromNative(
                nativeSessionId: 'replacement-session',
                accountFingerprint: testAccountFingerprintA,
                protectedStoreIdentity: 'obcs2.store.$testAccountFingerprintA',
                cloudMessagesClient: Object(),
              );
            case 'journal':
              objectBox.box<CloudSyncLocalSendIntentEntity>().put(
                intent()..sourceSha256 = 'changed',
              );
          }
          release.complete();
          await rejected;
          expect(intent().state, 1);
          expect(intent().admittedOperationId, isNull);
          expect(objectBox.box<CloudOutboxOperationEntity>().count(), 0);
          expect(recordMapCountForZone(objectBox, scope.zone), 0);
          final checkpoints = objectBox
              .box<CloudSyncCheckpointEntity>()
              .getAll();
          expect(checkpoints, hasLength(3));
          expect(
            checkpoints.every((row) => row.mutationRevisionCounter == 0),
            isTrue,
          );
          expect(transport.rolledBack, [stage.leaseReference]);
          expect(transport.committed, isEmpty);
        },
      );
    }

    test('missing adopted operation is not silently re-encoded', () async {
      transport.stages.add(_stage('a', 'P', 'L', 'S'));
      await admit();
      final row = objectBox.box<CloudOutboxOperationEntity>().getAll().single;
      objectBox.box<CloudOutboxOperationEntity>().remove(row.id);
      await expectLater(admit(), throwsStateError);
      expect(encodes, 1);
      expect(intent().state, 2);
      expect(timeline.where((entry) => entry == 'stage'), hasLength(1));
    });

    test('scope account must match the native auth fence', () async {
      final otherAuth = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'other',
        accountFingerprint: testAccountFingerprintB,
        protectedStoreIdentity: 'obcs2.store.$testAccountFingerprintB',
        cloudMessagesClient: Object(),
      );
      authFence = CloudSyncLocalSendAuthFence(
        expected: otherAuth,
        capture: () async => otherAuth,
        stillCurrent: () => true,
      );
      await expectLater(admit(), throwsStateError);
      expect(encodes, 0);
      expect(timeline, ['recover']);
    });

    test(
      'journal rejects authority from another Store at construction',
      () async {
        final other = await openStore(
          directory: '${directory.path}/other-store',
        );
        try {
          expect(
            () => CloudSyncLocalSendJournal(
              store: other,
              authority: authority,
              authoritySnapshot: authority.read(writerScope)!,
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'safe code',
                'cloud_sync_local_send_authority_store_mismatch',
              ),
            ),
          );
          expect(other.box<CloudSyncLocalSendIntentEntity>().count(), 0);
          expect(intent().state, 1);
        } finally {
          other.close();
        }
      },
    );

    for (final corruption in [
      'missing map',
      'envelope',
      'payload hash',
      'server hash',
      'lease',
    ]) {
      test(
        'adopted $corruption corruption fails without re-encoding',
        () async {
          transport.stages.add(_stage('a', 'P', 'L', 'S'));
          await admit();
          final row = objectBox
              .box<CloudOutboxOperationEntity>()
              .getAll()
              .single;
          switch (corruption) {
            case 'missing map':
              final mapping = objectBox
                  .box<CloudRecordMapEntity>()
                  .getAll()
                  .singleWhere((row) => row.zone == scope.zone);
              objectBox.box<CloudRecordMapEntity>().remove(mapping.id);
            case 'envelope':
              row.encryptedPayloadRef = testProtectedReference('Q');
            case 'payload hash':
              row.payloadSha256 = testSha256('b');
            case 'server hash':
              row.serverRecordIdHash = 'T' * 43;
            case 'lease':
              row.protectedLeaseReference = 'invalid-lease';
          }
          objectBox.box<CloudOutboxOperationEntity>().put(row);
          await expectLater(
            admit(),
            corruption == 'lease'
                ? throwsA(
                    isA<ArgumentError>().having(
                      (error) => error.message,
                      'safe code',
                      'cloud_outbox_protected_lease_reference_invalid',
                    ),
                  )
                : throwsA(
                    isA<StateError>().having(
                      (error) => error.message,
                      'safe code',
                      corruption == 'missing map'
                          ? 'cloud_sync_local_send_adopted_mapping_changed'
                          : 'cloud_sync_local_send_adopted_operation_missing',
                    ),
                  ),
          );
          expect(encodes, 1);
          expect(intent().state, 2);
          expect(timeline.where((entry) => entry == 'stage'), hasLength(1));
        },
      );
    }

    test(
      'settled receipt changes do not invalidate the immutable payload binding',
      () async {
        transport.stages.add(_stage('a', 'P', 'L', 'S'));
        final initial = await admit();
        // Synthetic already-acknowledged state. Receipt admission itself is
        // exercised by the separate exact-receipt store tests.
        final row = objectBox.box<CloudOutboxOperationEntity>().getAll().single
          ..state = 2
          ..confirmedAtMs = testEpoch.millisecondsSinceEpoch + 1000
          ..appleRequestUuid = '11111111-2222-4333-8444-555555555555'
          ..appleOperationUuid = '22222222-2222-4333-8444-555555555555'
          ..attemptCount = 1
          ..protectedLeaseReference = null;
        objectBox.box<CloudOutboxOperationEntity>().put(row);
        final mapping =
            objectBox.box<CloudRecordMapEntity>().getAll().singleWhere(
                (row) => row.zone == scope.zone,
              )
              ..etagHash = 'E' * 43
              ..encryptedServerRecordId = testProtectedReference('Q');
        objectBox.box<CloudRecordMapEntity>().put(mapping);
        final settled = await admit();
        expect(settled.operationId, initial.operationId);
        expect(settled.status, CloudOutboxStatus.confirmed);
        expect(
          settled.encryptedPayloadReference,
          initial.encryptedPayloadReference,
        );
        expect(settled.protectedLeaseReference, isNull);
        expect(encodes, 1);
      },
    );

    test(
      'receipt and timestamp normalization preserve the first staged snapshot',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        transport
          ..stages.add(_stage('a', 'P', 'L', 'S'))
          ..stageEntered = entered
          ..releaseStage = release;
        DateTime? encodedDate;
        final admission = admit(
          encoder: (message) {
            encodes++;
            encodedDate = message.dateCreated;
            return _LocalCloudMessage(message);
          },
        );
        await entered.future;
        local
          ..dateCreated = testEpoch.add(const Duration(seconds: 1))
          ..dateRead = testEpoch.add(const Duration(seconds: 3))
          ..dateDelivered = testEpoch.add(const Duration(seconds: 2));
        objectBox.box<Message>().put(local);
        release.complete();
        final admitted = await admission;
        expect(encodedDate?.toUtc(), testEpoch);
        expect(intent().state, 2);
        expect((await admit()).operationId, admitted.operationId);
        expect(encodes, 1);
      },
    );
  });
}

const _localGuid = '11111111-1111-4111-8111-111111111111';
const _reactionGuid = '22222222-2222-4222-8222-222222222222';

Future<void> _seedRestoredParent(
  Store db,
  ObjectBoxCloudSyncStore store,
  CloudSyncScope scope,
  Message parent, {
  CloudOutboxOperation? origin,
}) async {
  // Reuse the applied-source journal fixture. Source records are scoped;
  // the separate snapshot below proves this one's Message kind and GUID.
  final observedAt = origin == null
      ? testEpoch
      : testEpoch.add(const Duration(seconds: 2));
  final source = await seedSyntheticRestoredChatAppliedSource(
    objectBox: db,
    store: store,
    chatScope: scope,
    now: observedAt,
    recordIdHash: origin?.serverRecordIdHash,
  );
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final generationKey =
      'semantic-generation4:${sha256.convert(utf8.encode('$scopeKey\u001f${source.generation}'))}';
  final logical = origin?.logicalEntityKeyHash ?? 'M' * 43;
  // Model the semantic gateway's applied-source mapping, not the generic
  // transport upsert (which deliberately retains the earlier ID reference).
  // Production projection binds all references to the newly applied inbox row.
  final maps = db.box<CloudRecordMapEntity>();
  final existing = maps
      .getAll()
      .where(
        (row) =>
            row.scopeKey == scopeKey && row.logicalEntityKeyHash == logical,
      )
      .toList();
  maps.put(
    CloudRecordMapEntity(
      id: existing.isEmpty ? 0 : existing.single.id,
      mapKey: cloudSyncCanonicalRecordMapKey(scope, logical),
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      generation: source.generation,
      logicalEntityKeyHash: logical,
      serverRecordIdHash: source.serverRecordIdHash,
      encryptedServerRecordId: source.encryptedServerRecordId!,
      encryptedRawRecordRef: source.encryptedPayloadRef,
      etagHash: source.etagHash,
      updatedAtMs: observedAt.millisecondsSinceEpoch,
    ),
  );
  db.box<CloudSemanticSnapshotEntity>().put(
    CloudSemanticSnapshotEntity(
      snapshotKey: 'semantic-snapshot4:$generationKey:message:$logical',
      scopeGenerationKey: generationKey,
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: source.generation,
      entityKind: CloudEntityKind.message.name,
      logicalEntityKeyHash: logical,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: source.generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: logical,
        canonicalGuid: parent.guid!,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: source.generation,
            canonicalGuid: parent.guid!,
          ),
      etagHash: source.etagHash,
      updatedAtMs: observedAt.millisecondsSinceEpoch,
    ),
  );
}

// Tests exercise persistence and crash ordering, not the native protobuf codec.
final class _LocalCloudMessage implements frb_api.CloudMessage {
  _LocalCloudMessage(Message message, {this.type = 1})
    : guid = message.guid!,
      chatId = message.chat.target!.guid,
      destinationCallerId = message.chat.target!.usingHandle!
          .replaceFirst('mailto:', '')
          .replaceFirst('tel:', '');
  @override
  final String guid;
  @override
  final String chatId;
  @override
  final String destinationCallerId;
  @override
  final int type;
  @override
  String get service => 'iMessage';
  @override
  String get sender => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  _FakeCloudMessage({this.type = 1});
  @override
  final int type;
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
  void Function()? onCommit;
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
    onCommit?.call();
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
