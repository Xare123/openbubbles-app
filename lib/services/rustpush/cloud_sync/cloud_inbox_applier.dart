import 'dart:typed_data';

import 'cloud_attachment_provenance.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_semantic_diagnostics.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';

enum CloudDecodedMutationKind { upsert, tombstone }

enum CloudSemanticFieldState { absent, value, explicitClear }

enum CloudSemanticService { iMessage, sms }

enum CloudSemanticChatStyle { direct, group }

enum CloudSemanticAssociationKind { none, sticker, reactionAdd, reactionRemove }

final class CloudSemanticKnownMessageFlags {
  const CloudSemanticKnownMessageFlags({
    required this.fromMe,
    required this.delivered,
    required this.read,
    required this.hasDataDetectorResults,
    required this.deliveredQuietly,
    required this.didNotifyRecipient,
  });

  final bool fromMe;
  final bool delivered;
  final bool read;
  final bool hasDataDetectorResults;
  final bool deliveredQuietly;
  final bool didNotifyRecipient;

  @override
  String toString() => 'CloudSemanticKnownMessageFlags(redacted)';
}

final class CloudSemanticTextRun {
  CloudSemanticTextRun({
    required this.startUtf16,
    required this.lengthUtf16,
    required this.messagePart,
    required this.attachmentCanonicalGuid,
    required this.attachmentLogicalKeyHash,
    required this.mentionHandle,
    required this.audioTranscript,
    required this.textEffect,
    required this.bold,
    required this.italic,
    required this.strikethrough,
    required this.underline,
  }) {
    if (startUtf16 < 0 || lengthUtf16 < 0) {
      throw ArgumentError('cloud_text_run_range_invalid');
    }
    if ((attachmentCanonicalGuid == null) !=
        (attachmentLogicalKeyHash == null)) {
      throw ArgumentError('cloud_text_run_attachment_identity_invalid');
    }
  }

  final int startUtf16;
  final int lengthUtf16;
  final int? messagePart;
  final String? attachmentCanonicalGuid;
  final String? attachmentLogicalKeyHash;
  final String? mentionHandle;
  final String? audioTranscript;
  final int? textEffect;
  final bool? bold;
  final bool? italic;
  final bool? strikethrough;
  final bool? underline;

  @override
  String toString() => 'CloudSemanticTextRun(redacted)';
}

final class CloudSemanticAttributedBody {
  CloudSemanticAttributedBody({
    required this.text,
    required Iterable<CloudSemanticTextRun> runs,
  }) : runs = List.unmodifiable(runs);

  final String text;
  final List<CloudSemanticTextRun> runs;

  @override
  String toString() => 'CloudSemanticAttributedBody(redacted)';
}

final class CloudSemanticMessageEdit {
  CloudSemanticMessageEdit({
    required this.part,
    required this.revision,
    required Iterable<CloudSemanticAttributedBody> bodies,
    required this.modifiedAt,
    required this.originalRangeLocation,
    required this.originalRangeLength,
  }) : bodies = List.unmodifiable(bodies) {
    if (part < 0 ||
        revision < 0 ||
        bodies.isEmpty ||
        (originalRangeLocation == null) != (originalRangeLength == null)) {
      throw ArgumentError('cloud_message_edit_invalid');
    }
  }

  final int part;
  final int revision;
  final List<CloudSemanticAttributedBody> bodies;
  final DateTime modifiedAt;
  final int? originalRangeLocation;
  final int? originalRangeLength;

  @override
  String toString() => 'CloudSemanticMessageEdit(redacted)';
}

void _validateSemanticField(
  CloudSemanticFieldState state,
  Object? value,
  String safeFieldName,
) {
  if ((state == CloudSemanticFieldState.value) != (value != null)) {
    throw ArgumentError('cloud_semantic_${safeFieldName}_presence_invalid');
  }
}

