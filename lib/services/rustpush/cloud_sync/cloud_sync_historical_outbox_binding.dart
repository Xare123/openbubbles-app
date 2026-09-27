import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:bluebubbles/database/io/cloud_sync_records.dart'
    show cloudSyncSchemaVersion;

import 'cloud_operation_identity.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_historical_local_guard.dart';
import 'cloud_sync_models.dart';

/// Immutable metadata for one historical create. A native proof and a freshly
/// consumed exact absence are still required; this is not a write capability.
/// The target chat ID belongs to the destination store, never the snapshot.
final class CloudSyncHistoricalCreateSource {
  CloudSyncHistoricalCreateSource({
    required this.intentId,
    required this.source,
    required this.localChatId,
    required this.parentBinding,
    required this.generation,
    required this.logicalEntityKeyHash,
    required this.serverRecordIdHash,
    required this.createdAtMs,
    required this.localGuard,
  }) {
    if (intentId < 1 ||
        localChatId < 1 ||
        generation < 1 ||
        createdAtMs < 1 ||
        parentBinding.isEmpty ||
        parentBinding.length > 1024 ||
        !_token.hasMatch(logicalEntityKeyHash) ||
        !_token.hasMatch(serverRecordIdHash)) {
      throw StateError('cloud_sync_historical_create_source_invalid');
    }
  }

  final int intentId;
  final CloudSyncHistoricalProtectedSourceBinding source;
  final int localChatId;
  final String parentBinding;
  final int generation;
  final String logicalEntityKeyHash;
  final String serverRecordIdHash;
  final int createdAtMs;
  final CloudSyncHistoricalLocalGuard localGuard;

  static final _token = RegExp(r'^[A-Za-z0-9_-]{43}$');

  List<Object> get _fields => <Object>[
    intentId,
    source.encode(),
    localChatId,
    parentBinding,
    generation,
    logicalEntityKeyHash,
    serverRecordIdHash,
    createdAtMs,
    localGuard.encode(),
  ];

  bool sameSourceAs(CloudSyncHistoricalCreateSource other) =>
      jsonEncode(_fields) == jsonEncode(other._fields);

  void requireOperation(CloudOutboxOperation operation) {
    final scope = operation.scope;
    if (scope.accountFingerprint != source.accountFingerprint ||
        scope.container != 'com.apple.messages.cloud' ||
        scope.database != 'private' ||
        scope.zone != 'messageManateeZone' ||
        scope.streamKind != CloudSyncStreamKind.messages ||
        scope.schemaVersion != cloudSyncSchemaVersion ||
        scope.persistenceLane != CloudSyncPersistenceLane.semantic ||
        operation.action != CloudOutboxAction.save ||
        operation.payloadVersion != cloudSyncOutboundPayloadVersion ||
        operation.checkpointGeneration != generation ||
        operation.logicalEntityKeyHash != logicalEntityKeyHash ||
        operation.serverRecordIdHash != serverRecordIdHash ||
        operation.createdAt.millisecondsSinceEpoch != createdAtMs ||
        !operation.createdAt.isUtc ||
        operation.mutationRevision < 1 ||
        operation.dependencyOperationIds.isNotEmpty ||
        operation.encryptedPayloadReference == null ||
        !RegExp(
          r'^obcs2\.ref\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(operation.encryptedPayloadReference!) ||
        operation.payloadSha256 == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(operation.payloadSha256!) ||
        operation.operationId !=
            CloudOperationIdentity.forInitialCreate(
              scope: scope,
              logicalEntityKeyHash: logicalEntityKeyHash,
              payloadVersion: cloudSyncOutboundPayloadVersion,
            )) {
      throw StateError('cloud_sync_historical_admitted_operation_changed');
    }
  }

  @override
  String toString() => 'CloudSyncHistoricalCreateSource(redacted)';
}

/// Persisted in the same transaction as the outbox/map/lease adoption. Unknown
/// outcomes retain this exact ownership even if the visible Message changes.
/// Mutable attempt, receipt and confirmation fields deliberately are not part
/// of the fingerprint; changing them cannot allocate another create identity.
final class CloudSyncHistoricalOutboxBinding {
  CloudSyncHistoricalOutboxBinding._(this.source, this.operationDigest);

