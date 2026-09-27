import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_producer.dart';
import 'cloud_sync_transport.dart';

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
  }) : _root = Directory(privateStorageDirectory).absolute,
       _storeIdentity = account.protectedStoreIdentity,
       scope = historicalArchiveScope(manifest, account) {
    if (!manifest.hasValidShape(nowMs: DateTime.now().millisecondsSinceEpoch) ||
        !account.hasValidShape ||
        manifest.accountFingerprint != account.accountFingerprint ||
        !path.isAbsolute(privateStorageDirectory)) {
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
    final target = File(path.join(directoryPath, '$scope.json'));
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
    final body = <Object?>[1, scope, cursor.lastId, cursor.done];
    final checksum = sha256.convert(utf8.encode(jsonEncode(body))).toString();
    return jsonEncode([...body, checksum]);
  }

  HistoricalProducerCursor _decode(String encoded) {
    try {
      final fields = jsonDecode(encoded);
      if (fields is! List ||
          fields.length != 5 ||
          fields[0] != 1 ||
          fields[1] is! String ||
          (fields[2] != null && fields[2] is! String) ||
          fields[3] is! bool ||
          fields[4] is! String ||
          !_digest.hasMatch(fields[4] as String)) {
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
