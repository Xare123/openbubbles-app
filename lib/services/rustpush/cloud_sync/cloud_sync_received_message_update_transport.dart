import 'cloud_sync_historical_parent_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_message_update_transport.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_message_dependency.dart';
import 'cloud_sync_received_mutation_journal.dart';
import 'cloud_sync_write_transport.dart';

/// Origin-specific native preparation/opening only. The existing executor owns
/// single-submit, unknown-outcome readback, lease handoffs and queue ordering.
/// There is deliberately no outgoing IDS receipt parameter in this interface.
abstract interface class CloudSyncReceivedMessageUpdateTransport {
  Future<CloudSyncProtectedMessageUpdateStage> stageReceivedMessageUpdate(
    CloudSyncScope scope, {
    required CloudSyncReceivedMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
    required CloudSyncHistoricalParentProof parent,
    required CloudSyncNativeAuthSnapshot currentAuth,
  });

  Future<CloudSyncPreparedSubmission> prepareReceivedMessageUpdateSubmission(
    CloudSyncScope scope, {
    required CloudOutboxSubmissionIdentity submissionIdentity,
    required CloudOutboxOperation operation,
    required CloudSyncProtectedWriteOperation protectedOperation,
    required CloudSyncReceivedMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  });

  Future<CloudSyncMessageUpdateReconciliation> reconcileReceivedMessageUpdate(
    CloudSyncScope scope, {
    required CloudOutboxOperation operation,
    required CloudSyncReceivedMutationAdmissionSource source,
    required CloudSyncMessageMutationPredecessor predecessor,
  });
}
