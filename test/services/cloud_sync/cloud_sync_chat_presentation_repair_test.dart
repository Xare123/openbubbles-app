import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_presentation_repair.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Store store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'openbubbles-chat-presentation-repair-',
    );
    store = await openStore(directory: directory.path);
  });

  tearDown(() async {
    store.close();
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test(
    'backfills null and stale dates without moving newer state backward',
    () {
      final firstDate = DateTime.utc(2026, 9, 1, 10);
      final latestDate = DateTime.utc(2026, 9, 1, 12);
      final newerLocalDate = DateTime.utc(2026, 9, 1, 13);
      final deletedDate = DateTime.utc(2026, 9, 1, 14);

      final missingCache = Chat(guid: 'missing-cache-chat');
      final staleCache = Chat(guid: 'stale-cache-chat')
        ..dbOnlyLatestMessageDate = firstDate;
      final newerCache = Chat(guid: 'newer-cache-chat')
        ..dbOnlyLatestMessageDate = newerLocalDate;
      final noMessages = Chat(guid: 'no-messages-chat');
      final chatIds = store.box<Chat>().putMany([
        missingCache,
        staleCache,
        newerCache,
        noMessages,
      ]);

      store.box<Message>().putMany([
        Message(guid: 'first', dateCreated: firstDate)
          ..chat.targetId = chatIds[0],
        Message(guid: 'latest', dateCreated: latestDate)
          ..chat.targetId = chatIds[0],
        Message(guid: 'stale-latest', dateCreated: latestDate)
          ..chat.targetId = chatIds[1],
        Message(guid: 'older-than-cache', dateCreated: latestDate)
          ..chat.targetId = chatIds[2],
        Message(
          guid: 'deleted-newest',
          dateCreated: deletedDate,
          dateDeleted: deletedDate,
        )..chat.targetId = chatIds[1],
      ]);

      expect(repairCloudSyncChatLatestMessageDatesInStore(store), 2);
      expect(
        store.box<Chat>().get(chatIds[0])!.dbOnlyLatestMessageDate?.toUtc(),
        latestDate,
      );
      expect(
        store.box<Chat>().get(chatIds[1])!.dbOnlyLatestMessageDate?.toUtc(),
        latestDate,
      );
      expect(
        store.box<Chat>().get(chatIds[2])!.dbOnlyLatestMessageDate?.toUtc(),
        newerLocalDate,
      );
      expect(
        store.box<Chat>().get(chatIds[3])!.dbOnlyLatestMessageDate,
        isNull,
      );
      expect(repairCloudSyncChatLatestMessageDatesInStore(store), 0);
    },
  );

  test('single-message maintenance is monotonic', () {
    final existing = DateTime.utc(2026, 9, 1, 12);
    final chat = Chat(guid: 'chat')..dbOnlyLatestMessageDate = existing;

    expect(
      updateCloudSyncChatLatestMessageDate(
        chat,
        existing.subtract(const Duration(minutes: 1)),
      ),
      isFalse,
    );
    expect(chat.dbOnlyLatestMessageDate, existing);

    final newer = existing.add(const Duration(minutes: 1));
    expect(updateCloudSyncChatLatestMessageDate(chat, newer), isTrue);
    expect(chat.dbOnlyLatestMessageDate, newer);
  });
}
