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
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_record_maps.dart';
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

// For an already-existing target route, only its source metadata rotates. The
// old source must survive as an exact member, checked separately below. This
// hash still covers every other serialized field, including ownership and
// pending-writer fields. It never puts the normalized in-memory object in DB.
String quarantinedChatRotationIdentityHash(Object row) {
  final restore = <void Function()>[];
  try {
    if (row is CloudRecordMapEntity) {
      final server = row.serverRecordIdHash, encrypted = row.encryptedServerRecordId;
      final etag = row.etagHash, raw = row.encryptedRawRecordRef;
      final generation = row.rawRecordGeneration, updated = row.updatedAtMs;
      restore.add(() { row.serverRecordIdHash = server; row.encryptedServerRecordId = encrypted;
        row.etagHash = etag; row.encryptedRawRecordRef = raw;
        row.rawRecordGeneration = generation; row.updatedAtMs = updated; });
      row.serverRecordIdHash = ''; row.encryptedServerRecordId = '';
      row.etagHash = null; row.encryptedRawRecordRef = null;
      row.rawRecordGeneration = 0; row.updatedAtMs = 0;
    } else if (row is CloudSemanticSnapshotEntity) {
      final etag = row.etagHash, updated = row.updatedAtMs;
      restore.add(() { row.etagHash = etag; row.updatedAtMs = updated; });
      row.etagHash = null; row.updatedAtMs = 0;
    } else if (row is CloudSemanticChatAliasEntity) {
      final updated = row.updatedAtMs;
      restore.add(() => row.updatedAtMs = updated);
      row.updatedAtMs = 0;
    } else {
      throw StateError('quarantined_chat_rotation_type_forbidden');
    }
    String hashTyped<T>(T value) {
      final binding = getObjectBoxModel().bindings[T]! as EntityDefinition<T>;
      final builder = fb.Builder(initialSize: 1024);
      binding.objectToFB(value, builder);
      return sha256.convert(builder.buffer).toString();
    }
    return switch (row) {
      CloudRecordMapEntity value => hashTyped(value),
      CloudSemanticSnapshotEntity value => hashTyped(value),
      CloudSemanticChatAliasEntity value => hashTyped(value),
      _ => throw StateError('quarantined_chat_rotation_type_forbidden'),
    };
  } finally {
    for (final undo in restore.reversed) { undo(); }
  }
}

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
  Map<String, String>? collectRowHashes,
  ({int id, String? before, String after})? checkedUsingHandleProjection,
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
              final projection = checkedUsingHandleProjection;
              final target = row is Chat && row.id == projection?.id ? row : null;
              final actual = target?.usingHandle;
              try {
                if (target != null) {
                  _require(actual == projection!.after);
                  target.usingHandle = projection.before;
                }
                binding.objectToFB(row, builder);
                return sha256.convert(builder.buffer).toString();
              } finally {
                if (target != null) target.usingHandle = actual;
              }
            })(),
            if (row is Chat) (row.handles.map((h) => h.id).toList()..sort()),
            if (row is Chat) (row.messages.map((m) => m.id).toList()..sort()),
            if (row is Message)
              (row.dbAttachments.map((a) => a.id).toList()..sort()),
          ],
    ];
    if (collectRowHashes != null) {
      for (final value in entities[T.toString()]! as List) {
        collectRowHashes['${T.toString()}:${value[0]}'] =
          sha256.convert(utf8.encode(jsonEncode(value))).toString();
      }
    }
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
  final inspectNext = Platform.environment['OPENBUBBLES_INSPECT_NEXT_CHAT_CONFLICT'] == '1';
  final inspectNonDirect = Platform.environment['OPENBUBBLES_INSPECT_NON_DIRECT_CHAT_CONFLICT'] == '1';
  final inspectPostGroup = Platform.environment['OPENBUBBLES_INSPECT_POST_GROUP_CHAT_CONFLICT'] == '1';
  final inspectRecordMapping = Platform.environment['OPENBUBBLES_INSPECT_RECORD_MAPPING_CHAT_CONFLICT'] == '1';
  _require([inspectNext, inspectNonDirect, inspectPostGroup, inspectRecordMapping]
      .where((value) => value).length <= 1);
  final snapshotRoot = inspectRecordMapping
      ? '${_snapshotRoot.substring(0, _snapshotRoot.length - 1)}R' : inspectPostGroup
      ? '${_snapshotRoot.substring(0, _snapshotRoot.length - 1)}O' : inspectNonDirect
      ? '${_snapshotRoot.substring(0, _snapshotRoot.length - 1)}L' : inspectNext
      ? '${_snapshotRoot.substring(0, _snapshotRoot.length - 1)}G' : _snapshotRoot;
  final snapshotHash = inspectRecordMapping
      ? 'ec8b3df143cf700b6108437ce47d7a4723392bb3ee9d3f67da1ab87797956e51' : inspectPostGroup
      ? 'c3a674e0cf0e2e3d0961b0c50666bd6ee3716b65324e5a6266167f375a175c63' : inspectNonDirect
      ? '3c50655371f63412d26db87b6e716e4a61af3b62c69273a3a4f73103b5c23015' : inspectNext
      ? '21635c19e36223fd3d7d645d7477e1a7cddb54c8467b702d77e2cd99ae8fe287' : _snapshotHash;
  final expectedSequence = inspectRecordMapping ? 962 : inspectPostGroup ? 958 : inspectNonDirect ? 869 : inspectNext ? 864 : 863;
  final originalFile = File('${profile.path}/objectbox/data.mdb');
  final originalHash = await _hash(originalFile);
  final beforeState = quarantinedChatObservationPreservedState(store);
  final snapshotFile = File('$snapshotRoot/data.mdb');
  _require(await _hash(snapshotFile) == snapshotHash);
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
                .and(CloudInboxChangeEntity_.fetchSequence.equals(expectedSequence))
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
    _require(await _hash(File('${scratch.path}/data.mdb')) == snapshotHash);
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
    // A mapping-only hold can instead have an existing logical owner under a
    // different physical record. Inspect only that exact canonical map, never
    // an arbitrary alias/recipient candidate. This mode remains read-only.
    final previousMaps = inspectRecordMapping && collisions.isEmpty ? canonicalMaps : collisions;
    final previous = <String, Object?>{'map_count': previousMaps.length};
    if (previousMaps.length == 1) {
      final oldMap = previousMaps.single;
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
            'same_canonical_guid': oldChat.canonicalGuid == chatPayload.canonicalGuid,
            'same_service': oldChat.service == chatPayload.service,
            'same_style': oldChat.style == chatPayload.style,
            'same_logical_key': oldChat.logicalEntityKeyHash == chatPayload.logicalEntityKeyHash,
            'same_physical_record': oldRow.serverRecordIdHash == row.serverRecordIdHash,
            'same_participants': jsonEncode(oldPeers) == jsonEncode(newPeers),
            'same_one_participant':
                oldPeers.length == 1 &&
                newPeers.length == 1 &&
                oldPeers.single == newPeers.single,
            'previous_participant_count': oldPeers.length,
            'incoming_participant_count': newPeers.length,
            'previous_has_group_id': oldChat.groupId?.isNotEmpty == true,
            'incoming_has_group_id': chatPayload.groupId?.isNotEmpty == true,
            'same_nonempty_group_id': oldChat.groupId?.isNotEmpty == true &&
                oldChat.groupId == chatPayload.groupId,
            'same_nonempty_original_group_id': oldChat.originalGroupId?.isNotEmpty == true &&
                oldChat.originalGroupId == chatPayload.originalGroupId,
            'same_typed_alias_count': oldChat.aliases.where((old) =>
                chatPayload.aliases.any((current) => current.kind == old.kind &&
                  current.keyHash == old.keyHash)).length,
            'group_version_equal': oldChat.groupVersion != null &&
                oldChat.groupVersion == chatPayload.groupVersion,
            'group_version_increases': oldChat.groupVersion != null &&
                chatPayload.groupVersion != null &&
                chatPayload.groupVersion! > oldChat.groupVersion!,
            'sms_to_imessage_group_guid_pair':
                oldChat.canonicalGuid == 'SMS;+;${chatPayload.chatIdentifier}' &&
                chatPayload.canonicalGuid == 'iMessage;+;${chatPayload.chatIdentifier}',
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
    final Chat? canonicalChatBefore;
    try {
      canonicalChatCount = canonicalChats.count();
      canonicalChatBefore = canonicalChatCount == 1 ? canonicalChats.findUnique() : null;
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
    final targetMap = (inspectNext || inspectRecordMapping) && productionRecovery && canonicalMaps.length == 1
        ? canonicalMaps.single : null;
    final targetMetadata = <String, String>{};
    if (targetMap != null) {
      void remember(Object value, int id) {
        final key = '${value.runtimeType}:$id';
        copyMutableRows.add(key);
        targetMetadata[key] = quarantinedChatRotationIdentityHash(value);
      }
      remember(targetMap, targetMap.id);
      final snapshots = copy.box<CloudSemanticSnapshotEntity>().getAll().where((value) =>
        value.scopeKey == scopeKey && value.generation == row.generation &&
        value.entityKind == 'chat' && value.logicalEntityKeyHash == chatPayload.logicalEntityKeyHash).toList();
      _require(snapshots.length == 1);
      remember(snapshots.single, snapshots.single.id);
      for (final alias in copy.box<CloudSemanticChatAliasEntity>().getAll().where((value) =>
          value.scopeKey == scopeKey && value.generation == row.generation &&
          value.chatLogicalEntityKeyHash == chatPayload.logicalEntityKeyHash)) {
        remember(alias, alias.id);
      }
    }
    final beforeRowHashes = <String, String>{};
    final priorData = quarantinedChatObservationPreservedState(copy,
      collectIds: priorIds, ignoredRows: copyMutableRows, collectRowHashes: beforeRowHashes);
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
    var targetMetadataVerified = targetMap == null;
    if (targetMap != null && result.disposition == CloudInboxApplyDisposition.applied) {
      final current = cloudSyncFindRecordMap(store: copy, scope: scope,
        generation: row.generation, logicalEntityKeyHash: chatPayload.logicalEntityKeyHash);
      final former = cloudSyncFindRecordMap(store: copy, scope: scope,
        generation: row.generation, logicalEntityKeyHash: chatPayload.logicalEntityKeyHash,
        serverRecordIdHash: targetMap.serverRecordIdHash);
      final afterMetadata = <String, String>{
        for (final value in copy.box<CloudRecordMapEntity>().getAll())
          if (targetMetadata.containsKey('CloudRecordMapEntity:${value.id}'))
            'CloudRecordMapEntity:${value.id}': quarantinedChatRotationIdentityHash(value),
        for (final value in copy.box<CloudSemanticSnapshotEntity>().getAll())
          if (targetMetadata.containsKey('CloudSemanticSnapshotEntity:${value.id}'))
            'CloudSemanticSnapshotEntity:${value.id}': quarantinedChatRotationIdentityHash(value),
        for (final value in copy.box<CloudSemanticChatAliasEntity>().getAll())
          if (targetMetadata.containsKey('CloudSemanticChatAliasEntity:${value.id}'))
            'CloudSemanticChatAliasEntity:${value.id}': quarantinedChatRotationIdentityHash(value),
      };
      targetMetadataVerified = current != null && former != null &&
        current.id == targetMap.id && current.serverRecordIdHash == row.serverRecordIdHash &&
        current.encryptedServerRecordId == row.encryptedServerRecordId &&
        current.etagHash == row.etagHash && current.encryptedRawRecordRef == row.encryptedPayloadRef &&
        current.rawRecordGeneration == row.generation &&
        cloudSyncRecordMapProvenanceMatches(former, targetMap) &&
        afterMetadata.length == targetMetadata.length &&
        targetMetadata.entries.every((entry) => afterMetadata[entry.key] == entry.value);
    }
    final sourcePreserved = _immutableInboxSource(row) == _immutableInboxSource(
      copy.box<CloudInboxChangeEntity>().get(copiedRow.id)!);
    final afterRowHashes = <String, String>{};
    // J proved that only this existing Chat's usingHandle changes. Match that
    // one value to the actual authenticated lastAddressedHandle, using the
    // same explicit scheme framing as the production adapter; do not ignore
    // the Chat row, its other fields, participant links or message history.
    ({int id, String? before, String after})? usingHandleProjection;
    final addressed = chatPayload.lastAddressedHandle;
    if ((inspectNext || inspectRecordMapping) && productionRecovery && canonicalChatBefore != null &&
        chatPayload.lastAddressedHandleState == CloudSemanticFieldState.value &&
        addressed != null && addressed.isNotEmpty) {
      final lower = addressed.toLowerCase();
      final expected = lower.startsWith('mailto:') ? 'mailto:${addressed.substring(7)}'
          : lower.startsWith('tel:') ? 'tel:${addressed.substring(4)}'
          : addressed.contains('@') ? 'mailto:$addressed' : 'tel:$addressed';
      usingHandleProjection = (id: canonicalChatBefore.id!,
        before: canonicalChatBefore.usingHandle, after: expected);
    }
    final priorDataPreserved = priorData ==
        quarantinedChatObservationPreservedState(copy,
          collectIds: afterIds, restrictIds: priorIds,
          ignoredRows: copyMutableRows, collectRowHashes: afterRowHashes,
          checkedUsingHandleProjection: usingHandleProjection);
    final changedRowTypes = <String, int>{};
    for (final entry in beforeRowHashes.entries) {
      if (afterRowHashes[entry.key] != entry.value) {
        final type = entry.key.split(':').first;
        changedRowTypes[type] = (changedRowTypes[type] ?? 0) + 1;
      }
    }
    Map<String, Object?> adapterFields(Chat value) => {
      'guid': value.guid, 'chatIdentifier': value.chatIdentifier,
      'style': value.style, 'isRpSms': value.isRpSms, 'displayName': value.displayName,
      'usingHandle': value.usingHandle, 'groupVersion': value.groupVersion,
      'lastReadMessageGuid': value.lastReadMessageGuid, 'cloudGuid': value.cloudGuid,
      'dateDeleted': value.dateDeleted?.millisecondsSinceEpoch,
      'isRoutingStub': value.isRoutingStub,
    };
    final changedChatFields = <String>[];
    if (canonicalChatBefore != null) {
      final after = copy.box<Chat>().get(canonicalChatBefore.id!);
      if (after != null) {
        final old = adapterFields(canonicalChatBefore), current = adapterFields(after);
        changedChatFields.addAll(old.keys.where((key) => old[key] != current[key]));
      }
    }
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
    final expectedParticipants = chatPayload.participantHandles.map((raw) {
      final lower = raw.toLowerCase();
      if (lower.startsWith('tel:')) return raw.substring(4);
      if (lower.startsWith('mailto:')) return raw.substring(7);
      return raw;
    }).toSet();
    final groupRoute = chatPayload.style == CloudSemanticChatStyle.group;
    final newRouteMatches = routeApplied && newChats.length == 1 &&
        newChats.single.dateDeleted == null && !newChats.single.isRpSms &&
        !newChats.single.isRoutingStub && newChats.single.style == (groupRoute ? 43 : 45) &&
        newChats.single.chatIdentifier == chatPayload.chatIdentifier &&
        (groupRoute
          ? expectedParticipants.length >= 2 &&
            newChats.single.cloudGuid == chatPayload.groupId &&
            newChats.single.handles.length == expectedParticipants.length &&
            newChats.single.handles.map((handle) => handle.address).toSet().length ==
                expectedParticipants.length &&
            newChats.single.handles.every((handle) => handle.service == 'iMessage' &&
                expectedParticipants.contains(handle.address))
          : newChats.single.handles.length == 1 &&
            newChats.single.handles.single.address == chatPayload.chatIdentifier &&
            newChats.single.handles.single.service == 'iMessage');
    final outboxUnchanged = copy.box<CloudOutboxOperationEntity>().count() == outboxCount;
    // The launcher enforces every copy-preservation predicate. Return its
    // content-free negatives too so a held qualification retains its cause.
    // Live state and immutable snapshot tripwires below remain hard failures.
    if (routeApplied) {
      _require(newRouteMatches);
    }
    _require(
      quarantinedChatObservationPreservedState(store) == beforeState &&
          _rowBinding(store.box<CloudInboxChangeEntity>().get(row.id)!) ==
              originalBinding &&
          await _hash(snapshotFile) == snapshotHash,
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
      'copy_changed_existing_row_types': changedRowTypes,
      'copy_changed_existing_chat_fields': changedChatFields,
      'copy_using_handle_projection_checked': usingHandleProjection != null,
      'copy_target_route_metadata_rotation_verified': targetMetadataVerified,
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
          await _hash(snapshotFile) == snapshotHash,
    );
  }
}
