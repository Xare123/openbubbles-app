import 'dart:io';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_selection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_admission.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_admission.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/transient_cloud_canonical_identity_registry.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

const _guid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const _recipient = 'recipient@example.invalid';
const _sender = 'sender@example.invalid';
const _canonical = 'iMessage;-;$_recipient';
final _logical = 'L' * 43;
final _record = 'S' * 43;
final _ref = 'obcs2.ref.${'P' * 43}';
final _lease = 'obcs2.lease.${'a' * 32}';
final _now = DateTime.utc(2026, 9, 5);
CloudSyncScope _scope([String zone = 'chatManateeZone']) => CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: 2,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

void main() {
  late Directory directory;
  late Store db;
  late ObjectBoxCloudSyncStore sync;
  late int chatId;
  late int messageId;
  void bindStore() {
    sync = ObjectBoxCloudSyncStore(
      store: db,
      protector: _Protector(),
      clock: () => _now,
    );
  }

  Future<void> restart() async {
    db.close();
    db = await openStore(directory: directory.path);
    bindStore();
  }

  CloudOutboxOperationEntity outbox() =>
      db.box<CloudOutboxOperationEntity>().getAll().single;
  CloudRecordMapEntity recordMap() =>
      db.box<CloudRecordMapEntity>().getAll().single;
  void preserved({bool adopted = false}) {
    expect(db.box<Chat>().count(), 1);
    expect(db.box<Message>().count(), 1);
    final message = db.box<Message>().get(messageId)!;
    expect(message.text, 'synthetic body survives adoption');
    expect(message.chat.targetId, chatId);
    expect(message.chat.target!.guid, adopted ? _canonical : _guid);
    expect(db.box<Chat>().get(chatId)!.handles.single.address, _recipient);
  }

  CloudOutboxOperation admit() {
    final origin = sync.captureFreshOutboundChatOrigin(_scope(), chatId);
    return sync.admitProtectedOutboundChatCreate(
      draft: CloudOutboxDraft(
        scope: _scope(),
        logicalEntityKeyHash: _logical,
        action: CloudOutboxAction.save,
        payloadVersion: cloudSyncOutboundChatPayloadVersion,
        dependencyOperationIds: const {},
        createdAt: _now,
        encryptedPayloadReference: _ref,
        payloadSha256: 'b' * 64,
        serverRecordIdHash: _record,
        protectedLeaseReference: _lease,
      ),
      recordMapping: CloudRecordMapEntry(
        scope: _scope(),
        logicalEntityKeyHash: _logical,
        serverRecordIdHash: _record,
        encryptedServerRecordId: _ref,
        updatedAt: _now,
      ),
      origin: origin,
    );
  }

  void submitted({bool confirmed = false, bool cleanup = false}) {
    final row = outbox()
      ..state =
          (confirmed
                  ? CloudOutboxStatus.confirmed
                  : CloudOutboxStatus.unknownOutcome)
              .index
      ..appleRequestUuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
      ..appleOperationUuid = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC';
    if (cleanup) row.protectedLeaseReference = null;
    db.box<CloudOutboxOperationEntity>().put(row);
    final map = recordMap()
      ..etagHash = 'E' * 43
      ..encryptedRawRecordRef = 'obcs2.ref.${'R' * 43}';
    db.box<CloudRecordMapEntity>().put(map);
  }

  void project({CloudChatEntityPayload? payload, int generation = 1}) {
    final adapter = ObjectBoxCanonicalSemanticEntityAdapter(
      store: db,
      activeScopeProvider: () =>
          CloudCanonicalActiveScope(scope: _scope(), generation: generation),
      identityResolver: _Resolver(),
      semanticApplyEnabled: true,
      allowChatUpserts: true,
    );
    // Same transaction boundary as canonical projection: a rejected origin
    // must not leave aliases, Chat mutations or relation changes behind.
    db.runInTransaction(TxMode.write, () {
      adapter.applyEntity(
        scope: _scope(),
        generation: generation,
        payload: payload ?? _payload(),
        snapshot: _snapshot(),
      );
      // This adapter-level fixture models the gateway's ownership snapshot
      // write after successful canonical apply, in the same real transaction.
      // It is never installed before a rejected provisional-origin adoption.
      _persistOwnership(db, generation);
    });
  }

  for (final mutation in [
    'none',
    'shared Chat',
    'account',
    'route',
    'recipient',
    'original GUID',
    'origin',
    'generation',
    'map',
    'payload',
    'foreign Chat',
    'foreign Message',
  ]) {
    test(
      'offline first Chat receipt -> gateway -> original v2 Message ($mutation)',
      () async {
        // Real persistence/admission/projection, synthetic native edges only.
        // Does not execute service attachment-lock release or live CloudKit.
        final writerScope = CloudKitWriterScope(accountFingerprint: 'A' * 43);
        late CloudSyncLocalSendJournal journal;
        void bindJournal() {
          final authority = ObjectBoxCloudKitWriterAuthority.forTest(
            store: db,
            buildDecision: CloudKitWriterOwnership.resolve('v2'),
          );
          if (authority.read(writerScope) == null) {
            final disabled = authority.initializeDisabled(
              writerScope,
              now: _now,
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
              now: _now,
            );
          }
          journal = CloudSyncLocalSendJournal(
            store: db,
            authority: authority,
            authoritySnapshot: authority.read(writerScope)!,
          );
          sync = ObjectBoxCloudSyncStore(
            store: db,
            protector: _Protector(),
            clock: () => _now,
            localSendJournal: journal,
          );
        }

        bindJournal();
        const messageGuid = 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD';
        final local = db.box<Message>().get(messageId)!
          ..guid = 'temp-Abc12345'
          ..stagingGuid = messageGuid
          ..attributedBody = [
            AttributedBody.raw('synthetic body survives adoption'),
          ];
        final identity = CloudSyncLocalSendIdentity.capture(
          local,
          local.chat.target!,
          messageGuid,
        )!;
        journal.saveSubmission(
          identity: identity,
          newlyGeneratedGuid: true,
          persistMessage: () => db.box<Message>().put(local),
          now: _now,
        );
        local
          ..guid = messageGuid
          ..stagingGuid = null;
        journal.saveConfirmedSubmission(
          identity: identity,
          persistMessage: () => db.box<Message>().put(local),
          now: _now,
        );
        final intentId = journal.readReady().single.id;
        final client = Object();
        CloudSyncNativeAuthSnapshot auth(String account) =>
            CloudSyncNativeAuthSnapshot.fromNative(
              nativeSessionId: 'synthetic-session',
              accountFingerprint: account,
              protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
              cloudMessagesClient: client,
            );
        final expected = auth('A' * 43);
        var current = expected;
        final fence = CloudSyncLocalSendAuthFence(
          expected: expected,
          capture: () async => current,
          stillCurrent: () => true,
        );
        final transport = _CombinedStaging();
        final source = journal.readForAdmission(intentId);
        CloudSyncLocalSendExactSelection newSelection() =>
            CloudSyncLocalSendExactSelection(
              intentId: intentId,
              expectedRecipient: _recipient,
              expectedSourceSha256: identity.sourceSha256,
            );
        var selection = newSelection();
        Future<void> validateSelected() => fence.run(() {
          selection.validate(
            store: db,
            journal: journal,
            durable: sync,
            scope: _scope('messageManateeZone'),
          );
        });
        await validateSelected();
        final operation =
            await CloudSyncOutboundChatAdmissionCoordinator(
              store: sync,
              transport: transport,
              ensureProtectedStoreRecovered: () async {},
            ).admitChat(
              _scope(),
              chatId: chatId,
              createdAt: mutation == 'shared Chat'
                  ? _now.subtract(const Duration(days: 1))
                  : _now,
              authFence: fence,
              encode: (_) => _FakeChat(),
              validateLocalOrigin: () {
                expect(
                  journal
                      .validateReadyForCreate(
                        db,
                        _scope('messageManateeZone'),
                        source,
                      )
                      .chat
                      .targetId,
                  chatId,
                );
              },
            );
        expect(transport.stages, 1);
        await validateSelected();
        const submissionLease = 'synthetic-combined-submission';
        final leased = await sync.leaseEligibleOutbox(
          _scope(),
          now: _now,
          limit: 1,
          leaseId: submissionLease,
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        expect(leased.single.operationId, operation.operationId);
        await sync.markOutboxSubmissionStarted(
          _scope(),
          leaseId: submissionLease,
          submissionIdentity: CloudOutboxSubmissionIdentity(
            requestUuid: 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',
            operationUuids: {
              operation.operationId: 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC',
            },
          ),
          now: _now,
        );
        // Fake successful network response, committed by the actual store API.
        await sync.commitOutboxCreateReceipt(
          _scope(),
          leaseId: submissionLease,
          receipt: CloudOutboxCreateReceipt(
            operationId: operation.operationId,
            logicalEntityKeyHash: _logical,
            serverRecordIdHash: _record,
            etagHash: 'E' * 43,
          ),
          now: _now,
        );
        final confirmed = (await sync.readOutboxEntries(_scope())).single;
        expect(confirmed.status, CloudOutboxStatus.confirmed);
        expect(confirmed.protectedLeaseReference, isNull);
        expect(db.box<CloudSemanticSnapshotEntity>().count(), 0);
        await restart();
        bindJournal();
        selection = newSelection();
        // Durable same-Chat recovery must accept even settled work allocated
        // for an earlier intent, without relying on process-local selection.
        await validateSelected();

        Future<CloudOutboxOperation> admitMessage() async {
          await validateSelected();
          return CloudSyncOutboundAdmissionCoordinator(
            store: sync,
            transport: transport,
            ensureProtectedStoreRecovered: () async {},
          ).admitLocalSend(
            _scope('messageManateeZone'),
            intentId: intentId,
            journal: journal,
            authFence: fence,
            encodeMessage: _CombinedMessage.new,
          );
        }

        // Receipt alone must not admit a Message before canonical ownership exists.
        await expectLater(
          admitMessage(),
          _failure('cloud_sync_local_send_chat_not_ready'),
        );
        expect(transport.messageStages, 0);

        final checkpoint = await sync.readCheckpoint(_scope());
        final lease = (await sync.tryAcquireCoordinatorLease(
          _scope(),
          ownerId: 'synthetic-combined-gateway',
          now: _now,
          leaseDuration: const Duration(minutes: 1),
        ))!;
        final change = CloudFetchedChange(
          changeId: 'C' * 43,
          recordIdHash: _record,
          etagHash: 'E' * 43,
          type: CloudChangeType.save,
          isTombstone: false,
          encryptedServerRecordId: _ref,
          protectedSystemFieldsReference: 'obcs2.ref.${'F' * 43}',
          encryptedPayloadReference: 'obcs2.ref.${'R' * 43}',
          payloadSha256: 'c' * 64,
        );
        await sync.journalFetchedBatch(
          CloudFetchBatch(
            scope: _scope(),
            changes: [change],
            batchId: 'synthetic-combined-readback',
            generation: checkpoint.generation,
            nextToken: 'synthetic-combined-token',
            hasMore: false,
          ),
          now: _now,
          leaseFence: lease,
          expectedGeneration: checkpoint.generation,
          expectedFetchedToken: checkpoint.fetchedToken,
        );
        final entry = (await sync.readEligibleInbox(
          _scope(),
          now: _now,
          limit: 1,
        )).single;
        final registry = TransientCloudCanonicalIdentityRegistry();
        final gateway = ObjectBoxCloudSemanticStoreGateway(
          store: db,
          canonicalAdapter: ObjectBoxCanonicalSemanticEntityAdapter(
            store: db,
            identityResolver: registry,
            activeScopeProvider: () =>
                CloudCanonicalActiveScope(scope: _scope(), generation: 1),
            semanticApplyEnabled: true,
            allowChatUpserts: true,
          ),
          clock: () => _now,
        );
        final payload = _payload();
        final snapshot = CloudSemanticSnapshot(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: _logical,
          immutableContentDigest: 'I' * 43,
          etagHash: change.etagHash,
          encryptedRawRecordReference: change.encryptedPayloadReference,
        );
        final identityLease = registry.bind(
          CloudDecodedMutation.upsert(
            scope: _scope(),
            generation: 1,
            changeId: change.changeId,
            snapshot: snapshot,
            payload: payload,
          ),
        );
        try {
          await gateway.writeTransaction<void>(
            entry: entry,
            leaseFence: lease,
            action: (tx) {
              tx.applyEntity(payload: payload, snapshot: snapshot);
              tx.markChangeApplied(change.changeId);
            },
          );
        } finally {
          identityLease.release();
          await sync.releaseCoordinatorLease(_scope(), leaseFence: lease);
        }
        preserved(adopted: true);
        expect(db.box<CloudSemanticSnapshotEntity>().count(), 1);
        await restart();
        bindJournal();
        selection = newSelection();
        await validateSelected();
        expect(
          journal.readForAdmission(intentId).sourceSha256,
          identity.sourceSha256,
        );
        if (mutation == 'account') current = auth('B' * 43);
        if (mutation == 'route') {
          db.box<Chat>().put(
            db.box<Chat>().get(chatId)!
              ..usingHandle = 'mailto:other@example.invalid',
          );
        }
        if (mutation == 'recipient') {
          db.box<Handle>().put(
            db.box<Chat>().get(chatId)!.handles.single
              ..address = 'other@example.invalid',
          );
        }
        if (mutation == 'original GUID') {
          db.box<Chat>().put(
            db.box<Chat>().get(chatId)!
              ..cloudGuid = 'EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE',
          );
        }
        if (mutation == 'origin') {
          db.box<CloudOutboxOperationEntity>().put(
            outbox()..localChatOrigin = null,
          );
        }
        if (mutation == 'generation') {
          db.box<CloudOutboxOperationEntity>().put(
            outbox()..checkpointGeneration = 2,
          );
        }
        if (mutation == 'payload') {
          db.box<CloudOutboxOperationEntity>().put(
            outbox()..payloadSha256 = 'e' * 64,
          );
        }
        if (mutation == 'map') {
          db.box<CloudRecordMapEntity>().put(
            recordMap()..serverRecordIdHash = 'X' * 43,
          );
        }
        if (mutation == 'foreign Chat' || mutation == 'foreign Message') {
          final foreign = outbox()
            ..id = 0
            ..operationId = 'F' * 43;
          if (mutation == 'foreign Message') {
            foreign.zone = 'messageManateeZone';
          }
          db.box<CloudOutboxOperationEntity>().put(foreign);
        }
        if (mutation != 'none' && mutation != 'shared Chat') {
          await expectLater(
            admitMessage(),
            throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())),
          );
          expect(transport.messageStages, 0);
          expect(
            db.box<CloudOutboxOperationEntity>().count(),
            mutation.startsWith('foreign') ? 2 : 1,
          );
        } else {
          final messageOperation = await admitMessage();
          await validateSelected();
          final retried = await admitMessage();
          expect(retried.operationId, messageOperation.operationId);
          expect(transport.messageStages, 1);
          expect(messageOperation.scope, _scope('messageManateeZone'));
          expect(
            journal.readForAdmission(intentId).admittedOperationId,
            messageOperation.operationId,
          );
          expect(
            db
                .box<CloudSyncLocalSendIntentEntity>()
                .get(intentId)!
                .sourceSha256,
            identity.sourceSha256,
          );
          expect(db.box<CloudOutboxOperationEntity>().count(), 2);
          preserved(adopted: true);
        }
      },
    );
  }

  test(
    'real gateway binds map, adopts same row, persists ownership and survives replay/restart',
    () async {
      final operation = admit();
      // Synthetic successful submission, but deliberately no authenticated map
      // fields and no ownership snapshot: only the gateway may write those.
      db.box<CloudOutboxOperationEntity>().put(
        outbox()
          ..state = CloudOutboxStatus.confirmed.index
          ..appleRequestUuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
          ..appleOperationUuid = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC',
      );
      expect(recordMap().etagHash, isNull);
      expect(recordMap().encryptedRawRecordRef, isNull);
      expect(db.box<CloudSemanticSnapshotEntity>().count(), 0);
      final originalMapId = recordMap().id;
      int? ownershipId;
      for (var pass = 0; pass < 2; pass++) {
        if (pass == 1) await restart();
        final checkpoint = await sync.readCheckpoint(_scope());
        final fence = (await sync.tryAcquireCoordinatorLease(
          _scope(),
          ownerId: 'synthetic-origin-gateway',
          now: _now,
          leaseDuration: const Duration(minutes: 1),
        ))!;
        final change = CloudFetchedChange(
          changeId: (pass == 0 ? 'C' : 'D') * 43,
          recordIdHash: _record,
          etagHash: 'E' * 43,
          type: CloudChangeType.save,
          isTombstone: false,
          encryptedServerRecordId: _ref,
          protectedSystemFieldsReference: 'obcs2.ref.${'F' * 43}',
          encryptedPayloadReference: 'obcs2.ref.${'R' * 43}',
          payloadSha256: 'c' * 64,
        );
        await sync.journalFetchedBatch(
          CloudFetchBatch(
            scope: _scope(),
            changes: [change],
            batchId: 'synthetic-gateway-$pass',
            generation: checkpoint.generation,
            nextToken: 'synthetic-token-$pass',
            hasMore: false,
          ),
          now: _now,
          leaseFence: fence,
          expectedGeneration: checkpoint.generation,
          expectedFetchedToken: checkpoint.fetchedToken,
        );
        final entry = (await sync.readEligibleInbox(
          _scope(),
          now: _now,
          limit: 1,
        )).single;
        final registry = TransientCloudCanonicalIdentityRegistry();
        final adapter = ObjectBoxCanonicalSemanticEntityAdapter(
          store: db,
          identityResolver: registry,
          activeScopeProvider: () =>
              CloudCanonicalActiveScope(scope: _scope(), generation: 1),
          semanticApplyEnabled: true,
          allowChatUpserts: true,
        );
        final gateway = ObjectBoxCloudSemanticStoreGateway(
          store: db,
          canonicalAdapter: adapter,
          clock: () => _now,
        );
        final payload = _payload();
        final snapshot = CloudSemanticSnapshot(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: _logical,
          immutableContentDigest: 'I' * 43,
          etagHash: change.etagHash,
          encryptedRawRecordReference: change.encryptedPayloadReference,
        );
        final identityLease = registry.bind(
          CloudDecodedMutation.upsert(
            scope: _scope(),
            generation: 1,
            changeId: change.changeId,
            snapshot: snapshot,
            payload: payload,
          ),
        );
        try {
          await gateway.writeTransaction<void>(
            entry: entry,
            leaseFence: fence,
            action: (transaction) {
              expect(transaction.hasAppliedChange(change.changeId), isFalse);
              transaction.applyEntity(payload: payload, snapshot: snapshot);
              // Observe the real transactional writes before marking the inbox.
              expect(recordMap().id, originalMapId);
              expect(recordMap().etagHash, snapshot.etagHash);
              expect(
                recordMap().encryptedRawRecordRef,
                snapshot.encryptedRawRecordReference,
              );
              preserved(adopted: true);
              expect(db.box<CloudSemanticSnapshotEntity>().count(), 1);
              transaction.markChangeApplied(change.changeId);
            },
          );
        } finally {
          identityLease.release();
        }
        final owner = db.box<CloudSemanticSnapshotEntity>().getAll().single;
        ownershipId ??= owner.id;
        expect(owner.id, ownershipId);
        expect(
          owner.canonicalGuidHash,
          CloudCanonicalIdentityDigest.forCanonicalGuid(
            scope: _scope(),
            generation: 1,
            kind: CloudEntityKind.chat,
            logicalEntityKeyHash: _logical,
            canonicalGuid: _canonical,
          ),
        );
        expect(
          owner.canonicalGuidLookupHash,
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: _scope(),
            generation: 1,
            canonicalGuid: _canonical,
          ),
        );
        expect(owner.logicalEntityKeyHash, _logical);
        expect(db.box<CloudSemanticReplayEntity>().count(), pass + 1);
        expect(
          db.box<CloudInboxChangeEntity>().getAll().every(
            (row) => row.status == CloudInboxStatus.applied.index,
          ),
          isTrue,
        );
        expect(
          db
              .box<CloudSyncCheckpointEntity>()
              .getAll()
              .singleWhere((row) => row.zone == 'chatManateeZone')
              .appliedSequence,
          pass + 1,
        );
        expect(
          await sync.readEligibleInbox(_scope(), now: _now, limit: 1),
          isEmpty,
        );
        expect(
          sync.readOutboundChatCreateForLocalRow(_scope(), chatId)!.operationId,
          operation.operationId,
        );
        // Duplicate fetched replay is suppressed by the real journal, including
        // after restart. It cannot create another canonical or ownership row.
        final after = await sync.readCheckpoint(_scope());
        await sync.journalFetchedBatch(
          CloudFetchBatch(
            scope: _scope(),
            changes: [change],
            batchId: 'synthetic-duplicate-$pass',
            generation: after.generation,
            nextToken: 'synthetic-duplicate-token-$pass',
            hasMore: false,
          ),
          now: _now,
          leaseFence: fence,
          expectedGeneration: after.generation,
          expectedFetchedToken: after.fetchedToken,
        );
        expect(
          await sync.readEligibleInbox(_scope(), now: _now, limit: 1),
          isEmpty,
        );
        expect(db.box<CloudSemanticSnapshotEntity>().count(), 1);
        expect(db.box<CloudOutboxOperationEntity>().count(), 1);
        expect(db.box<CloudRecordMapEntity>().count(), 1);
        preserved(adopted: true);
        await sync.releaseCoordinatorLease(_scope(), leaseFence: fence);
      }
      await restart();
      preserved(adopted: true);
      expect(
        db.box<CloudSemanticSnapshotEntity>().getAll().single.id,
        ownershipId,
      );
      expect(db.box<CloudSemanticReplayEntity>().count(), 2);
    },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('synthetic-chat-origin-');
    db = await openStore(directory: directory.path);
    bindStore();
    for (final zone in [
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      await sync.recordPullSuccess(_scope(zone), now: _now);
    }
    final handle = Handle(
      address: _recipient,
      service: 'iMessage',
      uniqueAddressAndService: '$_recipient/iMessage',
    );
    db.box<Handle>().put(handle);
    final chat = Chat(
      guid: _guid,
      chatIdentifier: _recipient,
      usingHandle: 'mailto:$_sender',
      style: 45,
      participants: [handle],
    )..handles.add(handle);
    chatId = db.box<Chat>().put(chat);
    messageId = db.box<Message>().put(
      Message(
        guid: 'synthetic-message-guid',
        text: 'synthetic body survives adoption',
        dateCreated: _now,
        isFromMe: true,
      )..chat.target = chat,
    );
  });
  tearDown(() async {
    db.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'real admission and canonical adoption preserve the same Chat row and Message body',
    () {
      final operation = admit();
      expect(outbox().localChatOrigin, isNotNull);
      expect(outbox().localChatOrigin, isNot(contains(_guid)));
      expect(outbox().localChatOrigin, isNot(contains(_recipient)));
      expect(operation.protectedLeaseReference, _lease);
      preserved();
      submitted();
      expect(outbox().attemptCount, 0);
      project();
      preserved(adopted: true);
      expect(db.box<Chat>().get(chatId)!.cloudGuid, _guid);
      expect(db.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    },
  );

  test(
    'projection replay and real store restart never allocate a second Chat or outbox row',
    () async {
      final operation = admit();
      submitted();
      project();
      project();
      await restart();
      project();
      preserved(adopted: true);
      expect(db.box<CloudOutboxOperationEntity>().count(), 1);
      expect(
        sync.readOutboundChatCreateForLocalRow(_scope(), chatId)!.operationId,
        operation.operationId,
      );
    },
  );

  test(
    'pending never-submitted origin cannot adopt an authenticated remote Chat',
    () {
      admit();
      final map = recordMap()
        ..etagHash = 'E' * 43
        ..encryptedRawRecordRef = 'obcs2.ref.${'R' * 43}';
      db.box<CloudRecordMapEntity>().put(map);
      expect(
        () => project(),
        _failure('cloud_sync_outbound_chat_origin_not_submitted'),
      );
      preserved();
      expect(db.box<CloudSemanticChatAliasEntity>().count(), 0);
    },
  );

  for (final missing in ['both', 'request', 'operation']) {
    test(
      'leased origin without $missing submission UUIDs cannot adopt local Chat',
      () {
        admit();
        submitted();
        final row = outbox()..state = CloudOutboxStatus.leased.index;
        if (missing != 'operation') row.appleRequestUuid = null;
        if (missing != 'request') row.appleOperationUuid = null;
        db.box<CloudOutboxOperationEntity>().put(row);
        expect(outbox().attemptCount, 0);
        expect(
          () => project(),
          _failure('cloud_sync_outbound_chat_origin_not_submitted'),
        );
        preserved();
        expect(db.box<CloudSemanticChatAliasEntity>().count(), 0);
        expect(db.box<CloudSemanticSnapshotEntity>().count(), 0);
      },
    );
  }

  for (final field in ['request', 'operation']) {
    for (final invalid in [
      'malformed-uuid',
      'BBBBBBBB-BBBB-1BBB-8BBB-BBBBBBBBBBBB',
      'BBBBBBBB-BBBB-4BBB-7BBB-BBBBBBBBBBBB',
    ]) {
      test(
        'invalid $field submission UUID ($invalid) cannot adopt local Chat',
        () {
          admit();
          submitted();
          final row = outbox();
          if (field == 'request') {
            row.appleRequestUuid = invalid;
          } else {
            row.appleOperationUuid = invalid;
          }
          db.box<CloudOutboxOperationEntity>().put(row);
          expect(
            () => project(),
            _failure('cloud_sync_outbound_chat_origin_not_submitted'),
          );
          preserved();
          expect(db.box<CloudSemanticChatAliasEntity>().count(), 0);
          expect(db.box<CloudSemanticSnapshotEntity>().count(), 0);
        },
      );
    }
  }

  test(
    'negative attempt count cannot adopt local Chat with valid submission UUIDs',
    () {
      admit();
      submitted();
      db.box<CloudOutboxOperationEntity>().put(outbox()..attemptCount = -1);
      expect(
        () => project(),
        _failure('cloud_sync_outbound_chat_origin_not_submitted'),
      );
      preserved();
      expect(db.box<CloudSemanticChatAliasEntity>().count(), 0);
      expect(db.box<CloudSemanticSnapshotEntity>().count(), 0);
    },
  );

  test(
    'confirmed receipt remains adoptable after protected lease-reference cleanup and restart',
    () async {
      final operation = admit();
      submitted(confirmed: true, cleanup: true);
      await restart();
      expect(outbox().protectedLeaseReference, isNull);
      expect(
        sync.readOutboundChatCreateForLocalRow(_scope(), chatId)!.operationId,
        operation.operationId,
      );
      project();
      preserved(adopted: true);
    },
  );

  for (final kind in [
    'record',
    'group',
    'originalGroup',
    'recipient',
    'sender',
    'origin',
    'generation',
  ]) {
    test('rejects wrong $kind without mutating the local Chat or Message', () {
      admit();
      submitted();
      var payload = _payload();
      var generation = 1;
      switch (kind) {
        case 'record':
          db.box<CloudRecordMapEntity>().put(
            recordMap()..serverRecordIdHash = 'T' * 43,
          );
        case 'group':
          payload = _payload(group: 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD');
        case 'originalGroup':
          payload = _payload(
            originalGroup: 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD',
          );
        case 'recipient':
          payload = _payload(participant: 'other@example.invalid');
        case 'sender':
          payload = _payload(sender: 'other-sender@example.invalid');
        case 'origin':
          final origin = outbox().localChatOrigin!;
          db.box<CloudOutboxOperationEntity>().put(
            outbox()
              ..localChatOrigin = origin.replaceFirst(
                RegExp(r'[0-9a-f]{64}'),
                '0' * 64,
              ),
          );
        case 'generation':
          generation = 2;
      }
      expect(
        () => project(payload: payload, generation: generation),
        _failure(
          kind == 'record'
              ? 'cloud_sync_outbound_chat_origin_record_changed'
              : kind == 'generation'
              ? 'cloud_sync_outbound_chat_origin_scope_changed'
              : 'cloud_sync_outbound_chat_origin_payload_changed',
        ),
      );
      preserved();
      expect(db.box<CloudSemanticChatAliasEntity>().count(), 0);
    });
  }

  test(
    'admission rejects an origin changed after staging and rolls back the entire adoption',
    () {
      final origin = sync.captureFreshOutboundChatOrigin(_scope(), chatId);
      db.box<Chat>().put(
        db.box<Chat>().get(chatId)!
          ..usingHandle = 'mailto:changed@example.invalid',
      );
      expect(
        () => sync.admitProtectedOutboundChatCreate(
          draft: CloudOutboxDraft(
            scope: _scope(),
            logicalEntityKeyHash: _logical,
            action: CloudOutboxAction.save,
            payloadVersion: 1,
            dependencyOperationIds: const {},
            createdAt: _now,
            encryptedPayloadReference: _ref,
            payloadSha256: 'b' * 64,
            serverRecordIdHash: _record,
            protectedLeaseReference: _lease,
          ),
          recordMapping: CloudRecordMapEntry(
            scope: _scope(),
            logicalEntityKeyHash: _logical,
            serverRecordIdHash: _record,
            encryptedServerRecordId: _ref,
            updatedAt: _now,
          ),
          origin: origin,
        ),
        _failure('cloud_sync_outbound_chat_origin_changed'),
      );
      expect(db.box<CloudOutboxOperationEntity>().count(), 0);
      expect(db.box<CloudRecordMapEntity>().count(), 0);
      preserved();
    },
  );

  test(
    'null-origin legacy row does not invent local-origin evidence or rekey a provisional Chat',
    () {
      admit();
      submitted();
      db.box<CloudOutboxOperationEntity>().put(
        outbox()..localChatOrigin = null,
      );
      expect(
        resolveCloudSyncOutboundChatOrigin(
          store: db,
          scope: _scope(),
          generation: 1,
          payload: _payload(),
          snapshot: _snapshot(),
          canonicalChat: null,
        ),
        isNull,
      );
      expect(() => project(), _failure('canonical_chat_alias_conflict'));
      preserved();
      // Existing canonical legacy Chats still follow the normal projection path.
      db.box<Chat>().put(db.box<Chat>().get(chatId)!..guid = _canonical);
      _persistOwnership(db, 1);
      project();
      preserved(adopted: true);
      expect(outbox().localChatOrigin, isNull);
    },
  );

  test(
    'fresh send drift during Chat staging rolls back Chat admission',
    () async {
      final transport = _Staging();
      final native = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'synthetic-session',
        accountFingerprint: 'A' * 43,
        protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
        cloudMessagesClient: Object(),
      );
      var checks = 0;
      final coordinator = CloudSyncOutboundChatAdmissionCoordinator(
        store: sync,
        transport: transport,
        ensureProtectedStoreRecovered: () async {},
      );
      await expectLater(
        coordinator.admitChat(
          _scope(),
          chatId: chatId,
          createdAt: _now,
          authFence: CloudSyncLocalSendAuthFence(
            expected: native,
            capture: () async => native,
            stillCurrent: () => true,
          ),
          encode: (_) => _FakeChat(),
          validateLocalOrigin: () {
            if (++checks == 2) throw StateError('synthetic_send_changed');
          },
        ),
        throwsStateError,
      );
      expect(checks, 2);
      expect(transport.stages, 1);
      expect(transport.rollbacks, 1);
      expect(transport.commits, 0);
      expect(db.box<CloudOutboxOperationEntity>().count(), 0);
      preserved();
    },
  );

  test(
    'coordinator retry after commit uncertainty and restart recovers without restaging',
    () async {
      final transport = _Staging()..failCommit = true;
      final native = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'synthetic-session',
        accountFingerprint: 'A' * 43,
        protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
        cloudMessagesClient: Object(),
      );
      final fence = CloudSyncLocalSendAuthFence(
        expected: native,
        capture: () async => native,
        stillCurrent: () => true,
      );
      var recoveryCount = 0;
      CloudSyncOutboundChatAdmissionCoordinator coordinator() =>
          CloudSyncOutboundChatAdmissionCoordinator(
            store: sync,
            transport: transport,
            ensureProtectedStoreRecovered: () async {
              recoveryCount++;
            },
          );
      Future<CloudOutboxOperation> run() => coordinator().admitChat(
        _scope(),
        chatId: chatId,
        createdAt: _now,
        authFence: fence,
        encode: (_) => _FakeChat(),
      );
      await expectLater(run(), throwsStateError);
      final original = outbox();
      expect(original.localChatOrigin, isNotNull);
      expect(transport.rollbacks, 0);
      await restart();
      transport.failCommit = false;
      final recovered = await run();
      expect(recovered.operationId, original.operationId);
      expect(recovered.encryptedPayloadReference, _ref);
      expect(transport.stages, 1);
      expect(transport.commits, 1);
      expect(recoveryCount, 2);
      expect(db.box<CloudOutboxOperationEntity>().count(), 1);
      preserved();
    },
  );
}

