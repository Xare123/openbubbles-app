import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_shadow_report.dart';

/// Persists one allowlisted shadow report through a same-directory atomic
/// rename.
///
/// Reports contain only [CloudSyncShadowReport.toJson]. The writer never
/// accepts arbitrary maps, log lines, account identifiers, or CloudKit data.
final class CloudSyncShadowReportFileWriter {
  CloudSyncShadowReportFileWriter({
    required String privateReportDirectory,
    String? trustedStorageRoot,
    this.maximumRetainedReports = 20,
    DateTime Function()? now,
  }) : _directory = Directory(privateReportDirectory).absolute,
       _trustedStorageRoot = Directory(
         trustedStorageRoot ?? path.dirname(privateReportDirectory),
       ).absolute,
       _now = now ?? DateTime.now {
    if (maximumRetainedReports < 1 || maximumRetainedReports > 100) {
      throw ArgumentError.value(
        maximumRetainedReports,
        'maximumRetainedReports',
        'cloud_sync_report_retention_invalid',
      );
    }
    if (!path.isWithin(_trustedStorageRoot.path, _directory.path)) {
      throw ArgumentError('cloud_sync_report_directory_outside_storage');
    }
  }

  static const int maximumEncodedBytes = 256 * 1024;
  static final RegExp _safeRunId = RegExp(
    r'^obcs2-shadow-[A-Za-z0-9_-]{1,60}$',
  );
  static final RegExp _ownedReportName = RegExp(
    r'^obcs2-shadow-[A-Za-z0-9_-]{1,60}\.json$',
  );
  static final RegExp _ownedTemporaryName = RegExp(
    r'^\.obcs2-shadow-[A-Za-z0-9_-]{1,60}\.[0-9a-f]{24}\.tmp$',
  );
  static final RegExp _safeCorrelationTag = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
  static final RegExp _safeBuildIdentifier = RegExp(r'^[A-Za-z0-9._+-]{1,80}$');
  static const Set<String> _supportedPlatforms = {'android', 'windows'};
  static const Set<String> _supportedArchitectures = {
    'android_arm64',
    'windows_arm64',
    'windows_x64',
    // Test and imported redacted reports may use the architecture shorthand.
    'arm64',
    'x64',
  };
  static const Set<String> _supportedZoneLabels = {
    'chats',
    'messages',
    'attachments',
  };
  static const Duration _orphanedTemporaryAge = Duration(hours: 24);
  static const int _maximumZoneElapsedMilliseconds = 10 * 60 * 1000;

  final Directory _directory;
  final Directory _trustedStorageRoot;
  final DateTime Function() _now;
  final int maximumRetainedReports;

