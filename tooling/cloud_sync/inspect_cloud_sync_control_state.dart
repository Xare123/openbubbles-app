import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';

const _pageSize = 256;
const _failureCategories = <String>{
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
};
const _streamKinds = <String>{'messages', 'profiles'};
const _persistenceLanes = <String>{'legacy', 'shadow', 'semantic'};
const _replayOutcomes = <String>{
  'applied',
  'appliedWithConflict',
  'quarantined',
};

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('usage_error');
    exitCode = 64;
    return;
  }

  try {
    final report = await inspectCloudSyncControlState(
      Directory(arguments.single).absolute,
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } catch (_) {
    stderr.writeln('inspection_failed');
    exitCode = 70;
  }
}

Future<Map<String, Object?>> inspectCloudSyncControlState(
  Directory sourceDirectory,
) async {
  final sourceData = File(
    '${sourceDirectory.path}${Platform.pathSeparator}data.mdb',
  );
  if (!sourceData.existsSync()) {
    throw const FileSystemException('objectbox_data_missing');
  }

  final stagingDirectory = await Directory.systemTemp.createTemp(
    'openbubbles-cloud-sync-inspect-',
  );
  try {
    await _copyDirectoryContents(sourceDirectory, stagingDirectory);
    final store = await openStore(directory: stagingDirectory.path);
    try {
      return _inspectStore(store);
    } finally {
      store.close();
    }
  } finally {
    await _deleteValidatedStagingDirectory(stagingDirectory);
  }
}

