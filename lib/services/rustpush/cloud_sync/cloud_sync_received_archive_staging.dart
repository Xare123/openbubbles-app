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

  /// Foreground capture needs no file lease: encrypted bytes and the received
  /// Message commit together. Disk staging may retry after restart from this
  /// exact seed without waiting on a network or local-store lock during receive.
  static Future<int> persistSealed({
    required CloudSyncReceivedArchiveJournal journal,
    required CloudSyncNativeAuthSnapshot capturedIdentity,
    required Future<void> Function() validateCurrentIdentity,
    required bool Function() stillCurrent,
    required api.MessageInst wire,
    required CloudSyncReceivedArchiveLiveContext liveContext,
    required int localChatId,
    required int Function() persistMessage,
    required Future<CloudSyncReceivedArchiveSourceBinding> Function()
    sealNative,
    required DateTime Function() clock,
  }) async {
    await validateCurrentIdentity();
    final existing = journal.findProtectedSource(
      messageGuid: wire.id,
      localChatId: localChatId,
      currentAuth: capturedIdentity,
    );
    final source = existing ?? await sealNative();
    if (existing == null && !source.isSeed) {
      throw StateError('cloud_sync_received_archive_protected_source_invalid');
    }
    await validateCurrentIdentity();
    return journal.saveReceivedCapture(
      wire: wire,
      liveContext: liveContext,
      localChatId: localChatId,
      persistMessage: persistMessage,
      source: source,
      capturedAuth: capturedIdentity,
      stillCurrent: stillCurrent,
      now: clock().toUtc(),
    );
  }

  /// Bounded worker/restart handoff. Original encrypted seed remains durable
  /// until a descriptor is adopted; afterward failed commits retain that exact
  /// lease. There is no restage after a lost commit response and no IDS call.
  Future<CloudSyncReceivedArchiveSourceBinding> materialize({
    required int intentId,
    required Future<CloudSyncReceivedArchiveSourceBinding> Function(
      CloudSyncReceivedArchiveSourceBinding seed,
    )
    stageSeedNative,
  }) {
    if (_transport.protectedPageLeaseRecoveryIdentity !=
            _identity.protectedStoreIdentity ||
        _transport is! CloudProtectedLocalLifecycleTransport) {
      throw StateError(
        'cloud_sync_received_archive_store_exclusion_unavailable',
      );
    }
    return (_transport as CloudProtectedLocalLifecycleTransport)
        .runLocalProtectedStoreExclusive(() async {
          await _validateCurrent();
          var source = _journal.readProtectedSource(
            intentId: intentId,
            currentAuth: _identity,
          );
          if (source.isSeed) {
            final seed = source;
            final staged = await stageSeedNative(seed);
            var owned = false;
            try {
              await _validateCurrent();
              _journal.adoptMaterializedSource(
                intentId: intentId,
                seed: seed,
                staged: staged,
                currentAuth: _identity,
                stillCurrent: _stillCurrent,
              );
              owned = true;
              source = staged;
            } catch (_) {
              if (!owned && !staged.isSeed) {
                try {
                  await _transport.rollbackProtectedPageLease(
                    staged.leaseReference,
                  );
                } catch (_) {}
              }
              rethrow;
            }
          }
          await _transport.commitProtectedPageLease(source.leaseReference, {
            source.protectedReference,
          });
          await _validateCurrent();
          if (_journal
                  .readProtectedSource(
                    intentId: intentId,
                    currentAuth: _identity,
                  )
                  .encode() !=
              source.encode()) {
            throw StateError('cloud_sync_received_archive_intent_changed');
          }
          _journal.markSourceMaterialized(
            intentId: intentId,
            source: source,
            currentAuth: _identity,
            stillCurrent: _stillCurrent,
          );
          return source;
        });
  }

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
          if (source.isSeed) {
            throw StateError(
              'cloud_sync_received_archive_seed_requires_materialization',
            );
          }
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
