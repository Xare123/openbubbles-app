import 'package:bluebubbles/app/layouts/fullscreen_media/dialogs/attachment_info_summary.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/dialogs/metadata_dialog.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('summary maps common kinds and formats bytes', () {
    expect(attachmentKindLabel('image/jpeg', null), 'JPEG image');
    expect(attachmentKindLabel('video/mp4', null), 'MP4 video');
    expect(attachmentKindLabel('application/pdf', null), 'PDF document');
    expect(attachmentKindLabel('application/octet-stream', null), 'File');
    expect(attachmentKindLabel(null, 'public.png'), 'PNG image');
    expect(attachmentKindLabel(null, null), 'File');
    expect(formatAttachmentBytes(512), '512 B');
    expect(formatAttachmentBytes(2048), '2.0 KB');
    expect(formatAttachmentBytes(1572864), '1.5 MB');
  });
  test('summary prefers local size and omits unknowns', () {
    final full = summarizeAttachment(transferName: 'photo.heic', mimeType: 'image/heic', advertisedBytes: 1048576, localBytes: 1572864, width: 3000, height: 4000, dateCreated: DateTime.utc(2026, 9, 26, 10, 30));
    expect(full.filename, 'photo.heic');
    expect(full.kindLabel, 'HEIC image');
    expect(full.sizeLabel, '1.5 MB');
    expect(full.dimensionsLabel, '3000x4000');
    expect(full.dateLabel, isNotNull);
    expect(full.isEmpty, isFalse);
    final bare = summarizeAttachment();
    expect(bare.isEmpty, isTrue);
    expect(bare.filename, isNull);
  });
  test('info rows expose only allowlisted labels and values', () {
    const secretUrl = 'https://mmcs.example/signed-download-token-abc123';
    const secretKey = 'deadbeef-key-material';
    final summary = summarizeAttachment(transferName: 'photo.heic', mimeType: 'image/heic', advertisedBytes: 1048576, width: 3000, height: 4000);
    final rows = attachmentInfoRows(summary);
    expect(rows.map((e) => e.key), everyElement(isIn(['File name', 'Kind', 'Size', 'Dimensions', 'Date'])));
    final rendered = rows.map((e) => '${e.key}: ${e.value}').join('\n');
    expect(rendered, contains('photo.heic'));
    expect(rendered, contains('HEIC image'));
    expect(rendered, isNot(contains(secretUrl)));
    expect(rendered, isNot(contains(secretKey)));
    expect(rendered, isNot(contains('mmcsUrl')));
    expect(rendered, isNot(contains('decryptionKey')));
    expect(rendered, isNot(contains('signature:')));
  });
  testWidgets('rendered dialog rows hide nested secret metadata', (tester) async {
    const secretUrl = 'https://mmcs.example/signed-download-token-abc123';
    const secretKey = 'deadbeef-key-material';
    final attachment = Attachment(guid: 'secret-guid', transferName: 'photo.heic', mimeType: 'image/heic', totalBytes: 1048576, width: 3000, height: 4000, metadata: {'mmcsUrl': secretUrl, 'decryptionKey': secretKey, 'signature': secretKey});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Column(children: buildAttachmentInfoRows(attachment, context, localBytes: 1454701))))));
    expect(find.textContaining('photo.heic', findRichText: true), findsOneWidget);
    expect(find.textContaining('HEIC image', findRichText: true), findsOneWidget);
    expect(find.textContaining('1.4 MB', findRichText: true), findsOneWidget);
    expect(attachment.totalBytes, 1048576);
    expect(find.textContaining(secretUrl, findRichText: true), findsNothing);
    expect(find.textContaining(secretKey, findRichText: true), findsNothing);
    expect(find.textContaining('mmcsUrl', findRichText: true), findsNothing);
    expect(find.textContaining('decryptionKey', findRichText: true), findsNothing);
    expect(find.textContaining('secret-guid', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
