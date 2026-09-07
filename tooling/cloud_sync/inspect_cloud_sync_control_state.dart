import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_source_resolver.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_chat_identity_read_set.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/objectbox_cloud_sync_preflight.dart';

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
  'unsupportedService',
  'outOfScopeService',
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
  final presentationFidelityCounts = _inspectPresentationFidelity(store);
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
    'schema': 11,
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
    'presentationFidelityCounts': presentationFidelityCounts,
    'semanticOwnershipCounts': semanticOwnershipCounts,
    'chatIdentityObservationInputs': _inspectChatIdentityInputs(store),
    'outboundControl': _inspectOutboundControl(store),
    'checkpoints': checkpoints,
    'inboxGroups': inboxGroups,
    'replayOutcomes': replayOutcomes,
    'replaySafeCodes': replaySafeCodes,
  };
}

Map<String, Object?> _inspectOutboundControl(Store store) {
  final rows = store.box<CloudOutboxOperationEntity>().getAll()
    ..sort((a, b) => a.id.compareTo(b.id));
  final states = <String, int>{};
  var present = 0;
  var readable = 0;
  var cloudSynced = 0;
  var linkedToSyncedChat = 0;
  for (final intent in store.box<CloudSyncLocalSendIntentEntity>().getAll()) {
    final name = switch (intent.state) {
      0 => 'awaitingIds', 1 => 'ready', 2 => 'adopted', 3 => 'authDeferred',
      _ => 'invalid',
    };
    states.update(name, (count) => count + 1, ifAbsent: () => 1);
    final message = store.box<Message>().get(intent.localMessageId);
    if (message != null) {
      present++;
      final body = message.attributedBody;
      if (message.text?.trim().isNotEmpty == true && body.length == 1 &&
          body.single.string == message.text) {
        readable++;
      }
      if (message.ckSyncState == true && message.ckRecordId?.isNotEmpty == true) cloudSynced++;
      final chat = message.chat.target;
      if (chat?.ckSyncState == true && chat?.ckRecordId?.isNotEmpty == true) linkedToSyncedChat++;
    }
  }
  return {
    'journalStates': states,
    // These flags belong to the legacy uploader. V2 owns separate semantic
    // snapshots and record maps; false here is NOT evidence of a V2 failure.
    'journalMessageRows': {'present': present, 'readable': readable,
      'legacyMessageCkSynced': cloudSynced, 'legacyChatCkSynced': linkedToSyncedChat},
    // An unchanged digest proves that the complete durable audit did not
    // change across restart. It contains no raw IDs, paths, keys or content.
    'settledAuditFingerprint': ObjectBoxCloudSyncPreflightReader.settledAuditFingerprint(rows),
    'operations': [for (final row in rows) {
      'ordinal': row.id,
      'zone': _allowlistedOrInvalid(row.zone, _cloudZones),
      'state': switch (row.state) {
        0 => 'pending', 1 => 'inFlight', 2 => 'confirmed', 3 => 'paused',
        4 => 'quarantined', 5 => 'unknownOutcome', _ => 'invalid',
      },
      'action': row.action == 0 ? 'save' : row.action == 1 ? 'delete' : 'invalid',
      'attemptCount': row.attemptCount,
      'hasServerRecord': row.serverRecordIdHash != null,
      'hasProtectedPayload': row.encryptedPayloadRef != null,
      'hasRetainedReceipt': row.protectedLeaseReference != null,
      'hasActiveLease': row.leaseIdHash != null,
      'confirmedAtMs': row.confirmedAtMs,
    }],
  };
}

List<Map<String, Object?>> _inspectChatIdentityInputs(Store store) {
  final query = store.box<CloudSyncCheckpointEntity>().query(
    CloudSyncCheckpointEntity_.zone.equals('chatManateeZone').and(
      CloudSyncCheckpointEntity_.persistenceLane.equals('semantic'),
    ),
  ).build();
  try {
    return query.find().map((checkpoint) {
      try {
        final scope = CloudSyncScope(
          accountFingerprint: checkpoint.accountFingerprint,
          container: checkpoint.container, database: checkpoint.database,
          zone: checkpoint.zone, schemaVersion: checkpoint.schemaVersion,
          persistenceLane: CloudSyncPersistenceLane.semantic,
        );
        final inputs = CloudSyncChatIdentityReadSet.capture(store, scope);
        inputs.requireUnchanged(store);
        return <String, Object?>{
          'status': 'readyForNativeObservation',
          'generation': inputs.generation,
          'fetchedSequence': inputs.fetchedSequence,
          'appliedSequence': inputs.appliedSequence,
          'retainedSaves': inputs.retainedSaves.length,
          'retainedTombstones': inputs.retainedTombstones,
          'writeAuthorized': false,
        };
      } catch (error) {
        return <String, Object?>{
          'status': 'blocked',
          'safeCode': cloudSyncV2SafeFailureCode(error),
          'writeAuthorized': false,
        };
      }
    }).toList(growable: false);
  } finally {
    query.close();
  }
}

