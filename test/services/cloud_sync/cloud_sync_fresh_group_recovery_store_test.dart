import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_fresh_group_recovery_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_fresh_group_recovery_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_fresh_group_recovery_snapshot.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_chat_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_admission.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_group_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

// ObjectBox/journal integration using synthetic local data. Native conversion,
// committed native files, IDS delivery and Apple readback are not exercised.
const _groupGuid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _messageGuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const _sender = 'sender@example.invalid';
const _members = ['+15550000002', 'member@example.invalid'];
const _requestUuid = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC';
const _operationUuid = 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD';
final _base = DateTime.utc(2026, 10, 25);
DateTime _time(int seconds) => _base.add(Duration(seconds: seconds));
final _scope = CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'chatManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
final _oldRef = 'obcs2.ref.${'P' * 43}';
final _newRef = 'obcs2.ref.${'Q' * 43}';
final _oldLease = 'obcs2.lease.${'a' * 32}';
final _newLease = 'obcs2.lease.${'c' * 32}';
final _oldStage = CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: 'L' * 43,
  protectedEnvelopeReference: _oldRef,
  payloadSha256: 'b' * 64,
  serverRecordIdHash: 'S' * 43,
  leaseReference: _oldLease,
);

CloudSyncProtectedOutboundStageData _converted({
  String? logical, String? record, String? digest, String? reference, String? lease,
}) => CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: logical ?? _oldStage.logicalEntityKeyHash,
  protectedEnvelopeReference: reference ?? _newRef,
  payloadSha256: digest ?? _oldStage.payloadSha256,
  serverRecordIdHash: record ?? _oldStage.serverRecordIdHash,
  leaseReference: lease ?? _newLease,
);

final _refusal = throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>()));

