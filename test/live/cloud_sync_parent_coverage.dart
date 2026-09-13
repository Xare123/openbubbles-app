// Bounded cached-evidence correlation. Never admits a Chat or infers remote
// absence, participants, deletion intent, or write authority from a match.
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/rust_cloud_semantic_decoder.dart';

Future<Map<String, Object?>> observeCachedParentCoverage({
  required Store store,
  required Directory profile,
  required CloudSyncNativeAuthSnapshot auth,
  required BigInt pauseToken,
}) async {
  String durableState() => jsonEncode([
    store
        .box<CloudSyncCheckpointEntity>()
        .getAll()
        .map(
          (row) => [
            row.id,
            row.generation,
            row.fetchedSequence,
            row.appliedSequence,
            row.fetchedTokenCiphertext,
            row.pendingFetchedTokenCiphertext,
            row.pendingBatchId,
          ],
        )
        .toList(),
    store
        .box<CloudOutboxOperationEntity>()
        .getAll()
        .map((row) => [row.id, row.state, row.updatedAtMs])
        .toList(),
    store.box<Chat>().count(),
    store.box<Message>().count(),
    store.box<Attachment>().count(),
  ]);
  final before = durableState();
  CloudSyncScope scopeFor(String zone) => CloudSyncScope(
    accountFingerprint: auth.accountFingerprint,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: zone,
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  final chatScope = scopeFor('chatManateeZone');
  final messageScope = scopeFor('messageManateeZone');
  CloudSyncCheckpointEntity checkpoint(CloudSyncScope scope) {
    final query = store
        .box<CloudSyncCheckpointEntity>()
        .query(
          CloudSyncCheckpointEntity_.checkpointKey.equals(
            cloudSyncPersistentScopeKey(scope),
          ),
        )
        .build();
    try {
      final result = query.findUnique();
      if (result == null) {
        throw StateError('parent_coverage_checkpoint_missing');
      }
      return result;
    } finally {
      query.close();
    }
  }

  final chatCheckpoint = checkpoint(chatScope);
  final messageCheckpoint = checkpoint(messageScope);
  final decoder = RustCloudSemanticDecoder(
    readAuthSnapshot: () async => auth,
    storageDirectory: profile.path,
    nativeWriterPauseToken: pauseToken,
  );
  Future<CloudDecodedMutation> decode(
    CloudInboxChangeEntity row,
    CloudSyncScope scope,
  ) => decoder.decode(
    CloudInboxEntry(
      scope: scope,
      sequence: row.fetchSequence,
      generation: row.generation,
      batchId: row.batchId,
      status: CloudInboxStatus.values[row.status],
      attemptCount: row.retryCount,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.createdAtMs,
        isUtc: true,
      ),
      change: CloudFetchedChange(
        changeId: row.changeIdHash,
        recordIdHash: row.serverRecordIdHash,
        etagHash: row.etagHash,
        type: CloudChangeType.save,
        encryptedServerRecordId: row.encryptedServerRecordId,
        protectedSystemFieldsReference: row.protectedSystemFieldsRef,
        encryptedPayloadReference: row.encryptedPayloadRef,
        payloadSha256: row.payloadSha256,
        serverModifiedAt: row.serverModifiedAtMs == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                row.serverModifiedAtMs,
                isUtc: true,
              ),
      ),
    ),
  );
  final chatQuery =
      (store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey
                .equals(chatCheckpoint.checkpointKey)
                .and(
                  CloudInboxChangeEntity_.accountFingerprint.equals(
                    auth.accountFingerprint,
                  ),
                )
                .and(
                  CloudInboxChangeEntity_.generation.equals(
                    chatCheckpoint.generation,
                  ),
                ),
          )..order(
            CloudInboxChangeEntity_.fetchSequence,
            flags: Order.descending,
          ))
          .build()
        ..limit = 1001;
  late final List<CloudInboxChangeEntity> chatRows;
  try {
    chatRows = chatQuery.find();
  } finally {
    chatQuery.close();
  }
  final latest = <String, CloudInboxChangeEntity>{};
  for (final row in chatRows.take(1000)) {
    latest.putIfAbsent(row.serverRecordIdHash, () => row);
  }
  final chats = <(CloudInboxChangeEntity, CloudChatEntityPayload)>[];
  var tombstones = 0;
  final decodeFailures = <String, int>{};
  void failure(String key) =>
      decodeFailures.update(key, (count) => count + 1, ifAbsent: () => 1);
  for (final row in latest.values) {
    if (row.isTombstone || row.changeType != 'save') {
      tombstones++;
      continue;
    }
    try {
      final decoded = await decode(row, chatScope);
      if (decoded.payload case final CloudChatEntityPayload payload) {
        chats.add((row, payload));
      } else {
        failure('not_chat');
      }
    } on CloudSemanticOutOfScopeServiceDisposition {
      failure('out_of_scope');
    } on CloudSemanticDecodeFailure catch (error) {
      failure(error.category.name);
    } catch (_) {
      failure('unexpected');
    }
  }
  final messageQuery = (store.box<CloudInboxChangeEntity>().query(
    CloudInboxChangeEntity_.scopeKey
        .equals(messageCheckpoint.checkpointKey)
        .and(
          CloudInboxChangeEntity_.accountFingerprint.equals(
            auth.accountFingerprint,
          ),
        )
        .and(
          CloudInboxChangeEntity_.generation.equals(
            messageCheckpoint.generation,
          ),
        )
        .and(
          CloudInboxChangeEntity_.status.equals(
            CloudInboxStatus.retainedUnprojected.index,
          ),
        )
        .and(CloudInboxChangeEntity_.failureCategory.equals('dependency'))
        .and(CloudInboxChangeEntity_.changeType.equals('save'))
        .and(CloudInboxChangeEntity_.isTombstone.equals(false)),
  )..order(CloudInboxChangeEntity_.fetchSequence)).build()..limit = 257;
  late final List<CloudInboxChangeEntity> messageRows;
  try {
    messageRows = messageQuery.find();
  } finally {
    messageQuery.close();
  }
  final controlQuery =
      (store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey
                .equals(messageCheckpoint.checkpointKey)
                .and(
                  CloudInboxChangeEntity_.accountFingerprint.equals(
                    auth.accountFingerprint,
                  ),
                )
                .and(
                  CloudInboxChangeEntity_.generation.equals(
                    messageCheckpoint.generation,
                  ),
                )
                .and(
                  CloudInboxChangeEntity_.status.equals(
                    CloudInboxStatus.applied.index,
                  ),
                )
                .and(CloudInboxChangeEntity_.changeType.equals('save'))
                .and(CloudInboxChangeEntity_.isTombstone.equals(false)),
          )..order(
            CloudInboxChangeEntity_.fetchSequence,
            flags: Order.descending,
          ))
          .build()
        ..limit = 128;
  late final List<CloudInboxChangeEntity> controlRows;
  try {
    controlRows = controlQuery.find();
  } finally {
    controlQuery.close();
  }
  final observations = <Map<String, Object?>>[];
  final routes = <String>{};
  var examined = 0;
  var controlsExamined = 0;
  var samples = 0;
  var controls = 0;
  for (final (row, control) in [
    ...messageRows.take(256).map((row) => (row, false)),
    ...controlRows.map((row) => (row, true)),
  ]) {
    if ((!control && samples == 8) || (control && controls == 4)) continue;
    if (control) {
      controlsExamined++;
    } else {
      examined++;
    }
    CloudMessageEntityPayload message;
    try {
      final payload = (await decode(row, messageScope)).payload;
      if (payload is! CloudMessageEntityPayload) continue;
      message = payload;
    } catch (_) {
      continue;
    }
    final local =
        store
            .box<Chat>()
            .query(
              Chat_.guid
                  .equals(message.chatIdentifier)
                  .or(Chat_.chatIdentifier.equals(message.chatIdentifier)),
            )
            .build()
          ..limit = 2;
    late final int localCount;
    try {
      localCount = local.count();
    } finally {
      local.close();
    }
    if ((control ? localCount == 0 : localCount != 0) ||
        !routes.add(
          '${control ? "control" : "sample"}:${message.chatIdentifier}',
        )) {
      continue;
    }
    final matches = <Map<String, Object?>>[];
    final legacyVariants = Chat.cloudIdentityCandidates(message.chatIdentifier);
    final legacyResolved = Chat.findEligibleCloudMessageChatReferences([
      message.chatIdentifier,
    ], box: store.box<Chat>());
    for (final (source, chat) in chats) {
      final exact =
          message.chatIdExactGuidLogicalKeyHash == chat.logicalEntityKeyHash;
      final kinds = <String>{};
      for (final candidate in message.chatIdAliasCandidates) {
        if (chat.aliases.any(
          (alias) =>
              alias.kind == candidate.kind &&
              alias.keyHash == candidate.keyHash,
        )) {
          kinds.add(candidate.kind.name);
        }
      }
      if (chat.aliases.any(
        (alias) =>
            alias.kind == CloudSemanticChatAliasKind.serviceIdentifier &&
            alias.keyHash ==
                message.chatIdBareDirectServiceIdentifierAliasKeyHash,
      )) {
        kinds.add('bare_direct_service');
      }
      final corroborates = chat.aliases.any(
        (alias) =>
            alias.kind == CloudSemanticChatAliasKind.groupId &&
            alias.keyHash == message.msgProto4GroupIdAliasKeyHash,
      );
      final normalizedFields = <String>[];
      for (final field in <String, String?>{
        'canonical_guid': chat.canonicalGuid,
        'chat_identifier': chat.chatIdentifier,
        'group_id': chat.groupId,
        'original_group_id': chat.originalGroupId,
      }.entries) {
        if (field.value != null &&
            Chat.cloudIdentityCandidates(
              field.value!,
            ).any(legacyVariants.contains)) {
          normalizedFields.add(field.key);
        }
      }
      if (!exact &&
          kinds.isEmpty &&
          !corroborates &&
          normalizedFields.isEmpty) {
        continue;
      }
      final canonicalQuery =
          store.box<Chat>().query(Chat_.guid.equals(chat.canonicalGuid)).build()
            ..limit = 2;
      late final List<Chat> canonical;
      try {
        canonical = canonicalQuery.find();
      } finally {
        canonicalQuery.close();
      }
      final bindingQuery = store
          .box<CloudSemanticChatAliasEntity>()
          .query(
            CloudSemanticChatAliasEntity_.scopeKey
                .equals(chatCheckpoint.checkpointKey)
                .and(
                  CloudSemanticChatAliasEntity_.generation.equals(
                    chatCheckpoint.generation,
                  ),
                )
                .and(
                  CloudSemanticChatAliasEntity_.chatLogicalEntityKeyHash.equals(
                    chat.logicalEntityKeyHash,
                  ),
                ),
          )
          .build();
      late final int bindings;
      try {
        bindings = bindingQuery.count();
      } finally {
        bindingQuery.close();
      }
      matches.add({
        'chat_record_hash': source.serverRecordIdHash,
        'source_status': source.status,
        'exact_logical': exact,
        'alias_kinds': kinds.toList(),
        'proto4_corroborates': corroborates,
        'legacy_normalized_fields': normalizedFields,
        'service': chat.service?.name,
        'style': chat.style?.name,
        'canonical_rows': canonical.length,
        'eligible_rows': canonical
            .where(
              (chat) =>
                  chat.isRpSms != true &&
                  chat.isRoutingStub != true &&
                  chat.dateDeleted == null,
            )
            .length,
        'durable_alias_bindings': bindings,
      });
    }
    observations.add({
      'observation_kind': control ? 'applied_control' : 'retained_sample',
      'message_record_hash': row.serverRecordIdHash,
      'wire_reference_shape': Chat.cloudIdentityReferenceShape(
        message.chatIdentifier,
      ),
      'reference_token_class': _referenceTokenClass(message.chatIdentifier),
      'from_me': message.knownFlags?.fromMe,
      'reference_matches_sender':
          Chat.cloudIdentityCandidates(message.chatIdentifier)
              .intersection(Chat.cloudIdentityCandidates(message.senderHandle))
              .isNotEmpty,
      'legacy_resolver_found': legacyResolved != null,
      'chat_route': message.chatIdentifier.startsWith('iMessage;-;')
          ? 'direct'
          : message.chatIdentifier.startsWith('iMessage;+;')
          ? 'group'
          : 'bare',
      'reply_dependency': message.replyParentLogicalKeyHash != null,
      'extension_dependency': message.extensionParentLogicalKeyHash != null,
      'cached_chat_matches': matches,
    });
    if (control) {
      controls++;
    } else {
      samples++;
    }
  }
  final unchanged = before == durableState();
  if (!unchanged) throw StateError('parent_coverage_durable_state_changed');
  return {
    'durable_state_unchanged': unchanged,
    'chat_journal_rows_read': chatRows.length,
    'chat_journal_capped': chatRows.length > 1000,
    'latest_chat_records': latest.length,
    'latest_chat_tombstones': tombstones,
    'decoded_chat_records': chats.length,
    'chat_decode_failures': decodeFailures,
    'message_rows_examined': examined,
    'control_rows_examined': controlsExamined,
    'message_scan_capped': messageRows.length > 256,
    'observations': observations,
    'remote_absence_inferred': false,
    'chat_admission_performed': false,
  };
}

String _referenceTokenClass(String value) {
  final token = Chat.normalizeCloudParticipantAddress(
    Chat.normalizedCompositeChatIdentifier(value),
  );
  if (RegExp(r'^\+[0-9]{7,15}$').hasMatch(token)) return 'e164';
  if (RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(token)) {
    return 'uuid';
  }
  if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(token)) return 'compact_uuid';
  if (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(token)) {
    return 'email_shape';
  }
  return 'other';
}
