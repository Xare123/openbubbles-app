import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_source_resolver.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  late Directory directory;
  late Store objectBox;
  late CloudAttachmentSourceResolver resolver;

  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'attachmentManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semanticV2,
  );
  const generation = 7;
  const canonicalGuid = 'attachment-guid';
  const logicalEntityKeyHash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const recordIdHash = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
  const etagHash = 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';
  const payloadSha256 =
      'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-attachment-source-',
    );
    objectBox = await openStore(directory: directory.path);
    resolver = CloudAttachmentSourceResolver(store: objectBox);
  });

  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('resolves one applied source through snapshot and replay evidence', () {
    _seedApplied(objectBox, scope, generation);

    final result = resolver.resolve(
      scope: scope,
      generation: generation,
      canonicalGuid: canonicalGuid,
    );

    expect(result.recordMap.mapKey, _recordMapKey(scope));
    expect(result.inboxChange.status, CloudInboxStatus.applied.index);
    expect(result.logicalEntityKeyHash, logicalEntityKeyHash);
    expect(
      result.expectedCanonicalGuidSha256,
      '6c3649d22f60dc030886b73028b97cc737a563388c2b0eb7b2c916d3ebb3235f',
    );
    expect(result.protectedSourceReference, testProtectedReference('A'));
    expect(result.recordIdHash, recordIdHash);
    expect(result.etagHash, etagHash);
    expect(result.payloadSha256, payloadSha256);
    expect(result.replayOutcome, 'applied');
  });

  test(
    'selects the current version when historical applied versions remain',
    () {
      _seedApplied(objectBox, scope, generation);
      _seedHistoricalAppliedVersion(objectBox, scope, generation);

      final result = resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      );

      expect(result.recordIdHash, recordIdHash);
      expect(result.etagHash, etagHash);
      expect(result.payloadSha256, payloadSha256);
      expect(result.protectedSourceReference, testProtectedReference('A'));
    },
  );

  test('rejects duplicate current inbox evidence', () {
    _seedApplied(objectBox, scope, generation);
    final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single;
    objectBox.box<CloudInboxChangeEntity>().put(
      _copyInbox(inbox, changeKey: '${inbox.changeKey}-duplicate'),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.ambiguousSource)),
    );
  });

  test('rejects duplicate current replay evidence', () {
    _seedApplied(objectBox, scope, generation);
    final replay = objectBox.box<CloudSemanticReplayEntity>().getAll().single;
    objectBox.box<CloudSemanticReplayEntity>().put(
      _copyReplay(replay, replayKey: '${replay.replayKey}-duplicate'),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.ambiguousSource)),
    );
  });

  test('does not mutate any ObjectBox evidence while resolving', () {
    _seedApplied(objectBox, scope, generation);
    final before = _evidence(objectBox);

    resolver.resolve(
      scope: scope,
      generation: generation,
      canonicalGuid: canonicalGuid,
    );

    expect(_evidence(objectBox), before);
  });

  test('rejects a missing canonical identity', () {
    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: 'missing-guid',
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.missingIdentity)),
    );
  });

  test('rejects duplicate canonical identity claims', () {
    _seedApplied(objectBox, scope, generation);
    final snapshot = objectBox
        .box<CloudSemanticSnapshotEntity>()
        .getAll()
        .single;
    objectBox.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        snapshotKey: '${snapshot.snapshotKey}-duplicate',
        scopeGenerationKey: snapshot.scopeGenerationKey,
        scopeKey: snapshot.scopeKey,
        accountFingerprint: snapshot.accountFingerprint,
        container: snapshot.container,
        database: snapshot.database,
        zone: snapshot.zone,
        streamKind: snapshot.streamKind,
        schemaVersion: snapshot.schemaVersion,
        generation: snapshot.generation,
        entityKind: snapshot.entityKind,
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuidHash: snapshot.canonicalGuidHash,
        canonicalGuidLookupHash: snapshot.canonicalGuidLookupHash,
        etagHash: snapshot.etagHash,
        updatedAtMs: snapshot.updatedAtMs,
      ),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.ambiguousIdentity)),
    );
  });

  test('rejects pending and quarantined inbox rows', () {
    for (final status in [
      CloudInboxStatus.pending,
      CloudInboxStatus.quarantined,
    ]) {
      _seedApplied(objectBox, scope, generation, status: status);
      expect(
        () => resolver.resolve(
          scope: scope,
          generation: generation,
          canonicalGuid: canonicalGuid,
        ),
        throwsA(
          _code(
            status == CloudInboxStatus.pending
                ? CloudAttachmentSourceResolutionCode.pendingSource
                : CloudAttachmentSourceResolutionCode.quarantinedSource,
          ),
        ),
      );
      objectBox.box<CloudSemanticSnapshotEntity>().removeAll();
      objectBox.box<CloudSemanticReplayEntity>().removeAll();
      objectBox.box<CloudRecordMapEntity>().removeAll();
      objectBox.box<CloudInboxChangeEntity>().removeAll();
    }
  });

  test('rejects a missing durable record map', () {
    _seedApplied(objectBox, scope, generation);
    objectBox.box<CloudRecordMapEntity>().removeAll();

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.missingSource)),
    );
  });

  test('rejects duplicate durable owners for one logical attachment', () {
    _seedApplied(objectBox, scope, generation);
    final map = objectBox.box<CloudRecordMapEntity>().getAll().single;
    objectBox.box<CloudRecordMapEntity>().put(
      CloudRecordMapEntity(
        mapKey: '${map.mapKey}-collision',
        scopeKey: map.scopeKey,
        accountFingerprint: map.accountFingerprint,
        zone: map.zone,
        logicalEntityKeyHash: map.logicalEntityKeyHash,
        serverRecordIdHash: map.serverRecordIdHash,
        generation: map.generation,
        encryptedServerRecordId: map.encryptedServerRecordId,
        etagHash: map.etagHash,
        encryptedRawRecordRef: map.encryptedRawRecordRef,
        updatedAtMs: map.updatedAtMs,
      ),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.ambiguousSource)),
    );
  });

  test('rejects a record map with a stale etag', () {
    _seedApplied(objectBox, scope, generation);
    _replaceRecordMap(
      objectBox,
      etagHash: 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.staleIdentity)),
    );
  });

  test('rejects a record map with the wrong protected source reference', () {
    _seedApplied(objectBox, scope, generation);
    _replaceRecordMap(
      objectBox,
      encryptedRawRecordRef: testProtectedReference('X'),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.invalidSource)),
    );
  });

  test('rejects a record map with the wrong protected server identity', () {
    _seedApplied(objectBox, scope, generation);
    _replaceRecordMap(
      objectBox,
      encryptedServerRecordId: testProtectedReference('Y'),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.invalidSource)),
    );
  });

  test('rejects a record map from the wrong scope', () {
    _seedApplied(objectBox, scope, generation);
    _replaceRecordMap(objectBox, accountFingerprint: testAccountFingerprintB);

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.wrongScope)),
    );
  });

  test('rejects a record map from the wrong generation', () {
    _seedApplied(objectBox, scope, generation);
    _replaceRecordMap(objectBox, generation: generation + 1);

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.wrongGeneration)),
    );
  });

  test('rejects stale snapshot when the applied source etag changed', () {
    _seedApplied(objectBox, scope, generation);
    final replay = objectBox.box<CloudSemanticReplayEntity>().getAll().single;
    objectBox.box<CloudSemanticReplayEntity>().put(
      CloudSemanticReplayEntity(
        id: replay.id,
        replayKey: replay.replayKey,
        scopeGenerationKey: replay.scopeGenerationKey,
        scopeKey: replay.scopeKey,
        accountFingerprint: replay.accountFingerprint,
        container: replay.container,
        database: replay.database,
        zone: replay.zone,
        streamKind: replay.streamKind,
        schemaVersion: replay.schemaVersion,
        generation: replay.generation,
        changeIdHash: replay.changeIdHash,
        serverRecordIdHash: replay.serverRecordIdHash,
        logicalEntityKeyHash: replay.logicalEntityKeyHash,
        payloadSha256: replay.payloadSha256,
        protectedPayloadReferenceHash: replay.protectedPayloadReferenceHash,
        inboxSequence: replay.inboxSequence,
        changeType: replay.changeType,
        terminalOutcome: replay.terminalOutcome,
        terminalSafeCode: replay.terminalSafeCode,
        updatedAtMs: replay.updatedAtMs,
      ),
    );
    final snapshot = objectBox
        .box<CloudSemanticSnapshotEntity>()
        .getAll()
        .single;
    objectBox.box<CloudSemanticSnapshotEntity>().put(
      CloudSemanticSnapshotEntity(
        id: snapshot.id,
        snapshotKey: snapshot.snapshotKey,
        scopeGenerationKey: snapshot.scopeGenerationKey,
        scopeKey: snapshot.scopeKey,
        accountFingerprint: snapshot.accountFingerprint,
        container: snapshot.container,
        database: snapshot.database,
        zone: snapshot.zone,
        streamKind: snapshot.streamKind,
        schemaVersion: snapshot.schemaVersion,
        generation: snapshot.generation,
        entityKind: snapshot.entityKind,
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuidHash: snapshot.canonicalGuidHash,
        canonicalGuidLookupHash: snapshot.canonicalGuidLookupHash,
        etagHash: 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
        updatedAtMs: snapshot.updatedAtMs,
      ),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.staleIdentity)),
    );
  });

  test('rejects wrong generation in the inbox evidence', () {
    _seedApplied(objectBox, scope, generation);
    final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single;
    objectBox.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        id: inbox.id,
        changeKey: inbox.changeKey,
        changeIdHash: inbox.changeIdHash,
        scopeKey: inbox.scopeKey,
        accountFingerprint: inbox.accountFingerprint,
        zone: inbox.zone,
        serverRecordIdHash: inbox.serverRecordIdHash,
        etagHash: inbox.etagHash,
        changeType: inbox.changeType,
        encryptedServerRecordId: inbox.encryptedServerRecordId,
        protectedSystemFieldsRef: inbox.protectedSystemFieldsRef,
        encryptedPayloadRef: inbox.encryptedPayloadRef,
        payloadSha256: inbox.payloadSha256,
        batchId: inbox.batchId,
        generation: generation + 1,
        fetchSequence: inbox.fetchSequence,
        status: inbox.status,
        isTombstone: inbox.isTombstone,
        completedAtMs: inbox.completedAtMs,
        createdAtMs: inbox.createdAtMs,
        updatedAtMs: inbox.updatedAtMs,
      ),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.wrongGeneration)),
    );
  });

  test('rejects wrong scope in the inbox evidence', () {
    _seedApplied(objectBox, scope, generation);
    final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single;
    final otherScope = CloudSyncScope(
      accountFingerprint: testAccountFingerprintB,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      persistenceLane: scope.persistenceLane,
    );
    objectBox.box<CloudInboxChangeEntity>().put(
      CloudInboxChangeEntity(
        id: inbox.id,
        changeKey: inbox.changeKey,
        changeIdHash: inbox.changeIdHash,
        scopeKey: 'scope2:${_digest(otherScope.storageKey)}',
        accountFingerprint: otherScope.accountFingerprint,
        zone: inbox.zone,
        serverRecordIdHash: inbox.serverRecordIdHash,
        etagHash: inbox.etagHash,
        changeType: inbox.changeType,
        encryptedServerRecordId: inbox.encryptedServerRecordId,
        protectedSystemFieldsRef: inbox.protectedSystemFieldsRef,
        encryptedPayloadRef: inbox.encryptedPayloadRef,
        payloadSha256: inbox.payloadSha256,
        batchId: inbox.batchId,
        generation: inbox.generation,
        fetchSequence: inbox.fetchSequence,
        status: inbox.status,
        isTombstone: inbox.isTombstone,
        completedAtMs: inbox.completedAtMs,
        createdAtMs: inbox.createdAtMs,
        updatedAtMs: inbox.updatedAtMs,
      ),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.wrongScope)),
    );
  });

  test('rejects an inbox row with a stale current eTag', () {
    _seedApplied(objectBox, scope, generation);
    final inbox = objectBox.box<CloudInboxChangeEntity>().getAll().single;
    objectBox.box<CloudInboxChangeEntity>().put(
      _copyInbox(
        inbox,
        etagHash: 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
      ),
    );

    expect(
      () => resolver.resolve(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      ),
      throwsA(_code(CloudAttachmentSourceResolutionCode.staleIdentity)),
    );
  });
}

