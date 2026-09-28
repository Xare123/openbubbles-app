import 'dart:convert';
import 'dart:isolate';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_objectbox_reader.dart';
import 'cloud_sync_historical_producer.dart';
import 'cloud_sync_historical_snapshot_codec.dart';

/// Content-frozen source, not proof that a database belongs to an Apple account.
/// The service must qualify the source owner and validate current auth/store
/// before and after capture. Capture is read-only and must run off the UI
/// isolate. No live DB file is copied, and nothing is sent or persisted here.
///
/// Retaining canonical strings instead of Message/AttributedBody objects stops
/// later relation loads, database edits and consumer mutations changing a source.
/// The caller must durably protect this export before archival or progress can
/// be offered across restart. This memory reader alone is not restart support.
final class CloudSyncHistoricalSnapshot implements HistoricalRowReader {
  CloudSyncHistoricalSnapshot._({
    required this.account,
    required this.manifest,
    required List<String> encodedRows,
    required List<int> ids,
    required Map<String, List<int>> guidIndexes,
    required this.encodedByteLength,
  }) : _rows = List.unmodifiable(encodedRows),
       _ids = List.unmodifiable(ids),
       _guidIndexes = Map.unmodifiable({
         for (final entry in guidIndexes.entries)
           entry.key: List<int>.unmodifiable(entry.value),
       });

  static const maximumRows = 100000;
  static const maximumBytes = 32 * 1024 * 1024;
  static const maximumPageSize = 200;
  static final _cursor = RegExp(
    r'^historical-scan:v1:([a-f0-9]{64}):([1-9][0-9]{0,18})$',
  );

  final CloudSyncHistoricalAccountBinding account;
  final CloudSyncHistoricalSourceManifest manifest;
  final int encodedByteLength;
  final List<String> _rows;
  final List<int> _ids;
  final Map<String, List<int>> _guidIndexes;
  String get scope => historicalArchiveScope(manifest, account);

  /// Immutable canonical rows for private encrypted persistence only. Never
  /// log this content or put it in a diagnostic/progress report.
  Iterable<String> get encodedRows => _rows;

  /// Production capture entry point. The SDK attaches and closes its own worker
  /// Store; no native Store pointer, auth client or closure crosses isolates.
  /// The caller must validate the source database's account ownership, not just
  /// a newly supplied account string. That validation brackets the worker so a
  /// logout/account switch cannot publish the result under a replacement owner.
  static Future<CloudSyncHistoricalSnapshot> captureAsync({
    required Store store,
    required CloudSyncHistoricalAccountBinding account,
    required List<String> accountHandles,
    required int capturedAtMs,
    required Future<void> Function() validateSource,
    required bool Function() stillCurrent,
    int rowLimit = maximumRows,
    int byteLimit = maximumBytes,
  }) async {
    _requireLimits(rowLimit, byteLimit);
    final input = _HistoricalCaptureInput(
      account: account,
      handles: List<String>.unmodifiable(accountHandles),
      time: capturedAtMs,
      rowLimit: rowLimit,
      byteLimit: byteLimit,
    );
    void requireCurrent() {
      if (!stillCurrent() || store.isClosed()) {
        throw StateError('cloud_sync_historical_snapshot_identity_changed');
      }
    }

    requireCurrent();
    await validateSource();
    requireCurrent();
    final snapshot = await store.runAsync(_captureInWorker, input);
    requireCurrent();
    await validateSource();
    requireCurrent();
    return snapshot;
  }

  static CloudSyncHistoricalSnapshot _captureInWorker(
    Store store,
    _HistoricalCaptureInput input,
  ) => capture(
    store: store,
    account: input.account,
    accountHandles: input.handles,
    capturedAtMs: input.time,
    // The worker has no access to auth. Only the caller above validates it;
    // this check concerns the lifetime of the SDK-attached read-only view.
    stillCurrent: () => !store.isClosed(),
    rowLimit: input.rowLimit,
    byteLimit: input.byteLimit,
  );

