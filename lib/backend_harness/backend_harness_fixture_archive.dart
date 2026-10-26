import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_message_archive_recovery_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_mutation_lineage.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_message_dependency.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:crypto/crypto.dart';

/// Observation of retained evidence only. No native calls, permits, queue
/// transitions or fresh cloud reads. The caller fences native identity/store
/// before and after this synchronous read transaction.
Map<String, bool> backendFixtureArchiveAbsentFlags({bool uncertain = false}) =>
    {
      'ids_evidence_present': false,
      'outcome_uncertain': uncertain,
      'fixture_attachment_archive_settled': false,
      for (final kind in ['create', 'edit', 'undo']) ...{
        'fixture_${kind}_present': false,
        'fixture_${kind}_pending': false,
        'fixture_${kind}_settled': false,
      },
    };

Map<String, bool> backendFixtureArchiveFlags({
  required Store store,
  required CloudSyncNativeAuthSnapshot auth,
  required Message message,
  required String messageGuid,
  String? completedAction,
}) => store.runInTransaction(TxMode.read, () {
  final flags = backendFixtureArchiveAbsentFlags();
  flags['failure_present'] =
      CloudSyncLocalSendJournal.nativeSendFailureCode(store, message) != null;
  var commandIdsConfirmed = false;
  final account = auth.accountFingerprint;
  final guidHash = _digest(['cloud-sync-local-send-guid-v1', messageGuid]);
  final origins = _find(
    store.box<CloudSyncLocalSendIntentEntity>().query(
      CloudSyncLocalSendIntentEntity_.accountFingerprint
          .equals(account)
          .and(
            CloudSyncLocalSendIntentEntity_.localMessageId
                .equals(message.id ?? 0)
                .or(
                  CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                    guidHash,
                  ),
                ),
          ),
    ),
    2,
  );
  final mutations = _find(
    store.box<CloudSyncLocalMutationIntentEntity>().query(
      CloudSyncLocalMutationIntentEntity_.accountFingerprint
          .equals(account)
          .and(
            CloudSyncLocalMutationIntentEntity_.localMessageId
                .equals(message.id ?? 0)
                .or(
                  CloudSyncLocalMutationIntentEntity_.targetGuidHash.equals(
                    guidHash,
                  ),
                ),
          ),
    ),
    3,
  );
  flags['fixture_create_present'] = origins.isNotEmpty;
  for (final kind in [0, 1]) {
    flags['fixture_${kind == 0 ? 'edit' : 'undo'}_present'] = mutations.any(
      (row) => row.kind == kind,
    );
  }
  // Each fixture permits at most one edit and one undo. Ambiguity is never
  // resolved by choosing the newest row or an arbitrary operation.
  if (origins.length != 1 ||
      mutations.length > 2 ||
      mutations.any((row) => row.kind < 0 || row.kind > 1) ||
      mutations.map((row) => row.kind).toSet().length != mutations.length) {
    flags['outcome_uncertain'] = true;
    return flags;
  }
  final origin = origins.single;
  final scope = _scope(account, 'messageManateeZone');
  CloudOutboxOperationEntity? create;
  try {
    final owner = ObjectBoxCloudKitWriterAuthority(
      store: store,
    ).read(CloudKitWriterScope(accountFingerprint: account));
    if (owner == null ||
        origin.writerEpoch <= 0 ||
        origin.writerEpoch > owner.epoch ||
        origin.localMessageId != message.id ||
        origin.messageGuidHash != guidHash ||
        origin.state < 0 ||
        origin.state > 3 ||
        origin.intentKey !=
            _digest(['cloud-sync-local-send-intent-v1', account, guidHash]) ||
        !_sha.hasMatch(origin.sourceSha256)) {
      _reject();
    }
    final encodedSource = origin.protectedSourceBinding;
    if (encodedSource != null) {
      CloudSyncLocalSendSourceBinding.decode(encodedSource).requireOrigin(
        accountFingerprint: account,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        messageGuidHash: guidHash,
        sourceSha256: origin.sourceSha256,
      );
    } else if (origin.state == 1 || origin.state == 3) {
      if (origin.admittedBindingSha256 !=
          _digest([
            'cloud-sync-local-send-durable-auth-v1',
            account,
            auth.protectedStoreIdentity,
          ])) {
        _reject();
      }
    }
    if (origin.state == 2) {
      create = _operation(store, origin.admittedOperationId, scope);
      if (create == null ||
          create.payloadVersion != cloudSyncOutboundPayloadVersion ||
          create.operationId !=
              CloudOperationIdentity.forInitialCreate(
                scope: scope,
                logicalEntityKeyHash: create.logicalEntityKeyHash,
                payloadVersion: create.payloadVersion,
              )) {
        _reject();
      }
      _requireMap(store, scope, create);
    } else if (origin.admittedOperationId != null ||
        origin.admittedChatBinding != null ||
        origin.confirmedReadbackBindingSha256 != null) {
      _reject();
    }
    // Normalize only detached bookkeeping fields after validating the adopted
    // mapping. The journal reconstructs a pre-edit view from actual lineage.
    final view = message.dateEdited == null
        ? store.box<Message>().get(message.id!)!
        : cloudSyncReadOriginalPlaintextBeforeMutations(
            store: store,
            localMessageId: message.id!,
            accountFingerprint: account,
            maximumWriterEpoch: owner.epoch,
            targetGuidHash: guidHash,
          );
    if (create != null) {
      view.ckRecordId = null;
      view.ckSyncState = false;
    }
    final chat = view.chat.target;
    if (chat == null || view.guid != messageGuid || view.stagingGuid != null) {
      _reject();
    }
    final identity = encodedSource == null
        ? CloudSyncLocalSendIdentity.capture(
            view,
            chat,
            messageGuid,
            expectedSourceSha256: origin.sourceSha256,
          )
        : CloudSyncLocalSendIdentity.captureAttachment(
            view,
            chat,
            messageGuid,
            expectedSourceSha256: origin.sourceSha256,
          );
    if (identity == null || identity.guidHash != guidHash) _reject();
    flags['ids_evidence_present'] =
        origin.idsConfirmationVersion == 2 && origin.state != 0;
    if (flags['ids_evidence_present'] != true) _reject();
    commandIdsConfirmed = completedAction == 'create';
    if (create == null) {
      flags['fixture_create_pending'] = true;
    } else {
      final complete =
          CloudSyncLocalSendJournal.sourceLeaseReleasedAfterReadback(
            intent: origin,
            operation: _model(scope, create),
          );
      if (complete && _terminal(create)) {
        requireCloudSyncAdoptedLocalSendDependencies(
          store: store,
          messageScope: scope,
          binding: origin.admittedChatBinding,
          expectedChatId: message.chat.targetId,
          requireAttachmentReadback: (proof) =>
              _requireAttachments(store, auth, origin, proof),
        );
        // A protected attachment origin must carry the v4 child inventory.
        if (encodedSource != null) {
          var dependency = origin.admittedChatBinding!;
          if (CloudSyncMessageArchiveRecoveryOrigin.isEncoded(dependency)) {
            final recovery = CloudSyncLocalSendJournal.messageArchiveRecoveryAuditForLiveness(
              origin, originalOperation: create,
            );
            if (recovery == null) _reject();
            dependency = recovery.legacyBinding;
          }
          final binding = jsonDecode(dependency);
          if (binding is! List || binding.length != 3 || binding[0] != 4) {
            _reject();
          }
          flags['fixture_attachment_archive_settled'] = true;
        }
        flags['fixture_create_settled'] = true;
      } else if (origin.confirmedReadbackBindingSha256 != null) {
        _reject();
      } else {
        flags['fixture_create_pending'] = _pending(create);
        if (!_pending(create)) flags['outcome_uncertain'] = true;
      }
    }
    for (final row in mutations) {
      final kind = row.kind == 0 ? 'edit' : 'undo';
      try {
        validateCloudSyncMutationRow(row).requireOrigin(
          accountFingerprint: account,
          protectedStoreIdentity: auth.protectedStoreIdentity,
          mutationGuidHash: row.mutationGuidHash,
          targetGuidHash: guidHash,
          targetPart: 0,
          sourceSha256: row.sourceSha256,
        );
        if (row.localMessageId != message.id ||
            row.localChatId != message.chat.targetId ||
            row.writerEpoch > owner.epoch) {
          _reject();
        }
        if (row.state < 2) _reject(); // staged/claimed is not positive IDS.
        if (completedAction == kind) commandIdsConfirmed = true;
        if (row.state >= 3) {
          requireCloudSyncMutationForwardLineage(
            store: store,
            target: message,
            accountFingerprint: account,
            protectedStoreIdentity: auth.protectedStoreIdentity,
            maximumWriterEpoch: owner.epoch,
            automaticArchiveEpoch: owner.automaticArchiveEpoch,
            receivedOrigin: false,
            intentId: row.id,
            reject: _reject,
          );
        }
        if (row.state < 4) {
          flags['fixture_${kind}_pending'] = true;
          continue;
        }
        final operation = _operation(store, row.admittedOperationId, scope);
        if (create == null ||
            operation == null ||
            operation.payloadVersion != cloudSyncMessageUpdatePayloadVersion ||
            operation.logicalEntityKeyHash != create.logicalEntityKeyHash ||
            operation.serverRecordIdHash != create.serverRecordIdHash ||
            operation.checkpointGeneration != create.checkpointGeneration ||
            operation.mutationRevision <= create.mutationRevision ||
            operation.createdAtMs < row.createdAtMs ||
            operation.createdAtMs > row.updatedAtMs ||
            operation.operationId !=
                CloudOperationIdentity.forMutation(
                  scope: scope,
                  logicalEntityKeyHash: operation.logicalEntityKeyHash,
                  action: CloudOutboxAction.save,
                  payloadVersion: operation.payloadVersion,
                  mutationRevision: operation.mutationRevision,
                  payloadSha256: operation.payloadSha256,
                ) ||
            _find(
                  store.box<CloudSyncLocalMutationIntentEntity>().query(
                    CloudSyncLocalMutationIntentEntity_.admittedOperationId
                        .equals(operation.operationId),
                  ),
                  2,
                ).length !=
                1) {
          _reject();
        }
        if (row.state == 5) {
          _requireMap(store, scope, operation, mutation: true);
          if (!_terminal(operation) ||
              operation.confirmedAtMs < operation.createdAtMs ||
              operation.confirmedAtMs > row.updatedAtMs ||
              flags['fixture_create_settled'] != true) {
            _reject();
          }
          // State 5 is written only by the exact-readback callback. Its
          // predecessor-dependent adoption digest cannot be recomputed from
          // the now-advanced map; never manufacture a replacement binding.
          flags['fixture_${kind}_settled'] = true;
        } else {
          flags['fixture_${kind}_pending'] = _pending(operation);
          if (!_pending(operation)) flags['outcome_uncertain'] = true;
        }
      } on CloudSyncFailure {
        flags['outcome_uncertain'] = true;
      } on StateError {
        flags['outcome_uncertain'] = true;
      } on FormatException {
        flags['outcome_uncertain'] = true;
      } on ArgumentError {
        flags['outcome_uncertain'] = true;
      }
    }
  } on CloudSyncFailure {
    flags['outcome_uncertain'] = true;
  } on CloudKitWriterAuthorityFailure {
    flags['outcome_uncertain'] = true;
  } on StateError {
    flags['outcome_uncertain'] = true;
  } on FormatException {
    flags['outcome_uncertain'] = true;
  } on ArgumentError {
    flags['outcome_uncertain'] = true;
  }
  // Completed writer jobs are retained by hasUncertainJobs. Their flag describes
  // this command's IDS outcome, not archive work which may settle later. An
  // explicit foreground fixture.status retains the full archive uncertainty.
  if (completedAction != null) {
    flags['outcome_uncertain'] = !commandIdsConfirmed;
  }
  return flags;
});

