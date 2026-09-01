// ignore_for_file: prefer_initializing_formals

import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;

import 'cloud_operation_identity.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_ownership.dart';

typedef CloudSyncOutboundCanarySessionFactory =
    Future<CloudSyncOutboundCanarySession> Function(
      CloudSyncNativeAuthSnapshot authSnapshot,
      CloudSyncScope scope,
      CloudSyncOutboundCanarySessionKind kind,
      CloudOutboxOperation? expectedOperation,
    );

enum CloudSyncOutboundCanarySessionKind {
  freshWrite,
  pendingRecovery,
  unknownRecovery,
  confirmedReplay,
}

typedef CloudSyncOutboundCanaryOutboxReader =
    Future<List<CloudOutboxOperation>> Function(CloudSyncScope scope);

typedef CloudSyncOutboundCanaryAdmissionRevalidator =
    Future<CloudSyncOutboundCanaryAdmission?> Function();

/// A freshly revalidated, in-memory message admission.
///
/// Neither contents nor routing are exposed through diagnostics. The callback
/// which creates this value runs under the final cross-process exclusion.
final class CloudSyncOutboundCanaryAdmission {
  const CloudSyncOutboundCanaryAdmission({
    required this.message,
    required this.createdAt,
  });

  final frb_api.CloudMessage message;
  final DateTime createdAt;

  @override
  String toString() => 'CloudSyncOutboundCanaryAdmission(redacted)';
}

/// Common, read-only lifecycle surface for one outbound Canary session.
///
/// Mutation, reconciliation, and replay capabilities are split into disjoint
/// interfaces below. An unknown-outcome recovery session therefore cannot be
/// cast to an admission or write-submission surface.
abstract interface class CloudSyncOutboundCanarySession {
  Future<List<CloudOutboxOperation>> readOutbox();

  Future<void> quiesce();
}

abstract interface class CloudSyncOutboundCanaryFlushSession
    implements CloudSyncOutboundCanarySession {
  Future<CloudSyncRunResult> flushOneBatch();
}

abstract interface class CloudSyncOutboundCanaryWriteSession
    implements CloudSyncOutboundCanaryFlushSession {
  Future<CloudOutboxOperation> admitMessage({
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  });
}

abstract interface class CloudSyncOutboundCanaryUnknownRecoverySession
    implements CloudSyncOutboundCanarySession {
  /// Performs one exact protected readback and persists only a confirmed,
  /// proven-not-applied, or still-unknown transition. It cannot submit a save.
  Future<CloudSyncRunResult> reconcileUnknownOutcome({
    required CloudOutboxOperation operation,
  });
}

abstract interface class CloudSyncOutboundCanaryReplaySession
    implements CloudSyncOutboundCanarySession {
  /// Performs the exact remote digest readback for an already-confirmed
  /// create. Implementations must not prepare, consume, or submit a write.
  Future<CloudSyncConfirmedReplayProof> verifyConfirmedNoSave({
    required CloudOutboxOperation operation,
  });

  /// After exact no-save replay, clears the receipt's exact durable adoption
  /// marker and then releases only that retained local protected receipt. This
  /// must not contact CloudKit.
  Future<void> finalizeConfirmedReplayProof({
    required CloudOutboxOperation operation,
    required CloudSyncConfirmedReplayProof proof,
  });
}

/// Opaque, single-use evidence that the user completed the first confirmation.
///
/// The selected message is retained only in memory and is intentionally absent
/// from diagnostics and [toString]. A second explicit call is required before
/// any durable admission or CloudKit mutation can occur.
final class CloudSyncOutboundCanaryConfirmation {
  CloudSyncOutboundCanaryConfirmation._({
    this.revalidateAdmission,
    this.selectedCreatedAt,
    this.armedOperation,
    required this.authSnapshot,
    required this.expiresAt,
    required this.recovery,
    required this.replayVerification,
  });

  final CloudSyncOutboundCanaryAdmissionRevalidator? revalidateAdmission;
  final DateTime? selectedCreatedAt;
  final CloudOutboxOperation? armedOperation;
  final CloudSyncNativeAuthSnapshot authSnapshot;
  final DateTime expiresAt;
  final bool recovery;
  final bool replayVerification;
  bool consumed = false;

  @override
  String toString() => 'CloudSyncOutboundCanaryConfirmation(redacted)';
}

