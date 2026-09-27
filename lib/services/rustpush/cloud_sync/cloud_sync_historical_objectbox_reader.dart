library;

import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_producer.dart';

/// Read-only ObjectBox reader for an already-qualified immutable source
/// snapshot. Pages Message rows by ascending ObjectBox id with a frozen
/// source high-water id, so rows appended after qualification are never
/// read. The caller owns the Store, freezes the high-water id and expected
/// row count from its own qualification, and supplies the trusted snapshot
/// identity; shape checks here never authenticate the account. No global
/// Database singleton, no credentials, no writes. Per-query handles are
/// closed; the caller store is never closed.

/// Fixed failure reasons. None carries row content.
class CloudSyncHistoricalReaderReasons {
  static const String malformedCursor =
      'cloud_sync_historical_reader_malformed_cursor';
  static const String foreignCursor =
      'cloud_sync_historical_reader_foreign_cursor';
  static const String pageInvalid = 'cloud_sync_historical_reader_page_invalid';
  static const String ambiguousHandle =
      'cloud_sync_historical_reader_ambiguous_handle';
  static const String missingHandle =
      'cloud_sync_historical_reader_missing_handle';
  static const String missingChat = 'cloud_sync_historical_reader_missing_chat';
  static const String snapshotMismatch =
      'cloud_sync_historical_reader_snapshot_mismatch';
}

/// Read failure carrying one fixed reason above. The caller retains and
/// reconciles the row; it never advances past it as success.
class CloudSyncHistoricalReaderException implements Exception {
  const CloudSyncHistoricalReaderException(this.reason);

  final String reason;

  @override
  String toString() => 'CloudSyncHistoricalReaderException: $reason';
}

/// Per-reader limits. Pages stay bounded regardless of caller input.
class CloudSyncHistoricalObjectBoxReader implements HistoricalRowReader {
  CloudSyncHistoricalObjectBoxReader({
    required this.store,
    required this.scope,
    required this.rowSnapshotSha256,
    required this.highWaterId,
    required this.expectedRowCount,
    this.maxPageLimit = 200,
  });

  /// Caller-owned store. Never closed here.
  final Store store;

  /// Scope binding this scan, from historicalArchiveScope. Foreign or
  /// malformed cursors are rejected without reading anything.
  final String scope;

  /// Trusted snapshot hash stamped onto every row view.
  final String rowSnapshotSha256;

  /// Frozen maximum Message id from qualification. Rows above it are
  /// never read, so post-qualification appends are excluded.
  final int highWaterId;

  /// Expected row count frozen at qualification. Validated against the
  /// frozen window on every page, including an exhausted cursor. This
  /// detects changed membership, not in-place content edits; the caller
  /// must still provide a qualified immutable snapshot.
  final int expectedRowCount;

  /// Hard ceiling for this reader instance. Construction clamps nothing;
  /// any value above the absolute cap fails closed at read time.
  final int maxPageLimit;

  /// Absolute ceiling for any reader instance or page.
  static const int absoluteMaxPageLimit = 500;

  static const _cursorVersion = 'v1';
  static const _cursorKind = 'historical-scan';
  static final _snapshotHex = RegExp(r'^[0-9a-f]{64}$');
  static final _scopeHash = RegExp(r'^[0-9a-f]{64}$');
  static final _decimalId = RegExp(r'^(0|[1-9][0-9]*)$');

  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async {
    if (limit < 1 ||
        limit > maxPageLimit ||
        maxPageLimit > absoluteMaxPageLimit ||
        highWaterId < 0 ||
        maxPageLimit < 1 ||
        expectedRowCount < 0 ||
        !_snapshotHex.hasMatch(rowSnapshotSha256) ||
        !_scopeHash.hasMatch(scope)) {
      throw const CloudSyncHistoricalReaderException(
        CloudSyncHistoricalReaderReasons.pageInvalid,
      );
    }
    final start = _parseCursor(cursor);
    return store.runInTransaction(TxMode.read, () {
      // Every page validates the frozen window, including the exhausted
      // shortcut, so no cursor can bypass the completion check.
      _checkSnapshotConsistency(store.box<Message>());
      if (start >= highWaterId) {
        return const HistoricalRowPage(views: [], nextCursor: null);
      }
      // Database-level bound: at most limit rows plus one exhaustion
      // sentinel. The sentinel proves more rows remain without a full
      // count scan.
      final box = store.box<Message>();
      final query =
          box
              .query(
                Message_.id
                    .greaterThan(start)
                    .and(Message_.id.lessOrEqual(highWaterId)),
              )
              .order(Message_.id)
              .build()
            ..limit = limit + 1;
      try {
        final rows = query.find();
        final views = <CloudSyncHistoricalRowView>[];
        var last = start;
        for (var i = 0; i < rows.length && i < limit; i++) {
          final message = rows[i];
          final id = message.id ?? -1;
          if (id <= start || id > highWaterId) {
            throw const CloudSyncHistoricalReaderException(
              CloudSyncHistoricalReaderReasons.snapshotMismatch,
            );
          }
          views.add(_mapRow(message));
          last = id;
        }
        final exhausted = rows.length <= limit;
        return HistoricalRowPage(
          views: views,
          nextCursor: exhausted ? null : _encodeCursor(last),
        );
      } finally {
        query.close();
      }
    });
  }

