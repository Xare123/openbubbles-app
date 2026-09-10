// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

import 'cloud_operation_identity.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_message_dependency.dart';
import 'cloud_sync_outbound_chat_origin.dart';
import 'cloud_sync_group_send_route.dart';
import 'cloud_sync_reaction_send_identity.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_attachment_send_body.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';

const int cloudSyncIdsConfirmationVersion = 2;

/// Immutable local send identity. Raw routing/content never leaves this
/// capture; the raw GUID is retained in memory only for exact revalidation.
final class CloudSyncLocalSendIdentity {
  const CloudSyncLocalSendIdentity._(
    this._guid,
    this.guidHash,
    this.sourceSha256,
    this._usesProvisionalOrigin, {
    bool isReaction = false,
    bool isAttachment = false,
    CloudSyncGroupSendRoute? groupRoute,
  }) : _isReaction = isReaction,
       _isAttachment = isAttachment,
       _groupRoute = groupRoute;

  final String _guid;
  final String guidHash;
  final String sourceSha256;
  final bool _usesProvisionalOrigin;
  final bool _isReaction;
  final bool _isAttachment;
  bool get isAttachment => _isAttachment;
  final CloudSyncGroupSendRoute? _groupRoute;

  /// Explicit local reaction provenance. Plain-text capture remains unchanged.
  /// Temporary/staging GUIDs are bookkeeping only; saveSubmission separately
  /// requires proof that this invocation created the native GUID.
  static CloudSyncLocalSendIdentity? captureReaction(
    Message message,
    Chat chat,
    String stableGuid, {
    String? expectedSourceSha256,
  }) {
    final reaction = CloudSyncReactionSendIdentity.capture(
      message,
      chat,
      stableGuid,
      expectedSourceSha256: expectedSourceSha256,
      allowSubmissionGuid: true,
    );
    return reaction == null
        ? null
        : CloudSyncLocalSendIdentity._(
            stableGuid,
            reaction.guidHash,
            reaction.sourceSha256,
            false,
            isReaction: true,
          );
  }

  static CloudSyncLocalSendIdentity? captureReactionWire(
    Message message,
    Chat chat,
    api.MessageInst wire, {
    String? expectedSourceSha256,
  }) {
    final reaction = CloudSyncReactionSendIdentity.captureWire(
      message,
      chat,
      wire,
      expectedSourceSha256: expectedSourceSha256,
      allowSubmissionGuid: true,
    );
    return reaction == null
        ? null
        : CloudSyncLocalSendIdentity._(
            wire.id,
            reaction.guidHash,
            reaction.sourceSha256,
            false,
            isReaction: true,
          );
  }

  static CloudSyncLocalSendIdentity? _captureJournaled(
    Message message,
    Chat chat,
    String stableGuid, {
    required String expectedSourceSha256,
  }) =>
      capture(
        message,
        chat,
        stableGuid,
        expectedSourceSha256: expectedSourceSha256,
      ) ??
      captureReaction(
        message,
        chat,
        stableGuid,
        expectedSourceSha256: expectedSourceSha256,
      ) ??
      captureAttachment(
        message,
        chat,
        stableGuid,
        expectedSourceSha256: expectedSourceSha256,
      );

  CloudSyncLocalSendIdentity? _revalidate(Message message, Chat chat) =>
      _isReaction
      ? captureReaction(
          message,
          chat,
          _guid,
          expectedSourceSha256: sourceSha256,
        )
      : _isAttachment
      ? captureAttachment(
          message,
          chat,
          _guid,
          expectedSourceSha256: sourceSha256,
        )
      : capture(message, chat, _guid, expectedSourceSha256: sourceSha256);

  /// Explicit attachment origin, independent of local display GUIDs. This is
  /// not enabled merely because the ordinary plaintext capture was attempted.
  static CloudSyncLocalSendIdentity? captureAttachment(
    Message message,
    Chat chat,
    String stableGuid, {
    String? expectedSourceSha256,
  }) {
    final body = CloudSyncAttachmentSendBody.capture(message);
    if (body == null) return null;
    return _capture(
      message,
      chat,
      stableGuid,
      expectedSourceSha256: expectedSourceSha256,
      attachmentBody: body,
    );
  }

  static CloudSyncLocalSendIdentity? capture(
    Message message,
    Chat chat,
    String stableGuid, {
    String? expectedSourceSha256,
  }) => _capture(
    message,
    chat,
    stableGuid,
    expectedSourceSha256: expectedSourceSha256,
  );

  static CloudSyncLocalSendIdentity? _capture(
    Message message,
    Chat chat,
    String stableGuid, {
    String? expectedSourceSha256,
    CloudSyncAttachmentSendBody? attachmentBody,
  }) {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(stableGuid)) {
      return null;
    }
    if (message.isFromMe != true ||
        message.ckRecordId != null ||
        message.ckSyncState == true ||
        message.temp ||
        message.hasBeenForwarded ||
        message.verificationFailed ||
        message.dateCreated == null ||
        message.dateScheduled != null ||
        message.dateDeleted != null ||
        message.dateEdited != null ||
        message.subject?.isNotEmpty == true ||
        (attachmentBody == null &&
            (message.hasAttachments ||
                message.attachments.isNotEmpty ||
                message.dbAttachments.isNotEmpty)) ||
        message.messageSummaryInfo.isNotEmpty ||
        message.associatedMessageGuid != null ||
        message.associatedMessagePart != null ||
        message.associatedMessageType != null ||
        message.associatedMessageEmoji != null ||
        message.sendingServiceId != null ||
        message.threadOriginatorGuid != null ||
        message.threadOriginatorPart != null ||
        message.expressiveSendStyleId != null ||
        message.balloonBundleId != null ||
        message.payloadData != null ||
        message.hasApplePayloadData ||
        message.metadata != null ||
        message.amkSessionId != null ||
        (message.itemType ?? 0) != 0 ||
        (message.groupActionType ?? 0) != 0 ||
        message.groupTitle != null) {
      return null;
    }
    final text = attachmentBody?.sourceSha256 ?? message.text;
    if (attachmentBody == null &&
        (text == null ||
            text.trim().isEmpty ||
            message.attributedBody.length != 1)) {
      return null;
    }
    if (text == null) return null;
    var end = attachmentBody == null ? 0 : text.length;
    if (attachmentBody == null) {
      final body = message.attributedBody.single;
      if (body.string != text || body.runs.isEmpty) return null;
      for (final run in body.runs) {
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
          return null;
        }
        end += run.range.last;
        if (end > text.length) return null;
      }
    }
    final group = CloudSyncGroupSendRoute.capture(chat);
    if (group != null) {
      if (end != text.length) return null;
      // Distinct domains keep all existing direct-chat hashes unchanged. The
      // provisional form survives only a proven same-row Chat adoption. Local
      // capture is not upload permission: group encoding/dependency gates are
      // deliberately still required by outbound admission.
      final canonicalHash = _digest([
        attachmentBody == null
            ? 'cloud-sync-local-send-group-v1'
            : 'cloud-sync-local-attachment-group-v1',
        stableGuid,
        text,
        group.chatId,
        group.guid,
        group.identifier,
        group.members,
        group.sender,
      ]);
      final originHash = group.originalGuid == null
          ? null
          : _digest([
              attachmentBody == null
                  ? 'cloud-sync-local-send-group-origin-v1'
                  : 'cloud-sync-local-attachment-group-origin-v1',
              stableGuid,
              text,
              group.chatId,
              group.originalGuid,
              group.members,
              group.sender,
            ]);
      final sourceHash = group.provisional
          ? originHash
          : expectedSourceSha256 != null && expectedSourceSha256 == originHash
          ? originHash
          : canonicalHash;
      if (sourceHash == null ||
          (expectedSourceSha256 != null &&
              expectedSourceSha256 != sourceHash)) {
        return null;
      }
      return CloudSyncLocalSendIdentity._(
        stableGuid,
        _digest(['cloud-sync-local-send-guid-v1', stableGuid]),
        sourceHash,
        sourceHash == originHash,
        isAttachment: attachmentBody != null,
        groupRoute: group,
      );
    }
    final provisional = _uuid.hasMatch(chat.guid);
    if (end != text.length ||
        (chat.style != 45 && !(provisional && chat.style == null)) ||
        chat.isRpSms ||
        chat.isRoutingStub ||
        chat.usingHandle?.isNotEmpty != true) {
      return null;
    }
    final participants = chat.handles.toList(growable: false);
    if (participants.length != 1 || participants.single.service != 'iMessage') {
      return null;
    }
    final recipient = participants.single.address;
    if (recipient.isEmpty ||
        (chat.chatIdentifier != recipient &&
            !(provisional && chat.chatIdentifier == null)) ||
        (!provisional && chat.guid != 'iMessage;-;$recipient') ||
        (provisional &&
            (chat.id == null ||
                chat.id! <= 0 ||
                chat.ckRecordId != null ||
                chat.cloudData != null ||
                (chat.cloudGuid != null && chat.cloudGuid != chat.guid)))) {
      return null;
    }

    // Preserve existing canonical-chat journal hashes byte-for-byte. Only an
    // explicitly captured provisional origin uses v2. Revalidation after
    // canonical adoption must select it with the previously persisted hash,
    // never rewrite the journal to match whatever row happens to exist now.
    final legacyHash = _digest([
      attachmentBody == null
          ? 'cloud-sync-local-send-source-v1'
          : 'cloud-sync-local-attachment-source-v1',
      stableGuid,
      text,
      chat.guid,
      chat.chatIdentifier,
      chat.usingHandle,
    ]);
    final originalChatGuid = provisional ? chat.guid : chat.cloudGuid;
    final originHash =
        chat.id != null &&
            chat.id! > 0 &&
            _compatibleRoutePrefix(chat.usingHandle!) &&
            originalChatGuid != null &&
            _uuid.hasMatch(originalChatGuid)
        ? _digest([
            attachmentBody == null
                ? 'cloud-sync-local-send-source-v2'
                : 'cloud-sync-local-attachment-source-v2',
            stableGuid,
            text,
            chat.id,
            originalChatGuid,
            recipient,
            _bareSender(chat.usingHandle!),
          ])
        : null;
    final sourceHash = provisional
        ? originHash
        : expectedSourceSha256 != null && expectedSourceSha256 == originHash
        ? originHash
        : legacyHash;
    if (sourceHash == null ||
        (expectedSourceSha256 != null && expectedSourceSha256 != sourceHash)) {
      return null;
    }

    // Read/delivery receipts, a reaction to this message and server timestamp
    // normalization do not change the text that this device submitted.
    return CloudSyncLocalSendIdentity._(
      stableGuid,
      _digest(['cloud-sync-local-send-guid-v1', stableGuid]),
      sourceHash,
      sourceHash == originHash,
      isAttachment: attachmentBody != null,
    );
  }

  static String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static String _bareSender(String value) => value.startsWith('mailto:')
      ? value.substring(7)
      : value.startsWith('tel:')
      ? value.substring(4)
      : value;

  static bool _compatibleRoutePrefix(String value) =>
      !value.contains(':') ||
      value.startsWith(value.contains('@') ? 'mailto:' : 'tel:');

  /// Validate the actual IDS payload, not only the mutable local model. Wire
  /// construction and retries can await network work while that model changes.
  /// This is entirely local inspection of Dart fields, with no native calls.
  static CloudSyncLocalSendIdentity? captureWire(
    Message message,
    Chat chat,
    api.MessageInst wire, {
    String? expectedSourceSha256,
  }) {
    final identity = capture(
      message,
      chat,
      wire.id,
      expectedSourceSha256: expectedSourceSha256,
    );
    return _validateWire(message, chat, wire, identity);
  }

  static Future<CloudSyncLocalSendIdentity?> captureAttachmentWire(
    Message message,
    Chat chat,
    api.MessageInst wire, {
    String? expectedSourceSha256,
    required Future<String> Function(api.Attachment) serializeAttachment,
  }) async {
    final body = CloudSyncAttachmentSendBody.capture(message);
    final initial = captureAttachment(
      message,
      chat,
      wire.id,
      expectedSourceSha256: expectedSourceSha256,
    );
    if (body == null ||
        initial == null ||
        !await body.matchesWire(
          wire,
          serializeAttachment: serializeAttachment,
        )) {
      return null;
    }
    // Native serialization awaited above. Recheck the local row and route
    // against the pre-await identity, not the model's possibly newer contents.
    final current = captureAttachment(
      message,
      chat,
      wire.id,
      expectedSourceSha256: initial.sourceSha256,
    );
    return _validateWire(
      message,
      chat,
      wire,
      current,
      attachmentBodyMatched: true,
    );
  }

  static CloudSyncLocalSendIdentity? _validateWire(
    Message message,
    Chat chat,
    api.MessageInst wire,
    CloudSyncLocalSendIdentity? identity, {
    bool attachmentBodyMatched = false,
  }) {
    if (identity == null ||
        wire.verificationFailed ||
        wire.target != null ||
        (identity._groupRoute == null &&
            (identity._usesProvisionalOrigin
                ? wire.sender == null ||
                      !_compatibleRoutePrefix(wire.sender!) ||
                      _bareSender(wire.sender!) !=
                          _bareSender(chat.usingHandle!)
                : wire.sender != chat.usingHandle)) ||
        wire.message is! api.Message_Message) {
      return null;
    }
    final normal = (wire.message as api.Message_Message).field0;
    if (normal.service is! api.MessageType_IMessage ||
        normal.effect != null ||
        normal.replyGuid != null ||
        normal.replyPart != null ||
        normal.subject?.isNotEmpty == true ||
        normal.app != null ||
        normal.linkMeta != null ||
        normal.voice ||
        normal.scheduled != null ||
        normal.parts.field0.isEmpty) {
      return null;
    }
    final text = StringBuffer();
    if (!attachmentBodyMatched) {
      for (final indexed in normal.parts.field0) {
        final part = indexed.part_;
        if (indexed.ext != null ||
            (indexed.idx != null && indexed.idx != 0) ||
            part is! api.MessagePart_Text ||
            part.field1 is! api.TextFormat_Flags) {
          return null;
        }
        final flags = (part.field1 as api.TextFormat_Flags).field0;
        if (flags.bold ||
            flags.italic ||
            flags.underline ||
            flags.strikethrough) {
          return null;
        }
        text.write(part.field0);
      }
    }
    final bodyMatches =
        attachmentBodyMatched || text.toString() == message.text;
    final group = identity._groupRoute;
    if (group != null) {
      return bodyMatches &&
              group.matchesWire(
                wire,
                usesOriginalGuid: identity._usesProvisionalOrigin,
              )
          ? identity
          : null;
    }
    final recipient = chat.handles.single.address;
    final expectedParticipants = [
      '${recipient.contains('@') ? 'mailto' : 'tel'}:$recipient',
      chat.usingHandle!,
    ]..sort();
    final conversation = wire.conversation;
    var actualParticipants = conversation?.participants.toList()?..sort();
    if (identity._usesProvisionalOrigin) {
      if (actualParticipants?.any((value) => !_compatibleRoutePrefix(value)) ==
          true) {
        return null;
      }
      actualParticipants = actualParticipants?.map(_bareSender).toList()
        ?..sort();
      for (var i = 0; i < expectedParticipants.length; i++) {
        expectedParticipants[i] = _bareSender(expectedParticipants[i]);
      }
      expectedParticipants.sort();
    }
    if (!bodyMatches ||
        (conversation?.senderGuid != chat.guid &&
            !(identity._usesProvisionalOrigin &&
                chat.cloudGuid != null &&
                conversation?.senderGuid == chat.cloudGuid)) ||
        jsonEncode(actualParticipants) != jsonEncode(expectedParticipants)) {
      return null;
    }
    return identity;
  }

  /// A UUID from this invocation is necessary but not sufficient: a restored
  /// row can also be re-sent. Only the unsent local temporary-GUID path creates
  /// new origin; stable-GUID retries must already have a durable intent.
  static bool isFreshLocalSubmission(
    Message message, {
    required String generatedGuid,
    required String stableGuid,
  }) =>
      generatedGuid == stableGuid &&
      message.stagingGuid == null &&
      message.dateScheduled == null &&
      message.ckRecordId == null &&
      message.ckSyncState != true &&
      RegExp(r'^temp-[A-Za-z0-9]{8}$').hasMatch(message.guid ?? '');

  @override
  String toString() => 'CloudSyncLocalSendIdentity(redacted)';
}

