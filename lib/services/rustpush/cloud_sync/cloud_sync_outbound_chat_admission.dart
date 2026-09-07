import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_chat_identity_evidence.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_origin.dart';
import 'cloud_sync_outbound_staging.dart';
import 'objectbox_cloud_sync_store.dart';

/// Local-only admission of a direct Chat dependency. The existing engine still
/// owns leasing, remote permission, submission and uncertain-outcome recovery.
final class CloudSyncOutboundChatAdmissionCoordinator {
  const CloudSyncOutboundChatAdmissionCoordinator({
    required this._store,
    required this._transport,
    required this._ensureProtectedStoreRecovered,
    this._observeChatIdentity,
  });

  final ObjectBoxCloudSyncStore _store;
  final CloudSyncOutboundChatStagingTransport _transport;
  final Future<void> Function() _ensureProtectedStoreRecovered;
  final Future<CloudSyncChatIdentityEvidence?> Function(
    CloudSyncOutboundChatOrigin origin,
    CloudSyncProtectedOutboundStageData stage,
  )?
  _observeChatIdentity;

  Future<CloudOutboxOperation> admitChat(
    CloudSyncScope scope, {
    required int chatId,
    required DateTime createdAt,
    required CloudSyncLocalSendAuthFence authFence,
    CloudSyncLocalSendAdmissionSource? localSendSource,
    void Function()? validateLocalOrigin,
    api.CloudChat Function(CloudSyncOutboundChatOrigin)? encode,
  }) => _transport.runOutboundAdmissionExclusive(() async {
    await _ensureProtectedStoreRecovered();
    final existing = await authFence.run(() {
      validateLocalOrigin?.call();
      return _store.readOutboundChatCreateForLocalRow(scope, chatId);
    }, accountFingerprint: scope.accountFingerprint);
    if (existing != null) {
      if (_store.isRetiredUnsubmittedChatCreate(existing)) {
        throw StateError('cloud_sync_outbound_chat_source_retired');
      }
      return existing;
    }

    final origin = await authFence.run(
      () => _observeChatIdentity != null && localSendSource != null
          ? _store.captureOutboundChatObservationOrigin(
              scope,
              chatId,
              localSendSource: localSendSource,
            )
          : _store.captureFreshOutboundChatOrigin(
              scope,
              chatId,
              localSendSource: localSendSource,
            ),
      accountFingerprint: scope.accountFingerprint,
    );
    final candidate = (encode ?? _encodeOrigin)(origin);
    if (candidate.guid != origin.canonicalGuid ||
        candidate.chatIdentifier != origin.chatIdentifier ||
        candidate.groupId != origin.originalGuid ||
        candidate.originalGroupId != origin.originalGuid ||
        candidate.lastAddressedHandle != origin.usingHandle ||
        candidate.serviceName != 'iMessage' ||
        candidate.style != 45 ||
        candidate.participants.length != 1 ||
        candidate.participants.single.uri != origin.chatIdentifier) {
      throw StateError('cloud_sync_outbound_chat_encoded_identity_changed');
    }
    final stage = await _transport.stageOutboundChat(scope, chat: candidate);
    var adopted = false;
    try {
      final identityEvidence = await _observeChatIdentity?.call(origin, stage);
      final operation = await authFence.run(
        () => _store.admitProtectedOutboundChatCreate(
          draft: CloudOutboxDraft(
            scope: scope,
            logicalEntityKeyHash: stage.logicalEntityKeyHash,
            action: CloudOutboxAction.save,
            payloadVersion: cloudSyncOutboundChatPayloadVersion,
            dependencyOperationIds: const {},
            createdAt: createdAt,
            encryptedPayloadReference: stage.protectedEnvelopeReference,
            payloadSha256: stage.payloadSha256,
            serverRecordIdHash: stage.serverRecordIdHash,
            protectedLeaseReference: stage.leaseReference,
          ),
          recordMapping: CloudRecordMapEntry(
            scope: scope,
            logicalEntityKeyHash: stage.logicalEntityKeyHash,
            serverRecordIdHash: stage.serverRecordIdHash,
            encryptedServerRecordId: stage.protectedEnvelopeReference,
            updatedAt: createdAt,
          ),
          origin: origin,
          localSendSource: localSendSource,
          validateLocalOrigin: validateLocalOrigin,
          identityEvidence: identityEvidence,
        ),
        accountFingerprint: scope.accountFingerprint,
      );
      adopted = true;
      await _transport.commitOutboundLease(
        stage.leaseReference,
        stage.protectedEnvelopeReference,
      );
      return operation;
    } catch (_) {
      if (!adopted) {
        try {
          await _transport.rollbackOutboundLease(stage.leaseReference);
        } catch (_) {
          // Startup recovery may reclaim an unadopted lease. An adopted
          // envelope must survive a later native commit failure.
        }
      }
      rethrow;
    }
  });

  /// Use the shipping direct-chat shape without calling Chat.toCloud(), whose
  /// identifier mutations occur before remote confirmation.
  static api.CloudChat _encodeOrigin(CloudSyncOutboundChatOrigin origin) =>
      api.CloudChat(
        style: 45,
        isFiltered: 0,
        successfulQuery: 1,
        state: 3,
        chatIdentifier: origin.chatIdentifier,
        groupId: origin.originalGuid,
        originalGroupId: origin.originalGuid,
        serviceName: 'iMessage',
        participants: [api.CloudParticipant(uri: origin.chatIdentifier)],
        lastAddressedHandle: origin.usingHandle,
        guid: origin.canonicalGuid,
        lastReadMessageTimestamp: 0,
        properties: api.CloudProp(
          pv: 1,
          numberOfTimesRespondedtoThread: 3,
          shouldForceToSms: false,
          legacyGroupIdentifiers: [],
          messageHandshakeState: 1,
        ),
        prop001: const api.CloudProp001(syndicationType: 0),
        proto001: api.encodeChatproto(chat: const api.ChatProto(unk1: 0)),
      );
}
