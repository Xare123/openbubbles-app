import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_archive_staging.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
import 'cloud_sync_historical_staging.dart';

typedef CloudSyncHistoricalNativeStage =
    Future<CloudSyncHistoricalProtectedSourceBinding> Function(
      CloudSyncHistoricalArchiveRequest request,
      List<int> canonicalBytes,
    );

/// Production scanner-to-protected-store handoff. Completion means durable
/// local adoption and committed native lease, never a CloudKit upload. The
/// owner must independently qualify the snapshot and hold its account/engine
/// lifetime; the staging coordinator revalidates identity under store exclusion.
final class CloudSyncHistoricalStageAdapter {
  const CloudSyncHistoricalStageAdapter({
    required this.staging,
    required this.stageNative,
  });

  factory CloudSyncHistoricalStageAdapter.production({
    required CloudSyncHistoricalArchiveStaging staging,
    required api.SharedPushState state,
  }) {
    final identity = staging.capturedIdentity;
    final expectedAuth = api.CloudSyncNativeAuthMetadata(
      nativeSessionId: identity.nativeSessionId,
      accountFingerprint: identity.accountFingerprint,
      protectedStoreIdentity: identity.protectedStoreIdentity,
    );
    return CloudSyncHistoricalStageAdapter(
      staging: staging,
      stageNative: (request, bytes) async =>
          CloudSyncHistoricalProtectedSourceBinding.fromNative(
            await api.cloudSyncStageHistoricalArchiveSource(
              state: state,
              expectedAuth: expectedAuth,
              snapshotSha256: request.snapshotSha256,
              expectedSourceSha256: request.sourceSha256,
              sourceBytes: bytes,
            ),
          ),
    );
  }

  final CloudSyncHistoricalArchiveStaging staging;
  final CloudSyncHistoricalNativeStage stageNative;

  Future<StagedHistoricalSource> call(
    CloudSyncHistoricalArchiveRequest request,
    List<int> canonicalBytes,
  ) async {
    if (request.accountFingerprint != staging.journal.accountFingerprint ||
        request.protectedStoreIdentity !=
            staging.journal.protectedStoreIdentity ||
        request.snapshotSha256 != staging.journal.snapshotSha256 ||
        canonicalBytes.isEmpty ||
        canonicalBytes.length > cloudSyncHistoricalMaxSourceBytes) {
      throw StateError('cloud_sync_historical_archive_binding_missing');
    }
    // Hold a private immutable copy across the asynchronous native boundary.
    final bytes = List<int>.unmodifiable(canonicalBytes);
    final expectedHash = historicalBytesSha256(bytes);
    final expectedLength = bytes.length;
    final adopted = await staging.adopt(
      messageGuidHash: request.guidHash,
      sourceSha256: request.sourceSha256,
      stageNative: () => stageNative(request, bytes),
      validateSource: (source) {
        if (source.payloadSha256 != expectedHash ||
            source.payloadLength != expectedLength) {
          throw StateError('cloud_sync_historical_archive_source_changed');
        }
      },
    );
    if (!adopted.sourceLeaseCommitted) {
      throw StateError('cloud_sync_historical_archive_stage_unverified');
    }
    return StagedHistoricalSource(
      key: adopted.source.sourceSha256,
      sha256: adopted.source.payloadSha256,
      byteLength: adopted.source.payloadLength,
      guid: request.guid,
    );
  }
}