/// Revalidates native account, client generation and keystore identity before
/// synchronous local persistence. Dart object identity alone is insufficient.
/// This grants no remote mutation capability and performs no network warmup.
final class CloudSyncLocalSendAuthFence {
  const CloudSyncLocalSendAuthFence({
    required CloudSyncNativeAuthSnapshot expected,
    required CloudSyncNativeAuthSnapshotReader capture,
    required bool Function() stillCurrent,
  }) : _expected = expected,
       _capture = capture,
       _stillCurrent = stillCurrent;

  final CloudSyncNativeAuthSnapshot _expected;
  final CloudSyncNativeAuthSnapshotReader _capture;
  final bool Function() _stillCurrent;

  /// Synchronous lifetime check after the native capture in [run]. Never a
  /// substitute for capturing native authentication before an awaited write.
  void requireCurrentBinding(CloudSyncNativeAuthSnapshot expected) {
    if (!_expected.sameIdentity(expected) || !_stillCurrent()) {
      throw StateError('cloud_sync_local_send_identity_changed');
    }
  }

  Future<T> run<T>(T Function() persist, {String? accountFingerprint}) async {
    if (!_stillCurrent() ||
        (accountFingerprint != null &&
            accountFingerprint != _expected.accountFingerprint)) {
      throw StateError('cloud_sync_local_send_identity_changed');
    }
    final current = await _capture();
    if (!_expected.sameIdentity(current) || !_stillCurrent()) {
      throw StateError('cloud_sync_local_send_identity_changed');
    }
    return persist();
  }
}

/// Exact process-local scope for one native receipt replay pass. A receipt page
/// may outlive an await, but it must never outlive the account, client, database
/// or storage directory that authenticated that page.
final class CloudSyncNativeReceiptReplayBinding {
  const CloudSyncNativeReceiptReplayBinding({
    required this.expectedAuth,
    required this.expectedState,
    required this.expectedStore,
    required this.expectedClient,
    required this.expectedStoragePath,
    required this.readState,
    required this.readStore,
    required this.readClient,
    required this.readStoragePath,
    required this.runtimeCurrent,
  });

  final CloudSyncNativeAuthSnapshot expectedAuth;
  final Object expectedState;
  final Object expectedStore;
  final Object expectedClient;
  final String expectedStoragePath;
  final Object? Function() readState;
  final Object? Function() readStore;
  final Object? Function() readClient;
  final String Function() readStoragePath;
  final bool Function() runtimeCurrent;

  bool get isCurrent =>
      runtimeCurrent() &&
      identical(expectedState, readState()) &&
      identical(expectedStore, readStore()) &&
      identical(expectedClient, readClient()) &&
      expectedStoragePath == readStoragePath();

  void requireCurrent() {
    if (!isCurrent) {
      throw StateError('cloud_sync_native_send_replay_binding_changed');
    }
  }

  void requireCapturedAuth(CloudSyncNativeAuthSnapshot current) {
    requireCurrent();
    if (!expectedAuth.sameIdentity(current)) {
      throw StateError('cloud_sync_native_send_replay_binding_changed');
    }
  }
}

final class CloudSyncNativeSendReceiptResolution {
  const CloudSyncNativeSendReceiptResolution._({
    required this.stableGuid,
    required this.alreadyDurable,
  });

  final String? stableGuid;
  final bool alreadyDurable;

  @override
  String toString() => 'CloudSyncNativeSendReceiptResolution(redacted)';
}

/// Local-only journal. It cannot create an outbox row or contact CloudKit.
/// The caller's synchronous persistence callback and this journal share one
/// ObjectBox transaction. The persisted message is re-read before acceptance.
final class CloudSyncLocalSendJournal {
  CloudSyncLocalSendJournal({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot authoritySnapshot,
  }) : _store = store,
       _authority = authority,
       _binding = authoritySnapshot,
       _intents = store.box<CloudSyncLocalSendIntentEntity>(),
       _messages = store.box<Message>() {
    if (!authority.isBoundToStore(store)) {
      throw StateError('cloud_sync_local_send_authority_store_mismatch');
    }
  }

  final Store _store;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterAuthoritySnapshot _binding;
  final Box<CloudSyncLocalSendIntentEntity> _intents;
  final Box<Message> _messages;

  bool isBoundToStore(Store store) => identical(store, _store);

  /// Reconstruct local ownership for read-only queue inspection, not sending.
  static CloudSyncLocalSendJournal? forRetainedQueueInspection(
    Store store,
    String accountFingerprint,
  ) {
    final authority = ObjectBoxCloudKitWriterAuthority(store: store);
    final owner = authority.read(
      CloudKitWriterScope(accountFingerprint: accountFingerprint),
    );
    if (owner == null || owner.owner != CloudKitWriterOwner.v2) return null;
    return CloudSyncLocalSendJournal(
      store: store,
      authority: authority,
      authoritySnapshot: owner,
    );
  }

