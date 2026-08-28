import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_inbox_applier.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_quarantine_repair_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scope = CloudSyncScope(
    accountFingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    container: 'container',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semanticV2,
  );

  test('web repair request applies the native positive exact lease fence', () {
    CloudKitV2QuarantineRepairRequest request({
      required int generation,
      required int leaseGeneration,
    }) => CloudKitV2QuarantineRepairRequest(
      scope: scope,
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
      generation: generation,
      changeIdHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      correction: CloudKitV2QuarantineRepairAllowlist.only,
      leaseFence: CloudCoordinatorLeaseFence(
        ownerId: 'owner',
        generation: leaseGeneration,
      ),
    );

    expect(
      () => request(generation: 1, leaseGeneration: 0),
      throwsArgumentError,
    );
    expect(
      () => request(generation: 2, leaseGeneration: 1),
      throwsArgumentError,
    );
    expect(request(generation: 1, leaseGeneration: 1).generation, 1);
  });

  test(
    'web remains disabled and pins the canonical repair digest vector',
    () async {
      final payload = _digestPayload();
      expect(
        CloudKitV2SemanticContentDigest.forPayload(payload),
        '29a7fe45ef50c3571890d8438923450ed72095f3c26551b19d3fd0236dd2f0f2',
      );
      expect(
        CloudKitV2SemanticContentDigest.forPayload(
          CloudMessageEntityPayload(
            logicalEntityKeyHash: payload.logicalEntityKeyHash,
            canonicalGuid: payload.canonicalGuid,
            chatAliasKeyHash: payload.chatAliasKeyHash,
            chatIdentifier: payload.chatIdentifier,
            body: 'changed',
            senderHandle: payload.senderHandle,
            createdAt: payload.createdAt,
            error: payload.error,
            service: payload.service,
            subjectState: payload.subjectState,
            subject: payload.subject,
            bodyState: payload.bodyState,
            knownFlags: payload.knownFlags,
          ),
        ),
        isNot(CloudKitV2SemanticContentDigest.forPayload(payload)),
      );
      final result = await const CloudKitV2QuarantineRepairGateway().repair(
        request: CloudKitV2QuarantineRepairRequest(
          scope: scope,
          persistenceLane: CloudSyncPersistenceLane.semanticV2,
          generation: 1,
          changeIdHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          correction: CloudKitV2QuarantineRepairAllowlist.only,
          leaseFence: const CloudCoordinatorLeaseFence(
            ownerId: 'owner',
            generation: 1,
          ),
        ),
      );
      expect(
        result.disposition,
        CloudKitV2QuarantineRepairDisposition.disabled,
      );
      expect(
        result.safeCode,
        'quarantine_repair_native_capability_unavailable',
      );
    },
  );
}

CloudMessageEntityPayload _digestPayload() => CloudMessageEntityPayload(
  logicalEntityKeyHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  canonicalGuid: 'guid',
  chatAliasKeyHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  chatIdentifier: 'chat',
  body: 'body',
  senderHandle: 'sender',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
  error: 2,
  service: CloudSemanticService.iMessage,
  subjectState: CloudSemanticFieldState.value,
  subject: 'subject',
  bodyState: CloudSemanticFieldState.value,
  knownFlags: const CloudSemanticKnownMessageFlags(
    fromMe: true,
    delivered: false,
    read: true,
    hasDataDetectorResults: false,
    deliveredQuietly: true,
    didNotifyRecipient: false,
  ),
);