  factory CloudSyncHistoricalOutboxBinding.adopt({
    required CloudSyncHistoricalCreateSource source,
    required CloudOutboxOperation operation,
  }) {
    source.requireOperation(operation);
    if (operation.status != CloudOutboxStatus.pending ||
        operation.attemptCount != 0 ||
        operation.appleRequestUuid != null ||
        operation.appleOperationUuid != null ||
        operation.confirmedAt != null ||
        operation.leaseId != null ||
        operation.leaseExpiresAt != null ||
        operation.nextEligibleAt != null ||
        operation.lastFailure != null ||
        operation.protectedLeaseReference == null ||
        !RegExp(
          r'^obcs2\.lease\.[a-f0-9]{32}$',
        ).hasMatch(operation.protectedLeaseReference!)) {
      throw StateError('cloud_sync_historical_create_admission_changed');
    }
    return CloudSyncHistoricalOutboxBinding._(
      source,
      _digest(operation, source),
    );
  }

  final CloudSyncHistoricalCreateSource source;
  final String operationDigest;

  String encode() => jsonEncode(<Object>[
    1,
    'historicalCreateOwnership',
    ...source._fields,
    operationDigest,
  ]);

  static CloudSyncHistoricalOutboxBinding decode(String encoded) {
    if (encoded.length > 8192) {
      throw StateError('cloud_sync_historical_outbox_binding_invalid');
    }
    final dynamic value;
    try {
      value = jsonDecode(encoded);
    } on FormatException {
      throw StateError('cloud_sync_historical_outbox_binding_invalid');
    }
    if (value is! List ||
        value.length != 12 ||
        value[0] != 1 ||
        value[1] != 'historicalCreateOwnership' ||
        value[2] is! int ||
        value[3] is! String ||
        value[4] is! int ||
        value[5] is! String ||
        value[6] is! int ||
        value[7] is! String ||
        value[8] is! String ||
        value[9] is! int ||
        value[10] is! String ||
        value[11] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value[11] as String)) {
      throw StateError('cloud_sync_historical_outbox_binding_invalid');
    }
    final result = CloudSyncHistoricalOutboxBinding._(
      CloudSyncHistoricalCreateSource(
        intentId: value[2] as int,
        source: CloudSyncHistoricalProtectedSourceBinding.decode(
          value[3] as String,
        ),
        localChatId: value[4] as int,
        parentBinding: value[5] as String,
        generation: value[6] as int,
        logicalEntityKeyHash: value[7] as String,
        serverRecordIdHash: value[8] as String,
        createdAtMs: value[9] as int,
        localGuard: CloudSyncHistoricalLocalGuard.decode(value[10] as String),
      ),
      value[11] as String,
    );
    if (result.encode() != encoded) {
      throw StateError('cloud_sync_historical_outbox_binding_invalid');
    }
    return result;
  }

  void requireOperation(CloudOutboxOperation operation) {
    source.requireOperation(operation);
    if (_digest(operation, source) != operationDigest) {
      throw StateError('cloud_sync_historical_admitted_operation_changed');
    }
  }

  static String _digest(
    CloudOutboxOperation operation,
    CloudSyncHistoricalCreateSource source,
  ) => sha256
      .convert(
        utf8.encode(
          jsonEncode(<Object?>[
            'historical-create-admission-v1',
            ...source._fields,
            operation.scope.storageKey,
            operation.operationId,
            operation.logicalEntityKeyHash,
            operation.serverRecordIdHash,
            operation.checkpointGeneration,
            operation.action.name,
            operation.payloadVersion,
            operation.mutationRevision,
            operation.encryptedPayloadReference,
            operation.payloadSha256,
            operation.createdAt.millisecondsSinceEpoch,
          ]),
        ),
      )
      .toString();

  @override
  String toString() => 'CloudSyncHistoricalOutboxBinding(redacted)';
}
