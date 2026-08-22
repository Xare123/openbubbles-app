import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Object client;
  late CloudSyncNativeAuthSnapshot auth;
  late CloudSyncNativeAuthSnapshot? currentAuth;
  late _Bindings bindings;

  setUp(() {
    client = Object();
    auth = _auth(client);
    currentAuth = auth;
    bindings = _Bindings();
  });

  RustCloudSemanticDecoder decoder({
    CloudTombstoneIdentityResolver? tombstoneResolver,
  }) => RustCloudSemanticDecoder(
    readAuthSnapshot: () async => currentAuth,
    storageDirectory: r'C:\private\cloud-sync',
    bindings: bindings,
    tombstoneIdentityResolver: tombstoneResolver,
  );

  test('maps a native message upsert and passes every source fence', () async {
    final entry = _entry();
    bindings.result = _readyMessage(entry);

    final decoded = await decoder().decode(entry);

    expect(decoded.scope, same(entry.scope));
    expect(decoded.generation, entry.generation);
    expect(decoded.changeId, entry.change.changeId);
    expect(decoded.kind, CloudDecodedMutationKind.upsert);
    expect(decoded.snapshot!.logicalEntityKeyHash, _messageHash);
    expect(decoded.payload, isA<CloudMessageEntityPayload>());
    final request = bindings.requests.single;
    expect(request.authSnapshot, same(auth));
    expect(request.protectedStoreIdentity, _storeIdentity);
    expect(request.nativeStream, 'messages');
    expect(request.entry.change.recordIdHash, _recordHash);
    expect(request.entry.change.payloadSha256, _payloadSha);
    expect(request.entry.change.encryptedPayloadReference, _sourceReference);
  });

  test('maps every currently representable native payload lane', () async {
    final entry = _entry();
    final cases =
        <
          (
            frb.CloudSyncTransientEntityKind,
            String,
            frb.CloudSyncTransientPayload,
            Type,
          )
        >[
          (
            frb.CloudSyncTransientEntityKind.chat,
            _chatHash,
            const frb.CloudSyncTransientPayload(
              chat: frb.CloudSyncTransientChatPayload(
                logicalEntityKeyHash: _chatHash,
                participantHandles: ['one@example.invalid'],
                displayNameState: frb.CloudSyncTransientFieldState.value,
                displayName: 'Transient title',
              ),
            ),
            CloudChatEntityPayload,
          ),
          (
            frb.CloudSyncTransientEntityKind.reaction,
            _reactionHash,
            const frb.CloudSyncTransientPayload(
              message: frb.CloudSyncTransientMessagePayload(
                logicalEntityKeyHash: _reactionHash,
                chatLogicalKeyHash: _chatHash,
                senderHandle: 'sender@example.invalid',
                bodyState: frb.CloudSyncTransientFieldState.absent,
                reactionKind: frb.CloudSyncTransientReactionKind.emoji,
                reactionRemoved: false,
                reactionParentLogicalKeyHash: _messageHash,
                associatedEmojiState: frb.CloudSyncTransientFieldState.value,
                associatedEmoji: '👍',
              ),
            ),
            CloudReactionEntityPayload,
          ),
          (
            frb.CloudSyncTransientEntityKind.attachment,
            _attachmentHash,
            const frb.CloudSyncTransientPayload(
              attachment: frb.CloudSyncTransientAttachmentPayload(
                logicalEntityKeyHash: _attachmentHash,
                ownerLogicalKeyHash: _messageHash,
                fileNameState: frb.CloudSyncTransientFieldState.value,
                fileName: 'document.pdf',
                mimeTypeState: frb.CloudSyncTransientFieldState.absent,
                protectedLocalReferenceState:
                    frb.CloudSyncTransientFieldState.value,
                protectedLocalReference: _attachmentReference,
              ),
            ),
            CloudAttachmentEntityPayload,
          ),
          (
            frb.CloudSyncTransientEntityKind.groupPhoto,
            _groupPhotoHash,
            const frb.CloudSyncTransientPayload(
              groupPhoto: frb.CloudSyncTransientGroupPhotoPayload(
                logicalEntityKeyHash: _groupPhotoHash,
                ownerLogicalKeyHash: _chatHash,
                protectedLocalReference: _attachmentReference,
              ),
            ),
            CloudGroupPhotoEntityPayload,
          ),
        ];

    for (final item in cases) {
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        changeId: entry.change.changeId,
        entityKind: item.$1,
        mutationKind: frb.CloudSyncTransientMutationKind.upsert,
        snapshot: _snapshotFor(item.$1, item.$2),
        payload: item.$3,
      );
      final decoded = await decoder().decode(entry);
      expect(decoded.payload.runtimeType, item.$4);
      expect(decoded.payload!.toString(), isNot(contains('Transient')));
    }
  });

  test(
    'rejects a native source reference mismatch before projection',
    () async {
      final entry = _entry();
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: 'obcs2.ref.${'X' * 43}',
        generation: BigInt.from(entry.generation),
        changeId: entry.change.changeId,
        entityKind: frb.CloudSyncTransientEntityKind.message,
        mutationKind: frb.CloudSyncTransientMutationKind.upsert,
        snapshot: _snapshot(),
        payload: _messagePayload(),
      );

      await _expectFailure(
        decoder().decode(entry),
        CloudFailureCategory.conflict,
      );
    },
  );

  test('rejects a nested snapshot source reference mismatch', () async {
    final entry = _entry();
    bindings.result = _readyMessage(
      entry,
      snapshot: _snapshotFor(
        frb.CloudSyncTransientEntityKind.message,
        _messageHash,
        sourceReference: 'obcs2.ref.${'N' * 43}',
      ),
    );

    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.malformedRecord,
    );
  });

  test('rejects an account session replacement after native decode', () async {
    final entry = _entry();
    bindings.result = _readyMessage(entry);
    bindings.afterDecode = () => currentAuth = _auth(Object());

    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.conflict,
    );
  });

  test('maps native retry and terminal dispositions exhaustively', () async {
    final entry = _entry();
    final cases = <frb.CloudSyncTransientFailureCode, CloudFailureCategory>{
      frb.CloudSyncTransientFailureCode.invalidRequest:
          CloudFailureCategory.malformedRecord,
      frb.CloudSyncTransientFailureCode.activeAccountMismatch:
          CloudFailureCategory.authorization,
      frb.CloudSyncTransientFailureCode.scopeMismatch:
          CloudFailureCategory.conflict,
      frb.CloudSyncTransientFailureCode.generationMismatch:
          CloudFailureCategory.conflict,
      frb.CloudSyncTransientFailureCode.storeIdentityMismatch:
          CloudFailureCategory.conflict,
      frb.CloudSyncTransientFailureCode.protectedReferenceMismatch:
          CloudFailureCategory.conflict,
      frb.CloudSyncTransientFailureCode.malformedRecord:
          CloudFailureCategory.malformedRecord,
      frb.CloudSyncTransientFailureCode.oversizedRecord:
          CloudFailureCategory.malformedRecord,
      frb.CloudSyncTransientFailureCode.pcsUnavailable:
          CloudFailureCategory.pcsUnavailable,
      frb.CloudSyncTransientFailureCode.retryableUpstream:
          CloudFailureCategory.server,
      frb.CloudSyncTransientFailureCode.decoderFailure:
          CloudFailureCategory.unknown,
    };
    for (final item in cases.entries) {
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        failureCode: item.key,
      );
      await _expectFailure(decoder().decode(entry), item.value);
    }

    bindings.result = frb.CloudSyncTransientDecodeResult(
      protectedSourceReference: _sourceReference,
      generation: BigInt.from(entry.generation),
      deferredReason:
          frb.CloudSyncTransientDeferredReason.unsupportedMediaCredentials,
    );
    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.dependency,
    );

    bindings.result = frb.CloudSyncTransientDecodeResult(
      protectedSourceReference: _sourceReference,
      generation: BigInt.from(entry.generation),
      quarantineReason: frb.CloudSyncTransientQuarantineReason.malformedRecord,
    );
    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.malformedRecord,
    );
  });

  test('rejects mixed dispositions and malformed payload lanes', () async {
    final entry = _entry();
    bindings.result = frb.CloudSyncTransientDecodeResult(
      protectedSourceReference: _sourceReference,
      generation: BigInt.from(entry.generation),
      changeId: entry.change.changeId,
      entityKind: frb.CloudSyncTransientEntityKind.message,
      mutationKind: frb.CloudSyncTransientMutationKind.upsert,
      snapshot: _snapshot(),
      payload: frb.CloudSyncTransientPayload(
        message: _messagePayload().message,
        chat: const frb.CloudSyncTransientChatPayload(
          logicalEntityKeyHash: _chatHash,
          participantHandles: [],
          displayNameState: frb.CloudSyncTransientFieldState.absent,
        ),
      ),
      deferredReason:
          frb.CloudSyncTransientDeferredReason.nestedPresenceUnavailable,
    );

    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.conflict,
    );

    bindings.result = _readyMessage(
      entry,
      payload: frb.CloudSyncTransientPayload(
        message: _messagePayload().message,
        chat: const frb.CloudSyncTransientChatPayload(
          logicalEntityKeyHash: _chatHash,
          participantHandles: [],
          displayNameState: frb.CloudSyncTransientFieldState.absent,
        ),
      ),
    );
    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.malformedRecord,
    );
  });

  test('defers partial messages rather than inventing an empty body', () async {
    final entry = _entry();
    bindings.result = _readyMessage(
      entry,
      payload: const frb.CloudSyncTransientPayload(
        message: frb.CloudSyncTransientMessagePayload(
          logicalEntityKeyHash: _messageHash,
          chatLogicalKeyHash: _chatHash,
          senderHandle: 'sender@example.invalid',
          bodyState: frb.CloudSyncTransientFieldState.absent,
          reactionRemoved: false,
          associatedEmojiState: frb.CloudSyncTransientFieldState.absent,
        ),
      ),
    );

    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.dependency,
    );
  });

  test(
    'maps every reaction kind and removal to application vocabulary',
    () async {
      final entry = _entry();
      final expected = <frb.CloudSyncTransientReactionKind, String>{
        frb.CloudSyncTransientReactionKind.heart: 'love',
        frb.CloudSyncTransientReactionKind.like: 'like',
        frb.CloudSyncTransientReactionKind.dislike: 'dislike',
        frb.CloudSyncTransientReactionKind.laugh: 'laugh',
        frb.CloudSyncTransientReactionKind.emphasize: 'emphasize',
        frb.CloudSyncTransientReactionKind.question: 'question',
        frb.CloudSyncTransientReactionKind.emoji: 'emoji',
        frb.CloudSyncTransientReactionKind.stickerBack: 'stickerback',
      };
      for (final item in expected.entries) {
        for (final removed in [false, true]) {
          final emoji = item.key == frb.CloudSyncTransientReactionKind.emoji
              ? '👍'
              : null;
          bindings.result = _readyReaction(
            entry,
            reactionKind: item.key,
            removed: removed,
            emoji: emoji,
          );
          final payload =
              (await decoder().decode(entry)).payload!
                  as CloudReactionEntityPayload;
          expect(payload.reactionType, removed ? '-${item.value}' : item.value);
          expect(payload.associatedEmoji, emoji);
        }
      }
    },
  );

  test(
    'defers explicit clears that current Dart payloads cannot preserve',
    () async {
      final entry = _entry();
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        changeId: entry.change.changeId,
        entityKind: frb.CloudSyncTransientEntityKind.chat,
        mutationKind: frb.CloudSyncTransientMutationKind.upsert,
        snapshot: _snapshotFor(
          frb.CloudSyncTransientEntityKind.chat,
          _chatHash,
        ),
        payload: const frb.CloudSyncTransientPayload(
          chat: frb.CloudSyncTransientChatPayload(
            logicalEntityKeyHash: _chatHash,
            participantHandles: [],
            displayNameState: frb.CloudSyncTransientFieldState.explicitClear,
          ),
        ),
      );
      await _expectFailure(
        decoder().decode(entry),
        CloudFailureCategory.dependency,
      );

      bindings.result = _readyMessage(
        entry,
        payload: const frb.CloudSyncTransientPayload(
          message: frb.CloudSyncTransientMessagePayload(
            logicalEntityKeyHash: _messageHash,
            chatLogicalKeyHash: _chatHash,
            senderHandle: 'sender@example.invalid',
            bodyState: frb.CloudSyncTransientFieldState.explicitClear,
            reactionRemoved: false,
            associatedEmojiState: frb.CloudSyncTransientFieldState.absent,
          ),
        ),
      );
      await _expectFailure(
        decoder().decode(entry),
        CloudFailureCategory.dependency,
      );
    },
  );

  test(
    'reduces edit history to the highest revision and rejects duplicates',
    () async {
      final entry = _entry();
      const partHash = 'PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP';
      const digest1 =
          '1111111111111111111111111111111111111111111111111111111111111111';
      const digest2 =
          '2222222222222222222222222222222222222222222222222222222222222222';
      final revisions = [
        const frb.CloudSyncTransientEditPart(
          partKeyHash: partHash,
          revision: 1,
          contentDigest: digest1,
          modifiedAtMillis: 1,
        ),
        const frb.CloudSyncTransientEditPart(
          partKeyHash: partHash,
          revision: 2,
          contentDigest: digest2,
          modifiedAtMillis: 2,
        ),
      ];
      bindings.result = _readyMessage(
        entry,
        snapshot: _snapshotFor(
          frb.CloudSyncTransientEntityKind.message,
          _messageHash,
          editParts: revisions,
        ),
      );
      final decoded = await decoder().decode(entry);
      expect(decoded.snapshot!.editParts[partHash]!.revision, 2);

      bindings.result = _readyMessage(
        entry,
        snapshot: _snapshotFor(
          frb.CloudSyncTransientEntityKind.message,
          _messageHash,
          editParts: [revisions.first, revisions.first],
        ),
      );
      await _expectFailure(
        decoder().decode(entry),
        CloudFailureCategory.malformedRecord,
      );
    },
  );

  test(
    'requires a proven tombstone identity and maps it without a timestamp',
    () async {
      final entry = _entry(tombstone: true);
      await _expectFailure(
        decoder().decode(entry),
        CloudFailureCategory.dependency,
      );
      expect(bindings.requests, isEmpty);

      final resolver = _TombstoneResolver(
        CloudTombstoneIdentity(
          scope: entry.scope,
          generation: entry.generation,
          changeId: entry.change.changeId,
          serverRecordIdHash: entry.change.recordIdHash,
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: _messageHash,
        ),
      );
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        changeId: entry.change.changeId,
        entityKind: frb.CloudSyncTransientEntityKind.message,
        mutationKind: frb.CloudSyncTransientMutationKind.tombstone,
        tombstone: const frb.CloudSyncTransientTombstone(
          entityKind: frb.CloudSyncTransientEntityKind.message,
          logicalEntityKeyHash: _messageHash,
          serverConfirmed: true,
        ),
      );

      final decoded = await decoder(tombstoneResolver: resolver).decode(entry);
      expect(decoded.kind, CloudDecodedMutationKind.tombstone);
      expect(decoded.tombstone!.deletedAt, isNull);
      expect(decoded.tombstone!.serverConfirmed, isTrue);
      expect(
        bindings.requests.single.tombstoneIdentity!.logicalEntityKeyHash,
        _messageHash,
      );

      bindings.requests.clear();
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        changeId: entry.change.changeId,
        entityKind: frb.CloudSyncTransientEntityKind.message,
        mutationKind: frb.CloudSyncTransientMutationKind.tombstone,
        tombstone: const frb.CloudSyncTransientTombstone(
          entityKind: frb.CloudSyncTransientEntityKind.message,
          logicalEntityKeyHash: _reactionHash,
          serverConfirmed: true,
        ),
      );
      await _expectFailure(
        decoder(tombstoneResolver: resolver).decode(entry),
        CloudFailureCategory.malformedRecord,
      );
    },
  );

  test(
    'rejects stale tombstone resolver output before native decode',
    () async {
      final entry = _entry(tombstone: true);
      final resolver = _TombstoneResolver(
        CloudTombstoneIdentity(
          scope: entry.scope,
          generation: entry.generation + 1,
          changeId: entry.change.changeId,
          serverRecordIdHash: entry.change.recordIdHash,
          kind: CloudEntityKind.message,
          logicalEntityKeyHash: _messageHash,
        ),
      );
      await _expectFailure(
        decoder(tombstoneResolver: resolver).decode(entry),
        CloudFailureCategory.dependency,
      );
      expect(bindings.requests, isEmpty);
    },
  );

  test('rejects every auxiliary zone before native semantic decode', () async {
    for (final zone in [
      'messageUpdateZone',
      'recoverableMessageDeleteZone',
      'scheduledMessageZone',
      'chat1ManateeZone',
    ]) {
      final entry = _entry(
        scope: CloudSyncScope(
          accountFingerprint: _accountFingerprint,
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: zone,
        ),
      );
      await _expectFailure(
        decoder().decode(entry),
        CloudFailureCategory.conflict,
      );
    }
    expect(bindings.requests, isEmpty);
  });

  test('rejects unsupported scope before calling native code', () async {
    final entry = _entry(
      scope: CloudSyncScope(
        accountFingerprint: _accountFingerprint,
        container: 'wrong-container',
        database: 'private',
        zone: 'messageManateeZone',
      ),
    );

    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.conflict,
    );
    expect(bindings.requests, isEmpty);
  });
}

