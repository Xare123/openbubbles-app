import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart' as frb_generated;
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;
import 'package:bluebubbles/utils/logger/logger.dart';

import 'cloud_attachment_provenance.dart';
import 'cloud_inbox_applier.dart';
import 'cloud_merge_policy.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_semantic_diagnostics.dart';

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
    required this.nativeWriterPauseToken,
    required this.storageDirectory,
    required this.entry,
    required this.protectedStoreIdentity,
    required this.nativeStream,
    this.tombstoneIdentity,
  });

  final CloudSyncNativeAuthSnapshot authSnapshot;
  final BigInt nativeWriterPauseToken;
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
      nativeWriterPauseToken: request.nativeWriterPauseToken,
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
    required BigInt nativeWriterPauseToken,
    RustCloudSemanticDecodeBindings? bindings,
    CloudTombstoneIdentityResolver? tombstoneIdentityResolver,
    CloudSyncSemanticDiagnosticRecorder? diagnosticRecorder,
  }) => RustCloudSemanticDecoder._(
    readAuthSnapshot,
    _validateStorageDirectory(storageDirectory),
    _validateNativeWriterPauseToken(nativeWriterPauseToken),
    bindings ?? FrbRustCloudSemanticDecodeBindings(),
    tombstoneIdentityResolver,
    diagnosticRecorder,
  );

  RustCloudSemanticDecoder._(
    this._readAuthSnapshot,
    this._storageDirectory,
    this._nativeWriterPauseToken,
    this._bindings,
    this._tombstoneIdentityResolver,
    this._diagnosticRecorder,
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
  final BigInt _nativeWriterPauseToken;
  final RustCloudSemanticDecodeBindings _bindings;
  final CloudTombstoneIdentityResolver? _tombstoneIdentityResolver;
  final CloudSyncSemanticDiagnosticRecorder? _diagnosticRecorder;

  @override
  Future<CloudDecodedMutation> decode(CloudInboxEntry entry) async {
    _validateEntry(entry);
    final CloudSyncNativeAuthSnapshot? auth;
    try {
      auth = await _readAuthSnapshot();
    } catch (_) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.authorization,
        safeCode: 'cloud_sync_auth_capture_failed',
      );
    }
    if (auth == null) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.authorization,
        safeCode: 'cloud_sync_auth_snapshot_missing',
      );
    }
    if (auth.accountFingerprint != entry.scope.accountFingerprint) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.authorization,
        safeCode: 'cloud_sync_auth_scope_changed',
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
      final CloudSyncNativeAuthSnapshot? currentAuth;
      try {
        currentAuth = await _readAuthSnapshot();
      } catch (_) {
        throw const CloudSemanticDecodeFailure(
          CloudFailureCategory.authorization,
          safeCode: 'cloud_sync_auth_capture_failed',
        );
      }
      final mismatch = auth.identityMismatchSafeCode(currentAuth);
      if (mismatch != null) {
        throw CloudSemanticDecodeFailure(
          CloudFailureCategory.authorization,
          safeCode: mismatch,
        );
      }
    }

    final result = await _bindings.decode(
      RustCloudSemanticDecodeRequest(
        authSnapshot: auth,
        nativeWriterPauseToken: _nativeWriterPauseToken,
        storageDirectory: _storageDirectory,
        entry: entry,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        nativeStream: _nativeStream(entry.scope),
        tombstoneIdentity: tombstoneIdentity,
      ),
    );

    final nativeDisposition = _nativeDisposition(result);
    _logContentFreeNativeDisposition(
      _nativeStream(entry.scope),
      nativeDisposition,
    );
    _recordDiagnostic('native_$nativeDisposition');

    // A native failure contains no decoded semantic payload. Preserve that
    // typed outcome before refreshing authentication so a transient auth
    // read cannot replace the real PCS/upstream failure with an untyped
    // exception. Ready, deferred, and quarantined semantic outcomes still
    // remain behind the post-decode identity fence below.
    final preAuthFailure = _failureBeforeAuthRefresh(entry, result);
    CloudSyncNativeAuthSnapshot? currentAuth;
    try {
      currentAuth = await _readAuthSnapshot();
    } catch (_) {
      if (preAuthFailure != null) throw preAuthFailure;
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.authorization,
        safeCode: 'cloud_sync_auth_capture_failed',
      );
    }
    final mismatch = auth.identityMismatchSafeCode(currentAuth);
    if (mismatch != null) {
      throw CloudSemanticDecodeFailure(
        CloudFailureCategory.authorization,
        safeCode: mismatch,
      );
    }
    if (preAuthFailure != null) throw preAuthFailure;
    final decoded = _mapResult(entry, result, tombstoneIdentity);
    _recordDiagnostic('decoder_ready');
    return decoded;
  }

  static String _nativeDisposition(
    frb_api.CloudSyncTransientDecodeResult result,
  ) {
    final hasReadyField =
        result.changeId != null ||
        result.entityKind != null ||
        result.mutationKind != null ||
        result.snapshot != null ||
        result.payload != null ||
        result.tombstone != null;
    return switch ((
      hasReadyField,
      result.outOfScopeService,
      result.deferredReason,
      result.quarantineReason,
      result.failureCode,
    )) {
      (true, null, null, null, null) => 'ready',
      (false, final service?, null, null, null) =>
        'out_of_scope_${_safeCodeSegment(service.name)}',
      (false, null, final deferred?, null, null) =>
        'deferred_${_safeCodeSegment(deferred.name)}',
      (false, null, null, final quarantine?, null) =>
        'quarantined_${_safeCodeSegment(quarantine.name)}',
      (false, null, null, null, final failure?) =>
        'failure_${_safeCodeSegment(failure.name)}',
      _ => 'invalid_disposition_shape',
    };
  }

  static void _logContentFreeNativeDisposition(
    String stream,
    String disposition,
  ) {
    final logDisposition = _displayDisposition(disposition);
    Logger.info(
      'CloudKit V2 semantic native outcome stream=$stream '
      'disposition=$logDisposition',
    );
  }

  static String _displayDisposition(String value) {
    for (final prefix in const <String>[
      'out_of_scope_',
      'deferred_',
      'quarantined_',
      'failure_',
    ]) {
      if (value.startsWith(prefix)) {
        final words = value.substring(prefix.length).split('_');
        final camel =
            words.first +
            words
                .skip(1)
                .map(
                  (word) => word.isEmpty
                      ? word
                      : '${word[0].toUpperCase()}${word.substring(1)}',
                )
                .join();
        return '${prefix.substring(0, prefix.length - 1)}:$camel';
      }
    }
    return value;
  }

  CloudSemanticDecodeFailure? _failureBeforeAuthRefresh(
    CloudInboxEntry entry,
    frb_api.CloudSyncTransientDecodeResult result,
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
        (result.outOfScopeService == null ? 0 : 1) +
        (result.deferredReason == null ? 0 : 1) +
        (result.quarantineReason == null ? 0 : 1) +
        (result.failureCode == null ? 0 : 1);
    if (dispositionCount != 1 ||
        result.generation != BigInt.from(entry.generation) ||
        result.protectedSourceReference !=
            entry.change.encryptedPayloadReference) {
      return const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    final failure = result.failureCode;
    return failure == null
        ? null
        : CloudSemanticDecodeFailure(_failureCategory(failure));
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
        (result.outOfScopeService == null ? 0 : 1) +
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
    if (result.outOfScopeService case final service?) {
      if (entry.change.type != CloudChangeType.save ||
          entry.change.isTombstone) {
        throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
      }
      throw CloudSemanticOutOfScopeServiceDisposition(switch (service) {
        frb_api.CloudSyncTransientOutOfScopeService.smsFamily =>
          CloudSemanticOutOfScopeService.smsFamily,
        frb_api.CloudSyncTransientOutOfScopeService.rcs =>
          CloudSemanticOutOfScopeService.rcs,
      });
    }
    if (result.deferredReason case final deferredReason?) {
      // Native deferred reasons describe deterministic record shapes that this
      // build cannot yet project (stickers, scheduling, extension payloads,
      // etc.). Keep them in the bounded dependency lane so a newer converter
      // can recover them before the protected source is explicitly retained.
      throw CloudSemanticDecodeFailure(
        CloudFailureCategory.dependency,
        safeCode: _deferredSafeCode(deferredReason),
      );
    }
    if (result.quarantineReason != null) {
      throw CloudSemanticDecodeFailure(switch (result.quarantineReason!) {
        frb_api.CloudSyncTransientQuarantineReason.unsupportedService =>
          CloudFailureCategory.unsupportedService,
        _ => CloudFailureCategory.malformedRecord,
      });
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
        safeCode: CloudSyncV2DecoderSafeFailureCodes.payloadLaneCountInvalid,
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

  CloudSemanticFieldState _fieldState(
    frb_api.CloudSyncTransientFieldState value,
  ) => switch (value) {
    frb_api.CloudSyncTransientFieldState.absent =>
      CloudSemanticFieldState.absent,
    frb_api.CloudSyncTransientFieldState.value => CloudSemanticFieldState.value,
    frb_api.CloudSyncTransientFieldState.explicitClear =>
      CloudSemanticFieldState.explicitClear,
  };

  CloudSemanticService _service(frb_api.CloudSyncTransientService value) =>
      switch (value) {
        frb_api.CloudSyncTransientService.iMessage =>
          CloudSemanticService.iMessage,
        frb_api.CloudSyncTransientService.sms => CloudSemanticService.sms,
      };

  CloudSemanticChatStyle _chatStyle(
    frb_api.CloudSyncTransientChatStyle value,
  ) => switch (value) {
    frb_api.CloudSyncTransientChatStyle.direct => CloudSemanticChatStyle.direct,
    frb_api.CloudSyncTransientChatStyle.group => CloudSemanticChatStyle.group,
  };

  CloudSemanticAssociationKind _associationKind(
    frb_api.CloudSyncTransientAssociationKind value,
  ) => switch (value) {
    frb_api.CloudSyncTransientAssociationKind.none =>
      CloudSemanticAssociationKind.none,
    frb_api.CloudSyncTransientAssociationKind.sticker =>
      CloudSemanticAssociationKind.sticker,
    frb_api.CloudSyncTransientAssociationKind.reactionAdd =>
      CloudSemanticAssociationKind.reactionAdd,
    frb_api.CloudSyncTransientAssociationKind.reactionRemove =>
      CloudSemanticAssociationKind.reactionRemove,
  };

  CloudSemanticKnownMessageFlags _knownFlags(
    frb_api.CloudSyncTransientKnownMessageFlags value,
  ) => CloudSemanticKnownMessageFlags(
    fromMe: value.fromMe,
    delivered: value.delivered,
    read: value.read,
    hasDataDetectorResults: value.hasDataDetectorResults,
    deliveredQuietly: value.deliveredQuietly,
    didNotifyRecipient: value.didNotifyRecipient,
  );

  CloudSemanticTextRun _textRun(frb_api.CloudSyncTransientTextRun value) {
    if ((value.attachmentCanonicalGuid == null) !=
        (value.attachmentLogicalKeyHash == null)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
        safeCode:
            CloudSyncV2DecoderSafeFailureCodes.textRunAttachmentShapeInvalid,
      );
    }
    return CloudSemanticTextRun(
      startUtf16: value.startUtf16,
      lengthUtf16: value.lengthUtf16,
      messagePart: value.messagePart,
      attachmentCanonicalGuid: value.attachmentCanonicalGuid,
      attachmentLogicalKeyHash: _optionalExternalDigest(
        value.attachmentLogicalKeyHash,
      ),
      mentionHandle: value.mentionHandle,
      audioTranscript: value.audioTranscript,
      textEffect: value.textEffect,
      bold: value.bold,
      italic: value.italic,
      strikethrough: value.strikethrough,
      underline: value.underline,
    );
  }

  CloudSemanticAttributedBody _attributedBody(
    frb_api.CloudSyncTransientAttributedBody value,
  ) => CloudSemanticAttributedBody(
    text: value.text,
    runs: value.runs.map(_textRun),
  );

  CloudSemanticMessageEdit _messageEdit(
    frb_api.CloudSyncTransientMessageEdit value,
  ) {
    if ((value.originalRangeLocation == null) !=
        (value.originalRangeLength == null)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    final modifiedAt = _dateTime(value.modifiedAtMillis);
    if (modifiedAt == null) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
      );
    }
    return CloudSemanticMessageEdit(
      part: value.part_,
      revision: value.revision,
      bodies: value.bodies.map(_attributedBody),
      modifiedAt: modifiedAt,
      originalRangeLocation: value.originalRangeLocation,
      originalRangeLength: value.originalRangeLength,
    );
  }

  CloudChatEntityPayload _chatPayload(frb_api.CloudSyncTransientPayload value) {
    final payload = value.chat;
    if (payload != null &&
        payload.service != frb_api.CloudSyncTransientService.iMessage) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    if (payload == null ||
        !_fieldStateMatches(payload.displayNameState, payload.displayName) ||
        !_fieldStateMatches(
          payload.lastAddressedHandleState,
          payload.lastAddressedHandle,
        ) ||
        !_fieldStateMatches(payload.groupVersionState, payload.groupVersion) ||
        !_fieldStateMatches(
          payload.lastSeenMessageGuidState,
          payload.lastSeenMessageGuid,
        ) ||
        !_fieldStateMatches(
          payload.groupPhotoGuidState,
          payload.groupPhotoGuid,
        )) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
        safeCode: CloudSyncV2DecoderSafeFailureCodes.chatShapeInvalid,
      );
    }
    return CloudChatEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      canonicalGuid: payload.canonicalGuid,
      chatIdentifier: payload.chatIdentifier,
      groupId: payload.groupId,
      originalGroupId: payload.originalGroupId,
      aliases: payload.aliases.map(
        (alias) => CloudSemanticChatAlias(
          kind: _chatAliasKind(alias.kind),
          keyHash: _requireExternalDigest(alias.keyHash),
        ),
      ),
      service: _service(payload.service),
      style: _chatStyle(payload.style),
      displayNameState: _fieldState(payload.displayNameState),
      displayName: payload.displayName,
      participantHandles: payload.participantHandles,
      lastAddressedHandleState: _fieldState(payload.lastAddressedHandleState),
      lastAddressedHandle: payload.lastAddressedHandle,
      groupVersionState: _fieldState(payload.groupVersionState),
      groupVersion: payload.groupVersion,
      lastSeenMessageGuidState: _fieldState(payload.lastSeenMessageGuidState),
      lastSeenMessageGuid: payload.lastSeenMessageGuid,
      groupPhotoGuidState: _fieldState(payload.groupPhotoGuidState),
      groupPhotoGuid: payload.groupPhotoGuid,
    );
  }

  CloudSemanticChatAliasKind _chatAliasKind(
    frb_api.CloudSyncTransientChatAliasKind value,
  ) => switch (value) {
    frb_api.CloudSyncTransientChatAliasKind.groupId =>
      CloudSemanticChatAliasKind.groupId,
    frb_api.CloudSyncTransientChatAliasKind.originalGroupId =>
      CloudSemanticChatAliasKind.originalGroupId,
    frb_api.CloudSyncTransientChatAliasKind.serviceIdentifier =>
      CloudSemanticChatAliasKind.serviceIdentifier,
    frb_api.CloudSyncTransientChatAliasKind.legacyGroupIdentifier =>
      CloudSemanticChatAliasKind.legacyGroupIdentifier,
  };

  CloudMessageEntityPayload _messagePayload(
    frb_api.CloudSyncTransientPayload value,
  ) {
    final payload = value.message;
    if (payload != null &&
        payload.service != frb_api.CloudSyncTransientService.iMessage) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    if (payload == null ||
        (payload.associationKind !=
                frb_api.CloudSyncTransientAssociationKind.none &&
            payload.associationKind !=
                frb_api.CloudSyncTransientAssociationKind.sticker) ||
        payload.reactionKind != null ||
        payload.reactionRemoved ||
        !_fieldStateMatches(payload.subjectState, payload.subject) ||
        !_fieldStateMatches(payload.bodyState, payload.body) ||
        !_collectionFieldStateMatches(
          payload.attributedBodiesState,
          payload.attributedBodies,
        ) ||
        !_fieldStateMatches(
          payload.balloonBundleIdState,
          payload.balloonBundleId,
        ) ||
        !_fieldStateMatches(payload.effectState, payload.effect) ||
        !_fieldStateMatches(payload.readAtMillisState, payload.readAtMillis) ||
        !_fieldStateMatches(
          payload.deliveredAtMillisState,
          payload.deliveredAtMillis,
        ) ||
        !_collectionFieldStateMatches(payload.editsState, payload.edits) ||
        !_collectionFieldStateMatches(
          payload.retractedPartsState,
          payload.retractedParts,
        ) ||
        !_fieldStateMatches(
          payload.associatedEmojiState,
          payload.associatedEmoji,
        ) ||
        payload.associatedEmojiState !=
            frb_api.CloudSyncTransientFieldState.absent ||
        !_associationShapeMatches(payload, isReaction: false) ||
        !_replyShapeMatches(payload)) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.dependency,
        safeCode: CloudSyncV2DecoderSafeFailureCodes.messageShapeUnsupported,
      );
    }
    final chatIdAliasCandidates = payload.chatIdAliasCandidates
        .map(
          (candidate) => CloudSemanticChatAlias(
            kind: _chatAliasKind(candidate.kind),
            keyHash: _requireExternalDigest(candidate.keyHash),
          ),
        )
        .toList(growable: false);
    final candidateKinds = chatIdAliasCandidates
        .map((candidate) => candidate.kind)
        .toSet();
    final serviceCandidates = chatIdAliasCandidates.where(
      (candidate) =>
          candidate.kind == CloudSemanticChatAliasKind.serviceIdentifier,
    );
    if (chatIdAliasCandidates.length !=
            CloudSemanticChatAliasKind.values.length ||
        candidateKinds.length != CloudSemanticChatAliasKind.values.length ||
        !candidateKinds.containsAll(CloudSemanticChatAliasKind.values) ||
        serviceCandidates.length != 1 ||
        serviceCandidates.single.keyHash != payload.chatAliasKeyHash) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.malformedRecord,
        safeCode:
            CloudSyncV2DecoderSafeFailureCodes.messageChatReferenceInvalid,
      );
    }
    return CloudMessageEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      canonicalGuid: payload.canonicalGuid,
      chatAliasKeyHash: _requireExternalDigest(payload.chatAliasKeyHash),
      chatIdentifier: payload.chatIdentifier,
      chatIdExactGuidLogicalKeyHash: _requireExternalDigest(
        payload.chatIdExactGuidLogicalKeyHash,
      ),
      chatIdBareDirectServiceIdentifierAliasKeyHash: _optionalExternalDigest(
        payload.chatIdBareDirectServiceIdentifierAliasKeyHash,
      ),
      chatIdAliasCandidates: chatIdAliasCandidates,
      msgProto4GroupIdAliasKeyHash: _optionalExternalDigest(
        payload.msgProto4GroupIdAliasKeyHash,
      ),
      body: payload.body,
      senderHandle: payload.senderHandle,
      createdAt: _dateTime(payload.createdAtMillis),
      error: payload.error,
      service: _service(payload.service),
      subjectState: _fieldState(payload.subjectState),
      subject: payload.subject,
      bodyState: _fieldState(payload.bodyState),
      attributedBodiesState: _fieldState(payload.attributedBodiesState),
      attributedBodies: payload.attributedBodies.map(_attributedBody),
      balloonBundleIdState: _fieldState(payload.balloonBundleIdState),
      balloonBundleId: payload.balloonBundleId,
      // Native currently defers any extension payload before this boundary.
      // Binary extension bytes must never cross the transient FRB contract.
      decodedExtensionPayloadState: CloudSemanticFieldState.absent,
      effectState: _fieldState(payload.effectState),
      effect: payload.effect,
      readAtState: _fieldState(payload.readAtMillisState),
      readAt: _dateTime(payload.readAtMillis),
      deliveredAtState: _fieldState(payload.deliveredAtMillisState),
      deliveredAt: _dateTime(payload.deliveredAtMillis),
      knownFlags: _knownFlags(payload.knownFlags),
      associationKind: _associationKind(payload.associationKind),
      associationParentLogicalKeyHash: _optionalExternalDigest(
        payload.reactionParentLogicalKeyHash,
      ),
      associationParentCanonicalGuid: payload.reactionParentCanonicalGuid,
      associationParentPart: payload.reactionParentPart,
      associatedRangeLocation: payload.associatedRangeLocation,
      associatedRangeLength: payload.associatedRangeLength,
      replyParentLogicalKeyHash: _optionalExternalDigest(
        payload.replyParentLogicalKeyHash,
      ),
      replyParentCanonicalGuid: payload.replyParentCanonicalGuid,
      replyParentPart: payload.replyParentPart,
      editsState: _fieldState(payload.editsState),
      edits: payload.edits.map(_messageEdit),
      retractedPartsState: _fieldState(payload.retractedPartsState),
      retractedParts: payload.retractedParts,
    );
  }

  CloudReactionEntityPayload _reactionPayload(
    frb_api.CloudSyncTransientPayload value,
  ) {
    final payload = value.message;
    final parent = payload?.reactionParentLogicalKeyHash;
    final parentGuid = payload?.reactionParentCanonicalGuid;
    final reactionKind = payload?.reactionKind;
    if (payload != null &&
        payload.service != frb_api.CloudSyncTransientService.iMessage) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.conflict);
    }
    if (payload == null ||
        parent == null ||
        parentGuid == null ||
        reactionKind == null ||
        !_associationShapeMatches(payload, isReaction: true) ||
        !_replyShapeMatches(payload) ||
        payload.replyParentCanonicalGuid != null ||
        payload.subjectState != frb_api.CloudSyncTransientFieldState.absent ||
        !_fieldStateMatches(payload.bodyState, payload.body) ||
        payload.bodyState != frb_api.CloudSyncTransientFieldState.absent ||
        !_collectionFieldStateMatches(
          payload.attributedBodiesState,
          payload.attributedBodies,
        ) ||
        payload.attributedBodiesState !=
            frb_api.CloudSyncTransientFieldState.absent ||
        payload.balloonBundleIdState !=
            frb_api.CloudSyncTransientFieldState.absent ||
        payload.effectState != frb_api.CloudSyncTransientFieldState.absent ||
        !_fieldStateMatches(payload.readAtMillisState, payload.readAtMillis) ||
        !_fieldStateMatches(
          payload.deliveredAtMillisState,
          payload.deliveredAtMillis,
        ) ||
        !_collectionFieldStateMatches(payload.editsState, payload.edits) ||
        payload.editsState != frb_api.CloudSyncTransientFieldState.absent ||
        !_collectionFieldStateMatches(
          payload.retractedPartsState,
          payload.retractedParts,
        ) ||
        payload.retractedPartsState !=
            frb_api.CloudSyncTransientFieldState.absent ||
        !_fieldStateMatches(
          payload.associatedEmojiState,
          payload.associatedEmoji,
        ) ||
        (reactionKind == frb_api.CloudSyncTransientReactionKind.emoji &&
            (payload.associatedEmojiState !=
                    frb_api.CloudSyncTransientFieldState.value ||
                payload.associatedEmoji == null))) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.dependency,
        safeCode: CloudSyncV2DecoderSafeFailureCodes.reactionShapeUnsupported,
      );
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
      canonicalGuid: payload.canonicalGuid,
      parentLogicalKeyHash: _requireExternalDigest(parent),
      parentCanonicalGuid: parentGuid,
      parentPart: payload.reactionParentPart,
      senderHandle: payload.senderHandle,
      reactionType: type,
      associatedEmoji: payload.associatedEmoji,
      createdAt: _dateTime(payload.createdAtMillis),
      error: payload.error,
      service: _service(payload.service),
      knownFlags: _knownFlags(payload.knownFlags),
      readAtState: _fieldState(payload.readAtMillisState),
      readAt: _dateTime(payload.readAtMillis),
      deliveredAtState: _fieldState(payload.deliveredAtMillisState),
      deliveredAt: _dateTime(payload.deliveredAtMillis),
      associatedRangeLocation: payload.associatedRangeLocation,
      associatedRangeLength: payload.associatedRangeLength,
    );
  }

  CloudAttachmentEntityPayload _attachmentPayload(
    frb_api.CloudSyncTransientPayload value,
  ) {
    final payload = value.attachment;
    if (payload == null ||
        !_ownerShapeMatches(payload) ||
        !_fieldStateMatches(payload.utiState, payload.uti) ||
        !_fieldStateMatches(payload.fileNameState, payload.fileName) ||
        !_fieldStateMatches(payload.mimeTypeState, payload.mimeType) ||
        !_fieldStateMatches(payload.totalBytesState, payload.totalBytes) ||
        !_fieldStateMatches(payload.isOutgoingState, payload.isOutgoing) ||
        !_fieldStateMatches(
          payload.protectedLocalReferenceState,
          payload.protectedLocalReference,
        ) ||
        (payload.protectedLocalReference != null &&
            !_protectedReference.hasMatch(payload.protectedLocalReference!))) {
      throw const CloudSemanticDecodeFailure(
        CloudFailureCategory.dependency,
        safeCode: CloudSyncV2DecoderSafeFailureCodes.attachmentShapeUnsupported,
      );
    }
    return CloudAttachmentEntityPayload(
      logicalEntityKeyHash: _requireExternalDigest(
        payload.logicalEntityKeyHash,
      ),
      canonicalGuid: payload.canonicalGuid,
      ownerLogicalKeyHash: _optionalExternalDigest(payload.ownerLogicalKeyHash),
      ownerCanonicalGuid: payload.ownerCanonicalGuid,
      ownerPart: payload.ownerPart,
      utiState: _fieldState(payload.utiState),
      uti: payload.uti,
      fileNameState: _fieldState(payload.fileNameState),
      fileName: payload.fileName,
      mimeTypeState: _fieldState(payload.mimeTypeState),
      mimeType: payload.mimeType,
      bodyCapability: switch (payload.materializationCapability) {
        frb_api
            .CloudSyncTransientAttachmentMaterializationCapability
            .materializable =>
          CloudAttachmentBodyCapability.materializable,
        frb_api
            .CloudSyncTransientAttachmentMaterializationCapability
            .metadataOnlyUnsupportedMediaCredentials =>
          CloudAttachmentBodyCapability.metadataOnlyUnsupportedMediaCredentials,
      },
      totalBytesState: _fieldState(payload.totalBytesState),
      totalBytes: _boundedUnsignedInt64(payload.totalBytes),
      isOutgoingState: _fieldState(payload.isOutgoingState),
      isOutgoing: payload.isOutgoing,
      protectedLocalReferenceState: _fieldState(
        payload.protectedLocalReferenceState,
      ),
      protectedLocalReference: payload.protectedLocalReference,
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
      photoGuid: payload.photoGuid,
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

  static BigInt _validateNativeWriterPauseToken(BigInt value) {
    if (value <= BigInt.zero || value.bitLength > 64) {
      throw ArgumentError('cloud_semantic_decoder_writer_pause_token_invalid');
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
    Object? value,
  ) => switch (state) {
    frb_api.CloudSyncTransientFieldState.value => value != null,
    frb_api.CloudSyncTransientFieldState.absent ||
    frb_api.CloudSyncTransientFieldState.explicitClear => value == null,
  };

  bool _collectionFieldStateMatches(
    frb_api.CloudSyncTransientFieldState state,
    Iterable<Object?> value,
  ) => state == frb_api.CloudSyncTransientFieldState.value || value.isEmpty;

  bool _associationShapeMatches(
    frb_api.CloudSyncTransientMessagePayload payload, {
    required bool isReaction,
  }) {
    final parentHash = payload.reactionParentLogicalKeyHash;
    final parentGuid = payload.reactionParentCanonicalGuid;
    final hasParent = parentHash != null && parentGuid != null;
    if ((parentHash == null) != (parentGuid == null) ||
        (payload.associatedRangeLocation == null) !=
            (payload.associatedRangeLength == null) ||
        (!hasParent &&
            (payload.reactionParentPart != null ||
                payload.associatedRangeLocation != null))) {
      return false;
    }
    return switch (payload.associationKind) {
      frb_api.CloudSyncTransientAssociationKind.none =>
        !isReaction &&
            !hasParent &&
            payload.reactionKind == null &&
            !payload.reactionRemoved,
      frb_api.CloudSyncTransientAssociationKind.sticker =>
        !isReaction &&
            hasParent &&
            payload.reactionKind == null &&
            !payload.reactionRemoved,
      frb_api.CloudSyncTransientAssociationKind.reactionAdd =>
        isReaction &&
            hasParent &&
            payload.reactionKind != null &&
            !payload.reactionRemoved,
      frb_api.CloudSyncTransientAssociationKind.reactionRemove =>
        isReaction &&
            hasParent &&
            payload.reactionKind != null &&
            payload.reactionRemoved,
    };
  }

  bool _replyShapeMatches(frb_api.CloudSyncTransientMessagePayload payload) {
    final fields = [
      payload.replyParentLogicalKeyHash,
      payload.replyParentCanonicalGuid,
      payload.replyParentPart,
    ];
    return fields.every((value) => value == null) ||
        fields.every((value) => value != null);
  }

  bool _ownerShapeMatches(frb_api.CloudSyncTransientAttachmentPayload payload) {
    final fields = [
      payload.ownerLogicalKeyHash,
      payload.ownerCanonicalGuid,
      payload.ownerPart,
    ];
    return fields.every((value) => value == null) ||
        fields.every((value) => value != null);
  }

  int? _boundedUnsignedInt64(BigInt? value) {
    if (value == null) return null;
    final maximum = BigInt.parse('9223372036854775807');
    if (value.isNegative || value > maximum) {
      throw const CloudSemanticDecodeFailure(CloudFailureCategory.dependency);
    }
    return value.toInt();
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

  static String _deferredSafeCode(
    frb_api.CloudSyncTransientDeferredReason reason,
  ) => 'native_deferred_${_safeCodeSegment(reason.name)}';

  CloudFailureCategory _failureCategory(
    frb_api.CloudSyncTransientFailureCode value,
  ) => switch (value) {
    frb_api.CloudSyncTransientFailureCode.invalidRequest ||
    frb_api.CloudSyncTransientFailureCode.malformedRecord ||
    frb_api.CloudSyncTransientFailureCode.oversizedRecord =>
      CloudFailureCategory.malformedRecord,
    frb_api.CloudSyncTransientFailureCode.readAuthenticationScope ||
    frb_api.CloudSyncTransientFailureCode.activeAccountMismatch ||
    frb_api.CloudSyncTransientFailureCode.warmAuthenticationRequired =>
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
