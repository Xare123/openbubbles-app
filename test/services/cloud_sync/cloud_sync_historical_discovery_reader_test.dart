import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_discovery_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_chat_identity_session.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 9, 27, 20);
final _scope = CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
String get _storeIdentity => 'obcs2.store.${'S' * 43}';
CloudSyncNativeAuthSnapshot _auth({String? storeIdentity, String? account}) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'synthetic-history-session',
      accountFingerprint: account ?? _scope.accountFingerprint,
      protectedStoreIdentity: storeIdentity ?? _storeIdentity,
      cloudMessagesClient: Object(),
    );
CloudSyncHistoricalProtectedSourceBinding _source({
  String? digest,
  String? snapshot,
}) => CloudSyncHistoricalProtectedSourceBinding(
  accountFingerprint: _scope.accountFingerprint,
  protectedStoreIdentity: _storeIdentity,
  snapshotSha256: snapshot ?? 'a' * 64,
  messageGuidHash: 'b' * 64,
  sourceSha256: digest ?? 'c' * 64,
  protectedReference: 'obcs2.ref.${'S' * 43}',
  leaseReference: 'obcs2.lease.${'a' * 32}',
  payloadSha256: 'e' * 64,
  payloadLength: 128,
);
CloudFetchedChange _change({String raw = 'Y', String identity = 'I'}) =>
    CloudFetchedChange(
      changeId: 'D' * 43,
      recordIdHash: 'R' * 43,
      etagHash: 'E' * 43,
      type: CloudChangeType.save,
      encryptedServerRecordId: 'obcs2.ref.${identity * 43}',
      encryptedPayloadReference: 'obcs2.ref.${raw * 43}',
      payloadSha256: 'd' * 64,
      serverModifiedAt: _now,
    );

