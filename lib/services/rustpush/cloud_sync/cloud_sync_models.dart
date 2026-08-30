import 'dart:collection';

final RegExp _canonicalAppleUuidPattern = RegExp(
  r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
);

bool _isCanonicalAppleUuid(String value) =>
    _canonicalAppleUuidPattern.hasMatch(value);

enum CloudSyncStreamKind { messages, profiles }

/// Local persistence namespace. It does not alter the remote CloudKit scope.
/// [legacy] preserves the exact pre-lane storage key for compatibility while
/// new shadow evidence and semantic production state remain isolated.
enum CloudSyncPersistenceLane {
  legacy,
  shadow,
  semantic;

  /// Stable spelling for callers that require the isolated semantic V2 lane.
  /// Existing local ObjectBox keys retain the `semantic` suffix.
  static const CloudSyncPersistenceLane semanticV2 = semantic;
}

/// Account and CloudKit-zone boundary for every V2 record and operation.
///
/// [accountFingerprint] must be a one-way, application-scoped fingerprint.
/// Raw DSIDs and Apple IDs are not valid values.
class CloudSyncScope {
  static final RegExp _accountFingerprintPattern = RegExp(
    r'^[A-Za-z0-9_-]{43}$',
  );
  static const int _maximumComponentLength = 256;
  static const int _maximumSchemaVersion = 1 << 20;

  CloudSyncScope({
    required this.accountFingerprint,
    required this.container,
    required this.database,
    required this.zone,
    this.streamKind = CloudSyncStreamKind.messages,
    this.schemaVersion = 2,
    this.persistenceLane = CloudSyncPersistenceLane.legacy,
  }) {
    if (!_accountFingerprintPattern.hasMatch(accountFingerprint)) {
      throw ArgumentError('cloud_sync_scope_account_fingerprint_invalid');
    }
    if (!_isValidComponent(container)) {
      throw ArgumentError('cloud_sync_scope_container_invalid');
    }
    if (!_isValidComponent(database)) {
      throw ArgumentError('cloud_sync_scope_database_invalid');
    }
    if (!_isValidComponent(zone)) {
      throw ArgumentError('cloud_sync_scope_zone_invalid');
    }
    if (schemaVersion <= 0 || schemaVersion > _maximumSchemaVersion) {
      throw ArgumentError('cloud_sync_scope_schema_version_invalid');
    }
  }

  static bool _isValidComponent(
    String value, {
    int maximumLength = _maximumComponentLength,
  }) {
    if (value.isEmpty || value.length > maximumLength) return false;
    for (final codeUnit in value.codeUnits) {
      if (codeUnit == 0x1f ||
          codeUnit < 0x20 ||
          (codeUnit >= 0x7f && codeUnit <= 0x9f)) {
        return false;
      }
    }
    return true;
  }

  final String accountFingerprint;
  final String container;
  final String database;
  final String zone;
  final CloudSyncStreamKind streamKind;
  final int schemaVersion;
  final CloudSyncPersistenceLane persistenceLane;

  String get storageKey {
    final base =
        '$accountFingerprint\u001f$container\u001f$database\u001f$zone\u001f${streamKind.name}\u001f$schemaVersion';
    return persistenceLane == CloudSyncPersistenceLane.legacy
        ? base
        : '$base\u001f${persistenceLane.name}';
  }

  /// Safe, bounded identifier for diagnostics. It intentionally excludes the
  /// container, database, zone, and full account fingerprint.
  String get diagnosticKey {
    final prefix = accountFingerprint.length <= 8
        ? accountFingerprint
        : accountFingerprint.substring(0, 8);
    return 'acct:$prefix/v$schemaVersion/${persistenceLane.name}';
  }

  @override
  bool operator ==(Object other) =>
      other is CloudSyncScope && other.storageKey == storageKey;

  @override
  int get hashCode => storageKey.hashCode;

  @override
  String toString() => 'CloudSyncScope($diagnosticKey)';
}

/// Typed reset input produced after the protected remote reset/identity
/// checks have completed. The store treats the proof reference as opaque and
/// never resolves it inside an ObjectBox transaction.
final class CloudSyncResetRebootstrapRequest {
  CloudSyncResetRebootstrapRequest({
    required this.scope,
    required this.transitionIdHash,
    required this.activeIdentityFingerprint,
    required this.expectedGeneration,
    required this.protectedRemoteStateProofReference,
  }) {
    if (!_isDigest(transitionIdHash) ||
        activeIdentityFingerprint != scope.accountFingerprint ||
        expectedGeneration <= 0 ||
        !_isProtectedReference(protectedRemoteStateProofReference)) {
      throw ArgumentError('cloud_reset_rebootstrap_request_invalid');
    }
  }

  final CloudSyncScope scope;
  final String transitionIdHash;
  final String activeIdentityFingerprint;
  final int expectedGeneration;
  final String protectedRemoteStateProofReference;

  @override
  String toString() => 'CloudSyncResetRebootstrapRequest(redacted)';
}

/// Receipt emitted only after the store has atomically completed a reset
/// rebootstrap. It is the only accepted input for authority reset completion.
final class CloudSyncResetCompletionProof {
  CloudSyncResetCompletionProof({
    required this.scope,
    required this.transitionIdHash,
    required this.activeIdentityFingerprint,
    required this.previousGeneration,
    required this.generation,
    required this.protectedRemoteStateProofReference,
  }) {
    if (!_isDigest(transitionIdHash) ||
        activeIdentityFingerprint != scope.accountFingerprint ||
        previousGeneration <= 0 ||
        generation != previousGeneration + 1 ||
        !_isProtectedReference(protectedRemoteStateProofReference)) {
      throw ArgumentError('cloud_reset_completion_proof_invalid');
    }
  }

  final CloudSyncScope scope;
  final String transitionIdHash;
  final String activeIdentityFingerprint;
  final int previousGeneration;
  final int generation;
  final String protectedRemoteStateProofReference;

