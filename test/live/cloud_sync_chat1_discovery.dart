// Test-host-only, bounded discovery of the protected Chat1 zone. The caller
// receives counts and safe codes only; record identifiers and content stay in
// the protected local journal.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_runtime.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/shadow_only_cloud_sync_store.dart';
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;
import 'package:bluebubbles/src/rust/api/cloud_sync_chat1_correlation.dart'
    as correlation_api;
import 'package:path/path.dart' as path;

Future<Map<String, Object?>> observeChat1Discovery({
  required Store store,
  required Directory profile,
  required CloudSyncNativeAuthSnapshot auth,
  required Object pauseToken,
  required CloudSyncNativeAuthSnapshotReader readCurrentBoundAuth,
}) async {
  if (pauseToken is! BigInt ||
      pauseToken <= BigInt.zero ||
      pauseToken.bitLength > 64) {
    throw StateError('chat1_discovery_pause_capability_invalid');
  }
  if (auth.cloudMessagesClient
      is! rustlib.ArcCloudMessagesClientDefaultAnisetteProvider) {
    throw StateError('chat1_discovery_client_invalid');
  }
  final initialAuth = await readCurrentBoundAuth();
  if (!auth.sameIdentity(initialAuth)) {
    throw StateError('account_changed');
  }

  final scope = _chat1Scope(auth.accountFingerprint);
  final protector = RustCloudSyncProtector(storageDirectory: profile.path);
  final durableStore = ObjectBoxCloudSyncStore(
    store: store,
    protector: protector,
  );
  final shadowStore = ShadowOnlyCloudSyncStore(durableStore);
  final budget = CloudSyncManualShadowSampler.journalBudget;
  final beforeCheckpoint = await shadowStore.readCheckpoint(scope);
  final beforeUsage = await shadowStore.readShadowJournalUsage(
    scope,
    budget: budget,
  );
  final beforeOutboxCount = store.box<CloudOutboxOperationEntity>().count();
  final beforeCanonicalCounts = <int>[
    store.box<Chat>().count(),
    store.box<Message>().count(),
    store.box<Attachment>().count(),
  ];

  Future<CloudSyncNativeAuthSnapshot?> readBoundAuth() async {
    final current = await readCurrentBoundAuth();
    return auth.sameIdentity(current) ? current : null;
  }

  final bindings = FrbNativeProtectedCloudSyncBindings.chat1Discovery(
    nativeWriterPauseToken: pauseToken,
  );
  final rawTransport = NativeProtectedCloudSyncTransport(
    cloudMessagesClient: auth.cloudMessagesClient,
    storageDirectory: profile.path,
    protectedStoreIdentity: auth.protectedStoreIdentity,
    bindings: bindings,
  );
  final guardedTransport = AccountBoundShadowTransport(
    delegate: rawTransport,
    readActiveFingerprint: () async {
      final current = await readBoundAuth();
      return current?.accountFingerprint;
    },
    expectedFingerprint: auth.accountFingerprint,
  );
  final engine = CloudSyncEngine(
    scope: scope,
    coordinatorId: 'windows-chat1-discovery-${auth.nativeSessionId}',
    architectureName: 'windows-test-host',
    store: shadowStore,
    transport: guardedTransport,
    inboxApplier: const RejectingShadowInboxApplier(),
    refreshIdentityReader: () async {
      final current = await readBoundAuth();
      if (current == null) return null;
      return CloudSyncRefreshIdentity.fromNative(
        accountFingerprint: current.accountFingerprint,
        nativeSessionId: current.nativeSessionId,
        protectedStoreIdentity: current.protectedStoreIdentity,
      );
    },
    config: CloudSyncEngineConfig(
      maximumBatchSize: CloudSyncManualShadowSampler.changeLimit,
      maximumFetchPagesPerRun: CloudSyncManualShadowSampler.pageLimit,
      maximumInboxEntriesPerRun: CloudSyncManualShadowSampler.changeLimit,
      maximumOutboxBatchesPerRun: 1,
      fetchOperationTimeout: const Duration(seconds: 45),
      allowManualPullBackoffOverride: true,
      shadowJournalBudget: budget,
      flags: const CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: false,
        saves: false,
        deletions: false,
        profiles: false,
        notificationHints: false,
      ),
    ),
  );
  CloudSyncShadowRuntime? runtime;
  late final CloudSyncRunResult result;
  try {
    runtime = CloudSyncShadowRuntime(
      engines: [engine],
      automaticTriggersEnabled: false,
      debounce: Duration.zero,
    );
    result = (await runtime.synchronizeNow()).single;
  } finally {
    try {
      await runtime?.dispose();
    } finally {
      await rawTransport.quiesceNativeOperations();
    }
  }

  final afterCheckpoint = await shadowStore.readCheckpoint(scope);
  final afterUsage = await shadowStore.readShadowJournalUsage(
    scope,
    budget: budget,
  );
  final cachedShape = _inspectCachedJournalShape(
    store,
    scope,
    generation: afterCheckpoint.generation,
  );
  final afterOutboxCount = store.box<CloudOutboxOperationEntity>().count();
  final afterCanonicalCounts = <int>[
    store.box<Chat>().count(),
    store.box<Message>().count(),
    store.box<Attachment>().count(),
  ];
  final finalAuth = await readCurrentBoundAuth();
  if (!auth.sameIdentity(finalAuth)) {
    throw StateError('account_changed');
  }

  final counters = result.counters;
  final zeroMutationCounters =
      counters.applied == 0 &&
      counters.confirmed == 0 &&
      counters.deferred == 0 &&
      counters.retried == 0;
  final canonicalCountsUnchanged = _sameCounts(
    beforeCanonicalCounts,
    afterCanonicalCounts,
  );
  final outboxCountUnchanged = beforeOutboxCount == afterOutboxCount;
  if (!zeroMutationCounters ||
      !canonicalCountsUnchanged ||
      !outboxCountUnchanged) {
    throw StateError('chat1_discovery_write_tripwire');
  }

  return <String, Object?>{
    'account_bound': true,
    'scope': 'chat1ManateeZone',
    'page_limit': CloudSyncManualShadowSampler.pageLimit,
    'change_limit': CloudSyncManualShadowSampler.changeLimit,
    'checkpoint_was_fresh':
        beforeCheckpoint.fetchedToken == null &&
        beforeCheckpoint.fetchedSequence == 0,
    'checkpoint_before': <String, Object?>{
      'generation': beforeCheckpoint.generation,
      'has_token': beforeCheckpoint.fetchedToken != null,
      'fetched_sequence': beforeCheckpoint.fetchedSequence,
      'has_pending_batch': beforeCheckpoint.pendingBatchId != null,
    },
    'checkpoint_after': <String, Object?>{
      'generation': afterCheckpoint.generation,
      'has_token': afterCheckpoint.fetchedToken != null,
      'fetched_sequence': afterCheckpoint.fetchedSequence,
      'has_pending_batch': afterCheckpoint.pendingBatchId != null,
    },
    'journal_before': <String, Object?>{
      'entries': beforeUsage.pendingEntries,
      'estimated_bytes': beforeUsage.estimatedBytes,
    },
    'journal_after': <String, Object?>{
      'entries': afterUsage.pendingEntries,
      'estimated_bytes': afterUsage.estimatedBytes,
    },
    'cached_shape_after': cachedShape,
    'status': result.status.name,
    'fetched': counters.fetched,
    'journaled': counters.shadowJournalEntries,
    'journal_rejected': counters.shadowJournalRejectedEntries,
    'journal_estimated_bytes': counters.shadowJournalEstimatedBytes,
    'failure_category': result.failureCategory?.name,
    'failure_safe_code': result.failureSafeCode,
    'skip_reason': result.skipReason?.name,
    'journal_block_reason': result.shadowJournalBlockReason?.name,
    'empty_terminal_read': result.observedEmptyTerminalRead,
    'zero_mutation_counters': zeroMutationCounters,
    'canonical_counts_unchanged': canonicalCountsUnchanged,
    'outbox_count_unchanged': outboxCountUnchanged,
  };
}