void _validateSemanticCollectionField(
  CloudSemanticFieldState state,
  List<Object?> value,
  String safeFieldName,
) {
  if (state != CloudSemanticFieldState.value && value.isNotEmpty) {
    throw ArgumentError('cloud_semantic_${safeFieldName}_presence_invalid');
  }
}

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
    required this.chatAliasKeyHash,
    required this.chatIdentifier,
    this.chatIdExactGuidLogicalKeyHash,
    this.chatIdBareDirectServiceIdentifierAliasKeyHash,
    Iterable<CloudSemanticChatAlias> chatIdAliasCandidates = const [],
    this.msgProto4GroupIdAliasKeyHash,
    required this.body,
    required this.senderHandle,
    this.createdAt,
    this.error,
    this.service,
    this.subjectState = CloudSemanticFieldState.absent,
    this.subject,
    this.bodyState = CloudSemanticFieldState.value,
    this.attributedBodiesState = CloudSemanticFieldState.absent,
    Iterable<CloudSemanticAttributedBody> attributedBodies = const [],
    this.balloonBundleIdState = CloudSemanticFieldState.absent,
    this.balloonBundleId,
    this.decodedExtensionPayloadState = CloudSemanticFieldState.absent,
    Uint8List? decodedExtensionPayload,
    this.effectState = CloudSemanticFieldState.absent,
    this.effect,
    this.readAtState = CloudSemanticFieldState.absent,
    this.readAt,
    this.deliveredAtState = CloudSemanticFieldState.absent,
    this.deliveredAt,
    this.knownFlags,
    this.associationKind = CloudSemanticAssociationKind.none,
    this.associationParentLogicalKeyHash,
    this.associationParentCanonicalGuid,
    this.associationParentPart,
    this.associatedRangeLocation,
    this.associatedRangeLength,
    this.replyParentLogicalKeyHash,
    this.replyParentCanonicalGuid,
    this.replyParentPart,
    this.editsState = CloudSemanticFieldState.absent,
    Iterable<CloudSemanticMessageEdit> edits = const [],
    this.retractedPartsState = CloudSemanticFieldState.absent,
    Iterable<int> retractedParts = const [],
  }) : chatIdAliasCandidates = List.unmodifiable(chatIdAliasCandidates),
       attributedBodies = List.unmodifiable(attributedBodies),
       decodedExtensionPayload = decodedExtensionPayload == null
           ? null
           : Uint8List.fromList(decodedExtensionPayload),
       edits = List.unmodifiable(edits),
       retractedParts = List.unmodifiable(retractedParts) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_message_payload_logical_key_invalid');
    }
    if (canonicalGuid.isEmpty || chatIdentifier.isEmpty) {
      throw ArgumentError('cloud_message_payload_canonical_identity_invalid');
    }
    if (chatAliasKeyHash.isEmpty) {
      throw ArgumentError('cloud_message_payload_chat_key_invalid');
    }
    final candidateKinds = <CloudSemanticChatAliasKind>{};
    final candidateKeys = <(CloudSemanticChatAliasKind, String)>{};
    for (final candidate in this.chatIdAliasCandidates) {
      if (candidate.keyHash.isEmpty ||
          !candidateKinds.add(candidate.kind) ||
          !candidateKeys.add((candidate.kind, candidate.keyHash))) {
        throw ArgumentError('cloud_message_payload_chat_candidates_invalid');
      }
    }
    final hasTypedReferences = this.chatIdAliasCandidates.isNotEmpty;
    if (hasTypedReferences != (chatIdExactGuidLogicalKeyHash != null) ||
        (hasTypedReferences &&
            (this.chatIdAliasCandidates.length !=
                    CloudSemanticChatAliasKind.values.length ||
                candidateKinds.length !=
                    CloudSemanticChatAliasKind.values.length ||
                !candidateKinds.containsAll(
                  CloudSemanticChatAliasKind.values,
                ))) ||
        (chatIdExactGuidLogicalKeyHash?.isEmpty ?? false) ||
        (chatIdBareDirectServiceIdentifierAliasKeyHash?.isEmpty ?? false) ||
        (chatIdBareDirectServiceIdentifierAliasKeyHash != null &&
            !hasTypedReferences) ||
        (msgProto4GroupIdAliasKeyHash?.isEmpty ?? false) ||
        (msgProto4GroupIdAliasKeyHash != null && !hasTypedReferences)) {
      throw ArgumentError('cloud_message_payload_chat_reference_invalid');
    }
    if (hasTypedReferences) {
      final serviceIdentifierCandidate = this.chatIdAliasCandidates.singleWhere(
        (candidate) =>
            candidate.kind == CloudSemanticChatAliasKind.serviceIdentifier,
      );
      if (serviceIdentifierCandidate.keyHash != chatAliasKeyHash) {
        throw ArgumentError('cloud_message_payload_chat_reference_invalid');
      }
    }
    _validateSemanticField(subjectState, subject, 'subject');
    _validateSemanticField(bodyState, body, 'body');
    _validateSemanticCollectionField(
      attributedBodiesState,
      this.attributedBodies,
      'attributed_bodies',
    );
    _validateSemanticField(
      balloonBundleIdState,
      balloonBundleId,
      'balloon_bundle_id',
    );
    _validateSemanticField(
      decodedExtensionPayloadState,
      this.decodedExtensionPayload,
      'decoded_extension_payload',
    );
    _validateSemanticField(effectState, effect, 'effect');
    _validateSemanticField(readAtState, readAt, 'read_at');
    _validateSemanticField(deliveredAtState, deliveredAt, 'delivered_at');
    _validateSemanticCollectionField(editsState, this.edits, 'edits');
    _validateSemanticCollectionField(
      retractedPartsState,
      this.retractedParts,
      'retracted_parts',
    );
    if ((replyParentCanonicalGuid == null) != (replyParentPart == null) ||
        (replyParentCanonicalGuid == null) !=
            (replyParentLogicalKeyHash == null)) {
      throw ArgumentError('cloud_message_payload_reply_identity_invalid');
    }
    final hasAssociationParent = associationParentCanonicalGuid != null;
    if (hasAssociationParent != (associationParentLogicalKeyHash != null) ||
        (associationKind == CloudSemanticAssociationKind.none &&
            hasAssociationParent) ||
        (associationKind != CloudSemanticAssociationKind.none &&
            !hasAssociationParent) ||
        (!hasAssociationParent &&
            (associationParentPart != null ||
                associatedRangeLocation != null ||
                associatedRangeLength != null)) ||
        (associatedRangeLocation == null) != (associatedRangeLength == null)) {
      throw ArgumentError('cloud_message_payload_association_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String canonicalGuid;
  final String chatAliasKeyHash;
  final String chatIdentifier;
  final String? chatIdExactGuidLogicalKeyHash;
  final String? chatIdBareDirectServiceIdentifierAliasKeyHash;
  final List<CloudSemanticChatAlias> chatIdAliasCandidates;
  final String? msgProto4GroupIdAliasKeyHash;
  final String? body;
  final String senderHandle;
  final DateTime? createdAt;
  final int? error;
  final CloudSemanticService? service;
  final CloudSemanticFieldState subjectState;
  final String? subject;
  final CloudSemanticFieldState bodyState;
  final CloudSemanticFieldState attributedBodiesState;
  final List<CloudSemanticAttributedBody> attributedBodies;
  final CloudSemanticFieldState balloonBundleIdState;
  final String? balloonBundleId;
  final CloudSemanticFieldState decodedExtensionPayloadState;
  final Uint8List? decodedExtensionPayload;
  final CloudSemanticFieldState effectState;
  final String? effect;
  final CloudSemanticFieldState readAtState;
  final DateTime? readAt;
  final CloudSemanticFieldState deliveredAtState;
  final DateTime? deliveredAt;
  final CloudSemanticKnownMessageFlags? knownFlags;
  final CloudSemanticAssociationKind associationKind;
  final String? associationParentLogicalKeyHash;
  final String? associationParentCanonicalGuid;
  final int? associationParentPart;
  final int? associatedRangeLocation;
  final int? associatedRangeLength;
  final String? replyParentLogicalKeyHash;
  final String? replyParentCanonicalGuid;
  final String? replyParentPart;
  final CloudSemanticFieldState editsState;
  final List<CloudSemanticMessageEdit> edits;
  final CloudSemanticFieldState retractedPartsState;
  final List<int> retractedParts;

  @override
  CloudEntityKind get kind => CloudEntityKind.message;
}

enum CloudSemanticChatAliasKind {
  groupId,
  originalGroupId,
  serviceIdentifier,
  legacyGroupIdentifier,
}

final class CloudSemanticChatAlias {
  const CloudSemanticChatAlias({required this.kind, required this.keyHash});

  final CloudSemanticChatAliasKind kind;
  final String keyHash;
}

final class CloudChatEntityPayload extends CloudSemanticEntityPayload {
  CloudChatEntityPayload({
    required this.logicalEntityKeyHash,
    required this.canonicalGuid,
    required this.chatIdentifier,
    required this.displayName,
    required Iterable<String> participantHandles,
    Iterable<CloudSemanticChatAlias> aliases = const [],
    this.groupId,
    this.originalGroupId,
    this.service,
    this.style,
    CloudSemanticFieldState? displayNameState,
    this.lastAddressedHandleState = CloudSemanticFieldState.absent,
    this.lastAddressedHandle,
    this.groupVersionState = CloudSemanticFieldState.absent,
    this.groupVersion,
    this.lastSeenMessageGuidState = CloudSemanticFieldState.absent,
    this.lastSeenMessageGuid,
    this.groupPhotoGuidState = CloudSemanticFieldState.absent,
    this.groupPhotoGuid,
  }) : aliases = List.unmodifiable(aliases),
       displayNameState =
           displayNameState ??
           (displayName == null
               ? CloudSemanticFieldState.absent
               : CloudSemanticFieldState.value),
       participantHandles = List.unmodifiable(participantHandles) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_chat_payload_logical_key_invalid');
    }
    if (canonicalGuid.isEmpty || chatIdentifier.isEmpty) {
      throw ArgumentError('cloud_chat_payload_canonical_identity_invalid');
    }
    if (this.participantHandles.any((handle) => handle.isEmpty)) {
      throw ArgumentError('cloud_chat_payload_participant_invalid');
    }
    final aliasKeys = <(CloudSemanticChatAliasKind, String)>{};
    for (final alias in this.aliases) {
      if (alias.keyHash.isEmpty ||
          !aliasKeys.add((alias.kind, alias.keyHash))) {
        throw ArgumentError('cloud_chat_payload_alias_invalid');
      }
    }
    _validateSemanticField(this.displayNameState, displayName, 'display_name');
    _validateSemanticField(
      lastAddressedHandleState,
      lastAddressedHandle,
      'last_addressed_handle',
    );
    _validateSemanticField(groupVersionState, groupVersion, 'group_version');
    _validateSemanticField(
      lastSeenMessageGuidState,
      lastSeenMessageGuid,
      'last_seen_message_guid',
    );
    _validateSemanticField(
      groupPhotoGuidState,
      groupPhotoGuid,
      'group_photo_guid',
    );
  }

  @override
  final String logicalEntityKeyHash;
  final String canonicalGuid;
  final String chatIdentifier;
  final String? groupId;
  final String? originalGroupId;
  final List<CloudSemanticChatAlias> aliases;
  final CloudSemanticService? service;
  final CloudSemanticChatStyle? style;
  final CloudSemanticFieldState displayNameState;
  final String? displayName;
  final List<String> participantHandles;
  final CloudSemanticFieldState lastAddressedHandleState;
  final String? lastAddressedHandle;
  final CloudSemanticFieldState groupVersionState;
  final int? groupVersion;
  final CloudSemanticFieldState lastSeenMessageGuidState;
  final String? lastSeenMessageGuid;
  final CloudSemanticFieldState groupPhotoGuidState;
  final String? groupPhotoGuid;

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
    required this.bodyCapability,
    required this.protectedLocalReference,
    this.utiState = CloudSemanticFieldState.absent,
    this.uti,
    this.fileNameState = CloudSemanticFieldState.value,
    CloudSemanticFieldState? mimeTypeState,
    this.totalBytesState = CloudSemanticFieldState.absent,
    this.totalBytes,
    this.isOutgoingState = CloudSemanticFieldState.absent,
    this.isOutgoing,
    this.protectedLocalReferenceState = CloudSemanticFieldState.value,
  }) : mimeTypeState =
           mimeTypeState ??
           (mimeType == null
               ? CloudSemanticFieldState.absent
               : CloudSemanticFieldState.value) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_attachment_payload_logical_key_invalid');
    }
    if (canonicalGuid.isEmpty ||
        (ownerCanonicalGuid != null && ownerCanonicalGuid!.isEmpty) ||
        (ownerPart != null && ownerPart! < 0)) {
      throw ArgumentError(
        'cloud_attachment_payload_canonical_identity_invalid',
      );
    }
    final ownerParts = [
      ownerLogicalKeyHash != null,
      ownerCanonicalGuid != null,
      ownerPart != null,
    ];
    if (ownerParts.any((present) => present) &&
        !ownerParts.every((present) => present)) {
      throw ArgumentError('cloud_attachment_payload_owner_identity_invalid');
    }
    if (ownerLogicalKeyHash?.isEmpty ?? false) {
      throw ArgumentError('cloud_attachment_payload_owner_key_invalid');
    }
    _validateSemanticField(utiState, uti, 'uti');
    _validateSemanticField(fileNameState, fileName, 'file_name');
    _validateSemanticField(this.mimeTypeState, mimeType, 'mime_type');
    _validateSemanticField(totalBytesState, totalBytes, 'total_bytes');
    _validateSemanticField(isOutgoingState, isOutgoing, 'is_outgoing');
    _validateSemanticField(
      protectedLocalReferenceState,
      protectedLocalReference,
      'protected_local_reference',
    );
    if (protectedLocalReference?.isEmpty ?? false) {
      throw ArgumentError('cloud_attachment_payload_reference_invalid');
    }
  }

  @override
  final String logicalEntityKeyHash;
  final String canonicalGuid;
  final String? ownerLogicalKeyHash;
  final String? ownerCanonicalGuid;
  final int? ownerPart;
  final CloudSemanticFieldState utiState;
  final String? uti;
  final CloudSemanticFieldState fileNameState;
  final String? fileName;
  final CloudSemanticFieldState mimeTypeState;
  final String? mimeType;
  final CloudAttachmentBodyCapability bodyCapability;
  final CloudSemanticFieldState totalBytesState;
  final int? totalBytes;
  final CloudSemanticFieldState isOutgoingState;
  final bool? isOutgoing;
  final CloudSemanticFieldState protectedLocalReferenceState;
  final String? protectedLocalReference;

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
    this.createdAt,
    this.error,
    this.service,
    this.knownFlags,
    this.readAtState = CloudSemanticFieldState.absent,
    this.readAt,
    this.deliveredAtState = CloudSemanticFieldState.absent,
    this.deliveredAt,
    this.associatedRangeLocation,
    this.associatedRangeLength,
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
    if ((associatedRangeLocation == null) != (associatedRangeLength == null)) {
      throw ArgumentError('cloud_reaction_payload_range_invalid');
    }
    _validateSemanticField(readAtState, readAt, 'reaction_read_at');
    _validateSemanticField(
      deliveredAtState,
      deliveredAt,
      'reaction_delivered_at',
    );
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
  final DateTime? createdAt;
  final int? error;
  final CloudSemanticService? service;
  final CloudSemanticKnownMessageFlags? knownFlags;
  final CloudSemanticFieldState readAtState;
  final DateTime? readAt;
  final CloudSemanticFieldState deliveredAtState;
  final DateTime? deliveredAt;
  final int? associatedRangeLocation;
  final int? associatedRangeLength;

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

