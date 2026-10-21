import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_plan_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_executor.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_parent_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_record_observation.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';
import 'cloud_sync_test_helpers.dart' show testSubmissionIdentity;

// Real disposable ObjectBox and production journals. Protected references,
// canonical attachment keys, byte results and readbacks are synthetic local
// collaborators, NOT native authentication, MMCS upload or Apple-save proof.
final _now = DateTime.utc(2026, 10, 21, 12);
final _account = 'A' * 43;
final _storeId = 'obcs2.store.${'S' * 43}';
const _owner = 'mailto:owner@example.com';
const _peer = 'mailto:remote@example.com';
const _chatGuid = 'iMessage;-;remote@example.com';
const _attempt = '11111111-2222-4333-8444-555555555555';
const _otherAttempt = '66666666-7777-4888-9999-AAAAAAAAAAAA';
final _keys = {'L' * 43, 'Q' * 43};
const _live = CloudSyncReceivedArchiveLiveContext(
  observedViaLiveReceive: true,
  observedLocalHandles: [_owner],
  receivedOnHandle: _owner,
);

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
CloudSyncScope _scope(String zone, {String? account}) => CloudSyncScope(
  accountFingerprint: account ?? _account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
CloudKitWriterScope _writerScope() =>
    CloudKitWriterScope(accountFingerprint: _account);
CloudSyncNativeAuthSnapshot _auth({String? storeId, String? account}) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic-received-upload-session',
      accountFingerprint: account ?? _account,
      protectedStoreIdentity: storeId ?? _storeId,
      cloudMessagesClient: Object(),
    );