List<T> _find<T>(QueryBuilder<T> builder, int limit) {
  final query = builder.build()..limit = limit;
  try {
    return query.find();
  } finally {
    query.close();
  }
}

CloudSyncScope _scope(String account, String zone) => CloudSyncScope(
  accountFingerprint: account,
  container: 'com.apple.messages.cloud',
  database: 'private',
  zone: zone,
  persistenceLane: CloudSyncPersistenceLane.semantic,
);

CloudOutboxOperationEntity? _operation(
  Store store,
  String? id,
  CloudSyncScope scope,
) {
  if (id == null) return null;
  final rows = _find(
    store.box<CloudOutboxOperationEntity>().query(
      CloudOutboxOperationEntity_.operationId.equals(id),
    ),
    2,
  );
  if (rows.length != 1) return null;
  final row = rows.single;
  if (row.accountFingerprint != scope.accountFingerprint ||
      row.scopeKey != cloudSyncPersistentScopeKey(scope) ||
      row.zone != scope.zone ||
      row.action != CloudOutboxAction.save.index ||
      row.checkpointGeneration <= 0 ||
      row.mutationRevision <= 0 ||
      row.createdAtMs <= 0 ||
      row.updatedAtMs < row.createdAtMs ||
      row.dependencyOperationIdsJson != '[]' ||
      row.localChatOrigin != null ||
      !_reference.hasMatch(row.encryptedPayloadRef ?? '') ||
      !_sha.hasMatch(row.payloadSha256 ?? '') ||
      !_token.hasMatch(row.logicalEntityKeyHash) ||
      !_token.hasMatch(row.serverRecordIdHash ?? '') ||
      row.state < 0 ||
      row.state > 5) {
    _reject();
  }
  return row;
}