/// Content-free result for one developer-confirmed outbound text canary.
final class CloudSyncOutboundCanaryReport {
  const CloudSyncOutboundCanaryReport({
    required this.timestampUtc,
    required this.status,
    required this.confirmed,
    required this.quarantined,
    required this.retried,
    required this.outboxStatus,
    required this.recovery,
    required this.replayVerification,
  });

  final DateTime timestampUtc;
  final CloudSyncRunStatus status;
  final int confirmed;
  final int quarantined;
  final int retried;
  final CloudOutboxStatus outboxStatus;
  final bool recovery;
  final bool replayVerification;

  bool get terminal =>
      outboxStatus == CloudOutboxStatus.confirmed ||
      outboxStatus == CloudOutboxStatus.quarantined;

  Map<String, Object> toJson() => <String, Object>{
    'mode': 'manual-outbound-text-canary',
    'timestampUtc': timestampUtc.toIso8601String(),
    'status': status.name,
    'confirmed': confirmed,
    'quarantined': quarantined,
    'retried': retried,
    'outboxStatus': outboxStatus.name,
    'recovery': recovery,
    'replayVerification': replayVerification,
  };

  @override
  String toString() =>
      'CloudSyncOutboundCanaryReport(status=${status.name}, redacted)';
}

/// Developer-only, one-message, create-only CloudKit V2 write canary.
///
/// It is compile-time disabled by default, requires the exclusive V2 writer
/// build, requires two separate confirmation calls, admits exactly one already
/// existing local message, performs no pull or semantic apply, and runs at most
/// one outbox batch. CloudKit and local deletions are never enabled here.
final class CloudSyncManualOutboundCanary {
  CloudSyncManualOutboundCanary({
    required CloudSyncShadowPreflightReader readPreflight,
    required CloudSyncNativeAuthSnapshotReader readAuthSnapshot,
    required CloudSyncOutboundCanaryOutboxReader readOutboxForConfirmation,
    required CloudSyncOutboundCanarySessionFactory createSession,
    required CloudKitOperationExclusion writerExclusion,
    bool? compileGateOverrideForTest,
    bool? v2WriterOverrideForTest,
    DateTime Function()? clock,
  }) : _readPreflight = readPreflight,
       _readAuthSnapshot = readAuthSnapshot,
       _readOutboxForConfirmation = readOutboxForConfirmation,
       _createSession = createSession,
       _writerExclusion = writerExclusion,
       _enabled =
           compileGateOverrideForTest ??
           CloudSyncDevGate.manualOutboundCanaryEnabled,
       _v2WriterEnabled =
           v2WriterOverrideForTest ??
           CloudKitWriterOwnership.v2MutationsEnabled,
       _clock = clock ?? DateTime.now;

  static const container = 'com.apple.messages.cloud';
  static const database = 'private';
  static const zone = 'messageManateeZone';
  static const confirmationLifetime = Duration(minutes: 5);
  static final RegExp _nativeDigestPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _contentDigestPattern = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _protectedReferencePattern = RegExp(
    r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
  );
  static final RegExp _leaseReferencePattern = RegExp(
    r'^obcs2\.lease\.[0-9a-f]{32}$',
  );

  final CloudSyncShadowPreflightReader _readPreflight;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudSyncOutboundCanaryOutboxReader _readOutboxForConfirmation;
  final CloudSyncOutboundCanarySessionFactory _createSession;
  final CloudKitOperationExclusion _writerExclusion;
  final bool _enabled;
  final bool _v2WriterEnabled;
  final DateTime Function() _clock;

  CloudSyncOutboundCanaryConfirmation? _armedConfirmation;
  bool _active = false;

  bool get isActive => _active;

  /// First confirmation. This performs only fail-closed local/auth checks and
  /// retains the selected existing message in memory for at most five minutes.
  Future<CloudSyncOutboundCanaryConfirmation> armConfirmed({
    required CloudSyncOutboundCanaryAdmissionRevalidator revalidateAdmission,
    required DateTime selectedCreatedAt,
  }) async {
    _requireEnabled();
    if (_active) throw StateError('cloud_sync_outbound_canary_active');
    if (_armedConfirmation != null) {
      throw StateError('cloud_sync_outbound_canary_already_armed');
    }
    if (selectedCreatedAt.isAfter(_clock().toUtc())) {
      throw StateError('cloud_sync_outbound_canary_message_time_invalid');
    }
    _validatePreflight(await _readPreflight(), expectedOutboxCount: 0);
    final auth = await _readAuthSnapshot();
    if (auth == null) throw StateError('account_unavailable');
    final confirmation = CloudSyncOutboundCanaryConfirmation._(
      revalidateAdmission: revalidateAdmission,
      selectedCreatedAt: selectedCreatedAt.toUtc(),
      authSnapshot: auth,
      expiresAt: _clock().toUtc().add(confirmationLifetime),
      recovery: false,
      replayVerification: false,
    );
    _armedConfirmation = confirmation;
    return confirmation;
  }

