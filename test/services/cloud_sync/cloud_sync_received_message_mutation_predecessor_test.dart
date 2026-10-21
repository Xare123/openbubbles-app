import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_message_dependency.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_received_archive_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _guid = 'B3E7A1C4-9D2F-4B6E-8A1C-5F0E9D2C7B3A';
// Opaque synthetic shape-only values, not native keyed hashes or Apple proof.
final _logical = 'L' * 43;
final _record = 'R' * 43;
final _etag = 'E' * 43;
final _now = DateTime.utc(2026, 10, 21);
final _scope = CloudSyncScope(
  accountFingerprint: 'A' * 43,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: 'messageManateeZone',
  streamKind: CloudSyncStreamKind.messages,
  schemaVersion: cloudSyncSchemaVersion,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);
final _blocked = throwsA(isA<CloudSyncFailure>());

void main() {
  for (final origin in CloudSyncReceivedArchiveOrigin.values) {
    group(origin.name, () {
      late _Fixture f;
      setUp(() async => f = await _Fixture.create(origin));
      tearDown(() async => f.close());

      test(
        'resolves exact current local evidence and survives restart',
        () async {
          final counts = f.counts;
          final first = f.resolve();
          expect(first.localMessageId, f.messageId);
          expect(first.generation, 1);
          expect(
            first.canonicalGuidLookupHash,
            f.snapshot.canonicalGuidLookupHash,
          );
          expect(first.canonicalGuidHash, f.snapshot.canonicalGuidHash);
          expect(first.recordMapping.logicalEntityKeyHash, _logical);
          expect(first.recordMapping.serverRecordIdHash, _record);
          expect(first.recordMapping.etagHash, _etag);
          expect(first.recordMapping.rawRecordGeneration, 1);
          expect(
            first.toString(),
            'CloudSyncMessageMutationPredecessor(redacted)',
          );
          expect(
            f.counts,
            counts,
            reason: 'resolution must not enqueue or mutate',
          );
          await f.reopen();
          expect(
            f.resolve().recordMapping.sameDurableSnapshotAs(
              first.recordMapping,
            ),
            isTrue,
          );
          expect(f.counts, counts);
        },
      );

      test('requires the received namespace and exact persisted direction', () {
        var callbackCalls = 0;
        List<Object>? reader(Message _) {
          callbackCalls++;
          return f.confirmedProof;
        }

        for (final hash in [
          '',
          'f' * 64,
          _guidHash('cloud-sync-local-send-guid-v1'),
          _guidHash('cloud-sync-received-archive-guid-v1').toUpperCase(),
        ]) {
          expect(
            () => f.resolve(targetGuidHash: hash, reader: reader),
            _blocked,
          );
        }
        for (final direction in [null, !f.expectedDirection]) {
          f.changeMessage((row) => row.isFromMe = direction);
          expect(() => f.resolve(reader: reader), _blocked);
        }
        expect(
          callbackCalls,
          0,
          reason: 'a callback cannot bypass origin gates',
        );
        f.changeMessage((row) => row.isFromMe = f.expectedDirection);
        expect(f.resolve, returnsNormally);
      });

      test(
        'rejects missing target IDs, wrong Chat and changed target GUID',
        () {
          expect(() => f.resolve(localMessageId: 0), _blocked);
          expect(() => f.resolve(localMessageId: f.messageId + 999), _blocked);
          expect(() => f.resolve(localChatId: 0), _blocked);
          final foreign = Chat(guid: 'synthetic-foreign-chat', style: 45);
          f.db.box<Chat>().put(foreign);
          expect(() => f.resolve(localChatId: foreign.id), _blocked);
          f.changeMessage((row) => row.chat.target = foreign);
          expect(f.resolve, _blocked);
          f.changeMessage((row) {
            row.chat.targetId = f.chatId;
            row.guid = _guid.toLowerCase();
          });
          expect(f.resolve, _blocked, reason: 'exact GUID spelling is pinned');
        },
      );

      test('does not borrow another account scope', () {
        final foreign = CloudSyncScope(
          accountFingerprint: 'Z' * 43,
          container: _scope.container,
          database: _scope.database,
          zone: _scope.zone,
          streamKind: _scope.streamKind,
          schemaVersion: _scope.schemaVersion,
          persistenceLane: _scope.persistenceLane,
        );
        expect(() => f.resolve(messageScope: foreign), _blocked);
      });

      test('rejects ambiguous current canonical snapshots', () {
        final duplicate = f.snapshot
          ..id = 0
          ..snapshotKey = 'synthetic-second-canonical-snapshot';
        f.db.box<CloudSemanticSnapshotEntity>().put(duplicate);
        expect(f.resolve, _blocked);
      });

      test('accepts a fully applied update only after all sources agree', () {
        f.changeMapping((row) => row.etagHash = 'N' * 43);
        expect(f.resolve, _blocked);
        f.changeSnapshot((row) => row.etagHash = 'N' * 43);
        expect(
          f.resolve,
          _blocked,
          reason: 'the old inbox cannot prove new raw',
        );
        f.appendSource();
        expect(f.resolve().recordMapping.etagHash, 'N' * 43);
      });

      test('keeps exact optional confirmed-local-parent proof checks', () {
        final proof = f.confirmedProof;
        f.db.box<CloudSemanticSnapshotEntity>().removeAll();
        f.db.box<CloudInboxChangeEntity>().removeAll();
        expect(() => f.resolve(reader: (_) => null), _blocked);
        final confirmed = f.resolve(reader: (_) => proof);
        expect(confirmed.canonicalGuidLookupHash, proof[4]);
        expect(confirmed.canonicalGuidHash, proof[5]);
        expect(confirmed.recordMapping.serverRecordIdHash, proof[7]);
        final changes = <int, Object>{
          0: 1,
          1: 'foreign-scope',
          2: 2,
          3: f.messageId + 1,
          4: 'f' * 64,
          5: 'f' * 64,
          6: 'N' * 43,
          7: 'N' * 43,
          8: 0,
          9: 'not-a-digest',
        };
        for (final change in changes.entries) {
          final changed = List<Object>.from(proof)..[change.key] = change.value;
          expect(
            () => f.resolve(reader: (_) => changed),
            _blocked,
            reason: 'pinned proof field ${change.key}',
          );
        }
        expect(() => f.resolve(reader: (_) => proof.sublist(1)), _blocked);
        f.changeMapping((row) => row.pendingUpdateOperationId = 'unfinished');
        expect(() => f.resolve(reader: (_) => proof), _blocked);
      });

      test('propagates the owner callback failure', () {
        final failure = StateError('synthetic-owner-proof-failure');
        expect(
          () => f.resolve(reader: (_) => throw failure),
          throwsA(same(failure)),
        );
      });

      final drifts = <String, void Function(_Fixture)>{
        'deleted local target': (f) =>
            f.changeMessage((r) => r.dateDeleted = _now),
        'failed verification': (f) =>
            f.changeMessage((r) => r.verificationFailed = true),
        'associated target': (f) =>
            f.changeMessage((r) => r.associatedMessagePart = 0),
        'checkpoint generation': (f) =>
            f.changeCheckpoint((r) => r.generation = 2),
        'checkpoint account': (f) =>
            f.changeCheckpoint((r) => r.accountFingerprint = 'Z' * 43),
        'legacy checkpoint lane': (f) =>
            f.changeCheckpoint((r) => r.persistenceLane = null),
        'missing snapshot': (f) {
          f.db.box<CloudSemanticSnapshotEntity>().removeAll();
        },
        'old snapshot index': (f) => f.changeSnapshot(
          (r) => r.snapshotKey = r.snapshotKey.replaceFirst(
            'snapshot4',
            'snapshot3',
          ),
        ),
        'old generation index': (f) => f.changeSnapshot(
          (r) => r.scopeGenerationKey = r.scopeGenerationKey.replaceFirst(
            'generation4',
            'generation3',
          ),
        ),
        'snapshot canonical hash': (f) =>
            f.changeSnapshot((r) => r.canonicalGuidHash = 'f' * 64),
        'snapshot lookup hash': (f) =>
            f.changeSnapshot((r) => r.canonicalGuidLookupHash = 'f' * 64),
        'snapshot generation': (f) => f.changeSnapshot((r) => r.generation = 2),
        'snapshot kind': (f) => f.changeSnapshot(
          (r) => r.entityKind = CloudEntityKind.reaction.name,
        ),
        'snapshot scope': (f) =>
            f.changeSnapshot((r) => r.scopeKey = 'foreign-scope'),
        'missing canonical map': (f) {
          f.db.box<CloudRecordMapEntity>().removeAll();
        },
        'map account': (f) =>
            f.changeMapping((r) => r.accountFingerprint = 'Z' * 43),
        'map generation': (f) => f.changeMapping((r) => r.generation = 2),
        'map logical identity': (f) =>
            f.changeMapping((r) => r.logicalEntityKeyHash = 'N' * 43),
        'missing raw map reference': (f) =>
            f.changeMapping((r) => r.encryptedRawRecordRef = null),
        'malformed raw map reference': (f) =>
            f.changeMapping((r) => r.encryptedRawRecordRef = 'unprotected'),
        'raw map generation': (f) =>
            f.changeMapping((r) => r.rawRecordGeneration = 2),
        'malformed encrypted record ID': (f) =>
            f.changeMapping((r) => r.encryptedServerRecordId = 'unprotected'),
        'missing ETag': (f) => f.changeMapping((r) => r.etagHash = null),
        'ETag drift': (f) => f.changeMapping((r) => r.etagHash = 'N' * 43),
        'pending readback lease': (f) => f.changeMapping(
          (r) => r.protectedReadbackLeaseReference = 'obcs2.lease.${'a' * 32}',
        ),
        'pending update operation': (f) =>
            f.changeMapping((r) => r.pendingUpdateOperationId = 'unfinished'),
        'pending predecessor ETag': (f) =>
            f.changeMapping((r) => r.pendingUpdatePredecessorEtagHash = _etag),
        'missing applied inbox': (f) {
          f.db.box<CloudInboxChangeEntity>().removeAll();
        },
        'latest pending inbox': (f) =>
            f.appendSource(status: CloudInboxStatus.pending),
        'latest retained inbox': (f) =>
            f.appendSource(status: CloudInboxStatus.retainedUnprojected),
        'latest tombstone': (f) => f.appendSource(deleted: true),
        'inbox raw source drift': (f) => f.changeInbox(
          (r) => r.encryptedPayloadRef = 'obcs2.ref.${'N' * 43}',
        ),
        'inbox encrypted record drift': (f) => f.changeInbox(
          (r) => r.encryptedServerRecordId = 'obcs2.ref.${'N' * 43}',
        ),
        'inbox ETag drift': (f) => f.changeInbox((r) => r.etagHash = 'N' * 43),
        'inbox generation': (f) => f.changeInbox((r) => r.generation = 2),
        'inbox change type': (f) =>
            f.changeInbox((r) => r.changeType = CloudChangeType.delete.name),
      };
      for (final drift in drifts.entries) {
        test('rejects ${drift.key}', () {
          expect(f.resolve, returnsNormally);
          drift.value(f);
          final counts = f.counts;
          expect(f.resolve, _blocked);
          expect(
            f.counts,
            counts,
            reason: 'a rejection must preserve local evidence',
          );
        });
      }
    });
  }
}