  Future<File> write(CloudSyncShadowReport report) async {
    if (!_safeRunId.hasMatch(report.runId)) {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_run_id_invalid',
      );
    }
    if (!_isValidReportContract(report)) {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_contract_invalid',
      );
    }

    try {
      if (!await _trustedStorageRoot.exists()) {
        throw const CloudSyncShadowReportFileException(
          'cloud_sync_report_storage_unavailable',
        );
      }
      await _directory.create(recursive: true);
    } on FileSystemException {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_directory_unavailable',
      );
    }

    final canonicalDirectory = await _verifiedDirectoryPath();
    final verifiedDirectory = Directory(canonicalDirectory);
    final target = File(path.join(canonicalDirectory, '${report.runId}.json'));
    if (path.dirname(path.normalize(target.path)) != canonicalDirectory) {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_path_invalid',
      );
    }
    if (await target.exists()) {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_already_exists',
      );
    }
    await _makeRoomForOneReport(verifiedDirectory);

    final encoded = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(report.toJson()),
    );
    if (encoded.length > maximumEncodedBytes) {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_too_large',
      );
    }

    final random = Random.secure();
    final nonce = List<int>.generate(
      12,
      (_) => random.nextInt(256),
      growable: false,
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final temporary = File(
      path.join(canonicalDirectory, '.${report.runId}.$nonce.tmp'),
    );

    RandomAccessFile? handle;
    try {
      await temporary.create(exclusive: true);
      handle = await temporary.open(mode: FileMode.writeOnly);
      await handle.writeFrom(encoded);
      await handle.flush();
      await handle.close();
      handle = null;
      if (await _verifiedDirectoryPath() != canonicalDirectory) {
        throw const CloudSyncShadowReportFileException(
          'cloud_sync_report_directory_changed',
        );
      }
      return await temporary.rename(target.path);
    } on FileSystemException {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_write_failed',
      );
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } on FileSystemException {
          // The original fixed failure remains authoritative.
        }
      }
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // A unique, content-free temporary report can be reclaimed later.
        }
      }
    }
  }

  bool _isValidReportContract(CloudSyncShadowReport report) {
    if (!_safeCorrelationTag.hasMatch(report.correlationTag) ||
        !_supportedPlatforms.contains(report.platform) ||
        !_supportedArchitectures.contains(report.architecture) ||
        !_safeBuildIdentifier.hasMatch(report.buildCommit) ||
        !report.timestampUtc.isUtc ||
        report.legacySyncEnabled ||
        report.pageLimit != 1 ||
        report.changeLimit != 50 ||
        !report.tripwiresArmed ||
        report.outboxCountBefore != 0 ||
        report.outboxCountAfter != 0 ||
        report.zones.length != _supportedZoneLabels.length) {
      return false;
    }
    final labels = <String>{};
    for (final zone in report.zones) {
      if (!_supportedZoneLabels.contains(zone.zoneLabel) ||
          !labels.add(zone.zoneLabel) ||
          zone.fetched < 0 ||
          zone.fetched > report.pageLimit * report.changeLimit ||
          zone.journaled < 0 ||
          zone.journaled > report.pageLimit * report.changeLimit ||
          zone.rejected < 0 ||
          zone.rejected > report.pageLimit * report.changeLimit ||
          zone.estimatedBytes < 0 ||
          zone.estimatedBytes > 8 * 1024 * 1024 ||
          zone.elapsedMilliseconds < 0 ||
          zone.elapsedMilliseconds > _maximumZoneElapsedMilliseconds) {
        return false;
      }
    }
    return labels.length == _supportedZoneLabels.length;
  }

  Future<String> _verifiedDirectoryPath() async {
    try {
      final trusted = path.normalize(
        await _trustedStorageRoot.resolveSymbolicLinks(),
      );
      final reports = path.normalize(await _directory.resolveSymbolicLinks());
      if (!path.isWithin(trusted, reports)) {
        throw const CloudSyncShadowReportFileException(
          'cloud_sync_report_directory_unsafe',
        );
      }
      return reports;
    } on CloudSyncShadowReportFileException {
      rethrow;
    } on FileSystemException {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_directory_unavailable',
      );
    }
  }

  Future<void> _makeRoomForOneReport(Directory verifiedDirectory) async {
    try {
      final reports = <({File file, DateTime modified})>[];
      final reclaimBefore = _now().toUtc().subtract(_orphanedTemporaryAge);
      await for (final entity in verifiedDirectory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = path.basename(entity.path);
        final modified = await entity.lastModified();
        if (_ownedReportName.hasMatch(name)) {
          reports.add((file: entity, modified: modified));
        } else if (_ownedTemporaryName.hasMatch(name) &&
            modified.toUtc().isBefore(reclaimBefore)) {
          await entity.delete();
        }
      }
      final removeCount = reports.length - maximumRetainedReports + 1;
      if (removeCount <= 0) return;
      reports.sort((left, right) {
        final modified = left.modified.compareTo(right.modified);
        return modified != 0
            ? modified
            : left.file.path.compareTo(right.file.path);
      });
      for (final report in reports.take(removeCount)) {
        await report.file.delete();
      }
    } on FileSystemException {
      throw const CloudSyncShadowReportFileException(
        'cloud_sync_report_retention_failed',
      );
    }
  }
}

final class CloudSyncShadowReportFileException implements Exception {
  const CloudSyncShadowReportFileException(this.safeCode);

  final String safeCode;

  @override
  String toString() => 'CloudSyncShadowReportFileException($safeCode)';
}
