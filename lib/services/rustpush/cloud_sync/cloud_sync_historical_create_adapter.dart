import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/api/cloud_sync_chat_identity.dart' as identity_api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:crypto/crypto.dart';

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_chat_identity_evidence.dart';
import 'cloud_sync_historical_parent_origin.dart';
import 'cloud_sync_historical_chat_origin.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_outbox_binding.dart';
import 'cloud_sync_historical_parent_binding.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_write_chat_identity_session.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_ownership.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_cloud_sync_store.dart';

/// Local encrypted-stage -> durable ownership -> native lease commit. Caller
/// holds both protected-store exclusions. No CloudKit save happens here.
/// The source callback is inside cleanup coverage because its validation may
/// fail after native staging. Never roll back a lease that the queue owns.
Future<CloudOutboxOperation> adoptCloudSyncHistoricalCreateStage({
  required api.CloudSyncProtectedOutboundStage stage,
  required CloudSyncScope scope,
  required int generation,
  required ObjectBoxCloudSyncStore durable,
  required CloudSyncHistoricalArchiveJournal journal,
  required CloudSyncHistoricalCreateSource Function() selectSource,
  required CloudSyncNativeAuthSnapshot auth,
  required Future<void> Function() validate,
  required bool Function() stillCurrent,
  required CloudProtectedPageLeaseLifecycle lifecycle,
  required CloudProtectedPageLeaseTransport transport,
}) async {
  var owned = false;
  try {
    await validate();
    final source = selectSource();
    if (source.generation != generation ||
        stage.logicalEntityKeyHash != source.logicalEntityKeyHash ||
        stage.serverRecordIdHash != source.serverRecordIdHash ||
        stage.protectedPayloadReference !=
            stage.protectedServerRecordReference ||
        stage.payloadLength <= BigInt.zero ||
        stage.payloadLength > BigInt.from(cloudSyncHistoricalMaxSourceBytes)) {
      throw StateError('cloud_sync_historical_create_stage_changed');
    }
    final now = DateTime.fromMillisecondsSinceEpoch(
      source.createdAtMs,
      isUtc: true,
    );
    final operation = durable.admitProtectedHistoricalCreate(
      draft: CloudOutboxDraft(
        scope: scope,
        logicalEntityKeyHash: stage.logicalEntityKeyHash,
        action: CloudOutboxAction.save,
        payloadVersion: cloudSyncOutboundPayloadVersion,
        dependencyOperationIds: const {},
        createdAt: now,
        encryptedPayloadReference: stage.protectedPayloadReference,
        payloadSha256: stage.payloadSha256,
        serverRecordIdHash: stage.serverRecordIdHash,
        protectedLeaseReference: stage.leaseReference,
      ),
      recordMapping: CloudRecordMapEntry(
        scope: scope,
        logicalEntityKeyHash: stage.logicalEntityKeyHash,
        serverRecordIdHash: stage.serverRecordIdHash,
        encryptedServerRecordId: stage.protectedPayloadReference,
        updatedAt: now,
      ),
      journal: journal,
      source: source,
      currentAuth: auth,
      stillCurrent: stillCurrent,
    );
    owned = true;
    await transport.commitProtectedPageLease(stage.leaseReference, {
      stage.protectedPayloadReference,
    });
    await validate();
    final retained = durable.readHistoricalArchiveOperation(
      scope,
      operation.operationId,
    );
    if (retained == null ||
        !(durable.readHistoricalArchiveSource(retained)?.sameSourceAs(source) ??
            false)) {
      throw StateError('cloud_sync_historical_admitted_operation_changed');
    }
    return retained;
  } catch (_) {
    if (!owned) {
      try {
        // Cover a committed transaction whose response was lost too. If this
        // inventory cannot be proved, retain the file for bounded recovery.
        final retained = await durable.readLiveProtectedOutboundLeaseReferences(
          maximumCount: CloudProtectedPageLeaseLifecycle.maximumAdoptedLeases,
        );
        if (!retained.contains(stage.leaseReference)) {
          await lifecycle.rollbackUnjournaledPage(
            CloudFetchBatch(
              scope: scope,
              changes: const [],
              nextToken: null,
              hasMore: false,
              batchId: 'historical-create-unadopted',
              generation: generation,
              protectedPageLeaseReference: stage.leaseReference,
            ),
          );
        }
      } catch (_) {
        // Keep the original failure. The lifecycle invalidates its cached
        // recovery on failed rollback; the next write always recovers afresh.
      }
    }
    rethrow;
  }
}