  /// First confirmation for a process-death or interrupted-run recovery.
  /// No new message is staged or admitted. The second confirmation may only
  /// inspect and advance the one exact durable create already in the outbox.
  Future<CloudSyncOutboundCanaryConfirmation> armRecoveryConfirmed() async {
    return _armExistingConfirmed(requireConfirmed: false, allowConfirmed: true);
  }

  /// First confirmation for an immediate, confirmed-only replay check.
  /// The durable operation must already be terminal-confirmed before the
  /// transport runs, and the run must report zero additional mutations.
  Future<CloudSyncOutboundCanaryConfirmation> armConfirmedReplay() async {
    return _armExistingConfirmed(requireConfirmed: true, allowConfirmed: true);
  }

  Future<CloudSyncOutboundCanaryConfirmation> _armExistingConfirmed({
    required bool requireConfirmed,
    required bool allowConfirmed,
  }) async {
    _requireEnabled();
    if (_active) throw StateError('cloud_sync_outbound_canary_active');
    if (_armedConfirmation != null) {
      throw StateError('cloud_sync_outbound_canary_already_armed');
    }
    _validatePreflight(await _readPreflight(), expectedOutboxCount: 1);
    final auth = await _readAuthSnapshot();
    if (auth == null) throw StateError('account_unavailable');
    final scope = _scopeForAuth(auth);
    final armedOperation = _requireSingleRecoverableOperation(
      await _readOutboxForConfirmation(scope),
      scope,
      requireConfirmed: requireConfirmed,
      allowConfirmed: allowConfirmed,
    );
    await _requireSameAuth(auth);
    final confirmation = CloudSyncOutboundCanaryConfirmation._(
      armedOperation: armedOperation,
      authSnapshot: auth,
      expiresAt: _clock().toUtc().add(confirmationLifetime),
      recovery: true,
      replayVerification: armedOperation.status == CloudOutboxStatus.confirmed,
    );
    _armedConfirmation = confirmation;
    return confirmation;
  }

