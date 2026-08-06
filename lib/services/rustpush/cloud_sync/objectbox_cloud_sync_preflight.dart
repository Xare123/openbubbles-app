import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';

import 'cloud_sync_production_preflight.dart';

/// Reads the local mutation fence in one ObjectBox transaction.
///
/// Keeping the active coordinator-lease check and outbox count in the same
/// snapshot prevents a manual shadow run from observing a torn local state.
final class ObjectBoxCloudSyncPreflightReader {
  ObjectBoxCloudSyncPreflightReader({
    required Store store,
    DateTime Function()? now,
  }) : _store = store,
       _leases = store.box<CloudSyncLeaseEntity>(),
       _outbox = store.box<CloudOutboxOperationEntity>(),
       _now = now ?? DateTime.now;

  factory ObjectBoxCloudSyncPreflightReader.fromDatabase() =>
      ObjectBoxCloudSyncPreflightReader(store: Database.store);

  final Store _store;
  final Box<CloudSyncLeaseEntity> _leases;
  final Box<CloudOutboxOperationEntity> _outbox;
  final DateTime Function() _now;

  CloudSyncLocalPreflightState read() {
    return _store.runInTransaction(TxMode.read, () {
      final nowMs = _now().millisecondsSinceEpoch;
      final query =
          _leases
              .query(CloudSyncLeaseEntity_.expiresAtMs.greaterThan(nowMs))
              .build()
            ..limit = 1;
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