void main() {
  late Directory scratch;
  late Store db;
  late Chat chat;
  late Message message;
  late int intentId;
  late String operationId;
  late CloudSyncLocalSendJournal journal;
  late ObjectBoxCloudSyncStore durable;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncLocalSendAuthFence fence;

  CloudOutboxOperationEntity row() => db.box<CloudOutboxOperationEntity>().getAll().single;
  CloudRecordMapEntity mapping() => db.box<CloudRecordMapEntity>().getAll().single;
  CloudSyncLocalSendIntentEntity intent() =>
      db.box<CloudSyncLocalSendIntentEntity>().get(intentId)!;

  String persistedState() => jsonEncode([
    db.box<CloudOutboxOperationEntity>().getAll().map(freshGroupRecoveryOperationSnapshot).toList(),
    db.box<CloudRecordMapEntity>().getAll().map(freshGroupRecoveryMapSnapshot).toList(),
    db.box<CloudSyncLocalSendIntentEntity>().getAll().map(freshGroupRecoverySourceSnapshot).toList(),
  ]);

  Future<List<CloudOutboxOperation>> lease(String leaseId, int second) =>
      durable.leaseEligibleOutbox(
        _scope, now: _time(second), limit: 1, leaseId: leaseId,
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save}, allowedPayloadVersions: const {1},
      );

  Future<CloudOutboxOperation> submit(String leaseId, int second) async =>
      (await durable.markOutboxSubmissionStarted(
        _scope, leaseId: leaseId, now: _time(second),
        submissionIdentity: CloudOutboxSubmissionIdentity(
          requestUuid: _requestUuid, operationUuids: {operationId: _operationUuid},
        ),
      )).single;

  Future<CloudOutboxOperation> legacy({bool submitted = false, bool quarantined = true}) async {
    final operation = await CloudSyncOutboundChatAdmissionCoordinator(
      store: durable, transport: _GroupStaging(),
      ensureProtectedStoreRecovered: () async {},
    ).admitChat(
      _scope, chatId: chat.id!, createdAt: _time(3), authFence: fence,
      localSendSource: journal.readForAdmission(intentId),
      // Reuse the existing group-fixture wire view, avoiding native proto encoding.
      encode: (origin) => _WireGroup(origin as CloudSyncOutboundGroupOrigin),
    );
    operationId = operation.operationId;
    expect((await lease('legacy-store-lease', 4)).single.operationId, operationId);
    if (submitted) await submit('legacy-store-lease', 5);
    if (quarantined) {
      await durable.applyOutboxTransitions(
        _scope, leaseId: 'legacy-store-lease', now: _time(6),
        transitions: [CloudOutboxTransition.quarantined(
          operationId, category: CloudFailureCategory.cancelled,
        )],
      );
    }
    // Terminal submitted failures may no longer own a native lease and are
    // intentionally rejected by the narrower local-create recovery lookup.
    return (await durable.readOutboxEntries(_scope)).single;
  }

  CloudSyncFreshGroupRecoveryClaim capture() => durable.captureFreshGroupChatRecovery(
    _scope, operationId: operationId, chatId: chat.id!, intentId: intentId,
  );

  CloudOutboxOperation adopt(
    CloudSyncFreshGroupRecoveryClaim claim, {CloudSyncProtectedOutboundStageData? stage}
  ) => durable.adoptFreshGroupChatRecovery(
    claim: claim, stage: stage ?? _converted(), nativeSessionId: auth.nativeSessionId,
    protectedStoreIdentity: auth.protectedStoreIdentity, now: _time(10),
  );

  CloudOutboxOperation? readRecovered() => durable.readRecoveredFreshGroupChat(
    _scope, operationId: operationId, chatId: chat.id!, intentId: intentId,
  );

  void validateProof(CloudOutboxOperation operation) {
    final recovery = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    db.runInTransaction(TxMode.read, () => journal.validateChatCreateBinding(
      db, operation, chat.id!, recovery.identity, recovery.proof,
    ));
  }

  Future<void> expectLiveness({required bool replacement}) async {
    final leases = await durable.readLiveProtectedOutboundLeaseReferences(maximumCount: 1024);
    expect(leases, unorderedEquals([_oldLease, if (replacement) _newLease]));
    final blobs = await durable.readLiveProtectedReferences(maximumCount: 1024);
    expect(blobs.isComplete, isTrue);
    expect(blobs.references, unorderedEquals([_oldRef, _newRef]));
  }

  setUp(() async {
    final root = Directory('build/test-temp')..createSync(recursive: true);
    scratch = await root.createTemp('fresh-group-recovery-store-');
    db = await openStore(directory: scratch.path);
    auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'N' * 43, accountFingerprint: _scope.accountFingerprint,
      protectedStoreIdentity: 'obcs2.store.${'A' * 43}', cloudMessagesClient: Object(),
    );
    fence = CloudSyncLocalSendAuthFence(
      expected: auth, capture: () async => auth, stillCurrent: () => true,
    );
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: db, buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final writerScope = CloudKitWriterScope(accountFingerprint: _scope.accountFingerprint);
    final disabled = authority.initializeDisabled(writerScope, now: _time(0));
    authority.provisionInitialOwner(
      writerScope, owner: CloudKitWriterOwner.v2, expectedEpoch: disabled.epoch,
      evidence: const CloudKitWriterTransitionEvidence.forTest(
        operationsQuiesced: true, activeIdentityRevalidated: true,
        legacyMutationQueues: LegacyMutationQueueDisposition.empty,
      ), now: _time(0),
    );
    journal = CloudSyncLocalSendJournal(
      store: db, authority: authority, authoritySnapshot: authority.read(writerScope)!,
      currentAuth: auth,
    );
    durable = ObjectBoxCloudSyncStore(
      store: db, protector: _Protector(), localSendJournal: journal, clock: () => _time(20),
    );
    for (final zone in ['chatManateeZone', 'messageManateeZone', 'attachmentManateeZone']) {
      await durable.recordPullSuccess(CloudSyncScope(
        accountFingerprint: _scope.accountFingerprint, container: _scope.container,
        database: _scope.database, zone: zone, streamKind: _scope.streamKind,
        persistenceLane: _scope.persistenceLane,
      ), now: _time(0));
    }
    final handles = [for (final address in _members) Handle(
      address: address, service: 'iMessage', uniqueAddressAndService: '$address/iMessage',
    )];
    db.box<Handle>().putMany(handles);
    chat = Chat(guid: _groupGuid, usingHandle: 'mailto:$_sender')..handles.addAll(handles);
    db.box<Chat>().put(chat);
    message = Message(
      guid: 'temp-ABCDEFGH', stagingGuid: _messageGuid, text: 'synthetic recovery body',
      attributedBody: [AttributedBody.raw('synthetic recovery body')],
      isFromMe: true, dateCreated: _time(0),
    )..chat.target = chat;
    final identity = CloudSyncLocalSendIdentity.capture(message, chat, _messageGuid)!;
    journal.saveSubmission(
      identity: identity, newlyGeneratedGuid: true,
      persistMessage: () => db.box<Message>().put(message), now: _time(0),
    );
    // Drive the production journal's synthetic positive event and promotion.
    // No proof string or IDS-confirmation flag is fabricated for eligible data.
    intentId = journal.recordNativeSendConfirmation(
      stableGuid: _messageGuid, succeeded: true, capturedAuth: auth,
      stillCurrent: () => true, now: _time(1),
    )!;
    journal.promoteIdsConfirmedDeferred(intentId: intentId, currentAuth: auth, now: _time(2));
    message = db.box<Message>().get(message.id!)!;
    expect(intent().state, 1);
    expect(intent().idsConfirmationVersion, 2);
    expect(intent().admittedOperationId, isNull);
  });

  tearDown(() async {
    if (!db.isClosed()) db.close();
    final resolved = (await scratch.resolveSymbolicLinks()).replaceAll('\\', '/');
    expect(resolved, endsWith(scratch.path.replaceAll('\\', '/')));
    final files = await scratch.list(followLinks: false).toList();
    expect(files.every((file) => file is File &&
      const {'data.mdb', 'lock.mdb'}.contains(file.path.replaceAll('\\', '/').split('/').last)), isTrue);
    for (final file in files) { await file.delete(); }
    await scratch.delete();
  });

  test('eligible journal-owned legacy6 is atomically recovered without a new identity', () async {
    final original = await legacy();
    expect(row().state, CloudOutboxStatus.quarantined.index);
    expect(row().lastErrorCategory, 'cancelled');
    expect(row().attemptCount, 1);
    expect(row().appleRequestUuid, isNull);
    expect(row().appleOperationUuid, isNull);
    expect(row().leaseIdHash, isNull);
    expect(decodeCloudSyncOutboundGroupOrigin(row().localChatOrigin!)[0], 6);
    final oldRow = freshGroupRecoveryOperationSnapshot(row());
    final oldMap = freshGroupRecoveryMapSnapshot(mapping());
    final oldSource = freshGroupRecoverySourceSnapshot(intent());
    final claim = capture();
    expect(claim.operation.sameDurableSnapshotAs(original), isTrue);
    expect(claim.operationSnapshot, oldRow);
    expect(claim.recordMapSnapshot, oldMap);
    expect(claim.sourceSnapshot, oldSource);
    final recovered = adopt(claim);
    final after = freshGroupRecoveryOperationSnapshot(row());
    const changed = {'encryptedPayloadRef', 'protectedLeaseReference', 'localChatOrigin',
      'state', 'lastErrorCategory', 'updatedAtMs'};
    for (final entry in oldRow.entries.where((entry) => !changed.contains(entry.key))) {
      expect(after[entry.key], entry.value, reason: entry.key);
    }
    expect(recovered.operationId, original.operationId);
    expect(recovered.status, CloudOutboxStatus.pending);
    expect(recovered.attemptCount, 1);
    expect(recovered.encryptedPayloadReference, _newRef);
    expect(recovered.protectedLeaseReference, _newLease);
    expect(recovered.lastFailure, isNull);
    expect(mapping().id, oldMap['id']);
    expect(mapping().encryptedServerRecordId, _newRef);
    for (final entry in oldMap.entries.where((e) =>
        !{'encryptedServerRecordId', 'updatedAtMs'}.contains(e.key))) {
      expect(freshGroupRecoveryMapSnapshot(mapping())[entry.key], entry.value, reason: entry.key);
    }
    final recovery = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    expect(recovery.phase, CloudSyncFreshGroupRecoveryPhase.ready);
    expect(recovery.receipt['operation'], oldRow);
    expect(recovery.receipt['recordMap'], oldMap);
    expect(recovery.receipt['source'], oldSource);
    expect((recovery.receipt['operation'] as Map)['lastErrorCategory'], 'cancelled');
    expect((jsonDecode(recovery.proof) as List).take(2), [2, intentId]);
    validateProof(recovered);
    expect(freshGroupRecoverySourceSnapshot(intent()), oldSource);
    expect(db.box<CloudOutboxOperationEntity>().count(), 1);
    expect(db.box<CloudRecordMapEntity>().count(), 1);
    expect(db.box<CloudSyncLocalSendIntentEntity>().count(), 1);
    expect(db.box<Message>().count(), 1);
    expect(db.box<Chat>().count(), 1);
    expect(db.box<Message>().get(message.id!)!.guid, _messageGuid);
    await expectLiveness(replacement: true);
  });

  test('proof2 revalidates the live journal source instead of accepting syntax', () async {
    await legacy();
    final recovered = adopt(capture());
    validateProof(recovered);
    db.box<CloudSyncLocalSendIntentEntity>().put(intent()..sourceSha256 = 'e' * 64);
    final before = persistedState();
    expect(() => validateProof(recovered), _refusal);
    expect(persistedState(), before);
  });

  test('canonical audit changes cannot reuse the journal-issued proof2', () async {
    await legacy();
    final recovered = adopt(capture());
    final recovery = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    final receipt = Map<String, Object?>.from(jsonDecode(recovery.canonicalReceipt) as Map);
    final binding = receipt['binding'] as Map;
    binding['recoveredAtMs'] = (binding['recoveredAtMs'] as int) + 1;
    final altered = CloudSyncFreshGroupRecoveryOrigin.create(
      identity: recovery.identity, receipt: receipt, proof: recovery.proof,
    );
    db.box<CloudOutboxOperationEntity>().put(row()..localChatOrigin = altered.encode());
    final before = persistedState();
    expect(() => validateProof(recovered), _refusal);
    expect(persistedState(), before);
  });

  test('persisted entity binding rejects identity, active-reference and counter tampering', () async {
    await legacy();
    adopt(capture());
    final current = row();
    final recovery = CloudSyncFreshGroupRecoveryOrigin.decode(current.localChatOrigin!);
    expect(validateFreshGroupRecoveryEntity(recovery, current).id, current.id);
    expect(cloudSyncIsNeverSubmittedChatCreate(current), isTrue);
    final snapshot = freshGroupRecoveryOperationSnapshot(current);
    const immutable = ['id', 'operationId', 'scopeKey', 'accountFingerprint', 'zone',
      'logicalEntityKeyHash', 'action', 'dependencyOperationIdsJson', 'payloadVersion',
      'mutationRevision', 'checkpointGeneration', 'payloadSha256', 'serverRecordIdHash',
      'createdAtMs'];
    final mutations = <String, Object?>{
      for (final key in immutable)
        key: snapshot[key] is int ? (snapshot[key] as int) + 1 : '${snapshot[key]}:changed',
      'encryptedPayloadRef': 'obcs2.ref.${'T' * 43}',
      'protectedLeaseReference': 'obcs2.lease.${'d' * 32}',
      'localChatOrigin': '[9]',
      'attemptCount': current.attemptCount - 1,
      'updatedAtMs': _time(9).millisecondsSinceEpoch,
    };
    for (final entry in mutations.entries) {
      final changed = freshGroupRecoveryOperationFromSnapshot(
        Map<String, Object?>.of(snapshot)..[entry.key] = entry.value,
      );
      expect(() => validateFreshGroupRecoveryEntity(recovery, changed), _refusal,
          reason: entry.key);
      expect(cloudSyncIsNeverSubmittedChatCreate(changed), isFalse, reason: entry.key);
    }
    final prematurelyReleased = freshGroupRecoveryOperationFromSnapshot(
      Map<String, Object?>.of(snapshot)..['protectedLeaseReference'] = null,
    );
    expect(() => validateFreshGroupRecoveryEntity(recovery, prematurelyReleased), _refusal);
    expect(freshGroupRecoveryOperationSnapshot(row()), snapshot);
  });

  test('canonical submitted version9 readback resolves the same Chat and requires its map', () async {
    await legacy();
    final recovered = adopt(capture());
    final recovery = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    final origin = CloudSyncOutboundGroupOrigin.capture(scope: _scope, chat: chat);
    final localId = chat.id!;
    final payload = CloudChatEntityPayload(
      logicalEntityKeyHash: recovered.logicalEntityKeyHash,
      canonicalGuid: origin.canonicalGuid, chatIdentifier: origin.chatIdentifier,
      groupId: _groupGuid, originalGroupId: _groupGuid, displayName: null,
      participantHandles: ['tel:${_members.first}', 'mailto:${_members.last}'],
      aliases: [
        CloudSemanticChatAlias(kind: CloudSemanticChatAliasKind.serviceIdentifier, keyHash: 'I' * 43),
        CloudSemanticChatAlias(kind: CloudSemanticChatAliasKind.groupId, keyHash: 'G' * 43),
      ],
      service: CloudSemanticService.iMessage, style: CloudSemanticChatStyle.group,
      lastAddressedHandleState: CloudSemanticFieldState.value,
      lastAddressedHandle: 'mailto:$_sender',
      groupVersionState: CloudSemanticFieldState.value, groupVersion: 1,
    );
    final adapter = ObjectBoxCanonicalSemanticEntityAdapter(
      store: db, activeScopeProvider: () => CloudCanonicalActiveScope(scope: _scope, generation: 1),
      identityResolver: _GroupResolver(origin.canonicalGuid),
      semanticApplyEnabled: true, allowChatUpserts: true,
    );
    // Model the authenticated reader's map binding and projection in one
    // transaction, as in the existing outbound-group ObjectBox fixture.
    void project({bool wrongMap = false}) => db.runInTransaction(TxMode.write, () {
      db.box<CloudRecordMapEntity>().put(mapping()
        ..etagHash = wrongMap ? 'Z' * 43 : 'E' * 43
        ..encryptedRawRecordRef = 'obcs2.ref.${'R' * 43}');
      adapter.applyEntity(
        scope: _scope, generation: 1, payload: payload,
        snapshot: CloudSemanticSnapshot(
          kind: CloudEntityKind.chat, logicalEntityKeyHash: recovered.logicalEntityKeyHash,
          immutableContentDigest: 'synthetic-recovery-group-payload', etagHash: 'E' * 43,
          encryptedRawRecordReference: 'obcs2.ref.${'R' * 43}',
        ),
      );
    });
    final readyState = persistedState();
    expect(project, _refusal);
    expect(persistedState(), readyState);
    expect(db.box<Chat>().get(localId)!.guid, _groupGuid);
    expect((await lease('recovered-store-lease', 11)).single.operationId, operationId);
    await submit('recovered-store-lease', 12);
    final submittedState = persistedState();
    expect(() => project(wrongMap: true), _refusal);
    expect(persistedState(), submittedState);
    expect(db.box<Chat>().get(localId)!.guid, _groupGuid);
    expect(db.box<Chat>().count(), 1);
    project();
    final projected = db.box<Chat>().get(localId)!;
    expect(projected.id, localId);
    expect(projected.guid, origin.canonicalGuid);
    expect(projected.cloudGuid, _groupGuid);
    expect(projected.style, 43);
    expect(db.box<Chat>().count(), 1);
    expect(db.box<Message>().get(message.id!)!.chat.targetId, localId);
    expect(db.box<Message>().get(message.id!)!.guid, _messageGuid);
    expect(row().operationId, recovered.operationId);
    final after = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    expect(after.phase, CloudSyncFreshGroupRecoveryPhase.submitted);
    expect(after.canonicalReceipt, recovery.canonicalReceipt);
    expect(after.proof, recovery.proof);
  });

  test('submission and confirmed marker release preserve audit and the old lease', () async {
    await legacy();
    adopt(capture());
    final ready = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    final activeBinding = cloudSyncActiveChatOriginBinding(row().localChatOrigin!);
    await expectLiveness(replacement: true);
    expect((await lease('recovered-store-lease', 11)).single.operationId, operationId);
    await submit('recovered-store-lease', 12);
    final submitted = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    expect(submitted.phase, CloudSyncFreshGroupRecoveryPhase.submitted);
    expect(submitted.canonicalReceipt, ready.canonicalReceipt);
    expect(submitted.proof, ready.proof);
    expect(cloudSyncActiveChatOriginBinding(row().localChatOrigin!), activeBinding);
    expect(cloudSyncIsNeverSubmittedChatCreate(row()), isFalse);
    final beforeRead = persistedState();
    expect(readRecovered()!.status, CloudOutboxStatus.unknownOutcome);
    expect(persistedState(), beforeRead);
    expect(capture, _refusal);
    await durable.commitOutboxCreateReceipt(
      _scope, leaseId: 'recovered-store-lease', now: _time(13),
      retainProtectedLeaseReference: true,
      receipt: CloudOutboxCreateReceipt(
        operationId: operationId, logicalEntityKeyHash: _oldStage.logicalEntityKeyHash,
        serverRecordIdHash: _oldStage.serverRecordIdHash, etagHash: 'E' * 43,
      ),
    );
    final confirmed = readRecovered()!;
    expect(confirmed.status, CloudOutboxStatus.confirmed);
    expect(confirmed.protectedLeaseReference, _newLease);
    await expectLiveness(replacement: true);
    // Store-side handoff only: the caller's native exact-readback proof and
    // native acknowledgement are outside this synthetic integration test.
    await durable.clearConfirmedProtectedOutboundLeaseReference(expectedOperation: confirmed);
    final released = readRecovered()!;
    expect(released.status, CloudOutboxStatus.confirmed);
    expect(released.protectedLeaseReference, isNull);
    final audit = CloudSyncFreshGroupRecoveryOrigin.decode(row().localChatOrigin!);
    expect(audit.phase, CloudSyncFreshGroupRecoveryPhase.submitted);
    expect(audit.canonicalReceipt, ready.canonicalReceipt);
    expect(audit.receiptSha256, ready.receiptSha256);
    expect(audit.proof, ready.proof);
    final conversion = audit.receipt['conversion'] as Map;
    expect(conversion['previousLeaseReference'], _oldLease);
    expect(conversion['leaseReference'], _newLease);
    await expectLiveness(replacement: false);
    final stable = persistedState();
    expect(readRecovered()!.sameDurableSnapshotAs(released), isTrue);
    expect(persistedState(), stable);
    expect(capture, _refusal);
  });

  test('idempotent recovered reads never reactivate a later quarantined attempt', () async {
    await legacy();
    final claim = capture();
    final recovered = adopt(claim);
    final pending = persistedState();
    for (var i = 0; i < 2; i++) {
      expect(readRecovered()!.sameDurableSnapshotAs(recovered), isTrue);
      expect(persistedState(), pending);
    }
    expect((await lease('recovered-store-lease', 11)).single.operationId, operationId);
    await durable.applyOutboxTransitions(
      _scope, leaseId: 'recovered-store-lease', now: _time(12),
      transitions: [CloudOutboxTransition.quarantined(
        operationId, category: CloudFailureCategory.cancelled,
      )],
    );
    final failed = persistedState();
    expect(readRecovered()!.status, CloudOutboxStatus.quarantined);
    expect(row().attemptCount, 2);
    expect(persistedState(), failed);
    expect(() => adopt(claim), _refusal);
    expect(persistedState(), failed);
    await expectLiveness(replacement: true);
  });

  for (final target in ['operation', 'recordMap', 'source']) {
    test('post-capture $target scalar tampering rejects without partial adoption', () async {
      await legacy();
      final claim = capture();
      switch (target) {
        case 'operation':
          db.box<CloudOutboxOperationEntity>().put(row()..updatedAtMs += 1);
        case 'recordMap':
          db.box<CloudRecordMapEntity>().put(mapping()..updatedAtMs += 1);
        case 'source':
          db.box<CloudSyncLocalSendIntentEntity>().put(intent()..updatedAtMs += 1);
      }
      final before = persistedState();
      expect(() => adopt(claim), _refusal);
      expect(persistedState(), before);
      expect(row().encryptedPayloadRef, _oldRef);
      expect(row().protectedLeaseReference, _oldLease);
      expect(row().state, CloudOutboxStatus.quarantined.index);
      expect(CloudSyncFreshGroupRecoveryOrigin.isEncoded(row().localChatOrigin!), isFalse);
    });
  }

  final wrongStages = <String, CloudSyncProtectedOutboundStageData Function()>{
    'logical key': () => _converted(logical: 'X' * 43),
    'record identity': () => _converted(record: 'Z' * 43),
    'payload digest': () => _converted(digest: 'd' * 64),
    'malformed reference': () => _converted(reference: 'obcs2.ref.bad'),
    'unchanged legacy reference': () => _converted(reference: _oldRef),
    'malformed lease': () => _converted(lease: 'obcs2.lease.bad'),
    'unchanged legacy lease': () => _converted(lease: _oldLease),
  };
  for (final entry in wrongStages.entries) {
    test('conversion with wrong ${entry.key} rejects without partial write', () async {
      await legacy();
      final claim = capture();
      final before = persistedState();
      final refusal = entry.key == 'malformed lease'
          ? throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
              'cloud_outbox_protected_lease_reference_invalid'))
          : _refusal;
      expect(() => adopt(claim, stage: entry.value()), refusal);
      expect(persistedState(), before);
    });
  }

  for (final kind in ['submitted', 'unknown', 'historical', 'missing IDS-v2', 'forged legacy proof']) {
    test('$kind cannot enter legacy fresh-group recovery', () async {
      if (kind == 'submitted' || kind == 'unknown') {
        await legacy(submitted: true, quarantined: kind == 'submitted');
        expect(decodeCloudSyncOutboundGroupOrigin(row().localChatOrigin!)[0], 7);
        expect(row().appleRequestUuid, isNotNull);
        if (kind == 'unknown') expect(row().state, CloudOutboxStatus.unknownOutcome.index);
      } else {
        await legacy();
        if (kind == 'missing IDS-v2') {
          db.box<CloudSyncLocalSendIntentEntity>().put(intent()..idsConfirmationVersion = 0);
        } else if (kind == 'historical') {
          final historical = CloudSyncHistoricalChatOrigin(
            generation: 1, intentId: intentId, localChatId: chat.id,
            sourceChatGuidSha256: 'a' * 64, parentPayloadLength: 128,
            source: CloudSyncHistoricalProtectedSourceBinding(
              accountFingerprint: _scope.accountFingerprint,
              protectedStoreIdentity: auth.protectedStoreIdentity,
              snapshotSha256: 'a' * 64, messageGuidHash: 'b' * 64, sourceSha256: 'c' * 64,
              protectedReference: _oldRef, leaseReference: _oldLease,
              payloadSha256: 'd' * 64, payloadLength: 128,
            ),
          );
          db.box<CloudOutboxOperationEntity>().put(row()..localChatOrigin = historical.encode());
        } else {
          final parts = decodeCloudSyncOutboundGroupOrigin(row().localChatOrigin!);
          parts[8] = jsonEncode([1, intentId, '0' * 64]);
          db.box<CloudOutboxOperationEntity>().put(row()..localChatOrigin = jsonEncode(parts));
          expect(cloudSyncIsNeverSubmittedChatCreate(row()), isTrue);
        }
      }
      final before = persistedState();
      expect(capture, _refusal);
      expect(persistedState(), before);
      expect(db.box<CloudOutboxOperationEntity>().count(), 1);
    });
  }
}

