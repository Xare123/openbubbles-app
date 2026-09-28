import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_snapshot.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_transport.dart';

/// One encrypted, immutable upgrade snapshot per account and installation.
///
/// Publication uses the existing cross-engine local store exclusion, identity
/// checks, a flushed temporary file and atomic rename. An existing different
/// snapshot is never replaced; it may own cursors or uncertain writes. Loading
/// verifies every ordered chunk and reconstructs the exact content digest.
/// No plaintext is written, no DB is copied, no CloudKit request is made and
/// no source-account ownership is inferred merely from the supplied binding.
final class CloudSyncHistoricalSnapshotFile {
  CloudSyncHistoricalSnapshotFile({
    required String privateStorageDirectory,
    required this.account,
    required this.protector,
    required this.transport,
    required this.validateIdentity,
    required this.stillCurrent,
  }) : _root = Directory(privateStorageDirectory).absolute {
    if (!path.isAbsolute(privateStorageDirectory) ||
        !account.hasValidShape ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(account.accountFingerprint) ||
        !RegExp(
          r'^obcs2\.store\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(account.protectedStoreIdentity)) {
      throw StateError('cloud_sync_historical_snapshot_binding_invalid');
    }
  }

  static const directoryName = 'cloud-sync-v2-history-snapshots';
  static const maximumFileBytes = 96 * 1024 * 1024;
  static const maximumChunkPlaintextBytes = 3 * 1024 * 1024;
  static const _maximumSealedChunkBytes = 8 * 1024 * 1024;
  static const _chunkRows = 200;
  static const _chunkTargetBytes = 1024 * 1024;
  static const _maximumChunks = 600;
  static const _maximumMetadataBytes = 512 * 1024;
  static const _tag = 'cloud-sync-historical-snapshot-file-v1';

  final Directory _root;
  final CloudSyncHistoricalAccountBinding account;
  final CloudSyncProtector protector;
  final CloudProtectedPageLeaseTransport transport;
  final Future<void> Function() validateIdentity;
  final bool Function() stillCurrent;

  String get _key => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            _tag,
            account.accountFingerprint,
            account.protectedStoreIdentity,
          ]),
        ),
      )
      .toString();

  CloudSyncScope get _scope => CloudSyncScope(
    accountFingerprint: account.accountFingerprint,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );

  void _current() {
    if (!stillCurrent() ||
        transport.protectedPageLeaseRecoveryIdentity !=
            account.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_snapshot_identity_changed');
    }
  }

  Future<void> _validate() async {
    _current();
    await validateIdentity();
    _current();
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    _current();
    final local = transport;
    if (local is! CloudProtectedLocalLifecycleTransport) {
      throw StateError('cloud_sync_historical_snapshot_exclusion_unavailable');
    }
    return (local as CloudProtectedLocalLifecycleTransport)
        .runLocalProtectedStoreExclusive(() async {
          await _validate();
          try {
            final result = await action();
            await _validate();
            return result;
          } on FileSystemException {
            throw StateError(
              'cloud_sync_historical_snapshot_storage_unavailable',
            );
          } on FormatException {
            throw StateError('cloud_sync_historical_snapshot_invalid');
          }
        });
  }

  Future<File?> _target({required bool create}) async {
    // Use the platform's canonical private root. Android may expose the same
    // application directory through /data/user/0 and /data/data aliases.
    final rootPath = path.normalize(await _root.resolveSymbolicLinks());
    final folder = Directory(path.join(rootPath, directoryName));
    final type = await FileSystemEntity.type(folder.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return null;
      await folder.create();
    } else if (type != FileSystemEntityType.directory) {
      throw StateError('cloud_sync_historical_snapshot_storage_untrusted');
    }
    final resolved = path.normalize(await folder.resolveSymbolicLinks());
    if (resolved != path.normalize(folder.path) ||
        !path.isWithin(rootPath, resolved)) {
      throw StateError('cloud_sync_historical_snapshot_storage_untrusted');
    }
    final target = File(path.join(folder.path, '$_key.snapshot'));
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.file) {
      throw StateError('cloud_sync_historical_snapshot_storage_untrusted');
    }
    return target;
  }

  Future<String> _protect(String plain) async {
    await _validate();
    if (plain.length > maximumChunkPlaintextBytes ||
        utf8.encode(plain).length > maximumChunkPlaintextBytes) {
      throw StateError('cloud_sync_historical_snapshot_limit');
    }
    final String sealed;
    try {
      sealed = await protector.protect(
        scope: _scope,
        kind: CloudSyncProtectedValueKind.historicalSnapshot,
        plaintext: plain,
      );
    } catch (_) {
      // The platform error must not accidentally expose the captured contents.
      throw StateError('cloud_sync_historical_snapshot_protection_unavailable');
    }
    await _validate();
    if (sealed.isEmpty || sealed.length > _maximumSealedChunkBytes) {
      throw StateError('cloud_sync_historical_snapshot_invalid');
    }
    return sealed;
  }

  Future<String> _unprotect(String sealed, int limit) async {
    await _validate();
    if (sealed.isEmpty || sealed.length > _maximumSealedChunkBytes) {
      throw StateError('cloud_sync_historical_snapshot_invalid');
    }
    final String plain;
    try {
      plain = await protector.unprotect(
        scope: _scope,
        kind: CloudSyncProtectedValueKind.historicalSnapshot,
        ciphertext: sealed,
      );
    } catch (_) {
      throw StateError('cloud_sync_historical_snapshot_unprotect_failed');
    }
    await _validate();
    if (plain.length > limit || utf8.encode(plain).length > limit) {
      throw StateError('cloud_sync_historical_snapshot_limit');
    }
    return plain;
  }

  Future<CloudSyncHistoricalSnapshot?> load() =>
      _exclusive(() async => _read(await _target(create: false)));

  Future<CloudSyncHistoricalSnapshot?> _read(File? target) async {
    if (target == null || !await target.exists()) return null;
    final handle = await target.open(mode: FileMode.read);
    final Uint8List bytes;
    try {
      final length = await handle.length();
      if (length < 1 || length > maximumFileBytes) {
        throw StateError('cloud_sync_historical_snapshot_limit');
      }
      bytes = Uint8List(length);
      var offset = 0;
      while (offset < length) {
        final read = await handle.readInto(bytes, offset);
        if (read == 0) {
          throw StateError('cloud_sync_historical_snapshot_invalid');
        }
        offset += read;
      }
      if (await handle.length() != length) {
        throw StateError('cloud_sync_historical_snapshot_invalid');
      }
    } finally {
      await handle.close();
    }
    final raw = utf8.decode(bytes);
    final envelope = jsonDecode(raw);
    if (envelope is! List ||
        envelope.length != 4 ||
        envelope[0] != _tag ||
        envelope[1] != _key ||
        envelope[2] is! String ||
        envelope[3] is! List ||
        jsonEncode(envelope) != raw) {
      throw StateError('cloud_sync_historical_snapshot_invalid');
    }
    final chunks = envelope[3] as List;
    if (chunks.isEmpty ||
        chunks.length > _maximumChunks ||
        chunks.any((e) => e is! String)) {
      throw StateError('cloud_sync_historical_snapshot_invalid');
    }
    final encodedHeader = await _unprotect(
      envelope[2] as String,
      _maximumMetadataBytes,
    );
    final header = jsonDecode(encodedHeader);
    if (header is! List ||
        header.length != 9 ||
        header[0] != 1 ||
        header[1] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(header[1] as String) ||
        header[2] != account.accountFingerprint ||
        header[3] != account.protectedStoreIdentity ||
        header[4] is! List ||
        (header[4] as List).any((e) => e is! String) ||
        header[5] is! int ||
        (header[5] as int) < 1 ||
        (header[5] as int) > CloudSyncHistoricalSnapshot.maximumRows ||
        header[6] is! int ||
        header[7] is! int ||
        (header[7] as int) < 1 ||
        (header[7] as int) > CloudSyncHistoricalSnapshot.maximumBytes ||
        header[8] != chunks.length ||
        jsonEncode(header) != encodedHeader) {
      throw StateError('cloud_sync_historical_snapshot_invalid');
    }
    final rows = <String>[];
    var contentBytes = 0;
    for (var i = 0; i < chunks.length; i++) {
      final plaintext = await _unprotect(
        chunks[i] as String,
        maximumChunkPlaintextBytes,
      );
      final split = plaintext.indexOf('\n');
      if (split < 1 ||
          plaintext.substring(0, split) != jsonEncode([1, header[1], i])) {
        throw StateError('cloud_sync_historical_snapshot_invalid');
      }
      final page = plaintext.substring(split + 1).split('\n');
      if (page.isEmpty ||
          page.length > _chunkRows ||
          page.any((row) => row.isEmpty)) {
        throw StateError('cloud_sync_historical_snapshot_invalid');
      }
      for (final row in page) {
        contentBytes += utf8.encode(row).length;
        if (rows.length >= CloudSyncHistoricalSnapshot.maximumRows ||
            contentBytes > CloudSyncHistoricalSnapshot.maximumBytes) {
          throw StateError('cloud_sync_historical_snapshot_limit');
        }
        rows.add(row);
      }
    }
    final snapshot = await CloudSyncHistoricalSnapshot.fromEncodedRowsAsync(
      encodedRows: rows,
      account: account,
      accountHandles: List<String>.from(header[4] as List),
      capturedAtMs: header[6] as int,
    );
    await _validate();
    if (snapshot.manifest.snapshotSha256 != header[1] ||
        snapshot.manifest.messageCount != header[5] ||
        snapshot.encodedByteLength != header[7]) {
      throw StateError('cloud_sync_historical_snapshot_invalid');
    }
    return snapshot;
  }

  Future<void> save(
    CloudSyncHistoricalSnapshot snapshot,
  ) => _exclusive(() async {
    if (snapshot.account.accountFingerprint != account.accountFingerprint ||
        snapshot.account.protectedStoreIdentity !=
            account.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_snapshot_binding_invalid');
    }
    final target = (await _target(create: true))!;
    final existing = await _read(target);
    if (existing != null) {
      if (existing.manifest.snapshotSha256 !=
          snapshot.manifest.snapshotSha256) {
        throw StateError('cloud_sync_historical_snapshot_already_present');
      }
      return;
    }
    final chunks = <String>[];
    var page = <String>[];
    var pageBytes = 0;
    Future<void> sealPage() async {
      if (page.isEmpty) return;
      final payload =
          '${jsonEncode([1, snapshot.manifest.snapshotSha256, chunks.length])}\n${page.join('\n')}';
      if (utf8.encode(payload).length > maximumChunkPlaintextBytes ||
          chunks.length >= _maximumChunks) {
        throw StateError('cloud_sync_historical_snapshot_limit');
      }
      chunks.add(await _protect(payload));
      page = [];
      pageBytes = 0;
    }

    for (final row in snapshot.encodedRows) {
      final length = utf8.encode(row).length;
      if (page.length >= _chunkRows ||
          (page.isNotEmpty && pageBytes + length > _chunkTargetBytes)) {
        await sealPage();
      }
      page.add(row);
      pageBytes += length;
    }
    await sealPage();
    final header = await _protect(
      jsonEncode([
        1,
        snapshot.manifest.snapshotSha256,
        account.accountFingerprint,
        account.protectedStoreIdentity,
        snapshot.manifest.accountHandles,
        snapshot.manifest.messageCount,
        snapshot.manifest.capturedAtMs,
        snapshot.encodedByteLength,
        chunks.length,
      ]),
    );
    final encoded = utf8.encode(jsonEncode([_tag, _key, header, chunks]));
    if (encoded.length > maximumFileBytes) {
      throw StateError('cloud_sync_historical_snapshot_limit');
    }
    // Bound crash leftovers and old-account snapshots too. Never prune another
    // snapshot automatically to make room for a replacement.
    var retainedBytes = 0;
    await for (final entry in target.parent.list(followLinks: false)) {
      if (entry is! File) {
        throw StateError('cloud_sync_historical_snapshot_storage_untrusted');
      }
      retainedBytes += await entry.length();
      if (retainedBytes + encoded.length > 2 * maximumFileBytes) {
        throw StateError('cloud_sync_historical_snapshot_storage_limit');
      }
    }
    final random = Random.secure();
    final nonce = List.generate(
      12,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final temporary = File(path.join(target.parent.path, '.$_key.$nonce.tmp'));
    try {
      await temporary.writeAsBytes(encoded, flush: true);
      await _validate();
      // The native exclusion serializes all production writers. Check again
      // after asynchronous protection; publication must never overwrite a file.
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('cloud_sync_historical_snapshot_already_present');
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
}
