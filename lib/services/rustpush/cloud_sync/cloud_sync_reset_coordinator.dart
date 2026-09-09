import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cloud_sync_manual_semantic_pull_sampler.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_store.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

typedef CloudSyncResetCoordinatorClock = DateTime Function();

/// Completes the local half of an authenticated CloudKit reset response.
///
/// The semantic reader must release its read interlock and native-writer pause
/// before invoking this coordinator. The coordinator then reacquires the same
/// profile under [CloudKitOperationKind.destructiveReset], pauses the native
/// writer again, and advances the local generation exactly once.
final class CloudSyncResetCoordinator {
  CloudSyncResetCoordinator({
    required this._authority,
    required this._interlock,
    required this._store,
    required this._readAuthSnapshot,
    required this._readPreflight,
    required this._nativeWriterPause,
    CloudSyncResetCoordinatorClock? clock,
  }) : _clock = clock ?? DateTime.now;

  final ObjectBoxCloudKitWriterAuthority _authority;
  final CloudKitOperationExclusion _interlock;
  final CloudSyncStore _store;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudSyncShadowPreflightReader _readPreflight;
  final CloudSyncNativeWriterPause _nativeWriterPause;
  final CloudSyncResetCoordinatorClock _clock;

  Future<void> coordinate({
    required CloudSyncNativeAuthSnapshot expectedAuth,
    required CloudSyncResetRequiredContext context,
  }) {
    _requireBoundContext(expectedAuth, context);
    return _interlock.runExclusive(
      kind: CloudKitOperationKind.destructiveReset,
      action: () async {
        await _requireReadyAndSameAuth(expectedAuth);
        await _runUnderNativePause(expectedAuth, () async {
          final writerScope = _writerScope(expectedAuth);
          final snapshot = _authority.read(writerScope);
          if (snapshot == null) {
            throw const CloudSyncResetCoordinatorFailure(
              'cloudkit_reset_writer_authority_missing',
            );
          }
          if (snapshot.owner != CloudKitWriterOwner.v2) {
            throw const CloudSyncResetCoordinatorFailure(
              'cloudkit_reset_v2_writer_owner_required',
            );
          }

          late final CloudKitResetFence fence;
          if (snapshot.state == CloudKitWriterAuthorityState.stable) {
            final request = CloudSyncResetRebootstrapRequest(
              scope: context.scope,
              transitionIdHash: _transitionIdHash(context),
              activeIdentityFingerprint: expectedAuth.accountFingerprint,
              expectedGeneration: context.expectedGeneration,
              protectedRemoteStateProofReference:
                  context.protectedRemoteStateProofReference,
            );
            final permit = _authority.issuePermit(
              writerScope,
              expectedOwner: CloudKitWriterOwner.v2,
            );
            fence = _authority.prepareReset(
              permit,
              request: request,
              now: _now(),
            );
          } else if (snapshot.state ==
                  CloudKitWriterAuthorityState.resetPrepared ||
              snapshot.state == CloudKitWriterAuthorityState.resetUnknown) {
            final recovered = _authority.recoverResetFence(
              writerScope,
              syncScope: context.scope,
            );
            if (recovered == null ||
                recovered.expectedGeneration != context.expectedGeneration ||
                recovered.protectedRemoteStateProofReference !=
                    context.protectedRemoteStateProofReference) {
              throw const CloudSyncResetCoordinatorFailure(
                'cloudkit_reset_signal_mismatch',
              );
            }
            fence = recovered;
          } else {
            throw const CloudSyncResetCoordinatorFailure(
              'cloudkit_reset_writer_authority_unresolved',
            );
          }

          await _finishPreparedReset(expectedAuth, fence);
        });
      },
    );
  }