const _accountFingerprint = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _storeIdentity =
    'obcs2.store.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _sourceReference =
    'obcs2.ref.RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR';
const _changeId = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _recordHash = 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';
const _messageHash = 'MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM';
const _chatHash = 'HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH';
const _reactionHash = 'QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ';
const _attachmentHash = 'TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT';
const _groupPhotoHash = 'GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG';
const _attachmentReference =
    'obcs2.ref.LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL';
const _payloadSha =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

CloudSyncNativeAuthSnapshot _auth(Object client) =>
    CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'session',
      accountFingerprint: _accountFingerprint,
      protectedStoreIdentity: _storeIdentity,
      cloudMessagesClient: client,
    );

CloudInboxEntry _entry({bool tombstone = false, CloudSyncScope? scope}) {
  final actualScope =
      scope ??
      CloudSyncScope(
        accountFingerprint: _accountFingerprint,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
      );
  return CloudInboxEntry(
    scope: actualScope,
    sequence: 1,
    change: CloudFetchedChange(
      changeId: _changeId,
      recordIdHash: _recordHash,
      type: tombstone ? CloudChangeType.delete : CloudChangeType.save,
      etagHash: tombstone
          ? null
          : 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
      encryptedServerRecordId:
          'obcs2.ref.IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII',
      encryptedPayloadReference: _sourceReference,
      payloadSha256: _payloadSha,
      isTombstone: tombstone,
      serverModifiedAt: DateTime.utc(2026, 8, 22),
    ),
    status: CloudInboxStatus.pending,
    attemptCount: 0,
    createdAt: DateTime.utc(2026, 8, 22),
    batchId: 'batch',
    generation: 7,
  );
}

