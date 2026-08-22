import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart' as frb_generated;
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;

import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';

final class CloudTombstoneIdentity {
  const CloudTombstoneIdentity({
    required this.scope,
    required this.generation,
    required this.changeId,
    required this.serverRecordIdHash,
    required this.kind,
    required this.logicalEntityKeyHash,
  });

  final CloudSyncScope scope;
  final int generation;
  final String changeId;
  final String serverRecordIdHash;
  final CloudEntityKind kind;
  final String logicalEntityKeyHash;
}

abstract interface class CloudTombstoneIdentityResolver {
  Future<CloudTombstoneIdentity?> resolve(CloudInboxEntry entry);
}

final class RustCloudSemanticDecodeRequest {
  const RustCloudSemanticDecodeRequest({
    required this.authSnapshot,
    required this.storageDirectory,
    required this.entry,
    required this.protectedStoreIdentity,
    required this.nativeStream,
    this.tombstoneIdentity,
  });

  final CloudSyncNativeAuthSnapshot authSnapshot;
  final String storageDirectory;
  final CloudInboxEntry entry;
  final String protectedStoreIdentity;
  final String nativeStream;
  final CloudTombstoneIdentity? tombstoneIdentity;
}

abstract interface class RustCloudSemanticDecodeBindings {
  Future<frb_api.CloudSyncTransientDecodeResult> decode(
    RustCloudSemanticDecodeRequest request,
  );
}

final class FrbRustCloudSemanticDecodeBindings
    implements RustCloudSemanticDecodeBindings {
  FrbRustCloudSemanticDecodeBindings({frb_generated.RustLibApi? api})
    // ignore: invalid_use_of_internal_member
    : _api = api ?? frb_generated.RustLib.instance.api;

  final frb_generated.RustLibApi _api;

  @override
  Future<frb_api.CloudSyncTransientDecodeResult> decode(
    RustCloudSemanticDecodeRequest request,
  ) {
    final client = request.authSnapshot.cloudMessagesClient;
    if (client is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw ArgumentError('cloud_semantic_decoder_client_invalid');
    }
    final entry = request.entry;
    final change = entry.change;
    final tombstone = request.tombstoneIdentity;
    return _api.crateApiApiCloudSyncDecodeProtectedChange(
      cloudMessagesClient: client,
      storageDirectory: request.storageDirectory,
      expectedAccountFingerprint: entry.scope.accountFingerprint,
      expectedProtectedStoreIdentity: request.protectedStoreIdentity,
      container: entry.scope.container,
      database: entry.scope.database,
      zone: entry.scope.zone,
      streamKind: entry.scope.streamKind.name,
      schemaVersion: entry.scope.schemaVersion,
      nativeStream: request.nativeStream,
      generation: BigInt.from(entry.generation),
      expectedChangeKind: switch (change.type) {
        CloudChangeType.save => frb_api.CloudSyncProtectedChangeKind.save,
        CloudChangeType.delete => frb_api.CloudSyncProtectedChangeKind.delete,
      },
      expectedChangeId: change.changeId,
      expectedRecordIdHash: change.recordIdHash,
      expectedEtagHash: change.etagHash,
      expectedPayloadSha256: change.payloadSha256!,
      expectedPayloadLength: null,
      expectedServerModifiedAtMillis:
          change.serverModifiedAt?.millisecondsSinceEpoch,
      protectedRawEnvelopeReference: change.encryptedPayloadReference!,
      tombstoneEntityKind: tombstone == null
          ? null
          : _entityKindToFrb(tombstone.kind),
      tombstoneLogicalEntityKeyHash: tombstone?.logicalEntityKeyHash,
    );
  }
}

/// Production-capable, default-uncomposed semantic decoder for one protected
/// CloudKit journal entry.
///
/// Decrypted payloads remain in memory and are mapped directly into redacted
/// semantic DTOs. This class never logs or persists their contents. Production
/// composition must still supply the separately reviewed canonical identity
/// and entity adapters before semantic apply can be enabled.
final class RustCloudSemanticDecoder implements CloudSemanticDecoder {
  factory RustCloudSemanticDecoder({
    required CloudSyncNativeAuthSnapshotReader readAuthSnapshot,
    required String storageDirectory,
    RustCloudSemanticDecodeBindings? bindings,
    CloudTombstoneIdentityResolver? tombstoneIdentityResolver,
  }) => RustCloudSemanticDecoder._(
    readAuthSnapshot,
    _validateStorageDirectory(storageDirectory),
    bindings ?? FrbRustCloudSemanticDecodeBindings(),
    tombstoneIdentityResolver,
  );

