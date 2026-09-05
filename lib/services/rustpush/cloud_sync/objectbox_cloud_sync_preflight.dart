import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_production_preflight.dart';
import 'cloudkit_operation_interlock.dart';

/// Reads the local mutation fence in one ObjectBox transaction.
///
/// Keeping the active coordinator-lease check and outbox count in the same
/// snapshot prevents a manual shadow run from observing a torn local state.
final class ObjectBoxCloudSyncPreflightReader {
  ObjectBoxCloudSyncPreflightReader({
    required Store store,
    DateTime Function()? now,
    Set<String>? ignoredScopeKeys,
  }) : _store = store,
       _leases = store.box<CloudSyncLeaseEntity>(),
       _outbox = store.box<CloudOutboxOperationEntity>(),
       _now = now ?? DateTime.now,
       _ignoredScopeKeys =
           ignoredScopeKeys ??
           <String>{CloudKitOperationInterlock.fenceScopeKey};

  factory ObjectBoxCloudSyncPreflightReader.fromDatabase() =>
      ObjectBoxCloudSyncPreflightReader(store: Database.store);

  final Store _store;
  final Box<CloudSyncLeaseEntity> _leases;
  final Box<CloudOutboxOperationEntity> _outbox;
  final DateTime Function() _now;
  final Set<String> _ignoredScopeKeys;

  CloudSyncLocalPreflightState read() {
    return _store.runInTransaction(TxMode.read, () {
      final nowMs = _now().millisecondsSinceEpoch;
      // The caller of this probe runs inside the operation interlock, which
      // holds its own fence lease for the duration of the guarded work. Reading
      // every unexpired lease made an operation observe its own fence and fail
      // closed with coordinator_active before any network call. Every other
      // scope, including any unrecognized one, still blocks.
      var condition = CloudSyncLeaseEntity_.expiresAtMs.greaterThan(nowMs);
      for (final ignored in _ignoredScopeKeys) {
        condition = condition.and(
          CloudSyncLeaseEntity_.scopeKey.notEquals(ignored),
        );
      }
      final query = _leases.query(condition).build()..limit = 1;
      try {
        final rows = _outbox.getAll()..sort((a, b) => a.id.compareTo(b.id));
        return CloudSyncLocalPreflightState(
          objectBoxReady: true,
          coordinatorLeaseActive: query.findFirst() != null,
          outboxCount: rows.length,
          settledOutboxFingerprint: _settledFingerprint(rows),
        );
      } finally {
        query.close();
      }
    });
  }

  // This is evidence of local quiescence, not proof of a remote save. The
  // writer owns receipt validation. Retaining its completed audit rows must
  // not prevent subsequent reads, but unacknowledged receipts, uncertain
  // outcomes, malformed states, and every non-confirmed row still block.
  static String? _settledFingerprint(List<CloudOutboxOperationEntity> rows) {
    if (rows.isEmpty) return null;
    for (final row in rows) {
      if (row.state != 2 ||
          row.action != 0 ||
          row.confirmedAtMs <= 0 ||
          row.checkpointGeneration <= 0 ||
          row.protectedLeaseReference != null ||
          row.leaseIdHash != null ||
          row.leaseExpiresAtMs != 0 ||
          row.nextEligibleAtMs != 0 ||
          row.lastErrorCategory != null ||
          row.operationId.isEmpty ||
          row.scopeKey.isEmpty ||
          row.accountFingerprint.isEmpty ||
          row.zone.isEmpty ||
          row.logicalEntityKeyHash.isEmpty ||
          row.serverRecordIdHash == null ||
          row.serverRecordIdHash!.isEmpty ||
          row.encryptedPayloadRef == null ||
          row.encryptedPayloadRef!.isEmpty ||
          row.payloadSha256 == null ||
          row.payloadSha256!.isEmpty ||
          row.payloadVersion <= 0 ||
          row.mutationRevision < 0 ||
          row.attemptCount < 0) {
        return null;
      }
    }
    // Include every durable column, including nulls, IDs, and timestamps. A
    // same-count replacement or mutation during a read is not an unchanged
    // outbox. JSON preserves field boundaries without exposing any value.
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'cloud-sync-settled-outbox-v1',
              for (final row in rows)
                [
                  row.id,
                  row.operationId,
                  row.scopeKey,
                  row.accountFingerprint,
                  row.zone,
                  row.logicalEntityKeyHash,
                  row.action,
                  row.dependencyOperationIdsJson,
                  row.payloadVersion,
                  row.mutationRevision,
                  row.checkpointGeneration,
                  row.appleRequestUuid,
                  row.appleOperationUuid,
                  row.encryptedPayloadRef,
                  row.payloadSha256,
                  row.protectedLeaseReference,
                  row.state,
                  row.attemptCount,
                  row.nextEligibleAtMs,
                  row.lastErrorCategory,
                  row.serverRecordIdHash,
                  row.leaseIdHash,
                  row.leaseExpiresAtMs,
                  row.confirmedAtMs,
                  row.createdAtMs,
                  row.updatedAtMs,
                ],
            ]),
          ),
        )
        .toString();
  }
}
