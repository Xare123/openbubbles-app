import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_models.dart';
import 'cloud_attachment_provenance.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_semantic_diagnostics.dart';
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

  /// Returns the owner of [canonicalGuid] while the same bounded identity
  /// proof is active. Null means ownership is unknown, not that the GUID is
  /// safe to reuse for an existing row.
  CloudCanonicalIdentityOwner? resolveCanonicalIdentityOwner({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  });
}

/// A logical identity proven to own one canonical row for a bounded scope and
/// generation.
final class CloudCanonicalIdentityOwner {
  const CloudCanonicalIdentityOwner({
    required this.kind,
    required this.logicalEntityKeyHash,
  });

  final CloudEntityKind kind;
  final String logicalEntityKeyHash;

  bool matches({
    required CloudEntityKind expectedKind,
    required String expectedLogicalEntityKeyHash,
  }) =>
      kind == expectedKind &&
      logicalEntityKeyHash == expectedLogicalEntityKeyHash;
}

/// One-way durable binding between a canonical ObjectBox row and its semantic
/// snapshot. The digest is evidence, not another canonical-ID registry: it is
/// persisted only on the same scoped snapshot transaction as the row mutation.
/// Its input binds the exact scope, generation, entity kind, and logical owner
/// so a copied snapshot cannot establish ownership in another context.
final class CloudCanonicalIdentityDigest {
  const CloudCanonicalIdentityDigest._();

  static final RegExp _pattern = RegExp(r'^[0-9a-f]{64}$');

