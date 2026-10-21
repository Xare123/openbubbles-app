import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_local_mutation_journal.dart'
    show validateCloudSyncMutationRow;
import 'cloud_sync_models.dart';
import 'cloud_sync_received_archive_identity.dart';
import 'cloud_sync_received_mutation_source_binding.dart';

/// The existing LOCAL v1 snapshot, including its exact nested-map canonical
/// encoding and ordered attachment/route lists. This is not an origin, actor,
/// outgoing receipt, remote predecessor or write-permission proof.
String cloudSyncMutationTargetSnapshot(Message target) {
  final chat = target.chat.target;
  if (chat == null) throw StateError('cloud_sync_mutation_target_changed');
  return _digest([
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
    target.attributedBody.map((part) => part.toMap()).toList(),
    target.messageSummaryInfo.map((info) => info.toJson()).toList(),
    target.dbAttachments
        .map((attachment) => [attachment.id, attachment.guid])
        .toList(),
    chat.guid,
    chat.chatIdentifier,
    chat.usingHandle,
    chat.style,
    chat.isRpSms,
    chat.handles.map((handle) => [handle.address, handle.service]).toList(),
  ]);
}

/// Read-only bounded forward lineage over independently validated origin lanes.
/// Local state 5 / received state 3 are the journals' exact-readback markers,
/// never inferred from IDS acceptance, reflection, or save-only success.
///
/// The requested event's immutable before/after hashes stay unchanged. The
/// returned current tip is transient and must be pinned across staging/adoption.
/// Detached unfinished rows, including pre-release received-domain snapshots,
/// HOLD the operation; no hash or row is migrated, discarded or rewritten here.
String requireCloudSyncMutationForwardLineage({
  required Store store,
  required Message target,
  required String accountFingerprint,
  required String protectedStoreIdentity,
  required int maximumWriterEpoch,
  required int automaticArchiveEpoch,
  required bool receivedOrigin,
  required int intentId,
  required Never Function() reject,
}) => store.runInTransaction(TxMode.read, () {
  final id = target.id;
  final guid = target.guid;
  if (id == null ||
      id <= 0 ||
      guid == null ||
      intentId <= 0 ||
      maximumWriterEpoch <= 0 ||
      automaticArchiveEpoch < 0 ||
      automaticArchiveEpoch > maximumWriterEpoch ||
      !_token.hasMatch(accountFingerprint) ||
      !_store.hasMatch(protectedStoreIdentity)) {
    reject();
  }
  final current = store.box<Message>().get(id);
  if (current == null ||
      current.guid != guid ||
      current.verificationFailed ||
      current.dateDeleted != null ||
      current.chat.targetId != target.chat.targetId ||
      current.chat.target == null) {
    reject();
  }
  final tip = cloudSyncMutationTargetSnapshot(current);
  if (tip != cloudSyncMutationTargetSnapshot(target)) reject();
  final localHash = _digest(['cloud-sync-local-send-guid-v1', guid]);
  final receivedHash = _digest(['cloud-sync-received-archive-guid-v1', guid]);
  final localQuery =
      store
          .box<CloudSyncLocalMutationIntentEntity>()
          .query(
            CloudSyncLocalMutationIntentEntity_.accountFingerprint
                .equals(accountFingerprint)
                .and(
                  CloudSyncLocalMutationIntentEntity_.targetGuidHash
                      .equals(localHash)
                      .or(
                        CloudSyncLocalMutationIntentEntity_.localMessageId
                            .equals(id),
                      ),
                ),
          )
          .build()
        ..limit = 65;
  final receivedQuery =
      store
          .box<CloudSyncReceivedMutationIntentEntity>()
          .query(
            CloudSyncReceivedMutationIntentEntity_.accountFingerprint
                .equals(accountFingerprint)
                .and(
                  CloudSyncReceivedMutationIntentEntity_.targetGuidHash
                      .equals(receivedHash)
                      .or(
                        CloudSyncReceivedMutationIntentEntity_.localMessageId
                            .equals(id),
                      ),
                ),
          )
          .build()
        ..limit = 65;
  late final List<CloudSyncLocalMutationIntentEntity> localRows;
  late final List<CloudSyncReceivedMutationIntentEntity> receivedRows;
  try {
    localRows = localQuery.find();
    receivedRows = receivedQuery.find();
  } finally {
    localQuery.close();
    receivedQuery.close();
  }
  if (localRows.length + receivedRows.length > 64) reject();
  final selected = receivedOrigin
      ? receivedRows
            .where((row) => row.id == intentId)
            .map((row) => row.admittedOperationId)
            .toList()
      : localRows
            .where((row) => row.id == intentId)
            .map((row) => row.admittedOperationId)
            .toList();
  if (selected.length != 1) reject();
  // Retained-event ordering is fresh-dispatch policy, not permission to strand
  // an immutable submitted envelope. The caller still proves the exact native
  // source/operation/predecessor; no callback can label an unsubmitted op safe.
  final recovering = _hasSubmittedReadback(
    store,
    selected.single,
    accountFingerprint,
  );
  final nodes = <_Node>[];
  for (final row in localRows) {
    final source = validateCloudSyncMutationRow(row);
    source.requireOrigin(
      accountFingerprint: accountFingerprint,
      protectedStoreIdentity: protectedStoreIdentity,
      mutationGuidHash: row.mutationGuidHash,
      targetGuidHash: localHash,
      targetPart: 0,
      sourceSha256: row.sourceSha256,
    );
    if (current.isFromMe != true ||
        row.localMessageId != id ||
        row.localChatId != current.chat.targetId ||
        row.targetGuidHash != localHash ||
        row.targetPart != 0 ||
        row.writerEpoch > maximumWriterEpoch) {
      reject();
    }
    if (row.state < 3) {
      // A not-yet-reflected future send may be pinned to this exact tip. It is
      // not a preceding edge. Any detached unfinished source still holds.
      if (!recovering && row.targetSnapshotSha256 != tip) {
        _predecessorNotReady(receivedOrigin);
      }
      continue;
    }
    nodes.add(
      _Node(
        key: (false, row.id),
        before: row.targetSnapshotSha256,
        after: row.reflectedSnapshotSha256!,
        unsend: row.kind == 1,
        terminal: row.state == 5,
      ),
    );
  }
  for (final row in receivedRows) {
    final source = validateCloudSyncReceivedMutationRow(row);
    source.requireOrigin(
      account: accountFingerprint,
      store: protectedStoreIdentity,
      eventGuidHash: row.mutationGuidHash,
      sourceDigest: row.sourceSha256,
    );
    if (automaticArchiveEpoch <= 0 ||
        row.ownershipEpoch != automaticArchiveEpoch ||
        row.targetGuidHash != receivedHash ||
        row.targetPart != 0 ||
        current.isFromMe !=
            (row.origin == CloudSyncReceivedArchiveOrigin.mirrored.index) ||
        (row.state >= 2 &&
            (row.admittedWriterEpoch < automaticArchiveEpoch ||
                row.admittedWriterEpoch > maximumWriterEpoch))) {
      reject();
    }
    if (row.state == 0) {
      // No before-image exists yet. An earlier/equal retained event cannot be
      // skipped; a future event has not changed this target or its lineage.
      final reflectedAt = current.dateEdited?.millisecondsSinceEpoch;
      if (!recovering &&
          (reflectedAt == null || row.sentTimestampMs <= reflectedAt)) {
        _predecessorNotReady(receivedOrigin);
      }
      continue;
    }
    if (row.localMessageId != id || row.localChatId != current.chat.targetId) {
      reject();
    }
    nodes.add(
      _Node(
        key: (true, row.id),
        before: row.beforeSnapshotSha256!,
        after: row.reflectedSnapshotSha256!,
        unsend: row.kind == 1,
        terminal: row.state == 3,
      ),
    );
  }
  final byBefore = <String, _Node>{};
  final byAfter = <String, _Node>{};
  for (final node in nodes) {
    if (node.before == node.after ||
        byBefore.containsKey(node.before) ||
        byAfter.containsKey(node.after)) {
      reject();
    }
    byBefore[node.before] = node;
    byAfter[node.after] = node;
  }
  // Validate every component, not just the selected tip: detached terminal
  // history is allowed, but a cycle or an unsend successor is never lineage.
  final complete = <(bool, int)>{};
  for (final start in nodes) {
    final path = <(bool, int)>{};
    _Node? cursor = start;
    while (cursor != null && !complete.contains(cursor.key)) {
      if (!path.add(cursor.key)) reject();
      final next = byBefore[cursor.after];
      if (cursor.unsend && next != null) reject();
      cursor = next;
    }
    complete.addAll(path);
  }
  var cursor = tip;
  final visited = <(bool, int)>{};
  final reverse = <_Node>[];
  while (byAfter.containsKey(cursor)) {
    final node = byAfter[cursor]!;
    if (!visited.add(node.key)) reject();
    reverse.add(node);
    cursor = node.before;
  }
  if (reverse.isEmpty ||
      nodes.any((n) => !visited.contains(n.key) && !n.terminal)) {
    reject();
  }
  final chain = reverse.reversed.toList(growable: false);
  final index = chain.indexWhere((n) => n.key == (receivedOrigin, intentId));
  if (index < 0) reject();
  if (chain.take(index).any((n) => !n.terminal)) {
    _predecessorNotReady(receivedOrigin);
  }
  return tip;
});

