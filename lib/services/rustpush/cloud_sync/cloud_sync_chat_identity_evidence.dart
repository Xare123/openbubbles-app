import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/cloud_sync_chat_identity.dart'
    as native;

import 'cloud_sync_chat_identity_read_set.dart';
import 'cloud_sync_local_send_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_origin.dart';
import 'cloud_sync_outbound_staging.dart';

/// This edge must call the native observer with the exact staged candidate.
/// A diagnostic comparison of an unstaged Chat cannot satisfy this contract.
typedef CloudSyncStagedChatIdentityObserver =
    Future<native.CloudSyncChatIdentityResult> Function(
      CloudSyncChatIdentityReadSet readSet,
      CloudSyncChatIdentitySource source,
      CloudSyncProtectedOutboundStageData stage,
      CloudSyncOutboundChatOrigin origin,
    );

/// In-memory coverage of retained saved Chat identities, NOT write authority.
/// Not serializable, transferable between stores, or reusable after admission
/// changes the checkpoint revision. Lease/submission must obtain fresh evidence.
final class CloudSyncChatIdentityEvidence {
  CloudSyncChatIdentityEvidence._({
    required CloudSyncChatIdentityReadSet readSet,
    required CloudSyncOutboundChatOrigin origin,
    required this._stage,
    required this._auth,
    required this._authFence,
  }) : _readSet = readSet,
       _originBinding = origin.binding(readSet.generation);

  final CloudSyncChatIdentityReadSet _readSet;
  final String _originBinding;
  final CloudSyncProtectedOutboundStageData _stage;
  final CloudSyncNativeAuthSnapshot _auth;
  final CloudSyncLocalSendAuthFence _authFence;
  static final _nativeDigest = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _payloadDigest = RegExp(r'^[a-f0-9]{64}$');
  static final _reference = RegExp(r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$');
  static final _lease = RegExp(r'^obcs2\.lease\.[a-f0-9]{32}$');

  /// All sources are awaited serially under the caller's controlled native
  /// read-auth scope. No exception, unknown shape or partial set means disjoint.
  static Future<CloudSyncChatIdentityEvidence?> observe({
    required Store store,
    required CloudSyncOutboundChatOrigin origin,
    required CloudSyncProtectedOutboundStageData stage,
    required CloudSyncNativeAuthSnapshot auth,
    required CloudSyncLocalSendAuthFence authFence,
    required CloudSyncStagedChatIdentityObserver observer,
  }) async {
    authFence.requireCurrentBinding(auth);
    if (origin.scope.accountFingerprint != auth.accountFingerprint ||
        !_nativeDigest.hasMatch(stage.logicalEntityKeyHash) ||
        !_nativeDigest.hasMatch(stage.serverRecordIdHash) ||
        !_payloadDigest.hasMatch(stage.payloadSha256) ||
        !_reference.hasMatch(stage.protectedEnvelopeReference) ||
        !_lease.hasMatch(stage.leaseReference)) {
      throw StateError('cloud_sync_chat_identity_candidate_invalid');
    }
    final readSet = await authFence.run(() {
      origin.requireUnchanged(store);
      return CloudSyncChatIdentityReadSet.capture(store, origin.scope);
    }, accountFingerprint: origin.scope.accountFingerprint);
    if (readSet.retainedSaves.isEmpty) return null;
    String? candidateBinding;
    String? stagedBinding;
    final sourceBindings = <String>{};
    void validate() {
      authFence.requireCurrentBinding(auth);
      origin.requireUnchanged(store);
      readSet.requireUnchanged(store);
    }

    for (final source in readSet.retainedSaves) {
      await authFence.run(validate);
      final result = await observer(readSet, source, stage, origin);
      await authFence.run(validate);
      if (result.failureCode != null ||
          result.comparison !=
              native.CloudSyncChatIdentityComparison.disjoint ||
          result.nativeSessionId != auth.nativeSessionId ||
          !_nativeDigest.hasMatch(result.candidateBindingHash ?? '') ||
          !_nativeDigest.hasMatch(result.stagedCandidateBindingHash ?? '') ||
          !_nativeDigest.hasMatch(result.sourceBindingHash ?? '') ||
          !sourceBindings.add(result.sourceBindingHash!) ||
          (candidateBinding != null &&
              candidateBinding != result.candidateBindingHash) ||
          (stagedBinding != null &&
              stagedBinding != result.stagedCandidateBindingHash)) {
        throw StateError('cloud_sync_chat_identity_not_disjoint');
      }
      candidateBinding = result.candidateBindingHash;
      stagedBinding = result.stagedCandidateBindingHash;
    }
    // No intervening await between this last validation and issuing coverage.
    return authFence.run(() {
      validate();
      return CloudSyncChatIdentityEvidence._(
        readSet: readSet,
        origin: origin,
        stage: stage,
        auth: auth,
        authFence: authFence,
      );
    });
  }

  /// Call inside the actual admission, lease or submission transaction. A
  /// future network sender must still perform its independent authorization.
  void requireMatches({
    required Store store,
    required CloudSyncOutboundChatOrigin origin,
    required String logicalEntityKeyHash,
    required String? serverRecordIdHash,
    required String? payloadSha256,
    required String? protectedEnvelopeReference,
    required String? leaseReference,
  }) {
    _authFence.requireCurrentBinding(_auth);
    if (origin.scope != _readSet.scope ||
        origin.binding(_readSet.generation) != _originBinding ||
        logicalEntityKeyHash != _stage.logicalEntityKeyHash ||
        serverRecordIdHash != _stage.serverRecordIdHash ||
        payloadSha256 != _stage.payloadSha256 ||
        protectedEnvelopeReference != _stage.protectedEnvelopeReference ||
        leaseReference != _stage.leaseReference) {
      throw StateError('cloud_sync_chat_identity_candidate_changed');
    }
    origin.requireUnchanged(store);
    _readSet.requireUnchanged(store);
  }

  void requireOperation({
    required Store store,
    required CloudSyncOutboundChatOrigin origin,
    required CloudOutboxOperation operation,
  }) {
    if (operation.scope != origin.scope ||
        operation.checkpointGeneration != _readSet.generation ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundChatPayloadVersion) {
      throw StateError('cloud_sync_chat_identity_candidate_changed');
    }
    requireMatches(
      store: store,
      origin: origin,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: operation.serverRecordIdHash,
      payloadSha256: operation.payloadSha256,
      protectedEnvelopeReference: operation.encryptedPayloadReference,
      leaseReference: operation.protectedLeaseReference,
    );
  }

  @override
  String toString() => 'CloudSyncChatIdentityEvidence(redacted)';
}
