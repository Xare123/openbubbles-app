// Bounded coverage for CloudSyncAttachmentUploadJournal.
//
// Uses a real disposable ObjectBox store plus the established local-send
// attachment fixtures (pending save -> protected-source adoption -> native IDS
// confirmation -> deferred promotion) to prove IDS-confirmed, source-bound
// upload origin. No real accounts, files, or network.
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
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_mutation_guard.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
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

  CloudSyncAttachmentUploadJournal buildUploads({
    int generation = 1,
    CloudSyncNativeAuthSnapshot? authOverride,
  }) => CloudSyncAttachmentUploadJournal(
    store: store,
    localSends: localSends,
    scope: _uploadScope,
    checkpointGeneration: generation,
    currentAuth: authOverride ?? auth,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-sync-attachment-upload-journal-',
    );
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

  int seedConfirmedIntent({
    String stableGuid = _guidA,
    String attachmentGuid = 'LOCAL-ATTACHMENT-A',
  }) {
    final attachment = Attachment(
      guid: attachmentGuid,
      metadata: const {'rustpush': '<attachment><id>A</id></attachment>'},
    );
    store.box<Attachment>().put(attachment);
    final message = _attachmentMessage(
      stableGuid: stableGuid,
      attachmentGuid: attachmentGuid,
    );
    message.chat.target = chat;
    message.dbAttachments.add(attachment);
    final identity = CloudSyncLocalSendIdentity.captureAttachment(
      message,
      chat,
      stableGuid,
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
    attachment.guid = '${stableGuid}_0';
    store.box<Attachment>().put(attachment);
    message
      ..guid = stableGuid
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
      stableGuid: stableGuid,
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

  CloudAttachmentUploadSnapshot toUploaded(
    int intentId,
    CloudSyncProtectedOutboundStageData plan,
    CloudSyncProtectedOutboundStageData result,
    String attemptId,
  ) {
    final prepared = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: plan,
      now: _time(6),
    );
    uploads.beginAttempt(id: prepared.id, attemptId: attemptId, now: _time(7));
    return uploads.recordUploaded(
      id: prepared.id,
      attemptId: attemptId,
      result: result,
      now: _time(8),
    );
  }

  void seedAccountReadReady() {
    final box = store.box<CloudSyncCheckpointEntity>();
    for (final zone in [
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      final scope = CloudSyncScope(
        accountFingerprint: _accountA,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: zone,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final key = cloudSyncPersistentScopeKey(scope);
      final query = box
          .query(CloudSyncCheckpointEntity_.checkpointKey.equals(key))
          .build();
      final CloudSyncCheckpointEntity row;
      try {
        row =
            query.findUnique() ??
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

  test(
    'completed upload atomically enters real record map and final-save outbox once across reopen',
    () async {
      final intent = seedConfirmedIntent();
      final uploaded = toUploaded(intent, _planA(), _resultA(), _attemptA);
      seedAccountReadReady();
      final adopted = _liveStore(store).admitCompletedAttachmentUpload(
        scope: _uploadScope,
        uploads: uploads,
        uploadId: uploaded.id,
        createdAt: _time(9),
      );
      expect(adopted.state, CloudAttachmentUploadState.adopted);
      final outbox = store.box<CloudOutboxOperationEntity>().getAll().single;
      final mapping = store.box<CloudRecordMapEntity>().getAll().single;
      expect(outbox.operationId, adopted.admittedOperationId);
      expect(outbox.state, CloudOutboxStatus.pending.index);
      expect(outbox.attemptCount, 0);
      expect(outbox.payloadVersion, 1);
      expect(outbox.appleOperationUuid, isNull);
      expect(outbox.encryptedPayloadRef, _resultA().protectedEnvelopeReference);
      expect(mapping.logicalEntityKeyHash, _resultA().logicalEntityKeyHash);
      expect(mapping.serverRecordIdHash, _resultA().serverRecordIdHash);
      expect(
        mapping.encryptedServerRecordId,
        _resultA().protectedEnvelopeReference,
      );
      await reopen();
      final recovered = _liveStore(store).admitCompletedAttachmentUpload(
        scope: _uploadScope,
        uploads: uploads,
        uploadId: uploaded.id,
        createdAt: _time(10),
      );
      expect(recovered.admittedOperationId, adopted.admittedOperationId);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
    },
  );

  test(
    'source lookup retains one original plan across attempt, result and reopen',
    () async {
      final intent = seedConfirmedIntent();
      CloudAttachmentUploadSnapshot? lookup() => uploads.findForAttachment(
        localSendIntentId: intent,
        logicalEntityKeyHash: _planA().logicalEntityKeyHash,
        sourceAttachmentKeys: {_planA().logicalEntityKeyHash},
      );
      expect(lookup(), isNull);
      final prepared = uploads.adoptPlan(
        localSendIntentId: intent,
        plan: _planA(),
        now: _time(6),
      );
      expect(lookup()!.id, prepared.id);
      uploads.beginAttempt(
        id: prepared.id,
        attemptId: _attemptA,
        now: _time(7),
      );
      uploads.markUnknown(id: prepared.id, attemptId: _attemptA, now: _time(8));
      await reopen();
      expect(lookup()!.state, CloudAttachmentUploadState.unknown);
      expect(lookup()!.plan.payloadSha256, _planA().payloadSha256);
      uploads.recordUploaded(
        id: prepared.id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(9),
      );
      expect(lookup()!.result!.leaseReference, _resultA().leaseReference);
      expect(
        uploads.findForAttachment(
          localSendIntentId: intent,
          logicalEntityKeyHash: _token('x'),
          sourceAttachmentKeys: {_planA().logicalEntityKeyHash, _token('x')},
        ),
        isNull,
      );
      seedCheckpoint(2);
      uploads = buildUploads(generation: 2);
      expect(lookup, throwsStateError);
    },
  );

  test(
    'changed inventory cannot hide a retained plan and authorize reupload',
    () {
      final intent = seedConfirmedIntent();
      final original = uploads.adoptPlan(
        localSendIntentId: intent,
        plan: _planA(),
        now: _time(6),
      );
      uploads.beginAttempt(
        id: original.id,
        attemptId: _attemptA,
        now: _time(7),
      );
      uploads.markUnknown(id: original.id, attemptId: _attemptA, now: _time(8));
      expect(
        () => uploads.findForAttachment(
          localSendIntentId: intent,
          logicalEntityKeyHash: _token('x'),
          sourceAttachmentKeys: {_token('x')},
        ),
        throwsA(
          _stateFailure('cloud_sync_attachment_upload_inventory_changed'),
        ),
      );
      expect(
        uploads.read(original.id).state,
        CloudAttachmentUploadState.unknown,
      );
      expect(
        uploads.read(original.id).plan.payloadSha256,
        _planA().payloadSha256,
      );
      expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
      expect(
        () => uploads.findForAttachment(
          localSendIntentId: intent,
          logicalEntityKeyHash: _token('x'),
          sourceAttachmentKeys: {_planA().logicalEntityKeyHash},
        ),
        throwsStateError,
      );
    },
  );

  test(
    'blocked projection retains completed upload without partial final-save admission',
    () {
      final uploaded = toUploaded(
        seedConfirmedIntent(),
        _planA(),
        _resultA(),
        _attemptA,
      );
      expect(
        () => _liveStore(store).admitCompletedAttachmentUpload(
          scope: _uploadScope,
          uploads: uploads,
          uploadId: uploaded.id,
          createdAt: _time(9),
        ),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(
        uploads.read(uploaded.id).state,
        CloudAttachmentUploadState.uploaded,
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(store.box<CloudRecordMapEntity>().count(), 0);
      seedAccountReadReady();
      expect(
        _liveStore(store)
            .admitCompletedAttachmentUpload(
              scope: _uploadScope,
              uploads: uploads,
              uploadId: uploaded.id,
              createdAt: _time(10),
            )
            .state,
        CloudAttachmentUploadState.adopted,
      );
    },
  );

  test(
    'prepared and unknown bytes cannot become final records, nor cross scope',
    () {
      final plan = uploads.adoptPlan(
        localSendIntentId: seedConfirmedIntent(),
        plan: _planA(),
        now: _time(6),
      );
      seedAccountReadReady();
      void attempt() => _liveStore(store).admitCompletedAttachmentUpload(
        scope: _uploadScope,
        uploads: uploads,
        uploadId: plan.id,
        createdAt: _time(9),
      );
      expect(
        attempt,
        throwsA(_stateFailure('cloud_sync_attachment_upload_result_missing')),
      );
      uploads.beginAttempt(id: plan.id, attemptId: _attemptA, now: _time(7));
      uploads.markUnknown(id: plan.id, attemptId: _attemptA, now: _time(8));
      expect(
        attempt,
        throwsA(_stateFailure('cloud_sync_attachment_upload_result_missing')),
      );
      expect(
        () => _liveStore(store).admitCompletedAttachmentUpload(
          scope: CloudSyncScope(
            accountFingerprint: _accountA,
            container: 'com.apple.messages.cloud',
            database: 'private',
            zone: 'messageManateeZone',
            persistenceLane: CloudSyncPersistenceLane.semantic,
          ),
          uploads: uploads,
          uploadId: plan.id,
          createdAt: _time(9),
        ),
        throwsA(isA<CloudSyncFailure>()),
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(store.box<CloudRecordMapEntity>().count(), 0);
    },
  );

  test(
    'final attachment save requires its upload journal again when leased',
    () async {
      final completed = toUploaded(
        seedConfirmedIntent(),
        _planA(),
        _resultA(),
        _attemptA,
      );
      seedAccountReadReady();
      final adopted = _liveStore(store).admitCompletedAttachmentUpload(
        scope: _uploadScope,
        uploads: uploads,
        uploadId: completed.id,
        createdAt: _time(9),
      );
      Future<List<CloudOutboxOperation>> lease(
        ObjectBoxCloudSyncStore target,
      ) => target.leaseEligibleOutbox(
        _uploadScope,
        now: _time(10),
        limit: 1,
        leaseId: 'fixture-attachment-save',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      await expectLater(
        lease(_liveStore(store)),
        throwsA(_stateFailure('cloud_sync_attachment_upload_journal_required')),
      );
      expect(
        store.box<CloudOutboxOperationEntity>().getAll().single.state,
        CloudOutboxStatus.pending.index,
      );
      await reopen();
      final leased = await lease(_liveStore(store, uploads: uploads));
      expect(leased.single.operationId, adopted.admittedOperationId);
      expect(leased.single.status, CloudOutboxStatus.leased);
      expect(leased.single.serverRecordIdHash, _resultA().serverRecordIdHash);
    },
  );

  test(
    'changed upload origin cannot lease an already admitted final save',
    () async {
      final completed = toUploaded(
        seedConfirmedIntent(),
        _planA(),
        _resultA(),
        _attemptA,
      );
      seedAccountReadReady();
      _liveStore(store).admitCompletedAttachmentUpload(
        scope: _uploadScope,
        uploads: uploads,
        uploadId: completed.id,
        createdAt: _time(9),
      );
      final box = store.box<CloudAttachmentUploadEntity>();
      final changed = box.get(completed.id)!..sourceSha256 = _digest('e');
      box.put(changed);
      await expectLater(
        _liveStore(store, uploads: uploads).leaseEligibleOutbox(
          _uploadScope,
          now: _time(10),
          limit: 1,
          leaseId: 'fixture-changed-origin',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        store.box<CloudOutboxOperationEntity>().getAll().single.state,
        CloudOutboxStatus.pending.index,
      );
    },
  );

  test('pending or IDS-unconfirmed origin cannot adopt a plan', () {
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
    final intentId = store
        .box<CloudSyncLocalSendIntentEntity>()
        .getAll()
        .single
        .id;
    expect(
      () => uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_not_ready')),
    );
    localSends.adoptProtectedSource(
      identity: identity,
      source: CloudSyncLocalSendSourceBinding(
        accountFingerprint: _accountA,
        protectedStoreIdentity: _storeA,
        messageGuidHash: identity.guidHash,
        sourceSha256: identity.sourceSha256,
        protectedReference: _ref('A'),
        leaseReference: _lease('a'),
        payloadSha256: _digest('b'),
        payloadLength: 512,
      ),
      capturedAuth: auth,
      stillCurrent: () => true,
      now: _time(3),
    );
    // A protected source alone is never upload authority: the intent is still
    // pending, so the state gate rejects before any IDS-proof check.
    expect(
      () => uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_not_ready')),
    );
    expect(store.box<CloudAttachmentUploadEntity>().count(), 0);
  });

  test(
    'duplicate identical plan returns the original row; replacement rejects',
    () {
      final intentId = seedConfirmedIntent();
      final first = uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      );
      final second = uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      );
      expect(second.id, first.id);
      expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
      expect(
        () => uploads.adoptPlan(
          localSendIntentId: intentId,
          plan: _planA(record: _token('J')),
          now: _time(6),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_plan_changed')),
      );
      expect(
        () => uploads.adoptPlan(
          localSendIntentId: intentId,
          plan: _planA(payload: _digest('0')),
          now: _time(6),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_plan_changed')),
      );
      expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
      expect(uploads.read(first.id).uploadKey, first.uploadKey);
    },
  );

  test(
    'beginAttempt persists across reopen and unknown accepts only the same attempt',
    () async {
      final intentId = seedConfirmedIntent();
      final prepared = uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      );
      expect(
        () => uploads.beginAttempt(
          id: prepared.id,
          attemptId: 'not-a-uuid',
          now: _time(7),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_attempt_invalid')),
      );
      final started = uploads.beginAttempt(
        id: prepared.id,
        attemptId: _attemptA,
        now: _time(7),
      );
      expect(started.state, CloudAttachmentUploadState.started);
      expect(started.attemptId, _attemptA);
      await reopen();
      final restored = uploads.read(prepared.id);
      expect(restored.state, CloudAttachmentUploadState.started);
      expect(restored.attemptId, _attemptA);
      expect(
        () => uploads.beginAttempt(
          id: prepared.id,
          attemptId: _attemptA,
          now: _time(7),
        ),
        throwsA(
          _stateFailure('cloud_sync_attachment_upload_already_attempted'),
        ),
      );
      expect(
        () => uploads.beginAttempt(
          id: prepared.id,
          attemptId: _attemptB,
          now: _time(7),
        ),
        throwsA(
          _stateFailure('cloud_sync_attachment_upload_already_attempted'),
        ),
      );
      uploads.markUnknown(id: prepared.id, attemptId: _attemptA, now: _time(8));
      expect(
        uploads.read(prepared.id).state,
        CloudAttachmentUploadState.unknown,
      );
      expect(
        () => uploads.markUnknown(
          id: prepared.id,
          attemptId: _attemptB,
          now: _time(8),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_attempt_changed')),
      );
      expect(
        () => uploads.beginAttempt(
          id: prepared.id,
          attemptId: _attemptA,
          now: _time(8),
        ),
        throwsA(
          _stateFailure('cloud_sync_attachment_upload_already_attempted'),
        ),
      );
      final uploaded = uploads.recordUploaded(
        id: prepared.id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(9),
      );
      expect(uploaded.state, CloudAttachmentUploadState.uploaded);
      expect(uploaded.result!.leaseReference, _lease('1'));
    },
  );

  test(
    'wrong attempt or record rejects; identical result repeat is idempotent',
    () {
      final intentId = seedConfirmedIntent();
      final prepared = uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      );
      expect(
        () => uploads.recordUploaded(
          id: prepared.id,
          attemptId: _attemptA,
          result: _resultA(),
          now: _time(8),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_result_changed')),
      );
      uploads.beginAttempt(
        id: prepared.id,
        attemptId: _attemptA,
        now: _time(7),
      );
      expect(
        () => uploads.recordUploaded(
          id: prepared.id,
          attemptId: _attemptB,
          result: _resultA(),
          now: _time(8),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_result_changed')),
      );
      expect(
        () => uploads.recordUploaded(
          id: prepared.id,
          attemptId: _attemptA,
          result: _resultA(record: _token('J')),
          now: _time(8),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_result_changed')),
      );
      final uploaded = uploads.recordUploaded(
        id: prepared.id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(8),
      );
      expect(uploaded.state, CloudAttachmentUploadState.uploaded);
      final repeat = uploads.recordUploaded(
        id: prepared.id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(9),
      );
      expect(repeat.id, uploaded.id);
      expect(repeat.result!.protectedEnvelopeReference, _ref('F'));
      expect(
        () => uploads.recordUploaded(
          id: prepared.id,
          attemptId: _attemptA,
          result: _resultA(lease: _lease('3')),
          now: _time(9),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_result_changed')),
      );
      expect(
        () => uploads.recordUploaded(
          id: prepared.id,
          attemptId: _attemptA,
          result: _resultA(payload: _digest('0')),
          now: _time(9),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_result_changed')),
      );
      expect(uploads.read(prepared.id).result!.leaseReference, _lease('1'));
    },
  );

  test(
    'adoptRecordCreate hands off atomically and never replays the callback',
    () async {
      final intentId = seedConfirmedIntent();
      final uploaded = toUploaded(intentId, _planA(), _resultA(), _attemptA);
      var calls = 0;
      var adopted = uploads.adoptRecordCreate(
        id: uploaded.id,
        admit: (tx, result) {
          calls++;
          _persistFinalOperation(tx, result);
          return _finalOperation(result);
        },
        now: _time(10),
      );
      expect(calls, 1);
      expect(adopted.state, CloudAttachmentUploadState.adopted);
      expect(adopted.admittedOperationId, _initialOperation(_resultA()));
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      adopted = uploads.adoptRecordCreate(
        id: uploaded.id,
        admit: (tx, result) {
          calls++;
          _persistFinalOperation(tx, result, operationId: _digest('f'));
          return _finalOperation(result, operationId: _digest('f'));
        },
        now: _time(11),
      );
      expect(calls, 1);
      expect(adopted.state, CloudAttachmentUploadState.adopted);
      expect(adopted.admittedOperationId, _initialOperation(_resultA()));
      await reopen();
      adopted = uploads.adoptRecordCreate(
        id: uploaded.id,
        admit: (tx, result) {
          calls++;
          _persistFinalOperation(tx, result, operationId: _digest('f'));
          return _finalOperation(result, operationId: _digest('f'));
        },
        now: _time(12),
      );
      expect(calls, 1);
      expect(adopted.state, CloudAttachmentUploadState.adopted);
      expect(
        () => uploads.beginAttempt(
          id: uploaded.id,
          attemptId: _attemptB,
          now: _time(13),
        ),
        throwsA(
          _stateFailure('cloud_sync_attachment_upload_already_attempted'),
        ),
      );
    },
  );

  test(
    'mismatched or missing final operation rolls back the callback insert',
    () {
      final firstId = seedConfirmedIntent();
      final first = toUploaded(firstId, _planA(), _resultA(), _attemptA);
      expect(
        () => uploads.adoptRecordCreate(
          id: first.id,
          admit: (tx, result) {
            _persistFinalOperation(tx, result);
            return _finalOperation(result, payload: _digest('0'));
          },
          now: _time(10),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_adoption_changed')),
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      final retained = uploads.read(first.id);
      expect(retained.state, CloudAttachmentUploadState.uploaded);
      expect(retained.admittedOperationId, isNull);
      expect(retained.result!.leaseReference, _lease('1'));
      final secondId = seedConfirmedIntent(
        stableGuid: _guidB,
        attachmentGuid: 'LOCAL-ATTACHMENT-B',
      );
      final second = toUploaded(secondId, _planB(), _resultB(), _attemptB);
      expect(
        () => uploads.adoptRecordCreate(
          id: second.id,
          admit: (tx, result) => _finalOperation(result),
          now: _time(10),
        ),
        throwsA(_stateFailure('cloud_sync_attachment_upload_adoption_changed')),
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(
        uploads.read(second.id).state,
        CloudAttachmentUploadState.uploaded,
      );
    },
  );

  test(
    'handoff rejects bare hashes and another canonical operation identity',
    () {
      final intentId = seedConfirmedIntent();
      final uploaded = toUploaded(intentId, _planA(), _resultA(), _attemptA);
      for (final wrongId in [_digest('e'), _initialOperation(_resultB())]) {
        expect(
          () => uploads.adoptRecordCreate(
            id: uploaded.id,
            admit: (tx, result) {
              _persistFinalOperation(tx, result, operationId: wrongId);
              return _finalOperation(result, operationId: wrongId);
            },
            now: _time(10),
          ),
          throwsA(
            _stateFailure('cloud_sync_attachment_upload_adoption_changed'),
          ),
        );
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
        expect(
          uploads.read(uploaded.id).state,
          CloudAttachmentUploadState.uploaded,
        );
      }
    },
  );

  test('checkpoint reset cannot hide an earlier unknown attempt', () {
    final intentId = seedConfirmedIntent();
    final prepared = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: _planA(),
      now: _time(6),
    );
    uploads.beginAttempt(id: prepared.id, attemptId: _attemptA, now: _time(7));
    uploads.markUnknown(id: prepared.id, attemptId: _attemptA, now: _time(8));
    seedCheckpoint(2);
    final gen2 = buildUploads(generation: 2);
    expect(
      () => gen2.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(
          record: _token('J'),
          payload: _digest('9'),
          reference: _ref('K'),
          lease: _lease('4'),
        ),
        now: _time(9),
      ),
      throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')),
    );
    expect(store.box<CloudAttachmentUploadEntity>().count(), 1);
    expect(
      () => uploads.read(prepared.id),
      throwsA(_stateFailure('cloud_sync_attachment_upload_generation_changed')),
    );
  });

  test('plan adoption is stable across the attempt lifecycle', () {
    final intentId = seedConfirmedIntent();
    final first = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: _planA(),
      now: _time(6),
    );
    uploads.beginAttempt(id: first.id, attemptId: _attemptA, now: _time(7));
    final again = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: _planA(),
      now: _time(8),
    );
    expect(again.id, first.id);
    expect(again.state, CloudAttachmentUploadState.started);
    expect(
      () => uploads.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(record: _token('J')),
        now: _time(8),
      ),
      throwsA(_stateFailure('cloud_sync_attachment_upload_plan_changed')),
    );
  });

  test('generation mismatch blocks adoption', () {
    final genIntent = seedConfirmedIntent();
    final gen2 = buildUploads(generation: 2);
    expect(
      () => gen2.adoptPlan(
        localSendIntentId: genIntent,
        plan: _planA(),
        now: _time(6),
      ),
      throwsA(_stateFailure('cloud_sync_attachment_upload_generation_changed')),
    );
    expect(store.box<CloudAttachmentUploadEntity>().count(), 0);
  });

  test('account mismatch blocks journal construction', () {
    expect(
      () => buildUploads(authOverride: _auth(Object(), account: _accountB)),
      throwsA(_stateFailure('cloud_sync_attachment_upload_scope_invalid')),
    );
  });

  test('protected-store owner mismatch blocks adoption and reads', () {
    final intentId = seedConfirmedIntent();
    final other = buildUploads(authOverride: _auth(Object(), store: _storeB));
    expect(
      () => other.adoptPlan(
        localSendIntentId: intentId,
        plan: _planA(),
        now: _time(6),
      ),
      throwsA(_stateFailure('cloud_sync_local_send_protected_source_changed')),
    );
    final prepared = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: _planA(),
      now: _time(6),
    );
    expect(
      () => other.read(prepared.id),
      throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')),
    );
  });

  test('corrupted row fails reads and lease recovery', () async {
    final intentId = seedConfirmedIntent();
    final prepared = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: _planA(),
      now: _time(6),
    );
    final box = store.box<CloudAttachmentUploadEntity>();
    final row = box.get(prepared.id)!..state = 99;
    box.put(row);
    expect(
      () => uploads.read(prepared.id),
      throwsA(_stateFailure('cloud_sync_attachment_upload_row_invalid')),
    );
    expect(
      () => uploads.beginAttempt(
        id: prepared.id,
        attemptId: _attemptA,
        now: _time(7),
      ),
      throwsA(_stateFailure('cloud_sync_attachment_upload_row_invalid')),
    );
    expect(
      () => uploads.recordUploaded(
        id: prepared.id,
        attemptId: _attemptA,
        result: _resultA(),
        now: _time(8),
      ),
      throwsA(_stateFailure('cloud_sync_attachment_upload_row_invalid')),
    );
    await expectLater(
      _liveStore(
        store,
      ).readLiveProtectedOutboundLeaseReferences(maximumCount: 4096),
      throwsStateError,
    );
  });

  test('lease recovery retains plan and result leases', () async {
    final firstId = seedConfirmedIntent();
    toUploaded(firstId, _planA(), _resultA(), _attemptA);
    final secondId = seedConfirmedIntent(
      stableGuid: _guidB,
      attachmentGuid: 'LOCAL-ATTACHMENT-B',
    );
    final second = uploads.adoptPlan(
      localSendIntentId: secondId,
      plan: _planB(),
      now: _time(6),
    );
    uploads.beginAttempt(id: second.id, attemptId: _attemptB, now: _time(7));
    uploads.markUnknown(id: second.id, attemptId: _attemptB, now: _time(8));
    final live = await _liveStore(
      store,
    ).readLiveProtectedOutboundLeaseReferences(maximumCount: 4096);
    expect(live, containsAll([_lease('d'), _lease('1'), _lease('2')]));
  });

  test('reconciliation binding is stable across attempt lifecycle stages', () {
    final intentId = seedConfirmedIntent();
    final prepared = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: _planA(),
      now: _time(6),
    );
    uploads.beginAttempt(id: prepared.id, attemptId: _attemptA, now: _time(7));
    final started = uploads.reconciliationBindingSha256(prepared.id);
    uploads.markUnknown(id: prepared.id, attemptId: _attemptA, now: _time(8));
    expect(uploads.reconciliationBindingSha256(prepared.id), started);
    uploads.recordUploaded(
      id: prepared.id,
      attemptId: _attemptA,
      result: _resultA(),
      now: _time(9),
    );
    expect(uploads.reconciliationBindingSha256(prepared.id), started);
    uploads.adoptRecordCreate(
      id: prepared.id,
      admit: (tx, result) {
        _persistFinalOperation(tx, result);
        return _finalOperation(result);
      },
      now: _time(10),
    );
    expect(uploads.reconciliationBindingSha256(prepared.id), started);
    expect(uploads.read(prepared.id).state, CloudAttachmentUploadState.adopted);
  });

  test('reconciliation binding separates origin, plan, and attempt', () {
    final firstId = seedConfirmedIntent();
    final first = uploads.adoptPlan(
      localSendIntentId: firstId,
      plan: _planA(),
      now: _time(6),
    );
    uploads.beginAttempt(id: first.id, attemptId: _attemptA, now: _time(7));
    final baseline = uploads.reconciliationBindingSha256(first.id);
    final uploadsBox = store.box<CloudAttachmentUploadEntity>();
    // Attempt alone changes the digest.
    uploadsBox.put(uploadsBox.get(first.id)!..attemptId = _attemptB);
    expect(uploads.reconciliationBindingSha256(first.id), isNot(baseline));
    // Restored attempt reproduces the baseline; plan lease alone changes it.
    uploadsBox.put(uploadsBox.get(first.id)!..attemptId = _attemptA);
    expect(uploads.reconciliationBindingSha256(first.id), baseline);
    uploadsBox.put(uploadsBox.get(first.id)!..planLeaseReference = _lease('9'));
    expect(uploads.reconciliationBindingSha256(first.id), isNot(baseline));
    uploadsBox.put(uploadsBox.get(first.id)!..planLeaseReference = _lease('d'));
    expect(uploads.reconciliationBindingSha256(first.id), baseline);
    // A distinct origin, plan, and attempt binds distinctly.
    final secondId = seedConfirmedIntent(
      stableGuid: _guidB,
      attachmentGuid: 'LOCAL-ATTACHMENT-B',
    );
    final second = uploads.adoptPlan(
      localSendIntentId: secondId,
      plan: _planB(),
      now: _time(6),
    );
    uploads.beginAttempt(id: second.id, attemptId: _attemptB, now: _time(7));
    expect(uploads.reconciliationBindingSha256(second.id), isNot(baseline));
  });

  test('reconciliation binding refuses a row before its attempt begins', () {
    final prepared = uploads.adoptPlan(
      localSendIntentId: seedConfirmedIntent(),
      plan: _planA(),
      now: _time(6),
    );
    expect(
      () => uploads.reconciliationBindingSha256(prepared.id),
      throwsA(_stateFailure('cloud_sync_attachment_upload_not_started')),
    );
  });

  test('reconciliation binding drifts with auth and checkpoint generation', () {
    final intentId = seedConfirmedIntent();
    final prepared = uploads.adoptPlan(
      localSendIntentId: intentId,
      plan: _planA(),
      now: _time(6),
    );
    uploads.beginAttempt(id: prepared.id, attemptId: _attemptA, now: _time(7));
    final other = buildUploads(authOverride: _auth(Object(), store: _storeB));
    expect(
      () => other.reconciliationBindingSha256(prepared.id),
      throwsA(_stateFailure('cloud_sync_attachment_upload_binding_changed')),
    );
    seedCheckpoint(2);
    expect(
      () => uploads.reconciliationBindingSha256(prepared.id),
      throwsA(_stateFailure('cloud_sync_attachment_upload_generation_changed')),
    );
  });

  for (final scenario in [
    'started',
    'unknown',
    'uploaded',
    'settled_history',
    'missing',
    'no_fence',
    'other_fence',
    'other_intent',
    'foreign_account',
    'foreign_store',
    'foreign_generation',
    'invalid_attempt',
    'forged_duplicate',
    'overflow',
    'changed_after_verify',
  ]) {
    test(
      'pending byte-fence discovery is exact and receipt-only: $scenario',
      () async {
        final originalEpoch = authoritySnapshot.epoch;
        final intentId = seedConfirmedIntent();
        final upload = uploads.adoptPlan(
          localSendIntentId: intentId,
          plan: _planA(),
          now: _time(6),
        );
        uploads.beginAttempt(
          id: upload.id,
          attemptId: _attemptA,
          now: _time(7),
        );
        if (scenario == 'unknown') {
          uploads.markUnknown(
            id: upload.id,
            attemptId: _attemptA,
            now: _time(8),
          );
        }
        if (scenario == 'uploaded') {
          uploads.recordUploaded(
            id: upload.id,
            attemptId: _attemptA,
            result: _resultA(),
            now: _time(8),
          );
        }
        if (scenario == 'settled_history') {
          for (var i = 1; i <= 65; i++) {
            final historicalIntent = seedConfirmedIntent(
              stableGuid:
                  '${i.toRadixString(16).padLeft(8, '0')}-2222-4222-8222-222222222222',
              attachmentGuid: 'HISTORY-$i',
            );
            final historical = uploads.adoptPlan(
              localSendIntentId: historicalIntent,
              plan: _planA(),
              now: _time(6),
            );
            uploads.beginAttempt(
              id: historical.id,
              attemptId: _attemptA,
              now: _time(7),
            );
            uploads.recordUploaded(
              id: historical.id,
              attemptId: _attemptA,
              result: _resultA(),
              now: _time(8),
            );
            if (i == 65) {
              uploads.adoptRecordCreate(
                id: historical.id,
                now: _time(9),
                admit: (tx, result) {
                  _persistFinalOperation(tx, result);
                  return _finalOperation(result);
                },
              );
            }
          }
          expect(store.box<CloudAttachmentUploadEntity>().count(), 66);
          expect(uploads.readAttemptedForReconciliation(), [upload.id]);
        }
        final originalOutboxIds = store
            .box<CloudOutboxOperationEntity>()
            .getAll()
            .map((row) => row.operationId)
            .toList();
        final binding = _UploadRecoveryBinding();
        final guard = CloudKitWriterMutationGuard.forTest(
          store: store,
          readActiveClient: () => auth.cloudMessagesClient,
          privateStorageDirectory: directory.path,
          buildDecision: CloudKitWriterOwnership.resolve('v2'),
          nativeAuthBinding: binding,
          reconciliationBinding: binding,
        );
        final interlock = CloudKitOperationInterlock(
          privateStorageDirectory: directory.path,
          fenceStore: InMemoryCloudSyncStore(),
        );
        Future<T> run<T>(Future<T> Function() action) => interlock.runExclusive(
          kind: CloudKitOperationKind.v2ReadWrite,
          action: action,
        );
        if (scenario != 'no_fence') {
          await expectLater(
            run(
              () => guard.runAuthorized<void>(
                owner: CloudKitWriterOwner.v2,
                expectedClient: auth.cloudMessagesClient,
                expectedAccountFingerprint: _accountA,
                preparedHandleBindingSha256: _digest('a'),
                reconciliationBindingSha256: scenario == 'other_fence'
                    ? _digest('b')
                    : uploads.reconciliationBindingSha256(upload.id),
                requireAdmission: () {},
                requireDurableAdmission: () async {},
                action: (capability) async {
                  capability.consumeForNative();
                  throw StateError('synthetic_lost_response');
                },
              ),
            ),
            throwsA(isA<CloudKitWriterAuthorityFailure>()),
          );
        }
        final rows = store.box<CloudAttachmentUploadEntity>();
        final original = rows.get(upload.id)!;
        void insertForgedDuplicate(int index) {
          // The real schema has a unique uploadKey. A forged alternate key must
          // fail lineage validation rather than authorizing a duplicate attempt.
          final duplicate = rows.get(upload.id)!;
          duplicate.id = 0;
          duplicate.uploadKey = index.toRadixString(16).padLeft(64, '0');
          rows.put(duplicate);
        }

        switch (scenario) {
          case 'foreign_account':
            rows.put(rows.get(upload.id)!..accountFingerprint = _accountB);
          case 'foreign_store':
            rows.put(rows.get(upload.id)!..protectedStoreIdentity = _storeB);
          case 'foreign_generation':
            rows.put(rows.get(upload.id)!..checkpointGeneration = 2);
          case 'invalid_attempt':
            rows.put(rows.get(upload.id)!..attemptId = null);
          case 'forged_duplicate':
            insertForgedDuplicate(1);
          case 'overflow':
            for (var i = 1; i <= 64; i++) {
              insertForgedDuplicate(i);
            }
          case 'changed_after_verify':
            binding.afterVerify = () =>
                rows.put(rows.get(upload.id)!..attemptId = _attemptB);
        }
        binding.result = scenario == 'missing'
            ? null
            : frb_api.CloudSyncAttachmentUploadReceiptEvidence(
                uploadAttemptId: _attemptA,
                planPayloadSha256: _planA().payloadSha256,
                logicalEntityKeyHash: _planA().logicalEntityKeyHash,
                serverRecordIdHash: _planA().serverRecordIdHash,
                completedPayloadSha256: _resultA().payloadSha256,
              );
        final recovery = run(
          () => guard.reconcilePendingAttachmentUpload(
            expectedClient: auth.cloudMessagesClient,
            uploads: uploads,
            onlyIntentId: scenario == 'settled_history'
                ? null
                : scenario == 'other_intent'
                ? intentId + 1000
                : intentId,
          ),
        );
        final completed = const [
          'started',
          'unknown',
          'settled_history',
        ].contains(scenario);
        final rejected = const [
          'invalid_attempt',
          'forged_duplicate',
          'overflow',
          'changed_after_verify',
        ].contains(scenario);
        if (scenario == 'changed_after_verify') {
          await expectLater(
            recovery,
            throwsA(isA<CloudKitWriterAuthorityFailure>()),
          );
        } else if (rejected) {
          await expectLater(
            recovery,
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'safeCode',
                scenario == 'overflow'
                    ? 'cloud_sync_attachment_upload_recovery_bound_exceeded'
                    : isA<String>(),
              ),
            ),
          );
        } else {
          expect(
            await recovery,
            completed
                ? isTrue
                : scenario == 'missing'
                ? isFalse
                : isNull,
          );
        }
        expect(
          binding.calls,
          completed ||
                  scenario == 'missing' ||
                  scenario == 'changed_after_verify'
              ? 1
              : 0,
        );
        expect(
          authority.read(_writerScope)!.epoch,
          originalEpoch +
              (scenario == 'no_fence'
                  ? 0
                  : completed
                  ? 2
                  : 1),
        );
        if (completed || scenario == 'no_fence') {
          guard.requireClear();
          expect(
            await run(
              () => guard.reconcilePendingAttachmentUpload(
                expectedClient: auth.cloudMessagesClient,
                uploads: uploads,
              ),
            ),
            isNull,
          );
        } else {
          expect(
            () => guard.requireClear(),
            throwsA(isA<CloudKitWriterAuthorityFailure>()),
          );
        }
        final retained = rows.get(upload.id)!;
        expect(retained.state, original.state);
        expect(retained.planReference, original.planReference);
        expect(retained.planLeaseReference, original.planLeaseReference);
        expect(retained.resultReference, original.resultReference);
        expect(retained.writerEpoch, originalEpoch);
        expect(
          store.box<CloudOutboxOperationEntity>().getAll().map(
            (row) => row.operationId,
          ),
          originalOutboxIds,
        );
      },
    );
  }

  test(
    'receipt discovery excludes untouched prepared rows and rejects invalid selection',
    () {
      final prepared = uploads.adoptPlan(
        localSendIntentId: seedConfirmedIntent(),
        plan: _planA(),
        now: _time(6),
      );
      expect(uploads.readAttemptedForReconciliation(), isEmpty);
      expect(
        () => uploads.readAttemptedForReconciliation(onlyIntentId: 0),
        throwsStateError,
      );
      store.box<CloudAttachmentUploadEntity>().put(
        store.box<CloudAttachmentUploadEntity>().get(prepared.id)!
          ..attemptId = _attemptA,
      );
      expect(() => uploads.readAttemptedForReconciliation(), throwsStateError);
    },
  );

  test(
    'receipt discovery accepts 64 validated attempts and rejects the 65th',
    () {
      final ids = <int>[];
      final intents = <int>[];
      for (var i = 1; i <= 65; i++) {
        final intentId = seedConfirmedIntent(
          stableGuid:
              '${i.toRadixString(16).padLeft(8, '0')}-2222-4222-8222-222222222222',
          attachmentGuid: 'LOCAL-ATTACHMENT-$i',
        );
        final upload = uploads.adoptPlan(
          localSendIntentId: intentId,
          plan: _planA(),
          now: _time(6),
        );
        uploads.beginAttempt(
          id: upload.id,
          attemptId: _attemptA,
          now: _time(7),
        );
        ids.add(upload.id);
        intents.add(intentId);
        if (i == 64) {
          expect(
            uploads.readAttemptedForReconciliation(),
            unorderedEquals(ids),
          );
        }
      }
      expect(
        () => uploads.readAttemptedForReconciliation(),
        throwsA(
          _stateFailure('cloud_sync_attachment_upload_recovery_bound_exceeded'),
        ),
      );
      expect(
        uploads.readAttemptedForReconciliation(onlyIntentId: intents.first),
        [ids.first],
      );
    },
  );

  for (final scenario in [
    'completed',
    'missing',
    'other_attempt',
    'other_result',
    'other_fence',
    'client_changed',
  ]) {
    test(
      'upload fence recovery requires exact native evidence: $scenario',
      () async {
        final originalEpoch = authoritySnapshot.epoch;
        final upload = uploads.adoptPlan(
          localSendIntentId: seedConfirmedIntent(),
          plan: _planA(),
          now: _time(6),
        );
        uploads.beginAttempt(
          id: upload.id,
          attemptId: _attemptA,
          now: _time(7),
        );
        var activeClient = auth.cloudMessagesClient;
        final expectedClient = activeClient;
        final binding = _UploadRecoveryBinding();
        final guard = CloudKitWriterMutationGuard.forTest(
          store: store,
          readActiveClient: () => activeClient,
          privateStorageDirectory: directory.path,
          buildDecision: CloudKitWriterOwnership.resolve('v2'),
          nativeAuthBinding: binding,
          reconciliationBinding: binding,
        );
        final interlock = CloudKitOperationInterlock(
          privateStorageDirectory: directory.path,
          fenceStore: InMemoryCloudSyncStore(),
        );
        Future<T> run<T>(Future<T> Function() action) => interlock.runExclusive(
          kind: CloudKitOperationKind.v2ReadWrite,
          action: action,
        );
        await expectLater(
          run(
            () => guard.runAuthorized<void>(
              owner: CloudKitWriterOwner.v2,
              expectedClient: expectedClient,
              expectedAccountFingerprint: _accountA,
              preparedHandleBindingSha256: _digest('a'),
              reconciliationBindingSha256: scenario == 'other_fence'
                  ? _digest('b')
                  : uploads.reconciliationBindingSha256(upload.id),
              requireAdmission: () {},
              requireDurableAdmission: () async {},
              action: (capability) async {
                capability.consumeForNative();
                throw StateError('synthetic_lost_response');
              },
            ),
          ),
          throwsA(isA<CloudKitWriterAuthorityFailure>()),
        );
        expect(authority.read(_writerScope)!.epoch, originalEpoch + 1);
        if (scenario == 'other_result' || scenario == 'completed') {
          uploads.recordUploaded(
            id: upload.id,
            attemptId: _attemptA,
            result: _resultA(),
            now: _time(8),
          );
        }
        binding.result = scenario == 'missing'
            ? null
            : frb_api.CloudSyncAttachmentUploadReceiptEvidence(
                uploadAttemptId: scenario == 'other_attempt'
                    ? _attemptB
                    : _attemptA,
                planPayloadSha256: _planA().payloadSha256,
                logicalEntityKeyHash: _planA().logicalEntityKeyHash,
                serverRecordIdHash: _planA().serverRecordIdHash,
                completedPayloadSha256: scenario == 'other_result'
                    ? _digest('b')
                    : _resultA().payloadSha256,
              );
        if (scenario == 'client_changed') {
          binding.afterVerify = () {
            activeClient = Object();
          };
        }
        final recovery = run(
          () => guard.reconcileAttachmentUpload(
            expectedClient: expectedClient,
            uploads: uploads,
            uploadId: upload.id,
          ),
        );
        if (scenario == 'completed') {
          expect(await recovery, isTrue);
          guard.requireClear();
          expect(authority.read(_writerScope)!.epoch, originalEpoch + 2);
          // Repeat after a restart-shaped read keeps the original result and epoch.
          expect(
            await run(
              () => guard.reconcileAttachmentUpload(
                expectedClient: expectedClient,
                uploads: uploads,
                uploadId: upload.id,
              ),
            ),
            isTrue,
          );
          expect(authority.read(_writerScope)!.epoch, originalEpoch + 2);
          expect(
            uploads.read(upload.id).result!.leaseReference,
            _resultA().leaseReference,
          );
        } else {
          if (scenario == 'missing') {
            expect(await recovery, isFalse);
          } else {
            await expectLater(
              recovery,
              throwsA(isA<CloudKitWriterAuthorityFailure>()),
            );
          }
          expect(
            () => guard.requireClear(),
            throwsA(isA<CloudKitWriterAuthorityFailure>()),
          );
          expect(authority.read(_writerScope)!.epoch, originalEpoch + 1);
        }
        expect(
          binding.calls,
          scenario == 'other_fence'
              ? 0
              : scenario == 'completed'
              ? 2
              : 1,
        );
        expect(
          store.box<CloudAttachmentUploadEntity>().get(upload.id)!.attemptId,
          _attemptA,
        );
        expect(store.box<CloudOutboxOperationEntity>().getAll(), isEmpty);
      },
    );
  }

  test(
    'retained evidence survives epoch rotation without granting a new attempt',
    () {
      final prepared = uploads.adoptPlan(
        localSendIntentId: seedConfirmedIntent(),
        plan: _planA(),
        now: _time(6),
      );
      final authorityBox = store.box<CloudKitWriterAuthorityEntity>();
      authorityBox.put(authorityBox.getAll().single..epoch += 1);
      // A retained plan remains inspectable, but its old intent cannot acquire
      // another attempt. Rebinding the reader to the new epoch does not help.
      provisionJournal();
      uploads = buildUploads();
      expect(
        uploads.read(prepared.id).state,
        CloudAttachmentUploadState.prepared,
      );
      expect(
        () => uploads.beginAttempt(
          id: prepared.id,
          attemptId: _attemptA,
          now: _time(8),
        ),
        throwsA(_stateFailure('cloud_sync_local_send_intent_changed')),
      );
    },
  );

  test(
    'late receipt and final admission survive writer reconciliation without rekeying',
    () async {
      final originalEpoch = authoritySnapshot.epoch;
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
      final binding = uploads.reconciliationBindingSha256(prepared.id);
      final originalSource = uploads.readOriginalSource(prepared.id).encode();
      await CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: InMemoryCloudSyncStore(),
      ).runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () async {
          final permit = authority.issuePermit(
            _writerScope,
            expectedOwner: CloudKitWriterOwner.v2,
          );
          authority.markMutationUnknown(permit, now: _time(8));
          expect(authority.read(_writerScope)!.epoch, originalEpoch + 1);
          // A native completion can be retained while the global writer is fenced.
          uploads.markUnknown(
            id: prepared.id,
            attemptId: _attemptA,
            now: _time(9),
          );
          uploads.recordUploaded(
            id: prepared.id,
            attemptId: _attemptA,
            result: _resultA(),
            now: _time(10),
          );
          var admissions = 0;
          CloudOutboxOperation admit(
            Store tx,
            CloudSyncProtectedOutboundStageData result,
          ) {
            admissions++;
            _persistFinalOperation(tx, result);
            return _finalOperation(result);
          }

          expect(
            () => uploads.adoptRecordCreate(
              id: prepared.id,
              admit: admit,
              now: _time(11),
            ),
            throwsA(isA<CloudKitWriterAuthorityFailure>()),
          );
          expect(admissions, 0);
          authority.reconcileMutationFence(
            _writerScope,
            owner: CloudKitWriterOwner.v2,
            fencedEpoch: originalEpoch,
            now: _time(12),
          );
          provisionJournal();
          uploads = buildUploads();
          final adopted = uploads.adoptRecordCreate(
            id: prepared.id,
            admit: admit,
            now: _time(13),
          );
          uploads.adoptRecordCreate(
            id: prepared.id,
            admit: admit,
            now: _time(14),
          );
          uploads.requireAdoptedOperation(_finalOperation(_resultA()));
          expect(adopted.state, CloudAttachmentUploadState.adopted);
          expect(admissions, 1);
          expect(uploads.reconciliationBindingSha256(prepared.id), binding);
          expect(
            uploads.readOriginalSource(prepared.id).encode(),
            originalSource,
          );
          expect(
            store
                .box<CloudAttachmentUploadEntity>()
                .get(prepared.id)!
                .writerEpoch,
            originalEpoch,
          );
          expect(
            store
                .box<CloudSyncLocalSendIntentEntity>()
                .get(intentId)!
                .writerEpoch,
            originalEpoch,
          );
        },
      );
    },
  );
}

final class _UploadRecoveryBinding
    implements
        CloudSyncNativeAuthBinding,
        CloudKitWriterUploadReconciliationBinding {
  int calls = 0;
  void Function()? afterVerify;
  frb_api.CloudSyncAttachmentUploadReceiptEvidence? result;

  @override
  Future<CloudSyncNativeAuthMetadata> capture({
    required Object cloudMessagesClient,
    required String privateStorageDirectory,
  }) async => const CloudSyncNativeAuthMetadata(
    nativeSessionId: 'native-session',
    accountFingerprint: _accountA,
    protectedStoreIdentity: _storeA,
  );

  @override
  Future<frb_api.CloudSyncAttachmentUploadReceiptEvidence?>
  verifyAttachmentUploadReceipt({
    required Object cloudMessagesClient,
    required frb_api.CloudSyncNativeSendReceiptContext context,
    required frb_api.CloudSyncAttachmentUploadPlanReference planStage,
    required String expectedAttemptId,
  }) async {
    calls++;
    expect(context.accountFingerprint, _accountA);
    expect(context.sourceBinding, isNotNull);
    expect(planStage.payloadSha256, _planA().payloadSha256);
    expect(expectedAttemptId, _attemptA);
    afterVerify?.call();
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_native_operation');
}

final class _FakeProtector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      _digest('e');

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'ciphertext';

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => 'plaintext';
}

ObjectBoxCloudSyncStore _liveStore(
  Store store, {
  CloudSyncAttachmentUploadJournal? uploads,
}) => ObjectBoxCloudSyncStore(
  store: store,
  protector: _FakeProtector(),
  attachmentUploadJournal: uploads,
  clock: () => _time(30),
);

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

CloudSyncNativeAuthSnapshot _auth(
  Object client, {
  String account = _accountA,
  String store = _storeA,
}) => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: 'native-session',
  accountFingerprint: account,
  protectedStoreIdentity: store,
  cloudMessagesClient: client,
);

CloudSyncProtectedOutboundStageData _planA({
  String? record,
  String? payload,
  String? reference,
  String? lease,
}) => CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: _token('C'),
  protectedEnvelopeReference: reference ?? _ref('E'),
  payloadSha256: payload ?? _digest('c'),
  serverRecordIdHash: record ?? _token('D'),
  leaseReference: lease ?? _lease('d'),
);

CloudSyncProtectedOutboundStageData _resultA({
  String? record,
  String? payload,
  String? lease,
}) => CloudSyncProtectedOutboundStageData(
  logicalEntityKeyHash: _token('C'),
  protectedEnvelopeReference: _ref('F'),
  payloadSha256: payload ?? _digest('e'),
  serverRecordIdHash: record ?? _token('D'),
  leaseReference: lease ?? _lease('1'),
);

CloudSyncProtectedOutboundStageData _planB() =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('G'),
      protectedEnvelopeReference: _ref('I'),
      payloadSha256: _digest('f'),
      serverRecordIdHash: _token('H'),
      leaseReference: _lease('2'),
    );

CloudSyncProtectedOutboundStageData _resultB() =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _token('G'),
      protectedEnvelopeReference: _ref('L'),
      payloadSha256: _digest('a'),
      serverRecordIdHash: _token('H'),
      leaseReference: _lease('5'),
    );

CloudOutboxOperation _finalOperation(
  CloudSyncProtectedOutboundStageData result, {
  String? operationId,
  String? payload,
}) => CloudOutboxOperation(
  scope: _uploadScope,
  operationId: operationId ?? _initialOperation(result),
  logicalEntityKeyHash: result.logicalEntityKeyHash,
  action: CloudOutboxAction.save,
  payloadVersion: 1,
  mutationRevision: 1,
  checkpointGeneration: 1,
  dependencyOperationIds: const [],
  createdAt: _time(9),
  encryptedPayloadReference: result.protectedEnvelopeReference,
  payloadSha256: payload ?? result.payloadSha256,
  serverRecordIdHash: result.serverRecordIdHash,
  protectedLeaseReference: result.leaseReference,
);

void _persistFinalOperation(
  Store tx,
  CloudSyncProtectedOutboundStageData result, {
  String? operationId,
}) {
  tx.box<CloudOutboxOperationEntity>().put(
    CloudOutboxOperationEntity(
      operationId: operationId ?? _initialOperation(result),
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
const _accountB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _storeA = 'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _storeB = 'obcs2.store.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _guidA = '11111111-1111-4111-8111-111111111111';
const _guidB = '22222222-2222-4222-8222-222222222222';
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
