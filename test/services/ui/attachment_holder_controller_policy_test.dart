import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active controller remains attached', () {
    expect(shouldKeepAttachmentDownloadController(hasError: false), isTrue);
  });

  test('failed controller is re-resolved, not kept', () {
    expect(shouldKeepAttachmentDownloadController(hasError: true), isFalse);
  });
}
