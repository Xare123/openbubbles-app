import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/services/network/download_file_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'openbubbles-download-test-',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('writes byte-backed downloads before returning the destination',
      () async {
    final target =
        File('${tempDirectory.path}${Platform.pathSeparator}photo.jpg');
    final result = await materializeDownloadedFile(
      targetPath: target.path,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );

    expect(result.path, target.path);
    expect(await target.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(
      tempDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('replaces a stale empty destination with the completed bytes', () async {
    final target =
        File('${tempDirectory.path}${Platform.pathSeparator}video.mov');
    await target.create(recursive: true);

    await materializeDownloadedFile(
      targetPath: target.path,
      bytes: Uint8List.fromList(<int>[9, 8, 7]),
    );

    expect(await target.readAsBytes(), <int>[9, 8, 7]);
  });

  test('accepts a non-empty file written directly by the backend', () async {
    final target =
        File('${tempDirectory.path}${Platform.pathSeparator}voice.caf');
    await target.writeAsBytes(<int>[4, 5, 6], flush: true);

    final result = await materializeDownloadedFile(
      targetPath: target.path,
      sourcePath: target.path,
    );

    expect(result.path, target.path);
    expect(await result.length(), 3);
  });

  test('rejects missing and zero-byte download results', () async {
    final target =
        File('${tempDirectory.path}${Platform.pathSeparator}empty.bin');

    await expectLater(
      materializeDownloadedFile(
        targetPath: target.path,
        bytes: Uint8List(0),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target.exists(), isFalse);
  });

  test('promotes a backend-written source file to the destination', () async {
    final source = File(
      '${tempDirectory.path}${Platform.pathSeparator}staging${Platform.pathSeparator}photo.jpg',
    );
    await source.create(recursive: true);
    await source.writeAsBytes(<int>[7, 7, 7, 7], flush: true);
    final target = File(
      '${tempDirectory.path}${Platform.pathSeparator}attachments${Platform.pathSeparator}photo.jpg',
    );

    final result = await materializeDownloadedFile(
      targetPath: target.path,
      sourcePath: source.path,
    );

    expect(result.path, target.path);
    expect(await target.readAsBytes(), <int>[7, 7, 7, 7]);
    expect(
      tempDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.part')),
      isEmpty,
    );
  });
}