  /// Every Message, Chat, Handle and attachment relation is resolved inside the
  /// same transaction. Limits fail the complete export, never truncate history
  /// and then mark it complete. The caller retains ownership of [store].
  static CloudSyncHistoricalSnapshot capture({
    required Store store,
    required CloudSyncHistoricalAccountBinding account,
    required List<String> accountHandles,
    required int capturedAtMs,
    required bool Function() stillCurrent,
    int rowLimit = maximumRows,
    int byteLimit = maximumBytes,
  }) {
    _requireLimits(rowLimit, byteLimit);
    if (!stillCurrent() || store.isClosed()) {
      throw StateError('cloud_sync_historical_snapshot_identity_changed');
    }
    final rows = store.runInTransaction(TxMode.read, () {
      final box = store.box<Message>();
      final count = box.count();
      if (count == 0) throw StateError('cloud_sync_historical_snapshot_empty');
      if (count > rowLimit) {
        throw StateError('cloud_sync_historical_snapshot_limit');
      }
      final lastQuery =
          box.query().order(Message_.id, flags: Order.descending).build()
            ..limit = 1;
      final int highWater;
      try {
        highWater = lastQuery.findFirst()?.id ?? 0;
      } finally {
        lastQuery.close();
      }
      // These placeholders never leave the capture. The codec excludes the
      // snapshot stamp; fromEncodedRows calculates the real content identity.
      final reader = CloudSyncHistoricalObjectBoxReader(
        store: store,
        scope: '0' * 64,
        rowSnapshotSha256: '0' * 64,
        highWaterId: highWater,
        expectedRowCount: count,
      );
      final result = <String>[];
      var bytes = 0;
      String? cursor;
      do {
        if (!stillCurrent()) {
          throw StateError('cloud_sync_historical_snapshot_identity_changed');
        }
        final page = reader.readPageInTransaction(
          cursor: cursor,
          limit: maximumPageSize,
        );
        for (final view in page.views) {
          final encoded = encodeHistoricalSnapshotRow(view);
          bytes += utf8.encode(encoded).length;
          if (bytes > byteLimit) {
            throw StateError('cloud_sync_historical_snapshot_limit');
          }
          result.add(encoded);
        }
        cursor = page.nextCursor;
      } while (cursor != null);
      if (result.length != count || !stillCurrent()) {
        throw StateError('cloud_sync_historical_snapshot_identity_changed');
      }
      return result;
    });
    final snapshot = fromEncodedRows(
      encodedRows: rows,
      account: account,
      accountHandles: accountHandles,
      capturedAtMs: capturedAtMs,
      rowLimit: rowLimit,
      byteLimit: byteLimit,
    );
    if (!stillCurrent() || store.isClosed()) {
      throw StateError('cloud_sync_historical_snapshot_identity_changed');
    }
    return snapshot;
  }

  /// Pure canonical reconstruction. Integrity and ordering checks here never
  /// authenticate an imported file or make its account assertion trustworthy.
  /// Use [fromEncodedRowsAsync] when reopening a sizeable export on the UI.
  static CloudSyncHistoricalSnapshot fromEncodedRows({
    required Iterable<String> encodedRows,
    required CloudSyncHistoricalAccountBinding account,
    required List<String> accountHandles,
    required int capturedAtMs,
    int rowLimit = maximumRows,
    int byteLimit = maximumBytes,
  }) {
    _requireLimits(rowLimit, byteLimit);
    final handles = List<String>.of(accountHandles)..sort();
    final provisional = CloudSyncHistoricalSourceManifest(
      snapshotSha256: '0' * 64,
      accountFingerprint: account.accountFingerprint,
      accountHandles: handles,
      messageCount: 1,
      capturedAtMs: capturedAtMs,
    );
    if (!account.hasValidShape ||
        !provisional.hasValidShape(
          nowMs: DateTime.now().millisecondsSinceEpoch,
        ) ||
        handles.toSet().length != handles.length) {
      throw StateError('cloud_sync_historical_snapshot_binding_invalid');
    }
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    hasher.add(
      utf8.encode(
        jsonEncode([
          'cloud-sync-historical-snapshot-v1',
          account.accountFingerprint,
          account.protectedStoreIdentity,
          handles,
          capturedAtMs,
        ]),
      ),
    );
    final rows = <String>[];
    final ids = <int>[];
    final guids = <String, List<int>>{};
    var bytes = 0;
    try {
      for (final encoded in encodedRows) {
        if (rows.length >= rowLimit) {
          throw StateError('cloud_sync_historical_snapshot_limit');
        }
        final raw = utf8.encode(encoded);
        bytes += raw.length;
        if (bytes > byteLimit) {
          throw StateError('cloud_sync_historical_snapshot_limit');
        }
        final view = decodeHistoricalSnapshotRow(
          encoded,
          snapshotSha256: '0' * 64,
        );
        if (view.messageId <= 0 ||
            (ids.isNotEmpty && view.messageId <= ids.last)) {
          throw StateError('cloud_sync_historical_snapshot_order_invalid');
        }
        (guids[view.guid] ??= []).add(rows.length);
        rows.add(encoded);
        ids.add(view.messageId);
        // Unambiguous newline framing: the canonical JSON encoder escapes every
        // newline inside values and decoder rejects alternate representations.
        hasher.add(const [10]);
        hasher.add(raw);
      }
    } finally {
      hasher.close();
    }
    if (rows.isEmpty) throw StateError('cloud_sync_historical_snapshot_empty');
    return CloudSyncHistoricalSnapshot._(
      account: account,
      manifest: CloudSyncHistoricalSourceManifest(
        snapshotSha256: digest.value!.toString(),
        accountFingerprint: account.accountFingerprint,
        accountHandles: List.unmodifiable(handles),
        messageCount: rows.length,
        capturedAtMs: capturedAtMs,
      ),
      encodedRows: rows,
      ids: ids,
      guidIndexes: guids,
      encodedByteLength: bytes,
    );
  }

