import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';

/// Both CloudKit attachment transports use the native CloudKit client whose
/// writers are paused by a semantic pull. IDS downloads are independent.
bool cloudAttachmentLaneWaitsForSemanticPull(
  CloudAttachmentDownloadLane lane,
) =>
    lane == CloudAttachmentDownloadLane.cloudSyncV2 ||
    lane == CloudAttachmentDownloadLane.legacyCloudKit;

/// Waits until a semantic CloudKit read has released its native writer pause.
///
/// The semantic result is deliberately ignored here. Its completion, whether
/// successful or failed, is only a coordination signal. The attachment path
/// performs its own source, authentication, and integrity validation afterward.
Future<void> waitForCloudAttachmentSyncGate(
  Future<Object?>? activeSemanticPull,
) async {
  if (activeSemanticPull == null) return;
  try {
    await activeSemanticPull;
  } catch (_) {
    // A failed read still releases the interlock and writer pause in `finally`.
  }
}