bool _terminal(CloudOutboxOperationEntity row) =>
    row.state == 2 &&
    row.confirmedAtMs > 0 &&
    row.protectedLeaseReference == null &&
    row.leaseIdHash == null &&
    row.leaseExpiresAtMs == 0 &&
    row.nextEligibleAtMs == 0 &&
    row.lastErrorCategory == null &&
    _uuid.hasMatch(row.appleRequestUuid ?? '') &&
    _uuid.hasMatch(row.appleOperationUuid ?? '') &&
    row.appleRequestUuid != row.appleOperationUuid;

bool _pending(CloudOutboxOperationEntity row) =>
    (row.state == 0 &&
        row.attemptCount == 0 &&
        row.appleRequestUuid == null &&
        row.appleOperationUuid == null &&
        row.confirmedAtMs == 0) ||
    row.state == 1 ||
    row.state == 3 ||
    (row.state == 2 && row.protectedLeaseReference != null);

CloudOutboxOperation _model(
  CloudSyncScope scope,
  CloudOutboxOperationEntity row,
) => CloudOutboxOperation(
  scope: scope,
  operationId: row.operationId,
  logicalEntityKeyHash: row.logicalEntityKeyHash,
  action: CloudOutboxAction.save,
  payloadVersion: row.payloadVersion,
  mutationRevision: row.mutationRevision,
  checkpointGeneration: row.checkpointGeneration,
  dependencyOperationIds: const {},
  createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAtMs, isUtc: true),
  encryptedPayloadReference: row.encryptedPayloadRef,
  payloadSha256: row.payloadSha256,
  serverRecordIdHash: row.serverRecordIdHash,
  protectedLeaseReference: row.protectedLeaseReference,
  appleRequestUuid: row.appleRequestUuid,
  appleOperationUuid: row.appleOperationUuid,
  status: CloudOutboxStatus.values[row.state],
  attemptCount: row.attemptCount,
  confirmedAt: row.confirmedAtMs == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(row.confirmedAtMs, isUtc: true),
  leaseId: row.leaseIdHash,
  leaseExpiresAt: row.leaseExpiresAtMs == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(row.leaseExpiresAtMs, isUtc: true),
  nextEligibleAt: row.nextEligibleAtMs == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(row.nextEligibleAtMs, isUtc: true),
  lastFailure: row.lastErrorCategory == null
      ? null
      : CloudFailureCategory.unknown,
);

