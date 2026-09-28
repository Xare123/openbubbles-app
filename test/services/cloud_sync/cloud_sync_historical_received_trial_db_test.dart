@Tags(['requires-objectbox'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_journal.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_source.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_received_trial.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_staging.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_consumer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_protector.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_historical_import_controller_test.dart' as fixtures;
import 'cloud_sync_historical_received_trial_test.dart' show requestFrom;

class _UnusedProtector extends Fake implements CloudSyncProtector {}

void main() {
  late Directory directory;
  late Store store;
  late CloudSyncHistoricalReceivedEndpointTrial trial;
  late CloudSyncHistoricalReceivedEndpointTrial otherTrial;
  late CloudSyncHistoricalArchiveRequest request;
  late CloudSyncHistoricalArchiveJournal journal;
  late CloudSyncHistoricalProtectedSourceBinding sealed;
  late List<int> bytes;
  late int intentId;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('historical-trial-db-');
    store = await openStore(directory: directory.path);
    final source = CloudSyncHistoricalImportSource(
      snapshot: fixtures.historicalImportTestSnapshot(),
      label: 'Synthetic history',
    );
    final rows = (await source.snapshot.readPage(limit: 3)).views;
    trial = await CloudSyncHistoricalReceivedEndpointTrial.select(
      source: source,
      guid: rows[1].guid,
    );
    otherTrial = await CloudSyncHistoricalReceivedEndpointTrial.select(
      source: source,
      guid: rows[0].guid,
    );
    final selected = (await trial.source.snapshot.readExact(rows[1].guid))!;
    request = requestFrom(selected, trial.source.snapshot);
    store.box<Chat>().put(
      Chat(
        guid: request.chatGuid,
        chatIdentifier: request.peerAddress,
        style: 45,
      ),
    );
    bytes = utf8.encode(
      jsonEncode(
        stagedHistoricalPayload(request: request, text: selected.text!),
      ),
    );
    sealed = CloudSyncHistoricalProtectedSourceBinding(
      accountFingerprint: request.accountFingerprint,
      protectedStoreIdentity: request.protectedStoreIdentity,
      snapshotSha256: request.snapshotSha256,
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
      protectedReference: 'obcs2.ref.${'Q' * 43}',
      leaseReference: 'obcs2.lease.${'c' * 32}',
      payloadSha256: historicalBytesSha256(bytes),
      payloadLength: bytes.length,
    );
    journal = CloudSyncHistoricalArchiveJournal(
      store: store,
      accountFingerprint: request.accountFingerprint,
      protectedStoreIdentity: request.protectedStoreIdentity,
      snapshotSha256: request.snapshotSha256,
    );
    intentId = journal.adopt(sealed).id;
    journal.markSourceLeaseCommitted(
      intentId: intentId,
      expectedSource: sealed,
    );
  });
  tearDown(() async {
    if (!store.isClosed()) store.close();
    await directory.delete(recursive: true);
  });

  for (final mode in ['default', 'different row', 'exact row']) {
    test(
      'real-DB received trial $mode keeps ordinary discovery and confirmation',
      () async {
        var consumed = 0;
        var discovered = 0;
        final dispositions = <CloudSyncHistoricalArchiveDisposition>[];
        final coordinator = CloudSyncHistoricalArchiveCoordinator(
          store: store,
          journal: journal,
          durable: ObjectBoxCloudSyncStore(
            store: store,
            protector: _UnusedProtector(),
          ),
          validate: () async {},
          stage: (candidate, data) async => StagedHistoricalSource(
            key: candidate.sourceSha256,
            guid: candidate.guid,
            sha256: sealed.payloadSha256,
            byteLength: sealed.payloadLength,
          ),
          discover: (_) async {
            discovered++;
            return false;
          },
          consume: (selection) async {
            consumed++;
            expect(selection.request.guid, request.guid);
            expect(selection.request.sourceSha256, request.sourceSha256);
            expect(selection.intentId, intentId);
            // Reaching the queue is not remote success. Ordinary confirmation
            // must still block advancement even for the exact trial selection.
            return const CloudSyncLocalSendConsumerResult(outboxBlocked: true);
          },
          receivedEndpointTrial: mode == 'exact row'
              ? trial
              : mode == 'different row'
              ? otherTrial
              : null,
          onDisposition: dispositions.add,
        );
        if (mode == 'exact row') {
          await expectLater(
            coordinator(request, bytes),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'code',
                'cloud_sync_historical_archive_confirmation_pending',
              ),
            ),
          );
          expect(consumed, 1);
          expect(dispositions, isEmpty);
        } else {
          await coordinator(request, bytes);
          expect(consumed, 0);
          expect(dispositions, [
            CloudSyncHistoricalArchiveDisposition.retainedMissingMetadata,
          ]);
        }
        expect(discovered, 1);
        expect(store.box<CloudOutboxOperationEntity>().count(), 0);
        final retained = store
            .box<CloudSyncHistoricalArchiveIntentEntity>()
            .get(intentId)!;
        expect(retained.state, 1);
        expect(retained.admittedOperationId, isNull);
        expect(retained.protectedSourceBinding, sealed.encode());
      },
    );
  }
}
