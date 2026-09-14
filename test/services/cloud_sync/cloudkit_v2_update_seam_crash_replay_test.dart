import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_merge_policy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_semantic_store_gateway.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic ObjectBox crash-replay test for the CloudKit v2 update seam.
///
/// Journals one durable page, closes before canonical projection, reopens,
/// projects once, promotes one cursor, redelivers the same change ID with a
/// mutated ETag, and proves no duplicate row and no latest-date regression.
///
/// No credentials, user data, live Apple services, or network.
void main() {
  final now = DateTime.utc(2026, 9, 14, 12);
  final latestDate = DateTime.utc(2026, 9, 1, 12);
  final scope = CloudSyncScope(
    accountFingerprint: _digest('A'),
    container: 'messages-container',
    database: 'private',
    zone: 'messageManateeZone',
  );
  final changeId = _digest('C');
  final etagOriginal = _digest('E');
  final etagMutated = _digest('F');
  final logicalKey = _digest('L');
  final batchOne = _digest('B');
  final batchTwo = _digest('Q');
  final tokenOne = _reference('T');

  late Directory directory;
  late Store objectBox;
  late ObjectBoxCloudSyncStore journalStore;
  late _SeamCanonicalAdapter adapter;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloudkit-v2-update-seam-',
    );
    objectBox = await openStore(directory: directory.path);
    journalStore = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: const _SeamProtector(),
      clock: () => now,
    );
    adapter = _SeamCanonicalAdapter(objectBox);
  });

  tearDown(() async {
    try {
      objectBox.close();
    } catch (_) {}
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'crash before projection replays once then ignores mutated ETag redelivery',
    () async {
      final fence = (await journalStore.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'update-seam-owner',
        now: now,
        leaseDuration: const Duration(hours: 1),
      ))!;
      final checkpoint = await journalStore.readCheckpoint(scope);
      final inserted = await journalStore.journalFetchedBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [
            CloudFetchedChange(
              changeId: changeId,
              recordIdHash: _digest('R'),
              etagHash: etagOriginal,
              type: CloudChangeType.save,
              encryptedServerRecordId: _reference('S'),
              protectedSystemFieldsReference: _reference('Y'),
              encryptedPayloadReference: _reference('P'),
              payloadSha256: List.filled(64, 'a').join(),
            ),
          ],
          batchId: batchOne,
          generation: checkpoint.generation,
          nextToken: tokenOne,
          hasMore: false,
        ),
        now: now,
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );
      expect(inserted, 1);
      expect(objectBox.box<CloudInboxChangeEntity>().getAll(), hasLength(1));
      var pending = await journalStore.readCheckpoint(scope);
      expect(pending.pendingBatchId, batchOne);
      expect(pending.fetchedToken, isNull);
      expect(pending.lastAppliedSequence, 0);

      objectBox.close();

      final reopenedAt = now.add(const Duration(minutes: 1));
      objectBox = await openStore(directory: directory.path);
      adapter = _SeamCanonicalAdapter(objectBox);
      journalStore = ObjectBoxCloudSyncStore(
        store: objectBox,
        protector: const _SeamProtector(),
        clock: () => reopenedAt,
      );
      final eligible = await journalStore.readEligibleInbox(
        scope,
        now: reopenedAt,
        limit: 10,
      );
      expect(eligible, hasLength(1));
      expect(eligible.single.change.changeId, changeId);
      expect(eligible.single.change.etagHash, etagOriginal);
      pending = await journalStore.readCheckpoint(scope);
      expect(pending.pendingBatchId, batchOne);
      expect(pending.fetchedToken, isNull);

      final gateway = ObjectBoxCloudSemanticStoreGateway(
        store: objectBox,
        canonicalAdapter: adapter,
        clock: () => reopenedAt,
      );
      await gateway.writeTransaction<void>(
        entry: eligible.single,
        leaseFence: fence,
        action: (transaction) {
          transaction.applyEntity(
            payload: CloudMessageEntityPayload(
              logicalEntityKeyHash: logicalKey,
              canonicalGuid: 'update-seam-message-guid',
              chatAliasKeyHash: _digest('H'),
              chatIdentifier: 'iMessage;-;update-seam-chat',
              body: 'update seam fixture',
              senderHandle: 'update-seam-handle',
              createdAt: latestDate,
            ),
            snapshot: CloudSemanticSnapshot(
              kind: CloudEntityKind.message,
              logicalEntityKeyHash: logicalKey,
              etagHash: etagOriginal,
              encryptedRawRecordReference: _reference('P'),
              createdAt: latestDate,
            ),
          );
          transaction.markChangeApplied(changeId);
        },
      );
      expect(adapter.commits, 1);
      expect(adapter.latestDate, latestDate);
      expect(objectBox.box<CloudInboxChangeEntity>().getAll().single.status, CloudInboxStatus.applied.index);
      expect(objectBox.box<CloudSemanticReplayEntity>().getAll(), hasLength(1));
      final promoted = await journalStore.readCheckpoint(scope);
      expect(promoted.pendingBatchId, isNull);
      expect(promoted.fetchedToken, tokenOne);
      expect(promoted.lastAppliedSequence, 1);

      final redeliveryAt = reopenedAt.add(const Duration(minutes: 1));
      // Reuse the still-valid owner fence: tryAcquireCoordinatorLease returns
      // null while another owner's lease is active, and redelivery arrives on
      // the same writer inside the original one-hour lease.
      final beforeRedelivery = await journalStore.readCheckpoint(scope);
      final redelivered = await journalStore.journalFetchedBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [
            CloudFetchedChange(
              changeId: changeId,
              recordIdHash: _digest('R'),
              etagHash: etagMutated,
              type: CloudChangeType.save,
              encryptedServerRecordId: _reference('S'),
              protectedSystemFieldsReference: _reference('Y'),
              encryptedPayloadReference: _reference('P'),
              payloadSha256: List.filled(64, 'a').join(),
            ),
          ],
          batchId: batchTwo,
          generation: beforeRedelivery.generation,
          nextToken: tokenOne,
          hasMore: false,
        ),
        now: redeliveryAt,
        leaseFence: fence,
        expectedGeneration: beforeRedelivery.generation,
        expectedFetchedToken: beforeRedelivery.fetchedToken,
      );

      expect(redelivered, 0);
      final inboxRows = objectBox.box<CloudInboxChangeEntity>().getAll();
      expect(inboxRows, hasLength(1));
      expect(inboxRows.single.changeIdHash, changeId);
      expect(inboxRows.single.etagHash, etagOriginal);
      expect(objectBox.box<CloudSemanticReplayEntity>().getAll(), hasLength(1));
      expect(adapter.commits, 1);
      expect(adapter.latestDate, latestDate);
      final stillEligible = await journalStore.readEligibleInbox(
        scope,
        now: redeliveryAt,
        limit: 10,
      );
      expect(stillEligible, isEmpty);
      final after = await journalStore.readCheckpoint(scope);
      expect(after.fetchedToken, tokenOne);
      expect(after.pendingBatchId, isNull);
      expect(after.lastAppliedSequence, 1);
    },
  );
}

