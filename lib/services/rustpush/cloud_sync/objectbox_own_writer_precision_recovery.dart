import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';
import 'cloud_operation_identity.dart';
import 'cloud_sync_local_mutation_journal.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_store.dart';
import 'objectbox_cloud_semantic_store_gateway.dart';

/// Local retry of the first failed, never-committed own edit precision echo.
/// No converter-repair capability, remote writes, or cursor updates live here.
/// The decoder MUST be the ordinary native protected decoder in production.
final class ObjectBoxOwnWriterPrecisionRecovery
    implements CloudOwnWriterPrecisionBarrierRecovery {
  ObjectBoxOwnWriterPrecisionRecovery({
    required Store store,
    required CloudSemanticDecoder decoder,
    required CloudCanonicalSemanticEntityAdapter canonicalAdapter,
    required CloudTransientCanonicalIdentityRegistrar identityRegistrar,
    required int? Function(CloudDecodedMutation) proveEcho,
    required Future<bool> Function() revalidateAccount,
    void Function(String)? onDiagnostic,
    DateTime Function()? clock,
    // Keep the public named API explicit rather than using private field formals.
    // ignore: prefer_initializing_formals
  }) : _store = store,
       // ignore: prefer_initializing_formals
       _decoder = decoder,
       _adapter = canonicalAdapter,
       _registrar = identityRegistrar,
       // ignore: prefer_initializing_formals
       _proveEcho = proveEcho,
       // ignore: prefer_initializing_formals
       _revalidateAccount = revalidateAccount,
       // ignore: prefer_initializing_formals
       _onDiagnostic = onDiagnostic,
       _clock = clock ?? DateTime.now;

  final Store _store;
  final CloudSemanticDecoder _decoder;
  final CloudCanonicalSemanticEntityAdapter _adapter;
  final CloudTransientCanonicalIdentityRegistrar _registrar;
  final int? Function(CloudDecodedMutation) _proveEcho;
  final Future<bool> Function() _revalidateAccount;
  final void Function(String)? _onDiagnostic;
  final DateTime Function() _clock;

  // Only fixed stage/catch literals enter this callback, never source values
  // or exception text. Diagnostics cannot change the recovery decision.
  void _diagnostic(String label) {
    try {
      _onDiagnostic?.call(label);
    } catch (_) {
      // A diagnostic observer must not authorize, reject, or abort recovery.
    }
  }

  bool _reject(String stage) {
    _diagnostic(stage);
    return false;
  }

  @override
  Future<bool> requeueOwnWriterPrecisionBarrier(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    if (scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2 ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      return _reject('own_writer_precision_scope');
    }
    var stage = 'own_writer_precision_candidate_checkpoint';
    void enterStage(String value) => stage = value;
    try {
      final candidate = _store.runInTransaction(
        TxMode.read,
        () => _candidate(scope, leaseFence, enterStage: enterStage),
      );
      if (candidate == null) {
        return _reject(stage);
      }
      stage = 'own_writer_precision_account_before_decode';
      if (!await _revalidateAccount()) {
        return _reject(stage);
      }
      stage = 'own_writer_precision_native_source_decode';
      final entry = _entry(scope, candidate.row);
      final decoded = await _decoder.decode(entry);
      if (!_decodedMatches(decoded, entry)) {
        return _reject('own_writer_precision_native_source_binding');
      }
      // A finalized write readback and a change-feed event are distinct native
      // envelopes, even for one record/ETag. This retry does not consume the
      // mapped raw bytes or authorize a write. Require the finalized local
      // operation/map provenance below and let ordinary application consume
      // ONLY this independently validated fetched source. Do not misrepresent
      // the predecessor admission digest as a resulting-ETag receipt.
      stage = 'own_writer_precision_account_after_decode';
      if (!await _revalidateAccount()) {
        return _reject(stage);
      }
      stage = 'own_writer_precision_identity_bind';
      final identities = _registrar.bind(decoded);
      try {
        return _store.runInTransaction(TxMode.write, () {
          final current = _candidate(scope, leaseFence, enterStage: enterStage);
          if (current == null) {
            return _reject(stage);
          }
          if (current.binding != candidate.binding) {
            return _reject('own_writer_precision_candidate_changed');
          }
          stage = 'own_writer_precision_proof';
          final id = _proveEcho(decoded);
          if (id == null) {
            return _reject('own_writer_precision_proof_null');
          }
          stage = 'own_writer_precision_terminal_mutation';
          if (!_terminalOwnMutation(scope, current, decoded, id)) {
            return _reject(stage);
          }
          stage = 'own_writer_precision_final_fence';
          ObjectBoxCloudSemanticFence.validateLocked(
            store: _store,
            entry: entry,
            leaseFence: leaseFence,
            nowMs: _clock().toUtc().millisecondsSinceEpoch,
            expectedInboxStatus: CloudInboxStatus.quarantined,
            canonicalAdapter: _adapter,
          );
          final row = current.row;
          // Count one is the original failed apply. Reserve its only recovery
          // attempt durably now, before returning to ordinary apply. A crash
          // resumes pending; failure increments again and cannot re-enter.
          // Preserve the original failure category/completion and all source.
          stage = 'own_writer_precision_requeue_write';
          row.status = CloudInboxStatus.pending.index;
          row.retryCount = 2;
          row.updatedAtMs = _clock().toUtc().millisecondsSinceEpoch;
          _store.box<CloudInboxChangeEntity>().put(row);
          return true;
        });
      } finally {
        identities.release();
      }
    } on CloudSyncFailure {
      _diagnostic(stage);
      _diagnostic('own_writer_precision_catch_cloud_sync');
      return false;
    } on CloudSemanticDecodeFailure {
      _diagnostic(stage);
      _diagnostic('own_writer_precision_catch_native_decode');
      return false;
    } catch (_) {
      _diagnostic(stage);
      _diagnostic('own_writer_precision_catch_other');
      rethrow; // Preserve the existing behavior for unexpected exceptions.
    }
  }

  bool _decodedMatches(CloudDecodedMutation value, CloudInboxEntry entry) =>
      value.scope == entry.scope &&
      value.generation == entry.generation &&
      value.changeId == entry.change.changeId &&
      value.kind == CloudDecodedMutationKind.upsert &&
      value.tombstone == null &&
      value.payload is CloudMessageEntityPayload &&
      value.snapshot != null &&
      value.snapshot!.etagHash == entry.change.etagHash &&
      value.snapshot!.encryptedRawRecordReference ==
          entry.change.encryptedPayloadReference;

  _Candidate? _candidate(
    CloudSyncScope scope,
    CloudCoordinatorLeaseFence fence, {
    required void Function(String) enterStage,
  }) {
    enterStage('own_writer_precision_candidate_checkpoint');
    final scopeKey = cloudSyncPersistentScopeKey(scope);
    final checkpoint = _unique(
      _store.box<CloudSyncCheckpointEntity>().query(
        CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey),
      ),
    );
    if (checkpoint == null ||
        checkpoint.pendingBatchId == null ||
        checkpoint.pendingFetchedTokenCiphertext == null ||
        checkpoint.persistenceLane != scope.persistenceLane.name ||
        checkpoint.appliedSequence < 0 ||
        checkpoint.appliedSequence > checkpoint.fetchedSequence) {
      return null;
    }
    enterStage('own_writer_precision_candidate_journal');
    final query = _store
        .box<CloudInboxChangeEntity>()
        .query(
          CloudInboxChangeEntity_.scopeKey
              .equals(scopeKey)
              .and(
                CloudInboxChangeEntity_.generation.equals(
                  checkpoint.generation,
                ),
              ),
        )
        .order(CloudInboxChangeEntity_.fetchSequence)
        .build();
    late List<CloudInboxChangeEntity> rows;
    try {
      rows = query.find();
    } finally {
      query.close();
    }
    // Full journal continuity, including duplicates, not just a prefix count.
    if (rows.length != checkpoint.fetchedSequence) {
      return null;
    }
    CloudInboxChangeEntity? row;
    for (var i = 0; i < rows.length; i++) {
      final item = rows[i];
      if (item.fetchSequence != i + 1 ||
          item.accountFingerprint != scope.accountFingerprint ||
          item.zone != scope.zone) {
        return null;
      }
      if (row == null &&
          item.status != CloudInboxStatus.applied.index &&
          item.status != CloudInboxStatus.retainedUnprojected.index) {
        row = item;
      }
    }
    enterStage('own_writer_precision_candidate_head_eligibility');
    if (row == null ||
        row.status != CloudInboxStatus.quarantined.index ||
        row.fetchSequence <= checkpoint.appliedSequence ||
        row.batchId != checkpoint.pendingBatchId ||
        row.changeType != 'save' ||
        row.isTombstone ||
        row.preflightCategory != null ||
        row.preflightCode != null ||
        row.failureCategory != CloudFailureCategory.conflict.name ||
        row.retryCount != 1 ||
        row.nextEligibleAtMs != 0 ||
        row.completedAtMs <= 0 ||
        row.completedAtMs != row.updatedAtMs ||
        row.updatedAtMs >= _clock().toUtc().millisecondsSinceEpoch ||
        row.encryptedPayloadRef == null ||
        row.payloadSha256 == null ||
        row.etagHash == null) {
      return null;
    }
    enterStage('own_writer_precision_candidate_fence');
    ObjectBoxCloudSemanticFence.validateLocked(
      store: _store,
      entry: _entry(scope, row),
      leaseFence: fence,
      nowMs: _clock().toUtc().millisecondsSinceEpoch,
      expectedInboxStatus: CloudInboxStatus.quarantined,
      canonicalAdapter: _adapter,
    );
    enterStage('own_writer_precision_candidate_replay');
    final replays = _store
        .box<CloudSemanticReplayEntity>()
        .query(
          CloudSemanticReplayEntity_.scopeKey
              .equals(scopeKey)
              .and(CloudSemanticReplayEntity_.generation.equals(row.generation))
              .and(
                CloudSemanticReplayEntity_.inboxSequence
                    .equals(row.fetchSequence)
                    .or(
                      CloudSemanticReplayEntity_.changeIdHash.equals(
                        _sha(row.changeIdHash),
                      ),
                    ),
              ),
        )
        .build();
    try {
      if (replays.count() != 0) {
        return null;
      }
    } finally {
      replays.close();
    }
    enterStage('own_writer_precision_candidate_map');
    final mapping = _unique(
      _store.box<CloudRecordMapEntity>().query(
        CloudRecordMapEntity_.scopeKey
            .equals(scopeKey)
            .and(CloudRecordMapEntity_.generation.equals(row.generation))
            .and(
              CloudRecordMapEntity_.serverRecordIdHash.equals(
                row.serverRecordIdHash,
              ),
            ),
      ),
    );
    if (mapping == null ||
        mapping.accountFingerprint != scope.accountFingerprint ||
        mapping.zone != scope.zone ||
        mapping.etagHash != row.etagHash ||
        mapping.mapKey !=
            cloudSyncCanonicalRecordMapKey(
              scope,
              mapping.logicalEntityKeyHash,
            ) ||
        !RegExp(
          r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(mapping.encryptedServerRecordId) ||
        mapping.rawRecordGeneration != row.generation ||
        mapping.encryptedRawRecordRef == null ||
        mapping.protectedReadbackLeaseReference != null ||
        mapping.pendingUpdateOperationId != null ||
        mapping.pendingUpdatePredecessorEtagHash != null) {
      return null;
    }
    final logicalMaps = _store
        .box<CloudRecordMapEntity>()
        .query(
          CloudRecordMapEntity_.scopeKey
              .equals(scopeKey)
              .and(CloudRecordMapEntity_.generation.equals(row.generation))
              .and(
                CloudRecordMapEntity_.logicalEntityKeyHash.equals(
                  mapping.logicalEntityKeyHash,
                ),
              ),
        )
        .build();
    try {
      if (logicalMaps.count() != 1) {
        return null;
      }
    } finally {
      logicalMaps.close();
    }
    return _Candidate(
      row,
      mapping,
      jsonEncode([
        checkpoint.generation,
        checkpoint.appliedSequence,
        checkpoint.fetchedSequence,
        checkpoint.pendingBatchId,
        checkpoint.pendingFetchedTokenCiphertext,
        checkpoint.fetchedTokenCiphertext,
        checkpoint.updatedAtMs,
        row.id,
        row.changeKey,
        row.changeIdHash,
        row.scopeKey,
        row.accountFingerprint,
        row.zone,
        row.serverRecordIdHash,
        row.etagHash,
        row.changeType,
        row.encryptedServerRecordId,
        row.protectedSystemFieldsRef,
        row.encryptedPayloadRef,
        row.payloadSha256,
        row.batchId,
        row.generation,
        row.fetchSequence,
        row.status,
        row.isTombstone,
        row.preflightCategory,
        row.preflightCode,
        row.failureCategory,
        row.retryCount,
        row.nextEligibleAtMs,
        row.serverModifiedAtMs,
        row.serverModifiedAtFormatVersion,
        row.createdAtMs,
        row.updatedAtMs,
        row.completedAtMs,
        mapping.id,
        mapping.mapKey,
        mapping.logicalEntityKeyHash,
        mapping.encryptedRawRecordRef,
        mapping.updatedAtMs,
        mapping.encryptedServerRecordId,
      ]),
    );
  }

  bool _terminalOwnMutation(
    CloudSyncScope scope,
    _Candidate candidate,
    CloudDecodedMutation decoded,
    int localId,
  ) {
    final payload = decoded.payload as CloudMessageEntityPayload;
    final map = candidate.mapping;
    if (payload.logicalEntityKeyHash != map.logicalEntityKeyHash) {
      return false;
    }
    final target = _store.box<Message>().get(localId);
    if (target == null ||
        target.guid != payload.canonicalGuid ||
        target.isFromMe != true) {
      return false;
    }
    final targetHash = _sha(
      jsonEncode(['cloud-sync-local-send-guid-v1', payload.canonicalGuid]),
    );
    final query = _store
        .box<CloudSyncLocalMutationIntentEntity>()
        .query(
          CloudSyncLocalMutationIntentEntity_.accountFingerprint.equals(
            scope.accountFingerprint,
          ),
        )
        .build();
    late List<CloudSyncLocalMutationIntentEntity> intents;
    try {
      intents = query.find().where((r) => r.localMessageId == localId).toList();
    } finally {
      query.close();
    }
    if (intents.isEmpty || intents.any((r) => r.state != 5)) {
      return false;
    }
    intents.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final intent = intents.first;
    validateCloudSyncMutationRow(intent);
    if (intent.kind != 0 ||
        intent.targetPart != 0 ||
        intent.targetGuidHash != targetHash ||
        intent.localChatId != target.chat.targetId ||
        intent.admittedOperationId == null ||
        intent.reflectedSnapshotSha256 !=
            cloudSyncPrecisionEchoReflectedSnapshotDigest(target) ||
        intents.where((r) => r.updatedAtMs == intent.updatedAtMs).length != 1) {
      return false;
    }
    final operation = _unique(
      _store.box<CloudOutboxOperationEntity>().query(
        CloudOutboxOperationEntity_.operationId.equals(
          intent.admittedOperationId!,
        ),
      ),
    );
    if (operation == null ||
        operation.scopeKey != map.scopeKey ||
        operation.accountFingerprint != scope.accountFingerprint ||
        operation.zone != scope.zone ||
        operation.checkpointGeneration != map.generation ||
        operation.action != 0 ||
        operation.payloadVersion != cloudSyncMessageUpdatePayloadVersion ||
        operation.logicalEntityKeyHash != map.logicalEntityKeyHash ||
        operation.serverRecordIdHash != map.serverRecordIdHash ||
        operation.state != CloudOutboxStatus.confirmed.index ||
        operation.confirmedAtMs <= 0 ||
        operation.protectedLeaseReference != null ||
        operation.leaseIdHash != null ||
        operation.leaseExpiresAtMs != 0 ||
        operation.nextEligibleAtMs != 0 ||
        operation.lastErrorCategory != null ||
        operation.appleRequestUuid == null ||
        operation.appleOperationUuid == null ||
        operation.dependencyOperationIdsJson != '[]' ||
        operation.encryptedPayloadRef == null ||
        operation.payloadSha256 == null ||
        operation.operationId !=
            CloudOperationIdentity.forMutation(
              scope: scope,
              logicalEntityKeyHash: map.logicalEntityKeyHash,
              action: CloudOutboxAction.save,
              payloadVersion: operation.payloadVersion,
              mutationRevision: operation.mutationRevision,
              payloadSha256: operation.payloadSha256,
            ) ||
        operation.confirmedAtMs != map.updatedAtMs ||
        operation.confirmedAtMs > candidate.row.createdAtMs ||
        intent.updatedAtMs < operation.confirmedAtMs) {
      return false;
    }
    final conflicts = _store
        .box<CloudOutboxOperationEntity>()
        .query(
          CloudOutboxOperationEntity_.scopeKey
              .equals(map.scopeKey)
              .and(
                CloudOutboxOperationEntity_.logicalEntityKeyHash.equals(
                  map.logicalEntityKeyHash,
                ),
              ),
        )
        .build();
    try {
      return conflicts.find().every(
        (row) =>
            row.state == CloudOutboxStatus.confirmed.index &&
            row.protectedLeaseReference == null &&
            row.leaseIdHash == null &&
            row.leaseExpiresAtMs == 0 &&
            row.nextEligibleAtMs == 0,
      );
    } finally {
      conflicts.close();
    }
  }

  static T? _unique<T>(QueryBuilder<T> builder) {
    final query = builder.build()..limit = 2;
    try {
      final rows = query.find();
      return rows.length == 1 ? rows.single : null;
    } finally {
      query.close();
    }
  }

  static String _sha(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static CloudInboxEntry _entry(
    CloudSyncScope scope,
    CloudInboxChangeEntity row,
  ) => CloudInboxEntry(
    scope: scope,
    sequence: row.fetchSequence,
    status: CloudInboxStatus.quarantined,
    attemptCount: row.retryCount,
    batchId: row.batchId,
    generation: row.generation,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row.createdAtMs,
      isUtc: true,
    ),
    completedAt: DateTime.fromMillisecondsSinceEpoch(
      row.completedAtMs,
      isUtc: true,
    ),
    lastFailure: CloudFailureCategory.conflict,
    change: CloudFetchedChange(
      changeId: row.changeIdHash,
      recordIdHash: row.serverRecordIdHash,
      etagHash: row.etagHash,
      type: CloudChangeType.save,
      encryptedServerRecordId: row.encryptedServerRecordId,
      protectedSystemFieldsReference: row.protectedSystemFieldsRef,
      encryptedPayloadReference: row.encryptedPayloadRef,
      payloadSha256: row.payloadSha256,
      serverModifiedAt: cloudInboxCanonicalServerModifiedAt(row),
    ),
  );
}

