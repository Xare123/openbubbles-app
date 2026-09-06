import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Explicit offline-only tooling. Never opens the source as a database, sends
// network requests, changes a journal, or prints identifiers/message content.
void main() {
  test('inspect upload queue and an explicitly excluded origin', () async {
    final source = Platform.environment['OPENBUBBLES_OBJECTBOX_INSPECT_DIR'];
    final excluded = Platform.environment['OPENBUBBLES_EXCLUDED_MESSAGE_GUID'];
    expect(source, isNotNull);
    expect(excluded, matches(RegExp(r'^[0-9a-fA-F-]{36}$')));
    final file = File('$source/data.mdb');
    final before = await sha256.bind(file.openRead()).first;
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
        }
        return {
          'journalCount': intents.length,
          'writerAuthorityCount': authorities.length,
          'writerAuthorityStates': authorityStates,
          'journalStates': states,
          'outboxCount': outbox.length,
          'outboxWithoutJournalLink': outbox
              .where((o) => !knownOperations.contains(o.operationId))
              .length,
          'missingOrDeletedJournalSources': missingOrDeletedSources,
          'excludedOriginJournalCount': excludedIntents.length,
          'excludedOriginAdoptedCount': excludedIntents
              .where((i) => i.admittedOperationId != null)
              .length,
        };
      });
      expect(await sha256.bind(file.openRead()).first, before);
      // ignore: avoid_print
      print(
        'CANARY_UPLOAD_QUEUE=${jsonEncode({...report, 'sourceUnchanged': true, 'notAnUploadAuthorization': true})}',
      );
    } finally {
      store?.close();
      // Dedicated scratch copy created above, not the retained source evidence.
      expect(staging.parent.absolute.path, root.absolute.path);
      await staging.delete(recursive: true);
    }
  });
}
