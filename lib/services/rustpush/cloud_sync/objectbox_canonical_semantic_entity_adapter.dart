import 'package:bluebubbles/database/models.dart';

import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_models.dart';
import 'objectbox_cloud_semantic_store_gateway.dart';

/// Immutable, content-free account and rebootstrap fence supplied by the
/// synchronous Cloud Sync composition layer.
///
/// It deliberately contains an account fingerprint rather than an Apple ID.
/// The provider used by [ObjectBoxCanonicalSemanticEntityAdapter] must read
/// already-loaded process state only. It must not query the network, secure
/// storage, or a Flutter service while an ObjectBox transaction is active.
final class CloudCanonicalActiveScope {
  const CloudCanonicalActiveScope({
    required this.scope,
    required this.generation,
  });

  final CloudSyncScope scope;
  final int generation;
}

/// Synchronous lookup for a verified transient canonical identity.
///
/// Cloud Sync V2 durable metadata stores only keyed hashes. A hash cannot be
/// reversed into a canonical `Chat.guid`, `Message.guid`, or
/// `Attachment.guid`. The future native DTO boundary must therefore retain a
/// short-lived, scope- and generation-bound identity lookup while the decoded
/// mutation is applied. Implementations must not log, serialize, persist, or
/// perform I/O with the returned plaintext GUID.
abstract interface class CloudCanonicalIdentityResolver {
  String? resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  });
}

