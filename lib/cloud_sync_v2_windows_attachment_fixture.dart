import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// Deterministic synthetic fixtures for Windows attachment-write
/// qualification. No user files, no native calls, no network.
///
/// Existence policy: both materialize methods require [profile] to already
/// exist as a real directory, never a symlink or junction, and never
/// create the profile itself. They create only the private scope below
/// it. A missing profile throws StateError; intermediate directories
/// are created as needed.
final class CloudSyncWindowsAttachmentFixture {
  CloudSyncWindowsAttachmentFixture._({
    required this.id,
    required this.filename,
    required this.mimeType,
    required this.uti,
    required Uint8List bytes,
  }) : bytes = bytes.asUnmodifiableView(),
       sha256Hex = sha256.convert(bytes).toString();

  /// Returns the fixture for exactly 'text-v1' or 'png-v1'.
  ///
  /// Any other id throws StateError.
  factory CloudSyncWindowsAttachmentFixture.fromId(String id) {
    switch (id) {
      case 'text-v1':
        return CloudSyncWindowsAttachmentFixture._(
          id: id,
          filename: 'qualification.txt',
          mimeType: 'text/plain',
          uti: 'public.plain-text',
          bytes: Uint8List.fromList(
            utf8.encode('OpenBubbles CloudKit attachment qualification\n'),
          ),
        );
      case 'png-v1':
        return CloudSyncWindowsAttachmentFixture._(
          id: id,
          filename: 'qualification.png',
          mimeType: 'image/png',
          uti: 'public.png',
          // 1x1 PNG, embedded so the fixture needs no files.
          bytes: Uint8List.fromList(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
            ),
          ),
        );
      default:
        throw StateError(
          'cloud_sync_windows_attachment_fixture_unknown',
        );
    }
  }

  final String id;
  final String filename;
  final String mimeType;
  final String uti;

  /// Immutable fixture bytes.
  final Uint8List bytes;

  /// Lowercase hex SHA-256 of bytes.
  final String sha256Hex;

  /// Writes the fixture to its private IDS-upload path under [profile]:
  /// <profile>/cloud-sync-v2/windows-write-fixtures/<requestId>/<filename>
  /// where requestId must match ^[a-z0-9-]{1,64}$ (lowercase alnum plus
  /// hyphen). Anything else throws StateError.
  ///
  /// Never overwrites: byte-identical existing files are reused; drift or
  /// foreign content throws StateError and is left untouched.
  Future<File> materialize(Directory profile, String requestId) async {
    if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(requestId)) {
      throw StateError('cloud_sync_windows_write_request_invalid');
    }
    return _materializeToFile(
      profile,
      Directory(
        path.join(
          profile.path,
          'cloud-sync-v2',
          'windows-write-fixtures',
          requestId,
        ),
      ),
    );
  }

  /// Copies only this fixture's deterministic built-in bytes (never
  /// arbitrary files) to the canonical production read path:
  /// <profile>/attachments/<attachmentGuid>/<filename>.
  ///
  /// attachmentGuid must be a UUID v4 with an optional _0
  /// single-attachment suffix (callers pass wire.id plus '_0'). Anything
  /// else throws StateError. Same exact-byte checks and segment/symlink
  /// protections as materialize. Main flow: materialize(requestId) for IDS
  /// upload first, then materializeForAttachment before journal commit.
  Future<File> materializeForAttachment(
    Directory profile,
    String attachmentGuid,
  ) async {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}(_0)?$',
    ).hasMatch(attachmentGuid)) {
      throw StateError('cloud_sync_windows_attachment_guid_invalid');
    }
    return _materializeToFile(
      profile,
      Directory(path.join(profile.path, 'attachments', attachmentGuid)),
    );
  }

  /// Shared writer behind both public entry points. Creates [dir], rejects
  /// a profile that is itself a link, rejects link escape on every segment
  /// below it, writes exclusively, reuses only byte-identical files, and
  /// verifies bytes plus digest after writing.
  Future<File> _materializeToFile(Directory profile, Directory dir) async {
    if (!profile.existsSync()) {
      throw StateError(
        'cloud_sync_windows_attachment_fixture_profile_missing',
      );
    }
    if (FileSystemEntity.isLinkSync(profile.path)) {
      throw StateError(
        'cloud_sync_windows_attachment_fixture_escape',
      );
    }
    final file = File(path.join(dir.path, filename));
    await _rejectLinksOnSegments(profile.path, file.path);
    await dir.create(recursive: true);
    await _rejectLinksOnSegments(profile.path, file.path);
    final root = await profile.resolveSymbolicLinks();
    final resolvedDir = await dir.resolveSymbolicLinks();
    if (resolvedDir != root && !path.isWithin(root, resolvedDir)) {
      throw StateError(
        'cloud_sync_windows_attachment_fixture_escape',
      );
    }
    if (FileSystemEntity.isLinkSync(file.path)) {
      throw StateError(
        'cloud_sync_windows_attachment_fixture_escape',
      );
    }
    var created = false;
    try {
      await file.create(exclusive: true);
      created = true;
    } on FileSystemException {
      // Already exists: fall through to the identical-reuse check below,
      // which never overwrites.
    }
    if (!created) {
      final resolvedFile = await file.resolveSymbolicLinks();
      if (resolvedFile != path.join(resolvedDir, filename) &&
          !path.isWithin(resolvedDir, resolvedFile)) {
        throw StateError(
          'cloud_sync_windows_attachment_fixture_escape',
        );
      }
      // Length first, so a huge foreign file is never loaded into memory.
      // Mismatches keep the existing file unchanged.
      if (await file.length() != bytes.length) {
        throw StateError(
          'cloud_sync_windows_attachment_fixture_exists',
        );
      }
      final current = await file.readAsBytes();
      if (_bytesEqual(current, bytes)) {
        return file;
      }
      throw StateError(
        'cloud_sync_windows_attachment_fixture_exists',
      );
    }
    await file.writeAsBytes(bytes, flush: true);
    final written = await file.readAsBytes();
    if (!_bytesEqual(written, bytes) ||
        sha256.convert(written).toString() != sha256Hex) {
      throw StateError(
        'cloud_sync_windows_attachment_fixture_verify_failed',
      );
    }
    return file;
  }

  /// Throws StateError if any existing lexical segment from [rootPath] to
  /// [targetPath] (inclusive of intermediate dirs and the target itself) is
  /// a link. Missing segments are skipped; they are re-checked after
  /// creation by the caller. The profile root itself is checked
  /// separately by the caller, since it must already exist.
  Future<void> _rejectLinksOnSegments(
    String rootPath,
    String targetPath,
  ) async {
    final rootParts = path.split(path.normalize(rootPath));
    final targetParts = path.split(path.normalize(targetPath));
    if (targetParts.length < rootParts.length) {
      throw StateError(
        'cloud_sync_windows_attachment_fixture_escape',
      );
    }
    for (var i = 0; i < rootParts.length; i++) {
      if (targetParts[i] != rootParts[i]) {
        throw StateError(
          'cloud_sync_windows_attachment_fixture_escape',
        );
      }
    }
    var current = path.joinAll(rootParts);
    for (var i = rootParts.length; i < targetParts.length; i++) {
      current = path.join(current, targetParts[i]);
      final isLast = i == targetParts.length - 1;
      // Only the file itself may be absent; intermediate dirs that are
      // absent are created by the caller and re-checked afterwards.
      if (!isLast ||
          FileSystemEntity.typeSync(current) !=
              FileSystemEntityType.notFound) {
        if (FileSystemEntity.isLinkSync(current)) {
          throw StateError(
            'cloud_sync_windows_attachment_fixture_escape',
          );
        }
      }
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
