import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_source.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// Fixed failure codes. They never carry paths, digests, labels, or row
/// content; every failure below throws one of these as a [StateError].
const String _invalid = 'cloud_sync_windows_historical_source_invalid';
const String _limit = 'cloud_sync_windows_historical_source_limit';
const String _identityChanged =
    'cloud_sync_windows_historical_source_identity_changed';
const String _unavailable = 'cloud_sync_windows_historical_source_unavailable';
const String _untrusted = 'cloud_sync_windows_historical_source_untrusted';
const String _cleanupFailed =
    'cloud_sync_windows_historical_source_cleanup_failed';

/// Mirrors the [CloudSyncHistoricalImportSource] label rules so caller bugs
/// fail before any evidence is touched; the constructor stays authoritative.
const String _sourceLabelInvalid =
    'cloud_sync_historical_import_source_invalid';

const String _alphaPackage = 'com.bluebubbles.messaging.alpha';
const int _maxMetadataBytes = 64 * 1024;
const String _snapshotDigestPattern = r'^[a-f0-9]{64}$';

/// Acquires an immutable historical snapshot from a separately qualified
/// Alpha database copy without opening or modifying the evidence original.
///
/// The historical import is finite: one bounded capture, not a second
/// continuous engine. Database capture runs in the existing worker isolate;
/// filesystem I/O is asynchronous. The source is an already qualified offline
/// copy, not the live Alpha installation. The caller must establish that its
/// history belongs to the explicitly selected destination account.
/// The capture-qualification proof authenticates a stable capture only,
/// never account ownership; explicit destination consent stays parent-owned.
/// The evidence source is preserved on every failure path; only the
/// generated scratch subdirectory is ever removed.
Future<CloudSyncHistoricalImportSource>
captureCloudSyncWindowsHistoricalSource({
  required Directory sourceDirectory,
  required Directory scratchRoot,
  required String expectedDatabaseSha256,
  required CloudSyncHistoricalAccountBinding account,
  required List<String> accountHandles,
  required String label,
  required int capturedAtMs,
  required Future<void> Function() validateIdentity,
  required bool Function() stillCurrent,
}) async {
  if (!RegExp(_snapshotDigestPattern).hasMatch(expectedDatabaseSha256)) {
    throw StateError(_invalid);
  }
  if (label.trim().isEmpty ||
      label.length > 120 ||
      label.contains(RegExp(r'[\r\n\x00]'))) {
    throw StateError(_sourceLabelInvalid);
  }
  if (!account.hasValidShape) throw StateError(_invalid);
  Future<void> checkIdentity() async {
    try {
      if (!stillCurrent()) throw StateError(_identityChanged);
      await validateIdentity();
      if (!stillCurrent()) throw StateError(_identityChanged);
    } catch (_) {
      throw StateError(_identityChanged);
    }
  }

  await checkIdentity();
  final canonicalSource = await _verifiedDirectory(sourceDirectory);
  final original = File(path.join(canonicalSource, 'data.mdb'));
  final proofFile = File(
    path.join(canonicalSource, 'capture-qualification.json'),
  );
  await _verifiedFile(original);
  await _verifiedFile(proofFile);
  final databaseLength = await _io(() => original.length());
  await _checkQualification(
    proofFile: proofFile,
    databaseLength: databaseLength,
    expectedDatabaseSha256: expectedDatabaseSha256,
  );
  final actualDigest = await _fileSha256(original);
  if (actualDigest != expectedDatabaseSha256) throw StateError(_invalid);
  final canonicalScratch = await _verifiedDirectory(scratchRoot);
  if (path.equals(canonicalScratch, canonicalSource) ||
      path.isWithin(canonicalSource, canonicalScratch)) {
    throw StateError(_untrusted);
  }
  Directory? generated;
  Store? working;
  CloudSyncHistoricalSnapshot? snapshot;
  StateError? failure;
  var cleanupFailed = false;
  try {
    final created = await _io(
      () => Directory(canonicalScratch).createTemp('alpha-historical-source-'),
    );
    generated = created;
    final canonicalGenerated = await _verifiedDirectory(created);
    if (!path.isWithin(canonicalScratch, canonicalGenerated) ||
        path.isWithin(canonicalSource, canonicalGenerated)) {
      throw StateError(_untrusted);
    }
    final workingCopy = File(path.join(canonicalGenerated, 'data.mdb'));
    await _io(() => original.copy(workingCopy.path));
    if (await _fileSha256(workingCopy) != expectedDatabaseSha256) {
      throw StateError(_invalid);
    }
    // A revoked session must not even open the copied database.
    await checkIdentity();
    working = await _openWorkingCopy(canonicalGenerated);
    snapshot = await CloudSyncHistoricalSnapshot.captureAsync(
      store: working,
      account: account,
      accountHandles: accountHandles,
      capturedAtMs: capturedAtMs,
      validateSource: checkIdentity,
      stillCurrent: stillCurrent,
    );
  } catch (error) {
    failure = _safeCaptureFailure(error);
  } finally {
    var closed = working == null;
    try {
      working?.close();
      closed = true;
    } catch (_) {
      cleanupFailed = true;
    }
    try {
      if (await _fileSha256(original) != expectedDatabaseSha256) {
        failure = StateError(_invalid);
      }
    } catch (error) {
      failure ??= _safeCaptureFailure(error);
    }
    if (generated != null && closed) {
      try {
        await _removeExclusiveTemp(
          canonicalScratch,
          path.normalize(generated.path),
        );
      } catch (_) {
        cleanupFailed = true;
      }
    }
  }
  // Never hide a leftover private copy behind a different primary error.
  // A failed Store close intentionally preserves its directory for recovery.
  if (cleanupFailed) throw StateError(_cleanupFailed);
  if (failure != null) throw failure;
  await checkIdentity();
  return CloudSyncHistoricalImportSource(snapshot: snapshot!, label: label);
}

