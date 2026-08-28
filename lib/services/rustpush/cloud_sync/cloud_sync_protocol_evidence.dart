import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:universal_io/io.dart';

import 'cloud_sync_observability.dart';

/// A fixed, local-only diagnostic record for the CloudKit V2 canary.
///
/// This is deliberately separate from the application logger.  In
/// particular, [CloudSyncEvent.scopeDiagnosticKey] is accepted as part of the
/// source event but is never copied into this record or its JSON encoding.
final class CloudSyncProtocolEvidenceRecord {
  static const int schemaVersion = 1;
  static const int maximumCount = 1 << 30;
  static const int maximumEstimatedBytes = 1 << 30;
  static const int maximumAttempt = 1 << 20;
  static const int maximumElapsedMilliseconds = 24 * 60 * 60 * 1000;

  static const Set<String> supportedZoneLabels = {
    'chatManateeZone',
    'messageManateeZone',
    'attachmentManateeZone',
    'messageUpdateZone',
    'recoverableMessageDeleteZone',
    'scheduledMessageZone',
    'chat1ManateeZone',
    'recoverableMessageManateeZone',
    'profileManateeZone',
    'chats',
    'messages',
    'attachments',
    'profiles',
  };

  static const Set<String> supportedStreamLabels = {'messages', 'profiles'};
  static const Set<String> supportedPlatforms = {'android', 'windows'};
  static const Set<String> supportedArchitectures = {
    'arm64',
    'x64',
    'android_arm64',
    'windows_arm64',
    'windows_x64',
  };

  static const Set<String> jsonKeys = {
    'schemaVersion',
    'timestampUtc',
    'zone',
    'stream',
    'eventType',
    'trigger',
    'failure',
    'skip',
    'journalBlock',
    'count',
    'estimatedBytes',
    'attempt',
    'elapsedMs',
    'platform',
    'architecture',
    'buildCommit',
  };