/// Historical origin joins the existing single-submit queue. It never emits an
/// IDS message or constructs live-send/receive provenance. Proof reopening is
/// intentionally independent of the current scan and mutable Message contents.
final class CloudSyncHistoricalCreateAdapter {
  const CloudSyncHistoricalCreateAdapter({
    required this.store,
    required this.durable,
    required this.transport,
    required this.auth,
    required this.storageDirectory,
    required this.readSession,
    required this.validate,
    required this.stillCurrent,
  });

  final Store store;
  final ObjectBoxCloudSyncStore durable;
  final NativeProtectedCloudSyncTransport transport;
  final CloudSyncNativeAuthSnapshot auth;
  final String storageDirectory;
  final CloudSyncWriteChatIdentitySession readSession;
  final Future<void> Function() validate;
  final bool Function() stillCurrent;

  /// Retained source lookup for both prepare and uncertain-outcome readback.
  /// It does not depend on a mutable visible Chat or the active snapshot scan.
  Future<api.CloudSyncNativeHistoricalArchiveSourceBinding?> openParentSource(
    CloudSyncScope scope, String operationId,
  ) async {
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await validate();
    if (scope.accountFingerprint != auth.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' || scope.database != 'private' ||
        scope.zone != 'chatManateeZone' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_historical_chat_source_changed');
    }
    final operations = await durable.readOutboxEntries(scope);
    await validate();
    final operation = operations.where((row) => row.operationId == operationId).single;
    final origin = durable.readHistoricalChatSource(operation);
    if (origin == null) return null; // Preserve ordinary direct Chat behavior.
    if (origin.source.protectedStoreIdentity != auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_chat_source_changed');
    }
    return _nativeSource(origin.source);
  }

  Future<CloudSyncChatIdentityEvidence?> observeParent({
    required CloudSyncHistoricalParentOrigin origin,
    required api.CloudSyncProtectedOutboundStage stage,
    required CloudSyncLocalSendAuthFence authFence,
    BigInt? pauseToken,
  }) {
    Future<CloudSyncChatIdentityEvidence?> observe(BigInt token) => CloudSyncChatIdentityEvidence.observe(
    store: store, origin: origin, stage: _stageData(stage), auth: auth, authFence: authFence,
    observer: (readSet, retained, staged, selected) => api.cloudSyncObserveHistoricalChatIdentity(
      cloudMessagesClient: _client, nativeWriterPauseToken: token,
      storageDirectory: storageDirectory, expectedAuth: _nativeAuth,
      // Native generation opens the retained envelope; candidate/admission
      // generation remains pinned by the read-set fence and durable origin.
      generation: BigInt.from(retained.generation), readSetFenceSha256: readSet.fenceSha256,
      historicalSource: _nativeSource(selected.durable.source), stagedCandidate: stage,
      retainedSource: identity_api.CloudSyncChatIdentitySourceInput(
        changeIdHash: retained.changeIdHash, recordIdHash: retained.recordIdHash,
        etagHash: retained.etagHash, payloadSha256: retained.payloadSha256,
        serverModifiedAtMillis: retained.serverModifiedAtMs,
        protectedRawEnvelopeReference: retained.encryptedPayloadReference),
    ),
    );
    return pauseToken == null ? readSession.run(observe) : observe(pauseToken);
  }

  /// Resolve a restored parent by its saved identity, never its current members
  /// or title. Only a canonical, protected reader mapping permits a message.
  int? confirmedParentId(CloudSyncScope messageScope, CloudSyncHistoricalArchiveRequest request) {
    var predicate = Chat_.guid.equals(request.chatGuid);
    if (request.groupMetadata case final group?) {
      predicate = predicate.or(Chat_.cloudGuid.equals(group.cloudGuid ?? request.chatGuid));
    }
    final query = store.box<Chat>().query(predicate).build()..limit = 2;
    try {
      final matches = query.find();
      if (matches.length > 1) throw StateError('cloud_sync_historical_create_parent_ambiguous');
      if (matches.isEmpty || matches.single.ckRecordId == null) return null;
      final id = matches.single.id!;
      _parent(messageScope, id, null);
      return id;
    } finally { query.close(); }
  }

