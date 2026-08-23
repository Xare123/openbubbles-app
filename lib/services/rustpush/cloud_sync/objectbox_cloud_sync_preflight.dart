import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';

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
        return CloudSyncLocalPreflightState(
          objectBoxReady: true,
          coordinatorLeaseActive: query.findFirst() != null,
          outboxCount: _outbox.count(),
        );
      } finally {
        query.close();
      }
    });
  }
}
