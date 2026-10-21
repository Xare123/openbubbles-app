import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:crypto/crypto.dart';

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_attachment_upload_journal.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_historical_parent_binding.dart';
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
    required this.receivedArchiveAllowed,
    this.receivedMediaArchiveAllowed,
    this.attachmentUploads,
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
  final bool Function() receivedArchiveAllowed;
  final bool Function()? receivedMediaArchiveAllowed;
  final CloudSyncAttachmentUploadJournal? attachmentUploads;

  void _requireMediaReadback(int intentId, String? proof) {
    if (proof == null) return;
    final uploads = attachmentUploads;
    if (uploads == null) {
      throw StateError('cloud_sync_attachment_parent_inventory_required');
    }
    uploads.requireReceivedParentReadbackProof(
      receivedIntentId: intentId, proof: proof, receivedJournal: journal);
  }

  Future<String?> _captureMediaReadback(
    CloudSyncScope scope,
    CloudSyncReceivedArchiveAdmissionSource source,
  ) async {
    final message = store.box<Message>().get(source.localMessageId);
    if (message == null) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    if (!message.hasAttachments) return null;
    void requireMediaConsent() {
      _requireReceivedConsent();
      if (receivedMediaArchiveAllowed?.call() != true) {
        throw StateError('cloud_sync_received_archive_confirmation_required');
      }
    }
    requireMediaConsent();
    final uploads = attachmentUploads;
    if (uploads == null) {
      throw StateError('cloud_sync_attachment_parent_inventory_required');
    }
    final inventory = await readSession.run((token) {
      requireMediaConsent();
      return api.cloudSyncInspectReceivedAttachmentSources(
        cloudMessagesClient: _client,
        context: api.CloudSyncReceivedAttachmentContext(
          storageDirectory: storageDirectory, expectedAuth: _nativeAuth,
          source: _source(source.source)));
    });
    await _validateReceived();
    requireMediaConsent();
    journal.validateCreateAdmission(transactionStore: store, scope: scope,
      expected: source, currentAuth: auth,
      stillCurrent: _receivedStillCurrent);
    return uploads.captureReceivedParentReadbackProof(
      receivedIntentId: source.intentId, receivedJournal: journal,
      sourceAttachmentKeys: inventory.map((item) => item.logicalEntityKeyHash));
  }

  void _requireReceivedConsent() {
    if (!receivedArchiveAllowed() || !stillCurrent()) {
      throw StateError('cloud_sync_received_archive_confirmation_required');
    }
  }

  Future<void> _validateReceived() async {
    _requireReceivedConsent();
    await validate();
    _requireReceivedConsent();
  }

  bool _receivedStillCurrent() => receivedArchiveAllowed() && stillCurrent();

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

  // This shared selector supplies only the ordinary restored direct/group
  // parent proof. Historical origin is not inferred or used by this lane.
  CloudSyncHistoricalParentProof _parent(
    CloudSyncScope scope,
    CloudSyncReceivedArchiveAdmissionSource source,
  ) {
    final message = store.box<Message>().get(source.localMessageId);
    if (message != null && message.chat.targetId != source.localChatId) {
      throw StateError('cloud_sync_received_archive_parent_changed');
    }
    final parent = requireCloudSyncHistoricalParentProof(
      store: store,
      messageScope: scope,
      chatId: source.localChatId,
      expectedBinding: source.observation.parentBinding,
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
    // Revoking future received uploads cannot discard an entered operation's
    // exact readback/reconciliation. These statuses carry no fresh-create
    // authority; pending/leased creates still require the scoped grant.
    final readbackOnly = operation.status == CloudOutboxStatus.unknownOutcome ||
        operation.status == CloudOutboxStatus.confirmed;
    void requireProofAccess() {
      if (!stillCurrent()) throw StateError('cloud_sync_received_archive_identity_changed');
      if (!readbackOnly) {
        _requireReceivedConsent();
        if (journal.readAdoptedSource(transactionStore: store, operation: operation)
                ?.attachmentReadbackProof != null && receivedMediaArchiveAllowed?.call() != true) {
          throw StateError('cloud_sync_received_archive_confirmation_required');
        }
      }
    }
    Future<void> validateProofAccess() async {
      requireProofAccess();
      await validate();
      requireProofAccess();
    }
    await validateProofAccess();
    final source = journal.readAdoptedSource(
      transactionStore: store,
      operation: operation,
    )!;
    _requireMediaReadback(source.intentId, source.attachmentReadbackProof);
    final parent = _parent(scope, source);
    final proof = await readSession.run((token) {
      requireProofAccess();
      return api.cloudSyncOpenReceivedArchiveCreateProof(
        cloudMessagesClient: _client,
        nativeWriterPauseToken: token,
        storageDirectory: storageDirectory,
        expectedAuth: _nativeAuth,
        receivedSource: _source(source.source),
        chatGeneration: BigInt.from(parent.generation),
        chatLogicalEntityKeyHash: parent.logicalEntityKeyHash,
        chatSource: parent.source,
        parentBindingSha256: _parentDigest(parent.binding),
        attachmentReadbackBindingSha256: source.attachmentReadbackProof == null
            ? null : _parentDigest(source.attachmentReadbackProof!),
      );
    });
    await validateProofAccess();
    _requireMediaReadback(source.intentId, source.attachmentReadbackProof);
    final current = durable.readReceivedArchiveOperation(scope, operationId);
    if (current == null ||
        current.operationId != operation.operationId ||
        current.scope != operation.scope ||
        current.status != operation.status ||
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
    _requireReceivedConsent();
    if (!CloudSyncDevGate.receivedArchiveUploadsEnabled ||
        !CloudSyncDevGate.receivedArchiveCaptureEnabled ||
        !CloudSyncDevGate.receivedArchiveInspectionEnabled) {
      throw StateError('cloud_sync_received_archive_uploads_disabled');
    }
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    await _validateReceived();
    await CloudProtectedPageLeaseLifecycle(
      store: durable,
      transport: transport,
    ).ensureRecoveredBeforeWrite();
    await _validateReceived();
    final source = journal.readForCreateAdmission(
      intentId: intentId,
      currentAuth: auth,
    );
    final parent = _parent(scope, source);
    final checkpoint = await durable.readCheckpoint(scope);
    await _validateReceived();
    if (checkpoint.generation != source.observation.generation) {
      throw StateError('cloud_sync_received_archive_admission_changed');
    }
    final attachmentProof = await _captureMediaReadback(scope, source);
    void requireCreateConsent() {
      _requireReceivedConsent();
      if (attachmentProof != null && receivedMediaArchiveAllowed?.call() != true) {
        throw StateError('cloud_sync_received_archive_confirmation_required');
      }
    }
    Future<void> validateCreateConsent() async {
      requireCreateConsent();
      await _validateReceived();
      requireCreateConsent();
    }
    bool createStillCurrent() => _receivedStillCurrent() &&
        (attachmentProof == null || receivedMediaArchiveAllowed?.call() == true);
    await validateCreateConsent();
    _requireMediaReadback(source.intentId, attachmentProof);
    return readSession.run((token) async {
      requireCreateConsent();
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
            await validateCreateConsent();
            journal.validateCreateAdmission(
              transactionStore: store,
              scope: scope,
              expected: source,
              currentAuth: auth,
              stillCurrent: createStillCurrent,
            );
            if (_parent(scope, source).source != parent.source) {
              throw StateError('cloud_sync_received_archive_parent_changed');
            }
            _requireMediaReadback(source.intentId, attachmentProof);
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
                  await validateCreateConsent();
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
                    stillCurrent: createStillCurrent,
                    validateParent: validateParent,
                  );
                  foundOwned = true;
                  await transport.commitProtectedPageLease(
                    found.rawLeaseReference!,
                    {found.rawReference!},
                  );
                  await validateCreateConsent();
                  journal.markRecordObservationCommitted(
                    intentId: source.intentId,
                    source: source.source,
                    observation: found,
                    currentAuth: auth,
                    stillCurrent: createStillCurrent,
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
              attachmentReadbackBindingSha256: attachmentProof == null
                  ? null : _parentDigest(attachmentProof),
            );
            var owned = false;
            try {
              await validateCreateConsent();
              _requireMediaReadback(source.intentId, attachmentProof);
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
                stillCurrent: createStillCurrent,
                attachmentReadbackProof: attachmentProof,
              );
              owned = true;
              await transport.commitProtectedPageLease(stage.leaseReference, {
                stage.protectedPayloadReference,
              });
              await validateCreateConsent();
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