Map<String, int> _inspectPresentationFidelity(Store store) {
  var messagesWithRecognizedUrlInText = 0;
  var messagesWithMultipleRecognizedUrlsInText = 0;
  var messagesWithUrlSchemeButNoRecognizedUrlInText = 0;
  var messagesWithRecognizedUrlInAttributedBody = 0;
  var messagesWithUrlOnlyInAttributedBody = 0;
  var messagesWithBalloonBundleId = 0;
  var messagesWithUrlBalloonBundleId = 0;
  var messagesWithDecodedPayload = 0;
  var messagesWithApplePayloadMarker = 0;
  var messagesWithAttachmentFlag = 0;
  var messagesWithAttachmentRelation = 0;
  var messagesWithAttributedAttachmentRun = 0;
  var messagesWithAttachmentFlagWithoutRelation = 0;
  var messagesWithAttachmentRelationWithoutFlag = 0;
  var messagesWithAttributedAttachmentRunWithoutRelation = 0;
  var messagesWithMissingReferencedAttachmentRow = 0;
  var messagesWithAttachmentReferenceMissingRelation = 0;
  var messagesWithAttachmentReferenceOwnedByAnotherMessage = 0;
  var messagesAtRiskOfEmptyAttachmentPlaceholder = 0;
  var missingReferencedAttachmentRows = 0;
  var missingAttachmentRelations = 0;

  final attachmentOwnerByGuid = <String, int>{};
  _scanPaged((store.box<Attachment>().query()..order(Attachment_.id)).build(), (
    attachment,
  ) {
    final guid = attachment.guid;
    if (guid != null && guid.isNotEmpty) {
      attachmentOwnerByGuid[guid] = attachment.message.targetId;
    }
  });

  _scanPaged((store.box<Message>().query()..order(Message_.id)).build(), (
    message,
  ) {
    final text = message.text ?? '';
    final recognizedTextUrls = urlRegex.allMatches(text).length;
    final hasRecognizedTextUrl = recognizedTextUrls > 0;
    final hasUrlScheme = _urlSchemeMarker.hasMatch(text);
    final hasRecognizedAttributedUrl = message.attributedBody.any(
      (body) => urlRegex.hasMatch(body.string),
    );
    final relatedAttachmentGuids = message.dbAttachments
        .map((attachment) => attachment.guid)
        .whereType<String>()
        .toSet();
    final attributedAttachmentGuids = message.attributedBody
        .expand((body) => body.runs)
        .map((run) => run.attributes?.attachmentGuid)
        .whereType<String>()
        .where((guid) => guid.isNotEmpty)
        .toSet();
    final hasAttachmentRelation = relatedAttachmentGuids.isNotEmpty;
    final hasAttributedAttachmentRun = attributedAttachmentGuids.isNotEmpty;
    final missingRows = attributedAttachmentGuids
        .where((guid) => !attachmentOwnerByGuid.containsKey(guid))
        .length;
    final missingRelations = attributedAttachmentGuids
        .where(
          (guid) =>
              attachmentOwnerByGuid.containsKey(guid) &&
              !relatedAttachmentGuids.contains(guid),
        )
        .length;
    final anotherOwner = attributedAttachmentGuids.any((guid) {
      final ownerId = attachmentOwnerByGuid[guid];
      return ownerId != null && ownerId != 0 && ownerId != message.id;
    });

    if (hasRecognizedTextUrl) messagesWithRecognizedUrlInText += 1;
    if (recognizedTextUrls > 1) messagesWithMultipleRecognizedUrlsInText += 1;
    if (hasUrlScheme && !hasRecognizedTextUrl) {
      messagesWithUrlSchemeButNoRecognizedUrlInText += 1;
    }
    if (hasRecognizedAttributedUrl) {
      messagesWithRecognizedUrlInAttributedBody += 1;
    }
    if (!hasRecognizedTextUrl && hasRecognizedAttributedUrl) {
      messagesWithUrlOnlyInAttributedBody += 1;
    }
    if (message.balloonBundleId?.isNotEmpty ?? false) {
      messagesWithBalloonBundleId += 1;
    }
    if (message.balloonBundleId == 'com.apple.messages.URLBalloonProvider') {
      messagesWithUrlBalloonBundleId += 1;
    }
    if (message.payloadData != null) messagesWithDecodedPayload += 1;
    if (message.hasApplePayloadData) messagesWithApplePayloadMarker += 1;
    if (message.hasAttachments) messagesWithAttachmentFlag += 1;
    if (hasAttachmentRelation) messagesWithAttachmentRelation += 1;
    if (hasAttributedAttachmentRun) messagesWithAttributedAttachmentRun += 1;
    if (message.hasAttachments && !hasAttachmentRelation) {
      messagesWithAttachmentFlagWithoutRelation += 1;
    }
    if (!message.hasAttachments && hasAttachmentRelation) {
      messagesWithAttachmentRelationWithoutFlag += 1;
    }
    if (hasAttributedAttachmentRun && !hasAttachmentRelation) {
      messagesWithAttributedAttachmentRunWithoutRelation += 1;
    }
    if (missingRows > 0) {
      messagesWithMissingReferencedAttachmentRow += 1;
      missingReferencedAttachmentRows += missingRows;
      final hasVisibleText = text
          .replaceAll(_nonVisibleAttachmentText, '')
          .isNotEmpty;
      final hasVisibleSubject =
          message.subject
              ?.replaceAll(_nonVisibleAttachmentText, '')
              .isNotEmpty ??
          false;
      if (!hasVisibleText && !hasVisibleSubject) {
        messagesAtRiskOfEmptyAttachmentPlaceholder += 1;
      }
    }
    if (missingRelations > 0) {
      messagesWithAttachmentReferenceMissingRelation += 1;
      missingAttachmentRelations += missingRelations;
    }
    if (anotherOwner) {
      messagesWithAttachmentReferenceOwnedByAnotherMessage += 1;
    }
  });

  var attachmentsWithoutOwner = 0;
  var attachmentsWithTransferName = 0;
  var attachmentsWithMimeType = 0;
  var attachmentsWithPositiveByteCount = 0;
  var v2AttachmentRows = 0;
  var v2LegacyProvenanceRows = 0;
  var v2CurrentProvenanceRows = 0;
  var v2MaterializableRows = 0;
  var v2MetadataOnlyRows = 0;
  var v2UnknownCapabilityRows = 0;
  var legacyCloudAttachmentRows = 0;
  var idsAttachmentRows = 0;
  final currentV2Attachments = <Attachment>[];
  _scanPaged((store.box<Attachment>().query()..order(Attachment_.id)).build(), (
    attachment,
  ) {
    if (attachment.message.targetId == 0) attachmentsWithoutOwner += 1;
    if (attachment.transferName?.isNotEmpty ?? false) {
      attachmentsWithTransferName += 1;
    }
    if (attachment.mimeType?.isNotEmpty ?? false) attachmentsWithMimeType += 1;
    if ((attachment.totalBytes ?? 0) > 0) attachmentsWithPositiveByteCount += 1;

    final metadata = attachment.metadata;
    if (hasCloudAttachmentV2Provenance(metadata)) {
      v2AttachmentRows += 1;
      switch (metadata?[cloudAttachmentV2MetadataKey]) {
        case cloudAttachmentV2LegacyMetadataVersion:
          v2LegacyProvenanceRows += 1;
        case cloudAttachmentV2MetadataVersion:
          v2CurrentProvenanceRows += 1;
          currentV2Attachments.add(attachment);
      }
      switch (cloudAttachmentBodyCapabilityFor(metadata)) {
        case CloudAttachmentBodyCapability.materializable:
          v2MaterializableRows += 1;
        case CloudAttachmentBodyCapability
            .metadataOnlyUnsupportedMediaCredentials:
          v2MetadataOnlyRows += 1;
        case null:
          v2UnknownCapabilityRows += 1;
      }
    } else if (metadata?.containsKey('cloud') ?? false) {
      legacyCloudAttachmentRows += 1;
    } else if (metadata?.containsKey('rustpush') ?? false) {
      idsAttachmentRows += 1;
    }
  });

  final attachmentCheckpoints = store
      .box<CloudSyncCheckpointEntity>()
      .getAll()
      .where(
        (checkpoint) =>
            checkpoint.container == 'com.apple.messages.cloud' &&
            checkpoint.database == 'private' &&
            checkpoint.zone == 'attachmentManateeZone' &&
            checkpoint.streamKind == CloudSyncStreamKind.messages.name &&
            checkpoint.schemaVersion == cloudSyncSchemaVersion &&
            checkpoint.persistenceLane ==
                CloudSyncPersistenceLane.semanticV2.name &&
            checkpoint.generation > 0,
      )
      .toList(growable: false);
  var v2ResolvableSourceRows = 0;
  final v2SourceResolutionFailures =
      <CloudAttachmentSourceResolutionCode, int>{};
  final v2SourceResolutionStages =
      <CloudAttachmentSourceResolutionStage, int>{};
  if (attachmentCheckpoints.length == 1) {
    final checkpoint = attachmentCheckpoints.single;
    final scope = CloudSyncScope(
      accountFingerprint: checkpoint.accountFingerprint,
      container: checkpoint.container,
      database: checkpoint.database,
      zone: checkpoint.zone,
      streamKind: CloudSyncStreamKind.messages,
      schemaVersion: checkpoint.schemaVersion,
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
    );
    final resolver = CloudAttachmentSourceResolver(store: store);
    for (final attachment in currentV2Attachments) {
      final guid = attachment.guid;
      if (guid == null || guid.isEmpty) continue;
      try {
        resolver.resolve(
          scope: scope,
          generation: checkpoint.generation,
          canonicalGuid: guid,
        );
        v2ResolvableSourceRows += 1;
      } on CloudAttachmentSourceResolutionFailure catch (failure) {
        v2SourceResolutionFailures.update(
          failure.code,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        final stage = failure.stage;
        if (stage != null) {
          v2SourceResolutionStages.update(
            stage,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
      }
    }
  }

  final materializationStages = <CloudAttachmentMaterializationStage, int>{};
  var invalidMaterializationStages = 0;
  _scanPaged(
    (store.box<CloudAttachmentMaterializationEntity>().query()
          ..order(CloudAttachmentMaterializationEntity_.id))
        .build(),
    (entry) {
      if (entry.stage < 0 ||
          entry.stage >= CloudAttachmentMaterializationStage.values.length) {
        invalidMaterializationStages += 1;
        return;
      }
      final stage = CloudAttachmentMaterializationStage.values[entry.stage];
      materializationStages.update(
        stage,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    },
  );

  return <String, int>{
    'messagesWithRecognizedUrlInText': messagesWithRecognizedUrlInText,
    'messagesWithMultipleRecognizedUrlsInText':
        messagesWithMultipleRecognizedUrlsInText,
    'messagesWithUrlSchemeButNoRecognizedUrlInText':
        messagesWithUrlSchemeButNoRecognizedUrlInText,
    'messagesWithRecognizedUrlInAttributedBody':
        messagesWithRecognizedUrlInAttributedBody,
    'messagesWithUrlOnlyInAttributedBody': messagesWithUrlOnlyInAttributedBody,
    'messagesWithBalloonBundleId': messagesWithBalloonBundleId,
    'messagesWithUrlBalloonBundleId': messagesWithUrlBalloonBundleId,
    'messagesWithDecodedPayload': messagesWithDecodedPayload,
    'messagesWithApplePayloadMarker': messagesWithApplePayloadMarker,
    'messagesWithAttachmentFlag': messagesWithAttachmentFlag,
    'messagesWithAttachmentRelation': messagesWithAttachmentRelation,
    'messagesWithAttributedAttachmentRun': messagesWithAttributedAttachmentRun,
    'messagesWithAttachmentFlagWithoutRelation':
        messagesWithAttachmentFlagWithoutRelation,
    'messagesWithAttachmentRelationWithoutFlag':
        messagesWithAttachmentRelationWithoutFlag,
    'messagesWithAttributedAttachmentRunWithoutRelation':
        messagesWithAttributedAttachmentRunWithoutRelation,
    'messagesWithMissingReferencedAttachmentRow':
        messagesWithMissingReferencedAttachmentRow,
    'messagesWithAttachmentReferenceMissingRelation':
        messagesWithAttachmentReferenceMissingRelation,
    'messagesWithAttachmentReferenceOwnedByAnotherMessage':
        messagesWithAttachmentReferenceOwnedByAnotherMessage,
    'messagesAtRiskOfEmptyAttachmentPlaceholder':
        messagesAtRiskOfEmptyAttachmentPlaceholder,
    'missingReferencedAttachmentRows': missingReferencedAttachmentRows,
    'missingAttachmentRelations': missingAttachmentRelations,
    'attachmentsWithoutOwner': attachmentsWithoutOwner,
    'attachmentsWithTransferName': attachmentsWithTransferName,
    'attachmentsWithMimeType': attachmentsWithMimeType,
    'attachmentsWithPositiveByteCount': attachmentsWithPositiveByteCount,
    'v2AttachmentRows': v2AttachmentRows,
    'v2LegacyProvenanceRows': v2LegacyProvenanceRows,
    'v2CurrentProvenanceRows': v2CurrentProvenanceRows,
    'v2MaterializableRows': v2MaterializableRows,
    'v2MetadataOnlyRows': v2MetadataOnlyRows,
    'v2UnknownCapabilityRows': v2UnknownCapabilityRows,
    'v2AttachmentSourceCheckpointRows': attachmentCheckpoints.length,
    'v2ResolvableSourceRows': v2ResolvableSourceRows,
    for (final entry in v2SourceResolutionFailures.entries)
      'v2SourceResolutionFailure_${entry.key.name}': entry.value,
    for (final entry in v2SourceResolutionStages.entries)
      'v2SourceResolutionStage_${entry.key.name}': entry.value,
    'legacyCloudAttachmentRows': legacyCloudAttachmentRows,
    'idsAttachmentRows': idsAttachmentRows,
    'materializationMetadataReadyRows':
        materializationStages[CloudAttachmentMaterializationStage
            .metadataReady] ??
        0,
    'materializationTempStreamingRows':
        materializationStages[CloudAttachmentMaterializationStage
            .tempStreaming] ??
        0,
    'materializationContentVerifiedRows':
        materializationStages[CloudAttachmentMaterializationStage
            .contentVerified] ??
        0,
    'materializationFilePlacedRows':
        materializationStages[CloudAttachmentMaterializationStage.filePlaced] ??
        0,
    'materializationReferencedRows':
        materializationStages[CloudAttachmentMaterializationStage.referenced] ??
        0,
    'invalidMaterializationStageRows': invalidMaterializationStages,
  };
}

final RegExp _urlSchemeMarker = RegExp(
  r'(?:(?:https?|ftp)://|www\.)',
  caseSensitive: false,
);

final RegExp _nonVisibleAttachmentText = RegExp(r'[\s\uFFFC]');

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
  final latestVisibleMessageDateByChatId = <int, DateTime>{};
  var messagesLinkedToSmsChats = 0;
  var messagesLinkedToIMessageChats = 0;
  var messagesWithoutChats = 0;
  var messagesWithText = 0;
  var messagesWithSubject = 0;
  var messagesWithAttributedBody = 0;
  var messagesWithAttributedText = 0;
  var messagesWithAttachments = 0;
  var associatedMessages = 0;
  var associatedMessagesWithMissingOrAmbiguousParent = 0;
  var associatedMessagesWithMismatchedChat = 0;
  var associatedMessagesWithMissingParentFlag = 0;
  var messagesWithEditHistory = 0;
  var editHistoryEntries = 0;
  var editHistoryEntriesWithText = 0;
  var editHistoryEntriesWithInvalidTimestamp = 0;
  var editHistoryEntriesBeforeMessageCreation = 0;
  var editHistoryEntriesWithInvalidUnicode = 0;
  var messagesWithRetractionMetadata = 0;
  var messagesWithUnrenderedRetractions = 0;
  var messagesWithRetractionPartBuildFailure = 0;
  var contentlessMessagesWithRetractionPlaceholder = 0;
  var visibleMessagesWithoutContentOrRetraction = 0;
  var eventMessages = 0;
  var messagesWithoutRenderableContent = 0;
  var visibleMessagesWithoutRenderableContent = 0;
  var deletedMessagesWithoutRenderableContent = 0;
  var unrenderableMessagesWithPayloadData = 0;
  var unrenderableMessagesWithBalloonBundleId = 0;
  var unrenderableMessagesWithCloudRecordId = 0;
  var unrenderableMessagesWithoutChat = 0;
  var projectedBodiesUsingText = 0;
  var projectedBodiesUsingAttributedText = 0;
  var projectedBodiesUsingSubject = 0;
  var projectedBodiesWithUnicodeReplacementCharacter = 0;
  var projectedBodiesWithUnexpectedControlCharacter = 0;
  var projectedBodiesWithUnpairedUtf16Surrogate = 0;
  var projectedBodiesWithLikelyMojibake = 0;
  var projectedBodiesWithHtmlDocumentText = 0;
  var projectedBodiesWithoutVisibleGlyphCandidate = 0;
  var messagesWithoutTextWithAttachments = 0;
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
    final chatId = message.chat.targetId;
    final createdAt = message.dateCreated;
    var hasEditHistory = false;
    for (final summary in message.messageSummaryInfo) {
      for (final edits in summary.editedContent.values) {
        for (final edit in edits) {
          hasEditHistory = true;
          editHistoryEntries += 1;
          final date = edit.date;
          if (date == null ||
              !date.isFinite ||
              date < 978307200000 ||
              date > 253402300799999) {
            editHistoryEntriesWithInvalidTimestamp += 1;
          } else if (createdAt != null &&
              date < createdAt.millisecondsSinceEpoch) {
            editHistoryEntriesBeforeMessageCreation += 1;
          }
          final text = edit.text?.values.map((body) => body.string).join(' ');
          if (_normalizedProjectionCandidate(text) != null) {
            editHistoryEntriesWithText += 1;
          }
          if (text != null &&
              (_hasUnpairedUtf16Surrogate(text) ||
                  _hasUnexpectedControlCharacter(text) ||
                  text.contains('\u{fffd}'))) {
            editHistoryEntriesWithInvalidUnicode += 1;
          }
        }
      }
    }
    if (hasEditHistory) messagesWithEditHistory += 1;
    final retractedParts = message.messageSummaryInfo
        .expand((summary) => summary.retractedParts)
        .toSet();
    var hasRetractionPlaceholder = false;
    if (retractedParts.isNotEmpty) {
      messagesWithRetractionMetadata += 1;
      var partBuildFailed = false;
      // Exercise the same part builder used by the conversation view. Merely
      // having retraction metadata must not excuse an unrenderable blank row.
      try {
        final renderedParts = message.buildMessageParts()
            .where((part) => part.isUnsent)
            .map((part) => part.part)
            .toSet();
        hasRetractionPlaceholder = retractedParts.every(
          (part) => part >= 0 && renderedParts.contains(part),
        );
      } catch (_) {
        // Some multipart attachment paths require live presentation services.
        // A failed offline build is unverified, not a successful placeholder
        // or proof that the installed application cannot render the row.
        partBuildFailed = true;
        messagesWithRetractionPartBuildFailure += 1;
      }
      if (!hasRetractionPlaceholder && !partBuildFailed) {
        messagesWithUnrenderedRetractions += 1;
      }
    }
    if (chatId != 0 && createdAt != null && message.dateDeleted == null) {
      final previous = latestVisibleMessageDateByChatId[chatId];
      if (previous == null || createdAt.isAfter(previous)) {
        latestVisibleMessageDateByChatId[chatId] = createdAt;
      }
    }
    final text = _normalizedProjectionCandidate(message.text);
    final attributedText = _normalizedProjectionCandidate(
      message.attributedBody
          .map((part) => part.string.trim())
          .where((part) => part.isNotEmpty)
          .join(' '),
    );
    final subject = _normalizedProjectionCandidate(message.subject);
    final hasText = text != null;
    final hasSubject = subject != null;
    final hasAttributedBody = message.attributedBody.isNotEmpty;
    final hasAttributedText = attributedText != null;
    final hasAttachments =
        message.hasAttachments || message.dbAttachments.isNotEmpty;
    final isAssociated = message.associatedMessageGuid?.isNotEmpty ?? false;
    final isEvent = (message.itemType ?? 0) != 0;
    if (hasText) messagesWithText += 1;
    if (hasSubject) messagesWithSubject += 1;
    if (hasAttributedBody) messagesWithAttributedBody += 1;
    if (hasAttributedText) messagesWithAttributedText += 1;
    if (hasAttachments) messagesWithAttachments += 1;
    if (isAssociated) {
      associatedMessages += 1;
      final parentQuery =
          store
              .box<Message>()
              .query(
                Message_.guid.equals(
                  message.associatedMessageGuid!,
                  caseSensitive: true,
                ),
              )
              .build()
            ..limit = 2;
      try {
        final parents = parentQuery.find();
        if (parents.length != 1) {
          associatedMessagesWithMissingOrAmbiguousParent += 1;
        } else {
          final parent = parents.single;
          if (parent.chat.targetId == 0 || parent.chat.targetId != chatId) {
            associatedMessagesWithMismatchedChat += 1;
          }
          if (!parent.hasReactions) {
            associatedMessagesWithMissingParentFlag += 1;
          }
        }
      } finally {
        parentQuery.close();
      }
    }
    if (isEvent) eventMessages += 1;
    final projectedBody = text ?? attributedText ?? subject;
    if (projectedBody != null) {
      if (text != null) {
        projectedBodiesUsingText += 1;
      } else if (attributedText != null) {
        projectedBodiesUsingAttributedText += 1;
      } else {
        projectedBodiesUsingSubject += 1;
      }
      if (projectedBody.contains('\u{fffd}')) {
        projectedBodiesWithUnicodeReplacementCharacter += 1;
      }
      if (_hasUnexpectedControlCharacter(projectedBody)) {
        projectedBodiesWithUnexpectedControlCharacter += 1;
      }
      if (_hasUnpairedUtf16Surrogate(projectedBody)) {
        projectedBodiesWithUnpairedUtf16Surrogate += 1;
      }
      if (_hasLikelyMojibake(projectedBody)) {
        projectedBodiesWithLikelyMojibake += 1;
      }
      if (_looksLikeHtmlDocument(projectedBody)) {
        projectedBodiesWithHtmlDocumentText += 1;
      }
      if (!_hasVisibleGlyphCandidate(projectedBody)) {
        projectedBodiesWithoutVisibleGlyphCandidate += 1;
      }
    }
    if (!hasText && hasAttachments) messagesWithoutTextWithAttachments += 1;
    if (!hasText &&
        !hasSubject &&
        !hasAttributedText &&
        !hasAttachments &&
        !isAssociated &&
        !isEvent) {
      messagesWithoutRenderableContent += 1;
      if (hasRetractionPlaceholder) {
        contentlessMessagesWithRetractionPlaceholder += 1;
      }
      if (message.dateDeleted == null) {
        visibleMessagesWithoutRenderableContent += 1;
        if (!hasRetractionPlaceholder) {
          visibleMessagesWithoutContentOrRetraction += 1;
        }
      } else {
        deletedMessagesWithoutRenderableContent += 1;
      }
      if (message.payloadData != null || message.hasApplePayloadData) {
        unrenderableMessagesWithPayloadData += 1;
      }
      if (message.balloonBundleId?.trim().isNotEmpty ?? false) {
        unrenderableMessagesWithBalloonBundleId += 1;
      }
      if (message.ckRecordId?.trim().isNotEmpty ?? false) {
        unrenderableMessagesWithCloudRecordId += 1;
      }
      if (chat == null || chatId == 0) {
        unrenderableMessagesWithoutChat += 1;
      }
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
  var chatsWithVisibleMessages = 0;
  var chatsWithMatchingLatestMessageDate = 0;
  var chatsWithNullLatestMessageDate = 0;
  var chatsWithLatestMessageDateBehind = 0;
  var chatsWithLatestMessageDateAhead = 0;
  var smsChatsWithNullOrStaleLatestMessageDate = 0;
  var iMessageChatsWithNullOrStaleLatestMessageDate = 0;
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
    final latestVisibleMessageDate = latestVisibleMessageDateByChatId[chat.id];
    if (latestVisibleMessageDate != null) {
      chatsWithVisibleMessages += 1;
      final cachedLatestMessageDate = chat.dbOnlyLatestMessageDate;
      final cacheIsNullOrBehind =
          cachedLatestMessageDate == null ||
          cachedLatestMessageDate.isBefore(latestVisibleMessageDate);
      if (cachedLatestMessageDate == null) {
        chatsWithNullLatestMessageDate += 1;
      } else if (cachedLatestMessageDate.isBefore(latestVisibleMessageDate)) {
        chatsWithLatestMessageDateBehind += 1;
      } else if (cachedLatestMessageDate.isAfter(latestVisibleMessageDate)) {
        chatsWithLatestMessageDateAhead += 1;
      } else {
        chatsWithMatchingLatestMessageDate += 1;
      }
      if (cacheIsNullOrBehind) {
        if (chat.isRpSms) {
          smsChatsWithNullOrStaleLatestMessageDate += 1;
        } else {
          iMessageChatsWithNullOrStaleLatestMessageDate += 1;
        }
      }
    }
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
    'messagesWithAttributedText': messagesWithAttributedText,
    'messagesWithAttachments': messagesWithAttachments,
    'associatedMessages': associatedMessages,
    'associatedMessagesWithMissingOrAmbiguousParent':
        associatedMessagesWithMissingOrAmbiguousParent,
    'associatedMessagesWithMismatchedChat':
        associatedMessagesWithMismatchedChat,
    'associatedMessagesWithMissingParentFlag':
        associatedMessagesWithMissingParentFlag,
    'messagesWithEditHistory': messagesWithEditHistory,
    'editHistoryEntries': editHistoryEntries,
    'editHistoryEntriesWithText': editHistoryEntriesWithText,
    'editHistoryEntriesWithInvalidTimestamp':
        editHistoryEntriesWithInvalidTimestamp,
    'editHistoryEntriesBeforeMessageCreation':
        editHistoryEntriesBeforeMessageCreation,
    'editHistoryEntriesWithInvalidUnicode':
        editHistoryEntriesWithInvalidUnicode,
    'messagesWithRetractionMetadata': messagesWithRetractionMetadata,
    'messagesWithUnrenderedRetractions': messagesWithUnrenderedRetractions,
    'messagesWithRetractionPartBuildFailure':
        messagesWithRetractionPartBuildFailure,
    'contentlessMessagesWithRetractionPlaceholder':
        contentlessMessagesWithRetractionPlaceholder,
    'visibleMessagesWithoutContentOrRetraction':
        visibleMessagesWithoutContentOrRetraction,
    'eventMessages': eventMessages,
    'messagesWithoutRenderableContent': messagesWithoutRenderableContent,
    'visibleMessagesWithoutRenderableContent':
        visibleMessagesWithoutRenderableContent,
    'deletedMessagesWithoutRenderableContent':
        deletedMessagesWithoutRenderableContent,
    'unrenderableMessagesWithPayloadData': unrenderableMessagesWithPayloadData,
    'unrenderableMessagesWithBalloonBundleId':
        unrenderableMessagesWithBalloonBundleId,
    'unrenderableMessagesWithCloudRecordId':
        unrenderableMessagesWithCloudRecordId,
    'unrenderableMessagesWithoutChat': unrenderableMessagesWithoutChat,
    'projectedBodiesUsingText': projectedBodiesUsingText,
    'projectedBodiesUsingAttributedText': projectedBodiesUsingAttributedText,
    'projectedBodiesUsingSubject': projectedBodiesUsingSubject,
    'projectedBodiesWithUnicodeReplacementCharacter':
        projectedBodiesWithUnicodeReplacementCharacter,
    'projectedBodiesWithUnexpectedControlCharacter':
        projectedBodiesWithUnexpectedControlCharacter,
    'projectedBodiesWithUnpairedUtf16Surrogate':
        projectedBodiesWithUnpairedUtf16Surrogate,
    'projectedBodiesWithLikelyMojibake': projectedBodiesWithLikelyMojibake,
    'projectedBodiesWithHtmlDocumentText': projectedBodiesWithHtmlDocumentText,
    'projectedBodiesWithoutVisibleGlyphCandidate':
        projectedBodiesWithoutVisibleGlyphCandidate,
    'messagesWithoutTextWithAttachments': messagesWithoutTextWithAttachments,
    'smsServiceRows': smsServiceRows,
    'iMessageServiceRows': iMessageServiceRows,
    'ckRecordIdRows': ckRecordIdRows,
    'cloudGuidRows': cloudGuidRows,
    'cloudDataRows': cloudDataRows,
    'guidReferenceRows': guidReferenceRows,
    'compositeLegacyCloudEvidenceRows': compositeLegacyCloudEvidenceRows,
    'chatsWithVisibleMessages': chatsWithVisibleMessages,
    'chatsWithMatchingLatestMessageDate': chatsWithMatchingLatestMessageDate,
    'chatsWithNullLatestMessageDate': chatsWithNullLatestMessageDate,
    'chatsWithLatestMessageDateBehind': chatsWithLatestMessageDateBehind,
    'chatsWithLatestMessageDateAhead': chatsWithLatestMessageDateAhead,
    'smsChatsWithNullOrStaleLatestMessageDate':
        smsChatsWithNullOrStaleLatestMessageDate,
    'iMessageChatsWithNullOrStaleLatestMessageDate':
        iMessageChatsWithNullOrStaleLatestMessageDate,
  };
}

String? _normalizedProjectionCandidate(String? value) {
  final normalized = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

bool _hasUnexpectedControlCharacter(String value) {
  for (final codeUnit in value.codeUnits) {
    if (codeUnit == 0x09 || codeUnit == 0x0a || codeUnit == 0x0d) continue;
    if (codeUnit < 0x20 || (codeUnit >= 0x7f && codeUnit <= 0x9f)) {
      return true;
    }
  }
  return false;
}

bool _hasUnpairedUtf16Surrogate(String value) {
  final codeUnits = value.codeUnits;
  for (var index = 0; index < codeUnits.length; index += 1) {
    final codeUnit = codeUnits[index];
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= codeUnits.length ||
          codeUnits[index + 1] < 0xdc00 ||
          codeUnits[index + 1] > 0xdfff) {
        return true;
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return true;
    }
  }
  return false;
}

bool _hasLikelyMojibake(String value) {
  final codeUnits = value.codeUnits;
  for (var index = 0; index + 1 < codeUnits.length; index += 1) {
    final first = codeUnits[index];
    final second = codeUnits[index + 1];
    if ((first == 0x00c2 || first == 0x00c3) &&
        second >= 0x0080 &&
        second <= 0x00bf) {
      return true;
    }
    if (first == 0x00e2 && second == 0x20ac) return true;
    if (first == 0x00f0 && second == 0x0178) return true;
  }
  return false;
}

bool _looksLikeHtmlDocument(String value) {
  final normalized = value.trimLeft().toLowerCase();
  return normalized.startsWith('<!doctype html') ||
      normalized.startsWith('<html');
}

bool _hasVisibleGlyphCandidate(String value) {
  for (final rune in value.runes) {
    if (rune <= 0x20 || (rune >= 0x7f && rune <= 0xa0)) continue;
    if (rune == 0x200b ||
        rune == 0x200c ||
        rune == 0x200d ||
        rune == 0x2060 ||
        rune == 0xfeff ||
        (rune >= 0xfe00 && rune <= 0xfe0f) ||
        (rune >= 0xe0100 && rune <= 0xe01ef)) {
      continue;
    }
    return true;
  }
  return false;
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
  final zones = <String>{};
  final statuses = <String, int>{};
  final failureCategories = <String, int>{};
  int retainedSaves = 0;
  int retainedUnclassifiedTombstones = 0;
  int retainedOther = 0;
  _BarrierMetadata? firstBarrier;

  void add(CloudInboxChangeEntity row, {required DateTime now}) {
    rowCount += 1;
    zones.add(_allowlistedOrInvalid(row.zone, _cloudZones));
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
    if (row.status == 3) {
      if (row.changeType == CloudChangeType.delete.name &&
          row.isTombstone &&
          row.failureCategory == null &&
          row.preflightCategory == null &&
          row.preflightCode == null) {
        retainedUnclassifiedTombstones++;
      } else if (row.changeType == CloudChangeType.save.name &&
          !row.isTombstone) {
        retainedSaves++;
      } else {
        retainedOther++;
      }
    }
    if (row.status == 1 || row.status == 3) return;
    final candidate = _BarrierMetadata.fromRow(row, now: now);
    if (firstBarrier == null || candidate.sequence < firstBarrier!.sequence) {
      firstBarrier = candidate;
    }
  }

  Map<String, Object?> toJson({required int groupOrdinal}) => <String, Object?>{
    'groupOrdinal': groupOrdinal,
    'zones': zones.toList()..sort(),
    'rows': rowCount,
    'statuses': statuses,
    'failureCategories': failureCategories,
    'retainedSaves': retainedSaves,
    'retainedUnclassifiedTombstones': retainedUnclassifiedTombstones,
    'retainedOther': retainedOther,
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
