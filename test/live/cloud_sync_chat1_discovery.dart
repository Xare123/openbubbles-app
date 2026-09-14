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
  final result = await correlation_api
      .cloudSyncInspectChat1RecordNameCorrelationUnderWriterPause(
        cloudMessagesClient: client,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: profile.path,
        expectedAccountFingerprint: auth.accountFingerprint,
        expectedProtectedStoreIdentity: auth.protectedStoreIdentity,
        messageGeneration: BigInt.from(messageCheckpoint.generation),
        messageSources: messageRows.map(_correlationSource).toList(),
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
    // The semantic diagnostic may perform only the lookup-only PCS reads
    // needed to decrypt the four bounded routing fields. It never fetches a
    // record page or persists a cursor.
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
    'chat_identifier_match_pairs': result.chatIdentifierMatchPairs,
    'group_id_match_pairs': result.groupIdMatchPairs,
    'original_group_id_match_pairs': result.originalGroupIdMatchPairs,
    'guid_match_pairs': result.guidMatchPairs,
    'semantic_match_pairs': result.semanticMatchPairs,
    'matched_semantic_message_routes': result.matchedSemanticMessageRoutes,
    'matched_semantic_chat1_records': result.matchedSemanticChat1Records,
    'failure_code': result.failureCode?.name,
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
    serverModifiedAtMillis: row.serverModifiedAtMs <= 0
        ? null
        : row.serverModifiedAtMs,
    protectedRawEnvelopeReference: protectedReference,
  );
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
