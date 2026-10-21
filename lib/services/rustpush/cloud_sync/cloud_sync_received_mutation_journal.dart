// Keep readable public names at the injection boundary.
// ignore_for_file: prefer_initializing_formals
import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:crypto/crypto.dart';

import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_received_archive_identity.dart';
import 'cloud_sync_received_mutation_identity.dart';
import 'cloud_sync_received_mutation_source_binding.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Local durable ownership only. No writer permit, native calls or network I/O.
/// Source and original target identities are immutable across duplicate events;
/// target reflection and its completion marker commit in one ObjectBox write.
final class CloudSyncReceivedMutationJournal {
  CloudSyncReceivedMutationJournal({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot owner,
  }) : _store = store,
       _authority = authority,
       _owner = owner {
    if (!authority.isBoundToStore(store)) {
      _fail('owner_changed');
    }
  }
  final Store _store;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterAuthoritySnapshot _owner;

  int retain({
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required CloudSyncReceivedMutationSourceBinding source,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireCurrent(currentAuth, stillCurrent);
    final identity = CloudSyncReceivedMutationIdentity.captureWire(
      wire,
      liveContext: liveContext,
      expectedSourceSha256: source.sourceSha256,
    );
    if (identity == null || identity.guidHash != source.mutationGuidHash) {
      _fail('source_changed');
    }
    source.requireOrigin(
      account: currentAuth.accountFingerprint,
      store: currentAuth.protectedStoreIdentity,
      eventGuidHash: identity.guidHash,
      sourceDigest: identity.sourceSha256,
    );
    final key = intentKey(currentAuth.accountFingerprint, identity.guidHash);
    final existing = _unique(
      _store.box<CloudSyncReceivedMutationIntentEntity>().query(
        CloudSyncReceivedMutationIntentEntity_.intentKey.equals(key),
      ),
    );
    if (existing != null) {
      _validateRow(existing, currentAuth);
      if (existing.sourceSha256 != identity.sourceSha256 ||
          existing.targetGuidHash != identity.targetGuidHash ||
          existing.targetPart != identity.targetPart ||
          existing.kind != identity.kind.index ||
          existing.origin != identity.origin.index ||
          existing.sentTimestampMs != identity.sentTimestamp) {
        _fail('source_changed');
      }
      // Randomized encryption of the same source never replaces its first seed.
      return existing.id;
    }
    if (!now.isUtc || now.millisecondsSinceEpoch <= 0) _fail('time_invalid');
    final time = now.millisecondsSinceEpoch;
    final id = _store.box<CloudSyncReceivedMutationIntentEntity>().put(
      CloudSyncReceivedMutationIntentEntity(
        intentKey: key,
        accountFingerprint: currentAuth.accountFingerprint,
        ownershipEpoch: _owner.automaticArchiveEpoch,
        mutationGuidHash: identity.guidHash,
        targetGuidHash: identity.targetGuidHash,
        targetPart: identity.targetPart,
        origin: identity.origin.index,
        kind: identity.kind.index,
        sentTimestampMs: identity.sentTimestamp,
        sourceSha256: identity.sourceSha256,
        protectedSourceBinding: source.encode(),
        createdAtMs: time,
        updatedAtMs: time,
      ),
    );
    _requireCurrent(currentAuth, stillCurrent);
    return id;
  });

  CloudSyncReceivedMutationSourceBinding? findSource({
    required String eventGuid,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    final row = _unique(
      _store.box<CloudSyncReceivedMutationIntentEntity>().query(
        CloudSyncReceivedMutationIntentEntity_.intentKey.equals(
          intentKey(
            currentAuth.accountFingerprint,
            _digest(['cloud-sync-received-mutation-guid-v1', eventGuid]),
          ),
        ),
      ),
    );
    if (row == null) return null;
    return _validateRow(row, currentAuth);
  });

  /// Reading local rows is not permission to replay them to Apple. A worker must
  /// reopen the native seed, resolve its exact predecessor and obtain consent.
  List<CloudSyncReceivedMutationIntentEntity> readPending({
    required CloudSyncNativeAuthSnapshot currentAuth,
    int afterId = 0,
    int limit = 20,
    bool onlyPendingReflection = false,
    int? maximumIntentId,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    if (limit < 1 ||
        limit > 50 ||
        afterId < 0 ||
        (maximumIntentId != null && maximumIntentId < 0)) {
      _fail('limit_invalid');
    }
    var condition = CloudSyncReceivedMutationIntentEntity_.accountFingerprint
        .equals(currentAuth.accountFingerprint)
        .and(
          CloudSyncReceivedMutationIntentEntity_.ownershipEpoch.equals(
            _owner.automaticArchiveEpoch,
          ),
        )
        .and(CloudSyncReceivedMutationIntentEntity_.id.greaterThan(afterId));
    if (onlyPendingReflection) {
      condition = condition.and(
        CloudSyncReceivedMutationIntentEntity_.state.equals(0),
      );
    }
    if (maximumIntentId != null) {
      condition = condition.and(
        CloudSyncReceivedMutationIntentEntity_.id.lessOrEqual(maximumIntentId),
      );
    }
    final query = (_store.box<CloudSyncReceivedMutationIntentEntity>().query(
      condition,
    )..order(CloudSyncReceivedMutationIntentEntity_.id)).build()..limit = limit;
    try {
      final rows = query.find();
      for (final row in rows) {
        _validateRow(row, currentAuth);
      }
      return rows;
    } finally {
      query.close();
    }
  });