  /// A retained pre-upgrade origin is not an upload candidate or a receipt.
  /// Only a pristine, never-submitted create may stop blocking unrelated work.
  /// Re-evaluate from the same transaction as the caller's queue snapshot.
  bool isRetainedPreproofPendingCreate(CloudOutboxOperationEntity row) =>
      _store.runInTransaction(TxMode.read, () {
        if (row.state != CloudOutboxStatus.pending.index ||
            row.action != CloudOutboxAction.save.index ||
            row.accountFingerprint != _binding.scope.accountFingerprint ||
            !{'chatManateeZone', 'messageManateeZone'}.contains(row.zone) ||
            row.attemptCount != 0 ||
            row.appleRequestUuid != null ||
            row.appleOperationUuid != null ||
            row.confirmedAtMs != 0 ||
            row.leaseIdHash != null ||
            row.leaseExpiresAtMs != 0 ||
            row.nextEligibleAtMs != 0 ||
            row.lastErrorCategory != null ||
            row.dependencyOperationIdsJson != '[]' ||
            row.checkpointGeneration <= 0 ||
            row.createdAtMs <= 0 ||
            row.updatedAtMs < row.createdAtMs ||
            !RegExp(
              r'^obcs2\.lease\.[0-9a-f]{32}$',
            ).hasMatch(row.protectedLeaseReference ?? '') ||
            !RegExp(
              r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
            ).hasMatch(row.encryptedPayloadRef ?? '') ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(row.payloadSha256 ?? '') ||
            !RegExp(
              r'^[A-Za-z0-9_-]{43}$',
            ).hasMatch(row.serverRecordIdHash ?? '')) {
          return false;
        }
        final scope = CloudSyncScope(
          accountFingerprint: row.accountFingerprint,
          container: _binding.scope.container,
          database: _binding.scope.database,
          zone: row.zone,
          streamKind: CloudSyncStreamKind.messages,
          schemaVersion: cloudSyncSchemaVersion,
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        if (row.scopeKey != cloudSyncPersistentScopeKey(scope)) return false;
        final operation = CloudOutboxOperation(
          scope: scope,
          operationId: row.operationId,
          logicalEntityKeyHash: row.logicalEntityKeyHash,
          action: CloudOutboxAction.save,
          payloadVersion: row.payloadVersion,
          mutationRevision: row.mutationRevision,
          checkpointGeneration: row.checkpointGeneration,
          dependencyOperationIds: const {},
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row.createdAtMs,
            isUtc: true,
          ),
          encryptedPayloadReference: row.encryptedPayloadRef,
          payloadSha256: row.payloadSha256,
          serverRecordIdHash: row.serverRecordIdHash,
        );
        try {
          _verifyLocalOwnership();
          final CloudSyncLocalSendAdmissionSource? source;
          if (scope.zone == 'chatManateeZone') {
            if (!cloudSyncIsNeverSubmittedChatCreate(row)) return false;
            final binding = cloudSyncOutboundChatOriginSendProof(
              row.localChatOrigin!,
            );
            if (binding == null) return false;
            source = _readChatCreateBindingSource(
              _store,
              operation,
              cloudSyncOutboundChatOriginId(row.localChatOrigin!),
              cloudSyncOutboundChatOriginIdentity(row.localChatOrigin!),
              binding,
            );
          } else {
            if (row.localChatOrigin != null) return false;
            source = readAdoptedCreateSource(_store, operation);
          }
          if (source == null || source.idsConfirmationVersion != 0) {
            return false;
          }
          final checkpoint = _readUnique(
            _store.box<CloudSyncCheckpointEntity>().query(
              CloudSyncCheckpointEntity_.checkpointKey.equals(row.scopeKey),
            ),
          );
          final mapping = _readUnique(
            _store.box<CloudRecordMapEntity>().query(
              CloudRecordMapEntity_.scopeKey
                  .equals(row.scopeKey)
                  .and(
                    CloudRecordMapEntity_.logicalEntityKeyHash.equals(
                      row.logicalEntityKeyHash,
                    ),
                  ),
            ),
          );
          return checkpoint != null &&
              checkpoint.accountFingerprint == row.accountFingerprint &&
              checkpoint.container == scope.container &&
              checkpoint.database == scope.database &&
              checkpoint.zone == scope.zone &&
              checkpoint.streamKind == scope.streamKind.name &&
              checkpoint.schemaVersion == scope.schemaVersion &&
              checkpoint.persistenceLane == scope.persistenceLane.name &&
              checkpoint.generation == row.checkpointGeneration &&
              mapping != null &&
              mapping.accountFingerprint == row.accountFingerprint &&
              mapping.zone == row.zone &&
              mapping.generation == row.checkpointGeneration &&
              mapping.serverRecordIdHash == row.serverRecordIdHash &&
              mapping.encryptedServerRecordId == row.encryptedPayloadRef;
        } on StateError {
          // Unrecognized, changed or malformed evidence remains blocking.
          return false;
        } on CloudKitWriterAuthorityFailure {
          return false;
        }
      });

