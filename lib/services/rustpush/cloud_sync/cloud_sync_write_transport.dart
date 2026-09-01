import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';

/// A write operation containing only protected local references.
///
/// Plaintext records, Apple credentials, and resolved server record IDs must
/// stay behind the native protected boundary. The native implementation can
/// resolve these references during preflight, but Dart only carries the
/// references and their digests.
final class CloudSyncProtectedWriteOperation {
  CloudSyncProtectedWriteOperation({
    required this.operationId,
    required this.logicalEntityKeyHash,
    required this.action,
    this.protectedLeaseReference,
    required this.protectedServerRecordIdReference,
    required this.serverRecordIdHash,
    this.protectedPayloadReference,
    this.payloadSha256,
  }) {
    if (operationId.isEmpty) {
      throw ArgumentError('cloud_sync_write_operation_id_invalid');
    }
    if (!_isNativeDigest(logicalEntityKeyHash)) {
      throw ArgumentError('cloud_sync_write_logical_key_hash_invalid');
    }
    if (protectedLeaseReference != null &&
        !_isLeaseReference(protectedLeaseReference!)) {
      throw ArgumentError('cloud_sync_write_lease_reference_invalid');
    }
    if (!_isProtectedReference(protectedServerRecordIdReference)) {
      throw ArgumentError('cloud_sync_write_server_record_reference_invalid');
    }
    if (!_isNativeDigest(serverRecordIdHash)) {
      throw ArgumentError('cloud_sync_write_server_record_hash_invalid');
    }
    if (action == CloudOutboxAction.save &&
        (protectedPayloadReference == null ||
            payloadSha256 == null ||
            protectedLeaseReference == null)) {
      throw ArgumentError('cloud_sync_write_payload_missing');
    }
    if (action == CloudOutboxAction.delete &&
        (protectedPayloadReference != null || payloadSha256 != null)) {
      throw ArgumentError('cloud_sync_write_delete_payload_invalid');
    }
    if (protectedPayloadReference != null &&
        !_isProtectedReference(protectedPayloadReference!)) {
      throw ArgumentError('cloud_sync_write_payload_reference_invalid');
    }
    if (payloadSha256 != null && !_isContentDigest(payloadSha256!)) {
      throw ArgumentError('cloud_sync_write_payload_digest_invalid');
    }
  }

  /// Builds the protected write input after the local record map has been
  /// resolved. The map's Apple record ID remains an opaque protected
  /// reference; it is never resolved in Dart.
  factory CloudSyncProtectedWriteOperation.fromOutbox(
    CloudOutboxOperation operation, {
    required CloudRecordMapEntry recordMapping,
  }) {
    if (operation.scope != recordMapping.scope ||
        operation.logicalEntityKeyHash != recordMapping.logicalEntityKeyHash ||
        operation.serverRecordIdHash != recordMapping.serverRecordIdHash) {
      throw ArgumentError('cloud_sync_write_record_mapping_mismatch');
    }

    return CloudSyncProtectedWriteOperation(
      operationId: operation.operationId,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      action: operation.action,
      protectedLeaseReference: operation.protectedLeaseReference,
      protectedServerRecordIdReference: recordMapping.encryptedServerRecordId,
      serverRecordIdHash: recordMapping.serverRecordIdHash,
      protectedPayloadReference: operation.encryptedPayloadReference,
      payloadSha256: operation.payloadSha256,
    );
  }

  final String operationId;
  final String logicalEntityKeyHash;
  final CloudOutboxAction action;
  final String? protectedLeaseReference;
  final String protectedServerRecordIdReference;
  final String serverRecordIdHash;
  final String? protectedPayloadReference;
  final String? payloadSha256;
}

/// A native-prepared submission that can cross the Dart/native boundary once.
///
/// The prepared operation material and identity are intentionally private and
/// there is no serialization or copying API. Dart cannot make an object truly
/// opaque, so the only public inspection is redacted binding metadata and the
/// single-use claim used by a transport implementation.
class CloudSyncPreparedSubmission {
  /// Internal construction seam for native transport implementations and
  /// fakes. The resulting object contains only protected references and is
  /// still bound to one exact identity before it can be consumed.
  CloudSyncPreparedSubmission.fromProtectedPreflight({
    required CloudSyncScope scope,
    required CloudOutboxSubmissionIdentity identity,
    required List<CloudSyncProtectedWriteOperation> operations,
  }) : _scopeStorageKey = scope.storageKey,
       _requestUuid = identity.requestUuid,
       _operationUuids = Map.unmodifiable(identity.operationUuids),
       _operationBindings = List.unmodifiable(
         operations.map(_protectedOperationBinding),
       ),
       _operationIds = List.unmodifiable(
         operations.map((operation) => operation.operationId),
       ) {
    if (_operationIds.isEmpty ||
        _operationIds.length > 256 ||
        _operationIds.toSet().length != _operationIds.length) {
      throw ArgumentError('cloud_sync_prepared_submission_operations_invalid');
    }
    if (operations.map((operation) => operation.action).toSet().length != 1) {
      throw ArgumentError('cloud_sync_prepared_submission_mixed_actions');
    }
    identity.validateOperationIds(_operationIds);
  }