  /// Recover exactly the retained candidate for fresh pending dispatch. The
  /// weaker openParentSource path above remains available for receipt recovery.
  CloudSyncHistoricalParentOrigin reopenParent({
    required CloudOutboxOperation operation,
    required CloudSyncHistoricalArchiveJournal journal,
    required CloudSyncHistoricalArchiveRequest request,
    required int intentId,
  }) {
    final retained = durable.readHistoricalChatSource(operation);
    if (retained == null || retained.intentId != intentId) {
      throw StateError('cloud_sync_historical_chat_source_changed');
    }
    return CloudSyncHistoricalParentOrigin.reopen(store: store, journal: journal,
      scope: operation.scope, request: request, durable: retained);
  }

  static api.CloudSyncProtectedOutboundStage retainedParentStage(
    CloudOutboxOperation operation, CloudSyncHistoricalChatOrigin origin,
  ) => api.CloudSyncProtectedOutboundStage(
    logicalEntityKeyHash: operation.logicalEntityKeyHash,
    protectedPayloadReference: operation.encryptedPayloadReference!,
    protectedServerRecordReference: operation.encryptedPayloadReference!,
    payloadSha256: operation.payloadSha256!,
    payloadLength: BigInt.from(origin.parentPayloadLength),
    serverRecordIdHash: operation.serverRecordIdHash!,
    leaseReference: operation.protectedLeaseReference!,
  );

  static CloudSyncProtectedOutboundStageData _stageData(api.CloudSyncProtectedOutboundStage stage) =>
    CloudSyncProtectedOutboundStageData(logicalEntityKeyHash: stage.logicalEntityKeyHash,
      protectedEnvelopeReference: stage.protectedPayloadReference, payloadSha256: stage.payloadSha256,
      serverRecordIdHash: stage.serverRecordIdHash, leaseReference: stage.leaseReference);

  Future<CloudOutboxOperation> admitParent({
    required CloudSyncScope scope,
    required CloudSyncHistoricalArchiveJournal journal,
    required CloudSyncHistoricalArchiveRequest request,
    required int intentId,
    required int? localChatId,
    required CloudSyncLocalSendAuthFence authFence,
    required Future<void> Function() validateSelection,
  }) async {
    if (!CloudSyncDevGate.manualSemanticPullEnabled ||
        !CloudSyncDevGate.manualOutboundCanaryEnabled ||
        !CloudKitWriterOwnership.v2MutationsEnabled) {
      throw StateError('cloud_sync_historical_create_disabled');
    }
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await validateSelection();
    final lifecycle = CloudProtectedPageLeaseLifecycle(store: durable, transport: transport);
    await lifecycle.ensureRecoveredBeforeWrite();
    await validateSelection();
    final checkpoint = await durable.readCheckpoint(scope);
    await validateSelection();
    final intent = journal.read(messageGuidHash: request.guidHash, sourceSha256: request.sourceSha256);
    if (intent == null || intent.id != intentId || !intent.sourceLeaseCommitted) {
      throw StateError('cloud_sync_historical_chat_source_changed');
    }
    return readSession.run((token) => transport.runProtectedStoreExclusive(() => transport.runLocalProtectedStoreExclusive(() async {
      await validateSelection();
      final result = await api.cloudSyncStageHistoricalChatCreate(
        cloudMessagesClient: _client, storageDirectory: storageDirectory,
        expectedAuth: _nativeAuth, historicalSource: _nativeSource(intent.source));
      final stage = result.stage;
      if (stage == null || result.failure != null) {
        throw StateError('cloud_sync_historical_chat_stage_failed');
      }
      var owned = false;
      try {
        await validateSelection();
        if (stage.protectedPayloadReference != stage.protectedServerRecordReference ||
            stage.payloadLength <= BigInt.zero || stage.payloadLength > BigInt.from(2 * 1024 * 1024)) {
          throw StateError('cloud_sync_historical_chat_stage_changed');
        }
        final origin = CloudSyncHistoricalParentOrigin.capture(store: store, journal: journal,
          scope: scope, generation: checkpoint.generation, request: request,
          intentId: intentId, localChatId: localChatId,
          parentPayloadLength: stage.payloadLength.toInt());
        final evidence = await observeParent(origin: origin, stage: stage, authFence: authFence,
          pauseToken: token);
        await validateSelection();
        final now = DateTime.now().toUtc();
        final operation = await authFence.run(() => durable.admitProtectedHistoricalChatCreate(
          origin: origin, identityEvidence: evidence,
          draft: CloudOutboxDraft(scope: scope, logicalEntityKeyHash: stage.logicalEntityKeyHash,
            action: CloudOutboxAction.save, payloadVersion: cloudSyncOutboundChatPayloadVersion,
            dependencyOperationIds: const {}, createdAt: now,
            encryptedPayloadReference: stage.protectedPayloadReference,
            payloadSha256: stage.payloadSha256, serverRecordIdHash: stage.serverRecordIdHash,
            protectedLeaseReference: stage.leaseReference),
          recordMapping: CloudRecordMapEntry(scope: scope, logicalEntityKeyHash: stage.logicalEntityKeyHash,
            serverRecordIdHash: stage.serverRecordIdHash,
            encryptedServerRecordId: stage.protectedPayloadReference, updatedAt: now)),
          accountFingerprint: scope.accountFingerprint);
        owned = true;
        await transport.commitProtectedPageLease(stage.leaseReference, {stage.protectedPayloadReference});
        await validateSelection();
        return operation;
      } catch (_) {
        if (!owned) {
          try {
            final retained = await durable.readLiveProtectedOutboundLeaseReferences(
              maximumCount: CloudProtectedPageLeaseLifecycle.maximumAdoptedLeases);
            if (!retained.contains(stage.leaseReference)) {
              await lifecycle.rollbackUnjournaledPage(CloudFetchBatch(scope: scope, changes: const [],
                nextToken: null, hasMore: false, batchId: 'historical-chat-unadopted',
                generation: checkpoint.generation, protectedPageLeaseReference: stage.leaseReference));
            }
          } catch (_) { /* Preserve uncertain ownership and the original failure. */ }
        }
        rethrow;
      }
    })));
  }