frb.CloudSyncTransientDecodeResult _readyMessage(
  CloudInboxEntry entry, {
  frb.CloudSyncTransientPayload? payload,
  frb.CloudSyncTransientSnapshot? snapshot,
}) => frb.CloudSyncTransientDecodeResult(
  protectedSourceReference: _sourceReference,
  generation: BigInt.from(entry.generation),
  changeId: entry.change.changeId,
  entityKind: frb.CloudSyncTransientEntityKind.message,
  mutationKind: frb.CloudSyncTransientMutationKind.upsert,
  snapshot: snapshot ?? _snapshot(),
  payload: payload ?? _messagePayload(),
);

frb.CloudSyncTransientDecodeResult _readyReaction(
  CloudInboxEntry entry, {
  required frb.CloudSyncTransientReactionKind reactionKind,
  required bool removed,
  String? emoji,
}) => frb.CloudSyncTransientDecodeResult(
  protectedSourceReference: _sourceReference,
  generation: BigInt.from(entry.generation),
  changeId: entry.change.changeId,
  entityKind: frb.CloudSyncTransientEntityKind.reaction,
  mutationKind: frb.CloudSyncTransientMutationKind.upsert,
  snapshot: _snapshotFor(
    frb.CloudSyncTransientEntityKind.reaction,
    _reactionHash,
  ),
  payload: frb.CloudSyncTransientPayload(
    message: frb.CloudSyncTransientMessagePayload(
      logicalEntityKeyHash: _reactionHash,
      chatLogicalKeyHash: _chatHash,
      senderHandle: 'sender@example.invalid',
      bodyState: frb.CloudSyncTransientFieldState.absent,
      reactionKind: reactionKind,
      reactionRemoved: removed,
      reactionParentLogicalKeyHash: _messageHash,
      associatedEmojiState: emoji == null
          ? frb.CloudSyncTransientFieldState.absent
          : frb.CloudSyncTransientFieldState.value,
      associatedEmoji: emoji,
    ),
  ),
);

