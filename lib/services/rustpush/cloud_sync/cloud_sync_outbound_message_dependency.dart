import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_binding.dart';
import 'cloud_sync_outbound_group_binding.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_reaction_send_identity.dart';
import 'cloud_sync_record_maps.dart';
import 'objectbox_canonical_semantic_entity_adapter.dart';

/// The account-bound journal supplies this inside the caller's transaction.
/// Null means there is no qualifying local readback; restored proof is required.
typedef CloudSyncConfirmedLocalParentReader =
    List<Object>? Function(Message parent);

/// Captures every durable local dependency needed by an outbound Message.
///
/// Plain-text sends retain the exact v1 Chat binding. Reactions additionally
/// pin a restored parent or a journal-owned parent with exact readback. The v2
/// wrapper contains digests and local row IDs only, never a GUID, body, route,
/// or Apple record identifier.
String requireCloudSyncLocalSendDependencies({
  required Store store,
  required CloudSyncScope messageScope,
  required Message message,
  CloudSyncConfirmedLocalParentReader? readConfirmedLocalParent,
}) {
  final hasAssociation =
      message.associatedMessageGuid != null ||
      message.associatedMessagePart != null ||
      message.associatedMessageType != null ||
      message.associatedMessageEmoji != null;
  if (!hasAssociation) {
    return message.chat.target?.style == 43
        ? requireCloudSyncRestoredGroupChat(
            store: store,
            messageScope: messageScope,
            message: message,
          )
        : requireCloudSyncRestoredDirectChat(
            store: store,
            messageScope: messageScope,
            message: message,
          );
  }
  Never reject() => throw CloudSyncFailure(
    category: CloudFailureCategory.dependency,
    safeCode: 'cloud_sync_local_send_parent_not_ready',
  );
  final chat = message.chat.target;
  final stableGuid = message.guid;
  if (chat == null ||
      stableGuid == null ||
      CloudSyncReactionSendIdentity.capture(message, chat, stableGuid) ==
          null) {
    reject();
  }
  final chatBinding = requireCloudSyncRestoredDirectChat(
    store: store,
    messageScope: messageScope,
    message: message,
  );
  final parentGuid = message.associatedMessageGuid!;
  final parent = _unique(
    store.box<Message>().query(Message_.guid.equals(parentGuid)),
  );
  if (!_validParent(parent, chat.id)) reject();
  final parentBinding =
      readConfirmedLocalParent?.call(parent!) ??
      _requireRestoredParent(
        store: store,
        messageScope: messageScope,
        parent: parent!,
      );
  return jsonEncode([2, chatBinding, parentBinding]);
}

