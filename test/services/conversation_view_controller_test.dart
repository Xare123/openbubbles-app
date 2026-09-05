import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

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

  test('send rejects a controller whose conversation route has closed', () async {
    final controller = ConversationViewController(Chat(guid: 'iMessage;-;send-stale-route-test'));
    var handlerCalled = false;
    controller.sendFunc = (_, __, ___) async => handlerCalled = true;
    controller.onClose();

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
    expect(handlerCalled, isFalse);
  });

  test('optional send scroll does not swallow a queue failure', () async {
    ss.settings = Settings();
    ss.settings.openKeyboardOnSTB.value = false;
    final guid = 'iMessage;-;send-queue-failure-test';
    final controller = ConversationViewController(Chat(guid: guid));
    final queueError = StateError('queue admission failed');
    controller.sendFunc = (_, __, ___) async => throw queueError;

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
        scrollTranscript: true,
      ),
      throwsA(same(queueError)),
    );
    await Future<void>.delayed(Duration.zero);
    controller.onClose();
    Get.delete<MessagesService>(tag: guid, force: true);
  });

  testWidgets('route disposal waits for an in-flight indexed scroll to settle', (tester) async {
    final controller = ConversationViewController(Chat(guid: 'iMessage;-;scroll-disposal-test'));

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        height: 120,
        child: ListView.builder(
          controller: controller.scrollController,
          itemCount: 100,
          itemExtent: 40,
          itemBuilder: (context, index) => AutoScrollTag(
            key: ValueKey(index),
            controller: controller.scrollController,
            index: index,
            child: Text('Message $index'),
          ),
        ),
      ),
    ));
    await tester.pump();

    final scrolling = controller.scrollToMessageIndex(
      80,
      duration: const Duration(seconds: 1),
      preferPosition: AutoScrollPosition.middle,
    );
    await tester.pump();
    controller.onClose();

    expect(() => controller.scrollController.addListener(() {}), returnsNormally);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(await scrolling, isFalse);
    expect(() => controller.scrollController.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional send scroll cannot delay queue admission or fail on route disposal', (tester) async {
    ss.settings = Settings();
    ss.settings.openKeyboardOnSTB.value = false;
    final guid = 'iMessage;-;send-scroll-lifecycle-test';
    final controller = ConversationViewController(Chat(guid: guid));
    final base = DateTime(2026, 9, 5, 12);
    ms(guid).struct.addMessages(List.generate(
      100,
      (index) => Message(
        guid: 'send-scroll-$index',
        isFromMe: false,
        dateCreated: base.subtract(Duration(minutes: index)),
      ),
    ));
    final queueGate = Completer<void>();
    final queueStarted = Completer<void>();
    controller.sendFunc = (_, __, ___) async {
      queueStarted.complete();
      await queueGate.future;
    };

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        height: 120,
        child: ListView.builder(
          controller: controller.scrollController,
          itemCount: 100,
          itemExtent: 40,
          itemBuilder: (context, index) => AutoScrollTag(
            key: ValueKey(index),
            controller: controller.scrollController,
            index: index,
            child: Text('Message $index'),
          ),
        ),
      ),
    ));
    await tester.pump();

    final sending = controller.send(
      [],
      AttributedBody.raw('ordinary send'),
      '',
      null,
      null,
      null,
      null,
      false,
      base.subtract(const Duration(minutes: 80)),
      scrollTranscript: true,
    );
    await queueStarted.future;
    controller.onClose();
    await tester.pumpWidget(const SizedBox.shrink());
    queueGate.complete();
    await sending;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    Get.delete<MessagesService>(tag: guid, force: true);
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
