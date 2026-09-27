import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:crypto/crypto.dart';

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_outbox_binding.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_binding.dart';
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

  CloudSyncRestoredDirectChatProof _parent(
    CloudSyncScope scope,
    int localChatId,
    String? expectedBinding,
  ) {
    final parent = requireCloudSyncRestoredDirectChatProofForId(
      store: store,
      messageScope: scope,
      chatId: localChatId,
    );
    if (expectedBinding != null && parent.binding != expectedBinding) {
      throw StateError('cloud_sync_historical_create_parent_changed');
    }
    return parent;
  }

  Future<api.CloudSyncHistoricalArchiveCreateProof> _open(
    BigInt token,
    CloudSyncHistoricalProtectedSourceBinding source,
    CloudSyncRestoredDirectChatProof parent,
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