Matcher _code(CloudAttachmentSourceResolutionCode code) =>
    isA<CloudAttachmentSourceResolutionFailure>().having(
      (failure) => failure.code,
      'code',
      code,
    );

void _seedApplied(
  Store objectBox,
  CloudSyncScope scope,
  int generation, {
  CloudInboxStatus status = CloudInboxStatus.applied,
}) {
  const canonicalGuid = 'attachment-guid';
  const logicalEntityKeyHash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const changeIdHash = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
  const recordIdHash = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
  const etagHash = 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';
  const payloadSha256 =
      'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
  final nowMs = DateTime.utc(2026, 8, 30).millisecondsSinceEpoch;
  final scopeKey = 'scope2:${_digest(scope.storageKey)}';
  final scopeGenerationKey =
      'semantic-generation4:${_digest('$scopeKey\u001f$generation')}';
  final protectedReference = testProtectedReference('A');
  final changeKey =
      'change:${_digest('${scope.storageKey}\u001fchange\u001f$changeIdHash')}';
  final replayChangeIdHash = _digest(changeIdHash);
  final replayKey = 'semantic-replay4:$scopeGenerationKey:$replayChangeIdHash';
  final recordMapKey = _recordMapKey(scope);

  objectBox.box<CloudSemanticSnapshotEntity>().put(
    CloudSemanticSnapshotEntity(
      snapshotKey:
          'semantic-snapshot4:$scopeGenerationKey:attachment:$logicalEntityKeyHash',
      scopeGenerationKey: scopeGenerationKey,
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      entityKind: CloudEntityKind.attachment.name,
      logicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: logicalEntityKeyHash,
        canonicalGuid: canonicalGuid,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: generation,
            canonicalGuid: canonicalGuid,
          ),
      etagHash: etagHash,
      updatedAtMs: nowMs,
    ),
  );
  objectBox.box<CloudSemanticReplayEntity>().put(
    CloudSemanticReplayEntity(
      replayKey: replayKey,
      scopeGenerationKey: scopeGenerationKey,
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      changeIdHash: replayChangeIdHash,
      serverRecordIdHash: recordIdHash,
      logicalEntityKeyHash: logicalEntityKeyHash,
      payloadSha256: payloadSha256,
      protectedPayloadReferenceHash: _digest(
        'semantic-payload-reference\u001f$protectedReference',
      ),
      inboxSequence: 1,
      changeType: CloudChangeType.save.name,
      terminalOutcome: 'applied',
      updatedAtMs: nowMs,
    ),
  );
  objectBox.box<CloudRecordMapEntity>().put(
    CloudRecordMapEntity(
      mapKey: recordMapKey,
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      logicalEntityKeyHash: logicalEntityKeyHash,
      serverRecordIdHash: recordIdHash,
      generation: generation,
      encryptedServerRecordId: testProtectedReference('S'),
      etagHash: etagHash,
      encryptedRawRecordRef: protectedReference,
      updatedAtMs: nowMs,
    ),
  );
  objectBox.box<CloudInboxChangeEntity>().put(
    CloudInboxChangeEntity(
      changeKey: changeKey,
      changeIdHash: changeIdHash,
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      serverRecordIdHash: recordIdHash,
      etagHash: etagHash,
      changeType: CloudChangeType.save.name,
      encryptedServerRecordId: testProtectedReference('S'),
      protectedSystemFieldsRef: testProtectedReference('W'),
      encryptedPayloadRef: protectedReference,
      payloadSha256: payloadSha256,
      batchId: 'batch-1',
      generation: generation,
      fetchSequence: 1,
      status: status.index,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      completedAtMs: status == CloudInboxStatus.applied ? nowMs : 0,
    ),
  );
}

