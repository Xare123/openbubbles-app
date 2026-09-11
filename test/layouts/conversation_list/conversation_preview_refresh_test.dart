import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/pinned_tile_text_bubble.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  const chatGuid = 'synthetic-preview-chat';
  const olderGuid = 'synthetic-preview-older';
  const latestGuid = 'synthetic-preview-latest';
  const olderBody = 'Older ordinary text';
  const initialBody = 'Initial latest body';
  const editedBody = 'Edited body same guid';
  late Directory directory;

  setUpAll(() async {
    directory = await Directory('${Directory.current.path}/.dart_tool')
        .createTemp('conversation-preview-refresh-');
    Database.store = await openStore(directory: directory.path);
    Database.chats = Database.store.box<Chat>();
    Database.messages = Database.store.box<Message>();
    Database.handles = Database.store.box<Handle>();
    Database.attachments = Database.store.box<Attachment>();
  });

  tearDownAll(() async {
    Database.store.close();
    final root = Directory('${Directory.current.path}/.dart_tool').absolute.path;
    if (!directory.absolute.path.startsWith(
      '$root${Platform.pathSeparator}conversation-preview-refresh-',
    )) {
      throw StateError('unexpected synthetic test directory');
    }
    await directory.delete(recursive: true);
  });

  setUp(() {
    Get.testMode = true;
    Get.reset();
    ss.settings = Settings();
    ss.settings.autoSave.value = false;
    ss.settings.colorfulBubbles.value = false;
    // Only the synthetic database created above, never a device database.
    Database.messages.removeAll();
    Database.handles.removeAll();
    Database.attachments.removeAll();
    Database.chats.removeAll();
  });
  tearDown(Get.reset);

  Chat seedChat() {
    final chat = Chat(guid: chatGuid, hasUnreadMessage: true);
    Database.chats.put(chat);
    Message seed(String guid, String body, DateTime created) {
      final message = Message(
        guid: guid,
        text: body,
        attributedBody: [AttributedBody.raw(body)],
        isFromMe: false,
        dateCreated: created,
      )..chat.target = chat;
      Database.messages.put(message);
      return message;
    }
    seed(olderGuid, olderBody, DateTime.utc(2026, 9, 10, 12));
    chat.latestMessage = seed(
      latestGuid, initialBody, DateTime.utc(2026, 9, 10, 12, 1),
    );
    return chat;
  }

  Future<void> settlePreviews(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      // ObjectBox change events arrive on a native port, outside fake time.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  MessageSummaryInfo summary(List<int> retracted) => MessageSummaryInfo(
    retractedParts: retracted,
    editedContent: {},
    originalTextRange: {},
    editedParts: [],
  );

  testWidgets(
    'same-GUID body and retraction refresh both mounted conversation previews',
    (tester) async {
      final chat = seedChat();
      GlobalChatService.unreadState(chatGuid).value = true;
      final listController = ConversationListController(
        showArchivedChats: false,
        showUnknownSenders: false,
      );
      final tileController = ConversationTileController(
        chat: chat, listController: listController,
      );
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(body: Column(children: [
          ChatSubtitle(
            parentController: tileController,
            style: const TextStyle(fontSize: 14),
          ),
          PinnedTileTextBubble(
            chat: chat, size: 120, parentController: tileController,
          ),
        ])),
      ));
      await settlePreviews(tester);
      expect(find.text(initialBody, findRichText: true), findsNWidgets(2));
      expect(find.text(olderBody, findRichText: true), findsNothing);

      final edited = Message.findOne(guid: latestGuid)!;
      expect(edited.dateEdited, isNull);
      edited.text = editedBody;
      edited.attributedBody = [AttributedBody.raw(editedBody)];
      Database.messages.put(edited);
      await settlePreviews(tester);
      expect(find.text(editedBody, findRichText: true), findsNWidgets(2));
      expect(find.text(initialBody, findRichText: true), findsNothing);

      final retracted = Message.findOne(guid: latestGuid)!;
      retracted.messageSummaryInfo = [summary([0])];
      Database.messages.put(retracted);
      await settlePreviews(tester);
      expect(find.text('Unsent message', findRichText: true), findsNWidgets(2));
      expect(find.text(editedBody, findRichText: true), findsNothing);
      final stored = Message.findOne(guid: latestGuid)!;
      expect(stored.dateEdited, isNull);
      expect(stored.text, editedBody);
      expect(stored.attributedBody.single.string, editedBody);
      expect(stored.messageSummaryInfo.single.retractedParts, [0]);

      // A change to an older row must not displace the retracted latest row.
      final older = Message.findOne(guid: olderGuid)!..text = 'Changed older row';
      Database.messages.put(older);
      await settlePreviews(tester);
      expect(find.text('Unsent message', findRichText: true), findsNWidgets(2));
      expect(find.text('Changed older row', findRichText: true), findsNothing);

      final partial = Message.findOne(guid: latestGuid)!;
      partial.attributedBody = [AttributedBody(string: 'gonekept', runs: [
        Run(range: [0, 4], attributes: Attributes(messagePart: 0)),
        Run(range: [4, 4], attributes: Attributes(messagePart: 1)),
      ])];
      partial.messageSummaryInfo = [summary([0])];
      Database.messages.put(partial);
      await settlePreviews(tester);
      expect(
        find.text('Partially unsent message', findRichText: true),
        findsNWidgets(2),
      );
      expect(find.text(olderBody, findRichText: true), findsNothing);
      await tester.pumpWidget(const SizedBox());
      listController.dispose();
    },
  );
}
