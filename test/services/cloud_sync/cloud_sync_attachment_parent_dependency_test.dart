// Bounded parent proof for attachment child readback.
//
// Uses a real disposable ObjectBox store plus the established local-send
// attachment fixtures to prove that captureParentReadbackProof admits only a
// complete source-derived child set in the readback-acknowledged state
// (adopted + deterministic final-save outbox confirmed with its receipt lease
// released after exact replay verification), and that
// requireParentReadbackProof recomputes and compares the exact proof,
// including across restart from the key list retained inside the proof.
// The readback-acknowledged outbox state is crafted to match exactly what the
// transport's verifyConfirmedAttachmentCreateNoSave plus
// releaseConfirmedReplayReceipt leaves behind under retain-for-replay; the
// native replay itself is covered by transport tests, not simulated here.
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
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudKitWriterAuthoritySnapshot authoritySnapshot;
  late CloudSyncLocalSendJournal localSends;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncAttachmentUploadJournal uploads;
  late Chat chat;

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
    );
  }

  void seedCheckpoint(int generation) {
    final box = store.box<CloudSyncCheckpointEntity>();
    final key = cloudSyncPersistentScopeKey(_uploadScope);
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
        zone: 'attachmentManateeZone',
        streamKind: 'messages',
        schemaVersion: 2,
        persistenceLane: 'semantic',
        generation: generation,
        updatedAtMs: _time(0).millisecondsSinceEpoch,
      ),
    );
  }

  CloudSyncAttachmentUploadJournal buildUploads({int generation = 1}) =>
      CloudSyncAttachmentUploadJournal(
        store: store,
        localSends: localSends,
        scope: _uploadScope,
        checkpointGeneration: generation,
        currentAuth: auth,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('openbubbles-attachment-parent-proof-');
    store = await openStore(directory: directory.path);
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
    auth = _auth(Object());
    seedCheckpoint(1);
    uploads = buildUploads();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> reopen({int generation = 1}) async {
    store.close();
    store = await openStore(directory: directory.path);
    provisionJournal();
    auth = _auth(Object());
    uploads = buildUploads(generation: generation);
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

  int adoptChild(int intentId, CloudSyncProtectedOutboundStageData plan,
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

  void acknowledgeReadback(int uploadId, {required bool retainLease}) {
    final upload = store.box<CloudAttachmentUploadEntity>().get(uploadId)!;
    final box = store.box<CloudOutboxOperationEntity>();
    final query = box.query(CloudOutboxOperationEntity_.operationId.equals(upload.admittedOperationId!)).build();
    try {
      final row = query.findUnique()!;
      row
        ..state = CloudOutboxStatus.confirmed.index
        ..confirmedAtMs = _time(20).millisecondsSinceEpoch
        ..appleRequestUuid = _requestUuid
        ..appleOperationUuid = _operationUuid
        ..protectedLeaseReference = retainLease ? row.protectedLeaseReference : null
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

  int adoptReadbackChild(int intentId, CloudSyncProtectedOutboundStageData plan,
      CloudSyncProtectedOutboundStageData result, String attemptId) {
    final id = adoptChild(intentId, plan, result, attemptId);
    acknowledgeReadback(id, retainLease: false);
    return id;
  }

  String capture(int intentId, Iterable<String> keys) => store.runInTransaction(
        TxMode.write,
        () => uploads.captureParentReadbackProof(localSendIntentId: intentId, sourceAttachmentKeys: keys),
      );

  void requireProof(int intentId, String proof) => store.runInTransaction(
        TxMode.write,
        () => uploads.requireParentReadbackProof(localSendIntentId: intentId, proof: proof),
      );

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

  Future<String> admitAndLease(int intentId, CloudSyncProtectedOutboundStageData plan,
      CloudSyncProtectedOutboundStageData result, String attemptId, String leaseId) async {
    seedAccountReadReady();
    final prepared = uploads.adoptPlan(localSendIntentId: intentId, plan: plan, now: _time(6));
    uploads.beginAttempt(id: prepared.id, attemptId: attemptId, now: _time(7));
    uploads.recordUploaded(id: prepared.id, attemptId: attemptId, result: result, now: _time(8));
    liveStore().admitCompletedAttachmentUpload(
      scope: _uploadScope,
      uploads: uploads,
      uploadId: prepared.id,
      createdAt: _time(9),
    );
    final leased = await liveStore().leaseEligibleOutbox(
      _uploadScope,
      now: _time(10),
      limit: 1,
      leaseId: leaseId,
      leaseDuration: const Duration(minutes: 1),
      allowedActions: const {CloudOutboxAction.save},
    );
    expect(leased.single.logicalEntityKeyHash, plan.logicalEntityKeyHash);
    // Simulate the submitter recording its Apple identities; the guarded
    // receipt and release steps below go through the real store API.
    final box = store.box<CloudOutboxOperationEntity>();
    final query = box
        .query(CloudOutboxOperationEntity_.operationId.equals(leased.single.operationId))
        .build();
    try {
      final row = query.findUnique()!;
      row
        ..appleRequestUuid = _requestUuid
        ..appleOperationUuid = _operationUuid
        ..updatedAtMs = _time(10).millisecondsSinceEpoch;
      box.put(row);
    } finally {
      query.close();
    }
    return leased.single.operationId;
  }

  CloudOutboxCreateReceipt receiptFor(String operationId, String key, String record) =>
      CloudOutboxCreateReceipt(
        operationId: operationId,
        logicalEntityKeyHash: key,
        serverRecordIdHash: record,
        etagHash: _token('E'),
      );

  test('captures and revalidates a complete two-child readback proof', () async {
    final intent = seedConfirmedIntent();
    final keyA = _planA().logicalEntityKeyHash;
    final keyB = _planB().logicalEntityKeyHash;
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    adoptReadbackChild(intent, _planB(), _resultB(), _attemptB);
    final proof = capture(intent, [keyA, keyB]);
    final decoded = jsonDecode(proof) as List;
    expect(decoded.first, 1);
    expect(decoded[3], intent);
    expect((decoded[8] as List).toSet(), {keyA, keyB});
    expect(proof, isNot(contains('LOCAL-ATTACHMENT')));
    expect(proof, isNot(contains(_guidA)));
    expect(proof, isNot(contains('obcs2.ref.')));
    requireProof(intent, proof);
    expect(capture(intent, [keyB, keyA]), proof);
    await reopen();
    requireProof(intent, proof);
  });

  test('rejects a missing source key', () {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    adoptReadbackChild(intent, _planB(), _resultB(), _attemptB);
    expect(
      () => capture(intent, [_planA().logicalEntityKeyHash]),
      throwsA(_stateFailure('cloud_sync_attachment_upload_inventory_changed')),
    );
  });

  test('rejects an extra source key with no retained plan', () {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    expect(
      () => capture(intent, [_planA().logicalEntityKeyHash, _planB().logicalEntityKeyHash]),
      throwsA(_stateFailure('cloud_sync_attachment_upload_inventory_changed')),
    );
  });

  test('rejects duplicate inventory keys and dedupes re-adoption', () {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    final key = _planA().logicalEntityKeyHash;
    expect(
      () => capture(intent, [key, key]),
      throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')),
    );
    final countBefore = store.box<CloudAttachmentUploadEntity>().count();
    final repeat = uploads.adoptPlan(localSendIntentId: intent, plan: _planA(), now: _time(6));
    expect(store.box<CloudAttachmentUploadEntity>().count(), countBefore);
    expect(capture(intent, [key]), isNotEmpty);
    expect(repeat.plan.payloadSha256, _planA().payloadSha256);
  });

  test('rejects malformed inventory input', () {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    final key = _planA().logicalEntityKeyHash;
    expect(() => capture(intent, const <String>[]), throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')));
    expect(() => capture(intent, ['not-a-token']), throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')));
    expect(() => capture(intent, List.filled(65, key)), throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')));
    expect(() => capture(0, [key]), throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')));
  });

  test('rejects a partial upload that never reached adoption', () {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    final partial = uploads.adoptPlan(localSendIntentId: intent, plan: _planB(), now: _time(6));
    uploads.beginAttempt(id: partial.id, attemptId: _attemptB, now: _time(7));
    uploads.recordUploaded(id: partial.id, attemptId: _attemptB, result: _resultB(), now: _time(8));
    expect(
      () => capture(intent, [_planA().logicalEntityKeyHash, _planB().logicalEntityKeyHash]),
      throwsA(_stateFailure('cloud_sync_attachment_upload_result_missing')),
    );
  });

  test('rejects adopted children without exact readback acknowledgement', () {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    final pendingId = adoptChild(intent, _planB(), _resultB(), _attemptB);
    final keys = [_planA().logicalEntityKeyHash, _planB().logicalEntityKeyHash];
    expect(() => capture(intent, keys), throwsA(_stateFailure('cloud_sync_attachment_upload_readback_not_ready')));
    acknowledgeReadback(pendingId, retainLease: true);
    expect(() => capture(intent, keys), throwsA(_stateFailure('cloud_sync_attachment_upload_readback_not_ready')));
    acknowledgeReadback(pendingId, retainLease: false);
    expect(capture(intent, keys), isNotEmpty);
  });

  test('rejects a final operation that drifted from its original result', () {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    adoptReadbackChild(intent, _planB(), _resultB(), _attemptB);
    final box = store.box<CloudOutboxOperationEntity>();
    final query = box.query(CloudOutboxOperationEntity_.logicalEntityKeyHash.equals(_planB().logicalEntityKeyHash)).build();
    try {
      final row = query.findUnique()!;
      row.payloadSha256 = _digest('z');
      box.put(row);
    } finally {
      query.close();
    }
    expect(
      () => capture(intent, [_planA().logicalEntityKeyHash, _planB().logicalEntityKeyHash]),
      throwsA(_stateFailure('cloud_sync_attachment_upload_adoption_changed')),
    );
  });

  test('rejects later row tamper against the captured proof', () {
    final intent = seedConfirmedIntent();
    final keys = [_planA().logicalEntityKeyHash, _planB().logicalEntityKeyHash];
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    adoptReadbackChild(intent, _planB(), _resultB(), _attemptB);
    final proof = capture(intent, keys);
    requireProof(intent, proof);
    final box = store.box<CloudOutboxOperationEntity>();
    final query = box.query(CloudOutboxOperationEntity_.logicalEntityKeyHash.equals(_planB().logicalEntityKeyHash)).build();
    try {
      final row = query.findUnique()!;
      row.protectedLeaseReference = _lease('1');
      box.put(row);
    } finally {
      query.close();
    }
    expect(() => requireProof(intent, proof), throwsStateError);
  });

  test('rejects malformed or foreign proofs without recomputing', () async {
    final intent = seedConfirmedIntent();
    adoptReadbackChild(intent, _planA(), _resultA(), _attemptA);
    final key = _planA().logicalEntityKeyHash;
    final proof = capture(intent, [key]);
    requireProof(intent, proof);
    expect(() => requireProof(intent, ''), throwsStateError);
    expect(() => requireProof(intent, 'not-json'), throwsStateError);
    expect(() => requireProof(intent, proof.substring(0, proof.length - 2)), throwsStateError);
    expect(() => requireProof(intent + 1, proof), throwsStateError);
    await reopen();
    seedCheckpoint(2);
    uploads = buildUploads(generation: 2);
    expect(() => requireProof(intent, proof), throwsStateError);
  });

  test('store refuses an immediate-release receipt for a journal-owned attachment create', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    final record = _planA().serverRecordIdHash;
    final operationId = await admitAndLease(intent, _planA(), _resultA(), _attemptA, 'guard-lease-a');
    expect(operationId, CloudOperationIdentity.forInitialCreate(scope: _uploadScope, logicalEntityKeyHash: key, payloadVersion: 1));
    await expectLater(
      liveStore().commitOutboxCreateReceipt(
        _uploadScope,
        leaseId: 'guard-lease-a',
        receipt: receiptFor(operationId, key, record),
        retainProtectedLeaseReference: false,
        now: _time(11),
      ),
      throwsA(isA<CloudSyncFailure>().having(
        (error) => error.safeCode,
        'safeCode',
        'attachment_receipt_retention_required',
      )),
    );
    final row = (await liveStore().readOutboxEntries(_uploadScope)).single;
    expect(row.status, isNot(CloudOutboxStatus.confirmed));
    expect(row.protectedLeaseReference, isNotNull);
  });

  test('store releases the receipt lease only on verified readback, then the proof captures', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    final record = _planA().serverRecordIdHash;
    final operationId = await admitAndLease(intent, _planA(), _resultA(), _attemptA, 'guard-lease-b');
    await liveStore().commitOutboxCreateReceipt(
      _uploadScope,
      leaseId: 'guard-lease-b',
      receipt: receiptFor(operationId, key, record),
      retainProtectedLeaseReference: true,
      now: _time(11),
    );
    var current = (await liveStore().readOutboxEntries(_uploadScope)).single;
    expect(current.status, CloudOutboxStatus.confirmed);
    expect(current.protectedLeaseReference, isNotNull);
    // A generic clear without the readback flag is refused for the
    // journal-owned create even though the row is confirmed.
    await expectLater(
      liveStore().clearConfirmedProtectedOutboundLeaseReference(expectedOperation: current),
      throwsA(isA<CloudSyncFailure>().having(
        (error) => error.safeCode,
        'safeCode',
        'attachment_readback_required',
      )),
    );
    expect(() => capture(intent, [key]), throwsA(_stateFailure('cloud_sync_attachment_upload_readback_not_ready')));
    // The verified release path clears the retained lease; the parent proof
    // then captures and revalidates end to end through the real APIs.
    await liveStore().clearConfirmedProtectedOutboundLeaseReference(
      expectedOperation: current,
      recordVerifiedLocalSendReadback: true,
    );
    current = (await liveStore().readOutboxEntries(_uploadScope)).single;
    expect(current.protectedLeaseReference, isNull);
    final proof = capture(intent, [key]);
    requireProof(intent, proof);
    await reopen();
    requireProof(intent, proof);
  });

  test('store refuses an immediate-release confirmed transition for a journal-owned attachment create', () async {
    final intent = seedConfirmedIntent();
    final operationId = await admitAndLease(intent, _planA(), _resultA(), _attemptA, 'guard-lease-c');
    await expectLater(
      liveStore().applyOutboxTransitions(
        _uploadScope,
        leaseId: 'guard-lease-c',
        transitions: [CloudOutboxTransition.confirmed(operationId)],
        now: _time(11),
      ),
      throwsA(isA<CloudSyncFailure>().having(
        (error) => error.safeCode,
        'safeCode',
        'attachment_receipt_retention_required',
      )),
    );
    final row = (await liveStore().readOutboxEntries(_uploadScope)).single;
    expect(row.status, isNot(CloudOutboxStatus.confirmed));
    expect(row.protectedLeaseReference, isNotNull);
  });

  test('store keeps a retained confirmed transition releasable only through verified readback', () async {
    final intent = seedConfirmedIntent();
    final key = _planA().logicalEntityKeyHash;
    final operationId = await admitAndLease(intent, _planA(), _resultA(), _attemptA, 'guard-lease-d');
    await liveStore().applyOutboxTransitions(
      _uploadScope,
      leaseId: 'guard-lease-d',
      transitions: [CloudOutboxTransition.confirmed(operationId, retainProtectedLeaseReference: true)],
      now: _time(11),
    );
    final retained = (await liveStore().readOutboxEntries(_uploadScope)).single;
    expect(retained.status, CloudOutboxStatus.confirmed);
    expect(retained.protectedLeaseReference, isNotNull);
    // Retained is not read back: the parent proof still refuses.
    expect(() => capture(intent, [key]), throwsA(_stateFailure('cloud_sync_attachment_upload_readback_not_ready')));
  });
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

CloudSyncNativeAuthSnapshot _auth(Object client) => CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'native-session',
      accountFingerprint: _accountA,
      protectedStoreIdentity: _storeA,
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
const _storeA = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _attemptA = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _attemptB = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
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
const _completeEvidence = CloudKitWriterTransitionEvidence.forTest(
  operationsQuiesced: true,
  activeIdentityRevalidated: true,
  legacyMutationQueues: LegacyMutationQueueDisposition.empty,
);

final class _FakeProtector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async => _digest('e');

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async =>
      'ciphertext';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async =>
      'plaintext';
}