/// Revalidates the v1 Chat binding or v2 Chat-plus-parent binding.
///
/// A fully applied update to the same pinned parent record is accepted. A
/// generation, owner, parent row, Chat, or server-record change is not.
void requireCloudSyncAdoptedLocalSendDependencies({
  required Store store,
  required CloudSyncScope messageScope,
  required String? binding,
  int? expectedChatId,
  CloudSyncConfirmedLocalParentReader? readConfirmedLocalParent,
}) {
  Never reject() => throw CloudSyncFailure(
    category: CloudFailureCategory.dependency,
    safeCode: 'cloud_sync_local_send_parent_not_ready',
  );
  void validateChatBinding() {
    dynamic chatDecoded;
    try {
      chatDecoded = binding == null ? null : jsonDecode(binding);
    } on FormatException {
      chatDecoded = null;
    }
    if (chatDecoded is List && chatDecoded.isNotEmpty && chatDecoded[0] == 3) {
      requireCloudSyncAdoptedGroupChatDependency(
        store: store,
        messageScope: messageScope,
        binding: binding,
        expectedChatId: expectedChatId,
      );
      return;
    }
    requireCloudSyncAdoptedChatDependency(
      store: store,
      messageScope: messageScope,
      binding: binding,
      expectedChatId: expectedChatId,
    );
  }

  if (binding == null || binding.length > 2048) {
    validateChatBinding();
    return;
  }
  final dynamic decoded;
  try {
    decoded = jsonDecode(binding);
  } on FormatException {
    validateChatBinding();
    return;
  }
  if (decoded is! List || decoded.length != 3 || decoded[0] != 2) {
    // Backward compatibility is intentional: plaintext admission remains the
    // old helper's byte-for-byte v1 format and validation behavior.
    validateChatBinding();
    return;
  }
  if (decoded[1] is! String || decoded[2] is! List) reject();
  final chatBinding = decoded[1] as String;
  requireCloudSyncAdoptedChatDependency(
    store: store,
    messageScope: messageScope,
    binding: chatBinding,
    expectedChatId: expectedChatId,
  );
  final dynamic chatDecoded;
  try {
    chatDecoded = jsonDecode(chatBinding);
  } on FormatException {
    reject();
  }
  if (chatDecoded is! List ||
      chatDecoded.length != 9 ||
      chatDecoded[0] != 1 ||
      chatDecoded[3] is! int ||
      (chatDecoded[3] as int) <= 0) {
    reject();
  }
  final parentBinding = decoded[2] as List;
  final isRestored = parentBinding.length == 8 && parentBinding[0] == 1;
  final isLocalReadback = parentBinding.length == 10 && parentBinding[0] == 2;
  if ((!isRestored && !isLocalReadback) ||
      parentBinding[1] is! String ||
      parentBinding[2] is! int ||
      parentBinding[3] is! int ||
      parentBinding[4] is! String ||
      parentBinding[5] is! String ||
      parentBinding[6] is! String ||
      parentBinding[7] is! String) {
    reject();
  }
  if (isLocalReadback &&
      (parentBinding[8] is! int ||
          (parentBinding[8] as int) <= 0 ||
          parentBinding[9] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(parentBinding[9] as String))) {
    reject();
  }
  final parentId = parentBinding[3] as int;
  final parent = parentId > 0 ? store.box<Message>().get(parentId) : null;
  if (!_validParent(parent, chatDecoded[3] as int)) reject();
  if (isLocalReadback) {
    final localProof = readConfirmedLocalParent?.call(parent!);
    if (localProof != null) {
      if (jsonEncode(localProof) != jsonEncode(parentBinding)) reject();
      return;
    }
    // Once an inbox record exists, the earlier readback must not override it.
    // A fully applied save of the same pinned identity can replace the proof;
    // pending updates, tombstones and retargeting still fail below.
  }
  final current = _requireRestoredParent(
    store: store,
    messageScope: messageScope,
    parent: parent!,
    expectedGeneration: parentBinding[2] as int,
    expectedLookupHash: parentBinding[4] as String,
    expectedCanonicalHash: parentBinding[5] as String,
    expectedLogicalKeyHash: parentBinding[6] as String,
    expectedServerRecordIdHash: parentBinding[7] as String,
  );
  if (isRestored
      ? jsonEncode(current) != jsonEncode(parentBinding)
      : jsonEncode(current.sublist(1)) !=
            jsonEncode(parentBinding.sublist(1, 8))) {
    reject();
  }
}

