import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/backend/queue/incoming_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, directory;
  late Chat chat;
  setUpAll(() async {
    root = await Directory(
      '${Directory.current.path}/build/test-temp',
    ).create(recursive: true);
    directory = await root.createTemp('received-persistence-');
    Database.store = await openStore(directory: directory.path);
    Database.messages = Database.store.box<Message>();
    Database.chats = Database.store.box<Chat>();
    Database.handles = Database.store.box<Handle>();
    chat = Chat(
      guid: 'iMessage;-;synthetic@example.com',
      style: 45,
      chatIdentifier: 'synthetic@example.com',
    );
    Database.chats.put(chat);
  });
  tearDownAll(() async {
    Get.reset();
    Database.store.close();
    expect(directory.parent.absolute.path, root.absolute.path);
    await directory.delete(recursive: true);
  });
  setUp(() => Database.messages.removeAll()); // This fixture's store only.

  Message message(String text) => Message(
    guid: 'synthetic-receive',
    text: text,
    isFromMe: false,
    dateCreated: DateTime.utc(2026, 9, 16),
  )..chat.target = chat;

  test(
    'new receive uses the real persistence callback before durable save',
    () async {
      final handler = ActionHandler();
      var calls = 0;
      await expectLater(
        handler.handleNewMessage(
          chat,
          message('hello'),
          null,
          persistReceivedMessage: (resolved, incoming, persist) async {
            calls++;
            expect(resolved.id, chat.id);
            expect(Database.messages.count(), 0);
            return Database.store.runInTransaction<Message>(TxMode.write, () {
              final saved = persist();
              expect(saved.id, greaterThan(0));
              expect(Database.messages.count(), 1);
              if (calls == 1) throw StateError('synthetic atomic rollback');
              return saved;
            });
          },
        ),
        throwsStateError,
      );
      expect(calls, 1);
      expect(Database.messages.count(), 0);
    },
  );

  test(
    'duplicate receive retries ownership on existing row without overwriting edit',
    () async {
      final saved = message('edited')
        ..dateEdited = DateTime.utc(2026, 9, 16, 0, 1);
      Database.messages.put(saved);
      final handler = ActionHandler();
      final blocked = Completer<void>();
      final entered = Completer<void>();
      var calls = 0;
      Future<Message> capture(
        Chat resolved,
        Message current,
        Message Function() persist,
      ) async {
        calls++;
        expect(current.id, saved.id);
        expect(current.text, 'edited');
        expect(resolved.id, chat.id);
        expect(identical(persist(), current), isTrue);
        if (calls == 1) {
          entered.complete();
          await blocked.future;
        }
        return current;
      }

      final first = handler.handleNewMessage(
        chat,
        message('original'),
        null,
        persistReceivedMessage: capture,
      );
      await entered.future;
      final second = handler.handleNewMessage(
        chat,
        message('original'),
        null,
        persistReceivedMessage: capture,
      );
      blocked.complete();
      await Future.wait([first, second]);
      expect(calls, 2);
      expect(Database.messages.count(), 1);
      expect(Database.messages.get(saved.id!)!.text, 'edited');
      expect(
        handler.handledNewMessages,
        isEmpty,
        reason: 'No second notification',
      );
    },
  );

  test('incoming queue forwards the exact live-only callback', () async {
    final spy = _QueueHandler();
    Get.put<ActionHandler>(spy);
    Future<Message> capture(
      Chat c,
      Message m,
      Message Function() persist,
    ) async => persist();
    final entry = IncomingItem(
      type: QueueType.newMessage,
      chat: chat,
      message: message('hello'),
      persistReceivedMessage: capture,
    );
    await IncomingQueue().handleQueueItem(entry);
    expect(identical(spy.callback, capture), isTrue);
    final ordinary = IncomingItem(
      type: QueueType.newMessage,
      chat: chat,
      message: message('history'),
    );
    await IncomingQueue().handleQueueItem(ordinary);
    expect(spy.callback, isNull);
  });
}

class _QueueHandler extends ActionHandler {
  IncomingMessagePersistence? callback;
  @override
  Future<void> handleNewMessage(
    Chat c,
    Message m,
    String? tempGuid, {
    bool checkExisting = true,
    IncomingMessagePersistence? persistReceivedMessage,
  }) async {
    callback = persistReceivedMessage;
  }
}