Map<String, Object?> inspectCachedChat1Journal({
  required Store store,
  required CloudSyncNativeAuthSnapshot auth,
}) {
  final scope = _chat1Scope(auth.accountFingerprint);
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final checkpointQuery = store
      .box<CloudSyncCheckpointEntity>()
      .query(CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey))
      .build();
  late final CloudSyncCheckpointEntity checkpoint;
  try {
    checkpoint =
        checkpointQuery.findUnique() ??
        (throw StateError('chat1_discovery_checkpoint_missing'));
  } finally {
    checkpointQuery.close();
  }
  if (checkpoint.accountFingerprint != auth.accountFingerprint ||
      checkpoint.container != scope.container ||
      checkpoint.database != scope.database ||
      checkpoint.zone != scope.zone ||
      checkpoint.persistenceLane != scope.persistenceLane.name ||
      checkpoint.generation <= 0 ||
      checkpoint.pendingBatchId != null ||
      checkpoint.pendingFetchedTokenCiphertext != null) {
    throw StateError('chat1_discovery_checkpoint_invalid');
  }
  return <String, Object?>{
    'account_bound': true,
    'scope': 'chat1ManateeZone',
    'network_read_performed': false,
    'checkpoint': <String, Object?>{
      'generation': checkpoint.generation,
      'has_token': checkpoint.fetchedTokenCiphertext != null,
      'fetched_sequence': checkpoint.fetchedSequence,
      'applied_sequence': checkpoint.appliedSequence,
      'has_pending_batch': false,
    },
    'cached_shape': _inspectCachedJournalShape(
      store,
      scope,
      generation: checkpoint.generation,
    ),
  };
}