abstract interface class CloudTransientCanonicalIdentityLease {
  void release();
}

/// Installs the plaintext canonical identities for exactly one decoded
/// mutation while its synchronous ObjectBox transaction is active.
///
/// Implementations must remain memory-only and clear every identity when the
/// returned lease is released.
abstract interface class CloudTransientCanonicalIdentityRegistrar {
  CloudTransientCanonicalIdentityLease bind(CloudDecodedMutation mutation);
}

class CloudSemanticDecodeFailure implements Exception {
  const CloudSemanticDecodeFailure(this.category, {this.safeCode});

  final CloudFailureCategory category;
  final String? safeCode;
}

/// A successful, content-free native classification that deliberately has no
/// canonical mutation. This is separate from [CloudSemanticDecodeFailure] so
/// an unknown or malformed service can never be mistaken for an allowed
/// out-of-scope record.
final class CloudSemanticOutOfScopeServiceDisposition implements Exception {
  const CloudSemanticOutOfScopeServiceDisposition(this.service);

  final CloudSemanticOutOfScopeService service;

  String get safeCode => service.safeCode;
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

/// Optional local-only repair surface for a projection bug discovered after
/// an inbox change was already committed. Implementations must leave the
/// checkpoint, inbox terminal state, replay record, and record map unchanged.
abstract interface class CloudAppliedProjectionRepairStoreGateway {
  Future<List<CloudInboxEntry>> readAppliedProjectionRepairCandidates({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  });

