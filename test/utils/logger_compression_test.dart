import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

void main() {
  test('compressLogs returns a complete readable archive before returning', () {
    final root = Directory.systemTemp.createTempSync(
      'openbubbles-logger-compression-',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    fs.appDocDir = root;
    final logDirectory = Directory('${root.path}/logs')..createSync();
    File('${logDirectory.path}/first.log').writeAsStringSync('first entry');
    File('${logDirectory.path}/second.log').writeAsStringSync('second entry');

    final archivePath = BaseLogger().compressLogs();
    final archiveFile = File(archivePath);
    expect(archiveFile.existsSync(), isTrue);
    expect(archiveFile.lengthSync(), greaterThan(0));

    final archive = ZipDecoder().decodeBytes(archiveFile.readAsBytesSync());
    final contents = <String, String>{
      for (final file in archive.files)
        file.name: utf8.decode(file.readBytes()!),
    };
    expect(
      contents,
      containsPair('first.log', 'first entry'),
    );
    expect(
      contents,
      containsPair('second.log', 'second entry'),
    );
  });
}
