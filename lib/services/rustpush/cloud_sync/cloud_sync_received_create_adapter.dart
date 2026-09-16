import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:crypto/crypto.dart';

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_binding.dart';
import 'cloud_sync_received_archive_journal.dart';
import 'cloud_sync_received_archive_source_binding.dart';
import 'cloud_sync_received_record_observation.dart';
import 'cloud_sync_write_chat_identity_session.dart';
import 'cloudkit_operation_interlock.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_cloud_sync_store.dart';

/// Received origin joins the existing create-only queue, not the IDS-send
/// consumer. Every admission performs a NEW native exact lookup and stages
/// only NotFound. Retained Found/uncertain observations cannot call this stage.
final class CloudSyncReceivedCreateAdapter {
  const CloudSyncReceivedCreateAdapter({
    required this.store,
    required this.durable,
    required this.journal,
    required this.transport,
    required this.auth,
    required this.storageDirectory,
    required this.readSession,
    required this.validate,
    required this.stillCurrent,
  });
  final Store store;
  final ObjectBoxCloudSyncStore durable;
  final CloudSyncReceivedArchiveJournal journal;
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
  api.CloudSyncNativeReceivedArchiveSourceBinding _source(
    CloudSyncReceivedArchiveSourceBinding source,
  ) => api.CloudSyncNativeReceivedArchiveSourceBinding(
    accountFingerprint: source.accountFingerprint,
    protectedStoreIdentity: source.protectedStoreIdentity,
    messageGuidHash: source.messageGuidHash,
    sourceSha256: source.sourceSha256,
    protectedReference: source.protectedReference,
    leaseReference: source.leaseReference,
    payloadSha256: source.payloadSha256,
    payloadLength: source.payloadLength,
  );

  CloudSyncRestoredDirectChatProof _parent(
    CloudSyncScope scope,
    CloudSyncReceivedArchiveAdmissionSource source,
  ) {
    final message = store.box<Message>().get(source.localMessageId);
    if (message != null && message.chat.targetId != source.localChatId) {
      throw StateError('cloud_sync_received_archive_parent_changed');
    }
    final parent = requireCloudSyncRestoredDirectChatProofForId(
      store: store,
      messageScope: scope,
      chatId: source.localChatId,
    );
    if (parent.binding != source.observation.parentBinding) {
      throw StateError('cloud_sync_received_archive_parent_changed');
    }
    return parent;
  }

  String _parentDigest(String binding) =>
      sha256.convert(utf8.encode(binding)).toString();

  Future<api.CloudSyncReceivedArchiveCreateProof?> openProof(
    CloudSyncScope scope,
    String operationId,
  ) async {
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await validate();
    final operation = durable.readReceivedArchiveOperation(scope, operationId);
    if (operation == null) return null;
    final source = journal.readAdoptedSource(
      transactionStore: store,
      operation: operation,
    )!;
    final parent = _parent(scope, source);
    final proof = await readSession.run(
      (token) => api.cloudSyncOpenReceivedArchiveCreateProof(
        cloudMessagesClient: _client,
        nativeWriterPauseToken: token,
        storageDirectory: storageDirectory,
        expectedAuth: _nativeAuth,
        receivedSource: _source(source.source),
        chatGeneration: BigInt.from(parent.generation),
        chatLogicalEntityKeyHash: parent.logicalEntityKeyHash,
        chatSource: parent.source,
        parentBindingSha256: _parentDigest(parent.binding),
      ),
    );
    await validate();
    final current = durable.readReceivedArchiveOperation(scope, operationId);
    if (current == null ||
        current.operationId != operation.operationId ||
        current.scope != operation.scope ||
        _parent(scope, source).source != parent.source ||
        !journal
            .readAdoptedSource(transactionStore: store, operation: current)!
            .sameSourceAs(source)) {
      throw StateError(
        'cloud_sync_received_archive_admitted_operation_changed',
      );
    }
    return proof;
  }

