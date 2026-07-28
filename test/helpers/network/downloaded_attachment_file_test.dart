import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/helpers/network/downloaded_attachment_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persists downloaded bytes before returning the playable path',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('openbubbles-download-test-');
    addTearDown(() => directory.delete(recursive: true));
    final target = '${directory.path}${Platform.pathSeparator}audio.m4a';
    final bytes = Uint8List.fromList([0, 1, 2, 3, 4]);

    final path = await persistDownloadedAttachmentBytes(
      bytes: bytes,
      responsePath: target,
      fallbackPath: 'unused',
      isWeb: false,
    );

    expect(path, target);
    expect(await File(target).readAsBytes(), bytes);
  });

  test('uses the attachment path when the backend returns bytes only',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('openbubbles-download-test-');
    addTearDown(() => directory.delete(recursive: true));
    final fallback = '${directory.path}${Platform.pathSeparator}photo.jpg';
    final bytes = Uint8List.fromList([5, 6, 7]);

    final path = await persistDownloadedAttachmentBytes(
      bytes: bytes,
      responsePath: null,
      fallbackPath: fallback,
      isWeb: false,
    );

    expect(path, fallback);
    expect(await File(fallback).readAsBytes(), bytes);
  });

  test('does not write native files for web downloads', () async {
    final directory =
        await Directory.systemTemp.createTemp('openbubbles-download-test-');
    addTearDown(() => directory.delete(recursive: true));
    final target = '${directory.path}${Platform.pathSeparator}video.mov';

    final path = await persistDownloadedAttachmentBytes(
      bytes: Uint8List.fromList([8, 9]),
      responsePath: target,
      fallbackPath: 'unused',
      isWeb: true,
    );

    expect(path, target);
    expect(await File(target).exists(), isFalse);
  });
}