Future<Map<String, Object?>> correlateCachedChat1Routes({
  required Store store,
  required Directory profile,
  required CloudSyncNativeAuthSnapshot auth,
  required Object pauseToken,
  required CloudSyncNativeAuthSnapshotReader readCurrentBoundAuth,
}) async {
  final semanticCorrelation =
      Platform.environment['OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION'] ==
      '1';
  if (pauseToken is! BigInt ||
      pauseToken <= BigInt.zero ||
      pauseToken.bitLength > 64) {
    throw StateError('chat1_correlation_pause_capability_invalid');
  }
  final client = auth.cloudMessagesClient;
  if (client is! rustlib.ArcCloudMessagesClientDefaultAnisetteProvider) {
    throw StateError('chat1_correlation_client_invalid');
  }
  final initialAuth = await readCurrentBoundAuth();
  if (!auth.sameIdentity(initialAuth)) {
    throw StateError('account_changed');
  }
  final targets = _requiredTargetMessageHashes();
  final messageScope = CloudSyncScope(
    accountFingerprint: auth.accountFingerprint,
    container: CloudSyncManualShadowSampler.container,
    database: CloudSyncManualShadowSampler.database,
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final chat1Scope = _chat1Scope(auth.accountFingerprint);
  final messageCheckpoint = _requireCheckpoint(store, messageScope);
  final chat1Checkpoint = _requireCheckpoint(store, chat1Scope);
  final messageRows = <CloudInboxChangeEntity>[];
  for (final target in targets) {
    final query =
        (store.box<CloudInboxChangeEntity>().query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(messageCheckpoint.checkpointKey)
                  .and(
                    CloudInboxChangeEntity_.accountFingerprint.equals(
                      auth.accountFingerprint,
                    ),
                  )
                  .and(
                    CloudInboxChangeEntity_.generation.equals(
                      messageCheckpoint.generation,
                    ),
                  )
                  .and(
                    CloudInboxChangeEntity_.serverRecordIdHash.equals(target),
                  )
                  .and(
                    CloudInboxChangeEntity_.status.equals(
                      CloudInboxStatus.retainedUnprojected.index,
                    ),
                  )
                  .and(
                    CloudInboxChangeEntity_.failureCategory.equals(
                      CloudFailureCategory.dependency.name,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.changeType.equals('save'))
                  .and(CloudInboxChangeEntity_.isTombstone.equals(false)),
            )..order(
              CloudInboxChangeEntity_.fetchSequence,
              flags: Order.descending,
            ))
            .build()
          ..limit = 1;
    try {
      final row = query.findFirst();
      if (row == null) {
        throw StateError('chat1_correlation_message_source_missing');
      }
      messageRows.add(row);
    } finally {
      query.close();
    }
  }
  const maximumAnchorMessageSources = 2048;
  // Apple Chat1 properties can point at an older message GUID. Build a bounded
  // local-only GUID-to-route index from the newest protected Message records,
  // while always retaining the eight explicit targets in the read set. No
  // message content or identifier leaves the native diagnostic.
  final anchorMessageRows = <CloudInboxChangeEntity>[];
  final anchorRecordHashes = <String>{};
  final anchorProtectedReferences = <String>{};
  var anchorSourceBudgetExhausted = false;

  void addAnchorSource(CloudInboxChangeEntity row) {
    if (!_isCorrelationSourceRow(row)) return;
    if (anchorMessageRows.length >= maximumAnchorMessageSources) {
      if (!anchorRecordHashes.contains(row.serverRecordIdHash) &&
          !anchorProtectedReferences.contains(row.encryptedPayloadRef)) {
        anchorSourceBudgetExhausted = true;
      }
      return;
    }
    final protectedReference = row.encryptedPayloadRef!;
    if (!anchorRecordHashes.add(row.serverRecordIdHash)) return;
    if (!anchorProtectedReferences.add(protectedReference)) {
      anchorRecordHashes.remove(row.serverRecordIdHash);
      return;
    }
    anchorMessageRows.add(row);
  }

  for (final row in messageRows) {
    addAnchorSource(row);
  }
  if (messageRows.any(
    (row) => !anchorRecordHashes.contains(row.serverRecordIdHash),
  )) {
    throw StateError('chat1_correlation_anchor_targets_missing');
  }
  final anchorQuery =
      (store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey
                .equals(messageCheckpoint.checkpointKey)
                .and(
                  CloudInboxChangeEntity_.accountFingerprint.equals(
                    auth.accountFingerprint,
                  ),
                )
                .and(
                  CloudInboxChangeEntity_.generation.equals(
                    messageCheckpoint.generation,
                  ),
                )
                .and(
                  CloudInboxChangeEntity_.status
                      .equals(CloudInboxStatus.applied.index)
                      .or(
                        CloudInboxChangeEntity_.status.equals(
                          CloudInboxStatus.retainedUnprojected.index,
                        ),
                      ),
                )
                .and(CloudInboxChangeEntity_.changeType.equals('save'))
                .and(CloudInboxChangeEntity_.isTombstone.equals(false)),
          )..order(
            CloudInboxChangeEntity_.fetchSequence,
            flags: Order.descending,
          ))
          .build()
        ..limit = maximumAnchorMessageSources + messageRows.length + 1;
  try {
    for (final row in anchorQuery.find()) {
      addAnchorSource(row);
    }
  } finally {
    anchorQuery.close();
  }
  final chat1Query = (store.box<CloudInboxChangeEntity>().query(
    CloudInboxChangeEntity_.scopeKey
        .equals(chat1Checkpoint.checkpointKey)
        .and(
          CloudInboxChangeEntity_.accountFingerprint.equals(
            auth.accountFingerprint,
          ),
        )
        .and(
          CloudInboxChangeEntity_.generation.equals(chat1Checkpoint.generation),
        ),
  )..order(CloudInboxChangeEntity_.fetchSequence)).build()..limit = 51;
  late final List<CloudInboxChangeEntity> chat1Rows;
  try {
    chat1Rows = chat1Query.find();
  } finally {
    chat1Query.close();
  }
  if (chat1Rows.length != 50 ||
      chat1Rows.any(
        (row) =>
            row.status != CloudInboxStatus.pending.index ||
            row.changeType != 'save' ||
            row.isTombstone ||
            row.preflightCode != 'unsupportedRecordType' ||
            row.failureCategory != CloudFailureCategory.malformedRecord.name ||
            row.encryptedServerRecordId?.isNotEmpty != true,
      )) {
    throw StateError('chat1_correlation_chat1_read_set_invalid');
  }
  final before = _correlationDurableState(store);
  if (Platform.environment['OPENBUBBLES_EXPORT_CHAT1_INPUT_MANIFEST'] == '1') {
    await _exportChat1CorrelationInputManifest(
      profile: profile,
      auth: auth,
      messageGeneration: messageCheckpoint.generation,
      messageRows: messageRows,
      anchorMessageRows: anchorMessageRows,
      chat1Generation: chat1Checkpoint.generation,
      chat1Rows: chat1Rows,
    );
    final finalAuth = await readCurrentBoundAuth();
    if (!auth.sameIdentity(finalAuth)) {
      throw StateError('account_changed');
    }
    final durableStateUnchanged = before == _correlationDurableState(store);
    if (!durableStateUnchanged) {
      throw StateError('chat1_correlation_export_write_tripwire');
    }
    return <String, Object?>{
      'account_bound': true,
      'scope': 'chat1ManateeZone',
      'network_read_performed': false,
      'content_exposed': false,
      'durable_state_unchanged': true,
      'manifest_exported': true,
      'message_sources': messageRows.length,
      'anchor_message_sources': anchorMessageRows.length,
      'chat1_sources': chat1Rows.length,
      'anchor_source_budget_exhausted': anchorSourceBudgetExhausted,
    };
  }
  final result = await correlation_api
      .cloudSyncInspectChat1RecordNameCorrelationUnderWriterPause(
        cloudMessagesClient: client,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: profile.path,
        expectedAccountFingerprint: auth.accountFingerprint,
        expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
        messageGeneration: BigInt.from(messageCheckpoint.generation),
        messageSources: messageRows.map(_correlationSource).toList(),
        anchorMessageSources: anchorMessageRows
            .map(_correlationSource)
            .toList(),
        chat1Generation: BigInt.from(chat1Checkpoint.generation),
        chat1Sources: chat1Rows.map(_correlationSource).toList(),
      );
  final finalAuth = await readCurrentBoundAuth();
  if (!auth.sameIdentity(finalAuth)) {
    throw StateError('account_changed');
  }
  final durableStateUnchanged = before == _correlationDurableState(store);
  if (!durableStateUnchanged) {
    throw StateError('chat1_correlation_write_tripwire');
  }
  return <String, Object?>{
    'account_bound': true,
    'scope': 'chat1ManateeZone',
    // The semantic diagnostic performs only the lookup-only PCS reads needed
    // to decrypt bounded routing fields. Its separately gated paged lane may
    // walk bounded pages in memory, but never persists a cursor.
    'network_read_performed': semanticCorrelation,
    'content_exposed': false,
    'durable_state_unchanged': durableStateUnchanged,
    'completed': result.completed,
    'message_sources': result.messageSources,
    'decoded_message_routes': result.decodedMessageRoutes,
    'distinct_message_routes': result.distinctMessageRoutes,
    'chat1_sources': result.chat1Sources,
    'verified_chat1_records': result.verifiedChat1Records,
    'exact_match_pairs': result.exactMatchPairs,
    'matched_message_routes': result.matchedMessageRoutes,
    'matched_chat1_records': result.matchedChat1Records,
    'semantic_correlation_requested': result.semanticCorrelationRequested,
    'pcs_lookup_attempted': result.pcsLookupAttempted,
    'chat_record_type_records': result.chatRecordTypeRecords,
    'other_record_type_records': result.otherRecordTypeRecords,
    'decoded_route_records': result.decodedRouteRecords,
    'record_decode_failures': result.recordDecodeFailures,
    'route_field_decode_failures': result.routeFieldDecodeFailures,
    'route_field_failure_matrix_schema': result.routeFieldFailureMatrixSchema,
    'route_field_failure_matrix': result.routeFieldFailureMatrix,
    'chat_identifier_match_pairs': result.chatIdentifierMatchPairs,
    'group_id_match_pairs': result.groupIdMatchPairs,
    'original_group_id_match_pairs': result.originalGroupIdMatchPairs,
    'guid_match_pairs': result.guidMatchPairs,
    'semantic_match_pairs': result.semanticMatchPairs,
    'matched_semantic_message_routes': result.matchedSemanticMessageRoutes,
    'matched_semantic_chat1_records': result.matchedSemanticChat1Records,
    'message_group_id_sources': result.messageGroupIdSources,
    'message_sender_sources': result.messageSenderSources,
    'anchor_message_sources': result.anchorMessageSources,
    'decoded_anchor_messages': result.decodedAnchorMessages,
    'skipped_anchor_messages': result.skippedAnchorMessages,
    'distinct_anchor_message_guids': result.distinctAnchorMessageGuids,
    'conflicting_anchor_message_guids': result.conflictingAnchorMessageGuids,
    'anchor_source_budget_exhausted': anchorSourceBudgetExhausted,
    'route_participant_match_pairs': result.routeParticipantMatchPairs,
    'route_legacy_match_pairs': result.routeLegacyMatchPairs,
    'route_lah_match_pairs': result.routeLahMatchPairs,
    'msgproto_chat_identifier_match_pairs':
        result.msgprotoChatIdentifierMatchPairs,
    'msgproto_group_id_match_pairs': result.msgprotoGroupIdMatchPairs,
    'msgproto_original_group_id_match_pairs':
        result.msgprotoOriginalGroupIdMatchPairs,
    'msgproto_guid_match_pairs': result.msgprotoGuidMatchPairs,
    'msgproto_legacy_match_pairs': result.msgprotoLegacyMatchPairs,
    'sender_participant_match_pairs': result.senderParticipantMatchPairs,
    'sender_lah_match_pairs': result.senderLahMatchPairs,
    'matched_route_extra_message_routes': result.matchedRouteExtraMessageRoutes,
    'matched_route_extra_chat1_records': result.matchedRouteExtraChat1Records,
    'matched_msgproto_targets': result.matchedMsgprotoTargets,
    'matched_msgproto_chat1_records': result.matchedMsgprotoChat1Records,
    'matched_sender_targets': result.matchedSenderTargets,
    'matched_sender_chat1_records': result.matchedSenderChat1Records,
    'participant_present_records': result.participantPresentRecords,
    'legacy_present_records': result.legacyPresentRecords,
    'lah_present_records': result.lahPresentRecords,
    'service_present_records': result.servicePresentRecords,
    'imessage_service_records': result.imessageServiceRecords,
    'other_service_records': result.otherServiceRecords,
    'style_group_records': result.styleGroupRecords,
    'style_direct_records': result.styleDirectRecords,
    'style_other_records': result.styleOtherRecords,
    'paged_correlation_requested': result.pagedCorrelationRequested,
    'paged_pages_scanned': result.pagedPagesScanned,
    'paged_changes_scanned': result.pagedChangesScanned,
    'paged_chat_records': result.pagedChatRecords,
    'paged_other_records': result.pagedOtherRecords,
    'paged_tombstones': result.pagedTombstones,
    'paged_record_decode_failures': result.pagedRecordDecodeFailures,
    'paged_route_field_decode_failures': result.pagedRouteFieldDecodeFailures,
    'paged_route_field_failure_matrix': result.pagedRouteFieldFailureMatrix,
    'paged_semantic_match_pairs': result.pagedSemanticMatchPairs,
    'paged_matched_message_routes': result.pagedMatchedMessageRoutes,
    'paged_matched_chat1_records': result.pagedMatchedChat1Records,
    'paged_normalized_chat_identifier_match_pairs':
        result.pagedNormalizedChatIdentifierMatchPairs,
    'paged_normalized_group_id_match_pairs':
        result.pagedNormalizedGroupIdMatchPairs,
    'paged_normalized_original_group_id_match_pairs':
        result.pagedNormalizedOriginalGroupIdMatchPairs,
    'paged_normalized_guid_match_pairs': result.pagedNormalizedGuidMatchPairs,
    'paged_normalized_semantic_match_pairs':
        result.pagedNormalizedSemanticMatchPairs,
    'paged_normalized_matched_message_routes':
        result.pagedNormalizedMatchedMessageRoutes,
    'paged_normalized_matched_chat1_records':
        result.pagedNormalizedMatchedChat1Records,
    'paged_imessage_service_records': result.pagedImessageServiceRecords,
    'paged_other_service_records': result.pagedOtherServiceRecords,
    'paged_route_participant_match_pairs':
        result.pagedRouteParticipantMatchPairs,
    'paged_route_legacy_match_pairs': result.pagedRouteLegacyMatchPairs,
    'paged_route_lah_match_pairs': result.pagedRouteLahMatchPairs,
    'paged_msgproto_chat_identifier_match_pairs':
        result.pagedMsgprotoChatIdentifierMatchPairs,
    'paged_msgproto_group_id_match_pairs':
        result.pagedMsgprotoGroupIdMatchPairs,
    'paged_msgproto_original_group_id_match_pairs':
        result.pagedMsgprotoOriginalGroupIdMatchPairs,
    'paged_msgproto_guid_match_pairs': result.pagedMsgprotoGuidMatchPairs,
    'paged_msgproto_legacy_match_pairs': result.pagedMsgprotoLegacyMatchPairs,
    'paged_sender_participant_match_pairs':
        result.pagedSenderParticipantMatchPairs,
    'paged_sender_lah_match_pairs': result.pagedSenderLahMatchPairs,
    'paged_matched_route_extra_message_routes':
        result.pagedMatchedRouteExtraMessageRoutes,
    'paged_matched_route_extra_chat1_records':
        result.pagedMatchedRouteExtraChat1Records,
    'paged_matched_msgproto_targets': result.pagedMatchedMsgprotoTargets,
    'paged_matched_msgproto_chat1_records':
        result.pagedMatchedMsgprotoChat1Records,
    'paged_matched_sender_targets': result.pagedMatchedSenderTargets,
    'paged_matched_sender_chat1_records': result.pagedMatchedSenderChat1Records,
    'paged_participant_present_records': result.pagedParticipantPresentRecords,
    'paged_legacy_present_records': result.pagedLegacyPresentRecords,
    'paged_lah_present_records': result.pagedLahPresentRecords,
    'paged_service_present_records': result.pagedServicePresentRecords,
    'paged_style_direct_records': result.pagedStyleDirectRecords,
    'paged_style_group_records': result.pagedStyleGroupRecords,
    'paged_style_other_records': result.pagedStyleOtherRecords,
    'paged_normalized_route_participant_match_pairs':
        result.pagedNormalizedRouteParticipantMatchPairs,
    'paged_normalized_route_legacy_match_pairs':
        result.pagedNormalizedRouteLegacyMatchPairs,
    'paged_normalized_route_lah_match_pairs':
        result.pagedNormalizedRouteLahMatchPairs,
    'paged_normalized_msgproto_chat_identifier_match_pairs':
        result.pagedNormalizedMsgprotoChatIdentifierMatchPairs,
    'paged_normalized_msgproto_group_id_match_pairs':
        result.pagedNormalizedMsgprotoGroupIdMatchPairs,
    'paged_normalized_msgproto_original_group_id_match_pairs':
        result.pagedNormalizedMsgprotoOriginalGroupIdMatchPairs,
    'paged_normalized_msgproto_guid_match_pairs':
        result.pagedNormalizedMsgprotoGuidMatchPairs,
    'paged_normalized_msgproto_legacy_match_pairs':
        result.pagedNormalizedMsgprotoLegacyMatchPairs,
    'paged_normalized_sender_participant_match_pairs':
        result.pagedNormalizedSenderParticipantMatchPairs,
    'paged_normalized_sender_lah_match_pairs':
        result.pagedNormalizedSenderLahMatchPairs,
    'paged_normalized_matched_route_extra_message_routes':
        result.pagedNormalizedMatchedRouteExtraMessageRoutes,
    'paged_normalized_matched_route_extra_chat1_records':
        result.pagedNormalizedMatchedRouteExtraChat1Records,
    'paged_normalized_matched_msgproto_targets':
        result.pagedNormalizedMatchedMsgprotoTargets,
    'paged_normalized_matched_msgproto_chat1_records':
        result.pagedNormalizedMatchedMsgprotoChat1Records,
    'paged_normalized_matched_sender_targets':
        result.pagedNormalizedMatchedSenderTargets,
    'paged_normalized_matched_sender_chat1_records':
        result.pagedNormalizedMatchedSenderChat1Records,
    'paged_last_seen_message_guid_present_records':
        result.pagedLastSeenMessageGuidPresentRecords,
    'paged_last_seen_target_message_match_pairs':
        result.pagedLastSeenTargetMessageMatchPairs,
    'paged_matched_last_seen_target_messages':
        result.pagedMatchedLastSeenTargetMessages,
    'paged_matched_last_seen_target_chat1_records':
        result.pagedMatchedLastSeenTargetChat1Records,
    'paged_last_seen_anchor_exact_match_pairs':
        result.pagedLastSeenAnchorExactMatchPairs,
    'paged_matched_anchor_exact_targets': result.pagedMatchedAnchorExactTargets,
    'paged_matched_anchor_exact_chat1_records':
        result.pagedMatchedAnchorExactChat1Records,
    'paged_last_seen_anchor_normalized_match_pairs':
        result.pagedLastSeenAnchorNormalizedMatchPairs,
    'paged_matched_anchor_normalized_targets':
        result.pagedMatchedAnchorNormalizedTargets,
    'paged_matched_anchor_normalized_chat1_records':
        result.pagedMatchedAnchorNormalizedChat1Records,
    'paged_sender_service_style_match_pairs':
        result.pagedSenderServiceStyleMatchPairs,
    'paged_matched_sender_service_style_targets':
        result.pagedMatchedSenderServiceStyleTargets,
    'paged_matched_sender_service_style_chat1_records':
        result.pagedMatchedSenderServiceStyleChat1Records,
    'paged_sender_service_style_zero_candidate_targets':
        result.pagedSenderServiceStyleZeroCandidateTargets,
    'paged_sender_service_style_unique_candidate_targets':
        result.pagedSenderServiceStyleUniqueCandidateTargets,
    'paged_sender_service_style_multiple_candidate_targets':
        result.pagedSenderServiceStyleMultipleCandidateTargets,
    'paged_last_seen_target_zero_candidate_targets':
        result.pagedLastSeenTargetZeroCandidateTargets,
    'paged_last_seen_target_unique_candidate_targets':
        result.pagedLastSeenTargetUniqueCandidateTargets,
    'paged_last_seen_target_multiple_candidate_targets':
        result.pagedLastSeenTargetMultipleCandidateTargets,
    'paged_anchor_exact_zero_candidate_targets':
        result.pagedAnchorExactZeroCandidateTargets,
    'paged_anchor_exact_unique_candidate_targets':
        result.pagedAnchorExactUniqueCandidateTargets,
    'paged_anchor_exact_multiple_candidate_targets':
        result.pagedAnchorExactMultipleCandidateTargets,
    'paged_anchor_normalized_zero_candidate_targets':
        result.pagedAnchorNormalizedZeroCandidateTargets,
    'paged_anchor_normalized_unique_candidate_targets':
        result.pagedAnchorNormalizedUniqueCandidateTargets,
    'paged_anchor_normalized_multiple_candidate_targets':
        result.pagedAnchorNormalizedMultipleCandidateTargets,
    'paged_terminal_reached': result.pagedTerminalReached,
    'paged_budget_exhausted': result.pagedBudgetExhausted,
    'failure_code': result.failureCode?.name,
  };
}

