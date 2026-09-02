import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_models.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';

/// Failure reasons returned by [CloudAttachmentSourceResolver].
///
/// These are deliberately content-free. They can be surfaced in diagnostics
/// without exposing a record identifier, source body, or protected reference.
enum CloudAttachmentSourceResolutionCode {
  invalidRequest,
  missingIdentity,
  ambiguousIdentity,
  staleIdentity,
  missingSource,
  ambiguousSource,
  pendingSource,
  quarantinedSource,
  wrongScope,
  wrongGeneration,
  invalidSource,
}

/// Content-free location of a source-resolution failure.
///
/// This narrows diagnostics without exposing a record identifier, attachment
/// name, path, payload, account, or protected reference.
enum CloudAttachmentSourceResolutionStage { recordMap, inbox, replay }

final class CloudAttachmentSourceResolutionFailure implements Exception {
  const CloudAttachmentSourceResolutionFailure(this.code, {this.stage});

  final CloudAttachmentSourceResolutionCode code;
  final CloudAttachmentSourceResolutionStage? stage;

  @override
  String toString() => 'CloudAttachmentSourceResolutionFailure(${code.name})';
}

/// The minimum authenticated evidence needed by the native attachment reader.
///
/// The raw CloudKit record identifier is intentionally not returned. Native
/// Rust reopens the protected source reference and verifies it against these
/// hashes before using the closed, download-only MMCS path.
final class CloudAttachmentSource {
  const CloudAttachmentSource({
    required this.recordMap,
    required this.inboxChange,
    required this.logicalEntityKeyHash,
    required this.expectedCanonicalGuidSha256,
    required this.protectedSourceReference,
    required this.recordIdHash,
    required this.etagHash,
    required this.payloadSha256,
    required this.replayOutcome,
  });

  final CloudRecordMapEntity recordMap;
  final CloudInboxChangeEntity inboxChange;
  final String logicalEntityKeyHash;
  final String expectedCanonicalGuidSha256;
  final String protectedSourceReference;
  final String recordIdHash;
  final String etagHash;
  final String payloadSha256;
  final String replayOutcome;
}

/// Read-only resolver for one already-applied CloudKit V2 attachment source.
///
/// The lookup is bounded and runs in an ObjectBox read transaction. It never
/// puts, removes, updates, or otherwise mutates an entity. A result is
/// accepted only when all of the following immutable links agree:
///
///   canonical GUID -> current attachment snapshot -> current durable record
///   map -> current applied inbox row -> its one semantic replay
///
/// The replay is deliberately resolved last. Historical replays can remain
/// applied after a record is updated and must not make the current version
/// ambiguous.
///
/// The replay row is the normalized association between a semantic identity
/// and its inbox change. It is required because inbox rows intentionally keep
/// only the protected CloudKit evidence and do not duplicate logical keys.
final class CloudAttachmentSourceResolver {
  CloudAttachmentSourceResolver({required Store store})
    : _store = store,
      _snapshots = store.box<CloudSemanticSnapshotEntity>(),
      _replay = store.box<CloudSemanticReplayEntity>(),
      _recordMaps = store.box<CloudRecordMapEntity>(),
      _inbox = store.box<CloudInboxChangeEntity>();

  static const int _maximumGeneration = 1 << 31;
  static const int _maximumRecordMapCandidates = 3;
  static const int _maximumInboxCandidates = 3;
  static const int _maximumReplayCandidates = 2;

  static final RegExp _externalDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _contentDigest = RegExp(
    r'^(?:[A-Za-z0-9_-]{43}|[0-9a-f]{64})$',
  );
  static final RegExp _protectedReference = RegExp(
    r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
  );

  final Store _store;
  final Box<CloudSemanticSnapshotEntity> _snapshots;
  final Box<CloudSemanticReplayEntity> _replay;
  final Box<CloudRecordMapEntity> _recordMaps;
  final Box<CloudInboxChangeEntity> _inbox;