Never _predecessorNotReady(bool received) => throw StateError(
  'cloud_sync_${received ? 'received' : 'local'}_mutation_predecessor_not_ready',
);

bool _hasSubmittedReadback(Store store, String? operationId, String account) {
  if (operationId == null) return false;
  final query = store
      .box<CloudOutboxOperationEntity>()
      .query(CloudOutboxOperationEntity_.operationId.equals(operationId))
      .build();
  try {
    final row = query.findUnique();
    return row != null &&
        row.accountFingerprint == account &&
        row.zone == 'messageManateeZone' &&
        row.action == CloudOutboxAction.save.index &&
        row.payloadVersion == cloudSyncMessageUpdatePayloadVersion &&
        row.checkpointGeneration > 0 &&
        // Submission UUIDs/state are persisted before native consumption.
        // attemptCount can still be zero when the very first response is lost.
        row.appleRequestUuid != null &&
        row.appleOperationUuid != null &&
        (row.state == CloudOutboxStatus.unknownOutcome.index ||
            row.state == CloudOutboxStatus.confirmed.index);
  } finally {
    query.close();
  }
}

/// Shape and inline-source correlation only. Owner/auth, target eligibility,
/// native actor/route, outbox/readback and consent fences remain with callers.
CloudSyncReceivedMutationSourceBinding validateCloudSyncReceivedMutationRow(
  CloudSyncReceivedMutationIntentEntity row,
) {
  if (row.id <= 0 ||
      row.ownershipEpoch <= 0 ||
      !_token.hasMatch(row.accountFingerprint) ||
      row.intentKey !=
          _digest([
            'cloud-sync-received-mutation-intent-v1',
            row.accountFingerprint,
            row.mutationGuidHash,
          ]) ||
      !_hash.hasMatch(row.mutationGuidHash) ||
      !_hash.hasMatch(row.targetGuidHash) ||
      !_hash.hasMatch(row.sourceSha256) ||
      ![0, 1].contains(row.origin) ||
      ![0, 1].contains(row.kind) ||
      row.targetPart < 0 ||
      row.sentTimestampMs <= 0 ||
      row.createdAtMs <= 0 ||
      row.updatedAtMs < row.createdAtMs ||
      row.state < 0 ||
      row.state > 3 ||
      ((row.state < 2) != (row.admittedOperationId == null)) ||
      ((row.state < 2) != (row.admittedBindingSha256 == null)) ||
      (row.state < 2
          ? row.admittedWriterEpoch != 0
          : row.admittedWriterEpoch <= 0) ||
      (row.admittedOperationId != null &&
          !_operationId.hasMatch(row.admittedOperationId!)) ||
      (row.admittedBindingSha256 != null &&
          !_hash.hasMatch(row.admittedBindingSha256!)) ||
      (row.state == 0 &&
          (row.localMessageId != 0 ||
              row.localChatId != 0 ||
              row.beforeSnapshotSha256 != null ||
              row.reflectedSnapshotSha256 != null)) ||
      (row.state >= 1 &&
          (row.localMessageId <= 0 ||
              row.localChatId <= 0 ||
              !_hash.hasMatch(row.beforeSnapshotSha256 ?? '') ||
              !_hash.hasMatch(row.reflectedSnapshotSha256 ?? '')))) {
    throw StateError('cloud_sync_received_mutation_intent_changed');
  }
  final source = CloudSyncReceivedMutationSourceBinding.decode(
    row.protectedSourceBinding,
  );
  source.requireOrigin(
    account: row.accountFingerprint,
    store: source.protectedStoreIdentity,
    eventGuidHash: row.mutationGuidHash,
    sourceDigest: row.sourceSha256,
  );
  return source;
}

final class _Node {
  const _Node({
    required this.key,
    required this.before,
    required this.after,
    required this.unsend,
    required this.terminal,
  });
  final (bool, int) key;
  final String before;
  final String after;
  final bool unsend;
  final bool terminal;
}

Object? _canonical(Object? value) {
  if (value is List) return value.map(_canonical).toList();
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  return value;
}

String _digest(List<Object?> value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
final _hash = RegExp(r'^[a-f0-9]{64}$');
final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _store = RegExp(r'^obcs2\.store\.[A-Za-z0-9_-]{43}$');
final _operationId = RegExp(r'^op1:[a-f0-9]{64}$');
