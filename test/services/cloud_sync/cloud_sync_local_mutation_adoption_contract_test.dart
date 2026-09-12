// Minimum adoption contract for promoting a locally staged edit/unsend into
// the CloudKit outbox.
//
// What this file proves today (all against existing public seams):
// - The journal pins the exact writer epoch, account, mutation target
//   GUID/part, and source bytes at adoption time.
// - Duplicate adoption is idempotent only for the identical operation.
// - Distinct target GUIDs never share an intent row.
// - A positive IDS receipt is bound to one mutation/source/auth triple,
//   cannot confirm a second intent, and replays idempotently.
// - cloudSyncFindRecordMap resolves (or fail-closes) a predecessor map by
//   exact account/scope/generation/logical-key/server-ID.
//
// What is still missing (skipped skeleton group at the bottom):
// - No production seam joins a journal intent's targetGuid to the message
//   logicalEntityKeyHash, opens the predecessor only through the mapped
//   server ID with its exact ETag, or adopts the journal row and the
//   CloudOutboxOperationEntity in one atomic transaction. The gap tripwire
//   below pins the current behavior (no outbox row is created) so the
//   missing seam cannot land silently.
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_record_maps.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

const _account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _mutationId = '11111111-1111-4111-8111-111111111111';
const _otherMutationId = '44444444-4444-4444-8444-444444444444';
const _targetGuid = '22222222-2222-4222-8222-222222222222';
const _otherTargetGuid = '33333333-3333-4333-8333-333333333333';
const _logical = 'LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL';
const _server = 'SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS';
const _etag = 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE';

