import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_producer.dart';
import 'cloud_sync_transport.dart';

enum CloudSyncHistoricalCursorMode { stageOnly, archive }

/// Durable scan progress, not an upload receipt or authority to write CloudKit.
///
/// One small file belongs to one qualified snapshot/account/protected store.
/// Page adoption must finish before save. Writes use the existing native local
/// store exclusion, compare against the last load, flush, then rename in place.
/// An interrupted promotion leaves the previous cursor authoritative; leftover
/// temporary files never count as progress. No reset or deletion API is exposed.
/// The owner still qualifies and retains the immutable snapshot independently.
final class CloudSyncHistoricalCursorFile implements HistoricalCursorStore {
  CloudSyncHistoricalCursorFile({
    required String privateStorageDirectory,
    required CloudSyncHistoricalSourceManifest manifest,
    required CloudSyncHistoricalAccountBinding account,
    required this.transport,
    required this.stillCurrent,
    this.mode = CloudSyncHistoricalCursorMode.stageOnly,
    this.archiveRevision = 0,
  }) : _root = Directory(privateStorageDirectory).absolute,
       _storeIdentity = account.protectedStoreIdentity,
       scope = historicalArchiveScope(manifest, account) {
    if (!manifest.hasValidShape(nowMs: DateTime.now().millisecondsSinceEpoch) ||
        !account.hasValidShape ||
        manifest.accountFingerprint != account.accountFingerprint ||
        !path.isAbsolute(privateStorageDirectory) ||
        archiveRevision < 0 ||
        archiveRevision > 0x7fffffff ||
        (mode == CloudSyncHistoricalCursorMode.stageOnly &&
            archiveRevision != 0)) {
      throw StateError('cloud_sync_historical_cursor_binding_invalid');
    }
  }

  static const directoryName = 'cloud-sync-v2-history-progress';
  static const maximumEncodedBytes = 1024;
  static final _digest = RegExp(r'^[0-9a-f]{64}$');
  static final _position = RegExp(
    r'^historical-scan:v1:([0-9a-f]{64}):([1-9][0-9]{0,18})$',
  );

  final Directory _root;
  final String _storeIdentity;
  final String scope;
  final CloudProtectedPageLeaseTransport transport;
  final bool Function() stillCurrent;
  final CloudSyncHistoricalCursorMode mode;

  /// Revision of archive eligibility/projection, not source identity. An older
  /// completed scan may have retained unsupported rows. A reviewed newer policy
  /// gets fresh progress over the same immutable source while its journals still
  /// reconcile exact old operations. Zero preserves the original cursor format.
  final int archiveRevision;
  bool _loaded = false;
  String? _expectedEncoded;

  void _requireCurrent() {
    if (!stillCurrent() ||
        transport.protectedPageLeaseRecoveryIdentity != _storeIdentity) {
      throw StateError('cloud_sync_historical_cursor_identity_changed');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    _requireCurrent();
    final local = transport;
    if (local is! CloudProtectedLocalLifecycleTransport) {
      throw StateError('cloud_sync_historical_cursor_exclusion_unavailable');
    }
    return (local as CloudProtectedLocalLifecycleTransport)
        .runLocalProtectedStoreExclusive(() async {
          _requireCurrent();
          try {
            final result = await action();
            _requireCurrent();
            return result;
          } on FileSystemException {
            // Do not expose a private profile path through error reporting.
            throw StateError(
              'cloud_sync_historical_cursor_storage_unavailable',
            );
          }
        });
  }

  Future<File?> _target({required bool createDirectory}) async {
    final rootPath = path.normalize(await _root.resolveSymbolicLinks());
    final directory = Directory(path.join(rootPath, directoryName));
    if (!await directory.exists()) {
      if (!createDirectory) return null;
      await directory.create();
    }
    final directoryPath = path.normalize(
      await directory.resolveSymbolicLinks(),
    );
    if (!path.isWithin(rootPath, directoryPath)) {
      throw StateError('cloud_sync_historical_cursor_storage_untrusted');
    }
    // A finished staging scan is not a finished upload. Keep independent
    // cursors so old staging-only progress can never bypass archival work.
    final suffix = mode != CloudSyncHistoricalCursorMode.archive
        ? ''
        : archiveRevision == 0
        ? '.archive'
        : '.archive-r$archiveRevision';
    final target = File(path.join(directoryPath, '$scope$suffix.json'));
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('cloud_sync_historical_cursor_storage_untrusted');
    }
    return target;
  }

