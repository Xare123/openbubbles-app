import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_chat_state.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_create_selection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_media_source.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_parent_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_attachment_inventory.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_ownership.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

/// Actual-DB regressions for [CloudSyncHistoricalCreateSelection].
///
/// Uses synthetic receipt/projection rows, not a native or live-account proof.
final _now = DateTime.utc(2026, 9, 28);
final _account = 'A' * 43;
final _storeIdentity = 'obcs2.store.${'S' * 43}';
final _snapshot = 'a' * 64;

CloudSyncScope _scope(String zone) => CloudSyncScope(
  accountFingerprint: _account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
final _messageScope = _scope('messageManateeZone');
final _chatScope = _scope('chatManateeZone');

String _digest(Object fields) =>
    sha256.convert(utf8.encode(jsonEncode(fields))).toString();

String _guidHash(String guid) =>
    _digest(['cloud-sync-historical-archive-guid-v1', guid]);

CloudSyncNativeAuthSnapshot _auth() => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: 'synthetic-session',
  accountFingerprint: _account,
  protectedStoreIdentity: _storeIdentity,
  cloudMessagesClient: Object(),
);

CloudSyncHistoricalArchiveRequest _request({
  required String guid,
  required String chatGuid,
  String? sourceSha,
  String? groupCloudGuid,
  CloudSyncHistoricalMediaSource? media,
}) {
  final template = Chat(
    guid: chatGuid,
    style: 43,
    usingHandle: 'owner@example.invalid',
  )..cloudGuid = groupCloudGuid ?? 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
  return CloudSyncHistoricalArchiveRequest(
    guid: guid,
    guidHash: _guidHash(guid),
    sourceSha256: sourceSha ?? 'c' * 64,
    origin: CloudSyncHistoricalArchiveOrigin.historicalSent,
    isFromMe: true,
    chatGuid: chatGuid,
    dateCreatedMs: _now.millisecondsSinceEpoch - 1000,
    snapshotSha256: _snapshot,
    accountFingerprint: _account,
    protectedStoreIdentity: _storeIdentity,
    textSha256: 'f' * 64,
    senderAddress: 'owner@example.invalid',
    peerAddress: 'peer@example.invalid',
    groupMetadata: CloudSyncHistoricalGroupMetadata(
      cloudGuid: template.cloudGuid,
      participants: const [
        CloudSyncHistoricalParticipantView(
          address: 'peer@example.invalid',
          service: 'iMessage',
        ),
      ],
    ),
    parentState: CloudSyncHistoricalChatState.capture(template),
    media: media,
  );
}