Map<String, Object?> _inspectStore(Store store) {
  final now = DateTime.now().toUtc();
  final checkpoints = <Map<String, Object?>>[];
  _scanPaged(
    (store.box<CloudSyncCheckpointEntity>().query()
          ..order(CloudSyncCheckpointEntity_.id))
        .build(),
    (checkpoint) {
      checkpoints.add(<String, Object?>{
        'groupOrdinal': checkpoints.length + 1,
        'streamKind': _allowlistedOrInvalid(
          checkpoint.streamKind,
          _streamKinds,
        ),
        'schemaVersion': checkpoint.schemaVersion,
        'persistenceLane': checkpoint.persistenceLane == null
            ? null
            : _allowlistedOrInvalid(
                checkpoint.persistenceLane!,
                _persistenceLanes,
              ),
        'generation': checkpoint.generation,
        'fetchedSequence': checkpoint.fetchedSequence,
        'appliedSequence': checkpoint.appliedSequence,
        'hasFetchedToken': checkpoint.fetchedTokenCiphertext != null,
        'hasPendingToken': checkpoint.pendingFetchedTokenCiphertext != null,
        'hasPendingBatch': checkpoint.pendingBatchId != null,
        'lastErrorCategory': _failureCategory(checkpoint.lastErrorCategory),
        'backoffAttempt': checkpoint.backoffAttempt,
        'nextEligibleInSeconds': _secondsUntil(
          checkpoint.nextEligibleAtMs,
          now,
        ),
      });
    },
  );

  final groups = <String, _InboxGroupAccumulator>{};
  _scanPaged(
    (store.box<CloudInboxChangeEntity>().query()
          ..order(CloudInboxChangeEntity_.id))
        .build(),
    (row) {
      final group = groups.putIfAbsent(
        '${row.scopeKey}|${row.generation}',
        _InboxGroupAccumulator.new,
      );
      group.add(row, now: now);
    },
  );
  final inboxGroups = <Map<String, Object?>>[];
  for (final group in groups.values) {
    inboxGroups.add(group.toJson(groupOrdinal: inboxGroups.length + 1));
  }

  final replayOutcomes = <String, int>{};
  final replaySafeCodes = <String, int>{};
  _scanPaged(
    (store.box<CloudSemanticReplayEntity>().query()
          ..order(CloudSemanticReplayEntity_.id))
        .build(),
    (replay) {
      final outcome = _allowlistedOrInvalid(
        replay.terminalOutcome,
        _replayOutcomes,
      );
      replayOutcomes.update(outcome, (count) => count + 1, ifAbsent: () => 1);
      if (replay.terminalSafeCode case final safeCode?) {
        final normalized = cloudSyncV2SafeFailureCodeForCandidate(safeCode);
        replaySafeCodes.update(
          normalized,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    },
  );

  return <String, Object?>{
    'schema': 2,
    'canonicalCounts': <String, int>{
      'chats': store.box<Chat>().count(),
      'messages': store.box<Message>().count(),
      'attachments': store.box<Attachment>().count(),
    },
    'cloudMetadataCounts': <String, int>{
      'checkpoints': store.box<CloudSyncCheckpointEntity>().count(),
      'inbox': store.box<CloudInboxChangeEntity>().count(),
      'outbox': store.box<CloudOutboxOperationEntity>().count(),
      'snapshots': store.box<CloudSemanticSnapshotEntity>().count(),
      'recordMaps': store.box<CloudRecordMapEntity>().count(),
      'replays': store.box<CloudSemanticReplayEntity>().count(),
      'chatAliases': store.box<CloudSemanticChatAliasEntity>().count(),
    },
    'checkpoints': checkpoints,
    'inboxGroups': inboxGroups,
    'replayOutcomes': replayOutcomes,
    'replaySafeCodes': replaySafeCodes,
  };
}

void _scanPaged<T>(Query<T> query, void Function(T row) visit) {
  var offset = 0;
  try {
    while (true) {
      query
        ..offset = offset
        ..limit = _pageSize;
      final page = query.find();
      for (final row in page) {
        visit(row);
      }
      if (page.length < _pageSize) return;
      offset += page.length;
    }
  } finally {
    query.close();
  }
}

final class _InboxGroupAccumulator {
  int rowCount = 0;
  final statuses = <String, int>{};
  final failureCategories = <String, int>{};
  _BarrierMetadata? firstBarrier;

  void add(CloudInboxChangeEntity row, {required DateTime now}) {
    rowCount += 1;
    final status = _statusName(row.status);
    statuses.update(status, (count) => count + 1, ifAbsent: () => 1);
    if (row.failureCategory case final category?) {
      final normalized = _failureCategory(category)!;
      failureCategories.update(
        normalized,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    if (row.status == 1 || row.status == 3) return;
    final candidate = _BarrierMetadata.fromRow(row, now: now);
    if (firstBarrier == null || candidate.sequence < firstBarrier!.sequence) {
      firstBarrier = candidate;
    }
  }

  Map<String, Object?> toJson({required int groupOrdinal}) => <String, Object?>{
    'groupOrdinal': groupOrdinal,
    'rows': rowCount,
    'statuses': statuses,
    'failureCategories': failureCategories,
    'firstBarrier': firstBarrier?.toJson(),
  };
}

final class _BarrierMetadata {
  const _BarrierMetadata({
    required this.sequence,
    required this.status,
    required this.failureCategory,
    required this.preflightCategory,
    required this.preflightCode,
    required this.retryCount,
    required this.ageSeconds,
    required this.nextEligibleInSeconds,
    required this.isTombstone,
  });

  factory _BarrierMetadata.fromRow(
    CloudInboxChangeEntity row, {
    required DateTime now,
  }) {
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      row.createdAtMs,
      isUtc: true,
    );
    return _BarrierMetadata(
      sequence: row.fetchSequence,
      status: _statusName(row.status),
      failureCategory: _failureCategory(row.failureCategory),
      preflightCategory: _failureCategory(row.preflightCategory),
      preflightCode: _preflightSafeCode(row.preflightCode),
      retryCount: row.retryCount,
      ageSeconds: now.isBefore(createdAt)
          ? 0
          : now.difference(createdAt).inSeconds,
      nextEligibleInSeconds: _secondsUntil(row.nextEligibleAtMs, now),
      isTombstone: row.isTombstone,
    );
  }

  final int sequence;
  final String status;
  final String? failureCategory;
  final String? preflightCategory;
  final String? preflightCode;
  final int retryCount;
  final int ageSeconds;
  final int? nextEligibleInSeconds;
  final bool isTombstone;

  Map<String, Object?> toJson() => <String, Object?>{
    'sequence': sequence,
    'status': status,
    'failureCategory': failureCategory,
    'preflightCategory': preflightCategory,
    'preflightCode': preflightCode,
    'retryCount': retryCount,
    'ageSeconds': ageSeconds,
    'nextEligibleInSeconds': nextEligibleInSeconds,
    'isTombstone': isTombstone,
  };
}

Future<void> _copyDirectoryContents(
  Directory source,
  Directory destination,
) async {
  final sourcePath = source.absolute.path;
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final absolutePath = entity.absolute.path;
    if (!absolutePath.startsWith('$sourcePath${Platform.pathSeparator}')) {
      throw const FileSystemException('inspection_source_escape');
    }
    final relativePath = absolutePath.substring(sourcePath.length + 1);
    final targetPath =
        '${destination.path}${Platform.pathSeparator}$relativePath';
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    } else {
      throw const FileSystemException('inspection_link_rejected');
    }
  }
}

Future<void> _deleteValidatedStagingDirectory(Directory directory) async {
  final resolved = directory.absolute.path;
  final tempRoot = Directory.systemTemp.absolute.path;
  final leaf = directory.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .lastOrNull;
  if (!resolved.startsWith('$tempRoot${Platform.pathSeparator}') ||
      leaf == null ||
      !leaf.startsWith('openbubbles-cloud-sync-inspect-')) {
    throw const FileSystemException('inspection_cleanup_boundary_invalid');
  }
  if (directory.existsSync()) await directory.delete(recursive: true);
}

String? _failureCategory(String? value) {
  if (value == null) return null;
  return _allowlistedOrInvalid(value, _failureCategories, fallback: 'unknown');
}

String? _preflightSafeCode(String? value) => switch (value) {
  null => null,
  'unsupportedRecordType' => 'preflight_unsupported_record_type',
  'malformedMetadata' => 'preflight_malformed_metadata',
  'oversizedRecord' => 'preflight_oversized_record',
  'invalidChangeShape' => 'preflight_invalid_change_shape',
  'unknown' => 'preflight_unknown',
  _ => cloudSyncV2SafeFailureCodeForCandidate(value),
};

String _allowlistedOrInvalid(
  String value,
  Set<String> allowlist, {
  String fallback = 'invalid',
}) => allowlist.contains(value) ? value : fallback;

int? _secondsUntil(int millisecondsSinceEpoch, DateTime now) {
  if (millisecondsSinceEpoch == 0) return null;
  final target = DateTime.fromMillisecondsSinceEpoch(
    millisecondsSinceEpoch,
    isUtc: true,
  );
  return target.isBefore(now) ? 0 : target.difference(now).inSeconds;
}

String _statusName(int status) => switch (status) {
  0 => 'pending',
  1 => 'applied',
  2 => 'quarantined',
  3 => 'retainedUnprojected',
  _ => 'invalid',
};
