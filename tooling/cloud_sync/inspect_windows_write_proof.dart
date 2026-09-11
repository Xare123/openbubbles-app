import 'dart:convert';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:crypto/crypto.dart';

/// Offline evidence only. Does not contact Apple or grant mutation authority.
/// Reuses the production exact-intent validator instead of reconstructing its
/// routing, checkpoint, mapping and immutable-envelope predicates here.
Map<String, Object?> inspectWindowsWriteProof(
  Store store,
  CloudSyncWindowsWriteRequest request,
  Map<String, dynamic>? claim, {
  Map<String, dynamic>? parentClaim,
}) => store.runInTransaction(TxMode.read, () {
  if (claim == null) {
    return {
      'version': 1,
      'state': 'unclaimed',
      'persisted_readback_proven': false,
    };
  }
  if (request.mutationType != null) {
    return _inspectMutation(store, request, claim, parentClaim);
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
      ...readWrittenRecordIngestionDiagnostic(store, operation),
      'persisted_readback_proven': false,
    };
  }
  if (request.reactionType != null) {
    final targetMatches =
        parentClaim != null &&
        parentClaim['version'] == 1 &&
        parentClaim['account'] == claim['account'] &&
        parentClaim['guid'] is String &&
        message?.associatedMessageGuid == parentClaim['guid'] &&
        message?.associatedMessagePart == request.reactionPart &&
        message?.associatedMessageType == request.reactionType &&
        message?.associatedMessageEmoji == null &&
        message?.isFromMe == true &&
        message?.dateDeleted == null &&
        message?.dateEdited == null;
    final positiveIds =
        intent.idsConfirmationVersion == cloudSyncIdsConfirmationVersion;
    return {
      'version': 1,
      'state': 'inspected',
      'request_kind': 'reaction-v5',
      'proof_scope': 'persisted_exact_readback_not_fresh_Apple_request',
      'positive_ids_confirmation': positiveIds,
      'exact_source_validated': exactSource,
      'validation_failure': validationFailure,
      'single_canonical_message': matchingMessages == 1,
      'reaction_target_matches_request': targetMatches,
      'readback_marker_matches_admission': readbackMarker,
      'confirmed_receipt_released': settled,
      'persisted_readback_proven':
          positiveIds &&
          exactSource &&
          matchingMessages == 1 &&
          targetMatches &&
          readbackMarker &&
          settled,
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
    'canonical_direct_chat': !request.isGroup &&
        message?.chat.target?.guid == 'iMessage;-;${request.recipient}' &&
        message?.chat.target?.chatIdentifier == request.recipient,
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

// Stored-row diagnostics only. The real runtime separately reopens the source
// and verifies the protected receipt. A marker in this copied DB is no substitute
// for that, nor evidence of a CloudKit update or another device's display.
Map<String, Object?> _inspectMutation(
  Store store,
  CloudSyncWindowsWriteRequest request,
  Map<String, dynamic> claim,
  Map<String, dynamic>? parentClaim,
) {
  if (claim['version'] != 2 ||
      claim['purpose'] != 'mutation' ||
      claim['binding'] != request.binding ||
      claim['account'] is! String ||
      claim['guid'] is! String ||
      claim['local_message_id'] is! int ||
      claim['target_guid_hash'] is! String ||
      claim['source_sha256'] is! String) {
    throw StateError('windows_mutation_proof_claim_mismatch');
  }
  String guidHash(String guid) => sha256
      .convert(utf8.encode(jsonEncode(['cloud-sync-local-send-guid-v1', guid])))
      .toString();
  final mutationHash = guidHash(claim['guid'] as String);
  final query =
      store
          .box<CloudSyncLocalMutationIntentEntity>()
          .query(
            CloudSyncLocalMutationIntentEntity_.accountFingerprint
                .equals(claim['account'] as String)
                .and(
                  CloudSyncLocalMutationIntentEntity_.mutationGuidHash.equals(
                    mutationHash,
                  ),
                ),
          )
          .build()
        ..limit = 2;
  final List<CloudSyncLocalMutationIntentEntity> rows;
  try {
    rows = query.find();
  } finally {
    query.close();
  }
  if (rows.length != 1) {
    return {
      'version': 1,
      'state': rows.isEmpty ? 'claim_without_intent' : 'ambiguous_intent',
      'proof_scope': 'db_only_mutation_diagnostics',
      'persisted_readback_proven': false,
    };
  }
  final row = rows.single;
  validateCloudSyncMutationRow(row);
  if (row.localMessageId != claim['local_message_id'] ||
      row.targetGuidHash != claim['target_guid_hash'] ||
      row.sourceSha256 != claim['source_sha256'] ||
      row.targetPart != request.mutationPart ||
      row.kind != (request.mutationType == 'edit' ? 0 : 1)) {
    throw StateError('windows_mutation_proof_claim_mismatch');
  }
  final target = store.box<Message>().get(row.localMessageId);
  final chat = target?.chat.target;
  final targetMatches =
      parentClaim?['version'] == 1 &&
      parentClaim?['account'] == claim['account'] &&
      parentClaim?['guid'] is String &&
      target?.guid == parentClaim?['guid'] &&
      guidHash(parentClaim!['guid'] as String) == row.targetGuidHash &&
      target?.chat.targetId == row.localChatId &&
      target?.isFromMe == true &&
      target?.dateDeleted == null &&
      target?.dateScheduled == null &&
      target?.verificationFailed == false &&
      chat?.guid == 'iMessage;-;${request.recipient}' &&
      chat?.chatIdentifier == request.recipient &&
      chat?.usingHandle == 'mailto:${request.sender}';
  final summary = target?.messageSummaryInfo.length == 1
      ? target!.messageSummaryInfo.single
      : null;
  final history = summary?.editedContent['0'];
  final lastBody = history?.isNotEmpty == true ? history!.last.text : null;
  final displayMatches =
      targetMatches &&
      target!.dateEdited != null &&
      (request.mutationType == 'edit'
          ? target.text == request.text &&
                target.attributedBody.length == 1 &&
                target.attributedBody.single.string == request.text &&
                summary?.retractedParts.isEmpty == true &&
                summary?.editedParts.contains(0) == true &&
                lastBody?.values.length == 1 &&
                lastBody!.values.single.string == request.text
          : summary?.retractedParts.where((part) => part == 0).length == 1);
  final initial = store
      .box<CloudSyncLocalSendIntentEntity>()
      .query(
        CloudSyncLocalSendIntentEntity_.accountFingerprint
            .equals(claim['account'] as String)
            .and(
              CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                mutationHash,
              ),
            ),
      )
      .build();
  final int initialCount;
  try {
    initialCount = initial.count();
  } finally {
    initial.close();
  }
  return {
    'version': 1,
    'state': 'inspected',
    'proof_scope': 'db_only_mutation_diagnostics',
    'request_kind': 'mutation-v6',
    'mutation_kind': request.mutationType,
    'intent_state': row.state,
    'source_binding_structurally_valid': true,
    'positive_ids_receipt_marker_present': row.idsReceiptBindingSha256 != null,
    'local_reflection_marker_present': row.reflectedSnapshotSha256 != null,
    'target_matches_claim_and_route': targetMatches,
    'stored_display_matches_request': displayMatches,
    'initial_send_intents_for_mutation': initialCount,
    'outbox_count': store.box<CloudOutboxOperationEntity>().count(),
    'persisted_readback_proven': false,
  };
}

/// Ingestion evidence is separate from upload receipts and local projection.
/// Compare before/after a real read-only pull; this never contacts Apple.
Map<String, Object?> readWrittenRecordIngestionDiagnostic(
  Store store,
  CloudOutboxOperationEntity? operation,
) {
  if (operation == null || operation.serverRecordIdHash == null) {
    return {'written_record_ingestion': null};
  }
  final query = store.box<CloudInboxChangeEntity>().query(
    CloudInboxChangeEntity_.accountFingerprint.equals(operation.accountFingerprint)
      .and(CloudInboxChangeEntity_.zone.equals(operation.zone))
      .and(CloudInboxChangeEntity_.scopeKey.equals(operation.scopeKey))
      .and(CloudInboxChangeEntity_.serverRecordIdHash.equals(operation.serverRecordIdHash!)),
  ).build()..limit = 129;
  try {
    final rows = query.find();
    if (rows.length > 128) return {'written_record_ingestion': null};
    return {
      'written_record_ingestion': {
        'count': rows.length,
        'statuses': rows.map((row) => row.status).toList()..sort(),
        'tombstones': rows.where((row) => row.isTombstone).length,
        'latest_created_at_ms': rows.isEmpty ? null : rows
          .map((row) => row.createdAtMs).reduce((a, b) => a > b ? a : b),
      },
    };
  } finally {
    query.close();
  }
}

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