CloudSyncHistoricalProtectedSourceBinding _source(
  CloudSyncHistoricalArchiveRequest request,
) => CloudSyncHistoricalProtectedSourceBinding(
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

CloudSyncHistoricalArchiveJournal _journal(Store store) =>
    CloudSyncHistoricalArchiveJournal(
      store: store,
      accountFingerprint: _account,
      protectedStoreIdentity: _storeIdentity,
      snapshotSha256: _snapshot,
      clock: () => _now,
    );

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudSyncStore durable;

  ObjectBoxCloudSyncStore _durable({
    CloudSyncAttachmentUploadJournal? uploads,
  }) => ObjectBoxCloudSyncStore(
    store: store,
    protector: _SyntheticProtector(),
    clock: () => _now,
    attachmentUploadJournal: uploads,
  );

  Future<void> _pullAll() async {
    for (final zone in [
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    ]) {
      await durable.recordPullSuccess(_scope(zone), now: _now);
    }
  }

  int _adopt(CloudSyncHistoricalArchiveRequest request) {
    final source = _source(request);
    final journal = _journal(store);
    final intentId = journal.adopt(source).id;
    journal.markSourceLeaseCommitted(
      intentId: intentId,
      expectedSource: source,
    );
    return intentId;
  }

  CloudSyncHistoricalParentOrigin _parentOrigin({
    required CloudSyncHistoricalArchiveRequest request,
    required int intentId,
    required int? chatId,
    required int generation,
  }) => CloudSyncHistoricalParentOrigin.capture(
    store: store,
    journal: _journal(store),
    scope: _chatScope,
    generation: generation,
    request: request,
    intentId: intentId,
    localChatId: chatId,
    parentPayloadLength: 1024,
  );

  CloudOutboxOperation _admitParent(
    CloudSyncHistoricalParentOrigin origin, {
    String logical = 'LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL',
    String server = 'RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR',
  }) => durable.admitProtectedHistoricalChatCreate(
    origin: origin,
    draft: CloudOutboxDraft(
      scope: _chatScope,
      logicalEntityKeyHash: logical,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncOutboundChatPayloadVersion,
      dependencyOperationIds: const {},
      createdAt: _now,
      encryptedPayloadReference: 'obcs2.ref.${'P' * 43}',
      payloadSha256: 'd' * 64,
      serverRecordIdHash: server,
      protectedLeaseReference: 'obcs2.lease.${'e' * 32}',
    ),
    recordMapping: CloudRecordMapEntry(
      scope: _chatScope,
      logicalEntityKeyHash: logical,
      serverRecordIdHash: server,
      encryptedServerRecordId: 'obcs2.ref.${'P' * 43}',
      updatedAt: _now,
    ),
  );

  CloudOutboxOperation _admitMessage({
    required CloudSyncHistoricalArchiveRequest request,
    required int intentId,
    required int chatId,
    required int generation,
  }) {
    final selected = _journal(store).readForCreateAdmission(
      scope: _messageScope,
      intentId: intentId,
      currentAuth: _auth(),
      request: request,
      localChatId: chatId,
      generation: generation,
      logicalEntityKeyHash: 'L' * 43,
      serverRecordIdHash: 'M' * 43,
    );
    return durable.admitProtectedHistoricalCreate(
      draft: CloudOutboxDraft(
        scope: _messageScope,
        logicalEntityKeyHash: 'L' * 43,
        action: CloudOutboxAction.save,
        payloadVersion: cloudSyncOutboundPayloadVersion,
        dependencyOperationIds: const {},
        createdAt: _now,
        encryptedPayloadReference: 'obcs2.ref.${'V' * 43}',
        payloadSha256: 'e' * 64,
        serverRecordIdHash: 'M' * 43,
        protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
      ),
      recordMapping: CloudRecordMapEntry(
        scope: _messageScope,
        logicalEntityKeyHash: 'L' * 43,
        serverRecordIdHash: 'M' * 43,
        encryptedServerRecordId: 'obcs2.ref.${'V' * 43}',
        updatedAt: _now,
      ),
      journal: _journal(store),
      source: selected,
      currentAuth: _auth(),
      stillCurrent: () => true,
    );
  }

  CloudSyncScope _attachmentScope() => _scope('attachmentManateeZone');

  late ObjectBoxCloudKitWriterAuthority _authority;

  void _provisionAuthority() {
    _authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    final scope = CloudKitWriterScope(accountFingerprint: _account);
    final disabled = _authority.initializeDisabled(scope, now: _now);
    _authority.provisionInitialOwner(
      scope,
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

  CloudSyncAttachmentUploadJournal _uploads({int generation = 1}) =>
      CloudSyncAttachmentUploadJournal(
        store: store,
        localSends: CloudSyncLocalSendJournal(
          store: store,
          authority: _authority,
          authoritySnapshot: _authority.read(
            CloudKitWriterScope(accountFingerprint: _account),
          )!,
        ),
        scope: _attachmentScope(),
        checkpointGeneration: generation,
        currentAuth: _auth(),
        writerAuthority: _authority,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'historical-create-selection-',
    );
    store = await openStore(directory: directory.path);
    durable = _durable();
    await _pullAll();
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'parent-only selection owns the single historical chat operation',
    () async {
      final request = _request(
        guid: 'synthetic-original-message',
        chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      );
      final intentId = _adopt(request);
      final chatGeneration = (await durable.readCheckpoint(
        _chatScope,
      )).generation;
      final parent = _admitParent(
        _parentOrigin(
          request: request,
          intentId: intentId,
          chatId: null,
          generation: chatGeneration,
        ),
      );
      final selection = CloudSyncHistoricalCreateSelection(
        request: request,
        intentId: intentId,
        localChatId: null,
      );
      final message = selection.validate(
        store: store,
        scope: _messageScope,
        journal: _journal(store),
        durable: durable,
        auth: _auth(),
      );
      expect(message, isNull);
      expect(selection.chatOperation?.operationId, parent.operationId);
      expect(selection.owns(parent), isTrue);
      expect(selection.canDrain([parent]), isTrue);
      final again = selection.validate(
        store: store,
        scope: _messageScope,
        journal: _journal(store),
        durable: durable,
        auth: _auth(),
      );
      expect(again, isNull);
      expect(selection.chatOperation?.operationId, parent.operationId);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );

  test('parent plus message selection owns both operations', () async {
    // Group lane end to end: the parent chat is missing locally, so it is
    // admitted with no destination first. The restored rows seeded below
    // only model that parent CONFIRMED readback and canonical group
    // projection for this selection-only test (synthetic, no native-proof
    // claim); admission behavior itself stays covered by the separate
    // parent-admission tests.
    final request = _request(
      guid: 'synthetic-combined-message',
      chatGuid: 'iMessage;+;historical-group',
      groupCloudGuid: 'original-cloud-group',
    );
    final intentId = _adopt(request);
    final chatGeneration = (await durable.readCheckpoint(
      _chatScope,
    )).generation;
    final parent = _admitParent(
      _parentOrigin(
        request: request,
        intentId: intentId,
        chatId: null,
        generation: chatGeneration,
      ),
      logical: syntheticRestoredChatLogicalEntityKeyHash(request.chatGuid),
    );
    final parentRow = store.box<CloudOutboxOperationEntity>().getAll().single
      ..state = CloudOutboxStatus.confirmed.index
      ..confirmedAtMs = _now.millisecondsSinceEpoch
      ..appleRequestUuid = '11111111-2222-4333-8444-555555555555'
      ..appleOperationUuid = 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE'
      ..protectedLeaseReference = null;
    store.box<CloudOutboxOperationEntity>().put(parentRow);
    final peer = Handle(address: 'peer@example.invalid', service: 'iMessage');
    final peers = [
      peer,
      Handle(address: 'second@example.invalid', service: 'iMessage'),
    ];
    store.box<Handle>().putMany(peers);
    final chat =
        Chat(
            guid: 'iMessage;+;historical-group',
            chatIdentifier: 'historical-group',
            usingHandle: 'mailto:owner@example.invalid',
            style: 43,
          )
          ..cloudGuid = 'original-cloud-group'
          ..groupVersion = 9;
    chat.handles.addAll(peers);
    store.box<Chat>().put(chat);
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: store,
      store: durable,
      chatScope: _chatScope,
      now: _now,
      recordIdHash: parent.serverRecordIdHash,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: store,
      store: durable,
      chatScope: _chatScope,
      chat: chat,
      appliedSource: applied,
      now: _now,
    );
    // The generic proof fixture retains an existing write mapping's protected
    // identity. Model the ordinary semantic reader's authenticated replacement
    // here, including any mirrored Chat-member mapping. This is fixture setup,
    // not permission for production to replace an unverified record reference.
    final projectedMaps = store.box<CloudRecordMapEntity>().getAll().where(
      (row) => row.scopeKey == applied.scopeKey &&
          row.generation == applied.generation &&
          row.logicalEntityKeyHash == parent.logicalEntityKeyHash &&
          row.serverRecordIdHash == applied.serverRecordIdHash,
    ).toList();
    expect(projectedMaps, isNotEmpty);
    for (final mapping in projectedMaps) {
      expect(mapping.etagHash, applied.etagHash);
      expect(mapping.encryptedRawRecordRef, applied.encryptedPayloadRef);
      mapping.encryptedServerRecordId = applied.encryptedServerRecordId!;
    }
    store.box<CloudRecordMapEntity>().putMany(projectedMaps);
    final messageGeneration = (await durable.readCheckpoint(
      _messageScope,
    )).generation;
    final message = _admitMessage(
      request: request,
      intentId: intentId,
      chatId: chat.id!,
      generation: messageGeneration,
    );
    final selection = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: chat.id!,
    );
    final validated = selection.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
    );
    expect(validated?.operationId, message.operationId);
    expect(selection.chatOperation?.operationId, parent.operationId);
    expect(selection.owns(parent), isTrue);
    expect(selection.owns(message), isTrue);
    expect(selection.canDrain([parent, message]), isTrue);
  });

  test('restart with the original parent reopens ownership', () async {
    final request = _request(
      guid: 'synthetic-original-message',
      chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
    );
    final intentId = _adopt(request);
    final chatGeneration = (await durable.readCheckpoint(
      _chatScope,
    )).generation;
    final parent = _admitParent(
      _parentOrigin(
        request: request,
        intentId: intentId,
        chatId: null,
        generation: chatGeneration,
      ),
    );
    final selection = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: null,
    );
    selection.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
    );
    store.close();
    store = await openStore(directory: directory.path);
    durable = _durable();
    final reopened = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: null,
    );
    final message = reopened.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
    );
    expect(message, isNull);
    expect(reopened.chatOperation?.operationId, parent.operationId);
    expect(reopened.owns(parent), isTrue);
  });

  test('unrelated pending historical work fails closed', () async {
    final first = _request(
      guid: 'synthetic-original-message',
      chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
    );
    final firstId = _adopt(first);
    final chatGeneration = (await durable.readCheckpoint(
      _chatScope,
    )).generation;
    final firstParent = _admitParent(
      _parentOrigin(
        request: first,
        intentId: firstId,
        chatId: null,
        generation: chatGeneration,
      ),
    );
    final selection = CloudSyncHistoricalCreateSelection(
      request: first,
      intentId: firstId,
      localChatId: null,
    );
    selection.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
    );
    final second = _request(
      guid: 'synthetic-unrelated-message',
      chatGuid: 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',
      sourceSha: 'd' * 64,
      groupCloudGuid: 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC',
    );
    final secondId = _adopt(second);
    final secondGeneration = (await durable.readCheckpoint(
      _chatScope,
    )).generation;
    _admitParent(
      _parentOrigin(
        request: second,
        intentId: secondId,
        chatId: null,
        generation: secondGeneration,
      ),
      logical: 'MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM',
      server: 'NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN',
    );
    expect(
      () => selection.validate(
        store: store,
        scope: _messageScope,
        journal: _journal(store),
        durable: durable,
        auth: _auth(),
      ),
      throwsStateError,
    );
    expect(selection.owns(firstParent), isTrue);
  });

  test('altered historical source fails closed', () async {
    final request = _request(
      guid: 'synthetic-original-message',
      chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
    );
    final intentId = _adopt(request);
    final chatGeneration = (await durable.readCheckpoint(
      _chatScope,
    )).generation;
    _admitParent(
      _parentOrigin(
        request: request,
        intentId: intentId,
        chatId: null,
        generation: chatGeneration,
      ),
    );
    final selection = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: null,
    );
    selection.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
    );
    final rows = store.box<CloudSyncHistoricalArchiveIntentEntity>();
    final row = rows.get(intentId)!;
    row.protectedSourceBinding = row.protectedSourceBinding.replaceFirst(
      'c' * 64,
      'd' * 64,
    );
    rows.put(row);
    expect(
      () => selection.validate(
        store: store,
        scope: _messageScope,
        journal: _journal(store),
        durable: durable,
        auth: _auth(),
      ),
      throwsStateError,
    );
  });

  CloudSyncHistoricalMediaSource _mediaFor({
    required String rowGuid,
    required int rowMessageId,
    required String partGuid,
  }) {
    final attachment = Attachment(
      id: 21,
      guid: partGuid,
      uti: 'public.jpeg',
      mimeType: 'image/jpeg',
      isOutgoing: true,
      transferName: 'photo.jpg',
      totalBytes: 128,
    )..message.targetId = rowMessageId;
    final inventory = CloudSyncHistoricalAttachmentInventory.capture([
      attachment,
    ]);
    final view = CloudSyncHistoricalRowView(
      guid: rowGuid,
      text: null,
      attributedBodies: [
        AttributedBody(
          string: ' ',
          runs: [
            Run(
              range: [0, 1],
              attributes: Attributes(messagePart: 0, attachmentGuid: partGuid),
            ),
          ],
        ),
      ],
      hasActualEditOrUnsend: false,
      dateEditedPresent: false,
      associationPresent: false,
      isFromMe: true,
      senderAddress: 'owner@example.invalid',
      chat: const CloudSyncHistoricalChatView(
        id: 1,
        guid: 'media-chat',
        style: 45,
        chatIdentifier: 'peer@example.invalid',
        isRoutingStub: false,
        dateDeletedPresent: false,
        isRpSms: false,
        participantCount: 1,
        participantAddress: 'peer@example.invalid',
        participantService: 'iMessage',
      ),
      dateCreatedMs: _now.millisecondsSinceEpoch - 1000,
      error: 0,
      isTemp: false,
      stagingGuid: null,
      sendingServiceId: null,
      hasBeenForwarded: false,
      verificationFailed: false,
      ckRecordId: null,
      ckSyncState: false,
      messageId: rowMessageId,
      itemType: 0,
      groupActionType: 0,
      groupTitle: null,
      isDeleted: false,
      dateScheduledPresent: false,
      threadOriginatorPresent: false,
      hasAttachments: true,
      attachmentCount: 1,
      subjectPresent: false,
      expressiveSendStyleIdPresent: false,
      balloonBundleIdPresent: false,
      payloadDataPresent: false,
      hasApplePayloadData: false,
      amkSessionIdPresent: false,
      rowSnapshotSha256: _snapshot,
      attachmentInventory: inventory,
    );
    return CloudSyncHistoricalMediaSource.capture(view);
  }

  CloudOutboxOperation _admitChild({
    required int intentId,
    required String logical,
    required CloudSyncAttachmentUploadJournal uploads,
    required int generation,
  }) {
    const attemptId = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
    final plan = CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: logical,
      protectedEnvelopeReference: 'obcs2.ref.${'P' * 43}',
      payloadSha256: 'e' * 64,
      serverRecordIdHash: 'M' * 43,
      leaseReference: 'obcs2.lease.${'f' * 32}',
    );
    final adopted = uploads.adoptHistoricalPlan(
      historicalIntentId: intentId,
      plan: plan,
      now: _now,
      historicalJournal: _journal(store),
    );
    uploads.beginHistoricalAttempt(
      id: adopted.id,
      attemptId: attemptId,
      now: _now,
      historicalJournal: _journal(store),
    );
    uploads.recordHistoricalUploaded(
      id: adopted.id,
      attemptId: attemptId,
      result: plan,
      now: _now,
      historicalJournal: _journal(store),
    );
    final operationId = CloudOperationIdentity.forInitialCreate(
      scope: _attachmentScope(),
      logicalEntityKeyHash: logical,
      payloadVersion: 1,
    );
    store.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: operationId,
        scopeKey: cloudSyncPersistentScopeKey(_attachmentScope()),
        accountFingerprint: _account,
        zone: 'attachmentManateeZone',
        logicalEntityKeyHash: logical,
        action: CloudOutboxAction.save.index,
        mutationRevision: 1,
        checkpointGeneration: generation,
        encryptedPayloadRef: 'obcs2.ref.${'P' * 43}',
        payloadSha256: 'e' * 64,
        protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
        serverRecordIdHash: 'M' * 43,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    uploads.adoptHistoricalRecordCreate(
      id: adopted.id,
      now: _now,
      historicalJournal: _journal(store),
      admit: (transactionStore, result) => CloudOutboxOperation(
        scope: _attachmentScope(),
        operationId: operationId,
        logicalEntityKeyHash: logical,
        action: CloudOutboxAction.save,
        payloadVersion: 1,
        mutationRevision: 1,
        checkpointGeneration: generation,
        dependencyOperationIds: const {},
        createdAt: _now,
        encryptedPayloadReference: 'obcs2.ref.${'P' * 43}',
        payloadSha256: 'e' * 64,
        serverRecordIdHash: 'M' * 43,
        protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
      ),
    );
    return durable.readHistoricalAttachmentOperation(
      _attachmentScope(),
      operationId,
      _journal(store),
    );
  }

  test('selection owns admitted historical child attachments', () async {
    _provisionAuthority();
    final generation = (await durable.readCheckpoint(
      _attachmentScope(),
    )).generation;
    final uploads = _uploads(generation: generation);
    durable = _durable(uploads: uploads);
    final media = _mediaFor(
      rowGuid: 'synthetic-combined-media',
      rowMessageId: 11,
      partGuid: 'synthetic-combined-media_0',
    );
    final request = _request(
      guid: 'synthetic-combined-media',
      chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      media: media,
    );
    final intentId = _adopt(request);
    final child = _admitChild(
      intentId: intentId,
      logical: 'C' * 43,
      uploads: uploads,
      generation: generation,
    );
    final selection = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: null,
    );
    expect(
      selection.validate(
        store: store,
        scope: _messageScope,
        journal: _journal(store),
        durable: durable,
        auth: _auth(),
        attachmentUploadJournal: uploads,
      ),
      isNull,
    );
    expect(selection.owns(child), isTrue);
    expect(selection.canDrain([child]), isTrue);
  });

  test('reopened selection re-resolves admitted children', () async {
    _provisionAuthority();
    final generation = (await durable.readCheckpoint(
      _attachmentScope(),
    )).generation;
    var uploads = _uploads(generation: generation);
    durable = _durable(uploads: uploads);
    final media = _mediaFor(
      rowGuid: 'synthetic-combined-media',
      rowMessageId: 11,
      partGuid: 'synthetic-combined-media_0',
    );
    final request = _request(
      guid: 'synthetic-combined-media',
      chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      media: media,
    );
    final intentId = _adopt(request);
    final child = _admitChild(
      intentId: intentId,
      logical: 'C' * 43,
      uploads: uploads,
      generation: generation,
    );
    var selection = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: null,
    );
    selection.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
      attachmentUploadJournal: uploads,
    );
    expect(selection.owns(child), isTrue);
    store.close();
    store = await openStore(directory: directory.path);
    _authority = ObjectBoxCloudKitWriterAuthority.forTest(
      store: store,
      buildDecision: CloudKitWriterOwnership.resolve('v2'),
    );
    uploads = _uploads(generation: generation);
    durable = _durable(uploads: uploads);
    selection = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: null,
    );
    selection.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
      attachmentUploadJournal: uploads,
    );
    expect(selection.owns(child), isTrue);
    expect(selection.canDrain([child]), isTrue);
  });

  test('alien child fails closed', () async {
    _provisionAuthority();
    final generation = (await durable.readCheckpoint(
      _attachmentScope(),
    )).generation;
    final uploads = _uploads(generation: generation);
    durable = _durable(uploads: uploads);
    final media = _mediaFor(
      rowGuid: 'synthetic-combined-media',
      rowMessageId: 11,
      partGuid: 'synthetic-combined-media_0',
    );
    final first = _request(
      guid: 'synthetic-combined-media',
      chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      media: media,
    );
    final firstId = _adopt(first);
    final selection = CloudSyncHistoricalCreateSelection(
      request: first,
      intentId: firstId,
      localChatId: null,
    );
    selection.validate(
      store: store,
      scope: _messageScope,
      journal: _journal(store),
      durable: durable,
      auth: _auth(),
      attachmentUploadJournal: uploads,
    );
    final alienMedia = _mediaFor(
      rowGuid: 'synthetic-alien-media',
      rowMessageId: 12,
      partGuid: 'synthetic-alien-media_0',
    );
    final second = _request(
      guid: 'synthetic-alien-media',
      chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      sourceSha: 'd' * 64,
      media: alienMedia,
    );
    final secondId = _adopt(second);
    _admitChild(
      intentId: secondId,
      logical: 'Q' * 43,
      uploads: uploads,
      generation: generation,
    );
    expect(
      () => selection.validate(
        store: store,
        scope: _messageScope,
        journal: _journal(store),
        durable: durable,
        auth: _auth(),
        attachmentUploadJournal: uploads,
      ),
      throwsStateError,
    );
  });

  test('media-less selection rejects present child rows', () async {
    _provisionAuthority();
    final generation = (await durable.readCheckpoint(
      _attachmentScope(),
    )).generation;
    final uploads = _uploads(generation: generation);
    durable = _durable(uploads: uploads);
    final media = _mediaFor(
      rowGuid: 'synthetic-combined-media',
      rowMessageId: 11,
      partGuid: 'synthetic-combined-media_0',
    );
    final intentId = _adopt(
      _request(
        guid: 'synthetic-combined-media',
        chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        media: media,
      ),
    );
    _admitChild(
      intentId: intentId,
      logical: 'C' * 43,
      uploads: uploads,
      generation: generation,
    );
    final bare = CloudSyncHistoricalCreateSelection(
      request: _request(
        guid: 'synthetic-combined-media',
        chatGuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      ),
      intentId: intentId,
      localChatId: null,
    );
    expect(
      () => bare.validate(
        store: store,
        scope: _messageScope,
        journal: _journal(store),
        durable: durable,
        auth: _auth(),
        attachmentUploadJournal: uploads,
      ),
      throwsStateError,
    );
  });
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
