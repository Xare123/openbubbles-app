// One cached Chat decode and a diagnostic pre-failure reconstruction on a
// disposable database copy. This is not a repair or a quarantine-requeue API.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/transient_cloud_canonical_identity_registry.dart';
import 'package:crypto/crypto.dart';
import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:objectbox/internal.dart' show EntityDefinition;

const _snapshotRoot =
    'C:/Codex/OpenBubblesReview/worktrees/cloudkit-v2-update-seam-live-bbfa/'
    'build-evidence/message-parent-diagnostics-20261022/CHAT_CONFLICT_SNAPSHOT_20261023_A';
const _snapshotHash =
    'e967b549397b8378a2b79bdfe7bcf018cb8e3b2e9e4deff7d2f5920ab8c64a6f';

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

void _require(bool condition) {
  if (!condition)
    throw StateError('quarantined_chat_observation_binding_failed');
}

// ObjectBox updates its file pages for the normal operation-fence heartbeat.
// Compare every persisted entity and relationship, exempting ONLY that exact
// sentinel lease. A message, cursor, replay, alias or unrelated lease change
// remains a hard failure. None of these private digests is printed.
String quarantinedChatObservationPreservedState(
  Store store,
) => store.runInTransaction(TxMode.read, () {
  final model = getObjectBoxModel();
  final entities = <String, Object?>{};
  void take<T>() {
    final binding = model.bindings[T]! as EntityDefinition<T>;
    final rows = store.box<T>().getAll()
      ..sort((a, b) => binding.getId(a)!.compareTo(binding.getId(b)!));
    entities[T.toString()] = [
      for (final row in rows)
        if (!(row is CloudSyncLeaseEntity &&
            row.scopeKey == CloudKitOperationInterlock.fenceScopeKey))
          [
            binding.getId(row),
            (() {
              final builder = fb.Builder(initialSize: 1024);
              binding.objectToFB(row, builder);
              return sha256.convert(builder.buffer).toString();
            })(),
            if (row is Chat) (row.handles.map((h) => h.id).toList()..sort()),
            if (row is Chat) (row.messages.map((m) => m.id).toList()..sort()),
            if (row is Message)
              (row.dbAttachments.map((a) => a.id).toList()..sort()),
          ],
    ];
  }

  take<Attachment>();
  take<Chat>();
  take<FCMData>();
  take<Handle>();
  take<ThemeEntry>();
  take<Message>();
  take<ThemeObject>();
  take<ThemeStruct>();
  take<Contact>();
  take<CloudInboxChangeEntity>();
  take<CloudOutboxOperationEntity>();
  take<CloudRecordMapEntity>();
  take<CloudSyncCheckpointEntity>();
  take<CloudSyncRunEntity>();
  take<CloudSyncLeaseEntity>();
  take<CloudAttachmentMaterializationEntity>();
  take<CloudSemanticReplayEntity>();
  take<CloudSemanticSnapshotEntity>();
  take<CloudProtectedPageLeaseEntity>();
  take<CloudKitWriterAuthorityEntity>();
  take<CloudKitDeletionIntentEntity>();
  take<CloudKitDeletionQuarantineEntity>();
  take<CloudKitV2QuarantineRepairReceiptEntity>();
  take<CloudSemanticChatAliasEntity>();
  take<CloudSyncLocalSendIntentEntity>();
  take<CloudAttachmentUploadEntity>();
  take<CloudSyncLocalMutationIntentEntity>();
  take<CloudSyncReceivedArchiveIntentEntity>();
  take<CloudSyncReceivedMutationIntentEntity>();
  take<CloudSyncHistoricalArchiveIntentEntity>();
  _require(entities.length == model.bindings.length);
  return sha256.convert(utf8.encode(jsonEncode(entities))).toString();
});

// Used only in memory to prove the exact captured row. Never returned/logged.
String _rowBinding(CloudInboxChangeEntity row) => jsonEncode([
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
  row.failureCategory,
  row.preflightCode,
  row.retryCount,
  row.nextEligibleAtMs,
  row.serverModifiedAtMs,
  row.serverModifiedAtFormatVersion,
  row.createdAtMs,
  row.updatedAtMs,
  row.completedAtMs,
]);

