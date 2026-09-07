import 'dart:io';
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_create_queue_drain.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_identity_evidence.dart';
import 'package:bluebubbles/src/rust/api/cloud_sync_chat_identity.dart' as identity_api;
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

class _UnexpectedTombstoneDecoder implements CloudSemanticDecoder {
  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async =>
      throw StateError('read-only tombstones must not decode an identity');
}
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
      db.box<CloudOutboxOperationEntity>().getAll()
          .where((row) => !row.operationId.startsWith('settled-')).single;
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

  Future<void> retainHistory(String zone, {bool tombstone = false, String? record}) async {
    final scope = _scope(zone);
    final checkpoint = await sync.readCheckpoint(scope);
    final fence = (await sync.tryAcquireCoordinatorLease(scope,
      ownerId: 'synthetic-retained-history', now: _now,
      leaseDuration: const Duration(minutes: 1)))!;
    await sync.journalFetchedBatch(CloudFetchBatch(
      scope: scope,
      changes: [CloudFetchedChange(
        changeId: 'U' * 43, recordIdHash: record ?? 'V' * 43,
        etagHash: tombstone ? null : 'E' * 43,
        type: tombstone ? CloudChangeType.delete : CloudChangeType.save,
        isTombstone: tombstone,
        encryptedServerRecordId: 'obcs2.ref.${'U' * 43}',
        protectedSystemFieldsReference: 'obcs2.ref.${'F' * 43}',
        encryptedPayloadReference: tombstone ? null : 'obcs2.ref.${'R' * 43}',
        payloadSha256: tombstone ? null : 'c' * 64,
      )],
      batchId: 'synthetic-history-$zone', generation: checkpoint.generation,
      nextToken: 'synthetic-history-token-$zone', hasMore: false,
    ), now: _now, leaseFence: fence, expectedGeneration: checkpoint.generation,
      expectedFetchedToken: checkpoint.fetchedToken);
    await sync.markInboxRetainedUnprojected(scope,
      sequence: checkpoint.fetchedSequence + 1,
      category: tombstone ? null : CloudFailureCategory.malformedRecord,
      now: _now, maximumDeferredAttempts: 8,
      maximumDeferredAge: const Duration(days: 3), leaseFence: fence);
    await sync.releaseCoordinatorLease(scope, leaseFence: fence);
  }

  for (final messageTombstone in [false, true]) {
    test(
      'native-confirmed Chat dependency rejects unrelated terminal retained '
      'attachment save and Message ${messageTombstone ? "tombstone" : "save"} '
      'before staging',
      () async {
        // Characterize the current global Chat gate, not a safe exemption.
        // Native confirmation/auth and transport are synthetic edges; journal,
        // retained-page transitions, origin capture and admission are real.
        final writerScope = CloudKitWriterScope(accountFingerprint: 'A' * 43);
        final authority = ObjectBoxCloudKitWriterAuthority.forTest(
          store: db,
          buildDecision: CloudKitWriterOwnership.resolve('v2'),
        );
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
        final journal = CloudSyncLocalSendJournal(
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
        final auth = CloudSyncNativeAuthSnapshot.fromNative(
          nativeSessionId: 'synthetic-retained-chat-session',
          accountFingerprint: 'A' * 43,
          protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
          cloudMessagesClient: Object(),
        );
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
        expect(journal.readReady(), isEmpty);
        final intentId = journal.recordNativeSendConfirmation(
          stableGuid: messageGuid,
          succeeded: true,
          capturedAuth: auth,
          stillCurrent: () => true,
          now: _now,
        )!;
        expect(db.box<CloudSyncLocalSendIntentEntity>().get(intentId)!.state, 3);
        journal.promoteIdsConfirmedDeferred(
          intentId: intentId,
          currentAuth: auth,
          now: _now,
        );
        expect(journal.readReady().single.id, intentId);
        final source = journal.readForAdmission(intentId);
        expect(source.admittedOperationId, isNull);
        expect(source.message!.guid, messageGuid);
        expect(source.message!.chat.target!.guid, _guid);
        // Without history debt this exact provisional Chat passes capture.
        expect(
          sync.captureFreshOutboundChatOrigin(_scope(), chatId).canonicalGuid,
          _canonical,
        );

        for (final zone in ['attachmentManateeZone', 'messageManateeZone']) {
          final sibling = _scope(zone);
          final checkpoint = await sync.readCheckpoint(sibling);
          final fence = (await sync.tryAcquireCoordinatorLease(
            sibling,
            ownerId: 'synthetic-retained-chat-history',
            now: _now,
            leaseDuration: const Duration(minutes: 1),
          ))!;
          final tombstone = messageTombstone && zone == 'messageManateeZone';
          await sync.journalFetchedBatch(
            CloudFetchBatch(
              scope: sibling,
              changes: [
                CloudFetchedChange(
                  changeId: 'C' * 43,
                  recordIdHash: 'U' * 43,
                  etagHash: tombstone ? null : 'E' * 43,
                  type: tombstone ? CloudChangeType.delete : CloudChangeType.save,
                  isTombstone: tombstone,
                  encryptedServerRecordId: 'obcs2.ref.${'U' * 43}',
                  protectedSystemFieldsReference: 'obcs2.ref.${'F' * 43}',
                  encryptedPayloadReference:
                      tombstone ? null : 'obcs2.ref.${'R' * 43}',
                  payloadSha256: tombstone ? null : 'c' * 64,
                ),
              ],
              batchId: 'synthetic-retained-$zone',
              generation: checkpoint.generation,
              nextToken: 'synthetic-retained-token-$zone',
              hasMore: false,
            ),
            now: _now,
            leaseFence: fence,
            expectedGeneration: checkpoint.generation,
            expectedFetchedToken: checkpoint.fetchedToken,
          );
          await sync.markInboxRetainedUnprojected(
            sibling,
            sequence: 1,
            category: tombstone ? null : CloudFailureCategory.malformedRecord,
            now: _now,
            maximumDeferredAttempts: 8,
            maximumDeferredAge: const Duration(days: 3),
            leaseFence: fence,
          );
          await sync.releaseCoordinatorLease(sibling, leaseFence: fence);
          final terminal = await sync.readCheckpoint(sibling);
          expect(terminal.pendingBatchId, isNull);
          expect(terminal.hasUnmarkedPendingInbox, isFalse);
          expect(terminal.fetchedToken, 'synthetic-retained-token-$zone');
          expect(terminal.lastAppliedSequence, 0);
        }
        final safeCode = messageTombstone
            ? 'messages_cloud_tombstone_projection_unavailable'
            : 'messages_cloud_account_projection_incomplete';
        expect(
          () => sync.captureFreshOutboundChatOrigin(_scope(), chatId),
          _failure(safeCode),
        );
        final transport = _Staging();
        var originChecks = 0;
        var encodes = 0;
        await expectLater(
          CloudSyncOutboundChatAdmissionCoordinator(
            store: sync,
            transport: transport,
            ensureProtectedStoreRecovered: () async {},
          ).admitChat(
            _scope(),
            chatId: chatId,
            createdAt: source.createdAtUtc,
            authFence: CloudSyncLocalSendAuthFence(
              expected: auth,
              capture: () async => auth,
              stillCurrent: () => true,
            ),
            validateLocalOrigin: () {
              originChecks++;
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
            encode: (_) {
              encodes++;
              return _FakeChat();
            },
          ),
          _failure(safeCode),
        );
        expect(originChecks, 1);
        expect(encodes, 0);
        expect(transport.stages, 0);
        expect(transport.commits, 0);
        expect(transport.rollbacks, 0);
        expect(db.box<CloudOutboxOperationEntity>().count(), 0);
        expect(db.box<CloudRecordMapEntity>().count(), 0);
        expect(journal.readReady().single.id, intentId);
        expect(journal.readForAdmission(intentId).admittedOperationId, isNull);
        final retained = db.box<CloudInboxChangeEntity>().getAll();
        expect(retained, hasLength(2));
        expect(
          retained.every(
            (row) => row.status == CloudInboxStatus.retainedUnprojected.index,
          ),
          isTrue,
        );
        expect(
          retained.where((row) => row.isTombstone),
          hasLength(messageTombstone ? 1 : 0),
        );
        preserved();
      },
    );
  }

  for (final mutation in [
    'none',
    'shared Chat',
    'unrelated history',
    'engine success',
    'engine retained tombstone success',
    'engine source during preflight',
    'engine tombstone during preflight',
    'engine retained save during preflight',
    'engine preflight retry retirement',
    'engine preflight pause retirement',
    'engine preflight quarantine retirement',
    'retire deleted',
    'retire missing',
    'retire edited',
    'retire expired lease',
    'retire diagnostic',
    'retire unknown',
    'retire attempted',
    'retire submitted UUID',
    'retire live source',
    'retire large settled history',
    'submitted cancellation forbidden',
    'retained Chat save',
    'retained Chat tombstone',
    'retained Chat reader tombstone',
    'retained Chat restart reader tombstone',
    'retained Chat conflict tombstone',
    'retained Chat unknown tombstone',
    'retained Chat preflight tombstone',
    'retained Chat code tombstone',
    'retained Chat invalid type tombstone',
    'retained Chat pending tombstone',
    'retained Chat gap tombstone',
    'retained Chat foreign tombstone',
    'retained Chat generation tombstone',
    'duplicate before stage',
    'prior snapshot before stage',
    'prior generation before stage',
    'prior map during stage',
    'source during stage',
    'tombstone during stage',
    'proof before lease',
    'observed history success',
    'observed history restart',
    'observed history stale before lease',
    'observed history revoked before lease',
    'observed history stale before submit',
    'observed history missing before submit',
    'observed history source during stage',
    'missing journal before lease',
    'missing journal before submit',
    'source before lease',
    'retained save before lease',
    'payload before submit',
    'tombstone before submit',
    'duplicate before submit',
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
        final observedHistory = mutation.startsWith('observed history');
        CloudSyncChatIdentityEvidence? identityEvidence;
        var currentBinding = true;
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
            readChatIdentityEvidence: observedHistory ? (_) => identityEvidence : null,
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
          stillCurrent: () => currentBinding,
        );
        final transport = _CombinedStaging();
        CloudSyncProtectedOutboundStageData? observedStage;
        Future<CloudSyncChatIdentityEvidence?> observeIdentity(
          CloudSyncOutboundChatOrigin origin,
          CloudSyncProtectedOutboundStageData stage,
        ) async {
          observedStage = stage;
          identityEvidence = await CloudSyncChatIdentityEvidence.observe(
            store: db, origin: origin, stage: stage,
            auth: expected, authFence: fence,
            observer: (readSet, retained, actualStage, actualOrigin) async {
              expect(identical(actualStage, stage), isTrue);
              expect(actualOrigin.binding(readSet.generation), origin.binding(readSet.generation));
              if (mutation == 'observed history source during stage') {
                final row = db.box<CloudInboxChangeEntity>().getAll()
                    .singleWhere((r) => r.zone == 'chatManateeZone');
                db.box<CloudInboxChangeEntity>().put(row..etagHash = 'Z' * 43);
              }
              // Only the native PCS edge is synthetic. All ObjectBox gates,
              // journal capabilities, restarts and transaction rollback are real.
              return identity_api.CloudSyncChatIdentityResult(
                comparison: identity_api.CloudSyncChatIdentityComparison.disjoint,
                candidateBindingHash: 'I' * 43,
                stagedCandidateBindingHash: 'J' * 43,
                sourceBindingHash: retained.changeIdHash,
                nativeSessionId: expected.nativeSessionId,
              );
            },
          );
          return identityEvidence;
        }
        var source = journal.readForAdmission(intentId);
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
        final unrelatedHistory = !mutation.startsWith('missing journal') &&
            (mutation == 'unrelated history' ||
            mutation.startsWith('engine') ||
            mutation.contains('before') || mutation.contains('during'));
        if (unrelatedHistory) {
          await retainHistory('attachmentManateeZone');
          await retainHistory('messageManateeZone', tombstone: true);
        }
        if (observedHistory) await retainHistory('chatManateeZone');
        const independentChatHistory = {
          'retained Chat tombstone',
          'retained Chat reader tombstone',
          'retained Chat restart reader tombstone',
        };
        if (mutation == 'engine retained tombstone success') {
          await retainHistory('chatManateeZone', tombstone: true);
        }
        if (mutation.startsWith('retained Chat')) {
          if (mutation.contains('reader')) {
            // Exercise the installed reader policy, not a hand-marked inbox
            // row. A completed fetch can retain a tombstone indefinitely.
            final remote = FakeCloudSyncTransport()..enqueueFetchBatch(
              CloudFetchBatch(
                scope: _scope(), generation: 1,
                batchId: 'synthetic-read-only-chat-deletion',
                nextToken: 'synthetic-terminal-chat-token', hasMore: false,
                changes: [CloudFetchedChange(
                  changeId: 'U' * 43, recordIdHash: 'V' * 43,
                  type: CloudChangeType.delete, isTombstone: true,
                  encryptedServerRecordId: 'obcs2.ref.${'U' * 43}',
                  protectedSystemFieldsReference: 'obcs2.ref.${'F' * 43}',
                )],
              ),
            );
            final registry = TransientCloudCanonicalIdentityRegistry();
            final reader = CloudSyncEngine(
              scope: _scope(), coordinatorId: 'synthetic-read-write-boundary',
              store: sync, transport: remote, clock: () => _now,
              inboxApplier: TransactionalCloudInboxApplier(
                decoder: _UnexpectedTombstoneDecoder(),
                identityRegistrar: registry,
                store: ObjectBoxCloudSemanticStoreGateway(
                  store: db, clock: () => _now,
                  canonicalAdapter: ObjectBoxCanonicalSemanticEntityAdapter(
                    store: db, identityResolver: registry,
                    activeScopeProvider: () => CloudCanonicalActiveScope(
                      scope: _scope(), generation: 1),
                    semanticApplyEnabled: true, allowChatUpserts: true,
                  ),
                ),
              ),
              config: CloudSyncEngineConfig(
                maximumFetchPagesPerRun: 1,
                flags: const CloudSyncFeatureFlags(semanticApply: true),
              ),
            );
            final first = await reader.synchronize(trigger: CloudSyncTrigger.manual);
            expect(first.status, CloudSyncRunStatus.degraded);
            expect(first.failureSafeCode, 'retained_projection_incomplete');
            expect(first.counters.tombstoneReadOnlyAcknowledged, 1);
            final second = await reader.synchronize(trigger: CloudSyncTrigger.manual);
            expect(second.status, CloudSyncRunStatus.degraded);
            expect(second.failureSafeCode, 'retained_projection_incomplete');
            expect(second.counters.fetched, 0);
            expect(second.counters.tombstoneReadOnlyAcknowledged, 0);
            expect(remote.consumePreparedSubmissionCallCount, 0);
            if (mutation.contains('restart')) {
              await restart();
              bindJournal();
              source = journal.readForAdmission(intentId);
            }
            final checkpoint = await sync.readCheckpoint(_scope());
            expect(checkpoint.fetchedSequence, 1);
            expect(checkpoint.lastAppliedSequence, 0);
            expect(checkpoint.fetchedToken, 'synthetic-terminal-chat-token');
            expect(checkpoint.pendingBatchId, isNull);
            expect(db.box<CloudInboxChangeEntity>().getAll().single.status,
                CloudInboxStatus.retainedUnprojected.index);
            preserved();
          } else {
            await retainHistory('chatManateeZone', tombstone: mutation.endsWith('tombstone'));
          }
          if (mutation.endsWith('tombstone') &&
              !independentChatHistory.contains(mutation)) {
            final row = db.box<CloudInboxChangeEntity>().getAll().single;
            switch (mutation) {
              case 'retained Chat conflict tombstone':
                row.failureCategory = CloudFailureCategory.conflict.name;
              case 'retained Chat unknown tombstone':
                row.failureCategory = CloudFailureCategory.unknown.name;
              case 'retained Chat preflight tombstone':
                row.preflightCategory = CloudFailureCategory.malformedRecord.name;
              case 'retained Chat code tombstone':
                row.preflightCode = 'synthetic_preflight_failure';
              case 'retained Chat invalid type tombstone':
                row.changeType = CloudChangeType.save.name;
              case 'retained Chat pending tombstone':
                row.status = CloudInboxStatus.pending.index;
              case 'retained Chat gap tombstone':
                row.fetchSequence = 2;
              case 'retained Chat foreign tombstone':
                row.accountFingerprint = 'B' * 43;
              case 'retained Chat generation tombstone':
                row.generation = 2;
            }
            db.box<CloudInboxChangeEntity>().put(row);
            await restart();
            bindJournal();
            source = journal.readForAdmission(intentId);
          }
        }
        void duplicateChat() {
          final duplicate = Chat(
            guid: 'EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE',
            usingHandle: 'mailto:$_sender', style: 45,
          )..handles.add(db.box<Chat>().get(chatId)!.handles.single);
          db.box<Chat>().put(duplicate);
        }
        if (mutation == 'duplicate before stage') duplicateChat();
        if (mutation == 'prior snapshot before stage' ||
            mutation == 'prior generation before stage') {
          _persistOwnership(db, 1);
          if (mutation == 'prior generation before stage') {
            final checkpoint = db.box<CloudSyncCheckpointEntity>().getAll()
                .singleWhere((row) => row.zone == 'chatManateeZone')..generation = 2;
            db.box<CloudSyncCheckpointEntity>().put(checkpoint);
          }
        }
        if (mutation == 'source during stage') {
          transport.onChatStage = () async {
            db.box<Message>().put(db.box<Message>().get(messageId)!..dateDeleted = _now);
          };
        }
        if (mutation == 'tombstone during stage') {
          transport.onChatStage = () => retainHistory('chatManateeZone',
              tombstone: true, record: _record);
        }
        if (mutation == 'prior map during stage') {
          transport.onChatStage = () => sync.upsertRecordMap(CloudRecordMapEntry(
            scope: _scope(), logicalEntityKeyHash: _logical,
            serverRecordIdHash: 'Z' * 43,
            encryptedServerRecordId: 'obcs2.ref.${'Z' * 43}',
            etagHash: 'E' * 43, updatedAt: _now,
          ), generation: 1);
        }
        Future<CloudOutboxOperation> admitChat() =>
            CloudSyncOutboundChatAdmissionCoordinator(
              store: sync, transport: transport,
              ensureProtectedStoreRecovered: () async {},
              observeChatIdentity: observedHistory ? observeIdentity : null,
            ).admitChat(_scope(), chatId: chatId,
              createdAt: source.createdAtUtc, authFence: fence,
              localSendSource: source, encode: (_) => _FakeChat());
        if ((mutation.startsWith('retained Chat') &&
                !independentChatHistory.contains(mutation)) ||
            mutation.endsWith('before stage') || mutation.contains('during stage')) {
          await expectLater(admitChat(),
            mutation.startsWith('retained Chat')
                ? _failure('messages_cloud_account_projection_incomplete')
                : throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())));
          final staged = mutation.contains('during stage') ? 1 : 0;
          expect(transport.stages, staged);
          expect(transport.rollbacks, staged);
          expect(transport.commits, 0);
          expect(db.box<CloudOutboxOperationEntity>().count(), 0);
          expect(db.box<CloudRecordMapEntity>().count(), mutation == 'prior map during stage' ? 1 : 0);
          if (mutation == 'prior map during stage') {
            expect(recordMap().serverRecordIdHash, 'Z' * 43);
          }
          expect(db.box<CloudSyncLocalSendIntentEntity>().get(intentId)!.state, 1);
          return;
        }
        final operation =
            await CloudSyncOutboundChatAdmissionCoordinator(
              store: sync,
              transport: transport,
              ensureProtectedStoreRecovered: () async {},
              observeChatIdentity: observedHistory ? observeIdentity : null,
            ).admitChat(
              _scope(),
              chatId: chatId,
              createdAt: mutation == 'shared Chat'
                  ? _now.subtract(const Duration(days: 1))
                  : _now,
              authFence: fence,
              localSendSource: source,
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
        // The journal proof survives a real Store reopen, not an in-memory
        // callback. Recovery returns the same envelope without staging again.
        if (mutation != 'shared Chat') {
          expect(jsonDecode(outbox().localChatOrigin!)[0], 2);
          await restart();
          bindJournal();
          selection = newSelection();
          expect((await admitChat()).operationId, operation.operationId);
          expect(transport.stages, 1);
        }
        await validateSelected();
        const submissionLease = 'synthetic-combined-submission';
        if (mutation.startsWith('retire ')) {
          final before = outbox();
          if (mutation == 'retire large settled history') {
            db.box<CloudOutboxOperationEntity>().putMany([
              for (var i = 0; i < 4097; i++) CloudOutboxOperationEntity(
                operationId: 'settled-$i', scopeKey: before.scopeKey,
                accountFingerprint: before.accountFingerprint, zone: before.zone,
                logicalEntityKeyHash: 'settled-$i', action: 0,
                payloadVersion: before.payloadVersion, mutationRevision: 1,
                checkpointGeneration: 1, state: CloudOutboxStatus.confirmed.index,
                confirmedAtMs: before.createdAtMs, createdAtMs: before.createdAtMs,
                updatedAtMs: before.createdAtMs, encryptedPayloadRef: before.encryptedPayloadRef,
                payloadSha256: before.payloadSha256, serverRecordIdHash: before.serverRecordIdHash,
              ),
            ]);
          }
          if (mutation == 'retire missing') {
            db.box<Message>().remove(messageId);
          } else if (mutation != 'retire live source') {
            final changed = db.box<Message>().get(messageId)!;
            if (mutation == 'retire edited') {
              changed.dateEdited = _now;
            } else {
              changed.dateDeleted = _now;
            }
            db.box<Message>().put(changed);
          }
          if (mutation == 'retire unknown') {
            db.box<CloudOutboxOperationEntity>().put(outbox()
              ..state = CloudOutboxStatus.unknownOutcome.index
              ..appleRequestUuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'
              ..appleOperationUuid = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC');
          }
          if (mutation == 'retire submitted UUID') {
            db.box<CloudOutboxOperationEntity>().put(outbox()
              ..appleRequestUuid = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB');
          }
          if (mutation == 'retire attempted') {
            db.box<CloudOutboxOperationEntity>().put(outbox()..attemptCount = 1
              ..localChatOrigin = cloudSyncSubmittedChatOrigin(before.localChatOrigin!));
          }
          if (mutation == 'retire expired lease') {
            db.box<CloudOutboxOperationEntity>().put(outbox()
              ..state = CloudOutboxStatus.leased.index
              ..leaseIdHash = 'synthetic-lease'
              ..leaseExpiresAtMs = _now.add(const Duration(minutes: 1)).millisecondsSinceEpoch);
            expect(sync.retireUnsubmittedChatCreates(_scope(), now: _now), 0);
            await sync.recoverExpiredOutboxLeases(_scope(),
              now: _now.add(const Duration(minutes: 2)));
          }
          final untouched = {'retire unknown', 'retire attempted',
            'retire submitted UUID', 'retire live source'}.contains(mutation);
          if (mutation == 'retire diagnostic') {
            expect(sync.retireUnsubmittedChatCreates(_scope(),
              now: _now, onlyIntentId: intentId + 1), 0);
          }
          expect(sync.retireUnsubmittedChatCreates(_scope(),
            now: _now.add(const Duration(minutes: 2)),
            onlyIntentId: mutation == 'retire diagnostic' ? intentId : null),
            untouched ? 0 : 1);
          if (untouched) {
            expect(cloudSyncIsRetiredUnsubmittedChatCreate(outbox()), isFalse);
            expect(ObjectBoxCloudSyncPreflightReader(store: db).read()
              .settledOutboxFingerprint, isNull);
            return;
          }
          if (mutation == 'retire diagnostic') {
            await expectLater(validateSelected(), throwsA(isA<StateError>()));
          }
          final retired = outbox();
          expect(retired.state, CloudOutboxStatus.quarantined.index);
          expect(retired.lastErrorCategory, CloudFailureCategory.cancelled.name);
          expect(retired.attemptCount, 0);
          expect(retired.appleRequestUuid, isNull);
          expect(retired.confirmedAtMs, 0);
          expect(retired.encryptedPayloadRef, before.encryptedPayloadRef);
          expect(retired.payloadSha256, before.payloadSha256);
          expect(jsonDecode(retired.localChatOrigin!)[0], 4);
          expect((jsonDecode(retired.localChatOrigin!) as List).skip(1),
            (jsonDecode(before.localChatOrigin!) as List).skip(1));
          expect(retired.protectedLeaseReference, before.protectedLeaseReference);
          expect(recordMap().serverRecordIdHash, before.serverRecordIdHash);
          expect(db.box<CloudSyncLocalSendIntentEntity>().get(intentId)!.state, 1);
          await restart();
          bindJournal();
          expect(sync.retireUnsubmittedChatCreates(_scope(), now: _now), 0);
          expect(await sync.readLiveProtectedOutboundLeaseReferences(maximumCount: 16),
            contains(before.protectedLeaseReference));
          expect((await sync.readLiveProtectedReferences(maximumCount: 10000))
            .references, contains(before.encryptedPayloadRef));
          expect(ObjectBoxCloudSyncPreflightReader(store: db).read()
            .settledOutboxFingerprint, isNotNull);
          if (mutation == 'retire large settled history') {
            // Settled history never occupies the cancellation candidate bound.
            expect(db.box<CloudOutboxOperationEntity>().count(), 4098);
            return;
          }
          var acknowledgements = 0;
          var submissions = 0;
          expect(await drainCloudSyncCreateQueues(
            scopes: [_scope(), _scope('messageManateeZone')],
            readOutbox: sync.readOutboxEntries,
            recoverExpired: (_) async {},
            reconcileUnknown: (_) async => fail('retirement is not remote reconciliation'),
            flush: (_) async { submissions++; },
            acknowledgeConfirmed: (_, __) async { acknowledgements++; },
            validateAccount: () async {},
            isRetiredUnsubmittedChatCreate: (op) async => sync.isRetiredUnsubmittedChatCreate(op),
          ), isTrue);
          expect(submissions, 0);
          expect(acknowledgements, 0);
          await expectLater(admitChat(), throwsA(isA<StateError>().having(
            (e) => e.message, 'code', 'cloud_sync_outbound_chat_source_retired')));
          expect(transport.stages, 1);
          // A malformed cancellation or unknown outcome cannot masquerade as
          // inert. Each mutation invalidates both queue and preflight proof.
          for (final mutate in <void Function(CloudOutboxOperationEntity)>[
            (r) => r.attemptCount = -1,
            (r) => r.appleRequestUuid = 'present',
            (r) => r.appleOperationUuid = 'present',
            (r) => r.leaseIdHash = 'present',
            (r) => r.confirmedAtMs = 1,
            (r) => r.state = CloudOutboxStatus.unknownOutcome.index,
            (r) => r.lastErrorCategory = CloudFailureCategory.unknown.name,
            (r) => r.localChatOrigin = 'malformed',
            (r) => r.protectedLeaseReference = null,
            (r) => r.accountFingerprint = 'malformed',
          ]) {
            final malformed = outbox();
            mutate(malformed);
            expect(cloudSyncIsRetiredUnsubmittedChatCreate(malformed), isFalse);
            expect(ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint([malformed]), isNull);
          }
          return;
        }
        if (mutation.startsWith('engine')) {
          final remote = FakeCloudSyncTransport();
          remote.writePreflightHandler = (scope, identity, operations) async {
            expect(operations.single.operationId, operation.operationId);
            if (mutation.startsWith('engine preflight')) {
              throw CloudSyncFailure(
                category: mutation.contains('retry') ? CloudFailureCategory.unknown :
                    mutation.contains('pause') ? CloudFailureCategory.dependency :
                    CloudFailureCategory.conflict,
                safeCode: 'synthetic_pre_submit_failure');
            }
            if (mutation == 'engine source during preflight') {
              db.box<Message>().put(db.box<Message>().get(messageId)!..dateDeleted = _now);
            }
            if (mutation == 'engine tombstone during preflight') {
              await retainHistory('chatManateeZone', tombstone: true, record: _record);
            }
            if (mutation == 'engine retained save during preflight') {
              await retainHistory('chatManateeZone');
            }
          };
          remote.preparedSubmissionHandler = (scope, prepared, identity) async {
            expect(outbox().state, CloudOutboxStatus.unknownOutcome.index);
            expect(outbox().appleRequestUuid, identity.requestUuid);
            expect(prepared.operationIds, [operation.operationId]);
            return CloudPushBatchResult(outcomes: [CloudPushOutcome(
              operationId: operation.operationId,
              disposition: CloudPushDisposition.confirmed,
              createReceipt: CloudOutboxCreateReceipt(
                operationId: operation.operationId,
                logicalEntityKeyHash: _logical, serverRecordIdHash: _record,
                etagHash: 'E' * 43,
              ),
            )]);
          };
          await CloudSyncEngine(
            scope: _scope(), coordinatorId: 'synthetic-chat-real-engine',
            store: sync, transport: remote, inboxApplier: FakeCloudInboxApplier(),
            writerAuthority: FakeCloudSyncWriterAuthority(),
            writerExclusion: FakeCloudKitOperationExclusion(), clock: () => _now,
            config: CloudSyncEngineConfig(
              maximumOutboxBatchesPerRun: 1,
              flags: const CloudSyncFeatureFlags(readOnlyFetch: false, saves: true),
            ),
          ).synchronize(trigger: CloudSyncTrigger.manual);
          expect(remote.prepareSubmissionCallCount, 1);
          expect(remote.consumePreparedSubmissionCallCount,
              mutation.endsWith('success') ? 1 : 0);
          if (mutation.endsWith('success')) {
            expect(outbox().state, CloudOutboxStatus.confirmed.index);
            expect(recordMap().etagHash, 'E' * 43);
          } else {
            expect(outbox().appleRequestUuid, isNull);
          }
          if (mutation.startsWith('engine preflight')) {
            expect(outbox().attemptCount, 1);
            expect(outbox().state, mutation.contains('retry') ? CloudOutboxStatus.pending.index :
                mutation.contains('pause') ? CloudOutboxStatus.paused.index :
                CloudOutboxStatus.quarantined.index);
            expect(jsonDecode(outbox().localChatOrigin!)[0], 2);
            expect(await sync.readLiveProtectedOutboundLeaseReferences(maximumCount: 16),
              contains(_lease));
            db.box<Message>().put(db.box<Message>().get(messageId)!..dateDeleted = _now);
            await restart();
            bindJournal();
            expect(sync.retireUnsubmittedChatCreates(_scope(), now: _now), 1);
            expect(outbox().attemptCount, 1); // never erase retry evidence
            expect(jsonDecode(outbox().localChatOrigin!)[0], 4);
            expect(ObjectBoxCloudSyncPreflightReader(store: db).read()
              .settledOutboxFingerprint, isNotNull);
            expect(await sync.readLiveProtectedOutboundLeaseReferences(maximumCount: 16),
              contains(_lease));
          }
          expect(db.box<CloudSyncLocalSendIntentEntity>().get(intentId)!.state, 1);
          expect(transport.stages, 1);
          expect(remote.fetchCallCount, 0);
          return;
        }
        if (mutation == 'proof before lease') {
          final proof = jsonDecode(outbox().localChatOrigin!) as List<dynamic>;
          proof[7] = jsonEncode([1, intentId, '0' * 64]);
          db.box<CloudOutboxOperationEntity>().put(outbox()..localChatOrigin = jsonEncode(proof));
        }
        if (mutation == 'source before lease') {
          db.box<Message>().put(db.box<Message>().get(messageId)!..dateDeleted = _now);
        }
        if (mutation == 'retained save before lease') {
          await retainHistory('chatManateeZone');
        }
        if (mutation == 'missing journal before lease') bindStore();
        Future<List<CloudOutboxOperation>> leaseChat() => sync.leaseEligibleOutbox(
          _scope(),
          now: _now,
          limit: 1,
          leaseId: submissionLease,
          leaseDuration: const Duration(minutes: 1),
          allowedActions: const {CloudOutboxAction.save},
        );
        if (observedHistory) {
          // Adoption changed the mutation revision. Its old evidence must not
          // lease the operation; restarting must not revive that evidence.
          if (mutation == 'observed history restart') {
            await restart();
            bindJournal();
          }
          await expectLater(leaseChat(), throwsStateError);
          expect(outbox().state, CloudOutboxStatus.pending.index);
          if (mutation != 'observed history stale before lease') {
            await observeIdentity(
              CloudSyncOutboundChatOrigin.capture(
                scope: _scope(), chat: db.box<Chat>().get(chatId)!),
              observedStage!,
            );
          }
          if (mutation == 'observed history revoked before lease') currentBinding = false;
        }
        if (mutation.endsWith('before lease')) {
          await expectLater(leaseChat(), mutation.startsWith('missing journal')
            ? throwsA(isA<StateError>().having((error) => error.message, 'code',
                'cloud_sync_local_send_chat_journal_missing'))
            : throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())));
          expect(outbox().state, CloudOutboxStatus.pending.index);
          expect(outbox().appleRequestUuid, isNull);
          return;
        }
        final leased = await leaseChat();
        expect(leased.single.operationId, operation.operationId);
        if (mutation == 'payload before submit') {
          db.box<CloudOutboxOperationEntity>().put(outbox()..payloadSha256 = 'e' * 64);
        }
        if (mutation == 'observed history stale before submit') {
          final row = db.box<CloudSyncCheckpointEntity>().getAll()
              .singleWhere((c) => c.zone == 'chatManateeZone');
          row.mutationRevisionCounter++;
          db.box<CloudSyncCheckpointEntity>().put(row);
        }
        if (mutation == 'observed history missing before submit') identityEvidence = null;
        if (mutation == 'duplicate before submit') duplicateChat();
        if (mutation == 'missing journal before submit') bindStore();
        if (mutation == 'tombstone before submit') {
          await retainHistory('chatManateeZone', tombstone: true, record: _record);
        }
        Future<List<CloudOutboxOperation>> startSubmit() => sync.markOutboxSubmissionStarted(
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
        if (mutation.endsWith('before submit')) {
          await expectLater(startSubmit(), mutation.startsWith('missing journal')
            ? throwsA(isA<StateError>().having((error) => error.message, 'code',
                'cloud_sync_local_send_chat_journal_missing'))
            : throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())));
          expect(outbox().state, CloudOutboxStatus.leased.index);
          expect(outbox().appleRequestUuid, isNull);
          return;
        }
        await startSubmit();
        if (mutation != 'shared Chat') expect(jsonDecode(outbox().localChatOrigin!)[0], 3);
        if (mutation == 'submitted cancellation forbidden') {
          // Even explicit retry permission after an unknown result cannot
          // restore the original never-submitted capability.
          await sync.applyOutboxTransitions(_scope(), leaseId: submissionLease,
            transitions: [CloudOutboxTransition.provenNotApplied(operation.operationId,
              category: CloudFailureCategory.unknown, nextEligibleAt: _now)], now: _now);
          expect(outbox().appleRequestUuid, isNull);
          expect(jsonDecode(outbox().localChatOrigin!)[0], 3);
          db.box<Message>().put(db.box<Message>().get(messageId)!..dateDeleted = _now);
          await restart();
          bindJournal();
          expect(sync.retireUnsubmittedChatCreates(_scope(), now: _now), 0);
          expect(outbox().state, CloudOutboxStatus.pending.index);
          expect(ObjectBoxCloudSyncPreflightReader(store: db).read()
            .settledOutboxFingerprint, isNull);
          return;
        }
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
        if (mutation.startsWith('retained Chat')) {
          // Fresh readback does not consume the earlier deletion or pretend
          // it was applied. Its record and the new Chat remain independent.
          final retained = db.box<CloudInboxChangeEntity>().getAll()
              .singleWhere((row) => row.isTombstone);
          expect(retained.serverRecordIdHash, 'V' * 43);
          expect(retained.status, CloudInboxStatus.retainedUnprojected.index);
          final checkpoint = await sync.readCheckpoint(_scope());
          expect(checkpoint.fetchedSequence, 2);
          expect(checkpoint.lastAppliedSequence, 0);
          expect(checkpoint.pendingBatchId, isNull);
          expect(checkpoint.fetchedToken, 'synthetic-combined-token');
        }
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
        if (mutation != 'none' && mutation != 'shared Chat' && mutation != 'unrelated history' &&
            !independentChatHistory.contains(mutation) && !observedHistory) {
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
          if (unrelatedHistory) {
            expect(db.box<CloudInboxChangeEntity>().getAll().where((row) =>
              row.status == CloudInboxStatus.retainedUnprojected.index), hasLength(2));
          }
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
    const api.CloudParticipant(uri: _recipient),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Staging implements CloudSyncOutboundChatStagingTransport {
  int stages = 0, commits = 0, rollbacks = 0;
  bool failCommit = false;
  Future<void> Function()? onChatStage;
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<CloudSyncProtectedOutboundStageData> stageOutboundChat(
    CloudSyncScope scope, {
    required api.CloudChat chat,
  }) async {
    stages++;
    await onChatStage?.call();
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
