import 'dart:io';
import 'dart:typed_data';

int _stagingFileCounter = 0;

/// Makes a completed download available at [targetPath] before consumers are
/// notified. Byte-backed downloads are staged next to the destination and
/// promoted only after a non-empty file has been written.
Future<File> materializeDownloadedFile({
  required String targetPath,
  Uint8List? bytes,
  String? sourcePath,
}) async {
  final target = File(targetPath);

  if (bytes != null && bytes.isNotEmpty) {
    await _stageAndPromote(
      target,
      (stagingPath) => File(stagingPath).writeAsBytes(bytes, flush: true),
    );
  } else if (!await _isNonEmpty(target)) {
    final source = sourcePath == null ? null : File(sourcePath);
    if (source == null || !await _isNonEmpty(source)) {
      throw FileSystemException(
        'Downloaded attachment is missing or empty',
        targetPath,
      );
    }

    if (!_samePath(source.path, target.path)) {
      await _stageAndPromote(
        target,
        (stagingPath) => source.copy(stagingPath),
      );
    }
  }

  if (!await _isNonEmpty(target)) {
    throw FileSystemException(
      'Downloaded attachment is missing or empty',
      targetPath,
    );
  }
  return target;
}

Future<void> _stageAndPromote(
  File target,
  Future<File> Function(String stagingPath) writeStagingFile,
) async {
  await target.parent.create(recursive: true);
  final staging = File(
    '${target.path}.download-$pid-'
    '${DateTime.now().microsecondsSinceEpoch}-${_stagingFileCounter++}.part',
  );

  try {
    await writeStagingFile(staging.path);
    if (!await _isNonEmpty(staging)) {
      throw FileSystemException(
        'Downloaded attachment staging file is empty',
        staging.path,
      );
    }

    try {
      await staging.rename(target.path);
    } on FileSystemException {
      // Dart replaces existing files on supported Windows versions. Retain a
      // narrow fallback for filesystems that reject replacement by rename.
      if (await target.exists()) await target.delete();
      await staging.rename(target.path);
    }
  } finally {
    if (await staging.exists()) {
      await staging.delete();
    }
  }
}

Future<bool> _isNonEmpty(File file) async {
  return await file.exists() && await file.length() > 0;
}

bool _samePath(String first, String second) {
  final firstAbsolute = File(first).absolute.path;
  final secondAbsolute = File(second).absolute.path;
  if (Platform.isWindows) {
    return firstAbsolute.toLowerCase() == secondAbsolute.toLowerCase();
  }
  return firstAbsolute == secondAbsolute;
}
