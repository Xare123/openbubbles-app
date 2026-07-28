import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/widgets.dart' as pw;

typedef PdfFontBytesLoader = Future<Uint8List> Function(Uri uri);

/// Loads the Open Sans font used by conversation transcript PDFs.
///
/// This keeps PDF font loading independent from platform printing libraries.
class TranscriptPdfFontLoader {
  TranscriptPdfFontLoader({PdfFontBytesLoader? loadBytes})
      : _loadBytes = loadBytes ?? _download;

  static final TranscriptPdfFontLoader shared = TranscriptPdfFontLoader();

  static final Uri openSansRegularUri = Uri.parse(
    'https://fonts.gstatic.com/s/opensans/v40/'
    'memSYaGs126MiZpBA-UvWbX2vVnXBbObj2OVZyOOSr4dVJWUgsjZ0C4nY1M2xLER.ttf',
  );

  final PdfFontBytesLoader _loadBytes;
  pw.Font? _cachedOpenSansRegular;
  Future<pw.Font>? _loadingOpenSansRegular;

  Future<pw.Font> openSansRegular() async {
    final cached = _cachedOpenSansRegular;
    if (cached != null) return cached;

    final pending = _loadingOpenSansRegular ??= _loadOpenSansRegular();
    try {
      final font = await pending;
      _cachedOpenSansRegular = font;
      return font;
    } catch (error) {
      assert(() {
        debugPrint(
            '$error\nError loading OpenSans-Regular, fallback to Helvetica.');
        return true;
      }());
      return pw.Font.helvetica();
    } finally {
      _loadingOpenSansRegular = null;
    }
  }

  Future<pw.Font> _loadOpenSansRegular() async {
    final bytes = await _loadBytes(openSansRegularUri);
    return pw.Font.ttf(
      bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }

  static Future<Uint8List> _download(Uri uri) async {
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw StateError('Unable to download $uri: HTTP ${response.statusCode}');
    }
    return response.bodyBytes;
  }
}
