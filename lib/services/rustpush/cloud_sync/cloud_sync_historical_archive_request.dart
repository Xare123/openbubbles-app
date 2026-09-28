library;

import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

/// Pure eligibility for one stored on-device message row as a historical
/// archive candidate (v2: supervisor review corrections applied).
/// Grants no upload authority; performs no network or database work.
///
/// Provenance is the immutable snapshot binding plus the same authenticated
/// account, never observedViaLiveReceive. Origins historicalReceived and
/// historicalSent preserve direction without claiming live observation.
/// Timestamps are Unix milliseconds. Remote record identity stays native;
/// guidHash/sourceSha256 are lane-local intent ids, and dedupe keys on the
/// exact GUID string. Plain-structure attributedBody is accepted; markers
/// reject separately with retained reasons.

/// Currently authenticated account and store binding, supplied separately
/// from the snapshot manifest at assessment time. The manifest account must
/// equal this binding or the row fails closed.
class CloudSyncHistoricalAccountBinding {
  const CloudSyncHistoricalAccountBinding({
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
  });

  final String accountFingerprint;
  final String protectedStoreIdentity;

  bool get hasValidShape =>
      _boundedIdentifier(accountFingerprint) &&
      _boundedIdentifier(protectedStoreIdentity);
}

/// Lower bound for stored creation times in Unix milliseconds: the native
/// codec converts millis to Apple-epoch nanoseconds via
/// (millis - 978307200000) * 1000000 and requires the result to be
/// positive, so the first representable millisecond is one after that epoch.
const _minDateCreatedMs = 978307200001;
const _maxDateCreatedMs = 10201679236854;

/// Clock-skew tolerance above the assessing clock for stored times.
const _futureSkewMs = 86400000;

/// Maximum UTF-8 bytes of one row text, matching the native codec 256 KiB.
const _maxTextBytes = 262144;
const cloudSyncHistoricalMaxSourceBytes = 1048576;

/// Historical origin. Distinct values from the live lane.
enum CloudSyncHistoricalArchiveOrigin {
  /// Row addressed to this account from another party.
  historicalReceived,

  /// Row sent from this account, sender mapped to the manifest.
  historicalSent,
}

/// Qualified source snapshot. Shape-validated here; rows must also carry
/// its exact snapshot hash or the assessment fails closed.
class CloudSyncHistoricalSourceManifest {
  const CloudSyncHistoricalSourceManifest({
    required this.snapshotSha256,
    required this.accountFingerprint,
    required this.accountHandles,
    required this.messageCount,
    required this.capturedAtMs,
  });

  /// Lowercase hex SHA-256 of the immutable source snapshot.
  final String snapshotSha256;

  /// Authenticated account fingerprint the snapshot belongs to.
  final String accountFingerprint;

  /// Qualified local handles for sent-identity mapping. Empty fails closed.
  final List<String> accountHandles;

  /// Row count observed at capture; must be positive.
  final int messageCount;

  /// Unix milliseconds when the snapshot was captured.
  final int capturedAtMs;

  /// Shape validation only; necessary but never sufficient. Rows must also
  /// carry the exact snapshot hash, and the manifest account must equal the
  /// currently authenticated binding supplied separately. Shape alone never
  /// proves ownership.
  bool hasValidShape({required int nowMs}) =>
      _snapshotHex.hasMatch(snapshotSha256) &&
      _boundedIdentifier(accountFingerprint) &&
      accountHandles.isNotEmpty &&
      accountHandles.length <= 64 &&
      accountHandles.every(_boundedIdentifier) &&
      messageCount > 0 &&
      capturedAtMs >= _minDateCreatedMs &&
      capturedAtMs <= nowMs + _futureSkewMs;
}

/// Exact persisted member metadata. Capture never substitutes a current account
/// alias or treats the stored member list as membership at message creation.
final class CloudSyncHistoricalParticipantView {
  const CloudSyncHistoricalParticipantView({
    required this.address,
    required this.service,
  });

  final String address;
  final String service;
}

