import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_operation_identity.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Durable owner discriminator for byte-upload rows. Stable codes: 0 IDS
/// local send (default, preserves every existing row), 1 historical archive
/// intent. A historical row never carries a local-send intent id and is
/// never resolved through the local-send journal.
const cloudSyncAttachmentOwnerKindLocalSend = 0;
const cloudSyncAttachmentOwnerKindHistorical = 1;

/// Fixed redacted code for owner-lane mismatches: a local-send entrypoint
/// meeting a historical row (or the reverse). Fail closed, never reinterpret.
const cloudSyncAttachmentOwnerChangedCode = 'cloud_sync_attachment_owner_changed';

/// Byte-upload progress, deliberately not a CloudKit record-save status.
/// Persisted codes are stable. There is no automatic unknown -> prepared edge.
enum CloudAttachmentUploadState {
  prepared,
  started,
  uploaded,
  adopted,
  unknown,
}

final class CloudAttachmentUploadSnapshot {
  CloudAttachmentUploadSnapshot._(CloudAttachmentUploadEntity row)
    : id = row.id,
      uploadKey = row.uploadKey,
      localSendIntentId = row.localSendIntentId,
      // Durable owner lane. Historical rows carry localSendIntentId 0;
      // executor routing must read ownerKind/ownerIntentId instead of
      // pretending a historical owner has a local-send intent id.
      ownerKind = row.ownerKind,
      ownerIntentId = row.ownerIntentId,
      state = CloudAttachmentUploadState.values[row.state],
      attemptId = row.attemptId,
      admittedOperationId = row.admittedOperationId,
      plan = _plan(row),
      result = row.resultReference == null ? null : _result(row);

  final int id;
  final String uploadKey;
  final int localSendIntentId;
  final int ownerKind;
  final int ownerIntentId;
  final CloudAttachmentUploadState state;
  final String? attemptId;
  final String? admittedOperationId;
  final CloudSyncProtectedOutboundStageData plan;
  final CloudSyncProtectedOutboundStageData? result;
}

/// Owns original preparation and completed-upload envelopes independently of
/// the immutable final-save outbox. Only content-free bindings enter ObjectBox.
///
/// Caller holds the CloudKit interlock and native protected-store exclusion
/// through stage/adopt/commit, and revalidates native auth around awaits. A
/// successful beginAttempt must be durable BEFORE consuming the native upload
/// owner. A started row surviving process death is ambiguous, never retryable
/// merely because its eventual attachment record is absent.
final class CloudSyncAttachmentUploadJournal {
  CloudSyncAttachmentUploadJournal({
    required Store store,
    required CloudSyncLocalSendJournal localSends,
    required CloudSyncScope scope,
    required int checkpointGeneration,
    required CloudSyncNativeAuthSnapshot currentAuth,
    // Writer authority for historical-owner paths only, publicly supplyable
    // under this name. Legacy IDS paths resolve authority through the
    // local-send journal and ignore this. Historical adoption/source/readback
    // methods throw when it is absent.
    this.writerAuthority,
  }) : _store = store,
       _localSends = localSends,
       _scope = scope,
       _generation = checkpointGeneration,
       _auth = currentAuth {
    if (!localSends.isBoundToStore(store) ||
        scope.accountFingerprint != currentAuth.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'attachmentManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        scope.schemaVersion != 2 ||
        checkpointGeneration <= 0) {
      throw StateError('cloud_sync_attachment_upload_scope_invalid');
    }
  }

  final Store _store;
  final CloudSyncLocalSendJournal _localSends;
  final CloudSyncScope _scope;
  final int _generation;
  final CloudSyncNativeAuthSnapshot _auth;
  final ObjectBoxCloudKitWriterAuthority? writerAuthority;
  Box<CloudAttachmentUploadEntity> get _uploads =>
      _store.box<CloudAttachmentUploadEntity>();

  /// Legacy IDS entrypoints resolve origins exclusively through the
  /// local-send journal. A historical row here is a caller error, never a
  /// local-send intent: fail closed instead of reinterpreting its ids.
  void _requireLocalRow(CloudAttachmentUploadEntity row) {
    if (row.ownerKind != cloudSyncAttachmentOwnerKindLocalSend) {
      throw StateError(cloudSyncAttachmentOwnerChangedCode);
    }
  }

  /// Owner gate before [_readBound], which itself resolves IDS origins and
  /// would otherwise fail historical rows with an unrelated intent error.
  /// Reads only the discriminator without validating the row.
  void _requireLocalId(int id) {
    final row = id > 0 ? _uploads.get(id) : null;
    if (row != null &&
        row.ownerKind != cloudSyncAttachmentOwnerKindLocalSend) {
      throw StateError(cloudSyncAttachmentOwnerChangedCode);
    }
  }

  bool isBoundTo(Store store, CloudSyncScope scope) =>
      identical(_store, store) && _scope == scope;

  CloudSyncScope get scope => _scope;

  /// Pending evidence only: the byte guard disarms before result recording,
  /// so uploaded/adopted history cannot own a pending byte fence. Include
  /// corrupt pending states and prepared rows with attempts to fail closed.
  /// Cap unresolved work, not lifetime history; reject overflow, never truncate.
  List<int> readAttemptedForReconciliation({int? onlyIntentId}) =>
      _store.runInTransaction(TxMode.read, () {
        if (onlyIntentId != null && onlyIntentId <= 0) {
          throw StateError('cloud_sync_attachment_upload_binding_changed');
        }
        _requireGeneration();
        var condition = CloudAttachmentUploadEntity_.accountFingerprint
            .equals(_scope.accountFingerprint)
            .and(CloudAttachmentUploadEntity_.protectedStoreIdentity
                .equals(_auth.protectedStoreIdentity))
            .and(CloudAttachmentUploadEntity_.checkpointGeneration
                .equals(_generation))
            .and(CloudAttachmentUploadEntity_.ownerKind
                .equals(cloudSyncAttachmentOwnerKindLocalSend))
            .and(CloudAttachmentUploadEntity_.state
                .notEquals(CloudAttachmentUploadState.uploaded.index))
            .and(CloudAttachmentUploadEntity_.state
                .notEquals(CloudAttachmentUploadState.adopted.index))
            .and(CloudAttachmentUploadEntity_.state
                .notEquals(CloudAttachmentUploadState.prepared.index)
                .or(CloudAttachmentUploadEntity_.attemptId.notNull()));
        if (onlyIntentId != null) {
          condition = condition.and(CloudAttachmentUploadEntity_.localSendIntentId
              .equals(onlyIntentId));
        }
        final query = _uploads.query(condition).build()..limit = 65;
        try {
          final candidates = query.find();
          if (candidates.length > 64) {
            throw StateError('cloud_sync_attachment_upload_recovery_bound_exceeded');
          }
          final keys = <String>{};
          final ids = <int>[];
          for (final candidate in candidates) {
            final row = _readBound(candidate.id);
            if (!keys.add(row.uploadKey)) {
              throw StateError('cloud_sync_attachment_upload_inventory_changed');
            }
            reconciliationBindingSha256(row.id);
            ids.add(row.id);
          }
          return List<int>.unmodifiable(ids);
        } finally {
          query.close();
        }
      });

  /// Immutable source evidence for an existing upload, never new-send authority.
  CloudSyncLocalSendSourceBinding readOriginalSource(int id) =>
      _store.runInTransaction(TxMode.read, () {
        _requireLocalId(id);
        _requireLocalRow(_readBound(id));
        return _localSends
            .readConfirmedOriginForExistingUpload(
              transactionStore: _store,
              uploadId: id,
              currentAuth: _auth,
            )
            .source;
      });

  /// Revalidate the completed upload and original IDS source at dispatch, not
  /// just admission. Called synchronously within the outbox store transaction.
  void requireAdoptedOperation(CloudOutboxOperation operation) {
    _localSends.requireCurrentAttachmentWriteAuthority(_store);
    if (operation.scope != _scope ||
        operation.checkpointGeneration != _generation) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.admittedOperationId.equals(
            operation.operationId,
          ),
        )
        .build();
    final CloudAttachmentUploadEntity? candidate;
    try {
      candidate = query.findUnique();
    } finally {
      query.close();
    }
    if (candidate == null) {
      throw StateError('cloud_sync_attachment_upload_origin_missing');
    }
    _requireLocalId(candidate.id);
    final row = _readBound(candidate.id);
    _requireLocalRow(row);
    if (row.state != CloudAttachmentUploadState.adopted.index ||
        row.attachmentKeyHash != operation.logicalEntityKeyHash ||
        row.serverRecordIdHash != operation.serverRecordIdHash ||
        row.resultReference != operation.encryptedPayloadReference ||
        row.resultPayloadSha256 != operation.payloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    _requireFinalOperation(row, operation.operationId);
  }

