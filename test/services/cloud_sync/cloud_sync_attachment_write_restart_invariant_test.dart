// Write-restart invariant for one attachment byte upload.
//
// Offline and deterministic: real disposable ObjectBox store plus the real
// local-send and attachment-upload journals prove staged -> started ->
// unknown-outcome -> restart -> late-receipt reconciliation performs no
// second byte upload and no second outbox admission while the writer
// authority epoch stays fenced. No real accounts, files, or network.
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
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudSyncLocalSendJournal localSends;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncAttachmentUploadJournal uploads;
  late Chat chat;

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
    final snapshot = authority.read(_writerScope)!;
    localSends = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: snapshot,
    );
  }

  void seedCheckpoint() {
    final box = store.box<CloudSyncCheckpointEntity>();
    final key = cloudSyncPersistentScopeKey(_uploadScope);
    final query = box
        .query(CloudSyncCheckpointEntity_.checkpointKey.equals(key))
        .build();
    try {
      if (query.findUnique() != null) return;
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
        generation: 1,
        updatedAtMs: _time(0).millisecondsSinceEpoch,
      ),
    );
  }

  CloudSyncAttachmentUploadJournal buildUploads() =>
      CloudSyncAttachmentUploadJournal(
        store: store,
        localSends: localSends,
        scope: _uploadScope,
        checkpointGeneration: 1,
        currentAuth: auth,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-attachment-write-restart-',
    );
    store = await openStore(directory: directory.path);
    provisionJournal();
    chat = _chat();
    _persistChat(store, chat);
    auth = _auth(Object());
    seedCheckpoint();
    uploads = buildUploads();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    provisionJournal();
    auth = _auth(Object());
    uploads = buildUploads();
  }

  int seedConfirmedIntent() {
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
    attachment.guid = _guidA + '_0';
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

  test(
    'unknown byte outcome reconciles after restart without a second upload or outbox write and keeps the writer epoch fenced',
    () async {
      final intentId = seedConfirmedIntent();
      final prepared = uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      );
      uploads.beginAttempt(
        id: prepared.id,
        attemptId: _attemptA,
        now: _time(7),
      );
      uploads.markUnknown(
        id: prepared.id,
        attemptId: _attemptA,
        now: _time(8),
      );
      final epochBefore = authority.read(_writerScope)!.epoch;
      final bindingBefore = uploads.reconciliationBindingSha256(prepared.id);
      expect(uploads.read(prepared.id).state, CloudAttachmentUploadState.unknown);
      expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      await reopen();
      final epochAfter = authority.read(_writerScope)!.epoch;
      expect(epochAfter, epochBefore,
          reason: 'Restart must not rotate the writer epoch.');
      final restarted = uploads.read(prepared.id);
      expect(restarted.state, CloudAttachmentUploadState.unknown);
      expect(restarted.attemptId, _attemptA);
      expect(restarted.plan.payloadSha256, _planA().payloadSha256);
      expect(store.box<CloudAttachmentUploadEntity>().get(prepared.id)!.writerEpoch, epochBefore);
      expect(uploads.reconciliationBindingSha256(prepared.id), bindingBefore);
      expect(uploads.readAttemptedForReconciliation(), [prepared.id]);
      final lookup = uploads.findForAttachment(
        localSendIntentId: intentId,
        logicalEntityKeyHash: _planA().logicalEntityKeyHash,
        sourceAttachmentKeys: {_planA().logicalEntityKeyHash},
      )!;
      expect(lookup.id, prepared.id);
      expect(lookup.state, CloudAttachmentUploadState.unknown);
      final duplicate = uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(9),
      );
      expect(duplicate.id, prepared.id);
      expect(
        () => uploads.beginAttempt(
          id: prepared.id,
          attemptId: _attemptB,
          now: _time(9),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_already_attempted')),
      );
      expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      final reconciled = uploads.recordUploaded(
        id: prepared.id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(10),
      );
      expect(reconciled.state, CloudAttachmentUploadState.uploaded);
      expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(uploads.reconciliationBindingSha256(prepared.id), bindingBefore);
      var admissions = 0;
      CloudOutboxOperation admit(Store tx, CloudSyncProtectedOutboundStageData result) {
        admissions++;
        _persistFinalOperation(tx, result);
        return _finalOperation(result);
      }
      final adopted = uploads.adoptRecordCreate(
        id: prepared.id,
        admit: admit,
        now: _time(11),
      );
      expect(adopted.state, CloudAttachmentUploadState.adopted);
      expect(admissions, 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      final repeat = uploads.adoptRecordCreate(
        id: prepared.id,
        admit: admit,
        now: _time(12),
      );
      expect(repeat.admittedOperationId, adopted.admittedOperationId);
      expect(admissions, 1, reason: 'Recovery must not replay the outbox admission.');
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(authority.read(_writerScope)!.epoch, epochBefore);
    },
  );
}

Message _attachmentMessage({required String stableGuid, required String attachmentGuid}) {
  return Message(
    guid: 'local-' + stableGuid,
    text: ' ',
    dateCreated: _time(1),
    isFromMe: true,
    hasAttachments: true,
    attributedBody: [
      AttributedBody(
        string: ' ',
        runs: [
          Run(range: const [0, 1], attributes: Attributes(attachmentGuid: attachmentGuid)),
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

CloudSyncNativeAuthSnapshot _auth(Object client) => CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'native-session',
      accountFingerprint: _accountA,
      protectedStoreIdentity: _storeA,
      cloudMessagesClient: client,
    );

CloudSyncProtectedOutboundStageData _planA() => CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('C'),
      protectedEnvelopeReference: _ref('E'),
      payloadSha256: _digest('c'),
      serverRecordIdHash: _token('D'),
      leaseReference: _lease('d'),
    );

CloudSyncProtectedOutboundStageData _resultA() => CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('C'),
      protectedEnvelopeReference: _ref('F'),
      payloadSha256: _digest('e'),
      serverRecordIdHash: _token('D'),
      leaseReference: _lease('1'),
    );

CloudOutboxOperation _finalOperation(CloudSyncProtectedOutboundStageData result) => CloudOutboxOperation(
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

void _persistFinalOperation(Store tx, CloudSyncProtectedOutboundStageData result) {
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

Matcher _stateFailure(String message) => isA<StateError>().having((error) => error.message, 'message', message);

String _initialOperation(CloudSyncProtectedOutboundStageData stage) => CloudOperationIdentity.forInitialCreate(
      scope: _uploadScope,
      logicalEntityKeyHash: stage.logicalEntityKeyHash,
      payloadVersion: 1,
    );

DateTime _time(int seconds) => DateTime.utc(2026, 9, 4, 12, 0, seconds);

String _token(String char) => List.filled(43, char).join();
String _digest(String char) => List.filled(64, char).join();
String _ref(String char) => 'obcs2.ref.' + _token(char);
String _lease(String char) => 'obcs2.lease.' + List.filled(32, char).join();

const _accountA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _attemptA = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _attemptB = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const _storeA = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

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