/// Optional additive group metadata. Old sealed snapshots lack these details;
/// they must remain unknown, not be filled from a later mutable chat.
final class CloudSyncHistoricalGroupMetadata {
  CloudSyncHistoricalGroupMetadata({
    required this.cloudGuid,
    required Iterable<CloudSyncHistoricalParticipantView> participants,
  }) : participants = List.unmodifiable(
         participants.toList()..sort((a, b) {
           final address = a.address.compareTo(b.address);
           return address != 0 ? address : a.service.compareTo(b.service);
         }),
       );

  final String? cloudGuid;
  final List<CloudSyncHistoricalParticipantView> participants;

  /// Exact optional extension shared by the snapshot and native source codec.
  List<Object?> toWire() => <Object?>[
    1,
    cloudGuid,
    participants.map((member) => <Object?>[
      member.address,
      member.service,
    ]).toList(),
  ];
}

/// Plain view of the owning chat. Built by mapHistoricalChat; never read
/// from a database here.
class CloudSyncHistoricalChatView {
  const CloudSyncHistoricalChatView({
    required this.id,
    required this.guid,
    required this.style,
    required this.chatIdentifier,
    required this.isRoutingStub,
    required this.dateDeletedPresent,
    required this.isRpSms,
    required this.participantCount,
    required this.participantAddress,
    required this.participantService,
    this.groupMetadata,
  });

  final int id;
  final String guid;
  final int? style;
  final String? chatIdentifier;
  final bool isRoutingStub;
  final bool dateDeletedPresent;
  final bool isRpSms;
  final int participantCount;
  final String participantAddress;
  final String participantService;
  final CloudSyncHistoricalGroupMetadata? groupMetadata;
}

/// Plain view of one stored row. Built by mapHistoricalRow; never read
/// from a database here.
class CloudSyncHistoricalRowView {
  const CloudSyncHistoricalRowView({
    required this.guid,
    required this.text,
    required this.attributedBodies,
    required this.hasActualEditOrUnsend,
    required this.dateEditedPresent,
    required this.associationPresent,
    required this.isFromMe,
    required this.senderAddress,
    required this.chat,
    required this.dateCreatedMs,
    required this.error,
    required this.isTemp,
    required this.stagingGuid,
    required this.sendingServiceId,
    required this.hasBeenForwarded,
    required this.verificationFailed,
    required this.ckRecordId,
    required this.ckSyncState,
    required this.messageId,
    required this.itemType,
    required this.groupActionType,
    required this.groupTitle,
    required this.isDeleted,
    required this.dateScheduledPresent,
    required this.threadOriginatorPresent,
    required this.hasAttachments,
    required this.attachmentCount,
    required this.subjectPresent,
    required this.expressiveSendStyleIdPresent,
    required this.balloonBundleIdPresent,
    required this.payloadDataPresent,
    required this.hasApplePayloadData,
    required this.amkSessionIdPresent,
    required this.rowSnapshotSha256,
  });

  final String guid;
  final String? text;
  final List<AttributedBody> attributedBodies;
  final bool hasActualEditOrUnsend;
  final bool dateEditedPresent;
  final bool associationPresent;

  /// Unknown stored direction stays unknown, never inferred as incoming.
  final bool? isFromMe;
  final String? senderAddress;
  final CloudSyncHistoricalChatView chat;
  final int dateCreatedMs;
  final int error;
  final bool isTemp;
  final String? stagingGuid;
  final String? sendingServiceId;
  final bool hasBeenForwarded;
  final bool verificationFailed;
  final String? ckRecordId;
  final bool ckSyncState;
  final int messageId;
  final int itemType;
  final int groupActionType;
  final String? groupTitle;
  final bool isDeleted;
  final bool dateScheduledPresent;
  final bool threadOriginatorPresent;
  final bool hasAttachments;
  final int attachmentCount;
  final bool subjectPresent;
  final bool expressiveSendStyleIdPresent;
  final bool balloonBundleIdPresent;
  final bool payloadDataPresent;
  final bool hasApplePayloadData;
  final bool amkSessionIdPresent;
  final String rowSnapshotSha256;
}

