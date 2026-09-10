import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_local_send_source_binding.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_transport.dart';
import 'cloudkit_operation_interlock.dart';

/// Local-only handoff of the exact attachment source, before IDS submission.
/// Never holds exclusion during IDS or a CloudKit network request. A busy
/// cross-process sync lock rejects this preparation without submitting IDS;
/// the caller retains the pending message for retry, not a false confirmation.
///
/// The journal must already own this fresh submission. Once adoption succeeds,
/// commit failures retain that exact lease for restart recovery. A retry must
/// recommit the original source, never manufacture a replacement descriptor.
final class CloudSyncLocalSendSourceStaging {
  const CloudSyncLocalSendSourceStaging({
    required this._journal,
    required this._authFence,
    required CloudSyncNativeAuthSnapshot capturedAuth,
    required this._stillCurrent,
    required this._exclusion,
    required this._transport,
  }) : _auth = capturedAuth;

  final CloudSyncLocalSendJournal _journal;
  final CloudSyncLocalSendAuthFence _authFence;
  final CloudSyncNativeAuthSnapshot _auth;
  final bool Function() _stillCurrent;
  final CloudKitOperationExclusion _exclusion;
  final CloudProtectedPageLeaseTransport _transport;

  Future<CloudSyncLocalSendSourceBinding> prepare({
    required CloudSyncLocalSendIdentity identity,
    required Future<CloudSyncLocalSendSourceBinding> Function() stage,
    required Future<bool> Function() validateWire,
  }) {
    if (!identity.isAttachment) {
      throw StateError('cloud_sync_local_send_protected_source_invalid');
    }
    if (_transport.protectedPageLeaseRecoveryIdentity != _auth.protectedStoreIdentity) {
      throw StateError('cloud_sync_local_send_protected_source_changed');
    }
    return _exclusion.runExclusive(
      kind: CloudKitOperationKind.v2ReadWrite,
      action: () => _transport.runProtectedStoreExclusive(() async {
        Future<void> validate() async {
          _authFence.requireCurrentBinding(_auth);
          if (!await validateWire()) {
            throw StateError('cloud_sync_local_send_source_changed');
          }
          _authFence.requireCurrentBinding(_auth);
        }

        await validate();
        final existing = await _authFence.run(
          () => _journal.readSubmissionProtectedSource(
            identity: identity,
            currentAuth: _auth,
          ),
        );
        if (existing != null) {
          // Idempotent even when the last process died after native commit.
          await _transport.commitProtectedPageLease(existing.leaseReference, {
            existing.protectedReference,
          });
          await validate();
          await _authFence.run(() {
            final current = _journal.readSubmissionProtectedSource(
              identity: identity,
              currentAuth: _auth,
            );
            if (current?.encode() != existing.encode()) {
              throw StateError(
                'cloud_sync_local_send_protected_source_changed',
              );
            }
          });
          return existing;
        }

        final source = await stage();
        var adopted = false;
        try {
          source.requireOrigin(
            accountFingerprint: _auth.accountFingerprint,
            messageGuidHash: identity.guidHash,
            sourceSha256: identity.sourceSha256,
            protectedStoreIdentity: _auth.protectedStoreIdentity,
          );
          await validate();
          await _authFence.run(() {
            _journal.adoptProtectedSource(
              identity: identity,
              source: source,
              capturedAuth: _auth,
              stillCurrent: _stillCurrent,
              now: DateTime.now().toUtc(),
            );
            // Synchronous with the ObjectBox transaction, before any await.
            adopted = true;
          });
          await _transport.commitProtectedPageLease(source.leaseReference, {
            source.protectedReference,
          });
          await validate();
          await _authFence.run(() {
            final current = _journal.readSubmissionProtectedSource(
              identity: identity,
              currentAuth: _auth,
            );
            if (current?.encode() != source.encode()) {
              throw StateError(
                'cloud_sync_local_send_protected_source_changed',
              );
            }
          });
          return source;
        } catch (_) {
          if (!adopted) {
            try {
              await _transport.rollbackProtectedPageLease(
                source.leaseReference,
              );
            } catch (_) {
              // Keep the original failure. Recovery will roll back an orphan;
              // never delete files directly or roll back an adopted source.
            }
          }
          rethrow;
        }
      }),
    );
  }
}
