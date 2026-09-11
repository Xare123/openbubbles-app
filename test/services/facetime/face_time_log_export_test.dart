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

  for (final names in [
    ['facetime-native.log'],
    ['facetime-native-previous.log'],
    ['facetime-native.log', 'facetime-native-previous.log'],
  ]) {
    test(
      'native-only sources are eligible and exported: ${names.join(', ')}',
      () {
        final logger = BaseLogger();
        expect(logger.exportLogFiles, isEmpty);
        for (final name in names) {
          File('${native.path}/$name').writeAsBytesSync(List.filled(1024, 65));
        }
        final sources = logger.exportLogFiles;
        expect(sources.length, names.length);
        expect(
          sources.fold<int>(0, (bytes, file) => bytes + file.lengthSync()),
          names.length * 1024,
        );
        expect(
          root.listSync().whereType<File>(),
          isEmpty,
          reason: 'Counting must not create an export',
        );
        final archive = ZipDecoder().decodeBytes(
          File(logger.compressLogs()).readAsBytesSync(),
        );
        expect(archive.files.map((file) => file.name), unorderedEquals(names));
      },
    );
  }

  test('eligibility excludes oversized, unrelated and directory entries', () {
    File(
      '${native.path}/facetime-native.log',
    ).writeAsBytesSync(List.filled(65537, 65));
    File(
      '${native.path}/capture.log',
    ).writeAsStringSync('not an export source');
    Directory('${logs.path}/not-a-file.log').createSync();
    expect(BaseLogger().exportLogFiles, isEmpty);
    File(
      '${native.path}/facetime-native-previous.log',
    ).writeAsBytesSync(List.filled(65536, 65));
    expect(BaseLogger().exportLogFiles.single.lengthSync(), 65536);
  });

  test('UI refreshes shared export sources before checking eligibility', () {
    final source = File(
      'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
    ).readAsStringSync();
    final refresh = source.substring(
      source.indexOf('void refreshLogFileStats()'),
      source.indexOf('void initState()'),
    );
    expect(refresh, contains('final logFiles = Logger.exportLogFiles;'));
    expect(refresh, contains('logFileCount.value = logFiles.length;'));
    expect(refresh, contains('logFileSize.value = logFiles.fold<int>'));
    final actionStart = source.indexOf('title: "Download / Share Logs"');
    final action = source.substring(
      actionStart,
      source.indexOf('String filePath = Logger.compressLogs();', actionStart),
    );
    expect(action.indexOf('refreshLogFileStats();'), greaterThanOrEqualTo(0));
    expect(
      action.indexOf('refreshLogFileStats();'),
      lessThan(action.indexOf('if (logFileCount.value == 0)')),
    );
  });

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
