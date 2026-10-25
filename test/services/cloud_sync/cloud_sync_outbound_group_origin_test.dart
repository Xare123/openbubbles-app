import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_identity_evidence.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_identity_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_admission.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/api/cloud_sync_chat_identity.dart'
    as native;
import 'package:flutter_test/flutter_test.dart';

const _uuid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _guid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const _sender = 'sender@example.invalid';
const _members = ['+15550000002', 'member@example.invalid'];
final _now = DateTime.utc(2026, 10, 25);
final _scope = CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'chatManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
final _ref = 'obcs2.ref.${'P' * 43}';
final _lease = 'obcs2.lease.${'a' * 32}';

void main() {
  late Directory scratch;
  late Store db;
  late Chat chat;
  late Message message;
  late CloudSyncLocalSendJournal journal;
  late CloudSyncLocalSendAdmissionSource source;
  late ObjectBoxCloudSyncStore durable;
  final auth = CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: 'synthetic-group-session',
    accountFingerprint: _scope.accountFingerprint,
    protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
    cloudMessagesClient: Object(),
  );
  final fence = CloudSyncLocalSendAuthFence(
    expected: auth,
    capture: () async => auth,
    stillCurrent: () => true,
  );

  void bindStore({
    CloudSyncChatIdentityEvidence? Function(CloudOutboxOperation)?
    readChatIdentityEvidence,
  }) {
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: db,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final writerScope = CloudKitWriterScope(
      accountFingerprint: _scope.accountFingerprint,
    );
    if (authority.read(writerScope) == null) {
      final disabled = authority.initializeDisabled(writerScope, now: _now);
      authority.provisionInitialOwner(
        writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: const CloudKitWriterTransitionEvidence.forTest(
          operationsQuiesced: true,
          activeIdentityRevalidated: true,
          legacyMutationQueues: LegacyMutationQueueDisposition.empty,
        ),
        now: _now,
      );
    }
    journal = CloudSyncLocalSendJournal(
      store: db,
      authority: authority,
      authoritySnapshot: authority.read(writerScope)!,
    );
    durable = ObjectBoxCloudSyncStore(
      store: db,
      protector: _Protector(),
      clock: () => _now,
      localSendJournal: journal,
      readChatIdentityEvidence: readChatIdentityEvidence,
    );
  }

  setUp(() async {
    final root = Directory('build/test-temp')..createSync(recursive: true);
    scratch = await root.createTemp('fresh-group-origin-');
    db = await openStore(directory: scratch.path);
    bindStore();
    for (final zone in [
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      await durable.recordPullSuccess(
        CloudSyncScope(
          accountFingerprint: _scope.accountFingerprint,
          container: _scope.container,
          database: _scope.database,
          zone: zone,
          streamKind: _scope.streamKind,
          persistenceLane: _scope.persistenceLane,
        ),
        now: _now,
      );
    }
    final handles = [
      for (final member in _members)
        Handle(
          address: member,
          service: 'iMessage',
          uniqueAddressAndService: '$member/iMessage',
        ),
    ];
    db.box<Handle>().putMany(handles);
    chat = Chat(guid: _uuid, usingHandle: 'mailto:$_sender')
      ..handles.addAll(handles);
    db.box<Chat>().put(chat);
    message = Message(
      guid: 'temp-group-test',
      stagingGuid: _guid,
      text: 'synthetic group body',
      attributedBody: [AttributedBody.raw('synthetic group body')],
      isFromMe: true,
      dateCreated: _now,
    )..chat.target = chat;
    final identity = CloudSyncLocalSendIdentity.capture(message, chat, _guid)!;
    journal.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => db.box<Message>().put(message),
      now: _now,
    );
    message
      ..guid = _guid
      ..stagingGuid = null;
    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: () => db.box<Message>().put(message),
      now: _now,
    );
    source = journal.readForAdmission(journal.readReady().single.id);
  });

  tearDown(() async {
    db.close();
    final resolved = await scratch.resolveSymbolicLinks();
    expect(
      resolved.replaceAll('\\', '/'),
      endsWith(scratch.path.replaceAll('\\', '/')),
    );
    final files = await scratch.list(followLinks: false).toList();
    expect(
      files.every(
        (file) =>
            file is File &&
            const {
              'data.mdb',
              'lock.mdb',
            }.contains(file.path.replaceAll('\\', '/').split('/').last),
      ),
      true,
    );
    for (final file in files) {
      await file.delete();
    }
    await scratch.delete();
  });

  Future<CloudOutboxOperation> admit(
    CloudSyncOutboundChatStagingTransport transport, {
    api.CloudChat Function(CloudSyncLocalChatCreateOrigin)? encode,
    Future<CloudSyncChatIdentityEvidence?> Function(
      CloudSyncLocalChatCreateOrigin,
      CloudSyncProtectedOutboundStageData,
    )?
    observeChatIdentity,
  }) =>
      CloudSyncOutboundChatAdmissionCoordinator(
        store: durable,
        transport: transport,
        ensureProtectedStoreRecovered: () async {},
        observeChatIdentity: observeChatIdentity,
      ).admitChat(
        _scope,
        chatId: chat.id!,
        createdAt: _now,
        authFence: fence,
        localSendSource: source,
        encode:
            encode ??
            (origin) => _WireGroup(origin as CloudSyncOutboundGroupOrigin),
      );

  CloudOutboxOperationEntity queuedRow() =>
      db.box<CloudOutboxOperationEntity>().getAll().single;

  Future<List<CloudOutboxOperation>> leaseGroup() =>
      durable.leaseEligibleOutbox(
        _scope,
        now: _now,
        limit: 1,
        leaseId: 'synthetic-group-lease',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );

  Future<List<CloudOutboxOperation>> submitGroup(String operationId) =>
      durable.markOutboxSubmissionStarted(
        _scope,
        leaseId: 'synthetic-group-lease',
        submissionIdentity: CloudOutboxSubmissionIdentity(
          requestUuid: 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC',
          operationUuids: {operationId: 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD'},
        ),
        now: _now,
      );

  void seedAppliedChatSave() {
    final checkpoints = db.box<CloudSyncCheckpointEntity>();
    final checkpoint =
        checkpoints.getAll().singleWhere((row) => row.zone == _scope.zone)
          ..fetchedSequence = 1
          ..appliedSequence = 1
          ..fetchedTokenCiphertext = 'synthetic-applied-chat-cursor'
          ..lastBatchId = 'synthetic-applied-chat-batch';
    checkpoints.put(checkpoint);
    db.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: 'synthetic-applied-chat-identity',
        changeIdHash: 'H' * 43,
        scopeKey: cloudSyncPersistentScopeKey(_scope),
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        serverRecordIdHash: 'R' * 43,
        etagHash: 'E' * 43,
        changeType: 'save',
        encryptedServerRecordId: 'synthetic-applied-chat-record',
        encryptedPayloadRef: 'obcs2.ref.${'R' * 43}',
        payloadSha256: 'c' * 64,
        batchId: 'synthetic-applied-chat-batch',
        generation: checkpoint.generation,
        fetchSequence: 1,
        status: CloudInboxStatus.applied.index,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
  }

  for (final boundary in ['lease', 'submission']) {
    for (final defect in ['missing', 'stale']) {
      test('applied-only group evidence $defect blocks $boundary', () async {
        CloudSyncChatIdentityEvidence? evidence;
        bindStore(readChatIdentityEvidence: (_) => evidence);
        seedAppliedChatSave();
        late CloudSyncLocalChatCreateOrigin observedOrigin;
        late CloudSyncProtectedOutboundStageData observedStage;
        var observations = 0;
        Future<CloudSyncChatIdentityEvidence?> observe(
          CloudSyncLocalChatCreateOrigin origin,
          CloudSyncProtectedOutboundStageData stage,
        ) async {
          observedOrigin = origin;
          observedStage = stage;
          evidence = await CloudSyncChatIdentityEvidence.observe(
            store: db,
            origin: origin,
            stage: stage,
            auth: auth,
            authFence: fence,
            observer: (readSet, retained, candidate, local) async {
              observations++;
              expect(readSet.includeAppliedSaves, isTrue);
              expect(readSet.retainedSaves, hasLength(1));
              expect(identical(candidate, stage), isTrue);
              expect(
                local.binding(readSet.generation),
                origin.binding(readSet.generation),
              );
              return native.CloudSyncChatIdentityResult(
                comparison: native.CloudSyncChatIdentityComparison.disjoint,
                candidateBindingHash: 'I' * 43,
                stagedCandidateBindingHash: 'J' * 43,
                sourceBindingHash: retained.changeIdHash,
                nativeSessionId: auth.nativeSessionId,
              );
            },
          );
          return evidence;
        }

        final transport = _Staging();
        final operation = await admit(transport, observeChatIdentity: observe);
        final originalOrigin = queuedRow().localChatOrigin;
        expect(observations, 1);
        // Admission changes the checkpoint revision, so obtain fresh coverage
        // of the original stage before crossing either consuming boundary.
        await observe(observedOrigin, observedStage);
        if (boundary == 'submission') {
          expect(
            (await leaseGroup()).single.operationId,
            operation.operationId,
          );
        }
        if (defect == 'missing') {
          evidence = null;
        } else {
          final history = db.box<CloudInboxChangeEntity>().getAll().single
            ..etagHash = 'Z' * 43;
          db.box<CloudInboxChangeEntity>().put(history);
        }
        // Every save is still applied. A generic projection barrier must not
        // accidentally provide this test's refusal.
        final checkpoint = db
            .box<CloudSyncCheckpointEntity>()
            .getAll()
            .singleWhere((row) => row.zone == _scope.zone);
        expect(checkpoint.appliedSequence, checkpoint.fetchedSequence);
        expect(
          db.box<CloudInboxChangeEntity>().getAll().single.status,
          CloudInboxStatus.applied.index,
        );
        final refusal = defect == 'missing'
            ? throwsA(
                isA<CloudSyncFailure>().having(
                  (error) => error.safeCode,
                  'code',
                  'cloud_sync_chat_identity_evidence_required',
                ),
              )
            : throwsA(
                isA<StateError>().having(
                  (error) => error.message,
                  'code',
                  'cloud_sync_chat_identity_read_set_changed',
                ),
              );
        await expectLater(
          boundary == 'lease'
              ? leaseGroup()
              : submitGroup(operation.operationId),
          refusal,
        );
        expect(
          queuedRow().state,
          boundary == 'lease'
              ? CloudOutboxStatus.pending.index
              : CloudOutboxStatus.leased.index,
        );
        expect(queuedRow().appleRequestUuid, isNull);
        expect(queuedRow().appleOperationUuid, isNull);
        expect(queuedRow().localChatOrigin, originalOrigin);

        // Valid refreshed coverage advances this same operation; no new
        // stage, replacement record or Message is needed.
        await observe(observedOrigin, observedStage);
        if (boundary == 'lease') {
          expect(
            (await leaseGroup()).single.operationId,
            operation.operationId,
          );
        }
        await submitGroup(operation.operationId);
        expect(queuedRow().state, CloudOutboxStatus.unknownOutcome.index);
        expect(jsonDecode(queuedRow().localChatOrigin!)[0], 7);
        expect(
          queuedRow().encryptedPayloadRef,
          operation.encryptedPayloadReference,
        );
        expect(queuedRow().serverRecordIdHash, operation.serverRecordIdHash);
        expect(transport.stages, 1);
        expect(transport.rollbacks, 0);
        expect(observations, 3);
        expect(db.box<Message>().count(), 1);
        expect(db.box<Message>().get(message.id!)!.guid, _guid);
        expect(db.box<Message>().get(message.id!)!.chat.targetId, chat.id);
      });
    }
  }

  for (final boundary in ['lease', 'submission']) {
    test(
      'identity-only group queue cannot take legacy $boundary fallback',
      () async {
        final transport = _Staging();
        final operation = await admit(transport);
        final readyOrigin = queuedRow().localChatOrigin!;
        if (boundary == 'submission') {
          expect(
            (await leaseGroup()).single.operationId,
            operation.operationId,
          );
        }
        final identityOnly = cloudSyncOutboundChatOriginIdentity(readyOrigin);
        expect(decodeCloudSyncOutboundGroupOrigin(identityOnly)[0], 5);
        expect(cloudSyncOutboundChatOriginSendProof(identityOnly), isNull);
        db.box<CloudOutboxOperationEntity>().put(
          queuedRow()..localChatOrigin = identityOnly,
        );
        await expectLater(
          boundary == 'lease'
              ? leaseGroup()
              : submitGroup(operation.operationId),
          throwsA(
            isA<CloudSyncFailure>().having(
              (error) => error.safeCode,
              'code',
              'cloud_sync_outbound_chat_recovery_changed',
            ),
          ),
        );
        expect(
          queuedRow().state,
          boundary == 'lease'
              ? CloudOutboxStatus.pending.index
              : CloudOutboxStatus.leased.index,
        );
        expect(queuedRow().localChatOrigin, identityOnly);
        expect(queuedRow().appleRequestUuid, isNull);
        expect(queuedRow().appleOperationUuid, isNull);
        if (boundary == 'submission') {
          expect(
            () => cloudSyncSubmittedChatOrigin(identityOnly),
            throwsA(
              isA<CloudSyncFailure>().having(
                (error) => error.safeCode,
                'code',
                'cloud_sync_outbound_chat_origin_not_submitted',
              ),
            ),
          );
        }

        // Restore the test fixture's genuine admission proof as a positive
        // control for the same protected operation and complete empty inbox.
        db.box<CloudOutboxOperationEntity>().put(
          queuedRow()..localChatOrigin = readyOrigin,
        );
        if (boundary == 'lease') {
          expect(
            (await leaseGroup()).single.operationId,
            operation.operationId,
          );
        }
        await submitGroup(operation.operationId);
        expect(queuedRow().state, CloudOutboxStatus.unknownOutcome.index);
        expect(jsonDecode(queuedRow().localChatOrigin!)[0], 7);
        expect(
          queuedRow().encryptedPayloadRef,
          operation.encryptedPayloadReference,
        );
        expect(queuedRow().serverRecordIdHash, operation.serverRecordIdHash);
        expect(transport.stages, 1);
        expect(db.box<Message>().count(), 1);
        expect(db.box<Message>().get(message.id!)!.guid, _guid);
      },
    );
  }

  test('direct-only staging cannot acquire fresh-group authority', () async {
    await expectLater(
      admit(_DirectOnly()),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_outbound_group_staging_unavailable',
        ),
      ),
    );
    expect(db.box<CloudOutboxOperationEntity>().count(), 0);
  });

  test(
    'member drift after stage rolls back only the unadopted lease',
    () async {
      final transport = _Staging()
        ..onStage = () {
          final changed = db.box<Chat>().get(chat.id!)!..handles.removeLast();
          db.box<Chat>().put(changed);
        };
      await expectLater(
        admit(transport),
        throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())),
      );
      expect(transport.stages, 1);
      expect(transport.rollbacks, 1);
      expect(db.box<CloudOutboxOperationEntity>().count(), 0);
      expect(db.box<Message>().count(), 1);
    },
  );

  test('group origin binds sender membership metadata and account', () {
    final origin = CloudSyncOutboundGroupOrigin.capture(
      scope: _scope,
      chat: chat,
    );
    final identity = origin.binding(1);
    final changed = db.box<Chat>().get(chat.id!)!..groupVersion = 2;
    db.box<Chat>().put(changed);
    expect(() => origin.requireUnchanged(db), throwsStateError);
    expect(
      CloudSyncOutboundGroupOrigin.capture(
        scope: _scope,
        chat: changed,
      ).binding(1),
      isNot(identity),
    );
    final foreign = CloudSyncScope(
      accountFingerprint: 'B' * 43,
      container: _scope.container,
      database: _scope.database,
      zone: _scope.zone,
      streamKind: _scope.streamKind,
      persistenceLane: _scope.persistenceLane,
    );
    expect(
      CloudSyncOutboundGroupOrigin.capture(
        scope: foreign,
        chat: changed,
      ).binding(1),
      isNot(identity),
    );
    expect(
      () => decodeCloudSyncOutboundGroupOrigin('[6,1,1]'),
      throwsStateError,
    );
  });

  test(
    'fresh group has a distinct deterministic identity and no local mutation',
    () {
      final origin = CloudSyncOutboundGroupOrigin.capture(
        scope: _scope,
        chat: chat,
      );
      expect(origin.chatIdentifier, 'chataaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa');
      expect(origin.canonicalGuid, 'iMessage;+;${origin.chatIdentifier}');
      expect(chat.guid, _uuid);
      expect(chat.chatIdentifier, isNull);
      expect(
        () => CloudSyncOutboundChatOrigin.capture(scope: _scope, chat: chat),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(origin.binding(1), isNot(contains(_uuid)));
      expect(origin.binding(1), isNot(contains(_sender)));
      expect(origin.binding(1), isNot(contains(_members.first)));
      expect(jsonDecode(origin.binding(1))[0], 5);
      final ready = origin.binding(
        1,
        localSendProof: jsonEncode([1, 1, 'a' * 64]),
      );
      expect(cloudSyncOutboundChatOriginIdentity(ready), origin.binding(1));
      expect(jsonDecode(cloudSyncSubmittedChatOrigin(ready))[0], 7);
      expect(
        cloudSyncActiveChatOriginBinding(cloudSyncSubmittedChatOrigin(ready)),
        ready,
      );
      expect(
        cloudSyncChatOriginIsRetired(cloudSyncRetiredChatOrigin(ready)),
        true,
      );
      expect(
        () => cloudSyncRetiredChatOrigin(cloudSyncSubmittedChatOrigin(ready)),
        throwsA(isA<CloudSyncFailure>()),
      );
    },
  );

  test(
    'same stage and server identity survive a lost response and store reopen',
    () async {
      final transport = _Staging()..failCommit = true;
      await expectLater(admit(transport), throwsStateError);
      final original = durable.readOutboundChatCreateForLocalRow(
        _scope,
        chat.id!,
      )!;
      expect(transport.stages, 1);
      expect(transport.rollbacks, 0);
      db.close();
      db = await openStore(directory: scratch.path);
      bindStore();
      source = journal.readForAdmission(source.intentId);
      transport.failCommit = false;
      final recovered = await admit(transport);
      expect(recovered.operationId, original.operationId);
      expect(
        recovered.encryptedPayloadReference,
        original.encryptedPayloadReference,
      );
      expect(recovered.serverRecordIdHash, original.serverRecordIdHash);
      expect(transport.stages, 1);
      expect(db.box<Message>().count(), 1);
    },
  );

  test(
    'only authenticated submitted group readback adopts the original row',
    () async {
      final transport = _Staging();
      final operation = await admit(transport);
      final origin = CloudSyncOutboundGroupOrigin.capture(
        scope: _scope,
        chat: chat,
      );
      final payload = CloudChatEntityPayload(
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        canonicalGuid: origin.canonicalGuid,
        chatIdentifier: origin.chatIdentifier,
        groupId: _uuid,
        originalGroupId: _uuid,
        displayName: null,
        participantHandles: [
          'tel:${_members.first}',
          'mailto:${_members.last}',
        ],
        aliases: [
          CloudSemanticChatAlias(
            kind: CloudSemanticChatAliasKind.serviceIdentifier,
            keyHash: 'I' * 43,
          ),
          CloudSemanticChatAlias(
            kind: CloudSemanticChatAliasKind.groupId,
            keyHash: 'G' * 43,
          ),
        ],
        service: CloudSemanticService.iMessage,
        style: CloudSemanticChatStyle.group,
        lastAddressedHandleState: CloudSemanticFieldState.value,
        lastAddressedHandle: 'mailto:$_sender',
        groupVersionState: CloudSemanticFieldState.value,
        groupVersion: 1,
      );
      final adapter = ObjectBoxCanonicalSemanticEntityAdapter(
        store: db,
        activeScopeProvider: () =>
            CloudCanonicalActiveScope(scope: _scope, generation: 1),
        identityResolver: _Resolver(origin.canonicalGuid),
        semanticApplyEnabled: true,
        allowChatUpserts: true,
      );
      void project({CloudChatEntityPayload? incoming}) =>
          db.runInTransaction(TxMode.write, () {
            adapter.applyEntity(
              scope: _scope,
              generation: 1,
              payload: incoming ?? payload,
              snapshot: CloudSemanticSnapshot(
                kind: CloudEntityKind.chat,
                logicalEntityKeyHash: operation.logicalEntityKeyHash,
                immutableContentDigest: 'synthetic-group-payload',
                etagHash: 'E' * 43,
                encryptedRawRecordReference: 'obcs2.ref.${'R' * 43}',
              ),
            );
          });
      expect(project, throwsA(isA<CloudSyncFailure>()));
      expect(db.box<Chat>().get(chat.id!)!.guid, _uuid);
      final row = db.box<CloudOutboxOperationEntity>().getAll().single
        ..state = CloudOutboxStatus.unknownOutcome.index
        ..localChatOrigin = cloudSyncSubmittedChatOrigin(
          db.box<CloudOutboxOperationEntity>().getAll().single.localChatOrigin!,
        )
        ..appleRequestUuid = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC'
        ..appleOperationUuid = 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD';
      db.box<CloudOutboxOperationEntity>().put(row);
      final map = db.box<CloudRecordMapEntity>().getAll().single
        ..etagHash = 'E' * 43
        ..encryptedRawRecordRef = 'obcs2.ref.${'R' * 43}';
      db.box<CloudRecordMapEntity>().put(map);
      for (final change in ['members', 'sender', 'version', 'group-id']) {
        final wrong = CloudChatEntityPayload(
          logicalEntityKeyHash: payload.logicalEntityKeyHash,
          canonicalGuid: payload.canonicalGuid,
          chatIdentifier: payload.chatIdentifier,
          groupId: change == 'group-id' ? _guid : payload.groupId,
          originalGroupId: payload.originalGroupId,
          displayName: payload.displayName,
          aliases: payload.aliases,
          participantHandles: change == 'members'
              ? ['mailto:unrelated@example.invalid']
              : payload.participantHandles,
          service: payload.service,
          style: payload.style,
          lastAddressedHandleState: CloudSemanticFieldState.value,
          lastAddressedHandle: change == 'sender'
              ? 'mailto:unrelated@example.invalid'
              : payload.lastAddressedHandle,
          groupVersionState: CloudSemanticFieldState.value,
          groupVersion: change == 'version' ? 2 : payload.groupVersion,
        );
        expect(
          () => project(incoming: wrong),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(db.box<Chat>().get(chat.id!)!.guid, _uuid);
        expect(db.box<Chat>().count(), 1);
      }
      project();
      final adopted = db.box<Chat>().get(chat.id!)!;
      expect(adopted.guid, origin.canonicalGuid);
      expect(adopted.cloudGuid, _uuid);
      expect(adopted.style, 43);
      expect(db.box<Chat>().count(), 1);
      expect(db.box<Message>().get(message.id!)!.chat.targetId, chat.id);
      expect(
        journal.readForAdmission(source.intentId).sourceSha256,
        source.sourceSha256,
      );
    },
  );

  test(
    'changed native group identity rejects admission before staging',
    () async {
      final transport = _Staging();
      await expectLater(
        admit(
          transport,
          encode: (origin) => _WireGroup(
            origin as CloudSyncOutboundGroupOrigin,
            changedGroupId: true,
          ),
        ),
        throwsStateError,
      );
      expect(transport.stages, 0);
      expect(db.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );
}

final class _WireGroup implements api.CloudChat {
  _WireGroup(this.origin, {this.changedGroupId = false});
  final CloudSyncOutboundGroupOrigin origin;
  final bool changedGroupId;
  @override
  String get guid => origin.canonicalGuid;
  @override
  String get chatIdentifier => origin.chatIdentifier;
  @override
  String get groupId => changedGroupId ? _guid : origin.originalGuid;
  @override
  String get originalGroupId => origin.originalGuid;
  @override
  String get lastAddressedHandle => origin.usingHandle;
  @override
  String get serviceName => 'iMessage';
  @override
  int get style => 43;
  @override
  String? get displayName => origin.displayName;
  @override
  api.CloudProp? get properties => api.CloudProp(
    pv: origin.groupVersion,
    numberOfTimesRespondedtoThread: 3,
    shouldForceToSms: false,
    legacyGroupIdentifiers: [],
    messageHandshakeState: 1,
  );
  @override
  api.Asset? get groupPhoto => null;
  @override
  String? get groupPhotoGuid => null;
  @override
  List<api.CloudParticipant> get participants =>
      origin.members.map((uri) => api.CloudParticipant(uri: uri)).toList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Staging implements CloudSyncOutboundGroupChatStagingTransport {
  int stages = 0, rollbacks = 0;
  bool failCommit = false;
  void Function()? onStage;
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundGroupChat(
    CloudSyncScope scope, {
    required api.CloudChat chat,
  }) async {
    stages++;
    onStage?.call();
    return CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: 'L' * 43,
      protectedEnvelopeReference: _ref,
      payloadSha256: 'b' * 64,
      serverRecordIdHash: 'S' * 43,
      leaseReference: _lease,
    );
  }

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundChat(
    CloudSyncScope scope, {
    required api.CloudChat chat,
  }) => throw StateError('fresh group cannot use direct staging');
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required api.CloudMessage message,
  }) => throw StateError('no message staging in this test');
  @override
  Future<void> commitOutboundLease(String lease, String reference) async {
    if (failCommit) throw StateError('synthetic native commit uncertainty');
  }

  @override
  Future<void> rollbackOutboundLease(String lease) async {
    rollbacks++;
  }
}

final class _DirectOnly implements CloudSyncOutboundChatStagingTransport {
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Resolver implements CloudCanonicalIdentityResolver {
  _Resolver(this.guid);
  final String guid;
  @override
  String? resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) => guid;
  @override
  CloudCanonicalIdentityOwner? resolveCanonicalIdentityOwner({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) => canonicalGuid == guid
      ? CloudCanonicalIdentityOwner(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: 'L' * 43,
        )
      : null;
}

final class _Protector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      _scope.accountFingerprint;
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'synthetic:$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext.substring('synthetic:'.length);
}
