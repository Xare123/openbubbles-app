import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_canonical_semantic_entity_adapter.dart';
import 'package:crypto/crypto.dart';

import 'backend_harness_protocol.dart';
import 'backend_harness_fixture_proof.dart';

/// Read-only observations of the normal reader's store. The caller's separate
/// fresh-reader admission establishes independence, not a marker in this API.
final class BackendHarnessEvidence {
  BackendHarnessEvidence({
    required this.readStore,
    required this.captureAuth,
    required this.download,
  });
  final Store Function() readStore;
  final Future<CloudSyncNativeAuthSnapshot?> Function() captureAuth;
  final Future<PlatformFile> Function(Attachment) download;
  static final guid = RegExp(
    r'^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$',
  );
  static final digest = RegExp(r'^[a-f0-9]{64}$');
  static const maximumFixtureBytes = 16 * 1024 * 1024;

  static bool validFetch(Map<String, Object?> args) =>
      args.length == 1 && args['messageGuid'] is String &&
      guid.hasMatch(args['messageGuid'] as String);

  static bool validInspect(Map<String, Object?> args) =>
      (args.length == 6 || args.length == 9) &&
      args.keys.every(
        const {
          'messageGuid',
          'visibleTextSha256',
          'edited',
          'retracted',
          'minimumEdits',
          'sinceUtcMs',
          'chatGuid',
          'chatGuidSha256',
          'participantsSha256',
          'editHistorySha256',
        }.contains,
      ) &&
      args['messageGuid'] is String &&
      guid.hasMatch(args['messageGuid'] as String) &&
      args['visibleTextSha256'] is String &&
      digest.hasMatch(args['visibleTextSha256'] as String) &&
      args['edited'] is bool &&
      args['retracted'] is bool &&
      args['minimumEdits'] is int &&
      (args['minimumEdits'] as int) >= 0 &&
      (args['minimumEdits'] as int) <= 100 &&
      args['sinceUtcMs'] is int &&
      (args['sinceUtcMs'] as int) >= 0 &&
      (args['sinceUtcMs'] as int) <= 9999999999999 &&
      (args.length == 6 ||
          ((args['chatGuid'] is String && guid.hasMatch(args['chatGuid'] as String) &&
                !args.containsKey('chatGuidSha256')) ||
              (args['chatGuidSha256'] is String &&
                digest.hasMatch(args['chatGuidSha256'] as String) &&
                !args.containsKey('chatGuid'))) &&
          args['participantsSha256'] is String && digest.hasMatch(args['participantsSha256'] as String) &&
          args['editHistorySha256'] is String && digest.hasMatch(args['editHistorySha256'] as String));

  static bool validMaterialize(Map<String, Object?> args) =>
      args.length == 3 &&
      args.keys.every(
        const {
          'messageGuid',
          'attachmentGuid',
          'attachmentIndex',
          'sha256',
        }.contains,
      ) &&
      args['messageGuid'] is String &&
      guid.hasMatch(args['messageGuid'] as String) &&
      ((args['attachmentGuid'] is String &&
              (args['attachmentGuid'] as String).isNotEmpty &&
              (args['attachmentGuid'] as String).length <= 256) ||
          (args['attachmentIndex'] is int && args['attachmentIndex'] == 0)) &&
      args['sha256'] is String &&
      digest.hasMatch(args['sha256'] as String);