  CloudSyncProtocolEvidenceRecord({
    required this.zoneLabel,
    required this.streamKindLabel,
    required this.platform,
    required this.architecture,
    required this.buildCommit,
    required this.eventType,
    required this.timestampUtc,
    this.triggerLabel = 'none',
    this.failureLabel = 'none',
    this.skipLabel = 'none',
    this.journalBlockLabel = 'none',
    this.count = 0,
    this.estimatedBytes = 0,
    this.attempt = 0,
    this.elapsedMilliseconds = 0,
  }) {
    _validateLabel(zoneLabel, supportedZoneLabels, 'zone');
    _validateLabel(streamKindLabel, supportedStreamLabels, 'stream');
    _validateLabel(platform, supportedPlatforms, 'platform');
    _validateLabel(architecture, supportedArchitectures, 'architecture');
    _validateBuildCommit(buildCommit);
    _validateLabel(eventType, _eventTypeLabels, 'event_type');
    _validateOptionalLabel(triggerLabel, _triggerLabels, 'trigger');
    _validateOptionalLabel(failureLabel, _failureLabels, 'failure');
    _validateOptionalLabel(skipLabel, _skipLabels, 'skip');
    _validateOptionalLabel(
      journalBlockLabel,
      _journalBlockLabels,
      'journal_block',
    );
    _validateRange(count, 0, maximumCount, 'count');
    _validateRange(estimatedBytes, 0, maximumEstimatedBytes, 'estimated_bytes');
    _validateRange(attempt, 0, maximumAttempt, 'attempt');
    _validateRange(
      elapsedMilliseconds,
      0,
      maximumElapsedMilliseconds,
      'elapsed_ms',
    );
    if (timestampUtc.isUtc == false ||
        timestampUtc.year < 2000 ||
        timestampUtc.year > 2100) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_timestamp_invalid',
      );
    }
  }

  factory CloudSyncProtocolEvidenceRecord.fromEvent(
    CloudSyncEvent event, {
    required String zoneLabel,
    required String streamKindLabel,
    required String platform,
    required String architecture,
    required String buildCommit,
  }) {
    return CloudSyncProtocolEvidenceRecord(
      zoneLabel: zoneLabel,
      streamKindLabel: streamKindLabel,
      platform: platform,
      architecture: architecture,
      buildCommit: buildCommit,
      eventType: event.type.name,
      timestampUtc: event.at.toUtc(),
      triggerLabel: event.trigger?.name ?? 'none',
      failureLabel: event.failureCategory?.name ?? 'none',
      skipLabel: event.skipReason?.name ?? 'none',
      journalBlockLabel: event.shadowJournalBlockReason?.name ?? 'none',
      count: event.count,
      estimatedBytes: event.estimatedBytes,
      attempt: event.attempt,
      elapsedMilliseconds: event.elapsed.inMilliseconds,
    );
  }

  final String zoneLabel;
  final String streamKindLabel;
  final String platform;
  final String architecture;
  final String buildCommit;
  final String eventType;
  final DateTime timestampUtc;
  final String triggerLabel;
  final String failureLabel;
  final String skipLabel;
  final String journalBlockLabel;
  final int count;
  final int estimatedBytes;
  final int attempt;
  final int elapsedMilliseconds;

  /// A fixed-key object. Callers cannot supply additional fields.
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'timestampUtc': timestampUtc.toUtc().toIso8601String(),
    'zone': zoneLabel,
    'stream': streamKindLabel,
    'eventType': eventType,
    'trigger': triggerLabel,
    'failure': failureLabel,
    'skip': skipLabel,
    'journalBlock': journalBlockLabel,
    'count': count,
    'estimatedBytes': estimatedBytes,
    'attempt': attempt,
    'elapsedMs': elapsedMilliseconds,
    'platform': platform,
    'architecture': architecture,
    'buildCommit': buildCommit,
  };

  String toJsonLine() {
    final encoded = jsonEncode(toJson());
    if (utf8.encode(encoded).length + 1 >
        CloudSyncProtocolEvidenceWriter.maximumFileBytes) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_line_too_large',
      );
    }
    return encoded;
  }

  static const Set<String> _eventTypeLabels = {
    'runStarted',
    'runSkipped',
    'fetchCompleted',
    'inboxApplied',
    'outboxFlushed',
    'authenticationRefreshed',
    'pcsRefreshed',
    'serverConflictReconciled',
    'backoffScheduled',
    'shadowJournalBlocked',
    'runCompleted',
    'runFailed',
    'runCancelled',
  };

  static const Set<String> _triggerLabels = {
    'startup',
    'networkReconnect',
    'localOutbox',
    'idsReconnect',
    'detectedGap',
    'manual',
    'notificationHint',
    'none',
  };

  static const Set<String> _failureLabels = {
    'network',
    'throttled',
    'server',
    'authorization',
    'pcsUnavailable',
    'malformedRecord',
    'conflict',
    'dependency',
    'localStorage',
    'cancelled',
    'unknown',
    'unsupportedService',
    'none',
  };

  static const Set<String> _skipLabels = {
    'localRunActive',
    'coordinatorLeaseUnavailable',
    'pullBackoffActive',
    'featureDisabled',
    'none',
  };

  static const Set<String> _journalBlockLabels = {
    'maximumAge',
    'maximumEntries',
    'maximumEstimatedBytes',
    'none',
  };

  static void _validateLabel(
    String value,
    Set<String> allowlist,
    String field,
  ) {
    if (!allowlist.contains(value)) {
      throw CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_${field}_invalid',
      );
    }
  }

  static void _validateOptionalLabel(
    String value,
    Set<String> allowlist,
    String field,
  ) {
    if (!allowlist.contains(value)) {
      throw CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_${field}_invalid',
      );
    }
  }

  static void _validateBuildCommit(String value) {
    if (!RegExp(r'^[A-Za-z0-9._+\-]{1,80}$').hasMatch(value)) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_build_commit_invalid',
      );
    }
  }

  static void _validateRange(
    int value,
    int minimum,
    int maximum,
    String field,
  ) {
    if (value < minimum || value > maximum) {
      throw CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_${field}_invalid',
      );
    }
  }
}

/// Writes only the three owned JSONL files in a verified private directory.
final class CloudSyncProtocolEvidenceWriter {
  static const int maximumFileBytes = 256 * 1024;
  static const int maximumRetainedFiles = 3;
  static const String _filePrefix = 'cloud-sync-v2-evidence';
  static final RegExp _ownedFileName = RegExp(
    r'^cloud-sync-v2-evidence-(?:0|1|2)\.jsonl$',
  );

  CloudSyncProtocolEvidenceWriter._({
    required Directory privateDirectory,
    required Directory trustedRoot,
    required this.now,
  }) : _privateDirectory = privateDirectory.absolute,
       _trustedRoot = trustedRoot.absolute;