StateError _safeCaptureFailure(Object error) {
  if (error is StateError) {
    if ({
      _invalid,
      _limit,
      _identityChanged,
      _unavailable,
      _untrusted,
      _cleanupFailed,
      _sourceLabelInvalid,
    }.contains(error.message)) {
      return error;
    }
    if (error.message == 'cloud_sync_historical_snapshot_limit') {
      return StateError(_limit);
    }
    if (error.message == 'cloud_sync_historical_snapshot_identity_changed') {
      return StateError(_identityChanged);
    }
  }
  return StateError(_unavailable);
}

/// Filesystem calls surface as unavailable; [StateError] codes pass through.
Future<T> _io<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on FileSystemException {
    throw StateError(_unavailable);
  }
}

Future<String> _verifiedDirectory(Directory directory) async {
  if (!path.isAbsolute(directory.path)) throw StateError(_untrusted);
  final kind = await _io(
    () => FileSystemEntity.type(directory.path, followLinks: false),
  );
  if (kind == FileSystemEntityType.notFound) throw StateError(_unavailable);
  if (kind != FileSystemEntityType.directory) throw StateError(_untrusted);
  final canonical = path.normalize(directory.path);
  final resolved = path.normalize(
    await _io(() => directory.resolveSymbolicLinks()),
  );
  if (!path.equals(resolved, canonical)) throw StateError(_untrusted);
  return canonical;
}

Future<void> _verifiedFile(File file) async {
  final kind = await _io(
    () => FileSystemEntity.type(file.path, followLinks: false),
  );
  if (kind == FileSystemEntityType.notFound) throw StateError(_unavailable);
  if (kind != FileSystemEntityType.file) throw StateError(_untrusted);
  final canonical = path.normalize(file.path);
  final resolved = path.normalize(await _io(() => file.resolveSymbolicLinks()));
  if (!path.equals(resolved, canonical)) throw StateError(_untrusted);
}

Future<void> _checkQualification({
  required File proofFile,
  required int databaseLength,
  required String expectedDatabaseSha256,
}) async {
  if (await _io(() => proofFile.length()) > _maxMetadataBytes) {
    throw StateError(_limit);
  }
  final dynamic proof;
  try {
    final bytes = await _io(
      () => proofFile
          .openRead(0, _maxMetadataBytes + 1)
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b)),
    );
    if (bytes.length > _maxMetadataBytes) throw StateError(_limit);
    proof = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw StateError(_invalid);
  }
  if (proof is! Map<String, dynamic> ||
      proof['stable'] != true ||
      proof['package'] != _alphaPackage ||
      proof['bytes'] != databaseLength ||
      proof['databaseSha256'] != expectedDatabaseSha256 ||
      proof['remoteBeforeSha256'] != expectedDatabaseSha256 ||
      proof['remoteAfterSha256'] != expectedDatabaseSha256) {
    throw StateError(_invalid);
  }
}

Future<String> _fileSha256(File file) async {
  final digest = await _io(() => sha256.bind(file.openRead()).first);
  return digest.toString();
}

Future<Store> _openWorkingCopy(String directory) async {
  try {
    return await openStore(directory: directory);
  } catch (_) {
    throw StateError(_unavailable);
  }
}

/// Removes only the generated subdirectory, never the shared scratch
/// root, the evidence source, or anything outside the scratch root.
Future<void> _removeExclusiveTemp(
  String canonicalScratch,
  String canonicalGenerated,
) async {
  if (path.equals(canonicalGenerated, canonicalScratch) ||
      !path.isWithin(canonicalScratch, canonicalGenerated)) {
    throw StateError(_cleanupFailed);
  }
  try {
    await _verifiedDirectory(Directory(canonicalScratch));
    await _verifiedDirectory(Directory(canonicalGenerated));
    await Directory(canonicalGenerated).delete(recursive: true);
  } catch (_) {
    throw StateError(_cleanupFailed);
  }
}
