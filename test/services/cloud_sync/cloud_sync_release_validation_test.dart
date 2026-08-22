import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_shadow_journal_budget.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  CloudSyncScope scope() => CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'container',
    database: 'private',
    zone: 'messages',
  );

  Matcher redactedArgument(String safeMessage, {String? secret}) {
    return throwsA(
      predicate<ArgumentError>((error) {
        final rendered = error.toString();
        return rendered.contains(safeMessage) &&
            (secret == null || !rendered.contains(secret));
      }, 'fixed redacted ArgumentError'),
    );
  }

  test('scope and fetched-change invariants survive release mode', () {
    for (final invalidFingerprint in [
      '',
      'short',
      'raw-account@example.com',
      '$testAccountFingerprintA=',
      '${List.filled(42, 'A').join()}\u001f',
    ]) {
      expect(
        () => CloudSyncScope(
          accountFingerprint: invalidFingerprint,
          container: 'container',
          database: 'private',
          zone: 'messages',
        ),
        redactedArgument(
          'cloud_sync_scope_account_fingerprint_invalid',
          secret: invalidFingerprint.isEmpty ? null : invalidFingerprint,
        ),
      );
    }
    expect(
      () => CloudFetchedChange(
        changeId: 'change',
        recordIdHash: 'record',
        type: CloudChangeType.delete,
      ),
      redactedArgument('cloud_fetched_tombstone_type_invalid'),
    );
    expect(
      () => CloudFetchedChange(
        changeId: 'change',
        recordIdHash: 'record',
        type: CloudChangeType.save,
        encryptedPayloadReference: '',
      ),
      redactedArgument('cloud_fetched_payload_reference_invalid'),
    );
    expect(
      () => CloudFetchBatch(
        scope: scope(),
        changes: const [],
        batchId: 'batch',
        generation: -1,
        nextToken: null,
        hasMore: false,
      ),
      redactedArgument('cloud_fetch_batch_generation_invalid'),
    );
    expect(
      () => CloudFetchBatch(
        scope: scope(),
        changes: const [],
        batchId: 'batch',
        generation: 0,
        nextToken: null,
        hasMore: false,
      ),
      redactedArgument('cloud_fetch_batch_generation_invalid'),
    );
  });

  test('failure diagnostic codes are allowlisted and never echo secrets', () {
    const secret = 'server body: secret-token';
    expect(
      () => CloudSyncFailure(
        category: CloudFailureCategory.server,
        safeCode: secret,
      ),
      redactedArgument('cloud_sync_failure_safe_code_invalid', secret: secret),
    );
    expect(
      () => CloudSyncFailure(
        category: CloudFailureCategory.network,
        retryAfter: const Duration(microseconds: -1),
      ),
      redactedArgument('cloud_sync_failure_retry_after_invalid'),
    );

    final valid = CloudSyncFailure(
      category: CloudFailureCategory.network,
      safeCode: 'network_retry-1',
    );
    expect(valid.toString(), contains('network_retry-1'));
  });

  test('checkpoint and outbox counters reject invalid release values', () {
    expect(
      () => CloudSyncCheckpoint(scope: scope(), consecutivePullFailures: -1),
      redactedArgument('cloud_checkpoint_pull_failures_invalid'),
    );
    expect(
      () => CloudSyncCheckpoint(scope: scope(), generation: 0),
      redactedArgument('cloud_checkpoint_generation_invalid'),
    );
    expect(
      () => CloudInboxEntry(
        scope: scope(),
        sequence: 1,
        change: CloudFetchedChange(
          changeId: 'change',
          recordIdHash: 'record',
          type: CloudChangeType.save,
        ),
        status: CloudInboxStatus.pending,
        attemptCount: 0,
        createdAt: DateTime.utc(2026),
        batchId: 'batch',
        generation: 0,
      ),
      redactedArgument('cloud_inbox_generation_invalid'),
    );
    expect(
      () => CloudInboxEntry(
        scope: scope(),
        sequence: 1,
        change: CloudFetchedChange(
          changeId: 'change',
          recordIdHash: 'record',
          type: CloudChangeType.save,
        ),
        status: CloudInboxStatus.pending,
        attemptCount: -1,
        createdAt: DateTime.utc(2026),
        batchId: 'batch',
        generation: 1,
      ),
      redactedArgument('cloud_inbox_attempt_count_invalid'),
    );
    expect(
      () => CloudOutboxDraft(
        scope: scope(),
        logicalEntityKeyHash: 'logical-key',
        action: CloudOutboxAction.save,
        payloadVersion: 1,
        dependencyOperationIds: const [],
        createdAt: DateTime.utc(2026),
      ),
      redactedArgument('cloud_outbox_draft_save_payload_missing'),
    );
  });

  test('merge metadata validates identity and revisions', () {
    expect(
      () => CloudEditPart(
        partKeyHash: 'part',
        revision: -1,
        contentDigest: 'digest',
        modifiedAt: DateTime.utc(2026),
      ),
      redactedArgument('cloud_edit_part_revision_invalid'),
    );

    expect(
      () => CloudSemanticSnapshot(
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: '',
      ),
      redactedArgument('cloud_semantic_snapshot_logical_key_invalid'),
    );
    expect(
      () => CloudSemanticSnapshot(
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: 'logical-key',
        groupVersion: -1,
      ),
      redactedArgument('cloud_semantic_snapshot_group_version_invalid'),
    );
  });

  test('semantic payload and mutation envelopes fail closed', () {
    expect(
      () => CloudAttachmentEntityPayload(
        logicalEntityKeyHash: 'attachment-key',
        canonicalGuid: 'attachment-guid',
        ownerLogicalKeyHash: '',
        ownerCanonicalGuid: 'owner-message-guid',
        ownerPart: 0,
        fileName: 'file',
        mimeType: null,
        protectedLocalReference: 'protected-ref',
      ),
      redactedArgument('cloud_attachment_payload_owner_key_invalid'),
    );

    final snapshot = CloudSemanticSnapshot(
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: 'message-key',
    );
    final mismatchedPayload = CloudChatEntityPayload(
      logicalEntityKeyHash: 'message-key',
      canonicalGuid: 'chat-guid',
      chatIdentifier: 'iMessage;-;chat',
      displayName: null,
      participantHandles: const [],
    );
    expect(
      () => CloudDecodedMutation.upsert(
        scope: scope(),
        generation: 0,
        changeId: 'change',
        snapshot: snapshot,
        payload: mismatchedPayload,
      ),
      redactedArgument('cloud_decoded_mutation_generation_invalid'),
    );
    expect(
      () => CloudDecodedMutation.upsert(
        scope: scope(),
        generation: 1,
        changeId: 'change',
        snapshot: snapshot,
        payload: mismatchedPayload,
      ),
      redactedArgument('cloud_decoded_mutation_kind_mismatch'),
    );
    expect(
      () => CloudSemanticTombstone(
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: '',
        deletedAt: null,
        serverConfirmed: true,
      ),
      redactedArgument('cloud_semantic_tombstone_logical_key_invalid'),
    );
  });

  test('transient canonical identities stay redacted from diagnostics', () {
    const sentinels = <String>[
      'message-guid-sensitive',
      'chat-guid-sensitive',
      'iMessage;-;sensitive-chat',
      'attachment-guid-sensitive',
      'owner-message-guid-sensitive',
      'reaction-guid-sensitive',
      'parent-message-guid-sensitive',
      'group-photo-guid-sensitive',
    ];
    final payloads = <CloudSemanticEntityPayload>[
      CloudMessageEntityPayload(
        logicalEntityKeyHash: 'message-key',
        canonicalGuid: sentinels[0],
        chatAliasKeyHash: 'chat-key',
        chatIdentifier: sentinels[2],
        body: 'body-sensitive',
        senderHandle: 'sender-sensitive',
      ),
      CloudChatEntityPayload(
        logicalEntityKeyHash: 'chat-key',
        canonicalGuid: sentinels[1],
        chatIdentifier: sentinels[2],
        displayName: 'display-sensitive',
        participantHandles: const ['participant-sensitive'],
      ),
      CloudAttachmentEntityPayload(
        logicalEntityKeyHash: 'attachment-key',
        canonicalGuid: sentinels[3],
        ownerLogicalKeyHash: 'message-key',
        ownerCanonicalGuid: sentinels[4],
        ownerPart: 0,
        fileName: 'file-sensitive.pdf',
        mimeType: 'application/pdf',
        protectedLocalReference: 'protected-reference-sensitive',
      ),
      CloudReactionEntityPayload(
        logicalEntityKeyHash: 'reaction-key',
        canonicalGuid: sentinels[5],
        parentLogicalKeyHash: 'message-key',
        parentCanonicalGuid: sentinels[6],
        parentPart: 0,
        senderHandle: 'sender-sensitive',
        reactionType: 'like',
      ),
      CloudGroupPhotoEntityPayload(
        logicalEntityKeyHash: 'group-photo-key',
        ownerLogicalKeyHash: 'chat-key',
        photoGuid: sentinels[7],
        protectedLocalReference: 'group-photo-reference-sensitive',
      ),
    ];

    for (final payload in payloads) {
      final rendered = payload.toString();
      expect(rendered, contains('redacted'));
      for (final sentinel in sentinels) {
        expect(rendered, isNot(contains(sentinel)));
      }
    }
  });

  test('engine, observer, and journal budgets validate at construction', () {
    expect(
      () => CloudSyncEngineConfig(maximumBatchSize: 257),
      redactedArgument('cloud_sync_config_batch_size_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(fetchOperationTimeout: Duration.zero),
      redactedArgument('cloud_sync_config_fetch_timeout_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(maximumFetchPagesPerRun: 65),
      redactedArgument('cloud_sync_config_fetch_pages_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(maximumInboxEntriesPerRun: 4097),
      redactedArgument('cloud_sync_config_inbox_entries_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(maximumOutboxBatchesPerRun: 65),
      redactedArgument('cloud_sync_config_outbox_batches_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(maximumUnknownAttempts: 17),
      redactedArgument('cloud_sync_config_unknown_attempts_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(
        fetchOperationTimeout: const Duration(minutes: 5, microseconds: 1),
      ),
      redactedArgument('cloud_sync_config_fetch_timeout_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(
        coordinatorLeaseDuration: const Duration(minutes: 30, microseconds: 1),
      ),
      redactedArgument('cloud_sync_config_coordinator_lease_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(
        outboxLeaseDuration: const Duration(minutes: 30, microseconds: 1),
      ),
      redactedArgument('cloud_sync_config_outbox_lease_invalid'),
    );
    expect(
      () => CloudSyncEngineConfig(
        pausedRetryDelay: const Duration(days: 30, microseconds: 1),
      ),
      redactedArgument('cloud_sync_config_paused_retry_invalid'),
    );
    expect(
      () => MemoryCloudSyncObserver(maximumEvents: 0),
      redactedArgument('cloud_sync_observer_capacity_invalid'),
    );
    expect(
      () => MemoryCloudSyncObserver(maximumEvents: 4097),
      redactedArgument('cloud_sync_observer_capacity_invalid'),
    );
    expect(
      () => CloudShadowJournalBudget(maximumPendingAge: Duration.zero),
      redactedArgument('cloud_shadow_budget_age_invalid'),
    );
    expect(
      () => CloudShadowJournalBudget(maximumEntriesPerScope: 16 * 1024 + 1),
      redactedArgument('cloud_shadow_budget_entries_invalid'),
    );
    expect(
      () => CloudShadowJournalBudget(
        maximumEstimatedBytesPerScope: 128 * 1024 * 1024 + 1,
      ),
      redactedArgument('cloud_shadow_budget_bytes_invalid'),
    );
    expect(
      () => CloudShadowJournalBudget(
        maximumPendingAge: const Duration(days: 30, microseconds: 1),
      ),
      redactedArgument('cloud_shadow_budget_age_invalid'),
    );
    expect(
      () => CloudShadowJournalUsage(
        pendingEntries: 0,
        estimatedBytes: 0,
        oldestPendingAt: DateTime.utc(2026),
      ),
      redactedArgument('cloud_shadow_usage_oldest_invalid'),
    );
    expect(
      () => CloudShadowJournalAdmission(
        insertedEntries: 1,
        rejectedEntries: 1,
        usage: CloudShadowJournalUsage.empty,
        blockReason: CloudShadowJournalBlockReason.maximumEntries,
      ),
      redactedArgument('cloud_shadow_admission_blocked_insert_invalid'),
    );
  });
}