  static Future<CloudSyncProtocolEvidenceWriter> open({
    required String privateDirectory,
    required String trustedRoot,
    DateTime Function()? now,
  }) async {
    final writer = CloudSyncProtocolEvidenceWriter._(
      privateDirectory: Directory(privateDirectory),
      trustedRoot: Directory(trustedRoot),
      now: now ?? DateTime.now,
    );
    await writer._initialize();
    return writer;
  }

  final Directory _privateDirectory;
  final Directory _trustedRoot;
  final DateTime Function() now;
  String? _canonicalRootPath;
  String? _canonicalDirectoryPath;
  Future<void> _pending = Future<void>.value();
  CloudSyncProtocolEvidenceException? _pendingFailure;

  String get currentFilePath =>
      path.join(_canonicalDirectoryPath!, '$_filePrefix-0.jsonl');

  Future<void> append(CloudSyncProtocolEvidenceRecord record) {
    final result = _pending.then<void>((_) async {
      if (_pendingFailure != null) return;
      try {
        await _appendNow(record);
      } on CloudSyncProtocolEvidenceException catch (error) {
        _pendingFailure ??= error;
      } catch (_) {
        _pendingFailure ??= const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_write_failed',
        );
      }
    });
    _pending = result.catchError((_) {});
    return result.then<void>((_) {
      final failure = _pendingFailure;
      if (failure != null) throw failure;
    });
  }

  Future<void> flush() async {
    await _pending;
    final failure = _pendingFailure;
    if (failure != null) throw failure;
  }

  Future<void> _initialize() async {
    try {
      final rootType = await FileSystemEntity.type(
        _trustedRoot.path,
        followLinks: false,
      );
      if (rootType != FileSystemEntityType.directory) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_trusted_root_invalid',
        );
      }
      final canonicalRoot = path.normalize(
        await _trustedRoot.resolveSymbolicLinks(),
      );
      final requestedRoot = path.normalize(_trustedRoot.path);
      final requestedDirectory = path.normalize(_privateDirectory.path);
      if (!_isStrictChild(requestedRoot, requestedDirectory)) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_path_escape',
        );
      }
      final canonicalRequestedDirectory = path.normalize(
        path.join(
          canonicalRoot,
          path.relative(requestedDirectory, from: requestedRoot),
        ),
      );
      if (!_isStrictChild(canonicalRoot, canonicalRequestedDirectory)) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_path_escape',
        );
      }
      await _rejectSymlinkAncestors(canonicalRequestedDirectory, canonicalRoot);
      final requestedCanonicalDirectory = Directory(
        canonicalRequestedDirectory,
      );
      await requestedCanonicalDirectory.create(recursive: true);
      final directoryType = await FileSystemEntity.type(
        canonicalRequestedDirectory,
        followLinks: false,
      );
      if (directoryType != FileSystemEntityType.directory) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_directory_unsafe',
        );
      }
      final canonicalDirectory = path.normalize(
        await requestedCanonicalDirectory.resolveSymbolicLinks(),
      );
      if (!_isStrictChild(canonicalRoot, canonicalDirectory)) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_directory_unsafe',
        );
      }
      _canonicalRootPath = canonicalRoot;
      _canonicalDirectoryPath = canonicalDirectory;
      await _verifyDirectory();
      for (var index = 0; index < maximumRetainedFiles; index++) {
        await _verifyOwnedFile(File(_ownedPath(index)), allowMissing: true);
      }
      await _recoverPartialFinalLine();
    } on CloudSyncProtocolEvidenceException {
      rethrow;
    } on FileSystemException {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_directory_unavailable',
      );
    } catch (_) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_directory_unavailable',
      );
    }
  }

  Future<void> _appendNow(CloudSyncProtocolEvidenceRecord record) async {
    final line = record.toJsonLine();
    final bytes = <int>[...utf8.encode(line), 0x0a];
    if (bytes.length > maximumFileBytes) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_line_too_large',
      );
    }
    await _verifyDirectory();
    await _recoverPartialFinalLine();

    final current = File(currentFilePath);
    await _verifyOwnedFile(current, allowMissing: true);
    final currentLength = await current.exists() ? await current.length() : 0;
    if (currentLength > maximumFileBytes) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_file_corrupt',
      );
    }
    if (currentLength + bytes.length > maximumFileBytes) {
      await _rotate();
    }

    RandomAccessFile? handle;
    try {
      handle = await File(currentFilePath).open(mode: FileMode.append);
      await handle.writeFrom(bytes);
      await handle.flush();
    } on FileSystemException {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_write_failed',
      );
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } on FileSystemException {
          // The fixed write failure, if any, remains authoritative.
        }
      }
    }
    if (await File(currentFilePath).length() > maximumFileBytes) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_file_corrupt',
      );
    }
  }

  Future<void> _rotate() async {
    await _verifyDirectory();
    try {
      for (var index = maximumRetainedFiles - 1; index >= 1; index--) {
        final source = File(_ownedPath(index - 1));
        final destination = File(_ownedPath(index));
        await _verifyOwnedFile(source, allowMissing: true);
        await _verifyOwnedFile(destination, allowMissing: true);
        if (!await source.exists()) continue;
        if (await destination.exists()) await destination.delete();
        await source.rename(destination.path);
      }
    } on CloudSyncProtocolEvidenceException {
      rethrow;
    } on FileSystemException {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_retention_failed',
      );
    }
  }

  Future<void> _recoverPartialFinalLine() async {
    final current = File(currentFilePath);
    await _verifyOwnedFile(current, allowMissing: true);
    if (!await current.exists()) return;
    final bytes = await current.readAsBytes();
    if (bytes.isEmpty || bytes.last == 0x0a) return;
    final lastNewline = bytes.lastIndexOf(0x0a);
    final tail = bytes.sublist(lastNewline + 1);
    if (_isValidEncodedLine(tail)) {
      RandomAccessFile? handle;
      try {
        handle = await current.open(mode: FileMode.append);
        await handle.writeByte(0x0a);
        await handle.flush();
      } on FileSystemException {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_write_failed',
        );
      } finally {
        await handle?.close();
      }
      return;
    }
    try {
      await current.writeAsBytes(
        bytes.sublist(0, lastNewline + 1),
        flush: true,
      );
    } on FileSystemException {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_write_failed',
      );
    }
  }

  bool _isValidEncodedLine(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return false;
      return decoded.keys.toSet().containsAll(
            CloudSyncProtocolEvidenceRecord.jsonKeys,
          ) &&
          decoded.keys.toSet().length ==
              CloudSyncProtocolEvidenceRecord.jsonKeys.length;
    } catch (_) {
      return false;
    }
  }

  Future<void> _verifyDirectory() async {
    final root = _canonicalRootPath;
    final directory = _canonicalDirectoryPath;
    if (root == null || directory == null) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_directory_unsafe',
      );
    }
    try {
      final rootType = await FileSystemEntity.type(
        _trustedRoot.path,
        followLinks: false,
      );
      final directoryType = await FileSystemEntity.type(
        _privateDirectory.path,
        followLinks: false,
      );
      if (rootType != FileSystemEntityType.directory ||
          directoryType != FileSystemEntityType.directory ||
          path.normalize(await _trustedRoot.resolveSymbolicLinks()) != root ||
          path.normalize(await _privateDirectory.resolveSymbolicLinks()) !=
              directory ||
          !_isStrictChild(root, directory)) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_directory_unsafe',
        );
      }
    } on CloudSyncProtocolEvidenceException {
      rethrow;
    } on FileSystemException {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_directory_unavailable',
      );
    }
  }

  Future<void> _verifyOwnedFile(File file, {bool allowMissing = false}) async {
    final name = path.basename(file.path);
    if (!_ownedFileName.hasMatch(name) ||
        path.dirname(file.path) != _canonicalDirectoryPath) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_path_escape',
      );
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && allowMissing) return;
    if (type != FileSystemEntityType.file) {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_owned_file_invalid',
      );
    }
    try {
      if (path.normalize(await file.resolveSymbolicLinks()) != file.path) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_owned_file_invalid',
        );
      }
    } on CloudSyncProtocolEvidenceException {
      rethrow;
    } on FileSystemException {
      throw const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_owned_file_invalid',
      );
    }
  }

  Future<void> _rejectSymlinkAncestors(
    String requestedDirectory,
    String canonicalRoot,
  ) async {
    var current = requestedDirectory;
    while (_isStrictChild(canonicalRoot, current)) {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_directory_unsafe',
        );
      }
      current = path.dirname(current);
    }
  }

  String _ownedPath(int index) =>
      path.join(_canonicalDirectoryPath!, '$_filePrefix-$index.jsonl');

  static bool _isStrictChild(String parent, String child) =>
      path.normalize(parent) != path.normalize(child) &&
      path.isWithin(path.normalize(parent), path.normalize(child));
}

