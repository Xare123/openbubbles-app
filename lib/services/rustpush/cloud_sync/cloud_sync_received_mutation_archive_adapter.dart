import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_historical_parent_binding.dart';
import 'cloud_sync_local_send_consumer.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_message_update_executor.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_message_dependency.dart';
import 'cloud_sync_received_mutation_journal.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloudkit_writer_authority.dart';
import 'objectbox_cloud_sync_store.dart';

/// Bounded received-origin admission inside the existing automatic worker's
/// interlock. This owns no timer, IDS sender, create engine or second outbox.
final class CloudSyncReceivedMutationArchiveAdapter {
  const CloudSyncReceivedMutationArchiveAdapter({
    required this.store,
    required this.durable,
    required this.journal,
    required this.executor,
    required this.auth,
    required this.warmReadDependencies,
    required this.validate,
    required this.stillCurrent,
    required this.receivedArchiveAllowed,
    this.readConfirmedLocalParent,
    this.shouldYield,
  });

  final Store store;
  final ObjectBoxCloudSyncStore durable;
  final CloudSyncReceivedMutationJournal journal;
  final CloudSyncMessageUpdateExecutor executor;
  final CloudSyncNativeAuthSnapshot auth;
  final Future<void> Function() warmReadDependencies;
  final Future<void> Function() validate;
  final bool Function() stillCurrent;
  final bool Function() receivedArchiveAllowed;
  final CloudSyncConfirmedLocalParentReader? readConfirmedLocalParent;
  final bool Function()? shouldYield;

  bool get _dispatchCurrent => stillCurrent() && receivedArchiveAllowed();

  Future<void> _validateDispatch() async {
    if (!_dispatchCurrent) {
      throw StateError('cloud_sync_received_archive_confirmation_required');
    }
    await validate();
    if (!_dispatchCurrent) {
      throw StateError('cloud_sync_received_archive_confirmation_required');
    }
  }

  /// Settle payload-v3 with its existing executor before the create drain can
  /// see it. Unknown results retain their operation UUID and use readback only.
  /// Dispatch authority remains separately checked by the native transport.
  Future<bool> drainExisting(CloudSyncScope scope) async {
    await validate();
    await durable.recoverExpiredOutboxLeases(
      scope,
      now: DateTime.now().toUtc(),
    );
    final operations = await durable.readOutboxEntries(scope);
    final needsWork = operations.any(
      (op) =>
          op.payloadVersion == cloudSyncMessageUpdatePayloadVersion &&
          (op.status != CloudOutboxStatus.confirmed ||
              op.protectedLeaseReference != null),
    );
    // Also run local marker recovery when the outbox already finalized before
    // a process interruption. A no-work executor cannot submit another origin.
    if (needsWork || journal.hasPendingReadbackRetirement(currentAuth: auth)) {
      try {
        await executor.runOnce(
          scope,
          currentAuth: auth,
          stillCurrent: stillCurrent,
        );
      } on CloudKitWriterAuthorityFailure catch (error) {
        // The guard may persist Unknown and then throw instead of returning a
        // save result. Schedule only that exact durable received operation's
        // readback. This is a retry hint, not permission to submit again.
        if (error.safeCode != 'cloudkit_writer_mutation_outcome_unknown' ||
            !stillCurrent()) {
          rethrow;
        }
        final unknown = (await durable.readOutboxEntries(scope))
            .where(
              (op) =>
                  op.payloadVersion == cloudSyncMessageUpdatePayloadVersion &&
                  op.status == CloudOutboxStatus.unknownOutcome,
            )
            .toList();
        if (unknown.length != 1 ||
            !operations.any(
              (op) => op.operationId == unknown.single.operationId,
            ) ||
            !journal.hasAdoptedOperationId(unknown.single.operationId)) {
          rethrow;
        }
        journal.readAdoptedForUpdate(
          operationId: unknown.single.operationId,
          currentAuth: auth,
          stillCurrent: stillCurrent,
        );
        return false;
      }
      await validate();
    }
    return !(await durable.readOutboxEntries(scope)).any(
      (op) =>
          op.payloadVersion == cloudSyncMessageUpdatePayloadVersion &&
          (op.status != CloudOutboxStatus.confirmed ||
              op.protectedLeaseReference != null),
    );
  }

  Future<CloudSyncLocalSendConsumerResult> admitPending(
    CloudSyncScope scope, {
    int maximumIntents = 5,
  }) async {
    if (maximumIntents < 1 || maximumIntents > 20) {
      throw ArgumentError('cloud_sync_received_mutation_limit_invalid');
    }
    await _validateDispatch();
    final candidates = journal.readUpdateCandidates(
      currentAuth: auth,
      limit: maximumIntents,
    );
    if (candidates.isEmpty) return const CloudSyncLocalSendConsumerResult();
    // Warm lookup-only dependencies in the established read session. Actual
    // staging independently revalidates the exact native source/Chat/Message.
    await warmReadDependencies();
    await _validateDispatch();
    var admitted = 0;
    var deferred = 0;
    final reasons = <String, int>{};
    for (final candidate in candidates) {
      if (shouldYield?.call() ?? false) {
        return CloudSyncLocalSendConsumerResult(
          admitted: admitted,
          deferred: deferred,
          yielded: true,
          deferredReasons: Map.unmodifiable(reasons),
        );
      }
      journal.markUpdateConsidered(
        intentId: candidate.id,
        currentAuth: auth,
        stillCurrent: () => _dispatchCurrent,
        now: DateTime.now().toUtc(),
      );
      try {
        final source = journal.readReflectedForUpdate(
          intentId: candidate.id,
          currentAuth: auth,
          stillCurrent: () => _dispatchCurrent,
        );
        final predecessor = source.requirePredecessor(
          store: store,
          messageScope: scope,
          readConfirmedLocalParent: readConfirmedLocalParent,
        );
        final parent = requireCloudSyncHistoricalParentProof(
          store: store,
          messageScope: scope,
          chatId: source.localChatId,
        );
        await executor.admitReflectedReceivedUpdate(
          scope,
          source: source,
          predecessor: predecessor,
          parent: parent,
          currentAuth: auth,
          stillCurrent: () => _dispatchCurrent,
        );
        admitted++;
      } catch (error) {
        // A throw can follow durable adoption. Drain that exact operation
        // before considering another event; never reconstruct a second stage.
        await _validateDispatch();
        deferred++;
        final code = cloudSyncV2SafeFailureCode(error);
        reasons.update(code, (count) => count + 1, ifAbsent: () => 1);
      }
      await _validateDispatch();
      if (!await drainExisting(scope)) {
        return CloudSyncLocalSendConsumerResult(
          admitted: admitted,
          deferred: deferred,
          outboxBlocked: true,
          deferredReasons: Map.unmodifiable(reasons),
        );
      }
    }
    return CloudSyncLocalSendConsumerResult(
      admitted: admitted,
      deferred: deferred,
      candidateLimitReached: candidates.length == maximumIntents,
      deferredReasons: Map.unmodifiable(reasons),
    );
  }
}