final class _Candidate {
  const _Candidate(this.row, this.mapping, this.binding);
  final CloudInboxChangeEntity row;
  final CloudRecordMapEntity mapping;
  final String binding;
}

/// The existing local-mutation journal's v1 reflection binding, checked here
/// without acquiring writer authority or reopening a terminal native source.
/// Keep identical to cloud_sync_local_mutation_journal.dart's _snapshot.
String cloudSyncPrecisionEchoReflectedSnapshotDigest(Message target) {
  final chat = target.chat.target;
  if (chat == null) throw StateError('precision_echo_chat_missing');
  Object? canonical(Object? value) {
    if (value is List) return value.map(canonical).toList();
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    return value;
  }

  return sha256
      .convert(
        utf8.encode(
          jsonEncode(
            canonical([
              'cloud-sync-mutation-target-v1',
              target.id,
              target.guid,
              target.chat.targetId,
              target.isFromMe,
              target.dateCreated?.millisecondsSinceEpoch,
              target.dateEdited?.millisecondsSinceEpoch,
              target.dateDeleted?.millisecondsSinceEpoch,
              target.text,
              target.subject,
              target.attributedBody.map((p) => p.toMap()).toList(),
              target.messageSummaryInfo.map((i) => i.toJson()).toList(),
              target.dbAttachments.map((a) => [a.id, a.guid]).toList(),
              chat.guid,
              chat.chatIdentifier,
              chat.usingHandle,
              chat.style,
              chat.isRpSms,
              chat.handles.map((h) => [h.address, h.service]).toList(),
            ]),
          ),
        ),
      )
      .toString();
}
