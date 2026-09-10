import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_selection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';
import 'cloud_sync_restored_chat_test_fixture.dart';

void main() {
  late Directory directory;
  late Store objectBox;
  late ObjectBoxCloudSyncStore durable;
  late _StagingTransport transport;
  late CloudSyncOutboundAdmissionCoordinator coordinator;
  late CloudSyncLocalSendJournal journal;
  late CloudSyncLocalSendAuthFence authFence;
  late Message local;
  late int oldIntentId;
  late int freshIntentId;
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
  CloudSyncScope sibling(String zone) => CloudSyncScope(
    accountFingerprint: scope.accountFingerprint,
    container: scope.container,
    database: scope.database,
    zone: zone,
    streamKind: scope.streamKind,
    schemaVersion: scope.schemaVersion,
    persistenceLane: scope.persistenceLane,
  );

  void bindJournal() {
    final authority = ObjectBoxCloudKitWriterAuthority.forTest(
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

  void confirmMessage(String stableGuid) {
    final identity = CloudSyncLocalSendIdentity.capture(
      local,
      local.chat.target!,
      stableGuid,
    )!;
    local
      ..guid = stableGuid
      ..stagingGuid = null;
    journal.saveConfirmedSubmission(
      identity: identity,
      persistMessage: () => objectBox.box<Message>().put(local),
      now: testEpoch,
    );
  }

  Future<CloudOutboxOperation> admit(int id) => coordinator.admitLocalSend(
    scope,
    intentId: id,
    journal: journal,
    authFence: authFence,
    encodeMessage: (message) {
      encodes++;
      return _LocalCloudMessage(message);
    },
  );

  CloudSyncLocalSendExactSelection freshSelection() {
    final intent = objectBox.box<CloudSyncLocalSendIntentEntity>().get(
      freshIntentId,
    )!;
    return CloudSyncLocalSendExactSelection(
      intentId: freshIntentId,
      expectedRecipient: 'recipient@example.com',
      expectedSourceSha256: intent.sourceSha256,
    );
  }

  CloudOutboxOperationEntity heldRow() =>
      objectBox.box<CloudOutboxOperationEntity>().getAll().singleWhere(
        (row) =>
            row.zone == scope.zone &&
            row.state == CloudOutboxStatus.pending.index,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-manual-selection-retained-',
    );
    objectBox = await openStore(directory: directory.path);
    durable = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: _Protector(),
      clock: () => testEpoch,
    );
    transport = _StagingTransport();
    coordinator = CloudSyncOutboundAdmissionCoordinator(
      store: durable,
      transport: transport,
      ensureProtectedStoreRecovered: () async {},
    );
    for (final zone in const [
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      await durable.recordPullSuccess(sibling(zone), now: testEpoch);
    }
    bindJournal();
    encodes = 0;
    final auth = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic-session',
      accountFingerprint: testAccountFingerprintA,
      protectedStoreIdentity: 'obcs2.store.$testAccountFingerprintA',
      cloudMessagesClient: Object(),
    );
    authFence = CloudSyncLocalSendAuthFence(
      expected: auth,
      capture: () async => auth,
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
      stagingGuid: _oldGuid,
      text: 'synthetic old send',
      isFromMe: true,
      dateCreated: testEpoch,
      attributedBody: [AttributedBody.raw('synthetic old send')],
    )..chat.target = chat;
    journal.saveSubmission(
      identity: CloudSyncLocalSendIdentity.capture(local, chat, _oldGuid)!,
      newlyGeneratedGuid: true,
      persistMessage: () => objectBox.box<Message>().put(local),
      now: testEpoch,
    );
    oldIntentId = objectBox
        .box<CloudSyncLocalSendIntentEntity>()
        .getAll()
        .single
        .id;
    confirmMessage(_oldGuid);
    final chatScope = sibling('chatManateeZone');
    final source = await seedSyntheticRestoredChatAppliedSource(
      objectBox: objectBox,
      store: durable,
      chatScope: chatScope,
      now: testEpoch,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: objectBox,
      store: durable,
      chatScope: chatScope,
      chat: chat,
      appliedSource: source,
      now: testEpoch,
    );
    transport.stages.add(_stage('a', 'P', 'L', 'S'));
    await admit(oldIntentId);
    objectBox.box<CloudSyncLocalSendIntentEntity>().put(
      objectBox.box<CloudSyncLocalSendIntentEntity>().get(oldIntentId)!
        ..idsConfirmationVersion = 0,
    );
    const newGuid = 'AAAAAAAB-BBBB-4CCC-8DDD-EEEEEEEEEEEE';
    local = Message(
      guid: 'temp-New12345',
      stagingGuid: newGuid,
      text: 'synthetic fresh send',
      isFromMe: true,
      dateCreated: testEpoch,
      attributedBody: [AttributedBody.raw('synthetic fresh send')],
    )..chat.target = chat;
    journal.saveSubmission(
      identity: CloudSyncLocalSendIdentity.capture(local, chat, newGuid)!,
      newlyGeneratedGuid: true,
      persistMessage: () => objectBox.box<Message>().put(local),
      now: testEpoch,
    );
    freshIntentId = objectBox
        .box<CloudSyncLocalSendIntentEntity>()
        .getAll()
        .singleWhere((row) => row.localMessageId == local.id)
        .id;
    confirmMessage(newGuid);
    local = objectBox.box<Message>().get(local.id!)!;
    durable = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: _Protector(),
      clock: () => testEpoch,
      localSendJournal: journal,
    );
    coordinator = CloudSyncOutboundAdmissionCoordinator(
      store: durable,
      transport: transport,
      ensureProtectedStoreRecovered: () async {},
    );
  });

  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'valid held plus fresh permits exact selection and pins the held row',
    () async {
      expect(encodes, 1, reason: 'old send admitted once');
      final held = heldRow();
      expect(
        durable.isRetainedPreproofPendingCreate(
          (await durable.readOutboxEntries(
            scope,
          )).singleWhere((o) => o.operationId == held.operationId),
        ),
        isTrue,
      );
      expect(
        ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint([held]),
        isNull,
        reason: 'row-only helper stays strict',
      );
      expect(
        ObjectBoxCloudSyncPreflightReader.retainedPreproofAuditFingerprint(
          held,
          journal: journal,
        ),
        isNotNull,
      );
      final selection = freshSelection();
      selection.validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      );
      expect(selection.isInertAuditOperation(held.operationId), isTrue);
      selection.validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      );
    },
  );

  test('held attempt mutation remains blocking', () async {
    final selection = freshSelection();
    selection.validate(
      store: objectBox,
      journal: journal,
      durable: durable,
      scope: scope,
    );
    final held = heldRow();
    objectBox.box<CloudOutboxOperationEntity>().put(held..attemptCount = 1);
    expect(
      () => selection.validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
    expect(
      () => freshSelection().validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
  });

  test('held proof upgrade remains blocking', () async {
    final selection = freshSelection();
    selection.validate(
      store: objectBox,
      journal: journal,
      durable: durable,
      scope: scope,
    );
    objectBox.box<CloudSyncLocalSendIntentEntity>().put(
      objectBox.box<CloudSyncLocalSendIntentEntity>().get(oldIntentId)!
        ..idsConfirmationVersion = cloudSyncIdsConfirmationVersion,
    );
    expect(
      () => selection.validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
    expect(
      () => freshSelection().validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
  });

  test('held foreign account remains blocking', () async {
    final selection = freshSelection();
    selection.validate(
      store: objectBox,
      journal: journal,
      durable: durable,
      scope: scope,
    );
    final held = heldRow();
    objectBox.box<CloudOutboxOperationEntity>().put(
      held..accountFingerprint = testAccountFingerprintB,
    );
    expect(
      () => selection.validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
    expect(
      () => freshSelection().validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
  });

  test('held generation drift remains blocking', () async {
    final selection = freshSelection();
    selection.validate(
      store: objectBox,
      journal: journal,
      durable: durable,
      scope: scope,
    );
    final held = heldRow();
    objectBox.box<CloudOutboxOperationEntity>().put(
      held..checkpointGeneration = held.checkpointGeneration + 1,
    );
    expect(
      () => selection.validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
    expect(
      () => freshSelection().validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
  });

  test('pinned held deletion remains blocked', () async {
    final selection = freshSelection();
    selection.validate(
      store: objectBox,
      journal: journal,
      durable: durable,
      scope: scope,
    );
    final held = heldRow();
    objectBox.box<CloudOutboxOperationEntity>().remove(held.id);
    expect(
      () => selection.validate(
        store: objectBox,
        journal: journal,
        durable: durable,
        scope: scope,
      ),
      throwsStateError,
    );
  });
}

const _oldGuid = '11111111-1111-4111-8111-111111111111';

final class _LocalCloudMessage implements frb_api.CloudMessage {
  _LocalCloudMessage(Message message)
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
  int get type => 1;
  @override
  String get service => 'iMessage';
  @override
  String get sender => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CloudSyncProtectedOutboundStageData _stage(
  String lease,
  String ref,
  String logical,
  String server,
) => CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: List.filled(43, logical).join(),
  protectedEnvelopeReference: testProtectedReference(ref),
  payloadSha256: testSha256('a'),
  serverRecordIdHash: List.filled(43, server).join(),
  leaseReference: testProtectedLeaseReference(lease),
);

final class _StagingTransport implements CloudSyncOutboundStagingTransport {
  final List<CloudSyncProtectedOutboundStageData> stages = [];
  final List<String> committed = [];
  final List<String> rolledBack = [];
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
  }) async => stages.removeAt(0);
  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) async {
    committed.add(leaseReference);
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
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