final class _GroupStaging implements CloudSyncOutboundGroupChatStagingTransport {
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) => action();
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundGroupChat(
    CloudSyncScope scope, {required api.CloudChat chat}
  ) async => _oldStage;
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundChat(
    CloudSyncScope scope, {required api.CloudChat chat}
  ) => throw StateError('group fixture cannot use direct staging');
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {required api.CloudMessage message}
  ) => throw StateError('no Message staging in this test');
  @override
  Future<void> commitOutboundLease(String lease, String reference) async {}
  @override
  Future<void> rollbackOutboundLease(String lease) async =>
      throw StateError('unexpected initial-stage rollback');
}

final class _WireGroup implements api.CloudChat {
  _WireGroup(this.origin);
  final CloudSyncOutboundGroupOrigin origin;
  @override
  String get guid => origin.canonicalGuid;
  @override
  String get chatIdentifier => origin.chatIdentifier;
  @override
  String get groupId => origin.originalGuid;
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
    pv: origin.groupVersion, numberOfTimesRespondedtoThread: 3,
    shouldForceToSms: false, legacyGroupIdentifiers: [], messageHandshakeState: 1,
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

final class _Protector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async => _scope.accountFingerprint;
  @override
  Future<String> protect({
    required CloudSyncScope scope, required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'synthetic:$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope, required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext.substring('synthetic:'.length);
}

final class _GroupResolver implements CloudCanonicalIdentityResolver {
  _GroupResolver(this.guid);
  final String guid;
  @override
  String? resolveCanonicalGuid({
    required CloudSyncScope scope, required int generation,
    required CloudEntityKind kind, required String logicalEntityKeyHash,
  }) => guid;
  @override
  CloudCanonicalIdentityOwner? resolveCanonicalIdentityOwner({
    required CloudSyncScope scope, required int generation, required String canonicalGuid,
  }) => canonicalGuid == guid ? CloudCanonicalIdentityOwner(
    kind: CloudEntityKind.chat, logicalEntityKeyHash: _oldStage.logicalEntityKeyHash,
  ) : null;
}
