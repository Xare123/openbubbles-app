// Disposable ObjectBox integration check for CloudKit V2 media handling.
//
// Synthetic, credential-free inputs only. A fresh temporary ObjectBox store is
// opened per test and deleted afterwards. Chat, message, and attachment rows
// are produced exclusively through ObjectBoxCanonicalSemanticEntityAdapter
// (the normal pipeline); only ownership-proof and alias entities are seeded
// as harness inputs, mirroring objectbox_canonical_semantic_entity_adapter_test
// (file-local helper copies are marked below). A tiny synthetic 1x1 PNG stands
// in for a downloaded body. The single labeled mock is the attachments-service
// thumbnail fake also used by the gallery widget suite. No network, no live
// writes, no real account data.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/conversation_details/widgets/media_gallery_card.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
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

const _generation = 4;
const _chatHash = 'disposable-chat-hash';
const _messageHash = 'disposable-message-hash';
const _attachmentHash = 'disposable-attachment-hash';
const _chatGuid = 'disposable-chat-guid';
const _messageGuid = 'disposable-message-guid';
const _attachmentGuid = 'disposable-message-guid_0';
const _chatIdentifier = 'iMessage;-;friend@example.com';
const _senderHandle = 'mailto:friend@example.com';

CloudSyncScope _scope() => CloudSyncScope(
  accountFingerprint: testAccountFingerprintA,
  container: 'container',
  database: 'private',
  zone: 'messageManateeZone',
  persistenceLane: CloudSyncPersistenceLane.semanticV2,
);

