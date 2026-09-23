// Disposable ObjectBox integration check for CloudKit V2 media handling.
//
// Synthetic, credential-free inputs only. A fresh temporary ObjectBox store is
// opened per test and deleted afterwards. Chat and message rows are projected
// through ObjectBoxCanonicalSemanticEntityAdapter. The attachment goes through
// ObjectBoxCloudSemanticStoreGateway.writeTransaction with a synthetic journal
// entry and lease fence, so snapshot, record-map, inbox, and replay links are
// produced by the normal projection machinery - never hand-seeded. The
// production CloudAttachmentSourceResolver is called against those outputs,
// and the real MediaGalleryCard renders the cached file. The single labeled
// mock is the attachments-service thumbnail fake also used by the gallery
// widget suite. No network, no live writes, no real account data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/conversation_details/widgets/media_gallery_card.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_prepared_extension.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/transient_cloud_canonical_identity_registry.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'cloud_sync_test_helpers.dart';

// Tiny synthetic 1x1 PNG. Never a user photo.
final Uint8List _kPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
);

const _messageGeneration = 5;
const _attachmentGeneration = 7;
const _chatHash = 'disposable-chat-hash';
const _messageHash = 'disposable-message-hash';
const _attachmentHash = 'disposable-attachment-hash';
const _chatGuid = 'disposable-chat-guid';
const _messageGuid = 'disposable-message-guid';
const _attachmentGuid = 'disposable-message-guid_0';
const _chatIdentifier = 'iMessage;-;friend@example.com';
const _senderHandle = 'mailto:friend@example.com';

CloudSyncScope _messageScope() => CloudSyncScope(
  accountFingerprint: testAccountFingerprintA,
  container: 'container',
  database: 'private',
  zone: 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semanticV2,
);

CloudSyncScope _attachmentScope() => CloudSyncScope(
  accountFingerprint: testAccountFingerprintA,
  container: 'container',
  database: 'private',
  zone: 'attachmentManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semanticV2,
);