final class _Fixture {
  _Fixture(this.directory, this.db, this.origin);

  final Directory directory;
  Store db;
  final CloudSyncReceivedArchiveOrigin origin;
  late int messageId;
  late int chatId;

  bool get expectedDirection =>
      origin == CloudSyncReceivedArchiveOrigin.mirrored;
  String get scopeKey => cloudSyncPersistentScopeKey(_scope);
  CloudSyncCheckpointEntity get checkpoint =>
      db.box<CloudSyncCheckpointEntity>().getAll().single;
  CloudSemanticSnapshotEntity get snapshot =>
      db.box<CloudSemanticSnapshotEntity>().getAll().single;
  CloudRecordMapEntity get mapping =>
      db.box<CloudRecordMapEntity>().getAll().single;
  List<int> get counts => [
    db.box<Message>().count(),
    db.box<CloudSyncCheckpointEntity>().count(),
    db.box<CloudSemanticSnapshotEntity>().count(),
    db.box<CloudRecordMapEntity>().count(),
    db.box<CloudInboxChangeEntity>().count(),
    db.box<CloudOutboxOperationEntity>().count(),
  ];

  List<Object> get confirmedProof => [
    2,
    scopeKey,
    checkpoint.generation,
    messageId,
    snapshot.canonicalGuidLookupHash!,
    snapshot.canonicalGuidHash!,
    _logical,
    _record,
    23,
    'a' * 64,
  ];

