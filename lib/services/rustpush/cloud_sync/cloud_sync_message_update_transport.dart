import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;

import 'cloud_sync_local_mutation_journal.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_message_dependency.dart';
import 'cloud_sync_write_transport.dart';

/// Protected native stage for one existing Message-record update.
///
/// This is deliberately not a create stage. It carries only opaque protected
/// references and digests and may be adopted only as payload version 3.
final class CloudSyncProtectedMessageUpdateStage {
  CloudSyncProtectedMessageUpdateStage({
    required this.protectedReference,
    required this.leaseReference,
    required this.payloadSha256,
    required this.logicalEntityKeyHash,
    required this.serverRecordIdHash,
  }) {
    if (!RegExp(
          r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(protectedReference) ||
        !RegExp(r'^obcs2\.lease\.[0-9a-f]{32}$').hasMatch(leaseReference) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(payloadSha256) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(logicalEntityKeyHash) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(serverRecordIdHash)) {
      throw ArgumentError('cloud_sync_message_update_stage_invalid');
    }
  }

  final String protectedReference;
  final String leaseReference;
  final String payloadSha256;
  final String logicalEntityKeyHash;
  final String serverRecordIdHash;

  @override
  String toString() => 'CloudSyncProtectedMessageUpdateStage(redacted)';
}

enum CloudSyncMessageUpdateReconciliationDisposition {
  committed,
  notApplied,
  diverged,
  unresolved,
}

/// Exact lookup-only result for one submitted conditional Message update.
final class CloudSyncMessageUpdateReconciliation {
  const CloudSyncMessageUpdateReconciliation._({
    required this.disposition,
    this.receipt,
    this.failureCategory,
    this.retryAfter,
  });

  const CloudSyncMessageUpdateReconciliation.committed(
    CloudMessageUpdateReadbackReceipt receipt,
  ) : this._(
        disposition: CloudSyncMessageUpdateReconciliationDisposition.committed,
        receipt: receipt,
      );

  const CloudSyncMessageUpdateReconciliation.notApplied()
    : this._(
        disposition: CloudSyncMessageUpdateReconciliationDisposition.notApplied,
      );

  const CloudSyncMessageUpdateReconciliation.diverged()
    : this._(
        disposition: CloudSyncMessageUpdateReconciliationDisposition.diverged,
        failureCategory: CloudFailureCategory.conflict,
      );

  const CloudSyncMessageUpdateReconciliation.unresolved({
    required CloudFailureCategory failureCategory,
    Duration? retryAfter,
  }) : this._(
         disposition:
             CloudSyncMessageUpdateReconciliationDisposition.unresolved,
         failureCategory: failureCategory,
         retryAfter: retryAfter,
       );

  final CloudSyncMessageUpdateReconciliationDisposition disposition;
  final CloudMessageUpdateReadbackReceipt? receipt;
  final CloudFailureCategory? failureCategory;
  final Duration? retryAfter;

  @override
  String toString() =>
      'CloudSyncMessageUpdateReconciliation('
      '${disposition.name}, redacted)';
}

/// Update-only transport. No method can stage or submit a record create.
abstract interface class CloudSyncMessageUpdateTransport {
  Future<CloudSyncProtectedMessageUpdateStage> stageMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
    required frb_api.CloudSyncNativeSendReceipt receipt,
  });

  Future<CloudSyncPreparedSubmission> prepareMessageUpdateSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  });

  /// Consumes the native single-use update handle. A successful return means
  /// only that the attempt is durably fenced as outcome-unknown. Exact remote
  /// readback is still mandatory before the outbox can be confirmed.
  Future<void> consumePreparedMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncPreparedSubmission preparedSubmission,
    required CloudOutboxSubmissionIdentity persistedIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
  });

  Future<CloudSyncMessageUpdateReconciliation> reconcileMessageUpdate(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required CloudSyncLocalMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  });

  /// Releases the writer fence after the caller has durably committed exact
  /// readback and completed both protected-lease handoffs.
  Future<void> completeMessageUpdateReconciliation(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
  });
}