void _seedHistoricalAppliedVersion(
  Store objectBox,
  CloudSyncScope scope,
  int generation,
) {
  const logicalEntityKeyHash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  final changeIdHash = List.filled(43, 'E').join();
  final recordIdHash = List.filled(43, 'F').join();
  final etagHash = List.filled(43, 'G').join();
  final payloadSha256 = List.filled(64, 'h').join();
  final protectedReference = testProtectedReference('B');
  final nowMs = DateTime.utc(2026, 8, 29).millisecondsSinceEpoch;
  final scopeKey = 'scope2:${_digest(scope.storageKey)}';
  final scopeGenerationKey =
      'semantic-generation4:${_digest('$scopeKey\u001f$generation')}';
  final changeKey =
      'change:${_digest('${scope.storageKey}\u001fchange\u001f$changeIdHash')}';
  final replayChangeIdHash = _digest(changeIdHash);
  final replayKey = 'semantic-replay4:$scopeGenerationKey:$replayChangeIdHash';

  objectBox.box<CloudSemanticReplayEntity>().put(
    CloudSemanticReplayEntity(
      replayKey: replayKey,
      scopeGenerationKey: scopeGenerationKey,
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      changeIdHash: replayChangeIdHash,
      serverRecordIdHash: recordIdHash,
      logicalEntityKeyHash: logicalEntityKeyHash,
      payloadSha256: payloadSha256,
      protectedPayloadReferenceHash: _digest(
        'semantic-payload-reference\u001f$protectedReference',
      ),
      inboxSequence: 2,
      changeType: CloudChangeType.save.name,
      terminalOutcome: 'applied',
      updatedAtMs: nowMs,
    ),
  );
  objectBox.box<CloudInboxChangeEntity>().put(
    CloudInboxChangeEntity(
      changeKey: changeKey,
      changeIdHash: changeIdHash,
      scopeKey: scopeKey,
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      serverRecordIdHash: recordIdHash,
      etagHash: etagHash,
      changeType: CloudChangeType.save.name,
      encryptedServerRecordId: testProtectedReference('T'),
      protectedSystemFieldsRef: testProtectedReference('V'),
      encryptedPayloadRef: protectedReference,
      payloadSha256: payloadSha256,
      batchId: 'batch-historical',
      generation: generation,
      fetchSequence: 2,
      status: CloudInboxStatus.applied.index,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      completedAtMs: nowMs,
    ),
  );
}