void main() {
  late Directory storeDir;
  late Directory filesRoot;
  late Store store;
  late _Resolver resolver;
  late AttachmentDownloadService downloads;
  final scope = _scope();

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
        scope: scope,
        generation: _generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: _chatHash,
        canonicalGuid: _chatGuid,
      )
      ..put(
        scope: scope,
        generation: _generation,
        kind: CloudEntityKind.message,
        logicalEntityKeyHash: _messageHash,
        canonicalGuid: _messageGuid,
      )
      ..put(
        scope: scope,
        generation: _generation,
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

  ObjectBoxCanonicalSemanticEntityAdapter _adapter() => _newAdapter(
    store: store,
    activeScopeProvider: () =>
        CloudCanonicalActiveScope(scope: scope, generation: _generation),
    resolver: resolver,
    semanticApplyEnabled: true,
    allowChatUpserts: true,
    allowMessageUpserts: true,
    allowAttachmentMetadataUpserts: true,
  );

  int _projectConversation() {
    final adapter = _adapter();
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: _generation,
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
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: _generation,
      logicalEntityKeyHash: _chatHash,
      canonicalGuid: _chatGuid,
      chatIdentifier: _chatIdentifier,
      chatId: chatId,
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: _generation,
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
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: _generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: _messageHash,
      canonicalGuid: _messageGuid,
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: _generation,
        payload: _attachmentPayload(
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
        ),
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          _attachmentHash,
          parentLogicalKeyHash: _messageHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    return store.box<Attachment>().getAll().single.id!;
  }

  test('projects chat, message, and attachment and caches the file', () {
    final attachmentId = _projectConversation();
    expect(
      _adapter().applyEntity(
        scope: scope,
        generation: _generation,
        payload: _attachmentPayload(
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
        ),
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          _attachmentHash,
          parentLogicalKeyHash: _messageHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    final attachment = store.box<Attachment>().get(attachmentId)!;
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
    final messageId = store.box<Message>().getAll().single.id!;
    expect(attachment.message.targetId, messageId);
    expect(store.box<Message>().get(messageId)!.hasAttachments, isTrue);
    expect(scope.persistenceLane, CloudSyncPersistenceLane.semanticV2);
    expect(attachment.existsOnDisk, isFalse);
    File(attachment.path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(_kPng);
    expect(attachment.existsOnDisk, isTrue);
    expect(File(attachment.path).readAsBytesSync(), _kPng);
  });

  test('refuses an unknown owner, then commits once the owner arrives', () {
    final adapter = _adapter();
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: _generation,
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
    _seedChatOwnershipAndAlias(
      store,
      scope: scope,
      generation: _generation,
      logicalEntityKeyHash: _chatHash,
      canonicalGuid: _chatGuid,
      chatIdentifier: _chatIdentifier,
      chatId: chatId,
    );
    expect(
      () => adapter.applyEntity(
        scope: scope,
        generation: _generation,
        payload: _attachmentPayload(
          logicalEntityKeyHash: _attachmentHash,
          canonicalGuid: _attachmentGuid,
          ownerLogicalKeyHash: 'ghost-owner-hash',
          ownerCanonicalGuid: 'ghost-message-guid',
          ownerPart: 0,
          fileName: 'photo.png',
          mimeType: 'image/png',
          protectedLocalReference: 'protected:disposable-synthetic',
        ),
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          _attachmentHash,
          parentLogicalKeyHash: 'ghost-owner-hash',
        ),
      ),
      throwsA(isA<CloudSyncFailure>()),
    );
    expect(store.box<Attachment>().count(), 0);
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: _generation,
        payload: _messagePayload(
          logicalEntityKeyHash: _messageHash,
          canonicalGuid: _messageGuid,
          chatIdentifier: _chatIdentifier,
          senderHandle: _senderHandle,
          createdAt: testEpoch,
        ),
        snapshot: _snapshot(CloudEntityKind.message, _messageHash),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    _seedExactOwnershipProof(
      store,
      scope: scope,
      generation: _generation,
      kind: CloudEntityKind.message,
      logicalEntityKeyHash: _messageHash,
      canonicalGuid: _messageGuid,
    );
    expect(
      adapter.applyEntity(
        scope: scope,
        generation: _generation,
        payload: _attachmentPayload(
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
        ),
        snapshot: _snapshot(
          CloudEntityKind.attachment,
          _attachmentHash,
          parentLogicalKeyHash: _messageHash,
        ),
      ),
      CloudCanonicalSemanticMutationReceipt.committed,
    );
    expect(store.box<Attachment>().getAll().single.guid, _attachmentGuid);
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
    final attachmentId = _projectConversation();
    final attachment = store.box<Attachment>().get(attachmentId)!;
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

// File-local copies of the canonical adapter suite harness below.
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
  allowReactionUpserts: allowReactionUpserts,
  allowAttachmentMetadataUpserts: allowAttachmentMetadataUpserts,
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
  chatAliasKeyHash: chatAliasKeyHash,
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

void _seedChatOwnershipAndAlias(
  Store store, {
  required CloudSyncScope scope,
  required int generation,
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  required int chatId,
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticChatAliasKind aliasKind =
      CloudSemanticChatAliasKind.serviceIdentifier,
  bool legacyBinding = false,
}) {
  _seedExactOwnershipProof(
    store,
    scope: scope,
    generation: generation,
    kind: CloudEntityKind.chat,
    logicalEntityKeyHash: logicalEntityKeyHash,
    canonicalGuid: canonicalGuid,
  );
  _seedChatAliasClaim(
    store,
    scope: scope,
    generation: generation,
    logicalEntityKeyHash: logicalEntityKeyHash,
    canonicalGuid: canonicalGuid,
    chatIdentifier: chatIdentifier,
    chatId: chatId,
    service: service,
    aliasKind: aliasKind,
    legacyBinding: legacyBinding,
  );
}

void _seedChatAliasClaim(
  Store store, {
  required CloudSyncScope scope,
  required int generation,
  required String logicalEntityKeyHash,
  required String canonicalGuid,
  required String chatIdentifier,
  required int chatId,
  CloudSemanticService service = CloudSemanticService.iMessage,
  CloudSemanticChatAliasKind aliasKind =
      CloudSemanticChatAliasKind.serviceIdentifier,
  bool legacyBinding = false,
}) {
  final aliasKeyHash = _testChatAliasHash(chatIdentifier);
  final bindingKey = _testChatAliasBindingKey(
    scope: scope,
    generation: generation,
    service: service,
    kind: aliasKind,
    aliasKeyHash: aliasKeyHash,
    logicalEntityKeyHash: logicalEntityKeyHash,
    legacy: legacyBinding,
  );
  store.box<CloudSemanticChatAliasEntity>().put(
    CloudSemanticChatAliasEntity(
      bindingKey: bindingKey,
      scopeGenerationKey: _semanticScopeGenerationKey(scope, generation),
      scopeKey: _semanticScopeKey(scope),
      accountFingerprint: scope.accountFingerprint,
      container: scope.container,
      database: scope.database,
      zone: scope.zone,
      streamKind: scope.streamKind.name,
      schemaVersion: scope.schemaVersion,
      generation: generation,
      service: service.name,
      aliasKind: aliasKind.name,
      aliasKeyHash: aliasKeyHash,
      chatLogicalEntityKeyHash: logicalEntityKeyHash,
      canonicalGuidHash: CloudCanonicalIdentityDigest.forCanonicalGuid(
        scope: scope,
        generation: generation,
        kind: CloudEntityKind.chat,
        logicalEntityKeyHash: logicalEntityKeyHash,
        canonicalGuid: canonicalGuid,
      ),
      canonicalGuidLookupHash:
          CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
            scope: scope,
            generation: generation,
            canonicalGuid: canonicalGuid,
          ),
      chatId: chatId,
      updatedAtMs: testEpoch.millisecondsSinceEpoch,
    ),
  );
}

String _testChatAliasBindingKey({
  required CloudSyncScope scope,
  required int generation,
  required CloudSemanticService service,
  required CloudSemanticChatAliasKind kind,
  required String aliasKeyHash,
  required String logicalEntityKeyHash,
  bool legacy = false,
}) {
  final sep = String.fromCharCode(0x1f);
  final base = scope.storageKey + sep + generation.toString() + sep + service.name + sep + kind.name + sep + aliasKeyHash;
  if (legacy) {
    return 'semantic-chat-alias1:' + sha256.convert(utf8.encode(scope.storageKey + sep + generation.toString() + sep + service.name + sep + kind.name + sep + aliasKeyHash)).toString();
  }
  if (kind == CloudSemanticChatAliasKind.serviceIdentifier) {
    return 'semantic-chat-strong2:' + sha256.convert(utf8.encode(base)).toString();
  }
  return 'semantic-chat-claim2:' + sha256.convert(utf8.encode(base + sep + logicalEntityKeyHash)).toString();
}

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
