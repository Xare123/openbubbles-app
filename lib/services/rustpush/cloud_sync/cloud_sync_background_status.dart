/// Presentation-only background sync status for the Profile card.
///
/// The foreground progress object cannot describe independently owned
/// background runs, so the card accepts this optional snapshot. Every field
/// but [active] is optional: the copy renders only what is actually known
/// and never invents a total, percentage, or ETA. Owner and stage are closed
/// enums so raw identifiers can never reach the UI.
library;

enum CloudSyncBackgroundOwner { historyCatchUp }

enum CloudSyncBackgroundStage { checking, downloading, organizing, settling }

class CloudSyncBackgroundStatus {
  const CloudSyncBackgroundStatus({
    required this.active,
    this.owner,
    this.stage,
    this.recordsProcessed,
    this.downloaded,
    this.restored,
    this.lastProgressAt,
  });
  final bool active;
  final CloudSyncBackgroundOwner? owner;
  final CloudSyncBackgroundStage? stage;
  final int? recordsProcessed;
  final int? downloaded;
  final int? restored;
  final DateTime? lastProgressAt;
}

String backgroundStatusHeadline(CloudSyncBackgroundStatus status) {
  final owner = status.owner == CloudSyncBackgroundOwner.historyCatchUp
      ? 'Background history sync'
      : 'Background sync';
  return switch (status.stage) {
    CloudSyncBackgroundStage.checking => '$owner is checking',
    CloudSyncBackgroundStage.downloading => '$owner is downloading',
    CloudSyncBackgroundStage.organizing => '$owner is organizing',
    CloudSyncBackgroundStage.settling => '$owner is settling',
    null => '$owner is active',
  };
}

String? backgroundStatusDetail(CloudSyncBackgroundStatus status) {
  final downloaded = status.downloaded;
  final restored = status.restored;
  if (downloaded != null &&
      downloaded >= 0 &&
      restored != null &&
      restored >= 0) {
    return 'This batch: $downloaded downloaded, $restored restored';
  }
  final records = status.recordsProcessed;
  if (records == null || records < 0) return null;
  return '$records records processed';
}

String? backgroundStatusRecency(
  CloudSyncBackgroundStatus status,
  DateTime now,
) {
  final last = status.lastProgressAt;
  if (last == null || last.isAfter(now)) return null;
  final minutes = now.difference(last).inMinutes;
  if (minutes < 1) return 'Active just now';
  if (minutes < 60) return 'Last activity $minutes min ago';
  return 'Last activity over an hour ago';
}

String? receiptFollowUpCopy({
  required bool backgroundBusy,
  required bool canStartNow,
}) {
  if (backgroundBusy) return 'Background sync is active.';
  if (canStartNow) return 'Sync is idle. You can start or resume.';
  return null;
}
