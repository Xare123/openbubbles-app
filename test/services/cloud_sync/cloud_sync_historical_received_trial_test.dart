import 'dart:convert';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_archive_request.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_source.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_received_trial.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_historical_import_controller_test.dart' as fixtures;

CloudSyncHistoricalArchiveRequest requestFrom(
  CloudSyncHistoricalRowView row,
  CloudSyncHistoricalSnapshot snapshot,
) =>
    (assessHistoricalArchiveRow(row, snapshot.manifest, snapshot.account)
            as CloudSyncHistoricalArchiveEligible)
        .request;

CloudSyncHistoricalArchiveRequest changed(
  CloudSyncHistoricalArchiveRequest value, {
  String? guid,
  String? sourceSha256,
  String? snapshotSha256,
  String? account,
  String? store,
  String? peer,
  String? sender,
  String? chat,
  bool? sent,
}) => CloudSyncHistoricalArchiveRequest(
  guid: guid ?? value.guid,
  guidHash: value.guidHash,
  sourceSha256: sourceSha256 ?? value.sourceSha256,
  origin: sent == true
      ? CloudSyncHistoricalArchiveOrigin.historicalSent
      : value.origin,
  isFromMe: sent ?? value.isFromMe,
  chatGuid: chat ?? value.chatGuid,
  dateCreatedMs: value.dateCreatedMs,
  snapshotSha256: snapshotSha256 ?? value.snapshotSha256,
  accountFingerprint: account ?? value.accountFingerprint,
  protectedStoreIdentity: store ?? value.protectedStoreIdentity,
  textSha256: value.textSha256,
  senderAddress: sender ?? value.senderAddress,
  peerAddress: peer ?? value.peerAddress,
);

void main() {
  late CloudSyncHistoricalImportSource source;
  late String guid;
  setUp(() async {
    source = CloudSyncHistoricalImportSource(
      snapshot: fixtures.historicalImportTestSnapshot(),
      label: 'Synthetic history',
    );
    guid = (await source.snapshot.readPage(limit: 3)).views[1].guid;
  });

  test(
    'selection is one exact immutable received row, not a bulk enable',
    () async {
      final trial = await CloudSyncHistoricalReceivedEndpointTrial.select(
        source: source,
        guid: guid,
      );
      expect(trial.source.snapshot.manifest.messageCount, 1);
      expect(trial.source.identitySha256, isNot(source.identitySha256));
      expect(source.snapshot.manifest.messageCount, 3);
      final selected = (await trial.source.snapshot.readExact(guid))!;
      final original = (await source.snapshot.readExact(guid))!;
      expect(selected.text, original.text);
      expect(selected.senderAddress, original.senderAddress);
      expect(selected.dateCreatedMs, original.dateCreatedMs);
      expect(
        trial.permits(requestFrom(selected, trial.source.snapshot)),
        isTrue,
      );
      expect(trial.permits(requestFrom(original, source.snapshot)), isFalse);
      expect(
        trial.toString(),
        'CloudSyncHistoricalReceivedEndpointTrial(redacted)',
      );
      trial.requireSource(trial.source);
      expect(() => trial.requireSource(source), throwsStateError);
      expect(() => trial.requireSource(null), throwsStateError);
    },
  );

  test(
    'selection requires exact account, store, source, direction and parent',
    () async {
      final trial = await CloudSyncHistoricalReceivedEndpointTrial.select(
        source: source,
        guid: guid,
      );
      final request = requestFrom(
        (await trial.source.snapshot.readExact(guid))!,
        trial.source.snapshot,
      );
      for (final altered in [
        changed(request, guid: 'different-guid'),
        changed(request, sourceSha256: 'c' * 64),
        changed(request, snapshotSha256: 'd' * 64),
        changed(request, account: 'B' * 43),
        changed(request, store: 'obcs2.store.${'T' * 43}'),
        changed(request, peer: 'different@example.com'),
        changed(request, sender: 'different@example.com'),
        changed(request, chat: 'iMessage;-;different@example.com'),
        changed(request, sent: true),
      ]) {
        expect(trial.permits(altered), isFalse);
      }
      final repeated = await CloudSyncHistoricalReceivedEndpointTrial.select(
        source: source,
        guid: guid,
      );
      expect(repeated.source.identitySha256, trial.source.identitySha256);
      expect(repeated.permits(request), isTrue);
    },
  );

  test(
    'missing, duplicate, outgoing, media and deleted rows cannot be trialed',
    () async {
      await expectLater(
        CloudSyncHistoricalReceivedEndpointTrial.select(
          source: source,
          guid: 'missing',
        ),
        throwsStateError,
      );
      final encoded = source.snapshot.encodedRows.elementAt(1);
      for (final mutate in <void Function(List<dynamic>)>[
        (row) {
          row[8] = true;
          row[9] = 'me@example.com';
        },
        (row) {
          row[27] = true;
          row[28] = 1;
        },
        (row) {
          row[24] = true;
        },
      ]) {
        final row = jsonDecode(encoded) as List<dynamic>;
        mutate(row);
        final invalid = CloudSyncHistoricalImportSource(
          snapshot: CloudSyncHistoricalSnapshot.fromEncodedRows(
            encodedRows: [jsonEncode(row)],
            account: source.snapshot.account,
            accountHandles: source.snapshot.manifest.accountHandles,
            capturedAtMs: source.snapshot.manifest.capturedAtMs,
          ),
          label: source.label,
        );
        await expectLater(
          CloudSyncHistoricalReceivedEndpointTrial.select(
            source: invalid,
            guid: guid,
          ),
          throwsStateError,
        );
      }
      final duplicate = jsonDecode(encoded) as List<dynamic>;
      duplicate[20] = 4;
      final ambiguous = CloudSyncHistoricalImportSource(
        snapshot: CloudSyncHistoricalSnapshot.fromEncodedRows(
          encodedRows: [encoded, jsonEncode(duplicate)],
          account: source.snapshot.account,
          accountHandles: source.snapshot.manifest.accountHandles,
          capturedAtMs: source.snapshot.manifest.capturedAtMs,
        ),
        label: source.label,
      );
      await expectLater(
        CloudSyncHistoricalReceivedEndpointTrial.select(
          source: ambiguous,
          guid: guid,
        ),
        throwsStateError,
      );
    },
  );
}