  /// Recovers a reset that may have committed its local generation before the
  /// process durably returned writer authority to stable.
  ///
  /// The candidate set is intentionally bounded to the three semantic zones.
  Future<bool> recoverPending({
    required CloudSyncNativeAuthSnapshot expectedAuth,
    required Iterable<CloudSyncScope> candidateScopes,
  }) {
    final candidates = candidateScopes.toList(growable: false);
    if (candidates.length !=
        CloudSyncManualSemanticPullSampler.zones.length) {
      throw const CloudSyncResetCoordinatorFailure(
        'cloudkit_reset_recovery_scope_set_invalid',
      );
    }
    for (final scope in candidates) {
      _requireBoundScope(expectedAuth, scope);
    }
    if (candidates.map((scope) => scope.zone).toSet().length !=
        CloudSyncManualSemanticPullSampler.zones.length) {
      throw const CloudSyncResetCoordinatorFailure(
        'cloudkit_reset_recovery_scope_set_invalid',
      );
    }
    return _interlock.runExclusive(
      kind: CloudKitOperationKind.destructiveReset,
      action: () async {
        await _requireReadyAndSameAuth(
          expectedAuth,
          requireSettledOutbox: false,
        );
        final writerScope = _writerScope(expectedAuth);
        final snapshot = _authority.read(writerScope);
        if (snapshot == null ||
            snapshot.state == CloudKitWriterAuthorityState.stable) {
          return false;
        }
        if (snapshot.owner != CloudKitWriterOwner.v2 ||
            (snapshot.state != CloudKitWriterAuthorityState.resetPrepared &&
                snapshot.state != CloudKitWriterAuthorityState.resetUnknown)) {
          throw const CloudSyncResetCoordinatorFailure(
            'cloudkit_reset_writer_authority_unresolved',
          );
        }
        return _runUnderNativePause(expectedAuth, () async {
          CloudKitResetFence? recovered;
          for (final scope in candidates) {
            try {
              final candidate = _authority.recoverResetFence(
                writerScope,
                syncScope: scope,
              );
              if (candidate != null) {
                if (recovered != null) {
                  throw const CloudSyncResetCoordinatorFailure(
                    'cloudkit_reset_recovery_scope_ambiguous',
                  );
                }
                recovered = candidate;
              }
            } on CloudKitWriterAuthorityFailure catch (error) {
              if (error.safeCode != 'cloudkit_writer_reset_scope_mismatch') {
                rethrow;
              }
            }
          }
          if (recovered == null) {
            throw const CloudSyncResetCoordinatorFailure(
              'cloudkit_reset_recovery_scope_missing',
            );
          }
          await _finishPreparedReset(expectedAuth, recovered);
          return true;
        }, requireSettledOutbox: false);
      },
    );
  }

  Future<T> _runUnderNativePause<T>(
    CloudSyncNativeAuthSnapshot expectedAuth,
    Future<T> Function() action, {
    bool requireSettledOutbox = true,
  }) async {
    Object? pauseToken;
    var pauseAcquired = false;
    try {
      try {
        pauseToken = await _nativeWriterPause.pause();
        pauseAcquired = true;
      } on CloudSyncNativeWriterPauseUncertain {
        _interlock.poisonUntilProcessRestart();
        rethrow;
      }
      await _requireReadyAndSameAuth(
        expectedAuth,
        requireSettledOutbox: requireSettledOutbox,
      );
      CloudKitOperationInterlock.throwIfActiveFenceLost();
      return await action();
    } finally {
      if (pauseAcquired) {
        try {
          await _nativeWriterPause.resume(pauseToken!);
        } catch (_) {
          _interlock.poisonUntilProcessRestart();
          throw const CloudSyncNativeWriterPauseUncertain();
        }
      }
    }
  }

  Future<void> _finishPreparedReset(
    CloudSyncNativeAuthSnapshot expectedAuth,
    CloudKitResetFence fence,
  ) async {
    CloudSyncResetCompletionProof proof;
    final checkpoint = await _store.readCheckpoint(fence.syncScope);
    if (checkpoint.generation == fence.expectedGeneration) {
      final request = CloudSyncResetRebootstrapRequest(
        scope: fence.syncScope,
        transitionIdHash: fence.transitionIdHash,
        activeIdentityFingerprint: expectedAuth.accountFingerprint,
        expectedGeneration: fence.expectedGeneration,
        protectedRemoteStateProofReference:
            fence.protectedRemoteStateProofReference,
      );
      try {
        proof = await _store.rebootstrapAfterReset(request, now: _now());
      } catch (_) {
        _markUnknownIfPrepared(fence);
        rethrow;
      }
    } else if (checkpoint.generation == fence.expectedGeneration + 1) {
      proof = CloudSyncResetCompletionProof(
        scope: fence.syncScope,
        transitionIdHash: fence.transitionIdHash,
        activeIdentityFingerprint: expectedAuth.accountFingerprint,
        previousGeneration: fence.expectedGeneration,
        generation: checkpoint.generation,
        protectedRemoteStateProofReference:
            fence.protectedRemoteStateProofReference,
      );
    } else {
      _markUnknownIfPrepared(fence);
      throw const CloudSyncResetCoordinatorFailure(
        'cloudkit_reset_generation_unresolved',
      );
    }

    try {
      await _requireReadyAndSameAuth(expectedAuth, requireSettledOutbox: false);
    } catch (_) {
      _markUnknownIfPrepared(fence);
      rethrow;
    }
    CloudKitOperationInterlock.throwIfActiveFenceLost();
    try {
      final state = _authority.read(fence.scope)?.state;
      if (state == CloudKitWriterAuthorityState.resetPrepared) {
        _authority.completeReset(fence, proof: proof, now: _now());
      } else if (state == CloudKitWriterAuthorityState.resetUnknown) {
        _authority.reconcileResetUnknown(fence, proof: proof, now: _now());
      } else {
        throw const CloudSyncResetCoordinatorFailure(
          'cloudkit_reset_writer_authority_unresolved',
        );
      }
    } catch (_) {
      _markUnknownIfPrepared(fence);
      rethrow;
    }
  }