void _requireMap(
  Store store,
  CloudSyncScope scope,
  CloudOutboxOperationEntity operation, {
  bool mutation = false,
}) {
  final checkpoints = _find(
    store.box<CloudSyncCheckpointEntity>().query(
      CloudSyncCheckpointEntity_.checkpointKey.equals(operation.scopeKey),
    ),
    2,
  );
  final maps = _find(
    store.box<CloudRecordMapEntity>().query(
      CloudRecordMapEntity_.mapKey.equals(
        cloudSyncCanonicalRecordMapKey(scope, operation.logicalEntityKeyHash),
      ),
    ),
    2,
  );
  if (checkpoints.length != 1 || maps.length != 1) _reject();
  final checkpoint = checkpoints.single;
  final map = maps.single;
  if (checkpoint.accountFingerprint != scope.accountFingerprint ||
      checkpoint.container != scope.container ||
      checkpoint.database != scope.database ||
      checkpoint.zone != scope.zone ||
      checkpoint.streamKind != scope.streamKind.name ||
      checkpoint.schemaVersion != scope.schemaVersion ||
      checkpoint.persistenceLane != scope.persistenceLane.name ||
      checkpoint.generation != operation.checkpointGeneration ||
      map.scopeKey != operation.scopeKey ||
      map.accountFingerprint != scope.accountFingerprint ||
      map.zone != scope.zone ||
      map.generation != operation.checkpointGeneration ||
      map.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
      map.serverRecordIdHash != operation.serverRecordIdHash ||
      !_reference.hasMatch(map.encryptedServerRecordId)) {
    _reject();
  }
  if (mutation &&
      (!_token.hasMatch(map.etagHash ?? '') ||
          !_reference.hasMatch(map.encryptedRawRecordRef ?? '') ||
          map.rawRecordGeneration <= 0 ||
          map.protectedReadbackLeaseReference != null ||
          map.pendingUpdateOperationId != null ||
          map.pendingUpdatePredecessorEtagHash != null)) {
    _reject();
  }
}

