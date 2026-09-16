// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_received_archive_identity.dart';
import 'cloud_sync_received_archive_source_binding.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

/// Durable metadata-only pre-admission journal for incoming/mirrored
/// messages. Not an uploader.
///
/// This journal owns one immutable protected-source reference per
/// already-protected incoming source plus the Message/Chat row identities
/// persisted atomically in the same transaction. It stores only hashes,
/// typed metadata, and the opaque protected reference/lease binding. It
/// stores no body, handle, raw GUID, key, IDS send receipt, or raw wire.
///
/// Honest limits, read once. [CloudSyncReceivedArchiveIdentity.capture]
/// runs inside the save transaction on the actually persisted Message/Chat
/// plus the caller-supplied original wire, so body/sender/time drift before
/// [persistMessage] is detected and rolls back both rows. A precomputed
/// identity is never accepted as a substitute. Read-ready is metadata-ready
/// only: it revalidates journal ownership, positive ids, parent binding,
/// GUID-hash equality, direction, legacy flags, sender evidence, and
/// outgoing-intent overlap by row and by recomputed local-send GUID hash.
/// It is never upload authority. Record-map/snapshot dedup against Apple
/// records requires existing native canonical key hashes at separate
/// admission and is explicitly gated here, never guessed from the
/// lane-local received hash. This journal never creates, mutates, or reads
/// [CloudOutboxOperationEntity]; separate admission (caller-owned atomic
/// outbox transition) is intentionally absent here. There is no upload or
/// outbox-adoption API in this step, and no automatic rollback of an
/// adopted source: a failed re-capture preserves the existing row.
///
/// Crash-gap closure: the caller persists the incoming Message via the
/// synchronous [persistMessage] callback inside this journal transaction,
/// sharing one ObjectBox transaction for persistence plus adoption. An
/// already-saved-row-only call cannot prove that gap is closed. Do not
/// wrap async or UI work in that callback; persist the already-validated
/// row and its Chat link only. The Chat row itself must already be
/// persisted with a positive id before this call.
///
/// ObjectBoxCloudSyncStore includes these rows in its complete blob and
/// crash-handoff lease inventories. Every retained account/epoch/state still
/// owns its references; malformed bindings stop cleanup. The helpers below
/// are diagnostic views, not permission to release or delete anything.
final class CloudSyncReceivedArchiveJournal {
  CloudSyncReceivedArchiveJournal({
    required Store store,
    required ObjectBoxCloudKitWriterAuthority authority,
    required CloudKitWriterAuthoritySnapshot authoritySnapshot,
  }) : _store = store,
       _authority = authority,
       _binding = authoritySnapshot {
    if (!authority.isBoundToStore(store)) {
      throw StateError('cloud_sync_received_archive_authority_store_mismatch');
    }
  }

  final Store _store;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitWriterAuthoritySnapshot _binding;

  bool isBoundToStore(Store store) => identical(store, _store);

  /// A live echo of our own journaled send must not acquire received origin.
  bool hasOutgoingOrigin(String messageGuid) =>
      _store.runInTransaction(TxMode.read, () {
        _verifyOwnership();
        return _hasOutgoingGuid(messageGuid);
      });