  int? _validate(HistoricalProducerCursor cursor) {
    if (cursor.scope != scope || cursor.done != (cursor.lastId == null)) {
      throw StateError('cloud_sync_historical_cursor_record_invalid');
    }
    if (cursor.done) return null;
    final match = _position.firstMatch(cursor.lastId!);
    final id = match == null ? null : int.tryParse(match.group(2)!);
    if (match == null || match.group(1) != scope || id == null || id < 1) {
      throw StateError('cloud_sync_historical_cursor_record_invalid');
    }
    return id;
  }

  String _encode(HistoricalProducerCursor cursor) {
    _validate(cursor);
    final body = mode == CloudSyncHistoricalCursorMode.stageOnly
        ? <Object?>[1, scope, cursor.lastId, cursor.done]
        : <Object?>[
            archiveRevision == 0 ? 2 : 3,
            scope,
            cursor.lastId,
            cursor.done,
            'archive',
            if (archiveRevision != 0) archiveRevision,
          ];
    final checksum = sha256.convert(utf8.encode(jsonEncode(body))).toString();
    return jsonEncode([...body, checksum]);
  }

  HistoricalProducerCursor _decode(String encoded) {
    try {
      final fields = jsonDecode(encoded);
      final archive = mode == CloudSyncHistoricalCursorMode.archive;
      final versioned = archive && archiveRevision != 0;
      final checksumIndex = versioned
          ? 6
          : archive
          ? 5
          : 4;
      if (fields is! List ||
          fields.length != checksumIndex + 1 ||
          fields[0] !=
              (versioned
                  ? 3
                  : archive
                  ? 2
                  : 1) ||
          (archive && fields[4] != 'archive') ||
          (versioned && fields[5] != archiveRevision) ||
          fields[1] is! String ||
          (fields[2] != null && fields[2] is! String) ||
          fields[3] is! bool ||
          fields[checksumIndex] is! String ||
          !_digest.hasMatch(fields[checksumIndex] as String)) {
        throw const FormatException();
      }
      final cursor = HistoricalProducerCursor(
        scope: fields[1] as String,
        lastId: fields[2] as String?,
        done: fields[3] as bool,
      );
      // Checksum detects damaged progress. It is not authentication or proof
      // that a source was adopted, uploaded, or belongs to the signed-in user.
      if (_encode(cursor) != encoded) throw const FormatException();
      return cursor;
    } on FormatException {
      throw StateError('cloud_sync_historical_cursor_record_invalid');
    }
  }

  Future<String?> _read(File? target) async {
    if (target == null || !await target.exists()) return null;
    final handle = await target.open(mode: FileMode.read);
    try {
      final bytes = await handle.read(maximumEncodedBytes + 1);
      if (bytes.isEmpty || bytes.length > maximumEncodedBytes) {
        throw StateError('cloud_sync_historical_cursor_record_invalid');
      }
      try {
        final encoded = utf8.decode(bytes);
        _decode(encoded);
        return encoded;
      } on FormatException {
        throw StateError('cloud_sync_historical_cursor_record_invalid');
      }
    } finally {
      await handle.close();
    }
  }

  @override
  Future<HistoricalProducerCursor?> load() => _exclusive(() async {
    final encoded = await _read(await _target(createDirectory: false));
    _expectedEncoded = encoded;
    _loaded = true;
    return encoded == null ? null : _decode(encoded);
  });

  @override
  Future<void> save(HistoricalProducerCursor? cursor) async {
    if (!_loaded || cursor == null) {
      throw StateError('cloud_sync_historical_cursor_load_required');
    }
    final encoded = _encode(cursor);
    await _exclusive(() async {
      final target = (await _target(createDirectory: true))!;
      final actual = await _read(target);
      if (actual != _expectedEncoded) {
        throw StateError('cloud_sync_historical_cursor_concurrent_change');
      }
      if (actual == encoded) return;
      if (actual != null) {
        final previous = _decode(actual);
        if (previous.done ||
            (!cursor.done && _validate(cursor)! <= _validate(previous)!)) {
          throw StateError('cloud_sync_historical_cursor_cannot_rewind');
        }
      }
      final random = Random.secure();
      final nonce = List.generate(
        12,
        (_) => random.nextInt(256),
      ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
      final temporary = File(
        path.join(target.parent.path, '.$scope.$nonce.tmp'),
      );
      try {
        await temporary.writeAsString(encoded, flush: true);
        _requireCurrent();
        await temporary.rename(target.path);
        _expectedEncoded = encoded;
      } finally {
        // Only this invocation's private temporary file is disposable. A crash
        // can leave another temp file, which is ignored rather than promoted.
        if (await temporary.exists()) await temporary.delete();
      }
    });
  }
}
