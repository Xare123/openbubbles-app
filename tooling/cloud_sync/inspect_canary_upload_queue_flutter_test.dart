import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_journal.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Explicit offline-only tooling. Never opens the source as a database, sends
// network requests, changes a journal, or prints identifiers/message content.
void main() {
  test('inspect upload queue and an explicitly excluded origin', () async {
    final source = Platform.environment['OPENBUBBLES_OBJECTBOX_INSPECT_DIR'];
    final excluded = Platform.environment['OPENBUBBLES_EXCLUDED_MESSAGE_GUID'];
    final testText = Platform.environment['OPENBUBBLES_TEST_MESSAGE_TEXT'];
    expect(source, isNotNull);
    expect(excluded, matches(RegExp(r'^[0-9a-fA-F-]{36}$')));
    // A locally unchanged file can still be an inconsistent device transfer.
    // Require the capture tool's three-way device/file hash qualification before
    // copying or opening any ObjectBox data. Historical unqualified copies are
    // not made trustworthy by passing this inspector's final local hash check.
    final qualificationFile = File('$source/capture-qualification.json');
    expect(qualificationFile.existsSync(), isTrue,
        reason: 'A stable device capture qualification is required');
    final qualification = jsonDecode(await qualificationFile.readAsString())
        as Map<String, dynamic>;
    expect(qualification['stable'], isTrue,
        reason: 'Do not inspect an unqualified device capture');
    expect(qualification['package'], 'com.bluebubbles.messaging.cloudkitcanary');
    final file = File('$source/data.mdb');
    final before = await sha256.bind(file.openRead()).first;
    expect(qualification['databaseSha256'], before.toString());
    expect(qualification['remoteBeforeSha256'], before.toString());
    expect(qualification['remoteAfterSha256'], before.toString());
    expect(qualification['bytes'], await file.length());
    final root = Directory(r'C:\Codex\OpenBubblesReview\scratch');
    final staging = await root.createTemp('canary-upload-queue-');
    Store? store;
    try {
      await file.copy('${staging.path}/data.mdb');
      store = await openStore(directory: staging.path);
      final report = store.runInTransaction(TxMode.read, () {
        final intents = store!.box<CloudSyncLocalSendIntentEntity>().getAll();
        final outbox = store.box<CloudOutboxOperationEntity>().getAll();
        final authorities = store.box<CloudKitWriterAuthorityEntity>().getAll();
        final checkpoints = store.box<CloudSyncCheckpointEntity>().getAll();
        final zoneReports = <Map<String, Object?>>[];
        for (final checkpoint in checkpoints) {
          final query = store.box<CloudInboxChangeEntity>().query(
            CloudInboxChangeEntity_.scopeKey.equals(checkpoint.checkpointKey) &
            CloudInboxChangeEntity_.generation.equals(checkpoint.generation),
          ).build();
          final rows = <CloudInboxChangeEntity>[];
          try {
            rows.addAll(query.find());
          } finally {
            query.close();
          }
          final counts = <String, int>{};
          for (final row in rows) {
            final status = row.status >= 0 && row.status <= 3
                ? '${row.status}' : 'invalid';
            final change = const {'save', 'delete'}.contains(row.changeType)
                ? row.changeType : 'invalid';
            final key = '$status/$change/tombstone:${row.isTombstone}';
            counts.update(key, (n) => n + 1, ifAbsent: () => 1);
          }
          zoneReports.add({
            'zone': const {'chatManateeZone', 'messageManateeZone',
              'attachmentManateeZone'}.contains(checkpoint.zone)
                ? checkpoint.zone : 'other',
            'hasPersistenceLane': checkpoint.persistenceLane != null,
            'generation': checkpoint.generation,
            'fetchedSequence': checkpoint.fetchedSequence,
            'appliedSequence': checkpoint.appliedSequence,
            'pendingBatch': checkpoint.pendingBatchId != null,
            'pendingToken': checkpoint.pendingFetchedTokenCiphertext != null,
            'hasSuccessfulFetch': checkpoint.lastSuccessfulAtMs > 0,
            'hasError': checkpoint.lastErrorCategory != null,
            'backoffAttempt': checkpoint.backoffAttempt,
            'hasNextEligibleTime': checkpoint.nextEligibleAtMs != 0,
            'inboxCounts': counts,
          });
        }
        final testMessages = <Message>[];
        if (testText != null && testText.isNotEmpty) {
          final query = store.box<Message>().query(Message_.text.equals(testText)).build();
          try {
            testMessages.addAll(query.find());
          } finally {
            query.close();
          }
        }
        final authorityStates = <String, int>{};
        for (final authority in authorities) {
          // Integer enums only. Do not expose account identifiers or permits.
          final key = 'owner:${authority.owner},state:${authority.state}';
          authorityStates.update(key, (n) => n + 1, ifAbsent: () => 1);
        }
        final excludedHash = sha256
            .convert(
              utf8.encode(
                jsonEncode(['cloud-sync-local-send-guid-v1', excluded]),
              ),
            )
            .toString();
        final excludedIntents = intents
            .where((i) => i.messageGuidHash == excludedHash)
            .toList();
        final knownOperations = intents
            .map((i) => i.admittedOperationId)
            .toSet();
        final states = <String, int>{};
        final readySourceShapes = <String, int>{};
        var missingOrDeletedSources = 0;
        for (final intent in intents) {
          final state = intent.state >= 0 && intent.state <= 3
              ? '${intent.state}'
              : 'invalid';
          states.update(state, (n) => n + 1, ifAbsent: () => 1);
          final message = store.box<Message>().get(intent.localMessageId);
          if (message == null || message.dateDeleted != null) {
            missingOrDeletedSources++;
          }
          if (intent.state == 1 && message != null) {
            final chat = message.chat.target;
            final intact = chat != null &&
                CloudSyncLocalSendIdentity.capture(message, chat,
                  message.guid ?? '',
                  expectedSourceSha256: intent.sourceSha256) != null;
            final shape = 'chatLinked:${chat != null},'
                'canonicalChat:${chat?.guid.startsWith('iMessage;') ?? false},'
                'messageMapped:${message.ckRecordId != null},'
                'deleted:${message.dateDeleted != null},'
                'sourceIntact:$intact,'
                'adopted:${intent.admittedOperationId != null}';
            readySourceShapes.update(shape, (n) => n + 1, ifAbsent: () => 1);
          }
        }
        return {
          'journalCount': intents.length,
          'writerAuthorityCount': authorities.length,
          'writerAuthorityStates': authorityStates,
          'journalStates': states,
          'readySourceShapes': readySourceShapes,
          'checkpointZones': zoneReports,
          'outboxCount': outbox.length,
          'outboxWithoutJournalLink': outbox
              .where((o) => !knownOperations.contains(o.operationId))
              .length,
          'missingOrDeletedJournalSources': missingOrDeletedSources,
          if (testText != null) 'testMessageCount': testMessages.length,
          if (testText != null) 'testMessageStates': [
            for (final message in testMessages) {
              'error': message.error,
              'pendingGuid': message.stagingGuid != null,
              'cloudMapped': message.ckRecordId != null,
              'chatLinked': message.chat.targetId != 0,
              'sendingServiceAssigned': message.sendingServiceId != null,
              'deleted': message.dateDeleted != null,
              'metadataPresent': message.metadata != null,
              'forwarded': message.hasBeenForwarded,
              'bodyCount': message.attributedBody.length,
              'hasAttachments': message.hasAttachments,
              'journalSourceStillMatches': intents.any((intent) =>
                  intent.localMessageId == message.id && message.chat.target != null &&
                  CloudSyncLocalSendIdentity.capture(message, message.chat.target!,
                    message.guid ?? '', expectedSourceSha256: intent.sourceSha256) != null),
            },
          ],
          'excludedOriginJournalCount': excludedIntents.length,
          'excludedOriginAdoptedCount': excludedIntents
              .where((i) => i.admittedOperationId != null)
              .length,
        };
      });
      expect(await sha256.bind(file.openRead()).first, before);
      // ignore: avoid_print
      print(
        'CANARY_UPLOAD_QUEUE=${jsonEncode({...report, 'sourceCaptureVerified': true, 'sourceUnchanged': true, 'notAnUploadAuthorization': true})}',
      );
    } finally {
      store?.close();
      // Dedicated scratch copy created above, not the retained source evidence.
      expect(staging.parent.absolute.path, root.absolute.path);
      await staging.delete(recursive: true);
    }
  });
}
