import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_safe_failure.dart';

/// Keeps archive capture failures from losing a normally received message.
/// A committed row is returned without another save, preserving its journal
/// for lease recovery. Before commit, ordinary receive may persist only while
/// the same live account/store still owns the callback. This does not silently
/// claim successful archival: the exact safe failure is reported separately.
Future<Message> persistReceivedMessageWithoutLoss({
  required Message message,
  required Future<Message> Function() capture,
  required Message Function() persistOrdinary,
  required Message? Function() findCommitted,
  required bool Function(Message value) isExpectedCommitted,
  required bool Function() sameReceiveIdentity,
  required void Function(String code, bool messageAlreadyPersisted) onDeferred,
}) async {
  if (!sameReceiveIdentity()) {
    throw StateError('cloud_sync_received_archive_identity_changed');
  }
  final previousId = message.id;
  final originalGuid = message.guid;
  try {
    return await capture();
  } catch (error, stack) {
    // Never inspect or persist into a replacement account/store after logout.
    if (!sameReceiveIdentity()) Error.throwWithStackTrace(error, stack);
    final committed = findCommitted();
    if (committed != null) {
      if (committed.id == null ||
          committed.id! <= 0 ||
          committed.guid != originalGuid ||
          !isExpectedCommitted(committed)) {
        throw StateError('cloud_sync_received_archive_source_changed');
      }
      try {
        onDeferred(cloudSyncV2SafeFailureCode(error), true);
      } catch (_) {}
      return committed;
    }
    // A database rollback does not undo the ID assigned to the Dart object.
    message.id = previousId;
    try {
      onDeferred(cloudSyncV2SafeFailureCode(error), false);
    } catch (_) {}
    return persistOrdinary();
  }
}
