import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator_message_snapshot.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuple/tuple.dart';

void main() {
  setUp(() {
    ss.settings = Settings();
    ss.settings.spellcheck.value = false;
    ss.settings.sendDelay.value = 0;
  });

  for (final startsWithPreview in [true, false]) {
    for (final submit in [false, true]) {
      testWidgets(
        'visible text survives handoff: preview=$startsWithPreview submit=$submit',
        (tester) async {
          final focus = FocusNode();
          final fallback = MentionTextEditingController(
            text: '',
            focusNode: focus,
          );
          final preview = ConversationViewController(
            Chat(guid: 'iMessage;-;synthetic'),
          );
          final destination = ConversationViewController(
            Chat(guid: 'iMessage;-;destination'),
          );
          final key = GlobalKey<TextFieldComponentState>();
          final navigation = Completer<void>();
          AttributedBody? sent;
          var sendCount = 0;
          destination.sendFunc = (args, _, __) async {
            sent = args.item2;
            sendCount++;
          };
          Future<void> sendMessage({String? effect}) async {
            final outgoing = captureChatCreatorMessage(key.currentState!);
            // Simulate keyboard callbacks/route initialization mutating both editors.
            fallback.clear();
            preview.textController.clear();
            await navigation.future;
            await destination.send(
              outgoing.attachments,
            outgoing.bodyForSend(),
              '',
              outgoing.replyGuid,
              outgoing.replyPart,
              effect,
              null,
              false,
              null,
            );
          }

          Widget composer(ConversationViewController? controller) =>
              MaterialApp(
                theme: ThemeData(
                  extensions: const [
                    BubbleText(bubbleText: TextStyle(fontSize: 16)),
                    BubbleColors(),
                  ],
                ),
                home: Scaffold(
                  body: TextFieldComponent(
                    key: key,
                    focusNode: focus,
                    textController: fallback,
                    controller: controller,
                    recorderController: null,
                    sendMessage: sendMessage,
                  ),
                ),
              );
          await tester.pumpWidget(composer(startsWithPreview ? preview : null));
          // The parent can change fakeController while the mounted field retains
          // the bindings installed by its original initState.
          await tester.pumpWidget(composer(startsWithPreview ? null : preview));
          await tester.enterText(
            find.byType(TextField),
            'Synthetic handoff message',
          );
          final visible = startsWithPreview ? preview.textController : fallback;
          final inactive = startsWithPreview
              ? fallback
              : preview.textController;
          expect(visible.text, 'Synthetic handoff message');
          expect(inactive.text, isEmpty);
          if (submit) {
            await tester.testTextInput.receiveAction(TextInputAction.send);
          } else {
            await tester.tap(find.byTooltip('Send message').last);
          }
          expect(sendCount, 0);
          navigation.complete();
          await tester.pump();
          expect(sent?.string, 'Synthetic handoff message');
          expect(sendCount, 1);
          await tester.pumpWidget(const SizedBox.shrink());
          fallback.dispose();
          focus.dispose();
          preview.textController.dispose();
          preview.focusNode.dispose();
          preview.subjectTextController.dispose();
          preview.subjectFocusNode.dispose();
        },
      );
    }
  }

  testWidgets(
    'snapshot retains mentions, formatting, reply and chosen attachments',
    (tester) async {
      final focus = FocusNode();
      final fallback = MentionTextEditingController(
        text: 'stale',
        focusNode: focus,
      );
      final preview = ConversationViewController(
        Chat(guid: 'iMessage;-;metadata'),
      );
      final key = GlobalKey<TextFieldComponentState>();
      final initial = [
        PlatformFile(name: 'removed.txt', size: 0, bytes: Uint8List(0)),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: const [
              BubbleText(bubbleText: TextStyle(fontSize: 16)),
              BubbleColors(),
            ],
          ),
          home: Scaffold(
            body: TextFieldComponent(
              key: key,
              focusNode: focus,
              textController: fallback,
              controller: preview,
              recorderController: null,
              initialAttachments: initial,
              sendMessage: ({String? effect}) async {},
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Hi  !');
      preview.textController.annotations = [
        Annotation(range: [0, 3], bold: true),
        Annotation(range: [3, 4], mentionedAddress: 'person@example.invalid'),
        Annotation(range: [4, 5], italic: true, textEffect: 5),
      ];
      preview.textController.mentionCache['person@example.invalid'] = 'Tester';
      final attachment = PlatformFile(
        name: 'chosen.txt',
        size: 0,
        bytes: Uint8List(0),
      );
      preview.pickedAttachments.add(attachment);
      preview.replyToMessage = Tuple2(
        Message(
          guid: 'synthetic-reply',
          threadOriginatorGuid: 'synthetic-thread',
        ),
        2,
      );
      final outgoing = captureChatCreatorMessage(key.currentState!);
      preview.textController.clear();
      preview.pickedAttachments.clear();
      preview.replyToMessage = null;
      initial.clear();
      expect(outgoing.body.string, 'Hi Tester!');
      expect(outgoing.body.runs.map((run) => run.range), [
        [0, 3],
        [3, 6],
        [9, 1],
      ]);
      expect(outgoing.body.runs.first.attributes?.bold, isTrue);
      expect(
        outgoing.body.runs[1].attributes?.mention,
        'person@example.invalid',
      );
      expect(outgoing.body.runs.last.attributes?.italic, isTrue);
      expect(outgoing.body.runs.last.attributes?.textEffect, 5);
      expect(outgoing.attachments, [same(attachment)]);
      expect(outgoing.replyGuid, 'synthetic-thread');
      expect(outgoing.replyPart, 2);
      preview.replyToMessage = Tuple2(Message(guid: 'synthetic-unthreaded'), 0);
      expect(
        captureChatCreatorMessage(key.currentState!).replyGuid,
        'synthetic-unthreaded',
      );
      // An empty current selection must not resurrect removed initial attachments.
      expect(captureChatCreatorMessage(key.currentState!).attachments, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      fallback.dispose();
      focus.dispose();
      preview.textController.dispose();
      preview.focusNode.dispose();
      preview.subjectTextController.dispose();
      preview.subjectFocusNode.dispose();
    },
  );

  test(
    'snapshot detaches and freezes body ranges and attachment selection',
    () {
      final body = AttributedBody.raw('synthetic');
      final attachments = [
        PlatformFile(name: 'synthetic.txt', size: 0, bytes: Uint8List(0)),
      ];
      final outgoing = ChatCreatorMessageSnapshot(
        body: body,
        attachments: attachments,
      );
      body.runs.first.range[1] = 0;
      body.runs.clear();
      attachments.clear();
      expect(outgoing.body.string, 'synthetic');
      expect(outgoing.body.runs.single.range, [0, 9]);
      expect(outgoing.attachments.single.name, 'synthetic.txt');
      expect(() => outgoing.body.runs.clear(), throwsUnsupportedError);
      expect(
        () => outgoing.body.runs.single.range.clear(),
        throwsUnsupportedError,
      );
      expect(() => outgoing.attachments.clear(), throwsUnsupportedError);
    },
  );

  test('creator captures before awaiting and sends the captured payload', () {
    final source = File(
      'lib/app/layouts/chat_creator/chat_creator.dart',
    ).readAsStringSync();
    final callback = source.substring(
      source.indexOf('sendMessage: ({String? effect}) async {'),
    );
    expect(
      callback.indexOf('captureChatCreatorMessage(composer)'),
      lessThan(callback.indexOf('await ')),
    );
    final handoff = callback.substring(
      callback.indexOf('sendInitialMessage() async {'),
      callback.indexOf('if (backend is RustPushBackend'),
    );
    expect(handoff, contains('final controller = cvc(chat);'));
    expect(handoff, contains('outgoing.attachments,'));
    expect(handoff, contains('outgoing.bodyForSend(),'));
    expect(handoff, contains('outgoing.replyGuid,'));
    expect(handoff, contains('outgoing.replyPart,'));
    expect(handoff, isNot(contains('getFinalAnnotations')));
    expect(handoff, isNot(contains('textController.text =')));
    expect(handoff, isNot(contains('fakeController.value')));
  });

  test('downstream message-part conversion can sort a detached send body', () {
    final outgoing = ChatCreatorMessageSnapshot(
      body: AttributedBody(
        string: 'ab',
        runs: [
          Run(range: [1, 1], attributes: Attributes(messagePart: 0, bold: true)),
          Run(range: [0, 1], attributes: Attributes(messagePart: 0)),
        ],
      ),
      attachments: [],
    );
    final message = Message(
      guid: 'synthetic-sort',
      attributedBody: [outgoing.bodyForSend()],
    );
    final parts = message.buildMessageParts();
    expect(parts.single.text, 'ab');
    expect(parts.single.annotations.last.bold, isTrue);
    expect(outgoing.body.runs.first.range, [1, 1]);
  });
}
