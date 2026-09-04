import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/attachments_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment-file-gate-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('null, empty, and missing paths are not usable', () {
    expect(isUsableDownloadedAttachmentFile(null), isFalse);
    expect(isUsableDownloadedAttachmentFile(''), isFalse);
    expect(
      isUsableDownloadedAttachmentFile('${root.path}/missing.bin'),
      isFalse,
    );
  });

  test('zero-byte file is not considered downloaded', () async {
    final file = File('${root.path}/empty.bin');
    await file.writeAsBytes(<int>[]);
    expect(await file.length(), 0);
    expect(isUsableDownloadedAttachmentFile(file.path), isFalse);
  });

  test('non-empty file is usable', () async {
    final file = File('${root.path}/data.bin');
    await file.writeAsBytes(<int>[1, 2, 3]);
    expect(isUsableDownloadedAttachmentFile(file.path), isTrue);
  });

  test('CloudKit metadata fallbacks remain usable in the gallery', () {
    expect(
      safeAttachmentTransferName(Attachment(transferName: 'photo.jpg', guid: 'attachment-1')),
      'photo.jpg',
    );
    expect(safeAttachmentTransferName(Attachment(guid: 'attachment-1')), 'attachment-1');
    expect(safeAttachmentTransferName(Attachment()), 'attachment');

    expect(safeAttachmentTotalBytes(Attachment(totalBytes: 7)), 7);
    final withBytes = Attachment()..bytes = Uint8List.fromList(<int>[1, 2, 3]);
    expect(safeAttachmentTotalBytes(withBytes), 3);
    expect(safeAttachmentTotalBytes(Attachment()), 0);
  });

  test('platform file requires bytes or a non-empty local file', () async {
    final empty = File('${root.path}/empty-platform-file.bin');
    await empty.create();
    final populated = File('${root.path}/populated-platform-file.bin');
    await populated.writeAsBytes(<int>[1]);

    expect(
      isUsableDownloadedPlatformFile(
        PlatformFile(name: 'inline.bin', size: 1, bytes: Uint8List.fromList(<int>[1])),
      ),
      isTrue,
    );
    expect(
      isUsableDownloadedPlatformFile(
        PlatformFile(name: 'empty.bin', size: 0, path: empty.path),
      ),
      isFalse,
    );
    expect(
      isUsableDownloadedPlatformFile(
        PlatformFile(name: 'local.bin', size: 1, path: populated.path),
      ),
      isTrue,
    );
  });
}
