import 'dart:io';

/// Read-only availability hint after exact source/attachment resolution.
/// It does not certify bytes: native staging still verifies the complete file.
/// Only absence is a deferral. Permission, I/O and unsafe-path errors retain
/// attention instead of silently advancing the historical import cursor.
Future<bool> cloudSyncHistoricalAttachmentSourceAvailable(String path) async {
  if (path.isEmpty) return false;
  if (path.contains('\u0000')) {
    throw StateError('cloud_sync_attachment_plan_source_unreadable');
  }
  try {
    final type = await FileSystemEntity.type(path, followLinks: false);
    // Dart also reports notFound when type lookup fails for other reasons.
    // Only an actual open failure with ENOENT is evidence of an absent file.
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw StateError('cloud_sync_attachment_plan_source_unreadable');
    }
    final file = await File(path).open(mode: FileMode.read);
    try {
      if (type != FileSystemEntityType.file) {
        throw StateError('cloud_sync_attachment_plan_source_unreadable');
      }
      await file.read(1);
    } finally {
      await file.close();
    }
    return true;
  } on FileSystemException catch (error) {
    // ENOENT on Android/Linux and file/path-not-found on Windows. A file can
    // disappear after type() without that authorizing loss of existing work.
    if (error.osError?.errorCode == 2 ||
        (Platform.isWindows && error.osError?.errorCode == 3)) {
      return false;
    }
    throw StateError('cloud_sync_attachment_plan_source_unreadable');
  } on ArgumentError {
    throw StateError('cloud_sync_attachment_plan_source_unreadable');
  }
}