  /// Content-free, versioned parent proof that every source-derived attachment
  /// child for one local send reached exact remote readback, not merely a
  /// completed byte upload or a generic confirmed outbox state.
  ///
  /// Opens its own read transaction, so it is safe to call with no ambient
  /// transaction (for example directly under the parent fence) or nested
  /// inside the caller's existing Store transaction; nested reads are
  /// supported like the existing journal methods. The initial key inventory
  /// comes from the native source in the parent; this method requires it
  /// to be the exact complete set (1..64 unique token-format keys) and requires every retained plan for
  /// [localSendIntentId] to match it with no missing, extra, or duplicate
  /// keys. Every child must be adopted, its deterministic final-save outbox
  /// operation must match its original result, and that operation must be in
  /// the readback-acknowledged state: confirmed with its protected lease
  /// released and the full release-candidate identity intact (Apple
  /// request/operation UUID pair, confirmation marker, no active lease).
  /// That durable state is produced only by the transport's exact no-save
  /// replay verification followed by the receipt release
  /// (verifyConfirmedAttachmentCreateNoSave then releaseConfirmedReplayReceipt
  /// clearing the retained receipt). It is authoritative under the
  /// retain-for-replay contract: a receipt committed with immediate lease
  /// clearing and no readback is durably identical, so parent-gated
  /// attachment scopes must retain confirmed receipts for replay.
  ///
  /// Returns the immutable proof as a versioned JSON string carrying only
  /// IDs and digests (scope key, generation, intent ID, source lineage
  /// hashes, the retained source-derived key list, per-child
  /// key/result/operation digests, and a proof digest). No message text,
  /// path, GUID, or credential enters the proof. The retained key list lets
  /// [requireParentReadbackProof] recompute and compare the exact proof
  /// later, including across restart, without awaiting a fresh native
  /// inventory.
  String captureParentReadbackProof({
    required int localSendIntentId,
    required Iterable<String> sourceAttachmentKeys,
  }) =>
      _store.runInTransaction(
        TxMode.read,
        () => _captureParentReadbackProofLocked(
          localSendIntentId: localSendIntentId,
          sourceAttachmentKeys: sourceAttachmentKeys,
        ),
      );