  /// Local routing check only. It grants no admission or writer authority.
  static bool hasPendingComposerAdmission(Store store, Message message) {
    final messageId = message.id;
    final stableGuid = message.stagingGuid;
    if (messageId == null || messageId <= 0 || stableGuid == null) return false;
    final query = store
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.localMessageId
              .equals(messageId)
              .and(CloudSyncLocalSendIntentEntity_.state.equals(0)),
        )
        .build();
    final List<CloudSyncLocalSendIntentEntity> found;
    try {
      found = query.find();
    } finally {
      query.close();
    }
    return found.length == 1 &&
        found.single.messageGuidHash ==
            CloudSyncLocalSendIdentity._digest([
              'cloud-sync-local-send-guid-v1',
              stableGuid,
            ]);
  }

  /// Prevents a retry from replacing an already journaled MMCS descriptor.
  /// Includes confirmed origins: local reflection can fail after IDS succeeds.
  /// This local check grants no send permission or remote confirmation.
  static bool hasJournaledSubmission(Store store, Message message) {
    final messageId = message.id;
    final stableGuid = message.stagingGuid;
    if (messageId == null || messageId <= 0 || stableGuid == null) return false;
    final query = store.box<CloudSyncLocalSendIntentEntity>().query(
      CloudSyncLocalSendIntentEntity_.localMessageId.equals(messageId).and(
        CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
          CloudSyncLocalSendIdentity._digest([
            'cloud-sync-local-send-guid-v1', stableGuid,
          ]),
        ),
      ),
    ).build();
    try {
      return query.count() != 0;
    } finally {
      query.close();
    }
  }

  /// A startup crash sweep must not downgrade a send while durable native IDS
  /// evidence can still arrive or still needs authenticated promotion. This is
  /// a local recovery fence only; it neither confirms the send nor authorizes
  /// a CloudKit write.
  static bool hasUnresolvedNativeConfirmation(Store store, Message message) {
    final messageId = message.id;
    if (messageId == null || messageId <= 0) return false;
    final unresolvedState = CloudSyncLocalSendIntentEntity_.state
        .equals(0)
        .or(CloudSyncLocalSendIntentEntity_.state.equals(3));
    final query =
        store
            .box<CloudSyncLocalSendIntentEntity>()
            .query(
              CloudSyncLocalSendIntentEntity_.localMessageId
                  .equals(messageId)
                  .and(unresolvedState),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst() != null;
    } finally {
      query.close();
    }
  }

  /// Atomically claims only an untracked stale send for legacy failure
  /// normalization. Native receipt replay uses the same Store transaction
  /// boundary, so it cannot confirm between this check and the claim.
  static Message? claimUntrackedCrashedSend(
    Store store,
    int localMessageId,
    String currentServiceId,
  ) => store.runInTransaction(TxMode.write, () {
    final message = store.box<Message>().get(localMessageId);
    if (message == null ||
        message.sendingServiceId == null ||
        message.sendingServiceId == currentServiceId ||
        hasUnresolvedNativeConfirmation(store, message)) {
      return null;
    }
    message.sendingServiceId = null;
    store.box<Message>().put(message);
    return message;
  });

  /// A native callback can finish before the matching send future returns.
  /// Avoid re-saving or downgrading that same immutable, already-confirmed
  /// origin. This is not a way to infer confirmation from a Message row.
  bool isSubmissionAlreadyConfirmed(CloudSyncLocalSendIdentity identity) =>
      _store.runInTransaction(TxMode.read, () {
        _verifyLocalOwnership();
        final key = CloudSyncLocalSendIdentity._digest([
          'cloud-sync-local-send-intent-v1',
          _binding.scope.accountFingerprint,
          identity.guidHash,
        ]);
        final query = _intents
            .query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key))
            .build();
        final CloudSyncLocalSendIntentEntity? found;
        try {
          found = query.findUnique();
        } finally {
          query.close();
        }
        if (found == null) return false;
        final intent = _readBoundIntent(found.id);
        if (intent.messageGuidHash != identity.guidHash ||
            intent.sourceSha256 != identity.sourceSha256) {
          throw StateError('cloud_sync_local_send_source_changed');
        }
        if (intent.idsConfirmationVersion != cloudSyncIdsConfirmationVersion) {
          return false;
        }
        if (intent.state == 1) {
          _validatedMessage(intent);
          return true;
        }
        // _readBoundIntent checked the immutable adoption binding. An adopted
        // source is no longer overwritten from the caller's mutable model.
        return intent.state == 2;
      });

  /// True only for the exact state-0 source already committed by composer
  /// admission. This distinguishes it from legacy post-queue capture.
  bool isComposerSubmissionPending(CloudSyncLocalSendIdentity identity) =>
      _store.runInTransaction(TxMode.read, () {
        _verifyLocalOwnership();
        final key = CloudSyncLocalSendIdentity._digest([
          'cloud-sync-local-send-intent-v1',
          _binding.scope.accountFingerprint,
          identity.guidHash,
        ]);
        final query = _intents
            .query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key))
            .build();
        final CloudSyncLocalSendIntentEntity? found;
        try {
          found = query.findUnique();
        } finally {
          query.close();
        }
        if (found == null) return false;
        final intent = _readBoundIntent(found.id);
        if (intent.state != 0 ||
            intent.messageGuidHash != identity.guidHash ||
            intent.sourceSha256 != identity.sourceSha256) {
          return false;
        }
        final saved = _messages.get(intent.localMessageId);
        final chat = saved?.chat.target;
        final actual = saved == null || chat == null
            ? null
            : identity._revalidate(saved, chat);
        return actual != null &&
            actual.sourceSha256 == identity.sourceSha256 &&
            saved!.stagingGuid == identity._guid;
      });

  /// Resolves a content-free native receipt only against this exact account,
  /// owner epoch and existing journal row. Missing or source-changed rows are
  /// not acknowledged by callers. State 1/2 is already durable and needs no
  /// duplicate state transition; state 0/3 still flows through
  /// [recordNativeSendConfirmation].
  CloudSyncNativeSendReceiptResolution? resolveNativeSendReceipt(
    String guidHash, {
    CloudSyncLocalSendSourceBinding? protectedSource,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyLocalOwnership();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(guidHash)) return null;
    final query = _intents
        .query(
          CloudSyncLocalSendIntentEntity_.accountFingerprint
              .equals(_binding.scope.accountFingerprint)
              .and(
                CloudSyncLocalSendIntentEntity_.writerEpoch.equals(
                  _binding.epoch,
                ),
              )
              .and(
                CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                  guidHash,
                ),
              ),
        )
        .build();
    final CloudSyncLocalSendIntentEntity? found;
    try {
      found = query.findUnique();
    } finally {
      query.close();
    }
    if (found == null) return null;
    final intent = _readBoundIntent(found.id);
    _requireNativeReceiptSource(intent, protectedSource);
    if ((intent.state == 1 || intent.state == 2) &&
        intent.idsConfirmationVersion == cloudSyncIdsConfirmationVersion) {
      if (intent.state == 2) {
        _validatedExactAdoptedMessage(intent);
      } else {
        _validatedMessage(intent);
      }
      return const CloudSyncNativeSendReceiptResolution._(
        stableGuid: null,
        alreadyDurable: true,
      );
    }
    final message = _messages.get(intent.localMessageId);
    final candidates = <String?>[message?.stagingGuid, message?.guid];
    final stableGuid = candidates.whereType<String>().firstWhere(
      (candidate) =>
          CloudSyncLocalSendIdentity._uuid.hasMatch(candidate) &&
          CloudSyncLocalSendIdentity._digest([
                'cloud-sync-local-send-guid-v1',
                candidate,
              ]) ==
              guidHash,
      orElse: () => '',
    );
    if (stableGuid.isEmpty) return null;
    return CloudSyncNativeSendReceiptResolution._(
      stableGuid: stableGuid,
      alreadyDurable: false,
    );
  });

  /// Recover the original fingerprint for a retry under this exact local
  /// account/owner. New submissions still need the pre-await fingerprint;
  /// this read neither invents an intent nor changes its payload or state.
  CloudSyncLocalSendIdentity? captureSubmissionWire({
    required Message message,
    required Chat chat,
    required api.MessageInst wire,
    required String initialSourceSha256,
  }) => _captureSubmissionWire(
    message: message,
    chat: chat,
    wire: wire,
    initialSourceSha256: initialSourceSha256,
    reaction: false,
  );

  CloudSyncLocalSendIdentity? captureReactionSubmissionWire({
    required Message message,
    required Chat chat,
    required api.MessageInst wire,
    required String initialSourceSha256,
  }) => _captureSubmissionWire(
    message: message,
    chat: chat,
    wire: wire,
    initialSourceSha256: initialSourceSha256,
    reaction: true,
  );

  CloudSyncLocalSendIdentity? _captureSubmissionWire({
    required Message message,
    required Chat chat,
    required api.MessageInst wire,
    required String initialSourceSha256,
    required bool reaction,
  }) => _store.runInTransaction(TxMode.read, () {
    final expected = _submissionSource(wire.id, initialSourceSha256);
    if (reaction) {
      return CloudSyncLocalSendIdentity.captureReactionWire(
        message,
        chat,
        wire,
        expectedSourceSha256: expected,
      );
    }
    return CloudSyncLocalSendIdentity.captureWire(
      message,
      chat,
      wire,
      expectedSourceSha256: expected,
    );
  });

  Future<CloudSyncLocalSendIdentity?> captureAttachmentSubmissionWire({
    required Message message,
    required Chat chat,
    required api.MessageInst wire,
    required String initialSourceSha256,
    required Future<String> Function(api.Attachment) serializeAttachment,
  }) async {
    final expected = _submissionSource(wire.id, initialSourceSha256);
    final identity = await CloudSyncLocalSendIdentity.captureAttachmentWire(
      message,
      chat,
      wire,
      expectedSourceSha256: expected,
      serializeAttachment: serializeAttachment,
    );
    // A journal/auth change during descriptor serialization invalidates capture.
    return _submissionSource(wire.id, initialSourceSha256) == expected
        ? identity
        : null;
  }

  String _submissionSource(String stableGuid, String initialSourceSha256) =>
      _store.runInTransaction(TxMode.read, () {
        _verifyLocalOwnership();
        final key = CloudSyncLocalSendIdentity._digest([
          'cloud-sync-local-send-intent-v1',
          _binding.scope.accountFingerprint,
          CloudSyncLocalSendIdentity._digest([
            'cloud-sync-local-send-guid-v1',
            stableGuid,
          ]),
        ]);
        final query = _intents
            .query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key))
            .build();
        final CloudSyncLocalSendIntentEntity? existing;
        try {
          existing = query.findUnique();
        } finally {
          query.close();
        }
        return existing == null
            ? initialSourceSha256
            : _readBoundIntent(existing.id).sourceSha256;
      });

  /// Adopt one already-protected native source before IDS submission. The
  /// caller holds the native protected-store lock across stage/adopt/commit.
  /// An existing binding is immutable, including after IDS confirmation.
  /// Never backfill a descriptor from mutable attachments after sending.
  void adoptProtectedSource({
    required CloudSyncLocalSendIdentity identity,
    required CloudSyncLocalSendSourceBinding source,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _verifyLocalOwnership();
    if (!stillCurrent() || !now.isUtc || now.millisecondsSinceEpoch <= 0) {
      throw StateError('cloud_sync_local_send_identity_changed');
    }
    source.requireOrigin(
      accountFingerprint: _binding.scope.accountFingerprint,
      messageGuidHash: identity.guidHash,
      sourceSha256: identity.sourceSha256,
      protectedStoreIdentity: capturedAuth.protectedStoreIdentity,
    );
    if (capturedAuth.accountFingerprint != source.accountFingerprint) {
      throw StateError('cloud_sync_local_send_auth_changed');
    }
    final key = CloudSyncLocalSendIdentity._digest([
      'cloud-sync-local-send-intent-v1',
      source.accountFingerprint,
      identity.guidHash,
    ]);
    final found = _readUnique(
      _intents.query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key)),
    );
    if (found == null) {
      throw StateError('cloud_sync_local_send_origin_missing');
    }
    final intent = _readBoundIntent(found.id);
    if (intent.sourceSha256 != identity.sourceSha256) {
      throw StateError('cloud_sync_local_send_source_changed');
    }
    final encoded = source.encode();
    if (intent.protectedSourceBinding != null) {
      if (intent.protectedSourceBinding != encoded) {
        throw StateError('cloud_sync_local_send_protected_source_changed');
      }
      return;
    }
    final message = _messages.get(intent.localMessageId);
    final chat = message?.chat.target;
    if (intent.state != 0 ||
        intent.idsConfirmationVersion != 0 ||
        message == null ||
        chat == null ||
        message.stagingGuid != identity._guid ||
        identity._revalidate(message, chat)?.sourceSha256 !=
            identity.sourceSha256) {
      throw StateError('cloud_sync_local_send_protected_source_too_late');
    }
    intent
      ..protectedSourceBinding = encoded
      ..updatedAtMs = now.millisecondsSinceEpoch;
    _intents.put(intent);
  });

  CloudSyncLocalSendSourceBinding? readProtectedSource({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyLocalOwnership();
    final intent = _readBoundIntent(intentId);
    final encoded = intent.protectedSourceBinding;
    if (encoded == null) return null;
    final source = CloudSyncLocalSendSourceBinding.decode(encoded);
    source.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
    );
    return source;
  });

  CloudSyncLocalSendSourceBinding? readSubmissionProtectedSource({
    required CloudSyncLocalSendIdentity identity,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyLocalOwnership();
    final key = CloudSyncLocalSendIdentity._digest([
      'cloud-sync-local-send-intent-v1',
      _binding.scope.accountFingerprint,
      identity.guidHash,
    ]);
    final found = _readUnique(
      _intents.query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key)),
    );
    if (found == null) throw StateError('cloud_sync_local_send_origin_missing');
    final intent = _readBoundIntent(found.id);
    if (intent.sourceSha256 != identity.sourceSha256) {
      throw StateError('cloud_sync_local_send_source_changed');
    }
    return readProtectedSource(intentId: intent.id, currentAuth: currentAuth);
  });

  /// A retry may re-use an existing intent, but cannot invent local origin for
  /// a GUID that predated this journal. Only the fresh IDS GUID path may create.
  void saveSubmission({
    required CloudSyncLocalSendIdentity identity,
    required bool newlyGeneratedGuid,
    required int Function() persistMessage,
    required DateTime now,
  }) => _save(
    identity,
    persistMessage,
    now,
    newlyGeneratedGuid: newlyGeneratedGuid,
    confirmed: false,
  );

  /// Call only after positive IDS participant acceptance is verified. A
  /// completed job alone, failure, or interruption never authorizes upload.
  void saveConfirmedSubmission({
    required CloudSyncLocalSendIdentity identity,
    required int Function() persistMessage,
    required DateTime now,
  }) => _save(
    identity,
    persistMessage,
    now,
    newlyGeneratedGuid: false,
    confirmed: true,
  );

  /// Records positive IDS participant acceptance without awaiting native auth
  /// again. Call only after a v2 native receipt or the strict Windows send and
  /// provide the original captured auth plus a bounded synchronous proof that
  /// its in-memory client/session is still current. State 3 is durable but is
  /// never eligible for admission until [promoteIdsConfirmedDeferred] succeeds.
  int saveIdsConfirmedDeferredSubmission({
    required CloudSyncLocalSendIdentity identity,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required int Function() persistMessage,
    required DateTime now,
    CloudSyncLocalSendSourceBinding? protectedSource,
  }) {
    return _store.runInTransaction(TxMode.write, () {
      if (!stillCurrent()) {
        throw StateError('cloud_sync_local_send_identity_changed');
      }
      if (!now.isUtc || now.millisecondsSinceEpoch <= 0) {
        throw StateError('cloud_sync_local_send_time_invalid');
      }
      if (capturedAuth.accountFingerprint !=
          _binding.scope.accountFingerprint) {
        throw StateError('cloud_sync_local_send_auth_changed');
      }
      final key = CloudSyncLocalSendIdentity._digest([
        'cloud-sync-local-send-intent-v1',
        _binding.scope.accountFingerprint,
        identity.guidHash,
      ]);
      final query = _intents
          .query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key))
          .build();
      final CloudSyncLocalSendIntentEntity? intent;
      try {
        intent = query.findUnique();
      } finally {
        query.close();
      }
      if (intent == null) {
        throw StateError('cloud_sync_local_send_origin_missing');
      }
      if (intent.accountFingerprint != _binding.scope.accountFingerprint ||
          intent.writerEpoch != _binding.epoch ||
          intent.messageGuidHash != identity.guidHash ||
          intent.sourceSha256 != identity.sourceSha256 ||
          (intent.state != 0 && intent.state != 3) ||
          !_hasConsistentAdoption(intent)) {
        throw StateError('cloud_sync_local_send_intent_changed');
      }
      final authBinding = _authBinding(capturedAuth);
      _requireNativeReceiptSource(intent, protectedSource);
      if (identity.isAttachment && protectedSource == null) {
        throw StateError('cloud_sync_local_send_receipt_source_required');
      }
      protectedSource?.requireOrigin(
        accountFingerprint: capturedAuth.accountFingerprint,
        messageGuidHash: identity.guidHash,
        sourceSha256: identity.sourceSha256,
        protectedStoreIdentity: capturedAuth.protectedStoreIdentity,
      );
      if (intent.state == 3 && intent.admittedBindingSha256 != authBinding) {
        throw StateError('cloud_sync_local_send_auth_changed');
      }
      final messageId = persistMessage();
      final saved = messageId > 0 ? _messages.get(messageId) : null;
      final chat = saved?.chat.target;
      final actual = saved == null || chat == null
          ? null
          : identity._revalidate(saved, chat);
      if (actual == null ||
          actual.sourceSha256 != identity.sourceSha256 ||
          saved!.guid != identity._guid ||
          saved.stagingGuid != null) {
        throw StateError('cloud_sync_local_send_source_changed');
      }
      intent
        ..localMessageId = messageId
        ..state = 3
        ..idsConfirmationVersion = cloudSyncIdsConfirmationVersion
        ..admittedBindingSha256 = authBinding
        ..updatedAtMs = now.millisecondsSinceEpoch;
      return _intents.put(intent);
    });
  }

  /// Consume an actual native SendConfirm success, not the early return from
  /// api.send when its background SendJob is still running. No origin is
  /// invented: the exact GUID, account, epoch, row and submitted body must all
  /// match an existing state-0/3 journal entry. Duplicate completed events are
  /// harmless. Persisted state 3 survives restart; native callbacks themselves
  /// currently live only in the bounded in-memory receive retry queue.
  int? recordNativeSendConfirmation({
    required String stableGuid,
    required bool succeeded,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
    CloudSyncLocalSendSourceBinding? protectedSource,
  }) {
    if (!succeeded || !CloudSyncLocalSendIdentity._uuid.hasMatch(stableGuid)) {
      return null;
    }
    return _store.runInTransaction(TxMode.write, () {
      _verifyLocalOwnership();
      final guidHash = CloudSyncLocalSendIdentity._digest([
        'cloud-sync-local-send-guid-v1',
        stableGuid,
      ]);
      final key = CloudSyncLocalSendIdentity._digest([
        'cloud-sync-local-send-intent-v1',
        _binding.scope.accountFingerprint,
        guidHash,
      ]);
      final query = _intents
          .query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key))
          .build();
      final CloudSyncLocalSendIntentEntity? found;
      try {
        found = query.findUnique();
      } finally {
        query.close();
      }
      if (found == null) return null;
      final intent = _readBoundIntent(found.id);
      _requireNativeReceiptSource(intent, protectedSource);
      if (intent.state == 1 || intent.state == 2) {
        if (intent.idsConfirmationVersion != cloudSyncIdsConfirmationVersion) {
          // A fresh v2 receipt may requalify this exact prior intent. Merely
          // reopening or inspecting an older row never changes its proof.
          if (!stillCurrent() ||
              capturedAuth.accountFingerprint != intent.accountFingerprint ||
              !now.isUtc ||
              now.millisecondsSinceEpoch <= 0) {
            throw StateError('cloud_sync_local_send_identity_changed');
          }
          if (intent.state == 2) {
            _validatedExactAdoptedMessage(intent);
          } else {
            _validatedMessage(intent);
          }
          intent
            ..idsConfirmationVersion = cloudSyncIdsConfirmationVersion
            ..updatedAtMs = now.millisecondsSinceEpoch;
          _intents.put(intent);
        }
        return null;
      }
      final message = _messages.get(intent.localMessageId);
      final chat = message?.chat.target;
      if (message == null ||
          chat == null ||
          (message.guid != stableGuid && message.stagingGuid != stableGuid)) {
        throw StateError('cloud_sync_local_send_source_changed');
      }
      // These are transport bookkeeping, normalized only after explicit native
      // success. All content/routing eligibility checks remain unchanged.
      message
        ..guid = stableGuid
        ..stagingGuid = null
        ..sendingServiceId = null
        ..error = 0;
      final identity = CloudSyncLocalSendIdentity._captureJournaled(
        message,
        chat,
        stableGuid,
        expectedSourceSha256: intent.sourceSha256,
      );
      if (identity == null || identity.guidHash != intent.messageGuidHash) {
        throw StateError('cloud_sync_local_send_source_changed');
      }
      return saveIdsConfirmedDeferredSubmission(
        identity: identity,
        capturedAuth: capturedAuth,
        stillCurrent: stillCurrent,
        persistMessage: () => _messages.put(message),
        now: now,
        protectedSource: protectedSource,
      );
    });
  }

  /// Bounded restart recovery for explicit IDS-confirmed/auth-deferred rows.
  /// Awaiting-IDS state 0 is intentionally excluded and cannot be inferred
  /// from the current Message or a stable GUID.
  List<CloudSyncLocalSendIntentEntity> readIdsConfirmedDeferred({
    required CloudSyncNativeAuthSnapshot currentAuth,
    int limit = 50,
  }) {
    if (limit < 1 || limit > 50) {
      throw ArgumentError('cloud_sync_local_send_limit_invalid');
    }
    if (currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_local_send_auth_changed');
    }
    return _store.runInTransaction(TxMode.read, () {
      final query =
          _intents
              .query(
                CloudSyncLocalSendIntentEntity_.accountFingerprint
                    .equals(_binding.scope.accountFingerprint)
                    .and(
                      CloudSyncLocalSendIntentEntity_.writerEpoch.equals(
                        _binding.epoch,
                      ),
                    )
                    .and(CloudSyncLocalSendIntentEntity_.state.equals(3))
                    .and(
                      CloudSyncLocalSendIntentEntity_.idsConfirmationVersion
                          .equals(cloudSyncIdsConfirmationVersion),
                    )
                    .and(
                      CloudSyncLocalSendIntentEntity_.admittedBindingSha256
                          .equals(_authBinding(currentAuth)),
                    ),
              )
              .order(CloudSyncLocalSendIntentEntity_.updatedAtMs)
              .order(CloudSyncLocalSendIntentEntity_.id)
              .build()
            ..limit = limit;
      try {
        return query.find();
      } finally {
        query.close();
      }
    });
  }

  /// Promotes only explicit state-3 IDS evidence. The persisted auth binding,
  /// active V2 owner and exact writer epoch must all still match. A new process
  /// may recover this durable evidence; the native client generation is only
  /// an in-flight fence, not a persistent identity. No Message field or GUID
  /// is consulted as evidence that IDS succeeded.
  void promoteIdsConfirmedDeferred({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required DateTime now,
  }) {
    _store.runInTransaction(TxMode.write, () {
      if (!now.isUtc || now.millisecondsSinceEpoch <= 0) {
        throw StateError('cloud_sync_local_send_time_invalid');
      }
      _verifyLocalOwnership();
      final permit = _authority.issuePermit(
        _binding.scope,
        expectedOwner: CloudKitWriterOwner.v2,
      );
      if (permit.epoch != _binding.epoch) {
        throw StateError('cloud_sync_local_send_owner_changed');
      }
      final intent = _readBoundIntent(intentId);
      if (intent.state != 3) {
        throw StateError('cloud_sync_local_send_not_deferred');
      }
      _requireIdsConfirmation(intent);
      if (currentAuth.accountFingerprint != intent.accountFingerprint ||
          intent.admittedBindingSha256 != _authBinding(currentAuth)) {
        throw StateError('cloud_sync_local_send_auth_changed');
      }
      intent
        ..state = 1
        ..admittedBindingSha256 = null
        ..updatedAtMs = now.millisecondsSinceEpoch;
      _intents.put(intent);
    });
  }

  void _save(
    CloudSyncLocalSendIdentity identity,
    int Function() persistMessage,
    DateTime now, {
    required bool newlyGeneratedGuid,
    required bool confirmed,
  }) {
    _store.runInTransaction(TxMode.write, () {
      _verifyLocalOwnership();
      if (!now.isUtc || now.millisecondsSinceEpoch <= 0) {
        throw StateError('cloud_sync_local_send_time_invalid');
      }
      final key = CloudSyncLocalSendIdentity._digest([
        'cloud-sync-local-send-intent-v1',
        _binding.scope.accountFingerprint,
        identity.guidHash,
      ]);
      final query = _intents
          .query(CloudSyncLocalSendIntentEntity_.intentKey.equals(key))
          .build();
      final CloudSyncLocalSendIntentEntity? previous;
      try {
        previous = query.findUnique();
      } finally {
        query.close();
      }
      if (previous == null && (!newlyGeneratedGuid || confirmed)) {
        throw StateError('cloud_sync_local_send_origin_missing');
      }
      if (confirmed &&
          (identity.isAttachment || previous?.protectedSourceBinding != null)) {
        throw StateError('cloud_sync_local_send_receipt_source_required');
      }
      if (previous != null &&
          (previous.accountFingerprint != _binding.scope.accountFingerprint ||
              previous.writerEpoch != _binding.epoch ||
              previous.messageGuidHash != identity.guidHash ||
              previous.sourceSha256 != identity.sourceSha256 ||
              previous.state < 0 ||
              previous.state > 3 ||
              !_hasConsistentAdoption(previous))) {
        throw StateError('cloud_sync_local_send_intent_changed');
      }
      final messageId = persistMessage();
      final saved = messageId > 0 ? _messages.get(messageId) : null;
      final chat = saved?.chat.target;
      final actual = saved == null || chat == null
          ? null
          : identity._revalidate(saved, chat);
      if (actual == null ||
          actual.sourceSha256 != identity.sourceSha256 ||
          (confirmed
              ? saved!.guid != identity._guid || saved.stagingGuid != null
              : saved!.stagingGuid != identity._guid)) {
        throw StateError('cloud_sync_local_send_source_changed');
      }
      final intent =
          previous ??
          CloudSyncLocalSendIntentEntity(
            intentKey: key,
            accountFingerprint: _binding.scope.accountFingerprint,
            writerEpoch: _binding.epoch,
            localMessageId: messageId,
            messageGuidHash: identity.guidHash,
            sourceSha256: identity.sourceSha256,
            createdAtMs: now.millisecondsSinceEpoch,
            updatedAtMs: now.millisecondsSinceEpoch,
          );
      intent.localMessageId = messageId;
      if (confirmed && intent.state == 0) {
        intent
          ..state = 1
          ..idsConfirmationVersion = cloudSyncIdsConfirmationVersion;
      }
      intent.updatedAtMs = now.millisecondsSinceEpoch;
      _intents.put(intent);
    });
  }

  List<CloudSyncLocalSendIntentEntity> readReady({int limit = 50}) {
    if (limit < 1 || limit > 50) {
      throw ArgumentError('cloud_sync_local_send_limit_invalid');
    }
    return _store.runInTransaction(TxMode.read, () {
      _verifyLocalOwnership();
      final query =
          _intents
              .query(
                CloudSyncLocalSendIntentEntity_.accountFingerprint
                    .equals(_binding.scope.accountFingerprint)
                    .and(
                      CloudSyncLocalSendIntentEntity_.writerEpoch.equals(
                        _binding.epoch,
                      ),
                    )
                    .and(CloudSyncLocalSendIntentEntity_.state.equals(1))
                    .and(
                      CloudSyncLocalSendIntentEntity_.idsConfirmationVersion
                          .equals(cloudSyncIdsConfirmationVersion),
                    ),
              )
              .order(CloudSyncLocalSendIntentEntity_.updatedAtMs)
              .order(CloudSyncLocalSendIntentEntity_.id)
              .build()
            ..limit = limit;
      try {
        return query.find();
      } finally {
        query.close();
      }
    });
  }

  /// Reconstruct only from an existing journaled origin, never by scanning
  /// Message.isFromMe. An adopted intent does not need its mutable message
  /// anymore: the outbox's original protected envelope is authoritative.
  CloudSyncLocalSendAdmissionSource readForAdmission(int intentId) =>
      _store.runInTransaction(TxMode.read, () {
        _verifyLocalOwnership();
        final intent = _readBoundIntent(intentId);
        if (intent.state != 1 && intent.state != 2) {
          throw StateError('cloud_sync_local_send_not_ready');
        }
        if (intent.state == 1) _requireIdsConfirmation(intent);
        final message = intent.state == 1 ? _validatedMessage(intent) : null;
        return CloudSyncLocalSendAdmissionSource._(intent, message);
      });

  /// Explicit diagnostic selection is stricter than ordinary recovery: keep
  /// checking the caller's source and recipient even after envelope adoption.
  /// This is an exact primary-key read, including auth-deferred IDS success;
  /// it neither scans candidates nor promotes any journal entry.
  CloudSyncLocalSendAdmissionSource readExactIntent({
    required int intentId,
    required String expectedRecipient,
    required String expectedSourceSha256,
  }) => _store.runInTransaction(TxMode.read, () {
    final intent = _readBoundExactIntent(
      intentId: intentId,
      expectedSourceSha256: expectedSourceSha256,
    );
    if (expectedRecipient.isEmpty) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    final message = intent.state == 2
        ? _validatedExactAdoptedMessage(intent)
        : _validatedMessage(intent);
    // Never let List.single leak a Range/State error for a group row: a
    // non-direct route and any handle arity mismatch both report the fixed
    // selection code.
    final chat = message.chat.target!;
    if (CloudSyncGroupSendRoute.capture(chat) != null) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    final handles = chat.handles.toList(growable: false);
    if (handles.length != 1 || handles.first.address != expectedRecipient) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    return CloudSyncLocalSendAdmissionSource._(intent, message);
  });

  /// Bounded exact selection for a restored non-provisional group row. The
  /// caller replays the full expected binding (chat GUID, sender and member
  /// set) alongside the independent immutable source hash. This neither
  /// scans candidates nor relaxes the protected CloudKit group binding, and
  /// it never promotes any journal entry.
  CloudSyncLocalSendAdmissionSource readExactGroupIntent({
    required int intentId,
    required String expectedChatGuid,
    required List<String> expectedMembers,
    required String expectedSender,
    required String expectedSourceSha256,
  }) => _store.runInTransaction(TxMode.read, () {
    if (expectedChatGuid.isEmpty ||
        expectedSender.isEmpty ||
        expectedMembers.isEmpty ||
        expectedMembers.any((member) => member.isEmpty)) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    final wanted = <String>{};
    for (final member in expectedMembers) {
      if (!wanted.add(member) || member == expectedSender) {
        throw StateError('cloud_sync_local_send_selection_changed');
      }
    }
    final intent = _readBoundExactIntent(
      intentId: intentId,
      expectedSourceSha256: expectedSourceSha256,
    );
    final message = intent.state == 2
        ? _validatedExactAdoptedMessage(intent)
        : _validatedMessage(intent);
    final route = CloudSyncGroupSendRoute.capture(message.chat.target!);
    if (route == null ||
        route.provisional ||
        route.guid != expectedChatGuid ||
        route.sender != expectedSender ||
        route.members.length != wanted.length) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    for (final member in route.members) {
      if (!wanted.contains(member)) {
        throw StateError('cloud_sync_local_send_selection_changed');
      }
    }
    return CloudSyncLocalSendAdmissionSource._(intent, message);
  });

  /// Shared ownership/source/state gate for exact diagnostic selection.
  /// Selectable states are 1-3; state is never changed here.
  CloudSyncLocalSendIntentEntity _readBoundExactIntent({
    required int intentId,
    required String expectedSourceSha256,
  }) {
    _verifyLocalOwnership();
    final intent = _readBoundIntent(intentId);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSourceSha256) ||
        intent.sourceSha256 != expectedSourceSha256 ||
        (intent.state != 1 && intent.state != 2 && intent.state != 3)) {
      throw StateError('cloud_sync_local_send_selection_changed');
    }
    return intent;
  }

  /// Durable round-robin selection, without changing immutable origin or
  /// adopting an upload. Blocked rows stay ready and can be retried after a
  /// pull repairs their dependency; they cannot monopolize a bounded worker.
  void markAdmissionConsidered(int intentId, {required DateTime now}) =>
      _store.runInTransaction(TxMode.write, () {
        _verifyLocalOwnership();
        if (!now.isUtc || now.millisecondsSinceEpoch <= 0) {
          throw StateError('cloud_sync_local_send_time_invalid');
        }
        final intent = _readBoundIntent(intentId);
        if (intent.state != 1) {
          throw StateError('cloud_sync_local_send_not_ready');
        }
        final observed = now.millisecondsSinceEpoch;
        intent.updatedAtMs = observed > intent.updatedAtMs
            ? observed
            : intent.updatedAtMs + 1;
        _intents.put(intent);
      });

  /// A fresh-create scheduling exception needs both durable origin and a
  /// currently stable V2 owner. Journaling itself intentionally needs less:
  /// an earlier unknown write must not prevent recording a new IDS send.
  Message validateReadyForCreate(
    Store transactionStore,
    CloudSyncScope scope,
    CloudSyncLocalSendAdmissionSource expected, {
    bool adopting = false,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCreateAuthority(transactionStore, scope);
    final intent = _readBoundIntent(expected.intentId);
    if (intent.state != 1 || !expected._matches(intent)) {
      throw StateError(
        adopting
            ? 'cloud_sync_local_send_adoption_changed'
            : 'cloud_sync_local_send_not_ready',
      );
    }
    _requireIdsConfirmation(intent);
    return _validatedMessage(intent);
  });

  /// Only new submission needs current IDS proof. Reading an old adopted
  /// envelope and reconciling a possibly completed remote write remain legal;
  /// otherwise an upgrade would strand ambiguity or invite blind resending.
  void requireIdsConfirmationForDispatch(
    CloudSyncLocalSendAdmissionSource expected,
  ) => _store.runInTransaction(TxMode.read, () {
    _verifyLocalOwnership();
    final intent = _readBoundIntent(expected.intentId);
    if (!expected._matches(intent)) {
      throw StateError('cloud_sync_local_send_adoption_changed');
    }
    _requireIdsConfirmation(intent);
  });

  static void _requireIdsConfirmation(CloudSyncLocalSendIntentEntity intent) {
    if (intent.idsConfirmationVersion != cloudSyncIdsConfirmationVersion) {
      throw StateError('cloud_sync_local_send_ids_proof_required');
    }
  }

  /// Resolve explicit adoption, never origin inferred from an outgoing row.
  /// The immutable envelope binding survives restart and receipt transitions.
  /// No match means the ordinary, fully-projected writer gate still applies.
  CloudSyncLocalSendAdmissionSource? readAdoptedCreateSource(
    Store transactionStore,
    CloudOutboxOperation operation,
  ) => _store.runInTransaction(TxMode.read, () {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    final query = _intents
        .query(
          CloudSyncLocalSendIntentEntity_.admittedOperationId.equals(
            operation.operationId,
          ),
        )
        .build();
    final CloudSyncLocalSendIntentEntity? intent;
    try {
      intent = query.findUnique();
    } finally {
      query.close();
    }
    if (intent == null) return null;
    _requireCreateAuthority(transactionStore, operation.scope);
    final source = CloudSyncLocalSendAdmissionSource._(intent, null);
    validateAdoptedOperation(transactionStore, source, operation);
    if (operation.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: operation.scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              payloadVersion: operation.payloadVersion,
            ) ||
        operation.dependencyOperationIds.isNotEmpty) {
      throw StateError('cloud_sync_local_send_adopted_operation_missing');
    }
    return source;
  });

  /// A Chat dependency does not consume the Message's adoption slot. It must
  /// still be justified by the exact native-confirmed, not-yet-adopted send.
  void validateChatCreateSource(
    Store transactionStore,
    CloudSyncScope chatScope,
    int chatId,
    CloudSyncLocalSendAdmissionSource source,
  ) {
    final message = validateReadyForCreate(
      transactionStore,
      _messageScopeForChatCreate(chatScope),
      source,
    );
    if (message.chat.targetId != chatId) {
      throw StateError('cloud_sync_local_send_chat_changed');
    }
  }

  CloudSyncScope _messageScopeForChatCreate(CloudSyncScope chatScope) {
    if (chatScope.zone != 'chatManateeZone') {
      throw StateError('cloud_sync_local_send_scope_invalid');
    }
    return CloudSyncScope(
      accountFingerprint: chatScope.accountFingerprint,
      container: chatScope.container,
      database: chatScope.database,
      zone: 'messageManateeZone',
      streamKind: chatScope.streamKind,
      schemaVersion: chatScope.schemaVersion,
      persistenceLane: chatScope.persistenceLane,
    );
  }

  /// Persisted alongside the Chat origin in the same admission transaction.
  /// Only hashes/row IDs cross this boundary; the immutable envelope, source,
  /// writer epoch and Chat identity are all bound. No journal state is changed.
  String bindChatCreateSource(
    Store transactionStore,
    CloudOutboxOperation operation,
    int chatId,
    String originIdentity,
    CloudSyncLocalSendAdmissionSource source,
  ) {
    validateChatCreateSource(transactionStore, operation.scope, chatId, source);
    return _chatCreateBinding(operation, chatId, originIdentity, source);
  }

  String _chatCreateBinding(
    CloudOutboxOperation operation,
    int chatId,
    String originIdentity,
    CloudSyncLocalSendAdmissionSource source,
  ) => jsonEncode([
    1,
    source.intentId,
    CloudSyncLocalSendIdentity._digest([
      'cloud-sync-local-send-chat-create-v1',
      source.intentKey,
      source.localMessageId,
      source.accountFingerprint,
      source.writerEpoch,
      source.messageGuidHash,
      source.sourceSha256,
      source.createdAtUtc.millisecondsSinceEpoch,
      chatId,
      originIdentity,
      _operationBinding(operation),
    ]),
  ]);

  /// Re-read after restart and again immediately before submission. A callback
  /// or an outgoing Message row alone is never a durable create capability.
  void validateChatCreateBinding(
    Store transactionStore,
    CloudOutboxOperation operation,
    int chatId,
    String originIdentity,
    String binding,
  ) {
    final source = _readChatCreateBindingSource(
      transactionStore,
      operation,
      chatId,
      originIdentity,
      binding,
    );
    validateChatCreateSource(transactionStore, operation.scope, chatId, source);
  }

  /// Explicit source retirement is not an unknown validation error. This only
  /// recognizes a deleted/missing/edited Message after verifying the immutable
  /// journal/envelope binding and current owner. The caller must independently
  /// prove that the Chat has never crossed the submission boundary.
  bool hasRetiredChatCreateSource(
    Store transactionStore,
    CloudOutboxOperation operation,
    int chatId,
    String originIdentity,
    String binding,
  ) {
    final source = _readChatCreateBindingSource(
      transactionStore,
      operation,
      chatId,
      originIdentity,
      binding,
    );
    final message = _messages.get(source.localMessageId);
    return message == null ||
        message.dateDeleted != null ||
        message.dateEdited != null;
  }

  CloudSyncLocalSendAdmissionSource _readChatCreateBindingSource(
    Store transactionStore,
    CloudOutboxOperation operation,
    int chatId,
    String originIdentity,
    String binding,
  ) {
    _requireCreateAuthority(
      transactionStore,
      _messageScopeForChatCreate(operation.scope),
    );
    Never reject() =>
        throw StateError('cloud_sync_local_send_chat_binding_changed');
    if (binding.length > 256) reject();
    final dynamic value;
    try {
      value = jsonDecode(binding);
    } on FormatException {
      reject();
    }
    if (value is! List ||
        value.length != 3 ||
        value[0] != 1 ||
        value[1] is! int ||
        value[1] <= 0 ||
        value[2] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value[2])) {
      reject();
    }
    final intent = _readBoundIntent(value[1] as int);
    final source = CloudSyncLocalSendAdmissionSource._(intent, null);
    if (intent.state != 1 ||
        _chatCreateBinding(operation, chatId, originIdentity, source) !=
            binding) {
      reject();
    }
    return source;
  }

  void _requireCreateAuthority(Store transactionStore, CloudSyncScope scope) {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    if (scope.accountFingerprint != _binding.scope.accountFingerprint ||
        scope.container != _binding.scope.container ||
        scope.database != _binding.scope.database ||
        scope.zone != 'messageManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != cloudSyncSchemaVersion ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw StateError('cloud_sync_local_send_scope_invalid');
    }
    _verifyLocalOwnership();
    final permit = _authority.issuePermit(
      _binding.scope,
      expectedOwner: CloudKitWriterOwner.v2,
    );
    if (permit.epoch != _binding.epoch) {
      throw StateError('cloud_sync_local_send_owner_changed');
    }
  }

  /// Called synchronously inside this exact Store's outbox write transaction.
  /// Throwing rejects both adoption and the journal transition together.
  void adoptInOutboxTransaction(
    Store transactionStore,
    CloudSyncLocalSendAdmissionSource expected,
    CloudOutboxOperation operation,
  ) {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    _verifyLocalOwnership();
    final intent = _readBoundIntent(expected.intentId);
    if (!expected._matches(intent) ||
        intent.state != 1 ||
        operation.scope.accountFingerprint != intent.accountFingerprint ||
        operation.scope.container != _binding.scope.container ||
        operation.scope.database != _binding.scope.database ||
        operation.scope.zone != 'messageManateeZone' ||
        operation.scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        operation.status != CloudOutboxStatus.pending ||
        operation.attemptCount != 0 ||
        operation.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: operation.scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              payloadVersion: operation.payloadVersion,
            ) ||
        operation.createdAt.millisecondsSinceEpoch != intent.createdAtMs) {
      throw StateError('cloud_sync_local_send_adoption_changed');
    }
    _requireIdsConfirmation(intent);
    final chatBinding = requireCloudSyncLocalSendDependencies(
      store: _store,
      messageScope: operation.scope,
      message: _validatedMessage(intent),
      readConfirmedLocalParent: (parent) =>
          readConfirmedParentDependency(_store, operation.scope, parent),
    );
    intent
      ..state = 2
      ..admittedOperationId = operation.operationId
      ..admittedChatBinding = chatBinding
      ..admittedBindingSha256 = _operationBinding(
        operation,
        chatBinding: chatBinding,
        protectedSourceBinding: intent.protectedSourceBinding,
      );
    _intents.put(intent);
  }

  void validateAdoptedOperation(
    Store transactionStore,
    CloudSyncLocalSendAdmissionSource expected,
    CloudOutboxOperation? operation,
  ) => _store.runInTransaction(TxMode.read, () {
    if (!identical(transactionStore, _store)) {
      throw StateError('cloud_sync_local_send_adoption_store_mismatch');
    }
    _verifyLocalOwnership();
    final intent = _readBoundIntent(expected.intentId);
    if (!expected._matches(intent) ||
        intent.state != 2 ||
        operation == null ||
        operation.operationId != intent.admittedOperationId ||
        operation.scope.accountFingerprint != intent.accountFingerprint ||
        operation.scope.container != _binding.scope.container ||
        operation.scope.database != _binding.scope.database ||
        operation.scope.zone != 'messageManateeZone' ||
        operation.scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        intent.admittedBindingSha256 !=
            _operationBinding(
              operation,
              chatBinding: intent.admittedChatBinding,
              protectedSourceBinding: intent.protectedSourceBinding,
            ) ||
        operation.createdAt.millisecondsSinceEpoch != intent.createdAtMs) {
      throw StateError('cloud_sync_local_send_adopted_operation_missing');
    }
  });

  /// Called only from the exact-readback callback inside the Store's receipt
  /// release transaction. Save confirmation and generic cleanup never call
  /// this. The immutable binding remains independently revalidated on use.
  void recordConfirmedReadbackInTransaction(
    Store transactionStore,
    CloudOutboxOperation operation,
  ) {
    final source = readAdoptedCreateSource(transactionStore, operation);
    if (source == null) return;
    if (operation.status != CloudOutboxStatus.confirmed ||
        operation.protectedLeaseReference == null ||
        operation.confirmedAt == null ||
        operation.leaseId != null ||
        operation.leaseExpiresAt != null) {
      throw StateError('cloud_sync_local_send_readback_not_ready');
    }
    final intent = _readBoundIntent(source.intentId);
    intent.confirmedReadbackBindingSha256 = intent.admittedBindingSha256;
    _intents.put(intent);
  }

  /// Durable own-message proof without requiring CloudKit to self-echo a save.
  /// Never infers confirmation from a Message flag or from generic receipt
  /// cleanup. Any inbox observation delegates back to restored-parent proof.
  List<Object>? readConfirmedParentDependency(
    Store transactionStore,
    CloudSyncScope scope,
    Message parent,
  ) {
    _requireCreateAuthority(transactionStore, scope);
    final found = _readUnique(
      _intents.query(
        CloudSyncLocalSendIntentEntity_.accountFingerprint
            .equals(scope.accountFingerprint)
            .and(
              CloudSyncLocalSendIntentEntity_.localMessageId.equals(
                parent.id ?? 0,
              ),
            ),
      ),
    );
    if (found == null || found.confirmedReadbackBindingSha256 == null) {
      return null;
    }
    final intent = _readBoundIntent(found.id);
    final row = _readUnique(
      _store.box<CloudOutboxOperationEntity>().query(
        CloudOutboxOperationEntity_.operationId.equals(
          intent.admittedOperationId!,
        ),
      ),
    );
    if (row == null ||
        row.state != CloudOutboxStatus.confirmed.index ||
        row.confirmedAtMs <= 0 ||
        row.protectedLeaseReference != null ||
        row.leaseIdHash != null ||
        row.leaseExpiresAtMs != 0) {
      throw StateError('cloud_sync_local_send_readback_not_ready');
    }
    final scopeKey = cloudSyncPersistentScopeKey(scope);
    final inbox = _store
        .box<CloudInboxChangeEntity>()
        .query(
          CloudInboxChangeEntity_.scopeKey
              .equals(scopeKey)
              .and(
                CloudInboxChangeEntity_.generation.equals(
                  row.checkpointGeneration,
                ),
              )
              .and(
                CloudInboxChangeEntity_.serverRecordIdHash.equals(
                  row.serverRecordIdHash ?? '',
                ),
              ),
        )
        .build();
    try {
      if (inbox.count() != 0) return null;
    } finally {
      inbox.close();
    }
    // A parent is a standalone message, never another reaction. Check the
    // original direct-Chat binding before validating it to prevent recursion
    // through a corrupted parent dependency. Existing v1 bindings are unchanged.
    final dynamic chatBinding = jsonDecode(
      intent.admittedChatBinding ?? 'null',
    );
    if (chatBinding is! List ||
        chatBinding.length != 9 ||
        chatBinding[0] != 1) {
      throw StateError('cloud_sync_local_send_parent_not_ready');
    }
    final validated = _validatedExactAdoptedMessage(intent);
    if (validated.id != parent.id ||
        validated.guid != parent.guid ||
        validated.associatedMessageGuid != null ||
        validated.associatedMessageType != null) {
      throw StateError('cloud_sync_local_send_parent_not_ready');
    }
    final generation = row.checkpointGeneration;
    return <Object>[
      2,
      scopeKey,
      generation,
      validated.id!,
      CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
        scope: scope,
        generation: generation,
        canonicalGuid: validated.guid!,
      ),
      CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: row.logicalEntityKeyHash,
        canonicalGuid: validated.guid!,
      ),
      row.logicalEntityKeyHash,
      row.serverRecordIdHash!,
      intent.id,
      intent.confirmedReadbackBindingSha256!,
    ];
  }

  CloudSyncLocalSendIntentEntity _readBoundIntent(int intentId) {
    final intent = intentId > 0 ? _intents.get(intentId) : null;
    if (intent == null ||
        intent.accountFingerprint != _binding.scope.accountFingerprint ||
        intent.writerEpoch != _binding.epoch ||
        intent.state < 0 ||
        intent.state > 3 ||
        !_hasConsistentAdoption(intent) ||
        intent.intentKey !=
            CloudSyncLocalSendIdentity._digest([
              'cloud-sync-local-send-intent-v1',
              intent.accountFingerprint,
              intent.messageGuidHash,
            ])) {
      throw StateError('cloud_sync_local_send_intent_changed');
    }
    return intent;
  }

  static bool _hasConsistentAdoption(CloudSyncLocalSendIntentEntity intent) {
    // Source-bearing origins require an independently source-bound native
    // receipt before promotion. Shape validation here is not receipt evidence.
    final protectedSource = intent.protectedSourceBinding;
    if (protectedSource != null) {
      try {
        CloudSyncLocalSendSourceBinding.decode(protectedSource).requireOrigin(
          accountFingerprint: intent.accountFingerprint,
          messageGuidHash: intent.messageGuidHash,
          sourceSha256: intent.sourceSha256,
        );
      } on StateError {
        return false;
      }
    }
    if (intent.confirmedReadbackBindingSha256 != null &&
        (intent.state != 2 ||
            intent.confirmedReadbackBindingSha256 !=
                intent.admittedBindingSha256)) {
      return false;
    }
    return intent.state == 2
        ? intent.admittedOperationId != null &&
              RegExp(
                r'^[0-9a-f]{64}$',
              ).hasMatch(intent.admittedBindingSha256 ?? '')
        : intent.state == 3
        ? intent.admittedOperationId == null &&
              RegExp(
                r'^[0-9a-f]{64}$',
              ).hasMatch(intent.admittedBindingSha256 ?? '') &&
              intent.admittedChatBinding == null
        : intent.admittedOperationId == null &&
              intent.admittedBindingSha256 == null &&
              intent.admittedChatBinding == null;
  }

  static String _authBinding(CloudSyncNativeAuthSnapshot auth) =>
      CloudSyncLocalSendIdentity._digest([
        'cloud-sync-local-send-durable-auth-v1',
        auth.accountFingerprint,
        auth.protectedStoreIdentity,
      ]);

  static void _requireNativeReceiptSource(
    CloudSyncLocalSendIntentEntity intent,
    CloudSyncLocalSendSourceBinding? source,
  ) {
    source?.requireOrigin(
      accountFingerprint: intent.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
    );
    if (intent.protectedSourceBinding != source?.encode()) {
      throw StateError('cloud_sync_local_send_receipt_source_changed');
    }
  }

  static String _operationBinding(
    CloudOutboxOperation operation, {
    String? chatBinding,
    String? protectedSourceBinding,
  }) => CloudSyncLocalSendIdentity._digest([
    // Keep old envelopes readable for recovery, but dispatch separately
    // requires the new dependency. Never retrofit proof from Message rows.
    protectedSourceBinding != null
        ? 'cloud-sync-local-send-adoption-v3'
        : chatBinding == null
        ? 'cloud-sync-local-send-adoption-v1'
        : 'cloud-sync-local-send-adoption-v2',
    operation.scope.storageKey, operation.operationId,
    operation.logicalEntityKeyHash, operation.action.name,
    operation.payloadVersion, operation.mutationRevision,
    operation.checkpointGeneration, operation.encryptedPayloadReference,
    operation.payloadSha256, operation.serverRecordIdHash,
    operation.dependencyOperationIds.toList()..sort(),
    operation.createdAt.millisecondsSinceEpoch,
    if (chatBinding != null) chatBinding,
    if (protectedSourceBinding != null) protectedSourceBinding,
    // Lease/receipt/status fields legitimately change on confirmation.
    // Native recovery and submission still validate the live lease itself.
  ]);

  Message _validatedMessage(CloudSyncLocalSendIntentEntity intent) {
    final message = _messages.get(intent.localMessageId);
    return _validateMessageIdentity(intent, message);
  }

  /// State 2 alone is not permission to ignore pre-upload eligibility fields.
  /// First prove the original envelope and Chat ownership. Only then inspect
  /// an unpersisted copy with CloudKit bookkeeping removed. All source-capture
  /// rules still apply, including user edits, routes, attachments and deletion.
  Message _validatedExactAdoptedMessage(CloudSyncLocalSendIntentEntity intent) {
    final scope = CloudSyncScope(
      accountFingerprint: intent.accountFingerprint,
      container: _binding.scope.container,
      database: _binding.scope.database,
      zone: 'messageManateeZone',
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: cloudSyncSchemaVersion,
      persistenceLane: CloudSyncPersistenceLane.semantic,
    );
    final scopeKey = cloudSyncPersistentScopeKey(scope);
    final row = _readUnique(
      _store.box<CloudOutboxOperationEntity>().query(
        CloudOutboxOperationEntity_.operationId.equals(
          intent.admittedOperationId!,
        ),
      ),
    );
    if (row == null ||
        row.scopeKey != scopeKey ||
        row.accountFingerprint != intent.accountFingerprint ||
        row.zone != scope.zone ||
        row.action != CloudOutboxAction.save.index ||
        row.dependencyOperationIdsJson != '[]' ||
        row.localChatOrigin != null ||
        !RegExp(
          r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(row.encryptedPayloadRef ?? '') ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(row.payloadSha256 ?? '') ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43}$',
        ).hasMatch(row.serverRecordIdHash ?? '')) {
      throw StateError('cloud_sync_local_send_adopted_operation_missing');
    }
    // Receipt/status transitions are not source identity. Dispatch continues
    // to validate their live values through the existing store/native guards.
    final operation = CloudOutboxOperation(
      scope: scope,
      operationId: row.operationId,
      logicalEntityKeyHash: row.logicalEntityKeyHash,
      action: CloudOutboxAction.save,
      payloadVersion: row.payloadVersion,
      mutationRevision: row.mutationRevision,
      checkpointGeneration: row.checkpointGeneration,
      dependencyOperationIds: const {},
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.createdAtMs,
        isUtc: true,
      ),
      encryptedPayloadReference: row.encryptedPayloadRef,
      payloadSha256: row.payloadSha256,
      serverRecordIdHash: row.serverRecordIdHash,
    );
    if (operation.operationId !=
        CloudOperationIdentity.forInitialCreate(
          scope: scope,
          logicalEntityKeyHash: operation.logicalEntityKeyHash,
          payloadVersion: operation.payloadVersion,
        )) {
      throw StateError('cloud_sync_local_send_adopted_operation_missing');
    }
    validateAdoptedOperation(
      _store,
      CloudSyncLocalSendAdmissionSource._(intent, null),
      operation,
    );
    final checkpoint = _readUnique(
      _store.box<CloudSyncCheckpointEntity>().query(
        CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey),
      ),
    );
    final mapping = _readUnique(
      _store.box<CloudRecordMapEntity>().query(
        CloudRecordMapEntity_.scopeKey
            .equals(scopeKey)
            .and(
              CloudRecordMapEntity_.logicalEntityKeyHash.equals(
                operation.logicalEntityKeyHash,
              ),
            ),
      ),
    );
    if (checkpoint == null ||
        checkpoint.accountFingerprint != intent.accountFingerprint ||
        checkpoint.generation != operation.checkpointGeneration ||
        mapping == null ||
        mapping.accountFingerprint != intent.accountFingerprint ||
        mapping.zone != scope.zone ||
        mapping.generation != operation.checkpointGeneration ||
        mapping.serverRecordIdHash != operation.serverRecordIdHash ||
        !RegExp(
          r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(mapping.encryptedServerRecordId) ||
        ((row.state != CloudOutboxStatus.confirmed.index ||
                row.protectedLeaseReference != null) &&
            mapping.encryptedServerRecordId !=
                operation.encryptedPayloadReference)) {
      throw StateError('cloud_sync_local_send_adopted_mapping_changed');
    }
    final message = _messages.get(intent.localMessageId);
    if (message == null || intent.admittedChatBinding == null) {
      throw StateError('cloud_sync_local_send_source_changed');
    }
    requireCloudSyncAdoptedLocalSendDependencies(
      store: _store,
      messageScope: scope,
      binding: intent.admittedChatBinding,
      expectedChatId: message.chat.targetId,
      readConfirmedLocalParent: (parent) =>
          readConfirmedParentDependency(_store, scope, parent),
    );
    // ObjectBox reads return independent objects. Do not round-trip toMap:
    // it omits fields that capture must continue rejecting. Never put this view.
    final view = _messages.get(intent.localMessageId)!
      ..ckRecordId = null
      ..ckSyncState = false;
    _validateMessageIdentity(intent, view);
    return message;
  }

  T? _readUnique<T>(QueryBuilder<T> builder) {
    final query = builder.build();
    try {
      return query.findUnique();
    } finally {
      query.close();
    }
  }

  Message _validateMessageIdentity(
    CloudSyncLocalSendIntentEntity intent,
    Message? message,
  ) {
    final chat = message?.chat.target;
    final guid = message?.guid;
    final identity =
        message == null ||
            chat == null ||
            guid == null ||
            message.stagingGuid != null
        ? null
        : CloudSyncLocalSendIdentity._captureJournaled(
            message,
            chat,
            guid,
            expectedSourceSha256: intent.sourceSha256,
          );
    if (identity == null ||
        identity.guidHash != intent.messageGuidHash ||
        identity.sourceSha256 != intent.sourceSha256) {
      throw StateError('cloud_sync_local_send_source_changed');
    }
    return message!;
  }

  void _verifyLocalOwnership() {
    if (_binding.owner != CloudKitWriterOwner.v2 ||
        _binding.epoch <= 0 ||
        _binding.scope.container != 'com.apple.messages.cloud' ||
        _binding.scope.database != 'private') {
      throw StateError('cloud_sync_local_send_owner_invalid');
    }
    final current = _authority.read(_binding.scope);
    if (current == null ||
        current.owner != _binding.owner ||
        current.epoch != _binding.epoch) {
      throw StateError('cloud_sync_local_send_owner_changed');
    }
    // An unresolved earlier remote mutation may fence uploads, but it must
    // not prevent journaling a new local send. This grants no writer permit.
  }
}