Matcher _failure(String code) => throwsA(
  isA<CloudSyncFailure>().having((e) => e.safeCode, 'safeCode', code),
);

CloudChatEntityPayload _payload({
  String group = _guid,
  String originalGroup = _guid,
  String participant = _recipient,
  String sender = _sender,
}) => CloudChatEntityPayload(
  logicalEntityKeyHash: _logical,
  canonicalGuid: _canonical,
  chatIdentifier: _recipient,
  groupId: group,
  originalGroupId: originalGroup,
  displayName: null,
  participantHandles: ['mailto:$participant'],
  aliases: [
    CloudSemanticChatAlias(
      kind: CloudSemanticChatAliasKind.serviceIdentifier,
      keyHash: 'I' * 43,
    ),
  ],
  service: CloudSemanticService.iMessage,
  style: CloudSemanticChatStyle.direct,
  lastAddressedHandleState: CloudSemanticFieldState.value,
  lastAddressedHandle: 'mailto:$sender',
);
CloudSemanticSnapshot _snapshot() => CloudSemanticSnapshot(
  kind: CloudEntityKind.chat,
  logicalEntityKeyHash: _logical,
  immutableContentDigest: 'fixture-digest',
  etagHash: 'E' * 43,
  encryptedRawRecordReference: 'obcs2.ref.${'R' * 43}',
);