  static String forCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
    required String canonicalGuid,
  }) {
    if (generation <= 0 ||
        logicalEntityKeyHash.isEmpty ||
        !_isValidCanonicalGuid(canonicalGuid)) {
      throw ArgumentError('canonical_identity_guid_invalid');
    }
    final canonical = StringBuffer('canonical-identity-v2\u001f')
      ..write(_lengthPrefixed(scope.storageKey))
      ..write(_lengthPrefixed(scope.accountFingerprint))
      ..write(_lengthPrefixed(scope.container))
      ..write(_lengthPrefixed(scope.database))
      ..write(_lengthPrefixed(scope.zone))
      ..write(_lengthPrefixed(scope.streamKind.name))
      ..write(_lengthPrefixed(scope.schemaVersion.toString()))
      ..write(_lengthPrefixed(scope.persistenceLane.name))
      ..write(_lengthPrefixed(generation.toString()))
      ..write(_lengthPrefixed(kind.name))
      ..write(_lengthPrefixed(logicalEntityKeyHash))
      ..write(_lengthPrefixed(canonicalGuid));
    return sha256.convert(utf8.encode(canonical.toString())).toString();
  }

  static String forPayload({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
  }) => forCanonicalGuid(
    scope: scope,
    generation: generation,
    kind: payload.kind,
    logicalEntityKeyHash: payload.logicalEntityKeyHash,
    canonicalGuid: switch (payload) {
      CloudChatEntityPayload value => value.canonicalGuid,
      CloudMessageEntityPayload value => value.canonicalGuid,
      CloudReactionEntityPayload value => value.canonicalGuid,
      CloudAttachmentEntityPayload value => value.canonicalGuid,
      CloudGroupPhotoEntityPayload value => value.photoGuid,
      CloudProfileEntityPayload _ => throw ArgumentError(
        'canonical_identity_payload_unsupported',
      ),
    },
  );

  /// Owner-independent lookup key used only to find every durable claimant of
  /// one canonical GUID inside the exact account scope and generation.
  static String forCanonicalGuidLookup({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) {
    if (generation <= 0 || !_isValidCanonicalGuid(canonicalGuid)) {
      throw ArgumentError('canonical_identity_guid_invalid');
    }
    final canonical = StringBuffer('canonical-identity-lookup-v1\u001f')
      ..write(_lengthPrefixed(scope.storageKey))
      ..write(_lengthPrefixed(scope.accountFingerprint))
      ..write(_lengthPrefixed(scope.container))
      ..write(_lengthPrefixed(scope.database))
      ..write(_lengthPrefixed(scope.zone))
      ..write(_lengthPrefixed(scope.streamKind.name))
      ..write(_lengthPrefixed(scope.schemaVersion.toString()))
      ..write(_lengthPrefixed(scope.persistenceLane.name))
      ..write(_lengthPrefixed(generation.toString()))
      ..write(_lengthPrefixed(canonicalGuid));
    return sha256.convert(utf8.encode(canonical.toString())).toString();
  }

  static String forPayloadLookup({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
  }) => forCanonicalGuidLookup(
    scope: scope,
    generation: generation,
    canonicalGuid: switch (payload) {
      CloudChatEntityPayload value => value.canonicalGuid,
      CloudMessageEntityPayload value => value.canonicalGuid,
      CloudReactionEntityPayload value => value.canonicalGuid,
      CloudAttachmentEntityPayload value => value.canonicalGuid,
      CloudGroupPhotoEntityPayload value => value.photoGuid,
      CloudProfileEntityPayload _ => throw ArgumentError(
        'canonical_identity_payload_unsupported',
      ),
    },
  );

  static bool isValid(String value) => _pattern.hasMatch(value);

  static String _lengthPrefixed(String value) =>
      '${utf8.encode(value).length}:$value';

  static bool _isValidCanonicalGuid(String value) =>
      value.isNotEmpty &&
      value.length <= 1024 &&
      value.codeUnits.every((unit) => unit >= 0x20 && unit != 0x7f);
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
    implements
        CloudCanonicalSemanticEntityAdapter,
        CloudAppliedChatProjectionRepairAdapter {
  static final RegExp _externalDigestPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

  ObjectBoxCanonicalSemanticEntityAdapter({
    required this.store,
    required this._activeScopeProvider,
    required this._identityResolver,
    CloudCanonicalActiveScope? chatDependencyScope,
    CloudCanonicalActiveScope? messageDependencyScope,
    CloudSyncSemanticDiagnosticRecorder? diagnosticRecorder,
    this._semanticApplyEnabled = false,
    this._allowExistingChatPresentationUpdates = false,
    this._allowChatUpserts = false,
    this._allowExistingChatDisplayNameClears = false,
    this._allowMessageUpserts = false,
    this._allowReactionUpserts = false,
    this._allowAttachmentMetadataUpserts = false,
  }) : // Public named parameters intentionally map to private immutable fields.
       // ignore: prefer_initializing_formals
       _chatDependencyScope = chatDependencyScope,
       // ignore: prefer_initializing_formals
       _messageDependencyScope = messageDependencyScope,
       // ignore: prefer_initializing_formals
       _diagnosticRecorder = diagnosticRecorder,
       _chats = store.box<Chat>(),
       _handles = store.box<Handle>(),
       _messages = store.box<Message>(),
       _attachments = store.box<Attachment>(),
       _checkpoints = store.box<CloudSyncCheckpointEntity>(),
       _snapshots = store.box<CloudSemanticSnapshotEntity>(),
       _chatAliases = store.box<CloudSemanticChatAliasEntity>();

  @override
  final Store store;
  final CloudCanonicalActiveScope? Function() _activeScopeProvider;
  final CloudCanonicalIdentityResolver _identityResolver;
  final CloudCanonicalActiveScope? _chatDependencyScope;
  final CloudCanonicalActiveScope? _messageDependencyScope;
  final CloudSyncSemanticDiagnosticRecorder? _diagnosticRecorder;
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
  final Box<CloudSyncCheckpointEntity> _checkpoints;
  final Box<CloudSemanticSnapshotEntity> _snapshots;
  final Box<CloudSemanticChatAliasEntity> _chatAliases;

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
    final ownershipScope = _dependencyScopeFor(
      kind: kind,
      currentScope: scope,
      currentGeneration: generation,
    );
    _requireCanonicalIdentityOwnership(
      scope: ownershipScope.scope,
      generation: ownershipScope.generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuid: guid,
    );

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
  void validateOwnershipEvidence({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) {
    _requireActiveScope(scope, generation);
    final canonicalGuid = _resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
    );
    if (canonicalGuid == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_identity_unavailable',
      );
    }
    _requireCanonicalIdentityOwnership(
      scope: scope,
      generation: generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuid: canonicalGuid,
    );
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
    _validateMutationIdentitySet(payload);

    final canonicalGuid = _resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: payload.kind,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
    );
    if (canonicalGuid == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_identity_unavailable',
      );
    }
    _requireCanonicalIdentityOwnership(
      scope: scope,
      generation: generation,
      kind: payload.kind,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
      canonicalGuid: canonicalGuid,
    );

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
  CloudCanonicalSemanticMutationReceipt repairChatProjection({
    required CloudSyncScope scope,
    required int generation,
    required CloudChatEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    _requireActiveScope(scope, generation);
    if (snapshot.kind != CloudEntityKind.chat ||
        payload.logicalEntityKeyHash != snapshot.logicalEntityKeyHash) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'canonical_chat_repair_snapshot_mismatch',
      );
    }
    _validateMutationIdentitySet(payload);
    final canonicalGuid = _resolveCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
    );
    if (canonicalGuid == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_identity_unavailable',
      );
    }
    _requireCanonicalIdentityOwnership(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
      canonicalGuid: canonicalGuid,
    );
    return _repairExistingChatAliases(
      scope: scope,
      generation: generation,
      payload: payload,
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

  CloudCanonicalSemanticMutationReceipt _repairExistingChatAliases({
    required CloudSyncScope scope,
    required int generation,
    required CloudChatEntityPayload payload,
  }) {
    if (payload.service == null ||
        payload.style == null ||
        payload.aliases.isEmpty ||
        !payload.aliases.any(
          (alias) => alias.kind == CloudSemanticChatAliasKind.serviceIdentifier,
        ) ||
        payload.aliases.any(
          (alias) => !_externalDigestPattern.hasMatch(alias.keyHash),
        )) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'canonical_chat_repair_shape_invalid',
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
    final chat = _findChat(guid);
    final chatId = chat?.id;
    if (chat == null || chatId == null || chatId <= 0) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_chat_repair_target_unavailable',
      );
    }
    final service = payload.service!;
    final expectedStyle = switch (payload.style!) {
      CloudSemanticChatStyle.direct => 45,
      CloudSemanticChatStyle.group => 43,
    };
    if (chat.style != null && chat.style != expectedStyle) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_style_conflict',
      );
    }
    if (chat.isRpSms != (service == CloudSemanticService.sms)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_service_conflict',
      );
    }
    final aliasMatch = _findChatByIdentifier(payload.chatIdentifier, service);
    if (aliasMatch != null && aliasMatch.id != chatId) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_alias_conflict',
      );
    }

    final canonicalGuidHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
      canonicalGuid: guid,
    );
    final canonicalGuidLookupHash =
        CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
          scope: scope,
          generation: generation,
          canonicalGuid: guid,
        );
    for (final alias in payload.aliases) {
      _validateChatAliasClaim(
        scope: scope,
        generation: generation,
        service: service,
        alias: alias,
        logicalEntityKeyHash: payload.logicalEntityKeyHash,
        canonicalGuidHash: canonicalGuidHash,
        canonicalGuidLookupHash: canonicalGuidLookupHash,
        expectedChat: chat,
      );
    }
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final alias in payload.aliases) {
      _putChatAlias(
        scope: scope,
        generation: generation,
        service: service,
        alias: alias,
        logicalEntityKeyHash: payload.logicalEntityKeyHash,
        canonicalGuidHash: canonicalGuidHash,
        canonicalGuidLookupHash: canonicalGuidLookupHash,
        chatId: chatId,
        updatedAtMs: nowMs,
      );
    }
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  CloudCanonicalSemanticMutationReceipt _applyChatUpsert({
    required CloudSyncScope scope,
    required int generation,
    required CloudChatEntityPayload payload,
  }) {
    if (payload.service == null ||
        payload.style == null ||
        (payload.groupVersion != null && payload.groupVersion! < 0) ||
        payload.aliases.isEmpty ||
        !payload.aliases.any(
          (alias) => alias.kind == CloudSemanticChatAliasKind.serviceIdentifier,
        ) ||
        payload.aliases.any(
          (alias) => !_externalDigestPattern.hasMatch(alias.keyHash),
        )) {
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

    final service = payload.service!;
    final isSms = service == CloudSemanticService.sms;
    final aliasMatch = _findChatByIdentifier(payload.chatIdentifier, service);
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
    if (chat != null && chat.isRpSms != isSms) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_service_conflict',
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

    final canonicalGuidHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: payload.logicalEntityKeyHash,
      canonicalGuid: guid,
    );
    final canonicalGuidLookupHash =
        CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
          scope: scope,
          generation: generation,
          canonicalGuid: guid,
        );
    for (final alias in payload.aliases) {
      _validateChatAliasClaim(
        scope: scope,
        generation: generation,
        service: service,
        alias: alias,
        logicalEntityKeyHash: payload.logicalEntityKeyHash,
        canonicalGuidHash: canonicalGuidHash,
        canonicalGuidLookupHash: canonicalGuidLookupHash,
        expectedChat: chat,
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
        ? _resolveParticipantHandles(payload.participantHandles, service)
        : const <Handle>[];

    chat ??= Chat(
      guid: guid,
      chatIdentifier: payload.chatIdentifier,
      style: style,
    );
    chat.chatIdentifier = payload.chatIdentifier;
    chat.style = style;
    chat.isRpSms = isSms;

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

    final chatId = _chats.put(chat);
    chat.id ??= chatId;
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

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final alias in payload.aliases) {
      _putChatAlias(
        scope: scope,
        generation: generation,
        service: service,
        alias: alias,
        logicalEntityKeyHash: payload.logicalEntityKeyHash,
        canonicalGuidHash: canonicalGuidHash,
        canonicalGuidLookupHash: canonicalGuidLookupHash,
        chatId: chatId,
        updatedAtMs: nowMs,
      );
    }

    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  List<Handle> _resolveParticipantHandles(
    Iterable<String> rawHandles,
    CloudSemanticService service,
  ) {
    final handles = <Handle>[];
    final seen = <String>{};
    final serviceName = _serviceName(service);
    for (final raw in rawHandles) {
      // Apple's bare FZPersonID value is opaque. Only explicit tel/mailto
      // values carry a grammar that can be validated as a phone or email.
      final normalized = _normalizeHandle(
        raw,
        allowOpaqueBareParticipant: true,
        onInvalid: _diagnosticRecorder,
      );
      if (normalized == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.malformedRecord,
          safeCode: 'canonical_chat_participant_invalid',
        );
      }
      final uniqueKey = '${normalized.address}/$serviceName';
      if (!seen.add(uniqueKey)) continue;
      var handle = _findHandle(uniqueKey);
      if (handle == null) {
        handle = Handle(
          address: normalized.address,
          service: serviceName,
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
    if (payload.service == null ||
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
    final service = payload.service!;
    if (!_externalDigestPattern.hasMatch(payload.chatAliasKeyHash)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'canonical_message_chat_alias_invalid',
      );
    }
    final chatDependency = _dependencyScopeFor(
      kind: CloudEntityKind.chat,
      currentScope: scope,
      currentGeneration: generation,
    );
    var chat = _resolveChatByAlias(
      scope: chatDependency.scope,
      generation: chatDependency.generation,
      service: service,
      aliasKeyHash: payload.chatAliasKeyHash,
    );
    chat ??= _repairMessageChatAliasFromExactGuid(
      scope: chatDependency.scope,
      generation: chatDependency.generation,
      service: service,
      chatIdentifier: payload.chatIdentifier,
      aliasKeyHash: payload.chatAliasKeyHash,
    );
    if (chat == null) {
      _diagnosticRecorder?.call(
        'canonical_message_chat_alias_missing_${Chat.cloudIdentityReferenceShape(payload.chatIdentifier)}',
      );
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_chat_unavailable',
      );
    }
    final exactIdentifierMatch = _findChatByIdentifier(
      payload.chatIdentifier,
      service,
    );
    if (exactIdentifierMatch != null && exactIdentifierMatch.id != chat.id) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_message_chat_conflict',
      );
    }

    final flags = payload.knownFlags!;
    final sender = _resolveMessageSender(
      payload.senderHandle,
      flags.fromMe,
      service,
    );
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
        final attributedBodies = _attributedBodies(payload.attributedBodies);
        message.attributedBody = attributedBodies;
        // Apple can omit the plain `t` field while carrying the complete
        // message text in the attributed body. The normal Messages import
        // path treats that first attributed string as Message.text; preserve
        // the same invariant so fullText, notifications, search, and the
        // conversation list do not mislabel a real message as empty.
        if (payload.bodyState == CloudSemanticFieldState.absent &&
            attributedBodies.isNotEmpty) {
          message.text = attributedBodies.first.string;
        }
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
    final sender = _resolveMessageSender(
      payload.senderHandle,
      flags.fromMe,
      payload.service!,
    );
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
      final messageDependency = _dependencyScopeFor(
        kind: CloudEntityKind.message,
        currentScope: scope,
        currentGeneration: generation,
      );
      final ownerGuid = _requireResolvedGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: payload.ownerLogicalKeyHash!,
        payloadCanonicalGuid: payload.ownerCanonicalGuid!,
        durableOwnershipScope: messageDependency,
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
    attachment.metadata ??= <String, dynamic>{};
    attachment.metadata![cloudAttachmentV2MetadataKey] =
        cloudAttachmentV2MetadataVersion;
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
    CloudCanonicalActiveScope? durableOwnershipScope,
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
    final ownershipScope =
        durableOwnershipScope ??
        CloudCanonicalActiveScope(scope: scope, generation: generation);
    _requireCanonicalIdentityOwnership(
      scope: ownershipScope.scope,
      generation: ownershipScope.generation,
      kind: kind,
      logicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuid: resolved,
    );
    return resolved;
  }

  CloudCanonicalActiveScope _dependencyScopeFor({
    required CloudEntityKind kind,
    required CloudSyncScope currentScope,
    required int currentGeneration,
  }) {
    final configured = switch (kind) {
      CloudEntityKind.chat => _chatDependencyScope,
      CloudEntityKind.message => _messageDependencyScope,
      _ => null,
    };
    if (configured == null) {
      return CloudCanonicalActiveScope(
        scope: currentScope,
        generation: currentGeneration,
      );
    }
    final dependency = configured.scope;
    final expectedZone = switch (kind) {
      CloudEntityKind.chat => 'chatManateeZone',
      CloudEntityKind.message => 'messageManateeZone',
      _ => currentScope.zone,
    };
    if (configured.generation <= 0 ||
        dependency.zone != expectedZone ||
        (dependency == currentScope &&
            configured.generation != currentGeneration) ||
        dependency.accountFingerprint != currentScope.accountFingerprint ||
        dependency.container != currentScope.container ||
        dependency.database != currentScope.database ||
        dependency.streamKind != currentScope.streamKind ||
        dependency.schemaVersion != currentScope.schemaVersion ||
        dependency.persistenceLane != currentScope.persistenceLane) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_dependency_scope_conflict',
      );
    }
    // Production calls this synchronously inside the gateway's ObjectBox write
    // transaction. The checkpoint read and canonical mutation therefore share
    // one serialization boundary with a competing account reset.
    final checkpoint = _findCheckpoint(dependency);
    if (checkpoint == null ||
        checkpoint.generation != configured.generation ||
        checkpoint.accountFingerprint != dependency.accountFingerprint ||
        checkpoint.container != dependency.container ||
        checkpoint.database != dependency.database ||
        checkpoint.zone != dependency.zone ||
        checkpoint.streamKind != dependency.streamKind.name ||
        checkpoint.schemaVersion != dependency.schemaVersion ||
        checkpoint.persistenceLane != dependency.persistenceLane.name) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_dependency_scope_stale',
      );
    }
    return configured;
  }

  CloudSyncCheckpointEntity? _findCheckpoint(CloudSyncScope scope) {
    final query =
        _checkpoints
            .query(
              CloudSyncCheckpointEntity_.checkpointKey.equals(
                cloudSyncPersistentScopeKey(scope),
              ),
            )
            .build()
          ..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  void _requireCanonicalIdentityOwnership({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
    required String canonicalGuid,
  }) {
    final resolverOwner = _identityResolver.resolveCanonicalIdentityOwner(
      scope: scope,
      generation: generation,
      canonicalGuid: canonicalGuid,
    );
    if (resolverOwner != null &&
        !resolverOwner.matches(
          expectedKind: kind,
          expectedLogicalEntityKeyHash: logicalEntityKeyHash,
        )) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_identity_owner_conflict',
      );
    }

    final scopeGenerationKey = _scopeGenerationKey(scope, generation);
    final legacyQuery =
        _snapshots
            .query(
              CloudSemanticSnapshotEntity_.scopeGenerationKey
                  .equals(scopeGenerationKey)
                  .and(
                    CloudSemanticSnapshotEntity_.canonicalGuidLookupHash
                        .isNull(),
                  ),
            )
            .build()
          ..limit = 1;
    try {
      if (legacyQuery.findFirst() != null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_identity_owner_unproven',
        );
      }
    } finally {
      legacyQuery.close();
    }

    final lookupHash = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
      scope: scope,
      generation: generation,
      canonicalGuid: canonicalGuid,
    );
    final ownerQuery =
        _snapshots
            .query(
              CloudSemanticSnapshotEntity_.scopeGenerationKey
                  .equals(scopeGenerationKey)
                  .and(
                    CloudSemanticSnapshotEntity_.canonicalGuidLookupHash.equals(
                      lookupHash,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    late final List<CloudSemanticSnapshotEntity> ownerCandidates;
    try {
      ownerCandidates = ownerQuery.find();
    } finally {
      ownerQuery.close();
    }
    if (ownerCandidates.length > 1) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_identity_owner_conflict',
      );
    }

    var exactDurableProof = false;
    for (final snapshot in ownerCandidates) {
      if (!_snapshotMatchesScope(snapshot, scope, generation) ||
          snapshot.canonicalGuidLookupHash != lookupHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_identity_owner_unproven',
        );
      }
      final snapshotKind = _snapshotKind(snapshot.entityKind);
      if (snapshotKind == null) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_identity_owner_unproven',
        );
      }
      final snapshotGuidHash = snapshot.canonicalGuidHash;
      if (snapshotGuidHash == null) {
        // A pre-ownership snapshot cannot prove that it does not own this
        // GUID. It must block every canonical mutation in this scope and
        // generation, even if the incoming GUID does not currently resolve to
        // a local row. Otherwise a fresh row could establish an alias that
        // future ownership checks can no longer disprove.
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_identity_owner_unproven',
        );
      }
      if (!CloudCanonicalIdentityDigest.isValid(snapshotGuidHash)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_identity_owner_unproven',
        );
      }
      final snapshotBoundHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: snapshotKind,
        logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
        canonicalGuid: canonicalGuid,
      );
      if (snapshotGuidHash != snapshotBoundHash) {
        // The exact owner row must carry evidence for this exact context. A
        // mismatch is not an unrelated GUID, it is stale or re-homed proof.
        if (snapshotKind == kind &&
            snapshot.logicalEntityKeyHash == logicalEntityKeyHash) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.dependency,
            safeCode: 'canonical_identity_owner_unproven',
          );
        }
        continue;
      }
      if (snapshotKind != kind ||
          snapshot.logicalEntityKeyHash != logicalEntityKeyHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_identity_owner_conflict',
        );
      }
      exactDurableProof = true;
    }

    // A transient decode lease proves only the identity asserted by this one
    // incoming mutation. It cannot establish ownership of an already-present
    // canonical row, which may predate V2 or belong to another account scope.
    // Existing rows therefore require their own exact, durable V2 proof.
    if (!exactDurableProof && _canonicalRowExists(canonicalGuid)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_identity_owner_unproven',
      );
    }
  }

  void _validateMutationIdentitySet(CloudSemanticEntityPayload payload) {
    final owners = <String, CloudCanonicalIdentityOwner>{};
    void add({
      required CloudEntityKind kind,
      required String logicalEntityKeyHash,
      required String canonicalGuid,
    }) {
      final existing = owners[canonicalGuid];
      if (existing != null &&
          !existing.matches(
            expectedKind: kind,
            expectedLogicalEntityKeyHash: logicalEntityKeyHash,
          )) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_identity_owner_conflict',
        );
      }
      owners[canonicalGuid] = CloudCanonicalIdentityOwner(
        kind: kind,
        logicalEntityKeyHash: logicalEntityKeyHash,
      );
    }

    switch (payload) {
      case CloudChatEntityPayload value:
        add(
          kind: CloudEntityKind.chat,
          logicalEntityKeyHash: value.logicalEntityKeyHash,
          canonicalGuid: value.canonicalGuid,
        );
      case CloudMessageEntityPayload value:
        add(
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: value.logicalEntityKeyHash,
          canonicalGuid: value.canonicalGuid,
        );
        if (value.replyParentLogicalKeyHash != null) {
          add(
            kind: CloudEntityKind.message,
            logicalEntityKeyHash: value.replyParentLogicalKeyHash!,
            canonicalGuid: value.replyParentCanonicalGuid!,
          );
        }
        if (value.associationParentLogicalKeyHash != null) {
          add(
            kind: CloudEntityKind.message,
            logicalEntityKeyHash: value.associationParentLogicalKeyHash!,
            canonicalGuid: value.associationParentCanonicalGuid!,
          );
        }
      case CloudReactionEntityPayload value:
        add(
          kind: CloudEntityKind.reaction,
          logicalEntityKeyHash: value.logicalEntityKeyHash,
          canonicalGuid: value.canonicalGuid,
        );
        add(
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: value.parentLogicalKeyHash,
          canonicalGuid: value.parentCanonicalGuid,
        );
      case CloudAttachmentEntityPayload value:
        add(
          kind: CloudEntityKind.attachment,
          logicalEntityKeyHash: value.logicalEntityKeyHash,
          canonicalGuid: value.canonicalGuid,
        );
        if (value.ownerLogicalKeyHash != null) {
          add(
            kind: CloudEntityKind.message,
            logicalEntityKeyHash: value.ownerLogicalKeyHash!,
            canonicalGuid: value.ownerCanonicalGuid!,
          );
        }
      case CloudProfileEntityPayload _:
      case CloudGroupPhotoEntityPayload _:
        break;
    }
  }

  bool _snapshotMatchesScope(
    CloudSemanticSnapshotEntity snapshot,
    CloudSyncScope scope,
    int generation,
  ) =>
      snapshot.scopeKey == _scopeKey(scope) &&
      snapshot.accountFingerprint == scope.accountFingerprint &&
      snapshot.container == scope.container &&
      snapshot.database == scope.database &&
      snapshot.zone == scope.zone &&
      snapshot.streamKind == scope.streamKind.name &&
      snapshot.schemaVersion == scope.schemaVersion &&
      snapshot.generation == generation;

  void _validateChatAliasClaim({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticService service,
    required CloudSemanticChatAlias alias,
    required String logicalEntityKeyHash,
    required String canonicalGuidHash,
    required String canonicalGuidLookupHash,
    required Chat? expectedChat,
  }) {
    final bindingKey = _chatAliasBindingKey(
      scope: scope,
      generation: generation,
      service: service,
      kind: alias.kind,
      aliasKeyHash: alias.keyHash,
    );
    final existing = _findChatAlias(bindingKey);
    if (existing == null) return;
    if (!_chatAliasMatchesScope(existing, scope, generation) ||
        existing.bindingKey != bindingKey ||
        existing.service != service.name ||
        existing.aliasKind != alias.kind.name ||
        existing.aliasKeyHash != alias.keyHash ||
        !_externalDigestPattern.hasMatch(existing.aliasKeyHash) ||
        !CloudCanonicalIdentityDigest.isValid(existing.canonicalGuidHash) ||
        !CloudCanonicalIdentityDigest.isValid(
          existing.canonicalGuidLookupHash,
        )) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_chat_alias_unproven',
      );
    }
    if (existing.chatLogicalEntityKeyHash != logicalEntityKeyHash ||
        existing.canonicalGuidHash != canonicalGuidHash ||
        existing.canonicalGuidLookupHash != canonicalGuidLookupHash) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_alias_conflict',
      );
    }
    final boundChat = _chats.get(existing.chatId);
    if (boundChat == null ||
        expectedChat == null ||
        boundChat.id != expectedChat.id ||
        boundChat.guid != expectedChat.guid) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_chat_alias_conflict',
      );
    }
    _requireCanonicalIdentityOwnership(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuid: boundChat.guid,
    );
  }

  void _putChatAlias({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticService service,
    required CloudSemanticChatAlias alias,
    required String logicalEntityKeyHash,
    required String canonicalGuidHash,
    required String canonicalGuidLookupHash,
    required int chatId,
    required int updatedAtMs,
  }) {
    final bindingKey = _chatAliasBindingKey(
      scope: scope,
      generation: generation,
      service: service,
      kind: alias.kind,
      aliasKeyHash: alias.keyHash,
    );
    final existing = _findChatAlias(bindingKey);
    _chatAliases.put(
      CloudSemanticChatAliasEntity(
        id: existing?.id ?? 0,
        bindingKey: bindingKey,
        scopeGenerationKey: _scopeGenerationKey(scope, generation),
        scopeKey: _scopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        generation: generation,
        service: service.name,
        aliasKind: alias.kind.name,
        aliasKeyHash: alias.keyHash,
        chatLogicalEntityKeyHash: logicalEntityKeyHash,
        canonicalGuidHash: canonicalGuidHash,
        canonicalGuidLookupHash: canonicalGuidLookupHash,
        chatId: chatId,
        updatedAtMs: updatedAtMs,
      ),
    );
  }

  /// Repairs the one exact alias omitted by older converters: a message's
  /// `chatID` can equal the canonical chat GUID while the stored alias set only
  /// covered `cid`, `gid`, and `ogid`.
  ///
  /// This is not a raw-identifier fallback. The candidate must be the exact
  /// canonical GUID of a same-service chat, and an existing scoped alias plus
  /// its durable identity snapshot must prove ownership before a new alias is
  /// written.
  Chat? _repairMessageChatAliasFromExactGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticService service,
    required String chatIdentifier,
    required String aliasKeyHash,
  }) {
    final chat = _findChat(chatIdentifier);
    final chatId = chat?.id;
    if (chat == null || chatId == null || chatId <= 0) return null;
    if (chat.isRpSms != (service == CloudSemanticService.sms)) {
      _diagnosticRecorder?.call(
        'canonical_message_chat_alias_exact_guid_service_mismatch',
      );
      return null;
    }

    final proof = _findProvenServiceAliasForChat(
      scope: scope,
      generation: generation,
      service: service,
      chat: chat,
    );
    if (proof == null) {
      _diagnosticRecorder?.call(
        'canonical_message_chat_alias_exact_guid_unproven',
      );
      return null;
    }

    _putChatAlias(
      scope: scope,
      generation: generation,
      service: service,
      alias: CloudSemanticChatAlias(
        kind: CloudSemanticChatAliasKind.serviceIdentifier,
        keyHash: aliasKeyHash,
      ),
      logicalEntityKeyHash: proof.chatLogicalEntityKeyHash,
      canonicalGuidHash: proof.canonicalGuidHash,
      canonicalGuidLookupHash: proof.canonicalGuidLookupHash,
      chatId: chatId,
      updatedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    _diagnosticRecorder?.call(
      'canonical_message_chat_alias_repaired_exact_guid',
    );
    return _resolveChatByAlias(
      scope: scope,
      generation: generation,
      service: service,
      aliasKeyHash: aliasKeyHash,
    );
  }

  CloudSemanticChatAliasEntity? _findProvenServiceAliasForChat({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticService service,
    required Chat chat,
  }) {
    final chatId = chat.id;
    if (chatId == null || chatId <= 0) return null;
    const kind = CloudSemanticChatAliasKind.serviceIdentifier;
    final query = _chatAliases
        .query(
          CloudSemanticChatAliasEntity_.scopeGenerationKey
              .equals(_scopeGenerationKey(scope, generation))
              .and(CloudSemanticChatAliasEntity_.chatId.equals(chatId))
              .and(CloudSemanticChatAliasEntity_.service.equals(service.name))
              .and(CloudSemanticChatAliasEntity_.aliasKind.equals(kind.name)),
        )
        .build();
    late final List<CloudSemanticChatAliasEntity> candidates;
    try {
      candidates = query.find();
    } finally {
      query.close();
    }
    if (candidates.isEmpty) return null;

    CloudSemanticChatAliasEntity? proof;
    for (final candidate in candidates) {
      if (!_chatAliasMatchesScope(candidate, scope, generation) ||
          candidate.service != service.name ||
          candidate.aliasKind != kind.name ||
          candidate.chatId != chatId ||
          !_externalDigestPattern.hasMatch(candidate.aliasKeyHash) ||
          !_externalDigestPattern.hasMatch(
            candidate.chatLogicalEntityKeyHash,
          ) ||
          !CloudCanonicalIdentityDigest.isValid(candidate.canonicalGuidHash) ||
          !CloudCanonicalIdentityDigest.isValid(
            candidate.canonicalGuidLookupHash,
          )) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_message_chat_alias_unproven',
        );
      }
      final expectedBindingKey = _chatAliasBindingKey(
        scope: scope,
        generation: generation,
        service: service,
        kind: kind,
        aliasKeyHash: candidate.aliasKeyHash,
      );
      final expectedGuidHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: candidate.chatLogicalEntityKeyHash,
        canonicalGuid: chat.guid,
      );
      final expectedLookupHash =
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: generation,
            canonicalGuid: chat.guid,
          );
      if (candidate.bindingKey != expectedBindingKey ||
          candidate.canonicalGuidHash != expectedGuidHash ||
          candidate.canonicalGuidLookupHash != expectedLookupHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.dependency,
          safeCode: 'canonical_message_chat_alias_unproven',
        );
      }
      _requireCanonicalIdentityOwnership(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: candidate.chatLogicalEntityKeyHash,
        canonicalGuid: chat.guid,
      );
      if (proof != null &&
          (proof.chatLogicalEntityKeyHash !=
                  candidate.chatLogicalEntityKeyHash ||
              proof.canonicalGuidHash != candidate.canonicalGuidHash ||
              proof.canonicalGuidLookupHash !=
                  candidate.canonicalGuidLookupHash)) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_chat_alias_conflict',
        );
      }
      proof ??= candidate;
    }
    return proof;
  }

  Chat? _resolveChatByAlias({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticService service,
    required String aliasKeyHash,
  }) {
    const kind = CloudSemanticChatAliasKind.serviceIdentifier;
    final bindingKey = _chatAliasBindingKey(
      scope: scope,
      generation: generation,
      service: service,
      kind: kind,
      aliasKeyHash: aliasKeyHash,
    );
    final binding = _findChatAlias(bindingKey);
    if (binding == null) return null;
    if (!_chatAliasMatchesScope(binding, scope, generation) ||
        binding.bindingKey != bindingKey ||
        binding.service != service.name ||
        binding.aliasKind != kind.name ||
        binding.aliasKeyHash != aliasKeyHash ||
        !_externalDigestPattern.hasMatch(binding.aliasKeyHash) ||
        !CloudCanonicalIdentityDigest.isValid(binding.canonicalGuidHash) ||
        !CloudCanonicalIdentityDigest.isValid(
          binding.canonicalGuidLookupHash,
        )) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_chat_alias_unproven',
      );
    }

    final chat = _chats.get(binding.chatId);
    if (chat == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_chat_unavailable',
      );
    }
    if (chat.isRpSms != (service == CloudSemanticService.sms)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'canonical_message_chat_conflict',
      );
    }
    final expectedGuidHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: binding.chatLogicalEntityKeyHash,
      canonicalGuid: chat.guid,
    );
    final expectedLookupHash =
        CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
          scope: scope,
          generation: generation,
          canonicalGuid: chat.guid,
        );
    if (binding.canonicalGuidHash != expectedGuidHash ||
        binding.canonicalGuidLookupHash != expectedLookupHash) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'canonical_message_chat_alias_unproven',
      );
    }
    _requireCanonicalIdentityOwnership(
      scope: scope,
      generation: generation,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: binding.chatLogicalEntityKeyHash,
      canonicalGuid: chat.guid,
    );
    return chat;
  }

  bool _chatAliasMatchesScope(
    CloudSemanticChatAliasEntity binding,
    CloudSyncScope scope,
    int generation,
  ) =>
      binding.scopeGenerationKey == _scopeGenerationKey(scope, generation) &&
      binding.scopeKey == _scopeKey(scope) &&
      binding.accountFingerprint == scope.accountFingerprint &&
      binding.container == scope.container &&
      binding.database == scope.database &&
      binding.zone == scope.zone &&
      binding.streamKind == scope.streamKind.name &&
      binding.schemaVersion == scope.schemaVersion &&
      binding.generation == generation;

  static String _chatAliasBindingKey({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticService service,
    required CloudSemanticChatAliasKind kind,
    required String aliasKeyHash,
  }) =>
      'semantic-chat-alias1:${sha256.convert(utf8.encode('${scope.storageKey}\u001f$generation\u001f${service.name}\u001f${kind.name}\u001f$aliasKeyHash')).toString()}';

  static String _scopeKey(CloudSyncScope scope) =>
      'scope2:${sha256.convert(utf8.encode(scope.storageKey)).toString()}';

  static String _scopeGenerationKey(CloudSyncScope scope, int generation) =>
      'semantic-generation4:${sha256.convert(utf8.encode('${_scopeKey(scope)}\u001f$generation')).toString()}';

  CloudEntityKind? _snapshotKind(String value) {
    for (final kind in CloudEntityKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }

  bool _canonicalRowExists(String guid) =>
      _findChat(guid) != null ||
      _findMessage(guid) != null ||
      _findAttachment(guid) != null;

  Handle? _resolveMessageSender(
    String raw,
    bool fromMe,
    CloudSemanticService service,
  ) {
    if (raw.isEmpty && fromMe) return null;
    final normalized = _normalizeHandle(raw);
    if (normalized == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'canonical_message_sender_invalid',
      );
    }
    final serviceName = _serviceName(service);
    final key = '${normalized.address}/$serviceName';
    var handle = _findHandle(key);
    if (handle == null) {
      handle = Handle(
        address: normalized.address,
        service: serviceName,
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

  _NormalizedCanonicalHandle? _normalizeHandle(
    String raw, {
    bool allowOpaqueBareParticipant = false,
    CloudSyncSemanticDiagnosticRecorder? onInvalid,
  }) {
    _NormalizedCanonicalHandle? reject(String safeCode) {
      onInvalid?.call(safeCode);
      return null;
    }

    if (raw.isEmpty) return reject('canonical_participant_shape_empty');
    if (raw != raw.trim()) {
      return reject('canonical_participant_shape_outer_whitespace');
    }
    if (raw.length > 512) {
      return reject('canonical_participant_shape_too_long');
    }
    String address;
    bool email;
    bool bare = false;
    final lower = raw.toLowerCase();
    if (lower.startsWith('mailto:')) {
      address = raw.substring('mailto:'.length);
      email = true;
    } else if (lower.startsWith('tel:')) {
      address = raw.substring('tel:'.length);
      email = false;
    } else {
      if (raw.contains(':')) {
        return reject('canonical_participant_shape_unknown_scheme');
      }
      bare = true;
      address = raw;
      email = raw.contains('@');
    }
    if (address.isEmpty) {
      return reject('canonical_participant_shape_empty_address');
    }
    if (address != address.trim()) {
      return reject('canonical_participant_shape_address_whitespace');
    }
    if (email) {
      if (!_emailPattern.hasMatch(address)) {
        return reject('canonical_participant_shape_email_invalid');
      }
    } else if (!_telephonePattern.hasMatch(address)) {
      if (allowOpaqueBareParticipant && bare) {
        if (_controlCharacterPattern.hasMatch(address)) {
          return reject('canonical_participant_shape_control_character');
        }
        if (_whitespacePattern.hasMatch(address)) {
          return reject('canonical_participant_shape_embedded_whitespace');
        }
        return _NormalizedCanonicalHandle(address: address, email: false);
      }
      onInvalid?.call('canonical_participant_shape_telephone_invalid');
      onInvalid?.call(_telephoneInvalidDiagnosticKey(address));
      return null;
    }
    return _NormalizedCanonicalHandle(address: address, email: email);
  }

  String _telephoneInvalidDiagnosticKey(String address) {
    if (_percentEscapePattern.hasMatch(address)) {
      return 'canonical_participant_shape_telephone_invalid_percent_escaped';
    }
    if (address.runes.any((rune) => rune > 0x7f)) {
      return 'canonical_participant_shape_telephone_invalid_non_ascii';
    }

    final plusCount = address.runes.where((rune) => rune == 0x2b).length;
    if (plusCount != 0 && (plusCount != 1 || !address.startsWith('+'))) {
      return 'canonical_participant_shape_telephone_invalid_plus_position_count';
    }
    if (_asciiLetterPattern.hasMatch(address)) {
      return 'canonical_participant_shape_telephone_invalid_alphabetic_ascii';
    }

    final units = address.codeUnits;
    final hasDigit = units.any(_isAsciiDigit);
    final hasFormatting = units.any(
      (unit) => unit == 0x20 || _isAsciiPunctuation(unit),
    );
    if (hasDigit && hasFormatting) {
      return 'canonical_participant_shape_telephone_invalid_formatted_punctuation';
    }
    if (units.isNotEmpty && units.every(_isAsciiPunctuation)) {
      return 'canonical_participant_shape_telephone_invalid_punctuation_only';
    }
    return 'canonical_participant_shape_telephone_invalid_other';
  }

  static bool _isAsciiDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  static bool _isAsciiPunctuation(int unit) =>
      (unit >= 0x21 && unit <= 0x2f) ||
      (unit >= 0x3a && unit <= 0x40) ||
      (unit >= 0x5b && unit <= 0x60) ||
      (unit >= 0x7b && unit <= 0x7e);

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
    return CloudCanonicalIdentityDigest._isValidCanonicalGuid(value);
  }

  Chat? _findChat(String guid) {
    final query = _chats.query(Chat_.guid.equals(guid)).build()..limit = 1;
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudSemanticChatAliasEntity? _findChatAlias(String bindingKey) {
    final query =
        _chatAliases
            .query(CloudSemanticChatAliasEntity_.bindingKey.equals(bindingKey))
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_chat_alias_conflict',
        );
      }
      return matches.isEmpty ? null : matches.first;
    } finally {
      query.close();
    }
  }

  Chat? _findChatByIdentifier(
    String chatIdentifier,
    CloudSemanticService service,
  ) {
    final query =
        _chats
            .query(
              Chat_.chatIdentifier
                  .equals(chatIdentifier)
                  .and(
                    Chat_.isRpSms.equals(service == CloudSemanticService.sms),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (matches.length > 1) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'canonical_chat_alias_conflict',
        );
      }
      return matches.isEmpty ? null : matches.first;
    } finally {
      query.close();
    }
  }

  static String _serviceName(CloudSemanticService service) => switch (service) {
    CloudSemanticService.iMessage => 'iMessage',
    CloudSemanticService.sms => 'SMS',
  };

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
  static final RegExp _asciiLetterPattern = RegExp(r'[A-Za-z]');
  static final RegExp _percentEscapePattern = RegExp(r'%[0-9A-Fa-f]{2}');
  static final RegExp _controlCharacterPattern = RegExp(
    r'[\u0000-\u001F\u007F-\u009F]',
  );
  static final RegExp _whitespacePattern = RegExp(r'\s');
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
