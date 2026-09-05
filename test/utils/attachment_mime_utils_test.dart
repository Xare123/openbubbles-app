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

    test('infers DOCX from the original filename', () {
      expect(
        resolveAttachmentMimeType(
          'handoff.docx',
          '/data/user/0/app/cache/file_picker/43',
        ),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    });

    test('infers PDF from UTI when filenames have no extension', () {
      expect(
        resolveAttachmentMimeType(
          'attachment',
          '/tmp/attachment',
          uti: 'com.adobe.pdf',
        ),
        'application/pdf',
      );
    });

    test('infers DOCX from UTI when filenames have no extension', () {
      expect(
        resolveAttachmentMimeType(
          'attachment',
          '/tmp/attachment',
          uti: 'org.openxmlformats.wordprocessingml.document',
        ),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    });

    test('preserves a specific declared MIME type', () {
      expect(
        resolveAttachmentMimeType(
          'handoff.docx',
          '/tmp/handoff.docx',
          declaredMimeType: 'application/pdf',
        ),
        'application/pdf',
      );
    });

    test('replaces generic MIME with filename evidence', () {
      expect(
        resolveAttachmentMimeType(
          'handoff.docx',
          '/tmp/attachment',
          declaredMimeType: 'application/octet-stream',
        ),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    });

    test('replaces generic MIME with UTI evidence', () {
      expect(
        resolveAttachmentMimeType(
          'attachment',
          '/tmp/attachment',
          uti: 'com.adobe.pdf',
          declaredMimeType: 'application/octet-stream',
        ),
        'application/pdf',
      );
    });

    test('retains generic MIME when no stronger evidence exists', () {
      expect(
        resolveAttachmentMimeType(
          'attachment',
          '/tmp/attachment',
          declaredMimeType: 'application/octet-stream',
        ),
        'application/octet-stream',
      );
    });
  });

  group('conciseAttachmentTypeLabel', () {
    test('uses common document extensions and MIME fallbacks', () {
      expect(conciseAttachmentTypeLabel('handoff.docx', null), 'DOCX');
      expect(conciseAttachmentTypeLabel('attachment', 'application/pdf'), 'PDF');
      expect(conciseAttachmentTypeLabel('handoff.docx', 'application/pdf'), 'PDF');
      expect(conciseAttachmentTypeLabel('attachment', 'application/octet-stream'), 'FILE');
    });
  });
}