  Future<void> repairAppliedProjection({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  });
}

/// Optional capability used by the manual semantic Canary before it processes
/// the pending prefix. It re-decodes only durable applied rows selected by the
/// store and cannot fetch, save, delete, or move a CloudKit checkpoint.
abstract interface class CloudAppliedProjectionRepairer {
  Future<int> repairAppliedProjections({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  });
}

/// Durable storage half of [CloudRetainedProjectionReprocessor]. Candidate
/// selection is read-only. The write method must fence the exact retained row
/// and roll all local projection writes back if [action] throws.
abstract interface class CloudRetainedProjectionStoreGateway {
  Future<List<CloudInboxEntry>> readRetainedProjectionCandidates({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  });

  Future<T> writeRetainedProjectionTransaction<T>({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
    required T Function(CloudSemanticStoreTransaction transaction) action,
  });

  /// Records one unsuccessful local reprojection attempt without changing the
  /// retained status, checkpoint, protected references, or canonical state.
  /// Implementations must fence the exact row and durably move it behind rows
  /// that have not been attempted as recently.
  Future<void> recordRetainedProjectionFailure({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
  });

  /// Reclassifies exactly one retained save after the current native decoder
  /// proves it is an intentionally unsupported service. The row remains
  /// retained and terminal, no replay or canonical entity is written, and the
  /// exact-applied checkpoint floor must not advance.
  Future<void> recordRetainedProjectionOutOfScopeService({
    required CloudInboxEntry entry,
    required CloudCoordinatorLeaseFence leaseFence,
  });
}

/// Sequence-bounded retained-save reader used only after the same native
/// writer-pause session has persisted a terminal remote-head report.
///
/// Candidate selection must be ordered strictly by fetch sequence and must
/// exclude tombstones. Failure rotation timestamps are deliberately ignored
/// so one sweep can prove that every save in its immutable bound was examined
/// at most once.
abstract interface class CloudRetainedProjectionWindowStoreGateway {
  Future<List<CloudInboxEntry>> readRetainedProjectionWindow({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int afterFetchSequence,
    required int throughFetchSequence,
    required int limit,
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

class TransactionalCloudInboxApplier
    implements
        CloudInboxApplier,
        CloudAppliedProjectionRepairer,
        CloudRetainedProjectionReprocessor,
        CloudRetainedProjectionWindowReprocessor,
        CloudReadOnlyTombstoneAcknowledgementPolicy {
  const TransactionalCloudInboxApplier({
    required this._decoder,
    required this._store,
    this._mergePolicy = const CloudMergePolicy(),
    this._identityRegistrar,
    this._activeScopeRevalidator,
    this._allowTombstones = false,
    this._diagnosticRecorder,
  });

  final CloudSemanticDecoder _decoder;
  final CloudSemanticStoreGateway _store;
  final CloudMergePolicy _mergePolicy;
  final CloudTransientCanonicalIdentityRegistrar? _identityRegistrar;
  final Future<bool> Function()? _activeScopeRevalidator;
  final bool _allowTombstones;
  final CloudSyncSemanticDiagnosticRecorder? _diagnosticRecorder;

  @override
  bool get readOnlyTombstoneAcknowledgementsEnabled => !_allowTombstones;

  @override
  Future<CloudRetainedProjectionResult> reprojectRetainedUnprojected({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  }) async {
    final retainedStore = _store;
    final registrar = _identityRegistrar;
    if (retainedStore is! CloudRetainedProjectionStoreGateway) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'retained_projection_store_unavailable',
      );
    }
    final projectionStore =
        retainedStore as CloudRetainedProjectionStoreGateway;
    if (registrar == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'retained_projection_registrar_unavailable',
      );
    }
    if (generation <= 0 || limit <= 0 || limit > 4096) {
      throw ArgumentError('cloud_retained_projection_request_invalid');
    }

    final candidates = await projectionStore.readRetainedProjectionCandidates(
      scope: scope,
      generation: generation,
      leaseFence: leaseFence,
      limit: limit,
    );
    final counts = await _reprojectRetainedCandidates(
      scope: scope,
      generation: generation,
      leaseFence: leaseFence,
      projectionStore: projectionStore,
      registrar: registrar,
      candidates: candidates,
    );
    // A row proven out of scope remains physically retained but disappears
    // from the eligible candidate query. Re-read the fenced candidate surface
    // instead of inferring work from the physical retained count.
    final hasRemaining =
        (await projectionStore.readRetainedProjectionCandidates(
          scope: scope,
          generation: generation,
          leaseFence: leaseFence,
          limit: 1,
        )).isNotEmpty;
    if (hasRemaining) {
      _recordDiagnostic('retained_projection_has_remaining');
    }
    return CloudRetainedProjectionResult(
      examined: counts.examined,
      reprojected: counts.reprojected,
      retained: counts.retained,
      hasRemaining: hasRemaining,
    );
  }