CloudSemanticReplayEntity _copyReplay(
  CloudSemanticReplayEntity replay, {
  required String replayKey,
}) => CloudSemanticReplayEntity(
  replayKey: replayKey,
  scopeGenerationKey: replay.scopeGenerationKey,
  scopeKey: replay.scopeKey,
  accountFingerprint: replay.accountFingerprint,
  container: replay.container,
  database: replay.database,
  zone: replay.zone,
  streamKind: replay.streamKind,
  schemaVersion: replay.schemaVersion,
  generation: replay.generation,
  changeIdHash: replay.changeIdHash,
  serverRecordIdHash: replay.serverRecordIdHash,
  logicalEntityKeyHash: replay.logicalEntityKeyHash,
  payloadSha256: replay.payloadSha256,
  protectedPayloadReferenceHash: replay.protectedPayloadReferenceHash,
  inboxSequence: replay.inboxSequence,
  changeType: replay.changeType,
  terminalOutcome: replay.terminalOutcome,
  terminalSafeCode: replay.terminalSafeCode,
  updatedAtMs: replay.updatedAtMs,
);

CloudInboxChangeEntity _copyInbox(
  CloudInboxChangeEntity inbox, {
  String? changeKey,
  String? etagHash,
}) => CloudInboxChangeEntity(
  id: changeKey == null ? inbox.id : 0,
  changeKey: changeKey ?? inbox.changeKey,
  changeIdHash: inbox.changeIdHash,
  scopeKey: inbox.scopeKey,
  accountFingerprint: inbox.accountFingerprint,
  zone: inbox.zone,
  serverRecordIdHash: inbox.serverRecordIdHash,
  etagHash: etagHash ?? inbox.etagHash,
  changeType: inbox.changeType,
  encryptedServerRecordId: inbox.encryptedServerRecordId,
  protectedSystemFieldsRef: inbox.protectedSystemFieldsRef,
  encryptedPayloadRef: inbox.encryptedPayloadRef,
  payloadSha256: inbox.payloadSha256,
  batchId: inbox.batchId,
  generation: inbox.generation,
  fetchSequence: inbox.fetchSequence,
  status: inbox.status,
  isTombstone: inbox.isTombstone,
  preflightCategory: inbox.preflightCategory,
  failureCategory: inbox.failureCategory,
  preflightCode: inbox.preflightCode,
  retryCount: inbox.retryCount,
  nextEligibleAtMs: inbox.nextEligibleAtMs,
  serverModifiedAtMs: inbox.serverModifiedAtMs,
  createdAtMs: inbox.createdAtMs,
  updatedAtMs: inbox.updatedAtMs,
  completedAtMs: inbox.completedAtMs,
);

