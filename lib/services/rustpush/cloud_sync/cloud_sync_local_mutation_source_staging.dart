import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_local_mutation_identity.dart';
import 'cloud_sync_local_mutation_journal.dart';
import 'cloud_sync_local_mutation_source_binding.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_transport.dart';
import 'cloudkit_operation_interlock.dart';

/// Adopt, commit and reopen the original edit/unsend before claiming one send.
/// Holds exclusion for local protected storage only. The caller sends the
/// returned wire after preparation releases exclusion, never inside it.
/// [submitConfirmed] composes that handoff with positive receipt retention.
/// A crash after claiming remains ambiguous and cannot re-enter this method.
final class CloudSyncLocalMutationSourceStaging {
  const CloudSyncLocalMutationSourceStaging({
    required this._journal,
    required this._authFence,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required this._stillCurrent,
    required this._exclusion,
    required this._transport,
  }) : _auth = capturedAuth;

  final CloudSyncLocalMutationJournal _journal;
  final CloudSyncLocalSendAuthFence _authFence;
  final CloudSyncNativeAuthSnapshot _auth;
  final bool Function() _stillCurrent;
  final CloudKitOperationExclusion _exclusion;
  final CloudProtectedPageLeaseTransport _transport;

  /// Recover display values from the retained source and acceptance receipt.
  /// This never prepares/sends a new mutation, acknowledges receipts, or
  /// touches CloudKit. Both native source reads and the atomic local commit
  /// remain inside the original protected-store and authentication exclusions.
  Future<void> reflectConfirmed({
    required int intentId,
    required CloudSyncLocalMutationSourceBinding source,
    required api.CloudSyncNativeSendReceipt receipt,
    required Future<api.MessageInst> Function(
      CloudSyncLocalMutationSourceBinding,
    )
    restore,
    CloudSyncNativeReceiptReplayBinding? replayBinding,
  }) async {
    if (_transport.protectedPageLeaseRecoveryIdentity !=
            _auth.protectedStoreIdentity ||
        source.accountFingerprint != _auth.accountFingerprint ||
        source.protectedStoreIdentity != _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_local_mutation_protected_source_changed');
    }
    await _exclusion.runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () => _transport.runProtectedStoreExclusive(() async {
        _authFence.requireCurrentBinding(_auth);
        final original = await restore(source);
        await _authFence.run(
          () => _journal.reflectSourceConfirmed(
            intentId: intentId,
            committedSource: source,
            original: original,
            receipt: receipt,
            currentAuth: _auth,
            stillCurrent: _stillCurrent,
            replayBinding: replayBinding,
            now: DateTime.now().toUtc(),
          ),
        );
      }),
    );
  }

  /// One positive-acceptance submission composed with its durable journal.
  /// No timeout, retry, CK update or receipt acknowledgement occurs here.
  /// In particular, a successful send followed by a fence/storage failure is
  /// reconciled from its native receipt, never by calling this method again.
  Future<int> submitConfirmed({
    required int localMessageId,
    required CloudSyncLocalMutationIdentity identity,
    required Future<CloudSyncLocalMutationSourceBinding> Function() stage,
    required Future<api.MessageInst> Function(
      CloudSyncLocalMutationSourceBinding,
    )
    restore,
    required Future<api.CloudSyncNativeSendReceipt> Function(
      api.MessageInst,
      CloudSyncLocalMutationSourceBinding,
    )
    send,
    void Function()? validateBeforeSend,
  }) async {
    final prepared = await prepareSubmission(
      localMessageId: localMessageId,
      identity: identity,
      stage: stage,
      restore: restore,
    );
    await _authFence.run(() {
      _journal.requireClaimedSubmission(
        intentId: prepared.intentId,
        committedSource: prepared.source,
        capturedAuth: _auth,
        stillCurrent: _stillCurrent,
      );
      validateBeforeSend?.call();
    });
    // Both exclusions have been released before any network operation.
    final receipt = await send(prepared.wire, prepared.source);
    await _authFence.run(
      () => _journal.recordNativeReceipt(
        intentId: prepared.intentId,
        receipt: receipt,
        capturedAuth: _auth,
        stillCurrent: _stillCurrent,
        now: DateTime.now().toUtc(),
      ),
    );
    return prepared.intentId;
  }

  Future<
    ({
      int intentId,
      CloudSyncLocalMutationSourceBinding source,
      api.MessageInst wire,
    })
  >
  prepareSubmission({
    required int localMessageId,
    required CloudSyncLocalMutationIdentity identity,
    required Future<CloudSyncLocalMutationSourceBinding> Function() stage,
    required Future<api.MessageInst> Function(
      CloudSyncLocalMutationSourceBinding,
    )
    restore,
  }) async {
    if (_transport.protectedPageLeaseRecoveryIdentity !=
        _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_local_mutation_protected_source_changed');
    }
    return _exclusion.runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () => _transport.runProtectedStoreExclusive(() async {
        _authFence.requireCurrentBinding(_auth);
        final snapshot = await _authFence.run(
          () => _journal.captureTargetSnapshot(
            localMessageId: localMessageId,
            identity: identity,
          ),
        );
        final existing = await _authFence.run(
          () => _journal.readStagedSource(
            localMessageId: localMessageId,
            identity: identity,
            currentAuth: _auth,
            stillCurrent: _stillCurrent,
          ),
        );
        final CloudSyncLocalMutationSourceBinding source;
        final int intentId;
        if (existing != null) {
          source = existing.source;
          intentId = existing.intentId;
        } else {
          source = await stage();
          var adopted = false;
          try {
            source.requireOrigin(
              accountFingerprint: _auth.accountFingerprint,
              protectedStoreIdentity: _auth.protectedStoreIdentity,
              mutationGuidHash: identity.guidHash,
              targetGuidHash: identity.targetGuidHash,
              targetPart: identity.targetPart,
              sourceSha256: identity.sourceSha256,
            );
            intentId = await _authFence.run(() {
              final id = _journal.adoptSource(
                localMessageId: localMessageId,
                identity: identity,
                targetSnapshotSha256: snapshot,
                source: source,
                capturedAuth: _auth,
                stillCurrent: _stillCurrent,
                now: DateTime.now().toUtc(),
              );
              adopted = true; // No suspension between adoption and ownership.
              return id;
            });
          } catch (_) {
            if (!adopted) {
              try {
                await _transport.rollbackProtectedPageLease(
                  source.leaseReference,
                );
              } catch (_) {
                // Orphan recovery owns cleanup; preserve the original error.
              }
            }
            rethrow;
          }
        }
        // Native commit is idempotent. Never replace/rollback an adopted source,
        // including on commit, restore, auth or target-validation failure.
        await _transport.commitProtectedPageLease(source.leaseReference, {
          source.protectedReference,
        });
        _authFence.requireCurrentBinding(_auth);
        final restored = await restore(source);
        final restoredIdentity = CloudSyncLocalMutationIdentity.captureWire(
          restored,
          expectedSourceSha256: identity.sourceSha256,
        );
        if (restoredIdentity?.guidHash != identity.guidHash ||
            restoredIdentity?.targetGuidHash != identity.targetGuidHash ||
            restoredIdentity?.targetPart != identity.targetPart ||
            restoredIdentity?.kind != identity.kind) {
          throw StateError(
            'cloud_sync_local_mutation_protected_source_changed',
          );
        }
        await _authFence.run(
          () => _journal.beginSubmission(
            intentId: intentId,
            committedSource: source,
            capturedAuth: _auth,
            stillCurrent: _stillCurrent,
            now: DateTime.now().toUtc(),
          ),
        );
        return (intentId: intentId, source: source, wire: restored);
      }),
    );
  }
}
