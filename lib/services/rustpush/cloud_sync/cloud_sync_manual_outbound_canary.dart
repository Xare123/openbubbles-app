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
    );

/// One production-composed write session for the single-message canary.
///
/// The sampler owns ordering and account checks. The session owns the native
/// protected transport, durable ObjectBox store, admission coordinator, writer
/// authority, and operation interlock used by the engine.
abstract interface class CloudSyncOutboundCanarySession {
  Future<CloudOutboxOperation> admitMessage({
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  });

  Future<CloudSyncRunResult> flushOneBatch();

  Future<List<CloudOutboxOperation>> readOutbox();

  Future<void> quiesce();
}

/// Opaque, single-use evidence that the user completed the first confirmation.
///
/// The selected message is retained only in memory and is intentionally absent
/// from diagnostics and [toString]. A second explicit call is required before
/// any durable admission or CloudKit mutation can occur.
final class CloudSyncOutboundCanaryConfirmation {
  CloudSyncOutboundCanaryConfirmation._({
    this.message,
    this.createdAt,
    required this.authSnapshot,
    required this.expiresAt,
    required this.recovery,
  });

  final frb_api.CloudMessage? message;
  final DateTime? createdAt;
  final CloudSyncNativeAuthSnapshot authSnapshot;
  final DateTime expiresAt;
  final bool recovery;
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
  });

  final DateTime timestampUtc;
  final CloudSyncRunStatus status;
  final int confirmed;
  final int quarantined;
  final int retried;
  final CloudOutboxStatus outboxStatus;
  final bool recovery;

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
    required CloudSyncOutboundCanarySessionFactory createSession,
    required CloudKitOperationExclusion writerExclusion,
    bool? compileGateOverrideForTest,
    bool? v2WriterOverrideForTest,
    DateTime Function()? clock,
  }) : _readPreflight = readPreflight,
       _readAuthSnapshot = readAuthSnapshot,
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
    required frb_api.CloudMessage message,
    required DateTime createdAt,
  }) async {
    _requireEnabled();
    if (_active) throw StateError('cloud_sync_outbound_canary_active');
    if (_armedConfirmation != null) {
      throw StateError('cloud_sync_outbound_canary_already_armed');
    }
    if (createdAt.isAfter(_clock().toUtc())) {
      throw StateError('cloud_sync_outbound_canary_message_time_invalid');
    }
    _validatePreflight(await _readPreflight(), expectedOutboxCount: 0);
    final auth = await _readAuthSnapshot();
    if (auth == null) throw StateError('account_unavailable');
    final confirmation = CloudSyncOutboundCanaryConfirmation._(
      message: message,
      createdAt: createdAt.toUtc(),
      authSnapshot: auth,
      expiresAt: _clock().toUtc().add(confirmationLifetime),
      recovery: false,
    );
    _armedConfirmation = confirmation;
    return confirmation;
  }

  /// First confirmation for a process-death or interrupted-run recovery.
  /// No new message is staged or admitted. The second confirmation may only
  /// inspect and advance the one exact durable create already in the outbox.
  Future<CloudSyncOutboundCanaryConfirmation> armRecoveryConfirmed() async {
    _requireEnabled();
    if (_active) throw StateError('cloud_sync_outbound_canary_active');
    if (_armedConfirmation != null) {
      throw StateError('cloud_sync_outbound_canary_already_armed');
    }
    _validatePreflight(await _readPreflight(), expectedOutboxCount: 1);
    final auth = await _readAuthSnapshot();
    if (auth == null) throw StateError('account_unavailable');
    final confirmation = CloudSyncOutboundCanaryConfirmation._(
      authSnapshot: auth,
      expiresAt: _clock().toUtc().add(confirmationLifetime),
      recovery: true,
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
            final scope = CloudSyncScope(
              accountFingerprint: auth!.accountFingerprint,
              container: container,
              database: database,
              zone: zone,
              streamKind: CloudSyncStreamKind.messages,
              schemaVersion: 2,
              persistenceLane: CloudSyncPersistenceLane.semantic,
            );
            session = await _createSession(auth, scope);
            final CloudOutboxOperation operation;
            if (confirmation.recovery) {
              operation = _requireSingleRecoverableOperation(
                await session.readOutbox(),
                scope,
              );
            } else {
              operation = await session.admitMessage(
                message: confirmation.message!,
                createdAt: confirmation.createdAt!,
              );
              _validateAdmission(operation, scope, confirmation.createdAt!);
            }
            await _requireSameAuth(auth);

            final result = await session.flushOneBatch();
            _validateRunResult(result);
            await _requireSameAuth(auth);
            _validatePreflight(await _readPreflight(), expectedOutboxCount: 1);
            final durableOperation = _requireSameDurableOperation(
              await session.readOutbox(),
              operation,
            );
            return CloudSyncOutboundCanaryReport(
              timestampUtc: _clock().toUtc(),
              status: result.status,
              confirmed: result.counters.confirmed,
              quarantined: result.counters.quarantined,
              retried: result.counters.retried,
              outboxStatus: durableOperation.status,
              recovery: confirmation.recovery,
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

  CloudOutboxOperation _requireSingleRecoverableOperation(
    List<CloudOutboxOperation> operations,
    CloudSyncScope expectedScope,
  ) {
    if (operations.length != 1) {
      throw StateError('cloud_sync_outbound_canary_recovery_invalid');
    }
    final operation = operations.single;
    if (!_hasExactCreateBinding(operation, expectedScope) ||
        operation.status == CloudOutboxStatus.leased) {
      throw StateError('cloud_sync_outbound_canary_recovery_invalid');
    }
    return operation;
  }

  CloudOutboxOperation _requireSameDurableOperation(
    List<CloudOutboxOperation> operations,
    CloudOutboxOperation expected,
  ) {
    if (operations.length != 1) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }
    final actual = operations.single;
    if (!_hasExactCreateBinding(actual, expected.scope) ||
        actual.operationId != expected.operationId ||
        actual.logicalEntityKeyHash != expected.logicalEntityKeyHash ||
        actual.payloadSha256 != expected.payloadSha256 ||
        actual.serverRecordIdHash != expected.serverRecordIdHash ||
        actual.encryptedPayloadReference !=
            expected.encryptedPayloadReference ||
        actual.protectedLeaseReference != expected.protectedLeaseReference ||
        actual.mutationRevision != expected.mutationRevision ||
        actual.checkpointGeneration != expected.checkpointGeneration ||
        actual.createdAt.millisecondsSinceEpoch !=
            expected.createdAt.millisecondsSinceEpoch ||
        actual.status == CloudOutboxStatus.leased) {
      throw StateError('cloud_sync_outbound_canary_postflight_invalid');
    }
    return actual;
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

  void _validateRunResult(CloudSyncRunResult result) {
    final counters = result.counters;
    final outboundTotal =
        counters.confirmed + counters.quarantined + counters.retried;
    if (counters.fetched != 0 ||
        counters.applied != 0 ||
        counters.deferred != 0 ||
        outboundTotal > 1) {
      throw StateError('cloud_sync_outbound_canary_tripwire');
    }
  }

  Future<void> _requireSameAuth(CloudSyncNativeAuthSnapshot expected) async {
    if (!expected.sameIdentity(await _readAuthSnapshot())) {
      throw StateError('account_changed');
    }
  }
}
