// Private test-claim-bound observation, not an app operation or recovery API.
import 'dart:convert';
import 'dart:io';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart';

Future<Map<String, Object?>> verifyEditEcho({
  required Store store,
  required Directory profile,
  required String requestId,
  required CloudSyncNativeAuthSnapshot auth,
  required Object pauseToken,
}) async {
  Never reject() => throw StateError('windows_edit_echo_binding_rejected');
  if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(requestId)) reject();
  final file = File(
    '${profile.path}/cloud-sync-v2/windows-write-$requestId.json',
  );
  if (await file.length() > 8192) reject();
  final claim = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final requestFile = File(
    '${profile.path}/cloud-sync-v2/windows-local-write-request-$requestId.json',
  );
  if (await requestFile.length() > 8192) reject();
  final request = CloudSyncWindowsWriteRequest.fromJson(
    jsonDecode(await requestFile.readAsString()) as Map<String, dynamic>,
  );
  if (claim['version'] != 2 ||
      claim['purpose'] != 'mutation' ||
      claim['account'] != auth.accountFingerprint ||
      claim['local_message_id'] is! int ||
      request.id != requestId ||
      request.mutationType != 'edit' ||
      claim['binding'] != request.binding) {
    reject();
  }
  final messageId = claim['local_message_id'] as int;
  final message = store.box<Message>().get(messageId);
  if (message == null ||
      message.isFromMe != true ||
      message.dateEdited == null ||
      message.messageSummaryInfo.isEmpty ||
      message.dateDeleted != null ||
      message.text != request.text) {
    reject();
  }
  final intents = store
      .box<CloudSyncLocalMutationIntentEntity>()
      .query(
        CloudSyncLocalMutationIntentEntity_.accountFingerprint
            .equals(auth.accountFingerprint)
            .and(
              CloudSyncLocalMutationIntentEntity_.localMessageId.equals(
                messageId,
              ),
            )
            .and(
              CloudSyncLocalMutationIntentEntity_.sourceSha256.equals(
                claim['source_sha256'] as String,
              ),
            )
            .and(
              CloudSyncLocalMutationIntentEntity_.targetGuidHash.equals(
                claim['target_guid_hash'] as String,
              ),
            ),
      )
      .build();
  final intent = intents.findUnique();
  intents.close();
  if (intent == null ||
      intent.state != 5 ||
      intent.kind != 0 ||
      intent.admittedOperationId == null) {
    reject();
  }
  final operations = store
      .box<CloudOutboxOperationEntity>()
      .query(
        CloudOutboxOperationEntity_.operationId.equals(
          intent.admittedOperationId!,
        ),
      )
      .build();
  final operation = operations.findUnique();
  operations.close();
  if (operation == null ||
      operation.state != CloudOutboxStatus.confirmed.index ||
      operation.accountFingerprint != auth.accountFingerprint ||
      operation.protectedLeaseReference != null) {
    reject();
  }
  final scope = CloudSyncScope(
    accountFingerprint: auth.accountFingerprint,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  if (operation.scopeKey != scopeKey ||
      operation.zone != scope.zone ||
      operation.serverRecordIdHash == null) {
    reject();
  }
  final checkpoints = store
      .box<CloudSyncCheckpointEntity>()
      .query(CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey))
      .build();
  final checkpoint = checkpoints.findUnique();
  checkpoints.close();
  if (checkpoint == null ||
      checkpoint.generation != operation.checkpointGeneration) {
    reject();
  }
  final maps = store
      .box<CloudRecordMapEntity>()
      .query(
        CloudRecordMapEntity_.scopeKey
            .equals(scopeKey)
            .and(CloudRecordMapEntity_.generation.equals(checkpoint.generation))
            .and(
              CloudRecordMapEntity_.serverRecordIdHash.equals(
                operation.serverRecordIdHash!,
              ),
            ),
      )
      .build();
  final map = maps.findUnique();
  maps.close();
  if (map == null ||
      map.logicalEntityKeyHash != operation.logicalEntityKeyHash ||
      map.pendingUpdateOperationId != null ||
      map.protectedReadbackLeaseReference != null) {
    reject();
  }
  final rows =
      (store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey
                .equals(scopeKey)
                .and(
                  CloudInboxChangeEntity_.generation.equals(
                    checkpoint.generation,
                  ),
                )
                .and(
                  CloudInboxChangeEntity_.serverRecordIdHash.equals(
                    operation.serverRecordIdHash!,
                  ),
                ),
          )..order(
            CloudInboxChangeEntity_.fetchSequence,
            flags: Order.descending,
          ))
          .build()
        ..limit = 1;
  final row = rows.findFirst();
  rows.close();
  if (row == null ||
      row.status != CloudInboxStatus.applied.index ||
      row.isTombstone ||
      row.changeType != 'save' ||
      row.etagHash != map.etagHash) {
    reject();
  }
  final entry = CloudInboxEntry(
    scope: scope,
    sequence: row.fetchSequence,
    generation: row.generation,
    batchId: row.batchId,
    status: CloudInboxStatus.applied,
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
      serverModifiedAt: row.serverModifiedAtMs == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row.serverModifiedAtMs,
              isUtc: true,
            ),
    ),
  );
  String localHistory(Message value) =>
      jsonEncode(value.messageSummaryInfo.map((s) => s.toJson()).toList());
  final before = localHistory(message);
  final decoded = await RustCloudSemanticDecoder(
    readAuthSnapshot: () async => auth,
    storageDirectory: profile.path,
    nativeWriterPauseToken: pauseToken as BigInt,
  ).decode(entry);
  final payload = decoded.payload;
  if (payload is! CloudMessageEntityPayload ||
      payload.canonicalGuid != message.guid) {
    reject();
  }
  final local = <String>[];
  for (final summary in message.messageSummaryInfo) {
    for (final part in summary.editedContent.entries) {
      for (final edit in part.value) {
        final date = edit.date;
        if (date == null || !date.isFinite || edit.text == null) reject();
        final ms = date >= 978307200000
            ? date.toInt()
            : 978307200000 + (date * 1000).floor();
        local.add(
          jsonEncode([
            int.parse(part.key),
            ms,
            edit.text!.values.map((v) => v.string).toList(),
          ]),
        );
      }
    }
  }
  final incoming = payload.edits
      .map(
        (e) => jsonEncode([
          e.part,
          e.modifiedAt.millisecondsSinceEpoch,
          e.bodies.map((b) => b.text).toList(),
        ]),
      )
      .toList();
  local.sort();
  incoming.sort();
  if (localHistory(store.box<Message>().get(messageId)!) != before) reject();
  final localRetracted = message.messageSummaryInfo.expand((s) => s.retractedParts).toSet().toList()..sort();
  final nativeRetracted = payload.retractedParts.toSet().toList()..sort();
  return {
    'exact_current_text':
        payload.body == message.text && payload.body == request.text,
    'local_edit_count': local.length,
    'native_edit_count': incoming.length,
    'exact_edit_text_and_milliseconds':
        jsonEncode(local) == jsonEncode(incoming),
    'decoded_current_etag': true,
    'local_history_unchanged': true,
    'exact_retracted_parts': jsonEncode(localRetracted) == jsonEncode(nativeRetracted),
    'retracted_part_count': nativeRetracted.length,
  };
}