/// Immutable admission binding. Only the journal can construct one. The
/// mutable Message is used for first encoding only and re-read at adoption.
final class CloudSyncLocalSendAdmissionSource {
  CloudSyncLocalSendAdmissionSource._(
    CloudSyncLocalSendIntentEntity intent,
    this.message,
  ) : intentId = intent.id,
      intentKey = intent.intentKey,
      localMessageId = intent.localMessageId,
      accountFingerprint = intent.accountFingerprint,
      writerEpoch = intent.writerEpoch,
      sourceSha256 = intent.sourceSha256,
      messageGuidHash = intent.messageGuidHash,
      admittedOperationId = intent.admittedOperationId,
      admittedBindingSha256 = intent.admittedBindingSha256,
      admittedChatBinding = intent.admittedChatBinding,
      protectedSourceBinding = intent.protectedSourceBinding,
      idsConfirmationVersion = intent.idsConfirmationVersion,
      state = intent.state,
      createdAtUtc = DateTime.fromMillisecondsSinceEpoch(
        intent.createdAtMs,
        isUtc: true,
      );

  final int intentId;
  final String intentKey;
  final int localMessageId;
  final String accountFingerprint;
  final int writerEpoch;
  final String sourceSha256;
  final String messageGuidHash;
  final String? admittedOperationId;
  final String? admittedBindingSha256;
  final String? admittedChatBinding;
  final String? protectedSourceBinding;
  final int idsConfirmationVersion;
  final int state;
  final DateTime createdAtUtc;
  final Message? message;

  bool _matches(CloudSyncLocalSendIntentEntity intent) =>
      intentId == intent.id &&
      intentKey == intent.intentKey &&
      localMessageId == intent.localMessageId &&
      accountFingerprint == intent.accountFingerprint &&
      writerEpoch == intent.writerEpoch &&
      sourceSha256 == intent.sourceSha256 &&
      messageGuidHash == intent.messageGuidHash &&
      state == intent.state &&
      admittedOperationId == intent.admittedOperationId &&
      admittedBindingSha256 == intent.admittedBindingSha256 &&
      admittedChatBinding == intent.admittedChatBinding &&
      protectedSourceBinding == intent.protectedSourceBinding &&
      idsConfirmationVersion == intent.idsConfirmationVersion &&
      createdAtUtc.millisecondsSinceEpoch == intent.createdAtMs;

  @override
  String toString() => 'CloudSyncLocalSendAdmissionSource(redacted)';
}