List<Object> _requireRestoredParent({
  required Store store,
  required CloudSyncScope messageScope,
  required Message parent,
  int? expectedGeneration,
  String? expectedLookupHash,
  String? expectedCanonicalHash,
  String? expectedLogicalKeyHash,
  String? expectedServerRecordIdHash,
}) {
  Never reject() => throw CloudSyncFailure(
    category: CloudFailureCategory.dependency,
    safeCode: 'cloud_sync_local_send_parent_not_ready',
  );
  final parentId = parent.id;
  final parentGuid = parent.guid;
  if (parentId == null || parentId <= 0 || parentGuid?.isNotEmpty != true) {
    reject();
  }
  if (messageScope.container != 'com.apple.messages.cloud' ||
      messageScope.database != 'private' ||
      messageScope.zone != 'messageManateeZone' ||
      messageScope.streamKind != CloudSyncStreamKind.messages ||
      messageScope.schemaVersion != cloudSyncSchemaVersion ||
      messageScope.persistenceLane != CloudSyncPersistenceLane.semantic) {
    reject();
  }
  final scopeKey = cloudSyncPersistentScopeKey(messageScope);
  final checkpoint = _unique(
    store.box<CloudSyncCheckpointEntity>().query(
      CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey),
    ),
  );
  if (checkpoint == null ||
      checkpoint.checkpointKey != scopeKey ||
      checkpoint.accountFingerprint != messageScope.accountFingerprint ||
      checkpoint.container != messageScope.container ||
      checkpoint.database != messageScope.database ||
      checkpoint.zone != messageScope.zone ||
      checkpoint.streamKind != messageScope.streamKind.name ||
      checkpoint.schemaVersion != messageScope.schemaVersion ||
      checkpoint.persistenceLane != messageScope.persistenceLane.name ||
      checkpoint.generation <= 0 ||
      (expectedGeneration != null &&
          checkpoint.generation != expectedGeneration)) {
    reject();
  }
  final generation = checkpoint.generation;
  final generationKey =
      'semantic-generation4:${_digest('$scopeKey\u001f$generation')}';
  final lookup = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
    scope: messageScope,
    generation: generation,
    canonicalGuid: parentGuid!,
  );
  if (expectedLookupHash != null && lookup != expectedLookupHash) reject();
  final snapshot = _unique(
    store.box<CloudSemanticSnapshotEntity>().query(
      CloudSemanticSnapshotEntity_.scopeGenerationKey
          .equals(generationKey)
          .and(
            CloudSemanticSnapshotEntity_.canonicalGuidLookupHash.equals(lookup),
          ),
    ),
  );
  if (snapshot == null ||
      snapshot.snapshotKey !=
          'semantic-snapshot4:$generationKey:message:${snapshot.logicalEntityKeyHash}' ||
      snapshot.scopeGenerationKey != generationKey ||
      snapshot.scopeKey != scopeKey ||
      snapshot.accountFingerprint != messageScope.accountFingerprint ||
      snapshot.container != messageScope.container ||
      snapshot.database != messageScope.database ||
      snapshot.zone != messageScope.zone ||
      snapshot.streamKind != messageScope.streamKind.name ||
      snapshot.schemaVersion != messageScope.schemaVersion ||
      snapshot.generation != generation ||
      snapshot.entityKind != CloudEntityKind.message.name ||
      snapshot.logicalEntityKeyHash.isEmpty ||
      snapshot.canonicalGuidLookupHash != lookup) {
    reject();
  }
  final canonicalHash = CloudCanonicalIdentityDigest.forCanonicalGuid(
    scope: messageScope,
    generation: generation,
    kind: CloudEntityKind.message,
    logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
    canonicalGuid: parentGuid,
  );
  if (snapshot.canonicalGuidHash != canonicalHash ||
      (expectedCanonicalHash != null &&
          canonicalHash != expectedCanonicalHash) ||
      (expectedLogicalKeyHash != null &&
          snapshot.logicalEntityKeyHash != expectedLogicalKeyHash)) {
    reject();
  }
  final mapping = cloudSyncFindRecordMap(
    store: store,
    scope: messageScope,
    generation: generation,
    logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
    serverRecordIdHash: expectedServerRecordIdHash,
  );
  if (mapping == null ||
      mapping.mapKey !=
          cloudSyncCanonicalRecordMapKey(
            messageScope,
            snapshot.logicalEntityKeyHash,
          ) ||
      mapping.scopeKey != scopeKey ||
      mapping.accountFingerprint != messageScope.accountFingerprint ||
      mapping.zone != messageScope.zone ||
      mapping.generation != generation ||
      mapping.logicalEntityKeyHash != snapshot.logicalEntityKeyHash ||
      !_nativeDigest.hasMatch(mapping.serverRecordIdHash) ||
      !_reference.hasMatch(mapping.encryptedServerRecordId) ||
      !_reference.hasMatch(mapping.encryptedRawRecordRef ?? '') ||
      !_nativeDigest.hasMatch(mapping.etagHash ?? '') ||
      mapping.etagHash != snapshot.etagHash) {
    reject();
  }
  final latestQuery =
      (store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey
                .equals(scopeKey)
                .and(CloudInboxChangeEntity_.generation.equals(generation))
                .and(
                  CloudInboxChangeEntity_.serverRecordIdHash.equals(
                    mapping.serverRecordIdHash,
                  ),
                ),
          )..order(
            CloudInboxChangeEntity_.fetchSequence,
            flags: Order.descending,
          ))
          .build()
        ..limit = 1;
  try {
    final latest = latestQuery.findFirst();
    if (latest == null ||
        latest.scopeKey != scopeKey ||
        latest.accountFingerprint != messageScope.accountFingerprint ||
        latest.zone != messageScope.zone ||
        latest.generation != generation ||
        latest.status != CloudInboxStatus.applied.index ||
        latest.isTombstone ||
        latest.changeType != CloudChangeType.save.name ||
        latest.etagHash != mapping.etagHash ||
        latest.encryptedServerRecordId != mapping.encryptedServerRecordId ||
        latest.encryptedPayloadRef != mapping.encryptedRawRecordRef) {
      reject();
    }
  } finally {
    latestQuery.close();
  }
  return <Object>[
    1,
    scopeKey,
    generation,
    parentId,
    lookup,
    canonicalHash,
    snapshot.logicalEntityKeyHash,
    mapping.serverRecordIdHash,
  ];
}

bool _validParent(Message? parent, int? chatId) =>
    parent != null &&
    parent.id != null &&
    parent.id! > 0 &&
    chatId != null &&
    chatId > 0 &&
    parent.chat.targetId == chatId &&
    parent.associatedMessageGuid == null &&
    parent.associatedMessagePart == null &&
    parent.associatedMessageType == null &&
    parent.associatedMessageEmoji == null &&
    parent.dateDeleted == null;

T? _unique<T>(QueryBuilder<T> builder) {
  final query = builder.build()..limit = 2;
  try {
    final rows = query.find();
    return rows.length == 1 ? rows.single : null;
  } finally {
    query.close();
  }
}

final _nativeDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _reference = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