  void _markUnknownIfPrepared(CloudKitResetFence fence) {
    final state = _authority.read(fence.scope)?.state;
    if (state == CloudKitWriterAuthorityState.resetPrepared) {
      _authority.markResetUnknown(fence, now: _now());
    }
  }

  Future<void> _requireReadyAndSameAuth(
    CloudSyncNativeAuthSnapshot expectedAuth, {
    bool requireSettledOutbox = true,
  }) async {
    _validatePreflight(
      await _readPreflight(),
      requireSettledOutbox: requireSettledOutbox,
    );
    final current = await _readAuthSnapshot();
    final mismatch = expectedAuth.identityMismatchSafeCode(current);
    if (mismatch != null) {
      throw CloudSyncResetCoordinatorFailure(mismatch);
    }
  }

  void _validatePreflight(
    CloudSyncShadowPreflightState state, {
    required bool requireSettledOutbox,
  }) {
    if (!state.platformSupported) {
      throw const CloudSyncResetCoordinatorFailure('unsupported_platform');
    }
    if (!state.uiIsolate) {
      throw const CloudSyncResetCoordinatorFailure('not_ui_isolate');
    }
    if (!state.rustPushReady) {
      throw const CloudSyncResetCoordinatorFailure('rustpush_not_ready');
    }
    if (!state.objectBoxReady) {
      throw const CloudSyncResetCoordinatorFailure('objectbox_not_ready');
    }
    if (!state.privateStorageExists) {
      throw const CloudSyncResetCoordinatorFailure('storage_unavailable');
    }
    if (state.logoutActive) {
      throw const CloudSyncResetCoordinatorFailure('logout_active');
    }
    if (state.legacySyncEnabled || state.legacySyncActive) {
      throw const CloudSyncResetCoordinatorFailure('legacy_sync_active');
    }
    if (state.coordinatorLeaseActive) {
      throw const CloudSyncResetCoordinatorFailure('coordinator_active');
    }
    if (requireSettledOutbox && !state.allowsSemanticRead) {
      throw const CloudSyncResetCoordinatorFailure('outbox_not_settled');
    }
    if (!state.protectorSentinelValid) {
      throw const CloudSyncResetCoordinatorFailure('protector_unavailable');
    }
  }

  void _requireBoundContext(
    CloudSyncNativeAuthSnapshot expectedAuth,
    CloudSyncResetRequiredContext context,
  ) => _requireBoundScope(expectedAuth, context.scope);

  void _requireBoundScope(
    CloudSyncNativeAuthSnapshot expectedAuth,
    CloudSyncScope scope,
  ) {
    if (scope.accountFingerprint != expectedAuth.accountFingerprint ||
        scope.container != CloudSyncManualSemanticPullSampler.container ||
        scope.database != CloudSyncManualSemanticPullSampler.database ||
        !CloudSyncManualSemanticPullSampler.zones.contains(scope.zone) ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic) {
      throw const CloudSyncResetCoordinatorFailure(
        'cloudkit_reset_scope_invalid',
      );
    }
  }

  CloudKitWriterScope _writerScope(CloudSyncNativeAuthSnapshot auth) =>
      CloudKitWriterScope(
        accountFingerprint: auth.accountFingerprint,
        container: CloudSyncManualSemanticPullSampler.container,
        database: CloudSyncManualSemanticPullSampler.database,
      );

  String _transitionIdHash(CloudSyncResetRequiredContext context) => sha256
      .convert(
        utf8.encode(
          'cloudkit-reset-transition-v1\u001f${context.scope.storageKey}'
          '\u001f${context.expectedGeneration}'
          '\u001f${context.protectedRemoteStateProofReference}',
        ),
      )
      .toString();

  DateTime _now() => _clock().toUtc();
}

final class CloudSyncResetCoordinatorFailure
    implements Exception, CloudSyncSafeCodeFailure {
  const CloudSyncResetCoordinatorFailure(this.safeCode);

  @override
  final String safeCode;

  @override
  String toString() => 'CloudSyncResetCoordinatorFailure($safeCode)';
}
