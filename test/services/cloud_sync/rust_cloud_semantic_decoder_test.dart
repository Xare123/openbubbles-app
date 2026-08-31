import 'dart:typed_data';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart' as logger_api;

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
    CloudSyncSemanticDiagnosticRecorder? diagnosticRecorder,
    CloudSyncNativeAuthSnapshotReader? readAuthSnapshot,
  }) => RustCloudSemanticDecoder(
    readAuthSnapshot: readAuthSnapshot ?? (() async => currentAuth),
    storageDirectory: r'C:\private\cloud-sync',
    nativeWriterPauseToken: BigInt.from(7),
    bindings: bindings,
    tombstoneIdentityResolver: tombstoneResolver,
    diagnosticRecorder: diagnosticRecorder,
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
    expect(request.nativeWriterPauseToken, BigInt.from(7));
    expect(request.protectedStoreIdentity, _storeIdentity);
    expect(request.nativeStream, 'messages');
    expect(request.entry.change.recordIdHash, _recordHash);
    expect(request.entry.change.payloadSha256, _payloadSha);
    expect(request.entry.change.encryptedPayloadReference, _sourceReference);
  });

  test('rejects an invalid native writer-pause token before decoding', () {
    for (final token in [BigInt.zero, BigInt.one << 64]) {
      expect(
        () => RustCloudSemanticDecoder(
          readAuthSnapshot: () async => currentAuth,
          storageDirectory: r'C:\private\cloud-sync',
          nativeWriterPauseToken: token,
          bindings: bindings,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'cloud_semantic_decoder_writer_pause_token_invalid',
          ),
        ),
      );
    }
    expect(bindings.requests, isEmpty);
  });

  test('maps the exact native SMS service without iMessage aliasing', () async {
    final entry = _entry();
    bindings.result = _readyMessage(
      entry,
      payload: frb.CloudSyncTransientPayload(
        message: _messagePayload(
          service: frb.CloudSyncTransientService.sms,
          chatIdentifier: 'SMS;-;+19492476163',
        ),
      ),
    );

    final payload =
        (await decoder().decode(entry)).payload! as CloudMessageEntityPayload;
    expect(payload.service, CloudSemanticService.sms);
    expect(payload.chatIdentifier, 'SMS;-;+19492476163');
  });

  test('maps the diagnostic-only qualified direct CID digest', () async {
    final entry = _entry();
    bindings.result = _readyMessage(
      entry,
      payload: frb.CloudSyncTransientPayload(
        message: _messagePayload(
          chatIdentifier: 'bare-direct-cid',
          chatIdBareDirectServiceIdentifierAliasKeyHash: _bareDirectHash,
        ),
      ),
    );

    final payload =
        (await decoder().decode(entry)).payload! as CloudMessageEntityPayload;
    expect(payload.chatIdentifier, 'bare-direct-cid');
    expect(
      payload.chatIdBareDirectServiceIdentifierAliasKeyHash,
      _bareDirectHash,
    );
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
            frb.CloudSyncTransientPayload(
              chat: _chatPayload(
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
            frb.CloudSyncTransientPayload(
              message: _messagePayload(
                logicalEntityKeyHash: _reactionHash,
                canonicalGuid: 'reaction-guid',
                associationKind:
                    frb.CloudSyncTransientAssociationKind.reactionAdd,
                reactionKind: frb.CloudSyncTransientReactionKind.emoji,
                reactionParentLogicalKeyHash: _messageHash,
                reactionParentCanonicalGuid: 'message-guid',
                reactionParentPart: 0,
                bodyState: frb.CloudSyncTransientFieldState.absent,
                body: null,
                associatedEmojiState: frb.CloudSyncTransientFieldState.value,
                associatedEmoji: '👍',
              ),
            ),
            CloudReactionEntityPayload,
          ),
          (
            frb.CloudSyncTransientEntityKind.attachment,
            _attachmentHash,
            frb.CloudSyncTransientPayload(attachment: _attachmentPayload()),
            CloudAttachmentEntityPayload,
          ),
          (
            frb.CloudSyncTransientEntityKind.groupPhoto,
            _groupPhotoHash,
            const frb.CloudSyncTransientPayload(
              groupPhoto: frb.CloudSyncTransientGroupPhotoPayload(
                logicalEntityKeyHash: _groupPhotoHash,
                ownerLogicalKeyHash: _chatHash,
                photoGuid: 'group-photo-guid',
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
        payload: frb.CloudSyncTransientPayload(message: _messagePayload()),
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
      frb.CloudSyncTransientFailureCode.readAuthenticationScope:
          CloudFailureCategory.authorization,
      frb.CloudSyncTransientFailureCode.activeAccountMismatch:
          CloudFailureCategory.authorization,
      frb.CloudSyncTransientFailureCode.warmAuthenticationRequired:
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

    const deferredSafeCodes = <frb.CloudSyncTransientDeferredReason, String>{
      frb.CloudSyncTransientDeferredReason.nestedPresenceUnavailable:
          'native_deferred_nested_presence_unavailable',
      frb.CloudSyncTransientDeferredReason.unprovenEditTimestamp:
          'native_deferred_unproven_edit_timestamp',
      frb.CloudSyncTransientDeferredReason.unsupportedExtensionPayload:
          'native_deferred_unsupported_extension_payload',
      frb.CloudSyncTransientDeferredReason.unsupportedMediaCredentials:
          'native_deferred_unsupported_media_credentials',
      frb.CloudSyncTransientDeferredReason.unsupportedGroupPhoto:
          'native_deferred_unsupported_group_photo',
      frb.CloudSyncTransientDeferredReason.unsupportedSticker:
          'native_deferred_unsupported_sticker',
      frb.CloudSyncTransientDeferredReason.unsupportedScheduling:
          'native_deferred_unsupported_scheduling',
      frb.CloudSyncTransientDeferredReason.unsupportedOffGridMetadata:
          'native_deferred_unsupported_off_grid_metadata',
      frb.CloudSyncTransientDeferredReason.unsupportedNegativeAttachmentSize:
          'native_deferred_unsupported_negative_attachment_size',
    };
    for (final item in deferredSafeCodes.entries) {
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        deferredReason: item.key,
      );
      await _expectFailure(
        decoder().decode(entry),
        CloudFailureCategory.dependency,
        safeCode: item.value,
      );
    }

    for (final reason in frb.CloudSyncTransientQuarantineReason.values) {
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        quarantineReason: reason,
      );
      await _expectFailure(
        decoder().decode(entry),
        reason == frb.CloudSyncTransientQuarantineReason.unsupportedService
            ? CloudFailureCategory.unsupportedService
            : CloudFailureCategory.malformedRecord,
      );
    }
    expect(CloudFailureCategory.unsupportedService.isRetryable, isFalse);
  });

  test('preserves native failure when the auth refresh would throw', () async {
    final entry = _entry();
    bindings.result = frb.CloudSyncTransientDecodeResult(
      protectedSourceReference: _sourceReference,
      generation: BigInt.from(entry.generation),
      failureCode: frb.CloudSyncTransientFailureCode.decoderFailure,
    );
    var authReads = 0;

    await _expectFailure(
      decoder(
        readAuthSnapshot: () async {
          authReads++;
          if (authReads == 1) return auth;
          throw StateError('injected_auth_refresh_failure');
        },
      ).decode(entry),
      CloudFailureCategory.unknown,
    );
    expect(authReads, 2);
  });

  test('account replacement outranks a native failure disposition', () async {
    final entry = _entry();
    bindings.result = frb.CloudSyncTransientDecodeResult(
      protectedSourceReference: _sourceReference,
      generation: BigInt.from(entry.generation),
      failureCode: frb.CloudSyncTransientFailureCode.decoderFailure,
    );
    bindings.afterDecode = () => currentAuth = _auth(Object());

    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.conflict,
    );
  });

  test(
    'logs only the bounded native disposition for unsupported service',
    () async {
      final output = _CapturingLogOutput();
      final diagnostics = CloudSyncSemanticDiagnosticCollector();
      final previousLogger = Logger;
      Logger = BaseLogger();
      Logger.currentOutput = output;
      Logger.currentLevel = logger_api.Level.info;
      try {
        final entry = _entry();
        bindings.result = frb.CloudSyncTransientDecodeResult(
          protectedSourceReference: _sourceReference,
          generation: BigInt.from(entry.generation),
          quarantineReason:
              frb.CloudSyncTransientQuarantineReason.unsupportedService,
        );

        await _expectFailure(
          decoder(diagnosticRecorder: diagnostics.record).decode(entry),
          CloudFailureCategory.unsupportedService,
        );

        final message = output.lines.join('\n');
        expect(message, contains('disposition=quarantined:unsupportedService'));
        expect(message, isNot(contains(entry.change.changeId)));
        expect(message, isNot(contains(_sourceReference)));
        expect(message, isNot(contains(_payloadSha)));
        expect(message, isNot(contains('iMessage')));
        expect(diagnostics.snapshot(), <String, int>{
          'native_quarantined_unsupported_service': 1,
        });
      } finally {
        Logger = previousLogger;
      }
    },
  );

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
        message: _messagePayload(),
        chat: _chatPayload(),
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
        message: _messagePayload(),
        chat: _chatPayload(),
      ),
    );
    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.malformedRecord,
    );
  });

  test('maps absent message bodies without inventing content', () async {
    final entry = _entry();
    bindings.result = _readyMessage(
      entry,
      payload: frb.CloudSyncTransientPayload(
        message: _messagePayload(
          bodyState: frb.CloudSyncTransientFieldState.absent,
          body: null,
        ),
      ),
    );

    final payload =
        (await decoder().decode(entry)).payload! as CloudMessageEntityPayload;
    expect(payload.bodyState, CloudSemanticFieldState.absent);
    expect(payload.body, isNull);
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

  test('reports a fixed code for an unsupported reaction shape', () async {
    final entry = _entry();
    bindings.result = _readyReaction(
      entry,
      reactionKind: frb.CloudSyncTransientReactionKind.emoji,
      removed: false,
    );

    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.dependency,
      safeCode: 'decoder_reaction_shape_unsupported',
    );
  });

  test(
    'defers every incomplete attachment owner identity combination',
    () async {
      final entry = _entry();
      final incompleteOwners = <(String?, String?, int?)>[
        (null, null, null),
        (_messageHash, null, null),
        (null, 'message-guid', null),
        (null, null, 0),
        (_messageHash, 'message-guid', null),
        (_messageHash, null, 0),
        (null, 'message-guid', 0),
      ];

      for (final (ownerHash, ownerGuid, ownerPart) in incompleteOwners) {
        bindings.result = frb.CloudSyncTransientDecodeResult(
          protectedSourceReference: _sourceReference,
          generation: BigInt.from(entry.generation),
          changeId: entry.change.changeId,
          entityKind: frb.CloudSyncTransientEntityKind.attachment,
          mutationKind: frb.CloudSyncTransientMutationKind.upsert,
          snapshot: _snapshotFor(
            frb.CloudSyncTransientEntityKind.attachment,
            _attachmentHash,
          ),
          payload: frb.CloudSyncTransientPayload(
            attachment: _attachmentPayload(
              ownerLogicalKeyHash: ownerHash,
              ownerCanonicalGuid: ownerGuid,
              ownerPart: ownerPart,
            ),
          ),
        );

        if (ownerHash == null && ownerGuid == null && ownerPart == null) {
          final payload =
              (await decoder().decode(entry)).payload!
                  as CloudAttachmentEntityPayload;
          expect(payload.ownerLogicalKeyHash, isNull);
          expect(payload.ownerCanonicalGuid, isNull);
          expect(payload.ownerPart, isNull);
        } else {
          await _expectFailure(
            decoder().decode(entry),
            CloudFailureCategory.dependency,
          );
        }
      }
    },
  );

  test('preserves chat field states, including explicit clear', () async {
    final entry = _entry();
    for (final (state, displayName) in [
      (frb.CloudSyncTransientFieldState.absent, null),
      (frb.CloudSyncTransientFieldState.value, 'A title'),
      (frb.CloudSyncTransientFieldState.explicitClear, null),
    ]) {
      bindings.result = _readyChat(
        entry,
        payload: frb.CloudSyncTransientPayload(
          chat: _chatPayload(displayNameState: state, displayName: displayName),
        ),
      );

      final payload =
          (await decoder().decode(entry)).payload! as CloudChatEntityPayload;
      expect(payload.displayNameState, _chatFieldState(state));
      expect(payload.displayName, displayName);
    }
  });

  test('maps rich message fields into the domain payload', () async {
    final entry = _entry();
    const attributedBody = frb.CloudSyncTransientAttributedBody(
      text: 'hello',
      runs: [
        frb.CloudSyncTransientTextRun(
          startUtf16: 0,
          lengthUtf16: 5,
          mentionHandle: 'friend@example.invalid',
          bold: true,
          italic: false,
        ),
      ],
    );
    const edit = frb.CloudSyncTransientMessageEdit(
      part_: 1,
      revision: 2,
      bodies: [attributedBody],
      modifiedAtMillis: 1787385604000,
      originalRangeLocation: 3,
      originalRangeLength: 2,
    );
    bindings.result = _readyMessage(
      entry,
      payload: frb.CloudSyncTransientPayload(
        message: _messagePayload(
          subjectState: frb.CloudSyncTransientFieldState.value,
          subject: 'Subject',
          body: 'hello',
          attributedBodiesState: frb.CloudSyncTransientFieldState.value,
          attributedBodies: [attributedBody],
          createdAtMillis: 1787385601000,
          error: 7,
          readAtMillisState: frb.CloudSyncTransientFieldState.value,
          readAtMillis: 1787385602000,
          deliveredAtMillisState: frb.CloudSyncTransientFieldState.value,
          deliveredAtMillis: 1787385603000,
          knownFlags: const frb.CloudSyncTransientKnownMessageFlags(
            fromMe: true,
            delivered: true,
            read: true,
            hasDataDetectorResults: true,
            deliveredQuietly: false,
            didNotifyRecipient: true,
          ),
          replyParentLogicalKeyHash: _messageHash,
          replyParentCanonicalGuid: 'reply-guid',
          replyParentPart: '0',
          editsState: frb.CloudSyncTransientFieldState.value,
          edits: [edit],
          retractedPartsState: frb.CloudSyncTransientFieldState.value,
          retractedParts: [2, 4],
        ),
      ),
    );

    final payload =
        (await decoder().decode(entry)).payload! as CloudMessageEntityPayload;
    expect(payload.subjectState, CloudSemanticFieldState.value);
    expect(payload.subject, 'Subject');
    expect(payload.bodyState, CloudSemanticFieldState.value);
    expect(payload.body, 'hello');
    expect(
      payload.createdAt,
      DateTime.fromMillisecondsSinceEpoch(1787385601000, isUtc: true),
    );
    expect(payload.error, 7);
    expect(
      payload.readAt,
      DateTime.fromMillisecondsSinceEpoch(1787385602000, isUtc: true),
    );
    expect(
      payload.deliveredAt,
      DateTime.fromMillisecondsSinceEpoch(1787385603000, isUtc: true),
    );
    expect(payload.knownFlags?.fromMe, isTrue);
    expect(payload.knownFlags?.hasDataDetectorResults, isTrue);
    expect(payload.replyParentCanonicalGuid, 'reply-guid');
    expect(payload.replyParentLogicalKeyHash, _messageHash);
    expect(payload.replyParentPart, '0');
    expect(payload.attributedBodiesState, CloudSemanticFieldState.value);
    expect(payload.attributedBodies.single.text, 'hello');
    expect(payload.attributedBodies.single.runs.single.startUtf16, 0);
    expect(payload.attributedBodies.single.runs.single.lengthUtf16, 5);
    expect(
      payload.attributedBodies.single.runs.single.mentionHandle,
      'friend@example.invalid',
    );
    expect(payload.attributedBodies.single.runs.single.bold, isTrue);
    expect(payload.editsState, CloudSemanticFieldState.value);
    expect(payload.edits.single.part, 1);
    expect(payload.edits.single.revision, 2);
    expect(payload.edits.single.originalRangeLocation, 3);
    expect(payload.edits.single.originalRangeLength, 2);
    expect(payload.retractedPartsState, CloudSemanticFieldState.value);
    expect(payload.retractedParts, [2, 4]);
  });

  test('rejects malformed field-state and value combinations', () async {
    final entry = _entry();
    final cases = <frb.CloudSyncTransientPayload>[
      frb.CloudSyncTransientPayload(
        chat: _chatPayload(
          displayNameState: frb.CloudSyncTransientFieldState.value,
        ),
      ),
      frb.CloudSyncTransientPayload(
        message: _messagePayload(
          subjectState: frb.CloudSyncTransientFieldState.value,
        ),
      ),
      frb.CloudSyncTransientPayload(
        attachment: _attachmentPayload(
          totalBytesState: frb.CloudSyncTransientFieldState.value,
        ),
      ),
    ];
    final kinds = [
      frb.CloudSyncTransientEntityKind.chat,
      frb.CloudSyncTransientEntityKind.message,
      frb.CloudSyncTransientEntityKind.attachment,
    ];
    final hashes = [_chatHash, _messageHash, _attachmentHash];
    for (var i = 0; i < cases.length; i++) {
      bindings.result = frb.CloudSyncTransientDecodeResult(
        protectedSourceReference: _sourceReference,
        generation: BigInt.from(entry.generation),
        changeId: entry.change.changeId,
        entityKind: kinds[i],
        mutationKind: frb.CloudSyncTransientMutationKind.upsert,
        snapshot: _snapshotFor(kinds[i], hashes[i]),
        payload: cases[i],
      );
      await _expectFailure(
        decoder().decode(entry),
        i == 0
            ? CloudFailureCategory.malformedRecord
            : CloudFailureCategory.dependency,
      );
    }
  });

  test('maps attachment states and defers oversized unsigned sizes', () async {
    final entry = _entry();
    bindings.result = _readyAttachment(
      entry,
      payload: frb.CloudSyncTransientPayload(
        attachment: _attachmentPayload(
          utiState: frb.CloudSyncTransientFieldState.value,
          uti: 'public.data',
          totalBytesState: frb.CloudSyncTransientFieldState.value,
          totalBytes: BigInt.from(42),
          isOutgoingState: frb.CloudSyncTransientFieldState.value,
          isOutgoing: true,
        ),
      ),
    );
    final payload =
        (await decoder().decode(entry)).payload!
            as CloudAttachmentEntityPayload;
    expect(payload.utiState, CloudSemanticFieldState.value);
    expect(payload.uti, 'public.data');
    expect(payload.totalBytesState, CloudSemanticFieldState.value);
    expect(payload.totalBytes, 42);
    expect(payload.isOutgoingState, CloudSemanticFieldState.value);
    expect(payload.isOutgoing, isTrue);

    bindings.result = _readyAttachment(
      entry,
      payload: frb.CloudSyncTransientPayload(
        attachment: _attachmentPayload(
          totalBytesState: frb.CloudSyncTransientFieldState.value,
          totalBytes: BigInt.parse('9223372036854775808'),
        ),
      ),
    );
    await _expectFailure(
      decoder().decode(entry),
      CloudFailureCategory.dependency,
    );
  });

  test('maps reaction association, range, and timestamps', () async {
    final entry = _entry();
    bindings.result = _readyReaction(
      entry,
      reactionKind: frb.CloudSyncTransientReactionKind.heart,
      removed: false,
      associatedRangeLocation: 4,
      associatedRangeLength: 2,
      createdAtMillis: 1787385601000,
      readAtMillisState: frb.CloudSyncTransientFieldState.value,
      readAtMillis: 1787385602000,
      deliveredAtMillisState: frb.CloudSyncTransientFieldState.value,
      deliveredAtMillis: 1787385603000,
    );
    final payload =
        (await decoder().decode(entry)).payload! as CloudReactionEntityPayload;
    expect(payload.reactionType, 'love');
    expect(payload.parentCanonicalGuid, 'message-guid');
    expect(payload.parentPart, 0);
    expect(payload.associatedRangeLocation, 4);
    expect(payload.associatedRangeLength, 2);
    expect(
      payload.createdAt,
      DateTime.fromMillisecondsSinceEpoch(1787385601000, isUtc: true),
    );
    expect(payload.readAtState, CloudSemanticFieldState.value);
    expect(
      payload.readAt,
      DateTime.fromMillisecondsSinceEpoch(1787385602000, isUtc: true),
    );
    expect(payload.deliveredAtState, CloudSemanticFieldState.value);
    expect(
      payload.deliveredAt,
      DateTime.fromMillisecondsSinceEpoch(1787385603000, isUtc: true),
    );
  });

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
const _bareDirectHash = 'JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJ';
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
  payload: payload ?? frb.CloudSyncTransientPayload(message: _messagePayload()),
);

