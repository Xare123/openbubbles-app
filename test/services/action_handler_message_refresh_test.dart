import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/action_handler.dart';
import 'package:bluebubbles/services/ui/message/messages_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  const chatGuid = 'iMessage;-;edit-refresh-test';

  tearDown(() {
    Get.reset();
  });

  test('refreshActiveMessage replaces a loaded text-only edit', () {
    final service = MessagesService(chatGuid);
    final original = Message(
      guid: 'edit-refresh-message',
      text: 'Before edit',
      isFromMe: true,
      dateCreated: DateTime.utc(2026, 8, 1),
    );
    final edited = Message(
      guid: original.guid,
      text: 'After edit',
      isFromMe: true,
      dateCreated: original.dateCreated,
      dateEdited: DateTime.utc(2026, 8, 1, 0, 1),
    );
    Message? renderedMessage;

    service.struct.addMessages([original]);
    service.updateFunc = (message, {oldGuid}) {
      renderedMessage = message;
    };
    Get.put<MessagesService>(service, tag: chatGuid);

    ActionHandler().refreshActiveMessage(
      Chat(guid: chatGuid),
      edited,
    );

    expect(renderedMessage, isNotNull);
    expect(renderedMessage!.text, 'After edit');
    expect(service.struct.getMessage(original.guid!)!.text, 'After edit');
  });

  test('refreshActiveMessage is a no-op when the conversation is not loaded',
      () {
    expect(
      () => ActionHandler().refreshActiveMessage(
        Chat(guid: chatGuid),
        Message(
          guid: 'not-loaded-message',
          text: 'Edited text',
          isFromMe: true,
        ),
      ),
      returnsNormally,
    );
    expect(Get.isRegistered<MessagesService>(tag: chatGuid), isFalse);
  });
}
