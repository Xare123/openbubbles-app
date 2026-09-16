// Keep public named parameters while the stored fields stay private.
// ignore_for_file: prefer_initializing_formals

import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_received_archive_identity.dart';
import 'cloud_sync_received_archive_journal.dart';
import 'cloud_sync_received_archive_source_binding.dart';
import 'cloud_sync_transport.dart';

/// Local protected-store handoff only, never an IDS send or CloudKit write.
/// Existing received intent ownership wins after a lost commit response;
/// recovery recommits the same lease instead of restaging a second source.
/// The caller must retain the engine for this whole future and supply current
/// native identity validation, not a writer permission inferred from metadata.
final class CloudSyncReceivedArchiveStaging {
  const CloudSyncReceivedArchiveStaging({
    required CloudSyncReceivedArchiveJournal journal,
    required CloudProtectedPageLeaseTransport transport,
    required CloudSyncNativeAuthSnapshot capturedIdentity,
    required Future<void> Function() validateCurrentIdentity,
    required bool Function() stillCurrent,
  }) : _journal = journal,
       _transport = transport,
       _identity = capturedIdentity,
       _validateCurrent = validateCurrentIdentity,
       _stillCurrent = stillCurrent;

  final CloudSyncReceivedArchiveJournal _journal;
  final CloudProtectedPageLeaseTransport _transport;
  final CloudSyncNativeAuthSnapshot _identity;
  final Future<void> Function() _validateCurrent;
  final bool Function() _stillCurrent;

  Future<int> persist({
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required int localChatId,
    required int Function() persistMessage,
    required Future<CloudSyncReceivedArchiveSourceBinding> Function()
    stageNative,
    required DateTime Function() clock,
  }) {
    if (_transport.protectedPageLeaseRecoveryIdentity !=
        _identity.protectedStoreIdentity) {
      throw StateError('cloud_sync_received_archive_identity_changed');
    }
    final local = _transport;
    if (local is! CloudProtectedLocalLifecycleTransport) {
      throw StateError(
        'cloud_sync_received_archive_store_exclusion_unavailable',
      );
    }
    // Native local-store ownership covers stage/adopt/commit against recovery
    // and GC across engines. It is distinct from the network writer interlock.
    return (local as CloudProtectedLocalLifecycleTransport)
        .runLocalProtectedStoreExclusive(() async {
          await _validateCurrent();
          final existing = _journal.findProtectedSource(
            messageGuid: wire.id,
            localChatId: localChatId,
            currentAuth: _identity,
          );
          final source = existing ?? await stageNative();
          var owned = existing != null;
          try {
            await _validateCurrent();
            final id = _journal.saveReceivedCapture(
              wire: wire,
              liveContext: liveContext,
              localChatId: localChatId,
              persistMessage: persistMessage,
              source: source,
              capturedAuth: _identity,
              stillCurrent: _stillCurrent,
              now: clock().toUtc(),
            );
            owned =
                true; // synchronous durable adoption, before the first await
            await _transport.commitProtectedPageLease(source.leaseReference, {
              source.protectedReference,
            });
            await _validateCurrent();
            final retained = _journal.readProtectedSource(
              intentId: id,
              currentAuth: _identity,
            );
            if (retained.encode() != source.encode()) {
              throw StateError('cloud_sync_received_archive_intent_changed');
            }
            return id;
          } catch (_) {
            if (!owned) {
              try {
                await _transport.rollbackProtectedPageLease(
                  source.leaseReference,
                );
              } catch (_) {
                // Unadopted orphan recovery owns cleanup; preserve the failure.
              }
            }
            rethrow;
          }
        });
  }
}
