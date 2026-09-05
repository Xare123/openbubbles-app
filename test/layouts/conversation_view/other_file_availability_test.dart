import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_details/widgets/media_gallery_card.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/other_file.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SyntheticDownloadService extends AttachmentDownloadService {
  _SyntheticDownloadService(this.controller);
  final AttachmentDownloadController controller;

  @override
  AttachmentDownloadController? getController(String? guid) =>
      guid == controller.attachment.guid ? controller : null;
}

void main() {
  late Directory root;

  setUp(() async {
    ss.settings = Settings();
    root = await Directory.systemTemp.createTemp('other-file-availability-');
    fs.appDocDir = root;
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('accepts a completed path-only document download', () async {
    final document = File('${root.path}/handoff.pdf');
    await document.writeAsBytes(<int>[1, 2, 3]);

    expect(
      isOtherFileAvailable(
        PlatformFile(name: 'handoff.pdf', path: document.path, size: 3),
      ),
      isTrue,
    );
  });

  test(
    'gallery file builder consumes a completed path-only document',
    () async {
      final document = File('${root.path}/gallery-handoff.pdf');
      await document.writeAsBytes(<int>[1, 2, 3]);
      final file = PlatformFile(
        name: 'gallery-handoff.pdf',
        path: document.path,
        size: 3,
      );

      final widget = buildOtherFileIfAvailable(
        file: file,
        attachment: Attachment(
          guid: 'gallery-document',
          transferName: file.name,
          mimeType: 'application/pdf',
          totalBytes: file.size,
        ),
      );

      expect(widget, isA<OtherFile>());
    },
  );

  testWidgets('gallery renders a path-only completion and detaches on exit', (
    tester,
  ) async {
    final document = File('${root.path}/completed.pdf');
    document.writeAsBytesSync(<int>[1, 2, 3]);
    final attachment = Attachment(
      guid: 'path-only-completion',
      transferName: 'completed.pdf',
      mimeType: 'application/pdf',
      totalBytes: 3,
    );
    // No Get registration: onInit must not enter the live download queue.
    final downloader = AttachmentDownloadController(attachment: attachment);
    final previousService = attachmentDownloader;
    attachmentDownloader = _SyntheticDownloadService(downloader);
    addTearDown(() => attachmentDownloader = previousService);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MediaGalleryCard(attachment: attachment),
          ),
        ),
      ),
    );
    expect(downloader.completeFuncs.length, 1);
    expect(downloader.errorFuncs.length, 1);
    final file = PlatformFile(
      name: 'completed.pdf',
      path: document.path,
      size: 3,
    );
    for (final callback in List<Function(PlatformFile)>.of(
      downloader.completeFuncs,
    )) {
      callback(file);
    }
    await tester.pumpAndSettle();
    expect(find.byType(OtherFile), findsOneWidget);
    expect(find.text('completed.pdf'), findsOneWidget);
    expect(tester.widget<OtherFile>(find.byType(OtherFile)).file.bytes, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(downloader.completeFuncs, isEmpty);
    expect(downloader.errorFuncs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document download prompt grows naturally with large text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(2)),
                child: DocumentDownloadPrompt(
                  name: 'very-long-clinical-handoff-document-name.docx',
                  typeLabel: 'DOCX',
                  sizeLabel: '3 MB',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('very-long-clinical-handoff-document-name.docx'),
      findsOneWidget,
    );
    expect(find.text('DOCX • 3 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('rejects missing and empty local documents', () async {
    final emptyDocument = File('${root.path}/empty.docx');
    await emptyDocument.create();

    expect(
      isOtherFileAvailable(
        PlatformFile(
          name: 'missing.pdf',
          path: '${root.path}/missing.pdf',
          size: 3,
        ),
      ),
      isFalse,
    );
    expect(
      isOtherFileAvailable(
        PlatformFile(name: 'empty.docx', path: emptyDocument.path, size: 0),
      ),
      isFalse,
    );
  });
}
