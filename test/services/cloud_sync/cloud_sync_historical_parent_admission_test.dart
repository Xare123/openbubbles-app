import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_identity_evidence.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_identity_read_set.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_chat_state.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_parent_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_chat_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/cloud_sync_chat_identity.dart'
    as native;
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

final _now = DateTime.utc(2026, 9, 28);
final _account = 'A' * 43;
final _storeIdentity = 'obcs2.store.${'S' * 43}';
CloudSyncScope _scope(String zone) => CloudSyncScope(
  accountFingerprint: _account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
final _chatScope = _scope('chatManateeZone');

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudSyncStore durable;
  late CloudSyncHistoricalArchiveJournal journal;
  late CloudSyncHistoricalProtectedSourceBinding source;
  late CloudSyncHistoricalArchiveRequest request;
  late int intentId;

  CloudSyncHistoricalParentOrigin origin({int? chatId}) =>
      CloudSyncHistoricalParentOrigin.capture(
        store: store,
        journal: journal,
        scope: _chatScope,
        generation: 1,
        request: request,
        intentId: intentId,
        localChatId: chatId,
        parentPayloadLength: 1024,
      );

  CloudOutboxOperation admit(
    CloudSyncHistoricalParentOrigin selected, {
    CloudSyncChatIdentityEvidence? evidence,
  }) => durable.admitProtectedHistoricalChatCreate(
    origin: selected,
    identityEvidence: evidence,
    draft: CloudOutboxDraft(
      scope: _chatScope,
      logicalEntityKeyHash: 'L' * 43,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncOutboundChatPayloadVersion,
      dependencyOperationIds: const {},
      createdAt: _now,
      encryptedPayloadReference: 'obcs2.ref.${'P' * 43}',
      payloadSha256: 'd' * 64,
      serverRecordIdHash: 'R' * 43,
      protectedLeaseReference: 'obcs2.lease.${'e' * 32}',
    ),
    recordMapping: CloudRecordMapEntry(
      scope: _chatScope,
      logicalEntityKeyHash: 'L' * 43,
      serverRecordIdHash: 'R' * 43,
      encryptedServerRecordId: 'obcs2.ref.${'P' * 43}',
      updatedAt: _now,
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'historical-parent-admission-',
    );
    store = await openStore(directory: directory.path);
    durable = ObjectBoxCloudSyncStore(
      store: store,
      protector: _SyntheticProtector(),
      clock: () => _now,
    );
    for (final zone in [
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      await durable.recordPullSuccess(_scope(zone), now: _now);
    }
    final detachedChat = Chat(
      guid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      style: 43,
      usingHandle: 'owner@example.invalid',
    )..cloudGuid = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
    request = CloudSyncHistoricalArchiveRequest(
      guid: 'synthetic-original-message',
      guidHash: 'b' * 64,
      sourceSha256: 'c' * 64,
      origin: CloudSyncHistoricalArchiveOrigin.historicalSent,
      isFromMe: true,
      chatGuid: detachedChat.guid,
      dateCreatedMs: _now.millisecondsSinceEpoch - 1000,
      snapshotSha256: 'a' * 64,
      accountFingerprint: _account,
      protectedStoreIdentity: _storeIdentity,
      textSha256: 'f' * 64,
      senderAddress: 'owner@example.invalid',
      peerAddress: 'peer@example.invalid',
      groupMetadata: CloudSyncHistoricalGroupMetadata(
        cloudGuid: detachedChat.cloudGuid,
        participants: const [
          CloudSyncHistoricalParticipantView(
            address: 'peer@example.invalid',
            service: 'iMessage',
          ),
        ],
      ),
      parentState: CloudSyncHistoricalChatState.capture(detachedChat),
    );
    source = CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _storeIdentity,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
      protectedReference: 'obcs2.ref.${'H' * 43}',
      leaseReference: 'obcs2.lease.${'a' * 32}',
      payloadSha256: 'b' * 64,
      payloadLength: 128,
    );
    journal = CloudSyncHistoricalArchiveJournal(
      store: store,
      accountFingerprint: _account,
      protectedStoreIdentity: _storeIdentity,
      snapshotSha256: source.snapshotSha256,
      clock: () => _now,
    );
    intentId = journal.adopt(source).id;
    journal.markSourceLeaseCommitted(
      intentId: intentId,
      expectedSource: source,
    );
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    await directory.delete(recursive: true);
  });

  test(
    'parent adoption owns one exact envelope without fake chat, message or IDS proof',
    () async {
      final selected = origin();
      final operation = admit(selected);
      final encoded = durable.readHistoricalChatSource(operation)!.encode();
      expect(
        durable
            .readHistoricalChatCreate(_chatScope, selected.durable)!
            .operationId,
        operation.operationId,
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      expect(store.box<Chat>().count(), 0);
      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(
        journal
            .read(
              messageGuidHash: request.guidHash,
              sourceSha256: request.sourceSha256,
            )!
            .admittedOperationId,
        isNull,
      );
      expect(cloudSyncOutboundChatOriginSendProof(encoded), isNull);
      expect(cloudSyncSubmittedChatOrigin(encoded), encoded);
      store.close();
      store = await openStore(directory: directory.path);
      durable = ObjectBoxCloudSyncStore(
        store: store,
        protector: _SyntheticProtector(),
      );
      final retained = (await durable.readOutboxEntries(_chatScope)).single;
      expect(durable.readHistoricalChatSource(retained)!.encode(), encoded);
      expect(retained.operationId, operation.operationId);
    },
  );

  test('uncommitted or replaced source cannot be adopted', () {
    final selected = origin();
    final rows = store.box<CloudSyncHistoricalArchiveIntentEntity>();
    final row = rows.get(intentId)!..state = 0;
    rows.put(row);
    expect(() => admit(selected), throwsA(anything));
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    row.state = 1;
    row.protectedSourceBinding = row.protectedSourceBinding.replaceFirst(
      'c' * 64,
      'd' * 64,
    );
    rows.put(row);
    expect(() => admit(selected), throwsA(anything));
    expect(store.box<CloudRecordMapEntity>().count(), 0);
  });

  test(
    'destination creation after capture invalidates absence without deleting rows',
    () {
      final selected = origin();
      store.box<Chat>().put(Chat(guid: request.chatGuid, style: 43));
      expect(() => admit(selected), throwsA(anything));
      expect(store.box<Chat>().count(), 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'receipt source survives later local deletion but fresh dispatch fails closed',
    () async {
      final chat = Chat(guid: request.chatGuid, style: 43);
      store.box<Chat>().put(chat);
      final selected = origin(chatId: chat.id);
      final operation = admit(selected);
      store.box<Chat>().remove(chat.id!);
      expect(
        durable.readHistoricalChatSource(operation)!.source.encode(),
        source.encode(),
      );
      expect(() => selected.requireUnchanged(store), throwsStateError);
      expect(
        durable
            .readHistoricalChatCreate(_chatScope, selected.durable)!
            .operationId,
        operation.operationId,
      );
    },
  );

  test(
    'applied group identities require fresh native comparison, not just empty retained debt',
    () async {
      await seedSyntheticRestoredChatAppliedSource(
        objectBox: store,
        store: durable,
        chatScope: _chatScope,
        now: _now,
      );
      expect(
        CloudSyncChatIdentityReadSet.capture(store, _chatScope).retainedSaves,
        isEmpty,
      );
      final broad = CloudSyncChatIdentityReadSet.capture(
        store,
        _chatScope,
        includeAppliedSaves: true,
      );
      expect(broad.retainedSaves, hasLength(1));
      expect(() => admit(origin()), throwsA(anything));
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      final selected = origin();
      final auth = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'synthetic',
        accountFingerprint: _account,
        protectedStoreIdentity: _storeIdentity,
        cloudMessagesClient: Object(),
      );
      var observations = 0;
      final evidence = await CloudSyncChatIdentityEvidence.observe(
        store: store,
        origin: selected,
        stage: CloudSyncProtectedOutboundStageData(
          logicalEntityKeyHash: 'L' * 43,
          serverRecordIdHash: 'R' * 43,
          payloadSha256: 'd' * 64,
          protectedEnvelopeReference: 'obcs2.ref.${'P' * 43}',
          leaseReference: 'obcs2.lease.${'e' * 32}',
        ),
        auth: auth,
        authFence: CloudSyncLocalSendAuthFence(
          expected: auth,
          capture: () async => auth,
          stillCurrent: () => true,
        ),
        observer: (set, retained, stage, candidate) async {
          observations++;
          expect(set.includeAppliedSaves, isTrue);
          return native.CloudSyncChatIdentityResult(
            comparison: native.CloudSyncChatIdentityComparison.disjoint,
            candidateBindingHash: 'C' * 43,
            stagedCandidateBindingHash: 'D' * 43,
            sourceBindingHash: 'E' * 43,
            nativeSessionId: auth.nativeSessionId,
          );
        },
      );
      expect(observations, 1);
      final operation = admit(selected, evidence: evidence);
      expect(operation.status, CloudOutboxStatus.pending);
      // Admission changed the read-set revision, so the old comparison cannot
      // authorize another dispatch. Production must refresh against this stage.
      expect(
        () => evidence!.requireOperation(
          store: store,
          origin: selected,
          operation: operation,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'historical-origin retirement never impersonates an unconsumed local send',
    () {
      final encoded = origin().durable.encode();
      expect(cloudSyncChatOriginIsRetired(encoded), isFalse);
      expect(cloudSyncActiveChatOriginBinding(encoded), encoded);
      expect(() => cloudSyncRetiredChatOrigin(encoded), throwsA(anything));
    },
  );

  for (final hasDestination in [false, true]) {
    test(
      'historical group projection needs matching protected receipt existing=$hasDestination',
      () {
        Chat? local;
        if (hasDestination) {
          local = Chat(guid: request.chatGuid, style: 43);
          store.box<Chat>().put(local);
        }
        admit(origin(chatId: local?.id));
        final payload = CloudChatEntityPayload(
          logicalEntityKeyHash: 'L' * 43,
          canonicalGuid: 'iMessage;+;chat9876',
          chatIdentifier: 'chat9876',
          groupId: request.chatGuid,
          originalGroupId: request.chatGuid,
          displayName: 'synthetic historical group',
          participantHandles: const ['mailto:peer@example.invalid'],
          aliases: const [],
          service: CloudSemanticService.iMessage,
          style: CloudSemanticChatStyle.group,
        );
        final snapshot = CloudSemanticSnapshot(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: 'L' * 43,
          immutableContentDigest: 'I' * 43,
          etagHash: 'E' * 43,
          encryptedRawRecordReference: 'obcs2.ref.${'W' * 43}',
        );
        Chat? resolve() => resolveCloudSyncOutboundChatOrigin(
          store: store,
          scope: _chatScope,
          generation: 1,
          payload: payload,
          snapshot: snapshot,
          canonicalChat: null,
        );
        expect(resolve, throwsA(anything)); // Merely staged is not a receipt.
        final row = store.box<CloudOutboxOperationEntity>().getAll().single
          ..state = CloudOutboxStatus.confirmed.index
          ..confirmedAtMs = _now.millisecondsSinceEpoch
          ..appleRequestUuid = '11111111-2222-4333-8444-555555555555'
          ..appleOperationUuid = 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE';
        store.box<CloudOutboxOperationEntity>().put(row);
        expect(
          resolve,
          throwsA(anything),
        ); // No authenticated raw record mapping.
        final mapping = store.box<CloudRecordMapEntity>().getAll().single
          ..etagHash = snapshot.etagHash
          ..encryptedRawRecordRef = snapshot.encryptedRawRecordReference
          ..rawRecordGeneration = 1;
        store.box<CloudRecordMapEntity>().put(mapping);
        expect(resolve()?.id, local?.id);
        // A missing destination is returned to the ordinary canonical inserter,
        // never inserted as a placeholder by the origin resolver.
        expect(store.box<Chat>().count(), hasDestination ? 1 : 0);
        expect(store.box<Message>().count(), 0);
        mapping.etagHash = 'Z' * 43;
        store.box<CloudRecordMapEntity>().put(mapping);
        expect(resolve, throwsA(anything));
      },
    );
  }
}

class _SyntheticProtector implements CloudSyncProtector {
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
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) =>
      throw StateError('not a live account test');
}