  static Future<_Fixture> create(CloudSyncReceivedArchiveOrigin origin) async {
    final directory = await Directory.systemTemp.createTemp(
      'received-mutation-predecessor-',
    );
    final f = _Fixture(
      directory,
      await openStore(directory: directory.path),
      origin,
    );
    final chat = Chat(guid: 'synthetic-received-chat', style: 45);
    f.chatId = f.db.box<Chat>().put(chat);
    f.messageId = f.db.box<Message>().put(
      Message(
        guid: _guid,
        text: 'synthetic received target',
        isFromMe: f.expectedDirection,
        dateCreated: _now,
      )..chat.target = chat,
    );
    f.db.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: f.scopeKey,
        accountFingerprint: _scope.accountFingerprint,
        container: _scope.container,
        database: _scope.database,
        zone: _scope.zone,
        streamKind: _scope.streamKind.name,
        schemaVersion: _scope.schemaVersion,
        persistenceLane: _scope.persistenceLane.name,
        generation: 1,
        fetchedSequence: 1,
        appliedSequence: 1,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    final generationKey =
        'semantic-generation4:${_digest('${f.scopeKey}\u001f1')}';
    f.db.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey: 'semantic-snapshot4:$generationKey:message:$_logical',
        scopeGenerationKey: generationKey,
        scopeKey: f.scopeKey,
        accountFingerprint: _scope.accountFingerprint,
        container: _scope.container,
        database: _scope.database,
        zone: _scope.zone,
        streamKind: _scope.streamKind.name,
        schemaVersion: _scope.schemaVersion,
        generation: 1,
        entityKind: CloudEntityKind.message.name,
        logicalEntityKeyHash: _logical,
        canonicalGuidLookupHash:
            CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
              scope: _scope,
              generation: 1,
              canonicalGuid: _guid,
            ),
        canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
          scope: _scope,
          generation: 1,
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: _logical,
          canonicalGuid: _guid,
        ),
        etagHash: _etag,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    f.db.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: cloudSyncCanonicalRecordMapKey(_scope, _logical),
        scopeKey: f.scopeKey,
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        logicalEntityKeyHash: _logical,
        serverRecordIdHash: _record,
        generation: 1,
        encryptedServerRecordId: 'obcs2.ref.${'R' * 43}',
        etagHash: _etag,
        encryptedRawRecordRef: 'obcs2.ref.${'P' * 43}',
        rawRecordGeneration: 1,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
    f.appendSource();
    return f;
  }

  CloudSyncMessageMutationPredecessor resolve({
    int? localMessageId,
    int? localChatId,
    String? targetGuidHash,
    CloudSyncScope? messageScope,
    CloudSyncConfirmedLocalParentReader? reader,
  }) => db.runInTransaction(
    TxMode.read,
    () => requireCloudSyncReceivedMessageMutationPredecessor(
      store: db,
      messageScope: messageScope ?? _scope,
      localMessageId: localMessageId ?? messageId,
      localChatId: localChatId ?? chatId,
      targetGuidHash:
          targetGuidHash ?? _guidHash('cloud-sync-received-archive-guid-v1'),
      origin: origin,
      readConfirmedLocalParent: reader,
    ),
  );

  void changeMessage(void Function(Message) change) {
    final row = db.box<Message>().get(messageId)!;
    change(row);
    db.box<Message>().put(row);
  }

  void changeCheckpoint(void Function(CloudSyncCheckpointEntity) change) {
    final row = checkpoint;
    change(row);
    db.box<CloudSyncCheckpointEntity>().put(row);
  }

  void changeSnapshot(void Function(CloudSemanticSnapshotEntity) change) {
    final row = snapshot;
    change(row);
    db.box<CloudSemanticSnapshotEntity>().put(row);
  }

  void changeMapping(void Function(CloudRecordMapEntity) change) {
    final row = mapping;
    change(row);
    db.box<CloudRecordMapEntity>().put(row);
  }

  void changeInbox(void Function(CloudInboxChangeEntity) change) {
    final row = db.box<CloudInboxChangeEntity>().getAll().single;
    change(row);
    db.box<CloudInboxChangeEntity>().put(row);
  }

  void appendSource({
    CloudInboxStatus status = CloudInboxStatus.applied,
    bool deleted = false,
  }) {
    final map = mapping;
    final sequence = db.box<CloudInboxChangeEntity>().count() + 1;
    db.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        changeKey: 'synthetic-received-change-$sequence',
        changeIdHash: 'C' * 43,
        scopeKey: scopeKey,
        accountFingerprint: _scope.accountFingerprint,
        zone: _scope.zone,
        serverRecordIdHash: map.serverRecordIdHash,
        etagHash: map.etagHash,
        changeType: deleted
            ? CloudChangeType.delete.name
            : CloudChangeType.save.name,
        encryptedServerRecordId: map.encryptedServerRecordId,
        encryptedPayloadRef: deleted ? null : map.encryptedRawRecordRef,
        payloadSha256: deleted ? null : 'a' * 64,
        batchId: 'synthetic-received-batch-$sequence',
        generation: checkpoint.generation,
        fetchSequence: sequence,
        status: status.index,
        isTombstone: deleted,
        createdAtMs: _now.millisecondsSinceEpoch,
        updatedAtMs: _now.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> reopen() async {
    db.close();
    db = await openStore(directory: directory.path);
  }

  Future<void> close() async {
    if (!db.isClosed()) db.close();
    await directory.delete(recursive: true);
  }
}

String _guidHash(String namespace) => _digest(jsonEncode([namespace, _guid]));
String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
