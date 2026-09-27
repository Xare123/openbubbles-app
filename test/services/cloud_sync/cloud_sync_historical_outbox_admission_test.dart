import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_create_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_outbox_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
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
  late int intentId;
  late int generation;

  final auth = CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: 'synthetic-session',
    accountFingerprint: _account,
    protectedStoreIdentity: _protectedStore,
    cloudMessagesClient: Object(),
  );
  ObjectBoxCloudSyncStore durable() => ObjectBoxCloudSyncStore(
    store: store,
    protector: _SyntheticProtector(),
    clock: () => _now,
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
    final assessed = assessHistoricalArchiveRow(
      mapHistoricalRow(
        message: fixture,
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
    request = (assessed as CloudSyncHistoricalArchiveEligible).request;
    store.box<Message>().remove(fixtureId);
    source = CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: _account,
      protectedStoreIdentity: _protectedStore,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
      protectedReference: 'obcs2.ref.${'R' * 43}',
      leaseReference: 'obcs2.lease.${'b' * 32}',
      payloadSha256: 'c' * 64,
      payloadLength: 128,
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
