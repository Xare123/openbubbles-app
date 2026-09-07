import 'package:bluebubbles/database/models.dart';

final _nativeGuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

/// Retry the original row, not a new event. Queue preparation may replace its
/// temporary display GUID, but the existing native ID must survive in staging.
/// This is only transport bookkeeping, never proof of CloudKit eligibility.
void prepareIMessageReactionRetry(Message message) {
  if (message.sendingServiceId != null) {
    throw StateError('imessage_reaction_send_still_pending');
  }
  if (message.isFromMe != true ||
      message.associatedMessageGuid == null ||
      message.associatedMessageType == null ||
      message.dateDeleted != null ||
      message.ckRecordId != null ||
      message.ckSyncState == true) {
    throw StateError('imessage_reaction_retry_source_invalid');
  }
  final staged = message.stagingGuid;
  if (staged != null && !_nativeGuid.hasMatch(staged)) {
    throw StateError('imessage_reaction_retry_guid_invalid');
  }
  message
    ..stagingGuid =
        staged ??
        (_nativeGuid.hasMatch(message.guid ?? '') ? message.guid : null)
    ..error = 0;
}

/// Keeps the caller's existing reaction row discoverable by native callbacks.
/// Completion here is transport bookkeeping, not CloudKit authorization.
Future<void> submitTrackedIMessageReaction({
  required Message message,
  required String stableGuid,
  required Future<void> Function() persistPending,
  required Future<bool> Function() send,
  required Future<void> Function(bool backgroundPending) persistCompletion,
}) async {
  if (stableGuid.isEmpty) {
    throw ArgumentError('imessage_reaction_send_guid_missing');
  }
  message.stagingGuid = stableGuid;
  // This must finish before send can synchronously emit SendConfirm.
  await persistPending();
  final backgroundPending = await send();
  message
    ..guid = stableGuid
    ..stagingGuid = null;
  if (!backgroundPending) message.error = 0;
  // A native background job's early return is never confirmation of delivery.
  await persistCompletion(backgroundPending);
}
