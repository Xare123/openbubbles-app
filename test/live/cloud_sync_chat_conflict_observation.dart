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
  if (!condition) {
    throw StateError('quarantined_chat_observation_binding_failed');
  }
}

// ObjectBox updates its file pages for the normal operation-fence heartbeat.
// Compare every persisted entity and relationship, exempting ONLY that exact
// sentinel lease. A message, cursor, replay, alias or unrelated lease change
// remains a hard failure. None of these private digests is printed.
String quarantinedChatObservationPreservedState(
  Store store, {
  Map<String, Set<int>>? collectIds,
  Map<String, Set<int>>? restrictIds,
  Set<String> ignoredRows = const {},
}
) => store.runInTransaction(TxMode.read, () {
  final model = getObjectBoxModel();
  final entities = <String, Object?>{};
  void take<T>() {
    final binding = model.bindings[T]! as EntityDefinition<T>;
    final rows = store.box<T>().getAll()
      ..sort((a, b) => binding.getId(a)!.compareTo(binding.getId(b)!));
    collectIds?[T.toString()] = rows.map((r) => binding.getId(r)!).toSet();
    entities[T.toString()] = [
      for (final row in rows)
        if (!(row is CloudSyncLeaseEntity &&
                row.scopeKey == CloudKitOperationInterlock.fenceScopeKey) &&
            !ignoredRows.contains('${T.toString()}:${binding.getId(row)}') &&
            (restrictIds == null ||
                restrictIds[T.toString()]!.contains(binding.getId(row))))
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

// Only processing status/failure/retry/scheduling/completion fields may differ.
// Enumerate source fields rather than relying on offsets in the full binding.
String _immutableInboxSource(CloudInboxChangeEntity row) => jsonEncode([
  row.id, row.changeKey, row.changeIdHash, row.scopeKey, row.accountFingerprint,
  row.zone, row.serverRecordIdHash, row.etagHash, row.changeType,
  row.encryptedServerRecordId, row.protectedSystemFieldsRef,
  row.encryptedPayloadRef, row.payloadSha256, row.batchId, row.generation,
  row.fetchSequence, row.isTombstone, row.preflightCategory, row.preflightCode,
  row.serverModifiedAtMs, row.serverModifiedAtFormatVersion, row.createdAtMs,
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
  final productionRecovery =
      Platform.environment['OPENBUBBLES_QUALIFY_CHAT_ROUTE_RECOVERY'] == '1';
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
    final decoder = RustCloudSemanticDecoder(
      readAuthSnapshot: () async => auth,
      storageDirectory: profile.path,
      nativeWriterPauseToken: pauseToken,
      diagnosticRecorder: diagnostics.record,
    );
    final decoded = await decoder.decode(_entry(row, scope));
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
    // Read the ONE exact previously applied protected version, when present.
    // This distinguishes an actual route transition from an older converter's
    // bad projection; no prior identity or plaintext escapes this observation.
    final collisions = copy
        .box<CloudRecordMapEntity>()
        .getAll()
        .where(
          (r) =>
              r.scopeKey == scopeKey &&
              r.accountFingerprint == auth.accountFingerprint &&
              r.generation == row.generation &&
              r.serverRecordIdHash == row.serverRecordIdHash &&
              r.mapKey.startsWith('record-map:'),
        )
        .toList();
    final previous = <String, Object?>{'map_count': collisions.length};
    if (collisions.length == 1) {
      final oldMap = collisions.single;
      final oldRows = copy
          .box<CloudInboxChangeEntity>()
          .getAll()
          .where(
            (old) =>
                old.scopeKey == scopeKey &&
                old.accountFingerprint == auth.accountFingerprint &&
                old.generation == row.generation &&
                old.zone == scope.zone &&
                old.status == CloudInboxStatus.applied.index &&
                old.changeType == 'save' &&
                !old.isTombstone &&
                old.serverRecordIdHash == oldMap.serverRecordIdHash &&
                old.etagHash == oldMap.etagHash &&
                old.encryptedPayloadRef == oldMap.encryptedRawRecordRef,
          )
          .toList();
      previous['exact_applied_source_count'] = oldRows.length;
      if (oldRows.length == 1) {
        final oldRow = oldRows.single;
        try {
          final oldDecoded = await decoder.decode(_entry(oldRow, scope));
          final oldPayload = oldDecoded.payload;
          _require(oldPayload is CloudChatEntityPayload);
          final oldChat = oldPayload as CloudChatEntityPayload;
          final oldPeers = oldChat.participantHandles.toList()..sort();
          final newPeers = chatPayload.participantHandles.toList()..sort();
          final oldDate = cloudInboxCanonicalServerModifiedAt(oldRow);
          final newDate = cloudInboxCanonicalServerModifiedAt(row);
          previous.addAll({
            'decode': 'ready',
            'service': oldChat.service?.name,
            'style': oldChat.style?.name,
            'logical_key_matches_existing_map':
                oldChat.logicalEntityKeyHash == oldMap.logicalEntityKeyHash,
            'same_chat_identifier':
                oldChat.chatIdentifier == chatPayload.chatIdentifier,
            'same_participants': jsonEncode(oldPeers) == jsonEncode(newPeers),
            'same_one_participant':
                oldPeers.length == 1 &&
                newPeers.length == 1 &&
                oldPeers.single == newPeers.single,
            'sms_to_imessage_direct_guid_pair':
                oldChat.canonicalGuid ==
                    'SMS;-;${chatPayload.chatIdentifier}' &&
                chatPayload.canonicalGuid ==
                    'iMessage;-;${chatPayload.chatIdentifier}',
            'server_time_strictly_increases':
                oldDate != null && newDate != null && newDate.isAfter(oldDate),
            'different_logical_keys':
                oldChat.logicalEntityKeyHash !=
                chatPayload.logicalEntityKeyHash,
            'previous_pending_update':
                oldMap.pendingUpdateOperationId != null ||
                oldMap.protectedReadbackLeaseReference != null,
          });
        } catch (error) {
          previous['decode'] = 'failed';
          previous['failure_code'] = error is CloudSemanticDecodeFailure
              ? cloudSyncV2SafeFailureCodeForCandidate(error.safeCode)
              : cloudSyncV2SafeFailureCode(error);
        }
      }
    }
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

    final priorIds = <String, Set<int>>{};
    final copyMutableRows = <String>{
      'CloudInboxChangeEntity:${copiedRow!.id}',
      for (final cp in copy.box<CloudSyncCheckpointEntity>().getAll())
        if (cp.checkpointKey == scopeKey) 'CloudSyncCheckpointEntity:${cp.id}',
      for (final lease in copy.box<CloudSyncLeaseEntity>().getAll())
        if (lease.scopeKey == scopeKey) 'CloudSyncLeaseEntity:${lease.id}',
    };
    final priorData = quarantinedChatObservationPreservedState(copy,
      collectIds: priorIds, ignoredRows: copyMutableRows);
    final outboxCount = copy.box<CloudOutboxOperationEntity>().count();

    if (!productionRecovery) {
      // Historical diagnosis ONLY. The new recovery mode MUST NOT enter this
      // direct status reconstruction; it uses the production reservation API.
      copiedRow.status = CloudInboxStatus.pending.index;
      copiedRow.failureCategory = null;
      copiedRow.nextEligibleAtMs = 0;
      copiedRow.completedAtMs = 0;
      copy.box<CloudInboxChangeEntity>().put(copiedRow);
    }
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
    bool? recoveryReserved;
    bool? repeatedRecoveryReserved;
    try {
      final applier = TransactionalCloudInboxApplier(
        decoder: _DecodedOnce(decoded),
        store: ObjectBoxCloudSemanticStoreGateway(
          store: copy,
          canonicalAdapter: projector,
        ),
        identityRegistrar: identities,
        activeScopeRevalidator: () async => true,
        diagnosticRecorder: diagnostics.record,
      );
      if (productionRecovery) {
        recoveryReserved = await applier.requeueChatServiceRouteBarrier(scope,
          leaseFence: fence!);
        repeatedRecoveryReserved = await applier.requeueChatServiceRouteBarrier(scope,
          leaseFence: fence);
      }
      final pending = copy.box<CloudInboxChangeEntity>().get(copiedRow.id)!;
      result = pending.status == CloudInboxStatus.pending.index
          ? await applier.apply(_entry(pending, scope), leaseFence: fence!)
          : const CloudInboxApplyResult.deferred(safeCode: 'chat_route_recovery_unavailable');
    } finally {
      await durable.releaseCoordinatorLease(scope, leaseFence: fence!);
    }
    final afterIds = <String, Set<int>>{};
    final sourcePreserved = _immutableInboxSource(row) == _immutableInboxSource(
      copy.box<CloudInboxChangeEntity>().get(copiedRow.id)!);
    final priorDataPreserved = priorData ==
        quarantinedChatObservationPreservedState(copy,
          collectIds: afterIds, restrictIds: priorIds,
          ignoredRows: copyMutableRows);
    const permittedNewTypes = {
      'Chat', 'Handle', 'CloudRecordMapEntity', 'CloudSemanticSnapshotEntity',
      'CloudSemanticReplayEntity', 'CloudSemanticChatAliasEntity',
      'CloudSyncLeaseEntity',
    };
    final unexpectedNewRows = afterIds.entries.any((entry) =>
      !permittedNewTypes.contains(entry.key) &&
      entry.value.difference(priorIds[entry.key]!).isNotEmpty);
    final newChats = copy.box<Chat>().getAll().where(
      (chat) => chat.guid == chatPayload.canonicalGuid).toList();
    final routeApplied = result.disposition == CloudInboxApplyDisposition.applied;
    final newRouteMatches = routeApplied && newChats.length == 1 &&
        newChats.single.dateDeleted == null && !newChats.single.isRpSms &&
        !newChats.single.isRoutingStub && newChats.single.style == 45 &&
        newChats.single.chatIdentifier == chatPayload.chatIdentifier &&
        newChats.single.handles.length == 1 &&
        newChats.single.handles.single.address == chatPayload.chatIdentifier &&
        newChats.single.handles.single.service == 'iMessage';
    final outboxUnchanged = copy.box<CloudOutboxOperationEntity>().count() == outboxCount;
    _require(priorDataPreserved && !unexpectedNewRows && outboxUnchanged && sourcePreserved);
    if (routeApplied) {
      _require(newRouteMatches);
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
      'copy_only_pre_failure_reconstruction': !productionRecovery,
      'copy_production_recovery_attempted': productionRecovery,
      'copy_production_recovery_reserved': recoveryReserved,
      'copy_repeated_recovery_reserved': repeatedRecoveryReserved,
      'copy_original_data_rows_preserved': priorDataPreserved,
      'copy_conflict_source_preserved': sourcePreserved,
      'copy_unexpected_new_rows': unexpectedNewRows,
      'copy_outbox_unchanged': outboxUnchanged,
      'copy_new_route_matches': newRouteMatches,
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
      'previous_protected_version': previous,
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