api.CloudSyncReceivedFoundProjection _stage(
  int generation, {
  String? guidHash,
  String lease = '1',
  String etag = 'E',
}) => api.CloudSyncReceivedFoundProjection(
  messageGuidHash: guidHash ?? _source().messageGuidHash,
  sourceSha256: _source().sourceSha256,
  generation: BigInt.from(generation),
  batchId: 'B' * 43,
  leaseReference: 'obcs2.lease.${lease * 32}',
  change: api.CloudSyncProtectedChange(
    changeId: 'D' * 43,
    recordIdHash: 'R' * 43,
    etagHash: etag * 43,
    kind: api.CloudSyncProtectedChangeKind.save,
    payloadSha256: 'd' * 64,
    payloadLength: BigInt.from(128),
    protectedRecordIdentityReference: 'obcs2.ref.${'I' * 43}',
    protectedRawEnvelopeReference: 'obcs2.ref.${'Y' * 43}',
    serverModifiedAtMillis: null,
    preflightCode: null,
    isTombstone: false,
  ),
);

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudSyncStore durable;
  late CloudSyncHistoricalArchiveJournal journal;
  late CloudCoordinatorLeaseFence fence;
  late int intentId;
  late int generation;

  CloudSyncHistoricalArchiveJournal bindJournal({
    String? snapshot,
    Store? target,
  }) => CloudSyncHistoricalArchiveJournal(
    store: target ?? store,
    accountFingerprint: _scope.accountFingerprint,
    protectedStoreIdentity: _storeIdentity,
    snapshotSha256: snapshot ?? 'a' * 64,
    clock: () => _now,
  );
  ObjectBoxCloudSyncStore bindStore() => ObjectBoxCloudSyncStore(
    store: store,
    protector: _TestProtector(),
    clock: () => _now,
  );
  CloudSyncHistoricalArchiveIntentEntity row() =>
      store.box<CloudSyncHistoricalArchiveIntentEntity>().get(intentId)!;
  bool adopt({
    CloudSyncHistoricalArchiveJournal? sourceJournal,
    CloudSyncHistoricalProtectedSourceBinding? source,
    int? id,
    CloudSyncNativeAuthSnapshot? auth,
    int? atGeneration,
    CloudFetchedChange? change,
    String lease = '1',
    bool Function()? stillCurrent,
  }) => durable.journalHistoricalDiscoveredFound(
    scope: _scope,
    change: change ?? _change(),
    generation: atGeneration ?? generation,
    batchId: 'B' * 43,
    leaseReference: 'obcs2.lease.${lease * 32}',
    leaseFence: fence,
    journal: sourceJournal ?? journal,
    intentId: id ?? intentId,
    source: source ?? _source(),
    currentAuth: auth ?? _auth(),
    stillCurrent: stillCurrent ?? () => true,
  );
  String snapshot() => jsonEncode({
    'checkpoint': store
        .box<CloudSyncCheckpointEntity>()
        .getAll()
        .map(
          (r) => [
            r.fetchedTokenCiphertext,
            r.pendingFetchedTokenCiphertext,
            r.pendingBatchId,
            r.fetchedSequence,
            r.appliedSequence,
            r.generation,
          ],
        )
        .toList(),
    'inbox': store
        .box<CloudInboxChangeEntity>()
        .getAll()
        .map(
          (r) => [
            r.id,
            r.changeKey,
            r.changeIdHash,
            r.etagHash,
            r.isTombstone,
            r.encryptedPayloadRef,
            r.encryptedServerRecordId,
            r.fetchSequence,
          ],
        )
        .toList(),
    'history': store
        .box<CloudSyncHistoricalArchiveIntentEntity>()
        .getAll()
        .map(
          (r) => [
            r.id,
            r.state,
            r.protectedSourceBinding,
            r.readerObservationBinding,
            r.updatedAtMs,
          ],
        )
        .toList(),
    'leases': store.box<CloudProtectedPageLeaseEntity>().count(),
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ob-history-discovery-');
    store = await openStore(directory: directory.path);
    durable = bindStore();
    journal = bindJournal();
    await durable.recordPullSuccess(_scope, now: _now);
    fence = (await durable.tryAcquireCoordinatorLease(
      _scope,
      ownerId: 'history-test',
      now: _now,
      leaseDuration: const Duration(hours: 1),
    ))!;
    final checkpoint = await durable.readCheckpoint(_scope);
    generation = checkpoint.generation;
    await durable.journalFetchedBatch(
      CloudFetchBatch(
        scope: _scope,
        changes: const [],
        batchId: 'synthetic-baseline',
        generation: generation,
        nextToken: 'keep-server-cursor',
        hasMore: false,
      ),
      now: _now,
      leaseFence: fence,
      expectedGeneration: generation,
      expectedFetchedToken: checkpoint.fetchedToken,
      expectedFetchDirection: checkpoint.fetchDirection,
    );
    intentId = journal.adopt(_source()).id;
    journal.markSourceLeaseCommitted(
      intentId: intentId,
      expectedSource: _source(),
    );
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  CloudSyncHistoricalArchiveIntent selected() => journal.read(
    messageGuidHash: _source().messageGuidHash,
    sourceSha256: _source().sourceSha256,
  )!;
  Future<bool> runStage(
    _HistoricalLeaseTransport transport, {
    api.CloudSyncReceivedFoundProjection? result,
    Future<void> Function()? validate,
  }) => adoptCloudSyncHistoricalDiscoveryStage(
    result: result ?? _stage(generation),
    intent: selected(),
    journal: journal,
    auth: _auth(),
    generation: generation,
    scope: _scope,
    coordinator: fence,
    durable: durable,
    validate: validate ?? () async {},
    stillCurrent: () => true,
    lifecycle: CloudProtectedPageLeaseLifecycle(
      store: durable,
      transport: transport,
    ),
    transport: transport,
  );

  test(
    'historical discovery session validates its own one-way adoption',
    () async {
      final intent = selected();
      final result = _stage(generation);
      api.CloudSyncReceivedFoundProjection? adopted;
      var validationsAfterAdoption = 0;
      Future<void> validate() async {
        validateCloudSyncHistoricalDiscoverySelection(
          journal: journal,
          intent: intent,
          auth: _auth(),
          generation: generation,
          adopted: adopted,
        );
        if (adopted != null) validationsAfterAdoption++;
      }

      final transport = _HistoricalLeaseTransport();
      final pause = _HistoricalPause();
      final exclusion = CloudKitOperationInterlock(
        privateStorageDirectory: directory.path,
        fenceStore: durable,
      );
      final session = CloudSyncWriteChatIdentitySession(
        exclusion: exclusion,
        nativePause: pause,
        validate: validate,
        ensureReadAuthentication: () async {},
        warmReadAuthentication: (_) async {},
      );
      expect(
        await exclusion.runExclusive(
          kind: CloudKitOperationKind.v2ReadWrite,
          action: () => session.run((_) async {
            final retained = await runStage(
              transport,
              result: result,
              validate: validate,
            );
            adopted = result;
            return retained;
          }),
        ),
        isTrue,
      );
      expect(validationsAfterAdoption, 2);
      expect(pause.active, isFalse);
      expect(transport.committed, [result.leaseReference]);
      expect(transport.rolledBack, isEmpty);
      expect(row().state, 2);
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );
  test('disabled historical lookup never reads a client or starts native work', () async {
    var clientsRead = 0;
    await expectLater(retainCloudSyncDiscoveredHistoricalFound(
      intent: selected(), privateStorageDirectory: directory.path,
      readActiveClient: () { clientsRead++; return null; },
      stillCurrent: () => true,
    ), throwsA(isA<StateError>().having((e) => e.message, 'code',
      'cloud_sync_historical_discovery_disabled')));
    expect(clientsRead, 0);
    expect(row().state, 1);
    expect(store.box<CloudInboxChangeEntity>().count(), 0);
  });
  test(
    'historical pipeline rejects foreign result and rolls back only its lease',
    () async {
      final transport = _HistoricalLeaseTransport();
      final before = snapshot();
      await expectLater(
        runStage(transport, result: _stage(generation, guidHash: 'f' * 64)),
        throwsStateError,
      );
      expect(snapshot(), before);
      expect(transport.rolledBack, ['obcs2.lease.${'1' * 32}']);
      expect(transport.committed, isEmpty);
    },
  );
  test(
    'historical pipeline revalidates before adoption and rolls back on drift',
    () async {
      final transport = _HistoricalLeaseTransport();
      final before = snapshot();
      await expectLater(
        runStage(
          transport,
          validate: () async => throw StateError('synthetic identity changed'),
        ),
        throwsStateError,
      );
      expect(snapshot(), before);
      expect(transport.rolledBack, ['obcs2.lease.${'1' * 32}']);
    },
  );
  test(
    'historical pipeline duplicate does not commit or replace reader references',
    () async {
      final transport = _HistoricalLeaseTransport();
      expect(await runStage(transport), isTrue);
      final before = snapshot();
      expect(
        await runStage(transport, result: _stage(generation, lease: '2')),
        isTrue,
      );
      expect(snapshot(), before);
      expect(transport.committed, ['obcs2.lease.${'1' * 32}']);
      expect(transport.rolledBack, ['obcs2.lease.${'2' * 32}']);
    },
  );
  test(
    'lost historical reader commit recovers after reopen without duplicate adoption',
    () async {
      final transport = _HistoricalLeaseTransport()..failCommit = true;
      await expectLater(runStage(transport), throwsStateError);
      expect(row().state, 2);
      expect(transport.rolledBack, isEmpty);
      final before = jsonDecode(snapshot()) as Map<String, dynamic>;
      expect(before['leases'], 1);
      store.close();
      store = await openStore(directory: directory.path);
      journal = bindJournal();
      durable = bindStore();
      transport.failCommit = false;
      final lifecycle = CloudProtectedPageLeaseLifecycle(
        store: durable,
        transport: transport,
      );
      await lifecycle.ensureRecoveredBeforeFetch();
      expect(transport.recovered.single, contains('obcs2.lease.${'1' * 32}'));
      expect(
        await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 50),
        isEmpty,
      );
      // Successful recovery retires only the temporary page-adoption marker.
      // Keep every history/inbox/cursor value exact across reopen and recovery.
      final recovered = {...before, 'leases': 0};
      expect(jsonDecode(snapshot()), recovered);
      await lifecycle.ensureRecoveredBeforeFetch();
      expect(jsonDecode(snapshot()), recovered);
      expect(transport.recovered, hasLength(1));
      final retained = selected();
      validateCloudSyncHistoricalDiscoverySelection(
        journal: journal,
        intent: retained,
        auth: _auth(),
        generation: generation,
      );
      expect(retained.readerChangeId, 'D' * 43);
      expect(transport.committed, ['obcs2.lease.${'1' * 32}']);
      expect(transport.rolledBack, isEmpty);
    },
  );
  test(
    'historical post-adoption validation rejects different version or generation',
    () async {
      final intent = selected();
      expect(await runStage(_HistoricalLeaseTransport()), isTrue);
      for (final evidence in [
        (_stage(generation, etag: 'Q'), generation),
        (_stage(generation), generation + 1),
      ]) {
        expect(
          () => validateCloudSyncHistoricalDiscoverySelection(
            journal: journal,
            intent: intent,
            auth: _auth(),
            generation: evidence.$2,
            adopted: evidence.$1,
          ),
          throwsStateError,
        );
      }
      expect(row().state, 2);
    },
  );
  test(
    'historical post-adoption validation rejects changed store identity',
    () async {
      final intent = selected();
      expect(await runStage(_HistoricalLeaseTransport()), isTrue);
      expect(
        () => validateCloudSyncHistoricalDiscoverySelection(
          journal: journal,
          intent: intent,
          auth: _auth(storeIdentity: 'obcs2.store.${'Q' * 43}'),
          generation: generation,
          adopted: _stage(generation),
        ),
        throwsStateError,
      );
      expect(row().state, 2);
    },
  );

  test(
    'historical Found enters ordinary reader and survives reopen without moving cursor',
    () async {
      expect(adopt(), isTrue);
      expect(row().state, 2);
      final inbox = store.box<CloudInboxChangeEntity>().getAll().single;
      expect(inbox.status, CloudInboxStatus.pending.index);
      expect(inbox.changeIdHash, _change().changeId);
      expect(
        (await durable.readCheckpoint(_scope)).fetchedToken,
        'keep-server-cursor',
      );
      final before = snapshot();
      store.close();
      store = await openStore(directory: directory.path);
      durable = bindStore();
      journal = bindJournal();
      expect(snapshot(), before);
      final retained = journal.read(
        messageGuidHash: _source().messageGuidHash,
        sourceSha256: _source().sourceSha256,
      )!;
      expect(retained.readerChangeId, _change().changeId);
      expect(retained.sourceLeaseCommitted, isTrue);
      expect(
        journal
            .markSourceLeaseCommitted(
              intentId: intentId,
              expectedSource: _source(),
            )
            .readerChangeId,
        _change().changeId,
      );
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
      expect(store.box<CloudSyncLocalSendIntentEntity>().count(), 0);
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
      expect(store.box<Message>().count(), 0);
      expect(
        await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10),
        {'obcs2.lease.${'1' * 32}'},
      );
    },
  );

  test(
    'duplicate keeps original reader references and never adopts the second lease',
    () async {
      expect(adopt(), isTrue);
      final first = snapshot();
      expect(
        adopt(
          change: _change(raw: 'V', identity: 'U'),
          lease: '2',
        ),
        isFalse,
      );
      expect(snapshot(), first);
      final another = _source(snapshot: 'f' * 64, digest: 'f' * 64);
      final anotherJournal = bindJournal(snapshot: another.snapshotSha256);
      final secondId = anotherJournal.adopt(another).id;
      anotherJournal.markSourceLeaseCommitted(
        intentId: secondId,
        expectedSource: another,
      );
      expect(
        adopt(
          sourceJournal: anotherJournal,
          source: another,
          id: secondId,
          change: _change(raw: 'V', identity: 'U'),
          lease: '2',
        ),
        isFalse,
      );
      expect(
        anotherJournal
            .read(
              messageGuidHash: another.messageGuidHash,
              sourceSha256: another.sourceSha256,
            )!
            .readerChangeId,
        _change().changeId,
      );
      final inbox = store.box<CloudInboxChangeEntity>().getAll().single;
      expect(inbox.encryptedPayloadRef, _change().encryptedPayloadReference);
      expect(
        await durable.readAdoptedProtectedPageLeaseReferences(maximumCount: 10),
        {'obcs2.lease.${'1' * 32}'},
      );
    },
  );

  for (final kind in [
    'uncommitted',
    'source changed',
    'account changed',
    'store changed',
    'generation changed',
    'lifetime changed',
  ]) {
    test('$kind fails atomically without manufacturing reader ownership', () {
      if (kind == 'uncommitted') {
        store.box<CloudSyncHistoricalArchiveIntentEntity>().put(
          row()..state = 0,
        );
      }
      final before = snapshot();
      expect(
        () => adopt(
          source: kind == 'source changed' ? _source(digest: 'f' * 64) : null,
          auth: kind == 'account changed'
              ? _auth(account: 'Z' * 43)
              : kind == 'store changed'
              ? _auth(storeIdentity: 'obcs2.store.${'Z' * 43}')
              : null,
          atGeneration: kind == 'generation changed' ? generation + 1 : null,
          stillCurrent: () => kind != 'lifetime changed',
        ),
        throwsA(anything),
      );
      expect(snapshot(), before);
      expect(store.box<CloudSyncReceivedArchiveIntentEntity>().count(), 0);
    });
  }

  test(
    'foreign journal store rejects before either store acquires a reader row',
    () async {
      final foreignDirectory = await Directory.systemTemp.createTemp(
        'ob-history-foreign-',
      );
      final foreign = await openStore(directory: foreignDirectory.path);
      try {
        final before = snapshot();
        expect(
          () => adopt(sourceJournal: bindJournal(target: foreign)),
          throwsA(anything),
        );
        expect(snapshot(), before);
        expect(foreign.box<CloudInboxChangeEntity>().count(), 0);
      } finally {
        foreign.close();
        await foreignDirectory.delete(recursive: true);
      }
    },
  );

  for (final kind in ['newer version', 'tombstone', 'different change']) {
    test('existing $kind cannot be displaced by a historical lookup', () {
      expect(adopt(), isTrue);
      final box = store.box<CloudInboxChangeEntity>();
      final existing = box.getAll().single;
      if (kind == 'newer version') existing.etagHash = 'Z' * 43;
      if (kind == 'tombstone') existing.isTombstone = true;
      if (kind == 'different change') {
        existing.changeKey = 'synthetic-newer-change';
      }
      box.put(existing);
      final before = snapshot();
      expect(
        () => adopt(),
        throwsA(
          isA<CloudSyncFailure>().having(
            (e) => e.safeCode,
            'code',
            'received_found_reader_newer_evidence',
          ),
        ),
      );
      expect(snapshot(), before);
    });
  }

  test(
    'pending remote page is not overwritten by exact historical discovery',
    () {
      final box = store.box<CloudSyncCheckpointEntity>();
      box.put(box.getAll().single..pendingBatchId = 'pending-existing-page');
      final before = snapshot();
      expect(
        () => adopt(),
        throwsA(
          isA<CloudSyncFailure>().having(
            (e) => e.safeCode,
            'code',
            'checkpoint_pending_page_unresolved',
          ),
        ),
      );
      expect(snapshot(), before);
    },
  );

  test(
    'retained record map prevents resurrecting an older historical record',
    () {
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
      store.box<CloudRecordMapEntity>().put(
        CloudRecordMapEntity(
          mapKey: 'synthetic-retained-record',
          scopeKey: checkpoint.checkpointKey,
          accountFingerprint: _scope.accountFingerprint,
          zone: _scope.zone,
          logicalEntityKeyHash: 'L' * 43,
          serverRecordIdHash: _change().recordIdHash,
          generation: generation,
          encryptedServerRecordId: 'obcs2.ref.${'Z' * 43}',
          updatedAtMs: _now.millisecondsSinceEpoch,
        ),
      );
      final before = snapshot();
      expect(
        () => adopt(),
        throwsA(
          isA<CloudSyncFailure>().having(
            (e) => e.safeCode,
            'code',
            'received_found_reader_newer_evidence',
          ),
        ),
      );
      expect(snapshot(), before);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
    },
  );
  test(
    'uncertain outgoing work stays unchanged and prevents historical adoption',
    () {
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
      final id = store.box<CloudOutboxOperationEntity>().put(
        CloudOutboxOperationEntity(
          operationId: 'op1:${'f' * 64}',
          scopeKey: checkpoint.checkpointKey,
          accountFingerprint: _scope.accountFingerprint,
          zone: _scope.zone,
          logicalEntityKeyHash: 'L' * 43,
          action: CloudOutboxAction.save.index,
          payloadVersion: 1,
          mutationRevision: 1,
          state: CloudOutboxStatus.unknownOutcome.index,
          createdAtMs: _now.millisecondsSinceEpoch,
          updatedAtMs: _now.millisecondsSinceEpoch,
        ),
      );
      final before = snapshot();
      expect(
        () => adopt(),
        throwsA(
          isA<CloudSyncFailure>().having(
            (e) => e.safeCode,
            'code',
            'received_found_reader_outbox_unsettled',
          ),
        ),
      );
      expect(snapshot(), before);
      expect(
        store.box<CloudOutboxOperationEntity>().get(id)!.state,
        CloudOutboxStatus.unknownOutcome.index,
      );
    },
  );
}

