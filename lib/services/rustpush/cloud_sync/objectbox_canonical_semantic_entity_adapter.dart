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
/// This class intentionally has a very narrow currently-safe mutation:
/// updating the non-null display name of an *existing*, exactly-resolved chat
/// when that chat is not locally name-locked. It never creates a chat from
/// display names or participants, and never writes raw CloudKit IDs, account
/// identifiers, protected references, message text, attachment paths, or
/// media bytes into canonical entities.
///
/// The current semantic payloads do not include enough field-presence and
/// canonical identity data to safely create chats/messages/attachments or
/// apply reactions, profiles, group photos, or tombstones. Those operations
/// fail closed until the typed native DTO described in
/// `docs/CLOUD_SYNC_V2_CANONICAL_MAPPING.md` exists and its fixture gates pass.
/// No production composition instantiates this adapter today.
final class ObjectBoxCanonicalSemanticEntityAdapter
    implements CloudCanonicalSemanticEntityAdapter {
  ObjectBoxCanonicalSemanticEntityAdapter({
    required this.store,
    required this._activeScopeProvider,
    required this._identityResolver,
    this._semanticApplyEnabled = false,
    this._allowExistingChatPresentationUpdates = false,
  }) : _chats = store.box<Chat>(),
       _messages = store.box<Message>(),
       _attachments = store.box<Attachment>();

  @override
  final Store store;
  final CloudCanonicalActiveScope? Function() _activeScopeProvider;
  final CloudCanonicalIdentityResolver _identityResolver;
  final bool _semanticApplyEnabled;
  final bool _allowExistingChatPresentationUpdates;
  final Box<Chat> _chats;
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
      return _applyExistingChatPresentation(
        scope: scope,
        generation: generation,
        payload: payload,
      );
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
}
