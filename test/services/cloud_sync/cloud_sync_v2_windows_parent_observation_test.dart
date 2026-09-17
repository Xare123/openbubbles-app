import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_parent_observation.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/api/cloud_sync_dependency.dart' as native;
import 'package:flutter_test/flutter_test.dart';

String _hash(String marker) => marker * 43;
String _ref(String marker) => 'obcs2.ref.${_hash(marker)}';
String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

void main() {
  test(
    'native locator result is bound to one child, parent generation and session',
    () {
      native.CloudSyncDependencyParentTarget target({
        String? sourceChange,
        String? sourceRecord,
        int sourceGeneration = 3,
        int messageGeneration = 4,
        String? parentLogical,
        String? physical,
        String session = 'synthetic-session',
        String? binding,
      }) => native.CloudSyncDependencyParentTarget(
        sourceChangeIdHash: sourceChange ?? _hash('C'),
        sourceRecordIdHash: sourceRecord ?? _hash('S'),
        sourceGeneration: BigInt.from(sourceGeneration),
        messageGeneration: BigInt.from(messageGeneration),
        parentLogicalKeyHash: parentLogical ?? _hash('L'),
        parentRecordIdHash: physical ?? _hash('R'),
        nativeSessionId: session,
        bindingHash: binding ?? _hash('B'),
      );
      String? validate(native.CloudSyncDependencyParentResult result) =>
          validateCloudSyncParentLocator(
            result: result,
            sourceChangeHash: _hash('C'),
            sourceRecordHash: _hash('S'),
            sourceGeneration: 3,
            messageGeneration: 4,
            parentLogicalHash: _hash('L'),
            nativeSessionId: 'synthetic-session',
          );
      expect(
        validate(native.CloudSyncDependencyParentResult(target: target())),
        _hash('R'),
      );
      expect(
        validate(
          const native.CloudSyncDependencyParentResult(
            failureCode: api.CloudSyncTransientFailureCode.invalidRequest,
          ),
        ),
        isNull,
      );
      for (final changed in [
        target(sourceChange: _hash('X')),
        target(sourceRecord: _hash('X')),
        target(sourceGeneration: 2),
        target(messageGeneration: 3),
        target(parentLogical: _hash('X')),
        target(physical: 'raw-record-name'),
        target(session: 'stale-session'),
        target(binding: ''),
      ]) {
        expect(
          () =>
              validate(native.CloudSyncDependencyParentResult(target: changed)),
          throwsStateError,
        );
      }
      expect(
        () => validate(const native.CloudSyncDependencyParentResult()),
        throwsStateError,
      );
      expect(
        () => validate(
          native.CloudSyncDependencyParentResult(
            target: target(),
            failureCode: api.CloudSyncTransientFailureCode.invalidRequest,
          ),
        ),
        throwsStateError,
      );
    },
  );

  const parentGuid = 'aabbccdd-1122-4333-8444-5566778899aa';
  const generation = 3;
  final parentHash = _hash('L');
  final now = DateTime.utc(2026, 9, 16, 12).millisecondsSinceEpoch;
  CloudSyncScope scopeFor(String account) => CloudSyncScope(
    accountFingerprint: _hash(account),
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final scope = scopeFor('A');
  late Directory root;
  late Directory directory;
  late Store store;

  setUp(() async {
    root = await Directory(
      '${Directory.current.path}/build/test-temp',
    ).create(recursive: true);
    directory = await root.createTemp('parent-observation-');
    store = await openStore(directory: directory.path);
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: cloudSyncPersistentScopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        persistenceLane: scope.persistenceLane.name,
        generation: generation,
        fetchDirection: 'newestFirst',
        fetchedTokenCiphertext: 'synthetic-fetched-token',
        pendingFetchedTokenCiphertext: 'synthetic-pending-token',
        pendingBatchId: 'synthetic-pending-batch',
        fetchedSequence: 10,
        appliedSequence: 1,
        mutationRevisionCounter: 4,
        updatedAtMs: now,
      ),
    );
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    if (directory.existsSync()) {
      expect(directory.parent.absolute.path, root.absolute.path);
      await directory.delete(recursive: true);
    }
  });

  CloudSemanticSnapshotEntity seedSnapshot({
    CloudSyncScope? owner,
    int epoch = generation,
  }) {
    final bound = owner ?? scope;
    final scopeKey = cloudSyncPersistentScopeKey(bound);
    final generationKey =
        'semantic-generation4:${_digest('$scopeKey\u001f$epoch')}';
    final row = CloudSemanticSnapshotEntity(
      snapshotKey: 'semantic-snapshot4:$generationKey:message:$parentHash',
      scopeGenerationKey: generationKey,
      scopeKey: scopeKey,
      accountFingerprint: bound.accountFingerprint,
      container: bound.container,
      database: bound.database,
      zone: bound.zone,
      streamKind: bound.streamKind.name,
      schemaVersion: bound.schemaVersion,
      generation: epoch,
      entityKind: CloudEntityKind.message.name,
      logicalEntityKeyHash: parentHash,
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: bound,
            generation: epoch,
            canonicalGuid: parentGuid,
          ),
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: bound,
        generation: epoch,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: parentHash,
        canonicalGuid: parentGuid,
      ),
      immutableContentDigest: _hash('D'),
      etagHash: _hash('E'),
      updatedAtMs: now,
    );
    row.id = store.box<CloudSemanticSnapshotEntity>().put(row);
    return row;
  }

  CloudRecordMapEntity seedMap({
    CloudSyncScope? owner,
    int epoch = generation,
  }) {
    final bound = owner ?? scope;
    final row = CloudRecordMapEntity(
      mapKey: cloudSyncCanonicalRecordMapKey(bound, parentHash),
      scopeKey: cloudSyncPersistentScopeKey(bound),
      accountFingerprint: bound.accountFingerprint,
      zone: bound.zone,
      logicalEntityKeyHash: parentHash,
      serverRecordIdHash: _hash('R'),
      generation: epoch,
      encryptedServerRecordId: _ref('I'),
      etagHash: _hash('E'),
      encryptedRawRecordRef: _ref('W'),
      rawRecordGeneration: epoch,
      updatedAtMs: now,
    );
    row.id = store.box<CloudRecordMapEntity>().put(row);
    return row;
  }

  CloudInboxChangeEntity seedInbox({
    CloudSyncScope? owner,
    int epoch = generation,
    int sequence = 2,
    String change = 'C',
    String etag = 'E',
    String raw = 'W',
    bool tombstone = false,
    bool excluded = false,
  }) {
    final bound = owner ?? scope;
    final row = CloudInboxChangeEntity(
      changeKey: cloudSyncPersistentChangeKey(bound, epoch, _hash(change)),
      changeIdHash: _hash(change),
      scopeKey: cloudSyncPersistentScopeKey(bound),
      accountFingerprint: bound.accountFingerprint,
      zone: bound.zone,
      serverRecordIdHash: _hash('R'),
      etagHash: tombstone ? null : _hash(etag),
      changeType: tombstone
          ? CloudChangeType.delete.name
          : CloudChangeType.save.name,
      encryptedServerRecordId: _ref('I'),
      protectedSystemFieldsRef: _ref('F'),
      encryptedPayloadRef: tombstone ? null : _ref(raw),
      payloadSha256: tombstone ? null : _digest('synthetic-payload-$change'),
      batchId: 'synthetic-batch-$change',
      generation: epoch,
      fetchSequence: sequence,
      isTombstone: tombstone,
      status: excluded
          ? CloudInboxStatus.retainedUnprojected.index
          : CloudInboxStatus.applied.index,
      failureCategory: excluded
          ? CloudFailureCategory.outOfScopeService.name
          : null,
      retryCount: excluded ? 2 : 0,
      createdAtMs: now,
      updatedAtMs: now,
      completedAtMs: now,
    );
    row.id = store.box<CloudInboxChangeEntity>().put(row);
    return row;
  }

  // Observe all relevant durable fields, not just counts: a diagnostic must
  // not normalize identity, clear retained debt or advance either cursor.
  String fingerprint() => jsonEncode({
    'checkpoints': store
        .box<CloudSyncCheckpointEntity>()
        .getAll()
        .map(
          (r) => [
            r.id,
            r.checkpointKey,
            r.accountFingerprint,
            r.container,
            r.database,
            r.zone,
            r.streamKind,
            r.schemaVersion,
            r.persistenceLane,
            r.fetchDirection,
            r.fetchedTokenCiphertext,
            r.pendingFetchedTokenCiphertext,
            r.pendingBatchId,
            r.generation,
            r.lastBatchId,
            r.fetchedSequence,
            r.appliedSequence,
            r.lastSuccessfulAtMs,
            r.lastAttemptAtMs,
            r.lastErrorCategory,
            r.backoffAttempt,
            r.nextEligibleAtMs,
            r.mutationRevisionCounter,
            r.updatedAtMs,
          ],
        )
        .toList(),
    'snapshots': store
        .box<CloudSemanticSnapshotEntity>()
        .getAll()
        .map(
          (r) => [
            r.id,
            r.snapshotKey,
            r.scopeGenerationKey,
            r.scopeKey,
            r.accountFingerprint,
            r.container,
            r.database,
            r.zone,
            r.streamKind,
            r.schemaVersion,
            r.generation,
            r.entityKind,
            r.logicalEntityKeyHash,
            r.canonicalGuidHash,
            r.canonicalGuidLookupHash,
            r.parentLogicalKeyHash,
            r.immutableContentDigest,
            r.createdAtMs,
            r.readAtMs,
            r.deliveredAtMs,
            r.editPartsJson,
            r.retractedAtMs,
            r.groupVersion,
            r.groupMetadataDigest,
            r.etagHash,
            r.updatedAtMs,
          ],
        )
        .toList(),
    'maps': store
        .box<CloudRecordMapEntity>()
        .getAll()
        .map(
          (r) => [
            r.id,
            r.mapKey,
            r.scopeKey,
            r.accountFingerprint,
            r.zone,
            r.logicalEntityKeyHash,
            r.serverRecordIdHash,
            r.generation,
            r.encryptedServerRecordId,
            r.etagHash,
            r.encryptedRawRecordRef,
            r.rawRecordGeneration,
            r.protectedReadbackLeaseReference,
            r.pendingUpdateOperationId,
            r.pendingUpdatePredecessorEtagHash,
            r.updatedAtMs,
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
            r.scopeKey,
            r.accountFingerprint,
            r.zone,
            r.serverRecordIdHash,
            r.etagHash,
            r.changeType,
            r.encryptedServerRecordId,
            r.protectedSystemFieldsRef,
            r.encryptedPayloadRef,
            r.payloadSha256,
            r.batchId,
            r.generation,
            r.fetchSequence,
            r.status,
            r.isTombstone,
            r.preflightCategory,
            r.failureCategory,
            r.preflightCode,
            r.retryCount,
            r.nextEligibleAtMs,
            r.serverModifiedAtMs,
            r.serverModifiedAtFormatVersion,
            r.createdAtMs,
            r.updatedAtMs,
            r.completedAtMs,
          ],
        )
        .toList(),
    'messages': store
        .box<Message>()
        .getAll()
        .map(
          (r) => [
            r.id,
            r.guid,
            r.text,
            r.chat.targetId,
            r.isFromMe,
            r.handleId,
            r.dateCreated?.millisecondsSinceEpoch,
            r.dateEdited?.millisecondsSinceEpoch,
            r.dateDeleted?.millisecondsSinceEpoch,
            r.dbAttributedBody,
            r.dbMessageSummaryInfo,
            r.ckRecordId,
            r.ckSyncState,
            r.sendingServiceId,
          ],
        )
        .toList(),
    'outbox': store.box<CloudOutboxOperationEntity>().count(),
    'replay': store.box<CloudSemanticReplayEntity>().count(),
  });

  Map<String, Object?> observe({int epoch = generation, String? physicalHash}) {
    final before = fingerprint();
    try {
      final result = observeCloudSyncRetainedMessageParent(
        store: store,
        scope: scope,
        generation: epoch,
        logicalParentHash: parentHash,
        canonicalParentGuid: parentGuid,
        locatedParentRecordHash: physicalHash,
      );
      expect(
        result.values.every((value) => value is int || value is bool),
        isTrue,
      );
      final encoded = jsonEncode(result);
      for (final secret in [
        parentGuid,
        parentGuid.toUpperCase(),
        parentHash,
        scope.accountFingerprint,
        _hash('R'),
        _hash('E'),
        _ref('W'),
        'private synthetic body',
        CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
          scope: scope,
          generation: generation,
          canonicalGuid: parentGuid,
        ),
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      return result;
    } finally {
      expect(fingerprint(), before);
    }
  }

  void expectNoOwnership(Map<String, Object?> result) {
    expect(result['parent_snapshot_count'], 0);
    expect(result['parent_snapshot_guid_matches'], isFalse);
    expect(result['parent_map_count'], 0);
    expect(result['parent_map_key_matches'], isFalse);
    expect(result.containsKey('parent_map_matches_latest'), isFalse);
  }

  test(
    'absent parent returns zero counts and no identifiers without writing',
    () {
      final result = observe();
      expect(result['parent_row_count'], 0);
      expect(result['parent_case_variant_count'], 0);
      expectNoOwnership(result);
      expect(result.containsKey('parent_mapped_inbox_present'), isFalse);
    },
  );

  test(
    'native physical locator finds retained evidence without inventing a map',
    () {
      seedInbox(sequence: 8, change: 'N', excluded: true);
      seedInbox(
        owner: scopeFor('B'),
        sequence: 99,
        change: 'Z',
        tombstone: true,
      );
      final result = observe(physicalHash: _hash('R'));
      expect(result['parent_row_count'], 0);
      expect(result['parent_snapshot_count'], 0);
      expect(result['parent_map_count'], 0);
      expect(result['parent_physical_lookup_used'], isTrue);
      expect(result['parent_physical_inbox_present'], isTrue);
      expect(result['parent_mapped_inbox_present'], isFalse);
      expect(result['parent_locator_matches_map'], isFalse);
      expect(result['parent_latest_excluded'], isTrue);
      expect(result['parent_latest_is_save'], isTrue);
      expect(result['parent_map_matches_latest'], isFalse);
    },
  );

  test(
    'unobserved physical locator is not remote absence or map ownership',
    () {
      seedMap();
      seedInbox();
      final result = observe(physicalHash: _hash('Q'));
      expect(result['parent_physical_lookup_used'], isTrue);
      expect(result['parent_physical_inbox_present'], isFalse);
      expect(result['parent_locator_matches_map'], isFalse);
      expect(result.containsKey('parent_map_matches_latest'), isFalse);
      expect(() => observe(physicalHash: 'raw-record'), throwsStateError);
    },
  );

  test(
    'exact current-scope proof correlates only the latest mapped inbox version',
    () {
      store.box<Message>().put(
        Message(
          guid: parentGuid,
          text: 'private synthetic body',
          dateCreated: DateTime.fromMillisecondsSinceEpoch(now),
          isFromMe: false,
        ),
      );
      seedSnapshot();
      seedMap();
      seedInbox(sequence: 8, change: 'N', excluded: true);
      // Insert older evidence last to prove sequence ordering, not row-id order.
      seedInbox(sequence: 2, change: 'C', etag: 'X', raw: 'Q');
      seedInbox(
        owner: scopeFor('B'),
        sequence: 99,
        change: 'Z',
        tombstone: true,
      );
      seedInbox(epoch: 2, sequence: 100, change: 'Y', tombstone: true);
      final result = observe();
      expect(result['parent_row_count'], 1);
      expect(result['parent_snapshot_count'], 1);
      expect(result['parent_snapshot_guid_matches'], isTrue);
      expect(result['parent_map_count'], 1);
      expect(result['parent_map_key_matches'], isTrue);
      expect(result['parent_mapped_inbox_present'], isTrue);
      expect(result['parent_latest_is_save'], isTrue);
      expect(result['parent_latest_tombstone'], isFalse);
      expect(
        result['parent_latest_status'],
        CloudInboxStatus.retainedUnprojected.index,
      );
      expect(result['parent_latest_excluded'], isTrue);
      expect(result['parent_map_matches_latest'], isTrue);
    },
  );

  test(
    'older and other-account maps or snapshots never establish this parent',
    () {
      seedSnapshot(epoch: 2);
      seedMap(epoch: 2);
      seedInbox(epoch: 2, excluded: true);
      seedSnapshot(owner: scopeFor('B'));
      seedMap(owner: scopeFor('B'));
      seedInbox(owner: scopeFor('B'), excluded: true);
      // A global local row is only a candidate without scoped current evidence.
      store.box<Message>().put(
        Message(guid: parentGuid, text: 'private synthetic body'),
      );
      final result = observe();
      expect(result['parent_row_count'], 1);
      expectNoOwnership(result);
    },
  );

  test(
    'latest tombstone or changed ETag or raw reference cannot match an older map',
    () {
      seedSnapshot();
      seedMap();
      seedInbox();
      expect(observe()['parent_map_matches_latest'], isTrue);
      final changed = seedInbox(sequence: 3, change: 'N', etag: 'X');
      expect(observe()['parent_map_matches_latest'], isFalse);
      changed
        ..etagHash = _hash('E')
        ..encryptedPayloadRef = _ref('Q');
      store.box<CloudInboxChangeEntity>().put(changed);
      expect(observe()['parent_map_matches_latest'], isFalse);
      changed
        ..changeType = CloudChangeType.delete.name
        ..isTombstone = true
        ..etagHash = null
        ..encryptedPayloadRef = null
        ..payloadSha256 = null;
      store.box<CloudInboxChangeEntity>().put(changed);
      final result = observe();
      expect(result['parent_latest_tombstone'], isTrue);
      expect(result['parent_latest_is_save'], isFalse);
      expect(result['parent_map_matches_latest'], isFalse);
    },
  );

  test(
    'stale checkpoint generation rejects even an otherwise exact stored chain',
    () {
      seedSnapshot();
      seedMap();
      seedInbox();
      final checkpoint = store.box<CloudSyncCheckpointEntity>().getAll().single;
      checkpoint.generation++;
      store.box<CloudSyncCheckpointEntity>().put(checkpoint);
      expect(
        () => observe(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'retained_parent_observation_checkpoint_changed',
          ),
        ),
      );
    },
  );

  test(
    'case-variant local Message is only a candidate and never ownership proof',
    () {
      final id = store.box<Message>().put(
        Message(
          guid: parentGuid.toUpperCase(),
          text: 'private synthetic body',
          isFromMe: false,
        ),
      );
      final result = observe();
      expect(result['parent_row_count'], 0);
      expect(result['parent_case_variant_count'], 1);
      expectNoOwnership(result);
      expect(store.box<Message>().get(id)!.guid, parentGuid.toUpperCase());
    },
  );
}