class _HistoricalPause implements CloudSyncNativeWriterPause {
  bool active = false;
  @override
  Future<Object> pause() async {
    active = true;
    return BigInt.one;
  }

  @override
  Future<void> resume(Object token) async {
    active = false;
  }
}

class _HistoricalLeaseTransport
    implements
        CloudProtectedPageLeaseTransport,
        CloudProtectedLocalLifecycleTransport {
  bool failCommit = false;
  final committed = <String>[];
  final rolledBack = <String>[];
  final recovered = <Set<String>>[];
  @override
  String get protectedPageLeaseRecoveryIdentity => _storeIdentity;
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<T> runLocalProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<void> commitProtectedPageLease(
    String reference,
    Set<String> live,
  ) async {
    committed.add(reference);
    if (failCommit) throw StateError('synthetic lost commit response');
  }

  @override
  Future<void> acknowledgeCommittedPageLease(String reference) async {}
  @override
  Future<void> rollbackProtectedPageLease(String reference) async {
    rolledBack.add(reference);
  }

  @override
  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adopted,
    CloudProtectedReferenceSnapshot live,
  ) async {
    recovered.add(adopted);
    return CloudProtectedPageLeaseRecoveryResult(
      finalizedAdoptedLeaseReferences: adopted,
      hasMore: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected native call');
}

class _TestProtector implements CloudSyncProtector {
  String _prefix(CloudSyncScope scope, CloudSyncProtectedValueKind kind) =>
      'synthetic-history:${scope.storageKey}:${kind.name}:';
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async => '${_prefix(scope, kind)}$plaintext';
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    final prefix = _prefix(scope, kind);
    if (!ciphertext.startsWith(prefix)) {
      throw StateError('synthetic_scope_changed');
    }
    return ciphertext.substring(prefix.length);
  }

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) =>
      throw StateError('unexpected_account_access');
}
