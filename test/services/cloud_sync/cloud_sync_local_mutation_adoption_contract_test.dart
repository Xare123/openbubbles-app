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
// The store seam also proves atomic journal/outbox adoption, exact predecessor
// revalidation, idempotent restart recovery, and rollback on stale local or
// remote state. The exported cloud_sync_prepare_message_update API owns the
// target-GUID/keyed-logical-hash/protected-predecessor proof. Its production
// assembly checks are exercised by cloud_sync_message_update_prepare_tests in
// rust/src/api/api.rs (target/logical hash, record name/server hash, ETag, PCS
// prefix and minimal conditional merge). Protected source/lease checks live in
// cloud_sync_ids_mutation_stage tests. These are real native tests, not a Dart
// mock of the FFI response. This fixture does not exercise the authenticated
// exported entry end to end; named Windows/Pixel evidence covers that separately.
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_record_maps.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
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

Matcher _cloudFailure(String code) => isA<CloudSyncFailure>().having(
  (failure) => failure.safeCode,
  'safeCode',
  code,
);

api.MessageInst _mutationWire({
  required String mutationId,
  required String targetGuid,
  int targetPart = 0,
  String replacement = 'replacement',
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
              replacement,
              const api.TextFormat.flags(
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
  CloudSyncLocalMutationIdentity identity, {
  String reference = 'B',
  String lease = 'b',
  String payload = 'a',
}) => CloudSyncLocalMutationSourceBinding(
  accountFingerprint: _account,
  protectedStoreIdentity: 'obcs2.store.${'A' * 43}',
  mutationGuidHash: identity.guidHash,
  targetGuidHash: identity.targetGuidHash,
  targetPart: identity.targetPart,
  sourceSha256: identity.sourceSha256,
  protectedReference: 'obcs2.ref.${reference * 43}',
  leaseReference: 'obcs2.lease.${lease * 32}',
  payloadSha256: payload * 64,
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
  String receiptMarker = 'A',
  DateTime? preparedAt,
}) => api.CloudSyncNativeSendReceipt(
  receiptId: 'obcs2.ids.${receiptMarker * 43}',
  guidHash: identity.guidHash,
  nativeSessionId: session,
  preparedSentTimestampMs: BigInt.from(
    preparedAt?.millisecondsSinceEpoch ?? 1789146004000,
  ),
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
  String? rawRef,
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
  encryptedRawRecordRef: rawRef ?? 'obcs2.ref.${'W' * 43}',
  updatedAtMs: _time(10).millisecondsSinceEpoch,
);

CloudRecordMapEntry _mapEntry({
  String logical = _logical,
  String server = _server,
  String etag = _etag,
  String encryptedRef = 'obcs2.ref.RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR',
  String rawRef = 'obcs2.ref.WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW',
}) => CloudRecordMapEntry(
  scope: _messageScope,
  logicalEntityKeyHash: logical,
  serverRecordIdHash: server,
  encryptedServerRecordId: encryptedRef,
  etagHash: etag,
  encryptedRawRecordReference: rawRef,
  updatedAt: _time(10),
);

CloudOutboxDraft _updateDraft({
  String logical = _logical,
  String server = _server,
  String payload = 'c',
  String reference = 'U',
  String lease = 'c',
  DateTime? createdAt,
}) => CloudOutboxDraft(
  scope: _messageScope,
  logicalEntityKeyHash: logical,
  action: CloudOutboxAction.save,
  payloadVersion: cloudSyncMessageUpdatePayloadVersion,
  dependencyOperationIds: const {},
  createdAt: createdAt ?? _time(20),
  encryptedPayloadReference: 'obcs2.ref.${reference * 43}',
  payloadSha256: payload * 64,
  serverRecordIdHash: server,
  protectedLeaseReference: 'obcs2.lease.${lease * 32}',
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
        final disabled = authority.initializeDisabled(
          _writerScope,
          now: _time(0),
        );
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

    ({
      CloudSyncLocalMutationIdentity identity,
      CloudSyncLocalMutationSourceBinding source,
      String snapshot,
      int intentId,
    })
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

    test(
      'duplicate adoption is idempotent only for the identical operation',
      () {
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
        expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 1);
      },
    );

    test('different target GUIDs never share an intent', () {
      final first = adopt();
      final other = adoptOther();
      expect(other.intentId, isNot(first));
      expect(store.box<CloudSyncLocalMutationIntentEntity>().count(), 2);
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
      store.box<CloudRecordMapEntity>().put(
        _mapRow(logical: _logical, server: _server),
      );
      final found = resolve();
      expect(found, isNotNull);
      expect(found!.serverRecordIdHash, _server);
      expect(found.etagHash, _etag);
      expect(found.encryptedServerRecordId, isNotEmpty);
      expect(found.encryptedRawRecordRef, isNotNull);
    });

    test('stale generation and foreign server hash resolve to null', () {
      store.box<CloudRecordMapEntity>().put(
        _mapRow(logical: _logical, server: _server),
      );
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

  group('mutation-to-outbox atomic adoption', () {
    late Directory directory;
    late Store store;
    late ObjectBoxCloudKitWriterAuthority authority;
    late CloudSyncLocalMutationJournal journal;
    late ObjectBoxCloudSyncStore cloudStore;
    late Message target;
    late CloudSyncLocalMutationIdentity identity;
    late CloudSyncLocalMutationSourceBinding source;
    late CloudSyncLocalMutationAdmissionSource admissionSource;
    late CloudRecordMapEntry expectedPredecessor;
    late CloudOutboxDraft draft;
    late int intentId;

    void bind() {
      authority = ObjectBoxCloudKitWriterAuthority.forTest(
        store: store,
        buildDecision: CloudKitWriterOwnership.resolve('v2'),
      );
      if (authority.read(_writerScope) == null) {
        final disabled = authority.initializeDisabled(
          _writerScope,
          now: _time(0),
        );
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
      cloudStore = ObjectBoxCloudSyncStore(
        store: store,
        protector: _NoProtector(),
        localMutationJournal: journal,
        clock: () => _time(20),
      );
    }

    Future<void> reopen() async {
      store.close();
      store = await openStore(directory: directory.path);
      bind();
    }

    Future<CloudRecordMapEntry> currentPredecessor() async =>
        (await cloudStore.readRecordMap(
          _messageScope,
          logicalEntityKeyHash: _logical,
          serverRecordIdHash: _server,
          generation: (await cloudStore.readCheckpoint(_messageScope)).generation,
        ))!;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'ob-mutation-outbox-adoption-',
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
      identity = CloudSyncLocalMutationIdentity.captureWire(
        _mutationWire(mutationId: _mutationId, targetGuid: _targetGuid),
      )!;
      source = _mutationSource(identity);
      final snapshot = journal.captureTargetSnapshot(
        localMessageId: target.id!,
        identity: identity,
      );
      intentId = journal.adoptSource(
        localMessageId: target.id!,
        identity: identity,
        targetSnapshotSha256: snapshot,
        source: source,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(2),
      );
      journal.beginSubmission(
        intentId: intentId,
        committedSource: source,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(3),
      );
      final receipt = _receipt(identity, source);
      journal.recordNativeReceipt(
        intentId: intentId,
        receipt: receipt,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(4),
      );
      journal.reflectConfirmed(
        intentId: intentId,
        receipt: receipt,
        currentAuth: _auth(),
        stillCurrent: () => true,
        project: (message, preparedSentTimestampMs) => message
          ..text = 'replacement'
          ..attributedBody = [AttributedBody.raw('replacement')]
          ..dateEdited = DateTime.fromMillisecondsSinceEpoch(
            preparedSentTimestampMs,
            isUtc: true,
          ),
        now: _time(5),
      );
      admissionSource = journal.readReflectedForUpdate(
        intentId: intentId,
        currentAuth: _auth(),
        stillCurrent: () => true,
      );
      await cloudStore.readCheckpoint(_messageScope);
      store.box<CloudRecordMapEntity>().put(
        _mapRow(logical: _logical, server: _server),
      );
      expectedPredecessor = await currentPredecessor();
      draft = _updateDraft();
    });

    tearDown(() async {
      if (!store.isClosed()) store.close();
      await directory.delete(recursive: true);
    });

    CloudOutboxOperation admit({
      CloudOutboxDraft? withDraft,
      CloudRecordMapEntry? withPredecessor,
      CloudSyncNativeAuthSnapshot? auth,
      bool Function()? stillCurrent,
    }) => cloudStore.admitProtectedLocalMutationUpdate(
      draft: withDraft ?? draft,
      expectedPredecessor: withPredecessor ?? expectedPredecessor,
      journal: journal,
      source: admissionSource,
      currentAuth: auth ?? _auth(),
      stillCurrent: stillCurrent ?? () => true,
    );

    void expectRolledBack() {
      final row = store.box<CloudSyncLocalMutationIntentEntity>().get(
        intentId,
      )!;
      expect(row.state, 3);
      expect(row.admittedOperationId, isNull);
      expect(row.admittedBindingSha256, isNull);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    }

    List<Object?> immutableProof(int id) {
      final row = store.box<CloudSyncLocalMutationIntentEntity>().get(id)!;
      return [
        row.intentKey,
        row.accountFingerprint,
        row.writerEpoch,
        row.localMessageId,
        row.localChatId,
        row.mutationGuidHash,
        row.targetGuidHash,
        row.targetPart,
        row.kind,
        row.sourceSha256,
        row.targetSnapshotSha256,
        row.protectedSourceBinding,
        row.submissionAuthBindingSha256,
        row.idsReceiptBindingSha256,
        row.reflectedSnapshotSha256,
        row.createdAtMs,
      ];
    }

    ({int id, CloudSyncLocalMutationSourceBinding source}) reflectSecond({
      int at = 6,
    }) {
      final wire = _mutationWire(
        mutationId: _otherMutationId,
        targetGuid: _targetGuid,
        replacement: 'second replacement',
      );
      final secondIdentity = CloudSyncLocalMutationIdentity.captureWire(wire)!;
      final secondSource = _mutationSource(
        secondIdentity,
        reference: 'D',
        lease: 'd',
        payload: 'd',
      );
      final id = journal.adoptSource(
        localMessageId: target.id!,
        identity: secondIdentity,
        targetSnapshotSha256: journal.captureTargetSnapshot(
          localMessageId: target.id!,
          identity: secondIdentity,
        ),
        source: secondSource,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(at),
      );
      journal.beginSubmission(
        intentId: id,
        committedSource: secondSource,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(at + 1),
      );
      final receipt = _receipt(
        secondIdentity,
        secondSource,
        receiptMarker: 'D',
        preparedAt: _time(at + 2),
      );
      journal.recordNativeReceipt(
        intentId: id,
        receipt: receipt,
        capturedAuth: _auth(),
        stillCurrent: () => true,
        now: _time(at + 2),
      );
      journal.reflectConfirmed(
        intentId: id,
        receipt: receipt,
        currentAuth: _auth(),
        stillCurrent: () => true,
        project: (message, preparedSentTimestampMs) => message
          ..text = 'second replacement'
          ..attributedBody = [AttributedBody.raw('second replacement')]
          ..dateEdited = DateTime.fromMillisecondsSinceEpoch(
            preparedSentTimestampMs,
            isUtc: true,
          ),
        now: _time(at + 3),
      );
      expect(store.box<CloudSyncLocalMutationIntentEntity>().get(id)!.state, 3);
      return (id: id, source: secondSource);
    }

    Future<CloudOutboxOperation> settleThroughFence(
      CloudOutboxOperation operation, {
      required int mutationIntentId,
      required CloudRecordMapEntry predecessor,
      int sequence = 1,
      bool reopenUnknown = false,
      void Function()? beforeTerminalize,
    }) async {
      // Synthetic native readback evidence; all DB and authority changes use
      // the real store APIs. No native transport or IDS resend is invoked.
      final checkpoint = await cloudStore.readCheckpoint(_messageScope);
      expect(checkpoint.generation, greaterThan(0));
      expect(operation.checkpointGeneration, checkpoint.generation);
      expect(predecessor.generation, checkpoint.generation);
      expect(predecessor.rawRecordGeneration, checkpoint.generation);
      expect(
        predecessor.sameDurableSnapshotAs(await currentPredecessor()),
        isTrue,
        reason: 'Readback evidence must use the exact persisted predecessor',
      );
      for (final zone in [
        'chatManateeZone',
        'messageManateeZone',
        'attachmentManateeZone',
      ]) {
        final scope = CloudSyncScope(
          accountFingerprint: _account,
          container: _messageScope.container,
          database: _messageScope.database,
          zone: zone,
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        await cloudStore.readCheckpoint(scope);
        final row = store.box<CloudSyncCheckpointEntity>().getAll().singleWhere(
          (row) => row.checkpointKey == cloudSyncPersistentScopeKey(scope),
        )..lastSuccessfulAtMs = _time(10).millisecondsSinceEpoch;
        store.box<CloudSyncCheckpointEntity>().put(row);
      }
      final at = 30 + (sequence - 1) * 40;
      final owner = authority.read(_writerScope)!;
      final permit = authority.issuePermit(
        _writerScope,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      expect(permit.epoch, owner.epoch);
      final leaseId = 'continuity-update-$sequence';
      final leased = await cloudStore.leaseEligibleOutbox(
        _messageScope,
        now: _time(at),
        limit: 1,
        leaseId: leaseId,
        leaseDuration: const Duration(minutes: 1),
        allowedActions: const {CloudOutboxAction.save},
        allowedPayloadVersions: const {cloudSyncMessageUpdatePayloadVersion},
      );
      expect(leased.single.operationId, operation.operationId);
      final submission = CloudOutboxSubmissionIdentity(
        requestUuid:
            'AAAAAAAA-BBBB-4CCC-8DDD-${sequence.toString().padLeft(12, '0')}',
        operationUuids: {
          operation.operationId:
              'AAAAAAAA-BBBB-4CCC-8DDD-${(sequence + 10).toString().padLeft(12, '0')}',
        },
      );
      authority.verifyPermit(permit);
      await cloudStore.markOutboxSubmissionStarted(
        _messageScope,
        leaseId: leaseId,
        submissionIdentity: submission,
        now: _time(at),
      );
      authority.markMutationUnknown(permit, now: _time(at + 1));
      final unknown = authority.read(_writerScope)!;
      expect(unknown.epoch, permit.epoch + 1);
      expect(unknown.ownershipEpoch, owner.ownershipEpoch);
      expect(
        () => authority.issuePermit(
          _writerScope,
          expectedOwner: CloudKitWriterOwner.v2,
        ),
        throwsA(isA<CloudKitWriterAuthorityFailure>()),
      );
      if (reopenUnknown) {
        await reopen();
      } else {
        bind();
      }
      final retained = journal.readAdoptedForUpdate(
        operationId: operation.operationId,
        currentAuth: _auth(),
        stillCurrent: () => true,
      );
      expect(retained.adoptedOperationId, operation.operationId);
      expect(
        retained.writerEpoch,
        store.box<CloudSyncLocalMutationIntentEntity>().get(mutationIntentId)!.writerEpoch,
      );
      expect(
        journal.readTerminalSourceForCleanup(
          intentId: mutationIntentId,
          currentAuth: _auth(),
          stillCurrent: () => true,
        ),
        isNull,
      );
      final entered = (await cloudStore.readOutboxEntries(_messageScope))
          .singleWhere((row) => row.operationId == operation.operationId);
      expect(entered.status, CloudOutboxStatus.unknownOutcome);
      // Submission entry persists UUIDs before any response/failure transition;
      // that crash boundary does not increment the retry-attempt counter.
      expect(entered.attemptCount, 0);
      expect(entered.appleRequestUuid, submission.requestUuid);
      expect(entered.appleOperationUuid,
          submission.operationUuids[operation.operationId]);
      journal.validateAdoptedOperation(
        store,
        entered,
        cloudSyncFindRecordMap(
          store: store,
          scope: _messageScope,
          generation: operation.checkpointGeneration,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          serverRecordIdHash: operation.serverRecordIdHash,
        )!,
      );
      final readback = await cloudStore.commitMessageUpdateReadbackReceipt(
        _messageScope,
        leaseId: leaseId,
        receipt: CloudMessageUpdateReadbackReceipt(
          operationId: operation.operationId,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          serverRecordIdHash: operation.serverRecordIdHash!,
          predecessorEtagHash: predecessor.etagHash!,
          resultingEtagHash: (sequence == 1 ? 'F' : 'G') * 43,
          protectedCurrentRawRecordReference:
              'obcs2.ref.${(sequence == 1 ? 'V' : 'Y') * 43}',
          protectedCurrentRawRecordLeaseReference:
              'obcs2.lease.${(sequence == 1 ? 'f' : '9') * 32}',
          rawGeneration: predecessor.rawRecordGeneration,
          appleRequestUuid: submission.requestUuid,
          appleOperationUuid: submission.operationUuids[operation.operationId]!,
        ),
        now: _time(at + 2),
      );
      await cloudStore.finalizeMessageUpdateReadbackLeases(
        expectedSnapshot: readback,
        updateStageLeaseCommitted: true,
        readbackLeaseCommitted: true,
      );
      final reconciled = authority.reconcileMutationFence(
        _writerScope,
        owner: CloudKitWriterOwner.v2,
        fencedEpoch: permit.epoch,
        now: _time(at + 3),
      );
      expect(reconciled.epoch, permit.epoch + 2);
      expect(reconciled.ownershipEpoch, owner.ownershipEpoch);
      expect(
        () => authority.verifyPermit(permit),
        throwsA(isA<CloudKitWriterAuthorityFailure>()),
      );
      bind();
      final confirmed = (await cloudStore.readOutboxEntries(_messageScope))
          .singleWhere((row) => row.operationId == operation.operationId);
      expect(confirmed.status, CloudOutboxStatus.confirmed);
      expect(confirmed.protectedLeaseReference, isNull);
      beforeTerminalize?.call();
      journal.markExactReadbackConfirmed(
        intentId: mutationIntentId,
        operation: confirmed,
        currentAuth: _auth(),
        stillCurrent: () => true,
        now: _time(at + 4),
      );
      expect(
        store.box<CloudSyncLocalMutationIntentEntity>().get(mutationIntentId)!.state,
        5,
      );
      return confirmed;
    }

    test(
      'queued state3 adopts at N+2 and recovers at N+4 with immutable N source',
      () async {
        final original = authority.read(_writerScope)!;
        final staleJournal = journal;
        final second = reflectSecond();
        final proof = immutableProof(second.id);
        expect(original.ownershipEpoch, original.epoch);
        expect(
          store.box<CloudSyncLocalMutationIntentEntity>().get(second.id)!.writerEpoch,
          original.epoch,
        );
        expect(
          () => journal.readReflectedForUpdate(
            intentId: second.id,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('predecessor_not_ready')),
        );
        // Refresh the first source's canonical tip after the second reflection.
        admissionSource = journal.readReflectedForUpdate(
          intentId: intentId,
          currentAuth: _auth(),
          stillCurrent: () => true,
        );
        final first = admit();
        await settleThroughFence(
          first,
          mutationIntentId: intentId,
          predecessor: expectedPredecessor,
          beforeTerminalize: () {
            expect(
              () => journal.readReflectedForUpdate(
                intentId: second.id,
                currentAuth: _auth(),
                stillCurrent: () => true,
              ),
              throwsA(_mutationFailure('predecessor_not_ready')),
            );
          },
        );
        final current = authority.read(_writerScope)!;
        expect(current.epoch, original.epoch + 2);
        expect(current.ownershipEpoch, original.epoch);
        final permit = authority.issuePermit(
          _writerScope,
          expectedOwner: CloudKitWriterOwner.v2,
        );
        expect(permit.epoch, current.epoch);
        final secondAdmission = journal.readReflectedForUpdate(
          intentId: second.id,
          currentAuth: _auth(),
          stillCurrent: () => true,
        );
        expect(secondAdmission.writerEpoch, original.epoch);
        expect(secondAdmission.adoptedOperationId, isNull);
        expectedPredecessor = await currentPredecessor();
        expect(expectedPredecessor.etagHash, 'F' * 43);
        expect(expectedPredecessor.encryptedRawRecordReference, 'obcs2.ref.${'V' * 43}');
        draft = _updateDraft(
          payload: 'e',
          reference: 'X',
          lease: 'e',
          createdAt: _time(60),
        );
        expect(
          () => staleJournal.readReflectedForUpdate(
            intentId: second.id,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('owner_changed')),
        );
        expect(
          () => cloudStore.admitProtectedLocalMutationUpdate(
            draft: draft,
            expectedPredecessor: expectedPredecessor,
            journal: staleJournal,
            source: secondAdmission,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('owner_changed')),
        );
        admissionSource = secondAdmission;
        expect(
          () => admit(withPredecessor: _mapEntry()),
          throwsA(_cloudFailure('protected_message_update_predecessor_changed')),
        );
        expect(store.box<CloudOutboxOperationEntity>().count(), 1);
        authority.verifyPermit(permit);
        final adopted = admit();
        authority.verifyPermit(permit);
        expect(adopted.operationId, isNot(first.operationId));
        expect(admit().operationId, adopted.operationId);
        expect(store.box<CloudOutboxOperationEntity>().count(), 2);
        expect((await cloudStore.readCheckpoint(_messageScope)).mutationRevisionCounter, 2);
        expect(immutableProof(second.id), proof);
        expect(
          () => journal.beginSubmission(
            intentId: second.id,
            committedSource: second.source,
            capturedAuth: _auth(),
            stillCurrent: () => true,
            now: _time(61),
          ),
          throwsA(_mutationFailure('owner_changed')),
        );
        await reopen();
        expect(authority.read(_writerScope)!.ownershipEpoch, original.epoch);
        expect(
          journal.readAdoptedForUpdate(
            operationId: adopted.operationId,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ).sameReflectedMutationAs(secondAdmission),
          isTrue,
        );
        expect(immutableProof(second.id), proof);
        expect(store.box<CloudOutboxOperationEntity>().count(), 2);
        await settleThroughFence(
          adopted,
          mutationIntentId: second.id,
          predecessor: expectedPredecessor,
          sequence: 2,
          reopenUnknown: true,
        );
        expect(authority.read(_writerScope)!.epoch, original.epoch + 4);
        expect(authority.read(_writerScope)!.ownershipEpoch, original.epoch);
        expect(
          journal.readTerminalSourceForCleanup(
            intentId: second.id,
            currentAuth: _auth(),
            stillCurrent: () => true,
          )?.encode(),
          second.source.encode(),
        );
        expect(immutableProof(second.id), proof);
        final settled = (await cloudStore.readOutboxEntries(_messageScope))
            .singleWhere((row) => row.operationId == adopted.operationId);
        expect(settled.status, CloudOutboxStatus.confirmed);
        expect(settled.attemptCount, 0,
            reason: 'Exact readback applies no retry/failure transition');
        expect(store.box<CloudOutboxOperationEntity>().count(), 2);
        await reopen();
        expect(
          journal.readTerminalSourceForCleanup(
            intentId: second.id,
            currentAuth: _auth(),
            stillCurrent: () => true,
          )?.encode(),
          second.source.encode(),
        );
        expect(immutableProof(second.id), proof);
      },
    );

    test('terminal cleanup survives a second actual fence to N+4', () async {
      final original = authority.read(_writerScope)!;
      final staleJournal = journal;
      final proof = immutableProof(intentId);
      final first = admit();
      await settleThroughFence(
        first,
        mutationIntentId: intentId,
        predecessor: expectedPredecessor,
      );
      // Leave the first source/IDS cleanup deferred while another update enters.
      final second = reflectSecond(at: 40);
      admissionSource = journal.readReflectedForUpdate(
        intentId: second.id,
        currentAuth: _auth(),
        stillCurrent: () => true,
      );
      expect(admissionSource.writerEpoch, original.epoch + 2);
      expectedPredecessor = await currentPredecessor();
      draft = _updateDraft(
        payload: 'e',
        reference: 'X',
        lease: 'e',
        createdAt: _time(60),
      );
      final permit = authority.issuePermit(
        _writerScope,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      expect(permit.epoch, original.epoch + 2);
      authority.verifyPermit(permit);
      final next = admit();
      await settleThroughFence(
        next,
        mutationIntentId: second.id,
        predecessor: expectedPredecessor,
        sequence: 2,
      );
      expect(authority.read(_writerScope)!.epoch, original.epoch + 4);
      expect(authority.read(_writerScope)!.ownershipEpoch, original.epoch);
      expect(
        staleJournal.readTerminalSourceForCleanup(
          intentId: intentId,
          currentAuth: _auth(),
          stillCurrent: () => true,
        )?.encode(),
        source.encode(),
        reason: 'Terminal cleanup rereads current ownership and grants no write permit',
      );
      await reopen();
      expect(
        journal.readTerminalSourceForCleanup(
          intentId: intentId,
          currentAuth: _auth(),
          stillCurrent: () => true,
        )?.encode(),
        source.encode(),
      );
      expect(immutableProof(intentId), proof);
      expect(store.box<CloudSyncLocalMutationIntentEntity>().get(intentId)!.state, 5);
      expect(store.box<CloudOutboxOperationEntity>().count(), 2);
    });

    for (final transition in ['reset', 'migration abort']) {
      test('$transition rejects old queued and terminal ownership lineage', () async {
        final original = authority.read(_writerScope)!;
        final second = reflectSecond();
        final queuedProof = immutableProof(second.id);
        final terminalProof = immutableProof(intentId);
        admissionSource = journal.readReflectedForUpdate(
          intentId: intentId,
          currentAuth: _auth(),
          stillCurrent: () => true,
        );
        await settleThroughFence(
          admit(),
          mutationIntentId: intentId,
          predecessor: expectedPredecessor,
        );
        final queued = journal.readReflectedForUpdate(
          intentId: second.id,
          currentAuth: _auth(),
          stillCurrent: () => true,
        );
        final before = authority.read(_writerScope)!;
        if (transition == 'reset') {
          final fence = authority.prepareReset(
            authority.issuePermit(_writerScope, expectedOwner: CloudKitWriterOwner.v2),
            request: CloudSyncResetRebootstrapRequest(
              scope: _messageScope,
              transitionIdHash: '1' * 64,
              activeIdentityFingerprint: _account,
              expectedGeneration: 1,
              protectedRemoteStateProofReference: 'obcs2.ref.${'Z' * 43}',
            ),
            now: _time(90),
          );
          // Retain the old DB rows to isolate the authority's lineage fence.
          authority.completeReset(
            fence,
            proof: CloudSyncResetCompletionProof(
              scope: _messageScope,
              transitionIdHash: '1' * 64,
              activeIdentityFingerprint: _account,
              previousGeneration: 1,
              generation: 2,
              protectedRemoteStateProofReference: 'obcs2.ref.${'Z' * 43}',
            ),
            now: _time(91),
          );
        } else {
          final legacy = ObjectBoxCloudKitWriterAuthority.forTest(
            store: store,
            buildDecision: CloudKitWriterOwnership.resolve('legacy'),
          );
          final prepared = legacy.prepareMigration(
            _writerScope,
            from: CloudKitWriterOwner.v2,
            to: CloudKitWriterOwner.legacy,
            expectedEpoch: before.epoch,
            transitionIdHash: '2' * 64,
            evidence: const CloudKitWriterTransitionEvidence.forTest(
              operationsQuiesced: true,
              activeIdentityRevalidated: true,
              legacyMutationQueues: LegacyMutationQueueDisposition.empty,
            ),
            now: _time(90),
          );
          legacy.abortMigration(
            _writerScope,
            targetOwner: CloudKitWriterOwner.legacy,
            expectedEpoch: prepared.epoch,
            transitionIdHash: '2' * 64,
            now: _time(91),
          );
        }
        await reopen();
        final predecessor = await currentPredecessor();
        final current = authority.read(_writerScope)!;
        expect(current.owner, CloudKitWriterOwner.v2);
        expect(current.epoch, original.epoch + 4);
        expect(current.ownershipEpoch, current.epoch);
        final permit = authority.issuePermit(
          _writerScope,
          expectedOwner: CloudKitWriterOwner.v2,
        );
        expect(permit.epoch, current.epoch);
        authority.verifyPermit(permit);
        expect(
          () => journal.readReflectedForUpdate(
            intentId: second.id,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('owner_changed')),
        );
        expect(
          () => cloudStore.admitProtectedLocalMutationUpdate(
            draft: _updateDraft(createdAt: _time(92)),
            expectedPredecessor: predecessor,
            journal: journal,
            source: queued,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('owner_changed')),
        );
        expect(
          () => journal.readTerminalSourceForCleanup(
            intentId: intentId,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('owner_changed')),
        );
        expect(immutableProof(second.id), queuedProof);
        expect(immutableProof(intentId), terminalProof);
        expect(store.box<CloudSyncLocalMutationIntentEntity>().get(second.id)!.state, 3);
        expect(store.box<CloudSyncLocalMutationIntentEntity>().get(intentId)!.state, 5);
        expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      });
    }

    test('legacy ownershipEpoch zero cannot adopt a retained state3 source', () async {
      final second = reflectSecond();
      final proof = immutableProof(second.id);
      admissionSource = journal.readReflectedForUpdate(
        intentId: intentId,
        currentAuth: _auth(),
        stillCurrent: () => true,
      );
      await settleThroughFence(
        admit(),
        mutationIntentId: intentId,
        predecessor: expectedPredecessor,
      );
      final queued = journal.readReflectedForUpdate(
        intentId: second.id,
        currentAuth: _auth(),
        stillCurrent: () => true,
      );
      final predecessor = await currentPredecessor();
      final epoch = authority.read(_writerScope)!.epoch;
      // Negative legacy/corruption fixture only; positive epochs use real fences.
      final entity = store.box<CloudKitWriterAuthorityEntity>().getAll().single
        ..ownershipEpoch = 0;
      store.box<CloudKitWriterAuthorityEntity>().put(entity);
      await reopen();
      expect(authority.read(_writerScope)!.epoch, epoch);
      expect(authority.read(_writerScope)!.ownershipEpoch, 0);
      final permit = authority.issuePermit(
        _writerScope,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      expect(permit.epoch, epoch);
      authority.verifyPermit(permit);
      expect(
        () => journal.readReflectedForUpdate(
          intentId: second.id,
          currentAuth: _auth(),
          stillCurrent: () => true,
        ),
        throwsA(_mutationFailure('owner_changed')),
      );
      expect(
        () => cloudStore.admitProtectedLocalMutationUpdate(
          draft: _updateDraft(createdAt: _time(60)),
          expectedPredecessor: predecessor,
          journal: journal,
          source: queued,
          currentAuth: _auth(),
          stillCurrent: () => true,
        ),
        throwsA(_mutationFailure('owner_changed')),
      );
      expect(immutableProof(second.id), proof);
      expect(store.box<CloudSyncLocalMutationIntentEntity>().get(second.id)!.state, 3);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
    });

    test('journal and one immutable outbox row commit atomically', () async {
      final operation = admit();
      final row = store.box<CloudSyncLocalMutationIntentEntity>().get(
        intentId,
      )!;
      final checkpoint = await cloudStore.readCheckpoint(_messageScope);

      expect(row.state, 4);
      expect(row.admittedOperationId, operation.operationId);
      expect(row.admittedBindingSha256, isNotNull);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(checkpoint.mutationRevisionCounter, 1);
      expect(operation.logicalEntityKeyHash, _logical);
      expect(operation.serverRecordIdHash, _server);
      expect(operation.payloadVersion, cloudSyncMessageUpdatePayloadVersion);
      journal.validateAdoptedOperation(
        store,
        operation,
        store.box<CloudRecordMapEntity>().getAll().single,
      );
    });

    test(
      'exact readback terminalizes mutation and releases both GC roots',
      () async {
        final operation = admit();
        final confirmedAt = _time(30);
        final entity = store.box<CloudOutboxOperationEntity>().getAll().single
          ..state = CloudOutboxStatus.confirmed.index
          ..protectedLeaseReference = null
          ..confirmedAtMs = confirmedAt.millisecondsSinceEpoch
          ..updatedAtMs = confirmedAt.millisecondsSinceEpoch;
        store.box<CloudOutboxOperationEntity>().put(entity);
        final confirmed = operation.copyWith(
          status: CloudOutboxStatus.confirmed,
          confirmedAt: confirmedAt,
          clearProtectedLeaseReference: true,
        );

        final terminalSource = journal.markExactReadbackConfirmed(
          intentId: intentId,
          operation: confirmed,
          currentAuth: _auth(),
          stillCurrent: () => true,
          now: _time(31),
        );
        expect(terminalSource.encode(), source.encode());
        expect(
          store.box<CloudSyncLocalMutationIntentEntity>().get(intentId)!.state,
          5,
        );
        expect(
          journal.readTerminalSourceForCleanup(
            intentId: intentId,
            currentAuth: _auth(),
            stillCurrent: () => true,
          )?.encode(),
          source.encode(),
        );
        expect(
          () => journal.readReflectedForUpdate(
            intentId: intentId,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('update_not_ready')),
        );
        expect(
          () => journal.readReceiptConfirmedSource(
            intentId: intentId,
            currentAuth: _auth(),
            stillCurrent: () => true,
          ),
          throwsA(_mutationFailure('ids_unconfirmed')),
        );
        expect(
          await cloudStore.readLiveProtectedOutboundLeaseReferences(
            maximumCount: 100,
          ),
          isNot(contains(source.leaseReference)),
        );
        expect(
          (await cloudStore.readLiveProtectedReferences(maximumCount: 100))
              .references,
          isNot(contains(source.protectedReference)),
        );

        await reopen();
        expect(
          journal.markExactReadbackConfirmed(
            intentId: intentId,
            operation: confirmed,
            currentAuth: _auth(),
            stillCurrent: () => true,
            now: _time(32),
          ).encode(),
          source.encode(),
        );
      },
    );

    test('identical retry and restart recover the same operation', () async {
      final first = admit();
      expect(admit().operationId, first.operationId);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(
        (await cloudStore.readCheckpoint(
          _messageScope,
        )).mutationRevisionCounter,
        1,
      );

      await reopen();
      admissionSource = journal.readReflectedForUpdate(
        intentId: intentId,
        currentAuth: _auth(),
        stillCurrent: () => true,
      );
      final recoveredRow = store
          .box<CloudSyncLocalMutationIntentEntity>()
          .get(intentId)!;
      expect(admissionSource.intentId, recoveredRow.id);
      expect(admissionSource.intentKey, recoveredRow.intentKey);
      expect(admissionSource.accountFingerprint, recoveredRow.accountFingerprint);
      expect(admissionSource.writerEpoch, recoveredRow.writerEpoch);
      expect(admissionSource.localMessageId, recoveredRow.localMessageId);
      expect(admissionSource.localChatId, recoveredRow.localChatId);
      expect(admissionSource.mutationGuidHash, recoveredRow.mutationGuidHash);
      expect(admissionSource.targetGuidHash, recoveredRow.targetGuidHash);
      expect(admissionSource.targetPart, recoveredRow.targetPart);
      expect(admissionSource.kind, recoveredRow.kind);
      expect(admissionSource.sourceSha256, recoveredRow.sourceSha256);
      expect(
        admissionSource.targetSnapshotSha256,
        recoveredRow.targetSnapshotSha256,
      );
      expect(
        admissionSource.protectedSourceBinding,
        recoveredRow.protectedSourceBinding,
      );
      expect(
        admissionSource.submissionAuthBindingSha256,
        recoveredRow.submissionAuthBindingSha256,
      );
      expect(
        admissionSource.idsReceiptBindingSha256,
        recoveredRow.idsReceiptBindingSha256,
      );
      expect(
        admissionSource.reflectedSnapshotSha256,
        recoveredRow.reflectedSnapshotSha256,
      );
      expect(
        admissionSource.adoptedOperationId,
        recoveredRow.admittedOperationId,
      );
      expect(admissionSource.createdAtMs, recoveredRow.createdAtMs);
      final recovered = admit();
      expect(recovered.operationId, first.operationId);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(
        (await cloudStore.readCheckpoint(
          _messageScope,
        )).mutationRevisionCounter,
        1,
      );
    });

    test('changed predecessor ETag rolls back outbox and journal', () {
      final row = store.box<CloudRecordMapEntity>().getAll().single
        ..etagHash = 'F' * 43;
      store.box<CloudRecordMapEntity>().put(row);
      expect(
        admit,
        throwsA(_cloudFailure('protected_message_update_predecessor_changed')),
      );
      expectRolledBack();
    });

    test('changed local reflection rolls back outbox and journal', () {
      final changed = store.box<Message>().get(target.id!)!
        ..text = 'newer edit';
      store.box<Message>().put(changed);
      expect(admit, throwsA(_mutationFailure('reflection_changed')));
      expectRolledBack();
    });

    test('changed native auth and stale session both roll back', () {
      expect(
        () => admit(auth: _auth(session: 'replacement-session')),
        throwsA(_mutationFailure('adoption_changed')),
      );
      expectRolledBack();
      expect(
        () => admit(stillCurrent: () => false),
        throwsA(_mutationFailure('auth_changed')),
      );
      expectRolledBack();
    });

    test('pre-dispatch validation rechecks the adopted predecessor', () {
      final operation = admit();
      final row = store.box<CloudRecordMapEntity>().getAll().single
        ..encryptedRawRecordRef = 'obcs2.ref.${'X' * 43}';
      store.box<CloudRecordMapEntity>().put(row);
      expect(
        () => journal.validateAdoptedOperation(
          store,
          operation,
          store.box<CloudRecordMapEntity>().getAll().single,
        ),
        throwsA(_mutationFailure('adoption_changed')),
      );
      expect(operation.operationId, isNotEmpty);
    });
  });

}

class _NoProtector implements CloudSyncProtector {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}
