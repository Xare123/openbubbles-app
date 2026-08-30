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
  if (hasCloudAttachmentV2Provenance(metadata)) {
    return CloudAttachmentDownloadLane.cloudSyncV2;
  }
  if (metadata?.containsKey('cloud') ?? false) {
    return CloudAttachmentDownloadLane.legacyCloudKit;
  }
  if (metadata?.containsKey('rustpush') ?? false) {
    return CloudAttachmentDownloadLane.ids;
  }
  return CloudAttachmentDownloadLane.unavailable;
}