/// Result of one pure historical eligibility check.
sealed class CloudSyncHistoricalArchiveAssessment {
  const CloudSyncHistoricalArchiveAssessment();
}

/// Eligible row with its import request.
final class CloudSyncHistoricalArchiveEligible
    extends CloudSyncHistoricalArchiveAssessment {
  const CloudSyncHistoricalArchiveEligible(this.request);

  final CloudSyncHistoricalArchiveRequest request;
}

/// Explicit rejection with a fixed reason code safe to log.
final class CloudSyncHistoricalArchiveIneligible
    extends CloudSyncHistoricalArchiveAssessment {
  const CloudSyncHistoricalArchiveIneligible(this.reason);

  final String reason;
}

/// Import request for one eligible row. Carries identity and binding
/// only; the complete row is re-read and re-assessed at staging time.
class CloudSyncHistoricalArchiveRequest {
  const CloudSyncHistoricalArchiveRequest({
    required this.guid,
    required this.guidHash,
    required this.sourceSha256,
    required this.origin,
    required this.isFromMe,
    required this.chatGuid,
    required this.dateCreatedMs,
    required this.snapshotSha256,
    required this.accountFingerprint,
    required this.protectedStoreIdentity,
    required this.textSha256,
    required this.senderAddress,
    required this.peerAddress,
    this.groupMetadata,
  });

  final String guid;
  final String guidHash;
  final String sourceSha256;
  final CloudSyncHistoricalArchiveOrigin origin;
  final bool isFromMe;
  final String chatGuid;
  final int dateCreatedMs;
  final String snapshotSha256;
  final String accountFingerprint;
  final String protectedStoreIdentity;
  final String textSha256;
  final String senderAddress;
  final String peerAddress;
  final CloudSyncHistoricalGroupMetadata? groupMetadata;
}

/// Fixed reason codes. None carries content, GUIDs, handles, or times.
class CloudSyncHistoricalArchiveReasons {
  static const String bindingMissing =
      'cloud_sync_historical_archive_binding_missing';
  static const String tempGuid = 'cloud_sync_historical_archive_temp_guid';
  static const String verificationFailed =
      'cloud_sync_historical_archive_verification_failed';
  static const String legacyMapped =
      'cloud_sync_historical_archive_legacy_mapped';
  static const String unpersisted = 'cloud_sync_historical_archive_unpersisted';
  static const String directionMismatch =
      'cloud_sync_historical_archive_direction_mismatch';
  static const String identity =
      'cloud_sync_historical_archive_identity_unmapped';
  static const String sendState = 'cloud_sync_historical_archive_send_state';
  static const String systemMessage =
      'cloud_sync_historical_archive_system_message';
  static const String tombstone = 'cloud_sync_historical_archive_tombstone';
  static const String scheduled = 'cloud_sync_historical_archive_scheduled';
  static const String sms = 'cloud_sync_historical_archive_sms';
  static const String reply = 'cloud_sync_historical_archive_reply';
  static const String reaction = 'cloud_sync_historical_archive_reaction';
  static const String media = 'cloud_sync_historical_archive_media';
  static const String mutation = 'cloud_sync_historical_archive_mutation';
  static const String richPayload =
      'cloud_sync_historical_archive_rich_payload';
  static const String route = 'cloud_sync_historical_archive_route';
  static const String group = 'cloud_sync_historical_archive_group';
  static const String counterparts =
      'cloud_sync_historical_archive_counterparts';
  static const String body = 'cloud_sync_historical_archive_body';
  static const String timestamp = 'cloud_sync_historical_archive_timestamp';
}