  Future<BackendHarnessPayload> inspect(Map<String, Object?> args) async {
    if (!validInspect(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final store = readStore();
    final auth = await captureAuth();
    if (auth == null || store.isClosed() || !identical(store, readStore())) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final result = store.runInTransaction(
      TxMode.read,
      () => _inspect(store, auth.accountFingerprint, args),
    );
    if (!auth.sameIdentity(await captureAuth()) ||
        !identical(store, readStore())) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    return result;
  }

  static BackendHarnessPayload _inspect(
    Store store,
    String account,
    Map<String, Object?> args,
  ) {
    final query =
        store
            .box<Message>()
            .query(Message_.guid.equals(args['messageGuid'] as String))
            .build()
          ..limit = 2;
    late final List<Message> messages;
    try {
      messages = query.find();
    } finally {
      query.close();
    }
    final flags = <String, bool>{
      'fixture_content_matches': false,
      'fixture_edit_matches': false,
      'fixture_retraction_matches': false,
      'fixture_matches': false,
      'cloud_projection_present': false,
    };
    if (messages.length != 1) {
      return BackendHarnessPayload(
        flags: flags,
        counts: {'messages': messages.length},
      );
    }
    final message = messages.single;
    message.attachments = List<Attachment>.from(message.dbAttachments);
    final parts = message.buildMessageParts();
    final visible = parts
        .where((part) => !part.isUnsent)
        .map(
          (part) => [
            part.subject,
            part.text,
          ].whereType<String>().where((text) => text.isNotEmpty).join('\n'),
        )
        .where((text) => text.isNotEmpty)
        .join('\n');
    final edits = parts.fold<int>(
      0,
      (count, part) => count + part.edits.length,
    );
    final retracted = parts.where((part) => part.isUnsent).length;
    final edited = message.messageSummaryInfo.any(
      (summary) => summary.editedParts.isNotEmpty,
    );
    flags['fixture_content_matches'] =
        sha256.convert(utf8.encode(visible)).toString() ==
        args['visibleTextSha256'];
    flags['fixture_edit_matches'] =
        edited == args['edited'] && edits >= (args['minimumEdits'] as int);
    flags['fixture_retraction_matches'] = (retracted > 0) == args['retracted'];
    flags['cloud_projection_present'] = _cloudProjection(
      store,
      account,
      message.guid!,
      args['sinceUtcMs'] as int,
    );
    if (args.containsKey('chatGuid') || args.containsKey('chatGuidSha256')) {
      final parent = message.chat.target;
      flags['fixture_parent_matches'] = parent != null &&
          (args.containsKey('chatGuid') ? parent.guid == args['chatGuid'] :
              sha256.convert(utf8.encode(parent.guid)).toString() == args['chatGuidSha256']);
      flags['fixture_participants_match'] = parent != null &&
          backendFixtureParticipantsSha256(parent) == args['participantsSha256'];
      flags['fixture_history_matches'] =
          backendFixtureEditHistorySha256(message) == args['editHistorySha256'];
    }
    flags['fixture_matches'] =
        flags['fixture_content_matches']! &&
        flags['fixture_edit_matches']! &&
        flags['fixture_retraction_matches']! &&
        flags['cloud_projection_present']! &&
        ((!args.containsKey('chatGuid') && !args.containsKey('chatGuidSha256')) ||
            flags['fixture_parent_matches']! &&
            flags['fixture_participants_match']! &&
            flags['fixture_history_matches']!);
    return BackendHarnessPayload(
      flags: flags,
      counts: {
        'messages': 1,
        'attachments': message.attachments.whereType<Attachment>().length,
        'edits': edits,
        'retracted_parts': retracted,
      },
    );
  }

  static bool _cloudProjection(
    Store store,
    String account,
    String messageGuid,
    int since,
  ) {
    final scope = CloudSyncScope(
      accountFingerprint: account,
      container: CloudSyncManualSemanticPullSampler.container,
      database: CloudSyncManualSemanticPullSampler.database,
      zone: 'messageManateeZone',
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
    );
    final scopeKey = cloudSyncPersistentScopeKey(scope);
    final checkpoints =
        store
            .box<CloudSyncCheckpointEntity>()
            .query(CloudSyncCheckpointEntity_.checkpointKey.equals(scopeKey))
            .build()
          ..limit = 2;
    late final List<CloudSyncCheckpointEntity> checkpoint;
    try {
      checkpoint = checkpoints.find();
    } finally {
      checkpoints.close();
    }
    if (checkpoint.length != 1 ||
        checkpoint.single.generation <= 0 ||
        checkpoint.single.accountFingerprint != account ||
        checkpoint.single.container != scope.container ||
        checkpoint.single.database != scope.database ||
        checkpoint.single.zone != scope.zone ||
        checkpoint.single.schemaVersion != scope.schemaVersion ||
        checkpoint.single.streamKind != scope.streamKind.name ||
        checkpoint.single.persistenceLane != scope.persistenceLane.name) {
      return false;
    }
    final generation = checkpoint.single.generation;
    final lookup = CloudCanonicalIdentityDigest.forCanonicalGuidLookup(
      scope: scope,
      generation: generation,
      canonicalGuid: messageGuid,
    );
    final owners =
        store
            .box<CloudSemanticSnapshotEntity>()
            .query(
              CloudSemanticSnapshotEntity_.scopeKey
                  .equals(scopeKey)
                  .and(
                    CloudSemanticSnapshotEntity_.accountFingerprint.equals(
                      account,
                    ),
                  )
                  .and(
                    CloudSemanticSnapshotEntity_.generation.equals(generation),
                  )
                  .and(
                    CloudSemanticSnapshotEntity_.canonicalGuidLookupHash.equals(
                      lookup,
                    ),
                  ),
            )
            .build()
          ..limit = 2;
    late final List<CloudSemanticSnapshotEntity> snapshots;
    try {
      snapshots = owners.find();
    } finally {
      owners.close();
    }
    if (snapshots.length != 1) return false;
    final snapshot = snapshots.single;
    if (snapshot.entityKind != CloudEntityKind.message.name ||
        snapshot.etagHash == null ||
        snapshot.container != scope.container ||
        snapshot.database != scope.database ||
        snapshot.zone != scope.zone ||
        snapshot.streamKind != scope.streamKind.name ||
        snapshot.schemaVersion != scope.schemaVersion ||
        snapshot.canonicalGuidHash !=
            CloudCanonicalIdentityDigest.forCanonicalGuid(
              scope: scope,
              generation: generation,
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: snapshot.logicalEntityKeyHash,
              canonicalGuid: messageGuid,
            )) {
      return false;
    }
    final maps =
        store
            .box<CloudRecordMapEntity>()
            .query(
              CloudRecordMapEntity_.mapKey.equals(
                cloudSyncCanonicalRecordMapKey(
                  scope,
                  snapshot.logicalEntityKeyHash,
                ),
              ),
            )
            .build()
          ..limit = 2;
    late final List<CloudRecordMapEntity> mapped;
    try {
      mapped = maps.find();
    } finally {
      maps.close();
    }
    if (mapped.length != 1) return false;
    final map = mapped.single;
    if (map.scopeKey != scopeKey ||
        map.accountFingerprint != account ||
        map.generation != generation ||
        map.zone != scope.zone ||
        map.logicalEntityKeyHash != snapshot.logicalEntityKeyHash ||
        map.etagHash != snapshot.etagHash ||
        map.encryptedRawRecordRef?.isNotEmpty != true) {
      return false;
    }
    final inbox =
        store
            .box<CloudInboxChangeEntity>()
            .query(
              CloudInboxChangeEntity_.scopeKey
                  .equals(scopeKey)
                  .and(
                    CloudInboxChangeEntity_.accountFingerprint.equals(account),
                  )
                  .and(CloudInboxChangeEntity_.generation.equals(generation))
                  .and(
                    CloudInboxChangeEntity_.serverRecordIdHash.equals(
                      map.serverRecordIdHash,
                    ),
                  )
                  .and(CloudInboxChangeEntity_.etagHash.equals(map.etagHash!))
                  .and(CloudInboxChangeEntity_.status.equals(1))
                  .and(CloudInboxChangeEntity_.isTombstone.equals(false))
                  .and(
                    CloudInboxChangeEntity_.createdAtMs.greaterOrEqual(since),
                  ),
            )
            .build()
          ..limit = 2;
    try {
      return inbox.count() == 1;
    } finally {
      inbox.close();
    }
  }

  Future<BackendHarnessPayload> materialize(Map<String, Object?> args) async {
    if (!validMaterialize(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final store = readStore();
    final auth = await captureAuth();
    if (auth == null || store.isClosed() || !identical(store, readStore())) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final messageQuery =
        store
            .box<Message>()
            .query(Message_.guid.equals(args['messageGuid'] as String))
            .build()
          ..limit = 2;
    late final List<Message> messages;
    try {
      messages = messageQuery.find();
    } finally {
      messageQuery.close();
    }
    if (messages.length != 1) throw BackendHarnessFailure('backend_not_ready');
    final children = messages.single.dbAttachments.toList();
    final attachments = args.containsKey('attachmentIndex')
        ? (children.length == 1 ? children : <Attachment>[])
        : children
              .where((attachment) => attachment.guid == args['attachmentGuid'])
              .toList();
    if (attachments.length != 1 ||
        attachments.single.totalBytes == null ||
        attachments.single.totalBytes! < 0 ||
        attachments.single.totalBytes! > maximumFixtureBytes) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final attachment = attachments.single;
    final selectedId = attachment.id;
    final selectedGuid = attachment.guid;
    final selectedParent = attachment.message.targetId;
    final selectedBytes = attachment.totalBytes;
    final selectedRecord = attachment.ckRecordId;
    if (selectedId == null ||
        selectedParent != messages.single.id ||
        !auth.sameIdentity(await captureAuth()) ||
        !identical(store, readStore())) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    final file = await download(attachment);
    if (file.size < 0 || file.size > maximumFixtureBytes) {
      throw BackendHarnessFailure('backend_not_ready');
    }
    final bytes = await file.getBytes();
    if (!auth.sameIdentity(await captureAuth()) ||
        !identical(store, readStore())) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    final current = store.box<Attachment>().get(selectedId);
    if (current == null ||
        current.guid != selectedGuid ||
        current.message.targetId != selectedParent ||
        current.totalBytes != selectedBytes ||
        current.ckRecordId != selectedRecord) {
      throw BackendHarnessFailure('backend_identity_changed');
    }
    final matches =
        bytes.length <= maximumFixtureBytes &&
        bytes.length == selectedBytes &&
        sha256.convert(bytes).toString() == args['sha256'];
    return BackendHarnessPayload(
      flags: {'attachment_bytes_match': matches},
      counts: {'attachments': 1, 'bytes': bytes.length},
    );
  }
}