  /// Resolves one row's stored relations through the existing helpers,
  /// preserving the original sender and direction without inventing a
  /// local endpoint or choosing a preferred alias. Ambiguous or missing
  /// chat relations throw fixed reasons instead of dropping the row.
  CloudSyncHistoricalRowView _mapRow(Message message) {
    final resolvedChat = _resolveChat(message);
    _resolveHandle(message);
    return mapHistoricalRow(
      message: message,
      chat: mapHistoricalChat(resolvedChat),
      rowSnapshotSha256: rowSnapshotSha256,
    );
  }

  Chat _resolveChat(Message message) {
    final targetId = message.chat.targetId;
    if (targetId <= 0) {
      throw const CloudSyncHistoricalReaderException(
        CloudSyncHistoricalReaderReasons.missingChat,
      );
    }
    final matches = store.box<Chat>().get(targetId);
    if (matches == null) {
      throw const CloudSyncHistoricalReaderException(
        CloudSyncHistoricalReaderReasons.missingChat,
      );
    }
    return matches;
  }

  void _resolveHandle(Message message) {
    // Mirror Message.getHandle: handleId 0 or null means no recorded
    // sender, not row zero. Leave the sender unknown and let eligibility
    // reject missing sender; never invent an alias or direction.
    if (message.handle != null ||
        message.handleId == null ||
        message.handleId == 0) {
      return;
    }
    final query =
        store
            .box<Handle>()
            .query(Handle_.originalROWID.equals(message.handleId!))
            .build()
          ..limit = 2;
    try {
      final matches = query.find();
      if (matches.isEmpty) {
        throw const CloudSyncHistoricalReaderException(
          CloudSyncHistoricalReaderReasons.missingHandle,
        );
      }
      if (matches.length > 1) {
        throw const CloudSyncHistoricalReaderException(
          CloudSyncHistoricalReaderReasons.ambiguousHandle,
        );
      }
      message.handle = matches.single;
    } finally {
      query.close();
    }
  }

  void _checkSnapshotConsistency(Box<Message> box) {
    final query = box.query(Message_.id.lessOrEqual(highWaterId)).build();
    try {
      if (query.count() != expectedRowCount) {
        throw const CloudSyncHistoricalReaderException(
          CloudSyncHistoricalReaderReasons.snapshotMismatch,
        );
      }
    } finally {
      query.close();
    }
  }

  int _parseCursor(String? cursor) {
    if (cursor == null) return 0;
    final parts = cursor.split(':');
    if (parts.length != 4 ||
        parts[0] != _cursorKind ||
        parts[1] != _cursorVersion ||
        !_scopeHash.hasMatch(parts[2])) {
      throw const CloudSyncHistoricalReaderException(
        CloudSyncHistoricalReaderReasons.malformedCursor,
      );
    }
    if (parts[2] != scope) {
      throw const CloudSyncHistoricalReaderException(
        CloudSyncHistoricalReaderReasons.foreignCursor,
      );
    }
    if (!_decimalId.hasMatch(parts[3])) {
      throw const CloudSyncHistoricalReaderException(
        CloudSyncHistoricalReaderReasons.malformedCursor,
      );
    }
    final last = int.tryParse(parts[3]);
    if (last == null || last < 0 || last > highWaterId) {
      throw const CloudSyncHistoricalReaderException(
        CloudSyncHistoricalReaderReasons.malformedCursor,
      );
    }
    return last;
  }

  String _encodeCursor(int lastId) =>
      '$_cursorKind:$_cursorVersion:$scope:$lastId';
}
