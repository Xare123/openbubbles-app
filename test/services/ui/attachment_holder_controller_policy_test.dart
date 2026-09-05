import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active controller remains attached', () {
    expect(shouldKeepAttachmentDownloadController(hasError: false), isTrue);
  });

  test('failed controller is re-resolved, not kept', () {
    expect(shouldKeepAttachmentDownloadController(hasError: true), isFalse);
  });

  test('null-MIME PDF resolves for message bubble routing', () {
    expect(
      resolveMessageAttachmentMimeType(
        Attachment(uti: 'com.adobe.pdf'),
        PlatformFile(name: 'attachment', path: '/tmp/attachment', size: 3),
      ),
      'application/pdf',
    );
  });

  test('generic DOCX resolves for message bubble routing', () {
    expect(
      resolveMessageAttachmentMimeType(
        Attachment(mimeType: 'application/octet-stream'),
        PlatformFile(name: 'handoff.docx', path: '/tmp/attachment', size: 3),
      ),
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
  });
}