  /// Only detached values cross this boundary. In particular, do not capture a
  /// service/native client or the encrypted file owner inside Isolate.run.
  static Future<CloudSyncHistoricalSnapshot> fromEncodedRowsAsync({
    required List<String> encodedRows,
    required CloudSyncHistoricalAccountBinding account,
    required List<String> accountHandles,
    required int capturedAtMs,
  }) {
    final rows = List<String>.unmodifiable(encodedRows);
    final handles = List<String>.unmodifiable(accountHandles);
    return Isolate.run(
      () => fromEncodedRows(
        encodedRows: rows,
        account: account,
        accountHandles: handles,
        capturedAtMs: capturedAtMs,
      ),
    );
  }

  static void _requireLimits(int rows, int bytes) {
    if (rows < 1 || rows > maximumRows || bytes < 1 || bytes > maximumBytes) {
      throw StateError('cloud_sync_historical_snapshot_limit');
    }
  }

  @override
  Future<HistoricalRowPage> readPage({
    String? cursor,
    required int limit,
  }) async {
    if (limit < 1 || limit > maximumPageSize) {
      throw StateError('cloud_sync_historical_snapshot_limit');
    }
    var start = 0;
    if (cursor != null) {
      final match = _cursor.firstMatch(cursor);
      final lastId = match == null ? null : int.tryParse(match.group(2)!);
      final index = lastId == null ? -1 : _ids.indexOf(lastId);
      if (match == null || match.group(1) != scope || index < 0) {
        throw StateError('cloud_sync_historical_snapshot_cursor_invalid');
      }
      start = index + 1;
    }
    final end = (start + limit).clamp(start, _rows.length);
    return HistoricalRowPage(
      views: [for (var i = start; i < end; i++) _decode(i)],
      nextCursor: end == _rows.length
          ? null
          : 'historical-scan:v1:$scope:${_ids[end - 1]}',
    );
  }

  Future<CloudSyncHistoricalRowView?> readExact(String guid) async {
    final indexes = _guidIndexes[guid];
    if (indexes == null) return null;
    if (indexes.length != 1) {
      throw StateError('cloud_sync_historical_snapshot_guid_ambiguous');
    }
    return _decode(indexes.single);
  }

  CloudSyncHistoricalRowView _decode(int index) => decodeHistoricalSnapshotRow(
    _rows[index],
    snapshotSha256: manifest.snapshotSha256,
  );
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

final class _HistoricalCaptureInput {
  const _HistoricalCaptureInput({
    required this.account,
    required this.handles,
    required this.time,
    required this.rowLimit,
    required this.byteLimit,
  });
  final CloudSyncHistoricalAccountBinding account;
  final List<String> handles;
  final int time;
  final int rowLimit;
  final int byteLimit;
}