CloudInboxEntry _entry(CloudInboxChangeEntity row, CloudSyncScope scope) =>
    CloudInboxEntry(
      scope: scope,
      sequence: row.fetchSequence,
      generation: row.generation,
      batchId: row.batchId,
      status: CloudInboxStatus.values[row.status],
      attemptCount: row.retryCount,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.createdAtMs,
        isUtc: true,
      ),
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

final class _DecodedOnce implements CloudSemanticDecoder {
  _DecodedOnce(this.decoded);
  final CloudDecodedMutation decoded;
  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async {
    _require(
      entry.scope == decoded.scope &&
          entry.generation == decoded.generation &&
          entry.change.changeId == decoded.changeId,
    );
    return decoded;
  }
}

final class _NoAccountAccess implements CloudSyncProtector {
  Never _deny() => throw StateError('copy_account_access_forbidden');
  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) => _deny();
  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) => _deny();
  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) => _deny();
}

Future<Map<String, Object?>> observeQuarantinedChatConflict({
  required Store store,
  required Directory profile,
  required CloudSyncNativeAuthSnapshot auth,
  required BigInt pauseToken,
}) async {
  _require(Platform.environment['OPENBUBBLES_INSPECT_QUARANTINED_CHAT'] == '1');
  final originalFile = File('${profile.path}/objectbox/data.mdb');
  final originalHash = await _hash(originalFile);
  final beforeState = quarantinedChatObservationPreservedState(store);
  final snapshotFile = File('$_snapshotRoot/data.mdb');
  _require(await _hash(snapshotFile) == _snapshotHash);
  final scope = CloudSyncScope(
    accountFingerprint: auth.accountFingerprint,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'chatManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final query =
      store
          .box<CloudInboxChangeEntity>()
          .query(
            CloudInboxChangeEntity_.scopeKey
                .equals(scopeKey)
                .and(
                  CloudInboxChangeEntity_.accountFingerprint.equals(
                    auth.accountFingerprint,
                  ),
                )
                .and(CloudInboxChangeEntity_.zone.equals(scope.zone))
                .and(CloudInboxChangeEntity_.generation.equals(1))
                .and(CloudInboxChangeEntity_.fetchSequence.equals(863))
                .and(
                  CloudInboxChangeEntity_.status.equals(
                    CloudInboxStatus.quarantined.index,
                  ),
                )
                .and(CloudInboxChangeEntity_.failureCategory.equals('conflict'))
                .and(CloudInboxChangeEntity_.changeType.equals('save'))
                .and(CloudInboxChangeEntity_.isTombstone.equals(false)),
          )
          .build()
        ..limit = 2;
  final List<CloudInboxChangeEntity> rows;
  try {
    rows = query.find();
  } finally {
    query.close();
  }
  _require(rows.length == 1);
  final row = rows.single;
  final originalBinding = _rowBinding(row);
  const scratchRoot = 'C:/Codex/OpenBubblesReview/scratch';
  final scratch = await Directory(
    scratchRoot,
  ).createTemp('chat-conflict-reproduce-');
  Store? copy;
  try {
    await snapshotFile.copy('${scratch.path}/data.mdb');
    _require(await _hash(File('${scratch.path}/data.mdb')) == _snapshotHash);
    copy = await openStore(directory: scratch.path);
    final copiedRow = copy.box<CloudInboxChangeEntity>().get(row.id);
    _require(copiedRow != null && _rowBinding(copiedRow) == originalBinding);
    final diagnostics = CloudSyncSemanticDiagnosticCollector();
    final decoded = await RustCloudSemanticDecoder(
      readAuthSnapshot: () async => auth,
      storageDirectory: profile.path,
      nativeWriterPauseToken: pauseToken,
      diagnosticRecorder: diagnostics.record,
    ).decode(_entry(row, scope));
    final payload = decoded.payload;
    _require(payload is CloudChatEntityPayload && decoded.snapshot != null);
    final chatPayload = payload as CloudChatEntityPayload;
    final maps = copy
        .box<CloudRecordMapEntity>()
        .getAll()
        .where(
          (r) =>
              r.scopeKey == scopeKey &&
              r.generation == row.generation &&
              r.logicalEntityKeyHash == chatPayload.logicalEntityKeyHash,
        )
        .toList();
    final canonicalMaps = maps
        .where((r) => r.mapKey.startsWith('record-map:'))
        .toList();
    final canonicalChats = copy
        .box<Chat>()
        .query(Chat_.guid.equals(chatPayload.canonicalGuid))
        .build();
    final int canonicalChatCount;
    try {
      canonicalChatCount = canonicalChats.count();
    } finally {
      canonicalChats.close();
    }

    // Diagnostic reconstruction ONLY: restore this copy's exact captured row
    // to its pre-failure pending state. Live quarantine/cursors are untouched.
    copiedRow!.status = CloudInboxStatus.pending.index;
    copiedRow.failureCategory = null;
    copiedRow.nextEligibleAtMs = 0;
    copiedRow.completedAtMs = 0;
    copy.box<CloudInboxChangeEntity>().put(copiedRow);
    final durable = ObjectBoxCloudSyncStore(
      store: copy,
      protector: _NoAccountAccess(),
    );
    final fence = await durable.tryAcquireCoordinatorLease(
      scope,
      ownerId: 'quarantined-chat-copy-diagnosis',
      now: DateTime.now().toUtc(),
      leaseDuration: const Duration(minutes: 2),
    );
    _require(fence != null);
    final identities = TransientCloudCanonicalIdentityRegistry();
    final projector = ObjectBoxCanonicalSemanticEntityAdapter(
      store: copy,
      activeScopeProvider: () =>
          CloudCanonicalActiveScope(scope: scope, generation: row.generation),
      identityResolver: identities,
      semanticApplyEnabled: true,
      allowChatUpserts: true,
      diagnosticRecorder: diagnostics.record,
    );
    final CloudInboxApplyResult result;
    try {
      result = await TransactionalCloudInboxApplier(
        decoder: _DecodedOnce(decoded),
        store: ObjectBoxCloudSemanticStoreGateway(
          store: copy,
          canonicalAdapter: projector,
        ),
        identityRegistrar: identities,
        diagnosticRecorder: diagnostics.record,
      ).apply(_entry(copiedRow, scope), leaseFence: fence!);
    } finally {
      await durable.releaseCoordinatorLease(scope, leaseFence: fence!);
    }
    _require(
      quarantinedChatObservationPreservedState(store) == beforeState &&
          _rowBinding(store.box<CloudInboxChangeEntity>().get(row.id)!) ==
              originalBinding &&
          await _hash(snapshotFile) == _snapshotHash,
    );
    return {
      'decode': 'ready',
      'durable_state_unchanged': true,
      'all_non_fence_entities_and_edges_unchanged': true,
      'original_database_byte_exact': await _hash(originalFile) == originalHash,
      'exact_operation_fence_lease_excluded': true,
      'snapshot_source_unchanged': true,
      'copy_only_pre_failure_reconstruction': true,
      'generation': row.generation,
      'sequence': row.fetchSequence,
      'chat_style': chatPayload.style?.name,
      'chat_service': chatPayload.service?.name,
      'canonical_chat_count': canonicalChatCount,
      'logical_record_map_count': maps.length,
      'canonical_record_map_count': canonicalMaps.length,
      'canonical_map_same_record': canonicalMaps.length == 1
          ? canonicalMaps.single.serverRecordIdHash == row.serverRecordIdHash
          : null,
      'disposition': result.disposition.name,
      'failure_category': result.failureCategory?.name,
      'failure_code': result.safeCode == null
          ? null
          : cloudSyncV2SafeFailureCodeForCandidate(result.safeCode),
      'diagnostics': diagnostics.snapshot(),
    };
  } finally {
    copy?.close();
    final resolved = (await scratch.resolveSymbolicLinks()).replaceAll(
      '\\',
      '/',
    );
    _require(resolved.startsWith('$scratchRoot/chat-conflict-reproduce-'));
    await scratch.delete(recursive: true);
    _require(
      quarantinedChatObservationPreservedState(store) == beforeState &&
          await _hash(snapshotFile) == _snapshotHash,
    );
  }
}
