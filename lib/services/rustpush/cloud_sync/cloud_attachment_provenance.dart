/// Content-free local marker for attachment rows projected by Cloud Sync V2.
///
/// It contains no account, record, path, or message data. The marker lets the
/// download path avoid CloudKit setup for ordinary IDS attachments.
const String cloudAttachmentV2MetadataKey = 'cloudSyncV2';
const int cloudAttachmentV2LegacyMetadataVersion = 2;
// Version 3 was projected while the NO_ASSETS change-page response was
// incorrectly treated as proof that an attachment body was unavailable.
const int cloudAttachmentV2NoAssetsMetadataVersion = 3;
const int cloudAttachmentV2MetadataVersion = 4;
const String cloudAttachmentV2BodyCapabilityKey = 'cloudSyncV2BodyCapability';

enum CloudAttachmentBodyCapability {
  materializable,
  metadataOnlyUnsupportedMediaCredentials,
}

extension CloudAttachmentBodyCapabilityMetadata
    on CloudAttachmentBodyCapability {
  String get metadataValue => switch (this) {
    CloudAttachmentBodyCapability.materializable => 'materializable',
    CloudAttachmentBodyCapability.metadataOnlyUnsupportedMediaCredentials =>
      'metadata_only_unsupported_media_credentials',
  };
}

CloudAttachmentBodyCapability? cloudAttachmentBodyCapabilityFor(
  Map<String, dynamic>? metadata,
) => switch (metadata?[cloudAttachmentV2BodyCapabilityKey]) {
  'materializable' => CloudAttachmentBodyCapability.materializable,
  'metadata_only_unsupported_media_credentials' =>
    CloudAttachmentBodyCapability.metadataOnlyUnsupportedMediaCredentials,
  _ => null,
};

bool hasCloudAttachmentV2Provenance(Map<String, dynamic>? metadata) {
  final marker = metadata?[cloudAttachmentV2MetadataKey];
  return marker is int &&
      (marker == cloudAttachmentV2LegacyMetadataVersion ||
          marker == cloudAttachmentV2NoAssetsMetadataVersion ||
          marker == cloudAttachmentV2MetadataVersion);
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
    final marker = metadata?[cloudAttachmentV2MetadataKey];
    if (marker == cloudAttachmentV2LegacyMetadataVersion) {
      return CloudAttachmentDownloadLane.cloudSyncV2;
    }
    if ((marker == cloudAttachmentV2NoAssetsMetadataVersion ||
            marker == cloudAttachmentV2MetadataVersion) &&
        cloudAttachmentBodyCapabilityFor(metadata) ==
            CloudAttachmentBodyCapability.materializable) {
      return CloudAttachmentDownloadLane.cloudSyncV2;
    }
    return CloudAttachmentDownloadLane.unavailable;
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
