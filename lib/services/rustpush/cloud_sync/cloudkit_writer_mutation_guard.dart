// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:objectbox/objectbox.dart';
import 'package:path/path.dart' as path;
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;

import 'cloud_operation_identity.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_production_sampler_adapter.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';

typedef ActiveCloudKitClientReader = Object? Function();

final RegExp _cloudKitWriterSha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _cloudKitWriterNativeDigestPattern = RegExp(
  r'^[A-Za-z0-9_-]{43}$',
);
final RegExp _cloudKitWriterProtectedReferencePattern = RegExp(
  r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
);
final RegExp _cloudKitWriterLeaseReferencePattern = RegExp(
  r'^obcs2\.lease\.[0-9a-f]{32}$',
);
const int _cloudKitWriterMaximumRetryAfterSeconds = 7 * 24 * 60 * 60;

/// Content-free digest shared by mutation admission and later exact readback.
/// Mutable lifecycle fields are deliberately excluded so the same durable
/// create binds while it moves from leased to unknownOutcome.
String cloudKitWriterReconciliationBindingSha256(
  CloudOutboxOperation operation, {
  String? appleRequestUuid,
  String? appleOperationUuid,
}) => sha256
    .convert(
      utf8.encode(
        jsonEncode(<Object?>[
          1,
          operation.scope.storageKey,
          operation.operationId,
          operation.logicalEntityKeyHash,
          operation.action.name,
          operation.payloadVersion,
          operation.mutationRevision,
          operation.checkpointGeneration,
          operation.encryptedPayloadReference,
          operation.payloadSha256,
          operation.serverRecordIdHash,
          operation.protectedLeaseReference,
          appleRequestUuid ?? operation.appleRequestUuid,
          appleOperationUuid ?? operation.appleOperationUuid,
        ]),
      ),
    )
    .toString();

/// Narrow capability used by the protected V2 transport at the exact native
/// mutation boundary.
abstract interface class CloudKitWriterMutationRunner {
  void requireClear();

  void markActiveMutationUnknown();

  Future<void> requireReconciliationAllowed({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required CloudOutboxOperation operation,
  });

  Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required CloudOutboxOperation operation,
  });

  Future<T> runAuthorized<T>({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required String? preparedHandleBindingSha256,
    String? reconciliationBindingSha256,
    required void Function() requireAdmission,
    required Future<T> Function(CloudKitWriterMutationCapability capability)
    action,
  });
}

/// Exact native readback seam owned by the writer guard. Production
/// composition supplies the generated FRB binding; tests may inject a fake.
/// No caller can submit a Dart-constructed proof to release the mutation fence.
abstract interface class CloudKitWriterReconciliationBinding {
  Future<frb_api.CloudSyncOutboundReconcileResult> reconcileMessageCreate({
    required Object cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required frb_api.CloudSyncPreparedMessageCreateInput input,
  });
}

/// Non-constructible, single-use native mutation capability.
///
/// The raw random token exists only for the lifetime of one guarded action.
/// Durable state and diagnostics retain only its SHA-256 digest.
final class CloudKitWriterMutationCapability {
  CloudKitWriterMutationCapability._(String token) : _token = token;

  String? _token;

  bool get consumed => _token == null;

  String consumeForNative() {
    final token = _token;
    if (token == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_capability_consumed',
      );
    }
    _token = null;
    return token;
  }

  @override
  String toString() => 'CloudKitWriterMutationCapability(redacted)';
}

final class _ActiveCloudKitMutation {
  _ActiveCloudKitMutation({required this.permit});

  final CloudKitWriterPermit permit;
  bool forcedUnknown = false;
}

