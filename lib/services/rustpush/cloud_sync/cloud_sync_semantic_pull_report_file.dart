import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_semantic_pull_report.dart';

/// Persists one typed, content-free semantic Canary report atomically.
final class CloudSyncSemanticPullReportFileWriter {
  CloudSyncSemanticPullReportFileWriter({
    required String privateReportDirectory,
    required String trustedStorageRoot,
    this.maximumRetainedReports = 20,
  }) : _directory = Directory(privateReportDirectory).absolute,
       _trustedStorageRoot = Directory(trustedStorageRoot).absolute {
    if (maximumRetainedReports < 1 || maximumRetainedReports > 100) {
      throw ArgumentError.value(maximumRetainedReports);
    }
    if (!path.isWithin(_trustedStorageRoot.path, _directory.path)) {
      throw const CloudSyncSemanticPullReportFileException(
        'cloud_sync_semantic_report_directory_invalid',
      );
    }
  }

  static const int maximumEncodedBytes = 256 * 1024;
  static const int maximumDiagnosticCount = 65535;
  static const int _maximumReadElapsedMilliseconds = 10 * 60 * 1000;
  static const int _projectionSweepBaseElapsedMilliseconds = 30 * 60 * 1000;
  static const int _projectionSweepElapsedMillisecondsPerBatch =
      2 * 60 * 1000;
  static final RegExp _ownedReportName = RegExp(
    r'^obcs2-semantic-[0-9]{1,24}\.json$',
  );
  static final RegExp _safeBuildIdentifier = RegExp(r'^[A-Za-z0-9._+-]{1,80}$');
  static const Set<String> _supportedPlatforms = {'android', 'windows'};
  static const Set<String> _supportedArchitectures = {
    'android_arm64',
    'windows_arm64',
    'windows_x64',
    'arm64',
    'x64',
  };
  static const Set<String> _supportedZoneLabels = {
    'chats',
    'messages',
    'attachments',
  };

  final Directory _directory;
  final Directory _trustedStorageRoot;
  final int maximumRetainedReports;

  Future<File> write(CloudSyncSemanticPullReport report) async {
    final failure = _contractFailure(report);
    if (failure != null) {
      throw CloudSyncSemanticPullReportFileException(failure);
    }
    if (!await _trustedStorageRoot.exists()) {
      throw const CloudSyncSemanticPullReportFileException(
        'cloud_sync_semantic_report_storage_unavailable',
      );
    }
    try {
      await _directory.create(recursive: true);
    } on FileSystemException {
      throw const CloudSyncSemanticPullReportFileException(
        'cloud_sync_semantic_report_directory_unavailable',
      );
    }

    final trustedPath = path.normalize(
      await _trustedStorageRoot.resolveSymbolicLinks(),
    );
    final directoryPath = path.normalize(
      await _directory.resolveSymbolicLinks(),
    );
    if (!path.isWithin(trustedPath, directoryPath)) {
      throw const CloudSyncSemanticPullReportFileException(
        'cloud_sync_semantic_report_directory_untrusted',
      );
    }

    final runId =
        'obcs2-semantic-${report.timestampUtc.microsecondsSinceEpoch}';
    final target = File(path.join(directoryPath, '$runId.json'));
    if (await target.exists()) {
      throw const CloudSyncSemanticPullReportFileException(
        'cloud_sync_semantic_report_already_exists',
      );
    }

    final encoded = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(report.toJson()),
    );
    if (encoded.length > maximumEncodedBytes) {
      throw const CloudSyncSemanticPullReportFileException(
        'cloud_sync_semantic_report_too_large',
      );
    }