/// Pure eligibility mapping for one stored row view plus its manifest.
/// Rule order mirrors the live-receive lane, minus live-only provenance.
CloudSyncHistoricalArchiveAssessment assessHistoricalArchiveRow(
  CloudSyncHistoricalRowView row,
  CloudSyncHistoricalSourceManifest manifest,
  CloudSyncHistoricalAccountBinding account, {
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  if (!manifest.hasValidShape(nowMs: now) ||
      row.rowSnapshotSha256 != manifest.snapshotSha256 ||
      manifest.accountFingerprint != account.accountFingerprint ||
      !account.hasValidShape) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.bindingMissing,
    );
  }
  return _assessHistoricalBoundRow(
    row,
    snapshotSha256: manifest.snapshotSha256,
    accountFingerprint: manifest.accountFingerprint,
    protectedStoreIdentity: account.protectedStoreIdentity,
    nowMs: now,
    classifySender: (sender, fromMe) {
      final senderIsLocal = manifest.accountHandles.contains(sender);
      if (senderIsLocal && fromMe) {
        return CloudSyncHistoricalArchiveOrigin.historicalSent;
      }
      if (!senderIsLocal && !fromMe) {
        return CloudSyncHistoricalArchiveOrigin.historicalReceived;
      }
      return null;
    },
  );
}

/// Compares a current local row with an already-qualified immutable request.
/// This grants no snapshot/account authority and constructs no account handles.
/// In particular, the peer of a received message is not the local account.
bool historicalArchiveRowMatchesRequest(
  CloudSyncHistoricalRowView row,
  CloudSyncHistoricalArchiveRequest request, {
  int? nowMs,
}) {
  if (row.rowSnapshotSha256 != request.snapshotSha256 ||
      row.guid != request.guid ||
      row.chat.guid != request.chatGuid ||
      row.chat.participantAddress != request.peerAddress ||
      row.dateCreatedMs != request.dateCreatedMs) {
    return false;
  }
  final assessment = _assessHistoricalBoundRow(
    row,
    snapshotSha256: request.snapshotSha256,
    accountFingerprint: request.accountFingerprint,
    protectedStoreIdentity: request.protectedStoreIdentity,
    nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    classifySender: (sender, fromMe) =>
        sender == request.senderAddress &&
            fromMe == request.isFromMe &&
            fromMe ==
                (request.origin ==
                    CloudSyncHistoricalArchiveOrigin.historicalSent)
        ? request.origin
        : null,
  );
  return assessment is CloudSyncHistoricalArchiveEligible &&
      assessment.request.guidHash == request.guidHash &&
      assessment.request.textSha256 == request.textSha256 &&
      assessment.request.sourceSha256 == request.sourceSha256;
}