/// Default-off synchronous adapter for the app's canonical ObjectBox boxes.
///
/// The legacy presentation-only lane can update the non-null display name of
/// an existing, exactly-resolved chat. A separate default-off chat-upsert lane
/// can create or update a chat only from a scope-bound canonical GUID and an
/// exact, conflict-free chat alias. Participant sets are authoritative only on
/// create or a strictly higher group version.
///
/// Independently gated lanes project ordinary messages, reactions, and
/// attachment metadata by exact canonical identity. Stickers, extension
/// payloads that still require decoding, media materialization, profiles,
/// group photos, and tombstones fail closed. The adapter never writes raw
/// CloudKit record IDs, account identifiers, protected references, attachment
/// paths, or media bytes into canonical entities. The only production
/// composition is the separately compile-gated manual semantic pull canary.
final class ObjectBoxCanonicalSemanticEntityAdapter
    implements CloudCanonicalSemanticEntityAdapter {
  ObjectBoxCanonicalSemanticEntityAdapter({
    required this.store,
    required this._activeScopeProvider,
    required this._identityResolver,
    this._semanticApplyEnabled = false,
    this._allowExistingChatPresentationUpdates = false,
    this._allowChatUpserts = false,
    this._allowExistingChatDisplayNameClears = false,
    this._allowMessageUpserts = false,
    this._allowReactionUpserts = false,
    this._allowAttachmentMetadataUpserts = false,
  }) : _chats = store.box<Chat>(),
       _handles = store.box<Handle>(),
       _messages = store.box<Message>(),
       _attachments = store.box<Attachment>();

  @override
  final Store store;
  final CloudCanonicalActiveScope? Function() _activeScopeProvider;
  final CloudCanonicalIdentityResolver _identityResolver;
  final bool _semanticApplyEnabled;
  final bool _allowExistingChatPresentationUpdates;
  final bool _allowChatUpserts;
  final bool _allowExistingChatDisplayNameClears;
  final bool _allowMessageUpserts;
  final bool _allowReactionUpserts;
  final bool _allowAttachmentMetadataUpserts;
  final Box<Chat> _chats;
  final Box<Handle> _handles;
  final Box<Message> _messages;
  final Box<Attachment> _attachments;

  @override
  bool isActiveAccountScope({
    required CloudSyncScope scope,
    required int generation,
  }) => _semanticApplyEnabled && _matchesActiveScope(scope, generation);

  @override
  bool entityExists({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    if (!isActiveAccountScope(scope: scope, generation: generation)) {
      return false;
    }
    final guid = _resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
    );
    if (guid == null) return false;

    return switch (kind) {
      CloudEntityKind.chat => _findChat(guid) != null,
      CloudEntityKind.message ||
      CloudEntityKind.reaction => _findMessage(guid) != null,
      CloudEntityKind.attachment => _findAttachment(guid) != null,
      // Group photos and profiles do not have a canonical primary row whose
      // existence can be safely inferred from the current V2 DTO.
      CloudEntityKind.groupPhoto || CloudEntityKind.sharedProfile => false,
    };
  }

  @override
  CloudCanonicalSemanticMutationReceipt applyEntity({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    _requireActiveScope(scope, generation);
    if (payload.kind != snapshot.kind ||
        payload.logicalEntityKeyHash != snapshot.logicalEntityKeyHash) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'canonical_payload_snapshot_mismatch',
      );
    }

    // There is one deliberately narrow safe mapping. The merge gateway has
    // already decided the incoming snapshot wins; this adapter still refuses
    // chat creation and respects the user's local name lock.
    if (payload case CloudChatEntityPayload()) {
      if (_allowChatUpserts) {
        return _applyChatUpsert(
          scope: scope,
          generation: generation,
          payload: payload,
        );
      }
      return _applyExistingChatPresentation(
        scope: scope,
        generation: generation,
        payload: payload,
      );
    }
    if (payload case CloudMessageEntityPayload()) {
      if (_allowMessageUpserts) {
        return _applyMessageUpsert(
          scope: scope,
          generation: generation,
          payload: payload,
        );
      }
    }
    if (payload case CloudReactionEntityPayload()) {
      if (_allowReactionUpserts) {
        return _applyReactionUpsert(
          scope: scope,
          generation: generation,
          payload: payload,
        );
      }
    }
    if (payload case CloudAttachmentEntityPayload()) {
      if (_allowAttachmentMetadataUpserts) {
        return _applyAttachmentMetadataUpsert(
          scope: scope,
          generation: generation,
          payload: payload,
        );
      }
    }

    throw CloudSyncFailure(
      category: CloudFailureCategory.dependency,
      safeCode: 'canonical_payload_dto_incomplete',
    );
  }

  @override
  CloudCanonicalSemanticMutationReceipt applyTombstone({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticTombstone tombstone,
  }) {
    _requireActiveScope(scope, generation);
    // A tombstone contains a hash, not a proven canonical GUID/alias mapping.
    // Do not infer an entity or turn a server deletion into a broad local wipe.
    throw CloudSyncFailure(
      category: CloudFailureCategory.dependency,
      safeCode: 'canonical_tombstone_dto_incomplete',
    );
  }

  CloudCanonicalSemanticMutationReceipt _applyExistingChatPresentation({
    required CloudSyncScope scope,
    required int generation,
    required CloudChatEntityPayload payload,
  }) {
    if (!_allowExistingChatPresentationUpdates) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_chat_apply_disabled',
      );
    }
    final guid = _resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
    );
    if (guid == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_identity_unavailable',
      );
    }
    if (guid != payload.canonicalGuid) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_identity_mismatch',
      );
    }
    final existing = _findChat(guid);
    if (existing == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_chat_creation_unavailable',
      );
    }

    // The current payload has no presence bitmap, so null means preserve, not
    // clear. Participant, service, group-version, icon, and raw-cloud fields
    // remain untouched because this DTO does not prove their semantics.
    if (payload.displayName != null && !existing.lockChatName) {
      existing.displayName = payload.displayName;
      _chats.put(existing);
    }
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  CloudCanonicalSemanticMutationReceipt _applyChatUpsert({
    required CloudSyncScope scope,
    required int generation,
    required CloudChatEntityPayload payload,
  }) {
    if (payload.service != CloudSemanticService.iMessage ||
        payload.style == null ||
        (payload.groupVersion != null && payload.groupVersion! < 0)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'canonical_chat_shape_invalid',
      );
    }

    final guid = _resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
    );
    if (guid == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_identity_unavailable',
      );
    }
    if (guid != payload.canonicalGuid) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_identity_mismatch',
      );
    }

    final aliasMatch = _findChatByIdentifier(payload.chatIdentifier);
    if (aliasMatch != null && aliasMatch.guid != guid) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_alias_conflict',
      );
    }

    var chat = _findChat(guid);
    final isCreate = chat == null;
    final style = switch (payload.style!) {
      CloudSemanticChatStyle.direct => 45,
      CloudSemanticChatStyle.group => 43,
    };
    if (chat != null && chat.style != null && chat.style != style) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_style_conflict',
      );
    }
    if (!isCreate &&
        payload.displayNameState == CloudSemanticFieldState.explicitClear &&
        !_allowExistingChatDisplayNameClears &&
        !chat.lockChatName) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_chat_display_name_clear_unverified',
      );
    }

    final incomingVersion = switch (payload.groupVersionState) {
      CloudSemanticFieldState.value => payload.groupVersion,
      CloudSemanticFieldState.absent ||
      CloudSemanticFieldState.explicitClear => null,
    };
    final replacesParticipants =
        isCreate ||
        (incomingVersion != null &&
            (chat.groupVersion == null ||
                incomingVersion > chat.groupVersion!));
    final participantHandles = replacesParticipants
        ? _resolveParticipantHandles(payload.participantHandles)
        : const <Handle>[];

    chat ??= Chat(
      guid: guid,
      chatIdentifier: payload.chatIdentifier,
      style: style,
    );
    chat.chatIdentifier = payload.chatIdentifier;
    chat.style = style;

    if (!chat.lockChatName) {
      switch (payload.displayNameState) {
        case CloudSemanticFieldState.absent:
          break;
        case CloudSemanticFieldState.value:
          chat.displayName = payload.displayName;
        case CloudSemanticFieldState.explicitClear:
          chat.displayName = null;
      }
    }

    if (payload.lastAddressedHandleState == CloudSemanticFieldState.value) {
      final normalized = _normalizeHandle(payload.lastAddressedHandle!);
      if (normalized != null) chat.usingHandle = normalized.prefixed;
    }
    if (incomingVersion != null &&
        (chat.groupVersion == null || incomingVersion > chat.groupVersion!)) {
      chat.groupVersion = incomingVersion;
    }

    if (payload.lastSeenMessageGuidState == CloudSemanticFieldState.value) {
      final referenced = _findMessage(payload.lastSeenMessageGuid!);
      if (referenced != null && referenced.chat.targetId == chat.id) {
        chat.lastReadMessageGuid = payload.lastSeenMessageGuid;
      }
    }

    _chats.put(chat);
    if (replacesParticipants) {
      final attached = _chats.get(chat.id!);
      if (attached == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_chat_relation_unavailable',
        );
      }
      attached.handles.clear();
      attached.handles.addAll(participantHandles);
      attached.handles.applyToDb();
    }

    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  List<Handle> _resolveParticipantHandles(Iterable<String> rawHandles) {
    final handles = <Handle>[];
    final seen = <String>{};
    for (final raw in rawHandles) {
      final normalized = _normalizeHandle(raw);
      if (normalized == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.malformedRecord,
          safeCode: 'canonical_chat_participant_invalid',
        );
      }
      final uniqueKey = '${normalized.address}/iMessage';
      if (!seen.add(uniqueKey)) continue;
      var handle = _findHandle(uniqueKey);
      if (handle == null) {
        handle = Handle(
          address: normalized.address,
          service: 'iMessage',
          uniqueAddressAndService: uniqueKey,
        );
        final id = _handles.put(handle);
        handle.id = id;
        handle.originalROWID = id;
        _handles.put(handle);
      } else if (handle.originalROWID == null) {
        handle.originalROWID = handle.id;
        _handles.put(handle);
      }
      handles.add(handle);
    }
    return handles;
  }

  CloudCanonicalSemanticMutationReceipt _applyMessageUpsert({
    required CloudSyncScope scope,
    required int generation,
    required CloudMessageEntityPayload payload,
  }) {
    if (payload.service != CloudSemanticService.iMessage ||
        payload.createdAt == null ||
        payload.knownFlags == null ||
        payload.associationKind != CloudSemanticAssociationKind.none) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_shape_unsupported',
      );
    }
    if (payload.decodedExtensionPayloadState == CloudSemanticFieldState.value) {
      // Extension decoding must happen before the ObjectBox transaction. Do
      // not discard URL-balloon or app payload bytes and still advance replay.
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_extension_decode_required',
      );
    }

    final guid = _requireResolvedGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
      payloadCanonicalGuid: payload.canonicalGuid,
    );
    final chat = _findChatByIdentifier(payload.chatIdentifier);
    if (chat == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_chat_unavailable',
      );
    }

    final flags = payload.knownFlags!;
    final sender = _resolveMessageSender(payload.senderHandle, flags.fromMe);
    var message = _findMessage(guid);
    if (message != null) {
      if (message.chat.targetId != 0 && message.chat.targetId != chat.id) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_message_chat_conflict',
        );
      }
      if (message.isFromMe != null && message.isFromMe != flags.fromMe) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_message_sender_conflict',
        );
      }
      if (message.dateCreated != null &&
          message.dateCreated!.toUtc() != payload.createdAt!.toUtc()) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_message_created_at_conflict',
        );
      }
    }

    message ??= Message(guid: guid, dateCreated: payload.createdAt);
    message.chat.target = chat;
    message.dateCreated ??= payload.createdAt;
    message.isFromMe = flags.fromMe;
    message.handle = sender;
    message.handleId = sender?.originalROWID ?? 0;
    message.error = payload.error ?? message.error;
    message.hasDdResults = flags.hasDataDetectorResults;
    message.wasDeliveredQuietly = flags.deliveredQuietly;
    message.didNotifyRecipient = flags.didNotifyRecipient;

    message.subject = _applyNullableStringField(
      state: payload.subjectState,
      incoming: payload.subject,
      existing: message.subject,
    );
    message.text = _applyNullableStringField(
      state: payload.bodyState,
      incoming: payload.body,
      existing: message.text,
    );
    message.balloonBundleId = _applyNullableStringField(
      state: payload.balloonBundleIdState,
      incoming: payload.balloonBundleId,
      existing: message.balloonBundleId,
    );
    message.expressiveSendStyleId = _applyNullableStringField(
      state: payload.effectState,
      incoming: payload.effect,
      existing: message.expressiveSendStyleId,
    );
    if (payload.decodedExtensionPayloadState ==
        CloudSemanticFieldState.explicitClear) {
      message.payloadData = null;
      message.hasApplePayloadData = false;
    }

    switch (payload.attributedBodiesState) {
      case CloudSemanticFieldState.absent:
        break;
      case CloudSemanticFieldState.value:
        message.attributedBody = _attributedBodies(payload.attributedBodies);
      case CloudSemanticFieldState.explicitClear:
        message.attributedBody = [];
    }
    // Attachment records can arrive before a later replay of their owner.
    // Until attachment tombstones are enabled, a message's confirmed
    // attachment bit is monotonic and must not be cleared merely because one
    // message payload omitted attributed-body attachment runs.
    message.hasAttachments =
        message.hasAttachments ||
        message.attributedBody.any(
          (body) =>
              body.runs.any((run) => run.attributes?.attachmentGuid != null),
        );

    message.dateRead = _maximumDate(
      message.dateRead,
      payload.readAtState == CloudSemanticFieldState.value
          ? payload.readAt
          : null,
    );
    message.dateDelivered = _maximumDate(
      message.dateDelivered,
      payload.deliveredAtState == CloudSemanticFieldState.value
          ? payload.deliveredAt
          : null,
    );
    message.isDelivered = flags.delivered || message.dateDelivered != null;

    if (payload.replyParentCanonicalGuid != null) {
      final replyGuid = _requireResolvedGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: payload.replyParentLogicalKeyHash!,
        payloadCanonicalGuid: payload.replyParentCanonicalGuid!,
      );
      final replyParent = _findMessage(replyGuid);
      if (replyParent == null || replyParent.chat.targetId != chat.id) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_message_reply_parent_unavailable',
        );
      }
      message.threadOriginatorGuid = replyGuid;
      message.threadOriginatorPart = payload.replyParentPart;
    }

    _applyMessageSummary(message, payload);
    _messages.put(message);
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  CloudCanonicalSemanticMutationReceipt _applyReactionUpsert({
    required CloudSyncScope scope,
    required int generation,
    required CloudReactionEntityPayload payload,
  }) {
    if (payload.service != CloudSemanticService.iMessage ||
        payload.createdAt == null ||
        payload.knownFlags == null ||
        !_reactionTypes.contains(payload.reactionType)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_reaction_shape_unsupported',
      );
    }
    final guid = _requireResolvedGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.reaction,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
      payloadCanonicalGuid: payload.canonicalGuid,
    );
    final parentGuid = _requireResolvedGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: payload.parentLogicalKeyHash,
      payloadCanonicalGuid: payload.parentCanonicalGuid,
    );
    final parent = _findMessage(parentGuid);
    final chat = parent?.chat.target;
    if (parent == null || chat == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_reaction_parent_unavailable',
      );
    }

    final flags = payload.knownFlags!;
    final sender = _resolveMessageSender(payload.senderHandle, flags.fromMe);
    var reaction = _findMessage(guid);
    if (reaction != null) {
      if (reaction.associatedMessageGuid != parentGuid ||
          (reaction.chat.targetId != 0 && reaction.chat.targetId != chat.id)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_reaction_parent_conflict',
        );
      }
      if (reaction.isFromMe != null && reaction.isFromMe != flags.fromMe) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_reaction_sender_conflict',
        );
      }
      if (reaction.dateCreated != null &&
          reaction.dateCreated!.toUtc() != payload.createdAt!.toUtc()) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_reaction_created_at_conflict',
        );
      }
    }
    reaction ??= Message(guid: guid, dateCreated: payload.createdAt);
    reaction.chat.target = chat;
    reaction.dateCreated ??= payload.createdAt;
    reaction.isFromMe = flags.fromMe;
    reaction.handle = sender;
    reaction.handleId = sender?.originalROWID ?? 0;
    reaction.error = payload.error ?? reaction.error;
    reaction.associatedMessageGuid = parentGuid;
    reaction.associatedMessagePart = payload.parentPart;
    reaction.associatedMessageType = payload.reactionType;
    reaction.associatedMessageEmoji = payload.associatedEmoji;
    reaction.hasDdResults = flags.hasDataDetectorResults;
    reaction.wasDeliveredQuietly = flags.deliveredQuietly;
    reaction.didNotifyRecipient = flags.didNotifyRecipient;
    reaction.dateRead = _maximumDate(
      reaction.dateRead,
      payload.readAtState == CloudSemanticFieldState.value
          ? payload.readAt
          : null,
    );
    reaction.dateDelivered = _maximumDate(
      reaction.dateDelivered,
      payload.deliveredAtState == CloudSemanticFieldState.value
          ? payload.deliveredAt
          : null,
    );
    reaction.isDelivered = flags.delivered || reaction.dateDelivered != null;
    _messages.put(reaction);

    if (!parent.hasReactions) {
      parent.hasReactions = true;
      _messages.put(parent);
    }
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  CloudCanonicalSemanticMutationReceipt _applyAttachmentMetadataUpsert({
    required CloudSyncScope scope,
    required int generation,
    required CloudAttachmentEntityPayload payload,
  }) {
    final canonicalGuid = _requireResolvedGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
      payloadCanonicalGuid: payload.canonicalGuid,
    );
    final hasOwner = payload.ownerCanonicalGuid != null;
    // Rust has already normalized Apple's `at_<part>_<message>` wire form to
    // the app's canonical `<message>_<part>` form and independently verified
    // the owner hash. Do not parse the normalized value as wire syntax again.
    if (hasOwner &&
        canonicalGuid != '${payload.ownerCanonicalGuid}_${payload.ownerPart}') {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_attachment_owner_conflict',
      );
    }

    Message? owner;
    if (hasOwner) {
      final ownerGuid = _requireResolvedGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: payload.ownerLogicalKeyHash!,
        payloadCanonicalGuid: payload.ownerCanonicalGuid!,
      );
      owner = _findMessage(ownerGuid);
      if (owner == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_attachment_owner_unavailable',
        );
      }
    }

    final localGuid = canonicalGuid;
    var attachment = _findAttachment(localGuid);
    if (attachment != null &&
        attachment.message.targetId != 0 &&
        attachment.message.targetId != owner?.id) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_attachment_relation_conflict',
      );
    }
    attachment ??= Attachment(guid: localGuid);
    if (owner != null) attachment.message.target = owner;
    attachment.uti = _applyNullableStringField(
      state: payload.utiState,
      incoming: payload.uti,
      existing: attachment.uti,
    );
    attachment.transferName = _applyNullableStringField(
      state: payload.fileNameState,
      incoming: payload.fileName,
      existing: attachment.transferName,
    );
    attachment.mimeType = _applyNullableStringField(
      state: payload.mimeTypeState,
      incoming: payload.mimeType,
      existing: attachment.mimeType,
    );
    switch (payload.totalBytesState) {
      case CloudSemanticFieldState.absent:
        break;
      case CloudSemanticFieldState.value:
        if (payload.totalBytes! < 0) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.malformedRecord,
            safeCode: 'canonical_attachment_size_invalid',
          );
        }
        attachment.totalBytes = payload.totalBytes;
      case CloudSemanticFieldState.explicitClear:
        attachment.totalBytes = null;
    }
    switch (payload.isOutgoingState) {
      case CloudSemanticFieldState.absent:
        break;
      case CloudSemanticFieldState.value:
        attachment.isOutgoing = payload.isOutgoing;
      case CloudSemanticFieldState.explicitClear:
        attachment.isOutgoing = null;
    }
    _attachments.put(attachment);
    if (owner != null && !owner.hasAttachments) {
      owner.hasAttachments = true;
      _messages.put(owner);
    }
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  String _requireResolvedGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
    required String payloadCanonicalGuid,
  }) {
    final resolved = _resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
    );
    if (resolved == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_identity_unavailable',
      );
    }
    if (resolved != payloadCanonicalGuid) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_identity_mismatch',
      );
    }
    return resolved;
  }

  Handle? _resolveMessageSender(String raw, bool fromMe) {
    if (raw.isEmpty && fromMe) return null;
    final normalized = _normalizeHandle(raw);
    if (normalized == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'canonical_message_sender_invalid',
      );
    }
    final key = '${normalized.address}/iMessage';
    var handle = _findHandle(key);
    if (handle == null) {
      handle = Handle(
        address: normalized.address,
        service: 'iMessage',
        uniqueAddressAndService: key,
      );
      final id = _handles.put(handle);
      handle.id = id;
      handle.originalROWID = id;
      _handles.put(handle);
    } else if (handle.originalROWID == null) {
      handle.originalROWID = handle.id;
      _handles.put(handle);
    }
    return handle;
  }

  List<AttributedBody> _attributedBodies(
    Iterable<CloudSemanticAttributedBody> bodies,
  ) => bodies
      .map((body) {
        final runs = body.runs
            .map((run) {
              final end = run.startUtf16 + run.lengthUtf16;
              if (end < run.startUtf16 || end > body.text.length) {
                throw CloudSyncFailure(
                  category: CloudFailureCategory.malformedRecord,
                  safeCode: 'canonical_message_text_range_invalid',
                );
              }
              return Run(
                range: [run.startUtf16, run.lengthUtf16],
                attributes: Attributes(
                  messagePart: run.messagePart,
                  attachmentGuid: run.attachmentCanonicalGuid,
                  mention: run.mentionHandle,
                  audioTranscript: run.audioTranscript,
                  textEffect: run.textEffect,
                  bold: run.bold,
                  italic: run.italic,
                  strikethrough: run.strikethrough,
                  underline: run.underline,
                ),
              );
            })
            .toList(growable: false);
        return AttributedBody(string: body.text, runs: runs);
      })
      .toList(growable: false);

  void _applyMessageSummary(
    Message message,
    CloudMessageEntityPayload payload,
  ) {
    if (payload.editsState == CloudSemanticFieldState.absent &&
        payload.retractedPartsState == CloudSemanticFieldState.absent) {
      return;
    }
    final current = message.messageSummaryInfo.isEmpty
        ? MessageSummaryInfo.empty()
        : message.messageSummaryInfo.first;
    if (payload.editsState == CloudSemanticFieldState.explicitClear) {
      current.editedContent = {};
      current.editedParts = [];
      current.originalTextRange = {};
    } else if (payload.editsState == CloudSemanticFieldState.value) {
      final grouped = <String, List<EditedContent>>{};
      final ranges = <String, List<int>>{};
      for (final edit in payload.edits) {
        final key = edit.part.toString();
        grouped
            .putIfAbsent(key, () => [])
            .add(
              EditedContent(
                text: Content(values: _attributedBodies(edit.bodies)),
                date: edit.modifiedAt.millisecondsSinceEpoch.toDouble(),
              ),
            );
        if (edit.originalRangeLocation != null) {
          ranges[key] = [
            edit.originalRangeLocation!,
            edit.originalRangeLength!,
          ];
        }
      }
      current.editedContent = grouped;
      current.editedParts = grouped.keys.map(int.parse).toList()..sort();
      current.originalTextRange = ranges;
    }
    if (payload.retractedPartsState == CloudSemanticFieldState.explicitClear) {
      current.retractedParts = [];
    } else if (payload.retractedPartsState == CloudSemanticFieldState.value) {
      current.retractedParts = payload.retractedParts.toSet().toList()..sort();
    }
    message.messageSummaryInfo = [current];
  }

  String? _applyNullableStringField({
    required CloudSemanticFieldState state,
    required String? incoming,
    required String? existing,
  }) => switch (state) {
    CloudSemanticFieldState.absent => existing,
    CloudSemanticFieldState.value => incoming,
    CloudSemanticFieldState.explicitClear => null,
  };

  DateTime? _maximumDate(DateTime? existing, DateTime? incoming) {
    if (existing == null) return incoming;
    if (incoming == null || !incoming.isAfter(existing)) return existing;
    return incoming;
  }

  _NormalizedCanonicalHandle? _normalizeHandle(String raw) {
    if (raw.isEmpty || raw != raw.trim() || raw.length > 512) return null;
    String address;
    bool email;
    if (raw.startsWith('mailto:')) {
      address = raw.substring('mailto:'.length);
      email = true;
    } else if (raw.startsWith('tel:')) {
      address = raw.substring('tel:'.length);
      email = false;
    } else {
      address = raw;
      email = raw.contains('@');
    }
    if (address.isEmpty || address != address.trim()) return null;
    if (email) {
      if (!_emailPattern.hasMatch(address)) return null;
    } else if (!_telephonePattern.hasMatch(address)) {
      return null;
    }
    return _NormalizedCanonicalHandle(address: address, email: email);
  }

  bool _matchesActiveScope(CloudSyncScope scope, int generation) {
    final active = _activeScopeProvider();
    return active != null &&
        active.scope == scope &&
        active.generation == generation;
  }

  void _requireActiveScope(CloudSyncScope scope, int generation) {
    if (!isActiveAccountScope(scope: scope, generation: generation)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_scope_fence_rejected',
      );
    }
  }

  String? _resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    final value = _identityResolver.resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
    );
    if (value == null || !_isValidCanonicalGuid(value)) return null;
    return value;
  }

  static bool _isValidCanonicalGuid(String value) {
    if (value.isEmpty || value.length > 1024) return false;
    return value.codeUnits.every((unit) => unit >= 0x20 && unit != 0x7f);
  }

  Chat? _findChat(String guid) {
    final query = _chats.query(Chat_.guid.equals(guid)).build()..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  Chat? _findChatByIdentifier(String chatIdentifier) {
    final query =
        _chats.query(Chat_.chatIdentifier.equals(chatIdentifier)).build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  Handle? _findHandle(String uniqueAddressAndService) {
    final query =
        _handles
            .query(
              Handle_.uniqueAddressAndService.equals(uniqueAddressAndService),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  Message? _findMessage(String guid) {
    final query = _messages.query(Message_.guid.equals(guid)).build()
      ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  Attachment? _findAttachment(String guid) {
    final query = _attachments.query(Attachment_.guid.equals(guid)).build()
      ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  static final RegExp _emailPattern = RegExp(r'^[^@\s:]+@[^@\s:]+\.[^@\s:]+$');
  static final RegExp _telephonePattern = RegExp(r'^\+?[0-9]{3,20}$');
  static const Set<String> _reactionTypes = {
    'love',
    'like',
    'dislike',
    'laugh',
    'emphasize',
    'question',
    'emoji',
    'stickerback',
    '-love',
    '-like',
    '-dislike',
    '-laugh',
    '-emphasize',
    '-question',
    '-emoji',
    '-stickerback',
  };
}

final class _NormalizedCanonicalHandle {
  const _NormalizedCanonicalHandle({
    required this.address,
    required this.email,
  });

  final String address;
  final bool email;
  String get prefixed => '${email ? 'mailto' : 'tel'}:$address';
}
