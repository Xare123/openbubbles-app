import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_producer.dart';

/// Fresh local-lane ownership, not remote deduplication or upload proof. The
/// coordinator still performs exact remote discovery and native dispatch guards.
/// No current account, message flags or chat alias manufactures a send receipt.
final class ObjectBoxHistoricalOwnership extends HistoricalOwnershipRegistry {
  ObjectBoxHistoricalOwnership({required this.store, required this.journal});

  final Store store;
  final CloudSyncHistoricalArchiveJournal journal;

  static String _guidHash(String domain, String guid) =>
      sha256.convert(utf8.encode(jsonEncode([domain, guid]))).toString();

  static List<T> _matches<T>(QueryBuilder<T> builder) {
    final query = builder.build()..limit = 2;
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  @override
  CloudSyncHistoricalDedupeVerdict resolve(
    CloudSyncHistoricalArchiveRequest request,
  ) {
    if (store.isClosed() ||
        !journal.isBoundToStore(store) ||
        request.accountFingerprint != journal.accountFingerprint ||
        request.protectedStoreIdentity != journal.protectedStoreIdentity ||
        request.snapshotSha256 != journal.snapshotSha256) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
    return store.runInTransaction(TxMode.read, () {
      // Resume exact historical ownership first, even if visible history later
      // changed. Unknown outcomes require readback, not a new dispatch or a skip
      // that strands the old operation. Native pre-dispatch guards remain intact.
      if (journal.read(
            messageGuidHash: request.guidHash,
            sourceSha256: request.sourceSha256,
          ) !=
          null) {
        return CloudSyncHistoricalDedupeVerdict.proceed;
      }
      final sendHash = _guidHash('cloud-sync-local-send-guid-v1', request.guid);
      final receivedHash = _guidHash(
        'cloud-sync-received-archive-guid-v1',
        request.guid,
      );
      // Across accounts deliberately: a foreign/ambiguous owner is retained,
      // not silently reattributed to the newest login. These fields are not all
      // indexed; limits bound returned rows, not database scan cost.
      final mutations = _matches(
        store.box<CloudSyncLocalMutationIntentEntity>().query(
          CloudSyncLocalMutationIntentEntity_.targetGuidHash.equals(sendHash),
        ),
      );
      if (mutations.isNotEmpty) {
        return CloudSyncHistoricalDedupeVerdict.retainConflict;
      }
      final sends = _matches(
        store.box<CloudSyncLocalSendIntentEntity>().query(
          CloudSyncLocalSendIntentEntity_.messageGuidHash.equals(sendHash),
        ),
      );
      final received = _matches(
        store.box<CloudSyncReceivedArchiveIntentEntity>().query(
          CloudSyncReceivedArchiveIntentEntity_.messageGuidHash.equals(
            receivedHash,
          ),
        ),
      );
      if (sends.isEmpty && received.isEmpty) {
        return CloudSyncHistoricalDedupeVerdict.proceed;
      }
      if (sends.length + received.length != 1) {
        return CloudSyncHistoricalDedupeVerdict.retainConflict;
      }
      if (sends.isNotEmpty) {
        final send = sends.single;
        return send.accountFingerprint == journal.accountFingerprint &&
                send.state >= 1 &&
                send.state <= 3 &&
                send.idsConfirmationVersion == 2
            ? CloudSyncHistoricalDedupeVerdict.skipOwned
            : CloudSyncHistoricalDedupeVerdict.retainConflict;
      }
      final incoming = received.single;
      return incoming.accountFingerprint == journal.accountFingerprint &&
              incoming.state >= 0 &&
              incoming.state <= 4 &&
              (incoming.origin == 0 || incoming.origin == 1)
          ? CloudSyncHistoricalDedupeVerdict.skipOwned
          : CloudSyncHistoricalDedupeVerdict.retainConflict;
    });
  }
}
