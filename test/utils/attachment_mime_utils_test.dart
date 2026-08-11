import 'package:bluebubbles/utils/attachment_mime_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveAttachmentMimeType', () {
    test('uses the original filename when an Android cache path has no extension', () {
      expect(
        resolveAttachmentMimeType('medical-form.pdf', '/data/user/0/app/cache/file_picker/42'),
        'application/pdf',
      );
    });

    test('falls back to the path when the original filename has no extension', () {
      expect(
        resolveAttachmentMimeType('document', '/tmp/document.pdf'),
        'application/pdf',
      );
    });
  });
}