Future<void> _exportChat1CorrelationInputManifest({
  required Directory profile,
  required CloudSyncNativeAuthSnapshot auth,
  required int messageGeneration,
  required List<CloudInboxChangeEntity> messageRows,
  required List<CloudInboxChangeEntity> anchorMessageRows,
  required int chat1Generation,
  required List<CloudInboxChangeEntity> chat1Rows,
}) async {
  final directory = Directory(
    path.join(profile.path, 'cloud-sync-v2', 'diagnostics'),
  );
  await directory.create(recursive: true);
  final destination = File(
    path.join(directory.path, 'chat1-correlation-input-v2.json'),
  );
  final temporary = File('${destination.path}.$pid.tmp');
  final encoded = jsonEncode(<String, Object?>{
    'schema': 2,
    'server_modified_at_format': 'unix_epoch_milliseconds',
    'content_exposed': false,
    'account_fingerprint': auth.accountFingerprint,
    'protected_store_identity': auth.protectedStoreIdentity,
    'message_generation': messageGeneration,
    'message_sources': messageRows.map(_correlationSourceMap).toList(),
    'anchor_message_sources': anchorMessageRows
        .map(_correlationSourceMap)
        .toList(),
    'chat1_generation': chat1Generation,
    'chat1_sources': chat1Rows.map(_correlationSourceMap).toList(),
  });
  if (encoded.length > 4 * 1024 * 1024) {
    throw StateError('chat1_correlation_export_too_large');
  }
  try {
    await temporary.writeAsString(encoded, flush: true);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

Map<String, Object?> _correlationSourceMap(CloudInboxChangeEntity row) {
  final source = _correlationSource(row);
  return <String, Object?>{
    'change_id_hash': source.changeIdHash,
    'record_id_hash': source.recordIdHash,
    'etag_hash': source.etagHash,
    'payload_sha256': source.payloadSha256,
    'payload_length': source.payloadLength,
    'server_modified_at_millis': source.serverModifiedAtMillis,
    'protected_raw_envelope_reference': source.protectedRawEnvelopeReference,
  };
}

List<String> _requiredTargetMessageHashes() {
  final encoded =
      Platform.environment['OPENBUBBLES_CHAT1_TARGET_MESSAGE_HASHES'];
  if (encoded == null) {
    throw StateError('chat1_correlation_targets_missing');
  }
  final values = encoded.split(',').map((value) => value.trim()).toList();
  if (values.length != 8 ||
      values.toSet().length != values.length ||
      values.any((value) => !_isBareDigest(value))) {
    throw StateError('chat1_correlation_targets_invalid');
  }
  return values;
}

CloudSyncCheckpointEntity _requireCheckpoint(
  Store store,
  CloudSyncScope scope,
) {
  final query = store
      .box<CloudSyncCheckpointEntity>()
      .query(
        CloudSyncCheckpointEntity_.checkpointKey.equals(
          cloudSyncPersistentScopeKey(scope),
        ),
      )
      .build();
  try {
    final checkpoint = query.findUnique();
    if (checkpoint == null ||
        checkpoint.accountFingerprint != scope.accountFingerprint ||
        checkpoint.container != scope.container ||
        checkpoint.database != scope.database ||
        checkpoint.zone != scope.zone ||
        checkpoint.persistenceLane != scope.persistenceLane.name ||
        checkpoint.generation <= 0 ||
        checkpoint.pendingBatchId != null ||
        checkpoint.pendingFetchedTokenCiphertext != null) {
      throw StateError('chat1_correlation_checkpoint_invalid');
    }
    return checkpoint;
  } finally {
    query.close();
  }
}

correlation_api.CloudSyncChat1CorrelationSourceInput _correlationSource(
  CloudInboxChangeEntity row,
) {
  final payloadSha256 = row.payloadSha256;
  final protectedReference = row.encryptedPayloadRef;
  if (!_isBareDigest(row.changeIdHash) ||
      !_isBareDigest(row.serverRecordIdHash) ||
      (row.etagHash != null && !_isBareDigest(row.etagHash!)) ||
      payloadSha256 == null ||
      !_isHexDigest(payloadSha256) ||
      protectedReference == null ||
      !_isProtectedReference(protectedReference)) {
    throw StateError('chat1_correlation_source_invalid');
  }
  return correlation_api.CloudSyncChat1CorrelationSourceInput(
    changeIdHash: row.changeIdHash,
    recordIdHash: row.serverRecordIdHash,
    etagHash: row.etagHash,
    payloadSha256: payloadSha256,
    payloadLength: null,
    serverModifiedAtMillis: cloudInboxCanonicalServerModifiedAtMillis(row),
    protectedRawEnvelopeReference: protectedReference,
  );
}

bool _isCorrelationSourceRow(CloudInboxChangeEntity row) {
  final payloadSha256 = row.payloadSha256;
  final protectedReference = row.encryptedPayloadRef;
  return _isBareDigest(row.changeIdHash) &&
      _isBareDigest(row.serverRecordIdHash) &&
      (row.etagHash == null || _isBareDigest(row.etagHash!)) &&
      payloadSha256 != null &&
      _isHexDigest(payloadSha256) &&
      protectedReference != null &&
      _isProtectedReference(protectedReference);
}

String _correlationDurableState(Store store) => jsonEncode([
  store
      .box<CloudSyncCheckpointEntity>()
      .getAll()
      .map(
        (row) => [
          row.id,
          row.generation,
          row.fetchedSequence,
          row.appliedSequence,
          row.fetchedTokenCiphertext,
          row.pendingFetchedTokenCiphertext,
          row.pendingBatchId,
        ],
      )
      .toList(),
  store
      .box<CloudOutboxOperationEntity>()
      .getAll()
      .map((row) => [row.id, row.state, row.updatedAtMs])
      .toList(),
  store.box<CloudInboxChangeEntity>().count(),
  store.box<Chat>().count(),
  store.box<Message>().count(),
  store.box<Attachment>().count(),
]);

bool _isBareDigest(String value) =>
    value.length == 43 &&
    value.codeUnits.every(
      (unit) =>
          (unit >= 48 && unit <= 57) ||
          (unit >= 65 && unit <= 90) ||
          (unit >= 97 && unit <= 122) ||
          unit == 45 ||
          unit == 95,
    );

bool _isHexDigest(String value) =>
    value.length == 64 &&
    value.codeUnits.every(
      (unit) => (unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102),
    );

bool _isProtectedReference(String value) =>
    value.startsWith('obcs2.ref.') && _isBareDigest(value.substring(10));

CloudSyncScope _chat1Scope(String accountFingerprint) => CloudSyncScope(
  accountFingerprint: accountFingerprint,
  container: CloudSyncManualShadowSampler.container,
  database: CloudSyncManualShadowSampler.database,
  zone: 'chat1ManateeZone',
  persistenceLane: CloudSyncPersistenceLane.shadow,
);

Map<String, Object?> _inspectCachedJournalShape(
  Store store,
  CloudSyncScope scope, {
  required int generation,
}) {
  const maximumRows = 512;
  final scopeKey = cloudSyncPersistentScopeKey(scope);
  final query =
      (store.box<CloudInboxChangeEntity>().query(
          CloudInboxChangeEntity_.scopeKey
              .equals(scopeKey)
              .and(
                CloudInboxChangeEntity_.accountFingerprint.equals(
                  scope.accountFingerprint,
                ),
              )
              .and(CloudInboxChangeEntity_.generation.equals(generation)),
        )..order(CloudInboxChangeEntity_.fetchSequence)).build()
        ..limit = maximumRows + 1;
  late final List<CloudInboxChangeEntity> rows;
  try {
    rows = query.find();
  } finally {
    query.close();
  }
  if (rows.length > maximumRows) {
    throw StateError('chat1_discovery_cached_journal_limit');
  }

  final statusCounts = <String, int>{};
  final changeTypeCounts = <String, int>{};
  final preflightCounts = <String, int>{};
  final failureCounts = <String, int>{};
  final recordHashes = <String>{};
  var duplicateRecordHashes = 0;
  var identityReferencesPresent = 0;
  var rawReferencesPresent = 0;
  var systemReferencesPresent = 0;
  var payloadDigestsPresent = 0;
  var tombstones = 0;
  for (final row in rows) {
    final status =
        row.status >= 0 && row.status < CloudInboxStatus.values.length
        ? CloudInboxStatus.values[row.status].name
        : 'invalid';
    statusCounts.update(status, (count) => count + 1, ifAbsent: () => 1);
    changeTypeCounts.update(
      row.changeType,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    final preflight = row.preflightCode ?? 'none';
    preflightCounts.update(preflight, (count) => count + 1, ifAbsent: () => 1);
    final failure = row.failureCategory ?? 'none';
    failureCounts.update(failure, (count) => count + 1, ifAbsent: () => 1);
    if (!recordHashes.add(row.serverRecordIdHash)) duplicateRecordHashes++;
    if (row.encryptedServerRecordId?.isNotEmpty == true) {
      identityReferencesPresent++;
    }
    if (row.encryptedPayloadRef?.isNotEmpty == true) rawReferencesPresent++;
    if (row.protectedSystemFieldsRef?.isNotEmpty == true) {
      systemReferencesPresent++;
    }
    if (row.payloadSha256?.isNotEmpty == true) payloadDigestsPresent++;
    if (row.isTombstone) tombstones++;
  }
  return <String, Object?>{
    'bounded': true,
    'rows': rows.length,
    'status_counts': statusCounts,
    'change_type_counts': changeTypeCounts,
    'preflight_code_counts': preflightCounts,
    'failure_category_counts': failureCounts,
    'tombstones': tombstones,
    'distinct_record_hashes': recordHashes.length,
    'duplicate_record_hashes': duplicateRecordHashes,
    'identity_references_present': identityReferencesPresent,
    'raw_references_present': rawReferencesPresent,
    'system_references_present': systemReferencesPresent,
    'payload_digests_present': payloadDigestsPresent,
  };
}

bool _sameCounts(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