    final random = Random.secure();
    final nonce = List<int>.generate(
      12,
      (_) => random.nextInt(256),
      growable: false,
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final temporary = File(path.join(directoryPath, '.$runId.$nonce.tmp'));

    RandomAccessFile? handle;
    try {
      handle = await temporary.open(mode: FileMode.writeOnly);
      await handle.writeFrom(encoded);
      await handle.flush();
      await handle.close();
      handle = null;
      await temporary.rename(target.path);
      await _pruneOwnedReports(directoryPath, keep: target.path);
      return target;
    } on CloudSyncSemanticPullReportFileException {
      rethrow;
    } on FileSystemException {
      throw const CloudSyncSemanticPullReportFileException(
        'cloud_sync_semantic_report_write_failed',
      );
    } finally {
      await handle?.close();
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  String? _contractFailure(CloudSyncSemanticPullReport report) {
    if (!_supportedPlatforms.contains(report.platform) ||
        !_supportedArchitectures.contains(report.architecture) ||
        !_safeBuildIdentifier.hasMatch(report.buildCommit) ||
        !report.timestampUtc.isUtc) {
      return 'cloud_sync_semantic_report_metadata_invalid';
    }
    if (report.pageLimit != 4 ||
        report.changeLimit != 50 ||
        report.outboxCountBefore < 0 ||
        report.outboxCountBefore > maximumDiagnosticCount ||
        report.outboxCountAfter < 0 ||
        report.outboxCountAfter > maximumDiagnosticCount) {
      return 'cloud_sync_semantic_report_read_only_invariant_invalid';
    }
    // Missing or duplicate supported zones are unsafe runtime evidence, not an
    // unsafe serialization shape. Persist up to the expected count so the
    // controller can stop on, and retain, the exact diagnostic report.
    if (report.zones.length > _supportedZoneLabels.length) {
      return 'cloud_sync_semantic_report_zone_count_invalid';
    }
    final maximumZoneRecords = report.pageLimit * report.changeLimit;
    // Normal semantic runs may examine one bounded retained-projection window
    // before consuming their complete four-page remote-fetch allowance. Both
    // lanes share the report counters, so bound total local work separately
    // from the unchanged remote fetched-record ceiling.
    final maximumZoneWorkRecords =
        maximumZoneRecords + maximumZoneRecords - report.changeLimit;
    for (final zone in report.zones) {
      final projectionSweep =
          report.mode == CloudSyncSemanticReportMode.retainedProjectionSweep;
      final maximumApplied = projectionSweep
          ? maximumDiagnosticCount
          : maximumZoneWorkRecords;
      // A retained sweep is bounded by both its sequence window and batch cap,
      // but its wall time scales with the amount of local history examined.
      // Keep corruption detection without rejecting valid large-history runs.
      final maximumElapsedMilliseconds = projectionSweep
          ? _projectionSweepBaseElapsedMilliseconds +
              zone.projectionBatches *
                  _projectionSweepElapsedMillisecondsPerBatch
          : _maximumReadElapsedMilliseconds;
      if (!_supportedZoneLabels.contains(zone.zoneLabel) ||
          zone.fetched < 0 ||
          zone.fetched > maximumZoneRecords ||
          zone.applied < 0 ||
          zone.applied > maximumApplied ||
          zone.deferred < 0 ||
          zone.deferred > maximumZoneWorkRecords ||
          zone.quarantined < 0 ||
          zone.quarantined > maximumZoneWorkRecords ||
          zone.preflightQuarantined < 0 ||
          zone.preflightQuarantined > maximumZoneWorkRecords ||
          zone.preflightUnsupportedRecordType < 0 ||
          zone.preflightUnsupportedRecordType > maximumZoneWorkRecords ||
          zone.preflightMalformedMetadata < 0 ||
          zone.preflightMalformedMetadata > maximumZoneWorkRecords ||
          zone.preflightOversizedRecord < 0 ||
          zone.preflightOversizedRecord > maximumZoneWorkRecords ||
          zone.preflightInvalidChangeShape < 0 ||
          zone.preflightInvalidChangeShape > maximumZoneWorkRecords ||
          zone.preflightUnknown < 0 ||
          zone.preflightUnknown > maximumZoneWorkRecords ||
          zone.startupQuarantined < 0 ||
          zone.startupQuarantined > maximumZoneWorkRecords ||
          zone.postFetchQuarantined < 0 ||
          zone.postFetchQuarantined > maximumZoneWorkRecords ||
          zone.tombstoneQuarantined < 0 ||
          zone.tombstoneQuarantined > maximumZoneWorkRecords ||
          zone.tombstoneReadOnlyAcknowledged < 0 ||
          zone.tombstoneReadOnlyAcknowledged > maximumZoneWorkRecords ||
          zone.retainedUnprojected < 0 ||
          zone.retainedUnprojected > maximumDiagnosticCount ||
          zone.semanticUnsupportedServiceQuarantined < 0 ||
          zone.semanticUnsupportedServiceQuarantined > maximumZoneWorkRecords ||
          zone.semanticStageQuarantined < 0 ||
          zone.semanticStageQuarantined > maximumZoneWorkRecords ||
          zone.retried < 0 ||
          zone.retried > maximumZoneWorkRecords ||
          (zone.observedEmptyTerminalRead && zone.fetched != 0) ||
          zone.elapsedMilliseconds < 0 ||
          zone.elapsedMilliseconds > maximumElapsedMilliseconds ||
          zone.projectionExamined < 0 ||
          zone.projectionExamined > maximumDiagnosticCount ||
          zone.projectionRetained < 0 ||
          zone.projectionRetained > zone.projectionExamined ||
          zone.projectionBatches < 0 ||
          zone.projectionBatches > 4096 ||
          (!projectionSweep &&
              (zone.projectionExamined != 0 ||
                  zone.projectionRetained != 0 ||
                  zone.projectionBatches != 0)) ||
          (projectionSweep &&
              (zone.fetched != 0 ||
                  zone.observedEmptyTerminalRead ||
                  zone.projectionExamined !=
                      zone.applied + zone.projectionRetained)) ||
          // Diagnostic events are not record counters. A single fetched chat
          // can emit several alias diagnostics, and same-generation projection
          // repair can inspect more rows than the one-page fetch limit. The
          // collector already rejects non-positive counts. A separate ceiling
          // catches corrupt aggregates without conflating them with the fetch
          // page or projection-repair limits.
          zone.diagnosticCounts.values.any(
            (count) => count > maximumDiagnosticCount,
          )) {
        return 'cloud_sync_semantic_report_zone_invalid';
      }
    }
    return null;
  }

  Future<void> _pruneOwnedReports(
    String directoryPath, {
    required String keep,
  }) async {
    final reports = <File>[];
    await for (final entity in Directory(
      directoryPath,
    ).list(followLinks: false)) {
      if (entity is File &&
          _ownedReportName.hasMatch(path.basename(entity.path))) {
        reports.add(entity);
      }
    }
    if (reports.length <= maximumRetainedReports) return;
    reports.sort((left, right) => left.path.compareTo(right.path));
    for (final report in reports.take(
      reports.length - maximumRetainedReports,
    )) {
      if (path.equals(report.path, keep)) continue;
      await report.delete();
    }
  }
}

final class CloudSyncSemanticPullReportFileException implements Exception {
  const CloudSyncSemanticPullReportFileException(this.safeCode);

  final String safeCode;

  @override
  String toString() => 'CloudSyncSemanticPullReportFileException($safeCode)';
}
