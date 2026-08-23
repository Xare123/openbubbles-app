import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_keyboard_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an active inline edit owns transcript keyboard input', () {
    expect(
      shouldDismissKeyboardFromTranscript(
        hasActiveMessageEdit: true,
        keyboardOpen: true,
        composerHasFocus: false,
        subjectHasFocus: false,
      ),
      isFalse,
    );
  });

  test('the transcript still dismisses the regular composer keyboard', () {
    expect(
      shouldDismissKeyboardFromTranscript(
        hasActiveMessageEdit: false,
        keyboardOpen: true,
        composerHasFocus: true,
        subjectHasFocus: false,
      ),
      isTrue,
    );
  });
}