  Future<CloudOutboxOperation> admit(CloudSyncScope scope, int intentId) async {
    if (!CloudSyncDevGate.receivedArchiveUploadsEnabled ||
        !CloudSyncDevGate.receivedArchiveCaptureEnabled ||
        !CloudSyncDevGate.receivedArchiveInspectionEnabled) {
      throw StateError('cloud_sync_received_archive_uploads_disabled');
    }
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await validate();
    await CloudProtectedPageLeaseLifecycle(
      store: durable,
      transport: transport,
    ).ensureRecoveredBeforeWrite();
    await validate();
    final source = journal.readForCreateAdmission(
      intentId: intentId,
      currentAuth: auth,
    );
    final parent = _parent(scope, source);
    final checkpoint = await durable.readCheckpoint(scope);
    await validate();
    if (checkpoint.generation != source.observation.generation) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    return readSession.run((token) async {
      final prepared = await api.cloudSyncPrepareReceivedArchiveInspection(
        cloudMessagesClient: _client,
        nativeWriterPauseToken: token,
        storageDirectory: storageDirectory,
        expectedAuth: _nativeAuth,
        receivedSource: _source(source.source),
        chatGeneration: BigInt.from(parent.generation),
        messageGeneration: BigInt.from(checkpoint.generation),
        chatLogicalEntityKeyHash: parent.logicalEntityKeyHash,
        chatSource: parent.source,
      );
      try {
        return await transport.runProtectedStoreExclusive(
          () => transport.runLocalProtectedStoreExclusive(() async {
            await validate();
            journal.validateCreateAdmission(
              transactionStore: store,
              scope: scope,
              expected: source,
              currentAuth: auth,
              stillCurrent: stillCurrent,
            );
            if (_parent(scope, source).source != parent.source) {
              throw StateError('cloud_sync_received_archive_parent_changed');
            }
            final disposition = await api
                .cloudSyncReceivedArchiveInspectionDisposition(
                  prepared: prepared,
                );
            if (disposition != api.CloudSyncReceivedRecordDisposition.absent) {
              if (disposition !=
                  api.CloudSyncReceivedRecordDisposition.unresolved) {
                final raw = await api.cloudSyncStageReceivedArchiveInspection(
                  prepared: prepared,
                  nativeWriterPauseToken: token,
                );
                var foundOwned = false;
                try {
                  final found = CloudSyncReceivedRecordObservation.fromNative(
                    raw,
                    source: source.source,
                    parentBinding: parent.binding,
                    now: DateTime.now(),
                  );
                  await validate();
                  void validateParent() {
                    if (_parent(scope, source).source != parent.source) {
                      throw StateError(
                        'cloud_sync_received_archive_parent_changed',
                      );
                    }
                  }

                  journal.replaceAbsenceWithFound(
                    expected: source,
                    found: found,
                    currentAuth: auth,
                    stillCurrent: stillCurrent,
                    validateParent: validateParent,
                  );
                  foundOwned = true;
                  await transport.commitProtectedPageLease(
                    found.rawLeaseReference!,
                    {found.rawReference!},
                  );
                  await validate();
                  journal.markRecordObservationCommitted(
                    intentId: source.intentId,
                    source: source.source,
                    observation: found,
                    currentAuth: auth,
                    stillCurrent: stillCurrent,
                    validateParent: validateParent,
                  );
                } catch (_) {
                  final lease = raw.protectedRawRecordLeaseReference;
                  if (!foundOwned && lease != null) {
                    try {
                      await transport.rollbackProtectedPageLease(lease);
                    } catch (_) {}
                  }
                  rethrow;
                }
              }
              throw StateError('cloud_sync_received_archive_not_absent');
            }
            final stage = await api.cloudSyncStageReceivedArchiveCreate(
              prepared: prepared,
              nativeWriterPauseToken: token,
              parentBindingSha256: _parentDigest(parent.binding),
            );
            var owned = false;
            try {
              await validate();
              if (stage.logicalEntityKeyHash !=
                      source.observation.logicalEntityKeyHash ||
                  stage.serverRecordIdHash !=
                      source.observation.serverRecordIdHash ||
                  stage.protectedPayloadReference !=
                      stage.protectedServerRecordReference) {
                throw StateError(
                  'cloud_sync_received_archive_admission_changed',
                );
              }
              final now = DateTime.fromMillisecondsSinceEpoch(
                source.createdAtMs,
                isUtc: true,
              );
              final operation = durable.admitProtectedReceivedCreate(
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
              return operation;
            } catch (_) {
              if (!owned) {
                try {
                  await transport.rollbackProtectedPageLease(
                    stage.leaseReference,
                  );
                } catch (_) {}
              }
              rethrow;
            }
          }),
        );
      } finally {
        await api.cloudSyncDiscardReceivedArchiveInspection(prepared: prepared);
      }
    });
  }
}
