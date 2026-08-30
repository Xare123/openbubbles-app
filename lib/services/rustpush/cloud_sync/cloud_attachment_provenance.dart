/// Content-free local marker for attachment rows projected by Cloud Sync V2.
///
/// It contains no account, record, path, or message data. The marker lets the
/// download path avoid CloudKit setup for ordinary IDS attachments.
const String cloudAttachmentV2MetadataKey = 'cloudSyncV2';
const int cloudAttachmentV2MetadataVersion = 2;

bool hasCloudAttachmentV2Provenance(Map<String, dynamic>? metadata) {
  final marker = metadata?[cloudAttachmentV2MetadataKey];
  return marker is int && marker == cloudAttachmentV2MetadataVersion;
}

enum CloudAttachmentDownloadLane {
  cloudSyncV2,
  legacyCloudKit,
  ids,
  unavailable,
}

/// Selects exactly one attachment transport. Exact V2 provenance always wins
/// and can never silently downgrade into a legacy or IDS transport.
CloudAttachmentDownloadLane cloudAttachmentDownloadLaneFor(
  Map<String, dynamic>? metadata,
) {
  if (metadata?.containsKey(cloudAttachmentV2MetadataKey) ?? false) {
    return hasCloudAttachmentV2Provenance(metadata)
        ? CloudAttachmentDownloadLane.cloudSyncV2
        : CloudAttachmentDownloadLane.unavailable;
  }
  if (metadata?.containsKey('cloud') ?? false) {
    return CloudAttachmentDownloadLane.legacyCloudKit;
  }
  if (metadata?.containsKey('rustpush') ?? false) {
    return CloudAttachmentDownloadLane.ids;
  }
  return CloudAttachmentDownloadLane.unavailable;
}

/// V2 downloads share one native writer pause and must enter that critical
/// section serially. Other transports retain the app's normal concurrency.
bool canStartCloudAttachmentDownload({
  required CloudAttachmentDownloadLane candidateLane,
  required bool cloudSyncV2DownloadActive,
}) {
  return !cloudSyncV2DownloadActive ||
      candidateLane != CloudAttachmentDownloadLane.cloudSyncV2;
}

/// The V2 native materializer never streams into or overwrites the final app
/// path. A failure therefore never proves that the caller owns that path.
/// Legacy and IDS transports retain their existing partial-file cleanup.
bool shouldDeleteFailedAttachmentTarget(CloudAttachmentDownloadLane lane) {
  return lane == CloudAttachmentDownloadLane.legacyCloudKit ||
      lane == CloudAttachmentDownloadLane.ids;
}