void _requireAttachments(
  Store store,
  CloudSyncNativeAuthSnapshot auth,
  CloudSyncLocalSendIntentEntity origin,
  String proof,
) {
  // Retained v1 inventory is already covered by the parent's immutable create
  // binding. Recompute its exact children using the existing release validator.
  if (proof.length > 65536) _reject();
  final value = jsonDecode(proof);
  final scope = _scope(auth.accountFingerprint, 'attachmentManateeZone');
  if (value is! List ||
      value.length != 11 ||
      value[0] != 1 ||
      value[1] != scope.storageKey ||
      value[2] is! int ||
      value[3] != origin.id ||
      value[4] != origin.messageGuidHash ||
      value[5] != origin.sourceSha256 ||
      value[6] != auth.protectedStoreIdentity ||
      value[7] != origin.writerEpoch ||
      value[8] is! List ||
      value[9] is! List ||
      value[10] != _digest(value.sublist(0, 10))) {
    _reject();
  }
  final keys = value[8] as List;
  if (keys.isEmpty ||
      keys.length > 64 ||
      keys.any((key) => key is! String || !_token.hasMatch(key)) ||
      keys.toSet().length != keys.length) {
    _reject();
  }
  final uploads = _find(
    store.box<CloudAttachmentUploadEntity>().query(
      CloudAttachmentUploadEntity_.localSendIntentId.equals(origin.id),
    ),
    65,
  )..sort((a, b) => a.attachmentKeyHash.compareTo(b.attachmentKeyHash));
  if (uploads.length != keys.length) _reject();
  final children = <List<Object?>>[];
  for (var i = 0; i < uploads.length; i++) {
    final row = uploads[i];
    if (row.ownerKind != 0 ||
        row.ownerIntentId != 0 ||
        row.accountFingerprint != auth.accountFingerprint ||
        row.protectedStoreIdentity != auth.protectedStoreIdentity ||
        row.writerEpoch != origin.writerEpoch ||
        row.checkpointGeneration != value[2] ||
        row.messageGuidHash != origin.messageGuidHash ||
        row.sourceSha256 != origin.sourceSha256 ||
        row.attachmentKeyHash != keys[i] ||
        !CloudSyncAttachmentUploadJournal.resultLeaseReleasedAfterReadback(
          store,
          row,
        )) {
      _reject();
    }
    children.add([
      row.id,
      row.attachmentKeyHash,
      row.serverRecordIdHash,
      row.resultPayloadSha256,
      row.admittedOperationId,
    ]);
  }
  if (jsonEncode(children) != jsonEncode(value[9])) _reject();
}

final _sha = RegExp(r'^[0-9a-f]{64}$');
final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _reference = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
final _uuid = RegExp(
  r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
);
String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
Never _reject() => throw StateError('backend_fixture_archive_evidence_changed');