CloudSyncHistoricalArchiveAssessment _assessHistoricalBoundRow(
  CloudSyncHistoricalRowView row, {
  required String snapshotSha256,
  required String accountFingerprint,
  required String protectedStoreIdentity,
  required int nowMs,
  required CloudSyncHistoricalArchiveOrigin? Function(String, bool)
  classifySender,
}) {
  final guid = row.guid;
  if (!_boundedIdentifier(guid) ||
      guid.startsWith('temp') ||
      guid.startsWith('error')) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.tempGuid,
    );
  }
  if (row.verificationFailed) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.verificationFailed,
    );
  }
  if (row.ckRecordId != null || row.ckSyncState) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.legacyMapped,
    );
  }
  if (row.messageId <= 0 || row.chat.id <= 0) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.unpersisted,
    );
  }
  final fromMe = row.isFromMe;
  if (fromMe == null) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.directionMismatch,
    );
  }
  final sender = row.senderAddress;
  if (sender == null || !_boundedIdentifier(sender)) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.directionMismatch,
    );
  }
  final origin = classifySender(sender, fromMe);
  if (origin == null) {
    return CloudSyncHistoricalArchiveIneligible(
      fromMe
          ? CloudSyncHistoricalArchiveReasons.identity
          : CloudSyncHistoricalArchiveReasons.directionMismatch,
    );
  }
  if (row.error != 0 ||
      row.isTemp ||
      row.stagingGuid != null ||
      row.sendingServiceId != null ||
      row.hasBeenForwarded) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.sendState,
    );
  }
  if (row.itemType != 0 || row.groupActionType != 0 || row.groupTitle != null) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.systemMessage,
    );
  }
  if (row.isDeleted) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.tombstone,
    );
  }
  if (row.dateScheduledPresent) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.scheduled,
    );
  }
  if (row.chat.isRpSms) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.sms,
    );
  }
  if (row.threadOriginatorPresent) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.reply,
    );
  }
  if (row.associationPresent) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.reaction,
    );
  }
  if (row.hasAttachments || row.attachmentCount > 0) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.media,
    );
  }
  if (row.hasActualEditOrUnsend || row.dateEditedPresent) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.mutation,
    );
  }
  if (row.subjectPresent ||
      row.expressiveSendStyleIdPresent ||
      row.balloonBundleIdPresent ||
      row.payloadDataPresent ||
      row.hasApplePayloadData ||
      row.amkSessionIdPresent) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.richPayload,
    );
  }
  final chat = row.chat;
  if (chat.dateDeletedPresent) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.route,
    );
  }
  final isGroup = chat.participantCount > 1 ||
      chat.style == 43 ||
      chat.guid.startsWith('iMessage;+;');
  final group = isGroup ? chat.groupMetadata : null;
  if (isGroup && !_validGroupMetadata(chat, group)) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.group,
    );
  }
  if ((!isGroup && chat.participantCount != 1) ||
      chat.participantService != 'iMessage' ||
      !_boundedIdentifier(chat.participantAddress) ||
      !_boundedIdentifier(chat.guid)) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.route,
    );
  }
  final identifier = chat.chatIdentifier;
  final canonicalDirect =
      chat.style == 45 &&
      !chat.isRoutingStub &&
      identifier != null &&
      identifier.isNotEmpty &&
      chat.guid == 'iMessage;-;$identifier' &&
      chat.participantAddress == identifier;
  final provisionalDirect =
      _uuid.hasMatch(chat.guid) &&
      chat.style == null &&
      identifier == null &&
      !chat.isRoutingStub;
  if (!isGroup && (!canonicalDirect && !provisionalDirect)) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.route,
    );
  }
  if (!isGroup &&
      origin == CloudSyncHistoricalArchiveOrigin.historicalReceived &&
      _bare(sender) != chat.participantAddress) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.counterparts,
    );
  }
  final text = row.text;
  if (text == null ||
      text.trim().isEmpty ||
      text.contains('\u0000') ||
      utf8.encode(text).length > _maxTextBytes ||
      !_hasSinglePlainBody(row.attributedBodies, text)) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.body,
    );
  }
  final createdMs = row.dateCreatedMs;
  if (createdMs < _minDateCreatedMs ||
      createdMs > _maxDateCreatedMs ||
      createdMs > nowMs + _futureSkewMs) {
    return const CloudSyncHistoricalArchiveIneligible(
      CloudSyncHistoricalArchiveReasons.timestamp,
    );
  }
  return CloudSyncHistoricalArchiveEligible(
    CloudSyncHistoricalArchiveRequest(
      guid: guid,
      guidHash: _digest(['cloud-sync-historical-archive-guid-v1', guid]),
      sourceSha256: _digest([
        group == null
            ? 'cloud-sync-historical-archive-source-v1'
            : 'cloud-sync-historical-archive-source-v2',
        guid,
        text,
        sender,
        chat.participantAddress,
        chat.guid,
        createdMs,
        origin.name,
        fromMe,
        snapshotSha256,
        accountFingerprint,
        protectedStoreIdentity,
        if (group != null) group.toWire(),
      ]),
      origin: origin,
      textSha256: historicalTextDigest(text),
      senderAddress: sender,
      peerAddress: chat.participantAddress,
      isFromMe: fromMe,
      chatGuid: chat.guid,
      dateCreatedMs: createdMs,
      snapshotSha256: snapshotSha256,
      accountFingerprint: accountFingerprint,
      protectedStoreIdentity: protectedStoreIdentity,
      groupMetadata: group,
    ),
  );
}

