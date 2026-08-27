import 'package:objectbox/objectbox.dart';

/// Durable, account-scoped Cloud Sync V2 state.
///
/// These records intentionally contain only hashes, typed metadata, or
/// application-encrypted references. Apple account identifiers, record IDs,
/// continuation tokens, message bodies, handles, and keys must never be
/// written to ObjectBox in plaintext.
const int cloudSyncSchemaVersion = 2;

@Entity()
class CloudSyncCheckpointEntity {
  int id;

  /// SHA-256 over account fingerprint, container, database, zone, stream and
  /// schema. Every related record carries the same key to prevent cross-scope
  /// reads when Apple reuses a zone name.
  @Index(type: IndexType.hash64)
  @Unique()
  String checkpointKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  String container;
  String database;

  @Index(type: IndexType.hash64)
  String zone;

  String streamKind;
  int schemaVersion;

  /// Local persistence lane only. Null identifies pre-lane legacy rows.
  String? persistenceLane;

  /// Base64 application ciphertext. Never a raw CloudKit continuation token.
  String? fetchedTokenCiphertext;

  /// Protected continuation token for the most recently journaled page.
  /// This is promoted only after every row in [pendingBatchId] is terminal.
  String? pendingFetchedTokenCiphertext;
  String? pendingBatchId;
  int generation;
  String? lastBatchId;
  int fetchedSequence;

  /// Highest contiguous terminal inbox sequence. The historical field name is
  /// retained for schema compatibility; both applied and quarantined rows are
  /// terminal and advance this floor.
  int appliedSequence;
  int lastSuccessfulAtMs;
  int lastAttemptAtMs;
  String? lastErrorCategory;
  int backoffAttempt;
  int nextEligibleAtMs;
  int mutationRevisionCounter;
  int updatedAtMs;

  CloudSyncCheckpointEntity({
    this.id = 0,
    required this.checkpointKey,
    required this.accountFingerprint,
    required this.container,
    required this.database,
    required this.zone,
    required this.streamKind,
    this.schemaVersion = cloudSyncSchemaVersion,
    this.persistenceLane,
    this.fetchedTokenCiphertext,
    this.pendingFetchedTokenCiphertext,
    this.pendingBatchId,
    this.generation = 1,
    this.lastBatchId,
    this.fetchedSequence = 0,
    this.appliedSequence = 0,
    this.lastSuccessfulAtMs = 0,
    this.lastAttemptAtMs = 0,
    this.lastErrorCategory,
    this.backoffAttempt = 0,
    this.nextEligibleAtMs = 0,
    this.mutationRevisionCounter = 0,
    required this.updatedAtMs,
  });
}

@Entity()
class CloudInboxChangeEntity {
  int id;

  /// SHA-256 over account, zone, record hash, etag hash and change type.
  @Index(type: IndexType.hash64)
  @Unique()
  String changeKey;

  /// Original account-keyed native change identifier. Unlike [changeKey],
  /// this value is preserved exactly for semantic decoder and replay binding.
  String changeIdHash;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  @Index(type: IndexType.hash64)
  String zone;

  /// Redacted identifiers used for equality and diagnostics.
  @Index(type: IndexType.hash64)
  String serverRecordIdHash;

  String? etagHash;
  String changeType;

  /// Protected raw identifiers/system fields needed to replay tombstones and
  /// preserve unknown CloudKit metadata. Hashes remain the query keys.
  String? encryptedServerRecordId;
  String? protectedSystemFieldsRef;

  /// Original PCS ciphertext, or a protected local reference to it.
  String? encryptedPayloadRef;
  String? payloadSha256;

  @Index(type: IndexType.hash64)
  String batchId;

  int generation;

  @Index()
  int fetchSequence;

  /// 0 pending, 1 applied, 2 quarantined.
  @Index()
  int status;

  bool isTombstone;

  /// Immutable ingestion classification, distinct from mutable retry state.
  String? preflightCategory;
  String? failureCategory;

  /// Fixed, content-free native preflight code. Never stores server text.
  String? preflightCode;
  int retryCount;
  int nextEligibleAtMs;
  int serverModifiedAtMs;
  int createdAtMs;
  int updatedAtMs;
  int completedAtMs;

  CloudInboxChangeEntity({
    this.id = 0,
    required this.changeKey,
    required this.changeIdHash,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.zone,
    required this.serverRecordIdHash,
    this.etagHash,
    required this.changeType,
    this.encryptedServerRecordId,
    this.protectedSystemFieldsRef,
    this.encryptedPayloadRef,
    this.payloadSha256,
    required this.batchId,
    this.generation = 1,
    required this.fetchSequence,
    this.status = 0,
    this.isTombstone = false,
    this.preflightCategory,
    this.failureCategory,
    this.preflightCode,
    this.retryCount = 0,
    this.nextEligibleAtMs = 0,
    this.serverModifiedAtMs = 0,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.completedAtMs = 0,
  });
}