Map<String, Object?> _evidence(Store objectBox) => {
  'snapshot': objectBox
      .box<CloudSemanticSnapshotEntity>()
      .getAll()
      .map(
        (e) => [
          e.id,
          e.snapshotKey,
          e.scopeGenerationKey,
          e.scopeKey,
          e.accountFingerprint,
          e.container,
          e.database,
          e.zone,
          e.streamKind,
          e.schemaVersion,
          e.generation,
          e.entityKind,
          e.logicalEntityKeyHash,
          e.canonicalGuidHash,
          e.canonicalGuidLookupHash,
          e.parentLogicalKeyHash,
          e.immutableContentDigest,
          e.createdAtMs,
          e.readAtMs,
          e.deliveredAtMs,
          e.editPartsJson,
          e.retractedAtMs,
          e.groupVersion,
          e.groupMetadataDigest,
          e.etagHash,
          e.updatedAtMs,
        ],
      )
      .toList(),
  'replay': objectBox
      .box<CloudSemanticReplayEntity>()
      .getAll()
      .map(
        (e) => [
          e.id,
          e.replayKey,
          e.scopeGenerationKey,
          e.scopeKey,
          e.accountFingerprint,
          e.container,
          e.database,
          e.zone,
          e.streamKind,
          e.schemaVersion,
          e.generation,
          e.changeIdHash,
          e.serverRecordIdHash,
          e.logicalEntityKeyHash,
          e.payloadSha256,
          e.protectedPayloadReferenceHash,
          e.inboxSequence,
          e.changeType,
          e.terminalOutcome,
          e.terminalSafeCode,
          e.updatedAtMs,
        ],
      )
      .toList(),
  'recordMap': objectBox
      .box<CloudRecordMapEntity>()
      .getAll()
      .map(
        (e) => [
          e.id,
          e.mapKey,
          e.scopeKey,
          e.accountFingerprint,
          e.zone,
          e.logicalEntityKeyHash,
          e.serverRecordIdHash,
          e.generation,
          e.encryptedServerRecordId,
          e.etagHash,
          e.encryptedRawRecordRef,
          e.updatedAtMs,
        ],
      )
      .toList(),
  'inbox': objectBox
      .box<CloudInboxChangeEntity>()
      .getAll()
      .map(
        (e) => [
          e.id,
          e.changeKey,
          e.changeIdHash,
          e.scopeKey,
          e.accountFingerprint,
          e.zone,
          e.serverRecordIdHash,
          e.etagHash,
          e.changeType,
          e.encryptedServerRecordId,
          e.protectedSystemFieldsRef,
          e.encryptedPayloadRef,
          e.payloadSha256,
          e.batchId,
          e.generation,
          e.fetchSequence,
          e.status,
          e.isTombstone,
          e.preflightCategory,
          e.failureCategory,
          e.preflightCode,
          e.retryCount,
          e.nextEligibleAtMs,
          e.serverModifiedAtMs,
          e.createdAtMs,
          e.updatedAtMs,
          e.completedAtMs,
        ],
      )
      .toList(),
};

