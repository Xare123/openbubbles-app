import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('send waits for the composer handler to finish', () async {
    final controller =
        ConversationViewController(Chat(guid: 'iMessage;-;send-await-test'));
    final handler = Completer<void>();
    controller.sendFunc = (_, __, ___) => handler.future;

    var completed = false;
    final sending = controller.send(
      [],
      AttributedBody.raw('https://example.com/one https://example.com/two'),
      '',
      null,
      null,
      null,
      null,
      false,
      null,
    ).then((_) => completed = true);

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    handler.complete();
    await sending;
    expect(completed, isTrue);
  });

  test('send fails when the composer handler is not ready', () async {
    final controller =
        ConversationViewController(Chat(guid: 'iMessage;-;send-missing-test'));

    await expectLater(
      controller.send(
        [],
        AttributedBody.raw('message'),
        '',
        null,
        null,
        null,
        null,
        false,
        null,
      ),
      throwsStateError,
    );
  });

  testWidgets('dismissKeyboard releases the conversation composer focus',
      (tester) async {
    final controller =
        ConversationViewController(Chat(guid: 'iMessage;-;keyboard-test'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(focusNode: controller.focusNode),
        ),
      ),
    );
    controller.focusNode.requestFocus();
    await tester.pump();
    expect(controller.focusNode.hasFocus, isTrue);

    controller.dismissKeyboard();
    await tester.pump();

    expect(controller.focusNode.hasFocus, isFalse);
  });

  testWidgets('dismissKeyboard releases an active inline edit focus',
      (tester) async {
    ss.settings = Settings();
    ss.settings.spellcheck.value = false;
    final controller =
        ConversationViewController(Chat(guid: 'iMessage;-;edit-keyboard-test'));
    final message = Message(guid: 'message-edit-test', isFromMe: true);
    final editController = controller.startEditing(
      message,
      MessagePart(part: 0, text: 'Message to edit'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            focusNode: editController.focusNode,
            controller: editController,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(editController.focusNode!.hasFocus, isTrue);

    controller.dismissKeyboard();
    await tester.pump();

    expect(editController.focusNode!.hasFocus, isFalse);
    controller.stopEditing(message.guid!, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('submitting an inline edit leaves the composer unfocused',
      (tester) async {
    ss.settings = Settings();
    ss.settings.spellcheck.value = false;
    final controller =
        ConversationViewController(Chat(guid: 'iMessage;-;edit-submit-test'));
    final message = Message(guid: 'message-edit-submit-test', isFromMe: true);
    final editController = controller.startEditing(
      message,
      MessagePart(part: 0, text: 'Message to edit'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: controller.focusNode),
              TextField(
                focusNode: editController.focusNode,
                controller: editController,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(editController.focusNode!.hasFocus, isTrue);

    controller.stopEditing(message.guid!, 0);
    controller.dismissKeyboard();
    await tester.pump();

    expect(controller.focusNode.hasFocus, isFalse);
    expect(FocusManager.instance.primaryFocus, isNot(controller.focusNode));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('closing a conversation disposes active inline edit resources', () {
    ss.settings = Settings();
    ss.settings.spellcheck.value = false;
    final controller =
        ConversationViewController(Chat(guid: 'iMessage;-;edit-close-test'));
    final editController = controller.startEditing(
      Message(guid: 'message-edit-close-test', isFromMe: true),
      MessagePart(part: 0, text: 'Message to edit'),
    );
    final editFocusNode = editController.focusNode!;

    controller.onClose();

    expect(controller.editing, isEmpty);
    expect(() => editController.addListener(() {}), throwsFlutterError);
    expect(() => editFocusNode.addListener(() {}), throwsFlutterError);
  });
}
