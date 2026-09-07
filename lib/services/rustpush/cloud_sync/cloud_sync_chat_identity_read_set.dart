import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_persistent_keys.dart';

/// Immutable inputs for a future authenticated Chat-identity observation.
///
/// This is NOT write authority, a remote-head proof, or completed projection.
/// No identity is inferred from a decoder failure category or service label.
/// The native observer must still authenticate/decrypt every retained save,
/// prove its identities disjoint from the intended recipient, and bind that
/// result to this exact read set and the current authentication session.
final class CloudSyncChatIdentityReadSet {
  CloudSyncChatIdentityReadSet._(
    this._store, {
    required this.scope,
    required this.generation,
    required this.fetchedSequence,
    required this.appliedSequence,
    required this.retainedTombstones,
    required this.fenceSha256,
    required List<CloudSyncChatIdentitySource> retainedSaves,
  }) : retainedSaves = List.unmodifiable(retainedSaves);

  static const maximumJournalRows = 16384;
  final Store _store;
  final CloudSyncScope scope;
  final int generation;
  final int fetchedSequence;
  final int appliedSequence;
  final int retainedTombstones;
  final String fenceSha256;
  final List<CloudSyncChatIdentitySource> retainedSaves;

  /// Synchronous, bounded and read-only. Protected references stay opaque.
  static CloudSyncChatIdentityReadSet capture(
    Store store,
    CloudSyncScope scope,
  ) {
    if (scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'chatManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        scope.schemaVersion != cloudSyncSchemaVersion) {
      throw StateError('cloud_sync_chat_identity_scope_invalid');
    }
    return store.runInTransaction(TxMode.read, () {
      final scopeKey = cloudSyncPersistentScopeKey(scope);
      final checkpointQuery = store
          .box<CloudSyncCheckpointEntity>()
          .query(CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey))
          .build();
      final CloudSyncCheckpointEntity? checkpoint;
      try {
        checkpoint = checkpointQuery.findUnique();
      } finally {
        checkpointQuery.close();
      }
      if (checkpoint == null ||
          checkpoint.accountFingerprint != scope.accountFingerprint ||
          checkpoint.container != scope.container ||
          checkpoint.database != scope.database ||
          checkpoint.zone != scope.zone ||
          checkpoint.streamKind != scope.streamKind.name ||
          checkpoint.persistenceLane != scope.persistenceLane.name ||
          checkpoint.schemaVersion != scope.schemaVersion ||
          checkpoint.generation <= 0 ||
          checkpoint.fetchedSequence < 0 ||
          checkpoint.appliedSequence < 0 ||
          checkpoint.appliedSequence > checkpoint.fetchedSequence ||
          checkpoint.lastSuccessfulAtMs <= 0 ||
          checkpoint.pendingBatchId != null ||
          checkpoint.pendingFetchedTokenCiphertext != null ||
          checkpoint.lastErrorCategory != null ||
          checkpoint.backoffAttempt != 0 ||
          checkpoint.nextEligibleAtMs != 0) {
        throw StateError('cloud_sync_chat_identity_checkpoint_unready');
      }
      final generation = checkpoint.generation;
      // Include old generations in the bounded scan. Ignoring an unresolved
      // prior-generation identity would manufacture evidence of absence.
      final query =
          (store.box<CloudInboxChangeEntity>().query(
                  CloudInboxChangeEntity_.scopeKey.equals(scopeKey),
                )
                ..order(CloudInboxChangeEntity_.generation)
                ..order(CloudInboxChangeEntity_.fetchSequence)
                ..order(CloudInboxChangeEntity_.id))
              .build()
            ..limit = maximumJournalRows + 1;
      final List<CloudInboxChangeEntity> rows;
      try {
        rows = query.find();
      } finally {
        query.close();
      }
      if (rows.length > maximumJournalRows) {
        throw StateError('cloud_sync_chat_identity_journal_limit');
      }
      if (rows.any(
        (row) =>
            row.accountFingerprint != scope.accountFingerprint ||
            row.zone != scope.zone ||
            row.generation <= 0 ||
            row.generation > generation,
      )) {
        throw StateError('cloud_sync_chat_identity_journal_incomplete');
      }
      if (rows.any(
        (row) =>
            row.generation != generation &&
            row.status != CloudInboxStatus.applied.index,
      )) {
        throw StateError(
          'cloud_sync_chat_identity_prior_generation_unresolved',
        );
      }
      final current = rows
          .where((row) => row.generation == generation)
          .toList(growable: false);
      if (current.length != checkpoint.fetchedSequence) {
        throw StateError('cloud_sync_chat_identity_journal_incomplete');
      }
      final sources = <CloudSyncChatIdentitySource>[];
      var tombstones = 0;
      for (final (index, row) in current.indexed) {
        if (row.fetchSequence != index + 1 ||
            row.scopeKey != scopeKey ||
            row.accountFingerprint != scope.accountFingerprint ||
            row.zone != scope.zone ||
            (row.status != CloudInboxStatus.applied.index &&
                row.status != CloudInboxStatus.retainedUnprojected.index) ||
            (row.fetchSequence <= checkpoint.appliedSequence &&
                row.status != CloudInboxStatus.applied.index) ||
            !{'save', 'delete'}.contains(row.changeType) ||
            row.isTombstone != (row.changeType == 'delete')) {
          throw StateError('cloud_sync_chat_identity_journal_incomplete');
        }
        if (row.status == CloudInboxStatus.applied.index) continue;
        if (row.isTombstone) {
          if (row.failureCategory != null ||
              row.preflightCategory != null ||
              row.preflightCode != null) {
            throw StateError('cloud_sync_chat_identity_tombstone_unresolved');
          }
          tombstones++;
        } else {
          if (!_digest.hasMatch(row.payloadSha256 ?? '') ||
              !_nativeDigest.hasMatch(row.changeIdHash) ||
              !_nativeDigest.hasMatch(row.serverRecordIdHash) ||
              !_nativeDigest.hasMatch(row.etagHash ?? '') ||
              !_reference.hasMatch(row.encryptedPayloadRef ?? '') ||
              !_opaque(row.encryptedServerRecordId)) {
            throw StateError('cloud_sync_chat_identity_source_incomplete');
          }
          sources.add(CloudSyncChatIdentitySource._(row));
        }
      }
      final fence = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'cloud-sync-chat-identity-read-set-v1',
                scope.storageKey,
                checkpoint.id,
                checkpoint.generation,
                checkpoint.fetchedSequence,
                checkpoint.appliedSequence,
                checkpoint.fetchedTokenCiphertext,
                checkpoint.lastBatchId,
                checkpoint.lastSuccessfulAtMs,
                checkpoint.mutationRevisionCounter,
                for (final row in rows)
                  [
                    row.id,
                    row.changeKey,
                    row.changeIdHash,
                    row.scopeKey,
                    row.accountFingerprint,
                    row.zone,
                    row.generation,
                    row.fetchSequence,
                    row.status,
                    row.changeType,
                    row.isTombstone,
                    row.serverRecordIdHash,
                    row.etagHash,
                    row.encryptedServerRecordId,
                    row.encryptedPayloadRef,
                    row.protectedSystemFieldsRef,
                    row.payloadSha256,
                    row.batchId,
                    row.serverModifiedAtMs,
                    row.preflightCategory,
                    row.preflightCode,
                    row.failureCategory,
                  ],
              ]),
            ),
          )
          .toString();
      return CloudSyncChatIdentityReadSet._(
        store,
        scope: scope,
        generation: checkpoint.generation,
        fetchedSequence: checkpoint.fetchedSequence,
        appliedSequence: checkpoint.appliedSequence,
        retainedTombstones: tombstones,
        fenceSha256: fence,
        retainedSaves: sources,
      );
    });
  }

  /// Use within the final admission transaction, not before an awaited write.
  /// Reopening or replacing a store requires a fresh observation, even if the
  /// files were copied byte-for-byte. This read-set is not a persisted permit.
  void requireUnchanged(Store store) {
    if (!identical(store, _store) ||
        capture(store, scope).fenceSha256 != fenceSha256) {
      throw StateError('cloud_sync_chat_identity_read_set_changed');
    }
  }

  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _nativeDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _reference = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
  static bool _opaque(String? value) =>
      value != null &&
      value.isNotEmpty &&
      value.length <= 4096 &&
      !value.codeUnits.any((unit) => unit < 32);

  @override
  String toString() => 'CloudSyncChatIdentityReadSet(redacted)';
}

/// Copied values only, never mutable ObjectBox entities or cleartext identity.
final class CloudSyncChatIdentitySource {
  CloudSyncChatIdentitySource._(CloudInboxChangeEntity row)
    : sequence = row.fetchSequence,
      changeIdHash = row.changeIdHash,
      recordIdHash = row.serverRecordIdHash,
      etagHash = row.etagHash!,
      encryptedServerRecordId = row.encryptedServerRecordId!,
      encryptedPayloadReference = row.encryptedPayloadRef!,
      payloadSha256 = row.payloadSha256!,
      serverModifiedAtMs = row.serverModifiedAtMs;

  final int sequence;
  final String changeIdHash;
  final String recordIdHash;
  final String etagHash;
  final String encryptedServerRecordId;
  final String encryptedPayloadReference;
  final String payloadSha256;
  final int serverModifiedAtMs;

  @override
  String toString() => 'CloudSyncChatIdentitySource(redacted)';
}