frb.CloudSyncTransientDecodeResult _readyChat(
  CloudInboxEntry entry, {
  frb.CloudSyncTransientPayload? payload,
}) => frb.CloudSyncTransientDecodeResult(
  protectedSourceReference: _sourceReference,
  generation: BigInt.from(entry.generation),
  changeId: entry.change.changeId,
  entityKind: frb.CloudSyncTransientEntityKind.chat,
  mutationKind: frb.CloudSyncTransientMutationKind.upsert,
  snapshot: _snapshotFor(frb.CloudSyncTransientEntityKind.chat, _chatHash),
  payload: payload ?? frb.CloudSyncTransientPayload(chat: _chatPayload()),
);

frb.CloudSyncTransientDecodeResult _readyAttachment(
  CloudInboxEntry entry, {
  frb.CloudSyncTransientPayload? payload,
}) => frb.CloudSyncTransientDecodeResult(
  protectedSourceReference: _sourceReference,
  generation: BigInt.from(entry.generation),
  changeId: entry.change.changeId,
  entityKind: frb.CloudSyncTransientEntityKind.attachment,
  mutationKind: frb.CloudSyncTransientMutationKind.upsert,
  snapshot: _snapshotFor(
    frb.CloudSyncTransientEntityKind.attachment,
    _attachmentHash,
  ),
  payload:
      payload ??
      frb.CloudSyncTransientPayload(attachment: _attachmentPayload()),
);

