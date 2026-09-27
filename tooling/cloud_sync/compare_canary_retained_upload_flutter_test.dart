import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Explicit offline tooling. Opens disposable copies of qualified captures,
// never a device or retained evidence database. No network or account calls.
// Values containing identities and protected references stay in memory.
List<Object?> _operation(CloudOutboxOperationEntity r) => [
  r.id,
  r.operationId,
  r.scopeKey,
  r.accountFingerprint,
  r.zone,
  r.logicalEntityKeyHash,
  r.action,
  r.dependencyOperationIdsJson,
  r.payloadVersion,
  r.mutationRevision,
  r.checkpointGeneration,
  r.appleRequestUuid,
  r.appleOperationUuid,
  r.encryptedPayloadRef,
  r.payloadSha256,
  r.protectedLeaseReference,
  r.localChatOrigin,
  r.state,
  r.attemptCount,
  r.nextEligibleAtMs,
  r.lastErrorCategory,
  r.serverRecordIdHash,
  r.leaseIdHash,
  r.leaseExpiresAtMs,
  r.confirmedAtMs,
  r.createdAtMs,
  r.updatedAtMs,
];

List<Object?> _intent(CloudSyncLocalSendIntentEntity r) => [
  r.id,
  r.intentKey,
  r.accountFingerprint,
  r.writerEpoch,
  r.localMessageId,
  r.messageGuidHash,
  r.sourceSha256,
  r.state,
  r.admittedOperationId,
  r.admittedBindingSha256,
  r.admittedChatBinding,
  r.confirmedReadbackBindingSha256,
  r.idsConfirmationVersion,
  r.protectedSourceBinding,
  r.createdAtMs,
  r.updatedAtMs,
];

Future<Map<String, Object?>> _readQualified(String source) async {
  final file = File('$source/data.mdb');
  final qualification =
      jsonDecode(
            await File('$source/capture-qualification.json').readAsString(),
          )
          as Map<String, dynamic>;
  final digest = (await sha256.bind(file.openRead()).first).toString();
  if (qualification['stable'] != true ||
      qualification['package'] != 'com.bluebubbles.messaging.cloudkitcanary' ||
      qualification['databaseSha256'] != digest ||
      qualification['remoteBeforeSha256'] != digest ||
      qualification['remoteAfterSha256'] != digest ||
      qualification['bytes'] != await file.length()) {
    throw StateError('capture_not_qualified');
  }
  final root = Directory(r'C:\Codex\OpenBubblesReview\scratch');
  final staging = await root.createTemp('retained-upload-comparison-');
  Store? store;
  try {
    await file.copy('${staging.path}/data.mdb');
    store = await openStore(directory: staging.path);
    return store.runInTransaction(TxMode.read, () {
      final rows = store!.box<CloudOutboxOperationEntity>().getAll()
        ..sort((a, b) => a.id.compareTo(b.id));
      final pending = rows.where((r) => r.state == 0).toList();
      if (pending.length != 1 ||
          rows.any((r) => r.state != 0 && r.state != 2)) {
        throw StateError('single_pending_operation_required');
      }
      final selected = pending.single;
      if (selected.action != 0 ||
          selected.zone != 'messageManateeZone' ||
          selected.protectedLeaseReference == null ||
          selected.encryptedPayloadRef == null ||
          selected.payloadSha256 == null) {
        throw StateError('retained_message_envelope_required');
      }
      final linked = store
          .box<CloudSyncLocalSendIntentEntity>()
          .getAll()
          .where((r) => r.admittedOperationId == selected.operationId)
          .toList();
      if (linked.length != 1 || linked.single.state != 2) {
        throw StateError('exact_adopted_local_send_required');
      }
      final intent = linked.single;
      final message = store.box<Message>().get(intent.localMessageId);
      final chat = message?.chat.target;
      final sourceIntact =
          message != null &&
          chat != null &&
          message.dateDeleted == null &&
          CloudSyncLocalSendIdentity.capture(
                message,
                chat,
                message.guid ?? '',
                expectedSourceSha256: intent.sourceSha256,
              ) !=
              null;
      if (!sourceIntact) throw StateError('retained_source_changed');
      final checkpoints = store
          .box<CloudSyncCheckpointEntity>()
          .getAll()
          .where((r) => r.checkpointKey == selected.scopeKey)
          .toList();
      if (checkpoints.length != 1) {
        throw StateError('exact_checkpoint_required');
      }
      final checkpoint = checkpoints.single;
      if (checkpoint.accountFingerprint != selected.accountFingerprint ||
          checkpoint.zone != selected.zone ||
          checkpoint.generation != selected.checkpointGeneration) {
        throw StateError('checkpoint_binding_changed');
      }
      return {
        'operations': jsonEncode(rows.map(_operation).toList()),
        'selectedOperation': jsonEncode(_operation(selected)),
        'intent': jsonEncode(_intent(intent)),
        'checkpoint': jsonEncode([
          checkpoint.id,
          checkpoint.checkpointKey,
          checkpoint.accountFingerprint,
          checkpoint.zone,
          checkpoint.generation,
        ]),
        'counts': {
          'chats': store.box<Chat>().count(),
          'messages': store.box<Message>().count(),
          'attachments': store.box<Attachment>().count(),
          'outbox': rows.length,
          'settledAudits': rows.length - 1,
        },
        'revision': selected.mutationRevision,
        'attempts': selected.attemptCount,
      };
    });
  } finally {
    store?.close();
    if (staging.parent.absolute.path != root.absolute.path) {
      throw StateError('invalid_scratch_cleanup_target');
    }
    await staging.delete(recursive: true);
    if ((await sha256.bind(file.openRead()).first).toString() != digest) {
      throw StateError('retained_source_file_changed');
    }
  }
}

void main() {
  test('retained upload still matches its approved capture', () async {
    final baseline = Platform.environment['OPENBUBBLES_APPROVED_CAPTURE'];
    final current = Platform.environment['OPENBUBBLES_CURRENT_CAPTURE'];
    if (baseline == null || current == null) {
      throw StateError('two_explicit_capture_paths_required');
    }
    final before = await _readQualified(baseline);
    final after = await _readQualified(current);
    // Compare privately. Never give the test matcher protected field values.
    final unchanged = {
      for (final field in [
        'operations',
        'selectedOperation',
        'intent',
        'checkpoint',
      ])
        field: before[field] == after[field],
    };
    // ignore: avoid_print
    print(
      'RETAINED_UPLOAD_COMPARISON=${jsonEncode({'unchanged': unchanged, 'beforeCounts': before['counts'], 'currentCounts': after['counts'], 'revision': after['revision'], 'attempts': after['attempts'], 'sourceCapturesPreserved': true, 'noNetworkRequests': true})}',
    );
    expect(
      unchanged.values.every((v) => v),
      isTrue,
      reason: 'Do not retry a changed retained operation or audit inventory',
    );
  });
}
