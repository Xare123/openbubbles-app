import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';

Future<String?> persistDownloadedAttachmentBytes({
  required Uint8List? bytes,
  required String? responsePath,
  required String fallbackPath,
  bool isWeb = kIsWeb,
}) async {
  if (isWeb || bytes == null) return responsePath;

  final targetPath = responsePath ?? fallbackPath;
  final target = await File(targetPath).create(recursive: true);
  await target.writeAsBytes(bytes);
  return target.path;
}