  bool _hasOutgoingGuid(String messageGuid) {
    final query = _store
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.accountFingerprint
              .equals(_binding.scope.accountFingerprint)
              .and(
                CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(
                  localSendGuidHashFor(messageGuid),
                ),
              ),
        )
        .build();
    try {
      return query.count() != 0;
    } finally {
      query.close();
    }
  }

  static String intentKeyFor({
    required String accountFingerprint,
    required String messageGuidHash,
  }) => _digest([
    'cloud-sync-received-archive-intent-v1',
    accountFingerprint,
    messageGuidHash,
  ]);

  static String guidHashFor(String guid) =>
      _digest(['cloud-sync-received-archive-guid-v1', guid]);

  static String localSendGuidHashFor(String guid) =>
      _digest(['cloud-sync-local-send-guid-v1', guid]);

  static String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// Maximum pages scanned by one [readReadyPage] call. Bounds per-call work
  /// while letting valid rows behind a bounded run of invalid head rows
  /// surface instead of starving.
  static const int _maxReadPages = 8;

  /// Durably owns one already-staged incoming source for one Message
  /// persisted atomically in the same transaction. Takes the original
  /// wire plus [liveContext] and runs full capture inside the transaction
  /// on the actually persisted rows. A precomputed identity is never
  /// accepted. Idempotent for the exact same account+GUID/source/parent
  /// plus binding; differing source/row/account/store refuses without
  /// overwriting, preserving any prior capture. Drift before persist
  /// fails capture and rolls back both rows. Native staging supplies the
  /// bound hash/ref via [source]; parent owns that next phase. Do not do
  /// async or UI work in [persistMessage]. Chat must already be persisted.
  int saveReceivedCapture({
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required int Function() persistMessage,
    required int localChatId,
    required CloudSyncReceivedArchiveSourceBinding source,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required bool Function() stillCurrent,
    required DateTime now,
  }) => _store.runInTransaction(TxMode.write, () {
    _verifyOwnership();
    if (!stillCurrent() || !now.isUtc || now.millisecondsSinceEpoch <= 0) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    if (capturedAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    if (localChatId <= 0) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    if (_hasOutgoingGuid(wire.id)) {
      throw StateError('cloud_sync_received_archive_outgoing_overlap');
    }
    // The typed binding is not authentication proof; account/store must
    // agree before persisting. GUID/source agreement is proven after the
    // in-transaction capture below.
    if (source.accountFingerprint != capturedAuth.accountFingerprint ||
        source.accountFingerprint != _binding.scope.accountFingerprint ||
        source.protectedStoreIdentity != capturedAuth.protectedStoreIdentity) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    // Caller-owned atomic persistence plus adoption in one transaction.
    // Synchronous only; no async or UI work is permitted here.
    final localMessageId = persistMessage();
    // The callback can synchronously trigger an account/owner change. Its
    // persistence belongs to this transaction and must roll back with capture.
    _verifyOwnership();
    if (!stillCurrent()) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    if (localMessageId <= 0) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    final message = _store.box<Message>().get(localMessageId);
    final chat = _store.box<Chat>().get(localChatId);
    if (message == null || chat == null) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    // Message.handle is transient and absent on a raw box read; resolve
    // it in memory exactly as Message.findOne does via getHandle, without
    // writing. Capture below then sees the same sender evidence the live
    // receive path persisted through handleId.
    if (message.handle == null && message.handleId != null) {
      message.handle = _readUnique(
        _store.box<Handle>().query(
          Handle_.originalROWID.equals(message.handleId!),
        ),
      );
    }
    final capture = CloudSyncReceivedArchiveIdentity.capture(
      message: message,
      chat: chat,
      wire: wire,
      liveContext: liveContext,
      expectedSourceSha256: source.sourceSha256,
    );
    final CloudSyncReceivedArchiveIdentity identity;
    if (capture is CloudSyncReceivedArchiveEligible) {
      identity = capture.identity;
    } else if (capture is CloudSyncReceivedArchiveIneligible) {
      throw StateError(capture.reason);
    } else {
      throw StateError('cloud_sync_received_archive_source_changed');
    }
    if (source.messageGuidHash != identity.guidHash ||
        source.sourceSha256 != identity.sourceSha256) {
      throw StateError('cloud_sync_received_archive_protected_source_changed');
    }
    final key = intentKeyFor(
      accountFingerprint: _binding.scope.accountFingerprint,
      messageGuidHash: identity.guidHash,
    );
    final existing = _readUnique(
      _store.box<CloudSyncReceivedArchiveIntentEntity>().query(
        CloudSyncReceivedArchiveIntentEntity_.intentKey.equals(key),
      ),
    );
    final encoded = source.encode();
    if (existing != null) {
      final bound = _readBoundIntent(existing.id);
      if (bound.localMessageId != localMessageId ||
          bound.localChatId != localChatId ||
          bound.messageGuidHash != identity.guidHash ||
          bound.sourceSha256 != identity.sourceSha256 ||
          bound.origin != identity.origin.index ||
          bound.protectedSourceBinding != encoded) {
        throw StateError('cloud_sync_received_archive_intent_changed');
      }
      return bound.id;
    }
    final time = now.millisecondsSinceEpoch;
    return _store.box<CloudSyncReceivedArchiveIntentEntity>().put(
      CloudSyncReceivedArchiveIntentEntity(
        intentKey: key,
        accountFingerprint: _binding.scope.accountFingerprint,
        writerEpoch: _binding.epoch,
        localMessageId: localMessageId,
        localChatId: localChatId,
        messageGuidHash: identity.guidHash,
        sourceSha256: identity.sourceSha256,
        origin: identity.origin.index,
        protectedSourceBinding: encoded,
        state: 0,
        createdAtMs: time,
        updatedAtMs: time,
      ),
    );
  });

  /// Recovers the exact adopted lease after crash. Never rolls back.
  CloudSyncReceivedArchiveSourceBinding? findProtectedSource({
    required String messageGuid,
    required int localChatId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    if (currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final key = intentKeyFor(
      accountFingerprint: currentAuth.accountFingerprint,
      messageGuidHash: guidHashFor(messageGuid),
    );
    final found = _readUnique(
      _store.box<CloudSyncReceivedArchiveIntentEntity>().query(
        CloudSyncReceivedArchiveIntentEntity_.intentKey.equals(key),
      ),
    );
    if (found == null) return null;
    final existing = _readBoundIntent(found.id);
    if (existing.localChatId != localChatId) {
      throw StateError('cloud_sync_received_archive_route_changed');
    }
    final source = CloudSyncReceivedArchiveSourceBinding.decode(
      existing.protectedSourceBinding,
    );
    source.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      messageGuidHash: existing.messageGuidHash,
      sourceSha256: existing.sourceSha256,
    );
    return source;
  });

  /// Recovers the exact adopted lease after crash. Never rolls back.
  CloudSyncReceivedArchiveSourceBinding readProtectedSource({
    required int intentId,
    required CloudSyncNativeAuthSnapshot currentAuth,
  }) => _store.runInTransaction(TxMode.read, () {
    _verifyOwnership();
    final intent = _readBoundIntent(intentId);
    final source = CloudSyncReceivedArchiveSourceBinding.decode(
      intent.protectedSourceBinding,
    );
    source.requireOrigin(
      accountFingerprint: currentAuth.accountFingerprint,
      messageGuidHash: intent.messageGuidHash,
      sourceSha256: intent.sourceSha256,
      protectedStoreIdentity: currentAuth.protectedStoreIdentity,
    );
    return source;
  });

  /// Bounded resumable read of staged candidates. Metadata-ready only,
  /// never upload authority: a returned row proves journal ownership plus
  /// parent binding, GUID-hash equality, direction, legacy-flag and sender
  /// evidence, not full source content. Post-adoption local body edits are
  /// not detected here; full wire plus protected-source revalidation
  /// remains the separate admission job. Filters (never throws for)
  /// per-row mismatches; ownership and auth mismatches still fail closed
  /// for the whole read. Record-map/snapshot dedup against Apple records
  /// requires existing native canonical key hashes at separate admission
  /// and is explicitly gated here.
  ///
  /// Keyset pagination (stable updatedAt/id order, never mutable offset)
  /// with a caller-held opaque [cursor]: each call scans at most
  /// [_maxReadPages] pages of `limit` rows, skipping invalid rows without
  /// ever stalling behind them. The caller must drive the drain loop to
  /// [CloudSyncReceivedArchiveReadPage.exhausted], holding the returned
  /// [CloudSyncReceivedArchiveReadPage.nextCursor] between calls. The
  /// cursor is pinned to the current account/epoch and is rejected after
  /// an owner change; restart the drain from null then. The cursor itself
  /// grants nothing and is not upload authority. Permanently invalid rows
  /// are left for explicit disposition, never silently retired.
  CloudSyncReceivedArchiveReadPage readReadyPage({
    int limit = 50,
    required CloudSyncNativeAuthSnapshot currentAuth,
    String? cursor,
  }) => _store.runInTransaction(TxMode.read, () {
    if (limit < 1 || limit > 50) {
      throw ArgumentError('cloud_sync_received_archive_limit_invalid');
    }
    _verifyOwnership();
    if (currentAuth.accountFingerprint != _binding.scope.accountFingerprint) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final resume = _decodeCursor(cursor);
    final ready = <CloudSyncReceivedArchiveIntentEntity>[];
    var scanned = 0;
    var pages = 0;
    var afterUpdatedAt = resume.updatedAtMs;
    var afterId = resume.id;
    // Keyset applies from the second page on even when the call started
    // without a cursor; otherwise every page would rescan the same head
    // rows and a long stale run would stall the drain within one call.
    var keyed = resume.active;
    var exhausted = false;
    CloudSyncReceivedArchiveIntentEntity? lastScanned;
    while (ready.length < limit && pages < _maxReadPages) {
      final base = CloudSyncReceivedArchiveIntentEntity_.accountFingerprint
          .equals(_binding.scope.accountFingerprint)
          .and(
            CloudSyncReceivedArchiveIntentEntity_.writerEpoch.equals(
              _binding.epoch,
            ),
          )
          .and(CloudSyncReceivedArchiveIntentEntity_.state.equals(0));
      final scoped = keyed
          ? base.and(
              CloudSyncReceivedArchiveIntentEntity_.updatedAtMs
                  .greaterThan(afterUpdatedAt)
                  .or(
                    CloudSyncReceivedArchiveIntentEntity_.updatedAtMs
                        .equals(afterUpdatedAt)
                        .and(
                          CloudSyncReceivedArchiveIntentEntity_.id.greaterThan(
                            afterId,
                          ),
                        ),
                  ),
            )
          : base;
      final query =
          _store
              .box<CloudSyncReceivedArchiveIntentEntity>()
              .query(scoped)
              .order(CloudSyncReceivedArchiveIntentEntity_.updatedAtMs)
              .order(CloudSyncReceivedArchiveIntentEntity_.id)
              .build()
            ..limit = limit;
      final List<CloudSyncReceivedArchiveIntentEntity> page;
      try {
        page = query.find();
      } finally {
        query.close();
      }
      if (page.isEmpty) {
        exhausted = true;
        break;
      }
      pages++;
      for (final candidate in page) {
        if (ready.length >= limit) break;
        lastScanned = candidate;
        scanned++;
        if (_isReady(candidate, currentAuth)) ready.add(candidate);
      }
      // Do not consume an unvisited tail merely because it was prefetched.
      // The next call must start after the last row actually considered.
      if (ready.length >= limit) break;
      if (page.length < limit) {
        exhausted = true;
        break;
      }
      afterUpdatedAt = page.last.updatedAtMs;
      afterId = page.last.id;
      keyed = true;
    }
    return CloudSyncReceivedArchiveReadPage(
      ready: List<CloudSyncReceivedArchiveIntentEntity>.unmodifiable(ready),
      scanned: scanned,
      nextCursor: exhausted || lastScanned == null
          ? null
          : _encodeCursor(lastScanned.updatedAtMs, lastScanned.id),
      exhausted: exhausted,
    );
  });

  /// Fair round-robin bump without changing immutable origin. Blocked rows
  /// stay ready and cannot monopolize a bounded worker.
  void markReadConsidered({required int intentId, required DateTime now}) =>
      _store.runInTransaction(TxMode.write, () {
        _verifyOwnership();
        if (!now.isUtc || now.millisecondsSinceEpoch <= 0) {
          throw StateError('cloud_sync_received_archive_time_invalid');
        }
        final intent = _readBoundIntent(intentId);
        if (intent.state != 0) {
          throw StateError('cloud_sync_received_archive_not_ready');
        }
        final observed = now.millisecondsSinceEpoch;
        intent.updatedAtMs = observed > intent.updatedAtMs
            ? observed
            : intent.updatedAtMs + 1;
        _store.box<CloudSyncReceivedArchiveIntentEntity>().put(intent);
      });

  /// Read-only integration point for restart GC. Returns live protected
  /// blob references owned by ALL durable received rows, regardless of
  /// writer epoch, account, or state: a retained old-epoch row still owns
  /// its evidence. Malformed ownership fails closed. Bounded read-only
  /// scan; never promotes, mutates, or releases. Production GC uses the
  /// complete ObjectBoxCloudSyncStore inventory, not this consumer's scope.
  Set<String> readLiveReceivedArchiveReferences({required int maximumCount}) =>
      _store.runInTransaction(TxMode.read, () {
        if (maximumCount <= 0 || maximumCount > 4096) {
          throw ArgumentError('cloud_sync_received_archive_limit_invalid');
        }
        _verifyOwnership();
        final query = _store
            .box<CloudSyncReceivedArchiveIntentEntity>()
            .query()
            .build();
        try {
          if (query.count() > maximumCount) {
            throw StateError('cloud_sync_received_archive_not_ready');
          }
          final refs = <String>{};
          for (final intent in query.find()) {
            // Retain every durable row; never silently drop an old-epoch
            // row that still owns evidence. Malformed ownership fails closed.
            if (intent.intentKey !=
                    intentKeyFor(
                      accountFingerprint: intent.accountFingerprint,
                      messageGuidHash: intent.messageGuidHash,
                    ) ||
                !_hasConsistentBinding(intent)) {
              throw StateError('cloud_sync_received_archive_intent_changed');
            }
            final src = CloudSyncReceivedArchiveSourceBinding.decode(
              intent.protectedSourceBinding,
            );
            refs.add(src.protectedReference);
          }
          return Set<String>.unmodifiable(refs);
        } finally {
          query.close();
        }
      });

  /// Read-only integration point for crash-handoff lease recovery.
  /// Returns live lease references owned by ALL durable received rows,
  /// regardless of writer epoch, account, or state. Malformed ownership
  /// fails closed. Bounded read-only diagnostic scan.
  Set<String> readLiveReceivedArchiveLeaseReferences({
    required int maximumCount,
  }) => _store.runInTransaction(TxMode.read, () {
    if (maximumCount <= 0 || maximumCount > 4096) {
      throw ArgumentError('cloud_sync_received_archive_limit_invalid');
    }
    _verifyOwnership();
    final query = _store
        .box<CloudSyncReceivedArchiveIntentEntity>()
        .query()
        .build();
    try {
      if (query.count() > maximumCount) {
        throw StateError('cloud_sync_received_archive_not_ready');
      }
      final leases = <String>{};
      for (final intent in query.find()) {
        // Same retain-all-or-fail-closed contract as the blob helper.
        if (intent.intentKey !=
                intentKeyFor(
                  accountFingerprint: intent.accountFingerprint,
                  messageGuidHash: intent.messageGuidHash,
                ) ||
            !_hasConsistentBinding(intent)) {
          throw StateError('cloud_sync_received_archive_intent_changed');
        }
        final src = CloudSyncReceivedArchiveSourceBinding.decode(
          intent.protectedSourceBinding,
        );
        leases.add(src.leaseReference);
      }
      return Set<String>.unmodifiable(leases);
    } finally {
      query.close();
    }
  });

  bool _isReady(
    CloudSyncReceivedArchiveIntentEntity candidate,
    CloudSyncNativeAuthSnapshot currentAuth,
  ) {
    try {
      if (candidate.accountFingerprint != _binding.scope.accountFingerprint ||
          candidate.writerEpoch != _binding.epoch ||
          candidate.state != 0 ||
          candidate.intentKey !=
              intentKeyFor(
                accountFingerprint: candidate.accountFingerprint,
                messageGuidHash: candidate.messageGuidHash,
              )) {
        return false;
      }
      final source = CloudSyncReceivedArchiveSourceBinding.decode(
        candidate.protectedSourceBinding,
      );
      source.requireOrigin(
        accountFingerprint: currentAuth.accountFingerprint,
        messageGuidHash: candidate.messageGuidHash,
        sourceSha256: candidate.sourceSha256,
        protectedStoreIdentity: currentAuth.protectedStoreIdentity,
      );
      final message = _store.box<Message>().get(candidate.localMessageId);
      final chat = _store.box<Chat>().get(candidate.localChatId);
      if (message == null ||
          chat == null ||
          message.dateDeleted != null ||
          message.id != candidate.localMessageId ||
          chat.id != candidate.localChatId) {
        return false;
      }
      // Exact parent relationship from the live rows.
      final boundChatId = message.chat.targetId;
      if (boundChatId != candidate.localChatId) return false;
      if (chat.dateDeleted != null) return false;
      final guid = message.guid;
      if (guid == null || guidHashFor(guid) != candidate.messageGuidHash) {
        return false;
      }
      final bool expectFromMe =
          candidate.origin == CloudSyncReceivedArchiveOrigin.mirrored.index;
      if (candidate.origin != CloudSyncReceivedArchiveOrigin.incoming.index &&
          candidate.origin != CloudSyncReceivedArchiveOrigin.mirrored.index) {
        return false;
      }
      if (message.isFromMe != expectFromMe) return false;
      if (message.ckRecordId != null || message.ckSyncState == true) {
        return false;
      }
      // Sender evidence still exists (transient handle or handleId lookup).
      if (!_hasSenderEvidence(message)) return false;
      // Outgoing-intent overlap: an echoed local send must not acquire a
      // second received identity. Checked by row and by recomputed
      // local-send GUID hash from the live GUID (exact, no cross-lane
      // guessing). Record-map/snapshot dedup is gated to separate
      // admission with existing native canonical key hashes.
      if (_hasOutgoingOverlap(candidate, guid)) return false;
      return true;
    } on StateError {
      return false;
    }
  }

  bool _hasSenderEvidence(Message message) {
    final direct = message.handle;
    if (direct != null) {
      if (direct.address.isEmpty) return false;
      final rowId = message.handleId;
      final handleRowId = direct.originalROWID;
      if (rowId != null && handleRowId != null && rowId != handleRowId) {
        return false;
      }
      return true;
    }
    final handleId = message.handleId;
    if (handleId == null) return false;
    final found = _readUnique(
      _store.box<Handle>().query(Handle_.originalROWID.equals(handleId)),
    );
    return found != null && found.address.isNotEmpty;
  }

  bool _hasOutgoingOverlap(
    CloudSyncReceivedArchiveIntentEntity candidate,
    String guid,
  ) {
    final byRow = _store
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.localMessageId.equals(
            candidate.localMessageId,
          ),
        )
        .build();
    try {
      for (final row in byRow.find()) {
        if (row.accountFingerprint == candidate.accountFingerprint) {
          return true;
        }
      }
    } finally {
      byRow.close();
    }
    final localSendHash = localSendGuidHashFor(guid);
    final byGuid = _store
        .box<CloudSyncLocalSendIntentEntity>()
        .query(
          CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(localSendHash),
        )
        .build();
    try {
      for (final row in byGuid.find()) {
        if (row.accountFingerprint == candidate.accountFingerprint) {
          return true;
        }
      }
    } finally {
      byGuid.close();
    }
    return false;
  }

  CloudSyncReceivedArchiveIntentEntity _readBoundIntent(int intentId) {
    final intent = intentId > 0
        ? _store.box<CloudSyncReceivedArchiveIntentEntity>().get(intentId)
        : null;
    if (intent == null ||
        intent.accountFingerprint != _binding.scope.accountFingerprint ||
        intent.writerEpoch != _binding.epoch ||
        intent.state != 0 ||
        (intent.origin != CloudSyncReceivedArchiveOrigin.incoming.index &&
            intent.origin != CloudSyncReceivedArchiveOrigin.mirrored.index) ||
        intent.intentKey !=
            intentKeyFor(
              accountFingerprint: intent.accountFingerprint,
              messageGuidHash: intent.messageGuidHash,
            ) ||
        !_hasConsistentBinding(intent)) {
      throw StateError('cloud_sync_received_archive_intent_changed');
    }
    return intent;
  }

  static bool _hasConsistentBinding(
    CloudSyncReceivedArchiveIntentEntity intent,
  ) {
    try {
      CloudSyncReceivedArchiveSourceBinding.decode(
        intent.protectedSourceBinding,
      ).requireOrigin(
        accountFingerprint: intent.accountFingerprint,
        messageGuidHash: intent.messageGuidHash,
        sourceSha256: intent.sourceSha256,
      );
    } on StateError {
      return false;
    }
    return true;
  }

  T? _readUnique<T>(QueryBuilder<T> builder) {
    final query = builder.build();
    try {
      return query.findUnique();
    } finally {
      query.close();
    }
  }

  void _verifyOwnership() {
    if (_binding.owner != CloudKitWriterOwner.v2 ||
        _binding.epoch <= 0 ||
        _binding.scope.container != 'com.apple.messages.cloud' ||
        _binding.scope.database != 'private') {
      throw StateError('cloud_sync_received_archive_owner_invalid');
    }
    final current = _authority.read(_binding.scope);
    if (current == null ||
        current.owner != _binding.owner ||
        current.epoch != _binding.epoch) {
      throw StateError('cloud_sync_received_archive_owner_changed');
    }
  }

  /// Opaque resume point for [readReadyPage]. `active` is false for the
  /// initial call (no cursor). The cursor pins the drain to one account
  /// and writer epoch; any mismatch fails the call closed.
  ({bool active, int updatedAtMs, int id}) _decodeCursor(String? cursor) {
    if (cursor == null) return (active: false, updatedAtMs: 0, id: 0);
    if (cursor.length > 512) {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    final dynamic fields;
    try {
      fields = jsonDecode(utf8.decode(base64Url.decode(cursor)));
    } on FormatException {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    if (fields is! List ||
        fields.length != 5 ||
        fields[0] != 1 ||
        fields[1] is! String ||
        fields[2] is! int ||
        fields[3] is! int ||
        fields[4] is! int) {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    if (fields[1] != _binding.scope.accountFingerprint ||
        fields[2] != _binding.epoch ||
        fields[3] <= 0 ||
        fields[4] <= 0) {
      throw ArgumentError('cloud_sync_received_archive_cursor_invalid');
    }
    return (active: true, updatedAtMs: fields[3] as int, id: fields[4] as int);
  }

  String _encodeCursor(int updatedAtMs, int id) => base64Url.encode(
    utf8.encode(
      jsonEncode([
        1,
        _binding.scope.accountFingerprint,
        _binding.epoch,
        updatedAtMs,
        id,
      ]),
    ),
  );
}

/// Bounded read-only page from
/// [CloudSyncReceivedArchiveJournal.readReadyPage]. The cursor is opaque,
/// caller-held drain state: it grants nothing and is not upload authority.
final class CloudSyncReceivedArchiveReadPage {
  const CloudSyncReceivedArchiveReadPage({
    required this.ready,
    required this.scanned,
    required this.nextCursor,
    required this.exhausted,
  });

  /// Metadata-ready intents, at most the requested limit.
  final List<CloudSyncReceivedArchiveIntentEntity> ready;

  /// Journal rows validated (ready or skipped) during this call.
  final int scanned;

  /// Resume point for the next call, or null when [exhausted].
  final String? nextCursor;

  /// True only when this call proved no unscanned rows remain.
  final bool exhausted;

  @override
  String toString() =>
      'CloudSyncReceivedArchiveReadPage(ready=${ready.length}, scanned=$scanned, exhausted=$exhausted)';
}