String _digest(String character) => List.filled(43, character).join();

String _reference(String character) => 'obcs2.ref.' + _digest(character);

final class _SeamCanonicalAdapter implements CloudCanonicalSemanticEntityAdapter {
  _SeamCanonicalAdapter(this._store);

  final Store _store;
  int commits = 0;
  DateTime? latestDate;

  @override
  Store get store => _store;

  @override
  bool isActiveAccountScope({required CloudSyncScope scope, required int generation}) => true;

  @override
  bool entityExists({required CloudSyncScope scope, required int generation, required CloudEntityKind kind, required String logicalEntityKeyHash}) => commits > 0;

  @override
  void validateOwnershipEvidence({required CloudSyncScope scope, required int generation, required CloudEntityKind kind, required String logicalEntityKeyHash}) {}

  @override
  CloudCanonicalSemanticMutationReceipt applyEntity({required CloudSyncScope scope, required int generation, required CloudSemanticEntityPayload payload, required CloudSemanticSnapshot snapshot}) {
    commits++;
    if (payload is CloudMessageEntityPayload && payload.createdAt != null) {
      final createdAt = payload.createdAt!.toUtc();
      if (latestDate == null || createdAt.isAfter(latestDate!)) {
        latestDate = createdAt;
      }
    }
    return CloudCanonicalSemanticMutationReceipt.committed;
  }

  @override
  CloudCanonicalSemanticMutationReceipt applyTombstone({required CloudSyncScope scope, required int generation, required CloudSemanticTombstone tombstone}) {
    throw StateError('update seam fixture rejects tombstones');
  }
}

final class _SeamProtector implements CloudSyncProtector {
  const _SeamProtector();

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async {
    return base64Url.encode(utf8.encode(rawAccountIdentifier)).replaceAll('=', '');
  }

  @override
  Future<String> protect({required CloudSyncScope scope, required CloudSyncProtectedValueKind kind, required String plaintext}) async {
    return base64Url.encode(utf8.encode(scope.storageKey + '|' + kind.name + '|' + plaintext));
  }

  @override
  Future<String> unprotect({required CloudSyncScope scope, required CloudSyncProtectedValueKind kind, required String ciphertext}) async {
    final decoded = utf8.decode(base64Url.decode(ciphertext));
    final prefix = scope.storageKey + '|' + kind.name + '|';
    if (!decoded.startsWith(prefix)) {
      throw const FormatException('fixture scope mismatch');
    }
    return decoded.substring(prefix.length);
  }
}