  int captureReadHighWatermark({
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    final query =
        (_store.box<CloudSyncReceivedMutationIntentEntity>().query(
              CloudSyncReceivedMutationIntentEntity_.accountFingerprint
                  .equals(currentAuth.accountFingerprint)
                  .and(
                    CloudSyncReceivedMutationIntentEntity_.ownershipEpoch
                        .equals(_owner.automaticArchiveEpoch),
                  ),
            )..order(
              CloudSyncReceivedMutationIntentEntity_.id,
              flags: Order.descending,
            ))
            .build()
          ..limit = 1;
    try {
      return query.findFirst()?.id ?? 0;
    } finally {
      query.close();
    }
  });

  /// True means the one exact event already committed its local reflection.
  /// Later edits to the target do not erase this retained receipt or reapply it.
  bool reflectionCommitted({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _requireCurrent(currentAuth, () => true);
    final row = _read(intentId);
    _validateRow(row, currentAuth);
    return row.state >= 1;
  });

  Message commitReflection({
    required int intentId,
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required String expectedBeforeSnapshot,
    required Message reflected,
    required DateTime now,
  }) => _commitReflection(
    intentId: intentId,
    wire: wire,
    currentAuth: currentAuth,
    stillCurrent: stillCurrent,
    expectedBeforeSnapshot: expectedBeforeSnapshot,
    reflected: reflected,
    now: now,
    capturedLocalHandles: liveContext.observedLocalHandles,
    identify: (row) => CloudSyncReceivedMutationIdentity.captureWire(
      wire,
      liveContext: liveContext,
      expectedSourceSha256: row.sourceSha256,
    ),
  );

  /// Local crash recovery only. A native-restored event is not a new live
  /// receive. It must match the first retained source and current account/store.
  Message commitReplayedReflection({
    required int intentId,
    required api.CloudSyncRestoredReceivedMutation restored,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required String expectedBeforeSnapshot,
    required Message reflected,
    required DateTime now,
  }) {
    if (restored.accountFingerprint != currentAuth.accountFingerprint ||
        restored.protectedStoreIdentity != currentAuth.protectedStoreIdentity) {
      _fail('source_changed');
    }
    return _commitReflection(
      intentId: intentId,
      wire: restored.message,
      currentAuth: currentAuth,
      stillCurrent: stillCurrent,
      expectedBeforeSnapshot: expectedBeforeSnapshot,
      reflected: reflected,
      now: now,
      capturedLocalHandles: restored.capturedLocalHandles,
      identify: (row) => CloudSyncReceivedMutationIdentity.restoreNative(
        restored,
        expectedGuidHash: row.mutationGuidHash,
        expectedTargetGuidHash: row.targetGuidHash,
        expectedSourceSha256: row.sourceSha256,
      ),
    );
  }