/// This establishes a coherent stored group route, not membership at the time
/// of the message and not the existence of its CloudKit parent. Native creation
/// still requires an independently restored exact parent record.
bool _validGroupMetadata(
  CloudSyncHistoricalChatView chat,
  CloudSyncHistoricalGroupMetadata? group,
) {
  if (group == null || chat.isRoutingStub ||
      group.participants.isEmpty ||
      group.participants.length != chat.participantCount ||
      (group.cloudGuid != null && !_boundedIdentifier(group.cloudGuid!))) {
    return false;
  }
  final identifier = chat.chatIdentifier;
  final canonical = chat.style == 43 && identifier != null &&
      _boundedIdentifier(identifier) && chat.guid == 'iMessage;+;$identifier';
  final provisional = _uuid.hasMatch(chat.guid) &&
      (chat.style == null || chat.style == 43) && identifier == null;
  if (!canonical && !provisional) return false;
  final members = <String>{};
  for (final member in group.participants) {
    if (member.service != 'iMessage' || !_boundedIdentifier(member.address) ||
        !_boundedIdentifier(_bare(member.address)) ||
        !members.add(_bare(member.address))) {
      return false;
    }
  }
  return members.contains(_bare(chat.participantAddress));
}

/// Ownership decision for one exact GUID against registries the caller
/// supplies. Production wiring must feed the V2 record-map plus the
/// local-send and received journals; any exact-GUID ownership suppresses
/// a duplicate upload. Unknown GUIDs proceed; conflicts are retained.
enum CloudSyncHistoricalDedupeVerdict { proceed, skipOwned, retainConflict }

CloudSyncHistoricalDedupeVerdict resolveHistoricalDedupe({
  required String guid,
  required Set<String> ownedGuids,
  required Set<String> conflictGuids,
}) {
  if (conflictGuids.contains(guid)) {
    return CloudSyncHistoricalDedupeVerdict.retainConflict;
  }
  if (ownedGuids.contains(guid)) {
    return CloudSyncHistoricalDedupeVerdict.skipOwned;
  }
  return CloudSyncHistoricalDedupeVerdict.proceed;
}

/// Builds the plain chat view from a persisted entity. Relations must be
/// loaded by the caller through their normal getters.
CloudSyncHistoricalChatView mapHistoricalChat(Chat chat) {
  final handles = chat.handles.toList(growable: false);
  final first = handles.isEmpty ? null : handles.first;
  final group = handles.length > 1 ||
      chat.style == 43 || chat.guid.startsWith('iMessage;+;');
  return CloudSyncHistoricalChatView(
    id: chat.id ?? -1,
    guid: chat.guid,
    style: chat.style,
    chatIdentifier: chat.chatIdentifier,
    isRoutingStub: chat.isRoutingStub,
    dateDeletedPresent: chat.dateDeleted != null,
    isRpSms: chat.isRpSms,
    participantCount: handles.length,
    participantAddress: first?.address ?? '',
    participantService: first?.service ?? '',
    groupMetadata: group
        ? CloudSyncHistoricalGroupMetadata(
            cloudGuid: chat.cloudGuid,
            participants: handles.map((handle) => CloudSyncHistoricalParticipantView(
              address: handle.address,
              service: handle.service,
            )),
          )
        : null,
  );
}

