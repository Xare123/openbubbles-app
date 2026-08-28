/// Web placeholders for the native ObjectBox Cloud Sync V2 entities.
///
/// Cloud Sync V2 is unavailable on web. Keeping these types allows the shared
/// database exports to compile without creating a web persistence path.
const int cloudSyncSchemaVersion = 2;

class CloudSyncCheckpointEntity {}

class CloudInboxChangeEntity {}

class CloudSyncLeaseEntity {}

class CloudProtectedPageLeaseEntity {}

class CloudOutboxOperationEntity {}

class CloudRecordMapEntity {}

class CloudSyncRunEntity {}

class CloudAttachmentMaterializationEntity {}

class CloudSemanticSnapshotEntity {}

class CloudSemanticReplayEntity {}

class CloudKitV2QuarantineRepairReceiptEntity {}

class CloudKitWriterAuthorityEntity {}

class CloudKitDeletionIntentEntity {}

class CloudKitDeletionQuarantineEntity {}
