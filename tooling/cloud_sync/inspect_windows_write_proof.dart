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
  if (request.attachmentFixture != null) {
    // DB-only diagnostics cannot establish attachment child readback proof.
    return {
      'version': 1,
      'state': 'inspected',
      'proof_scope': 'db_only_attachment_diagnostics',
      'request_kind': 'attachment-v4',
      'intent_state': intent.state,
      'exact_source_validated': exactSource,
      'validation_failure': validationFailure,
      'positive_ids_confirmation':
          intent.idsConfirmationVersion == cloudSyncIdsConfirmationVersion,
      'single_canonical_message': matchingMessages == 1,
      'persisted_attachment_count': message?.dbAttachments.length,
      ...readAttachmentUploadDiagnostic(
        store,
        intentId: intent.id,
        accountFingerprint: claim['account'] as String,
      ),
      'parent_operation_present': operation != null,
      'parent_operation_state': operation?.state,
      'parent_readback_marker_matches_admission': readbackMarker,
      'parent_confirmed_receipt_released': settled,
      'parent_save_attempt_count': operation?.attemptCount,
      'persisted_readback_proven': false,
    };
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

/// Query failure is unknown, never evidence of zero upload rows.
Map<String, Object?> readAttachmentUploadDiagnostic(
  Store store, {
  required int intentId,
  required String accountFingerprint,
}) {
  try {
    final query = store
        .box<CloudAttachmentUploadEntity>()
        .query(
          CloudAttachmentUploadEntity_.localSendIntentId
              .equals(intentId)
              .and(
                CloudAttachmentUploadEntity_.accountFingerprint.equals(
                  accountFingerprint,
                ),
              ),
        )
        .build();
    try {
      final rows = query.find();
      return {
        'attachment_upload_row_count': rows.length,
        'attachment_upload_states': rows.map((row) => row.state).toList()
          ..sort(),
        'attachment_child_operations': rows
            .map((row) => _readAttachmentChildDiagnostic(store, row))
            .toList(),
        'attachment_upload_failure': null,
      };
    } finally {
      query.close();
    }
  } catch (_) {
    return {
      'attachment_upload_row_count': null,
      'attachment_upload_states': null,
      'attachment_child_operations': null,
      'attachment_upload_failure':
          'cloud_sync_windows_proof_upload_query_failed',
    };
  }
}

Map<String, Object?> _readAttachmentChildDiagnostic(
  Store store,
  CloudAttachmentUploadEntity upload,
) {
  final operationId = upload.admittedOperationId;
  if (operationId == null) return {'matching_operations': 0};
  final query =
      store
          .box<CloudOutboxOperationEntity>()
          .query(
            CloudOutboxOperationEntity_.operationId
                .equals(operationId)
                .and(
                  CloudOutboxOperationEntity_.accountFingerprint
                      .equals(upload.accountFingerprint)
                      .and(
                        CloudOutboxOperationEntity_.zone.equals(
                          'attachmentManateeZone',
                        ),
                      ),
                ),
          )
          .build()
        ..limit = 2;
  try {
    final rows = query.find();
    if (rows.length != 1) return {'matching_operations': rows.length};
    final row = rows.single;
    return {
      'matching_operations': 1,
      'state': row.state,
      'attempt_count': row.attemptCount,
      'generation_matches_upload':
          row.checkpointGeneration == upload.checkpointGeneration,
      'record_matches_upload':
          row.serverRecordIdHash == upload.serverRecordIdHash,
      'payload_reference_retained': row.encryptedPayloadRef != null,
      'receipt_lease_retained': row.protectedLeaseReference != null,
      'confirmed_timestamp_present': row.confirmedAtMs > 0,
      // These are diagnostics only, never a substitute for native readback.
    };
  } finally {
    query.close();
  }
}
