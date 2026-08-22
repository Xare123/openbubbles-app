import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_operation_identity.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';

final testEpoch = DateTime.utc(2026, 7, 31, 12);
const testAccountFingerprintA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const testAccountFingerprintB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

CloudSyncScope testScope({
  String account = testAccountFingerprintA,
  CloudSyncStreamKind streamKind = CloudSyncStreamKind.messages,
}) {
  return CloudSyncScope(
    accountFingerprint: account,
    container: 'messages-container',
    database: 'private',
    zone: 'message-zone',
    streamKind: streamKind,
  );
}

CloudFetchedChange testChange(
  int index, {
  bool tombstone = false,
  CloudFailureCategory? preflightFailure,
}) {
  final changeId = 'C${index.toString().padLeft(42, '0')}';
  return CloudFetchedChange(
    changeId: changeId,
    recordIdHash: 'record-digest-$index',
    etagHash: tombstone ? null : 'etag-digest-$index',
    type: tombstone ? CloudChangeType.delete : CloudChangeType.save,
    encryptedServerRecordId: 'protected:server-record-$index',
    protectedSystemFieldsReference: 'protected:system-fields-$index',
    encryptedPayloadReference: tombstone ? null : 'protected:payload-$index',
    payloadSha256: tombstone ? null : 'payload-digest-$index',
    isTombstone: tombstone,
    preflightFailure: preflightFailure,
  );
}

CloudOutboxOperation testOutboxOperation(
  CloudSyncScope scope,
  int index, {
  CloudOutboxAction action = CloudOutboxAction.save,
  int revision = 1,
  int checkpointGeneration = 1,
  Iterable<String> dependencies = const [],
  DateTime? createdAt,
}) {
  final logicalKeyHash = 'logical-key-digest-$index';
  final payloadSha256 = action == CloudOutboxAction.save
      ? 'payload-digest-$index-$revision'
      : null;
  return CloudOutboxOperation(
    scope: scope,
    operationId: CloudOperationIdentity.forMutation(
      scope: scope,
      logicalEntityKeyHash: logicalKeyHash,
      action: action,
      payloadVersion: 1,
      mutationRevision: revision,
      payloadSha256: payloadSha256,
    ),
    logicalEntityKeyHash: logicalKeyHash,
    action: action,
    payloadVersion: 1,
    mutationRevision: revision,
    checkpointGeneration: checkpointGeneration,
    encryptedPayloadReference: action == CloudOutboxAction.save
        ? 'protected:outbox-$index-$revision'
        : null,
    payloadSha256: payloadSha256,
    dependencyOperationIds: dependencies,
    createdAt: createdAt ?? testEpoch.add(Duration(microseconds: revision)),
  );
}

CloudOutboxSubmissionIdentity testSubmissionIdentity(
  Iterable<String> operationIds,
) {
  final ids = operationIds.toList(growable: false);
  return CloudOutboxSubmissionIdentity(
    requestUuid: '11111111-2222-4ABC-8DEF-555555555555',
    operationUuids: {
      for (var index = 0; index < ids.length; index++)
        ids[index]:
            'AAAAAAAA-BBBB-4CCC-8DDD-${(index + 1).toRadixString(16).padLeft(12, '0').toUpperCase()}',
    },
  );
}

class MutableTestClock {
  MutableTestClock(this.value);

  DateTime value;

  DateTime call() => value;

  void advance(Duration duration) {
    value = value.add(duration);
  }
}