  native.ArcCloudMessagesClientDefaultAnisetteProvider get _client =>
      auth.cloudMessagesClient
          as native.ArcCloudMessagesClientDefaultAnisetteProvider;
  api.CloudSyncNativeAuthMetadata get _nativeAuth =>
      api.CloudSyncNativeAuthMetadata(
        nativeSessionId: auth.nativeSessionId,
        accountFingerprint: auth.accountFingerprint,
        protectedStoreIdentity: auth.protectedStoreIdentity,
      );
  api.CloudSyncNativeHistoricalArchiveSourceBinding _nativeSource(
    CloudSyncHistoricalProtectedSourceBinding source,
  ) => api.CloudSyncNativeHistoricalArchiveSourceBinding(
    accountFingerprint: source.accountFingerprint,
    protectedStoreIdentity: source.protectedStoreIdentity,
    snapshotSha256: source.snapshotSha256,
    messageGuidHash: source.messageGuidHash,
    sourceSha256: source.sourceSha256,
    protectedReference: source.protectedReference,
    leaseReference: source.leaseReference,
    payloadSha256: source.payloadSha256,
    payloadLength: source.payloadLength,
  );

  CloudSyncHistoricalParentProof _parent(
    CloudSyncScope scope,
    int localChatId,
    String? expectedBinding,
  ) {
    final parent = requireCloudSyncHistoricalParentProof(
      store: store,
      messageScope: scope,
      chatId: localChatId,
      expectedBinding: expectedBinding,
    );
    if (expectedBinding != null && parent.binding != expectedBinding) {
      throw StateError('cloud_sync_historical_create_parent_changed');
    }
    return parent;
  }

  Future<api.CloudSyncHistoricalArchiveCreateProof> _open(
    BigInt token,
    CloudSyncHistoricalProtectedSourceBinding source,
    CloudSyncHistoricalParentProof parent,
  ) => api.cloudSyncOpenHistoricalArchiveCreateProof(
    cloudMessagesClient: _client,
    nativeWriterPauseToken: token,
    storageDirectory: storageDirectory,
    expectedAuth: _nativeAuth,
    historicalSource: _nativeSource(source),
    chatGeneration: BigInt.from(parent.generation),
    chatLogicalEntityKeyHash: parent.logicalEntityKeyHash,
    chatSource: parent.source,
    parentBindingSha256: sha256.convert(utf8.encode(parent.binding)).toString(),
  );

  Future<api.CloudSyncHistoricalArchiveCreateProof?> openProof(
    CloudSyncScope scope,
    String operationId,
  ) async {
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await validate();
    final operation = durable.readHistoricalArchiveOperation(
      scope,
      operationId,
    );
    if (operation == null) return null;
    final source = durable.readHistoricalArchiveSource(operation)!;
    final parent = _parent(scope, source.localChatId, source.parentBinding);
    final proof = await readSession.run(
      (token) => _open(token, source.source, parent),
    );
    await validate();
    final current = durable.readHistoricalArchiveOperation(scope, operationId);
    if (current == null ||
        !(durable.readHistoricalArchiveSource(current)?.sameSourceAs(source) ??
            false) ||
        _parent(scope, source.localChatId, source.parentBinding).source !=
            parent.source) {
      throw StateError('cloud_sync_historical_admitted_operation_changed');
    }
    return proof;
  }

