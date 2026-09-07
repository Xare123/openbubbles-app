import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tooling/cloud_sync/inspect_cloud_sync_control_state.dart';

void main() {
  test(
    'offline inspector separates retained saves from clean deletions without identifiers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cloud-inspector-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final db = await openStore(directory: directory.path);
      try {
        final rows = <CloudInboxChangeEntity>[];
        for (var i = 0; i < 7; i++) {
          rows.add(
            CloudInboxChangeEntity(
              changeKey: 'private-change-$i',
              changeIdHash: 'private-change-hash-$i',
              scopeKey: 'private-scope',
              accountFingerprint: 'private-account',
              zone: 'chatManateeZone',
              serverRecordIdHash: 'private-record-$i',
              changeType: i == 1 || i == 6 ? 'save' : 'delete',
              isTombstone: i != 1 && i != 6,
              batchId: 'private-batch',
              fetchSequence: i + 1,
              status: i == 0 ? 1 : 3,
              failureCategory: i == 1
                  ? 'unsupportedService'
                  : i == 3
                  ? 'conflict'
                  : i == 6
                  ? 'outOfScopeService'
                  : null,
              preflightCategory: i == 4 ? 'malformedRecord' : null,
              preflightCode: i == 5 ? 'private-native-code' : null,
              createdAtMs: 1,
              updatedAtMs: 1,
            ),
          );
        }
        db.box<CloudInboxChangeEntity>().putMany(rows);
      } finally {
        db.close();
      }
      final data = File('${directory.path}${Platform.pathSeparator}data.mdb');
      final before = sha256.convert(await data.readAsBytes());
      final report = await inspectCloudSyncControlState(directory);
      expect(sha256.convert(await data.readAsBytes()), before);
      expect(report['schema'], 9);
      final group = (report['inboxGroups'] as List).single as Map;
      expect(group['zones'], ['chatManateeZone']);
      expect(group['rows'], 7);
      expect(group['statuses'], {'applied': 1, 'retainedUnprojected': 6});
      expect(group['retainedSaves'], 2);
      expect(group['retainedUnclassifiedTombstones'], 1);
      expect(group['retainedOther'], 3);
      expect(group['failureCategories'], {
        'unsupportedService': 1,
        'conflict': 1,
        'outOfScopeService': 1,
      });
      expect(jsonEncode(report), isNot(contains('private-')));
    },
  );

  test('distinguishes rendered unsends from genuinely blank messages', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cloud-inspector-retraction-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final db = await openStore(directory: directory.path);
    try {
      final retraction = MessageSummaryInfo.empty()..retractedParts = [0];
      db.box<Message>().putMany([
        Message(guid: 'private-unsent', messageSummaryInfo: [retraction]),
        Message(guid: 'private-blank'),
        Message(
          guid: 'private-unrendered-summary',
          messageSummaryInfo: [MessageSummaryInfo.empty(), retraction],
        ),
      ]);
    } finally {
      db.close();
    }
    final data = File('${directory.path}${Platform.pathSeparator}data.mdb');
    final before = sha256.convert(await data.readAsBytes());
    final report = await inspectCloudSyncControlState(directory);
    expect(sha256.convert(await data.readAsBytes()), before);
    final shapes = report['legacyChatShapeCounts'] as Map;
    // Keep the raw content count comparable with older inspector reports.
    expect(shapes['visibleMessagesWithoutRenderableContent'], 3);
    expect(shapes['messagesWithRetractionMetadata'], 2);
    expect(shapes['messagesWithUnrenderedRetractions'], 1);
    expect(shapes['messagesWithRetractionPartBuildFailure'], 0);
    expect(shapes['contentlessMessagesWithRetractionPlaceholder'], 1);
    expect(shapes['visibleMessagesWithoutContentOrRetraction'], 2);
    expect(jsonEncode(report), isNot(contains('private-')));
  });
}