/// Binds one remote mutation to the active native identity and a durable
/// single-writer permit.
///
/// This guard must run inside [CloudKitOperationInterlock]. Authority
/// transitions use the same interlock, so a transition cannot overtake a
/// mutation after its permit is issued. The post-action checks turn any
/// impossible identity/epoch race into an unknown outcome instead of allowing
/// the caller to record an unverified success.
final class CloudKitWriterMutationGuard
    implements CloudKitWriterMutationRunner {
  CloudKitWriterMutationGuard({
    required Store store,
    required ActiveCloudKitClientReader readActiveClient,
    required String privateStorageDirectory,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    CloudKitWriterReconciliationBinding? reconciliationBinding,
    DateTime Function()? clock,
  }) : _readActiveClient = readActiveClient,
       _privateStorageDirectory = privateStorageDirectory,
       _clock = clock ?? DateTime.now,
       _nativeAuthBinding =
           nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding(),
       _reconciliationBinding = reconciliationBinding,
       _authority = ObjectBoxCloudKitWriterAuthority(store: store) {
    if (privateStorageDirectory.isEmpty) {
      throw ArgumentError.value(
        privateStorageDirectory,
        'privateStorageDirectory',
        'must not be empty',
      );
    }
  }

  CloudKitWriterMutationGuard.forTest({
    required Store store,
    required ActiveCloudKitClientReader readActiveClient,
    required String privateStorageDirectory,
    required CloudKitWriterOwnershipDecision buildDecision,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    CloudKitWriterReconciliationBinding? reconciliationBinding,
    DateTime Function()? clock,
  }) : _readActiveClient = readActiveClient,
       _privateStorageDirectory = privateStorageDirectory,
       _clock = clock ?? DateTime.now,
       _nativeAuthBinding =
           nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding(),
       _reconciliationBinding = reconciliationBinding,
       _authority = ObjectBoxCloudKitWriterAuthority.forTest(
         store: store,
         buildDecision: buildDecision,
       ) {
    if (privateStorageDirectory.isEmpty) {
      throw ArgumentError.value(
        privateStorageDirectory,
        'privateStorageDirectory',
        'must not be empty',
      );
    }
  }

  final ActiveCloudKitClientReader _readActiveClient;
  final String _privateStorageDirectory;
  final CloudSyncNativeAuthBinding _nativeAuthBinding;
  final CloudKitWriterReconciliationBinding? _reconciliationBinding;
  final ObjectBoxCloudKitWriterAuthority _authority;
  final DateTime Function() _clock;

  @override
  void requireClear() => _PersistentCloudKitMutationFence(
    privateStorageDirectory: _privateStorageDirectory,
  ).requireClear();

  Future<T> run<T>({
    required CloudKitWriterOwner owner,
    required Future<T> Function() action,
  }) async {
    final expectedClient = _readActiveClient();
    if (expectedClient == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_active_client_missing',
      );
    }
    return runAuthorized(
      owner: owner,
      expectedClient: expectedClient,
      preparedHandleBindingSha256: null,
      reconciliationBindingSha256: null,
      requireAdmission: () {},
      action: (_) => action(),
    );
  }

  @override
  void markActiveMutationUnknown() {
    final active = _activeMutation;
    if (active == null) return;
    active.forcedUnknown = true;
    _markMutationUnknownFailClosed(active.permit);
  }

  @override
  Future<void> requireReconciliationAllowed({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required CloudOutboxOperation operation,
  }) async {
    _requireReconciliationOperation(owner, operation);
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    final client = _readActiveClient();
    if (client == null || !identical(client, expectedClient)) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_client_mismatch',
      );
    }
    final identity = await _capture(client);
    if (!identical(client, _readActiveClient()) ||
        identity.accountFingerprint != operation.scope.accountFingerprint) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_identity_mismatch',
      );
    }

    final writerScope = _writerScopeFor(operation);
    final authority = _authority.read(writerScope);
    final fence = _PersistentCloudKitMutationFence(
      privateStorageDirectory: _privateStorageDirectory,
    ).readForReconciliation();
    if (fence == null) {
      _requireStableReconciledAuthority(authority, owner);
      return;
    }
    _requireMatchingReconciliationFence(
      fence,
      operation: operation,
      owner: owner,
      identity: identity,
    );
    final stateAllowed =
        authority != null &&
        authority.owner == owner &&
        authority.targetOwner == CloudKitWriterOwner.none &&
        authority.transitionIdHash == null &&
        ((authority.state == CloudKitWriterAuthorityState.stable &&
                (authority.epoch == fence.epoch ||
                    authority.epoch == fence.epoch + 2)) ||
            (authority.state == CloudKitWriterAuthorityState.mutationUnknown &&
                authority.epoch == fence.epoch + 1));
    if (!stateAllowed) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_reconciliation_precondition_failed',
      );
    }
  }

  @override
  Future<CloudUnknownOutcomeResolution> reconcileUnknownOutcome({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required CloudOutboxOperation operation,
  }) async {
    await requireReconciliationAllowed(
      owner: owner,
      expectedClient: expectedClient,
      operation: operation,
    );
    final identity = await _capture(expectedClient);
    if (!identical(expectedClient, _readActiveClient()) ||
        identity.accountFingerprint != operation.scope.accountFingerprint ||
        identity.protectedStoreIdentity.isEmpty) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_identity_mismatch',
      );
    }
    final binding = _reconciliationBinding;
    if (binding == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_binding_missing',
      );
    }
    final result = await binding.reconcileMessageCreate(
      cloudMessagesClient: expectedClient,
      storageDirectory: _privateStorageDirectory,
      expectedAccountFingerprint: identity.accountFingerprint,
      expectedProtectedStoreIdentity: identity.protectedStoreIdentity,
      requestUuid: operation.appleRequestUuid!,
      input: frb_api.CloudSyncPreparedMessageCreateInput(
        localOperationId: operation.operationId,
        logicalEntityKeyHash: operation.logicalEntityKeyHash,
        protectedLeaseReference: operation.protectedLeaseReference!,
        protectedPayloadReference: operation.encryptedPayloadReference!,
        payloadSha256: operation.payloadSha256!,
        protectedServerRecordReference: operation.encryptedPayloadReference!,
        serverRecordIdHash: operation.serverRecordIdHash!,
        appleOperationUuid: operation.appleOperationUuid!,
      ),
    );
    CloudKitOperationInterlock.requireActive(CloudKitOperationKind.v2ReadWrite);
    if (!identical(expectedClient, _readActiveClient())) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_identity_mismatch',
      );
    }
    final disposition = _requireReconciliationDisposition(
      result,
      expectedProtectedReference: operation.encryptedPayloadReference!,
    );
    switch (disposition) {
      case frb_api.CloudSyncOutboundReconcileDisposition.committed:
        final receipt = _requireCommittedCreateReceipt(result, operation);
        await _completeReconciliationAfterExactReadback(
          owner: owner,
          expectedClient: expectedClient,
          operation: operation,
        );
        return CloudUnknownOutcomeResolution.committed(createReceipt: receipt);
      case frb_api.CloudSyncOutboundReconcileDisposition.notApplied:
        await _completeReconciliationAfterExactReadback(
          owner: owner,
          expectedClient: expectedClient,
          operation: operation,
        );
        return const CloudUnknownOutcomeResolution.notApplied();
      case frb_api.CloudSyncOutboundReconcileDisposition.diverged:
        return const CloudUnknownOutcomeResolution.quarantined(
          failureCategory: CloudFailureCategory.conflict,
        );
      case frb_api.CloudSyncOutboundReconcileDisposition.unresolved:
        return CloudUnknownOutcomeResolution.unresolved(
          failureCategory: _mapReconciliationFailureClass(result.failureClass),
          retryAfter: _boundedReconciliationRetryAfter(
            result.retryAfterSeconds,
          ),
        );
    }
  }

  /// Binds a committed readback to an exact create receipt before the mutation
  /// fence may be cleared. A missing, malformed, or mismatched receipt fails
  /// closed as an unknown outcome so the fence stays armed for a later retry.
  /// All failures use content-free safe codes and carry no raw identifiers.
  CloudOutboxCreateReceipt _requireCommittedCreateReceipt(
    frb_api.CloudSyncOutboundReconcileResult result,
    CloudOutboxOperation operation,
  ) {
    final serverRecordIdHash = result.serverRecordIdHash;
    final etagHash = result.etagHash;
    if (serverRecordIdHash == null ||
        etagHash == null ||
        !_cloudKitWriterNativeDigestPattern.hasMatch(serverRecordIdHash) ||
        !_cloudKitWriterNativeDigestPattern.hasMatch(etagHash) ||
        !_cloudKitWriterNativeDigestPattern.hasMatch(
          operation.logicalEntityKeyHash,
        )) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_receipt_invalid',
      );
    }
    if (serverRecordIdHash != operation.serverRecordIdHash) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_receipt_mismatch',
      );
    }
    return CloudOutboxCreateReceipt(
      operationId: operation.operationId,
      logicalEntityKeyHash: operation.logicalEntityKeyHash,
      serverRecordIdHash: serverRecordIdHash,
      etagHash: etagHash,
    );
  }

  Future<void> _completeReconciliationAfterExactReadback({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required CloudOutboxOperation operation,
  }) async {
    await requireReconciliationAllowed(
      owner: owner,
      expectedClient: expectedClient,
      operation: operation,
    );
    final identity = await _capture(expectedClient);
    if (!identical(expectedClient, _readActiveClient()) ||
        identity.accountFingerprint != operation.scope.accountFingerprint) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_reconciliation_identity_mismatch',
      );
    }
    // No await occurs after the second exact fence read. Authority is
    // stabilized before deletion, so either crash point remains replay-safe.
    final persistentFence = _PersistentCloudKitMutationFence(
      privateStorageDirectory: _privateStorageDirectory,
    );
    final fence = persistentFence.readForReconciliation();
    final writerScope = _writerScopeFor(operation);
    if (fence == null) {
      _requireStableReconciledAuthority(_authority.read(writerScope), owner);
      return;
    }
    _requireMatchingReconciliationFence(
      fence,
      operation: operation,
      owner: owner,
      identity: identity,
    );
    _authority.reconcileMutationFence(
      writerScope,
      owner: owner,
      fencedEpoch: fence.epoch,
      now: _clock(),
    );
    persistentFence.disarmReconciled(fence);
  }

  void _requireReconciliationOperation(
    CloudKitWriterOwner owner,
    CloudOutboxOperation operation,
  ) {
    if (owner != CloudKitWriterOwner.v2 ||
        operation.scope.container != 'com.apple.messages.cloud' ||
        operation.scope.database != 'private' ||
        operation.scope.streamKind != CloudSyncStreamKind.messages ||
        operation.scope.schemaVersion != 2 ||
        operation.scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        operation.status != CloudOutboxStatus.unknownOutcome ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        operation.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: operation.scope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              payloadVersion: operation.payloadVersion,
            ) ||
        !_cloudKitWriterNativeDigestPattern.hasMatch(
          operation.logicalEntityKeyHash,
        ) ||
        operation.appleRequestUuid == null ||
        operation.appleOperationUuid == null ||
        operation.encryptedPayloadReference == null ||
        !_cloudKitWriterProtectedReferencePattern.hasMatch(
          operation.encryptedPayloadReference!,
        ) ||
        operation.payloadSha256 == null ||
        !_cloudKitWriterSha256Pattern.hasMatch(operation.payloadSha256!) ||
        operation.serverRecordIdHash == null ||
        !_cloudKitWriterNativeDigestPattern.hasMatch(
          operation.serverRecordIdHash!,
        ) ||
        operation.protectedLeaseReference == null ||
        !_cloudKitWriterLeaseReferencePattern.hasMatch(
          operation.protectedLeaseReference!,
        )) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_reconciliation_operation_invalid',
      );
    }
  }

  frb_api.CloudSyncOutboundReconcileDisposition
  _requireReconciliationDisposition(
    frb_api.CloudSyncOutboundReconcileResult result, {
    required String expectedProtectedReference,
  }) {
    if (result.failure case final failure?) {
      if (result.disposition != null ||
          result.protectedProofReference != null ||
          result.failureClass != null ||
          result.retryAfterSeconds != null) {
        throw _reconciliationLocalFailure(
          'cloud_sync_outbound_reconcile_envelope_invalid',
        );
      }
      throw _mapReconciliationFailure(failure);
    }
    final disposition = result.disposition;
    if (disposition == null) {
      throw _reconciliationLocalFailure(
        'cloud_sync_outbound_reconcile_envelope_invalid',
      );
    }
    final decisive =
        disposition != frb_api.CloudSyncOutboundReconcileDisposition.unresolved;
    if ((decisive &&
            result.protectedProofReference != expectedProtectedReference) ||
        (!decisive && result.protectedProofReference != null) ||
        (disposition !=
                frb_api.CloudSyncOutboundReconcileDisposition.unresolved &&
            result.retryAfterSeconds != null) ||
        ((disposition ==
                    frb_api.CloudSyncOutboundReconcileDisposition.committed ||
                disposition ==
                    frb_api.CloudSyncOutboundReconcileDisposition.notApplied) &&
            result.failureClass != null) ||
        (disposition ==
                frb_api.CloudSyncOutboundReconcileDisposition.diverged &&
            result.failureClass !=
                frb_api.CloudSyncOutboundFailureClass.conflict)) {
      throw _reconciliationLocalFailure(
        'cloud_sync_outbound_reconcile_envelope_invalid',
      );
    }
    return disposition;
  }

  CloudSyncFailure _mapReconciliationFailure(
    frb_api.CloudSyncOutboundSafeCode failure,
  ) {
    final category = switch (failure) {
      frb_api.CloudSyncOutboundSafeCode.invalidScope ||
      frb_api.CloudSyncOutboundSafeCode.nativeAuthUnavailable =>
        CloudFailureCategory.authorization,
      frb_api.CloudSyncOutboundSafeCode.protectedStorage =>
        CloudFailureCategory.localStorage,
      frb_api.CloudSyncOutboundSafeCode.nativePrepareFailed =>
        CloudFailureCategory.server,
      frb_api.CloudSyncOutboundSafeCode.alreadyConsumed ||
      frb_api.CloudSyncOutboundSafeCode.correlationMismatch ||
      frb_api.CloudSyncOutboundSafeCode.mutationCapabilityInvalid =>
        CloudFailureCategory.unknown,
      _ => CloudFailureCategory.cancelled,
    };
    return CloudSyncFailure(
      category: category,
      safeCode:
          'cloud_sync_outbound_${switch (failure) {
            frb_api.CloudSyncOutboundSafeCode.invalidScope => 'invalid_scope',
            frb_api.CloudSyncOutboundSafeCode.invalidRequest => 'invalid_request',
            frb_api.CloudSyncOutboundSafeCode.unsupportedMessage => 'unsupported_message',
            frb_api.CloudSyncOutboundSafeCode.malformedMessage => 'malformed_message',
            frb_api.CloudSyncOutboundSafeCode.oversizedMessage => 'oversized_message',
            frb_api.CloudSyncOutboundSafeCode.protectedStorage => 'protected_storage',
            frb_api.CloudSyncOutboundSafeCode.bindingMismatch => 'binding_mismatch',
            frb_api.CloudSyncOutboundSafeCode.nativeAuthUnavailable => 'native_auth_unavailable',
            frb_api.CloudSyncOutboundSafeCode.nativePrepareFailed => 'native_prepare_failed',
            frb_api.CloudSyncOutboundSafeCode.alreadyConsumed => 'already_consumed',
            frb_api.CloudSyncOutboundSafeCode.correlationMismatch => 'correlation_mismatch',
            frb_api.CloudSyncOutboundSafeCode.mutationCapabilityInvalid => 'mutation_capability_invalid',
          }}',
    );
  }

  CloudFailureCategory _mapReconciliationFailureClass(
    frb_api.CloudSyncOutboundFailureClass? failure,
  ) => switch (failure) {
    frb_api.CloudSyncOutboundFailureClass.throttled =>
      CloudFailureCategory.throttled,
    frb_api.CloudSyncOutboundFailureClass.transientServer =>
      CloudFailureCategory.server,
    frb_api.CloudSyncOutboundFailureClass.authentication =>
      CloudFailureCategory.authorization,
    frb_api.CloudSyncOutboundFailureClass.conflict =>
      CloudFailureCategory.conflict,
    frb_api.CloudSyncOutboundFailureClass.resetRequired =>
      CloudFailureCategory.pcsUnavailable,
    frb_api.CloudSyncOutboundFailureClass.permanent ||
    frb_api.CloudSyncOutboundFailureClass.unknown ||
    null => CloudFailureCategory.unknown,
  };

  Duration? _boundedReconciliationRetryAfter(BigInt? seconds) {
    if (seconds == null) return null;
    if (seconds < BigInt.zero) {
      throw _reconciliationLocalFailure(
        'cloud_sync_outbound_retry_after_invalid',
      );
    }
    final maximum = BigInt.from(_cloudKitWriterMaximumRetryAfterSeconds);
    final bounded = seconds > maximum ? maximum : seconds;
    return Duration(seconds: bounded.toInt());
  }

  CloudSyncFailure _reconciliationLocalFailure(String safeCode) =>
      CloudSyncFailure(
        category: CloudFailureCategory.localStorage,
        safeCode: safeCode,
      );

  CloudKitWriterScope _writerScopeFor(CloudOutboxOperation operation) =>
      CloudKitWriterScope(
        accountFingerprint: operation.scope.accountFingerprint,
        container: operation.scope.container,
        database: operation.scope.database,
      );

  void _requireStableReconciledAuthority(
    CloudKitWriterAuthoritySnapshot? authority,
    CloudKitWriterOwner owner,
  ) {
    if (authority == null ||
        authority.owner != owner ||
        authority.state != CloudKitWriterAuthorityState.stable ||
        authority.targetOwner != CloudKitWriterOwner.none ||
        authority.transitionIdHash != null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_reconciliation_precondition_failed',
      );
    }
  }

  void _requireMatchingReconciliationFence(
    _CloudKitMutationFenceRecord fence, {
    required CloudOutboxOperation operation,
    required CloudKitWriterOwner owner,
    required CloudSyncNativeAuthMetadata identity,
  }) {
    final writerScope = _writerScopeFor(operation);
    final binding = cloudKitWriterReconciliationBindingSha256(operation);
    if (fence.scope != writerScope ||
        fence.owner != owner ||
        fence.reconciliationBindingSha256 != binding ||
        fence.protectedStoreIdentity != identity.protectedStoreIdentity ||
        fence.scope.accountFingerprint != identity.accountFingerprint) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_reconciliation_fence_mismatch',
      );
    }
  }

  _ActiveCloudKitMutation? _activeMutation;

  @override
  Future<T> runAuthorized<T>({
    required CloudKitWriterOwner owner,
    required Object expectedClient,
    required String? preparedHandleBindingSha256,
    String? reconciliationBindingSha256,
    required void Function() requireAdmission,
    required Future<T> Function(CloudKitWriterMutationCapability capability)
    action,
  }) async {
    final operationKind = switch (owner) {
      CloudKitWriterOwner.legacy => CloudKitOperationKind.legacyReadWrite,
      CloudKitWriterOwner.v2 => CloudKitOperationKind.v2ReadWrite,
      CloudKitWriterOwner.none => throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_owner_invalid',
      ),
    };
    CloudKitOperationInterlock.requireActive(operationKind);
    requireAdmission();
    requireClear();
    final client = _readActiveClient();
    if (client == null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_active_client_missing',
      );
    }
    if (!identical(client, expectedClient)) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_transport_client_mismatch',
      );
    }
    if (owner == CloudKitWriterOwner.v2 &&
        (preparedHandleBindingSha256 == null ||
            !_cloudKitWriterSha256Pattern.hasMatch(
              preparedHandleBindingSha256,
            ) ||
            reconciliationBindingSha256 == null ||
            !_cloudKitWriterSha256Pattern.hasMatch(
              reconciliationBindingSha256,
            ))) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_prepared_handle_binding_invalid',
      );
    }
    final before = await _capture(client);
    // A timeout can poison admission while native identity capture is pending.
    // Recheck before arming the fence; after this point no await occurs until
    // [_activeMutation] is installed, so late timeout poisoning is observable.
    requireAdmission();
    if (!identical(client, _readActiveClient())) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_identity_changed_before_mutation',
      );
    }
    final scope = CloudKitWriterScope(
      accountFingerprint: before.accountFingerprint,
    );
    final permit = _authority.issuePermit(scope, expectedOwner: owner);
    if (_activeMutation != null) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_already_active',
      );
    }
    final capabilityToken = _newCapabilityToken();
    final capabilityDigest = sha256
        .convert(utf8.encode(capabilityToken))
        .toString();
    final capability = CloudKitWriterMutationCapability._(capabilityToken);
    final persistentFence = _PersistentCloudKitMutationFence(
      privateStorageDirectory: _privateStorageDirectory,
    );
    persistentFence.arm(
      permit,
      protectedStoreIdentity: before.protectedStoreIdentity,
      capabilityDigest: capabilityDigest,
      preparedHandleBindingSha256:
          preparedHandleBindingSha256 ?? capabilityDigest,
      reconciliationBindingSha256:
          reconciliationBindingSha256 ?? capabilityDigest,
    );
    final active = _ActiveCloudKitMutation(permit: permit);
    _activeMutation = active;
    try {
      late final T value;
      try {
        CloudKitOperationInterlock.requireActive(operationKind);
        value = await action(capability);
        CloudKitOperationInterlock.requireActive(operationKind);
        if (active.forcedUnknown ||
            (owner == CloudKitWriterOwner.v2 && !capability.consumed)) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_mutation_outcome_unknown',
          );
        }
      } catch (_) {
        // Once the remote action starts, an exception cannot prove that Apple
        // rejected the request. Revoke the durable writer epoch and require
        // explicit reconciliation instead of allowing any automatic retry.
        active.forcedUnknown = true;
        _markMutationUnknownFailClosed(permit);
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_outcome_unknown',
        );
      }

      try {
        if (!identical(client, _readActiveClient())) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_active_client_replaced',
          );
        }
        final after = await _capture(client);
        if (after.accountFingerprint != before.accountFingerprint ||
            after.protectedStoreIdentity != before.protectedStoreIdentity) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_active_identity_changed',
          );
        }
        _authority.verifyPermit(permit);
        if (active.forcedUnknown) {
          throw const CloudKitWriterAuthorityFailure(
            'cloudkit_writer_mutation_outcome_unknown',
          );
        }
      } catch (_) {
        // The network action already returned. A failed postcondition cannot
        // prove whether CloudKit committed it, so never expose it as a normal
        // retryable failure.
        active.forcedUnknown = true;
        _markMutationUnknownFailClosed(permit);
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_outcome_unknown',
        );
      }
      try {
        persistentFence.disarm(
          permit,
          protectedStoreIdentity: before.protectedStoreIdentity,
          capabilityDigest: capabilityDigest,
          preparedHandleBindingSha256:
              preparedHandleBindingSha256 ?? capabilityDigest,
          reconciliationBindingSha256:
              reconciliationBindingSha256 ?? capabilityDigest,
        );
      } catch (_) {
        active.forcedUnknown = true;
        _markMutationUnknownFailClosed(permit);
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_release_failed',
        );
      }
      return value;
    } finally {
      if (identical(_activeMutation, active)) {
        _activeMutation = null;
      }
    }
  }

  String _newCapabilityToken() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<CloudSyncNativeAuthMetadata> _capture(Object client) =>
      _nativeAuthBinding.capture(
        cloudMessagesClient: client,
        privateStorageDirectory: _privateStorageDirectory,
      );

  void _markMutationUnknownFailClosed(CloudKitWriterPermit permit) {
    try {
      _authority.markMutationUnknown(permit, now: _clock());
    } catch (_) {
      // Suppress only a transition that durable readback proves already
      // invalidated this permit. The write-ahead filesystem fence remains in
      // place in either case and blocks every later process until explicit
      // reconciliation.
      CloudKitWriterAuthoritySnapshot? current;
      try {
        current = _authority.read(permit.scope);
      } catch (_) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_authority_fence_failed',
        );
      }
      final alreadyFenced =
          current == null ||
          current.state != CloudKitWriterAuthorityState.stable ||
          current.owner != permit.owner ||
          current.epoch != permit.epoch;
      if (!alreadyFenced) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_authority_fence_failed',
        );
      }
    }
  }
}