frb.CloudSyncTransientDecodeResult _readyReaction(
  CloudInboxEntry entry, {
  required frb.CloudSyncTransientReactionKind reactionKind,
  required bool removed,
  String? emoji,
  int? associatedRangeLocation,
  int? associatedRangeLength,
  int createdAtMillis = 1787385600000,
  frb.CloudSyncTransientFieldState readAtMillisState =
      frb.CloudSyncTransientFieldState.absent,
  int? readAtMillis,
  frb.CloudSyncTransientFieldState deliveredAtMillisState =
      frb.CloudSyncTransientFieldState.absent,
  int? deliveredAtMillis,
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
    message: _messagePayload(
      logicalEntityKeyHash: _reactionHash,
      canonicalGuid: 'reaction-guid',
      createdAtMillis: createdAtMillis,
      bodyState: frb.CloudSyncTransientFieldState.absent,
      body: null,
      associationKind: removed
          ? frb.CloudSyncTransientAssociationKind.reactionRemove
          : frb.CloudSyncTransientAssociationKind.reactionAdd,
      reactionKind: reactionKind,
      reactionRemoved: removed,
      reactionParentLogicalKeyHash: _messageHash,
      reactionParentCanonicalGuid: 'message-guid',
      reactionParentPart: 0,
      associatedRangeLocation: associatedRangeLocation,
      associatedRangeLength: associatedRangeLength,
      readAtMillisState: readAtMillisState,
      readAtMillis: readAtMillis,
      deliveredAtMillisState: deliveredAtMillisState,
      deliveredAtMillis: deliveredAtMillis,
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

frb.CloudSyncTransientMessagePayload _messagePayload({
  String logicalEntityKeyHash = _messageHash,
  String canonicalGuid = 'message-guid',
  frb.CloudSyncTransientService service =
      frb.CloudSyncTransientService.iMessage,
  String chatIdentifier = 'iMessage;-;chat',
  String chatIdExactGuidLogicalKeyHash = _chatHash,
  String? chatIdBareDirectServiceIdentifierAliasKeyHash,
  List<frb.CloudSyncTransientChatAlias>? chatIdAliasCandidates,
  String? msgProto4GroupIdAliasKeyHash,
  int createdAtMillis = 1787385600000,
  int error = 0,
  frb.CloudSyncTransientFieldState subjectState =
      frb.CloudSyncTransientFieldState.absent,
  String? subject,
  frb.CloudSyncTransientFieldState bodyState =
      frb.CloudSyncTransientFieldState.value,
  String? body = 'transient secret body',
  frb.CloudSyncTransientFieldState attributedBodiesState =
      frb.CloudSyncTransientFieldState.absent,
  List<frb.CloudSyncTransientAttributedBody> attributedBodies = const [],
  frb.CloudSyncTransientFieldState balloonBundleIdState =
      frb.CloudSyncTransientFieldState.absent,
  String? balloonBundleId,
  frb.CloudSyncTransientFieldState effectState =
      frb.CloudSyncTransientFieldState.absent,
  String? effect,
  frb.CloudSyncTransientFieldState readAtMillisState =
      frb.CloudSyncTransientFieldState.absent,
  int? readAtMillis,
  frb.CloudSyncTransientFieldState deliveredAtMillisState =
      frb.CloudSyncTransientFieldState.absent,
  int? deliveredAtMillis,
  frb.CloudSyncTransientKnownMessageFlags? knownFlags,
  frb.CloudSyncTransientAssociationKind associationKind =
      frb.CloudSyncTransientAssociationKind.none,
  frb.CloudSyncTransientReactionKind? reactionKind,
  bool reactionRemoved = false,
  String? reactionParentLogicalKeyHash,
  String? reactionParentCanonicalGuid,
  int? reactionParentPart,
  int? associatedRangeLocation,
  int? associatedRangeLength,
  String? replyParentLogicalKeyHash,
  String? replyParentCanonicalGuid,
  String? replyParentPart,
  frb.CloudSyncTransientFieldState editsState =
      frb.CloudSyncTransientFieldState.absent,
  List<frb.CloudSyncTransientMessageEdit> edits = const [],
  frb.CloudSyncTransientFieldState retractedPartsState =
      frb.CloudSyncTransientFieldState.absent,
  List<int> retractedParts = const [],
  frb.CloudSyncTransientFieldState associatedEmojiState =
      frb.CloudSyncTransientFieldState.absent,
  String? associatedEmoji,
}) => frb.CloudSyncTransientMessagePayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  chatAliasKeyHash: _chatHash,
  chatIdentifier: chatIdentifier,
  chatIdExactGuidLogicalKeyHash: chatIdExactGuidLogicalKeyHash,
  chatIdBareDirectServiceIdentifierAliasKeyHash:
      chatIdBareDirectServiceIdentifierAliasKeyHash,
  chatIdAliasCandidates:
      chatIdAliasCandidates ??
      const [
        frb.CloudSyncTransientChatAlias(
          kind: frb.CloudSyncTransientChatAliasKind.serviceIdentifier,
          keyHash: _chatHash,
        ),
        frb.CloudSyncTransientChatAlias(
          kind: frb.CloudSyncTransientChatAliasKind.groupId,
          keyHash: _chatHash,
        ),
        frb.CloudSyncTransientChatAlias(
          kind: frb.CloudSyncTransientChatAliasKind.originalGroupId,
          keyHash: _chatHash,
        ),
        frb.CloudSyncTransientChatAlias(
          kind: frb.CloudSyncTransientChatAliasKind.legacyGroupIdentifier,
          keyHash: _chatHash,
        ),
      ],
  msgProto4GroupIdAliasKeyHash: msgProto4GroupIdAliasKeyHash,
  senderHandle: 'sender@example.invalid',
  createdAtMillis: createdAtMillis,
  error: error,
  service: service,
  subjectState: subjectState,
  subject: subject,
  bodyState: bodyState,
  body: body,
  attributedBodiesState: attributedBodiesState,
  attributedBodies: attributedBodies,
  balloonBundleIdState: balloonBundleIdState,
  balloonBundleId: balloonBundleId,
  effectState: effectState,
  effect: effect,
  readAtMillisState: readAtMillisState,
  readAtMillis: readAtMillis,
  deliveredAtMillisState: deliveredAtMillisState,
  deliveredAtMillis: deliveredAtMillis,
  knownFlags: knownFlags ?? _neutralFlags,
  associationKind: associationKind,
  reactionKind: reactionKind,
  reactionRemoved: reactionRemoved,
  reactionParentLogicalKeyHash: reactionParentLogicalKeyHash,
  reactionParentCanonicalGuid: reactionParentCanonicalGuid,
  reactionParentPart: reactionParentPart,
  associatedRangeLocation: associatedRangeLocation,
  associatedRangeLength: associatedRangeLength,
  replyParentLogicalKeyHash: replyParentLogicalKeyHash,
  replyParentCanonicalGuid: replyParentCanonicalGuid,
  replyParentPart: replyParentPart,
  editsState: editsState,
  edits: edits,
  retractedPartsState: retractedPartsState,
  retractedParts: Uint32List.fromList(retractedParts),
  associatedEmojiState: associatedEmojiState,
  associatedEmoji: associatedEmoji,
);

frb.CloudSyncTransientChatPayload _chatPayload({
  List<String> participantHandles = const [],
  frb.CloudSyncTransientFieldState displayNameState =
      frb.CloudSyncTransientFieldState.absent,
  String? displayName,
  frb.CloudSyncTransientFieldState lastAddressedHandleState =
      frb.CloudSyncTransientFieldState.absent,
  String? lastAddressedHandle,
  frb.CloudSyncTransientFieldState groupVersionState =
      frb.CloudSyncTransientFieldState.absent,
  int? groupVersion,
  frb.CloudSyncTransientFieldState lastSeenMessageGuidState =
      frb.CloudSyncTransientFieldState.absent,
  String? lastSeenMessageGuid,
  frb.CloudSyncTransientFieldState groupPhotoGuidState =
      frb.CloudSyncTransientFieldState.absent,
  String? groupPhotoGuid,
}) => frb.CloudSyncTransientChatPayload(
  logicalEntityKeyHash: _chatHash,
  canonicalGuid: 'chat-guid',
  chatIdentifier: 'iMessage;-;chat',
  groupId: 'group-id',
  originalGroupId: 'original-group-id',
  aliases: const [
    frb.CloudSyncTransientChatAlias(
      kind: frb.CloudSyncTransientChatAliasKind.serviceIdentifier,
      keyHash: _chatHash,
    ),
  ],
  service: frb.CloudSyncTransientService.iMessage,
  style: frb.CloudSyncTransientChatStyle.direct,
  participantHandles: participantHandles,
  displayNameState: displayNameState,
  displayName: displayName,
  lastAddressedHandleState: lastAddressedHandleState,
  lastAddressedHandle: lastAddressedHandle,
  groupVersionState: groupVersionState,
  groupVersion: groupVersion,
  lastSeenMessageGuidState: lastSeenMessageGuidState,
  lastSeenMessageGuid: lastSeenMessageGuid,
  groupPhotoGuidState: groupPhotoGuidState,
  groupPhotoGuid: groupPhotoGuid,
);

frb.CloudSyncTransientAttachmentPayload _attachmentPayload({
  String? ownerLogicalKeyHash = _messageHash,
  String? ownerCanonicalGuid = 'message-guid',
  int? ownerPart = 0,
  frb.CloudSyncTransientFieldState utiState =
      frb.CloudSyncTransientFieldState.absent,
  String? uti,
  frb.CloudSyncTransientFieldState fileNameState =
      frb.CloudSyncTransientFieldState.value,
  String? fileName = 'document.pdf',
  frb.CloudSyncTransientFieldState mimeTypeState =
      frb.CloudSyncTransientFieldState.absent,
  String? mimeType,
  frb.CloudSyncTransientFieldState totalBytesState =
      frb.CloudSyncTransientFieldState.absent,
  BigInt? totalBytes,
  frb.CloudSyncTransientFieldState isOutgoingState =
      frb.CloudSyncTransientFieldState.absent,
  bool? isOutgoing,
  frb.CloudSyncTransientFieldState protectedLocalReferenceState =
      frb.CloudSyncTransientFieldState.value,
  String? protectedLocalReference = _attachmentReference,
}) => frb.CloudSyncTransientAttachmentPayload(
  logicalEntityKeyHash: _attachmentHash,
  canonicalGuid: 'attachment-guid',
  ownerLogicalKeyHash: ownerLogicalKeyHash,
  ownerCanonicalGuid: ownerCanonicalGuid,
  ownerPart: ownerPart,
  utiState: utiState,
  uti: uti,
  fileNameState: fileNameState,
  fileName: fileName,
  mimeTypeState: mimeTypeState,
  mimeType: mimeType,
  totalBytesState: totalBytesState,
  totalBytes: totalBytes,
  isOutgoingState: isOutgoingState,
  isOutgoing: isOutgoing,
  protectedLocalReferenceState: protectedLocalReferenceState,
  protectedLocalReference: protectedLocalReference,
);

const _neutralFlags = frb.CloudSyncTransientKnownMessageFlags(
  fromMe: false,
  delivered: false,
  read: false,
  hasDataDetectorResults: false,
  deliveredQuietly: false,
  didNotifyRecipient: false,
);

CloudSemanticFieldState _chatFieldState(
  frb.CloudSyncTransientFieldState value,
) => switch (value) {
  frb.CloudSyncTransientFieldState.absent => CloudSemanticFieldState.absent,
  frb.CloudSyncTransientFieldState.value => CloudSemanticFieldState.value,
  frb.CloudSyncTransientFieldState.explicitClear =>
    CloudSemanticFieldState.explicitClear,
};

Future<void> _expectFailure(
  Future<Object?> future,
  CloudFailureCategory category, {
  String? safeCode,
}) {
  var matcher = isA<CloudSemanticDecodeFailure>().having(
    (failure) => failure.category,
    'category',
    category,
  );
  if (safeCode != null) {
    matcher = matcher.having(
      (failure) => failure.safeCode,
      'safeCode',
      safeCode,
    );
  }
  return expectLater(future, throwsA(matcher));
}

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

final class _CapturingLogOutput extends logger_api.LogOutput {
  final List<String> lines = [];

  @override
  void output(logger_api.OutputEvent event) => lines.addAll(event.lines);
}

final class _TombstoneResolver implements CloudTombstoneIdentityResolver {
  const _TombstoneResolver(this.value);

  final CloudTombstoneIdentity? value;

  @override
  Future<CloudTombstoneIdentity?> resolve(CloudInboxEntry entry) async => value;
}
