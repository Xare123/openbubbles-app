/// Web placeholders for the native ObjectBox Cloud Sync V2 entities.
///
/// Cloud Sync V2 is unavailable on web. Keeping these types allows the shared
/// database exports to compile without creating a web persistence path.
const int cloudSyncSchemaVersion = 2;
const int cloudInboxServerModifiedAtLegacyAppleEpochFormat = 0;
const int cloudInboxServerModifiedAtUnixEpochFormat = 1;
const int cloudInboxAppleEpochOffsetMillis = 978307200000;

class CloudSyncLocalMutationIntentEntity {}

class CloudSyncLocalSendIntentEntity {}

class CloudSyncCheckpointEntity {}

class CloudInboxChangeEntity {}

int? cloudInboxCanonicalServerModifiedAtMillis(CloudInboxChangeEntity entity) =>
    throw UnsupportedError('Cloud Sync V2 is unavailable on web');

DateTime? cloudInboxCanonicalServerModifiedAt(CloudInboxChangeEntity entity) =>
    throw UnsupportedError('Cloud Sync V2 is unavailable on web');

class CloudSyncLeaseEntity {}

class CloudProtectedPageLeaseEntity {}

class CloudOutboxOperationEntity {}

class CloudRecordMapEntity {}

class CloudSyncRunEntity {}

class CloudAttachmentMaterializationEntity {}

class CloudSemanticSnapshotEntity {}

class CloudSemanticChatAliasEntity {}

class CloudSemanticReplayEntity {}

class CloudKitV2QuarantineRepairReceiptEntity {}

class CloudKitWriterAuthorityEntity {}

class CloudKitDeletionIntentEntity {}

class CloudKitDeletionQuarantineEntity {}

class CloudAttachmentUploadEntity {}

class CloudSyncReceivedArchiveIntentEntity {}
