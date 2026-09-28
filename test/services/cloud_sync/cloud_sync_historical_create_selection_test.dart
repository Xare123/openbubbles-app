import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_chat_state.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_create_selection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_parent_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
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

  ObjectBoxCloudSyncStore _durable() => ObjectBoxCloudSyncStore(
    store: store,
    protector: _SyntheticProtector(),
    clock: () => _now,
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