  Message _commitReflection({
    required int intentId,
    required api.MessageInst wire,
    required CloudSyncNativeAuthSnapshot currentAuth,
    required bool Function() stillCurrent,
    required String expectedBeforeSnapshot,
    required Message reflected,
    required DateTime now,
    required List<String> capturedLocalHandles,
    required CloudSyncReceivedMutationIdentity? Function(
      CloudSyncReceivedMutationIntentEntity,
    )
    identify,
  }) => _store.runInTransaction(TxMode.write, () {
    _requireCurrent(currentAuth, stillCurrent);
    final row = _read(intentId);
    _validateRow(row, currentAuth);
    final identity = identify(row);
    if (identity == null || identity.guidHash != row.mutationGuidHash) {
      _fail('source_changed');
    }
    final targetGuid = switch (wire.message) {
      api.Message_Edit(:final field0) => field0.tuuid,
      api.Message_Unsend(:final field0) => field0.tuuid,
      _ => null,
    };
    if (targetGuid == null || reflected.guid != targetGuid) {
      _fail('target_changed');
    }
    final target = _unique(
      _store.box<Message>().query(Message_.guid.equals(targetGuid)),
    );
    if (target == null || target.id == null || target.id! <= 0) {
      _fail('target_missing');
    }
    if (row.state >= 1) return target;
    _requireTargetAuthor(target, wire, identity, capturedLocalHandles);
    if (snapshot(target) != expectedBeforeSnapshot ||
        reflected.id != target.id ||
        reflected.chat.targetId != target.chat.targetId ||
        reflected.isFromMe != target.isFromMe ||
        reflected.handleId != target.handleId ||
        reflected.dateCreated != target.dateCreated ||
        reflected.dateDeleted != target.dateDeleted) {
      _fail('target_changed');
    }
    _requireOrderedTarget(row, target);
    if (!now.isUtc || now.millisecondsSinceEpoch <= 0) _fail('time_invalid');
    // Persist only reflection-owned fields. A read receipt, bookmark or cloud
    // mapping can change while reflection awaits without being rolled back by
    // a stale whole-row put. The original media relations are never rewritten.
    target
      ..text = reflected.text
      ..attributedBody = reflected.attributedBody
      ..messageSummaryInfo = reflected.messageSummaryInfo
      ..dateEdited = DateTime.fromMillisecondsSinceEpoch(row.sentTimestampMs)
      ..verificationFailed = reflected.verificationFailed;
    _store.box<Message>().put(target, mode: PutMode.update);
    row.localMessageId = target.id!;
    row.localChatId = target.chat.targetId;
    row.beforeSnapshotSha256 = expectedBeforeSnapshot;
    row.reflectedSnapshotSha256 = snapshot(
      _store.box<Message>().get(target.id!)!,
    );
    row.state = 1;
    row.updatedAtMs = now.millisecondsSinceEpoch > row.updatedAtMs
        ? now.millisecondsSinceEpoch
        : row.updatedAtMs + 1;
    _store.box<CloudSyncReceivedMutationIntentEntity>().put(row);
    _requireCurrent(currentAuth, stillCurrent);
    return target;
  });

  void _requireOrderedTarget(
    CloudSyncReceivedMutationIntentEntity row,
    Message target,
  ) {
    if (target.dateCreated == null ||
        row.sentTimestampMs < target.dateCreated!.millisecondsSinceEpoch) {
      _fail('predecessor_changed');
    }
    // Retraction is terminal for this part. A late edit must not resurrect it.
    for (final summary in target.messageSummaryInfo) {
      if (summary.retractedParts.contains(row.targetPart)) {
        _fail('predecessor_changed');
      }
      for (final edit
          in summary.editedContent[row.targetPart.toString()] ??
              <EditedContent>[]) {
        final date = edit.date;
        if (date == null || !date.isFinite || date >= row.sentTimestampMs) {
          _fail('predecessor_changed');
        }
      }
    }
    final query = _store
        .box<CloudSyncReceivedMutationIntentEntity>()
        .query(
          CloudSyncReceivedMutationIntentEntity_.accountFingerprint
              .equals(row.accountFingerprint)
              .and(
                CloudSyncReceivedMutationIntentEntity_.targetGuidHash.equals(
                  row.targetGuidHash,
                ),
              )
              .and(
                CloudSyncReceivedMutationIntentEntity_.targetPart.equals(
                  row.targetPart,
                ),
              )
              .and(CloudSyncReceivedMutationIntentEntity_.state.equals(1)),
        )
        .build();
    try {
      for (final previous in query.find()) {
        if (previous.id == row.id) continue;
        if (previous.kind == CloudSyncReceivedMutationKind.unsend.index ||
            previous.sentTimestampMs >= row.sentTimestampMs) {
          _fail('predecessor_changed');
        }
      }
    } finally {
      query.close();
    }
  }

  void _requireTargetAuthor(
    Message target,
    api.MessageInst wire,
    CloudSyncReceivedMutationIdentity identity,
    List<String> capturedLocalHandles,
  ) {
    final chat = _store.box<Chat>().get(target.chat.targetId);
    if (chat == null ||
        chat.dateDeleted != null ||
        target.dateDeleted != null ||
        target.verificationFailed ||
        target.isFromMe !=
            (identity.origin == CloudSyncReceivedArchiveOrigin.mirrored)) {
      _fail('target_author_changed');
    }
    if (identity.origin == CloudSyncReceivedArchiveOrigin.incoming) {
      if (target.handleId == null) _fail('target_author_changed');
      final handle = _unique(
        _store.box<Handle>().query(
          Handle_.originalROWID.equals(target.handleId!),
        ),
      );
      if (handle == null ||
          handle.service != 'iMessage' ||
          _bare(wire.sender!) != handle.address) {
        _fail('target_author_changed');
      }
    }
    if (chat.isRpSms || (chat.style != 43 && chat.style != 45)) {
      _fail('target_author_changed');
    }
    if (chat.style == 45) {
      final peers = wire.conversation!.participants
          .where((h) => !capturedLocalHandles.contains(h))
          .map(_bare)
          .toSet();
      if (peers.length != 1 ||
          (chat.chatIdentifier != peers.single &&
              chat.guid != 'iMessage;-;${peers.single}')) {
        _fail('target_author_changed');
      }
    } else {
      final group = wire.conversation!.senderGuid;
      if (group == null ||
          ![
            chat.guid.replaceFirst('iMessage;+;', ''),
            chat.chatIdentifier,
            chat.cloudGuid,
          ].contains(group)) {
        _fail('target_author_changed');
      }
    }
  }

