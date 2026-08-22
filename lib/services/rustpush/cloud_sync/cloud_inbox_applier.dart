import 'dart:typed_data';

import 'cloud_merge_policy.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';

enum CloudDecodedMutationKind { upsert, tombstone }

/// Transient user-visible entity data produced by the native decoder.
///
/// Payloads have no JSON/Map conversion and their string representation is
/// permanently redacted. They may be consumed only by the canonical local-store
/// adapter and must never be placed in Cloud Sync metadata, observability, or
/// exception messages.
sealed class CloudSemanticEntityPayload {
  const CloudSemanticEntityPayload();

  CloudEntityKind get kind;
  String get logicalEntityKeyHash;

  @override
  String toString() => 'CloudSemanticEntityPayload(${kind.name}, redacted)';
}

final class CloudMessageEntityPayload extends CloudSemanticEntityPayload {
  CloudMessageEntityPayload({
    required this.logicalEntityKeyHash,
    required this.canonicalGuid,
    required this.chatLogicalKeyHash,
    required this.chatIdentifier,
    required this.body,
    required this.senderHandle,
  }) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_message_payload_logical_key_invalid');
    }
    if (canonicalGuid.isEmpty || chatIdentifier.isEmpty) {
      throw ArgumentError('cloud_message_payload_canonical_identity_invalid');
    }
    if (chatLogicalKeyHash.isEmpty) {
      throw ArgumentError('cloud_message_payload_chat_key_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String canonicalGuid;
  final String chatLogicalKeyHash;
  final String chatIdentifier;
  final String body;
  final String senderHandle;

  @override
  CloudEntityKind get kind => CloudEntityKind.message;
}

final class CloudChatEntityPayload extends CloudSemanticEntityPayload {
  CloudChatEntityPayload({
    required this.logicalEntityKeyHash,
    required this.canonicalGuid,
    required this.chatIdentifier,
    required this.displayName,
    required Iterable<String> participantHandles,
  }) : participantHandles = List.unmodifiable(participantHandles) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_chat_payload_logical_key_invalid');
    }
    if (canonicalGuid.isEmpty || chatIdentifier.isEmpty) {
      throw ArgumentError('cloud_chat_payload_canonical_identity_invalid');
    }
    if (this.participantHandles.any((handle) => handle.isEmpty)) {
      throw ArgumentError('cloud_chat_payload_participant_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String canonicalGuid;
  final String chatIdentifier;
  final String? displayName;
  final List<String> participantHandles;

  @override
  CloudEntityKind get kind => CloudEntityKind.chat;
}

final class CloudAttachmentEntityPayload extends CloudSemanticEntityPayload {
  CloudAttachmentEntityPayload({
    required this.logicalEntityKeyHash,
    required this.canonicalGuid,
    required this.ownerLogicalKeyHash,
    required this.ownerCanonicalGuid,
    required this.ownerPart,
    required this.fileName,
    required this.mimeType,
    required this.protectedLocalReference,
  }) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_attachment_payload_logical_key_invalid');
    }
    if (canonicalGuid.isEmpty || ownerCanonicalGuid.isEmpty || ownerPart < 0) {
      throw ArgumentError(
        'cloud_attachment_payload_canonical_identity_invalid',
      );
    }
    if (ownerLogicalKeyHash.isEmpty) {
      throw ArgumentError('cloud_attachment_payload_owner_key_invalid');
    }
    if (protectedLocalReference.isEmpty) {
      throw ArgumentError('cloud_attachment_payload_reference_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String canonicalGuid;
  final String ownerLogicalKeyHash;
  final String ownerCanonicalGuid;
  final int ownerPart;
  final String fileName;
  final String? mimeType;
  final String protectedLocalReference;

  @override
  CloudEntityKind get kind => CloudEntityKind.attachment;
}

final class CloudReactionEntityPayload extends CloudSemanticEntityPayload {
  CloudReactionEntityPayload({
    required this.logicalEntityKeyHash,
    required this.canonicalGuid,
    required this.parentLogicalKeyHash,
    required this.parentCanonicalGuid,
    required this.parentPart,
    required this.senderHandle,
    required this.reactionType,
    this.associatedEmoji,
  }) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_reaction_payload_logical_key_invalid');
    }
    if (canonicalGuid.isEmpty ||
        parentCanonicalGuid.isEmpty ||
        (parentPart != null && parentPart! < 0)) {
      throw ArgumentError('cloud_reaction_payload_canonical_identity_invalid');
    }
    if (parentLogicalKeyHash.isEmpty) {
      throw ArgumentError('cloud_reaction_payload_parent_key_invalid');
    }
    if (reactionType.isEmpty) {
      throw ArgumentError('cloud_reaction_payload_type_invalid');
    }
    final baseType = reactionType.startsWith('-')
        ? reactionType.substring(1)
        : reactionType;
    if ((baseType == 'emoji') !=
        (associatedEmoji != null && associatedEmoji!.isNotEmpty)) {
      throw ArgumentError('cloud_reaction_payload_emoji_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String canonicalGuid;
  final String parentLogicalKeyHash;
  final String parentCanonicalGuid;
  final int? parentPart;
  final String senderHandle;
  final String reactionType;
  final String? associatedEmoji;

  @override
  CloudEntityKind get kind => CloudEntityKind.reaction;
}

final class CloudProfileEntityPayload extends CloudSemanticEntityPayload {
  CloudProfileEntityPayload({
    required this.logicalEntityKeyHash,
    required this.displayName,
    required this.handle,
    Uint8List? avatarBytes,
  }) : avatarBytes = avatarBytes == null
           ? null
           : Uint8List.fromList(avatarBytes) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_profile_payload_logical_key_invalid');
    }
    if (handle.isEmpty) {
      throw ArgumentError('cloud_profile_payload_handle_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String? displayName;
  final String handle;
  final Uint8List? avatarBytes;

  @override
  CloudEntityKind get kind => CloudEntityKind.sharedProfile;
}

final class CloudGroupPhotoEntityPayload extends CloudSemanticEntityPayload {
  CloudGroupPhotoEntityPayload({
    required this.logicalEntityKeyHash,
    required this.ownerLogicalKeyHash,
    required this.photoGuid,
    required this.protectedLocalReference,
  }) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_group_photo_payload_logical_key_invalid');
    }
    if (ownerLogicalKeyHash.isEmpty) {
      throw ArgumentError('cloud_group_photo_payload_owner_key_invalid');
    }
    if (photoGuid.isEmpty) {
      throw ArgumentError(
        'cloud_group_photo_payload_canonical_identity_invalid',
      );
    }
    if (protectedLocalReference.isEmpty) {
      throw ArgumentError('cloud_group_photo_payload_reference_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String ownerLogicalKeyHash;
  final String photoGuid;
  final String protectedLocalReference;

  @override
  CloudEntityKind get kind => CloudEntityKind.groupPhoto;
}

/// In-memory output of the future native semantic decoder.
///
/// [snapshot] is content-free durable merge metadata. [payload] is transient
/// user-visible data and must flow only into the canonical entity adapter.
class CloudDecodedMutation {
  factory CloudDecodedMutation.upsert({
    required CloudSyncScope scope,
    required int generation,
    required String changeId,
    required CloudSemanticSnapshot snapshot,
    required CloudSemanticEntityPayload payload,
  }) {
    if (generation <= 0) {
      throw ArgumentError('cloud_decoded_mutation_generation_invalid');
    }
    if (changeId.isEmpty) {
      throw ArgumentError('cloud_decoded_mutation_change_id_invalid');
    }
    if (snapshot.kind != payload.kind) {
      throw ArgumentError('cloud_decoded_mutation_kind_mismatch');
    }
    if (snapshot.logicalEntityKeyHash != payload.logicalEntityKeyHash) {
      throw ArgumentError('cloud_decoded_mutation_logical_key_mismatch');
    }
    return CloudDecodedMutation._(
      scope: scope,
      generation: generation,
      changeId: changeId,
      kind: CloudDecodedMutationKind.upsert,
      snapshot: snapshot,
      payload: payload,
    );
  }

  factory CloudDecodedMutation.tombstone({
    required CloudSyncScope scope,
    required int generation,
    required String changeId,
    required CloudSemanticTombstone tombstone,
  }) {
    if (generation <= 0) {
      throw ArgumentError('cloud_decoded_mutation_generation_invalid');
    }
    if (changeId.isEmpty) {
      throw ArgumentError('cloud_decoded_mutation_change_id_invalid');
    }
    return CloudDecodedMutation._(
      scope: scope,
      generation: generation,
      changeId: changeId,
      kind: CloudDecodedMutationKind.tombstone,
      tombstone: tombstone,
    );
  }

  const CloudDecodedMutation._({
    required this.scope,
    required this.generation,
    required this.changeId,
    required this.kind,
    this.snapshot,
    this.payload,
    this.tombstone,
  });

  final CloudSyncScope scope;
  final int generation;
  final String changeId;
  final CloudDecodedMutationKind kind;
  final CloudSemanticSnapshot? snapshot;
  final CloudSemanticEntityPayload? payload;
  final CloudSemanticTombstone? tombstone;

  @override
  String toString() =>
      'CloudDecodedMutation(${kind.name}, generation=$generation, redacted)';
}

class CloudSemanticTombstone {
  CloudSemanticTombstone({
    required this.kind,
    required this.logicalEntityKeyHash,
    required this.deletedAt,
    required this.serverConfirmed,
  }) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_semantic_tombstone_logical_key_invalid');
    }
  }

  final CloudEntityKind kind;
  final String logicalEntityKeyHash;

  /// Server deletion time when CloudKit supplied embedded record metadata.
  ///
  /// Valid zone tombstones may omit that metadata. A missing time must not be
  /// replaced with local wall time because doing so could erase a newer local
  /// mutation.
  final DateTime? deletedAt;
  final bool serverConfirmed;
}

abstract interface class CloudSemanticDecoder {
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry);
}

class CloudSemanticDecodeFailure implements Exception {
  const CloudSemanticDecodeFailure(this.category);

  final CloudFailureCategory category;
}

/// Transactional gateway to the app's canonical local message store.
///
/// The future ObjectBox adapter must commit the semantic mutation and replay
/// marker in one transaction. Implementations must not persist plaintext
/// bodies, handles, decoder credentials, or raw account identifiers as sync
/// metadata.
abstract interface class CloudSemanticStoreGateway {
  Future<T> writeTransaction<T>({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
    required T Function(CloudSemanticStoreTransaction transaction) action,
  });
}

abstract interface class CloudSemanticStoreTransaction {
  CloudSyncScope get activeScope;
  int get activeGeneration;

  bool hasAppliedChange(String changeId);

  CloudSemanticSnapshot? readSnapshot({
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  });

  bool entityExists({
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  });

  /// Binds the current inbox record to one canonical logical identity.
  ///
  /// The durable gateway must update the protected record map in the same
  /// transaction as the canonical mutation, snapshot, replay outcome, and
  /// inbox terminal state. A conflicting mapping must fail closed.
  void bindRecordIdentity({
    required String logicalEntityKeyHash,
    String? encryptedRawRecordReference,
  });

  /// Applies the transient payload to the canonical app entity and stores its
  /// content-free merge snapshot in the same transaction.
  void applyEntity({
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  });

  void applyTombstone(CloudSemanticTombstone tombstone);

  void markChangeApplied(String changeId);

  void quarantineChange(String changeId, String safeCode);

  void recordConflict(String changeId, String safeCode);
}

class TransactionalCloudInboxApplier implements CloudInboxApplier {
  const TransactionalCloudInboxApplier({
    required this._decoder,
    required this._store,
    this._mergePolicy = const CloudMergePolicy(),
    this._allowTombstones = false,
  });

  final CloudSemanticDecoder _decoder;
  final CloudSemanticStoreGateway _store;
  final CloudMergePolicy _mergePolicy;
  final bool _allowTombstones;

  @override
  Future<CloudInboxApplyResult> apply(
    CloudInboxEntry entry, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    final CloudDecodedMutation decoded;
    try {
      decoded = await _decoder.decode(entry);
    } on CloudSemanticDecodeFailure catch (failure) {
      if (failure.category.isRetryable) {
        return CloudInboxApplyResult.retryable(
          failureCategory: failure.category,
        );
      }
      return CloudInboxApplyResult.quarantined(
        failureCategory: failure.category,
      );
    } catch (_) {
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.unknown,
      );
    }

    if (decoded.scope != entry.scope ||
        decoded.generation != entry.generation ||
        decoded.changeId != entry.change.changeId) {
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.conflict,
      );
    }
    final decodedAsTombstone =
        decoded.kind == CloudDecodedMutationKind.tombstone;
    if (decodedAsTombstone != entry.change.isTombstone ||
        decodedAsTombstone != (entry.change.type == CloudChangeType.delete)) {
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.malformedRecord,
      );
    }
    if (!decodedAsTombstone) {
      final snapshot = decoded.snapshot;
      final payload = decoded.payload;
      if (snapshot == null ||
          payload == null ||
          snapshot.kind != payload.kind ||
          snapshot.logicalEntityKeyHash != payload.logicalEntityKeyHash) {
        return const CloudInboxApplyResult.quarantined(
          failureCategory: CloudFailureCategory.malformedRecord,
        );
      }
    } else if (decoded.tombstone == null ||
        decoded.snapshot != null ||
        decoded.payload != null) {
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.malformedRecord,
      );
    }
    if (decodedAsTombstone && !_allowTombstones) {
      return const CloudInboxApplyResult.deferred();
    }

    try {
      return await _store.writeTransaction(
        entry: entry,
        leaseFence: leaseFence,
        action: (transaction) {
          if (transaction.activeScope != entry.scope ||
              transaction.activeGeneration != entry.generation) {
            return const CloudInboxApplyResult.quarantined(
              failureCategory: CloudFailureCategory.conflict,
            );
          }
          if (transaction.hasAppliedChange(decoded.changeId)) {
            transaction.markChangeApplied(decoded.changeId);
            return const CloudInboxApplyResult.applied(
              inboxStatusPersisted: true,
            );
          }

          return switch (decoded.kind) {
            CloudDecodedMutationKind.upsert => _applyUpsert(
              transaction,
              decoded,
            ),
            CloudDecodedMutationKind.tombstone => _applyTombstone(
              transaction,
              decoded,
            ),
          };
        },
      );
    } on CloudSyncFailure catch (failure) {
      if (failure.category.isRetryable) {
        return CloudInboxApplyResult.retryable(
          failureCategory: failure.category,
          retryAfter: failure.retryAfter,
        );
      }
      return CloudInboxApplyResult.quarantined(
        failureCategory: failure.category,
      );
    } catch (_) {
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.unknown,
      );
    }
  }

  CloudInboxApplyResult _applyUpsert(
    CloudSemanticStoreTransaction transaction,
    CloudDecodedMutation decoded,
  ) {
    final incoming = decoded.snapshot!;
    final local = transaction.readSnapshot(
      kind: incoming.kind,
      logicalEntityKeyHash: incoming.logicalEntityKeyHash,
    );
    final decision = _mergePolicy.merge(
      local: local,
      incoming: incoming,
      parentExists:
          incoming.parentLogicalKeyHash == null ||
          transaction.entityExists(
            kind: _parentKind(incoming.kind),
            logicalEntityKeyHash: incoming.parentLogicalKeyHash!,
          ),
    );

    if (decision.action == CloudMergeAction.defer) {
      return const CloudInboxApplyResult.deferred();
    }

    if (decision.action == CloudMergeAction.quarantine ||
        decision.conflicts.contains(
          CloudMergeConflict.immutableContentMismatch,
        ) ||
        decision.conflicts.contains(CloudMergeConflict.editRevisionMismatch)) {
      transaction.quarantineChange(
        decoded.changeId,
        _conflictCode(decision.conflicts),
      );
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.conflict,
        inboxStatusPersisted: true,
      );
    }

    if (decision.conflicts.contains(
      CloudMergeConflict.equalGroupVersionMismatch,
    )) {
      transaction.bindRecordIdentity(
        logicalEntityKeyHash: incoming.logicalEntityKeyHash,
        encryptedRawRecordReference: incoming.encryptedRawRecordReference,
      );
      transaction.recordConflict(
        decoded.changeId,
        'equal_group_version_mismatch',
      );
      transaction.markChangeApplied(decoded.changeId);
      return const CloudInboxApplyResult.applied(inboxStatusPersisted: true);
    }

    if (decision.action == CloudMergeAction.create ||
        decision.action == CloudMergeAction.update) {
      transaction.applyEntity(
        payload: decoded.payload!,
        snapshot: decision.snapshot!,
      );
    } else {
      transaction.bindRecordIdentity(
        logicalEntityKeyHash: incoming.logicalEntityKeyHash,
        encryptedRawRecordReference: incoming.encryptedRawRecordReference,
      );
    }
    transaction.markChangeApplied(decoded.changeId);
    return const CloudInboxApplyResult.applied(inboxStatusPersisted: true);
  }

  CloudEntityKind _parentKind(CloudEntityKind kind) => switch (kind) {
    CloudEntityKind.message => CloudEntityKind.chat,
    CloudEntityKind.attachment ||
    CloudEntityKind.reaction => CloudEntityKind.message,
    CloudEntityKind.groupPhoto => CloudEntityKind.chat,
    _ => throw StateError('cloud_semantic_parent_kind_invalid'),
  };

  CloudInboxApplyResult _applyTombstone(
    CloudSemanticStoreTransaction transaction,
    CloudDecodedMutation decoded,
  ) {
    final tombstone = decoded.tombstone!;
    if (!tombstone.serverConfirmed) {
      transaction.quarantineChange(decoded.changeId, 'unconfirmed_tombstone');
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.conflict,
        inboxStatusPersisted: true,
      );
    }
    if (tombstone.deletedAt == null) {
      return const CloudInboxApplyResult.deferred();
    }

    final local = transaction.readSnapshot(
      kind: tombstone.kind,
      logicalEntityKeyHash: tombstone.logicalEntityKeyHash,
    );
    final latestLocalMutation = _latestMutation(local);
    if (latestLocalMutation != null &&
        tombstone.deletedAt!.isBefore(latestLocalMutation)) {
      transaction.recordConflict(decoded.changeId, 'stale_tombstone');
      transaction.markChangeApplied(decoded.changeId);
      return const CloudInboxApplyResult.applied(inboxStatusPersisted: true);
    }

    transaction.applyTombstone(tombstone);
    transaction.markChangeApplied(decoded.changeId);
    return const CloudInboxApplyResult.applied(inboxStatusPersisted: true);
  }

  DateTime? _latestMutation(CloudSemanticSnapshot? snapshot) {
    if (snapshot == null) return null;
    final candidates = <DateTime>[
      if (snapshot.createdAt != null) snapshot.createdAt!,
      if (snapshot.readAt != null) snapshot.readAt!,
      if (snapshot.deliveredAt != null) snapshot.deliveredAt!,
      if (snapshot.retractedAt != null) snapshot.retractedAt!,
      ...snapshot.editParts.values.map((part) => part.modifiedAt),
    ];
    if (candidates.isEmpty) return null;
    return candidates.reduce(
      (current, candidate) => candidate.isAfter(current) ? candidate : current,
    );
  }

  String _conflictCode(Set<CloudMergeConflict> conflicts) {
    if (conflicts.contains(CloudMergeConflict.immutableContentMismatch)) {
      return 'immutable_content_mismatch';
    }
    if (conflicts.contains(CloudMergeConflict.editRevisionMismatch)) {
      return 'edit_revision_mismatch';
    }
    return 'semantic_conflict';
  }
}
