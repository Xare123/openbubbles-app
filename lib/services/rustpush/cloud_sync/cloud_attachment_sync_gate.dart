import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:synchronized/synchronized.dart';

/// Both CloudKit attachment transports use the native CloudKit client whose
/// writers are paused by a semantic pull. IDS downloads are independent.
bool cloudAttachmentLaneWaitsForSemanticPull(
  CloudAttachmentDownloadLane lane,
) =>
    lane == CloudAttachmentDownloadLane.cloudSyncV2 ||
    lane == CloudAttachmentDownloadLane.legacyCloudKit;

/// Gives on-demand media a turn between native semantic sessions, including
/// the bounded windows of the retained-record projection sweep.
///
/// This is only in-isolate scheduling. The operation's durable interlock,
/// native writer pause and authentication checks remain authoritative. Never
/// hold this gate for the whole automatic catch-up or acquire it recursively.
final class CloudAttachmentSyncGate {
  final Lock _lock = Lock();

  Future<T> run<T>({
    required void Function() validate,
    required Future<T> Function() action,
  }) => _lock.synchronized(() {
    // An account transition or cancellation may have happened while queued.
    validate();
    return action();
  });

  /// Called after new work is quiesced, before native client disposal.
  /// Timing out this wait must not release an active operation's lock.
  Future<void> drain() => _lock.synchronized(() async {});
}
