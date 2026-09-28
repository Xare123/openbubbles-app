import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_create_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_create_selection.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_outbox_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_producer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_consumer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_restored_chat_test_fixture.dart';

final _now = DateTime.utc(2026, 9, 27, 12);
final _account = 'A' * 43;
final _protectedStore = 'obcs2.store.${'S' * 43}';
const _guid = 'historical-synthetic-original';
String _hash(Object fields) =>
    sha256.convert(utf8.encode(jsonEncode(fields))).toString();
CloudSyncScope _scope(String zone) => CloudSyncScope(
  accountFingerprint: _account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
final _messageScope = _scope('messageManateeZone');

void main() {
  late Directory directory;
  late Store store;
  late Chat chat;
  late Handle sender;
  late CloudSyncHistoricalProtectedSourceBinding source;
  late CloudSyncHistoricalArchiveRequest request;
  late List<int> canonicalBytes;
  late CloudSyncHistoricalRowView sourceView;
  late int intentId;
  late int generation;

  final auth = CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: 'synthetic-session',
    accountFingerprint: _account,
    protectedStoreIdentity: _protectedStore,
    cloudMessagesClient: Object(),
  );
  ObjectBoxCloudSyncStore durable({void Function()? validate}) =>
      ObjectBoxCloudSyncStore(
        store: store,
        protector: _SyntheticProtector(),
        clock: () => _now,
        validateOutboxDispatch: validate,
      );
  CloudSyncHistoricalArchiveJournal journal() =>
      CloudSyncHistoricalArchiveJournal(
        store: store,
        accountFingerprint: _account,
        protectedStoreIdentity: _protectedStore,
        snapshotSha256: source.snapshotSha256,
        clock: () => _now,
      );
  CloudSyncHistoricalArchiveIntentEntity row() =>
      store.box<CloudSyncHistoricalArchiveIntentEntity>().get(intentId)!;
  CloudSyncHistoricalCreateSource selection() =>
      journal().readForCreateAdmission(
        scope: _messageScope,
        intentId: intentId,
        currentAuth: auth,
        request: request,
        localChatId: chat.id!,
        generation: generation,
        logicalEntityKeyHash: 'L' * 43,
        serverRecordIdHash: 'M' * 43,
      );
  Future<CloudOutboxOperation> adoptStage(
    _StageTransport transport, {
    ObjectBoxCloudSyncStore? database,
    CloudSyncHistoricalCreateSource Function()? select,
    Future<void> Function()? validate,
  }) {
    final target = database ?? durable();
    return adoptCloudSyncHistoricalCreateStage(
      stage: api.CloudSyncProtectedOutboundStage(
        logicalEntityKeyHash: 'L' * 43,
        serverRecordIdHash: 'M' * 43,
        protectedPayloadReference: 'obcs2.ref.${'V' * 43}',
        protectedServerRecordReference: 'obcs2.ref.${'V' * 43}',
        payloadSha256: 'e' * 64,
        payloadLength: BigInt.from(128),
        leaseReference: 'obcs2.lease.${'f' * 32}',
      ),
      scope: _messageScope,
      generation: generation,
      durable: target,
      journal: journal(),
      selectSource: select ?? selection,
      auth: auth,
      validate: validate ?? () async {},
      stillCurrent: () => true,
      lifecycle: CloudProtectedPageLeaseLifecycle(
        store: target,
        transport: transport,
      ),
      transport: transport,
    );
  }

  CloudOutboxOperation admit(
    CloudSyncHistoricalCreateSource selected, {
    bool Function()? current,
  }) {
    final draft = CloudOutboxDraft(
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
    );
    return durable().admitProtectedHistoricalCreate(
      draft: draft,
      recordMapping: CloudRecordMapEntry(
        scope: _messageScope,
        logicalEntityKeyHash: draft.logicalEntityKeyHash,
        serverRecordIdHash: draft.serverRecordIdHash!,
        encryptedServerRecordId: draft.encryptedPayloadReference!,
        updatedAt: _now,
      ),
      journal: journal(),
      source: selected,
      currentAuth: auth,
      stillCurrent: current ?? () => true,
    );
  }

  Message localMessage() => Message(
    guid: _guid,
    text: 'synthetic original text',
    attributedBody: [AttributedBody.raw('synthetic original text')],
    isFromMe: true,
    dateCreated: _now.subtract(const Duration(days: 3)),
    handle: sender,
  )..chat.target = chat;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ob-history-create-');
    store = await openStore(directory: directory.path);
    final peer = Handle(address: 'peer@example.invalid', service: 'iMessage');
    sender = Handle(
      address: 'owner@example.invalid',
      service: 'iMessage',
      originalROWID: 102,
    );
    store.box<Handle>().putMany([peer, sender]);
    chat = Chat(
      guid: 'iMessage;-;peer@example.invalid',
      chatIdentifier: peer.address,
      usingHandle: 'mailto:owner@example.invalid',
      style: 45,
      isRpSms: false,
      participants: [peer],
    )..handles.add(peer);
    store.box<Chat>().put(chat);
    final database = durable();
    for (final zone in [
      'messageManateeZone',
      'chatManateeZone',
      'attachmentManateeZone',
    ]) {
      await database.recordPullSuccess(_scope(zone), now: _now);
    }
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: store,
      store: database,
      chatScope: _scope('chatManateeZone'),
      now: _now,
    );
    await seedSyntheticRestoredChatProof(
      objectBox: store,
      store: database,
      chatScope: _scope('chatManateeZone'),
      chat: chat,
      appliedSource: applied,
      now: _now,
    );
    generation = (await database.readCheckpoint(_messageScope)).generation;

    // Construct a snapshot source using real persisted model semantics, then
    // remove only this synthetic fixture row so the target models Alpha import.
    final fixture = localMessage();
    final fixtureId = store.box<Message>().put(fixture);
    sourceView = mapHistoricalRow(
      message: fixture,
      chat: mapHistoricalChat(chat),
      rowSnapshotSha256: 'a' * 64,
    );
    final assessed = assessHistoricalArchiveRow(
      sourceView,
      CloudSyncHistoricalSourceManifest(
        snapshotSha256: 'a' * 64,
        accountFingerprint: _account,
        accountHandles: [sender.address],
        messageCount: 1,
        capturedAtMs: _now.millisecondsSinceEpoch,
      ),
      CloudSyncHistoricalAccountBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: _protectedStore,
      ),
      nowMs: _now.millisecondsSinceEpoch,
    );
    expect(
      assessed,
      isA<CloudSyncHistoricalArchiveEligible>(),
      reason: assessed is CloudSyncHistoricalArchiveIneligible
          ? assessed.reason
          : null,
    );
    request = (assessed as CloudSyncHistoricalArchiveEligible).request;
    canonicalBytes = utf8.encode(
      jsonEncode(
        stagedHistoricalPayload(
          request: request,
          text: 'synthetic original text',
        ),
      ),
    );
    store.box<Message>().remove(fixtureId);
    source = CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _protectedStore,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
      protectedReference: 'obcs2.ref.${'R' * 43}',
      leaseReference: 'obcs2.lease.${'b' * 32}',
      payloadSha256: historicalBytesSha256(canonicalBytes),
      payloadLength: canonicalBytes.length,
    );
    intentId = journal().adopt(source).id;
    journal().markSourceLeaseCommitted(
      intentId: intentId,
      expectedSource: source,
    );
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'historical adoption survives restart without inserting a fake Message',
    () async {
      final selected = selection();
      final operation = admit(selected);
      final retained = row().admittedBinding;
      expect(row().state, 3);
      expect(store.box<Message>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
      store.close();
      store = await openStore(directory: directory.path);
      final reopened = durable().readHistoricalArchiveOperation(
        _messageScope,
        operation.operationId,
      )!;
      expect(reopened.operationId, operation.operationId);
      expect(
        durable().readHistoricalArchiveSource(reopened)!.sameSourceAs(selected),
        isTrue,
      );
      expect(row().admittedBinding, retained);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(store.box<Message>().count(), 0);
      journal().requireAdoptedDispatch(
        transactionStore: store,
        operation: reopened,
      );
    },
  );

  test('lost adoption return reuses the exact outbox row and revision', () {
    final selected = selection();
    final first = admit(selected);
    final repeated = admit(selected);
    expect(repeated.operationId, first.operationId);
    expect(repeated.mutationRevision, first.mutationRevision);
    expect(row().state, 3);
    expect(store.box<CloudOutboxOperationEntity>().count(), 1);
  });

  test('historical group adoption reopens without live-send provenance', () async {
    final peers = [
      Handle(address: 'peer@example.invalid', service: 'iMessage'),
      Handle(address: 'second@example.invalid', service: 'iMessage'),
    ];
    store.box<Handle>().putMany(peers);
    chat = Chat(guid: 'iMessage;+;historical-group',
      chatIdentifier: 'historical-group', style: 43,
      usingHandle: 'mailto:owner@example.invalid')
      ..cloudGuid = 'original-cloud-group'
      ..groupVersion = 9;
    chat.handles.addAll(peers);
    store.box<Chat>().put(chat);
    final database = durable();
    final applied = await seedSyntheticRestoredChatAppliedSource(
      objectBox: store, store: database, chatScope: _scope('chatManateeZone'),
      now: _now, recordIdHash: 'G' * 43);
    await seedSyntheticRestoredChatProof(objectBox: store, store: database,
      chatScope: _scope('chatManateeZone'), chat: chat,
      appliedSource: applied, now: _now);
    final message = localMessage()..guid = 'historical-group-original';
    final messageId = store.box<Message>().put(message);
    final assessment = assessHistoricalArchiveRow(mapHistoricalRow(
      message: message, chat: mapHistoricalChat(chat), rowSnapshotSha256: 'a' * 64),
      CloudSyncHistoricalSourceManifest(snapshotSha256: 'a' * 64,
        accountFingerprint: _account, accountHandles: [sender.address],
        messageCount: 1, capturedAtMs: _now.millisecondsSinceEpoch),
      CloudSyncHistoricalAccountBinding(accountFingerprint: _account,
        protectedStoreIdentity: _protectedStore), nowMs: _now.millisecondsSinceEpoch);
    expect(assessment, isA<CloudSyncHistoricalArchiveEligible>());
    request = (assessment as CloudSyncHistoricalArchiveEligible).request;
    canonicalBytes = utf8.encode(jsonEncode(stagedHistoricalPayload(
      request: request, text: message.text!)));
    source = CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: _account, protectedStoreIdentity: _protectedStore,
      snapshotSha256: request.snapshotSha256, messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256, protectedReference: 'obcs2.ref.${'T' * 43}',
      leaseReference: 'obcs2.lease.${'c' * 32}',
      payloadSha256: historicalBytesSha256(canonicalBytes), payloadLength: canonicalBytes.length);
    intentId = journal().adopt(source).id;
    journal().markSourceLeaseCommitted(intentId: intentId, expectedSource: source);
    final selected = selection();
    expect(jsonDecode(selected.parentBinding)[0], 3);
    final operation = admit(selected);
    expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
    expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
    store.close();
    store = await openStore(directory: directory.path);
    final reopened = durable().readHistoricalArchiveOperation(_messageScope, operation.operationId)!;
    expect(durable().readHistoricalArchiveSource(reopened)!.sameSourceAs(selected), isTrue);
    journal().requireAdoptedDispatch(transactionStore: store, operation: reopened);
    final retained = store.box<Message>().get(messageId)!;
    expect(retained.text, message.text);
    store.box<Chat>().put(store.box<Chat>().get(chat.id!)!..cloudGuid = 'changed-group');
    expect(() => journal().requireAdoptedDispatch(transactionStore: store,
      operation: reopened), throwsA(anyOf(isA<StateError>(), isA<CloudSyncFailure>())));
    expect(store.box<Message>().get(messageId)!.text, message.text);
    expect(row().admittedOperationId, operation.operationId);
  });

  test(
    'native stage is committed only after durable historical adoption',
    () async {
      final transport = _StageTransport()
        ..beforeCommit = () {
          expect(row().state, 3);
          expect(store.box<CloudOutboxOperationEntity>().count(), 1);
        };
      final operation = await adoptStage(transport);
      expect(transport.committed, ['obcs2.lease.${'f' * 32}']);
      expect(transport.rolledBack, isEmpty);
      expect(row().admittedOperationId, operation.operationId);
      expect(operation.status, CloudOutboxStatus.pending);
    },
  );

  test(
    'source selection failure rolls back only the unowned create stage',
    () async {
      final transport = _StageTransport();
      await expectLater(
        adoptStage(
          transport,
          select: () => throw StateError('synthetic source changed'),
        ),
        throwsStateError,
      );
      expect(transport.rolledBack, ['obcs2.lease.${'f' * 32}']);
      expect(transport.committed, isEmpty);
      expect(row().state, 1);
      expect(row().protectedSourceBinding, source.encode());
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'lost native commit response retains exact queue ownership for recovery',
    () async {
      final transport = _StageTransport()..failCommit = true;
      await expectLater(adoptStage(transport), throwsStateError);
      final operationId = row().admittedOperationId!;
      expect(transport.rolledBack, isEmpty);
      expect(row().state, 3);
      store.close();
      store = await openStore(directory: directory.path);
      final operation = durable().readHistoricalArchiveOperation(
        _messageScope,
        operationId,
      )!;
      expect(durable().readHistoricalArchiveSource(operation), isNotNull);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(operation.attemptCount, 0);
      expect(row().protectedSourceBinding, source.encode());
    },
  );

  test(
    'lost database adoption response never rolls back its committed stage owner',
    () async {
      final transport = _StageTransport();
      final lost = _LostAdoptionStore(store: store);
      await expectLater(
        adoptStage(transport, database: lost),
        throwsStateError,
      );
      expect(row().state, 3);
      expect(transport.rolledBack, isEmpty);
      expect(transport.committed, isEmpty);
      final operation = durable().readHistoricalArchiveOperation(
        _messageScope,
        row().admittedOperationId!,
      )!;
      expect(durable().readHistoricalArchiveSource(operation), isNotNull);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );

  test(
    'identity loss after native commit retains queue and immutable source',
    () async {
      final transport = _StageTransport();
      await expectLater(
        adoptStage(
          transport,
          validate: () async {
            if (transport.committed.isNotEmpty) {
              throw StateError('synthetic identity changed');
            }
          },
        ),
        throwsStateError,
      );
      expect(row().state, 3);
      expect(row().protectedSourceBinding, source.encode());
      expect(transport.committed, hasLength(1));
      expect(transport.rolledBack, isEmpty);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );

  test(
    'changed fence rolls back source owner queue map and lease together',
    () {
      final selected = selection();
      final mapCount = store.box<CloudRecordMapEntity>().count();
      expect(
        () => admit(
          selected,
          current: () => store.box<CloudOutboxOperationEntity>().count() == 0,
        ),
        throwsStateError,
      );
      expect(row().state, 1);
      expect(row().admittedOperationId, isNull);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(store.box<CloudRecordMapEntity>().count(), mapCount);
    },
  );

  test(
    'local content change blocks admission without altering original source',
    () {
      final message = localMessage();
      final id = store.box<Message>().put(message);
      final selected = selection();
      message.text = 'newer local text';
      store.box<Message>().put(message);
      expect(() => admit(selected), throwsStateError);
      expect(row().state, 1);
      expect(row().protectedSourceBinding, source.encode());
      expect(store.box<Message>().get(id)!.text, 'newer local text');
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'unknown outcome keeps exact ownership after local Message removal',
    () async {
      final id = store.box<Message>().put(localMessage());
      final operation = admit(selection());
      final entity = store.box<CloudOutboxOperationEntity>().getAll().single
        ..state = CloudOutboxStatus.unknownOutcome.index
        ..attemptCount = 1;
      store.box<CloudOutboxOperationEntity>().put(entity);
      store.box<Message>().remove(id);
      store.close();
      store = await openStore(directory: directory.path);
      final reopened = durable().readHistoricalArchiveOperation(
        _messageScope,
        operation.operationId,
      )!;
      expect(reopened.status, CloudOutboxStatus.unknownOutcome);
      expect(durable().readHistoricalArchiveSource(reopened), isNotNull);
      expect(
        () => journal().requireAdoptedDispatch(
          transactionStore: store,
          operation: reopened,
        ),
        throwsStateError,
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(row().protectedSourceBinding, source.encode());
    },
  );

  test(
    'unchanged local sender resolves from persisted identity after restart',
    () async {
      final messageId = store.box<Message>().put(localMessage());
      store.close();
      store = await openStore(directory: directory.path);
      expect(store.box<Message>().get(messageId)!.handle, isNull);
      final operation = admit(selection());
      journal().requireAdoptedDispatch(
        transactionStore: store,
        operation: operation,
      );
      expect(row().state, 3);
    },
  );

  test(
    'changed stored sender vetoes dispatch but preserves exact readback',
    () {
      store.box<Message>().put(localMessage());
      final operation = admit(selection());
      sender.address = 'other@example.invalid';
      store.box<Handle>().put(sender);
      expect(
        () => journal().requireAdoptedDispatch(
          transactionStore: store,
          operation: operation,
        ),
        throwsStateError,
      );
      expect(durable().readHistoricalArchiveSource(operation), isNotNull);
      expect(row().state, 3);
    },
  );

  for (final change in <String, void Function(Message)>{
    'subject': (message) => message.subject = 'new subject',
    'reply': (message) => message.threadOriginatorGuid = 'new thread parent',
    'legacy ownership': (message) => message.ckSyncState = true,
    'plugin': (message) => message.balloonBundleId = 'synthetic.plugin',
  }.entries) {
    test(
      'late ${change.key} vetoes stale dispatch without blocking readback',
      () {
        final message = localMessage();
        store.box<Message>().put(message);
        final operation = admit(selection());
        change.value(message);
        store.box<Message>().put(message);
        expect(
          () => journal().requireAdoptedDispatch(
            transactionStore: store,
            operation: operation,
          ),
          throwsStateError,
        );
        expect(durable().readHistoricalArchiveSource(operation), isNotNull);
        expect(row().state, 3);
        expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      },
    );
  }

  for (final origin in ['send', 'receive', 'mutation']) {
    test(
      '$origin ownership appearing after adoption vetoes dispatch but not readback',
      () {
        final selected = selection();
        final operation = admit(selected);
        if (origin == 'send') {
          store.box<CloudSyncLocalSendIntentEntity>().put(
            CloudSyncLocalSendIntentEntity(
              intentKey: 'synthetic-send',
              accountFingerprint: _account,
              writerEpoch: 1,
              localMessageId: 0,
              messageGuidHash: _hash(['cloud-sync-local-send-guid-v1', _guid]),
              sourceSha256: 'a' * 64,
              createdAtMs: 1000,
              updatedAtMs: 1000,
            ),
          );
        } else if (origin == 'receive') {
          store.box<CloudSyncReceivedArchiveIntentEntity>().put(
            CloudSyncReceivedArchiveIntentEntity(
              intentKey: 'synthetic-receive',
              accountFingerprint: _account,
              writerEpoch: 1,
              localMessageId: 0,
              localChatId: chat.id!,
              origin: 0,
              messageGuidHash: _hash([
                'cloud-sync-received-archive-guid-v1',
                _guid,
              ]),
              sourceSha256: 'b' * 64,
              protectedSourceBinding: 'synthetic-only',
              createdAtMs: 1000,
              updatedAtMs: 1000,
            ),
          );
        } else {
          store.box<CloudSyncLocalMutationIntentEntity>().put(
            CloudSyncLocalMutationIntentEntity(
              intentKey: 'synthetic-mutation',
              accountFingerprint: _account,
              writerEpoch: 1,
              localMessageId: 0,
              localChatId: chat.id!,
              mutationGuidHash: 'a' * 64,
              targetGuidHash: _hash(['cloud-sync-local-send-guid-v1', _guid]),
              targetPart: 0,
              kind: 1,
              sourceSha256: 'b' * 64,
              targetSnapshotSha256: 'c' * 64,
              protectedSourceBinding: 'synthetic-only',
              createdAtMs: 1000,
              updatedAtMs: 1000,
            ),
          );
        }
        expect(
          () => journal().requireAdoptedDispatch(
            transactionStore: store,
            operation: operation,
          ),
          throwsStateError,
        );
        expect(
          durable()
              .readHistoricalArchiveSource(operation)!
              .sameSourceAs(selected),
          isTrue,
        );
        expect(store.box<CloudOutboxOperationEntity>().count(), 1);
        expect(row().state, 3);
      },
    );
  }

  test('account drift cannot adopt an already staged historical create', () {
    final selected = selection();
    final other = CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'other',
      accountFingerprint: 'B' * 43,
      protectedStoreIdentity: _protectedStore,
      cloudMessagesClient: Object(),
    );
    expect(
      () => journal().validateCreateAdmission(
        transactionStore: store,
        scope: _messageScope,
        expected: selected,
        currentAuth: other,
        stillCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(row().state, 1);
    expect(store.box<CloudOutboxOperationEntity>().count(), 0);
  });

  CloudSyncHistoricalCreateSelection exactSelection() =>
      CloudSyncHistoricalCreateSelection(
        request: request,
        intentId: intentId,
        localChatId: chat.id!,
      );
  CloudOutboxOperation? validateExact(
    CloudSyncHistoricalCreateSelection exact,
  ) => exact.validate(
    store: store,
    scope: _messageScope,
    journal: journal(),
    durable: durable(),
    auth: auth,
  );
  CloudOutboxOperation otherOperation(
    CloudOutboxStatus status, {
    bool lease = false,
  }) => CloudOutboxOperation(
    scope: _messageScope,
    operationId: 'unrelated',
    logicalEntityKeyHash: 'unrelated',
    action: CloudOutboxAction.save,
    payloadVersion: 1,
    mutationRevision: 1,
    checkpointGeneration: generation,
    dependencyOperationIds: {},
    createdAt: _now,
    encryptedPayloadReference: 'obcs2.ref.${'Z' * 43}',
    payloadSha256: 'a' * 64,
    status: status,
    protectedLeaseReference: lease ? 'obcs2.lease.${'a' * 32}' : null,
  );
  CloudOutboxOperationEntity otherRow({
    CloudOutboxStatus status = CloudOutboxStatus.confirmed,
    CloudSyncScope? scope,
    bool lease = false,
  }) {
    final target = scope ?? _messageScope;
    final entity = CloudOutboxOperationEntity(
      operationId: 'unrelated',
      scopeKey: cloudSyncPersistentScopeKey(target),
      accountFingerprint: target.accountFingerprint,
      zone: target.zone,
      logicalEntityKeyHash: 'Z' * 43,
      action: CloudOutboxAction.save.index,
      payloadVersion: cloudSyncOutboundPayloadVersion,
      mutationRevision: 1,
      checkpointGeneration: generation,
      encryptedPayloadRef: 'obcs2.ref.${'Z' * 43}',
      payloadSha256: 'a' * 64,
      serverRecordIdHash: 'Z' * 43,
      state: status.index,
      protectedLeaseReference: lease ? 'obcs2.lease.${'a' * 32}' : null,
      confirmedAtMs: status == CloudOutboxStatus.confirmed
          ? _now.millisecondsSinceEpoch
          : 0,
      createdAtMs: _now.millisecondsSinceEpoch,
      updatedAtMs: _now.millisecondsSinceEpoch,
    );
    store.box<CloudOutboxOperationEntity>().put(entity);
    return entity;
  }

  for (final status in CloudOutboxStatus.values.where(
    (status) => status != CloudOutboxStatus.confirmed,
  )) {
    test('historical selection cannot drain unrelated ${status.name}', () {
      final exact = exactSelection();
      expect(validateExact(exact), isNull);
      final own = admit(selection());
      expect(validateExact(exact)?.operationId, own.operationId);
      expect(exact.canDrain([own]), isTrue);
      expect(exact.canDrain([own, otherOperation(status)]), isFalse);
      expect(exact.owns(otherOperation(status)), isFalse);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      otherRow(status: status);
      expect(() => validateExact(exact), throwsStateError);
      expect(store.box<CloudOutboxOperationEntity>().count(), 2);
    });
  }

  test('historical selection leaves other confirmation work alone', () {
    final exact = exactSelection();
    final own = admit(selection());
    validateExact(exact);
    expect(
      exact.canDrain([own, otherOperation(CloudOutboxStatus.confirmed)]),
      isFalse,
    );
    expect(
      exact.canDrain([
        own,
        otherOperation(CloudOutboxStatus.confirmed, lease: true),
      ]),
      isFalse,
    );
  });

  test(
    'historical selection pins existing settled evidence without draining it',
    () async {
      final own = admit(selection());
      final other = otherRow();
      final exact = exactSelection();
      validateExact(exact);
      final before = await durable().readOutboxEntries(_messageScope);
      expect(exact.canDrain(before), isTrue);
      expect(before.where(exact.owns).map((item) => item.operationId), [
        own.operationId,
      ]);
      expect(
        exact.owns(
          before.singleWhere((item) => item.operationId == other.operationId),
        ),
        isFalse,
      );
      validateExact(exact);
      final after = await durable().readOutboxEntries(_messageScope);
      for (final item in before) {
        expect(
          item.sameDurableSnapshotAs(
            after.singleWhere((row) => row.operationId == item.operationId),
          ),
          isTrue,
        );
      }
    },
  );

  for (final change in ['changed', 'removed', 'new']) {
    test('historical selection rejects $change settled audit evidence', () {
      admit(selection());
      final other = change == 'new' ? null : otherRow();
      final exact = exactSelection();
      validateExact(exact);
      if (change == 'removed') {
        store.box<CloudOutboxOperationEntity>().remove(other!.id);
      } else if (change == 'changed') {
        other!.attemptCount += 1;
        store.box<CloudOutboxOperationEntity>().put(other);
      } else {
        otherRow();
      }
      expect(() => validateExact(exact), throwsStateError);
      expect(row().state, 3);
    });
  }

  test('historical selection checks unrelated account queues too', () {
    admit(selection());
    otherRow(
      status: CloudOutboxStatus.unknownOutcome,
      scope: CloudSyncScope(
        accountFingerprint: 'B' * 43,
        container: _messageScope.container,
        database: _messageScope.database,
        zone: 'attachmentManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      ),
    );
    expect(() => validateExact(exactSelection()), throwsStateError);
    expect(store.box<CloudOutboxOperationEntity>().count(), 2);
  });

  test(
    'historical selection refuses a different database after reopen',
    () async {
      admit(selection());
      final exact = exactSelection();
      validateExact(exact);
      store.close();
      store = await openStore(directory: directory.path);
      expect(() => validateExact(exact), throwsStateError);
      expect(validateExact(exactSelection()), isNotNull);
    },
  );

  for (final boundary in ['lease', 'unknown', 'expired']) {
    test(
      'historical $boundary boundary rejects newly arrived unrelated work atomically',
      () async {
        final own = admit(selection());
        final exact = exactSelection();
        validateExact(exact);
        final guarded = durable(
          validate: () {
            validateExact(exact);
          },
        );
        otherRow(status: CloudOutboxStatus.pending);
        final before = await durable().readOutboxEntries(_messageScope);
        final Future<Object?> result;
        if (boundary == 'lease') {
          result = guarded.leaseEligibleOutbox(
            _messageScope,
            now: _now,
            limit: 1,
            leaseId: 'selected-lease',
            leaseDuration: const Duration(minutes: 1),
            allowedActions: {CloudOutboxAction.save},
          );
        } else if (boundary == 'unknown') {
          result = guarded.leaseUnknownOutcomes(
            _messageScope,
            now: _now,
            limit: 1,
            leaseId: 'selected-lease',
            leaseDuration: const Duration(minutes: 1),
          );
        } else {
          result = guarded.recoverExpiredOutboxLeases(_messageScope, now: _now);
        }
        await expectLater(result, throwsStateError);
        final after = await durable().readOutboxEntries(_messageScope);
        for (final item in before) {
          expect(
            item.sameDurableSnapshotAs(
              after.singleWhere((row) => row.operationId == item.operationId),
            ),
            isTrue,
          );
        }
        expect(row().admittedOperationId, own.operationId);
        expect(
          store.box<CloudOutboxOperationEntity>().getAll().every(
            (row) => row.leaseIdHash == null,
          ),
          isTrue,
        );
      },
    );
  }

  test(
    'historical selection reopens exact ownership without the visible row',
    () async {
      final messageId = store.box<Message>().put(localMessage());
      final own = admit(selection());
      store.box<Message>().remove(messageId);
      store.close();
      store = await openStore(directory: directory.path);
      final exact = exactSelection();
      expect(validateExact(exact)?.operationId, own.operationId);
      expect(exact.owns(own), isTrue);
      expect(exact.matches(exactSelection()), isTrue);
      expect(
        exact.matches(
          CloudSyncHistoricalCreateSelection(
            request: request,
            intentId: intentId,
            localChatId: chat.id! + 1,
          ),
        ),
        isFalse,
      );
    },
  );

  test('historical selection never retargets another local chat', () {
    admit(selection());
    final wrong = CloudSyncHistoricalCreateSelection(
      request: request,
      intentId: intentId,
      localChatId: chat.id! + 1,
    );
    expect(() => validateExact(wrong), throwsStateError);
    expect(row().state, 3);
  });

  CloudSyncHistoricalArchiveCoordinator archiveCoordinator({
    required Future<bool> Function(CloudSyncHistoricalArchiveIntent) discover,
    required Future<CloudSyncLocalSendConsumerResult> Function(
      CloudSyncHistoricalCreateSelection,
    )
    consume,
    Future<void> Function()? validate,
    void Function(CloudSyncHistoricalArchiveDisposition)? onDisposition,
  }) => CloudSyncHistoricalArchiveCoordinator(
    store: store,
    journal: journal(),
    durable: durable(),
    validate: validate ?? () async {},
    discover: discover,
    consume: consume,
    stage: (request, bytes) async => StagedHistoricalSource(
      key: request.sourceSha256,
      guid: request.guid,
      sha256: source.payloadSha256,
      byteLength: source.payloadLength,
    ),
    onDisposition: onDisposition,
  );

  test(
    'archive orchestration does not label a successful callback as a receipt',
    () async {
      final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
      final coordinator = archiveCoordinator(
        discover: (_) async => false,
        consume: (_) async =>
            const CloudSyncLocalSendConsumerResult(admitted: 1),
        onDisposition: dispositions.add,
      );
      await expectLater(
        coordinator.call(request, canonicalBytes),
        throwsStateError,
      );
      expect(dispositions, isEmpty);
      expect(row().state, 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'archive restart reopens an uncertain operation without rediscovery or another create',
    () async {
      var discoveries = 0;
      var admissions = 0;
      final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
      CloudSyncHistoricalArchiveCoordinator coordinator() => archiveCoordinator(
        discover: (_) async {
          discoveries++;
          return false;
        },
        consume: (exact) async {
          validateExact(exact);
          if (row().admittedOperationId == null) {
            admit(selection());
            admissions++;
          }
          final entity = store.box<CloudOutboxOperationEntity>().getAll().single
            ..state = CloudOutboxStatus.unknownOutcome.index;
          store.box<CloudOutboxOperationEntity>().put(entity);
          return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
        },
        onDisposition: dispositions.add,
      );
      await expectLater(
        coordinator().call(request, canonicalBytes),
        throwsStateError,
      );
      final originalId = row().admittedOperationId;
      store.close();
      store = await openStore(directory: directory.path);
      await expectLater(
        coordinator().call(request, canonicalBytes),
        throwsStateError,
      );
      expect(discoveries, 1);
      expect(admissions, 1);
      expect(row().admittedOperationId, originalId);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      expect(dispositions, isEmpty);
    },
  );

  test(
    'archive requires durable reader ownership before accepting found',
    () async {
      var consumes = 0;
      final coordinator = archiveCoordinator(
        discover: (_) async => true,
        consume: (_) async {
          consumes++;
          return const CloudSyncLocalSendConsumerResult();
        },
      );
      await expectLater(
        coordinator.call(request, canonicalBytes),
        throwsStateError,
      );
      expect(consumes, 0);
      expect(row().state, 1);
    },
  );

  test(
    'archive control flow reuses a synthetic confirmed receipt without another consume',
    () async {
      var consumes = 0;
      var discoveries = 0;
      final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
      CloudSyncHistoricalArchiveCoordinator coordinator() => archiveCoordinator(
        discover: (_) async {
          discoveries++;
          return false;
        },
        consume: (exact) async {
          consumes++;
          admit(selection());
          // Synthetic receipt state for orchestration only, not native or Apple proof.
          final entity = store.box<CloudOutboxOperationEntity>().getAll().single
            ..state = CloudOutboxStatus.confirmed.index
            ..confirmedAtMs = _now.millisecondsSinceEpoch
            ..protectedLeaseReference = null;
          store.box<CloudOutboxOperationEntity>().put(entity);
          return const CloudSyncLocalSendConsumerResult(admitted: 1);
        },
        onDisposition: dispositions.add,
      );
      expect(
        (await coordinator().call(request, canonicalBytes)).sha256,
        source.payloadSha256,
      );
      store.close();
      store = await openStore(directory: directory.path);
      expect(
        (await coordinator().call(request, canonicalBytes)).sha256,
        source.payloadSha256,
      );
      expect(consumes, 1);
      expect(discoveries, 1);
      expect(dispositions, [
        CloudSyncHistoricalArchiveDisposition.confirmedCreate,
        CloudSyncHistoricalArchiveDisposition.confirmedCreate,
      ]);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );

  test('archive stops after identity changes at discovery', () async {
    var current = true;
    var consumes = 0;
    final coordinator = archiveCoordinator(
      validate: () async {
        if (!current) throw StateError('identity_changed');
      },
      discover: (_) async {
        current = false;
        return false;
      },
      consume: (_) async {
        consumes++;
        return const CloudSyncLocalSendConsumerResult();
      },
    );
    await expectLater(
      coordinator.call(request, canonicalBytes),
      throwsStateError,
    );
    expect(consumes, 0);
    expect(row().state, 1);
  });

  test('archive never guesses another chat from the recipient alone', () async {
    chat.guid = 'different-conversation';
    store.box<Chat>().put(chat);
    var consumes = 0;
    final coordinator = archiveCoordinator(
      discover: (_) async => false,
      consume: (_) async {
        consumes++;
        return const CloudSyncLocalSendConsumerResult();
      },
    );
    await expectLater(
      coordinator.call(request, canonicalBytes),
      throwsStateError,
    );
    expect(consumes, 0);
    expect(row().state, 1);
  });

  test(
    'producer advances archive progress only after durable confirmation',
    () async {
      final cursor = MemoryHistoricalCursorStore();
      var consumes = 0;
      var discoveries = 0;
      CloudSyncHistoricalProducer producer() => CloudSyncHistoricalProducer(
        reader: _OneHistoricalRow(sourceView),
        registry: _NoHistoricalOwners(),
        cursors: cursor,
        manifest: CloudSyncHistoricalSourceManifest(
          snapshotSha256: request.snapshotSha256,
          accountFingerprint: _account,
          accountHandles: [sender.address],
          messageCount: 1,
          capturedAtMs: _now.millisecondsSinceEpoch,
        ),
        account: CloudSyncHistoricalAccountBinding(
          accountFingerprint: _account,
          protectedStoreIdentity: _protectedStore,
        ),
        readCurrentRow: (_) async => sourceView,
        stageAndAdopt: archiveCoordinator(
          discover: (_) async {
            discoveries++;
            return false;
          },
          consume: (_) async {
            consumes++;
            admit(selection());
            return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
          },
        ).call,
        nowMs: _now.millisecondsSinceEpoch,
      );
      await expectLater(producer().run(), throwsStateError);
      expect(await cursor.load(), isNull);
      final operationId = row().admittedOperationId;
      final entity = store.box<CloudOutboxOperationEntity>().getAll().single
        ..state = CloudOutboxStatus.confirmed.index
        ..confirmedAtMs = _now.millisecondsSinceEpoch
        ..protectedLeaseReference = null;
      store.box<CloudOutboxOperationEntity>().put(entity);
      final result = await producer().run();
      expect(result.summary.completed, isTrue);
      expect((await cursor.load())?.done, isTrue);
      expect(row().admittedOperationId, operationId);
      expect(consumes, 1);
      expect(discoveries, 1);
      expect(store.box<CloudOutboxOperationEntity>().count(), 1);
    },
  );

  test(
    'confirmed cleanup does not erase historical source or change its owner',
    () {
      final operation = admit(selection());
      final entity = store.box<CloudOutboxOperationEntity>().getAll().single
        ..state = CloudOutboxStatus.confirmed.index
        ..protectedLeaseReference = null;
      store.box<CloudOutboxOperationEntity>().put(entity);
      final reopened = durable().readHistoricalArchiveOperation(
        _messageScope,
        operation.operationId,
      )!;
      expect(reopened.status, CloudOutboxStatus.confirmed);
      expect(durable().readHistoricalArchiveSource(reopened), isNotNull);
      expect(row().protectedSourceBinding, source.encode());
      expect(row().admittedOperationId, operation.operationId);
    },
  );

  group('received missing-metadata retention', () {
    late CloudSyncHistoricalArchiveRequest receivedRequest;
    late List<int> receivedBytes;
    late CloudSyncHistoricalProtectedSourceBinding receivedSource;
    late int receivedIntentId;

    CloudSyncHistoricalArchiveIntentEntity receivedRow() => store
        .box<CloudSyncHistoricalArchiveIntentEntity>()
        .get(receivedIntentId)!;

    CloudSyncHistoricalArchiveCoordinator receivedCoordinator({
      required Future<bool> Function(CloudSyncHistoricalArchiveIntent) discover,
      required Future<CloudSyncLocalSendConsumerResult> Function(
        CloudSyncHistoricalCreateSelection,
      )
      consume,
      void Function(CloudSyncHistoricalArchiveDisposition)? onDisposition,
    }) => CloudSyncHistoricalArchiveCoordinator(
      store: store,
      journal: journal(),
      durable: durable(),
      validate: () async {},
      discover: discover,
      consume: consume,
      stage: (request, bytes) async => StagedHistoricalSource(
        key: request.sourceSha256,
        guid: request.guid,
        sha256: receivedSource.payloadSha256,
        byteLength: receivedSource.payloadLength,
      ),
      onDisposition: onDisposition,
    );

    setUp(() {
      // Genuine received canonical source: rebuilt from an actual synthetic
      // incoming Message through assessment with matching digests/binding,
      // never by flipping origin over the sent fixture source.
      final peerQuery = store
          .box<Handle>()
          .query(Handle_.address.equals('peer@example.invalid'))
          .build();
      final Handle peer;
      try {
        peer = peerQuery.findFirst()!;
      } finally {
        peerQuery.close();
      }
      peer.originalROWID = 101;
      store.box<Handle>().put(peer);
      final incoming = Message(
        guid: 'historical-synthetic-incoming',
        text: 'synthetic incoming text',
        attributedBody: [AttributedBody.raw('synthetic incoming text')],
        isFromMe: false,
        dateCreated: _now.subtract(const Duration(days: 3)),
        handle: peer,
      )..chat.target = chat;
      store.box<Message>().put(incoming);
      final assessed = assessHistoricalArchiveRow(
        mapHistoricalRow(
          message: incoming,
          chat: mapHistoricalChat(chat),
          rowSnapshotSha256: 'a' * 64,
        ),
        CloudSyncHistoricalSourceManifest(
          snapshotSha256: 'a' * 64,
          accountFingerprint: _account,
          accountHandles: [sender.address],
          messageCount: 1,
          capturedAtMs: _now.millisecondsSinceEpoch,
        ),
        CloudSyncHistoricalAccountBinding(
          accountFingerprint: _account,
          protectedStoreIdentity: _protectedStore,
        ),
        nowMs: _now.millisecondsSinceEpoch,
      );
      expect(
        assessed,
        isA<CloudSyncHistoricalArchiveEligible>(),
        reason: assessed is CloudSyncHistoricalArchiveIneligible
            ? assessed.reason
            : null,
      );
      receivedRequest =
          (assessed as CloudSyncHistoricalArchiveEligible).request;
      expect(
        receivedRequest.origin,
        CloudSyncHistoricalArchiveOrigin.historicalReceived,
      );
      receivedBytes = utf8.encode(
        jsonEncode(
          stagedHistoricalPayload(
            request: receivedRequest,
            text: 'synthetic incoming text',
          ),
        ),
      );
      receivedSource = CloudSyncHistoricalProtectedSourceBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: _protectedStore,
        snapshotSha256: receivedRequest.snapshotSha256,
        messageGuidHash: receivedRequest.guidHash,
        sourceSha256: receivedRequest.sourceSha256,
        protectedReference: 'obcs2.ref.${'Q' * 43}',
        leaseReference: 'obcs2.lease.${'c' * 32}',
        payloadSha256: historicalBytesSha256(receivedBytes),
        payloadLength: receivedBytes.length,
      );
      receivedIntentId = journal().adopt(receivedSource).id;
      journal().markSourceLeaseCommitted(
        intentId: receivedIntentId,
        expectedSource: receivedSource,
      );
    });

    test(
      'received NotFound is retained without consume across reopen',
      () async {
        var consumes = 0;
        var discoveries = 0;
        final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
        CloudSyncHistoricalArchiveCoordinator coordinator() =>
            receivedCoordinator(
              discover: (_) async {
                discoveries++;
                return false;
              },
              consume: (_) async {
                consumes++;
                return const CloudSyncLocalSendConsumerResult(admitted: 1);
              },
              onDisposition: dispositions.add,
            );
        final sealed = await coordinator().call(receivedRequest, receivedBytes);
        expect(sealed.sha256, receivedSource.payloadSha256);
        expect(consumes, 0);
        expect(discoveries, 1);
        expect(dispositions, [
          CloudSyncHistoricalArchiveDisposition.retainedMissingMetadata,
        ]);
        expect(receivedRow().state, 1);
        expect(receivedRow().admittedOperationId, isNull);
        expect(receivedRow().readerObservationBinding, isNull);
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
        store.close();
        store = await openStore(directory: directory.path);
        final reopened = await coordinator().call(
          receivedRequest,
          receivedBytes,
        );
        expect(reopened.sha256, receivedSource.payloadSha256);
        expect(consumes, 0);
        expect(discoveries, 2);
        expect(dispositions, [
          CloudSyncHistoricalArchiveDisposition.retainedMissingMetadata,
          CloudSyncHistoricalArchiveDisposition.retainedMissingMetadata,
        ]);
        expect(receivedRow().state, 1);
        expect(receivedRow().admittedOperationId, isNull);
      },
    );

    test('durable found reader ownership is still handed to reader', () async {
      // The remote discovery answer is synthesized as a bare bool; reader
      // ownership itself is durable journal state linked below.
      journal().markDiscoveryAdopted(
        transactionStore: store,
        scope: _messageScope,
        intentId: receivedIntentId,
        source: receivedSource,
        currentAuth: auth,
        stillCurrent: () => true,
        change: CloudFetchedChange(
          changeId: 'D' * 43,
          recordIdHash: 'R' * 43,
          etagHash: 'E' * 43,
          payloadSha256: 'd' * 64,
          type: CloudChangeType.save,
        ),
        generation: generation,
        observedAtMs: _now.millisecondsSinceEpoch,
      );
      var consumes = 0;
      final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
      final coordinator = receivedCoordinator(
        discover: (_) async => true,
        consume: (_) async {
          consumes++;
          return const CloudSyncLocalSendConsumerResult(admitted: 1);
        },
        onDisposition: dispositions.add,
      );
      final sealed = await coordinator.call(receivedRequest, receivedBytes);
      expect(sealed.sha256, receivedSource.payloadSha256);
      expect(consumes, 0);
      expect(dispositions, [
        CloudSyncHistoricalArchiveDisposition.retainedByReader,
      ]);
      expect(receivedRow().readerObservationBinding, isNotNull);
      expect(
        journal()
            .read(
              messageGuidHash: receivedRequest.guidHash,
              sourceSha256: receivedRequest.sourceSha256,
            )!
            .readerChangeId,
        'D' * 43,
      );
    });

    test('consume errors are never converted to deferred success', () async {
      // The received path returns before consume without an admitted
      // operation, so the error path is exercised on the sent fixtures
      // where consume is genuinely reached.
      var consumes = 0;
      final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
      final coordinator = archiveCoordinator(
        discover: (_) async => false,
        consume: (_) async {
          consumes++;
          throw StateError('synthetic consume failure');
        },
        onDisposition: dispositions.add,
      );
      await expectLater(
        coordinator.call(request, canonicalBytes),
        throwsStateError,
      );
      expect(consumes, 1);
      expect(dispositions, isEmpty);
      expect(row().state, 1);
      expect(row().admittedOperationId, isNull);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    });

    test(
      'received admitted-uncertain operations still throw without deferral',
      () async {
        // A real operation is admitted through the durable store (no native
        // proof involved), then left uncertain; only the uncertain receipt
        // below is synthesized.
        final selected = journal().readForCreateAdmission(
          scope: _messageScope,
          intentId: receivedIntentId,
          currentAuth: auth,
          request: receivedRequest,
          localChatId: chat.id!,
          generation: generation,
          logicalEntityKeyHash: 'L' * 43,
          serverRecordIdHash: 'M' * 43,
        );
        final operation = admit(selected);
        final entity = store.box<CloudOutboxOperationEntity>().getAll().single
          ..state = CloudOutboxStatus.unknownOutcome.index;
        store.box<CloudOutboxOperationEntity>().put(entity);
        var consumes = 0;
        final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
        final coordinator = receivedCoordinator(
          discover: (_) async => false,
          consume: (_) async {
            consumes++;
            return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
          },
          onDisposition: dispositions.add,
        );
        await expectLater(
          coordinator.call(receivedRequest, receivedBytes),
          throwsA(
            isA<StateError>().having(
              (failure) => failure.message,
              'message',
              'cloud_sync_historical_archive_confirmation_pending',
            ),
          ),
        );
        expect(consumes, 1);
        expect(dispositions, isEmpty);
        expect(receivedRow().admittedOperationId, operation.operationId);
        expect(store.box<CloudOutboxOperationEntity>().count(), 1);
      },
    );

    test('received discovery failure is not metadata deferral', () async {
      final before = receivedRow().protectedSourceBinding;
      final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
      var consumes = 0;
      final coordinator = receivedCoordinator(
        discover: (_) async => throw StateError('synthetic discovery failure'),
        consume: (_) async {
          consumes++;
          return const CloudSyncLocalSendConsumerResult(admitted: 1);
        },
        onDisposition: dispositions.add,
      );
      await expectLater(
        coordinator.call(receivedRequest, receivedBytes),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'synthetic discovery failure',
          ),
        ),
      );
      expect(dispositions, isEmpty);
      expect(consumes, 0);
      expect(receivedRow().state, 1);
      expect(receivedRow().protectedSourceBinding, before);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    });
  });
}

class _OneHistoricalRow implements HistoricalRowReader {
  _OneHistoricalRow(this.view);
  final CloudSyncHistoricalRowView view;
  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async => HistoricalRowPage(views: [view], nextCursor: null);
}

class _NoHistoricalOwners extends HistoricalOwnershipRegistry {
  @override
  Set<String> get ownedGuids => const {};
  @override
  Set<String> get conflictGuids => const {};
}

class _StageTransport implements CloudProtectedPageLeaseTransport {
  bool failCommit = false;
  void Function()? beforeCommit;
  final committed = <String>[];
  final rolledBack = <String>[];
  @override
  String get protectedPageLeaseRecoveryIdentity => _protectedStore;
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<void> commitProtectedPageLease(
    String reference,
    Set<String> live,
  ) async {
    beforeCommit?.call();
    expect(live, {'obcs2.ref.${'V' * 43}'});
    committed.add(reference);
    if (failCommit) throw StateError('synthetic lost commit response');
  }

  @override
  Future<void> rollbackProtectedPageLease(String reference) async {
    rolledBack.add(reference);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native call');
}

class _LostAdoptionStore extends ObjectBoxCloudSyncStore {
  _LostAdoptionStore({required super.store})
    : super(protector: _SyntheticProtector(), clock: () => _now);

  @override
  CloudOutboxOperation admitProtectedHistoricalCreate({
    required CloudOutboxDraft draft,
    required CloudRecordMapEntry recordMapping,
    required CloudSyncHistoricalArchiveJournal journal,
    required CloudSyncHistoricalCreateSource source,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
  }) {
    super.admitProtectedHistoricalCreate(
      draft: draft,
      recordMapping: recordMapping,
      journal: journal,
      source: source,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
    );
    throw StateError('synthetic lost database commit response');
  }
}

class _SyntheticProtector implements CloudSyncProtector {
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => 'synthetic:${scope.storageKey}:${kind.name}:$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    final prefix = 'synthetic:${scope.storageKey}:${kind.name}:';
    if (!ciphertext.startsWith(prefix)) {
      throw StateError('synthetic scope mismatch');
    }
    return ciphertext.substring(prefix.length);
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) =>
      throw StateError('not a live account test');
}