  final String _scopeStorageKey;
  final String _requestUuid;
  final Map<String, String> _operationUuids;
  final List<String> _operationBindings;
  final List<String> _operationIds;
  bool _claimed = false;

  /// Number of protected operations held by the native-prepared submission.
  int get operationCount => _operationIds.length;

  /// Local correlation IDs only. No payload, record ID, token, or credential
  /// is exposed through this diagnostic view.
  List<String> get operationIds => _operationIds;

  /// Claims this prepared submission for its one permitted network consume.
  ///
  /// The claim is made before the caller awaits network work, so concurrent or
  /// repeated consumption attempts fail closed instead of replaying a write.
  void claimForConsumption(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity persistedIdentity,
    required List<CloudSyncProtectedWriteOperation> protectedOperations,
  }) {
    if (_claimed) {
      throw StateError('cloud_sync_prepared_submission_already_consumed');
    }
    if (scope.storageKey != _scopeStorageKey) {
      throw ArgumentError('cloud_sync_prepared_submission_scope_mismatch');
    }
    persistedIdentity.validateOperationIds(_operationIds);
    if (persistedIdentity.requestUuid != _requestUuid ||
        !_sameMap(persistedIdentity.operationUuids, _operationUuids)) {
      throw ArgumentError('cloud_sync_prepared_submission_identity_mismatch');
    }
    final bindings = protectedOperations
        .map(_protectedOperationBinding)
        .toList(growable: false);
    if (!_sameList(bindings, _operationBindings)) {
      throw ArgumentError('cloud_sync_prepared_submission_binding_mismatch');
    }
    _claimed = true;
  }

  static bool _sameMap(Map<String, String> left, Map<String, String> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  static bool _sameList(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

/// Write-only capability used after protected preflight succeeds.
///
/// Callers must complete [prepareSubmission] before making the durable
/// outbox submission marker. A prepared object is then consumed exactly once.
abstract interface class CloudSyncWriteTransport {
  Future<CloudSyncPreparedSubmission> prepareSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required List<CloudSyncProtectedWriteOperation> operations,
  });

  Future<CloudPushBatchResult> consumePreparedSubmission(
    CloudSyncScope scope, {
    required CloudSyncPreparedSubmission preparedSubmission,
    required CloudOutboxSubmissionIdentity persistedIdentity,
    required List<CloudSyncProtectedWriteOperation> protectedOperations,
    required List<CloudOutboxOperation> operations,
  });
}

/// Optional native receipt cleanup invoked only after outbox outcomes are
/// durable. Implementations must retain receipts for every non-terminal row.
abstract interface class CloudSyncWriteReceiptFinalizer {
  Future<void> acknowledgeDurableTerminalOperations(
    CloudSyncScope scope, {
    required List<CloudOutboxOperation> operations,
    required List<CloudOutboxTransition> transitions,
  });
}

/// Durable policy consulted before a confirmed outbox transition is committed.
///
/// Most writers release terminal receipts immediately. The manual outbound
/// Canary retains exactly one confirmed receipt until a separate no-save
/// replay proves the remote digest.
abstract interface class CloudSyncConfirmedReceiptRetentionPolicy {
  bool get retainConfirmedReceiptsForReplay;
}

String _protectedOperationBinding(CloudSyncProtectedWriteOperation operation) =>
    '${operation.operationId}\u001f${operation.logicalEntityKeyHash}\u001f'
    '${operation.action.name}\u001f${operation.protectedLeaseReference ?? ''}\u001f'
    '${operation.protectedServerRecordIdReference}\u001f'
    '${operation.serverRecordIdHash}\u001f'
    '${operation.protectedPayloadReference ?? ''}\u001f'
    '${operation.payloadSha256 ?? ''}';

bool _isContentDigest(String value) =>
    RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

bool _isNativeDigest(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

bool _isLeaseReference(String value) =>
    RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(value);

bool _isProtectedReference(String value) =>
    RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$').hasMatch(value);