/// An observer that queues fixed-schema evidence in event order.
final class CloudSyncProtocolEvidenceObserver
    implements FlushableCloudSyncObserver {
  CloudSyncProtocolEvidenceObserver({
    required this.writer,
    required this.zoneLabel,
    required this.streamKindLabel,
    required this.platform,
    required this.architecture,
    required this.buildCommit,
  });

  final CloudSyncProtocolEvidenceWriter writer;
  final String zoneLabel;
  final String streamKindLabel;
  final String platform;
  final String architecture;
  final String buildCommit;
  Future<void> _pending = Future<void>.value();
  CloudSyncProtocolEvidenceException? _failure;

  @override
  void onEvent(CloudSyncEvent event) {
    CloudSyncProtocolEvidenceRecord record;
    try {
      record = CloudSyncProtocolEvidenceRecord.fromEvent(
        event,
        zoneLabel: zoneLabel,
        streamKindLabel: streamKindLabel,
        platform: platform,
        architecture: architecture,
        buildCommit: buildCommit,
      );
    } on CloudSyncProtocolEvidenceException catch (error) {
      _failure ??= error;
      return;
    } catch (_) {
      _failure ??= const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_event_invalid',
      );
      return;
    }

    _pending = _pending.then<void>((_) async {
      if (_failure != null) return;
      try {
        await writer.append(record);
      } on CloudSyncProtocolEvidenceException catch (error) {
        _failure ??= error;
      } catch (_) {
        _failure ??= const CloudSyncProtocolEvidenceException(
          'cloud_sync_protocol_evidence_write_failed',
        );
      }
    });
  }

  @override
  Future<void> flush() async {
    await _pending;
    try {
      await writer.flush();
    } on CloudSyncProtocolEvidenceException catch (error) {
      _failure ??= error;
    } catch (_) {
      _failure ??= const CloudSyncProtocolEvidenceException(
        'cloud_sync_protocol_evidence_write_failed',
      );
    }
    final failure = _failure;
    if (failure != null) throw failure;
  }
}