void _replaceRecordMap(
  Store objectBox, {
  String? scopeKey,
  String? accountFingerprint,
  String? zone,
  int? generation,
  String? etagHash,
  String? encryptedServerRecordId,
  String? encryptedRawRecordRef,
}) {
  final box = objectBox.box<CloudRecordMapEntity>();
  final map = box.getAll().single;
  box.put(
    CloudRecordMapEntity(
      id: map.id,
      mapKey: map.mapKey,
      scopeKey: scopeKey ?? map.scopeKey,
      accountFingerprint: accountFingerprint ?? map.accountFingerprint,
      zone: zone ?? map.zone,
      logicalEntityKeyHash: map.logicalEntityKeyHash,
      serverRecordIdHash: map.serverRecordIdHash,
      generation: generation ?? map.generation,
      encryptedServerRecordId:
          encryptedServerRecordId ?? map.encryptedServerRecordId,
      etagHash: etagHash ?? map.etagHash,
      encryptedRawRecordRef: encryptedRawRecordRef ?? map.encryptedRawRecordRef,
      updatedAtMs: map.updatedAtMs,
    ),
  );
}

String _recordMapKey(CloudSyncScope scope) =>
    'record-map:${_digest('${scope.storageKey}\u001frecord-map\u001fAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')}';

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
