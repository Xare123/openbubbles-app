import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_transport.dart';

/// Common lease lifecycle for exact discovery. The caller supplies its
/// provenance-specific atomic journal transaction, never an unprotected source.
/// Success means durable reader ownership, not projection or remote upload.
Future<bool> adoptCloudSyncExactDiscoveryStage({
  required api.CloudSyncReceivedFoundProjection result,
  required String messageGuidHash,
  required String sourceSha256,
  required int checkpointGeneration,
  required CloudSyncScope scope,
  required String mismatchCode,
  required Future<void> Function() validate,
  required bool Function(CloudFetchedChange change) journalChange,
  required CloudProtectedPageLeaseLifecycle lifecycle,
  required CloudProtectedPageLeaseTransport transport,
}) async {
  var adopted = false;
  try {
    final raw = result.change;
    if (result.messageGuidHash != messageGuidHash ||
        result.sourceSha256 != sourceSha256 ||
        result.generation.toInt() != checkpointGeneration ||
        raw.kind != api.CloudSyncProtectedChangeKind.save ||
        raw.preflightCode != null ||
        raw.isTombstone) {
      throw StateError(mismatchCode);
    }
    final change = CloudFetchedChange(
      changeId: raw.changeId,
      recordIdHash: raw.recordIdHash,
      etagHash: raw.etagHash,
      type: CloudChangeType.save,
      encryptedServerRecordId: raw.protectedRecordIdentityReference,
      encryptedPayloadReference: raw.protectedRawEnvelopeReference,
      payloadSha256: raw.payloadSha256,
      serverModifiedAt: raw.serverModifiedAtMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              raw.serverModifiedAtMillis!.toInt(),
              isUtc: true,
            ),
    );
    await validate();
    final owned = journalChange(change);
    adopted = true;
    if (!owned) {
      // Existing ownership keeps its original references. Only this unused
      // fresh lease is disposable; an adopted lease is never rolled back.
      await transport.rollbackProtectedPageLease(result.leaseReference);
      return true;
    }
    await lifecycle.commitJournaledPage(
      CloudFetchBatch(
        scope: scope,
        changes: [change],
        batchId: result.batchId,
        generation: checkpointGeneration,
        nextToken: null,
        hasMore: false,
        protectedPageLeaseReference: result.leaseReference,
      ),
      previousCheckpointReference: null,
    );
    return true;
  } catch (_) {
    if (!adopted) {
      try {
        await transport.rollbackProtectedPageLease(result.leaseReference);
      } catch (_) {}
    }
    rethrow;
  }
}