void _persistOwnership(Store db, int generation) {
  final scope = _scope();
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final box = db.box<CloudSemanticSnapshotEntity>();
  final existing = box.getAll();
  box.put(
    CloudSemanticSnapshotEntity(
      id: existing.isEmpty ? 0 : existing.single.id,
      snapshotKey: 'synthetic-origin-owner:$generation',
      scopeGenerationKey:
          'semantic-generation4:${sha256.convert(utf8.encode('$scopeKey\u001f$generation'))}',
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      entityKind: CloudEntityKind.chat.name,
      logicalEntityKeyHash: _logical,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: _logical,
        canonicalGuid: _canonical,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: generation,
            canonicalGuid: _canonical,
          ),
      updatedAtMs: _now.millisecondsSinceEpoch,
    ),
  );
}

final class _Resolver implements CloudCanonicalIdentityResolver {
  @override
  String? resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) =>
      scope == _scope() &&
          kind == CloudEntityKind.chat &&
          logicalEntityKeyHash == _logical
      ? _canonical
      : null;
  @override
  CloudCanonicalIdentityOwner? resolveCanonicalIdentityOwner({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) => canonicalGuid == _canonical
      ? CloudCanonicalIdentityOwner(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: _logical,
        )
      : null;
}

final class _Protector implements CloudSyncProtector {
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async =>
      'A' * 43;
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'fixture:$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async => ciphertext.substring('fixture:'.length);
}

