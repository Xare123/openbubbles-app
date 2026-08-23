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

void main() {
  final now = DateTime.utc(2026, 8, 2, 1);
  final scope = CloudSyncScope(
    accountFingerprint: _digest('A'),
    container: 'messages-container',
    database: 'private',
    zone: 'messageManateeZone',
  );
  final changeId = _digest('C');
  late Directory directory;
  late Store objectBox;
  late ObjectBoxCloudSyncStore journalStore;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-cloud-change-id-roundtrip-',
    );
    objectBox = await openStore(directory: directory.path);
    journalStore = ObjectBoxCloudSyncStore(
      store: objectBox,
      protector: const _RoundTripProtector(),
      clock: () => now,
    );
  });

  tearDown(() async {
    objectBox.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test(
    'native change ID survives journal, reopen, and semantic gateway handoff',
    () async {
      final fence = (await journalStore.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'roundtrip-owner',
        now: now,
        leaseDuration: const Duration(hours: 1),
      ))!;
      final checkpoint = await journalStore.readCheckpoint(scope);
      await journalStore.journalFetchedBatch(
        CloudFetchBatch(
          scope: scope,
          changes: [
            CloudFetchedChange(
              changeId: changeId,
              recordIdHash: _digest('R'),
              etagHash: _digest('E'),
              type: CloudChangeType.save,
              encryptedServerRecordId: _reference('S'),
              protectedSystemFieldsReference: _reference('F'),
              encryptedPayloadReference: _reference('P'),
              payloadSha256: List.filled(64, 'a').join(),
            ),
          ],
          batchId: _digest('B'),
          generation: checkpoint.generation,
          nextToken: _reference('T'),
          hasMore: false,
        ),
        now: now,
        leaseFence: fence,
        expectedGeneration: checkpoint.generation,
        expectedFetchedToken: checkpoint.fetchedToken,
      );

      final firstRead = (await journalStore.readEligibleInbox(
        scope,
        now: now,
        limit: 1,
      )).single;
      expect(firstRead.change.changeId, changeId);
      expect(
        objectBox.box<CloudInboxChangeEntity>().getAll().single.changeIdHash,
        changeId,
      );

      objectBox.close();
      objectBox = await openStore(directory: directory.path);
      journalStore = ObjectBoxCloudSyncStore(
        store: objectBox,
        protector: const _RoundTripProtector(),
        clock: () => now.add(const Duration(minutes: 1)),
      );
      final reopenedEntry = (await journalStore.readEligibleInbox(
        scope,
        now: now.add(const Duration(minutes: 1)),
        limit: 1,
      )).single;
      expect(reopenedEntry.change.changeId, changeId);

      final gateway = ObjectBoxCloudSemanticStoreGateway(
        store: objectBox,
        canonicalAdapter: _NoMutationCanonicalAdapter(
          objectBox,
          scope: scope,
          generation: checkpoint.generation,
        ),
        clock: () => now.add(const Duration(minutes: 1)),
      );
      await gateway.writeTransaction<void>(
        entry: reopenedEntry,
        leaseFence: fence,
        action: (transaction) {
          transaction.quarantineChange(changeId, 'roundtrip_fixture');
        },
      );

      final durableInbox = objectBox
          .box<CloudInboxChangeEntity>()
          .getAll()
          .single;
      expect(durableInbox.changeIdHash, changeId);
      expect(durableInbox.status, CloudInboxStatus.quarantined.index);
      expect(
        objectBox
            .box<CloudSemanticReplayEntity>()
            .getAll()
            .single
            .terminalOutcome,
        'quarantined',
      );
    },
  );
}

String _digest(String character) => List.filled(43, character).join();

String _reference(String character) => 'obcs2.ref.${_digest(character)}';

final class _NoMutationCanonicalAdapter
    implements CloudCanonicalSemanticEntityAdapter {
  _NoMutationCanonicalAdapter(
    this.store, {
    required this.scope,
    required this.generation,
  });

  @override
  final Store store;
  final CloudSyncScope scope;
  final int generation;

  @override
  bool isActiveAccountScope({
    required CloudSyncScope scope,
    required int generation,
  }) => scope == this.scope && generation == this.generation;

  @override
  bool entityExists({
    required CloudSyncScope scope,
    required int generation,
    required CloudEntityKind kind,
    required String logicalEntityKeyHash,
  }) => false;

  @override
  CloudCanonicalSemanticMutationReceipt applyEntity({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticEntityPayload payload,
    required CloudSemanticSnapshot snapshot,
  }) {
    throw StateError('canonical mutation is outside this fixture');
  }

  @override
  CloudCanonicalSemanticMutationReceipt applyTombstone({
    required CloudSyncScope scope,
    required int generation,
    required CloudSemanticTombstone tombstone,
  }) {
    throw StateError('canonical tombstone is outside this fixture');
  }
}

final class _RoundTripProtector implements CloudSyncProtector {
  const _RoundTripProtector();

  @override
  Future<String> fingerprintAccount(String rawAccountIdentifier) async {
    return base64Url
        .encode(utf8.encode(rawAccountIdentifier))
        .replaceAll('=', '');
  }

  @override
  Future<String> protect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String plaintext,
  }) async {
    return base64Url.encode(
      utf8.encode('${scope.storageKey}\u001f${kind.name}\u001f$plaintext'),
    );
  }

  @override
  Future<String> unprotect({
    required CloudSyncScope scope,
    required CloudSyncProtectedValueKind kind,
    required String ciphertext,
  }) async {
    final decoded = utf8.decode(base64Url.decode(ciphertext));
    final prefix = '${scope.storageKey}\u001f${kind.name}\u001f';
    if (!decoded.startsWith(prefix)) {
      throw const FormatException('fixture scope mismatch');
    }
    return decoded.substring(prefix.length);
  }
}
