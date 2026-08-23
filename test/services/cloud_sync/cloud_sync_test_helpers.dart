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
  final logicalKeyHash = List.filled(
    43,
    String.fromCharCode(65 + (index % 26)),
  ).join();
  final payloadSha256 = action == CloudOutboxAction.save
      ? '${index.toRadixString(16).padLeft(32, '0')}'
            '${revision.toRadixString(16).padLeft(32, '0')}'
      : null;
  final protectedReferenceMarker = String.fromCharCode(
    65 + ((index + revision) % 26),
  );
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
        ? 'obcs2.ref.${List.filled(43, protectedReferenceMarker).join()}'
        : null,
    payloadSha256: payloadSha256,
    protectedLeaseReference: action == CloudOutboxAction.save
        ? 'obcs2.lease.${index.toRadixString(16).padLeft(32, '0')}'
        : null,
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

String testSha256(String hexadecimalCharacter) =>
    List.filled(64, hexadecimalCharacter).join();

String testProtectedReference(String urlSafeCharacter) =>
    'obcs2.ref.${List.filled(43, urlSafeCharacter).join()}';

String testProtectedLeaseReference(String hexadecimalCharacter) =>
    'obcs2.lease.${List.filled(32, hexadecimalCharacter).join()}';

class MutableTestClock {
  MutableTestClock(this.value);

  DateTime value;

  DateTime call() => value;

  void advance(Duration duration) {
    value = value.add(duration);
  }
}