// Native Message serialization is an edge fake; journal and admission remain real.
final class _CombinedMessage implements api.CloudMessage {
  _CombinedMessage(Message message)
    : guid = message.guid!,
      chatId = message.chat.target!.guid,
      destinationCallerId = message.chat.target!.usingHandle!.replaceFirst(
        'mailto:',
        '',
      );
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

final class _CombinedStaging extends _Staging {
  int messageStages = 0;
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required api.CloudMessage message,
  }) async {
    messageStages++;
    expect(message.chatId, _canonical);
    return CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: 'M' * 43,
      protectedEnvelopeReference: 'obcs2.ref.${'Q' * 43}',
      payloadSha256: 'd' * 64,
      serverRecordIdHash: 'T' * 43,
      leaseReference: 'obcs2.lease.${'b' * 32}',
    );
  }

  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) async {
    commits++;
  }
}

final class _FakeChat implements api.CloudChat {
  @override
  String get guid => _canonical;
  @override
  String get chatIdentifier => _recipient;
  @override
  String get groupId => _guid;
  @override
  String get originalGroupId => _guid;
  @override
  String get lastAddressedHandle => _sender;
  @override
  String get serviceName => 'iMessage';
  @override
  int get style => 45;
  @override
  List<api.CloudParticipant> get participants => [
    api.CloudParticipant(uri: _recipient),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Staging implements CloudSyncOutboundChatStagingTransport {
  int stages = 0, commits = 0, rollbacks = 0;
  bool failCommit = false;
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundChat(
    CloudSyncScope scope, {
    required api.CloudChat chat,
  }) async {
    stages++;
    return CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: _logical,
      protectedEnvelopeReference: _ref,
      payloadSha256: 'b' * 64,
      serverRecordIdHash: _record,
      leaseReference: _lease,
    );
  }

  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundMessage(
    CloudSyncScope scope, {
    required api.CloudMessage message,
  }) => throw StateError('message staging forbidden');
  @override
  Future<void> commitOutboundLease(
    String leaseReference,
    String protectedEnvelopeReference,
  ) async {
    expect(leaseReference, _lease);
    expect(protectedEnvelopeReference, _ref);
    commits++;
    if (failCommit) throw StateError('synthetic commit uncertainty');
  }

  @override
  Future<void> rollbackOutboundLease(String leaseReference) async {
    rollbacks++;
  }
}
