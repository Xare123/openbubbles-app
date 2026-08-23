import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildMessageParts retains the original and prior edited versions', () {
    final original = AttributedBody.raw('Original message');
    final firstEdit = AttributedBody.raw('First edit');
    final current = AttributedBody.raw('Current edit');
    final message = Message(
      guid: 'edit-history-message',
      text: current.string,
      attributedBody: [current],
      messageSummaryInfo: [
        MessageSummaryInfo(
          retractedParts: [],
          editedContent: {
            '0': [
              EditedContent(
                text: Content(values: [original]),
                date: 1,
              ),
              EditedContent(
                text: Content(values: [firstEdit]),
                date: 2,
              ),
              EditedContent(
                text: Content(values: [current]),
                date: 3,
              ),
            ],
          },
          originalTextRange: const {},
          editedParts: [0],
        ),
      ],
    );

    final parts = message.buildMessageParts();

    expect(parts, hasLength(1));
    expect(parts.single.text, current.string);
    expect(parts.single.isEdited, isTrue);
    expect(
      parts.single.edits.map((edit) => edit.text).toList(),
      [original.string, firstEdit.string],
    );
  });
}