frb.CloudSyncTransientSnapshot _snapshot() =>
    _snapshotFor(frb.CloudSyncTransientEntityKind.message, _messageHash);

frb.CloudSyncTransientSnapshot _snapshotFor(
  frb.CloudSyncTransientEntityKind kind,
  String logicalEntityKeyHash, {
  String sourceReference = _sourceReference,
  List<frb.CloudSyncTransientEditPart> editParts = const [],
}) => frb.CloudSyncTransientSnapshot(
  entityKind: kind,
  logicalEntityKeyHash: logicalEntityKeyHash,
  parentLogicalKeyHash: _chatHash,
  immutableContentDigest: _payloadSha,
  createdAtMillis: 1787385600000,
  editParts: editParts,
  etagHash: 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
  protectedSourceReference: sourceReference,
);

frb.CloudSyncTransientPayload _messagePayload() =>
    const frb.CloudSyncTransientPayload(
      message: frb.CloudSyncTransientMessagePayload(
        logicalEntityKeyHash: _messageHash,
        chatLogicalKeyHash: _chatHash,
        senderHandle: 'sender@example.invalid',
        bodyState: frb.CloudSyncTransientFieldState.value,
        body: 'transient secret body',
        reactionRemoved: false,
        associatedEmojiState: frb.CloudSyncTransientFieldState.absent,
      ),
    );

Future<void> _expectFailure(
  Future<Object?> future,
  CloudFailureCategory category,
) => expectLater(
  future,
  throwsA(
    isA<CloudSemanticDecodeFailure>().having(
      (failure) => failure.category,
      'category',
      category,
    ),
  ),
);

final class _Bindings implements RustCloudSemanticDecodeBindings {
  final requests = <RustCloudSemanticDecodeRequest>[];
  late frb.CloudSyncTransientDecodeResult result;
  void Function()? afterDecode;

  @override
  Future<frb.CloudSyncTransientDecodeResult> decode(
    RustCloudSemanticDecodeRequest request,
  ) async {
    requests.add(request);
    afterDecode?.call();
    return result;
  }
}

final class _TombstoneResolver implements CloudTombstoneIdentityResolver {
  const _TombstoneResolver(this.value);

  final CloudTombstoneIdentity? value;

  @override
  Future<CloudTombstoneIdentity?> resolve(CloudInboxEntry entry) async => value;
}
