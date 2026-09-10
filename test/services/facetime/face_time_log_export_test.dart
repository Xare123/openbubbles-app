import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_io/io.dart';

void main() {
  late Directory root;
  late Directory logs;
  late Directory native;
  setUp(() {
    root = Directory.systemTemp.createTempSync('openbubbles-facetime-export-');
    fs.appDocDir = root;
    logs = Directory('${root.path}/logs')..createSync();
    native = Directory('${logs.path}/facetime-native')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('production export includes only the two capped native generations', () {
    File('${logs.path}/bluebubbles-latest.log').writeAsStringSync('ordinary');
    File(
      '${native.path}/facetime-native.log',
    ).writeAsStringSync('stage=close_reason state=web_leave\n');
    File(
      '${native.path}/facetime-native-previous.log',
    ).writeAsStringSync('stage=media_bytes bytes=4096\n');
    File('${native.path}/capture.log').writeAsStringSync('do not export');
    final archive = ZipDecoder().decodeBytes(
      File(BaseLogger().compressLogs()).readAsBytesSync(),
    );
    final contents = {
      for (final file in archive.files)
        file.name: utf8.decode(file.readBytes()!),
    };
    expect(contents.length, 3);
    expect(
      contents,
      containsPair(
        'facetime-native.log',
        'stage=close_reason state=web_leave\n',
      ),
    );
    expect(
      contents,
      containsPair(
        'facetime-native-previous.log',
        'stage=media_bytes bytes=4096\n',
      ),
    );
    expect(contents.containsKey('capture.log'), isFalse);
  });

  test('production export excludes oversized native data', () {
    File(
      '${native.path}/facetime-native.log',
    ).writeAsBytesSync(List.filled(65537, 65));
    File(
      '${native.path}/facetime-native-previous.log',
    ).writeAsStringSync('bounded');
    final archive = ZipDecoder().decodeBytes(
      File(BaseLogger().compressLogs()).readAsBytesSync(),
    );
    expect(archive.files.map((file) => file.name), [
      'facetime-native-previous.log',
    ]);
  });

  test(
    'production clear removes owned native logs but not unrelated captures',
    () {
      File('${native.path}/facetime-native.log').writeAsStringSync('bounded');
      File(
        '${native.path}/facetime-native-previous.log',
      ).writeAsStringSync('bounded');
      final other = File('${native.path}/capture.log')
        ..writeAsStringSync('retain');
      BaseLogger().clearLogs();
      expect(BaseLogger().nativeFaceTimeLogFiles, isEmpty);
      expect(other.readAsStringSync(), 'retain');
    },
  );
}