  Future<CloudOutboxOperation> admit({
    required CloudSyncScope scope,
    required CloudSyncHistoricalArchiveJournal journal,
    required CloudSyncHistoricalArchiveRequest request,
    required int intentId,
    required int localChatId,
  }) async {
    if (!CloudSyncDevGate.manualSemanticPullEnabled ||
        !CloudSyncDevGate.manualOutboundCanaryEnabled ||
        !CloudKitWriterOwnership.v2MutationsEnabled) {
      throw StateError('cloud_sync_historical_create_disabled');
    }
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await validate();
    final lifecycle = CloudProtectedPageLeaseLifecycle(
      store: durable,
      transport: transport,
    );
    await lifecycle.ensureRecoveredBeforeWrite();
    await validate();
    final intent = journal.read(
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    if (!journal.isBoundToStore(store) ||
        intent == null ||
        intent.id != intentId ||
        !intent.sourceLeaseCommitted ||
        intent.readerChangeId != null) {
      throw StateError('cloud_sync_historical_create_source_not_ready');
    }
    intent.source.requireOrigin(
      accountFingerprint: auth.accountFingerprint,
      protectedStoreIdentity: auth.protectedStoreIdentity,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
    );
    // A committed ownership response may have been lost. Resume that exact
    // operation through the existing queue, never create a new staged identity.
    if (intent.admittedOperationId case final operationId?) {
      final operation = durable.readHistoricalArchiveOperation(
        scope,
        operationId,
      );
      if (operation == null) {
        throw StateError('cloud_sync_historical_admitted_operation_changed');
      }
      return operation;
    }
    final parent = _parent(scope, localChatId, null);
    final checkpoint = await durable.readCheckpoint(scope);
    await validate();
    return readSession.run((token) async {
      final proof = await _open(token, intent.source, parent);
      await validate();
      final prepared = await api.cloudSyncDiscoverHistoricalRecordExact(
        cloudMessagesClient: _client,
        nativeWriterPauseToken: token,
        storageDirectory: storageDirectory,
        expectedAuth: _nativeAuth,
        historicalSource: _nativeSource(intent.source),
        messageGeneration: BigInt.from(checkpoint.generation),
      );
      try {
        return await transport.runProtectedStoreExclusive(
          () => transport.runLocalProtectedStoreExclusive(() async {
            await validate();
            final currentCheckpoint = await durable.readCheckpoint(scope);
            await validate();
            if (currentCheckpoint.generation != checkpoint.generation) {
              throw StateError('cloud_sync_historical_create_generation_changed');
            }
            if (_parent(scope, localChatId, parent.binding).source !=
                parent.source) {
              throw StateError('cloud_sync_historical_create_parent_changed');
            }
            // This independent lookup must still be fresh exact NotFound.
            // Found/divergent/unresolved never becomes create authority; the
            // ordinary historical reader must ingest it on its next pass.
            final stage = await api.cloudSyncStageHistoricalArchiveCreate(
              prepared: prepared,
              nativeWriterPauseToken: token,
              proof: proof,
            );
            return adoptCloudSyncHistoricalCreateStage(
              stage: stage,
              scope: scope,
              generation: checkpoint.generation,
              durable: durable,
              journal: journal,
              selectSource: () {
                final selected = journal.readForCreateAdmission(
                  scope: scope,
                  intentId: intentId,
                  currentAuth: auth,
                  request: request,
                  localChatId: localChatId,
                  generation: checkpoint.generation,
                  logicalEntityKeyHash: stage.logicalEntityKeyHash,
                  serverRecordIdHash: stage.serverRecordIdHash,
                );
                if (selected.parentBinding != parent.binding) {
                  throw StateError(
                    'cloud_sync_historical_create_parent_changed',
                  );
                }
                return selected;
              },
              auth: auth,
              validate: validate,
              stillCurrent: stillCurrent,
              lifecycle: lifecycle,
              transport: transport,
            );
          }),
        );
      } finally {
        await api.cloudSyncDiscardHistoricalDiscovery(prepared: prepared);
      }
    });
  }
}