final class CloudSyncProtocolEvidenceException implements Exception {
  const CloudSyncProtocolEvidenceException(this._requestedCode);

  static const Set<String> _safeCodes = {
    'cloud_sync_protocol_evidence_unknown_failure',
    'cloud_sync_protocol_evidence_trusted_root_invalid',
    'cloud_sync_protocol_evidence_path_escape',
    'cloud_sync_protocol_evidence_directory_unsafe',
    'cloud_sync_protocol_evidence_directory_unavailable',
    'cloud_sync_protocol_evidence_owned_file_invalid',
    'cloud_sync_protocol_evidence_write_failed',
    'cloud_sync_protocol_evidence_retention_failed',
    'cloud_sync_protocol_evidence_file_corrupt',
    'cloud_sync_protocol_evidence_line_too_large',
    'cloud_sync_protocol_evidence_event_invalid',
    'cloud_sync_protocol_evidence_zone_invalid',
    'cloud_sync_protocol_evidence_stream_invalid',
    'cloud_sync_protocol_evidence_platform_invalid',
    'cloud_sync_protocol_evidence_architecture_invalid',
    'cloud_sync_protocol_evidence_build_commit_invalid',
    'cloud_sync_protocol_evidence_event_type_invalid',
    'cloud_sync_protocol_evidence_trigger_invalid',
    'cloud_sync_protocol_evidence_failure_invalid',
    'cloud_sync_protocol_evidence_skip_invalid',
    'cloud_sync_protocol_evidence_journal_block_invalid',
    'cloud_sync_protocol_evidence_count_invalid',
    'cloud_sync_protocol_evidence_estimated_bytes_invalid',
    'cloud_sync_protocol_evidence_attempt_invalid',
    'cloud_sync_protocol_evidence_elapsed_ms_invalid',
    'cloud_sync_protocol_evidence_timestamp_invalid',
  };

  final String _requestedCode;

  String get safeCode => _safeCodes.contains(_requestedCode)
      ? _requestedCode
      : 'cloud_sync_protocol_evidence_unknown_failure';

  @override
  String toString() => 'CloudSyncProtocolEvidenceException($safeCode)';
}
