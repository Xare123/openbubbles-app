import 'dart:convert';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:crypto/crypto.dart';

/// Offline evidence only. Does not contact Apple or grant mutation authority.
/// Reuses the production exact-intent validator instead of reconstructing its
/// routing, checkpoint, mapping and immutable-envelope predicates here.
Map<String, Object?> inspectWindowsWriteProof(
  Store store,
  CloudSyncWindowsWriteRequest request,
  Map<String, dynamic>? claim,
) => store.runInTransaction(TxMode.read, () {
  if (claim == null) {
    return {
      'version': 1,
      'state': 'unclaimed',
      'persisted_readback_proven': false,
    };
  }
  if (claim['version'] != 1 ||
      claim['binding'] != request.binding ||
      claim['account'] is! String ||
      claim['guid'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(claim['account'] as String) ||
      !RegExp(
        r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
      ).hasMatch(claim['guid'] as String)) {
    throw StateError('windows_write_proof_claim_mismatch');
  }
  final guidHash = sha256
      .convert(
        utf8.encode(
          jsonEncode(['cloud-sync-local-send-guid-v1', claim['guid']]),
        ),
      )
      .toString();
  final query =
      store
          .box<CloudSyncLocalSendIntentEntity>()
          .query(
            CloudSyncLocalSendIntentEntity_.accountFingerprint
                .equals(claim['account'] as String)
                .and(
                  CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                    guidHash,
                  ),
                ),
          )
          .build()
        ..limit = 2;
  final List<CloudSyncLocalSendIntentEntity> rows;
  try {
    rows = query.find();
  } finally {
    query.close();
  }
  if (rows.length != 1) {
    return {
      'version': 1,
      'state': rows.isEmpty ? 'claim_without_intent' : 'ambiguous_intent',
      'persisted_readback_proven': false,
    };
  }
  final intent = rows.single;
  var exactSource = false;
  String? validationFailure;
  try {
    final journal = CloudSyncLocalSendJournal.forRetainedQueueInspection(
      store,
      claim['account'] as String,
    );
    if (journal == null) {
      throw StateError('cloud_sync_local_send_authority_changed');
    }
    if (request.isGroup) {
      journal.readExactGroupIntent(
        intentId: intent.id,
        expectedChatGuid: request.restoredGroupGuid!,
        expectedMembers: request.recipients,
        expectedSender: request.sender,
        expectedSourceSha256: intent.sourceSha256,
      );
    } else {
      journal.readExactIntent(
        intentId: intent.id,
        expectedRecipient: request.recipient,
        expectedSourceSha256: intent.sourceSha256,
      );
    }
    exactSource = true;
  } catch (error) {
    validationFailure = cloudSyncV2SafeFailureCode(error);
  }
  final operationQuery = store
      .box<CloudOutboxOperationEntity>()
      .query(
        CloudOutboxOperationEntity_.operationId.equals(
          intent.admittedOperationId ?? '',
        ),
      )
      .build();
  final CloudOutboxOperationEntity? operation;
  try {
    operation = operationQuery.findUnique();
  } finally {
    operationQuery.close();
  }
  final message = store.box<Message>().get(intent.localMessageId);
  final duplicates = store
      .box<Message>()
      .query(Message_.guid.equals(claim['guid'] as String))
      .build();
  final int matchingMessages;
  try {
    matchingMessages = duplicates.count();
  } finally {
    duplicates.close();
  }
  final bodyMatches =
      message != null &&
      message.text == request.text &&
      message.guid == claim['guid'] &&
      message.stagingGuid == null &&
      message.isFromMe == true &&
      message.dateDeleted == null &&
      message.chat.target?.usingHandle == 'mailto:${request.sender}' &&
      message.attributedBody.length == 1 &&
      message.attributedBody.single.string == request.text;
  final positiveIds =
      intent.idsConfirmationVersion == cloudSyncIdsConfirmationVersion;
  final readbackMarker =
      intent.state == 2 &&
      intent.confirmedReadbackBindingSha256 != null &&
      intent.confirmedReadbackBindingSha256 == intent.admittedBindingSha256;
  final settled =
      operation != null &&
      operation.state == 2 &&
      operation.confirmedAtMs > 0 &&
      operation.serverRecordIdHash != null &&
      operation.protectedLeaseReference == null &&
      operation.leaseIdHash == null &&
      operation.leaseExpiresAtMs == 0;
  return {
    'version': 1,
    'state': 'inspected',
    'proof_scope': 'persisted_exact_readback_not_fresh_Apple_request',
    'ids_confirmation_version': intent.idsConfirmationVersion,
    'positive_ids_confirmation': positiveIds,
    'exact_source_validated': exactSource,
    'validation_failure': validationFailure,
    'single_canonical_message': matchingMessages == 1,
    'legible_test_body_matches': bodyMatches,
    'readback_marker_matches_admission': readbackMarker,
    'confirmed_receipt_released': settled,
    'save_attempt_count': operation?.attemptCount,
    'persisted_readback_proven':
        positiveIds &&
        exactSource &&
        matchingMessages == 1 &&
        bodyMatches &&
        readbackMarker &&
        settled,
  };
});
