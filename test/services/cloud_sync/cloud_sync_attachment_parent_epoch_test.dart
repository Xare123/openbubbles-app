// Adopted-parent evidence across writer-epoch recovery.
//
// Counterexample coverage for the retained-epoch reader: an intent and its
// children prepared at epoch E must stay readable through E+1 (unknown) and
// E+2 (post-reconciliation) for evidence-only paths (adopted source read,
// dispatch confirmation, v4 proof revalidation), while fresh writes (new
// attempts, new plans) stay epoch-strict and future-epoch rows are rejected.
// Admission itself runs pre-rotation through the real journal and store paths;
// only the epoch boundary is crossed synthetically via the writer authority.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot authoritySnapshot;
  late CloudSyncLocalSendJournal localSends;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncAttachmentUploadJournal uploads;
  late Chat chat;
  late Map<int, Set<String>> attachmentInventories;
  late int originalEpoch;

  void provisionJournal() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    if (authority.read(_writerScope) == null) {
      final disabled = authority.initializeDisabled(_writerScope, now: _time(0));
      authority.provisionInitialOwner(
        _writerScope,
        owner: CloudKitWriterOwner.v2,
        expectedEpoch: disabled.epoch,
        evidence: _completeEvidence,
        now: _time(1),
      );
    }
    authoritySnapshot = authority.read(_writerScope)!;
    localSends = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authoritySnapshot,
      attachmentParentReadback: (intentId, retainedProof) {
        if (retainedProof != null) {
          uploads.requireParentReadbackProof(localSendIntentId: intentId, proof: retainedProof);
          return retainedProof;
        }
        final keys = attachmentInventories[intentId];
        if (keys == null) throw StateError('missing inventory');
        return uploads.captureParentReadbackProof(localSendIntentId: intentId, sourceAttachmentKeys: keys);
      },
    );
  }

  void seedCheckpoint(CloudSyncScope scope, int generation) {
    final box = store.box<CloudSyncCheckpointEntity>();
    final key = cloudSyncPersistentScopeKey(scope);
    final query = box.query(CloudSyncCheckpointEntity_.checkpointKey.equals(key)).build();
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
        zone: scope.zone,
        streamKind: 'messages',
        schemaVersion: 2,
        persistenceLane: 'semantic',
        generation: generation,
        updatedAtMs: _time(0).millisecondsSinceEpoch,
      ),
    );
  }

  ObjectBoxCloudSyncStore liveStore() => ObjectBoxCloudSyncStore(
        store: store,
        protector: _FakeProtector(),
        localSendJournal: localSends,
        attachmentUploadJournal: uploads,
        clock: () => _time(30),
      );

  void seedAccountReadReady() {
    final box = store.box<CloudSyncCheckpointEntity>();
    for (final zone in ['chatManateeZone', 'messageManateeZone', 'attachmentManateeZone']) {
      final scope = CloudSyncScope(
        accountFingerprint: _accountA,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: zone,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final key = cloudSyncPersistentScopeKey(scope);
      final query = box.query(CloudSyncCheckpointEntity_.checkpointKey.equals(key)).build();
      final CloudSyncCheckpointEntity row;
      try {
        row = query.findUnique() ??
            CloudSyncCheckpointEntity(
              checkpointKey: key,
              accountFingerprint: _accountA,
              container: scope.container,
              database: scope.database,
              zone: zone,
              streamKind: 'messages',
              schemaVersion: 2,
              persistenceLane: 'semantic',
              generation: 1,
              updatedAtMs: _time(0).millisecondsSinceEpoch,
            );
      } finally {
        query.close();
      }
      row.lastSuccessfulAtMs = _time(5).millisecondsSinceEpoch;
      box.put(row);
    }
  }

  CloudSyncAttachmentUploadJournal buildUploads() => CloudSyncAttachmentUploadJournal(
        store: store,
        localSends: localSends,
        scope: _uploadScope,
        checkpointGeneration: 1,
        currentAuth: auth,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('openbubbles-attachment-parent-epoch-');
    store = await openStore(directory: directory.path);
    attachmentInventories = {};
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
    auth = _auth(Object());
    seedCheckpoint(_uploadScope, 1);
    uploads = buildUploads();
    originalEpoch = authoritySnapshot.epoch;
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    provisionJournal();
    auth = _auth(Object());
    uploads = buildUploads();
  }

  int seedConfirmedIntent({String stableGuid = _guidA, String attachmentGuid = 'LOCAL-ATTACHMENT-A'}) {
    final attachment = Attachment(
      guid: attachmentGuid,
      metadata: const {'rustpush': '<attachment><id>A</id></attachment>'},
    );
    store.box<Attachment>().put(attachment);
    final message = _attachmentMessage(stableGuid: stableGuid, attachmentGuid: attachmentGuid);
    message.chat.target = chat;
    message.dbAttachments.add(attachment);
    final identity = CloudSyncLocalSendIdentity.captureAttachment(message, chat, stableGuid)!;
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
    attachment.guid = '${stableGuid}_0';
    store.box<Attachment>().put(attachment);
    message
      ..guid = stableGuid
      ..stagingGuid = null
      ..text = ' '
      ..attributedBody = [
        AttributedBody(
          string: ' ',
          runs: [Run(range: const [0, 1], attributes: Attributes(attachmentGuid: attachment.guid))],
        ),
      ];
    store.box<Message>().put(message);
    final intentId = localSends.recordNativeSendConfirmation(
      stableGuid: stableGuid,
      succeeded: true,
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(4),
      protectedSource: source,
    )!;
    localSends.promoteIdsConfirmedDeferred(intentId: intentId, currentAuth: auth, now: _time(5));
    return intentId;
  }

  int seedPlaintextIntent({String stableGuid = _guidA}) {
    final message = Message(
      guid: 'local-$stableGuid',
      text: 'hello',
      dateCreated: _time(1),
      isFromMe: true,
      hasAttachments: false,
      attributedBody: [AttributedBody.raw('hello')],
      stagingGuid: stableGuid,
    );
    message.chat.target = chat;
    final identity = CloudSyncLocalSendIdentity.capture(message, chat, stableGuid)!;
    localSends.saveSubmission(
      identity: identity,
      newlyGeneratedGuid: true,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(2),
    );
    message
      ..guid = stableGuid
      ..stagingGuid = null;
    store.box<Message>().put(message);
    localSends.saveConfirmedSubmission(
      identity: identity,
      persistMessage: () => store.box<Message>().put(message),
      now: _time(3),
    );
    final query = store.box<CloudSyncLocalSendIntentEntity>().query(
      CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(identity.guidHash),
    ).build();
    try {
      return query.findUnique()!.id;
    } finally {
      query.close();
    }
  }

  int adoptUpload(int intentId, CloudSyncProtectedOutboundStageData plan,
      CloudSyncProtectedOutboundStageData result, String attemptId) {
    final prepared = uploads.adoptPlan(localSendIntentId: intentId, plan: plan, now: _time(6));
    uploads.beginAttempt(id: prepared.id, attemptId: attemptId, now: _time(7));
    uploads.recordUploaded(id: prepared.id, attemptId: attemptId, result: result, now: _time(8));
    uploads.adoptRecordCreate(
      id: prepared.id,
      admit: (tx, admitted) {
        _persistFinalOperation(tx, admitted);
        return _finalOperation(admitted);
      },
      now: _time(9),
    );
    return prepared.id;
  }

  int admitUpload(int uploadId) {
    uploads.adoptRecordCreate(
      id: uploadId,
      admit: (tx, admitted) {
        _persistFinalOperation(tx, admitted);
        return _finalOperation(admitted);
      },
      now: _time(9),
    );
    return uploadId;
  }

  void releaseUpload(int uploadId) {
    final admittedOperationId = uploads.read(uploadId).admittedOperationId!;
    final box = store.box<CloudOutboxOperationEntity>();
    final query = box.query(CloudOutboxOperationEntity_.operationId.equals(admittedOperationId)).build();
    try {
      final row = query.findUnique()!;
      row
        ..state = CloudOutboxStatus.confirmed.index
        ..confirmedAtMs = _time(20).millisecondsSinceEpoch
        ..appleRequestUuid = _requestUuid
        ..appleOperationUuid = _operationUuid
        ..protectedLeaseReference = null
        ..leaseIdHash = null
        ..leaseExpiresAtMs = 0
        ..nextEligibleAtMs = 0
        ..lastErrorCategory = null
        ..updatedAtMs = _time(20).millisecondsSinceEpoch;
      box.put(row);
    } finally {
      query.close();
    }
  }

  void releaseChild(int intentId, CloudSyncProtectedOutboundStageData plan,
      CloudSyncProtectedOutboundStageData result, String attemptId) {
    releaseUpload(adoptUpload(intentId, plan, result, attemptId));
  }

  Future<void> seedRestoredChat() async {
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: store,
      store: liveStore(),
      chatScope: _chatScope,
      now: _time(9),
    );
    await seedSyntheticRestoredChatProof(
      objectBox: store,
      store: liveStore(),
      chatScope: _chatScope,
      chat: chat,
      appliedSource: applied,
      now: _time(9),
    );
  }

  CloudOutboxOperation _messageOperation() => CloudOutboxOperation(
        scope: _messageScope,
        operationId: CloudOperationIdentity.forInitialCreate(
          scope: _messageScope,
          logicalEntityKeyHash: _token('M'),
          payloadVersion: cloudSyncOutboundPayloadVersion,
        ),
        logicalEntityKeyHash: _token('M'),
        action: CloudOutboxAction.save,
        payloadVersion: cloudSyncOutboundPayloadVersion,
        mutationRevision: 1,
        checkpointGeneration: 1,
        dependencyOperationIds: const {},
        createdAt: _time(2),
        encryptedPayloadReference: _ref('P'),
        payloadSha256: _digest('d'),
        serverRecordIdHash: _token('S'),
        protectedLeaseReference: _lease('b'),
      );

  Future<AdmittedParent> admitParent(int intentId, Set<String> keys) async {
    attachmentInventories[intentId] = keys;
    await seedRestoredChat();
    final operation = _messageOperation();
    final source = localSends.readForAdmission(intentId);
    store.runInTransaction(TxMode.write, () {
      localSends.adoptInOutboxTransaction(store, source, operation);
    });
    final intent = store.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;
    expect(intent.state, 2);
    final binding = jsonDecode(intent.admittedChatBinding!) as List;
    // Attachment intents admit a v4 [4, chat, proof] wrapper; ordinary
    // plaintext intents admit their v1 chat binding directly.
    final proof = binding.first == 4 ? binding[2] as String : null;
    return AdmittedParent(operation: operation, proof: proof);
  }

  Future<void> rotateUnknown() async {
    final permit = authority.issuePermit(_writerScope, expectedOwner: CloudKitWriterOwner.v2);
    authority.markMutationUnknown(permit, now: _time(30));
    expect(authority.read(_writerScope)!.epoch, originalEpoch + 1);
    provisionJournal();
    auth = _auth(Object());
    uploads = buildUploads();
    seedAccountReadReady();
  }

  Future<void> reconcileFence() async {
    authority.reconcileMutationFence(_writerScope, owner: CloudKitWriterOwner.v2, fencedEpoch: originalEpoch, now: _time(31));
    expect(authority.read(_writerScope)!.epoch, originalEpoch + 2);
    provisionJournal();
    auth = _auth(Object());
    uploads = buildUploads();
  }

  test('E+1 unknown: adopted-parent evidence read survives', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {key});
    await rotateUnknown();
    final source = localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: auth);
    expect(source, isNotNull);
    final intentRow = store.box<CloudSyncLocalSendIntentEntity>().get(intent)!;
    expect(source!.messageGuidHash, intentRow.messageGuidHash);
    expect(source.sourceSha256, intentRow.sourceSha256);
  });

  test('E+2 post-reconciliation: dispatch revalidation passes on retained proof', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {key});
    await rotateUnknown();
    await reconcileFence();
    final expected = localSends.readAdoptedCreateSource(store, admitted.operation);
    expect(expected, isNotNull);
    localSends.requireIdsConfirmationForDispatch(expected!);
    expect(admitted.proof, isNotNull);
    localSends.requireAttachmentParentReadback(expected, admitted.proof!);
    final fresh = uploads.captureParentReadbackProof(localSendIntentId: intent, sourceAttachmentKeys: [key]);
    expect(fresh, admitted.proof);
  });

  test('new attempts and plans stay epoch-strict after rotation', () async {
    final intent = seedConfirmedIntent();
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    await admitParent(intent, {_planA().logicalEntityKeyHash});
    final staged = uploads.adoptPlan(localSendIntentId: intent, plan: _planB(), now: _time(6));
    await rotateUnknown();
    expect(
      () => uploads.beginAttempt(id: staged.id, attemptId: _attemptB, now: _time(32)),
      throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
    );
    expect(
      () => uploads.adoptPlan(localSendIntentId: intent, plan: _planC(), now: _time(32)),
      throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
    );
  });

  test('retained first attempt resumes a prepared child after rotation', () async {
    final intent = seedConfirmedIntent();
    final keyA = _planA().logicalEntityKeyHash;
    final keyB = _planB().logicalEntityKeyHash;
    final keyC = _planC().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final stagedB = uploads.adoptPlan(localSendIntentId: intent, plan: _planB(), now: _time(6));
    final stagedC = uploads.adoptPlan(localSendIntentId: intent, plan: _planC(), now: _time(6));
    uploads.beginAttempt(id: stagedC.id, attemptId: _attemptC, now: _time(7));
    uploads.markUnknown(id: stagedC.id, attemptId: _attemptC, now: _time(8));
    await rotateUnknown();
    await reconcileFence();
    final keys = [keyA, keyB, keyC];
    // Unknown rows cannot take a retained attempt, even with complete inventory.
    expect(
      () => uploads.beginRetainedAttempt(id: stagedC.id, attemptId: _attemptB, sourceAttachmentKeys: keys, now: _time(32)),
      throwsA(_stateFailure('cloud_sync_attachment_upload_already_attempted')),
    );
    // Incomplete inventory refuses before any state change.
    expect(
      () => uploads.beginRetainedAttempt(id: stagedB.id, attemptId: _attemptB, sourceAttachmentKeys: [keyA, keyB], now: _time(32)),
      throwsA(_stateFailure('cloud_sync_attachment_upload_inventory_changed')),
    );
    expect(uploads.read(stagedB.id).state, CloudAttachmentUploadState.prepared);
    // Complete inventory authorizes the first attempt on the prepared row.
    final started = uploads.beginRetainedAttempt(id: stagedB.id, attemptId: _attemptB, sourceAttachmentKeys: keys, now: _time(32));
    expect(started.state, CloudAttachmentUploadState.started);
    expect(started.attemptId, _attemptB);
    // The resumed child completes through the existing result/admission path.
    uploads.recordUploaded(id: stagedB.id, attemptId: _attemptB, result: _resultB(), now: _time(33));
    final adoptedB = admitUpload(stagedB.id);
    expect(uploads.read(adoptedB).state, CloudAttachmentUploadState.adopted);
    releaseUpload(adoptedB);
    final released = uploads.read(adoptedB);
    expect(released.admittedOperationId, isNotNull);
    expect(released.result!.leaseReference, _resultB().leaseReference);
  });

  test('retained attempt rejects invalid attempt identity', () async {
    final intent = seedConfirmedIntent();
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final stagedB = uploads.adoptPlan(localSendIntentId: intent, plan: _planB(), now: _time(6));
    await rotateUnknown();
    await reconcileFence();
    expect(
      () => uploads.beginRetainedAttempt(id: stagedB.id, attemptId: 'bad-attempt', sourceAttachmentKeys: [_planA().logicalEntityKeyHash, _planB().logicalEntityKeyHash], now: _time(32)),
      throwsA(_stateFailure('cloud_sync_attachment_upload_attempt_invalid')),
    );
    expect(uploads.read(stagedB.id).state, CloudAttachmentUploadState.prepared);
  });

  test('future-epoch rows are rejected by the retained reader', () async {
    final intent = seedConfirmedIntent();
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {_planA().logicalEntityKeyHash});
    await rotateUnknown();
    final box = store.box<CloudSyncLocalSendIntentEntity>();
    final row = box.get(intent)!;
    final originalWriterEpoch = row.writerEpoch;
    try {
      row.writerEpoch = originalEpoch + 10;
      box.put(row);
      expect(
        () => localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: auth),
        throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
      );
    } finally {
      row.writerEpoch = originalWriterEpoch;
      box.put(row);
    }
    expect(
      localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: auth),
      isNotNull,
    );
  });

  test('cross-account reads and tampered rows are rejected', () async {
    final intent = seedConfirmedIntent();
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {_planA().logicalEntityKeyHash});
    await rotateUnknown();
    final foreignAuth = _auth(Object(), account: _accountB);
    expect(
      () => localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: foreignAuth),
      throwsStateError,
    );
    final box = store.box<CloudSyncLocalSendIntentEntity>();
    final row = box.get(intent)!;
    final originalSource = row.sourceSha256;
    try {
      row.sourceSha256 = _digest('z');
      box.put(row);
      expect(
        () => localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: auth),
        throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
      );
    } finally {
      row.sourceSha256 = originalSource;
      box.put(row);
    }
    expect(
      localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: auth),
      isNotNull,
    );
  });

  test('fresh group dependency pin rejects non-group and null expected', () {
    final freshIntent = seedConfirmedIntent();
    final source = localSends.readForAdmission(freshIntent);
    // Direct (non-group) attachment message cannot satisfy the group pin,
    // without needing any restored group projection.
    expect(
      () => localSends.requireFreshAttachmentGroupDependency(_messageScope, source, _ref('P')),
      throwsA(_stateFailure('cloud_sync_local_send_adoption_changed')),
    );
    // Null expected binding fails before any restored lookup.
    expect(
      () => localSends.requireFreshAttachmentGroupDependency(_messageScope, source, null),
      throwsA(_stateFailure('cloud_sync_local_send_adoption_changed')),
    );
  });

  test('ordinary plaintext adoption returns null from both attachment readers', () async {
    final intent = seedPlaintextIntent();
    final admitted = await admitParent(intent, const {});
    final operationId = admitted.operation.operationId;
    expect(
      localSends.readAdoptedAttachmentChatDependency(operationId: operationId, currentAuth: auth),
      isNull,
    );
    expect(
      localSends.readAdoptedAttachmentSource(operationId: operationId, currentAuth: auth),
      isNull,
    );
  });

  test('wrong protected store rejects both attachment readers', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {key});
    final operationId = admitted.operation.operationId;
    final foreignAuth = _auth(Object(), store: _storeB);
    expect(
      () => localSends.readAdoptedAttachmentChatDependency(operationId: operationId, currentAuth: foreignAuth),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_changed')),
    );
    expect(
      () => localSends.readAdoptedAttachmentSource(operationId: operationId, currentAuth: foreignAuth),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_changed')),
    );
    expect(
      localSends.readAdoptedAttachmentChatDependency(operationId: operationId, currentAuth: auth),
      isNotNull,
    );
  });

  test('adopted chat dependency survives epoch rotation and message deletion', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {key});
    String expectedChat() {
      final row = store.box<CloudSyncLocalSendIntentEntity>().get(intent)!;
      return (jsonDecode(row.admittedChatBinding!) as List)[1] as String;
    }
    expect(
      localSends.readAdoptedAttachmentChatDependency(operationId: admitted.operation.operationId, currentAuth: auth),
      expectedChat(),
    );
    // Local deletion must not remove the adopted dependency, and the source
    // read stays independent of the mutable Message as well.
    final intents = store.box<CloudSyncLocalSendIntentEntity>();
    final messages = store.box<Message>();
    final doomed = messages.get(intents.get(intent)!.localMessageId)!;
    doomed.dateDeleted = _time(25);
    messages.put(doomed);
    expect(
      localSends.readAdoptedAttachmentChatDependency(operationId: admitted.operation.operationId, currentAuth: auth),
      expectedChat(),
    );
    expect(
      localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: auth),
      isNotNull,
    );
    await rotateUnknown();
    expect(
      localSends.readAdoptedAttachmentChatDependency(operationId: admitted.operation.operationId, currentAuth: auth),
      expectedChat(),
    );
    await reconcileFence();
    expect(
      localSends.readAdoptedAttachmentChatDependency(operationId: admitted.operation.operationId, currentAuth: auth),
      expectedChat(),
    );
    expect(
      localSends.readAdoptedAttachmentChatDependency(
        operationId: 'op1:${List.filled(64, '0').join()}',
        currentAuth: auth,
      ),
      isNull,
    );
  });

  test('malformed chat wrapper rejects without touching fresh paths', () async {
    final intent = seedConfirmedIntent();
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {_planA().logicalEntityKeyHash});
    String readChat() => localSends.readAdoptedAttachmentChatDependency(
      operationId: admitted.operation.operationId,
      currentAuth: auth,
    )!;
    final pristine = readChat();
    final box = store.box<CloudSyncLocalSendIntentEntity>();
    final row = box.get(intent)!;
    final original = row.admittedChatBinding;
    try {
      row.admittedChatBinding = 'garbage';
      box.put(row);
      expect(
        () => localSends.readAdoptedAttachmentChatDependency(operationId: admitted.operation.operationId, currentAuth: auth),
        throwsA(_stateFailure('cloud_sync_local_send_adoption_changed')),
      );
      row.admittedChatBinding = '[]';
      box.put(row);
      expect(
        () => localSends.readAdoptedAttachmentChatDependency(operationId: admitted.operation.operationId, currentAuth: auth),
        throwsA(_stateFailure('cloud_sync_local_send_adoption_changed')),
      );
      row.admittedChatBinding = jsonEncode([4, '[]', pristine]);
      box.put(row);
      expect(
        () => localSends.readAdoptedAttachmentChatDependency(operationId: admitted.operation.operationId, currentAuth: auth),
        throwsA(_stateFailure('cloud_sync_local_send_adoption_changed')),
      );
    } finally {
      row.admittedChatBinding = original;
      box.put(row);
    }
    expect(readChat(), pristine);
  });

  test('E+2 verified release writes the exact readback marker for an E-adopted parent', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {key});
    final operationId = admitted.operation.operationId;
    // Copy the immutable admitted operation header verbatim: fabricating it
    // (for example the default payloadVersion 1 versus the admitted
    // cloudSyncOutboundPayloadVersion) makes the lease reject the row.
    final admittedOperation = admitted.operation;
    store.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: operationId,
        scopeKey: cloudSyncPersistentScopeKey(_messageScope),
        accountFingerprint: _accountA,
        zone: 'messageManateeZone',
        logicalEntityKeyHash: admittedOperation.logicalEntityKeyHash,
        action: admittedOperation.action.index,
        checkpointGeneration: admittedOperation.checkpointGeneration,
        mutationRevision: admittedOperation.mutationRevision,
        payloadVersion: admittedOperation.payloadVersion,
        encryptedPayloadRef: admittedOperation.encryptedPayloadReference,
        payloadSha256: admittedOperation.payloadSha256,
        protectedLeaseReference: admittedOperation.protectedLeaseReference,
        serverRecordIdHash: admittedOperation.serverRecordIdHash,
        createdAtMs: admittedOperation.createdAt.millisecondsSinceEpoch,
        updatedAtMs: _time(9).millisecondsSinceEpoch,
      ),
    );
    seedAccountReadReady();
    await liveStore().upsertRecordMap(
      CloudRecordMapEntry(
        scope: _messageScope,
        logicalEntityKeyHash: _token('M'),
        serverRecordIdHash: _token('S'),
        encryptedServerRecordId: _ref('P'),
        updatedAt: _time(9),
      ),
      generation: 1,
    );
    final leased = await liveStore().leaseEligibleOutbox(
      _messageScope,
      now: _time(10),
      limit: 1,
      leaseId: 'marker-lease',
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    // Probe: surface which dispatch gate the lease sees.
    expect(leased.single.operationId, operationId);
    final outbox = store.box<CloudOutboxOperationEntity>();
    final leaseQuery = outbox.query(CloudOutboxOperationEntity_.operationId.equals(operationId)).build();
    try {
      final row = leaseQuery.findUnique()!;
      row
        ..appleRequestUuid = _requestUuid
        ..appleOperationUuid = _operationUuid
        ..updatedAtMs = _time(10).millisecondsSinceEpoch;
      outbox.put(row);
    } finally {
      leaseQuery.close();
    }
    await liveStore().commitOutboxCreateReceipt(
      _messageScope,
      leaseId: 'marker-lease',
      receipt: CloudOutboxCreateReceipt(
        operationId: operationId,
        logicalEntityKeyHash: _token('M'),
        serverRecordIdHash: _token('S'),
        etagHash: _token('E'),
      ),
      retainProtectedLeaseReference: true,
      now: _time(11),
    );
    await rotateUnknown();
    await reconcileFence();
    var current = (await liveStore().readOutboxEntries(_messageScope)).single;
    expect(current.status, CloudOutboxStatus.confirmed);
    expect(current.protectedLeaseReference, isNotNull);
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(intent)!.confirmedReadbackBindingSha256, isNull);
    // The verified release path (exact no-save replay already proven by the
    // transport) writes the marker and clears the retained lease even
    // though the adoption predates the binding epoch by two generations.
    await liveStore().clearConfirmedProtectedOutboundLeaseReference(
      expectedOperation: current,
      recordVerifiedLocalSendReadback: true,
    );
    current = (await liveStore().readOutboxEntries(_messageScope)).single;
    expect(current.protectedLeaseReference, isNull);
    final marked = store.box<CloudSyncLocalSendIntentEntity>().get(intent)!;
    expect(marked.confirmedReadbackBindingSha256, isNotNull);
    expect(marked.confirmedReadbackBindingSha256, marked.admittedBindingSha256);
  });

  test('store retained admission admits a rotated state-1 parent with live proof', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    attachmentInventories[intent] = {key};
    await seedRestoredChat();
    await rotateUnknown();
    await reconcileFence();
    await reopen();
    final source = localSends.readForAdmission(intent);
    final operation = liveStore().admitProtectedLocalSendCreate(
      draft: _messageDraft(),
      recordMapping: _messageMapping(),
      journal: localSends,
      source: source,
      attachmentParentChatBinding: null,
      retainedAttachmentResume: true,
    );
    final row = store.box<CloudSyncLocalSendIntentEntity>().get(intent)!;
    expect(row.state, 2);
    expect(row.writerEpoch, originalEpoch);
    expect(row.admittedOperationId, operation.operationId);
    final binding = jsonDecode(row.admittedChatBinding!) as List;
    expect(binding.first, 4);
    expect(
      uploads.captureParentReadbackProof(localSendIntentId: intent, sourceAttachmentKeys: [key]),
      binding[2] as String,
    );
    expect(operation.logicalEntityKeyHash, _token('M'));
  });

  test('store retained admission rejects flag-false on a rotated parent', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    attachmentInventories[intent] = {key};
    await seedRestoredChat();
    await rotateUnknown();
    await reconcileFence();
    await reopen();
    final source = localSends.readForAdmission(intent);
    expect(
      () => liveStore().admitProtectedLocalSendCreate(
        draft: _messageDraft(),
        recordMapping: _messageMapping(),
        journal: localSends,
        source: source,
        attachmentParentChatBinding: null,
        retainedAttachmentResume: false,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
    );
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(intent)!.state, 1);
  });

  test('store retained admission rejects an unreleased child', () async {
    final intent = seedConfirmedIntent();
    uploads.adoptPlan(localSendIntentId: intent, plan: _planA(), now: _time(6));
    attachmentInventories[intent] = {_planA().logicalEntityKeyHash};
    await seedRestoredChat();
    await rotateUnknown();
    await reconcileFence();
    await reopen();
    final source = localSends.readForAdmission(intent);
    expect(
      () => liveStore().admitProtectedLocalSendCreate(
        draft: _messageDraft(),
        recordMapping: _messageMapping(),
        journal: localSends,
        source: source,
        attachmentParentChatBinding: null,
        retainedAttachmentResume: true,
      ),
      throwsA(_stateFailure('cloud_sync_attachment_upload_result_missing')),
    );
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(intent)!.state, 1);
  });

  test('old plaintext refuses retained admission and evidence reads', () async {
    final intent = seedPlaintextIntent();
    await rotateUnknown();
    await reconcileFence();
    await reopen();
    expect(
      () => localSends.readForAdmission(intent),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_missing')),
    );
    final journal = localSends;
    expect(
      () => liveStore().admitProtectedLocalSendCreate(
        draft: _messageDraft(),
        recordMapping: _messageMapping(),
        journal: journal,
        source: journal.readForAdmission(intent),
        attachmentParentChatBinding: null,
        retainedAttachmentResume: true,
      ),
      throwsStateError,
    );
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(intent)!.state, 1);
  });

  test('ready listing merges old protected attachments, never plaintext', () async {
    final attachIntent = seedConfirmedIntent();
    final plainIntent = seedPlaintextIntent(stableGuid: _guidC);
    await rotateUnknown();
    await reconcileFence();
    final ready = localSends.readReady();
    expect(ready.map((e) => e.id), contains(attachIntent));
    expect(ready.map((e) => e.id), isNot(contains(plainIntent)));
    expect(ready.singleWhere((e) => e.id == attachIntent).writerEpoch, originalEpoch);
    localSends.markAdmissionConsidered(attachIntent, now: _time(40));
    expect(
      () => localSends.markAdmissionConsidered(plainIntent, now: _time(40)),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_missing')),
    );
    final attachRow = store.box<CloudSyncLocalSendIntentEntity>().get(attachIntent)!;
    final exact = localSends.readExactIntent(
      intentId: attachIntent,
      expectedRecipient: 'person@example.com',
      expectedSourceSha256: attachRow.sourceSha256,
    );
    expect(exact.intentId, attachIntent);
    final plainRow = store.box<CloudSyncLocalSendIntentEntity>().get(plainIntent)!;
    expect(
      () => localSends.readExactIntent(
        intentId: plainIntent,
        expectedRecipient: 'person@example.com',
        expectedSourceSha256: plainRow.sourceSha256,
      ),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_missing')),
    );
    final box = store.box<CloudSyncLocalSendIntentEntity>();
    final forged = box.get(attachIntent)!;
    final originalWriterEpoch = forged.writerEpoch;
    try {
      forged.writerEpoch = originalEpoch + 10;
      box.put(forged);
      expect(
        () => localSends.readForAdmission(attachIntent),
        throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
      );
      expect(
        () => localSends.markAdmissionConsidered(attachIntent, now: _time(41)),
        throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
      );
    } finally {
      forged.writerEpoch = originalWriterEpoch;
      box.put(forged);
    }
    expect(localSends.readForAdmission(attachIntent).intentId, attachIntent);
  });

  test('stale authority blocks retained reads until journals rebuild', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    final admitted = await admitParent(intent, {key});
    final permit = authority.issuePermit(_writerScope, expectedOwner: CloudKitWriterOwner.v2);
    authority.markMutationUnknown(permit, now: _time(30));
    // Deliberately no rebuild: the binding still pins the old epoch.
    expect(
      () => localSends.readAdoptedAttachmentSource(operationId: admitted.operation.operationId, currentAuth: auth),
      throwsA(_stateFailure('cloud_sync_local_send_owner_changed')),
    );
    expect(
      () => localSends.readForAdmission(intent),
      throwsA(_stateFailure('cloud_sync_local_send_owner_changed')),
    );
  });

  test('retained adoption without a trusted callback rejects without state change', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    releaseChild(intent, _planA(), _resultA(), _attemptA);
    attachmentInventories[intent] = {key};
    await seedRestoredChat();
    await rotateUnknown();
    await reconcileFence();
    await reopen();
    final bare = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: authority.read(_writerScope)!,
    );
    final source = localSends.readForAdmission(intent);
    expect(
      () => store.runInTransaction(TxMode.write, () =>
        bare.adoptInOutboxTransaction(store, source, _messageOperation(), retainedAttachmentResume: true)),
      throwsA(_stateFailure('cloud_sync_attachment_parent_readback_required')),
    );
    expect(store.box<CloudSyncLocalSendIntentEntity>().get(intent)!.state, 1);
  });
}

