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
const _semanticEntityKinds = <String>{
  'chat',
  'message',
  'attachment',
  'reaction',
};
const _semanticServices = <String>{'iMessage', 'sms'};
const _semanticAliasKinds = <String>{
  'groupId',
  'originalGroupId',
  'serviceIdentifier',
  'legacyGroupIdentifier',
};
const _cloudZones = <String>{
  'chatManateeZone',
  'messageManateeZone',
  'attachmentManateeZone',
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
  final legacyChatShapeCounts = _inspectLegacyChatShapes(store);
  final semanticOwnershipCounts = _inspectSemanticOwnership(store);
  final checkpoints = <Map<String, Object?>>[];
  _scanPaged(
    (store.box<CloudSyncCheckpointEntity>().query()
          ..order(CloudSyncCheckpointEntity_.id))
        .build(),
    (checkpoint) {
      checkpoints.add(<String, Object?>{
        'groupOrdinal': checkpoints.length + 1,
        'zone': _allowlistedOrInvalid(checkpoint.zone, _cloudZones),
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
    'schema': 4,
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
    'legacyChatShapeCounts': legacyChatShapeCounts,
    'semanticOwnershipCounts': semanticOwnershipCounts,
    'checkpoints': checkpoints,
    'inboxGroups': inboxGroups,
    'replayOutcomes': replayOutcomes,
    'replaySafeCodes': replaySafeCodes,
  };
}

Map<String, Object?> _inspectSemanticOwnership(Store store) {
  final snapshotsByEntityKind = <String, int>{};
  _scanPaged(
    (store.box<CloudSemanticSnapshotEntity>().query()
          ..order(CloudSemanticSnapshotEntity_.id))
        .build(),
    (snapshot) {
      final kind = _allowlistedOrInvalid(
        snapshot.entityKind,
        _semanticEntityKinds,
      );
      snapshotsByEntityKind.update(
        kind,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    },
  );

  final aliasesByService = <String, int>{};
  final aliasesByKind = <String, int>{};
  _scanPaged(
    (store.box<CloudSemanticChatAliasEntity>().query()
          ..order(CloudSemanticChatAliasEntity_.id))
        .build(),
    (alias) {
      final service = _allowlistedOrInvalid(alias.service, _semanticServices);
      aliasesByService.update(service, (count) => count + 1, ifAbsent: () => 1);
      final kind = _allowlistedOrInvalid(alias.aliasKind, _semanticAliasKinds);
      aliasesByKind.update(kind, (count) => count + 1, ifAbsent: () => 1);
    },
  );

  return <String, Object?>{
    'snapshotsByEntityKind': snapshotsByEntityKind,
    'chatAliasesByService': aliasesByService,
    'chatAliasesByKind': aliasesByKind,
  };
}

Map<String, int> _inspectLegacyChatShapes(Store store) {
  final guidCounts = <String, int>{};
  final messageGuids = <String>{};
  final attachmentGuids = <String>{};
  var messagesLinkedToSmsChats = 0;
  var messagesLinkedToIMessageChats = 0;
  var messagesWithoutChats = 0;
  var messagesWithText = 0;
  var messagesWithSubject = 0;
  var messagesWithAttributedBody = 0;
  var messagesWithAttachments = 0;
  var associatedMessages = 0;
  var eventMessages = 0;
  var messagesWithoutRenderableContent = 0;
  _scanPaged((store.box<Message>().query()..order(Message_.id)).build(), (
    message,
  ) {
    final guid = message.guid;
    if (guid != null && guid.isNotEmpty) messageGuids.add(guid);
    final chat = message.chat.target;
    if (chat == null) {
      messagesWithoutChats += 1;
    } else if (chat.isRpSms) {
      messagesLinkedToSmsChats += 1;
    } else {
      messagesLinkedToIMessageChats += 1;
    }
    final hasText = message.text?.trim().isNotEmpty ?? false;
    final hasSubject = message.subject?.trim().isNotEmpty ?? false;
    final hasAttributedBody = message.attributedBody.isNotEmpty;
    final hasAttachments =
        message.hasAttachments || message.dbAttachments.isNotEmpty;
    final isAssociated = message.associatedMessageGuid?.isNotEmpty ?? false;
    final isEvent = (message.itemType ?? 0) != 0;
    if (hasText) messagesWithText += 1;
    if (hasSubject) messagesWithSubject += 1;
    if (hasAttributedBody) messagesWithAttributedBody += 1;
    if (hasAttachments) messagesWithAttachments += 1;
    if (isAssociated) associatedMessages += 1;
    if (isEvent) eventMessages += 1;
    if (!hasText &&
        !hasSubject &&
        !hasAttributedBody &&
        !hasAttachments &&
        !isAssociated &&
        !isEvent) {
      messagesWithoutRenderableContent += 1;
    }
  });
  _scanPaged((store.box<Attachment>().query()..order(Attachment_.id)).build(), (
    attachment,
  ) {
    final guid = attachment.guid;
    if (guid != null && guid.isNotEmpty) attachmentGuids.add(guid);
  });

  var blankIdentifiers = 0;
  var compositeRows = 0;
  var compositeDirectRows = 0;
  var compositeGroupRows = 0;
  var compositeIdentifierMismatches = 0;
  var compositeStyleMismatches = 0;
  var compositeServiceMismatches = 0;
  var nullStyleRows = 0;
  var directStyleRows = 0;
  var groupStyleRows = 0;
  var otherStyleRows = 0;
  var crossKindGuidCollisions = 0;
  var smsServiceRows = 0;
  var iMessageServiceRows = 0;
  var ckRecordIdRows = 0;
  var cloudGuidRows = 0;
  var cloudDataRows = 0;
  var guidReferenceRows = 0;
  var compositeLegacyCloudEvidenceRows = 0;
  _scanPaged((store.box<Chat>().query()..order(Chat_.id)).build(), (chat) {
    if (chat.isRpSms) {
      smsServiceRows += 1;
    } else {
      iMessageServiceRows += 1;
    }
    guidCounts.update(chat.guid, (count) => count + 1, ifAbsent: () => 1);
    final identifier = chat.chatIdentifier;
    if (identifier == null || identifier.isEmpty) blankIdentifiers += 1;
    final hasCkRecordId = chat.ckRecordId?.isNotEmpty ?? false;
    final hasCloudGuid = chat.cloudGuid?.isNotEmpty ?? false;
    final hasCloudData = chat.cloudData?.isNotEmpty ?? false;
    final hasGuidReferences = chat.guidRefs.isNotEmpty;
    if (hasCkRecordId) ckRecordIdRows += 1;
    if (hasCloudGuid) cloudGuidRows += 1;
    if (hasCloudData) cloudDataRows += 1;
    if (hasGuidReferences) guidReferenceRows += 1;
    if (messageGuids.contains(chat.guid) ||
        attachmentGuids.contains(chat.guid)) {
      crossKindGuidCollisions += 1;
    }

    final direct = chat.guid.startsWith('iMessage;-;');
    final group = chat.guid.startsWith('iMessage;+;');
    if (!direct && !group) return;
    compositeRows += 1;
    if (direct) {
      compositeDirectRows += 1;
    } else {
      compositeGroupRows += 1;
    }
    final expectedIdentifier = chat.guid.substring('iMessage;-;'.length);
    if (identifier != expectedIdentifier) {
      compositeIdentifierMismatches += 1;
    }
    if (identifier == expectedIdentifier &&
        !chat.isRpSms &&
        hasCkRecordId &&
        hasCloudGuid &&
        chat.guidRefs.contains(chat.guid) &&
        chat.guidRefs.contains(identifier)) {
      compositeLegacyCloudEvidenceRows += 1;
    }
    final expectedStyle = direct ? 45 : 43;
    if (chat.style != expectedStyle) compositeStyleMismatches += 1;
    switch (chat.style) {
      case null:
        nullStyleRows += 1;
      case 45:
        directStyleRows += 1;
      case 43:
        groupStyleRows += 1;
      default:
        otherStyleRows += 1;
    }
    if (chat.isRpSms) compositeServiceMismatches += 1;
  });

  var duplicateGuidGroups = 0;
  var duplicateGuidRows = 0;
  for (final count in guidCounts.values) {
    if (count <= 1) continue;
    duplicateGuidGroups += 1;
    duplicateGuidRows += count;
  }
  return <String, int>{
    'blankIdentifiers': blankIdentifiers,
    'compositeRows': compositeRows,
    'compositeDirectRows': compositeDirectRows,
    'compositeGroupRows': compositeGroupRows,
    'compositeIdentifierMismatches': compositeIdentifierMismatches,
    'compositeStyleMismatches': compositeStyleMismatches,
    'compositeServiceMismatches': compositeServiceMismatches,
    'nullStyleRows': nullStyleRows,
    'directStyleRows': directStyleRows,
    'groupStyleRows': groupStyleRows,
    'otherStyleRows': otherStyleRows,
    'duplicateGuidGroups': duplicateGuidGroups,
    'duplicateGuidRows': duplicateGuidRows,
    'crossKindGuidCollisions': crossKindGuidCollisions,
    'messagesLinkedToSmsChats': messagesLinkedToSmsChats,
    'messagesLinkedToIMessageChats': messagesLinkedToIMessageChats,
    'messagesWithoutChats': messagesWithoutChats,
    'messagesWithText': messagesWithText,
    'messagesWithSubject': messagesWithSubject,
    'messagesWithAttributedBody': messagesWithAttributedBody,
    'messagesWithAttachments': messagesWithAttachments,
    'associatedMessages': associatedMessages,
    'eventMessages': eventMessages,
    'messagesWithoutRenderableContent': messagesWithoutRenderableContent,
    'smsServiceRows': smsServiceRows,
    'iMessageServiceRows': iMessageServiceRows,
    'ckRecordIdRows': ckRecordIdRows,
    'cloudGuidRows': cloudGuidRows,
    'cloudDataRows': cloudDataRows,
    'guidReferenceRows': guidReferenceRows,
    'compositeLegacyCloudEvidenceRows': compositeLegacyCloudEvidenceRows,
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