/// A content-free write-ahead fence independent of ObjectBox.
///
/// The file is armed before the network action starts and removed only after
/// the action and all identity/authority postconditions succeed. A crash or an
/// ObjectBox write failure therefore leaves a durable startup poison instead
/// of silently restoring a replay-capable stable authority.
final class _PersistentCloudKitMutationFence {
  _PersistentCloudKitMutationFence({required String privateStorageDirectory})
    : _file = File(
        path.join(
          privateStorageDirectory,
          '.openbubbles-cloudkit-writer-mutation-v1.fence',
        ),
      );

  final File _file;

  void requireClear() {
    if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_reconciliation_required',
      );
    }
  }

  void arm(
    CloudKitWriterPermit permit, {
    required String protectedStoreIdentity,
    required String capabilityDigest,
    required String preparedHandleBindingSha256,
    required String reconciliationBindingSha256,
  }) {
    requireClear();

    final encoded = _encode(
      permit,
      protectedStoreIdentity: protectedStoreIdentity,
      capabilityDigest: capabilityDigest,
      preparedHandleBindingSha256: preparedHandleBindingSha256,
      reconciliationBindingSha256: reconciliationBindingSha256,
    );
    RandomAccessFile? handle;
    try {
      // Exclusive creation makes a crash between creation and payload flush
      // fail closed: the empty file is still a durable reconciliation fence.
      _file.createSync(exclusive: true);
      handle = _file.openSync(mode: FileMode.write);
      handle.writeStringSync(encoded, encoding: utf8);
      handle.flushSync();
    } on FileSystemException {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_arm_failed',
      );
    } finally {
      try {
        handle?.closeSync();
      } on FileSystemException {
        // Exact readback below remains authoritative.
      }
    }

    try {
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          _file.readAsStringSync(encoding: utf8) != encoded) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_arm_failed',
        );
      }
    } on FileSystemException {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_arm_failed',
      );
    }
  }

  void disarm(
    CloudKitWriterPermit permit, {
    required String protectedStoreIdentity,
    required String capabilityDigest,
    required String preparedHandleBindingSha256,
    required String reconciliationBindingSha256,
  }) {
    final encoded = _encode(
      permit,
      protectedStoreIdentity: protectedStoreIdentity,
      capabilityDigest: capabilityDigest,
      preparedHandleBindingSha256: preparedHandleBindingSha256,
      reconciliationBindingSha256: reconciliationBindingSha256,
    );
    try {
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          _file.readAsStringSync(encoding: utf8) != encoded) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_corrupt',
        );
      }
      _file.deleteSync();
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_release_failed',
        );
      }
    } on CloudKitWriterAuthorityFailure {
      rethrow;
    } on FileSystemException {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_release_failed',
      );
    }
  }

  _CloudKitMutationFenceRecord? readForReconciliation() {
    try {
      final type = FileSystemEntity.typeSync(_file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.file) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_corrupt',
        );
      }
      final encoded = _file.readAsStringSync(encoding: utf8);
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic> ||
          decoded.length != _CloudKitMutationFenceRecord.fieldNames.length ||
          !decoded.keys.toSet().containsAll(
            _CloudKitMutationFenceRecord.fieldNames,
          )) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_corrupt',
        );
      }
      final version = decoded['version'];
      final accountFingerprint = decoded['accountFingerprint'];
      final container = decoded['container'];
      final database = decoded['database'];
      final epoch = decoded['epoch'];
      final ownerName = decoded['owner'];
      final capabilitySha256 = decoded['capabilitySha256'];
      final preparedHandleBindingSha256 =
          decoded['preparedHandleBindingSha256'];
      final reconciliationBindingSha256 =
          decoded['reconciliationBindingSha256'];
      final protectedStoreIdentity = decoded['protectedStoreIdentity'];
      final owner = switch (ownerName) {
        'legacy' => CloudKitWriterOwner.legacy,
        'v2' => CloudKitWriterOwner.v2,
        _ => null,
      };
      if (version != 3 ||
          accountFingerprint is! String ||
          container is! String ||
          database is! String ||
          epoch is! int ||
          epoch < 0 ||
          owner == null ||
          capabilitySha256 is! String ||
          !_cloudKitWriterSha256Pattern.hasMatch(capabilitySha256) ||
          preparedHandleBindingSha256 is! String ||
          !_cloudKitWriterSha256Pattern.hasMatch(preparedHandleBindingSha256) ||
          reconciliationBindingSha256 is! String ||
          !_cloudKitWriterSha256Pattern.hasMatch(reconciliationBindingSha256) ||
          protectedStoreIdentity is! String ||
          protectedStoreIdentity.isEmpty ||
          protectedStoreIdentity.length > 256) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_corrupt',
        );
      }
      final scope = CloudKitWriterScope(
        accountFingerprint: accountFingerprint,
        container: container,
        database: database,
      );
      return _CloudKitMutationFenceRecord(
        encoded: encoded,
        scope: scope,
        owner: owner,
        epoch: epoch,
        protectedStoreIdentity: protectedStoreIdentity,
        reconciliationBindingSha256: reconciliationBindingSha256,
      );
    } on CloudKitWriterAuthorityFailure {
      rethrow;
    } catch (_) {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_corrupt',
      );
    }
  }

  void disarmReconciled(_CloudKitMutationFenceRecord fence) {
    try {
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          _file.readAsStringSync(encoding: utf8) != fence.encoded) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_corrupt',
        );
      }
      _file.deleteSync();
      if (FileSystemEntity.typeSync(_file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_mutation_fence_release_failed',
        );
      }
    } on CloudKitWriterAuthorityFailure {
      rethrow;
    } on FileSystemException {
      throw const CloudKitWriterAuthorityFailure(
        'cloudkit_writer_mutation_fence_release_failed',
      );
    }
  }

  String _encode(
    CloudKitWriterPermit permit, {
    required String protectedStoreIdentity,
    required String capabilityDigest,
    required String preparedHandleBindingSha256,
    required String reconciliationBindingSha256,
  }) => jsonEncode(<String, Object>{
    'accountFingerprint': permit.scope.accountFingerprint,
    'capabilitySha256': capabilityDigest,
    'container': permit.scope.container,
    'database': permit.scope.database,
    'epoch': permit.epoch,
    'owner': permit.owner.name,
    'preparedHandleBindingSha256': preparedHandleBindingSha256,
    'protectedStoreIdentity': protectedStoreIdentity,
    'reconciliationBindingSha256': reconciliationBindingSha256,
    'version': 3,
  });
}

final class _CloudKitMutationFenceRecord {
  const _CloudKitMutationFenceRecord({
    required this.encoded,
    required this.scope,
    required this.owner,
    required this.epoch,
    required this.protectedStoreIdentity,
    required this.reconciliationBindingSha256,
  });

  static const fieldNames = <String>{
    'accountFingerprint',
    'capabilitySha256',
    'container',
    'database',
    'epoch',
    'owner',
    'preparedHandleBindingSha256',
    'protectedStoreIdentity',
    'reconciliationBindingSha256',
    'version',
  };

  final String encoded;
  final CloudKitWriterScope scope;
  final CloudKitWriterOwner owner;
  final int epoch;
  final String protectedStoreIdentity;
  final String reconciliationBindingSha256;
}