  /// Second confirmation. The token is consumed before the first await so a
  /// repeated or concurrent invocation cannot replay the write.
  Future<CloudSyncOutboundCanaryReport> runDoubleConfirmed(
    CloudSyncOutboundCanaryConfirmation confirmation,
  ) async {
    _requireEnabled();
    if (_active) throw StateError('cloud_sync_outbound_canary_active');
    if (!identical(_armedConfirmation, confirmation) || confirmation.consumed) {
      throw StateError('cloud_sync_outbound_canary_confirmation_invalid');
    }
    confirmation.consumed = true;
    _armedConfirmation = null;
    if (_clock().toUtc().isAfter(confirmation.expiresAt)) {
      throw StateError('cloud_sync_outbound_canary_confirmation_expired');
    }

    _active = true;
    try {
      return await _writerExclusion.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () async {
          CloudSyncOutboundCanarySession? session;
          try {
            _validatePreflight(
              await _readPreflight(),
              expectedOutboxCount: confirmation.recovery ? 1 : 0,
            );
            final auth = await _readAuthSnapshot();
            if (!confirmation.authSnapshot.sameIdentity(auth)) {
              throw StateError('account_changed');
            }
            final scope = _scopeForAuth(auth!);
            CloudSyncOutboundCanaryAdmission? admission;
            if (!confirmation.recovery) {
              admission = await confirmation.revalidateAdmission!();
              if (admission == null ||
                  admission.createdAt.toUtc().millisecondsSinceEpoch !=
                      confirmation.selectedCreatedAt!.millisecondsSinceEpoch ||
                  admission.createdAt.isAfter(_clock().toUtc())) {
                throw StateError('cloud_sync_outbound_candidate_changed');
              }
              await _requireSameAuth(auth);
            }
            final sessionKind = _sessionKindFor(confirmation);
            session = await _createSession(
              auth,
              scope,
              sessionKind,
              confirmation.armedOperation,
            );
            _requireExactSessionCapability(session, sessionKind);
            final CloudOutboxOperation operation;
            if (confirmation.recovery) {
              final currentOperation = _requireSingleRecoverableOperation(
                await session.readOutbox(),
                scope,
                requireConfirmed: confirmation.replayVerification,
              );
              operation = _requireSameArmedOperation(
                currentOperation,
                confirmation.armedOperation!,
              );
            } else {
              final writeSession =
                  session as CloudSyncOutboundCanaryWriteSession;
              operation = await writeSession.admitMessage(
                message: admission!.message,
                createdAt: admission.createdAt.toUtc(),
              );
              _validateAdmission(operation, scope, admission.createdAt.toUtc());
            }
            await _requireSameAuth(auth);

            final CloudSyncRunResult result;
            CloudSyncConfirmedReplayProof? replayProof;
            switch (sessionKind) {
              case CloudSyncOutboundCanarySessionKind.confirmedReplay:
                final replaySession =
                    session as CloudSyncOutboundCanaryReplaySession;
                final startedAt = _clock().toUtc();
                replayProof = await replaySession.verifyConfirmedNoSave(
                  operation: operation,
                );
                result = CloudSyncRunResult(
                  status: CloudSyncRunStatus.completed,
                  counters: const CloudSyncRunCounters(),
                  startedAt: startedAt,
                  finishedAt: _clock().toUtc(),
                );
                break;
              case CloudSyncOutboundCanarySessionKind.unknownRecovery:
                result =
                    await (session
                            as CloudSyncOutboundCanaryUnknownRecoverySession)
                        .reconcileUnknownOutcome(operation: operation);
                break;
              case CloudSyncOutboundCanarySessionKind.freshWrite:
              case CloudSyncOutboundCanarySessionKind.pendingRecovery:
                result = await (session as CloudSyncOutboundCanaryFlushSession)
                    .flushOneBatch();
                break;
            }
            _validateRunResult(
              result,
              replayVerification: confirmation.replayVerification,
            );
            await _requireSameAuth(auth);
            _validatePreflight(await _readPreflight(), expectedOutboxCount: 1);
            final finalOperations = await session.readOutbox();
            final durableOperation = confirmation.replayVerification
                ? _requireSameArmedOperation(
                    _requireSingleRecoverableOperation(
                      finalOperations,
                      scope,
                      requireConfirmed: true,
                    ),
                    operation,
                  )
                : operation.status == CloudOutboxStatus.unknownOutcome
                ? _requireAllowedUnknownRecoveryPostflightOperation(
                    finalOperations,
                    operation,
                    result,
                  )
                : _requireAllowedPostflightOperation(
                    finalOperations,
                    operation,
                    result,
                  );
            if (confirmation.replayVerification) {
              await (session as CloudSyncOutboundCanaryReplaySession)
                  .finalizeConfirmedReplayProof(
                    operation: durableOperation,
                    proof: replayProof!,
                  );
            }
            return CloudSyncOutboundCanaryReport(
              timestampUtc: _clock().toUtc(),
              status: result.status,
              confirmed: result.counters.confirmed,
              quarantined: result.counters.quarantined,
              retried: result.counters.retried,
              outboxStatus: durableOperation.status,
              recovery: confirmation.recovery,
              replayVerification: confirmation.replayVerification,
            );
          } finally {
            await session?.quiesce();
          }
        },
      );
    } finally {
      _active = false;
    }
  }

  CloudSyncOutboundCanarySessionKind _sessionKindFor(
    CloudSyncOutboundCanaryConfirmation confirmation,
  ) {
    if (!confirmation.recovery) {
      return CloudSyncOutboundCanarySessionKind.freshWrite;
    }
    return switch (confirmation.armedOperation!.status) {
      CloudOutboxStatus.pending =>
        CloudSyncOutboundCanarySessionKind.pendingRecovery,
      CloudOutboxStatus.unknownOutcome =>
        CloudSyncOutboundCanarySessionKind.unknownRecovery,
      CloudOutboxStatus.confirmed =>
        CloudSyncOutboundCanarySessionKind.confirmedReplay,
      CloudOutboxStatus.leased ||
      CloudOutboxStatus.paused ||
      CloudOutboxStatus.quarantined => throw StateError(
        'cloud_sync_outbound_canary_recovery_invalid',
      ),
    };
  }

  void _requireExactSessionCapability(
    CloudSyncOutboundCanarySession session,
    CloudSyncOutboundCanarySessionKind kind,
  ) {
    final valid = switch (kind) {
      CloudSyncOutboundCanarySessionKind.freshWrite =>
        session is CloudSyncOutboundCanaryWriteSession &&
            session is! CloudSyncOutboundCanaryUnknownRecoverySession &&
            session is! CloudSyncOutboundCanaryReplaySession,
      CloudSyncOutboundCanarySessionKind.pendingRecovery =>
        session is CloudSyncOutboundCanaryFlushSession &&
            session is! CloudSyncOutboundCanaryWriteSession &&
            session is! CloudSyncOutboundCanaryUnknownRecoverySession &&
            session is! CloudSyncOutboundCanaryReplaySession,
      CloudSyncOutboundCanarySessionKind.unknownRecovery =>
        session is CloudSyncOutboundCanaryUnknownRecoverySession &&
            session is! CloudSyncOutboundCanaryFlushSession &&
            session is! CloudSyncOutboundCanaryWriteSession &&
            session is! CloudSyncOutboundCanaryReplaySession,
      CloudSyncOutboundCanarySessionKind.confirmedReplay =>
        session is CloudSyncOutboundCanaryReplaySession &&
            session is! CloudSyncOutboundCanaryFlushSession &&
            session is! CloudSyncOutboundCanaryWriteSession &&
            session is! CloudSyncOutboundCanaryUnknownRecoverySession,
    };
    if (!valid) {
      throw StateError('cloud_sync_outbound_canary_session_capability_invalid');
    }
  }

  void disarm(CloudSyncOutboundCanaryConfirmation confirmation) {
    if (!identical(_armedConfirmation, confirmation) || confirmation.consumed) {
      return;
    }
    confirmation.consumed = true;
    _armedConfirmation = null;
  }

  void _requireEnabled() {
    if (!_enabled) throw StateError('cloud_sync_outbound_canary_disabled');
    if (!_v2WriterEnabled) {
      throw StateError('cloud_sync_outbound_canary_writer_disabled');
    }
  }

  void _validatePreflight(
    CloudSyncShadowPreflightState state, {
    required int expectedOutboxCount,
  }) {
    if (!state.platformSupported) throw StateError('unsupported_platform');
    if (!state.uiIsolate) throw StateError('not_ui_isolate');
    if (!state.rustPushReady) throw StateError('rustpush_not_ready');
    if (!state.objectBoxReady) throw StateError('objectbox_not_ready');
    if (!state.privateStorageExists) throw StateError('storage_unavailable');
    if (state.logoutActive) throw StateError('logout_active');
    if (state.legacySyncEnabled || state.legacySyncActive) {
      throw StateError('legacy_sync_active');
    }
    if (state.coordinatorLeaseActive) throw StateError('coordinator_active');
    if (state.outboxCount != expectedOutboxCount) {
      throw StateError('cloud_sync_outbound_canary_outbox_invalid');
    }
    if (!state.protectorSentinelValid) {
      throw StateError('protector_unavailable');
    }
  }

  void _validateAdmission(
    CloudOutboxOperation operation,
    CloudSyncScope expectedScope,
    DateTime expectedCreatedAt,
  ) {
    if (operation.scope != expectedScope ||
        operation.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: expectedScope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              payloadVersion: operation.payloadVersion,
            ) ||
        !_nativeDigestPattern.hasMatch(operation.logicalEntityKeyHash) ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        operation.mutationRevision <= 0 ||
        operation.status != CloudOutboxStatus.pending ||
        operation.attemptCount != 0 ||
        operation.dependencyOperationIds.isNotEmpty ||
        operation.encryptedPayloadReference == null ||
        !_protectedReferencePattern.hasMatch(
          operation.encryptedPayloadReference!,
        ) ||
        operation.payloadSha256 == null ||
        !_contentDigestPattern.hasMatch(operation.payloadSha256!) ||
        operation.serverRecordIdHash == null ||
        !_nativeDigestPattern.hasMatch(operation.serverRecordIdHash!) ||
        operation.protectedLeaseReference == null ||
        !_leaseReferencePattern.hasMatch(operation.protectedLeaseReference!) ||
        operation.appleRequestUuid != null ||
        operation.appleOperationUuid != null ||
        operation.nextEligibleAt != null ||
        operation.lastFailure != null ||
        operation.leaseId != null ||
        operation.leaseExpiresAt != null ||
        operation.confirmedAt != null ||
        operation.createdAt.millisecondsSinceEpoch !=
            expectedCreatedAt.millisecondsSinceEpoch) {
      throw StateError('cloud_sync_outbound_canary_admission_invalid');
    }
  }

  CloudSyncScope _scopeForAuth(CloudSyncNativeAuthSnapshot auth) =>
      CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: container,
        database: database,
        zone: zone,
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: 2,
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );

  CloudOutboxOperation _requireSingleRecoverableOperation(
    List<CloudOutboxOperation> operations,
    CloudSyncScope expectedScope, {
    required bool requireConfirmed,
    bool allowConfirmed = false,
  }) {
    if (operations.length != 1) {
      throw StateError('cloud_sync_outbound_canary_recovery_invalid');
    }
    final operation = operations.single;
    if (!_hasExactCreateBinding(operation, expectedScope)) {
      throw StateError('cloud_sync_outbound_canary_recovery_invalid');
    }
    if (requireConfirmed) {
      if (operation.status != CloudOutboxStatus.confirmed ||
          !_hasValidRecoverableLifecycle(operation)) {
        throw StateError('cloud_sync_outbound_canary_replay_invalid');
      }
    } else {
      final statusAllowed =
          operation.status == CloudOutboxStatus.pending ||
          operation.status == CloudOutboxStatus.unknownOutcome ||
          (allowConfirmed && operation.status == CloudOutboxStatus.confirmed);
      if (!statusAllowed || !_hasValidRecoverableLifecycle(operation)) {
        throw StateError('cloud_sync_outbound_canary_recovery_invalid');
      }
    }
    return operation;
  }

  CloudOutboxOperation _requireSameArmedOperation(
    CloudOutboxOperation actual,
    CloudOutboxOperation expected,
  ) {
    if (!actual.sameDurableSnapshotAs(expected)) {
      throw StateError('cloud_sync_outbound_canary_operation_changed');
    }
    return actual;
  }

  CloudOutboxOperation _requireAllowedPostflightOperation(
    List<CloudOutboxOperation> operations,
    CloudOutboxOperation expected,
    CloudSyncRunResult result,
  ) {
    if (operations.length != 1) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }
    final actual = operations.single;
    if (!_hasExactCreateBinding(expected, expected.scope) ||
        actual.scope != expected.scope ||
        actual.operationId != expected.operationId ||
        actual.logicalEntityKeyHash != expected.logicalEntityKeyHash ||
        actual.action != expected.action ||
        actual.payloadVersion != expected.payloadVersion ||
        actual.payloadSha256 != expected.payloadSha256 ||
        actual.serverRecordIdHash != expected.serverRecordIdHash ||
        actual.encryptedPayloadReference !=
            expected.encryptedPayloadReference ||
        actual.mutationRevision != expected.mutationRevision ||
        actual.checkpointGeneration != expected.checkpointGeneration ||
        actual.dependencyOperationIds.length !=
            expected.dependencyOperationIds.length ||
        !actual.dependencyOperationIds.containsAll(
          expected.dependencyOperationIds,
        ) ||
        actual.createdAt.millisecondsSinceEpoch !=
            expected.createdAt.millisecondsSinceEpoch ||
        actual.leaseId != null ||
        actual.leaseExpiresAt != null) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }
    final counters = result.counters;
    final outboundTotal =
        counters.confirmed + counters.quarantined + counters.retried;
    final statusMatchesCounter = switch (actual.status) {
      CloudOutboxStatus.confirmed => counters.confirmed == 1,
      CloudOutboxStatus.quarantined => counters.quarantined == 1,
      CloudOutboxStatus.pending => counters.retried == 1 || outboundTotal == 0,
      CloudOutboxStatus.unknownOutcome => outboundTotal == 0,
      CloudOutboxStatus.paused => false,
      CloudOutboxStatus.leased => false,
    };
    if (!statusMatchesCounter ||
        !_hasAllowedPostflightLifecycle(actual, expected, counters)) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }
    return actual;
  }

  CloudOutboxOperation _requireAllowedUnknownRecoveryPostflightOperation(
    List<CloudOutboxOperation> operations,
    CloudOutboxOperation expected,
    CloudSyncRunResult result,
  ) {
    if (expected.status != CloudOutboxStatus.unknownOutcome ||
        operations.length != 1 ||
        result.counters.quarantined != 0) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }
    final actual = operations.single;
    final immutableBindingMatches =
        _hasExactCreateBinding(expected, expected.scope) &&
        actual.scope == expected.scope &&
        actual.operationId == expected.operationId &&
        actual.logicalEntityKeyHash == expected.logicalEntityKeyHash &&
        actual.action == expected.action &&
        actual.payloadVersion == expected.payloadVersion &&
        actual.payloadSha256 == expected.payloadSha256 &&
        actual.serverRecordIdHash == expected.serverRecordIdHash &&
        actual.encryptedPayloadReference ==
            expected.encryptedPayloadReference &&
        actual.protectedLeaseReference == expected.protectedLeaseReference &&
        actual.mutationRevision == expected.mutationRevision &&
        actual.checkpointGeneration == expected.checkpointGeneration &&
        actual.dependencyOperationIds.length ==
            expected.dependencyOperationIds.length &&
        actual.dependencyOperationIds.containsAll(
          expected.dependencyOperationIds,
        ) &&
        actual.createdAt.millisecondsSinceEpoch ==
            expected.createdAt.millisecondsSinceEpoch &&
        actual.leaseId == null &&
        actual.leaseExpiresAt == null;
    if (!immutableBindingMatches) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }

    final counters = result.counters;
    final allowed = switch (actual.status) {
      CloudOutboxStatus.confirmed =>
        counters.confirmed == 1 &&
            counters.retried == 0 &&
            actual.appleRequestUuid == expected.appleRequestUuid &&
            actual.appleOperationUuid == expected.appleOperationUuid &&
            actual.attemptCount == expected.attemptCount &&
            actual.nextEligibleAt == null &&
            actual.lastFailure == null &&
            actual.confirmedAt != null,
      CloudOutboxStatus.pending =>
        counters.confirmed == 0 &&
            counters.retried == 1 &&
            actual.appleRequestUuid == null &&
            actual.appleOperationUuid == null &&
            actual.attemptCount == expected.attemptCount + 1 &&
            actual.nextEligibleAt != null &&
            actual.lastFailure != null &&
            actual.confirmedAt == null,
      CloudOutboxStatus.unknownOutcome =>
        counters.confirmed == 0 &&
            counters.retried == 0 &&
            actual.appleRequestUuid == expected.appleRequestUuid &&
            actual.appleOperationUuid == expected.appleOperationUuid &&
            actual.lastFailure == CloudFailureCategory.unknown &&
            actual.confirmedAt == null &&
            (actual.sameDurableSnapshotAs(expected) ||
                (actual.attemptCount == expected.attemptCount + 1 &&
                    actual.nextEligibleAt != null)),
      CloudOutboxStatus.leased ||
      CloudOutboxStatus.paused ||
      CloudOutboxStatus.quarantined => false,
    };
    if (!allowed) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }
    return actual;
  }

  bool _hasAllowedPostflightLifecycle(
    CloudOutboxOperation actual,
    CloudOutboxOperation expected,
    CloudSyncRunCounters counters,
  ) {
    if (counters.confirmed == 0 &&
        counters.quarantined == 0 &&
        counters.retried == 0 &&
        actual.sameDurableSnapshotAs(expected)) {
      return _hasValidRecoverableLifecycle(actual) &&
          (actual.status == CloudOutboxStatus.pending ||
              actual.status == CloudOutboxStatus.unknownOutcome);
    }
    final protectedReceiptUnchanged =
        actual.protectedLeaseReference == expected.protectedLeaseReference;
    final submissionIdentityPreservedOrAssigned =
        actual.appleRequestUuid != null &&
        actual.appleOperationUuid != null &&
        (expected.appleRequestUuid == null ||
            (actual.appleRequestUuid == expected.appleRequestUuid &&
                actual.appleOperationUuid == expected.appleOperationUuid));
    final quarantineSubmissionIdentityValid = expected.appleRequestUuid == null
        ? (actual.appleRequestUuid == null ||
              (actual.appleRequestUuid != null &&
                  actual.appleOperationUuid != null))
        : actual.appleRequestUuid == expected.appleRequestUuid &&
              actual.appleOperationUuid == expected.appleOperationUuid;
    return switch (actual.status) {
      CloudOutboxStatus.confirmed =>
        protectedReceiptUnchanged &&
            submissionIdentityPreservedOrAssigned &&
            actual.attemptCount == expected.attemptCount &&
            actual.nextEligibleAt == null &&
            actual.lastFailure == null &&
            actual.confirmedAt != null,
      CloudOutboxStatus.pending =>
        protectedReceiptUnchanged &&
            counters.retried == 1 &&
            actual.attemptCount == expected.attemptCount + 1 &&
            actual.nextEligibleAt != null &&
            actual.lastFailure != null &&
            actual.appleRequestUuid == null &&
            actual.appleOperationUuid == null &&
            actual.confirmedAt == null,
      CloudOutboxStatus.paused => false,
      CloudOutboxStatus.quarantined =>
        actual.protectedLeaseReference == null &&
            quarantineSubmissionIdentityValid &&
            actual.attemptCount == expected.attemptCount + 1 &&
            actual.nextEligibleAt == null &&
            actual.lastFailure != null &&
            actual.confirmedAt == null,
      CloudOutboxStatus.unknownOutcome =>
        protectedReceiptUnchanged &&
            submissionIdentityPreservedOrAssigned &&
            actual.attemptCount == expected.attemptCount + 1 &&
            actual.lastFailure == CloudFailureCategory.unknown &&
            actual.confirmedAt == null,
      CloudOutboxStatus.leased => false,
    };
  }

  bool _hasValidRecoverableLifecycle(CloudOutboxOperation operation) {
    if (operation.leaseId != null || operation.leaseExpiresAt != null) {
      return false;
    }
    return switch (operation.status) {
      CloudOutboxStatus.pending =>
        operation.appleRequestUuid == null &&
            operation.appleOperationUuid == null &&
            operation.confirmedAt == null &&
            (operation.attemptCount == 0
                ? operation.nextEligibleAt == null &&
                      operation.lastFailure == null
                : operation.nextEligibleAt != null &&
                      operation.lastFailure != null),
      CloudOutboxStatus.unknownOutcome =>
        operation.appleRequestUuid != null &&
            operation.appleOperationUuid != null &&
            operation.lastFailure == CloudFailureCategory.unknown &&
            operation.confirmedAt == null,
      CloudOutboxStatus.confirmed =>
        operation.appleRequestUuid != null &&
            operation.appleOperationUuid != null &&
            operation.nextEligibleAt == null &&
            operation.lastFailure == null &&
            operation.confirmedAt != null,
      CloudOutboxStatus.leased ||
      CloudOutboxStatus.paused ||
      CloudOutboxStatus.quarantined => false,
    };
  }

  bool _hasExactCreateBinding(
    CloudOutboxOperation operation,
    CloudSyncScope expectedScope,
  ) {
    return operation.scope == expectedScope &&
        operation.operationId ==
            CloudOperationIdentity.forInitialCreate(
              scope: expectedScope,
              logicalEntityKeyHash: operation.logicalEntityKeyHash,
              payloadVersion: operation.payloadVersion,
            ) &&
        _nativeDigestPattern.hasMatch(operation.logicalEntityKeyHash) &&
        operation.action == CloudOutboxAction.save &&
        operation.payloadVersion == cloudSyncOutboundPayloadVersion &&
        operation.mutationRevision > 0 &&
        operation.checkpointGeneration > 0 &&
        operation.dependencyOperationIds.isEmpty &&
        operation.encryptedPayloadReference != null &&
        _protectedReferencePattern.hasMatch(
          operation.encryptedPayloadReference!,
        ) &&
        operation.payloadSha256 != null &&
        _contentDigestPattern.hasMatch(operation.payloadSha256!) &&
        operation.serverRecordIdHash != null &&
        _nativeDigestPattern.hasMatch(operation.serverRecordIdHash!) &&
        operation.protectedLeaseReference != null &&
        _leaseReferencePattern.hasMatch(operation.protectedLeaseReference!);
  }

  void _validateRunResult(
    CloudSyncRunResult result, {
    required bool replayVerification,
  }) {
    final counters = result.counters;
    final outboundTotal =
        counters.confirmed + counters.quarantined + counters.retried;
    if (counters.fetched != 0 ||
        counters.applied != 0 ||
        counters.deferred != 0 ||
        outboundTotal > 1) {
      throw StateError('cloud_sync_outbound_canary_tripwire');
    }
    if (replayVerification &&
        (result.status != CloudSyncRunStatus.completed ||
            counters.confirmed != 0 ||
            counters.quarantined != 0 ||
            counters.retried != 0)) {
      throw StateError('cloud_sync_outbound_canary_replay_invalid');
    }
  }

  Future<void> _requireSameAuth(CloudSyncNativeAuthSnapshot expected) async {
    if (!expected.sameIdentity(await _readAuthSnapshot())) {
      throw StateError('account_changed');
    }
  }
}