  @override
  Future<CloudRetainedProjectionWindowResult> reprojectRetainedSaveWindow({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int afterFetchSequence,
    required int throughFetchSequence,
    required int limit,
  }) async {
    final retainedStore = _store;
    final registrar = _identityRegistrar;
    if (retainedStore is! CloudRetainedProjectionStoreGateway ||
        retainedStore is! CloudRetainedProjectionWindowStoreGateway) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: 'retained_projection_window_store_unavailable',
      );
    }
    if (registrar == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'retained_projection_registrar_unavailable',
      );
    }
    if (generation <= 0 ||
        afterFetchSequence < 0 ||
        throughFetchSequence < afterFetchSequence ||
        limit <= 0 ||
        limit > 4096) {
      throw ArgumentError('cloud_retained_projection_window_invalid');
    }

    final projectionStore =
        retainedStore as CloudRetainedProjectionStoreGateway;
    final windowStore =
        retainedStore as CloudRetainedProjectionWindowStoreGateway;
    final candidates = await windowStore.readRetainedProjectionWindow(
      scope: scope,
      generation: generation,
      leaseFence: leaseFence,
      afterFetchSequence: afterFetchSequence,
      throughFetchSequence: throughFetchSequence,
      limit: limit,
    );
    var lastSequence = afterFetchSequence;
    for (final entry in candidates) {
      if (entry.scope != scope ||
          entry.generation != generation ||
          entry.status != CloudInboxStatus.retainedUnprojected ||
          entry.change.type != CloudChangeType.save ||
          entry.change.isTombstone ||
          entry.sequence <= lastSequence ||
          entry.sequence > throughFetchSequence) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'retained_projection_window_candidate_invalid',
        );
      }
      lastSequence = entry.sequence;
    }

    final counts = await _reprojectRetainedCandidates(
      scope: scope,
      generation: generation,
      leaseFence: leaseFence,
      projectionStore: projectionStore,
      registrar: registrar,
      candidates: candidates,
    );
    var hasMoreWithinBound = false;
    if (candidates.length == limit) {
      hasMoreWithinBound = (await windowStore.readRetainedProjectionWindow(
        scope: scope,
        generation: generation,
        leaseFence: leaseFence,
        afterFetchSequence: lastSequence,
        throughFetchSequence: throughFetchSequence,
        limit: 1,
      )).isNotEmpty;
    }
    if (hasMoreWithinBound) {
      _recordDiagnostic('retained_projection_window_has_more');
    }
    return CloudRetainedProjectionWindowResult(
      examined: counts.examined,
      reprojected: counts.reprojected,
      retained: counts.retained,
      lastExaminedSequence: lastSequence,
      hasMoreWithinBound: hasMoreWithinBound,
    );
  }

  Future<_CloudRetainedProjectionBatchCounts> _reprojectRetainedCandidates({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required CloudRetainedProjectionStoreGateway projectionStore,
    required CloudTransientCanonicalIdentityRegistrar registrar,
    required List<CloudInboxEntry> candidates,
  }) async {
    var reprojected = 0;
    for (final entry in candidates) {
      _recordDiagnostic('retained_projection_examined');
      if (entry.scope != scope ||
          entry.generation != generation ||
          entry.status != CloudInboxStatus.retainedUnprojected ||
          entry.change.type != CloudChangeType.save ||
          entry.change.isTombstone ||
          entry.lastFailure == CloudFailureCategory.outOfScopeService) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'retained_projection_candidate_invalid',
        );
      }

      final CloudDecodedMutation decoded;
      try {
        decoded = await _decoder.decode(entry);
      } on CloudSemanticOutOfScopeServiceDisposition catch (disposition) {
        _recordDiagnostic(disposition.safeCode);
        if (entry.lastFailure != CloudFailureCategory.unsupportedService) {
          _recordDiagnostic(
            'retained_projection_out_of_scope_previous_failure_rejected',
          );
          await projectionStore.recordRetainedProjectionFailure(
            entry: entry,
            leaseFence: leaseFence,
          );
          _recordDiagnostic('retained_projection_retained');
          await Future<void>.delayed(Duration.zero);
          continue;
        }
        await projectionStore.recordRetainedProjectionOutOfScopeService(
          entry: entry,
          leaseFence: leaseFence,
        );
        _recordDiagnostic('retained_projection_out_of_scope_service');
        await Future<void>.delayed(Duration.zero);
        continue;
      } on CloudSemanticDecodeFailure catch (failure) {
        _recordDiagnostic(
          'retained_projection_decoder_${_safeCodeSegment(failure.category.name)}',
        );
        _recordDiagnostic(
          cloudSyncV2SafeFailureCodeForCandidate(
            failure.safeCode ??
                'decoder_${_safeCodeSegment(failure.category.name)}',
          ),
        );
        if (failure.category == CloudFailureCategory.authorization) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.authorization,
            safeCode:
                failure.safeCode ?? 'retained_projection_authorization_changed',
          );
        }
        await projectionStore.recordRetainedProjectionFailure(
          entry: entry,
          leaseFence: leaseFence,
        );
        _recordDiagnostic('retained_projection_retained');
        await Future<void>.delayed(Duration.zero);
        continue;
      } catch (_) {
        _recordDiagnostic('retained_projection_decoder_unknown');
        await projectionStore.recordRetainedProjectionFailure(
          entry: entry,
          leaseFence: leaseFence,
        );
        _recordDiagnostic('retained_projection_retained');
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      final snapshot = decoded.snapshot;
      final payload = decoded.payload;
      if (decoded.scope != entry.scope ||
          decoded.generation != entry.generation ||
          decoded.changeId != entry.change.changeId ||
          decoded.kind != CloudDecodedMutationKind.upsert ||
          decoded.tombstone != null ||
          snapshot == null ||
          payload == null ||
          snapshot.kind != payload.kind ||
          snapshot.logicalEntityKeyHash != payload.logicalEntityKeyHash) {
        _recordDiagnostic('retained_projection_decoded_shape_invalid');
        await projectionStore.recordRetainedProjectionFailure(
          entry: entry,
          leaseFence: leaseFence,
        );
        _recordDiagnostic('retained_projection_retained');
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      CloudTransientCanonicalIdentityLease? identityLease;
      try {
        identityLease = registrar.bind(decoded);
        if (_activeScopeRevalidator != null) {
          final stillActive = await _activeScopeRevalidator();
          if (!stillActive) {
            throw CloudSyncFailure(
              category: CloudFailureCategory.authorization,
              safeCode: 'retained_projection_active_scope_changed',
            );
          }
        }
        await projectionStore.writeRetainedProjectionTransaction<void>(
          entry: entry,
          leaseFence: leaseFence,
          action: (transaction) {
            if (transaction.activeScope != entry.scope ||
                transaction.activeGeneration != entry.generation) {
              throw CloudSyncFailure(
                category: CloudFailureCategory.conflict,
                safeCode: 'retained_projection_scope_mismatch',
              );
            }
            if (transaction.hasAppliedChange(decoded.changeId)) {
              throw CloudSyncFailure(
                category: CloudFailureCategory.conflict,
                safeCode: 'retained_projection_replay_exists',
              );
            }
            final result = _applyUpsert(transaction, decoded);
            if (result.disposition != CloudInboxApplyDisposition.applied ||
                !result.inboxStatusPersisted) {
              throw CloudSyncFailure(
                category:
                    result.failureCategory ?? CloudFailureCategory.conflict,
                safeCode:
                    result.safeCode ?? 'retained_projection_not_projected',
              );
            }
          },
        );
        reprojected++;
        _recordDiagnostic('retained_projection_reprojected');
      } on CloudSyncFailure catch (failure) {
        _recordDiagnostic(
          failure.safeCode == null
              ? 'retained_projection_${_safeCodeSegment(failure.category.name)}'
              : cloudSyncV2SafeFailureCodeForCandidate(failure.safeCode),
        );
        if (failure.category == CloudFailureCategory.authorization) rethrow;
        await projectionStore.recordRetainedProjectionFailure(
          entry: entry,
          leaseFence: leaseFence,
        );
        _recordDiagnostic('retained_projection_retained');
      } catch (_) {
        _recordDiagnostic('retained_projection_unknown');
        await projectionStore.recordRetainedProjectionFailure(
          entry: entry,
          leaseFence: leaseFence,
        );
        _recordDiagnostic('retained_projection_retained');
      } finally {
        identityLease?.release();
      }
      // Never place this fairness yield inside a canonical transaction or
      // while an identity lease is held. Yield between candidates so retained
      // replay remains ordered without monopolizing Flutter's UI isolate.
      await Future<void>.delayed(Duration.zero);
    }
    return _CloudRetainedProjectionBatchCounts(
      examined: candidates.length,
      reprojected: reprojected,
      retained: candidates.length - reprojected,
    );
  }

  @override
  Future<int> repairAppliedProjections({
    required CloudSyncScope scope,
    required int generation,
    required CloudCoordinatorLeaseFence leaseFence,
    required int limit,
  }) async {
    final repairStore = _store;
    final registrar = _identityRegistrar;
    if (repairStore is! CloudAppliedProjectionRepairStoreGateway ||
        registrar == null) {
      return 0;
    }
    final projectionStore =
        repairStore as CloudAppliedProjectionRepairStoreGateway;
    if (generation <= 0 || limit <= 0 || limit > 4096) {
      throw ArgumentError('cloud_projection_repair_request_invalid');
    }

    final candidates = await projectionStore
        .readAppliedProjectionRepairCandidates(
          scope: scope,
          generation: generation,
          leaseFence: leaseFence,
          limit: limit,
        );
    var repaired = 0;
    for (final entry in candidates) {
      if (entry.scope != scope ||
          entry.generation != generation ||
          entry.status != CloudInboxStatus.applied ||
          entry.change.isTombstone) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.localStorage,
          safeCode: 'projection_repair_candidate_invalid',
        );
      }

      final CloudDecodedMutation decoded;
      try {
        decoded = await _decoder.decode(entry);
      } on CloudSemanticOutOfScopeServiceDisposition catch (disposition) {
        _recordDiagnostic(disposition.safeCode);
        await Future<void>.delayed(Duration.zero);
        continue;
      } on CloudSemanticDecodeFailure catch (failure) {
        _recordDiagnostic(
          'projection_repair_decoder_${_safeCodeSegment(failure.category.name)}',
        );
        if (failure.category.isRetryable) {
          throw CloudSyncFailure(
            category: failure.category,
            safeCode: failure.safeCode ?? 'projection_repair_decode_retryable',
          );
        }
        await Future<void>.delayed(Duration.zero);
        continue;
      } catch (_) {
        _recordDiagnostic('projection_repair_decoder_unknown');
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      final snapshot = decoded.snapshot;
      final payload = decoded.payload;
      if (decoded.scope != entry.scope ||
          decoded.generation != entry.generation ||
          decoded.changeId != entry.change.changeId ||
          decoded.kind != CloudDecodedMutationKind.upsert ||
          snapshot == null ||
          payload is! CloudChatEntityPayload ||
          snapshot.kind != CloudEntityKind.chat ||
          snapshot.logicalEntityKeyHash != payload.logicalEntityKeyHash) {
        _recordDiagnostic('projection_repair_decoded_shape_invalid');
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      CloudTransientCanonicalIdentityLease? identityLease;
      try {
        identityLease = registrar.bind(decoded);
        if (_activeScopeRevalidator != null &&
            !await _activeScopeRevalidator()) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'projection_repair_active_scope_changed',
          );
        }
        await projectionStore.repairAppliedProjection(
          entry: entry,
          leaseFence: leaseFence,
          payload: payload,
          snapshot: snapshot,
        );
        repaired++;
        _recordDiagnostic('projection_repaired_chat_alias');
      } finally {
        identityLease?.release();
      }
      // The repaired row is fully committed and its transient identity lease
      // is released before yielding to Flutter's event loop.
      await Future<void>.delayed(Duration.zero);
    }
    return repaired;
  }

  @override
  Future<CloudInboxApplyResult> apply(
    CloudInboxEntry entry, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    if (entry.change.isTombstone && !_allowTombstones) {
      // Do not ask the native decoder for a reversible plaintext identity when
      // this build is forbidden to delete canonical state. The protected raw
      // tombstone remains in the inbox as evidence; only its local journal row
      // is acknowledged so it cannot block later, independent records.
      _recordDiagnostic('tombstone_read_only_acknowledged');
      return const CloudInboxApplyResult.tombstoneReadOnlyAcknowledged();
    }
    final CloudDecodedMutation decoded;
    try {
      decoded = await _decoder.decode(entry);
    } on CloudSemanticOutOfScopeServiceDisposition catch (disposition) {
      _recordDiagnostic(disposition.safeCode);
      return CloudInboxApplyResult.outOfScopeService(
        outOfScopeService: disposition.service,
      );
    } on CloudSemanticDecodeFailure catch (failure) {
      final safeCode =
          failure.safeCode ??
          'decoder_${_safeCodeSegment(failure.category.name)}';
      _recordDiagnostic(safeCode);
      if (failure.category.isRetryable) {
        return CloudInboxApplyResult.retryable(
          failureCategory: failure.category,
          safeCode: safeCode,
        );
      }
      return CloudInboxApplyResult.quarantined(
        failureCategory: failure.category,
        safeCode: safeCode,
      );
    } catch (_) {
      _recordDiagnostic('decoder_unknown');
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
    CloudTransientCanonicalIdentityLease? identityLease;
    if (!decodedAsTombstone && _identityRegistrar != null) {
      try {
        identityLease = _identityRegistrar.bind(decoded);
      } catch (_) {
        _recordDiagnostic('identity_registration_failed');
        return const CloudInboxApplyResult.quarantined(
          failureCategory: CloudFailureCategory.conflict,
        );
      }
    }

    try {
      if (_activeScopeRevalidator != null) {
        try {
          if (!await _activeScopeRevalidator()) {
            _recordDiagnostic('active_scope_changed');
            return const CloudInboxApplyResult.quarantined(
              failureCategory: CloudFailureCategory.conflict,
            );
          }
        } catch (_) {
          _recordDiagnostic('active_scope_revalidation_failed');
          return const CloudInboxApplyResult.retryable(
            failureCategory: CloudFailureCategory.authorization,
          );
        }
      }
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
      final safeCode =
          failure.safeCode ??
          'apply_${_safeCodeSegment(failure.category.name)}';
      _recordDiagnostic(safeCode);
      if (failure.category.isRetryable) {
        return CloudInboxApplyResult.retryable(
          failureCategory: failure.category,
          safeCode: safeCode,
          retryAfter: failure.retryAfter,
        );
      }
      return CloudInboxApplyResult.quarantined(
        failureCategory: failure.category,
        safeCode: safeCode,
      );
    } catch (_) {
      _recordDiagnostic('apply_unknown');
      return const CloudInboxApplyResult.quarantined(
        failureCategory: CloudFailureCategory.unknown,
      );
    } finally {
      identityLease?.release();
    }
  }

  void _recordDiagnostic(String safeCode) {
    _diagnosticRecorder?.call(safeCode);
  }

  static String _safeCodeSegment(String value) => value
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)}_${match.group(2)}',
      )
      .toLowerCase();

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
      _recordDiagnostic('semantic_parent_missing');
      return const CloudInboxApplyResult.deferred(
        safeCode: 'semantic_parent_missing',
      );
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
    // Message snapshots carry a parent only for a reply/association. The chat
    // relationship is represented separately by chatAliasKeyHash and is not
    // the semantic snapshot parent.
    CloudEntityKind.message => CloudEntityKind.message,
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

final class _CloudRetainedProjectionBatchCounts {
  const _CloudRetainedProjectionBatchCounts({
    required this.examined,
    required this.reprojected,
    required this.retained,
  });

  final int examined;
  final int reprojected;
  final int retained;
}
