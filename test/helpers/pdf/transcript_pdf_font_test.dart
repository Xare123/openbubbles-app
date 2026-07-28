import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/helpers/pdf/transcript_pdf_font.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  group('TranscriptPdfFontLoader', () {
    test('loads the same Open Sans URL and caches a successful font', () async {
      final fontBytes =
          await File('assets/fonts/Inter-VariableFont_opsz,wght.ttf')
              .readAsBytes();
      var calls = 0;
      Uri? requestedUri;
      final loader = TranscriptPdfFontLoader(
        loadBytes: (uri) async {
          calls++;
          requestedUri = uri;
          return Uint8List.fromList(fontBytes);
        },
      );

      final first = await loader.openSansRegular();
      final second = await loader.openSansRegular();

      expect(requestedUri, TranscriptPdfFontLoader.openSansRegularUri);
      expect(calls, 1);
      expect(identical(first, second), isTrue);

      final document = pw.Document();
      document.addPage(
        pw.Page(
          build: (_) => pw.Text('Transcript', style: pw.TextStyle(font: first)),
        ),
      );
      final pdfBytes = await document.save();
      expect(pdfBytes.take(4), orderedEquals(<int>[0x25, 0x50, 0x44, 0x46]));
    });

    test('falls back to Helvetica and retries after a download failure',
        () async {
      var calls = 0;
      final loader = TranscriptPdfFontLoader(
        loadBytes: (_) async {
          calls++;
          throw StateError('offline');
        },
      );

      final first = await loader.openSansRegular();
      final second = await loader.openSansRegular();

      expect(calls, 2);

      final document = pw.Document();
      document.addPage(
        pw.Page(
          build: (_) => pw.Column(
            children: [
              pw.Text('First', style: pw.TextStyle(font: first)),
              pw.Text('Second', style: pw.TextStyle(font: second)),
            ],
          ),
        ),
      );
      final pdfBytes = await document.save();
      expect(pdfBytes.take(4), orderedEquals(<int>[0x25, 0x50, 0x44, 0x46]));
    });
  });
}