  RustCloudSemanticDecoder._(
    this._readAuthSnapshot,
    this._storageDirectory,
    this._bindings,
    this._tombstoneIdentityResolver,
  );

  static final RegExp _externalDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _contentDigest = RegExp(
    r'^(?:[A-Za-z0-9_-]{43}|[0-9a-f]{64})$',
  );
  static final RegExp _payloadDigest = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _protectedReference = RegExp(
    r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
  );

  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final String _storageDirectory;
  final RustCloudSemanticDecodeBindings _bindings;
  final CloudTombstoneIdentityResolver? _tombstoneIdentityResolver;

  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async {
    _validateEntry(entry);
    final auth = await _readAuthSnapshot();
    if (auth == null ||
        auth.accountFingerprint != entry.scope.accountFingerprint) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.authorization,
      );
    }

    CloudTombstoneIdentity? tombstoneIdentity;
    if (entry.change.isTombstone) {
      tombstoneIdentity = await _tombstoneIdentityResolver?.resolve(entry);
      if (tombstoneIdentity == null ||
          tombstoneIdentity.scope != entry.scope ||
          tombstoneIdentity.generation != entry.generation ||
          tombstoneIdentity.changeId != entry.change.changeId ||
          tombstoneIdentity.serverRecordIdHash != entry.change.recordIdHash ||
          tombstoneIdentity.kind == CloudEntityKind.sharedProfile ||
          !_externalDigest.hasMatch(tombstoneIdentity.logicalEntityKeyHash)) {
        throw const CloudSemanticDecodeFailure(CloudFailureCategory.dependency);
      }
      if (!auth.sameIdentity(await _readAuthSnapshot())) {
        throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
      }
    }

    final result = await _bindings.decode(
      RustCloudSemanticDecodeRequest(
        authSnapshot: auth,
        storageDirectory: _storageDirectory,
        entry: entry,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        nativeStream: _nativeStream(entry.scope),
        tombstoneIdentity: tombstoneIdentity,
      ),
    );

    final currentAuth = await _readAuthSnapshot();
    if (!auth.sameIdentity(currentAuth)) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    return _mapResult(entry, result, tombstoneIdentity);
  }

  CloudDecodedMutation _mapResult(
    CloudInboxEntry entry,
    frb_api.CloudSyncTransientDecodeResult result,
    CloudTombstoneIdentity? tombstoneIdentity,
  ) {
    final hasReadyField =
        result.changeId != null ||
        result.entityKind != null ||
        result.mutationKind != null ||
        result.snapshot != null ||
        result.payload != null ||
        result.tombstone != null;
    final dispositionCount =
        (hasReadyField ? 1 : 0) +
        (result.deferredReason == null ? 0 : 1) +
        (result.quarantineReason == null ? 0 : 1) +
        (result.failureCode == null ? 0 : 1);
    if (dispositionCount != 1 ||
        result.generation != BigInt.from(entry.generation) ||
        result.protectedSourceReference !=
            entry.change.encryptedPayloadReference) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    if (result.failureCode case final failure?) {
      throw CloudSemanticDecodeFailure(_failureCategory(failure));
    }
    if (result.deferredReason != null) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.dependency);
    }
    if (result.quarantineReason != null) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }

    if (result.changeId != entry.change.changeId ||
        result.entityKind == null ||
        result.mutationKind == null) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    final expectedTombstone = entry.change.type == CloudChangeType.delete;
    final decodedTombstone =
        result.mutationKind == frb_api.CloudSyncTransientMutationKind.tombstone;
    if (decodedTombstone != expectedTombstone) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }

    if (decodedTombstone) {
      if (result.snapshot != null || result.payload != null) {
        throw const CloudSemanticDecodeFailure(
          CloudFailureCategory.malformedRecord,
        );
      }
      final tombstone = result.tombstone;
      if (tombstone == null ||
          tombstoneIdentity == null ||
          tombstone.entityKind != result.entityKind ||
          _entityKindFromFrb(tombstone.entityKind) != tombstoneIdentity.kind ||
          tombstone.logicalEntityKeyHash !=
              tombstoneIdentity.logicalEntityKeyHash) {
        throw const CloudSemanticDecodeFailure(
          CloudFailureCategory.malformedRecord,
        );
      }
      final mapped = CloudSemanticTombstone(
        kind: _entityKindFromFrb(tombstone.entityKind),
        logicalEntityKeyHash: _requireExternalDigest(
          tombstone.logicalEntityKeyHash,
        ),
        deletedAt: _dateTime(tombstone.deletedAtMillis),
        serverConfirmed: tombstone.serverConfirmed,
      );
      return CloudDecodedMutation.tombstone(
        scope: entry.scope,
        generation: entry.generation,
        changeId: entry.change.changeId,
        tombstone: mapped,
      );
    }

    if (result.tombstone != null ||
        result.snapshot == null ||
        result.payload == null) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    final snapshot = _snapshotFromFrb(
      result.snapshot!,
      expectedSourceReference: entry.change.encryptedPayloadReference!,
    );
    final payload = _payloadFromFrb(result.entityKind!, result.payload!);
    if (snapshot.kind != _entityKindFromFrb(result.entityKind!) ||
        snapshot.kind != payload.kind ||
        snapshot.logicalEntityKeyHash != payload.logicalEntityKeyHash) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    return CloudDecodedMutation.upsert(
      scope: entry.scope,
      generation: entry.generation,
      changeId: entry.change.changeId,
      snapshot: snapshot,
      payload: payload,
    );
  }

  CloudSemanticSnapshot _snapshotFromFrb(
    frb_api.CloudSyncTransientSnapshot value, {
    required String expectedSourceReference,
  }) {
    final editParts = <String, CloudEditPart>{};
    for (final part in value.editParts) {
      final key = _requireExternalDigest(part.partKeyHash);
      final candidate = CloudEditPart(
        partKeyHash: key,
        revision: part.revision,
        contentDigest: _requireContentDigest(part.contentDigest),
        modifiedAt: _dateTime(part.modifiedAtMillis)!,
      );
      final current = editParts[key];
      if (current == null || candidate.revision > current.revision) {
        editParts[key] = candidate;
      } else if (candidate.revision == current.revision) {
        throw const CloudSemanticDecodeFailure(
          CloudFailureCategory.malformedRecord,
        );
      }
    }
    if (!_protectedReference.hasMatch(value.protectedSourceReference) ||
        value.protectedSourceReference != expectedSourceReference) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    return CloudSemanticSnapshot(
      kind: _entityKindFromFrb(value.entityKind),
      logicalEntityKeyHash: _requireExternalDigest(value.logicalEntityKeyHash),
      parentLogicalKeyHash: _optionalExternalDigest(value.parentLogicalKeyHash),
      immutableContentDigest: _optionalContentDigest(
        value.immutableContentDigest,
      ),
      createdAt: _dateTime(value.createdAtMillis),
      readAt: _dateTime(value.readAtMillis),
      deliveredAt: _dateTime(value.deliveredAtMillis),
      editParts: editParts,
      retractedAt: _dateTime(value.retractedAtMillis),
      groupVersion: value.groupVersion,
      groupMetadataDigest: _optionalContentDigest(value.groupMetadataDigest),
      etagHash: _optionalExternalDigest(value.etagHash),
      encryptedRawRecordReference: value.protectedSourceReference,
    );
  }

  CloudSemanticEntityPayload _payloadFromFrb(
    frb_api.CloudSyncTransientEntityKind kind,
    frb_api.CloudSyncTransientPayload value,
  ) {
    final populated = [
      value.chat,
      value.message,
      value.attachment,
      value.groupPhoto,
    ].where((payload) => payload != null).length;
    if (populated != 1) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    return switch (kind) {
      frb_api.CloudSyncTransientEntityKind.chat => _chatPayload(value),
      frb_api.CloudSyncTransientEntityKind.message => _messagePayload(value),
      frb_api.CloudSyncTransientEntityKind.reaction => _reactionPayload(value),
      frb_api.CloudSyncTransientEntityKind.attachment => _attachmentPayload(
        value,
      ),
      frb_api.CloudSyncTransientEntityKind.groupPhoto => _groupPhotoPayload(
        value,
      ),
    };
  }

  CloudChatEntityPayload _chatPayload(frb_api.CloudSyncTransientPayload value) {
    final payload = value.chat;
    if (payload == null ||
        !_fieldStateMatches(payload.displayNameState, payload.displayName)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    if (payload.displayNameState ==
        frb_api.CloudSyncTransientFieldState.explicitClear) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.dependency);
    }
    return CloudChatEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      displayName: payload.displayName,
      participantHandles: payload.participantHandles,
    );
  }

  CloudMessageEntityPayload _messagePayload(
    frb_api.CloudSyncTransientPayload value,
  ) {
    final payload = value.message;
    if (payload == null ||
        payload.reactionKind != null ||
        payload.reactionParentLogicalKeyHash != null ||
        payload.reactionRemoved ||
        payload.bodyState != frb_api.CloudSyncTransientFieldState.value ||
        payload.body == null ||
        !_fieldStateMatches(
          payload.associatedEmojiState,
          payload.associatedEmoji,
        )) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.dependency);
    }
    return CloudMessageEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      chatLogicalKeyHash: _requireExternalDigest(payload.chatLogicalKeyHash),
      body: payload.body!,
      senderHandle: payload.senderHandle,
    );
  }

  CloudReactionEntityPayload _reactionPayload(
    frb_api.CloudSyncTransientPayload value,
  ) {
    final payload = value.message;
    final parent = payload?.reactionParentLogicalKeyHash;
    final reactionKind = payload?.reactionKind;
    if (payload == null ||
        parent == null ||
        reactionKind == null ||
        !_fieldStateMatches(payload.bodyState, payload.body) ||
        !_fieldStateMatches(
          payload.associatedEmojiState,
          payload.associatedEmoji,
        ) ||
        (reactionKind == frb_api.CloudSyncTransientReactionKind.emoji &&
            (payload.associatedEmojiState !=
                    frb_api.CloudSyncTransientFieldState.value ||
                payload.associatedEmoji == null))) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.dependency);
    }
    final baseType = switch (reactionKind) {
      frb_api.CloudSyncTransientReactionKind.heart => 'love',
      frb_api.CloudSyncTransientReactionKind.like => 'like',
      frb_api.CloudSyncTransientReactionKind.dislike => 'dislike',
      frb_api.CloudSyncTransientReactionKind.laugh => 'laugh',
      frb_api.CloudSyncTransientReactionKind.emphasize => 'emphasize',
      frb_api.CloudSyncTransientReactionKind.question => 'question',
      frb_api.CloudSyncTransientReactionKind.emoji => 'emoji',
      frb_api.CloudSyncTransientReactionKind.stickerBack => 'stickerback',
    };
    final type = payload.reactionRemoved ? '-$baseType' : baseType;
    return CloudReactionEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      parentLogicalKeyHash: _requireExternalDigest(parent),
      senderHandle: payload.senderHandle,
      reactionType: type,
      associatedEmoji: payload.associatedEmoji,
    );
  }

  CloudAttachmentEntityPayload _attachmentPayload(
    frb_api.CloudSyncTransientPayload value,
  ) {
    final payload = value.attachment;
    if (payload == null ||
        payload.ownerLogicalKeyHash == null ||
        payload.fileNameState != frb_api.CloudSyncTransientFieldState.value ||
        payload.fileName == null ||
        payload.protectedLocalReferenceState !=
            frb_api.CloudSyncTransientFieldState.value ||
        payload.protectedLocalReference == null ||
        payload.mimeTypeState ==
            frb_api.CloudSyncTransientFieldState.explicitClear ||
        !_fieldStateMatches(payload.mimeTypeState, payload.mimeType) ||
        !_protectedReference.hasMatch(payload.protectedLocalReference!)) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.dependency);
    }
    return CloudAttachmentEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      ownerLogicalKeyHash: _requireExternalDigest(payload.ownerLogicalKeyHash!),
      fileName: payload.fileName!,
      mimeType: payload.mimeType,
      protectedLocalReference: payload.protectedLocalReference!,
    );
  }

  CloudGroupPhotoEntityPayload _groupPhotoPayload(
    frb_api.CloudSyncTransientPayload value,
  ) {
    final payload = value.groupPhoto;
    if (payload == null ||
        !_protectedReference.hasMatch(payload.protectedLocalReference)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    return CloudGroupPhotoEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      ownerLogicalKeyHash: _requireExternalDigest(payload.ownerLogicalKeyHash),
      protectedLocalReference: payload.protectedLocalReference,
    );
  }

  void _validateEntry(CloudInboxEntry entry) {
    final change = entry.change;
    if (change.preflightFailure != null ||
        !_externalDigest.hasMatch(change.changeId) ||
        !_externalDigest.hasMatch(change.recordIdHash) ||
        (change.etagHash != null &&
            !_externalDigest.hasMatch(change.etagHash!)) ||
        change.payloadSha256 == null ||
        !_payloadDigest.hasMatch(change.payloadSha256!) ||
        change.encryptedPayloadReference == null ||
        !_protectedReference.hasMatch(change.encryptedPayloadReference!) ||
        change.isTombstone != (change.type == CloudChangeType.delete)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    _nativeStream(entry.scope);
  }

  String _nativeStream(CloudSyncScope scope) {
    if (scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != 2) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    return switch (scope.zone) {
      'chatManateeZone' => 'chats',
      'messageManateeZone' => 'messages',
      'attachmentManateeZone' => 'attachments',
      _ => throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.conflict,
      ),
    };
  }

  static String _validateStorageDirectory(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError('cloud_semantic_decoder_storage_invalid');
    }
    return value;
  }

  String _requireExternalDigest(String value) {
    if (!_externalDigest.hasMatch(value)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    return value;
  }

  String? _optionalExternalDigest(String? value) =>
      value == null ? null : _requireExternalDigest(value);

  String _requireContentDigest(String value) {
    if (!_contentDigest.hasMatch(value)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    return value;
  }

  String? _optionalContentDigest(String? value) =>
      value == null ? null : _requireContentDigest(value);

  DateTime? _dateTime(int? milliseconds) {
    if (milliseconds == null) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    } on RangeError {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
  }

  bool _fieldStateMatches(
    frb_api.CloudSyncTransientFieldState state,
    String? value,
  ) => switch (state) {
    frb_api.CloudSyncTransientFieldState.value => value != null,
    frb_api.CloudSyncTransientFieldState.absent ||
    frb_api.CloudSyncTransientFieldState.explicitClear => value == null,
  };

  CloudFailureCategory _failureCategory(
    frb_api.CloudSyncTransientFailureCode value,
  ) => switch (value) {
    frb_api.CloudSyncTransientFailureCode.invalidRequest ||
    frb_api.CloudSyncTransientFailureCode.malformedRecord ||
    frb_api.CloudSyncTransientFailureCode.oversizedRecord =>
      CloudFailureCategory.malformedRecord,
    frb_api.CloudSyncTransientFailureCode.activeAccountMismatch =>
      CloudFailureCategory.authorization,
    frb_api.CloudSyncTransientFailureCode.scopeMismatch ||
    frb_api.CloudSyncTransientFailureCode.generationMismatch ||
    frb_api.CloudSyncTransientFailureCode.storeIdentityMismatch ||
    frb_api.CloudSyncTransientFailureCode.protectedReferenceMismatch =>
      CloudFailureCategory.conflict,
    frb_api.CloudSyncTransientFailureCode.pcsUnavailable =>
      CloudFailureCategory.pcsUnavailable,
    frb_api.CloudSyncTransientFailureCode.retryableUpstream =>
      CloudFailureCategory.server,
    frb_api.CloudSyncTransientFailureCode.decoderFailure =>
      CloudFailureCategory.unknown,
  };
}

CloudEntityKind _entityKindFromFrb(
  frb_api.CloudSyncTransientEntityKind value,
) => switch (value) {
  frb_api.CloudSyncTransientEntityKind.chat => CloudEntityKind.chat,
  frb_api.CloudSyncTransientEntityKind.message => CloudEntityKind.message,
  frb_api.CloudSyncTransientEntityKind.reaction => CloudEntityKind.reaction,
  frb_api.CloudSyncTransientEntityKind.attachment => CloudEntityKind.attachment,
  frb_api.CloudSyncTransientEntityKind.groupPhoto => CloudEntityKind.groupPhoto,
};

frb_api.CloudSyncTransientEntityKind _entityKindToFrb(
  CloudEntityKind value,
) => switch (value) {
  CloudEntityKind.chat => frb_api.CloudSyncTransientEntityKind.chat,
  CloudEntityKind.message => frb_api.CloudSyncTransientEntityKind.message,
  CloudEntityKind.reaction => frb_api.CloudSyncTransientEntityKind.reaction,
  CloudEntityKind.attachment => frb_api.CloudSyncTransientEntityKind.attachment,
  CloudEntityKind.groupPhoto => frb_api.CloudSyncTransientEntityKind.groupPhoto,
  CloudEntityKind.sharedProfile => throw ArgumentError(
    'cloud_semantic_decoder_profile_unsupported',
  ),
};
