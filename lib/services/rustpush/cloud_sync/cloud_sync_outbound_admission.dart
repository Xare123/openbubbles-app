// ignore_for_file: prefer_initializing_formals

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;

import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_staging.dart';
import 'objectbox_cloud_sync_store.dart';

/// Crash-safe admission for the first create-only outbound text canary.
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
      final operation = await _store.admitProtectedOutboundCreate(
        draft: draft,
        recordMapping: CloudRecordMapEntry(
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
  });

  Future<void> _rollbackBestEffort(String leaseReference) async {
    try {
      await _transport.rollbackOutboundLease(leaseReference);
    } catch (_) {
      // An unadopted manifest is safe to leak. Bounded startup recovery rolls
      // it back without touching any ObjectBox-adopted operation.
    }
  }
}
