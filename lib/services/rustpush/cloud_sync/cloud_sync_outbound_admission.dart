// ignore_for_file: prefer_initializing_formals

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'objectbox_cloud_sync_store.dart';

/// Crash-safe protected admission. Admission is local and grants no permission
/// to transmit; writer, checkpoint and unknown-outcome fences still apply.
final class CloudSyncOutboundAdmissionCoordinator {
  const CloudSyncOutboundAdmissionCoordinator({
    required ObjectBoxCloudSyncStore store,
    required CloudSyncOutboundStagingTransport transport,
    required Future<void> Function() ensureProtectedStoreRecovered,
  }) : _store = store,
       _transport = transport,
       _ensureProtectedStoreRecovered = ensureProtectedStoreRecovered;

  final ObjectBoxCloudSyncStore _store;
  final CloudSyncOutboundStagingTransport _transport;
  final Future<void> Function() _ensureProtectedStoreRecovered;

  Future<CloudOutboxOperation> admitMessage(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  }) => _transport.runOutboundAdmissionExclusive(() async {
    await _ensureProtectedStoreRecovered();
    return _stageAndAdmit(
      scope,
      message: message,
      createdAt: createdAt,
      adopt: (draft, mapping) => _store.admitProtectedOutboundCreate(
        draft: draft,
        recordMapping: mapping,
      ),
    );
  });

  /// Adopt a successfully submitted local origin exactly once. After process
  /// death or commit uncertainty the journal resolves to its original outbox
  /// envelope without consulting or re-encoding a mutable Message.
  Future<CloudOutboxOperation> admitLocalSend(
    CloudSyncScope scope, {
    required int intentId,
    required CloudSyncLocalSendJournal journal,
    required CloudSyncLocalSendAuthFence authFence,
    frb_api.CloudMessage Function(Message)? encodeMessage,
  }) => _transport.runOutboundAdmissionExclusive(() async {
    if (scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_local_send_scope_invalid');
    }
    await _ensureProtectedStoreRecovered();
    final (source, candidate) = await authFence.run(() {
      final source = journal.readForAdmission(intentId);
      if (source.accountFingerprint != scope.accountFingerprint) {
        throw StateError('cloud_sync_local_send_identity_changed');
      }
      if (source.admittedOperationId == null) {
        _store.requireFreshOutboundProjectionReady(scope, localSendSource: source);
      }
      final local = source.message;
      // Encoding is synchronous with source revalidation. Native staging may
      // await, so the persisted source is checked again inside adoption.
      final candidate = local == null
          ? null
          : (encodeMessage ?? _encodeLocalMessage)(local);
      if (candidate != null &&
          (candidate.guid != local!.guid ||
              candidate.type != 1 ||
              candidate.service != 'iMessage' ||
              candidate.sender.isNotEmpty ||
              candidate.chatId != local.chat.target!.guid ||
              candidate.destinationCallerId !=
                  local.chat.target!.usingHandle!
                      .replaceFirst('mailto:', '')
                      .replaceFirst('tel:', ''))) {
        throw StateError('cloud_sync_local_send_encoded_identity_changed');
      }
      return (source, candidate);
    }, accountFingerprint: scope.accountFingerprint);

    if (source.admittedOperationId != null) {
      return authFence.run(
        () => _store.readAdoptedLocalSendOperation(
          scope,
          journal: journal,
          source: source,
        ),
        accountFingerprint: scope.accountFingerprint,
      );
    }
    if (candidate == null) {
      throw StateError('cloud_sync_local_send_not_ready');
    }
    return _stageAndAdmit(
      scope,
      message: candidate,
      createdAt: source.createdAtUtc,
      adopt: (draft, mapping) => authFence.run(
        () => _store.admitProtectedLocalSendCreate(
          draft: draft,
          recordMapping: mapping,
          journal: journal,
          source: source,
        ),
        accountFingerprint: scope.accountFingerprint,
      ),
    );
  });

  static frb_api.CloudMessage _encodeLocalMessage(Message message) =>
      message.toCloud(true);

  Future<CloudOutboxOperation> _stageAndAdmit(
    CloudSyncScope scope, {
    required frb_api.CloudMessage message,
    required DateTime createdAt,
    required Future<CloudOutboxOperation> Function(
      CloudOutboxDraft,
      CloudRecordMapEntry,
    )
    adopt,
  }) async {
    final stage = await _transport.stageOutboundMessage(
      scope,
      message: message,
    );
    final draft = CloudOutboxDraft(
      scope: scope,
      logicalEntityKeyHash: stage.logicalEntityKeyHash,
      action: CloudOutboxAction.save,
      payloadVersion: cloudSyncOutboundPayloadVersion,
      dependencyOperationIds: const {},
      createdAt: createdAt,
      encryptedPayloadReference: stage.protectedEnvelopeReference,
      payloadSha256: stage.payloadSha256,
      serverRecordIdHash: stage.serverRecordIdHash,
      protectedLeaseReference: stage.leaseReference,
    );
    var adoptedByOutbox = false;
    try {
      final operation = await adopt(
        draft,
        CloudRecordMapEntry(
          scope: scope,
          logicalEntityKeyHash: stage.logicalEntityKeyHash,
          serverRecordIdHash: stage.serverRecordIdHash,
          encryptedServerRecordId: stage.protectedEnvelopeReference,
          updatedAt: createdAt,
        ),
      );
      if (operation.protectedLeaseReference != stage.leaseReference) {
        await _rollbackBestEffort(stage.leaseReference);
        return operation;
      }
      adoptedByOutbox = true;
      await _transport.commitOutboundLease(
        stage.leaseReference,
        stage.protectedEnvelopeReference,
      );
      return operation;
    } catch (_) {
      if (!adoptedByOutbox) {
        await _rollbackBestEffort(stage.leaseReference);
      }
      rethrow;
    }
  }

  Future<void> _rollbackBestEffort(String leaseReference) async {
    try {
      await _transport.rollbackOutboundLease(leaseReference);
    } catch (_) {
      // An unadopted manifest is safe to leak. Bounded startup recovery rolls
      // it back without touching any ObjectBox-adopted operation.
    }
  }
}
