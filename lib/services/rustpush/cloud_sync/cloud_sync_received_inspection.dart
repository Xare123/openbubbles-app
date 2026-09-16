import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_received_archive_journal.dart';
import 'cloud_sync_received_archive_source_binding.dart';
import 'cloud_sync_received_record_observation.dart';
import 'cloud_sync_transport.dart';

/// One exact native observation -> durable ownership handoff. Caller owns the
/// network interlock, parent/checkpoint revalidation, and native writer pause.
/// Existing observations are reused, not silently replaced or called saves.
final class CloudSyncReceivedInspectionCoordinator {
  const CloudSyncReceivedInspectionCoordinator({
    required this.journal,
    required this.transport,
    required this.auth,
    required this.validate,
    required this.stillCurrent,
  });
  final CloudSyncReceivedArchiveJournal journal;
  final CloudProtectedPageLeaseTransport transport;
  final CloudSyncNativeAuthSnapshot auth;
  final Future<void> Function() validate;
  final bool Function() stillCurrent;

  Future<CloudSyncReceivedRecordObservation> inspect<T>({
    required int intentId,
    required Future<T> Function(CloudSyncReceivedArchiveSourceBinding source)
    prepareNative,
    required Future<CloudSyncReceivedRecordObservation> Function(T prepared)
    stageNative,
    required void Function() validateParent,
    required int expectedGeneration,
    required String expectedParentBinding,
  }) => transport.runProtectedStoreExclusive(() async {
    final local = transport;
    if (transport.protectedPageLeaseRecoveryIdentity !=
            auth.protectedStoreIdentity ||
        local is! CloudProtectedLocalLifecycleTransport) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    await validate();
    final (_, _, source) = journal.readMaterializedForInspection(
      intentId: intentId,
      currentAuth: auth,
    );
    final prior = journal.readRecordObservation(
      intentId: intentId,
      currentAuth: auth,
    );
    if (prior != null) {
      return (local as CloudProtectedLocalLifecycleTransport)
          .runLocalProtectedStoreExclusive(
            () => _adoptAndCommit(
              intentId: intentId,
              source: source,
              result: prior,
              owned: true,
              validateParent: validateParent,
              expectedGeneration: expectedGeneration,
              expectedParentBinding: expectedParentBinding,
            ),
          );
    }
    // Network and decryption retain only an opaque in-memory native result.
    // Do not make ordinary incoming delivery wait on this network fetch.
    final prepared = await prepareNative(source);
    return (local as CloudProtectedLocalLifecycleTransport)
        .runLocalProtectedStoreExclusive(() async {
          await validate();
          final (_, _, currentSource) = journal.readMaterializedForInspection(
            intentId: intentId,
            currentAuth: auth,
          );
          if (currentSource.encode() != source.encode()) {
            throw StateError('cloud_sync_received_archive_intent_changed');
          }
          validateParent();
          final result = await stageNative(prepared);
          return _adoptAndCommit(
            intentId: intentId,
            source: source,
            result: result,
            owned: false,
            validateParent: validateParent,
            expectedGeneration: expectedGeneration,
            expectedParentBinding: expectedParentBinding,
          );
        });
  });

  Future<CloudSyncReceivedRecordObservation> _adoptAndCommit({
    required int intentId,
    required CloudSyncReceivedArchiveSourceBinding source,
    required CloudSyncReceivedRecordObservation result,
    required bool owned,
    required void Function() validateParent,
    required int expectedGeneration,
    required String expectedParentBinding,
  }) async {
    try {
      await validate();
      result.requireSource(source);
      if (result.generation != expectedGeneration ||
          result.parentBinding != expectedParentBinding) {
        throw StateError('cloud_sync_received_archive_observation_changed');
      }
      validateParent();
      if (result.state == CloudSyncReceivedRecordState.unresolved) {
        return result;
      }
      if (!owned) {
        journal.adoptRecordObservation(
          intentId: intentId,
          expectedSource: source,
          observation: result,
          currentAuth: auth,
          stillCurrent: stillCurrent,
          validateParent: validateParent,
        );
        owned = true;
      }
      if (result.rawLeaseReference != null) {
        await transport.commitProtectedPageLease(result.rawLeaseReference!, {
          result.rawReference!,
        });
      }
      await validate();
      journal.markRecordObservationCommitted(
        intentId: intentId,
        source: source,
        observation: result,
        currentAuth: auth,
        stillCurrent: stillCurrent,
        validateParent: validateParent,
      );
      return result;
    } catch (_) {
      if (!owned && result.rawLeaseReference != null) {
        try {
          await transport.rollbackProtectedPageLease(result.rawLeaseReference!);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