/// Builds the plain row view from persisted entities. The caller supplies
/// the snapshot hash the row was read from; it is rechecked at assessment.
CloudSyncHistoricalRowView mapHistoricalRow({
  required Message message,
  required CloudSyncHistoricalChatView chat,
  required String rowSnapshotSha256,
}) {
  // The transient display cache can be empty even when ObjectBox retains an
  // attachment backlink. Never classify that stored message as plain text.
  final storedAttachments = message.dbAttachments.length;
  return CloudSyncHistoricalRowView(
    guid: message.guid ?? '',
    text: message.text,
    attributedBodies: List<AttributedBody>.of(message.attributedBody),
    hasActualEditOrUnsend: message.messageSummaryInfo.any(
      (summary) =>
          summary.retractedParts.isNotEmpty ||
          summary.editedParts.isNotEmpty ||
          summary.editedContent.isNotEmpty,
    ),
    dateEditedPresent: message.dateEdited != null,
    associationPresent:
        message.associatedMessageGuid != null ||
        message.associatedMessagePart != null ||
        message.associatedMessageType != null ||
        message.associatedMessageEmoji != null,
    isFromMe: message.isFromMe,
    senderAddress: message.handle?.address,
    chat: chat,
    dateCreatedMs: message.dateCreated?.millisecondsSinceEpoch ?? -1,
    error: message.error,
    isTemp: message.temp,
    stagingGuid: message.stagingGuid,
    sendingServiceId: message.sendingServiceId,
    hasBeenForwarded: message.hasBeenForwarded,
    verificationFailed: message.verificationFailed,
    ckRecordId: message.ckRecordId,
    ckSyncState: message.ckSyncState,
    messageId: message.id ?? -1,
    itemType: message.itemType ?? 0,
    groupActionType: message.groupActionType ?? 0,
    groupTitle: message.groupTitle,
    isDeleted: message.dateDeleted != null,
    dateScheduledPresent: message.dateScheduled != null,
    threadOriginatorPresent:
        message.threadOriginatorGuid != null ||
        message.threadOriginatorPart != null,
    hasAttachments: message.hasAttachments,
    attachmentCount: storedAttachments > message.attachments.length
        ? storedAttachments
        : message.attachments.length,
    subjectPresent: message.subject?.isNotEmpty ?? false,
    expressiveSendStyleIdPresent: message.expressiveSendStyleId != null,
    balloonBundleIdPresent: message.balloonBundleId != null,
    payloadDataPresent: message.payloadData != null,
    hasApplePayloadData: message.hasApplePayloadData,
    amkSessionIdPresent: message.amkSessionId != null,
    rowSnapshotSha256: rowSnapshotSha256,
  );
}

/// Plain-structure body check mirroring the live lane: exactly one body
/// whose string equals the text and whose runs cover it with messagePart 0
/// and no attachment, mention, transcript, sticker, effect, or styling.
/// Ordinary structural metadata passes; rich content does not.
bool _hasSinglePlainBody(List<AttributedBody> bodies, String text) {
  if (bodies.length != 1 || bodies.single.string != text) return false;
  final runs = bodies.single.runs;
  if (runs.isEmpty) return false;
  var end = 0;
  for (final run in runs) {
    final attributes = run.attributes;
    if (run.range.length != 2 ||
        run.range.first != end ||
        run.range.last <= 0 ||
        attributes == null ||
        attributes.messagePart != 0 ||
        attributes.attachmentGuid != null ||
        attributes.mention != null ||
        attributes.audioTranscript != null ||
        attributes.stickerData != null ||
        attributes.textEffect != null ||
        attributes.bold == true ||
        attributes.italic == true ||
        attributes.strikethrough == true ||
        attributes.underline == true) {
      return false;
    }
    end += run.range.last;
    if (end > text.length) return false;
  }
  return end == text.length;
}

final _snapshotHex = RegExp(r'^[0-9a-f]{64}$');

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

String _bare(String value) => value.startsWith('mailto:')
    ? value.substring(7)
    : value.startsWith('tel:')
    ? value.substring(4)
    : value;

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

bool _boundedIdentifier(String value) =>
    value.isNotEmpty &&
    value.trim() == value &&
    !value.contains('\u0000') &&
    utf8.encode(value).length <= 4096;

String historicalArchiveScope(
  CloudSyncHistoricalSourceManifest manifest,
  CloudSyncHistoricalAccountBinding account,
) => _digest([
  'cloud-sync-historical-scan-v1',
  manifest.snapshotSha256,
  account.accountFingerprint,
  account.protectedStoreIdentity,
]);

/// Lane-local digest binding the exact immutable row text. Staging
/// recomputes this over freshly read text and rejects any change.
String historicalTextDigest(String text) =>
    _digest(['cloud-sync-historical-archive-text-v1', text]);