  bool binds(CloudSyncResetRebootstrapRequest request) =>
      scope == request.scope &&
      transitionIdHash == request.transitionIdHash &&
      activeIdentityFingerprint == request.activeIdentityFingerprint &&
      previousGeneration == request.expectedGeneration &&
      protectedRemoteStateProofReference ==
          request.protectedRemoteStateProofReference;

  @override
  String toString() => 'CloudSyncResetCompletionProof(redacted)';
}

bool _isDigest(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

bool _isProtectedReference(String value) =>
    value.length <= 256 &&
    value.startsWith('obcs2.ref.') &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'));

bool _isProtectedLeaseReference(String value) =>
    RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(value);

bool _isNativeProtectedReference(String value) =>
    RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$').hasMatch(value);

bool _isNativeDigest(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

bool _isOperationId(String value) =>
    RegExp(r'^op1:[a-f0-9]{64}$').hasMatch(value);

enum CloudChangeType { save, delete }

/// Durable inbox states. Keep the order stable because ObjectBox persists the
/// explicit integer mapping in its status column.
enum CloudInboxStatus {
  pending,
  applied,
  quarantined,

  /// The protected source record is retained locally, but this client cannot
  /// project it into the canonical message store. This is terminal for fetch
  /// token progress, remains repairable, does not advance the exact-applied
  /// projection floor, and never authorizes a CloudKit or canonical delete.
  retainedUnprojected,
}

/// Fixed, content-free reason assigned before semantic decoding. These values
/// may be persisted and reported as counts; they must never contain server
/// text, identifiers, tokens, or payload data.
enum CloudPreflightCode {
  unsupportedRecordType,
  malformedMetadata,
  oversizedRecord,
  invalidChangeShape,
  unknown,
}

enum CloudOutboxAction { save, delete }

/// Durable outbox states. Keep the order stable because ObjectBox persists the
/// explicit integer mapping in its state column.
enum CloudOutboxStatus {
  pending,
  leased,
  confirmed,
  paused,
  quarantined,
  unknownOutcome,
}

enum CloudEntityKind {
  chat,
  message,
  attachment,
  reaction,
  groupPhoto,
  sharedProfile,
}

enum CloudFailureCategory {
  network,
  throttled,
  server,
  authorization,
  pcsUnavailable,
  malformedRecord,
  conflict,
  dependency,
  localStorage,
  cancelled,
  unknown,
  unsupportedService,
}

extension CloudFailureCategoryBehavior on CloudFailureCategory {
  bool get isRetryable => switch (this) {
    CloudFailureCategory.network ||
    CloudFailureCategory.throttled ||
    CloudFailureCategory.server ||
    CloudFailureCategory.authorization ||
    CloudFailureCategory.pcsUnavailable ||
    CloudFailureCategory.dependency ||
    CloudFailureCategory.localStorage => true,
    CloudFailureCategory.malformedRecord ||
    CloudFailureCategory.conflict ||
    CloudFailureCategory.cancelled ||
    CloudFailureCategory.unknown ||
    CloudFailureCategory.unsupportedService => false,
  };
}

class CloudSyncFailure implements Exception {
  CloudSyncFailure({required this.category, this.retryAfter, this.safeCode}) {
    if (retryAfter != null && retryAfter!.inMicroseconds < 0) {
      throw ArgumentError('cloud_sync_failure_retry_after_invalid');
    }
    if (safeCode != null && !_safeCodePattern.hasMatch(safeCode!)) {
      throw ArgumentError('cloud_sync_failure_safe_code_invalid');
    }
  }

  static final RegExp _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  final CloudFailureCategory category;
  final Duration? retryAfter;

  /// An allowlisted diagnostic code only. Never place server bodies, record
  /// identifiers, handles, tokens, or message content here.
  final String? safeCode;

  @override
  String toString() =>
      'CloudSyncFailure(category: ${category.name}, code: ${safeCode ?? 'none'})';
}

/// A fetched CloudKit change whose payload remains encrypted or is represented
/// by an encrypted local reference.
class CloudFetchedChange {
  CloudFetchedChange({
    required this.changeId,
    required this.recordIdHash,
    required this.type,
    this.etagHash,
    this.encryptedServerRecordId,
    this.protectedSystemFieldsReference,
    this.encryptedPayloadReference,
    this.payloadSha256,
    this.isTombstone = false,
    this.serverModifiedAt,
    this.preflightFailure,
    this.preflightCode,
  }) {
    if (changeId.isEmpty) {
      throw ArgumentError('cloud_fetched_change_id_invalid');
    }
    if (recordIdHash.isEmpty) {
      throw ArgumentError('cloud_fetched_record_id_hash_invalid');
    }
    if (etagHash != null && etagHash!.isEmpty) {
      throw ArgumentError('cloud_fetched_etag_hash_invalid');
    }
    if (encryptedServerRecordId != null && encryptedServerRecordId!.isEmpty) {
      throw ArgumentError('cloud_fetched_server_record_reference_invalid');
    }
    if (protectedSystemFieldsReference != null &&
        protectedSystemFieldsReference!.isEmpty) {
      throw ArgumentError('cloud_fetched_system_fields_reference_invalid');
    }
    if (encryptedPayloadReference != null &&
        encryptedPayloadReference!.isEmpty) {
      throw ArgumentError('cloud_fetched_payload_reference_invalid');
    }
    if (payloadSha256 != null && payloadSha256!.isEmpty) {
      throw ArgumentError('cloud_fetched_payload_digest_invalid');
    }
    if (isTombstone != (type == CloudChangeType.delete)) {
      throw ArgumentError('cloud_fetched_tombstone_type_invalid');
    }
    if (preflightFailure == null && preflightCode != null) {
      throw ArgumentError('cloud_fetched_preflight_code_without_failure');
    }
  }

  /// Deterministic, account-scoped digest used to deduplicate replayed pages.
  final String changeId;
  final String recordIdHash;
  final String? etagHash;
  final CloudChangeType type;

  /// Application-encrypted server identifier and raw CloudKit system fields.
  /// Tombstones may need these even when no etag or payload remains.
  final String? encryptedServerRecordId;
  final String? protectedSystemFieldsReference;

  /// A ciphertext blob identifier or protected local keystore reference.
  /// Decrypted message content must never be placed here.
  final String? encryptedPayloadReference;
  final String? payloadSha256;
  final bool isTombstone;
  final DateTime? serverModifiedAt;

  /// Set only when the Rust ingestion boundary has already proven that the
  /// raw server record is malformed or unsupported. The durable engine
  /// journals the original protected bytes, then quarantines the entry
  /// without invoking a semantic decoder.
  final CloudFailureCategory? preflightFailure;
  final CloudPreflightCode? preflightCode;

  CloudPreflightCode? get effectivePreflightCode => preflightFailure == null
      ? null
      : preflightCode ?? CloudPreflightCode.unknown;
}

class CloudFetchBatch {
  CloudFetchBatch({
    required this.scope,
    required Iterable<CloudFetchedChange> changes,
    required this.batchId,
    required this.generation,
    required this.nextToken,
    required this.hasMore,
    this.protectedPageLeaseReference,
  }) : changes = List.unmodifiable(changes) {
    if (batchId.isEmpty) {
      throw ArgumentError('cloud_fetch_batch_id_invalid');
    }
    if (generation <= 0) {
      throw ArgumentError('cloud_fetch_batch_generation_invalid');
    }
    if (protectedPageLeaseReference != null &&
        !RegExp(
          r'^obcs2\.lease\.[0-9a-f]{32}$',
        ).hasMatch(protectedPageLeaseReference!)) {
      throw ArgumentError('cloud_fetch_batch_lease_reference_invalid');
    }
  }

  final CloudSyncScope scope;
  final List<CloudFetchedChange> changes;
  final String batchId;
  final int generation;

  /// Opaque token. Store adapters must protect it at rest and observers must
  /// never emit it.
  final String? nextToken;
  final bool hasMore;

  /// Opaque native protected-page lease. The durable store adopts this value
  /// atomically with the journal/checkpoint before native blob finalization.
  final String? protectedPageLeaseReference;
}

class CloudInboxEntry {
  CloudInboxEntry({
    required this.scope,
    required this.sequence,
    required this.change,
    required this.status,
    required this.attemptCount,
    required this.createdAt,
    required this.batchId,
    required this.generation,
    this.nextEligibleAt,
    this.lastFailure,
    this.completedAt,
  }) {
    if (sequence <= 0) {
      throw ArgumentError('cloud_inbox_sequence_invalid');
    }
    if (attemptCount < 0) {
      throw ArgumentError('cloud_inbox_attempt_count_invalid');
    }
    if (batchId.isEmpty) {
      throw ArgumentError('cloud_inbox_batch_id_invalid');
    }
    if (generation <= 0) {
      throw ArgumentError('cloud_inbox_generation_invalid');
    }
  }

  final CloudSyncScope scope;
  final int sequence;
  final CloudFetchedChange change;
  final CloudInboxStatus status;
  final int attemptCount;
  final DateTime createdAt;
  final String batchId;
  final int generation;
  final DateTime? nextEligibleAt;
  final CloudFailureCategory? lastFailure;
  final DateTime? completedAt;

  CloudInboxEntry copyWith({
    CloudInboxStatus? status,
    int? attemptCount,
    DateTime? nextEligibleAt,
    bool clearNextEligibleAt = false,
    CloudFailureCategory? lastFailure,
    bool clearLastFailure = false,
    DateTime? completedAt,
  }) {
    return CloudInboxEntry(
      scope: scope,
      sequence: sequence,
      change: change,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      createdAt: createdAt,
      batchId: batchId,
      generation: generation,
      nextEligibleAt: clearNextEligibleAt
          ? null
          : nextEligibleAt ?? this.nextEligibleAt,
      lastFailure: clearLastFailure ? null : lastFailure ?? this.lastFailure,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}

class CloudSyncCheckpoint {
  CloudSyncCheckpoint({
    required this.scope,
    this.fetchedToken,
    this.generation = 1,
    this.lastBatchId,
    this.pendingBatchId,
    this.hasUnmarkedPendingInbox = false,
    this.fetchedSequence = 0,
    this.lastAppliedSequence = 0,
    this.mutationRevisionCounter = 0,
    this.consecutivePullFailures = 0,
    this.nextPullEligibleAt,
    this.lastSuccessfulRunAt,
    this.lastFailure,
  }) {
    if (generation <= 0) {
      throw ArgumentError('cloud_checkpoint_generation_invalid');
    }
    if (fetchedSequence < 0) {
      throw ArgumentError('cloud_checkpoint_fetched_sequence_invalid');
    }
    if (lastAppliedSequence < 0) {
      throw ArgumentError('cloud_checkpoint_applied_sequence_invalid');
    }
    if (mutationRevisionCounter < 0) {
      throw ArgumentError('cloud_checkpoint_mutation_revision_invalid');
    }
    if (consecutivePullFailures < 0) {
      throw ArgumentError('cloud_checkpoint_pull_failures_invalid');
    }
  }

  final CloudSyncScope scope;
  final String? fetchedToken;
  final int generation;
  final String? lastBatchId;
  final String? pendingBatchId;

  /// A pre-pending-token journal contains unresolved current-generation rows
  /// but no durable pending-page marker. Its already-advanced token must not
  /// be used for another fetch until those retained rows become terminal.
  final bool hasUnmarkedPendingInbox;
  final int fetchedSequence;

  /// Highest contiguous exactly-applied inbox sequence. Retained-unprojected,
  /// pending, and quarantined rows block this projection floor. The protected
  /// fetch token can independently advance once the complete journal is
  /// durably terminal.
  final int lastAppliedSequence;
  final int mutationRevisionCounter;
  final int consecutivePullFailures;
  final DateTime? nextPullEligibleAt;
  final DateTime? lastSuccessfulRunAt;
  final CloudFailureCategory? lastFailure;

  CloudSyncCheckpoint copyWith({
    String? fetchedToken,
    bool clearFetchedToken = false,
    int? generation,
    String? lastBatchId,
    String? pendingBatchId,
    bool clearPendingBatchId = false,
    bool? hasUnmarkedPendingInbox,
    int? fetchedSequence,
    int? lastAppliedSequence,
    int? mutationRevisionCounter,
    int? consecutivePullFailures,
    DateTime? nextPullEligibleAt,
    bool clearNextPullEligibleAt = false,
    DateTime? lastSuccessfulRunAt,
    CloudFailureCategory? lastFailure,
    bool clearLastFailure = false,
  }) {
    return CloudSyncCheckpoint(
      scope: scope,
      fetchedToken: clearFetchedToken
          ? null
          : fetchedToken ?? this.fetchedToken,
      generation: generation ?? this.generation,
      lastBatchId: lastBatchId ?? this.lastBatchId,
      pendingBatchId: clearPendingBatchId
          ? null
          : pendingBatchId ?? this.pendingBatchId,
      hasUnmarkedPendingInbox:
          hasUnmarkedPendingInbox ?? this.hasUnmarkedPendingInbox,
      fetchedSequence: fetchedSequence ?? this.fetchedSequence,
      lastAppliedSequence: lastAppliedSequence ?? this.lastAppliedSequence,
      mutationRevisionCounter:
          mutationRevisionCounter ?? this.mutationRevisionCounter,
      consecutivePullFailures:
          consecutivePullFailures ?? this.consecutivePullFailures,
      nextPullEligibleAt: clearNextPullEligibleAt
          ? null
          : nextPullEligibleAt ?? this.nextPullEligibleAt,
      lastSuccessfulRunAt: lastSuccessfulRunAt ?? this.lastSuccessfulRunAt,
      lastFailure: clearLastFailure ? null : lastFailure ?? this.lastFailure,
    );
  }
}

/// Content-free result of reconciling old inbox rows whose CloudKit token was
/// already committed before projection status became independently durable.
class CloudInboxRetentionRecovery {
  const CloudInboxRetentionRecovery({
    required this.retainedUnprojected,
    required this.tombstoneReadOnlyAcknowledged,
    required this.previousAppliedSequence,
    required this.recomputedAppliedSequence,
    required this.legacyFloorInflated,
    required this.recoveryComplete,
    this.firstUnresolvedSequence,
    this.firstUnresolvedStatus,
    this.firstUnresolvedCategory,
  }) : assert(retainedUnprojected >= 0),
       assert(tombstoneReadOnlyAcknowledged >= 0),
       assert(previousAppliedSequence >= 0),
       assert(recomputedAppliedSequence >= 0),
       assert(
         (firstUnresolvedSequence == null) == (firstUnresolvedStatus == null),
       ),
       assert(recoveryComplete == (firstUnresolvedSequence == null));

  final int retainedUnprojected;

  /// Subset of [retainedUnprojected] that are read-only tombstones.
  final int tombstoneReadOnlyAcknowledged;

  /// Persisted projection floor before journal reconciliation.
  final int previousAppliedSequence;

  /// Largest contiguous exactly-applied prefix proven from sequence one.
  final int recomputedAppliedSequence;

  /// Whether the persisted floor crossed a row that was not exactly applied.
  final bool legacyFloorInflated;

  /// First row that still blocks projection, if any.
  final int? firstUnresolvedSequence;
  final CloudInboxStatus? firstUnresolvedStatus;
  final CloudFailureCategory? firstUnresolvedCategory;

  /// True only when every fetched row is exactly applied.
  final bool recoveryComplete;
}

class CloudOutboxSubmissionIdentity {
  CloudOutboxSubmissionIdentity({
    required this.requestUuid,
    required Map<String, String> operationUuids,
  }) : operationUuids = Map.unmodifiable(operationUuids) {
    if (!_isCanonicalAppleUuid(requestUuid)) {
      throw ArgumentError('cloud_outbox_request_uuid_invalid');
    }
    if (operationUuids.isEmpty ||
        operationUuids.keys.any((operationId) => operationId.isEmpty) ||
        operationUuids.values.any((uuid) => !_isCanonicalAppleUuid(uuid)) ||
        operationUuids.values.toSet().length != operationUuids.length ||
        operationUuids.values.contains(requestUuid)) {
      throw ArgumentError('cloud_outbox_operation_uuid_map_invalid');
    }
  }

  final String requestUuid;
  final Map<String, String> operationUuids;

  void validateOperationIds(Iterable<String> operationIds) {
    final expected = operationIds.toSet();
    if (expected.length != operationUuids.length ||
        !expected.containsAll(operationUuids.keys)) {
      throw ArgumentError('cloud_outbox_submission_identity_mismatch');
    }
  }
}

class CloudOutboxOperation {
  CloudOutboxOperation({
    required this.scope,
    required this.operationId,
    required this.logicalEntityKeyHash,
    required this.action,
    required this.payloadVersion,
    required this.mutationRevision,
    required this.checkpointGeneration,
    required Iterable<String> dependencyOperationIds,
    required this.createdAt,
    this.encryptedPayloadReference,
    this.payloadSha256,
    this.serverRecordIdHash,
    this.protectedLeaseReference,
    this.appleRequestUuid,
    this.appleOperationUuid,
    this.status = CloudOutboxStatus.pending,
    this.attemptCount = 0,
    this.nextEligibleAt,
    this.lastFailure,
    this.leaseId,
    this.leaseExpiresAt,
    this.confirmedAt,
  }) : dependencyOperationIds = Set.unmodifiable(
         dependencyOperationIds.toSet(),
       ) {
    if (operationId.isEmpty) {
      throw ArgumentError('cloud_outbox_operation_id_invalid');
    }
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_outbox_logical_key_invalid');
    }
    if (payloadVersion <= 0) {
      throw ArgumentError('cloud_outbox_payload_version_invalid');
    }
    if (mutationRevision < 0) {
      throw ArgumentError('cloud_outbox_mutation_revision_invalid');
    }
    if (checkpointGeneration <= 0) {
      throw ArgumentError('cloud_outbox_checkpoint_generation_invalid');
    }
    if (encryptedPayloadReference != null &&
        encryptedPayloadReference!.isEmpty) {
      throw ArgumentError('cloud_outbox_payload_reference_invalid');
    }
    if (payloadSha256 != null && payloadSha256!.isEmpty) {
      throw ArgumentError('cloud_outbox_payload_digest_invalid');
    }
    if (serverRecordIdHash != null && serverRecordIdHash!.isEmpty) {
      throw ArgumentError('cloud_outbox_server_record_hash_invalid');
    }
    if (protectedLeaseReference != null &&
        !_isProtectedLeaseReference(protectedLeaseReference!)) {
      throw ArgumentError('cloud_outbox_protected_lease_reference_invalid');
    }
    if ((appleRequestUuid == null) != (appleOperationUuid == null)) {
      throw ArgumentError('cloud_outbox_submission_identity_incomplete');
    }
    if (appleRequestUuid != null &&
        (!_isCanonicalAppleUuid(appleRequestUuid!) ||
            !_isCanonicalAppleUuid(appleOperationUuid!) ||
            appleRequestUuid == appleOperationUuid ||
            operationId == appleOperationUuid)) {
      throw ArgumentError('cloud_outbox_submission_identity_invalid');
    }
    if (action != CloudOutboxAction.delete &&
        (encryptedPayloadReference == null || payloadSha256 == null)) {
      throw ArgumentError('cloud_outbox_save_payload_missing');
    }
    if (attemptCount < 0) {
      throw ArgumentError('cloud_outbox_attempt_count_invalid');
    }
  }

  final CloudSyncScope scope;
  final String operationId;
  final String logicalEntityKeyHash;
  final CloudOutboxAction action;
  final int payloadVersion;
  final int mutationRevision;

  /// Generation of the scope checkpoint which admitted this mutation.
  ///
  /// A rebootstrap advances the checkpoint generation and terminally fences
  /// every older non-terminal outbox row. This value must therefore never be
  /// zero, including after an ObjectBox schema migration.
  final int checkpointGeneration;

  /// A ciphertext blob identifier or protected local keystore reference.
  final String? encryptedPayloadReference;
  final String? payloadSha256;
  final String? serverRecordIdHash;

  /// Native protected lease adopted by this outbox row.
  ///
  /// This is deliberately separate from the page-lease adoption marker. It
  /// remains live while the outbound operation is non-terminal.
  final String? protectedLeaseReference;
  final String? appleRequestUuid;
  final String? appleOperationUuid;
  final Set<String> dependencyOperationIds;
  final DateTime createdAt;
  final CloudOutboxStatus status;
  final int attemptCount;
  final DateTime? nextEligibleAt;
  final CloudFailureCategory? lastFailure;
  final String? leaseId;
  final DateTime? leaseExpiresAt;
  final DateTime? confirmedAt;

  CloudOutboxOperation copyWith({
    CloudOutboxStatus? status,
    int? attemptCount,
    DateTime? nextEligibleAt,
    bool clearNextEligibleAt = false,
    CloudFailureCategory? lastFailure,
    bool clearLastFailure = false,
    String? leaseId,
    bool clearLeaseId = false,
    DateTime? leaseExpiresAt,
    bool clearLeaseExpiresAt = false,
    DateTime? confirmedAt,
    Set<String>? dependencyOperationIds,
    String? encryptedPayloadReference,
    String? payloadSha256,
    String? serverRecordIdHash,
    String? protectedLeaseReference,
    bool clearProtectedLeaseReference = false,
    String? appleRequestUuid,
    String? appleOperationUuid,
    bool clearSubmissionIdentity = false,
  }) {
    return CloudOutboxOperation(
      scope: scope,
      operationId: operationId,
      logicalEntityKeyHash: logicalEntityKeyHash,
      action: action,
      payloadVersion: payloadVersion,
      mutationRevision: mutationRevision,
      checkpointGeneration: checkpointGeneration,
      encryptedPayloadReference:
          encryptedPayloadReference ?? this.encryptedPayloadReference,
      payloadSha256: payloadSha256 ?? this.payloadSha256,
      serverRecordIdHash: serverRecordIdHash ?? this.serverRecordIdHash,
      protectedLeaseReference: clearProtectedLeaseReference
          ? null
          : protectedLeaseReference ?? this.protectedLeaseReference,
      appleRequestUuid: clearSubmissionIdentity
          ? null
          : appleRequestUuid ?? this.appleRequestUuid,
      appleOperationUuid: clearSubmissionIdentity
          ? null
          : appleOperationUuid ?? this.appleOperationUuid,
      dependencyOperationIds:
          dependencyOperationIds ?? this.dependencyOperationIds,
      createdAt: createdAt,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      nextEligibleAt: clearNextEligibleAt
          ? null
          : nextEligibleAt ?? this.nextEligibleAt,
      lastFailure: clearLastFailure ? null : lastFailure ?? this.lastFailure,
      leaseId: clearLeaseId ? null : leaseId ?? this.leaseId,
      leaseExpiresAt: clearLeaseExpiresAt
          ? null
          : leaseExpiresAt ?? this.leaseExpiresAt,
      confirmedAt: confirmedAt ?? this.confirmedAt,
    );
  }
}

class CloudOutboxDraft {
  CloudOutboxDraft({
    required this.scope,
    required this.logicalEntityKeyHash,
    required this.action,
    required this.payloadVersion,
    required Iterable<String> dependencyOperationIds,
    required this.createdAt,
    this.encryptedPayloadReference,
    this.payloadSha256,
    this.serverRecordIdHash,
    this.protectedLeaseReference,
  }) : dependencyOperationIds = Set.unmodifiable(
         dependencyOperationIds.toSet(),
       ) {
    if (logicalEntityKeyHash.isEmpty) {
      throw ArgumentError('cloud_outbox_draft_logical_key_invalid');
    }
    if (payloadVersion <= 0) {
      throw ArgumentError('cloud_outbox_draft_payload_version_invalid');
    }
    if (encryptedPayloadReference != null &&
        encryptedPayloadReference!.isEmpty) {
      throw ArgumentError('cloud_outbox_draft_payload_reference_invalid');
    }
    if (payloadSha256 != null && payloadSha256!.isEmpty) {
      throw ArgumentError('cloud_outbox_draft_payload_digest_invalid');
    }
    if (serverRecordIdHash != null && serverRecordIdHash!.isEmpty) {
      throw ArgumentError('cloud_outbox_draft_server_record_hash_invalid');
    }
    if (protectedLeaseReference != null &&
        !_isProtectedLeaseReference(protectedLeaseReference!)) {
      throw ArgumentError(
        'cloud_outbox_draft_protected_lease_reference_invalid',
      );
    }
    if (action != CloudOutboxAction.delete &&
        (encryptedPayloadReference == null || payloadSha256 == null)) {
      throw ArgumentError('cloud_outbox_draft_save_payload_missing');
    }
  }

  final CloudSyncScope scope;
  final String logicalEntityKeyHash;
  final CloudOutboxAction action;
  final int payloadVersion;
  final Set<String> dependencyOperationIds;
  final DateTime createdAt;
  final String? encryptedPayloadReference;
  final String? payloadSha256;
  final String? serverRecordIdHash;
  final String? protectedLeaseReference;
}

enum CloudPushDisposition {
  confirmed,
  retryable,
  unauthorized,
  pcsUnavailable,
  serverRecordChanged,
  quarantined,
  unknownOutcome,
}

class CloudPushOutcome {
  CloudPushOutcome({
    required this.operationId,
    required this.disposition,
    this.failureCategory,
    this.retryAfter,
  }) {
    final operationIdMatch = _operationIdPattern.matchAsPrefix(operationId);
    if (operationIdMatch == null ||
        operationIdMatch.end != operationId.length) {
      // Keep the rejected value out of the exception. Operation IDs are
      // correlation keys and must not become a diagnostic data-leak path.
      throw ArgumentError('cloud_push_outcome_operation_id_invalid');
    }
    if (retryAfter != null && retryAfter!.isNegative) {
      throw ArgumentError('cloud_push_outcome_retry_after_invalid');
    }
    if (disposition == CloudPushDisposition.unknownOutcome &&
        failureCategory != CloudFailureCategory.unknown) {
      throw ArgumentError('cloud_push_unknown_outcome_requires_unknown');
    }
  }

  static final RegExp _operationIdPattern = RegExp(r'op1:[0-9a-f]{64}');

  final String operationId;
  final CloudPushDisposition disposition;
  final CloudFailureCategory? failureCategory;
  final Duration? retryAfter;

  @override
  String toString() => 'CloudPushOutcome(${disposition.name}, redacted)';
}

class CloudPushBatchResult {
  CloudPushBatchResult({required Iterable<CloudPushOutcome> outcomes})
    : outcomes = UnmodifiableMapView(_indexOutcomes(outcomes));

  static Map<String, CloudPushOutcome> _indexOutcomes(
    Iterable<CloudPushOutcome> values,
  ) {
    final indexed = <String, CloudPushOutcome>{};
    for (final outcome in values) {
      if (indexed.containsKey(outcome.operationId)) {
        // Do not include the duplicate ID in the exception. The batch must
        // fail closed instead of silently choosing one of two outcomes.
        throw ArgumentError('cloud_push_batch_duplicate_outcome_id');
      }
      indexed[outcome.operationId] = outcome;
    }
    return indexed;
  }

  final Map<String, CloudPushOutcome> outcomes;

  @override
  String toString() => 'CloudPushBatchResult(count: ${outcomes.length})';
}

/// Result of reading CloudKit after a write response was lost.
///
/// The transport performs the protected semantic comparison. The Dart engine
/// never inspects message content or treats a transport retry as proof that a
/// write did not commit.
enum CloudUnknownOutcomeDisposition {
  committed,
  notApplied,
  serverRecordChanged,
  unresolved,
  quarantined,
}

/// Content-free evidence binding one protected server-state comparison to the
/// exact durable mutation it resolved. Production transports create the
/// opaque proof reference inside the protected Rust boundary.
final class CloudUnknownOutcomeProof {
  CloudUnknownOutcomeProof({
    required this.operationId,
    required this.appleRequestUuid,
    required this.appleOperationUuid,
    required this.scopeStorageKey,
    required this.checkpointGeneration,
    required this.logicalEntityKeyHash,
    required this.serverRecordIdHash,
    required this.action,
    required this.expectedPayloadSha256,
    required this.protectedProofReference,
    this.observedEtagHash,
  }) {
    if (!_isOperationId(operationId) ||
        !_isCanonicalAppleUuid(appleRequestUuid) ||
        !_isCanonicalAppleUuid(appleOperationUuid) ||
        appleRequestUuid == appleOperationUuid ||
        scopeStorageKey.isEmpty ||
        checkpointGeneration <= 0 ||
        !_isNativeDigest(logicalEntityKeyHash) ||
        !_isNativeDigest(serverRecordIdHash) ||
        !_isNativeProtectedReference(protectedProofReference) ||
        (action == CloudOutboxAction.save && expectedPayloadSha256 == null) ||
        (expectedPayloadSha256 != null && !_isDigest(expectedPayloadSha256!)) ||
        (action == CloudOutboxAction.delete && expectedPayloadSha256 != null)) {
      throw ArgumentError('cloud_unknown_outcome_proof_invalid');
    }
  }

  final String operationId;
  final String appleRequestUuid;
  final String appleOperationUuid;
  final String scopeStorageKey;
  final int checkpointGeneration;
  final String logicalEntityKeyHash;
  final String serverRecordIdHash;
  final CloudOutboxAction action;
  final String? expectedPayloadSha256;
  final String protectedProofReference;
  final String? observedEtagHash;

  bool binds(CloudOutboxOperation operation) =>
      action == CloudOutboxAction.save &&
      operationId == operation.operationId &&
      appleRequestUuid == operation.appleRequestUuid &&
      appleOperationUuid == operation.appleOperationUuid &&
      scopeStorageKey == operation.scope.storageKey &&
      checkpointGeneration == operation.checkpointGeneration &&
      logicalEntityKeyHash == operation.logicalEntityKeyHash &&
      serverRecordIdHash == operation.serverRecordIdHash &&
      action == operation.action &&
      expectedPayloadSha256 == operation.payloadSha256 &&
      protectedProofReference == operation.encryptedPayloadReference;

  @override
  String toString() => 'CloudUnknownOutcomeProof(redacted)';
}

class CloudUnknownOutcomeResolution {
  const CloudUnknownOutcomeResolution._({
    required this.disposition,
    this.proof,
    this.failureCategory,
    this.retryAfter,
  });

  const CloudUnknownOutcomeResolution.committed({
    required CloudUnknownOutcomeProof proof,
  }) : this._(
         disposition: CloudUnknownOutcomeDisposition.committed,
         proof: proof,
       );

  const CloudUnknownOutcomeResolution.notApplied({
    required CloudUnknownOutcomeProof proof,
  }) : this._(
         disposition: CloudUnknownOutcomeDisposition.notApplied,
         proof: proof,
       );

  const CloudUnknownOutcomeResolution.serverRecordChanged({
    required CloudUnknownOutcomeProof proof,
  }) : this._(
         disposition: CloudUnknownOutcomeDisposition.serverRecordChanged,
         proof: proof,
         failureCategory: CloudFailureCategory.conflict,
       );

  const CloudUnknownOutcomeResolution.unresolved({
    required CloudFailureCategory failureCategory,
    Duration? retryAfter,
  }) : this._(
         disposition: CloudUnknownOutcomeDisposition.unresolved,
         failureCategory: failureCategory,
         retryAfter: retryAfter,
       );

  const CloudUnknownOutcomeResolution.quarantined({
    required CloudFailureCategory failureCategory,
  }) : this._(
         disposition: CloudUnknownOutcomeDisposition.quarantined,
         failureCategory: failureCategory,
       );

  final CloudUnknownOutcomeDisposition disposition;
  final CloudUnknownOutcomeProof? proof;
  final CloudFailureCategory? failureCategory;
  final Duration? retryAfter;

  @override
  String toString() =>
      'CloudUnknownOutcomeResolution(${disposition.name}, redacted)';
}

class CloudRecordMapEntry {
  const CloudRecordMapEntry({
    required this.scope,
    required this.logicalEntityKeyHash,
    required this.serverRecordIdHash,
    required this.encryptedServerRecordId,
    this.etagHash,
    this.encryptedRawRecordReference,
    required this.updatedAt,
  });

  final CloudSyncScope scope;
  final String logicalEntityKeyHash;
  final String serverRecordIdHash;

  /// Protected keystore reference to the Apple record ID. Observers must never
  /// emit the resolved value.
  final String encryptedServerRecordId;
  final String? etagHash;
  final String? encryptedRawRecordReference;
  final DateTime updatedAt;
}

class CloudSyncRunRecord {
  const CloudSyncRunRecord({
    required this.scope,
    required this.runId,
    required this.triggerName,
    required this.architectureName,
    required this.startedAt,
    required this.finishedAt,
    required this.counters,
    required this.modeName,
    this.failureCategory,
  });

  final CloudSyncScope scope;
  final String runId;
  final String triggerName;
  final String architectureName;
  final DateTime startedAt;
  final DateTime finishedAt;
  final CloudSyncRunCounters counters;
  final String modeName;
  final CloudFailureCategory? failureCategory;
}

enum CloudInboxApplyDisposition {
  applied,
  tombstoneReadOnlyAcknowledged,
  deferred,
  retryable,
  quarantined,
}

class CloudInboxApplyResult {
  const CloudInboxApplyResult.applied({this.inboxStatusPersisted = false})
    : disposition = CloudInboxApplyDisposition.applied,
      failureCategory = null,
      safeCode = null,
      retryAfter = null;

  /// A server-confirmed tombstone was deliberately retained as protected
  /// evidence because this build is not permitted to delete canonical state.
  /// The engine may acknowledge only the inbox row as applied.
  const CloudInboxApplyResult.tombstoneReadOnlyAcknowledged()
    : disposition = CloudInboxApplyDisposition.tombstoneReadOnlyAcknowledged,
      failureCategory = null,
      safeCode = null,
      retryAfter = null,
      inboxStatusPersisted = false;

  const CloudInboxApplyResult.deferred({
    this.failureCategory = CloudFailureCategory.dependency,
    this.safeCode,
    this.retryAfter,
  }) : disposition = CloudInboxApplyDisposition.deferred,
       inboxStatusPersisted = false;

  const CloudInboxApplyResult.retryable({
    required this.failureCategory,
    this.safeCode,
    this.retryAfter,
  }) : disposition = CloudInboxApplyDisposition.retryable,
       inboxStatusPersisted = false;

  const CloudInboxApplyResult.quarantined({
    required this.failureCategory,
    this.safeCode,
    this.inboxStatusPersisted = false,
  }) : disposition = CloudInboxApplyDisposition.quarantined,
       retryAfter = null;

  final CloudInboxApplyDisposition disposition;
  final CloudFailureCategory? failureCategory;
  final String? safeCode;
  final Duration? retryAfter;

  /// True only when the semantic gateway committed the canonical mutation,
  /// replay outcome, record mapping, and inbox terminal state atomically.
  final bool inboxStatusPersisted;
}

class CloudSyncRunCounters {
  const CloudSyncRunCounters({
    this.fetched = 0,
    this.applied = 0,
    this.deferred = 0,
    this.quarantined = 0,
    this.preflightQuarantined = 0,
    this.preflightUnsupportedRecordType = 0,
    this.preflightMalformedMetadata = 0,
    this.preflightOversizedRecord = 0,
    this.preflightInvalidChangeShape = 0,
    this.preflightUnknown = 0,
    this.startupQuarantined = 0,
    this.postFetchQuarantined = 0,
    this.tombstoneQuarantined = 0,
    this.tombstoneReadOnlyAcknowledged = 0,
    this.retainedUnprojected = 0,
    this.semanticUnsupportedServiceQuarantined = 0,
    this.semanticStageQuarantined = 0,
    this.confirmed = 0,
    this.retried = 0,
    this.shadowJournalEntries = 0,
    this.shadowJournalEstimatedBytes = 0,
    this.shadowJournalRejectedEntries = 0,
  });

  final int fetched;
  final int applied;
  final int deferred;
  final int quarantined;

  /// Content-free semantic-inbox quarantine stages. They partition inbox
  /// quarantines; [semanticStageQuarantined] is the residual bucket for any
  /// non-preflight, non-tombstone, non-unsupported-service terminal result,
  /// and [quarantined] may also include unclassified outbox work.
  final int preflightQuarantined;
  final int preflightUnsupportedRecordType;
  final int preflightMalformedMetadata;
  final int preflightOversizedRecord;
  final int preflightInvalidChangeShape;
  final int preflightUnknown;
  final int startupQuarantined;
  final int postFetchQuarantined;
  final int tombstoneQuarantined;
  final int tombstoneReadOnlyAcknowledged;

  /// Protected records retained locally after deterministic projection
  /// failure. Tombstone acknowledgements are included in this total.
  final int retainedUnprojected;
  final int semanticUnsupportedServiceQuarantined;
  final int semanticStageQuarantined;
  final int confirmed;
  final int retried;

  /// Redacted Phase 1 gauges. They contain counts only, never identifiers,
  /// tokens, payload references, or message content.
  final int shadowJournalEntries;
  final int shadowJournalEstimatedBytes;
  final int shadowJournalRejectedEntries;

  CloudSyncRunCounters add({
    int fetched = 0,
    int applied = 0,
    int deferred = 0,
    int quarantined = 0,
    int preflightQuarantined = 0,
    int preflightUnsupportedRecordType = 0,
    int preflightMalformedMetadata = 0,
    int preflightOversizedRecord = 0,
    int preflightInvalidChangeShape = 0,
    int preflightUnknown = 0,
    int startupQuarantined = 0,
    int postFetchQuarantined = 0,
    int tombstoneQuarantined = 0,
    int tombstoneReadOnlyAcknowledged = 0,
    int retainedUnprojected = 0,
    int semanticUnsupportedServiceQuarantined = 0,
    int semanticStageQuarantined = 0,
    int confirmed = 0,
    int retried = 0,
    int shadowJournalEntries = 0,
    int shadowJournalEstimatedBytes = 0,
    int shadowJournalRejectedEntries = 0,
  }) {
    return CloudSyncRunCounters(
      fetched: this.fetched + fetched,
      applied: this.applied + applied,
      deferred: this.deferred + deferred,
      quarantined: this.quarantined + quarantined,
      preflightQuarantined: this.preflightQuarantined + preflightQuarantined,
      preflightUnsupportedRecordType:
          this.preflightUnsupportedRecordType + preflightUnsupportedRecordType,
      preflightMalformedMetadata:
          this.preflightMalformedMetadata + preflightMalformedMetadata,
      preflightOversizedRecord:
          this.preflightOversizedRecord + preflightOversizedRecord,
      preflightInvalidChangeShape:
          this.preflightInvalidChangeShape + preflightInvalidChangeShape,
      preflightUnknown: this.preflightUnknown + preflightUnknown,
      startupQuarantined: this.startupQuarantined + startupQuarantined,
      postFetchQuarantined: this.postFetchQuarantined + postFetchQuarantined,
      tombstoneQuarantined: this.tombstoneQuarantined + tombstoneQuarantined,
      tombstoneReadOnlyAcknowledged:
          this.tombstoneReadOnlyAcknowledged + tombstoneReadOnlyAcknowledged,
      retainedUnprojected: this.retainedUnprojected + retainedUnprojected,
      semanticUnsupportedServiceQuarantined:
          this.semanticUnsupportedServiceQuarantined +
          semanticUnsupportedServiceQuarantined,
      semanticStageQuarantined:
          this.semanticStageQuarantined + semanticStageQuarantined,
      confirmed: this.confirmed + confirmed,
      retried: this.retried + retried,
      shadowJournalEntries: this.shadowJournalEntries + shadowJournalEntries,
      shadowJournalEstimatedBytes:
          this.shadowJournalEstimatedBytes + shadowJournalEstimatedBytes,
      shadowJournalRejectedEntries:
          this.shadowJournalRejectedEntries + shadowJournalRejectedEntries,
    );
  }

  CloudSyncRunCounters combine(CloudSyncRunCounters other) => add(
    fetched: other.fetched,
    applied: other.applied,
    deferred: other.deferred,
    quarantined: other.quarantined,
    preflightQuarantined: other.preflightQuarantined,
    preflightUnsupportedRecordType: other.preflightUnsupportedRecordType,
    preflightMalformedMetadata: other.preflightMalformedMetadata,
    preflightOversizedRecord: other.preflightOversizedRecord,
    preflightInvalidChangeShape: other.preflightInvalidChangeShape,
    preflightUnknown: other.preflightUnknown,
    startupQuarantined: other.startupQuarantined,
    postFetchQuarantined: other.postFetchQuarantined,
    tombstoneQuarantined: other.tombstoneQuarantined,
    tombstoneReadOnlyAcknowledged: other.tombstoneReadOnlyAcknowledged,
    retainedUnprojected: other.retainedUnprojected,
    semanticUnsupportedServiceQuarantined:
        other.semanticUnsupportedServiceQuarantined,
    semanticStageQuarantined: other.semanticStageQuarantined,
    confirmed: other.confirmed,
    retried: other.retried,
    shadowJournalEntries: other.shadowJournalEntries,
    shadowJournalEstimatedBytes: other.shadowJournalEstimatedBytes,
    shadowJournalRejectedEntries: other.shadowJournalRejectedEntries,
  );
}