final class AdmittedParent {
  const AdmittedParent({required this.operation, required this.proof});
  final CloudOutboxOperation operation;
  final String? proof;
}

Message _attachmentMessage({required String stableGuid, required String attachmentGuid}) {
  return Message(
    guid: 'local-$stableGuid',
    text: ' ',
    dateCreated: _time(1),
    isFromMe: true,
    hasAttachments: true,
    attributedBody: [
      AttributedBody(
        string: ' ',
        runs: [Run(range: const [0, 1], attributes: Attributes(attachmentGuid: attachmentGuid))],
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

CloudSyncNativeAuthSnapshot _auth(Object client, {String account = _accountA, String store = _storeA}) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'native-session',
      accountFingerprint: account,
      protectedStoreIdentity: store,
      cloudMessagesClient: client,
    );

CloudSyncProtectedOutboundStageData _planA({String? record, String? payload, String? reference, String? lease}) =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('C'),
      protectedEnvelopeReference: reference ?? _ref('E'),
      payloadSha256: payload ?? _digest('c'),
      serverRecordIdHash: record ?? _token('D'),
      leaseReference: lease ?? _lease('d'),
    );

CloudSyncProtectedOutboundStageData _resultA({String? record, String? payload, String? lease}) =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('C'),
      protectedEnvelopeReference: _ref('F'),
      payloadSha256: payload ?? _digest('e'),
      serverRecordIdHash: record ?? _token('D'),
      leaseReference: lease ?? _lease('1'),
    );

CloudSyncProtectedOutboundStageData _planB() => CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('G'),
      protectedEnvelopeReference: _ref('I'),
      payloadSha256: _digest('f'),
      serverRecordIdHash: _token('H'),
      leaseReference: _lease('2'),
    );

