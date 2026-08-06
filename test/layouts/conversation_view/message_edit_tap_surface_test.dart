import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_edit_tap_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty edit-bubble space focuses the editor', (tester) async {
    final focusNode = FocusNode();
    final textController = TextEditingController(text: 'Message to edit');
    addTearDown(focusNode.dispose);
    addTearDown(textController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 120,
              child: MessageEditTapSurface(
                focusNode: focusNode,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 120,
                    height: 48,
                    child: TextField(
                      focusNode: focusNode,
                      controller: textController,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final surface = tester.getRect(find.byType(MessageEditTapSurface));
    await tester.tapAt(surface.bottomRight - const Offset(8, 8));
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('tapping edit-bubble padding preserves an existing cursor',
      (tester) async {
    final focusNode = FocusNode();
    final textController = TextEditingController(text: 'Message to edit');
    addTearDown(focusNode.dispose);
    addTearDown(textController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 120,
              child: MessageEditTapSurface(
                focusNode: focusNode,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 120,
                    height: 48,
                    child: TextField(
                      focusNode: focusNode,
                      controller: textController,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    textController.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();

    final surface = tester.getRect(find.byType(MessageEditTapSurface));
    await tester.tapAt(surface.bottomRight - const Offset(8, 8));
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    expect(textController.selection, const TextSelection.collapsed(offset: 4));
  });
}
