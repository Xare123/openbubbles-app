import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_chat_identity_evidence.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_chat_identity_origin.dart';
import 'cloud_sync_outbound_group_origin.dart';
import 'cloud_sync_outbound_staging.dart';
import 'objectbox_cloud_sync_store.dart';

/// Local-only admission of an explicitly journal-bound Chat dependency.
/// Direct and fresh-group native capabilities and identity rules stay separate.
/// The existing engine still
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
    CloudSyncLocalChatCreateOrigin origin,
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
    api.CloudChat Function(CloudSyncLocalChatCreateOrigin)? encode,
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
    if (origin is CloudSyncOutboundGroupOrigin &&
        (localSendSource == null ||
         _transport is! CloudSyncOutboundGroupChatStagingTransport)) {
      throw StateError('cloud_sync_outbound_group_staging_unavailable');
    }
    final candidate = (encode ?? encodeOrigin)(origin);
    if (candidate.guid != origin.canonicalGuid ||
        candidate.chatIdentifier != origin.chatIdentifier ||
        candidate.groupId != origin.originalGuid ||
        candidate.originalGroupId != origin.originalGuid ||
        candidate.lastAddressedHandle != origin.usingHandle ||
        candidate.serviceName != 'iMessage' ||
        (origin is CloudSyncOutboundGroupOrigin
          ? !_matchesGroupCandidate(origin, candidate)
          : candidate.style != 45 ||
            candidate.participants.length != 1 ||
            candidate.participants.single.uri != origin.chatIdentifier)) {
      throw StateError('cloud_sync_outbound_chat_encoded_identity_changed');
    }
    final stage = origin is CloudSyncOutboundGroupOrigin
        ? await (_transport as CloudSyncOutboundGroupChatStagingTransport)
            .stageOutboundGroupChat(scope, chat: candidate)
        : await _transport.stageOutboundChat(scope, chat: candidate);
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
  static api.CloudChat encodeOrigin(CloudSyncLocalChatCreateOrigin origin) =>
      origin is CloudSyncOutboundGroupOrigin ? encodeGroupOrigin(origin) :
        encodeDirectIdentity(originalGuid: origin.originalGuid,
          recipient: origin.chatIdentifier, sender: origin.usingHandle);

  static bool _matchesGroupCandidate(
    CloudSyncOutboundGroupOrigin origin, api.CloudChat candidate,
  ) {
    final actual = candidate.participants.map((p) => p.uri).toList()..sort();
    final expected = origin.members.toList()..sort();
    return candidate.style == 43 &&
      actual.length == expected.length &&
      List.generate(actual.length, (i) => actual[i] == expected[i]).every((v) => v) &&
      candidate.properties?.pv == origin.groupVersion &&
      candidate.displayName == origin.displayName &&
      candidate.groupPhoto == null && candidate.groupPhotoGuid == null;
  }

  static api.CloudChat encodeGroupOrigin(CloudSyncOutboundGroupOrigin origin) =>
      api.CloudChat(
        style: 43, isFiltered: 0, successfulQuery: 1, state: 3,
        chatIdentifier: origin.chatIdentifier,
        groupId: origin.originalGuid, originalGroupId: origin.originalGuid,
        serviceName: 'iMessage',
        participants: origin.members.map((uri) =>
          api.CloudParticipant(uri: uri)).toList(),
        lastAddressedHandle: origin.usingHandle, guid: origin.canonicalGuid,
        displayName: origin.displayName, lastReadMessageTimestamp: 0,
        properties: api.CloudProp(
          pv: origin.groupVersion, numberOfTimesRespondedtoThread: 3,
          shouldForceToSms: false, legacyGroupIdentifiers: [],
          messageHandshakeState: 1,
        ),
        prop001: const api.CloudProp001(syndicationType: 0),
        proto001: api.encodeChatproto(chat: const api.ChatProto(unk1: 0)),
      );

  /// Shared wire shape for staging and the Windows protected-stage diagnostic.
  /// Construction is not admission, a native-send receipt, or write authority.
  static api.CloudChat encodeDirectIdentity({
    required String originalGuid, required String recipient, required String sender,
  }) =>
      api.CloudChat(
        style: 45,
        isFiltered: 0,
        successfulQuery: 1,
        state: 3,
        chatIdentifier: recipient,
        groupId: originalGuid,
        originalGroupId: originalGuid,
        serviceName: 'iMessage',
        participants: [api.CloudParticipant(uri: recipient)],
        lastAddressedHandle: sender,
        guid: 'iMessage;-;$recipient',
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