void main() {
  late Directory storeDir;
  late Directory filesRoot;
  late Store store;
  late _Resolver resolver;
  late AttachmentDownloadService downloads;
  final messageScope = _messageScope();
  final attachmentScope = _attachmentScope();

  setUp(() async {
    Get.testMode = true;
    storeDir = await Directory.systemTemp.createTemp(
      'openbubbles-disposable-store-',
    );
    filesRoot = await Directory.systemTemp.createTemp(
      'openbubbles-disposable-files-',
    );
    fs.appDocDir = filesRoot;
    store = await openStore(directory: storeDir.path);
    resolver = _Resolver()
      ..put(
        scope: messageScope,
        generation: _messageGeneration,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: _chatHash,
        canonicalGuid: _chatGuid,
      )
      ..put(
        scope: messageScope,
        generation: _messageGeneration,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: _messageHash,
        canonicalGuid: _messageGuid,
      )
      ..put(
        scope: attachmentScope,
        generation: _attachmentGeneration,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: _messageHash,
        canonicalGuid: _messageGuid,
      )
      ..put(
        scope: attachmentScope,
        generation: _attachmentGeneration,
        kind: CloudEntityKind.attachment,
        logicalEntityKeyHash: _attachmentHash,
        canonicalGuid: _attachmentGuid,
      );
    downloads = AttachmentDownloadService();
  });

  tearDown(() async {
    expect(downloads.downloaders, isEmpty);
    store.close();
    if (storeDir.existsSync()) await storeDir.delete(recursive: true);
    if (filesRoot.existsSync()) await filesRoot.delete(recursive: true);
    Get.reset();
  });

  ObjectBoxCanonicalSemanticEntityAdapter _messageAdapter() => _newAdapter(
    store: store,
    activeScopeProvider: () => CloudCanonicalActiveScope(
      scope: messageScope,
      generation: _messageGeneration,
    ),
    resolver: resolver,
    semanticApplyEnabled: true,
    allowChatUpserts: true,
    allowMessageUpserts: true,
  );

  int _applyChatPhase() {
    final adapter = _messageAdapter();
    expect(
      adapter.applyEntity(
        scope: messageScope,
        generation: _messageGeneration,
        payload: _chatPayload(
          logicalEntityKeyHash: _chatHash,
          canonicalGuid: _chatGuid,
          chatIdentifier: _chatIdentifier,
          displayName: 'Disposable chat',
          participantHandles: const [_senderHandle],
        ),
        snapshot: _snapshot(CloudEntityKind.chat, _chatHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    final chatId = store.box<Chat>().getAll().single.id!;
    _seedExactOwnershipProof(
      store,
      scope: messageScope,
      generation: _messageGeneration,
      kind: CloudEntityKind.chat,
      logicalEntityKeyHash: _chatHash,
      canonicalGuid: _chatGuid,
    );
    return chatId;
  }

  int _applyMessagePhase() {
    final adapter = _messageAdapter();
    expect(
      adapter.applyEntity(
        scope: messageScope,
        generation: _messageGeneration,
        payload: _messagePayload(
          logicalEntityKeyHash: _messageHash,
          canonicalGuid: _messageGuid,
          chatIdentifier: _chatIdentifier,
          senderHandle: _senderHandle,
          subject: 'Disposable subject',
          body: 'Disposable body',
          createdAt: testEpoch,
        ),
        snapshot: _snapshot(CloudEntityKind.message, _messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    final messageId = store.box<Message>().getAll().single.id!;
    _seedExactOwnershipProof(
      store,
      scope: messageScope,
      generation: _messageGeneration,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: _messageHash,
      canonicalGuid: _messageGuid,
    );
    return messageId;
  }

  CloudAttachmentEntityPayload _imagePayload() => _attachmentPayload(
    logicalEntityKeyHash: _attachmentHash,
    canonicalGuid: _attachmentGuid,
    ownerLogicalKeyHash: _messageHash,
    ownerCanonicalGuid: _messageGuid,
    ownerPart: 0,
    utiState: CloudSemanticFieldState.value,
    uti: 'public.png',
    fileName: 'photo.png',
    mimeType: 'image/png',
    totalBytesState: CloudSemanticFieldState.value,
    totalBytes: _kPng.length,
    protectedLocalReference: 'protected:disposable-synthetic',
  );

  CloudSemanticSnapshot _imageSnapshot() => _snapshot(
    CloudEntityKind.attachment,
    _attachmentHash,
    parentLogicalKeyHash: _messageHash,
  );

  void _seedMessageCheckpoint() {
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: _semanticScopeKey(messageScope),
        accountFingerprint: messageScope.accountFingerprint,
        container: messageScope.container,
        database: messageScope.database,
        zone: messageScope.zone,
        streamKind: messageScope.streamKind.name,
        schemaVersion: messageScope.schemaVersion,
        persistenceLane: messageScope.persistenceLane.name,
        generation: _messageGeneration,
        updatedAtMs: testEpoch.millisecondsSinceEpoch,
      ),
    );
  }

  Future<CloudInboxEntry> _applyAttachmentJournal() async {
    final entry = _journalEntry();
    const leaseFence = CloudCoordinatorLeaseFence(
      ownerId: 'disposable-semantic-owner',
      generation: _attachmentGeneration,
    );
    _seedJournalFence(store, entry: entry, leaseFence: leaseFence);
    final gatewayAdapter = _newAdapter(
      store: store,
      activeScopeProvider: () => CloudCanonicalActiveScope(
        scope: attachmentScope,
        generation: _attachmentGeneration,
      ),
      resolver: resolver,
      messageDependencyScope: CloudCanonicalActiveScope(
        scope: messageScope,
        generation: _messageGeneration,
      ),
      semanticApplyEnabled: true,
      allowAttachmentMetadataUpserts: true,
    );
    final gateway = ObjectBoxCloudSemanticStoreGateway(
      store: store,
      canonicalAdapter: gatewayAdapter,
      clock: () => testEpoch,
    );
    final result = await gateway.writeTransaction<CloudInboxApplyResult>(
      entry: entry,
      leaseFence: leaseFence,
      action: (transaction) {
        // The gateway validates digest formats, so this snapshot carries
        // entry-bound valid digests instead of the unit placeholder.
        transaction.applyEntity(
          payload: _imagePayload(),
          snapshot: CloudSemanticSnapshot(
            kind: CloudEntityKind.attachment,
            logicalEntityKeyHash: _attachmentHash,
            parentLogicalKeyHash: _messageHash,
            immutableContentDigest: _digestValue('I'),
            etagHash: entry.change.etagHash,
            encryptedRawRecordReference: entry.change.encryptedPayloadReference,
          ),
        );
        transaction.markChangeApplied(entry.change.changeId);
        return const CloudInboxApplyResult.applied(inboxStatusPersisted: true);
      },
    );
    expect(result.inboxStatusPersisted, isTrue);
    return entry;
  }

  test(
    'projects through the gateway journal and resolves the true source',
    () async {
      _applyChatPhase();
      final messageId = _applyMessagePhase();
      _seedMessageCheckpoint();
      final entry = await _applyAttachmentJournal();
      final attachment = store.box<Attachment>().getAll().single;
      expect(attachment.guid, _attachmentGuid);
      expect(attachment.uti, 'public.png');
      expect(attachment.transferName, 'photo.png');
      expect(attachment.mimeType, 'image/png');
      expect(attachment.totalBytes, _kPng.length);
      expect(attachment.bytes, isNull);
      expect(attachment.sourcePath, isNull);
      expect(attachment.metadata, <String, dynamic>{
        cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
        cloudAttachmentV2BodyCapabilityKey:
            CloudAttachmentBodyCapability.materializable.metadataValue,
      });
      expect(attachment.message.targetId, messageId);
      expect(store.box<Message>().get(messageId)!.hasAttachments, isTrue);
      expect(store.box<CloudRecordMapEntity>().count(), 1);
      expect(store.box<CloudSemanticReplayEntity>().count(), 1);
      expect(store.box<CloudInboxChangeEntity>().count(), 1);
      final replay = store.box<CloudSemanticReplayEntity>().getAll().single;
      expect(replay.terminalOutcome, 'applied');
      expect(replay.logicalEntityKeyHash, _attachmentHash);
      final source = CloudAttachmentSourceResolver(
        store: store,
      ).resolve(
        scope: attachmentScope,
        generation: _attachmentGeneration,
        canonicalGuid: _attachmentGuid,
      );
      expect(source.logicalEntityKeyHash, _attachmentHash);
      expect(source.recordIdHash, entry.change.recordIdHash);
      expect(source.etagHash, entry.change.etagHash);
      expect(source.payloadSha256, entry.change.payloadSha256);
      expect(source.replayOutcome, 'applied');
      expect(
        source.expectedCanonicalGuidSha256,
        _destinationGuidSha256(_attachmentGuid),
      );
      expect(attachmentScope.persistenceLane, CloudSyncPersistenceLane.semanticV2);
      expect(attachment.existsOnDisk, isFalse);
      File(attachment.path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(_kPng);
      expect(attachment.existsOnDisk, isTrue);
      expect(File(attachment.path).readAsBytesSync(), _kPng);
    },
  );

  test('retries the same attachment after its parent arrives', () async {
    _applyChatPhase();
    _seedMessageCheckpoint();
    final payload = _imagePayload();
    final snapshot = _imageSnapshot();
    final applySame = () => _newAdapter(
      store: store,
      activeScopeProvider: () => CloudCanonicalActiveScope(
        scope: attachmentScope,
        generation: _attachmentGeneration,
      ),
      resolver: resolver,
      messageDependencyScope: CloudCanonicalActiveScope(
        scope: messageScope,
        generation: _messageGeneration,
      ),
      semanticApplyEnabled: true,
      allowAttachmentMetadataUpserts: true,
    ).applyEntity(
      scope: attachmentScope,
      generation: _attachmentGeneration,
      payload: payload,
      snapshot: snapshot,
    );
    // The parent message row is absent, so this exact payload must fail
    // closed with the owner-unproven safe code.
    expect(
      applySame,
      throwsA(_failureCode('canonical_identity_owner_unproven')),
    );
    expect(store.box<Attachment>().count(), 0);
    // Parent arrives through the pipeline; the SAME payload then commits,
    // and replaying it once more creates no duplicate row or relation.
    _applyMessagePhase();
    expect(applySame(), CloudCanonicalSemanticMutationReceipt.committed);
    _seedExactOwnershipProof(
      store,
      scope: attachmentScope,
      generation: _attachmentGeneration,
      kind: CloudEntityKind.attachment,
      logicalEntityKeyHash: _attachmentHash,
      canonicalGuid: _attachmentGuid,
    );
    expect(applySame(), CloudCanonicalSemanticMutationReceipt.committed);
    expect(store.box<Attachment>().count(), 1);
    final attachment = store.box<Attachment>().getAll().single;
    expect(attachment.guid, _attachmentGuid);
    expect(attachment.message.targetId, isNotNull);
  });

  testWidgets('renders the projected attachment from its cached file', (
    tester,
  ) async {
    Get.reset();
    ss.settings = Settings();
    ss.settings.autoSave.value = false;
    as = _MockAttachmentsService();
    attachmentDownloader = downloads;
    Get.put<AttachmentDownloadService>(downloads);
    _applyChatPhase();
    _applyMessagePhase();
    _seedMessageCheckpoint();
    await _applyAttachmentJournal();
    final attachment = store.box<Attachment>().getAll().single;
    File(attachment.path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(_kPng);
    expect(attachment.existsOnDisk, isTrue);
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              height: 220,
              child: MediaGalleryCard(
                key: ValueKey(attachment.guid),
                attachment: attachment,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ImageDisplay), findsOneWidget);
    // The decoded frame must actually resolve, not just mount a loader.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final imageDisplays = tester
        .widgetList<ImageDisplay>(find.byType(ImageDisplay))
        .toList();
    expect(imageDisplays, hasLength(1));
    // The frame must actually decode to the synthetic 1x1 PNG dimensions;
    // a mounted loader or error-only state fails here, boundedly.
    final decodedCompleter = Completer<ui.Image>();
    tester
        .widget<Image>(find.byType(Image))
        .image
        .resolve(const ImageConfiguration())
        .addListener(
          ImageStreamListener((info, _) {
            if (!decodedCompleter.isCompleted) {
              decodedCompleter.complete(info.image);
            }
          }),
        );
    final decoded = await tester.runAsync(
      () => decodedCompleter.future.timeout(const Duration(seconds: 10)),
    );
    expect(decoded, isNotNull);
    expect(decoded!.width, 1);
    expect(decoded!.height, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  });
}

// Labeled mock: answers gallery-thumbnail requests with the input path.
class _MockAttachmentsService extends AttachmentsService {
  @override
  Future<String?> getImageGalleryThumbnail(String path) async => path;
}

// File-local copies of established suite harness pieces below.
ObjectBoxCanonicalSemanticEntityAdapter _newAdapter({
  required Store store,
  required CloudCanonicalActiveScope? Function() activeScopeProvider,
  required CloudCanonicalIdentityResolver resolver,
  CloudCanonicalActiveScope? chatDependencyScope,
  CloudCanonicalActiveScope? messageDependencyScope,
  CloudSyncSemanticDiagnosticRecorder? diagnosticRecorder,
  bool semanticApplyEnabled = false,
  bool allowExistingChatPresentationUpdates = false,
  bool allowChatUpserts = false,
  bool allowExistingChatDisplayNameClears = false,
  bool allowMessageUpserts = false,
  bool allowReactionUpserts = false,
  bool allowAttachmentMetadataUpserts = false,
}) => ObjectBoxCanonicalSemanticEntityAdapter(
  store: store,
  activeScopeProvider: activeScopeProvider,
  identityResolver: resolver,
  chatDependencyScope: chatDependencyScope,
  messageDependencyScope: messageDependencyScope,
  diagnosticRecorder: diagnosticRecorder,
  semanticApplyEnabled: semanticApplyEnabled,
  allowExistingChatPresentationUpdates: allowExistingChatPresentationUpdates,
  allowChatUpserts: allowChatUpserts,
  allowExistingChatDisplayNameClears: allowExistingChatDisplayNameClears,
  allowMessageUpserts: allowMessageUpserts,
  allowAttachmentMetadataUpserts: allowAttachmentMetadataUpserts,
  allowReactionUpserts: allowReactionUpserts,
);

CloudChatEntityPayload _chatPayload({
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  String? displayName = 'Cloud chat',
  CloudSemanticFieldState? displayNameState,
  Iterable<String> participantHandles = const [],
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticChatStyle style = CloudSemanticChatStyle.direct,
  Iterable<CloudSemanticChatAlias>? aliases,
  int? groupVersion,
  String? groupId,
  String? originalGroupId,
}) => CloudChatEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  chatIdentifier: chatIdentifier,
  groupId: groupId,
  originalGroupId: originalGroupId,
  displayName: displayName,
  displayNameState: displayNameState,
  participantHandles: participantHandles,
  aliases:
      aliases ??
      [
        CloudSemanticChatAlias(
          kind: CloudSemanticChatAliasKind.serviceIdentifier,
          keyHash: _testChatAliasHash(chatIdentifier),
        ),
        if (groupId != null)
          CloudSemanticChatAlias(
            kind: CloudSemanticChatAliasKind.groupId,
            keyHash: _testChatAliasHash(groupId),
          ),
      ],
  service: service,
  style: style,
  groupVersionState: groupVersion == null
      ? CloudSemanticFieldState.absent
      : CloudSemanticFieldState.value,
  groupVersion: groupVersion,
);

CloudMessageEntityPayload _messagePayload({
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  DateTime? createdAt,
  String? subject = 'Cloud subject',
  String? body = 'Cloud body',
  String senderHandle = 'mailto:sender@example.com',
  CloudSemanticFieldState subjectState = CloudSemanticFieldState.value,
  CloudSemanticFieldState bodyState = CloudSemanticFieldState.value,
  DateTime? readAt,
  DateTime? deliveredAt,
  CloudSemanticFieldState? readAtState,
  CloudSemanticFieldState? deliveredAtState,
  String? effect,
  CloudSemanticFieldState? effectState,
  Iterable<CloudSemanticAttributedBody> attributedBodies = const [],
  CloudSemanticFieldState? attributedBodiesState,
  Uint8List? decodedExtensionPayload,
  CloudSyncPreparedExtension? preparedExtension,
  String? balloonBundleId,
  CloudSemanticFieldState? balloonBundleIdState,
  CloudSemanticFieldState? decodedExtensionPayloadState,
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticKnownMessageFlags? knownFlags,
  String? chatAliasKeyHash,
  String? chatIdExactGuidLogicalKeyHash,
  String? chatIdBareDirectServiceIdentifierAliasKeyHash,
  Iterable<CloudSemanticChatAlias> chatIdAliasCandidates = const [],
  String? msgProto4GroupIdAliasKeyHash,
  String? replyParentCanonicalGuid,
  String? replyParentLogicalKeyHash,
  String? replyParentPart,
  CloudSemanticAssociationKind associationKind =
      CloudSemanticAssociationKind.none,
  String? associationParentLogicalKeyHash,
  String? associationParentCanonicalGuid,
  int? associationParentPart,
  int? associatedRangeLocation,
  int? associatedRangeLength,
}) => CloudMessageEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  chatIdentifier: chatIdentifier,
  chatAliasKeyHash: chatAliasKeyHash ?? _testChatAliasHash(chatIdentifier),
  chatIdExactGuidLogicalKeyHash: chatIdExactGuidLogicalKeyHash,
  chatIdBareDirectServiceIdentifierAliasKeyHash:
      chatIdBareDirectServiceIdentifierAliasKeyHash,
  chatIdAliasCandidates: chatIdAliasCandidates,
  msgProto4GroupIdAliasKeyHash: msgProto4GroupIdAliasKeyHash,
  replyParentCanonicalGuid: replyParentCanonicalGuid,
  replyParentLogicalKeyHash: replyParentLogicalKeyHash,
  replyParentPart: replyParentPart,
  associationKind: associationKind,
  associationParentLogicalKeyHash: associationParentLogicalKeyHash,
  associationParentCanonicalGuid: associationParentCanonicalGuid,
  associationParentPart: associationParentPart,
  associatedRangeLocation: associatedRangeLocation,
  associatedRangeLength: associatedRangeLength,
  body: body,
  senderHandle: senderHandle,
  createdAt: createdAt ?? testEpoch,
  service: service,
  subjectState: subjectState,
  subject: subject,
  bodyState: bodyState,
  attributedBodiesState:
      attributedBodiesState ??
      (attributedBodies.isEmpty
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  attributedBodies: attributedBodies,
  decodedExtensionPayloadState:
      decodedExtensionPayloadState ??
      (decodedExtensionPayload == null
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  decodedExtensionPayload: decodedExtensionPayload,
  preparedExtension: preparedExtension,
  balloonBundleId: balloonBundleId,
  balloonBundleIdState: balloonBundleIdState ??
      (balloonBundleId == null
          ? CloudSemanticFieldState.absent
          : CloudSemanticFieldState.value),
  effectState:
      effectState ?? (effect == null ? CloudSemanticFieldState.absent : CloudSemanticFieldState.value),
  effect: effect,
  readAtState:
      readAtState ?? (readAt == null ? CloudSemanticFieldState.absent : CloudSemanticFieldState.value),
  readAt: readAt,
  deliveredAtState:
      deliveredAtState ?? (deliveredAt == null ? CloudSemanticFieldState.absent : CloudSemanticFieldState.value),
  deliveredAt: deliveredAt,
  knownFlags: knownFlags ?? _messageFlags(fromMe: false),
);

CloudAttachmentEntityPayload _attachmentPayload({
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String? ownerLogicalKeyHash,
  required String? ownerCanonicalGuid,
  required int? ownerPart,
  String? uti,
  CloudSemanticFieldState utiState = CloudSemanticFieldState.absent,
  String? fileName = 'attachment.bin',
  CloudSemanticFieldState fileNameState = CloudSemanticFieldState.value,
  String? mimeType = 'application/octet-stream',
  CloudSemanticFieldState? mimeTypeState,
  CloudAttachmentBodyCapability bodyCapability =
      CloudAttachmentBodyCapability.materializable,
  int? totalBytes,
  CloudSemanticFieldState totalBytesState = CloudSemanticFieldState.absent,
  bool? isOutgoing,
  CloudSemanticFieldState isOutgoingState = CloudSemanticFieldState.absent,
  required String? protectedLocalReference,
  CloudSemanticFieldState protectedLocalReferenceState =
      CloudSemanticFieldState.value,
}) => CloudAttachmentEntityPayload(
  logicalEntityKeyHash: logicalEntityKeyHash,
  canonicalGuid: canonicalGuid,
  ownerLogicalKeyHash: ownerLogicalKeyHash,
  ownerCanonicalGuid: ownerCanonicalGuid,
  ownerPart: ownerPart,
  utiState: utiState,
  uti: uti,
  fileNameState: fileNameState,
  fileName: fileName,
  mimeTypeState: mimeTypeState,
  mimeType: mimeType,
  bodyCapability: bodyCapability,
  totalBytesState: totalBytesState,
  totalBytes: totalBytes,
  isOutgoingState: isOutgoingState,
  isOutgoing: isOutgoing,
  protectedLocalReferenceState: protectedLocalReferenceState,
  protectedLocalReference: protectedLocalReference,
);

CloudSemanticSnapshot _snapshot(
  CloudEntityKind kind,
  String logicalEntityKeyHash, {
  String? parentLogicalKeyHash,
}) => CloudSemanticSnapshot(
  kind: kind,
  logicalEntityKeyHash: logicalEntityKeyHash,
  parentLogicalKeyHash: parentLogicalKeyHash,
  immutableContentDigest: 'content-digest',
);

String _testChatAliasHash(String value) => base64Url.encode(
  sha256.convert(utf8.encode('test-chat-alias' + String.fromCharCode(0x1f) + value)).bytes,
).replaceAll('=', '');

void _seedExactOwnershipProof(
  Store store, {
  required CloudSyncScope scope,
  required int generation,
  required CloudEntityKind kind,
  required String logicalEntityKeyHash,
  required String canonicalGuid,
}) {
  store.box<CloudSemanticSnapshotEntity>().put(
    CloudSemanticSnapshotEntity(
      snapshotKey:
          'ownership-proof:' + generation.toString() + ':' + kind.name + ':' + logicalEntityKeyHash + ':' + canonicalGuid,
      scopeGenerationKey: _semanticScopeGenerationKey(scope, generation),
      scopeKey: _semanticScopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      entityKind: kind.name,
      logicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: kind,
        logicalEntityKeyHash: logicalEntityKeyHash,
        canonicalGuid: canonicalGuid,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: generation,
            canonicalGuid: canonicalGuid,
          ),
      updatedAtMs: testEpoch.millisecondsSinceEpoch,
    ),
  );
}

String _semanticScopeKey(CloudSyncScope scope) =>
    'scope2:' + sha256.convert(utf8.encode(scope.storageKey)).toString();

String _semanticScopeGenerationKey(CloudSyncScope scope, int generation) =>
    'semantic-generation4:' + sha256.convert(utf8.encode(_semanticScopeKey(scope) + String.fromCharCode(0x1f) + generation.toString())).toString();

CloudSemanticKnownMessageFlags _messageFlags({
  required bool fromMe,
  bool delivered = false,
  bool read = false,
  bool hasDataDetectorResults = false,
  bool deliveredQuietly = false,
  bool didNotifyRecipient = false,
}) => CloudSemanticKnownMessageFlags(
  fromMe: fromMe,
  delivered: delivered,
  read: read,
  hasDataDetectorResults: hasDataDetectorResults,
  deliveredQuietly: deliveredQuietly,
  didNotifyRecipient: didNotifyRecipient,
);

final class _Resolver implements CloudCanonicalIdentityResolver {
  final Map<String, String> _values = {};
  final Map<String, CloudCanonicalIdentityOwner> _owners = {};

  void put({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
    required String canonicalGuid,
  }) {
    _values[_key(scope, generation, kind, logicalEntityKeyHash)] =
        canonicalGuid;
    _owners.putIfAbsent(
      scope.storageKey + ':' + generation.toString() + ':' + canonicalGuid,
      () => CloudCanonicalIdentityOwner(
        kind: kind,
        logicalEntityKeyHash: logicalEntityKeyHash,
      ),
    );
  }

  @override
  String? resolveCanonicalGuid({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) => _values[_key(scope, generation, kind, logicalEntityKeyHash)];

  @override
  CloudCanonicalIdentityOwner? resolveCanonicalIdentityOwner({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) => _owners[scope.storageKey + ':' + generation.toString() + ':' + canonicalGuid];

  String _key(
    CloudSyncScope scope,
    int generation,
    CloudEntityKind kind,
    String logicalEntityKeyHash,
  ) => scope.storageKey + ':' + generation.toString() + ':' + kind.name + ':' + logicalEntityKeyHash;
}

Matcher _failureCode(String safeCode) {
  return isA<CloudSyncFailure>().having(
    (failure) => failure.safeCode,
    'safeCode',
    safeCode,
  );
}

String _digestValue(String character) => List.filled(43, character).join();

String _sha256hex(String value) => sha256.convert(utf8.encode(value)).toString();

String _protectedReference(String character) =>
    'obcs2.ref.' + _digestValue(character);

String _scopedDigest(CloudSyncScope scope, String purpose, String value) =>
    purpose + ':' + _sha256hex(scope.storageKey + String.fromCharCode(0x1f) + purpose + String.fromCharCode(0x1f) + value);

String _fixtureChangeKey(CloudSyncScope scope, int generation, String changeId) =>
    _scopedDigest(scope, generation == 1 ? 'change' : 'change-generation-' + generation.toString(), changeId);

CloudInboxEntry _journalEntry() {
  final scope = _attachmentScope();
  final change = CloudFetchedChange(
    changeId: _digestValue('C'),
    recordIdHash: _digestValue('R'),
    etagHash: _digestValue('E'),
    type: CloudChangeType.save,
    encryptedServerRecordId: _protectedReference('S'),
    protectedSystemFieldsReference: _protectedReference('F'),
    encryptedPayloadReference: _protectedReference('W'),
    payloadSha256: _sha256hex('disposable-payload'),
    isTombstone: false,
    serverModifiedAt: testEpoch,
  );
  return CloudInboxEntry(
    scope: scope,
    sequence: 1,
    change: change,
    status: CloudInboxStatus.pending,
    attemptCount: 0,
    createdAt: testEpoch,
    batchId: 'disposable-batch-1',
    generation: _attachmentGeneration,
  );
}

void _seedJournalFence(
  Store store, {
  required CloudInboxEntry entry,
  required CloudCoordinatorLeaseFence leaseFence,
}) {
  final scope = entry.scope;
  final now = testEpoch;
  store.runInTransaction(TxMode.write, () {
    store.box<CloudSyncCheckpointEntity>().put(
      CloudSyncCheckpointEntity(
        checkpointKey: _semanticScopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        container: scope.container,
        database: scope.database,
        zone: scope.zone,
        streamKind: scope.streamKind.name,
        schemaVersion: scope.schemaVersion,
        persistenceLane: scope.persistenceLane.name,
        generation: entry.generation,
        lastBatchId: entry.batchId,
        fetchedSequence: entry.sequence,
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
    );
    store.box<CloudSyncLeaseEntity>().put(
      CloudSyncLeaseEntity(
        leaseKey: _scopedDigest(scope, 'coordinator-lease', 'v1'),
        scopeKey: _semanticScopeKey(scope),
        accountFingerprint: scope.accountFingerprint,
        ownerIdHash: _sha256hex('coordinator-owner' + String.fromCharCode(0x1f) + leaseFence.ownerId),
        generation: leaseFence.generation,
        acquiredAtMs: now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch,
        expiresAtMs: now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      ),
    );
    _putPendingJournalEntry(store, entry: entry);
  });
}

void _putPendingJournalEntry(Store store, {required CloudInboxEntry entry}) {
  final scope = entry.scope;
  final change = entry.change;
  store.box<CloudInboxChangeEntity>().put(
    CloudInboxChangeEntity(
      changeKey: _fixtureChangeKey(scope, entry.generation, change.changeId),
      changeIdHash: change.changeId,
      scopeKey: _semanticScopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      zone: scope.zone,
      serverRecordIdHash: change.recordIdHash,
      etagHash: change.etagHash,
      changeType: change.type.name,
      encryptedServerRecordId: change.encryptedServerRecordId,
      protectedSystemFieldsRef: change.protectedSystemFieldsReference,
      encryptedPayloadRef: change.encryptedPayloadReference,
      payloadSha256: change.payloadSha256,
      batchId: entry.batchId,
      generation: entry.generation,
      fetchSequence: entry.sequence,
      status: CloudInboxStatus.pending.index,
      isTombstone: change.isTombstone,
      serverModifiedAtMs:
          change.serverModifiedAt == null ? 0 : change.serverModifiedAt!.toUtc().millisecondsSinceEpoch,
      serverModifiedAtFormatVersion: change.serverModifiedAt == null
          ? null
          : cloudInboxServerModifiedAtUnixEpochFormat,
      createdAtMs: entry.createdAt.millisecondsSinceEpoch,
      updatedAtMs: testEpoch.millisecondsSinceEpoch,
    ),
  );
}

String _destinationGuidSha256(String canonicalGuid) {
  final bytes = utf8.encode(canonicalGuid);
  return _sha256hex(
    'cloud-attachment-canonical-guid-v1' +
        String.fromCharCode(0x1f) +
        bytes.length.toString() +
        ':' +
        canonicalGuid,
  );
}
