import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_protected_page_lease_lifecycle.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_exact_message_reader.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

final _now = DateTime.utc(2026, 10, 26, 20);
final _scope = CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

CloudFetchedChange _change({
  String? changeId,
  String? recordIdHash,
  String? etagHash,
  String? payloadSha256,
  String identity = 'I',
  String raw = 'Y',
}) => CloudFetchedChange(
  changeId: changeId ?? 'D' * 43,
  recordIdHash: recordIdHash ?? 'R' * 43,
  etagHash: etagHash ?? 'E' * 43,
  type: CloudChangeType.save,
  encryptedServerRecordId: 'obcs2.ref.${identity * 43}',
  encryptedPayloadReference: 'obcs2.ref.${raw * 43}',
  payloadSha256: payloadSha256 ?? 'd' * 64,
  serverModifiedAt: _now,
);

class _TestProtector implements CloudSyncProtector {
  String _prefix(CloudSyncScope scope, CloudSyncProtectedValueKind kind) =>
      'synthetic-exact-reader:${scope.storageKey}:${kind.name}:';

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

void main() {
  late Directory directory;
  late Store store;
  late ObjectBoxCloudSyncStore durable;
  late CloudCoordinatorLeaseFence fence;
  late int generation;
  late String scopeKey;

  ObjectBoxCloudSyncStore bindStore() => ObjectBoxCloudSyncStore(
    store: store,
    protector: _TestProtector(),
    clock: () => _now,
  );

  bool adopt({
    CloudFetchedChange? change,
    int? atGeneration,
    CloudCoordinatorLeaseFence? leaseFence,
    bool Function()? stillCurrent,
    String lease = '1',
  }) => durable.journalExactReadFound(
    scope: _scope,
    change: change ?? _change(),
    generation: atGeneration ?? generation,
    batchId: 'B' * 43,
    leaseReference: 'obcs2.lease.${lease * 32}',
    leaseFence: leaseFence ?? fence,
    stillCurrent: stillCurrent ?? () => true,
  );

  Map<String, Object?> snapshot() {
    final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
    return {
      'checkpoint': [
        checkpoint.fetchedTokenCiphertext,
        checkpoint.pendingFetchedTokenCiphertext,
        checkpoint.pendingBatchId,
        checkpoint.fetchedSequence,
        checkpoint.appliedSequence,
        checkpoint.generation,
      ],
      'inbox': store
          .box<CloudInboxChangeEntity>()
          .getAll()
          .map(
            (row) => [
              row.id,
              row.changeKey,
              row.changeIdHash,
              row.etagHash,
              row.isTombstone,
              row.encryptedPayloadRef,
              row.encryptedServerRecordId,
              row.fetchSequence,
            ],
          )
          .toList(),
      'pageLeases': store
          .box<CloudProtectedPageLeaseEntity>()
          .getAll()
          .map(
            (row) => [
              row.leaseReference,
              row.scopeKey,
              row.generation,
              row.batchIdHash,
            ],
          )
          .toList(),
      'messages': store
          .box<Message>()
          .getAll()
          .map((message) => [message.id, message.guid, message.text])
          .toList(),
      'historicalIntents': store
          .box<CloudSyncHistoricalArchiveIntentEntity>()
          .count(),
      'receivedIntents': store
          .box<CloudSyncReceivedArchiveIntentEntity>()
          .count(),
      'receivedMutationIntents': store
          .box<CloudSyncReceivedMutationIntentEntity>()
          .count(),
      'localSendIntents': store.box<CloudSyncLocalSendIntentEntity>().count(),
      'outbox': store.box<CloudOutboxOperationEntity>().count(),
    };
  }

  setUp(() async {
    CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests();
    directory = await Directory.systemTemp.createTemp('ob-exact-reader-');
    store = await openStore(directory: directory.path);
    durable = bindStore();
    await durable.recordPullSuccess(_scope, now: _now);
    fence = (await durable.tryAcquireCoordinatorLease(
      _scope,
      ownerId: 'exact-reader-test',
      now: _now,
      leaseDuration: const Duration(hours: 1),
    ))!;
    var checkpoint = await durable.readCheckpoint(_scope);
    generation = checkpoint.generation;
    await durable.journalFetchedBatch(
      CloudFetchBatch(
        scope: _scope,
        changes: const [],
        batchId: 'synthetic-exact-reader-baseline',
        generation: generation,
        nextToken: 'preserve-existing-server-cursor',
        hasMore: false,
      ),
      now: _now,
      leaseFence: fence,
      expectedGeneration: generation,
      expectedFetchedToken: checkpoint.fetchedToken,
      expectedFetchDirection: checkpoint.fetchDirection,
    );
    checkpoint = await durable.readCheckpoint(_scope);
    scopeKey = store
        .box<CloudSyncCheckpointEntity>()
        .getAll()
        .single
        .checkpointKey;
    expect(checkpoint.fetchedToken, 'preserve-existing-server-cursor');
  });

  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await directory.resolveSymbolicLinks();
      if (!path.isWithin(root, target) ||
          !path.basename(target).startsWith('ob-exact-reader-')) {
        throw StateError('exact_test_cleanup_target_invalid');
      }
      await directory.delete(recursive: true);
    }
  });

  test(
    'exact Found adopts one pending inbox row without changing cursor or messages',
    () async {
      final existingMessage = Message(
        guid: 'existing-local-message',
        text: 'preserve this local row',
      );
      store.box<Message>().put(existingMessage);
      final before = snapshot();

      expect(adopt(), isTrue);

      final after = snapshot();
      final oldCheckpoint = before['checkpoint'] as List<Object?>;
      final newCheckpoint = after['checkpoint'] as List<Object?>;
      expect(newCheckpoint.take(3), oldCheckpoint.take(3));
      expect(newCheckpoint[4], oldCheckpoint[4]);
      expect(newCheckpoint[5], oldCheckpoint[5]);
      expect(newCheckpoint[3], (oldCheckpoint[3] as int) + 1);
      expect((after['inbox'] as List).length, 1);
      final inbox = store.box<CloudInboxChangeEntity>().getAll().single;
      expect(inbox.status, CloudInboxStatus.pending.index);
      expect(inbox.changeIdHash, _change().changeId);
      expect(after['pageLeases'], hasLength(1));
      expect(after['messages'], before['messages']);
      expect(after['historicalIntents'], 0);
      expect(after['receivedIntents'], 0);
      expect(after['receivedMutationIntents'], 0);
      expect(after['localSendIntents'], 0);
      expect(after['outbox'], 0);
    },
  );

  test(
    'exact read selection waits for its nonterminal predecessor without cursor writes',
    () {
      expect(adopt(), isTrue);
      final exact = store.box<CloudInboxChangeEntity>().getAll().single;
      CloudInboxEntry? selected() => durable.readExactReadEntry(
        scope: _scope,
        generation: generation,
        changeId: _change().changeId,
        leaseFence: fence,
      );

      expect(selected()?.change.changeId, _change().changeId);
      exact.fetchSequence = 2;
      store.box<CloudInboxChangeEntity>().put(exact);
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
      checkpoint.fetchedSequence = 2;
      store.box<CloudSyncCheckpointEntity>().put(checkpoint);
      final checkpointBefore = snapshot()['checkpoint'];
      final predecessor = CloudInboxChangeEntity(
        changeKey: 'synthetic-predecessor-key',
        changeIdHash: 'P' * 43,
        scopeKey: scopeKey,
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        serverRecordIdHash: 'S' * 43,
        etagHash: 'T' * 43,
        changeType: CloudChangeType.save.name,
        encryptedServerRecordId: 'obcs2.ref.${'J' * 43}',
        encryptedPayloadRef: 'obcs2.ref.${'Z' * 43}',
        payloadSha256: 'e' * 64,
        batchId: 'synthetic-predecessor-batch',
        generation: generation,
        fetchSequence: exact.fetchSequence - 1,
        status: CloudInboxStatus.pending.index,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      );
      store.box<CloudInboxChangeEntity>().put(predecessor);

      expect(selected(), isNull);
      predecessor.status = CloudInboxStatus.applied.index;
      store.box<CloudInboxChangeEntity>().put(predecessor);
      expect(selected()?.change.changeId, _change().changeId);
      expect(snapshot()['checkpoint'], checkpointBefore);
    },
  );

  test('exact duplicate preserves original protected references and lease', () {
    expect(adopt(), isTrue);
    final before = snapshot();

    expect(
      adopt(
        change: _change(identity: 'U', raw: 'V'),
        lease: '2',
      ),
      isFalse,
    );

    expect(snapshot(), before);
    final inbox = store.box<CloudInboxChangeEntity>().getAll().single;
    expect(inbox.encryptedPayloadRef, _change().encryptedPayloadReference);
    expect(inbox.encryptedServerRecordId, _change().encryptedServerRecordId);
    expect(store.box<CloudProtectedPageLeaseEntity>().count(), 1);
  });

  test('conflicting etag or raw digest refuses atomically', () {
    expect(adopt(), isTrue);
    for (final conflicting in [
      _change(etagHash: 'Q' * 43),
      _change(payloadSha256: 'f' * 64),
    ]) {
      final before = snapshot();
      expect(
        () => adopt(change: conflicting, lease: '2'),
        throwsA(
          isA<CloudSyncFailure>().having(
            (e) => e.safeCode,
            'safe code',
            'received_found_reader_newer_evidence',
          ),
        ),
      );
      expect(snapshot(), before);
    }
  });

  test('existing record map blocks exact adoption without changing rows', () {
    store.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: 'synthetic-existing-map',
        scopeKey: scopeKey,
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        logicalEntityKeyHash: 'L' * 43,
        serverRecordIdHash: _change().recordIdHash,
        generation: generation,
        encryptedServerRecordId: 'obcs2.ref.${'I' * 43}',
        etagHash: 'E' * 43,
        encryptedRawRecordRef: 'obcs2.ref.${'Y' * 43}',
        rawRecordGeneration: generation,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    final before = snapshot();

    expect(
      () => adopt(),
      throwsA(
        isA<CloudSyncFailure>().having(
          (e) => e.safeCode,
          'safe code',
          'received_found_reader_newer_evidence',
        ),
      ),
    );

    expect(snapshot(), before);
    expect(store.box<CloudProtectedPageLeaseEntity>().count(), 0);
  });

  test('unsettled outbox operation blocks exact adoption atomically', () {
    store.box<CloudOutboxOperationEntity>().put(
      CloudOutboxOperationEntity(
        operationId: 'op1:${'f' * 64}',
        scopeKey: scopeKey,
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        logicalEntityKeyHash: 'L' * 43,
        action: 0,
        mutationRevision: 1,
        checkpointGeneration: generation,
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
          'safe code',
          'received_found_reader_outbox_unsettled',
        ),
      ),
    );

    expect(snapshot(), before);
    expect(store.box<CloudInboxChangeEntity>().count(), 0);
    expect(store.box<CloudProtectedPageLeaseEntity>().count(), 0);
  });

  test(
    'coordinator, generation, and currentness guards refuse without mutation',
    () {
      final before = snapshot();
      for (final attempt in [
        () => adopt(
          leaseFence: const CloudCoordinatorLeaseFence(
            ownerId: 'different-owner',
            generation: 1,
          ),
        ),
        () => adopt(atGeneration: generation + 1),
        () => adopt(stillCurrent: () => false),
      ]) {
        expect(attempt, throwsA(anything));
        expect(snapshot(), before);
      }
    },
  );

  api.CloudSyncExactMessageFound stage({
    int? atGeneration,
    String lease = '1',
  }) => api.CloudSyncExactMessageFound(
    generation: BigInt.from(atGeneration ?? generation),
    batchId: 'B' * 43,
    leaseReference: 'obcs2.lease.${lease * 32}',
    change: api.CloudSyncProtectedChange(
      changeId: 'D' * 43,
      recordIdHash: 'R' * 43,
      etagHash: 'E' * 43,
      kind: api.CloudSyncProtectedChangeKind.save,
      payloadSha256: 'd' * 64,
      payloadLength: BigInt.from(128),
      protectedRecordIdentityReference: 'obcs2.ref.${'I' * 43}',
      protectedRawEnvelopeReference: 'obcs2.ref.${'Y' * 43}',
      preflightCode: null,
      isTombstone: false,
    ),
  );
  Future<void> runStage(
    _ExactLeaseTransport transport, {
    api.CloudSyncExactMessageFound? result,
    Future<void> Function()? validate,
  }) => adoptCloudSyncExactMessageFound(
    result: result ?? stage(),
    scope: _scope,
    generation: generation,
    coordinator: fence,
    durable: durable,
    lifecycle: CloudProtectedPageLeaseLifecycle(
      store: durable,
      transport: transport,
    ),
    validate: validate ?? () async {},
    stillCurrent: () => true,
  );

  test(
    'unadopted native lease rolls back after changed identity or generation',
    () async {
      for (final identityChanged in [true, false]) {
        final transport = _ExactLeaseTransport();
        final before = snapshot();
        await expectLater(
          runStage(
            transport,
            result: stage(
              atGeneration: identityChanged ? generation : generation + 1,
            ),
            validate: () async {
              if (identityChanged) {
                throw StateError('synthetic-account-changed');
              }
            },
          ),
          throwsStateError,
        );
        expect(snapshot(), before);
        expect(transport.rolledBack, [stage().leaseReference]);
        expect(transport.committed, isEmpty);
      }
    },
  );

  test(
    'lost native lease commit keeps durable input for cold recovery without a new lookup',
    () async {
      final transport = _ExactLeaseTransport()..failCommit = true;
      final found = stage();
      await expectLater(runStage(transport), throwsStateError);
      expect(transport.rolledBack, isEmpty);
      expect(store.box<CloudInboxChangeEntity>().count(), 1);
      expect(store.box<CloudProtectedPageLeaseEntity>().count(), 1);
      store.close();
      store = await openStore(directory: directory.path);
      durable = bindStore();
      transport.failCommit = false;
      await CloudProtectedPageLeaseLifecycle(
        store: durable,
        transport: transport,
      ).ensureRecoveredBeforeFetch();
      expect(transport.recovered.single, contains(found.leaseReference));
      expect(store.box<CloudProtectedPageLeaseEntity>().count(), 0);
      expect(
        store.box<CloudInboxChangeEntity>().getAll().single.encryptedPayloadRef,
        found.change.protectedRawEnvelopeReference,
      );
      expect(store.box<CloudOutboxOperationEntity>().count(), 0);
    },
  );

  test(
    'duplicate staging rolls back only unused new lease and preserves original inbox',
    () async {
      final transport = _ExactLeaseTransport();
      await runStage(transport);
      final before = snapshot();
      await runStage(transport, result: stage(lease: '2'));
      expect(snapshot(), before);
      expect(transport.committed, [stage().leaseReference]);
      expect(transport.rolledBack, [stage(lease: '2').leaseReference]);
    },
  );
}

final class _ExactLeaseTransport implements CloudProtectedPageLeaseTransport {
  bool failCommit = false;
  final committed = <String>[];
  final rolledBack = <String>[];
  final recovered = <Set<String>>[];
  @override
  String get protectedPageLeaseRecoveryIdentity => 'obcs2.store.${'S' * 43}';
  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      action();
  @override
  Future<void> commitProtectedPageLease(
    String reference,
    Set<String> live,
  ) async {
    committed.add(reference);
    if (failCommit) throw StateError('synthetic-lost-commit-response');
  }

  @override
  Future<void> acknowledgeCommittedPageLease(String reference) async {}
  @override
  Future<void> rollbackProtectedPageLease(String reference) async =>
      rolledBack.add(reference);
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
      throw StateError('unexpected-native-operation');
}