  /// Capture implementation; the caller holds a Store transaction (the
  /// public wrapper's read transaction or an outer caller transaction).
  String _captureParentReadbackProofLocked({
    required int localSendIntentId,
    required Iterable<String> sourceAttachmentKeys,
  }) {
    final inventory = _requireParentProofInventory(sourceAttachmentKeys);
    if (localSendIntentId <= 0) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    _requireGeneration();
    _localSends.requireCurrentAttachmentWriteAuthority(_store);
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.localSendIntentId.equals(
            localSendIntentId,
          ),
        )
        .build();
    try {
      final retained = query.find();
      if (retained.isEmpty) {
        throw StateError('cloud_sync_attachment_upload_inventory_changed');
      }
      final seen = <String>{};
      CloudAttachmentUploadEntity? lineage;
      for (final candidate in retained) {
        final row = _readBound(candidate.id);
        if (row.localSendIntentId != localSendIntentId ||
            !inventory.contains(row.attachmentKeyHash) ||
            !seen.add(row.attachmentKeyHash)) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
        if (lineage == null) {
          lineage = row;
        } else if (lineage.messageGuidHash != row.messageGuidHash ||
            lineage.sourceSha256 != row.sourceSha256 ||
            lineage.protectedStoreIdentity != row.protectedStoreIdentity ||
            lineage.writerEpoch != row.writerEpoch) {
          throw StateError('cloud_sync_attachment_upload_binding_changed');
        }
      }
      if (seen.length != inventory.length) {
        throw StateError('cloud_sync_attachment_upload_inventory_changed');
      }
      final ordered = retained.map((candidate) => _readBound(candidate.id)).toList()
        ..sort((a, b) => a.attachmentKeyHash.compareTo(b.attachmentKeyHash));
      final children = <List<Object>>[];
      for (final row in ordered) {
        if (row.state != CloudAttachmentUploadState.adopted.index ||
            row.admittedOperationId == null) {
          throw StateError('cloud_sync_attachment_upload_result_missing');
        }
        final acknowledged = _requireReadbackAcknowledgedFinalOperation(row);
        children.add(<Object>[
          row.id,
          row.attachmentKeyHash,
          row.serverRecordIdHash,
          row.resultPayloadSha256!,
          acknowledged.operationId,
        ]);
      }
      final origin = lineage!;
      final body = <Object>[
        1,
        _scope.storageKey,
        _generation,
        localSendIntentId,
        origin.messageGuidHash,
        origin.sourceSha256,
        origin.protectedStoreIdentity,
        origin.writerEpoch,
        inventory,
        children,
      ];
      final digest = sha256.convert(utf8.encode(jsonEncode(body))).toString();
      return jsonEncode(<Object>[...body, digest]);
    } finally {
      query.close();
    }
  }

  /// Revalidates a proof previously captured by [captureParentReadbackProof].
  ///
  /// Opens its own read transaction like the capture path, so the same
  /// nesting rules apply. Parses the bounded proof, requires its intent ID
  /// to match [localSendIntentId], then recomputes the exact proof from the
  /// persisted source and children using the key list retained inside the
  /// proof and compares byte-for-byte. Any parse failure, inventory drift,
  /// later row tamper, or readback regression throws.
  void requireParentReadbackProof({
    required int localSendIntentId,
    required String proof,
  }) =>
      _store.runInTransaction(
        TxMode.read,
        () => _requireParentReadbackProofLocked(
          localSendIntentId: localSendIntentId,
          proof: proof,
        ),
      );

  /// Revalidation implementation; the caller holds a Store transaction and
  /// the recompute shares that same read snapshot.
  void _requireParentReadbackProofLocked({
    required int localSendIntentId,
    required String proof,
  }) {
    final keys = _parseParentProofKeys(proof, localSendIntentId);
    final recomputed = _captureParentReadbackProofLocked(
      localSendIntentId: localSendIntentId,
      sourceAttachmentKeys: keys,
    );
    if (recomputed != proof) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
  }

  /// Historical readback proof, version 2: the same child/readback rules as
  /// the version-1 IDS proof, keyed by (historical owner, intent id).
  /// Legacy version-1 proofs never validate historical rows and vice versa.
  String captureHistoricalParentReadbackProof({
    required int historicalIntentId,
    required Iterable<String> sourceAttachmentKeys,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(
    TxMode.read,
    () => _captureHistoricalParentReadbackProofLocked(
      historicalIntentId: historicalIntentId,
      sourceAttachmentKeys: sourceAttachmentKeys,
      historicalJournal: historicalJournal,
    ),
  );

  String _captureHistoricalParentReadbackProofLocked({
    required int historicalIntentId,
    required Iterable<String> sourceAttachmentKeys,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) {
    final inventory = _requireParentProofInventory(sourceAttachmentKeys);
    if (historicalIntentId <= 0) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    _requireGeneration();
    final authority = writerAuthority;
    if (authority == null) throw StateError('cloud_sync_attachment_upload_binding_changed');
    // Readback evidence must remain available under an uncertain parent save.
    // Dispatch still obtains its own current mutation permit separately.
    _readHistoricalEpoch(authority, CloudKitWriterScope(accountFingerprint: _scope.accountFingerprint));
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.ownerKind
              .equals(cloudSyncAttachmentOwnerKindHistorical)
              .and(
                CloudAttachmentUploadEntity_.ownerIntentId.equals(
                  historicalIntentId,
                ),
              ),
        )
        .build();
    try {
      final retained = query.find();
      if (retained.isEmpty) {
        throw StateError('cloud_sync_attachment_upload_inventory_changed');
      }
      final seen = <String>{};
      CloudAttachmentUploadEntity? lineage;
      for (final candidate in retained) {
        final row = _readHistoricalBound(candidate.id, historicalJournal);
        if (row.ownerKind != cloudSyncAttachmentOwnerKindHistorical ||
            row.ownerIntentId != historicalIntentId ||
            !inventory.contains(row.attachmentKeyHash) ||
            !seen.add(row.attachmentKeyHash)) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
        if (lineage == null) {
          lineage = row;
        } else if (lineage.messageGuidHash != row.messageGuidHash ||
            lineage.sourceSha256 != row.sourceSha256 ||
            lineage.protectedStoreIdentity != row.protectedStoreIdentity) {
          throw StateError('cloud_sync_attachment_upload_binding_changed');
        }
      }
      if (seen.length != inventory.length) {
        throw StateError('cloud_sync_attachment_upload_inventory_changed');
      }
      final ordered = retained
          .map((candidate) => _readHistoricalBound(candidate.id, historicalJournal))
          .toList()
        ..sort((a, b) => a.attachmentKeyHash.compareTo(b.attachmentKeyHash));
      final children = <List<Object>>[];
      for (final row in ordered) {
        if (row.state != CloudAttachmentUploadState.adopted.index ||
            row.admittedOperationId == null) {
          throw StateError('cloud_sync_attachment_upload_result_missing');
        }
        final acknowledged = _requireReadbackAcknowledgedFinalOperation(row);
        children.add(<Object>[
          row.id,
          row.attachmentKeyHash,
          row.serverRecordIdHash,
          row.resultPayloadSha256!,
          acknowledged.operationId,
          row.writerEpoch,
        ]);
      }
      final origin = lineage!;
      final body = <Object>[
        2,
        _scope.storageKey,
        _generation,
        cloudSyncAttachmentOwnerKindHistorical,
        historicalIntentId,
        origin.messageGuidHash,
        origin.sourceSha256,
        origin.protectedStoreIdentity,
        origin.writerEpoch,
        inventory,
        children,
      ];
      final digest = sha256.convert(utf8.encode(jsonEncode(body))).toString();
      return jsonEncode(<Object>[...body, digest]);
    } finally {
      query.close();
    }
  }

  /// Revalidates a version-2 historical proof byte-for-byte like the legacy
  /// version-1 path. Version-1 proofs are rejected here.
  void requireHistoricalParentReadbackProof({
    required int historicalIntentId,
    required String proof,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(
    TxMode.read,
    () => _requireHistoricalParentReadbackProofLocked(
      historicalIntentId: historicalIntentId,
      proof: proof,
      historicalJournal: historicalJournal,
    ),
  );

  void _requireHistoricalParentReadbackProofLocked({
    required int historicalIntentId,
    required String proof,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) {
    final keys = _parseHistoricalParentProofKeys(proof, historicalIntentId);
    final recomputed = _captureHistoricalParentReadbackProofLocked(
      historicalIntentId: historicalIntentId,
      sourceAttachmentKeys: keys,
      historicalJournal: historicalJournal,
    );
    if (recomputed != proof) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
  }

  List<String> _parseHistoricalParentProofKeys(
    String proof,
    int historicalIntentId,
  ) {
    if (historicalIntentId <= 0 || proof.isEmpty || proof.length > 65536) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(proof);
    } on FormatException {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    if (decoded is! List || decoded.length != 12) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    bool digest(String? value) => value != null && _digest.hasMatch(value);
    bool token(String? value) => value != null && _token.hasMatch(value);
    if (decoded[0] is! int ||
        decoded[0] as int != 2 ||
        decoded[1] is! String ||
        (decoded[1] as String).isEmpty ||
        decoded[2] is! int ||
        (decoded[2] as int) <= 0 ||
        decoded[3] is! int ||
        (decoded[3] as int) != cloudSyncAttachmentOwnerKindHistorical ||
        decoded[4] is! int ||
        (decoded[4] as int) != historicalIntentId ||
        decoded[5] is! String ||
        !digest(decoded[5] as String) ||
        decoded[6] is! String ||
        !digest(decoded[6] as String) ||
        decoded[7] is! String ||
        !_storeIdentity.hasMatch(decoded[7] as String) ||
        decoded[8] is! int ||
        (decoded[8] as int) <= 0 ||
        decoded[9] is! List ||
        decoded[11] is! String ||
        !digest(decoded[11] as String)) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final rawKeys = decoded[9] as List;
    if (rawKeys.isEmpty ||
        rawKeys.length > 64 ||
        rawKeys.any((key) => key is! String || !token(key)) ||
        rawKeys.toSet().length != rawKeys.length) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final keys = rawKeys.cast<String>();
    final rawChildren = decoded[10];
    if (rawChildren is! List || rawChildren.length != keys.length) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    for (var index = 0; index < keys.length; index++) {
      final child = rawChildren[index];
      if (child is! List ||
          child.length != 6 ||
          child[0] is! int ||
          (child[0] as int) <= 0 ||
          child[1] is! String ||
          (child[1] as String) != keys[index] ||
          child[2] is! String ||
          !token(child[2] as String) ||
          child[3] is! String ||
          !digest(child[3] as String) ||
          child[4] is! String ||
          !_operationId.hasMatch(child[4] as String) ||
          child[5] is! int ||
          (child[5] as int) <= 0) {
        throw StateError('cloud_sync_attachment_upload_binding_changed');
      }
    }
    return <String>[...keys]..sort();
  }

  List<String> _requireParentProofInventory(Iterable<String> keys) {
    final list = keys.toList(growable: false);
    if (list.isEmpty ||
        list.length > 64 ||
        list.any((key) => !_token.hasMatch(key)) ||
        list.toSet().length != list.length) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    return <String>[...list]..sort();
  }

  List<String> _parseParentProofKeys(String proof, int localSendIntentId) {
    if (localSendIntentId <= 0 || proof.isEmpty || proof.length > 65536) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(proof);
    } on FormatException {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    if (decoded is! List || decoded.length != 11) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    bool digest(String? value) => value != null && _digest.hasMatch(value);
    bool token(String? value) => value != null && _token.hasMatch(value);
    if (decoded[0] is! int ||
        decoded[0] as int != 1 ||
        decoded[1] is! String ||
        (decoded[1] as String).isEmpty ||
        decoded[2] is! int ||
        (decoded[2] as int) <= 0 ||
        decoded[3] is! int ||
        (decoded[3] as int) != localSendIntentId ||
        decoded[4] is! String ||
        !digest(decoded[4] as String) ||
        decoded[5] is! String ||
        !digest(decoded[5] as String) ||
        decoded[6] is! String ||
        !_storeIdentity.hasMatch(decoded[6] as String) ||
        decoded[7] is! int ||
        (decoded[7] as int) <= 0 ||
        decoded[8] is! List ||
        decoded[10] is! String ||
        !digest(decoded[10] as String)) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final rawKeys = decoded[8] as List;
    if (rawKeys.isEmpty ||
        rawKeys.length > 64 ||
        rawKeys.any((key) => key is! String || !token(key)) ||
        rawKeys.toSet().length != rawKeys.length) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final keys = rawKeys.cast<String>();
    final rawChildren = decoded[9];
    if (rawChildren is! List || rawChildren.length != keys.length) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    for (var index = 0; index < keys.length; index++) {
      final child = rawChildren[index];
      if (child is! List ||
          child.length != 5 ||
          child[0] is! int ||
          (child[0] as int) <= 0 ||
          child[1] is! String ||
          (child[1] as String) != keys[index] ||
          child[2] is! String ||
          !token(child[2] as String) ||
          child[3] is! String ||
          !digest(child[3] as String) ||
          child[4] is! String ||
          !_operationId.hasMatch(child[4] as String)) {
        throw StateError('cloud_sync_attachment_upload_binding_changed');
      }
    }
    return <String>[...keys]..sort();
  }

  /// Requires the deterministic final-save outbox operation for an adopted
  /// upload to match its original result and to sit in the
  /// readback-acknowledged state. Identity drift throws the adoption failure;
  /// any final state short of released-after-readback (pending, leased,
  /// confirmed with the receipt lease still retained, unknown outcome, or a
  /// missing release-candidate identity) throws the readback failure.
  CloudOutboxOperationEntity _requireReadbackAcknowledgedFinalOperation(
    CloudAttachmentUploadEntity upload,
  ) => _readbackAcknowledgedFinalOperation(
    _store, upload, scope: _scope, generation: _generation);

  /// Recovery liveness only, never write authority. The result lease is also
  /// the final-save receipt. Exact verified readback releases that receipt;
  /// the immutable upload still retains its historical lease and payload.
  /// Reuse the parent proof predicate so a merely terminal/mismatched row
  /// cannot make a missing receipt acceptable. Works across account switches.
  static bool resultLeaseReleasedAfterReadback(
    Store store,
    CloudAttachmentUploadEntity upload,
  ) {
    validateCloudAttachmentUploadRow(upload);
    if (upload.state != CloudAttachmentUploadState.adopted.index) return false;
    final scope = CloudSyncScope(
      accountFingerprint: upload.accountFingerprint,
      container: 'com.apple.messages.cloud', database: 'private',
      zone: 'attachmentManateeZone', streamKind: CloudSyncStreamKind.messages,
      schemaVersion: 2, persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    try {
      _readbackAcknowledgedFinalOperation(store, upload,
        scope: scope, generation: upload.checkpointGeneration);
      return true;
    } on StateError catch (error) {
      if (error.message == 'cloud_sync_attachment_upload_adoption_changed' ||
          error.message == 'cloud_sync_attachment_upload_readback_not_ready') {
        return false; // Retain the lease requirement on incomplete proof.
      }
      rethrow;
    }
  }

  static CloudOutboxOperationEntity _readbackAcknowledgedFinalOperation(
    Store store,
    CloudAttachmentUploadEntity upload, {
    required CloudSyncScope scope,
    required int generation,
  }) {
    if (upload.admittedOperationId !=
        CloudOperationIdentity.forInitialCreate(
          scope: scope,
          logicalEntityKeyHash: upload.attachmentKeyHash,
          payloadVersion: 1,
        )) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    final query = store
        .box<CloudOutboxOperationEntity>()
        .query(
          CloudOutboxOperationEntity_.operationId.equals(
            upload.admittedOperationId!,
          ),
        )
        .build();
    final CloudOutboxOperationEntity? row;
    try {
      row = query.findUnique();
    } finally {
      query.close();
    }
    if (row == null ||
        row.action != CloudOutboxAction.save.index ||
        row.payloadVersion != 1 ||
        row.accountFingerprint != scope.accountFingerprint ||
        row.zone != scope.zone ||
        row.scopeKey != cloudSyncPersistentScopeKey(scope) ||
        row.checkpointGeneration != generation ||
        row.logicalEntityKeyHash != upload.attachmentKeyHash ||
        row.serverRecordIdHash != upload.serverRecordIdHash ||
        row.encryptedPayloadRef != upload.resultReference ||
        row.payloadSha256 != upload.resultPayloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    if (row.state != CloudOutboxStatus.confirmed.index ||
        row.protectedLeaseReference != null ||
        row.confirmedAtMs <= 0 ||
        row.leaseIdHash != null ||
        row.leaseExpiresAtMs != 0 ||
        row.nextEligibleAtMs != 0 ||
        row.lastErrorCategory != null ||
        row.appleRequestUuid == null ||
        row.appleOperationUuid == null ||
        !_appleUuid.hasMatch(row.appleRequestUuid!) ||
        !_appleUuid.hasMatch(row.appleOperationUuid!) ||
        row.appleRequestUuid == row.appleOperationUuid) {
      throw StateError('cloud_sync_attachment_upload_readback_not_ready');
    }
    return row;
  }

  CloudAttachmentUploadSnapshot adoptPlan({
      required int localSendIntentId,
      required CloudSyncProtectedOutboundStageData plan,
      required DateTime now,
      Set<String>? retainedSourceAttachmentKeys,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireGeneration();
    _validateStage(plan);
    if (retainedSourceAttachmentKeys != null) {
      // Validate the complete native inventory against all existing rows in
      // the same transaction. A stale/changed plan cannot disappear into a
      // missing-entry decision and authorize randomized replacement.
      findForAttachment(localSendIntentId: localSendIntentId,
          logicalEntityKeyHash: plan.logicalEntityKeyHash,
          sourceAttachmentKeys: retainedSourceAttachmentKeys);
      _localSends.requireCurrentAttachmentWriteAuthority(_store);
    }
    final origin = retainedSourceAttachmentKeys != null
        ? _localSends.requireRetainedAttachmentUploadOrigin(
            transactionStore: _store, intentId: localSendIntentId, currentAuth: _auth)
        : _localSends.requireConfirmedAttachmentUploadOrigin(
      transactionStore: _store,
      intentId: localSendIntentId,
      currentAuth: _auth,
    );
    // Neither record identity nor checkpoint generation is part of this key:
    // allocating a name or resetting sync cannot hide an earlier attempt.
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-attachment-upload-v1',
              _scope.storageKey,
              origin.source.messageGuidHash,
              origin.source.sourceSha256,
              plan.logicalEntityKeyHash,
            ]),
          ),
        )
        .toString();
    final query = _uploads
        .query(CloudAttachmentUploadEntity_.uploadKey.equals(key))
        .build();
    final CloudAttachmentUploadEntity? existing;
    try {
      existing = query.findUnique();
    } finally {
      query.close();
    }
    if (existing != null) {
      final row = _readBound(existing.id);
      if (row.ownerKind != cloudSyncAttachmentOwnerKindLocalSend) {
        throw StateError(cloudSyncAttachmentOwnerChangedCode);
      }
      if (row.localSendIntentId != localSendIntentId ||
          !_sameStage(_plan(row), plan)) {
        throw StateError('cloud_sync_attachment_upload_plan_changed');
      }
      return CloudAttachmentUploadSnapshot._(row);
    }
    final row = CloudAttachmentUploadEntity(
      uploadKey: key,
      accountFingerprint: _scope.accountFingerprint,
      writerEpoch: origin.writerEpoch,
      checkpointGeneration: _generation,
      localSendIntentId: localSendIntentId,
      ownerKind: cloudSyncAttachmentOwnerKindLocalSend,
      ownerIntentId: 0,
      messageGuidHash: origin.source.messageGuidHash,
      sourceSha256: origin.source.sourceSha256,
      protectedStoreIdentity: _auth.protectedStoreIdentity,
      attachmentKeyHash: plan.logicalEntityKeyHash,
      serverRecordIdHash: plan.serverRecordIdHash,
      planReference: plan.protectedEnvelopeReference,
      planLeaseReference: plan.leaseReference,
      planPayloadSha256: plan.payloadSha256,
      createdAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Adopts one historical attachment plan under a committed immutable
  /// source. Idempotent for the exact (intent, plan) pair; a same-key row
  /// from the other lane throws instead of being adopted over.
  CloudAttachmentUploadSnapshot adoptHistoricalPlan({
    required int historicalIntentId,
    required CloudSyncProtectedOutboundStageData plan,
    required DateTime now,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireGeneration();
    _validateStage(plan);
    if (historicalIntentId <= 0) {
      throw StateError(cloudSyncAttachmentOwnerChangedCode);
    }
    final intent = historicalJournal.requireHistoricalAttachmentOrigin(
      intentId: historicalIntentId,
      currentAuth: _auth,
    );
    if (!historicalJournal.isBoundToStore(_store) ||
        historicalJournal.accountFingerprint != _auth.accountFingerprint ||
        historicalJournal.protectedStoreIdentity !=
            _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final epoch = _requireHistoricalWriterEpoch();
    final key = _historicalUploadKey(
      messageGuidHash: intent.source.messageGuidHash,
      sourceSha256: intent.source.sourceSha256,
      logicalEntityKeyHash: plan.logicalEntityKeyHash,
      snapshotSha256: intent.source.snapshotSha256,
      ownerIntentId: historicalIntentId,
    );
    final query = _uploads
        .query(CloudAttachmentUploadEntity_.uploadKey.equals(key))
        .build();
    final CloudAttachmentUploadEntity? existing;
    try {
      existing = query.findUnique();
    } finally {
      query.close();
    }
    if (existing != null) {
      final row = _readHistoricalBound(existing.id, historicalJournal);
      if (row.ownerIntentId != historicalIntentId ||
          !_sameStage(_plan(row), plan)) {
        throw StateError('cloud_sync_attachment_upload_plan_changed');
      }
      return CloudAttachmentUploadSnapshot._(row);
    }
    final row = CloudAttachmentUploadEntity(
      uploadKey: key,
      accountFingerprint: _scope.accountFingerprint,
      writerEpoch: epoch,
      checkpointGeneration: _generation,
      localSendIntentId: 0,
      ownerKind: cloudSyncAttachmentOwnerKindHistorical,
      ownerIntentId: historicalIntentId,
      messageGuidHash: intent.source.messageGuidHash,
      sourceSha256: intent.source.sourceSha256,
      protectedStoreIdentity: _auth.protectedStoreIdentity,
      attachmentKeyHash: plan.logicalEntityKeyHash,
      serverRecordIdHash: plan.serverRecordIdHash,
      planReference: plan.protectedEnvelopeReference,
      planLeaseReference: plan.leaseReference,
      planPayloadSha256: plan.payloadSha256,
      createdAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Owner-scoped variant of [findForAttachment] for historical intents.
  /// Legacy local-send rows never match: the predicate carries the kind.
  CloudAttachmentUploadSnapshot? findHistoricalForAttachment({
    required int historicalIntentId,
    required String logicalEntityKeyHash,
    required Set<String> sourceAttachmentKeys,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireGeneration();
    final inventory = Set<String>.unmodifiable(sourceAttachmentKeys);
    if (historicalIntentId <= 0 ||
        inventory.isEmpty ||
        inventory.length > 64 ||
        inventory.any((key) => !_token.hasMatch(key)) ||
        !inventory.contains(logicalEntityKeyHash)) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.ownerKind
              .equals(cloudSyncAttachmentOwnerKindHistorical)
              .and(
                CloudAttachmentUploadEntity_.ownerIntentId.equals(
                  historicalIntentId,
                ),
              ),
        )
        .build();
    try {
      CloudAttachmentUploadSnapshot? selected;
      final seen = <String>{};
      for (final candidate in query.find()) {
        final row = _readHistoricalBound(candidate.id, historicalJournal);
        if (row.ownerKind != cloudSyncAttachmentOwnerKindHistorical ||
            row.ownerIntentId != historicalIntentId ||
            !inventory.contains(row.attachmentKeyHash) ||
            !seen.add(row.attachmentKeyHash)) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
        if (row.attachmentKeyHash == logicalEntityKeyHash) {
          selected = CloudAttachmentUploadSnapshot._(row);
        }
      }
      return selected;
    } finally {
      query.close();
    }
  });

  /// Availability preflight only, not parent admission or retry authority.
  /// Prepared plans still need original bytes. Every attempted child must have
  /// exact, fully released readback before a different missing file can defer
  /// the containing message. The caller separately commits prepared leases.
  bool historicalUploadNeedsLocalSource(
    int id,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) => _store.runInTransaction(TxMode.read, () {
    final row = _readHistoricalBound(id, historicalJournal);
    if (row.state == CloudAttachmentUploadState.prepared.index &&
        row.attemptId == null && row.resultReference == null &&
        row.admittedOperationId == null) {
      return true;
    }
    if (row.state != CloudAttachmentUploadState.adopted.index) {
      throw StateError('cloud_sync_attachment_parent_upload_unresolved');
    }
    _requireReadbackAcknowledgedFinalOperation(row);
    return false;
  });

  /// Committed immutable source for a historical upload row. Never resolves
  /// through the local-send journal.
  CloudSyncHistoricalProtectedSourceBinding readHistoricalOriginalSource(
    int id,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) => _store.runInTransaction(TxMode.read, () {
    final row = _readHistoricalBound(id, historicalJournal);
    return _requireHistoricalRowSource(row, historicalJournal);
  });

  /// First byte attempt on an exact retained historical prepared upload.
  CloudAttachmentUploadSnapshot beginHistoricalAttempt({
    required int id,
    required String attemptId,
    required DateTime now,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
    Set<String>? retainedSourceAttachmentKeys,
  }) => _store.runInTransaction(TxMode.write, () {
    if (!_uuid.hasMatch(attemptId)) {
      throw StateError('cloud_sync_attachment_upload_attempt_invalid');
    }
    final row = _readHistoricalBound(id, historicalJournal);
    if (row.state != CloudAttachmentUploadState.prepared.index) {
      throw StateError('cloud_sync_attachment_upload_already_attempted');
    }
    final epoch = _requireHistoricalWriterEpoch();
    if (retainedSourceAttachmentKeys == null && epoch != row.writerEpoch) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
    if (retainedSourceAttachmentKeys != null) {
      // Recovery may advance authority, but never rewrites the original plan
      // epoch. An unattempted plan can proceed only with its complete original
      // inventory and a fresh current permit. Started/unknown rows never enter.
      final keys = _requireParentProofInventory(retainedSourceAttachmentKeys).toSet();
      for (final key in keys) {
        if (findHistoricalForAttachment(historicalIntentId: row.ownerIntentId,
            logicalEntityKeyHash: key, sourceAttachmentKeys: keys,
            historicalJournal: historicalJournal) == null) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
      }
    }
    row
      ..state = CloudAttachmentUploadState.started.index
      ..attemptId = attemptId
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Historical variant of [recordUploaded]: adopts only the native-validated
  /// result from this exact attempt on a historical row.
  CloudAttachmentUploadSnapshot recordHistoricalUploaded({
    required int id,
    required String attemptId,
    required CloudSyncProtectedOutboundStageData result,
    required DateTime now,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readHistoricalBound(id, historicalJournal);
    _validateStage(result);
    if (row.attemptId != attemptId ||
        result.logicalEntityKeyHash != row.attachmentKeyHash ||
        result.serverRecordIdHash != row.serverRecordIdHash) {
      throw StateError('cloud_sync_attachment_upload_result_changed');
    }
    if (row.state == CloudAttachmentUploadState.uploaded.index ||
        row.state == CloudAttachmentUploadState.adopted.index) {
      if (!_sameStage(_result(row), result)) {
        throw StateError('cloud_sync_attachment_upload_result_changed');
      }
      return CloudAttachmentUploadSnapshot._(row);
    }
    if (row.state != CloudAttachmentUploadState.started.index &&
        row.state != CloudAttachmentUploadState.unknown.index) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    row
      ..state = CloudAttachmentUploadState.uploaded.index
      ..resultReference = result.protectedEnvelopeReference
      ..resultLeaseReference = result.leaseReference
      ..resultPayloadSha256 = result.payloadSha256
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Historical variant of [markUnknown] for ambiguous historical attempts.
  void markHistoricalUnknown({
    required int id,
    required String attemptId,
    required DateTime now,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readHistoricalBound(id, historicalJournal);
    if (row.attemptId != attemptId) {
      throw StateError('cloud_sync_attachment_upload_attempt_changed');
    }
    if (row.state == CloudAttachmentUploadState.uploaded.index ||
        row.state == CloudAttachmentUploadState.adopted.index) {
      return;
    }
    if (row.state != CloudAttachmentUploadState.started.index &&
        row.state != CloudAttachmentUploadState.unknown.index) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    row
      ..state = CloudAttachmentUploadState.unknown.index
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
  });

  /// Historical variant of [read]: bound historical snapshot by upload id.
  CloudAttachmentUploadSnapshot readHistorical(
    int id,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) => _store.runInTransaction(
    TxMode.read,
    () => CloudAttachmentUploadSnapshot._(
      _readHistoricalBound(id, historicalJournal),
    ),
  );

  /// Historical variant of [reconciliationBindingSha256]: identical digest
  /// material resolved through the historical bound reader.
  String reconciliationHistoricalBindingSha256(
    int id,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) => _store.runInTransaction(TxMode.read, () {
    final row = _readHistoricalBound(id, historicalJournal);
    if (row.state == CloudAttachmentUploadState.prepared.index ||
        row.attemptId == null ||
        !_uuid.hasMatch(row.attemptId!)) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-attachment-upload-reconciliation-v1',
              _scope.storageKey,
              row.writerEpoch,
              row.checkpointGeneration,
              row.protectedStoreIdentity,
              row.messageGuidHash,
              row.sourceSha256,
              row.uploadKey,
              row.attachmentKeyHash,
              row.serverRecordIdHash,
              row.planReference,
              row.planLeaseReference,
              row.planPayloadSha256,
              row.attemptId,
            ]),
          ),
        )
        .toString();
  });

  /// First byte attempt on an exact retained prepared upload after writer
  /// recovery. The complete original inventory must be presented and match;
  /// nothing is staged here. The retained source plus a current-epoch write
  /// permit in this same transaction authorize the attempt. Unknown,
  /// started, uploaded, and adopted rows keep their existing refusals, and
  /// the strict [beginAttempt] is unchanged.
  CloudAttachmentUploadSnapshot beginRetainedAttempt({
    required int id,
    required String attemptId,
    required Iterable<String> sourceAttachmentKeys,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    if (!_uuid.hasMatch(attemptId)) {
      throw StateError('cloud_sync_attachment_upload_attempt_invalid');
    }
    _requireLocalId(id);
    final row = _readBound(id);
    if (row.state != CloudAttachmentUploadState.prepared.index) {
      throw StateError('cloud_sync_attachment_upload_already_attempted');
    }
    _requireLocalRow(row);
    _requireCompleteRetainedInventory(
      row.localSendIntentId,
      sourceAttachmentKeys,
    );
    final origin = _localSends.requireRetainedAttachmentUploadOrigin(
      transactionStore: _store,
      intentId: row.localSendIntentId,
      currentAuth: _auth,
    );
    if (origin.writerEpoch != row.writerEpoch) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
    _localSends.requireCurrentAttachmentWriteAuthority(_store);
    row
      ..state = CloudAttachmentUploadState.started.index
      ..attemptId = attemptId
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Complete-inventory gate over retained rows: every retained plan for the
  /// intent must match the presented inventory with no missing, extra, or
  /// duplicate keys and shared lineage. Returns the rows ordered by key.
  /// Mirrors the capture inventory checks without adoption or outbox state.
  List<CloudAttachmentUploadEntity> _requireCompleteRetainedInventory(
    int intentId,
    Iterable<String> sourceAttachmentKeys,
  ) {
    final inventory = _requireParentProofInventory(sourceAttachmentKeys);
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.localSendIntentId.equals(intentId),
        )
        .build();
    try {
      final retained = query.find();
      if (retained.isEmpty) {
        throw StateError('cloud_sync_attachment_upload_inventory_changed');
      }
      final seen = <String>{};
      CloudAttachmentUploadEntity? lineage;
      for (final candidate in retained) {
        final row = _readBound(candidate.id);
        if (row.localSendIntentId != intentId ||
            !inventory.contains(row.attachmentKeyHash) ||
            !seen.add(row.attachmentKeyHash)) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
        if (lineage == null) {
          lineage = row;
        } else if (lineage.messageGuidHash != row.messageGuidHash ||
            lineage.sourceSha256 != row.sourceSha256 ||
            lineage.protectedStoreIdentity != row.protectedStoreIdentity ||
            lineage.writerEpoch != row.writerEpoch) {
          throw StateError('cloud_sync_attachment_upload_binding_changed');
        }
      }
      if (seen.length != inventory.length) {
        throw StateError('cloud_sync_attachment_upload_inventory_changed');
      }
      final ordered = retained.map((candidate) => _readBound(candidate.id)).toList()
        ..sort((a, b) => a.attachmentKeyHash.compareTo(b.attachmentKeyHash));
      return ordered;
    } finally {
      query.close();
    }
  }

  CloudAttachmentUploadSnapshot read(int id) => _store.runInTransaction(
    TxMode.read,
    () => CloudAttachmentUploadSnapshot._(_readBound(id)),
  );

  /// Resolve the original plan BEFORE any new randomized preparation. The
  /// caller derives this key from the protected IDS source, never a mutable
  /// display GUID. Deliberately do not filter by generation: a stale retained
  /// row must fail validation instead of disappearing and permitting a duplicate.
  CloudAttachmentUploadSnapshot? findForAttachment({
    required int localSendIntentId,
    required String logicalEntityKeyHash,
    required Set<String> sourceAttachmentKeys,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireGeneration();
    final inventory = Set<String>.unmodifiable(sourceAttachmentKeys);
    if (localSendIntentId <= 0 ||
        inventory.isEmpty ||
        inventory.length > 64 ||
        inventory.any((key) => !_token.hasMatch(key)) ||
        !inventory.contains(logicalEntityKeyHash)) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.localSendIntentId.equals(
            localSendIntentId,
          ),
        )
        .build();
    try {
      // Inspect all plans for this original source. After an identity-codec
      // repair, a previously keyed plan must not disappear from an exact-key
      // lookup and accidentally authorize a second upload for the same bytes.
      // The complete inventory comes from the committed native source.
      CloudAttachmentUploadSnapshot? selected;
      final seen = <String>{};
      for (final candidate in query.find()) {
        final row = _readBound(candidate.id);
        if (!inventory.contains(row.attachmentKeyHash) ||
            !seen.add(row.attachmentKeyHash)) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
        if (row.attachmentKeyHash == logicalEntityKeyHash) {
          selected = CloudAttachmentUploadSnapshot._(row);
        }
      }
      return selected;
    } finally {
      query.close();
    }
  });

  /// Deterministic byte-upload reconciliation binding over the original
  /// envelope (scope, writer epoch, generation, store identity, local
  /// source, upload key, attachment identity, plan, attempt). Result,
  /// state, and admitted operation never enter the hash. Requires an
  /// attempted row; byte reconciliation never touches the record outbox.
  String reconciliationBindingSha256(int id) =>
      _store.runInTransaction(TxMode.read, () {
        final row = _readBound(id);
        if (row.state == CloudAttachmentUploadState.prepared.index ||
            row.attemptId == null ||
            !_uuid.hasMatch(row.attemptId!)) {
          throw StateError('cloud_sync_attachment_upload_not_started');
        }
        return sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  'cloud-sync-attachment-upload-reconciliation-v1',
                  _scope.storageKey,
                  row.writerEpoch,
                  row.checkpointGeneration,
                  row.protectedStoreIdentity,
                  row.messageGuidHash,
                  row.sourceSha256,
                  row.uploadKey,
                  row.attachmentKeyHash,
                  row.serverRecordIdHash,
                  row.planReference,
                  row.planLeaseReference,
                  row.planPayloadSha256,
                  row.attemptId,
                ]),
              ),
            )
            .toString();
      });

  /// No idempotent repeat is returned as another consumable attempt. If the
  /// caller cannot observe this transaction, it must inspect/recover, not send.
  CloudAttachmentUploadSnapshot beginAttempt({
    required int id,
    required String attemptId,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    if (!_uuid.hasMatch(attemptId)) {
      throw StateError('cloud_sync_attachment_upload_attempt_invalid');
    }
    _requireLocalId(id);
    final row = _readBound(id);
    if (row.state != CloudAttachmentUploadState.prepared.index) {
      throw StateError('cloud_sync_attachment_upload_already_attempted');
    }
    _requireLocalRow(row);
    // Reading retained evidence across a writer recovery never grants a new
    // byte attempt under an old epoch. Preparation remains strictly current.
    final origin = _localSends.requireConfirmedAttachmentUploadOrigin(
      transactionStore: _store,
      intentId: row.localSendIntentId,
      currentAuth: _auth,
    );
    if (origin.writerEpoch != row.writerEpoch) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
    _localSends.requireCurrentAttachmentWriteAuthority(_store);
    row
      ..state = CloudAttachmentUploadState.started.index
      ..attemptId = attemptId
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Adopt only the native-validated result from this exact attempt. This is
  /// upload evidence, not remote-record success. Lease commit follows outside
  /// the transaction and can be retried without any upload network request.
  CloudAttachmentUploadSnapshot recordUploaded({
    required int id,
    required String attemptId,
    required CloudSyncProtectedOutboundStageData result,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readBound(id);
    _validateStage(result);
    if (row.attemptId != attemptId ||
        result.logicalEntityKeyHash != row.attachmentKeyHash ||
        result.serverRecordIdHash != row.serverRecordIdHash) {
      throw StateError('cloud_sync_attachment_upload_result_changed');
    }
    if (row.state == CloudAttachmentUploadState.uploaded.index ||
        row.state == CloudAttachmentUploadState.adopted.index) {
      if (!_sameStage(_result(row), result)) {
        throw StateError('cloud_sync_attachment_upload_result_changed');
      }
      return CloudAttachmentUploadSnapshot._(row);
    }
    // Unknown may receive a late authenticated receipt for the SAME attempt.
    // It never creates a new attempt or accepts a record-absence observation.
    if (row.state != CloudAttachmentUploadState.started.index &&
        row.state != CloudAttachmentUploadState.unknown.index) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    row
      ..state = CloudAttachmentUploadState.uploaded.index
      ..resultReference = result.protectedEnvelopeReference
      ..resultLeaseReference = result.leaseReference
      ..resultPayloadSha256 = result.payloadSha256
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  void markUnknown({
    required int id,
    required String attemptId,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readBound(id);
    if (row.attemptId != attemptId) {
      throw StateError('cloud_sync_attachment_upload_attempt_changed');
    }
    if (row.state == CloudAttachmentUploadState.uploaded.index ||
        row.state == CloudAttachmentUploadState.adopted.index) {
      return;
    }
    if (row.state != CloudAttachmentUploadState.started.index &&
        row.state != CloudAttachmentUploadState.unknown.index) {
      throw StateError('cloud_sync_attachment_upload_not_started');
    }
    row
      ..state = CloudAttachmentUploadState.unknown.index
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
  });

  /// Runs final-envelope outbox admission in this SAME transaction. The
  /// callback performs the existing record-map/dependency admission, never
  /// network I/O. Throwing or returning an unpersisted/different envelope
  /// rolls back both sides. Recovery does not invoke the callback a second time.
  CloudAttachmentUploadSnapshot adoptRecordCreate({
    required int id,
    required CloudOutboxOperation Function(
      Store transactionStore,
      CloudSyncProtectedOutboundStageData result,
    )
    admit,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireLocalId(id);
    final row = _readBound(id);
    if (row.state == CloudAttachmentUploadState.adopted.index) {
      _requireFinalOperation(row, row.admittedOperationId!);
      return CloudAttachmentUploadSnapshot._(row);
    }
    if (row.state != CloudAttachmentUploadState.uploaded.index) {
      throw StateError('cloud_sync_attachment_upload_result_missing');
    }
    _localSends.requireCurrentAttachmentWriteAuthority(_store);
    final operation = admit(_store, _result(row));
    if (operation.scope != _scope ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != 1 ||
        operation.checkpointGeneration != _generation ||
        operation.logicalEntityKeyHash != row.attachmentKeyHash ||
        operation.serverRecordIdHash != row.serverRecordIdHash ||
        operation.encryptedPayloadReference != row.resultReference ||
        operation.protectedLeaseReference != row.resultLeaseReference ||
        operation.payloadSha256 != row.resultPayloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    _requireFinalOperation(row, operation.operationId);
    row
      ..state = CloudAttachmentUploadState.adopted.index
      ..admittedOperationId = operation.operationId
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Historical variant of [adoptRecordCreate]: runs final-envelope outbox
  /// admission for an uploaded historical row in the same transaction.
  /// Authority and origin resolve historically; the admit callback performs
  /// the existing record-map admission supplied by the caller.
  CloudAttachmentUploadSnapshot adoptHistoricalRecordCreate({
    required int id,
    required CloudOutboxOperation Function(
      Store transactionStore,
      CloudSyncProtectedOutboundStageData result,
    )
    admit,
    required DateTime now,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(TxMode.write, () {
    final row = _readHistoricalBound(id, historicalJournal);
    if (row.state == CloudAttachmentUploadState.adopted.index) {
      _requireFinalOperation(row, row.admittedOperationId!);
      return CloudAttachmentUploadSnapshot._(row);
    }
    if (row.state != CloudAttachmentUploadState.uploaded.index) {
      throw StateError('cloud_sync_attachment_upload_result_missing');
    }
    _requireHistoricalWriterEpoch();
    final operation = admit(_store, _result(row));
    if (operation.scope != _scope ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != 1 ||
        operation.checkpointGeneration != _generation ||
        operation.logicalEntityKeyHash != row.attachmentKeyHash ||
        operation.serverRecordIdHash != row.serverRecordIdHash ||
        operation.encryptedPayloadReference != row.resultReference ||
        operation.protectedLeaseReference != row.resultLeaseReference ||
        operation.payloadSha256 != row.resultPayloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    _requireFinalOperation(row, operation.operationId);
    row
      ..state = CloudAttachmentUploadState.adopted.index
      ..admittedOperationId = operation.operationId
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _uploads.put(row);
    return CloudAttachmentUploadSnapshot._(row);
  });

  /// Historical variant of [requireAdoptedOperation] for dispatch-time
  /// revalidation of an adopted historical upload.
  void requireHistoricalAdoptedOperation(
    CloudOutboxOperation operation,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) {
    _requireHistoricalWriterEpoch();
    if (operation.scope != _scope ||
        operation.checkpointGeneration != _generation) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final query = _uploads
        .query(
          CloudAttachmentUploadEntity_.admittedOperationId.equals(
            operation.operationId,
          ),
        )
        .build();
    final CloudAttachmentUploadEntity? candidate;
    try {
      candidate = query.findUnique();
    } finally {
      query.close();
    }
    if (candidate == null) {
      throw StateError('cloud_sync_attachment_upload_origin_missing');
    }
    final row = _readHistoricalBound(candidate.id, historicalJournal);
    if (row.state != CloudAttachmentUploadState.adopted.index ||
        row.attachmentKeyHash != operation.logicalEntityKeyHash ||
        row.serverRecordIdHash != operation.serverRecordIdHash ||
        row.resultReference != operation.encryptedPayloadReference ||
        row.resultPayloadSha256 != operation.payloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    _requireFinalOperation(row, operation.operationId);
  }

  /// Exact retained record origin for preparation and lookup-only recovery.
  /// Unlike dispatch, this must remain readable while a mutation is uncertain.
  /// It neither issues a writer permit nor promotes a historical source to IDS.
  CloudSyncHistoricalProtectedSourceBinding readHistoricalAdoptedSource(
    CloudOutboxOperation operation,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) => _store.runInTransaction(TxMode.read, () {
    if (operation.scope != _scope || operation.checkpointGeneration != _generation) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final query = _uploads.query(CloudAttachmentUploadEntity_.admittedOperationId
        .equals(operation.operationId)).build();
    final CloudAttachmentUploadEntity? candidate;
    try { candidate = query.findUnique(); } finally { query.close(); }
    if (candidate == null) {
      throw StateError('cloud_sync_attachment_upload_origin_missing');
    }
    final row = _readHistoricalBound(candidate.id, historicalJournal);
    if (row.state != CloudAttachmentUploadState.adopted.index ||
        row.attachmentKeyHash != operation.logicalEntityKeyHash ||
        row.serverRecordIdHash != operation.serverRecordIdHash ||
        row.resultReference != operation.encryptedPayloadReference ||
        row.resultPayloadSha256 != operation.payloadSha256) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    _requireFinalOperation(row, operation.operationId);
    return readHistoricalOriginalSource(row.id, historicalJournal);
  });

  /// Owner-scoped variant of [readAttemptedForReconciliation]: pending
  /// historical evidence only, capped like the legacy path.
  List<int> readHistoricalAttemptedForReconciliation({
    int? historicalIntentId,
    required CloudSyncHistoricalArchiveJournal historicalJournal,
  }) => _store.runInTransaction(TxMode.read, () {
    if (historicalIntentId != null && historicalIntentId <= 0) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    _requireGeneration();
    var condition = CloudAttachmentUploadEntity_.accountFingerprint
        .equals(_scope.accountFingerprint)
        .and(CloudAttachmentUploadEntity_.protectedStoreIdentity
            .equals(_auth.protectedStoreIdentity))
        .and(CloudAttachmentUploadEntity_.checkpointGeneration
            .equals(_generation))
        .and(CloudAttachmentUploadEntity_.ownerKind
            .equals(cloudSyncAttachmentOwnerKindHistorical))
        .and(CloudAttachmentUploadEntity_.state
            .notEquals(CloudAttachmentUploadState.uploaded.index))
        .and(CloudAttachmentUploadEntity_.state
            .notEquals(CloudAttachmentUploadState.adopted.index))
        .and(CloudAttachmentUploadEntity_.state
            .notEquals(CloudAttachmentUploadState.prepared.index)
            .or(CloudAttachmentUploadEntity_.attemptId.notNull()));
    if (historicalIntentId != null) {
      condition = condition.and(
        CloudAttachmentUploadEntity_.ownerIntentId.equals(historicalIntentId),
      );
    }
    final query = _uploads.query(condition).build()..limit = 65;
    try {
      final candidates = query.find();
      if (candidates.length > 64) {
        throw StateError('cloud_sync_attachment_upload_recovery_bound_exceeded');
      }
      final keys = <String>{};
      final ids = <int>[];
      for (final candidate in candidates) {
        final row = _readHistoricalBound(candidate.id, historicalJournal);
        if (row.ownerKind != cloudSyncAttachmentOwnerKindHistorical ||
            (historicalIntentId != null &&
                row.ownerIntentId != historicalIntentId)) {
          throw StateError(cloudSyncAttachmentOwnerChangedCode);
        }
        if (!keys.add(row.uploadKey)) {
          throw StateError('cloud_sync_attachment_upload_inventory_changed');
        }
        reconciliationHistoricalBindingSha256(row.id, historicalJournal);
        ids.add(row.id);
      }
      return List<int>.unmodifiable(ids);
    } finally {
      query.close();
    }
  });

  void _requireFinalOperation(
    CloudAttachmentUploadEntity upload,
    String operationId,
  ) {
    final query = _store
        .box<CloudOutboxOperationEntity>()
        .query(CloudOutboxOperationEntity_.operationId.equals(operationId))
        .build();
    final CloudOutboxOperationEntity? row;
    try {
      row = query.findUnique();
    } finally {
      query.close();
    }
    if (operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: _scope,
              logicalEntityKeyHash: upload.attachmentKeyHash,
              payloadVersion: 1,
            ) ||
        row == null ||
        row.action != CloudOutboxAction.save.index ||
        row.payloadVersion != 1 ||
        row.accountFingerprint != _scope.accountFingerprint ||
        row.zone != _scope.zone ||
        row.scopeKey != cloudSyncPersistentScopeKey(_scope) ||
        row.checkpointGeneration != _generation ||
        row.logicalEntityKeyHash != upload.attachmentKeyHash ||
        row.serverRecordIdHash != upload.serverRecordIdHash ||
        row.encryptedPayloadRef != upload.resultReference ||
        row.payloadSha256 != upload.resultPayloadSha256 ||
        (row.protectedLeaseReference != upload.resultLeaseReference &&
            !(upload.state == CloudAttachmentUploadState.adopted.index &&
                row.state == CloudOutboxStatus.confirmed.index &&
                row.protectedLeaseReference == null))) {
      throw StateError('cloud_sync_attachment_upload_adoption_changed');
    }
    if (upload.state != CloudAttachmentUploadState.adopted.index &&
        (row.state != CloudOutboxStatus.pending.index ||
            row.attemptCount != 0 ||
            row.leaseIdHash != null ||
            row.appleRequestUuid != null ||
            row.appleOperationUuid != null)) {
      throw StateError(
        'cloud_sync_attachment_upload_adoption_already_submitted',
      );
    }
  }

  void _requireGeneration() {
    final query = _store
        .box<CloudSyncCheckpointEntity>()
        .query(
          CloudSyncCheckpointEntity_.checkpointKey.equals(
            cloudSyncPersistentScopeKey(_scope),
          ),
        )
        .build();
    final CloudSyncCheckpointEntity? checkpoint;
    try {
      checkpoint = query.findUnique();
    } finally {
      query.close();
    }
    if (checkpoint == null || checkpoint.generation != _generation) {
      throw StateError('cloud_sync_attachment_upload_generation_changed');
    }
  }

  /// Historical-owner helpers. Same durable table and mechanics as the IDS
  /// paths, keyed by (ownerKind historical, ownerIntentId). Origin authority
  /// resolves through the caller-supplied historical archive journal against
  /// a committed immutable source; writer ownership resolves through
  /// [writerAuthority]. Historical sent/received share the journal;
  /// direction stays a message-request property enforced at admission, never
  /// an upload-row claim. Legacy methods reject historical rows instead of
  /// reinterpreting their ids.
  int _requireHistoricalWriterEpoch() {
    final authority = writerAuthority;
    if (authority == null) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final scope = CloudKitWriterScope(
      accountFingerprint: _scope.accountFingerprint,
    );
    final epoch = _readHistoricalEpoch(authority, scope);
    authority.issuePermit(scope, expectedOwner: CloudKitWriterOwner.v2);
    return epoch;
  }

  /// Read-only writer-epoch check shared by historical evidence reads.
  /// Reads tolerate a newer authority epoch (recovery evidence), unlike
  /// mutation attempts, which pin the exact current epoch at their own site.
  int _readHistoricalEpoch(
    ObjectBoxCloudKitWriterAuthority authority,
    CloudKitWriterScope scope,
  ) {
    if (!authority.isBoundToStore(_store)) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final current = authority.read(scope);
    if (current == null ||
        current.owner != CloudKitWriterOwner.v2 ||
        current.targetOwner != CloudKitWriterOwner.none ||
        current.transitionIdHash != null ||
        (current.state != CloudKitWriterAuthorityState.stable &&
            current.state != CloudKitWriterAuthorityState.mutationUnknown)) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    return current.epoch;
  }

  /// Kind-tagged upload identity: scope, owner lane, owning snapshot and
  /// intent, source lineage, and attachment key. Legacy IDS keys keep their
  /// exact five-slot material; only historical rows carry the lane tag.
  String _historicalUploadKey({
    required String messageGuidHash,
    required String sourceSha256,
    required String logicalEntityKeyHash,
    required String snapshotSha256,
    required int ownerIntentId,
  }) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'cloud-sync-attachment-upload-v1',
            _scope.storageKey,
            cloudSyncAttachmentOwnerKindHistorical,
            snapshotSha256,
            ownerIntentId,
            messageGuidHash,
            sourceSha256,
            logicalEntityKeyHash,
          ]),
        ),
      )
      .toString();

  CloudSyncHistoricalProtectedSourceBinding _requireHistoricalRowSource(
    CloudAttachmentUploadEntity row,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) {
    if (!historicalJournal.isBoundToStore(_store) ||
        historicalJournal.accountFingerprint != _auth.accountFingerprint ||
        historicalJournal.protectedStoreIdentity !=
            _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final intent = historicalJournal.requireHistoricalAttachmentOrigin(
      intentId: row.ownerIntentId,
      currentAuth: _auth,
    );
    if (intent.source.messageGuidHash != row.messageGuidHash ||
        intent.source.sourceSha256 != row.sourceSha256) {
      throw StateError(cloudSyncAttachmentOwnerChangedCode);
    }
    return intent.source;
  }

  CloudAttachmentUploadEntity _readHistoricalBound(
    int id,
    CloudSyncHistoricalArchiveJournal historicalJournal,
  ) {
    _requireGeneration();
    final row = id > 0 ? _uploads.get(id) : null;
    if (row == null ||
        row.accountFingerprint != _scope.accountFingerprint ||
        row.checkpointGeneration != _generation ||
        row.protectedStoreIdentity != _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    validateCloudAttachmentUploadRow(row);
    if (row.ownerKind != cloudSyncAttachmentOwnerKindHistorical ||
        row.ownerIntentId <= 0) {
      throw StateError(cloudSyncAttachmentOwnerChangedCode);
    }
    final source = _requireHistoricalRowSource(row, historicalJournal);
    final authority = writerAuthority;
    if (authority == null) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    final epoch = _readHistoricalEpoch(
      authority,
      CloudKitWriterScope(accountFingerprint: _scope.accountFingerprint),
    );
    if (epoch < row.writerEpoch) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
    final expectedKey = _historicalUploadKey(
      messageGuidHash: row.messageGuidHash,
      sourceSha256: row.sourceSha256,
      logicalEntityKeyHash: row.attachmentKeyHash,
      snapshotSha256: source.snapshotSha256,
      ownerIntentId: row.ownerIntentId,
    );
    if (row.uploadKey != expectedKey) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    return row;
  }

  CloudAttachmentUploadEntity _readBound(int id) {
    _requireGeneration();
    final row = id > 0 ? _uploads.get(id) : null;
    if (row == null ||
        row.accountFingerprint != _scope.accountFingerprint ||
        row.checkpointGeneration != _generation ||
        row.protectedStoreIdentity != _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    validateCloudAttachmentUploadRow(row);
    _requireLocalRow(row);
    final origin = _localSends.readConfirmedOriginForExistingUpload(
      transactionStore: _store,
      uploadId: row.id,
      currentAuth: _auth,
    );
    if (origin.writerEpoch != row.writerEpoch ||
        origin.source.messageGuidHash != row.messageGuidHash ||
        origin.source.sourceSha256 != row.sourceSha256) {
      throw StateError('cloud_sync_attachment_upload_origin_changed');
    }
    final expectedKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-attachment-upload-v1',
              _scope.storageKey,
              row.messageGuidHash,
              row.sourceSha256,
              row.attachmentKeyHash,
            ]),
          ),
        )
        .toString();
    if (row.uploadKey != expectedKey) {
      throw StateError('cloud_sync_attachment_upload_binding_changed');
    }
    return row;
  }
}

/// Used by protected-store recovery even when the account/owner changed.
/// Malformed metadata blocks cleanup rather than discarding retained keys.
void validateCloudAttachmentUploadRow(CloudAttachmentUploadEntity row) {
  final historical =
      row.ownerKind == cloudSyncAttachmentOwnerKindHistorical;
  if (row.ownerKind != cloudSyncAttachmentOwnerKindLocalSend &&
      !historical) {
    throw StateError('cloud_sync_attachment_upload_row_invalid');
  }
  if (row.state < 0 ||
      row.state >= CloudAttachmentUploadState.values.length ||
      (historical
          ? row.localSendIntentId != 0 || row.ownerIntentId <= 0
          : row.localSendIntentId <= 0 || row.ownerIntentId != 0) ||
      row.writerEpoch <= 0 ||
      row.checkpointGeneration <= 0 ||
      !_digest.hasMatch(row.uploadKey) ||
      !_token.hasMatch(row.accountFingerprint) ||
      !_digest.hasMatch(row.messageGuidHash) ||
      !_digest.hasMatch(row.sourceSha256) ||
      !RegExp(
        r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
      ).hasMatch(row.protectedStoreIdentity)) {
    throw StateError('cloud_sync_attachment_upload_row_invalid');
  }
  _validateStage(_plan(row));
  final hasResult =
      row.state == CloudAttachmentUploadState.uploaded.index ||
      row.state == CloudAttachmentUploadState.adopted.index;
  if ((row.state == CloudAttachmentUploadState.prepared.index
          ? row.attemptId != null
          : !_uuid.hasMatch(row.attemptId ?? '')) ||
      (hasResult
          ? row.resultReference == null ||
                row.resultLeaseReference == null ||
                row.resultPayloadSha256 == null
          : row.resultReference != null ||
                row.resultLeaseReference != null ||
                row.resultPayloadSha256 != null) ||
      (row.state == CloudAttachmentUploadState.adopted.index
          ? !_operationId.hasMatch(row.admittedOperationId ?? '')
          : row.admittedOperationId != null)) {
    throw StateError('cloud_sync_attachment_upload_row_invalid');
  }
  if (hasResult) _validateStage(_result(row));
}

final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _digest = RegExp(r'^[a-f0-9]{64}$');
final _operationId = RegExp(r'^op1:[a-f0-9]{64}$');
final _storeIdentity = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
final _appleUuid = RegExp(
  r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
);
final _uuid = RegExp(
  r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$',
);
void _validateStage(CloudSyncProtectedOutboundStageData stage) {
  if (!_token.hasMatch(stage.logicalEntityKeyHash) ||
      !_token.hasMatch(stage.serverRecordIdHash) ||
      !_digest.hasMatch(stage.payloadSha256) ||
      !RegExp(
        r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
      ).hasMatch(stage.protectedEnvelopeReference) ||
      !RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(stage.leaseReference)) {
    throw StateError('cloud_sync_attachment_upload_stage_invalid');
  }
}

CloudSyncProtectedOutboundStageData _plan(CloudAttachmentUploadEntity row) =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: row.attachmentKeyHash,
      protectedEnvelopeReference: row.planReference,
      payloadSha256: row.planPayloadSha256,
      serverRecordIdHash: row.serverRecordIdHash,
      leaseReference: row.planLeaseReference,
    );
CloudSyncProtectedOutboundStageData _result(CloudAttachmentUploadEntity row) =>
    CloudSyncProtectedOutboundStageData(
      logicalEntityKeyHash: row.attachmentKeyHash,
      protectedEnvelopeReference: row.resultReference!,
      payloadSha256: row.resultPayloadSha256!,
      serverRecordIdHash: row.serverRecordIdHash,
      leaseReference: row.resultLeaseReference!,
    );
bool _sameStage(
  CloudSyncProtectedOutboundStageData a,
  CloudSyncProtectedOutboundStageData b,
) =>
    a.logicalEntityKeyHash == b.logicalEntityKeyHash &&
    a.serverRecordIdHash == b.serverRecordIdHash &&
    a.payloadSha256 == b.payloadSha256 &&
    a.protectedEnvelopeReference == b.protectedEnvelopeReference &&
    a.leaseReference == b.leaseReference;