void main() {
  late _Fixture f;
  setUp(() async {
    f = await _Fixture.open();
    await f.seedReceived();
  });
  tearDown(() async => f.close());

  for (final mirrored in [false, true]) {
    test(
      '${mirrored ? 'mirrored' : 'incoming'} media keeps received ownership, never an IDS intent',
      () async {
        if (mirrored) await f.seedReceived(mirrored: true);
        final first = f.prepare();
        final retry = f.prepare();
        final row = f.upload(first.id);
        expect(retry.id, first.id);
        expect(first.ownerKind, cloudSyncAttachmentOwnerKindReceived);
        expect(first.ownerIntentId, f.intentId);
        expect(first.localSendIntentId, 0);
        expect(f.uploads.readOwnerKind(first.id), 2);
        expect(
          f.uploads.receivedUploadNeedsLocalSource(first.id, f.received),
          isTrue,
        );
        expect(
          f.uploads
              .findReceivedForAttachment(
                receivedIntentId: f.intentId,
                logicalEntityKeyHash: 'L' * 43,
                sourceAttachmentKeys: _keys,
                receivedJournal: f.received,
              )
              ?.id,
          first.id,
        );
        expect(
          f.uploads.findReceivedForAttachment(
            receivedIntentId: f.intentId,
            logicalEntityKeyHash: 'Q' * 43,
            sourceAttachmentKeys: _keys,
            receivedJournal: f.received,
          ),
          isNull,
        );
        expect(row.writerEpoch, f.origin.writerEpoch);
        expect(f.intent.origin, mirrored ? 1 : 0);
        expect(
          f.uploads.readReceivedOriginalSource(first.id, f.received).encode(),
          f.source.encode(),
        );
        expect(f.store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
        expect(
          row.uploadKey,
          _digest([
            'cloud-sync-received-attachment-upload-v1',
            f.uploadScope.storageKey,
            2,
            f.intentId,
            f.source.messageGuidHash,
            f.source.sourceSha256,
            row.attachmentKeyHash,
            f.source.encode(),
          ]),
        );
        expect(
          row.uploadKey,
          isNot(
            _digest([
              'cloud-sync-attachment-upload-v1',
              f.uploadScope.storageKey,
              f.source.messageGuidHash,
              f.source.sourceSha256,
              row.attachmentKeyHash,
            ]),
          ),
        );
      },
    );
  }

  test(
    'exact retry never replaces immutable plan or protected source reference',
    () {
      final prepared = f.prepare();
      expect(
        () => f.prepare(plan: f.plan('L', reference: 'X')),
        throwsStateError,
      );
      final intent = f.intent;
      final oldBinding = intent.protectedSourceBinding;
      intent.protectedSourceBinding = f
          .replacementSource(reference: 'V')
          .encode();
      f.store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
      expect(
        () => f.uploads.readReceived(prepared.id, f.received),
        throwsStateError,
      );
      expect(() => f.prepare(), throwsStateError);
      expect(f.store.box<CloudAttachmentUploadEntity>().count(), 1);
      intent.protectedSourceBinding = oldBinding;
      f.store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
      expect(
        f.uploads
            .readReceived(prepared.id, f.received)
            .plan
            .protectedEnvelopeReference,
        prepared.plan.protectedEnvelopeReference,
      );
    },
  );

  test(
    'readOwnerKind is scoped shape inspection, not typed-origin or mutation proof',
    () async {
      final prepared = f.prepare();
      final row = f.upload(prepared.id)..ownerIntentId = f.intentId + 1000;
      f.store.box<CloudAttachmentUploadEntity>().put(row);
      await f.enterUnknown();
      expect(f.uploads.readOwnerKind(prepared.id), 2);
      expect(
        () => f.uploads.readReceived(prepared.id, f.received),
        throwsStateError,
      );
      // No wrong-lane source lookup: the local journal has no matching intent.
      expect(
        () => f.uploads.read(prepared.id),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            cloudSyncAttachmentOwnerChangedCode,
          ),
        ),
      );
    },
  );

  test(
    'scoped discriminator rejects account/store/generation and unknown owner codes',
    () {
      final prepared = f.prepare();
      final originals = f.upload(prepared.id);
      for (final mutate in <void Function(CloudAttachmentUploadEntity)>[
        (row) => row.accountFingerprint = 'B' * 43,
        (row) => row.protectedStoreIdentity = 'obcs2.store.${'T' * 43}',
        (row) => row.checkpointGeneration = 2,
        (row) => row.ownerKind = 3,
        (row) => row.localSendIntentId = 1,
        (row) => row.ownerIntentId = 0,
      ]) {
        final row = f.upload(prepared.id);
        mutate(row);
        f.store.box<CloudAttachmentUploadEntity>().put(row);
        expect(() => f.uploads.readOwnerKind(prepared.id), throwsStateError);
        f.store.box<CloudAttachmentUploadEntity>().put(originals);
      }
      final checkpoint = f.store
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .singleWhere(
            (row) =>
                row.checkpointKey == cloudSyncPersistentScopeKey(f.uploadScope),
          );
      checkpoint.zone = 'messageManateeZone';
      f.store.box<CloudSyncCheckpointEntity>().put(checkpoint);
      expect(() => f.uploads.readOwnerKind(prepared.id), throwsStateError);
    },
  );

  test(
    'all three owner lanes reject cross-kind entry points without fallback',
    () {
      final received = f.prepare();
      final historical = f.historical();
      final historicalId = historical.adopt(f.historicalSource).id;
      historical.markSourceLeaseCommitted(
        intentId: historicalId,
        expectedSource: f.historicalSource,
      );
      final imported = f.uploads.adoptHistoricalPlan(
        historicalIntentId: historicalId,
        plan: f.plan('H'),
        now: _now,
        historicalJournal: historical,
      );
      expect(f.uploads.readOwnerKind(imported.id), 1);
      final wrongLane = throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          cloudSyncAttachmentOwnerChangedCode,
        ),
      );
      expect(() => f.uploads.read(imported.id), wrongLane);
      expect(() => f.uploads.readReceived(imported.id, f.received), wrongLane);
      expect(
        () => f.uploads.readHistorical(received.id, historical),
        wrongLane,
      );
      expect(
        () => f.uploads.readHistoricalOriginalSource(received.id, historical),
        wrongLane,
      );
      expect(() => f.uploads.readOriginalSource(received.id), wrongLane);
      // Legacy discriminator shape only. No local-send receipt is created.
      final localShape = f.upload(imported.id)
        ..ownerKind = 0
        ..ownerIntentId = 0
        ..localSendIntentId = 42;
      f.store.box<CloudAttachmentUploadEntity>().put(localShape);
      expect(f.uploads.readOwnerKind(imported.id), 0);
      expect(() => f.uploads.readReceived(imported.id, f.received), wrongLane);
      expect(f.store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  test(
    'source, generation, epoch, store and owner drift never hides an existing plan',
    () {
      final prepared = f.prepare();
      final original = f.upload(prepared.id);
      for (final mutate in <void Function(CloudAttachmentUploadEntity)>[
        (row) => row.sourceSha256 = 'c' * 64,
        (row) => row.messageGuidHash = 'd' * 64,
        (row) => row.writerEpoch++,
        (row) => row.ownerIntentId++,
        (row) => row.checkpointGeneration++,
        (row) => row.protectedStoreIdentity = 'obcs2.store.${'T' * 43}',
        (row) => row.accountFingerprint = 'B' * 43,
      ]) {
        final row = f.upload(prepared.id);
        mutate(row);
        f.store.box<CloudAttachmentUploadEntity>().put(row);
        expect(
          () => f.uploads.readReceived(prepared.id, f.received),
          throwsStateError,
        );
        // Altered owner id is separately rejected by the typed read; the other
        // drifts must not allow a replacement under a changed upload key.
        if (row.ownerIntentId == original.ownerIntentId) {
          expect(() => f.prepare(), throwsStateError);
        }
        expect(f.store.box<CloudAttachmentUploadEntity>().count(), 1);
        f.store.box<CloudAttachmentUploadEntity>().put(original);
      }
      expect(
        () => f
            .reboundUploads(auth: _auth(storeId: 'obcs2.store.${'T' * 43}'))
            .readReceived(prepared.id, f.received),
        throwsStateError,
      );
    },
  );

  test(
    'foreign Store journals and authorities cannot resolve a received origin',
    () async {
      final other = await _Fixture.open();
      try {
        await other.seedReceived();
        final prepared = f.prepare();
        expect(
          () => f.uploads.readReceived(prepared.id, other.received),
          throwsStateError,
        );
        expect(
          () => f
              .reboundUploads(authority: other.authority)
              .readReceived(prepared.id, f.received),
          throwsStateError,
        );
      } finally {
        await other.close();
      }
    },
  );

  test(
    'attempt needs current absent dispatch and complete retained inventory',
    () {
      final prepared = f.prepare();
      expect(
        () => f.uploads.beginReceivedAttempt(
          id: prepared.id,
          attemptId: _attempt,
          now: _now,
          receivedJournal: f.received,
          retainedSourceAttachmentKeys: _keys,
        ),
        throwsStateError,
      );
      f.prepare(marker: 'Q');
      final message = f.store.box<Message>().get(f.intent.localMessageId)!;
      message.hasAttachments = false;
      f.store.box<Message>().put(message);
      expect(() => f.begin(prepared.id), throwsStateError);
      expect(f.upload(prepared.id).attemptId, isNull);
      message.hasAttachments = true;
      message.dateEdited = _now;
      f.store.box<Message>().put(message);
      expect(() => f.begin(prepared.id), throwsStateError);
      message.dateEdited = null;
      f.store.box<Message>().put(message);
      expect(
        f.uploads
            .beginReceivedAttempt(
              id: prepared.id,
              attemptId: _attempt,
              now: _now,
              receivedJournal: f.received,
              retainedSourceAttachmentKeys: _keys,
            )
            .state,
        CloudAttachmentUploadState.started,
      );
    },
  );

  test(
    'started/unknown never retries bytes; same-attempt late result keeps reconciliation identity',
    () {
      final prepared = f.prepare();
      f.begin(prepared.id);
      final binding = f.uploads.reconciliationReceivedBindingSha256(
        prepared.id,
        f.received,
      );
      final row = f.upload(prepared.id);
      expect(
        binding,
        _digest([
          'cloud-sync-received-attachment-upload-reconciliation-v1',
          f.uploadScope.storageKey,
          2,
          f.intentId,
          row.writerEpoch,
          row.checkpointGeneration,
          row.protectedStoreIdentity,
          row.messageGuidHash,
          row.sourceSha256,
          row.uploadKey,
          row.attachmentKeyHash,
          row.serverRecordIdHash,
          row.planReference,
          row.planLeaseReference,
          row.planPayloadSha256,
          _attempt,
        ]),
      );
      f.uploads.markReceivedUnknown(
        id: prepared.id,
        attemptId: _attempt,
        now: _now,
        receivedJournal: f.received,
      );
      expect(
        f.uploads.readReceivedAttemptedForReconciliation(
          receivedJournal: f.received,
        ),
        [prepared.id],
      );
      expect(() => f.begin(prepared.id), throwsStateError);
      expect(
        () => f.begin(prepared.id, attempt: _otherAttempt),
        throwsStateError,
      );
      expect(
        () => f.uploads.recordReceivedUploaded(
          id: prepared.id,
          attemptId: _otherAttempt,
          result: f.result('L'),
          now: _now,
          receivedJournal: f.received,
        ),
        throwsStateError,
      );
      f.record(prepared.id);
      f.record(prepared.id); // Exact receipt retry, not another byte attempt.
      expect(
        f.uploads.reconciliationReceivedBindingSha256(prepared.id, f.received),
        binding,
      );
      expect(
        f.uploads.readReceivedAttemptedForReconciliation(
          receivedJournal: f.received,
        ),
        isEmpty,
      );
      expect(
        () => f.record(prepared.id, result: f.result('L', reference: 'Z')),
        throwsStateError,
      );
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'unknown process recovery retains original epoch without visible UI row',
    () async {
      final prepared = f.prepare();
      f.begin(prepared.id);
      f.uploads.markReceivedUnknown(
        id: prepared.id,
        attemptId: _attempt,
        now: _now,
        receivedJournal: f.received,
      );
      final epoch = f.upload(prepared.id).writerEpoch;
      final binding = f.uploads.reconciliationReceivedBindingSha256(
        prepared.id,
        f.received,
      );
      await f.enterUnknown();
      f.store.box<Message>().remove(f.intent.localMessageId);
      await f.reopen();
      expect(
        f.authority.read(_writerScope())!.state,
        CloudKitWriterAuthorityState.mutationUnknown,
      );
      expect(
        f.uploads.readReceivedOriginalSource(prepared.id, f.received).encode(),
        f.source.encode(),
      );
      expect(
        f.uploads.reconciliationReceivedBindingSha256(prepared.id, f.received),
        binding,
      );
      expect(f.upload(prepared.id).writerEpoch, epoch);
      expect(() => f.begin(prepared.id), throwsStateError);
      f.record(
        prepared.id,
      ); // The original native-validated receipt is recoverable.
      expect(
        () => f.admit(prepared.id),
        throwsA(
          anyOf(isA<StateError>(), isA<CloudKitWriterAuthorityFailure>()),
        ),
      );
      await f.reconcile(epoch);
      expect(f.authority.read(_writerScope())!.epoch, greaterThan(epoch));
      expect(
        f.uploads.readReceived(prepared.id, f.received).state,
        CloudAttachmentUploadState.uploaded,
      );
      expect(f.upload(prepared.id).writerEpoch, epoch);
      expect(() => f.prepare(), throwsStateError);
      expect(f.store.box<CloudAttachmentUploadEntity>().count(), 1);
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'final admission and outer transaction failures preserve uploaded evidence',
    () {
      final uploaded = f.complete();
      final mapCount = f.store.box<CloudRecordMapEntity>().count();
      expect(
        () => f.uploads.adoptReceivedRecordCreate(
          id: uploaded.id,
          now: _now,
          receivedJournal: f.received,
          admit: (store, result) {
            final operation = f.persistOperation(result);
            final intent = f.intent
              ..protectedSourceBinding = f
                  .replacementSource(reference: 'V')
                  .encode();
            store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
            return operation;
          },
        ),
        throwsStateError,
      );
      expect(f.intent.protectedSourceBinding, f.source.encode());
      expect(
        f.upload(uploaded.id).state,
        CloudAttachmentUploadState.uploaded.index,
      );
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(f.store.box<CloudRecordMapEntity>().count(), mapCount);
      expect(
        () => f.uploads.adoptReceivedRecordCreate(
          id: uploaded.id,
          now: _now,
          receivedJournal: f.received,
          admit: (_, result) => f
              .persistOperation(result)
              .copyWith(dependencyOperationIds: {'op1:${'f' * 64}'}),
        ),
        throwsStateError,
      );
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(f.store.box<CloudRecordMapEntity>().count(), mapCount);
      expect(
        () => f.store.runInTransaction<void>(TxMode.write, () {
          final adopted = f.admit(uploaded.id);
          if (adopted.admittedOperationId != null) {
            throw StateError('synthetic_outer_rollback');
          }
        }),
        throwsStateError,
      );
      expect(f.upload(uploaded.id).admittedOperationId, isNull);
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(f.store.box<CloudRecordMapEntity>().count(), mapCount);
      expect(f.admit(uploaded.id).state, CloudAttachmentUploadState.adopted);
    },
  );

  test(
    'adopted retry never runs callback; exact operation and map are mandatory',
    () {
      final uploaded = f.complete();
      final adopted = f.admit(uploaded.id);
      final retry = f.uploads.adoptReceivedRecordCreate(
        id: uploaded.id,
        now: _now,
        receivedJournal: f.received,
        admit: (_, __) => throw StateError('must_not_readmit'),
      );
      expect(retry.admittedOperationId, adopted.admittedOperationId);
      final operation = f.operation(uploaded.id);
      expect(
        f.uploads
            .markReceivedAdopted(
              id: uploaded.id,
              operation: operation,
              now: _now,
              receivedJournal: f.received,
            )
            .id,
        uploaded.id,
      );
      f.uploads.validateReceivedCompletedUploadOrigin(operation, f.received);
      f.uploads.requireReceivedAdoptedOperation(operation, f.received);
      expect(
        f.uploads.readReceivedAdoptedSource(operation, f.received).encode(),
        f.source.encode(),
      );
      expect(
        () => f.uploads.validateReceivedCompletedUploadOrigin(
          operation.copyWith(payloadSha256: 'f' * 64),
          f.received,
        ),
        throwsStateError,
      );
      expect(
        () => f.uploads.markReceivedAdopted(
          id: uploaded.id,
          operation: operation.copyWith(payloadSha256: 'f' * 64),
          now: _now,
          receivedJournal: f.received,
        ),
        throwsStateError,
      );
      final map = f.mapping(uploaded.id)..serverRecordIdHash = 'Z' * 43;
      f.store.box<CloudRecordMapEntity>().put(map);
      expect(
        () => f.uploads.validateReceivedCompletedUploadOrigin(
          operation,
          f.received,
        ),
        throwsStateError,
      );
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );

  test(
    'read-only source survives pending readback handoff; parent proof waits',
    () {
      final uploaded = f.complete();
      f.admit(uploaded.id);
      f.confirm(uploaded.id);
      final operation = f.operation(uploaded.id);
      final map = f.mapping(uploaded.id)
        ..encryptedRawRecordRef = 'obcs2.ref.${'W' * 43}'
        ..rawRecordGeneration = 1
        ..protectedReadbackLeaseReference = 'obcs2.lease.${'b' * 32}'
        ..pendingUpdateOperationId = operation.operationId
        ..pendingUpdatePredecessorEtagHash = 'E' * 43;
      f.store.box<CloudRecordMapEntity>().put(map);
      f.uploads.validateReceivedCompletedUploadOrigin(operation, f.received);
      expect(
        f.uploads.readReceivedAdoptedSource(operation, f.received).encode(),
        f.source.encode(),
      );
      expect(() => f.proof(keys: {'L' * 43}), throwsStateError);
      expect(
        () => f.uploads.requireReceivedAdoptedOperation(operation, f.received),
        throwsStateError,
      );
      map
        ..protectedReadbackLeaseReference = null
        ..pendingUpdateOperationId = null
        ..pendingUpdatePredecessorEtagHash = null;
      f.store.box<CloudRecordMapEntity>().put(map);
      f.requireProof(f.proof(keys: {'L' * 43}));
    },
  );

  test(
    'parent proof needs exact full inventory and every released child readback',
    () {
      final first = f.complete();
      f.admit(first.id);
      final second = f.complete(marker: 'Q');
      f.admit(second.id);
      expect(() => f.proof(), throwsStateError);
      f.confirm(first.id);
      expect(() => f.proof(), throwsStateError);
      expect(() => f.proof(keys: {'L' * 43}), throwsStateError);
      f.confirm(second.id, releaseLease: false);
      expect(() => f.proof(), throwsStateError);
      f.confirm(second.id);
      final proof = f.proof();
      f.requireProof(proof);
      final body = jsonDecode(proof) as List;
      expect(body[0], 3);
      expect(body[1], 'cloud-sync-received-attachment-parent-readback-v1');
      expect(body[4], 2);
      expect(body[10], _keys.toList()..sort());
      expect((body[11] as List).length, 2);
      expect(body[12], _digest(body.sublist(0, 12)));
      expect(
        f.uploads.receivedUploadNeedsLocalSource(first.id, f.received),
        isFalse,
      );
      expect(f.store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      final historical = f.historical();
      expect(
        () => f.uploads.requireHistoricalParentReadbackProof(
          historicalIntentId: f.intentId,
          proof: proof,
          historicalJournal: historical,
        ),
        throwsStateError,
      );
      expect(
        () => f.uploads.requireParentReadbackProof(
          localSendIntentId: f.intentId,
          proof: proof,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'proof pins map ETag/raw/generation and rejects changed receipt or inventory',
    () {
      final uploaded = f.complete();
      f.admit(uploaded.id);
      f.confirm(uploaded.id);
      final proof = f.proof(keys: {'L' * 43});
      final original = f.mapping(uploaded.id);
      for (final mutate in <void Function(CloudRecordMapEntity)>[
        (map) => map.etagHash = 'F' * 43,
        (map) {
          map.encryptedRawRecordRef = 'obcs2.ref.${'W' * 43}';
          map.rawRecordGeneration = 1;
        },
        (map) => map.generation++,
        (map) => map.encryptedServerRecordId = 'obcs2.ref.${'Z' * 43}',
        (map) =>
            map.protectedReadbackLeaseReference = 'obcs2.lease.${'e' * 32}',
      ]) {
        final map = f.mapping(uploaded.id);
        mutate(map);
        f.store.box<CloudRecordMapEntity>().put(map);
        expect(() => f.requireProof(proof), throwsStateError);
        f.store.box<CloudRecordMapEntity>().put(original);
      }
      final operation = f.outbox(uploaded.id)..appleOperationUuid = null;
      f.store.box<CloudOutboxOperationEntity>().put(operation);
      expect(() => f.requireProof(proof), throwsStateError);
      f.confirm(uploaded.id);
      f.requireProof(proof);
      final changed = jsonDecode(proof) as List;
      changed[1] = 'cloud-sync-attachment-parent-readback-v1';
      expect(() => f.requireProof(jsonEncode(changed)), throwsStateError);
      f.prepare(marker: 'Q');
      expect(() => f.requireProof(proof), throwsStateError);
    },
  );

  test(
    'complete parent readback stays readable under unknown newer owner without UI',
    () async {
      final uploaded = f.complete();
      f.admit(uploaded.id);
      f.confirm(uploaded.id);
      final proof = f.proof(keys: {'L' * 43});
      final epoch = f.upload(uploaded.id).writerEpoch;
      final operation = f.operation(uploaded.id);
      await f.enterUnknown();
      f.store.box<Message>().remove(f.intent.localMessageId);
      await f.reopen();
      f.requireProof(proof);
      f.uploads.validateReceivedCompletedUploadOrigin(operation, f.received);
      expect(
        f.uploads.receivedUploadNeedsLocalSource(uploaded.id, f.received),
        isFalse,
      );
      expect(
        f.uploads.readReceivedAdoptedSource(operation, f.received).encode(),
        f.source.encode(),
      );
      expect(f.upload(uploaded.id).writerEpoch, epoch);
      expect(
        () => f.uploads.requireReceivedAdoptedOperation(operation, f.received),
        throwsA(
          anyOf(isA<StateError>(), isA<CloudKitWriterAuthorityFailure>()),
        ),
      );
    },
  );

  test(
    'historical key/reconciliation/proof bytes remain version 1/2 contracts',
    () {
      final historical = f.historical();
      final source = f.historicalSource;
      final intentId = historical.adopt(source).id;
      historical.markSourceLeaseCommitted(
        intentId: intentId,
        expectedSource: source,
      );
      final prepared = f.uploads.adoptHistoricalPlan(
        historicalIntentId: intentId,
        plan: f.plan('H'),
        now: _now,
        historicalJournal: historical,
      );
      expect(
        prepared.uploadKey,
        _digest([
          'cloud-sync-attachment-upload-v1',
          f.uploadScope.storageKey,
          1,
          source.snapshotSha256,
          intentId,
          source.messageGuidHash,
          source.sourceSha256,
          prepared.plan.logicalEntityKeyHash,
        ]),
      );
      f.uploads.beginHistoricalAttempt(
        id: prepared.id,
        attemptId: _attempt,
        now: _now,
        historicalJournal: historical,
      );
      final row = f.upload(prepared.id);
      expect(
        f.uploads.reconciliationHistoricalBindingSha256(
          prepared.id,
          historical,
        ),
        _digest([
          'cloud-sync-attachment-upload-reconciliation-v1',
          f.uploadScope.storageKey,
          row.writerEpoch,
          row.checkpointGeneration,
          row.protectedStoreIdentity,
          row.messageGuidHash,
          row.sourceSha256,
          row.uploadKey,
          row.attachmentKeyHash,
          row.serverRecordIdHash,
          row.planReference,
          row.planLeaseReference,
          row.planPayloadSha256,
          _attempt,
        ]),
      );
      f.uploads.recordHistoricalUploaded(
        id: prepared.id,
        attemptId: _attempt,
        result: f.result('H'),
        now: _now,
        historicalJournal: historical,
      );
      f.uploads.adoptHistoricalRecordCreate(
        id: prepared.id,
        now: _now,
        historicalJournal: historical,
        admit: (_, result) => f.persistOperation(result),
      );
      f.confirm(prepared.id);
      final stored = f.upload(prepared.id);
      final body = <Object>[
        2,
        f.uploadScope.storageKey,
        1,
        1,
        intentId,
        source.messageGuidHash,
        source.sourceSha256,
        _storeId,
        stored.writerEpoch,
        ['H' * 43],
        [
          [
            stored.id,
            stored.attachmentKeyHash,
            stored.serverRecordIdHash,
            stored.resultPayloadSha256!,
            stored.admittedOperationId!,
            stored.writerEpoch,
          ],
        ],
      ];
      final proof = f.uploads.captureHistoricalParentReadbackProof(
        historicalIntentId: intentId,
        sourceAttachmentKeys: ['H' * 43],
        historicalJournal: historical,
      );
      expect(proof, jsonEncode([...body, _digest(body)]));
      expect(
        () => f.uploads.requireReceivedParentReadbackProof(
          receivedIntentId: f.intentId,
          proof: proof,
          receivedJournal: f.received,
        ),
        throwsStateError,
      );
    },
  );
  group('received plan coordinator', () {
    late _ReceivedPlanStaging staging;
    late CloudSyncNativeAuthSnapshot live;
    late List<CloudSyncAttachmentPlanInventoryItem> inventory;
    late int stages;
    Future<void> Function()? afterStage;

    CloudSyncAttachmentPlanInventoryItem item(String marker) {
      final message = f.store.box<Message>().get(f.intent.localMessageId)!;
      final guid = '${message.guid}_${marker == 'Q' ? 2 : 1}';
      return CloudSyncAttachmentPlanInventoryItem(
        originalAttachmentGuid: guid,
        reflectedAttachmentGuid: guid,
        logicalEntityKeyHash: marker * 43,
      );
    }

    CloudSyncAttachmentPlanCoordinator coordinator() =>
        CloudSyncAttachmentPlanCoordinator(
          store: f.store,
          localSends: f.localSends,
          uploads: f.uploads,
          readLiveAuth: () async => live,
          staging: staging,
          clock: () => _now,
          readInventory: (_, __) =>
              throw StateError('unexpected_IDS_inventory'),
          stagePlan: (_, __, ___) => throw StateError('unexpected_IDS_plan'),
        );

    Future<List<CloudAttachmentUploadSnapshot>> run({
      CloudSyncAttachmentPlanCoordinator? shared,
    }) => (shared ?? coordinator()).ensureReceivedPlans(
      receivedIntentId: f.intentId,
      receivedJournal: f.received,
      readInventory: (source, auth) async {
        expect(source.encode(), f.source.encode());
        expect(auth.sameIdentity(live), isTrue);
        return inventory;
      },
      stagePlan: (entry, source, auth) async {
        stages++;
        expect(source.encode(), f.source.encode());
        expect(auth.sameIdentity(live), isTrue);
        final plan = f.plan(entry.logicalEntityKeyHash[0]);
        await afterStage?.call();
        return plan;
      },
    );

    setUp(() {
      staging = _ReceivedPlanStaging();
      live = _auth();
      inventory = [item('L'), item('Q')];
      stages = 0;
      afterStage = null;
    });

    test(
      'retained started/unknown plans never restage or recommit after reopen',
      () async {
        final original = await run();
        f.begin(original.first.id);
        f.begin(original.last.id, attempt: _otherAttempt);
        f.uploads.markReceivedUnknown(
          id: original.last.id,
          attemptId: _otherAttempt,
          now: _now,
          receivedJournal: f.received,
        );
        staging.commits.clear();
        await f.reopen();
        final resumed = await run();
        expect(resumed.map((row) => row.id), original.map((row) => row.id));
        expect(
          resumed.map((row) => row.plan.protectedEnvelopeReference),
          original.map((row) => row.plan.protectedEnvelopeReference),
        );
        expect(resumed.map((row) => row.state), [
          CloudAttachmentUploadState.started,
          CloudAttachmentUploadState.unknown,
        ]);
        expect(resumed.map((row) => row.attemptId), [_attempt, _otherAttempt]);
        expect(stages, 2);
        expect(staging.commits, isEmpty);
        expect(staging.rollbacks, isEmpty);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
      },
    );

    test(
      'empty or missing retained inventory holds the whole plan set',
      () async {
        final original = await run();
        f.begin(original.last.id, attempt: _otherAttempt);
        f.uploads.markReceivedUnknown(
          id: original.last.id,
          attemptId: _otherAttempt,
          now: _now,
          receivedJournal: f.received,
        );
        staging.commits.clear();
        inventory = [];
        await expectLater(run(), throwsStateError);
        inventory = [item('L')];
        await expectLater(run(), throwsStateError);
        expect(stages, 2);
        expect(staging.commits, isEmpty);
        expect(staging.rollbacks, isEmpty);
        expect(f.store.box<CloudAttachmentUploadEntity>().count(), 2);
        expect(f.upload(original.last.id).attemptId, _otherAttempt);
        expect(
          f.upload(original.last.id).state,
          CloudAttachmentUploadState.unknown.index,
        );
      },
    );

    test(
      'failed commit retains adopted original plan and retries after reopen',
      () async {
        staging.failCommit = true;
        await expectLater(run(), throwsStateError);
        final original = f.store
            .box<CloudAttachmentUploadEntity>()
            .getAll()
            .single;
        expect(original.state, CloudAttachmentUploadState.prepared.index);
        expect(original.attemptId, isNull);
        expect(stages, 1);
        expect(staging.rollbacks, isEmpty);
        await f.reopen();
        staging.failCommit = false;
        final resumed = await run();
        expect(resumed.first.id, original.id);
        final retained = f.upload(original.id);
        expect(retained.planReference, original.planReference);
        expect(retained.planLeaseReference, original.planLeaseReference);
        expect(retained.planPayloadSha256, original.planPayloadSha256);
        expect(retained.writerEpoch, original.writerEpoch);
        expect(retained.createdAtMs, original.createdAtMs);
        expect(
          stages,
          2,
          reason: 'only the previously missing second part is staged',
        );
        expect(staging.commits, [
          original.planLeaseReference,
          original.planLeaseReference,
          resumed.last.plan.leaseReference,
        ]);
        expect(staging.rollbacks, isEmpty);
      },
    );

    test(
      'same numeric historical and received intent IDs have separate active roles',
      () async {
        final historical = f.historical();
        final historicalId = historical.adopt(f.historicalSource).id;
        historical.markSourceLeaseCommitted(
          intentId: historicalId,
          expectedSource: f.historicalSource,
        );
        expect(historicalId, f.intentId);
        final shared = coordinator();
        final entered = Completer<void>();
        final release = Completer<List<CloudSyncAttachmentPlanInventoryItem>>();
        final imported = shared.ensureHistoricalPlans(
          historicalIntentId: historicalId,
          historicalJournal: historical,
          readInventory: (source, auth) {
            expect(source.encode(), f.historicalSource.encode());
            entered.complete();
            return release.future;
          },
          stagePlan: (_, source, auth) async {
            expect(source.encode(), f.historicalSource.encode());
            return f.plan('H');
          },
        );
        await entered.future;
        late List<CloudAttachmentUploadSnapshot> received;
        late List<CloudAttachmentUploadSnapshot> historicalRows;
        try {
          received = await run(shared: shared);
          expect(received.map((row) => row.ownerKind), everyElement(2));
        } finally {
          release.complete([item('H')]);
          historicalRows = await imported;
        }
        expect(historicalRows.single.ownerKind, 1);
        expect(
          historicalRows.single.ownerIntentId,
          received.first.ownerIntentId,
        );
        expect(
          historicalRows.single.id,
          isNot(isIn(received.map((row) => row.id))),
        );
        expect(
          historicalRows.single.uploadKey,
          isNot(isIn(received.map((row) => row.uploadKey))),
        );
        expect(f.store.box<CloudAttachmentUploadEntity>().count(), 3);
        expect(stages, 2);
        expect(staging.commits, hasLength(3));
        expect(f.store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      },
    );

    for (final drift in ['auth', 'epoch']) {
      test(
        '$drift drift after staging rolls back only the unadopted plan',
        () async {
          inventory = [item('L')];
          final epoch = f.intent.writerEpoch;
          afterStage = () async {
            if (drift == 'auth') {
              live = _auth(
                account: 'B' * 43,
                storeId: 'obcs2.store.${'T' * 43}',
              );
            } else {
              await f.enterUnknown();
            }
          };
          await expectLater(
            run(),
            throwsA(
              anyOf(isA<StateError>(), isA<CloudKitWriterAuthorityFailure>()),
            ),
          );
          expect(stages, 1);
          expect(staging.commits, isEmpty);
          expect(staging.rollbacks, [f.plan('L').leaseReference]);
          expect(f.store.box<CloudAttachmentUploadEntity>().count(), 0);
          expect(f.intent.writerEpoch, epoch);
          expect(f.intent.protectedSourceBinding, f.source.encode());
          expect(f.store.box<CloudOutboxOperationEntity>().count(), 0);
        },
      );
    }
  });

  test(
    'received child pause skips pristine create, never its exact unknown readback',
    () async {
      final uploaded = f.complete();
      f.admit(uploaded.id);
      final operation = f.operation(uploaded.id);
      final sourceBytes = f.source.encode();
      bool paused = true;
      final durable = ObjectBoxCloudSyncStore(
        store: f.store,
        protector: _TestProtector(),
        clock: () => _now,
        localSendJournal: f.localSends,
        receivedArchiveJournal: f.received,
        attachmentUploadJournal: f.uploads,
        pauseUnsubmittedReceivedCreates: () => paused,
      );
      expect(durable.isPausedUnsubmittedReceivedCreate(operation), isTrue);
      final preflight = ObjectBoxCloudSyncPreflightReader(
        store: f.store,
        localSendJournal: f.localSends,
        now: () => _now,
        isPausedReceivedAttachmentCreate: (id) =>
            id == operation.operationId &&
            durable.isPausedUnsubmittedReceivedCreate(operation),
      ).read();
      expect(preflight.outboxCount, 1);
      expect(preflight.settledOutboxFingerprint, isNotNull);
      expect(
        await durable.leaseEligibleOutbox(
          f.uploadScope,
          now: _now,
          limit: 1,
          leaseId: 'paused-child',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        ),
        isEmpty,
      );
      expect(f.outbox(uploaded.id).state, CloudOutboxStatus.pending.index);
      expect(f.outbox(uploaded.id).leaseIdHash, isNull);
      expect(
        (await durable.readOutboxEntries(
          f.uploadScope,
        )).single.sameDurableSnapshotAs(operation),
        isTrue,
      );

      paused = false;
      expect(durable.isPausedUnsubmittedReceivedCreate(operation), isFalse);
      final leased = await durable.leaseEligibleOutbox(
        f.uploadScope,
        now: _now,
        limit: 1,
        leaseId: 'entered-child',
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
      );
      expect(leased.single.operationId, operation.operationId);
      final entered = (await durable.markOutboxSubmissionStarted(
        f.uploadScope,
        leaseId: 'entered-child',
        submissionIdentity: testSubmissionIdentity([operation.operationId]),
        now: _now.add(const Duration(seconds: 1)),
      )).single;
      expect(entered.status, CloudOutboxStatus.unknownOutcome);
      paused = true;
      final unknown = (await durable.readOutboxEntries(f.uploadScope)).single;
      expect(durable.isPausedUnsubmittedReceivedCreate(unknown), isFalse);
      expect(
        f.uploads.readReceivedAdoptedSource(unknown, f.received).encode(),
        sourceBytes,
      );
      final retryAt = _now.add(const Duration(minutes: 2));
      expect(
        await durable.leaseEligibleOutbox(
          f.uploadScope,
          now: retryAt,
          limit: 1,
          leaseId: 'still-paused-child',
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        ),
        isEmpty,
      );
      final readback = (await durable.leaseUnknownOutcomes(
        f.uploadScope,
        now: retryAt,
        limit: 1,
        leaseId: 'same-child-readback',
        leaseDuration: const Duration(minutes: 1),
        allowedPayloadVersions: const {1},
      )).single;
      expect(readback.status, CloudOutboxStatus.unknownOutcome);
      expect(readback.operationId, entered.operationId);
      expect(readback.appleRequestUuid, entered.appleRequestUuid);
      expect(readback.appleOperationUuid, entered.appleOperationUuid);
      expect(readback.payloadSha256, entered.payloadSha256);
      expect(readback.protectedLeaseReference, entered.protectedLeaseReference);
      expect(f.upload(uploaded.id).admittedOperationId, operation.operationId);
      expect(f.intent.protectedSourceBinding, sourceBytes);
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(f.store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  CloudSyncAttachmentUploadExecutor executor(
    _ExecutorBridge bridge,
    _ExecutorGate gate,
    _ReceivedPlanStaging staging,
    CloudSyncNativeAuthSnapshot auth,
  ) => CloudSyncAttachmentUploadExecutor(
    uploads: f.uploads,
    receivedJournal: f.received,
    historicalJournal: f.historical(),
    readLiveAuth: () async => auth,
    mutationGate: gate,
    bridge: bridge,
    staging: staging,
    completedAdmitter: _ExecutorAdmitter(f),
    clock: () => _now,
    privateStorageDirectory: f.directory.path,
  );

  test(
    'received media parent durably pins complete child proof and survives reopen',
    () async {
      for (final marker in ['L', 'Q']) {
        final child = f.complete(marker: marker);
        f.admit(child.id);
        f.confirm(child.id);
      }
      final proof = f.proof();
      final auth = _auth();
      final source = f.received.readForCreateAdmission(
        intentId: f.intentId,
        currentAuth: auth,
      );
      final scope = _scope('messageManateeZone');
      final reference = 'obcs2.ref.${'U' * 43}';
      final lease = 'obcs2.lease.${'b' * 32}';
      final now = DateTime.fromMillisecondsSinceEpoch(
        source.createdAtMs,
        isUtc: true,
      );
      ObjectBoxCloudSyncStore durable() => ObjectBoxCloudSyncStore(
        store: f.store,
        protector: _TestProtector(),
        localSendJournal: f.localSends,
        receivedArchiveJournal: f.received,
        attachmentUploadJournal: f.uploads,
      );
      CloudOutboxOperation admit(String? children) =>
          durable().admitProtectedReceivedCreate(
            draft: CloudOutboxDraft(
              scope: scope,
              logicalEntityKeyHash: source.observation.logicalEntityKeyHash,
              action: CloudOutboxAction.save,
              payloadVersion: cloudSyncOutboundPayloadVersion,
              dependencyOperationIds: const {},
              createdAt: now,
              encryptedPayloadReference: reference,
              payloadSha256: '9' * 64,
              serverRecordIdHash: source.observation.serverRecordIdHash,
              protectedLeaseReference: lease,
            ),
            recordMapping: CloudRecordMapEntry(
              scope: scope,
              logicalEntityKeyHash: source.observation.logicalEntityKeyHash,
              serverRecordIdHash: source.observation.serverRecordIdHash,
              encryptedServerRecordId: reference,
              updatedAt: now,
            ),
            journal: f.received,
            source: source,
            currentAuth: auth,
            stillCurrent: () => true,
            attachmentReadbackProof: children,
          );
      expect(() => admit(null), throwsStateError);
      final operation = admit(proof);
      expect(
        f.received
            .readAdoptedSource(transactionStore: f.store, operation: operation)!
            .attachmentReadbackProof,
        proof,
      );
      await f.reopen();
      expect(
        durable()
            .readReceivedArchiveOperation(scope, operation.operationId)
            ?.operationId,
        operation.operationId,
      );
      expect(
        f.received
            .readAdoptedSource(transactionStore: f.store, operation: operation)!
            .attachmentReadbackProof,
        proof,
      );
      final map = f.mapping(
        f.store.box<CloudAttachmentUploadEntity>().getAll().first.id,
      )..etagHash = 'F' * 43;
      f.store.box<CloudRecordMapEntity>().put(map);
      expect(
        () => durable().readReceivedArchiveOperation(
          scope,
          operation.operationId,
        ),
        throwsStateError,
      );
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 3);
    },
  );

  for (final mirrored in [false, true]) {
    test(
      'shared executor archives ${mirrored ? 'mirrored' : 'incoming'} media via its received owner',
      () async {
        if (mirrored) await f.seedReceived(mirrored: true);
        final plan = f.prepare();
        final bridge = _ExecutorBridge(f.result('L'));
        final gate = _ExecutorGate();
        final staging = _ReceivedPlanStaging();
        final run = await executor(bridge, gate, staging, _auth()).execute(
          CloudSyncAttachmentUploadExecutionInput(
            uploadId: plan.id,
            originalAttachmentGuid: 'received:0',
            sourcePath: 'synthetic-original-source',
            requestTimeoutSeconds: BigInt.from(120),
            retainedSourceAttachmentKeys: {'L' * 43},
          ),
        );
        expect(run.status, CloudAttachmentUploadExecutionStatus.completed);
        expect(bridge.receivedPrepares, 1);
        expect(bridge.receivedRecoveries, 0);
        expect(bridge.consumes, 1);
        expect(bridge.disposals, 1);
        expect(bridge.seenSource?.sourceSha256, f.source.sourceSha256);
        expect(
          f.upload(plan.id).ownerKind,
          cloudSyncAttachmentOwnerKindReceived,
        );
        expect(
          f.upload(plan.id).state,
          CloudAttachmentUploadState.adopted.index,
        );
        expect(f.upload(plan.id).attemptId, _attempt);
        expect(f.store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
        expect(f.store.box<CloudOutboxOperationEntity>().count(), 1);
        expect(staging.rollbacks, isEmpty);
      },
    );
  }

  test(
    'shared executor recovers original received attempt after reopen, never prepares missing receipts',
    () async {
      final plan = f.prepare();
      f.begin(plan.id);
      f.uploads.markReceivedUnknown(
        id: plan.id,
        attemptId: _attempt,
        now: _now,
        receivedJournal: f.received,
      );
      final original = f.upload(plan.id);
      await f.reopen();
      final bridge = _ExecutorBridge(f.result('L'));
      final gate = _ExecutorGate()..receipt = false;
      final staging = _ReceivedPlanStaging();
      final auth = _auth();
      final input = CloudSyncAttachmentUploadExecutionInput(
        uploadId: plan.id,
        originalAttachmentGuid: '',
        sourcePath: '',
        requestTimeoutSeconds: BigInt.zero,
      );
      final waiting = await executor(
        bridge,
        gate,
        staging,
        auth,
      ).execute(input);
      expect(
        waiting.status,
        CloudAttachmentUploadExecutionStatus.awaitingReceipt,
      );
      expect(
        bridge.receivedPrepares + bridge.receivedRecoveries + bridge.consumes,
        0,
      );
      expect(f.upload(plan.id).state, CloudAttachmentUploadState.unknown.index);
      expect(f.upload(plan.id).planReference, original.planReference);
      gate.receipt = true;
      final recovered = await executor(
        bridge,
        gate,
        staging,
        auth,
      ).execute(input);
      expect(
        recovered.status,
        CloudAttachmentUploadExecutionStatus.recoveredAndCompleted,
      );
      expect(bridge.receivedPrepares + bridge.consumes, 0);
      expect(bridge.receivedRecoveries, 1);
      expect(f.upload(plan.id).attemptId, original.attemptId);
      expect(f.upload(plan.id).writerEpoch, original.writerEpoch);
      expect(f.upload(plan.id).planReference, original.planReference);
      expect(f.upload(plan.id).state, CloudAttachmentUploadState.adopted.index);
      expect(f.store.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );
}

// Synthetic native collaborators exercise the real shared executor and durable
// journal. These are not Apple receipt or network-upload acceptance evidence.
api.CloudSyncProtectedOutboundStage _nativeStage(
  CloudSyncProtectedOutboundStageData value,
) => api.CloudSyncProtectedOutboundStage(
  logicalEntityKeyHash: value.logicalEntityKeyHash,
  protectedPayloadReference: value.protectedEnvelopeReference,
  payloadSha256: value.payloadSha256,
  payloadLength: BigInt.from(128),
  protectedServerRecordReference: value.protectedEnvelopeReference,
  serverRecordIdHash: value.serverRecordIdHash,
  leaseReference: value.leaseReference,
);

final class _ExecutorBridge implements CloudSyncReceivedAttachmentUploadBridge {
  _ExecutorBridge(this.result);
  final CloudSyncProtectedOutboundStageData result;
  int receivedPrepares = 0, receivedRecoveries = 0, consumes = 0, disposals = 0;
  api.CloudSyncNativeReceivedArchiveSourceBinding? seenSource;
  @override
  Future<CloudSyncPreparedUpload> prepareReceived({
    required api.CloudSyncReceivedAttachmentContext context,
    required api.CloudSyncAttachmentUploadPlanReference planStage,
    required String originalAttachmentGuid,
    required String sourcePath,
    required BigInt requestTimeoutSeconds,
  }) async {
    receivedPrepares++;
    seenSource = context.source;
    return _ExecutorPrepared(this);
  }

  @override
  Future<api.CloudSyncProtectedOutboundStage?> recoverReceived({
    required api.CloudSyncReceivedAttachmentContext context,
    required api.CloudSyncAttachmentUploadPlanReference planStage,
  }) async {
    receivedRecoveries++;
    seenSource = context.source;
    return _nativeStage(result);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_non_received_bridge');
}

final class _ExecutorPrepared implements CloudSyncPreparedUpload {
  _ExecutorPrepared(this.bridge);
  final _ExecutorBridge bridge;
  @override
  String get uploadAttemptId => _attempt;
  @override
  String get handleBindingSha256 => 'a' * 64;
  @override
  Future<api.CloudSyncAttachmentUploadConsumeResult> consume(
    String token,
  ) async {
    bridge.consumes++;
    return api.CloudSyncAttachmentUploadConsumeResult(
      uploadAttemptId: _attempt,
      disposition: api.CloudSyncOutboundSaveDisposition.succeeded,
      stage: _nativeStage(bridge.result),
    );
  }

  @override
  Future<void> dispose() async {
    bridge.disposals++;
  }
}

final class _ExecutorGate implements CloudSyncAttachmentUploadMutationGate {
  bool receipt = true;
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
    requireAdmission();
    await requireDurableAdmission();
    return action('synthetic-capability');
  }

  @override
  Future<bool> reconcileAttachmentUpload({
    required Object expectedClient,
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
  }) async => receipt;
  @override
  void markActiveMutationUnknown() =>
      throw StateError('unexpected_unknown_consume');
}

final class _ExecutorAdmitter implements CloudSyncCompletedUploadAdmitter {
  _ExecutorAdmitter(this.fixture);
  final _Fixture fixture;
  @override
  CloudAttachmentUploadSnapshot admitCompletedAttachmentUpload({
    required CloudSyncAttachmentUploadJournal uploads,
    required int uploadId,
    required DateTime createdAt,
  }) => fixture.admit(uploadId);
}

final class _Fixture {
  _Fixture(this.directory, this.store);
  final Directory directory;
  Store store;
  late ObjectBoxCloudKitWriterAuthority authority;
  late CloudSyncLocalSendJournal localSends;
  late CloudSyncReceivedArchiveJournal received;
  late CloudSyncAttachmentUploadJournal uploads;
  late Chat chat;
  late Handle remote;
  late Handle owner;
  late int intentId;
  late CloudSyncReceivedArchiveSourceBinding source;
  CloudSyncScope get uploadScope => _scope('attachmentManateeZone');
  CloudSyncReceivedArchiveIntentEntity get intent =>
      store.box<CloudSyncReceivedArchiveIntentEntity>().get(intentId)!;
  CloudSyncReceivedAttachmentOrigin get origin =>
      received.requireReceivedAttachmentOrigin(
        transactionStore: store,
        intentId: intentId,
        currentAuth: _auth(),
      );
  CloudAttachmentUploadEntity upload(int id) =>
      store.box<CloudAttachmentUploadEntity>().get(id)!;

  static Future<_Fixture> open() async {
    final directory = await Directory.systemTemp.createTemp(
      'received-upload-journal-',
    );
    final f = _Fixture(directory, await openStore(directory: directory.path));
    f.authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: f.store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final disabled = f.authority.initializeDisabled(_writerScope(), now: _now);
    f.authority.provisionInitialOwner(
      _writerScope(),
      owner: CloudKitWriterOwner.v2,
      expectedEpoch: disabled.epoch,
      evidence: const CloudKitWriterTransitionEvidence.forTest(
        operationsQuiesced: true,
        activeIdentityRevalidated: true,
        legacyMutationQueues: LegacyMutationQueueDisposition.empty,
      ),
      now: _now,
    );
    f.bind();
    f.remote = Handle(
      address: 'remote@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'remote@example.com/iMessage',
    )..originalROWID = 9001;
    f.owner = Handle(
      address: 'owner@example.com',
      service: 'iMessage',
      uniqueAddressAndService: 'owner@example.com/iMessage',
    )..originalROWID = 9003;
    f.store.box<Handle>().putMany([f.remote, f.owner]);
    f.chat = Chat(
      guid: _chatGuid,
      chatIdentifier: 'remote@example.com',
      usingHandle: _owner,
      isRpSms: false,
      style: 45,
      participants: [f.remote],
    );
    f.chat.handles.add(f.remote);
    f.store.box<Chat>().put(f.chat);
    final durable = ObjectBoxCloudSyncStore(
      store: f.store,
      protector: _TestProtector(),
      clock: () => _now,
    );
    for (final zone in [
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      await durable.recordPullSuccess(_scope(zone), now: _now);
    }
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: f.store,
      store: durable,
      chatScope: _scope('chatManateeZone'),
      now: _now,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: f.store,
      store: durable,
      chatScope: _scope('chatManateeZone'),
      chat: f.chat,
      appliedSource: applied,
      now: _now,
    );
    return f;
  }

  void bind() {
    authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final snapshot = authority.read(_writerScope())!;
    localSends = CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: snapshot,
    );
    received = CloudSyncReceivedArchiveJournal(
      store: store,
      authority: authority,
      authoritySnapshot: snapshot,
    );
    uploads = reboundUploads();
  }

  CloudSyncAttachmentUploadJournal reboundUploads({
    CloudSyncNativeAuthSnapshot? auth,
    ObjectBoxCloudKitWriterAuthority? authority,
  }) => CloudSyncAttachmentUploadJournal(
    store: store,
    localSends: localSends,
    scope: uploadScope,
    checkpointGeneration: 1,
    currentAuth: auth ?? _auth(),
    writerAuthority: authority ?? this.authority,
  );

  Future<void> seedReceived({bool mirrored = false}) async {
    final guid = 'received-upload-${mirrored ? 'mirrored' : 'incoming'}';
    final sender = mirrored ? owner : remote;
    final attachments = List.generate(
      2,
      (index) => Attachment(
        guid: '${guid}_${index + 1}',
        uti: 'public.jpeg',
        mimeType: 'image/jpeg',
        transferName: 'photo$index.jpg',
        totalBytes: 1234,
        isOutgoing: false,
        hasLivePhoto: false,
      ),
    );
    const text = 'caption  ';
    final message = Message(
      guid: guid,
      text: text,
      dateCreated: _now,
      isFromMe: mirrored,
      handle: sender,
      hasAttachments: true,
      attributedBody: [
        AttributedBody(
          string: text,
          runs: [
            Run(range: [0, 7], attributes: Attributes(messagePart: 0)),
            for (var index = 0; index < 2; index++)
              Run(
                range: [7 + index, 1],
                attributes: Attributes(
                  messagePart: index + 1,
                  attachmentGuid: attachments[index].guid,
                ),
              ),
          ],
        ),
      ],
    );
    message.handleId = sender.originalROWID;
    message.chat.target = chat;
    message.attachments = attachments;
    final wire = api.MessageInst(
      id: guid,
      sender: mirrored ? _owner : _peer,
      conversation: api.ConversationData(
        participants: [_owner, _peer],
        senderGuid: _chatGuid,
      ),
      message: api.Message.message(
        api.NormalMessage(
          service: const api.MessageType_IMessage(),
          voice: false,
          parts: api.MessageParts(
            field0: [
              const api.IndexedMessagePart(
                part_: api.MessagePart.text(
                  'caption',
                  api.TextFormat.flags(
                    api.TextFlags(
                      bold: false,
                      italic: false,
                      underline: false,
                      strikethrough: false,
                    ),
                  ),
                ),
              ),
              for (var index = 0; index < 2; index++)
                api.IndexedMessagePart(
                  idx: index + 1,
                  part_: api.MessagePart.attachment(
                    api.Attachment(
                      part_: index,
                      utiType: 'public.jpeg',
                      mime: 'image/jpeg',
                      name: 'photo$index.jpg',
                      iris: false,
                      aType: api.AttachmentType.mmcs(
                        api.MMCSFile(
                          key: Uint8List.fromList(List.filled(32, 7)),
                          signature: Uint8List.fromList(List.filled(21, 9)),
                          object: 'synthetic-object-$index',
                          url: 'https://example.invalid/mmcs/$index',
                          size: 1234,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      sentTimestamp: _now.millisecondsSinceEpoch,
      target: [api.MessageTarget.token(Uint8List(32))],
      sendDelivered: false,
      verificationFailed: false,
      receivedOnHandle: _owner,
    );
    final capture = CloudSyncReceivedArchiveIdentity.preview(
      message: message,
      chat: chat,
      wire: wire,
      liveContext: _live,
    );
    expect(capture, isA<CloudSyncReceivedArchiveEligible>());
    final identity = (capture as CloudSyncReceivedArchiveEligible).identity;
    source = CloudSyncReceivedArchiveSourceBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      messageGuidHash: identity.guidHash,
      sourceSha256: identity.sourceSha256,
      protectedReference: 'obcs2.ref.${'R' * 43}',
      leaseReference: 'obcs2.lease.${'a' * 32}',
      payloadSha256: 'b' * 64,
      payloadLength: 128,
    );
    intentId = received.saveReceivedCapture(
      wire: wire,
      liveContext: _live,
      localChatId: chat.id!,
      source: source,
      capturedAuth: _auth(),
      stillCurrent: () => true,
      now: _now,
      persistMessage: () {
        final localId = store.box<Message>().put(message);
        for (final attachment in attachments) {
          attachment.message.target = message;
        }
        store.box<Attachment>().putMany(attachments);
        message.dbAttachments.addAll(attachments);
        store.box<Message>().put(message);
        return localId;
      },
    );
    received.markSourceMaterialized(
      intentId: intentId,
      source: source,
      currentAuth: _auth(),
      stillCurrent: () => true,
    );
    final parent = requireCloudSyncHistoricalParentProof(
      store: store,
      messageScope: _scope('messageManateeZone'),
      chatId: chat.id!,
    );
    final observation = CloudSyncReceivedRecordObservation(
      state: CloudSyncReceivedRecordState.absent,
      accountFingerprint: _account,
      protectedStoreIdentity: _storeId,
      messageGuidHash: source.messageGuidHash,
      sourceSha256: source.sourceSha256,
      logicalEntityKeyHash: 'M' * 43,
      serverRecordIdHash: 'N' * 43,
      generation: 1,
      parentBinding: parent.binding,
      observedAtMs: _now.millisecondsSinceEpoch,
    );
    void validateParent() => requireCloudSyncHistoricalParentUnchanged(
      store: store,
      messageScope: _scope('messageManateeZone'),
      chatId: chat.id!,
      binding: parent.binding,
    );
    received.adoptRecordObservation(
      intentId: intentId,
      expectedSource: source,
      observation: observation,
      currentAuth: _auth(),
      stillCurrent: () => true,
      validateParent: validateParent,
    );
    received.markRecordObservationCommitted(
      intentId: intentId,
      source: source,
      observation: observation,
      currentAuth: _auth(),
      stillCurrent: () => true,
      validateParent: validateParent,
    );
  }

  CloudSyncReceivedArchiveSourceBinding replacementSource({
    String reference = 'R',
  }) => CloudSyncReceivedArchiveSourceBinding(
    accountFingerprint: _account,
    protectedStoreIdentity: _storeId,
    messageGuidHash: source.messageGuidHash,
    sourceSha256: source.sourceSha256,
    protectedReference: 'obcs2.ref.${reference * 43}',
    leaseReference: source.leaseReference,
    payloadSha256: source.payloadSha256,
    payloadLength: source.payloadLength,
  );

  CloudSyncProtectedOutboundStageData plan(
    String marker, {
    String? reference,
  }) => CloudSyncProtectedOutboundStageData(
    logicalEntityKeyHash: marker * 43,
    serverRecordIdHash: marker * 43,
    protectedEnvelopeReference: 'obcs2.ref.${(reference ?? marker) * 43}',
    leaseReference: 'obcs2.lease.${(marker == 'L' ? 'c' : 'd') * 32}',
    payloadSha256: 'c' * 64,
  );
  CloudSyncProtectedOutboundStageData result(
    String marker, {
    String? reference,
  }) => CloudSyncProtectedOutboundStageData(
    logicalEntityKeyHash: marker * 43,
    serverRecordIdHash: marker * 43,
    protectedEnvelopeReference:
        'obcs2.ref.${(reference ?? marker.toLowerCase()) * 43}',
    leaseReference: 'obcs2.lease.${(marker == 'L' ? 'e' : 'f') * 32}',
    payloadSha256: 'd' * 64,
  );
  CloudAttachmentUploadSnapshot prepare({
    String marker = 'L',
    CloudSyncProtectedOutboundStageData? plan,
  }) => uploads.adoptReceivedPlan(
    receivedIntentId: intentId,
    plan: plan ?? this.plan(marker),
    now: _now,
    receivedJournal: received,
  );
  CloudAttachmentUploadSnapshot begin(int id, {String attempt = _attempt}) =>
      uploads.beginReceivedAttempt(
        id: id,
        attemptId: attempt,
        now: _now,
        receivedJournal: received,
      );
  CloudAttachmentUploadSnapshot record(
    int id, {
    CloudSyncProtectedOutboundStageData? result,
  }) {
    final marker = upload(id).attachmentKeyHash[0];
    return uploads.recordReceivedUploaded(
      id: id,
      attemptId: _attempt,
      result: result ?? this.result(marker),
      now: _now,
      receivedJournal: received,
    );
  }

  CloudAttachmentUploadSnapshot complete({String marker = 'L'}) {
    final prepared = prepare(marker: marker);
    begin(prepared.id);
    return record(prepared.id);
  }

  CloudAttachmentUploadSnapshot admit(int id) =>
      uploads.adoptReceivedRecordCreate(
        id: id,
        now: _now,
        receivedJournal: received,
        admit: (transactionStore, result) {
          expect(identical(transactionStore, store), isTrue);
          return persistOperation(result);
        },
      );

  CloudOutboxOperation persistOperation(
    CloudSyncProtectedOutboundStageData result,
  ) {
    final operation = CloudOutboxOperation(
      scope: uploadScope,
      operationId: CloudOperationIdentity.forInitialCreate(
        scope: uploadScope,
        logicalEntityKeyHash: result.logicalEntityKeyHash,
        payloadVersion: 1,
      ),
      logicalEntityKeyHash: result.logicalEntityKeyHash,
      action: CloudOutboxAction.save,
      payloadVersion: 1,
      mutationRevision: 0,
      checkpointGeneration: 1,
      dependencyOperationIds: const {},
      createdAt: _now,
      encryptedPayloadReference: result.protectedEnvelopeReference,
      payloadSha256: result.payloadSha256,
      serverRecordIdHash: result.serverRecordIdHash,
      protectedLeaseReference: result.leaseReference,
    );
    store.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: operation.operationId,
        scopeKey: cloudSyncPersistentScopeKey(uploadScope),
        accountFingerprint: _account,
        zone: uploadScope.zone,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        action: CloudOutboxAction.save.index,
        mutationRevision: 0,
        checkpointGeneration: 1,
        encryptedPayloadRef: operation.encryptedPayloadReference,
        payloadSha256: operation.payloadSha256,
        protectedLeaseReference: operation.protectedLeaseReference,
        serverRecordIdHash: operation.serverRecordIdHash,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    store.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(
          uploadScope,
          operation.logicalEntityKeyHash,
        ),
        scopeKey: cloudSyncPersistentScopeKey(uploadScope),
        accountFingerprint: _account,
        zone: uploadScope.zone,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        serverRecordIdHash: operation.serverRecordIdHash!,
        encryptedServerRecordId: operation.encryptedPayloadReference!,
        generation: 1,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    return operation;
  }

  CloudOutboxOperationEntity outbox(int id) => store
      .box<CloudOutboxOperationEntity>()
      .getAll()
      .singleWhere((row) => row.operationId == upload(id).admittedOperationId);
  CloudOutboxOperation operation(int id) {
    final row = outbox(id);
    return CloudOutboxOperation(
      scope: uploadScope,
      operationId: row.operationId,
      logicalEntityKeyHash: row.logicalEntityKeyHash,
      action: CloudOutboxAction.save,
      payloadVersion: row.payloadVersion,
      mutationRevision: row.mutationRevision,
      checkpointGeneration: row.checkpointGeneration,
      dependencyOperationIds: const {},
      createdAt: _now,
      encryptedPayloadReference: row.encryptedPayloadRef,
      protectedLeaseReference: row.protectedLeaseReference,
      payloadSha256: row.payloadSha256,
      serverRecordIdHash: row.serverRecordIdHash,
      appleRequestUuid: row.appleRequestUuid,
      appleOperationUuid: row.appleOperationUuid,
      status: CloudOutboxStatus.values[row.state],
    );
  }

  CloudRecordMapEntity mapping(int id) =>
      store.box<CloudRecordMapEntity>().getAll().singleWhere(
        (row) =>
            row.mapKey ==
            cloudSyncCanonicalRecordMapKey(
              uploadScope,
              upload(id).attachmentKeyHash,
            ),
      );
  void confirm(int id, {bool releaseLease = true}) {
    final row = outbox(id)
      ..state = CloudOutboxStatus.confirmed.index
      ..confirmedAtMs = _now.millisecondsSinceEpoch
      ..appleRequestUuid = '11111111-2222-4333-8444-555555555555'
      ..appleOperationUuid = '66666666-7777-4888-9999-AAAAAAAAAAAA';
    if (releaseLease) row.protectedLeaseReference = null;
    store.box<CloudOutboxOperationEntity>().put(row);
    final map = mapping(id)..etagHash = 'E' * 43;
    store.box<CloudRecordMapEntity>().put(map);
  }

  String proof({Set<String>? keys}) =>
      uploads.captureReceivedParentReadbackProof(
        receivedIntentId: intentId,
        sourceAttachmentKeys: keys ?? _keys,
        receivedJournal: received,
      );
  void requireProof(String proof) => uploads.requireReceivedParentReadbackProof(
    receivedIntentId: intentId,
    proof: proof,
    receivedJournal: received,
  );

  CloudSyncHistoricalProtectedSourceBinding get historicalSource =>
      CloudSyncHistoricalProtectedSourceBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        snapshotSha256: 'a' * 64,
        messageGuidHash: 'b' * 64,
        sourceSha256: 'c' * 64,
        protectedReference: 'obcs2.ref.${'H' * 43}',
        leaseReference: 'obcs2.lease.${'a' * 32}',
        payloadSha256: 'd' * 64,
        payloadLength: 128,
      );
  CloudSyncHistoricalArchiveJournal historical() =>
      CloudSyncHistoricalArchiveJournal(
        store: store,
        accountFingerprint: _account,
        protectedStoreIdentity: _storeId,
        snapshotSha256: 'a' * 64,
        clock: () => _now,
      );

  Future<void> enterUnknown() async {
    await CloudKitOperationInterlock(
      privateStorageDirectory: directory.path,
      fenceStore: InMemoryCloudSyncStore(),
    ).runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () async {
        authority.markMutationUnknown(
          authority.issuePermit(
            _writerScope(),
            expectedOwner: CloudKitWriterOwner.v2,
          ),
          now: _now,
        );
      },
    );
    bind();
  }

  Future<void> reconcile(int epoch) async {
    await CloudKitOperationInterlock(
      privateStorageDirectory: directory.path,
      fenceStore: InMemoryCloudSyncStore(),
    ).runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () async {
        authority.reconcileMutationFence(
          _writerScope(),
          owner: CloudKitWriterOwner.v2,
          fencedEpoch: epoch,
          now: _now,
        );
      },
    );
    bind();
  }

  Future<void> reopen() async {
    store.close();
    store = await openStore(directory: directory.path);
    bind();
  }

  Future<void> close() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  }
}

final class _ReceivedPlanStaging implements CloudSyncOutboundStagingTransport {
  final commits = <String>[];
  final rollbacks = <String>[];
  bool failCommit = false;

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedReference,
  ) async {
    commits.add(leaseReference);
    if (failCommit) {
      throw StateError('synthetic_received_plan_commit_interrupted');
    }
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
    rollbacks.add(leaseReference);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_native_staging');
}

final class _TestProtector implements CloudSyncProtector {
  String prefix(CloudSyncScope scope, CloudSyncProtectedValueKind kind) =>
      'synthetic-received-upload:${scope.storageKey}:${kind.name}:';
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => '${prefix(scope, kind)}$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    final expected = prefix(scope, kind);
    if (!ciphertext.startsWith(expected)) {
      throw StateError('synthetic_scope_changed');
    }
    return ciphertext.substring(expected.length);
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) =>
      throw StateError('unexpected_native_auth');
}