CloudSyncProtectedOutboundStageData _resultB() => CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('G'),
      protectedEnvelopeReference: _ref('L'),
      payloadSha256: _digest('a'),
      serverRecordIdHash: _token('H'),
      leaseReference: _lease('5'),
    );

CloudSyncProtectedOutboundStageData _planC() => CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('J'),
      protectedEnvelopeReference: _ref('K'),
      payloadSha256: _digest('0'),
      serverRecordIdHash: _token('N'),
      leaseReference: _lease('3'),
    );

CloudOutboxDraft _messageDraft() => CloudOutboxDraft(
      scope: _messageScope,
      logicalEntityKeyHash: _token('M'),
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncOutboundPayloadVersion,
      dependencyOperationIds: const {},
      createdAt: _time(2),
      encryptedPayloadReference: _ref('P'),
      payloadSha256: _digest('d'),
      serverRecordIdHash: _token('S'),
      protectedLeaseReference: _lease('b'),
    );

CloudRecordMapEntry _messageMapping() => CloudRecordMapEntry(
      scope: _messageScope,
      logicalEntityKeyHash: _token('M'),
      serverRecordIdHash: _token('S'),
      encryptedServerRecordId: _ref('P'),
      updatedAt: _time(2),
    );

CloudOutboxOperation _finalOperation(CloudSyncProtectedOutboundStageData result) => CloudOutboxOperation(
      scope: _uploadScope,
      operationId: CloudOperationIdentity.forInitialCreate(scope: _uploadScope, logicalEntityKeyHash: result.logicalEntityKeyHash, payloadVersion: 1),
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

void _persistFinalOperation(Store tx, CloudSyncProtectedOutboundStageData result) {
  tx.box<CloudOutboxOperationEntity>().put(
    CloudOutboxOperationEntity(
      operationId: CloudOperationIdentity.forInitialCreate(scope: _uploadScope, logicalEntityKeyHash: result.logicalEntityKeyHash, payloadVersion: 1),
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

Matcher _stateFailure(String message) => isA<StateError>().having((error) => error.message, 'message', message);

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

String _token(String char) => List.filled(43, char).join();
String _digest(String char) => List.filled(64, char).join();
String _ref(String char) => 'obcs2.ref.${_token(char)}';
String _lease(String char) => 'obcs2.lease.${List.filled(32, char).join()}';

const _accountA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _accountB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _storeA = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _storeB = 'obcs2.store.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _guidC = '33333333-3333-4333-8333-333333333333';
const _attemptA = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _attemptB = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const _attemptC = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC';
const _requestUuid = '11111111-2222-4333-8444-555555555555';
const _operationUuid = '66666666-7777-4888-8999-AAAAAAAAAAAA';

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
final _messageScope = CloudSyncScope(
  accountFingerprint: _accountA,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
final _chatScope = CloudSyncScope(
  accountFingerprint: _accountA,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'chatManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);

final class _FakeProtector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async => _digest('e');
  @override
  Future<String> protect({required CloudSyncScope scope, required CloudSyncProtectedValueKind kind, required String plaintext}) async => 'ciphertext';
  @override
  Future<String> unprotect({required CloudSyncScope scope, required CloudSyncProtectedValueKind kind, required String ciphertext}) async => 'plaintext';
}
