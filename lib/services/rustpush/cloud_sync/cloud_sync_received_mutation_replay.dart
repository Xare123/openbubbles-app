import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_received_mutation_identity.dart';
import 'cloud_sync_received_mutation_journal.dart';
import 'cloud_sync_received_mutation_source_binding.dart';

/// One page in the existing received-source worker, not another scheduler or
/// upload engine. Each original event remains encrypted and durably owned.
final class CloudSyncReceivedMutationReplayResult {
  const CloudSyncReceivedMutationReplayResult({
    required this.nextId,
    required this.exhausted,
    required this.deferred,
    required this.applied,
  });
  final int nextId;
  final bool exhausted;
  final bool deferred;
  final int applied;
}

/// Local-only replay of the native-opened immutable seed. The incoming queue
/// owns reflection ordering with new receives. No outgoing send, native writer
/// permit, remote read, create, update or completion is granted here.
final class CloudSyncReceivedMutationReplay {
  CloudSyncReceivedMutationReplay({
    required this.journal,
    required this.currentAuth,
    required this.stillCurrent,
    required this.validateIdentity,
    required this.restoreNative,
    required this.enqueueLocal,
    required this.readTarget,
    required this.reflect,
    required this.onReflected,
    required this.onDeferred,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc());

  final CloudSyncReceivedMutationJournal journal;
  final CloudSyncNativeAuthSnapshot currentAuth;
  final bool Function() stillCurrent;
  final Future<void> Function() validateIdentity;
  final Future<api.CloudSyncRestoredReceivedMutation> Function(
    CloudSyncReceivedMutationSourceBinding,
  )
  restoreNative;
  final Future<void> Function(Future<void> Function()) enqueueLocal;
  final Message? Function(String) readTarget;
  final Future<Message?> Function(api.MessageInst) reflect;
  final void Function(Message) onReflected;
  final void Function(Object) onDeferred;
  final DateTime Function() _clock;

  Future<CloudSyncReceivedMutationReplayResult> runPage({
    required int afterId,
    required int maximumIntentId,
    int limit = 20,
  }) async {
    await validateIdentity();
    _requireCurrent();
    final rows = journal.readPending(
      currentAuth: currentAuth,
      afterId: afterId,
      maximumIntentId: maximumIntentId,
      onlyPendingReflection: true,
      limit: limit,
    );
    var cursor = afterId;
    var applied = 0;
    var deferred = false;
    for (final row in rows) {
      await validateIdentity();
      _requireCurrent();
      try {
        final source = CloudSyncReceivedMutationSourceBinding.decode(
          row.protectedSourceBinding,
        );
        source.requireOrigin(
          account: currentAuth.accountFingerprint,
          store: currentAuth.protectedStoreIdentity,
          eventGuidHash: row.mutationGuidHash,
          sourceDigest: row.sourceSha256,
        );
        final restored = await restoreNative(source);
        await validateIdentity();
        _requireCurrent();
        if (restored.accountFingerprint != currentAuth.accountFingerprint ||
            restored.protectedStoreIdentity !=
                currentAuth.protectedStoreIdentity ||
            CloudSyncReceivedMutationIdentity.restoreNative(
                  restored,
                  expectedGuidHash: row.mutationGuidHash,
                  expectedTargetGuidHash: row.targetGuidHash,
                  expectedSourceSha256: row.sourceSha256,
                ) ==
                null) {
          throw StateError('cloud_sync_received_mutation_source_changed');
        }
        await enqueueLocal(() async {
          _requireCurrent();
          if (journal.reflectionCommitted(
            intentId: row.id,
            currentAuth: currentAuth,
          )) {
            return;
          }
          final wire = restored.message;
          final targetGuid = switch (wire.message) {
            api.Message_Edit(:final field0) => field0.tuuid,
            api.Message_Unsend(:final field0) => field0.tuuid,
            _ => throw StateError(
              'cloud_sync_received_mutation_source_changed',
            ),
          };
          final before = readTarget(targetGuid);
          if (before == null) {
            deferred = true;
            return;
          }
          final digest = CloudSyncReceivedMutationJournal.snapshot(before);
          final projected = await reflect(wire);
          _requireCurrent();
          if (projected == null) {
            deferred = true;
            return;
          }
          final saved = journal.commitReplayedReflection(
            intentId: row.id,
            restored: restored,
            currentAuth: currentAuth,
            stillCurrent: stillCurrent,
            expectedBeforeSnapshot: digest,
            reflected: projected,
            now: _clock(),
          );
          applied++;
          onReflected(saved);
        });
      } catch (error) {
        _requireCurrent();
        deferred = true;
        onDeferred(error);
      }
      // A missing/unsupported event cannot starve later targets. A bounded
      // round retries it later from its original seed, without marking done.
      cursor = row.id;
    }
    _requireCurrent();
    final exhausted = journal
        .readPending(
          currentAuth: currentAuth,
          afterId: cursor,
          maximumIntentId: maximumIntentId,
          onlyPendingReflection: true,
          limit: 1,
        )
        .isEmpty;
    return CloudSyncReceivedMutationReplayResult(
      nextId: cursor,
      exhausted: exhausted,
      deferred: deferred,
      applied: applied,
    );
  }

  void _requireCurrent() {
    if (!stillCurrent()) {
      throw StateError('cloud_sync_received_mutation_identity_changed');
    }
  }
}
