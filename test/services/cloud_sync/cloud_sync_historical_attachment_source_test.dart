import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_attachment_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Read-only availability-hint tests over real temp files. The probe never
/// certifies bytes and performs no native staging: only absence defers.
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'historical-attachment-source-probe-',
    );
  });

  tearDown(() async {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  String path(String name) => '${directory.path}${Platform.pathSeparator}$name';

  test('missing and empty paths are unavailable without throwing', () async {
    expect(await cloudSyncHistoricalAttachmentSourceAvailable(''), isFalse);
    expect(
      await cloudSyncHistoricalAttachmentSourceAvailable(path('absent.bin')),
      isFalse,
    );
  });

  test('present file with bytes is available', () async {
    final file = File(path('photo.jpg'));
    await file.writeAsBytes(List.filled(64, 7));
    expect(
      await cloudSyncHistoricalAttachmentSourceAvailable(file.path),
      isTrue,
    );
  });

  test('empty file reads zero bytes and stays available', () async {
    final file = File(path('empty.bin'));
    await file.writeAsBytes(const []);
    expect(
      await cloudSyncHistoricalAttachmentSourceAvailable(file.path),
      isTrue,
    );
  });

  test('directory reports unreadable with the fixed redacted error', () async {
    try {
      await cloudSyncHistoricalAttachmentSourceAvailable(directory.path);
      fail('expected StateError');
    } on StateError catch (error) {
      expect(error.message, 'cloud_sync_attachment_plan_source_unreadable');
    }
  });

  test(
    'failed type lookup does not disguise a denied open as a missing file',
    () async {
      await IOOverrides.runZoned(
        () async {
          await expectLater(
            cloudSyncHistoricalAttachmentSourceAvailable(path('private.bin')),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'code',
                'cloud_sync_attachment_plan_source_unreadable',
              ),
            ),
          );
        },
        fseGetType: (_, __) async => FileSystemEntityType.notFound,
        createFile: (path) => _FailedOpenFile(path, 13),
      );
    },
  );

  test(
    'failed type lookup with exact file-not-found open is a deferral',
    () async {
      await IOOverrides.runZoned(
        () async {
          expect(
            await cloudSyncHistoricalAttachmentSourceAvailable(
              path('missing.bin'),
            ),
            isFalse,
          );
        },
        fseGetType: (_, __) async => FileSystemEntityType.notFound,
        createFile: (path) => _FailedOpenFile(path, 2),
      );
    },
  );

  test('ambiguous type lookup cannot certify a file that opens', () async {
    final file = File(path('present.bin'));
    await file.writeAsBytes([1]);
    await IOOverrides.runZoned(() async {
      await expectLater(
        cloudSyncHistoricalAttachmentSourceAvailable(file.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'code',
            'cloud_sync_attachment_plan_source_unreadable',
          ),
        ),
      );
    }, fseGetType: (_, __) async => FileSystemEntityType.notFound);
  });

  test('malformed path has a fixed content-free failure', () async {
    await expectLater(
      cloudSyncHistoricalAttachmentSourceAvailable('${path('private')}\u0000'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'code',
          'cloud_sync_attachment_plan_source_unreadable',
        ),
      ),
    );
  });
}

final class _FailedOpenFile implements File {
  _FailedOpenFile(this.path, this.errorCode);
  @override
  final String path;
  final int errorCode;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      throw FileSystemException(
        'synthetic inaccessible path',
        path,
        OSError('synthetic OS error', errorCode),
      );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected_file_operation');
}
