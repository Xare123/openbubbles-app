import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_persistent_keys.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tooling/cloud_sync/inspect_cloud_sync_control_state.dart';

void main() {
  test('journal convergence reports content-free canonical fidelity counts', () async {
    final directory = await Directory.systemTemp.createTemp('cloud-inspector-local-send-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await openStore(directory: directory.path);
    try {
      final chat = Chat(guid: 'private-chat')
        ..ckSyncState = true ..ckRecordId = 'private-chat-record';
      db.box<Chat>().put(chat);
      final message = Message(guid: 'private-message', text: 'private text',
        attributedBody: [AttributedBody.raw('private text')])
        ..ckSyncState = true ..ckRecordId = 'private-message-record';
      message.chat.target = chat;
      final messageId = db.box<Message>().put(message);
      db.box<CloudSyncLocalSendIntentEntity>().put(CloudSyncLocalSendIntentEntity(
        intentKey: 'private-intent', accountFingerprint: 'A' * 43, writerEpoch: 1,
        localMessageId: messageId, messageGuidHash: 'B' * 64, sourceSha256: 'C' * 64,
        state: 2, createdAtMs: 1, updatedAtMs: 1));
    } finally { db.close(); }
    final report = await inspectCloudSyncControlState(directory);
    expect((report['outboundControl'] as Map)['journalMessageRows'],
        {'present': 1, 'readable': 1, 'legacyMessageCkSynced': 1, 'legacyChatCkSynced': 1});
    expect(jsonEncode(report), isNot(contains('private-')));
    expect(jsonEncode(report), isNot(contains('private text')));
  });
  for (final intactSource in [true, false]) {
    test(
      'identity input inspection preserves source (intact=$intactSource)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'cloud-inspector-identity-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final scope = CloudSyncScope(
          accountFingerprint: 'A' * 43,
          container: 'com.apple.messages.cloud',
          database: 'private',
          zone: 'chatManateeZone',
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        final db = await openStore(directory: directory.path);
        try {
          db.box<CloudSyncCheckpointEntity>().put(
            CloudSyncCheckpointEntity(
              checkpointKey: cloudSyncPersistentScopeKey(scope),
              accountFingerprint: scope.accountFingerprint,
              container: scope.container,
              database: scope.database,
              zone: scope.zone,
              streamKind: scope.streamKind.name,
              persistenceLane: scope.persistenceLane.name,
              fetchedSequence: 1,
              appliedSequence: 0,
              lastSuccessfulAtMs: 1,
              updatedAtMs: 1,
            ),
          );
          db.box<CloudInboxChangeEntity>().put(
            CloudInboxChangeEntity(
              changeKey: 'private-change',
              changeIdHash: 'B' * 43,
              scopeKey: cloudSyncPersistentScopeKey(scope),
              accountFingerprint: scope.accountFingerprint,
              zone: scope.zone,
              serverRecordIdHash: 'C' * 43,
              etagHash: 'D' * 43,
              encryptedServerRecordId: 'private-record',
              changeType: 'save',
              encryptedPayloadRef: intactSource
                  ? 'obcs2.ref.${'E' * 43}'
                  : null,
              payloadSha256: 'a' * 64,
              batchId: 'private-batch',
              fetchSequence: 1,
              status: CloudInboxStatus.retainedUnprojected.index,
              failureCategory: 'unsupportedService',
              createdAtMs: 1,
              updatedAtMs: 1,
            ),
          );
        } finally {
          db.close();
        }
        final data = File('${directory.path}${Platform.pathSeparator}data.mdb');
        final before = sha256.convert(await data.readAsBytes());
        final report = await inspectCloudSyncControlState(directory);
        expect(sha256.convert(await data.readAsBytes()), before);
        final result =
            (report['chatIdentityObservationInputs'] as List).single as Map;
        expect(result['writeAuthorized'], false);
        expect(
          result['status'],
          intactSource ? 'readyForNativeObservation' : 'blocked',
        );
        if (intactSource) {
          expect(result['retainedSaves'], 1);
          expect(result['retainedTombstones'], 0);
          expect(result['appliedSequence'], 0);
        } else {
          expect(
            result['safeCode'],
            'cloud_sync_chat_identity_source_incomplete',
          );
        }
        expect(jsonEncode(report), isNot(contains('private-')));
        expect(jsonEncode(report), isNot(contains('obcs2.ref.')));
      },
    );
  }
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
      expect(report['schema'], 12);
      expect((report['outboundControl'] as Map)['journalStates'], isEmpty);
      expect((report['outboundControl'] as Map)['journalMessageRows'],
          {'present': 0, 'readable': 0, 'legacyMessageCkSynced': 0, 'legacyChatCkSynced': 0});
      expect((report['outboundControl'] as Map)['operations'], isEmpty);
      expect(report['chatIdentityObservationInputs'], isEmpty);
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

  test(
    'distinguishes rendered unsends from genuinely blank messages',
    () async {
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
    },
  );

  test(
    'native version inventory scopes by record plus scope, generation, zone',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cloud-inspector-native-versions-',
      );
      addTearDown(() => directory.delete(recursive: true));
      CloudInboxChangeEntity versionRow({
        required String changeKey,
        required String scopeKey,
        required int generation,
        required String zone,
        required String serverRecordIdHash,
        required String? etagHash,
        required int fetchSequence,
        String? payloadSha256,
        String changeType = 'save',
        bool isTombstone = false,
      }) {
        return CloudInboxChangeEntity(
          changeKey: changeKey,
          changeIdHash: '$changeKey-hash',
          scopeKey: scopeKey,
          accountFingerprint: 'private-account',
          zone: zone,
          serverRecordIdHash: serverRecordIdHash,
          etagHash: etagHash,
          changeType: changeType,
          isTombstone: isTombstone,
          encryptedPayloadRef: 'private-payload-ref',
          payloadSha256: payloadSha256,
          batchId: 'private-batch',
          generation: generation,
          fetchSequence: fetchSequence,
          status: 3,
          createdAtMs: 1,
          updatedAtMs: 1,
        );
      }

      final db = await openStore(directory: directory.path);
      try {
        db.box<CloudInboxChangeEntity>().putMany([
          // Same scoped record, two etags: candidate version pair.
          versionRow(changeKey: 'private-change-a1', scopeKey: 'private-scope-a', generation: 2, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-a', etagHash: 'private-etag-aaa', fetchSequence: 1),
          versionRow(changeKey: 'private-change-a2', scopeKey: 'private-scope-a', generation: 2, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-a', etagHash: 'private-etag-bbb', fetchSequence: 2),
          // Same bare record hash in another scope: must not merge with A.
          versionRow(changeKey: 'private-change-b1', scopeKey: 'private-scope-b', generation: 2, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-a', etagHash: 'private-etag-aaa', fetchSequence: 3),
          // Exact retry: one etag, one payload, one change type.
          versionRow(changeKey: 'private-change-c1', scopeKey: 'private-scope-c', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-c', etagHash: 'private-etag-ccc', payloadSha256: 'private-payload-1', fetchSequence: 4),
          versionRow(changeKey: 'private-change-c2', scopeKey: 'private-scope-c', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-c', etagHash: 'private-etag-ccc', payloadSha256: 'private-payload-1', fetchSequence: 5),
          // Missing tag: cannot prove a version pair.
          versionRow(changeKey: 'private-change-d1', scopeKey: 'private-scope-d', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-d', etagHash: null, fetchSequence: 6),
          // Save plus tombstone delete with distinct etags: candidate with
          // tombstone context. A tombstone alone is never an unsend verdict.
          versionRow(changeKey: 'private-change-e1', scopeKey: 'private-scope-e', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-e', etagHash: 'private-etag-eee', fetchSequence: 7),
          versionRow(changeKey: 'private-change-e2', scopeKey: 'private-scope-e', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-e', etagHash: 'private-etag-fff', fetchSequence: 8, changeType: 'delete', isTombstone: true),
          // Same etag with changed payload: inconsistent, never exactRetry.
          versionRow(changeKey: 'private-change-f1', scopeKey: 'private-scope-f', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-f', etagHash: 'private-etag-ggg', payloadSha256: 'private-payload-2', fetchSequence: 9),
          versionRow(changeKey: 'private-change-f2', scopeKey: 'private-scope-f', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-f', etagHash: 'private-etag-ggg', payloadSha256: 'private-payload-3', fetchSequence: 10),
          // Empty etag counts as missing, not as a distinct version.
          versionRow(changeKey: 'private-change-g1', scopeKey: 'private-scope-g', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-g', etagHash: '', fetchSequence: 11),
          // Same etag with no payload digest on either row: same-etag-only,
          // neither a proven exact retry nor an inconsistency.
          versionRow(changeKey: 'private-change-h1', scopeKey: 'private-scope-h', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-h', etagHash: 'private-etag-hhh', fetchSequence: 12),
          versionRow(changeKey: 'private-change-h2', scopeKey: 'private-scope-h', generation: 1, zone: 'messageManateeZone', serverRecordIdHash: 'private-record-h', etagHash: 'private-etag-hhh', fetchSequence: 13),
        ]);
      } finally {
        db.close();
      }
      final data = File('${directory.path}${Platform.pathSeparator}data.mdb');
      final before = sha256.convert(await data.readAsBytes());
      final report = await inspectCloudSyncControlState(directory);
      expect(sha256.convert(await data.readAsBytes()), before);
      final versions = report['nativeRecordVersions'] as Map;
      expect(versions['scopedRecordGroups'], 8);
      expect(versions['multiRowGroups'], 5);
      expect(versions['changedEtagGroups'], 2);
      expect(versions['exactRetryGroups'], 1);
      expect(versions['inconsistentRedeliveryGroups'], 1);
      expect(versions['sameEtagOnlyGroups'], 1);
      expect(versions['missingTagGroups'], 2);
      expect(versions['tombstoneGroups'], 1);
      expect(versions['candidateVersionPairGroups'], 2);
      expect(versions['exampleCap'], 5);
      final examples = versions['examples'] as List;
      expect(examples.length, 2);
      final first = examples.first as Map;
      expect(first['zone'], 'messageManateeZone');
      expect(first['generation'], 2);
      expect(first['rows'], 2);
      expect(first['distinctEtags'], 2);
      expect(first['versionClass'], 'changedEtagCandidate');
      expect(first['etagsTruncated'], false);
      expect(first['payloadsTruncated'], false);
      expect(jsonEncode(report), isNot(contains('private-')));
    },
  );

  test('native version caps preserve counts and separate zones/generations', () async {
    final directory = await Directory.systemTemp.createTemp('cloud-inspector-caps-');
    addTearDown(() => directory.delete(recursive: true));
    var sequence = 0;
    CloudInboxChangeEntity row(String record, String tag, String digest,
        {int generation = 1, String zone = 'messageManateeZone'}) {
      sequence++;
      return CloudInboxChangeEntity(
        changeKey: 'private-change-$sequence',
        changeIdHash: 'private-change-hash-$sequence',
        scopeKey: 'private-scope', accountFingerprint: 'private-account',
        generation: generation, zone: zone, serverRecordIdHash: record,
        etagHash: tag, payloadSha256: digest, changeType: 'save',
        isTombstone: false, batchId: 'private-batch', fetchSequence: sequence,
        status: 3, createdAtMs: 1, updatedAtMs: 1,
      );
    }
    final db = await openStore(directory: directory.path);
    try {
      db.box<CloudInboxChangeEntity>().putMany([
        for (var i = 0; i < 20; i++)
          row('private-record-0', 'private-etag-$i', 'private-payload-$i'),
        // Repeated overflow must not inflate the distinct lower bounds.
        for (var i = 0; i < 30; i++)
          row('private-record-0', 'private-etag-19', 'private-payload-19'),
        row('private-record-0', 'private-etag-0', 'private-payload-0', generation: 2),
        row('private-record-0', 'private-etag-0', 'private-payload-0', zone: 'chatManateeZone'),
        for (var group = 1; group < 8; group++) ...[
          row('private-record-$group', 'private-etag-a', 'private-payload-a'),
          row('private-record-$group', 'private-etag-b', 'private-payload-b'),
        ],
        row('private-empty-digest', 'private-etag', ''),
        row('private-empty-digest', 'private-etag', ''),
      ]);
    } finally { db.close(); }
    final data = File('${directory.path}${Platform.pathSeparator}data.mdb');
    final before = sha256.convert(await data.readAsBytes());
    final report = await inspectCloudSyncControlState(directory);
    expect(sha256.convert(await data.readAsBytes()), before);
    final versions = report['nativeRecordVersions'] as Map;
    expect(versions['scopedRecordGroups'], 11);
    expect(versions['multiRowGroups'], 9);
    expect(versions['candidateVersionPairGroups'], 8);
    expect(versions['exactRetryGroups'], 0);
    expect(versions['sameEtagOnlyGroups'], 1);
    final examples = versions['examples'] as List;
    expect(examples, hasLength(5));
    final capped = examples.cast<Map>().singleWhere((e) => e['rows'] == 50);
    expect(capped['distinctEtags'], 16);
    expect(capped['distinctPayloadDigests'], 16);
    expect(capped['etagsTruncated'], true);
    expect(capped['payloadsTruncated'], true);
    expect(capped['rowsWithPayloadDigest'], 50);
    expect(jsonEncode(report), isNot(contains('private-')));
  });
}