@Entity()
class CloudSyncLeaseEntity {
  int id;

  /// SHA-256 over account, container and database.
  @Index(type: IndexType.hash64)
  @Unique()
  String leaseKey;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  /// Random per-process owner value, stored as a hash.
  String ownerIdHash;
  int generation;
  int acquiredAtMs;

  @Index()
  int expiresAtMs;

  CloudSyncLeaseEntity({
    this.id = 0,
    required this.leaseKey,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.ownerIdHash,
    required this.generation,
    required this.acquiredAtMs,
    required this.expiresAtMs,
  });
}

/// Durable adoption marker for a native protected-page lease.
///
/// The marker is inserted in the same ObjectBox transaction as the fetched
/// inbox rows and checkpoint. Native crash recovery preserves protected blobs
/// only while this marker exists. The lease reference is an opaque,
/// content-free `obcs2.lease.*` token, never a CloudKit identifier.
@Entity()
class CloudProtectedPageLeaseEntity {
  int id;

  @Index(type: IndexType.hash64)
  @Unique()
  String leaseReference;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  int generation;
  String batchIdHash;
  int adoptedAtMs;
  int finalizeAttemptCount;
  int nextFinalizeEligibleAtMs;

  CloudProtectedPageLeaseEntity({
    this.id = 0,
    required this.leaseReference,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.generation,
    required this.batchIdHash,
    required this.adoptedAtMs,
    this.finalizeAttemptCount = 0,
    this.nextFinalizeEligibleAtMs = 0,
  });
}

@Entity()
class CloudOutboxOperationEntity {
  int id;

  /// Stable SHA-256 operation identity used for idempotency and coalescing.
  @Index(type: IndexType.hash64)
  @Unique()
  String operationId;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  @Index(type: IndexType.hash64)
  String zone;

  @Index(type: IndexType.hash64)
  String logicalEntityKeyHash;

  /// 0 save, 1 delete. Deletes remain feature-gated.
  int action;

  /// JSON list containing only hashed operation IDs.
  String dependencyOperationIdsJson;
  int payloadVersion;
  int mutationRevision;

  /// Checkpoint generation which admitted this row. Existing rows from before
  /// this property deserialize as zero and are fail-closed by the store.
  int checkpointGeneration;

  /// Persisted Apple HTTP request identity shared by one submitted batch.
  String? appleRequestUuid;

  /// Persisted Apple operation identity unique within the submitted batch.
  String? appleOperationUuid;

  /// Protected local reference or application ciphertext, never message text.
  String? encryptedPayloadRef;
  String? payloadSha256;

  /// Native protected lease adopted by this non-terminal outbound operation.
  ///
  /// This is distinct from CloudProtectedPageLeaseEntity. It is nullable so
  /// rows written before the schema migration remain readable.
  String? protectedLeaseReference;

  /// 0 pending, 1 in-flight, 2 confirmed, 3 paused, 4 quarantined,
  /// 5 unknown outcome. These values are stable persisted state codes.
  @Index()
  int state;

  int attemptCount;

  @Index()
  int nextEligibleAtMs;

  String? lastErrorCategory;
  String? serverRecordIdHash;
  String? leaseIdHash;
  int leaseExpiresAtMs;
  int confirmedAtMs;
  int createdAtMs;
  int updatedAtMs;