  /// Resolves exactly one source for [canonicalGuid] in [scope]/[generation].
  ///
  /// A source is usable only for the attachment Manatee zone. The method
  /// returns a defensive value object, but retains the complete inbox entity
  /// so the next native boundary can pass the exact immutable evidence onward.
  CloudAttachmentSource resolve({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) {
    if (generation <= 0 || generation > _maximumGeneration) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.invalidRequest,
      );
    }
    if (scope.persistenceLane != CloudSyncPersistenceLane.semanticV2 ||
        scope.zone != 'attachmentManateeZone') {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.invalidRequest,
      );
    }

    final lookupHash = _canonicalLookupHash(
      scope: scope,
      generation: generation,
      canonicalGuid: canonicalGuid,
    );
    final scopeKey = _scopeKey(scope);
    final scopeGenerationKey = _scopeGenerationKey(scope, generation);

    return _store.runInTransaction(TxMode.read, () {
      final snapshots = _findSnapshots(
        scopeGenerationKey: scopeGenerationKey,
        lookupHash: lookupHash,
      );
      if (snapshots.isEmpty) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.missingIdentity,
        );
      }
      if (snapshots.length > 1) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.ambiguousIdentity,
        );
      }

      final snapshot = snapshots.single;
      final logicalEntityKeyHash = _validateSnapshot(
        snapshot,
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
        scopeKey: scopeKey,
        scopeGenerationKey: scopeGenerationKey,
        lookupHash: lookupHash,
      );

      final recordMapKey = _recordMapKey(scope, logicalEntityKeyHash);
      final recordMaps = _findCurrentRecordMaps(
        mapKey: recordMapKey,
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        generation: generation,
        logicalEntityKeyHash: logicalEntityKeyHash,
        etagHash: snapshot.etagHash!,
      );
      if (recordMaps.isEmpty) {
        final staleMaps = _findRecordMapsForValidation(recordMapKey);
        if (staleMaps.length == 1) {
          _validateRecordMap(
            staleMaps.single,
            scope: scope,
            generation: generation,
            scopeKey: scopeKey,
            logicalEntityKeyHash: logicalEntityKeyHash,
            expectedMapKey: recordMapKey,
            expectedEtagHash: snapshot.etagHash!,
          );
        }
        if (staleMaps.length > 1) {
          throw const CloudAttachmentSourceResolutionFailure(
            CloudAttachmentSourceResolutionCode.ambiguousSource,
          );
        }
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.missingSource,
          stage: CloudAttachmentSourceResolutionStage.recordMap,
        );
      }
      if (recordMaps.length > 1) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.ambiguousSource,
        );
      }

      final recordMap = recordMaps.single;
      _validateRecordMap(
        recordMap,
        scope: scope,
        generation: generation,
        scopeKey: scopeKey,
        logicalEntityKeyHash: logicalEntityKeyHash,
        expectedMapKey: recordMapKey,
        expectedEtagHash: snapshot.etagHash!,
      );

      final currentOwners = _findRecordMapOwners(
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        logicalEntityKeyHash: logicalEntityKeyHash,
        generation: generation,
        etagHash: snapshot.etagHash!,
      );
      if (currentOwners.length != 1 ||
          currentOwners.single.id != recordMap.id ||
          currentOwners.single.mapKey != recordMapKey) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.ambiguousSource,
        );
      }

      final inboxCandidates = _findCurrentInboxCandidates(
        scopeKey: scopeKey,
        accountFingerprint: scope.accountFingerprint,
        zone: scope.zone,
        generation: generation,
        serverRecordIdHash: recordMap.serverRecordIdHash,
        etagHash: snapshot.etagHash!,
      );
      if (inboxCandidates.isEmpty) {
        final staleInbox = _findInboxCandidatesForValidation(
          serverRecordIdHash: recordMap.serverRecordIdHash,
        );
        if (staleInbox.length == 1) {
          _validateInboxWithoutReplay(
            staleInbox.single,
            scope: scope,
            generation: generation,
            scopeKey: scopeKey,
            expectedEtagHash: snapshot.etagHash,
          );
        }
        if (staleInbox.length > 1) {
          throw const CloudAttachmentSourceResolutionFailure(
            CloudAttachmentSourceResolutionCode.ambiguousSource,
          );
        }
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.missingSource,
          stage: CloudAttachmentSourceResolutionStage.inbox,
        );
      }
      if (inboxCandidates.length > 1) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.ambiguousSource,
        );
      }

      final inbox = inboxCandidates.single;
      final replayChangeIdHash = _replayChangeIdHash(inbox.changeIdHash);
      final replayCandidates = _findCurrentReplayCandidates(
        scopeGenerationKey: scopeGenerationKey,
        replayChangeIdHash: replayChangeIdHash,
      );
      if (replayCandidates.isEmpty) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.missingSource,
          stage: CloudAttachmentSourceResolutionStage.replay,
        );
      }
      if (replayCandidates.length > 1) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.ambiguousSource,
        );
      }
      final replay = replayCandidates.single;
      if (!_isAppliedReplay(
        replay,
        scope: scope,
        generation: generation,
        scopeKey: scopeKey,
        scopeGenerationKey: scopeGenerationKey,
        expectedChangeIdHash: replayChangeIdHash,
        logicalEntityKeyHash: logicalEntityKeyHash,
        expectedRecordIdHash: recordMap.serverRecordIdHash,
        expectedInboxSequence: inbox.fetchSequence,
        expectedPayloadSha256: inbox.payloadSha256,
        expectedProtectedPayloadReferenceHash: inbox.encryptedPayloadRef == null
            ? null
            : _protectedPayloadReferenceHash(inbox.encryptedPayloadRef!),
      )) {
        throw const CloudAttachmentSourceResolutionFailure(
          CloudAttachmentSourceResolutionCode.invalidSource,
        );
      }
      _validateInbox(
        inbox,
        recordMap: recordMap,
        replay: replay,
        scope: scope,
        generation: generation,
        scopeKey: scopeKey,
        expectedEtagHash: snapshot.etagHash,
      );

      return CloudAttachmentSource(
        recordMap: recordMap,
        inboxChange: inbox,
        logicalEntityKeyHash: logicalEntityKeyHash,
        expectedCanonicalGuidSha256: _destinationCanonicalGuidSha256(
          canonicalGuid,
        ),
        protectedSourceReference: inbox.encryptedPayloadRef!,
        recordIdHash: inbox.serverRecordIdHash,
        etagHash: inbox.etagHash!,
        payloadSha256: inbox.payloadSha256!,
        replayOutcome: replay.terminalOutcome,
      );
    });
  }

  List<CloudSemanticSnapshotEntity> _findSnapshots({
    required String scopeGenerationKey,
    required String lookupHash,
  }) {
    final query =
        _snapshots
            .query(
              CloudSemanticSnapshotEntity_.scopeGenerationKey
                  .equals(scopeGenerationKey)
                  .and(
                    CloudSemanticSnapshotEntity_.canonicalGuidLookupHash.equals(
                      lookupHash,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudRecordMapEntity> _findCurrentRecordMaps({
    required String mapKey,
    required String scopeKey,
    required String accountFingerprint,
    required String zone,
    required int generation,
    required String logicalEntityKeyHash,
    required String etagHash,
  }) {
    final query =
        _recordMaps
            .query(
              CloudRecordMapEntity_.mapKey
                  .equals(mapKey)
                  .and(CloudRecordMapEntity_.scopeKey.equals(scopeKey))
                  .and(
                    CloudRecordMapEntity_.accountFingerprint.equals(
                      accountFingerprint,
                    ),
                  )
                  .and(CloudRecordMapEntity_.zone.equals(zone))
                  .and(CloudRecordMapEntity_.generation.equals(generation))
                  .and(
                    CloudRecordMapEntity_.logicalEntityKeyHash.equals(
                      logicalEntityKeyHash,
                    ),
                  )
                  .and(CloudRecordMapEntity_.etagHash.equals(etagHash)),
            )
            .build()
          ..limit = 2;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudRecordMapEntity> _findRecordMapsForValidation(String mapKey) {
    final query =
        _recordMaps.query(CloudRecordMapEntity_.mapKey.equals(mapKey)).build()
          ..limit = 2;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudSemanticReplayEntity> _findCurrentReplayCandidates({
    required String scopeGenerationKey,
    required String replayChangeIdHash,
  }) {
    final query =
        _replay
            .query(
              CloudSemanticReplayEntity_.scopeGenerationKey
                  .equals(scopeGenerationKey)
                  .and(
                    CloudSemanticReplayEntity_.changeIdHash.equals(
                      replayChangeIdHash,
                    ),
                  ),
            )
            .build()
          ..limit = _maximumReplayCandidates;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudInboxChangeEntity> _findCurrentInboxCandidates({
    required String scopeKey,
    required String accountFingerprint,
    required String zone,
    required int generation,
    required String serverRecordIdHash,
    required String etagHash,
  }) {
    final query =
        _inbox
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(scopeKey)
                  .and(
                    CloudInboxChangeEntity_.accountFingerprint.equals(
                      accountFingerprint,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.zone.equals(zone))
                  .and(CloudInboxChangeEntity_.generation.equals(generation))
                  .and(
                    CloudInboxChangeEntity_.serverRecordIdHash.equals(
                      serverRecordIdHash,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.etagHash.equals(etagHash)),
            )
            .build()
          ..limit = _maximumInboxCandidates;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudInboxChangeEntity> _findInboxCandidatesForValidation({
    required String serverRecordIdHash,
  }) {
    final query =
        _inbox
            .query(
              CloudInboxChangeEntity_.serverRecordIdHash.equals(
                serverRecordIdHash,
              ),
            )
            .build()
          ..limit = _maximumInboxCandidates;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  List<CloudRecordMapEntity> _findRecordMapOwners({
    required String scopeKey,
    required String accountFingerprint,
    required String zone,
    required String logicalEntityKeyHash,
    required int generation,
    required String etagHash,
  }) {
    final query =
        _recordMaps
            .query(
              CloudRecordMapEntity_.scopeKey
                  .equals(scopeKey)
                  .and(
                    CloudRecordMapEntity_.logicalEntityKeyHash.equals(
                      logicalEntityKeyHash,
                    ),
                  )
                  .and(
                    CloudRecordMapEntity_.accountFingerprint.equals(
                      accountFingerprint,
                    ),
                  )
                  .and(CloudRecordMapEntity_.zone.equals(zone))
                  .and(CloudRecordMapEntity_.generation.equals(generation))
                  .and(CloudRecordMapEntity_.etagHash.equals(etagHash)),
            )
            .build()
          ..limit = _maximumRecordMapCandidates;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  String _validateSnapshot(
    CloudSemanticSnapshotEntity snapshot, {
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
    required String scopeKey,
    required String scopeGenerationKey,
    required String lookupHash,
  }) {
    final logicalEntityKeyHash = snapshot.logicalEntityKeyHash;
    final expectedSnapshotKey =
        'semantic-snapshot4:$scopeGenerationKey:attachment:$logicalEntityKeyHash';
    final expectedCanonicalGuidHash =
        CloudCanonicalIdentityDigest.forCanonicalGuid(
          scope: scope,
          generation: generation,
          kind: CloudEntityKind.attachment,
          logicalEntityKeyHash: logicalEntityKeyHash,
          canonicalGuid: canonicalGuid,
        );
    if (snapshot.snapshotKey != expectedSnapshotKey ||
        snapshot.scopeGenerationKey != scopeGenerationKey ||
        snapshot.scopeKey != scopeKey ||
        snapshot.accountFingerprint != scope.accountFingerprint ||
        snapshot.container != scope.container ||
        snapshot.database != scope.database ||
        snapshot.zone != scope.zone ||
        snapshot.streamKind != scope.streamKind.name ||
        snapshot.schemaVersion != scope.schemaVersion ||
        snapshot.generation != generation ||
        snapshot.entityKind != CloudEntityKind.attachment.name ||
        !_externalDigest.hasMatch(logicalEntityKeyHash) ||
        snapshot.canonicalGuidLookupHash != lookupHash ||
        snapshot.canonicalGuidHash == null ||
        !_isLowerHexDigest(snapshot.canonicalGuidHash!) ||
        snapshot.canonicalGuidHash != expectedCanonicalGuidHash ||
        snapshot.etagHash == null ||
        !_contentDigest.hasMatch(snapshot.etagHash!)) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.invalidSource,
      );
    }
    return logicalEntityKeyHash;
  }

  bool _isAppliedReplay(
    CloudSemanticReplayEntity replay, {
    required CloudSyncScope scope,
    required int generation,
    required String scopeKey,
    required String scopeGenerationKey,
    required String expectedChangeIdHash,
    required String logicalEntityKeyHash,
    required String expectedRecordIdHash,
    required int expectedInboxSequence,
    required String? expectedPayloadSha256,
    required String? expectedProtectedPayloadReferenceHash,
  }) {
    final expectedReplayKey =
        'semantic-replay4:$scopeGenerationKey:$expectedChangeIdHash';
    final outcomeIsApplied =
        replay.terminalOutcome == 'applied' ||
        replay.terminalOutcome == 'appliedWithConflict';
    final conflictCodeValid = replay.terminalOutcome == 'applied'
        ? replay.terminalSafeCode == null
        : _safeCode(replay.terminalSafeCode);
    return replay.replayKey == expectedReplayKey &&
        replay.scopeGenerationKey == scopeGenerationKey &&
        replay.scopeKey == scopeKey &&
        replay.accountFingerprint == scope.accountFingerprint &&
        replay.container == scope.container &&
        replay.database == scope.database &&
        replay.zone == scope.zone &&
        replay.streamKind == scope.streamKind.name &&
        replay.schemaVersion == scope.schemaVersion &&
        replay.generation == generation &&
        replay.changeIdHash == expectedChangeIdHash &&
        replay.logicalEntityKeyHash == logicalEntityKeyHash &&
        replay.changeType == CloudChangeType.save.name &&
        outcomeIsApplied &&
        conflictCodeValid &&
        replay.serverRecordIdHash == expectedRecordIdHash &&
        _externalDigest.hasMatch(replay.serverRecordIdHash) &&
        _isLowerHexDigest(replay.changeIdHash) &&
        replay.inboxSequence == expectedInboxSequence &&
        replay.inboxSequence > 0 &&
        replay.payloadSha256 != null &&
        replay.payloadSha256 == expectedPayloadSha256 &&
        _contentDigest.hasMatch(replay.payloadSha256!) &&
        replay.protectedPayloadReferenceHash != null &&
        replay.protectedPayloadReferenceHash ==
            expectedProtectedPayloadReferenceHash &&
        _isLowerHexDigest(replay.protectedPayloadReferenceHash!) &&
        expectedPayloadSha256 != null &&
        expectedProtectedPayloadReferenceHash != null;
  }

  void _validateRecordMap(
    CloudRecordMapEntity recordMap, {
    required CloudSyncScope scope,
    required int generation,
    required String scopeKey,
    required String logicalEntityKeyHash,
    required String expectedMapKey,
    required String expectedEtagHash,
  }) {
    if (recordMap.scopeKey != scopeKey ||
        recordMap.accountFingerprint != scope.accountFingerprint ||
        recordMap.zone != scope.zone) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.wrongScope,
      );
    }
    if (recordMap.generation != generation) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.wrongGeneration,
      );
    }
    if (!_externalDigest.hasMatch(recordMap.logicalEntityKeyHash) ||
        !_externalDigest.hasMatch(recordMap.serverRecordIdHash) ||
        recordMap.etagHash == null ||
        !_externalDigest.hasMatch(recordMap.etagHash!) ||
        !_protectedReference.hasMatch(recordMap.encryptedServerRecordId) ||
        recordMap.encryptedRawRecordRef == null ||
        !_protectedReference.hasMatch(recordMap.encryptedRawRecordRef!)) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.invalidSource,
      );
    }
    if (recordMap.mapKey != expectedMapKey ||
        recordMap.logicalEntityKeyHash != logicalEntityKeyHash ||
        recordMap.etagHash != expectedEtagHash) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.staleIdentity,
      );
    }
  }

  void _validateInboxWithoutReplay(
    CloudInboxChangeEntity inbox, {
    required CloudSyncScope scope,
    required int generation,
    required String scopeKey,
    required String? expectedEtagHash,
  }) {
    if (inbox.scopeKey != scopeKey ||
        inbox.accountFingerprint != scope.accountFingerprint ||
        inbox.zone != scope.zone) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.wrongScope,
      );
    }
    if (inbox.generation != generation) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.wrongGeneration,
      );
    }
    if (inbox.etagHash != expectedEtagHash) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.staleIdentity,
      );
    }
  }

  void _validateInbox(
    CloudInboxChangeEntity inbox, {
    required CloudRecordMapEntity recordMap,
    required CloudSemanticReplayEntity replay,
    required CloudSyncScope scope,
    required int generation,
    required String scopeKey,
    required String? expectedEtagHash,
  }) {
    if (inbox.scopeKey != scopeKey ||
        inbox.accountFingerprint != scope.accountFingerprint ||
        inbox.zone != scope.zone) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.wrongScope,
      );
    }
    if (inbox.generation != generation) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.wrongGeneration,
      );
    }
    if (inbox.status == CloudInboxStatus.pending.index) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.pendingSource,
      );
    }
    if (inbox.status == CloudInboxStatus.quarantined.index) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.quarantinedSource,
      );
    }
    if (inbox.status != CloudInboxStatus.applied.index ||
        inbox.changeKey !=
            'change:${_digest('${scope.storageKey}\u001fchange\u001f${inbox.changeIdHash}')}' ||
        inbox.changeType != CloudChangeType.save.name ||
        inbox.isTombstone ||
        inbox.failureCategory != null ||
        inbox.preflightCategory != null ||
        inbox.preflightCode != null ||
        inbox.completedAtMs <= 0 ||
        !_externalDigest.hasMatch(inbox.changeIdHash) ||
        !_externalDigest.hasMatch(inbox.serverRecordIdHash) ||
        inbox.etagHash == null ||
        !_externalDigest.hasMatch(inbox.etagHash!) ||
        inbox.encryptedServerRecordId == null ||
        !_protectedReference.hasMatch(inbox.encryptedServerRecordId!) ||
        inbox.encryptedPayloadRef == null ||
        !_protectedReference.hasMatch(inbox.encryptedPayloadRef!) ||
        inbox.payloadSha256 == null ||
        !_contentDigest.hasMatch(inbox.payloadSha256!) ||
        inbox.batchId.isEmpty ||
        inbox.fetchSequence <= 0) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.invalidSource,
      );
    }
    if (inbox.etagHash != expectedEtagHash ||
        inbox.etagHash != recordMap.etagHash ||
        inbox.serverRecordIdHash != recordMap.serverRecordIdHash ||
        inbox.serverRecordIdHash != replay.serverRecordIdHash) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.staleIdentity,
      );
    }
    if (inbox.encryptedPayloadRef != recordMap.encryptedRawRecordRef ||
        inbox.encryptedServerRecordId != recordMap.encryptedServerRecordId ||
        _replayChangeIdHash(inbox.changeIdHash) != replay.changeIdHash ||
        inbox.payloadSha256 != replay.payloadSha256 ||
        inbox.fetchSequence != replay.inboxSequence ||
        replay.protectedPayloadReferenceHash !=
            _protectedPayloadReferenceHash(inbox.encryptedPayloadRef!)) {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.invalidSource,
      );
    }
  }

  static String _scopeKey(CloudSyncScope scope) =>
      'scope2:${_digest(scope.storageKey)}';

  static String _scopeGenerationKey(CloudSyncScope scope, int generation) =>
      'semantic-generation4:${_digest('${_scopeKey(scope)}\u001f$generation')}';

  static String _recordMapKey(
    CloudSyncScope scope,
    String logicalEntityKeyHash,
  ) =>
      'record-map:${_digest('${scope.storageKey}\u001frecord-map\u001f$logicalEntityKeyHash')}';

  static String _canonicalLookupHash({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) {
    try {
      return CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      );
    } on ArgumentError {
      throw const CloudAttachmentSourceResolutionFailure(
        CloudAttachmentSourceResolutionCode.invalidRequest,
      );
    }
  }

  static String _protectedPayloadReferenceHash(String reference) =>
      _digest('semantic-payload-reference\u001f$reference');

  static String _destinationCanonicalGuidSha256(String canonicalGuid) {
    final bytes = utf8.encode(canonicalGuid);
    return _digest(
      'cloud-attachment-canonical-guid-v1\u001f${bytes.length}:$canonicalGuid',
    );
  }

  static bool _safeCode(String? value) =>
      value != null && RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$').hasMatch(value);

  static bool _isLowerHexDigest(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  // Inbox rows retain the native account-keyed change identifier. Semantic
  // replay rows deliberately store its SHA-256 digest, matching
  // _SemanticTransactionContext.prepare in the ObjectBox semantic gateway.
  static String _replayChangeIdHash(String inboxChangeIdHash) =>
      _digest(inboxChangeIdHash);

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}
