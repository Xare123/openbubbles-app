// Baseline characterization for CLOUD_SYNC_V2_RECENT_FIRST_AUDIT.md.
// These assertions expose omissions, not desired behavior. Replace them with
// complete reconciliation expectations when implementing the proposed fix.
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ObservedChatsService extends ChatsService {
  final List<String> added = [];

  @override
  Future<void> addChat(Chat chat) async {
    // Observe the real subscription's choice without creating controllers,
    // native services, notifications, or account-bound work.
    added.add(chat.guid);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _ObservedChatsService service;

  setUpAll(() async {
    directory = await Directory(
      '${Directory.current.path}/.dart_tool',
    ).createTemp('cloud-visibility-audit-');
    Database.store = await openStore(directory: directory.path);
    Database.chats = Database.store.box<Chat>();
    Database.messages = Database.store.box<Message>();
    Database.attachments = Database.store.box<Attachment>();
    Database.handles = Database.store.box<Handle>();
    ss.settings = Settings();
    ss.settings.finishedSetup.value = true;
  });

  tearDownAll(() async {
    Database.store.close();
    await directory.delete(recursive: true);
  });

  setUp(() {
    // Only this suite's synthetic database.
    Database.messages.removeAll();
    Database.chats.removeAll();
    service = _ObservedChatsService();
  });

  tearDown(() async {
    await service.countSub.cancel();
  });

  Chat seed(String guid, {bool withMessage = true, int day = 1}) {
    final chat = Chat(guid: guid);
    Database.chats.put(chat);
    if (withMessage) projectMessage(chat, day);
    return chat;
  }

  Future<void> waitForCount(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (service.currentCount != count && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.currentCount, count);
  }

  test(
    'baseline watcher omits the first usable conversations from zero',
    () async {
      service.onInit();
      // Let triggerImmediately deliver the initial empty snapshot.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      Database.store.runInTransaction(TxMode.write, () {
        seed('first', day: 2);
        seed('second', day: 3);
      });
      await waitForCount(2);
      expect(Database.messages.count(), 2);
      expect(service.added, isEmpty);
    },
  );

  test(
    'baseline watcher chooses one highest ID for a multi-chat commit',
    () async {
      seed('already-visible');
      service.onInit();
      await waitForCount(1);
      Database.store.runInTransaction(TxMode.write, () {
        seed('newest-message-low-id', day: 3);
        seed('older-message-high-id', day: 2);
      });
      await waitForCount(3);
      expect(service.added, ['older-message-high-id']);
    },
  );

  test(
    'late parent eligibility can select an already-visible higher ID',
    () async {
      final late = seed('late-parent-chat', withMessage: false);
      seed('already-visible-high-id');
      service.onInit();
      await waitForCount(1);
      projectMessage(late, 3);
      await waitForCount(2);
      expect(service.added, ['already-visible-high-id']);
    },
  );
}

void projectMessage(Chat chat, int day) {
  final date = DateTime.utc(2026, 9, day);
  final message = Message(
    guid: 'message-${chat.guid}',
    text: 'synthetic',
    isFromMe: true,
    dateCreated: date,
  )..chat.target = chat;
  Database.messages.put(message);
  chat.dbOnlyLatestMessageDate = date;
  Database.chats.put(chat);
}