  CloudOutboxOperationEntity({
    this.id = 0,
    required this.operationId,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.zone,
    required this.logicalEntityKeyHash,
    required this.action,
    this.dependencyOperationIdsJson = '[]',
    this.payloadVersion = 1,
    required this.mutationRevision,
    this.checkpointGeneration = 0,
    this.appleRequestUuid,
    this.appleOperationUuid,
    this.encryptedPayloadRef,
    this.payloadSha256,
    this.protectedLeaseReference,
    this.state = 0,
    this.attemptCount = 0,
    this.nextEligibleAtMs = 0,
    this.lastErrorCategory,
    this.serverRecordIdHash,
    this.leaseIdHash,
    this.leaseExpiresAtMs = 0,
    this.confirmedAtMs = 0,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

@Entity()
class CloudRecordMapEntity {
  int id;

  /// SHA-256 over account, zone and logical entity key.
  @Index(type: IndexType.hash64)
  @Unique()
  String mapKey;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  @Index(type: IndexType.hash64)
  String zone;

  @Index(type: IndexType.hash64)
  String logicalEntityKeyHash;

  @Index(type: IndexType.hash64)
  String serverRecordIdHash;

  /// Checkpoint generation that proved this server identity.
  /// Existing rows deserialize as zero and are ignored until reproven.
  int generation;

  /// Application-encrypted Apple record ID and last-known raw record reference.
  String encryptedServerRecordId;
  String? etagHash;
  String? encryptedRawRecordRef;
  int updatedAtMs;

  CloudRecordMapEntity({
    this.id = 0,
    required this.mapKey,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.zone,
    required this.logicalEntityKeyHash,
    required this.serverRecordIdHash,
    this.generation = 0,
    required this.encryptedServerRecordId,
    this.etagHash,
    this.encryptedRawRecordRef,
    required this.updatedAtMs,
  });
}

@Entity()
class CloudSyncRunEntity {
  int id;

  @Index(type: IndexType.hash64)
  @Unique()
  String runId;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  String trigger;
  String architecture;
  String mode;
  int fetchedCount;
  int appliedCount;
  int deferredCount;
  int quarantinedCount;
  int confirmedCount;
  int retriedCount;
  int startedAtMs;
  int finishedAtMs;
  String? failureCategory;

  CloudSyncRunEntity({
    this.id = 0,
    required this.runId,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.trigger,
    required this.architecture,
    required this.mode,
    this.fetchedCount = 0,
    this.appliedCount = 0,
    this.deferredCount = 0,
    this.quarantinedCount = 0,
    this.confirmedCount = 0,
    this.retriedCount = 0,
    required this.startedAtMs,
    this.finishedAtMs = 0,
    this.failureCategory,
  });
}

@Entity()
class CloudAttachmentMaterializationEntity {
  int id;

  /// SHA-256 over the complete account scope and native-keyed logical entity
  /// identity. It is an equality key, never an Apple record identifier.
  @Index(type: IndexType.hash64)
  @Unique()
  String transferKey;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  @Index(type: IndexType.hash64)
  String zone;

  int generation;

  @Index(type: IndexType.hash64)
  String logicalEntityKeyHash;

  int expectedBytes;
  String expectedIntegrityTagHash;

  /// See CloudAttachmentMaterializationStage. Stored as a monotonic ordinal.
  @Index()
  int stage;

  int verifiedBytes;

  /// Application-protected references only. Raw paths, MMCS credentials, and
  /// signatures must never be placed in these fields.
  String? protectedTempReference;
  String? protectedResumeManifestReference;
  String? protectedContentVerificationReference;
  String? protectedFinalReference;
  int updatedAtMs;

  CloudAttachmentMaterializationEntity({
    this.id = 0,
    required this.transferKey,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.zone,
    required this.generation,
    required this.logicalEntityKeyHash,
    required this.expectedBytes,
    required this.expectedIntegrityTagHash,
    required this.stage,
    required this.verifiedBytes,
    this.protectedTempReference,
    this.protectedResumeManifestReference,
    this.protectedContentVerificationReference,
    this.protectedFinalReference,
    required this.updatedAtMs,
  });
}

/// Content-free merge metadata for one canonical semantic entity.
///
/// Every identifier is already a one-way digest. Message bodies, handles,
/// filenames, raw Apple identifiers, credentials, and local paths are not
/// valid fields on this entity.
@Entity()
class CloudSemanticSnapshotEntity {
  int id;

  /// Composite of the scope-generation digest, entity kind, and logical key
  /// hash. It contains no raw account or entity identifier.
  @Index(type: IndexType.hash64)
  @Unique()
  String snapshotKey;

  @Index(type: IndexType.hash64)
  String scopeGenerationKey;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  String container;
  String database;

  @Index(type: IndexType.hash64)
  String zone;

  String streamKind;
  int schemaVersion;
  int generation;
  String entityKind;

  @Index(type: IndexType.hash64)
  String logicalEntityKeyHash;

  String? parentLogicalKeyHash;
  String? immutableContentDigest;
  int createdAtMs;
  int readAtMs;
  int deliveredAtMs;

  /// Deterministic JSON containing only hashed part keys/content, revisions,
  /// and millisecond timestamps.
  String editPartsJson;

  int retractedAtMs;
  int? groupVersion;
  String? groupMetadataDigest;
  String? etagHash;
  int updatedAtMs;

  CloudSemanticSnapshotEntity({
    this.id = 0,
    required this.snapshotKey,
    required this.scopeGenerationKey,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.container,
    required this.database,
    required this.zone,
    required this.streamKind,
    required this.schemaVersion,
    required this.generation,
    required this.entityKind,
    required this.logicalEntityKeyHash,
    this.parentLogicalKeyHash,
    this.immutableContentDigest,
    this.createdAtMs = -1,
    this.readAtMs = -1,
    this.deliveredAtMs = -1,
    this.editPartsJson = '[]',
    this.retractedAtMs = -1,
    this.groupVersion,
    this.groupMetadataDigest,
    this.etagHash,
    required this.updatedAtMs,
  });
}

/// Durable replay, quarantine, and conflict state for one decoded change.
///
/// The change identity is re-digested with the complete account scope and
/// generation before persistence. Diagnostic fields accept safe codes only.
@Entity()
class CloudSemanticReplayEntity {
  int id;

  @Index(type: IndexType.hash64)
  @Unique()
  String replayKey;

  @Index(type: IndexType.hash64)
  String scopeGenerationKey;

  @Index(type: IndexType.hash64)
  String scopeKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  String container;
  String database;

  @Index(type: IndexType.hash64)
  String zone;

  String streamKind;
  int schemaVersion;
  int generation;

  @Index(type: IndexType.hash64)
  String changeIdHash;

  @Index(type: IndexType.hash64)
  String serverRecordIdHash;

  @Index(type: IndexType.hash64)
  String? logicalEntityKeyHash;

  String? payloadSha256;
  String? protectedPayloadReferenceHash;
  int inboxSequence;
  String changeType;

  /// One legal terminal state: applied, appliedWithConflict, or quarantined.
  ///
  /// A pending semantic attempt is never persisted. Keeping one closed
  /// outcome prevents contradictory applied/quarantined/conflicted flags.
  @Index(type: IndexType.hash64)
  String terminalOutcome;
  String? terminalSafeCode;
  int updatedAtMs;

  CloudSemanticReplayEntity({
    this.id = 0,
    required this.replayKey,
    required this.scopeGenerationKey,
    required this.scopeKey,
    required this.accountFingerprint,
    required this.container,
    required this.database,
    required this.zone,
    required this.streamKind,
    required this.schemaVersion,
    required this.generation,
    required this.changeIdHash,
    required this.serverRecordIdHash,
    this.logicalEntityKeyHash,
    this.payloadSha256,
    this.protectedPayloadReferenceHash,
    required this.inboxSequence,
    required this.changeType,
    required this.terminalOutcome,
    this.terminalSafeCode,
    required this.updatedAtMs,
  });
}

/// Durable single-writer authority for one Apple account/container/database.
///
/// The account value is an application-scoped one-way fingerprint. Owner,
/// state, and targetOwner use stable integer encodings validated by the
/// authority adapter before any permit is issued.
@Entity()
class CloudKitWriterAuthorityEntity {
  int id;

  @Index(type: IndexType.hash64)
  @Unique()
  String authorityKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  String container;
  String database;
  int owner;
  int state;
  int targetOwner;
  int epoch;
  String? transitionIdHash;
  String? resetScopeKeyHash;
  String? resetProofReferenceHash;
  int resetGeneration;
  int updatedAtMs;

  CloudKitWriterAuthorityEntity({
    this.id = 0,
    required this.authorityKey,
    required this.accountFingerprint,
    required this.container,
    required this.database,
    this.owner = 0,
    this.state = 0,
    this.targetOwner = 0,
    this.epoch = 1,
    this.transitionIdHash,
    this.resetScopeKeyHash,
    this.resetProofReferenceHash,
    this.resetGeneration = 0,
    required this.updatedAtMs,
  });
}

/// One legacy CloudKit deletion target admitted under a complete writer scope.
///
/// The raw record ID is retained because the legacy Rust API requires it to
/// issue a delete. It is never selected for a remote call unless the supplied
/// scope and writer epoch still match the durable legacy authority.
@Entity()
class CloudKitDeletionIntentEntity {
  int id;

  @Index(type: IndexType.hash64)
  @Unique()
  String intentKey;

  @Index(type: IndexType.hash64)
  String accountFingerprint;

  String container;
  String database;
  int writerEpoch;
  int kind;
  String recordId;

  /// 0 pending, 1 quarantined. Values are stable persisted state codes.
  @Index()
  int state;

  String? quarantineReason;
  int createdAtMs;
  int updatedAtMs;

  CloudKitDeletionIntentEntity({
    this.id = 0,
    required this.intentKey,
    required this.accountFingerprint,
    required this.container,
    required this.database,
    required this.writerEpoch,
    required this.kind,
    required this.recordId,
    this.state = 0,
    this.quarantineReason,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
}

/// Durable evidence for a pre-V2 SharedPreferences deletion value.
///
/// These rows intentionally have no CloudKit scope. They are evidence only,
/// and the deletion-intent store never includes them in a remote batch.
@Entity()
class CloudKitDeletionQuarantineEntity {
  int id;

  @Index(type: IndexType.hash64)
  @Unique()
  String quarantineKey;

  String sourceKey;
  String recordId;
  String reason;
  int createdAtMs;

  CloudKitDeletionQuarantineEntity({
    this.id = 0,
    required this.quarantineKey,
    required this.sourceKey,
    required this.recordId,
    required this.reason,
    required this.createdAtMs,
  });
}
