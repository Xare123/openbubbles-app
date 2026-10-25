import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'backend_harness_protocol.dart';

/// Correlation only. A claim consumes a fixture before any backend effect; it
/// never grants send/retry, archive, queue, permit or receipt authority.
final class BackendHarnessFixtureClaim {
  const BackendHarnessFixtureClaim._(
    this.header,
    this.messageGuid,
    this.partialResult,
  );
  final String header;
  final String? messageGuid;
  final bool partialResult;
  Map<String, dynamic> get _value => jsonDecode(header) as Map<String, dynamic>;
  String get fixtureId => _value['fixtureId'] as String;
  String get owner => _value['owner'] as String;
  String get accountFingerprint => _value['account'] as String;
  String get protectedStoreIdentity => _value['store'] as String;
}

/// The root comes only from the app's private native storage directory. There
/// are no caller paths, repair, migration, overwrite, deletion or replay APIs.
final class BackendHarnessFixtureClaims {
  BackendHarnessFixtureClaims({
    required String storageDirectory,
    required this.source,
    required this.auth,
  }) : _root = p.normalize(storageDirectory) {
    if (!p.isAbsolute(_root) || !RegExp(r'^[a-f0-9]{40}$').hasMatch(source)) {
      _reject();
    }
    _plainDirectory(_root);
  }

  final String _root;
  final String source;
  final CloudSyncNativeAuthSnapshot auth;
  static const _maximumBytes = 4096;

  String? _directory({bool create = false}) {
    _plainDirectory(_root);
    var current = _root;
    for (final part in ['cloud-sync-v2', 'backend-fixtures']) {
      current = p.join(current, part);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.notFound) {
        if (!create) return null;
        Directory(current).createSync();
      }
      _plainDirectory(current);
    }
    return current;
  }

  File? _file(String id, {bool createDirectory = false}) {
    if (!BackendHarnessFixtureReceipt.uuid.hasMatch(id)) _reject();
    final directory = _directory(create: createDirectory);
    return directory == null
        ? null
        : File(p.join(directory, '${id.toUpperCase()}.jsonl'));
  }

  BackendHarnessFixtureClaim consume(String id, {required String owner}) {
    if (!BackendHarnessFixtureReceipt.uuid.hasMatch(owner)) _reject();
    final file = _file(id, createDirectory: true)!;
    // CreateNew is the one-use decision. Even an empty/partial header after a
    // disk/process failure remains consumed and is never removed or repaired.
    try {
      file.createSync(exclusive: true);
    } on FileSystemException {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw BackendHarnessFailure('backend_request_reused');
      }
      rethrow;
    }
    final header = jsonEncode({
      'version': 1,
      'fixtureId': id.toUpperCase(),
      'source': source,
      'owner': owner,
      'account': auth.accountFingerprint,
      'store': auth.protectedStoreIdentity,
    });
    _plainFile(file);
    final handle = file.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
      if (handle.lengthSync() != 0) _reject();
      handle.writeStringSync('$header\n');
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    _plainFile(file);
    return BackendHarnessFixtureClaim._(header, null, false);
  }

  BackendHarnessFixtureClaim? read(String id, {String? owner}) {
    final file = _file(id);
    if (file == null ||
        FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
      return null;
    }
    _plainFile(file);
    final handle = file.openSync();
    try {
      handle.lockSync(FileLock.shared);
      return _decode(_read(handle), id, owner);
    } finally {
      handle.closeSync();
    }
  }

  /// Append a bounded actual result once. An interrupted append stays consumed;
  /// observation may recover through exact marker + native-journal evidence.
  void commit(BackendHarnessFixtureClaim claim, String messageGuid) {
    if (!BackendHarnessFixtureReceipt.uuid.hasMatch(messageGuid)) _reject();
    final file = _file(claim.fixtureId)!;
    _plainFile(file);
    final handle = file.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
      final before = _read(handle);
      final current = _decode(before, claim.fixtureId, claim.owner);
      if (current.header != claim.header || before != '${claim.header}\n') {
        _reject();
      }
      final result = jsonEncode({
        'messageGuid': messageGuid,
        'claimSha256': sha256.convert(utf8.encode(claim.header)).toString(),
      });
      handle.setPositionSync(handle.lengthSync());
      handle.writeStringSync('$result\n');
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    _plainFile(file);
  }

  String _read(RandomAccessFile file) {
    final length = file.lengthSync();
    if (length > _maximumBytes) _reject();
    file.setPositionSync(0);
    try {
      // A torn result can include an incomplete UTF-8 sequence. It is still
      // consumed; only the complete ASCII header may establish its binding.
      return utf8.decode(file.readSync(length), allowMalformed: true);
    } on FormatException {
      return _reject();
    }
  }

  BackendHarnessFixtureClaim _decode(String text, String id, String? owner) {
    final end = text.indexOf('\n');
    if (end < 0) _reject();
    final header = text.substring(0, end);
    try {
      final value = jsonDecode(header);
      if (value is! Map ||
          value.length != 6 ||
          value['version'] != 1 ||
          value['fixtureId'] != id.toUpperCase() ||
          value['source'] != source ||
          value['account'] != auth.accountFingerprint ||
          value['store'] != auth.protectedStoreIdentity ||
          value['owner'] is! String ||
          !BackendHarnessFixtureReceipt.uuid.hasMatch(
            value['owner'] as String,
          ) ||
          (owner != null && value['owner'] != owner)) {
        _reject();
      }
      final tail = text.substring(end + 1);
      if (tail.isEmpty) {
        return BackendHarnessFixtureClaim._(header, null, false);
      }
      if (tail.endsWith('\n') && tail.indexOf('\n') == tail.length - 1) {
        try {
          final result = jsonDecode(tail);
          if (result is Map &&
              result.length == 2 &&
              result['messageGuid'] is String &&
              BackendHarnessFixtureReceipt.uuid.hasMatch(
                result['messageGuid'] as String,
              ) &&
              result['claimSha256'] ==
                  sha256.convert(utf8.encode(header)).toString()) {
            return BackendHarnessFixtureClaim._(
              header,
              result['messageGuid'] as String,
              false,
            );
          }
        } on FormatException {
          /* Retain the consumed partial result. */
        }
      }
      return BackendHarnessFixtureClaim._(header, null, true);
    } on FormatException {
      return _reject();
    }
  }

  static void _plainDirectory(String value) {
    if (FileSystemEntity.typeSync(value, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.equals(
          p.normalize(Directory(value).resolveSymbolicLinksSync()),
          p.normalize(value),
        )) {
      _reject();
    }
  }

  void _plainFile(File file) {
    _directory();
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.equals(
          p.normalize(file.resolveSymbolicLinksSync()),
          p.normalize(file.path),
        )) {
      _reject();
    }
  }

  static Never _reject() => throw BackendHarnessFailure('backend_not_ready');
}