final _writerScope = CloudKitWriterScope(accountFingerprint: _account);
final _messageScope = CloudSyncScope(
  accountFingerprint: _account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

DateTime _time(int seconds) => DateTime.utc(2026, 9, 11, 17, 0, seconds);

Matcher _mutationFailure(String code) => isA<StateError>().having(
  (e) => e.message,
  'safe code',
  'cloud_sync_local_mutation_$code',
);

Matcher _mappingConflict() => isA<CloudSyncFailure>().having(
  (f) => f.safeCode,
  'safeCode',
  'semantic_record_mapping_conflict',
);

api.MessageInst _mutationWire({
  required String mutationId,
  required String targetGuid,
  int targetPart = 0,
}) => api.MessageInst(
  id: mutationId,
  sender: 'mailto:me@example.invalid',
  conversation: api.ConversationData(
    participants: ['mailto:me@example.invalid', 'mailto:peer@example.invalid'],
    senderGuid: 'iMessage;-;peer@example.invalid',
  ),
  message: api.Message.edit(
    api.EditMessage(
      tuuid: targetGuid,
      editPart: targetPart,
      newParts: api.MessageParts(
        field0: [
          api.IndexedMessagePart(
            part_: api.MessagePart.text(
              'replacement',
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
        ],
      ),
    ),
  ),
  sentTimestamp: 0,
  sendDelivered: true,
  verificationFailed: false,
);

CloudSyncLocalMutationSourceBinding _mutationSource(
  CloudSyncLocalMutationIdentity identity,
) => CloudSyncLocalMutationSourceBinding(
  accountFingerprint: _account,
  protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
  mutationGuidHash: identity.guidHash,
  targetGuidHash: identity.targetGuidHash,
  targetPart: identity.targetPart,
  sourceSha256: identity.sourceSha256,
  protectedReference: 'obcs2.ref.${'B' * 43}',
  leaseReference: 'obcs2.lease.${'b' * 32}',
  payloadSha256: 'a' * 64,
  payloadLength: 512,
);

CloudSyncNativeAuthSnapshot _auth({String session = 'native-session'}) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: session,
      accountFingerprint: _account,
      protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
      cloudMessagesClient: Object(),
    );

api.CloudSyncNativeSendReceipt _receipt(
  CloudSyncLocalMutationIdentity identity,
  CloudSyncLocalMutationSourceBinding source, {
  String session = 'native-session',
}) => api.CloudSyncNativeSendReceipt(
  receiptId: 'obcs2.ids.${'A' * 43}',
  guidHash: identity.guidHash,
  nativeSessionId: session,
  preparedSentTimestampMs: BigInt.from(1789146004000),
  sourceBinding: api.CloudSyncNativeSendSourceBinding(
    kind: api.CloudSyncNativeSendSourceKind.mutation,
    sourceSha256: source.sourceSha256,
    protectedReference: source.protectedReference,
    leaseReference: source.leaseReference,
    payloadSha256: source.payloadSha256,
    payloadLength: BigInt.from(source.payloadLength),
  ),
);

CloudRecordMapEntity _mapRow({
  required String logical,
  required String server,
  int generation = 1,
  String? etag,
  String? encryptedRef,
  String? account,
}) => CloudRecordMapEntity(
  mapKey: cloudSyncCanonicalRecordMapKey(_messageScope, logical),
  scopeKey: cloudSyncPersistentScopeKey(_messageScope),
  accountFingerprint: account ?? _account,
  zone: _messageScope.zone,
  logicalEntityKeyHash: logical,
  serverRecordIdHash: server,
  generation: generation,
  encryptedServerRecordId: encryptedRef ?? 'obcs2.ref.${'R' * 43}',
  etagHash: etag ?? _etag,
  encryptedRawRecordRef: 'obcs2.ref.${'W' * 43}',
  updatedAtMs: _time(10).millisecondsSinceEpoch,
);

void main() {
  group('mutation intent exactness (existing journal seam)', () {
    late Directory directory;
    late Store store;
    late ObjectBoxCloudKitWriterAuthority authority;
    late CloudSyncLocalMutationJournal journal;
    late Message target;
    late Message otherTarget;
    late CloudSyncLocalMutationIdentity identity;
    late CloudSyncLocalMutationSourceBinding source;
    late String snapshot;

    void bind() {
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
          evidence: const CloudKitWriterTransitionEvidence.forTest(
            operationsQuiesced: true,
            activeIdentityRevalidated: true,
            legacyMutationQueues: LegacyMutationQueueDisposition.empty,
          ),
          now: _time(1),
        );
      }
      journal = CloudSyncLocalMutationJournal(
        store: store,
        authority: authority,
        authoritySnapshot: authority.read(_writerScope)!,
      );
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'ob-mutation-adoption-',
      );
      store = await openStore(directory: directory.path);
      bind();
      final handle = Handle(
        address: 'peer@example.invalid',
        service: 'iMessage',
        uniqueAddressAndService: 'peer@example.invalid/iMessage',
      );
      store.box<Handle>().put(handle);
      final chat = Chat(
        guid: 'iMessage;-;peer@example.invalid',
        style: 45,
        chatIdentifier: 'peer@example.invalid',
        usingHandle: 'mailto:me@example.invalid',
        participants: [handle],
      );
      chat.handles.add(handle);
      store.box<Chat>().put(chat);
      target = Message(
        guid: _targetGuid,
        isFromMe: true,
        text: 'original',
        dateCreated: _time(1),
        attributedBody: [AttributedBody.raw('original')],
      );
      target.chat.target = chat;
      store.box<Message>().put(target);
      otherTarget = Message(
        guid: _otherTargetGuid,
        isFromMe: true,
        text: 'other',
        dateCreated: _time(1),
        attributedBody: [AttributedBody.raw('other')],
      );
      otherTarget.chat.target = chat;
      store.box<Message>().put(otherTarget);
      identity = CloudSyncLocalMutationIdentity.captureWire(
        _mutationWire(mutationId: _mutationId, targetGuid: _targetGuid),
      )!;
      source = _mutationSource(identity);
      snapshot = journal.captureTargetSnapshot(
        localMessageId: target.id!,
        identity: identity,
      );
    });
    tearDown(() async {
      if (!store.isClosed()) store.close();
      await directory.delete(recursive: true);
    });

    int adopt() => journal.adoptSource(
      localMessageId: target.id!,
      identity: identity,
      targetSnapshotSha256: snapshot,
      source: source,
      capturedAuth: _auth(),
      stillCurrent: () => true,
      now: _time(2),
    );
    void claim(int id) => journal.beginSubmission(
      intentId: id,
      committedSource: source,
      capturedAuth: _auth(),
      stillCurrent: () => true,
      now: _time(3),
    );
    void confirm(int id, {api.CloudSyncNativeSendReceipt? receipt}) =>
        journal.recordNativeReceipt(
          intentId: id,
          receipt: receipt ?? _receipt(identity, source),
          capturedAuth: _auth(),
          stillCurrent: () => true,
          now: _time(4),
        );
    CloudSyncLocalMutationIntentEntity row(int id) =>
        store.box<CloudSyncLocalMutationIntentEntity>().get(id)!;

    ({CloudSyncLocalMutationIdentity identity, CloudSyncLocalMutationSourceBinding source, String snapshot, int intentId})
    adoptOther() {
      final otherIdentity = CloudSyncLocalMutationIdentity.captureWire(
        _mutationWire(
          mutationId: _otherMutationId,
          targetGuid: _otherTargetGuid,
        ),
      )!;
      final otherSource = _mutationSource(otherIdentity);
      final otherSnapshot = journal.captureTargetSnapshot(
        localMessageId: otherTarget.id!,
        identity: otherIdentity,
      );
      final intentId = journal.adoptSource(
        localMessageId: otherTarget.id!,
        identity: otherIdentity,
        targetSnapshotSha256: otherSnapshot,
        source: otherSource,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(2),
      );
      return (
        identity: otherIdentity,
        source: otherSource,
        snapshot: otherSnapshot,
        intentId: intentId,
      );
    }

    test('adoption pins the exact writer epoch', () {
      final id = adopt();
      final permit = authority.issuePermit(
        _writerScope,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      authority.markMutationUnknown(permit, now: _time(9));
      expect(
        () => journal.beginSubmission(
          intentId: id,
          committedSource: source,
          capturedAuth: _auth(),
          stillCurrent: () => true,
          now: _time(10),
        ),
        throwsA(_mutationFailure('owner_changed')),
      );
      expect(row(id).state, 0);
    });

    test('duplicate adoption is idempotent only for the identical operation', () {
      final first = adopt();
      expect(adopt(), first);
      final changedIdentity = CloudSyncLocalMutationIdentity.captureWire(
        _mutationWire(
          mutationId: _mutationId,
          targetGuid: _targetGuid,
          targetPart: 1,
        ),
      )!;
      expect(
        () => journal.adoptSource(
          localMessageId: target.id!,
          identity: changedIdentity,
          targetSnapshotSha256: snapshot,
          source: _mutationSource(changedIdentity),
          capturedAuth: _auth(),
          stillCurrent: () => true,
          now: _time(2),
        ),
        throwsA(_mutationFailure('intent_changed')),
      );
      expect(
        store.box<CloudSyncLocalMutationIntentEntity>().count(),
        1,
      );
    });

    test('different target GUIDs never share an intent', () {
      final first = adopt();
      final other = adoptOther();
      expect(other.intentId, isNot(first));
      expect(
        store.box<CloudSyncLocalMutationIntentEntity>().count(),
        2,
      );
    });

    test('changed account cannot claim an adopted mutation', () {
      final id = adopt();
      final foreign = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'native-session',
        accountFingerprint: 'B' * 43,
        protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
        cloudMessagesClient: Object(),
      );
      expect(
        () => journal.beginSubmission(
          intentId: id,
          committedSource: source,
          capturedAuth: foreign,
          stillCurrent: () => true,
          now: _time(3),
        ),
        throwsA(_mutationFailure('auth_changed')),
      );
      expect(row(id).state, 0);
    });

    test('a receipt from another native session cannot confirm', () {
      final id = adopt();
      claim(id);
      expect(
        () => journal.recordNativeReceipt(
          intentId: id,
          receipt: _receipt(identity, source, session: 'replacement-session'),
          capturedAuth: _auth(),
          stillCurrent: () => true,
          now: _time(4),
        ),
        throwsA(_mutationFailure('receipt_session_changed')),
      );
      expect(row(id).state, 1);
    });

    test('one positive receipt cannot confirm two intents', () {
      final first = adopt();
      claim(first);
      final other = adoptOther();
      journal.beginSubmission(
        intentId: other.intentId,
        committedSource: other.source,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(3),
      );
      final receipt = _receipt(identity, source);
      confirm(first, receipt: receipt);
      expect(row(first).state, 2);
      expect(
        () => journal.recordNativeReceipt(
          intentId: other.intentId,
          receipt: receipt,
          capturedAuth: _auth(),
          stillCurrent: () => true,
          now: _time(4),
        ),
        throwsA(_mutationFailure('receipt_changed')),
      );
      expect(row(other.intentId).state, 1);
    });

    test('replaying the identical receipt is idempotent', () {
      final id = adopt();
      claim(id);
      final receipt = _receipt(identity, source);
      confirm(id, receipt: receipt);
      final proof = row(id).idsReceiptBindingSha256;
      confirm(id, receipt: receipt);
      expect(row(id).state, 2);
      expect(row(id).idsReceiptBindingSha256, proof);
    });

    test('confirmed mutation stages no outbox operation (adoption gap)', () {
      // Tripwire for the missing seam: the journal confirms IDS acceptance,
      // but no production code adopts the intent into a
      // CloudOutboxOperationEntity bound to the exact record map (server ID,
      // ETag, encrypted predecessor). When that seam lands, replace this
      // expectation with atomic-adoption assertions.
      final id = adopt();
      claim(id);
      confirm(id);
      expect(row(id).state, 2);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    });
  });

  group('record-map predecessor resolution (existing store seam)', () {
    late Directory directory;
    late Store store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'ob-mutation-adoption-maps-',
      );
      store = await openStore(directory: directory.path);
    });
    tearDown(() async {
      if (!store.isClosed()) store.close();
      await directory.delete(recursive: true);
    });

    CloudRecordMapEntity? resolve({int generation = 1, String? server}) =>
        cloudSyncFindRecordMap(
          store: store,
          scope: _messageScope,
          generation: generation,
          logicalEntityKeyHash: _logical,
          serverRecordIdHash: server,
        );

    test('resolves the exact current-generation predecessor map', () {
      store
          .box<CloudRecordMapEntity>()
          .put(_mapRow(logical: _logical, server: _server));
      final found = resolve();
      expect(found, isNotNull);
      expect(found!.serverRecordIdHash, _server);
      expect(found.etagHash, _etag);
      expect(found.encryptedServerRecordId, isNotEmpty);
      expect(found.encryptedRawRecordRef, isNotNull);
    });

    test('stale generation and foreign server hash resolve to null', () {
      store
          .box<CloudRecordMapEntity>()
          .put(_mapRow(logical: _logical, server: _server));
      expect(resolve(generation: 2), isNull);
      expect(resolve(server: 'Z' * 43), isNull);
    });

    test('predecessor rows without server identity fail closed', () {
      store.box<CloudRecordMapEntity>().put(
        _mapRow(logical: _logical, server: '', etag: _etag),
      );
      expect(resolve, throwsA(_mappingConflict()));
    });

    test('predecessor rows without encrypted references fail closed', () {
      store.box<CloudRecordMapEntity>().put(
        _mapRow(logical: _logical, server: _server, encryptedRef: ''),
      );
      expect(resolve, throwsA(_mappingConflict()));
    });

    test('predecessor rows from another account fail closed', () {
      store.box<CloudRecordMapEntity>().put(
        _mapRow(logical: _logical, server: _server, account: 'B' * 43),
      );
      expect(resolve, throwsA(_mappingConflict()));
    });
  });

  group(
    'mutation-to-outbox adoption (missing production seam)',
    skip:
        'no production seam joins a journal intent to a CloudRecordMapEntity '
        'and CloudOutboxOperationEntity atomically',
    () {
      test('canonical target GUID resolves to exactly one logical key', () {
        // Required: derive the expected message logical key natively from the
        // verbatim targetGuid with the Message hasher, then resolve it through
        // cloudSyncFindRecordMap at the current generation. The journal never
        // performs this join today.
        fail('missing production seam: target GUID to logical key join');
      });

      test('predecessor opens only through the mapped server ID', () {
        // Required: open the predecessor via that map entry only, verify the
        // record identifier equals the mapped server ID, and copy its ETag
        // and PCS prefix exactly into a conditional update.
        fail('missing production seam: ETag/PCS-checked predecessor open');
      });

      test('outbox and journal transition in one atomic transaction', () {
        // Required: adopt the CloudOutboxOperation with logical key, server
        // ID, ETag, predecessor snapshot, and staged refs in the same
        // transaction that claims the journal intent.
        fail('missing production seam: atomic outbox and journal adoption');
      });

      test('a positive receipt is single-consumed across journal and outbox', () {
        // Required: the IDS receipt proof that confirmed the journal intent
        // must be the single credential consumed by the outbox save, so two
        // staged updates can never share one receipt.
        fail('missing production seam: shared receipt single-consumption');
      });
    },
  );
}
