import 'dart:io';
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
}