  CloudSyncReceivedMutationSourceBinding _validateRow(
    CloudSyncReceivedMutationIntentEntity row,
    CloudSyncNativeAuthSnapshot auth,
  ) {
    if (row.accountFingerprint != auth.accountFingerprint ||
        row.ownershipEpoch != _owner.automaticArchiveEpoch ||
        row.intentKey !=
            intentKey(row.accountFingerprint, row.mutationGuidHash) ||
        !_hash.hasMatch(row.mutationGuidHash) ||
        !_hash.hasMatch(row.targetGuidHash) ||
        !_hash.hasMatch(row.sourceSha256) ||
        ![0, 1].contains(row.origin) ||
        ![0, 1].contains(row.kind) ||
        row.targetPart < 0 ||
        row.sentTimestampMs <= 0 ||
        row.createdAtMs <= 0 ||
        row.updatedAtMs < row.createdAtMs ||
        row.state < 0 ||
        row.state > 1 ||
        row.admittedOperationId != null ||
        row.admittedBindingSha256 != null ||
        (row.state == 0 &&
            (row.localMessageId != 0 ||
                row.localChatId != 0 ||
                row.beforeSnapshotSha256 != null ||
                row.reflectedSnapshotSha256 != null)) ||
        (row.state == 1 &&
            (row.localMessageId <= 0 ||
                row.localChatId <= 0 ||
                !_hash.hasMatch(row.beforeSnapshotSha256 ?? '') ||
                !_hash.hasMatch(row.reflectedSnapshotSha256 ?? '')))) {
      _fail('intent_changed');
    }
    final source = CloudSyncReceivedMutationSourceBinding.decode(
      row.protectedSourceBinding,
    );
    source.requireOrigin(
      account: auth.accountFingerprint,
      store: auth.protectedStoreIdentity,
      eventGuidHash: row.mutationGuidHash,
      sourceDigest: row.sourceSha256,
    );
    return source;
  }

  CloudSyncReceivedMutationIntentEntity _read(int id) =>
      _store.box<CloudSyncReceivedMutationIntentEntity>().get(id) ??
      (throw StateError('cloud_sync_received_mutation_intent_changed'));

  void _requireCurrent(
    CloudSyncNativeAuthSnapshot auth,
    bool Function() stillCurrent,
  ) {
    final current = _authority.read(_owner.scope);
    if (!stillCurrent() ||
        _owner.scope.accountFingerprint != auth.accountFingerprint ||
        _owner.owner != CloudKitWriterOwner.v2 ||
        _owner.automaticArchiveEpoch <= 0 ||
        current == null ||
        current.owner != CloudKitWriterOwner.v2 ||
        current.automaticArchiveEpoch != _owner.automaticArchiveEpoch) {
      _fail('identity_changed');
    }
  }

  static String intentKey(String account, String hash) =>
      _digest(['cloud-sync-received-mutation-intent-v1', account, hash]);
  static String snapshot(Message m) => _digest([
    'cloud-sync-received-mutation-target-v1',
    m.id,
    m.guid,
    m.chat.targetId,
    m.isFromMe,
    m.handleId,
    m.otherHandle,
    m.dateCreated?.millisecondsSinceEpoch,
    m.dateEdited?.millisecondsSinceEpoch,
    m.dateDeleted?.millisecondsSinceEpoch,
    m.text,
    m.subject,
    m.hasAttachments,
    m.associatedMessageGuid,
    m.associatedMessagePart,
    m.associatedMessageType,
    m.threadOriginatorGuid,
    m.threadOriginatorPart,
    m.balloonBundleId,
    m.dbPayloadData,
    m.verificationFailed,
    m.attributedBody.map((b) => b.toMap()).toList(),
    m.messageSummaryInfo.map((s) => s.toJson()).toList(),
  ]);
}

T? _unique<T>(QueryBuilder<T> builder) {
  final query = builder.build();
  try {
    return query.findUnique();
  } finally {
    query.close();
  }
}

String _bare(String h) => h.replaceFirst(RegExp(r'^(mailto:|tel:)'), '');
Object? _canonical(Object? value) {
  if (value is List) return value.map(_canonical).toList();
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  return value;
}

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
final _hash = RegExp(r'^[a-f0-9]{64}$');
Never _fail(String code) =>
    throw StateError('cloud_sync_received_mutation_$code');
