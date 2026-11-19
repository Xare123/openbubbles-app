import 'cloud_sync_models.dart';

/// Intact legacy evidence is not proof of original CloudKit wire admission.
/// This refusal never requeues, migrates, resolves, or deletes an operation.
const cloudSyncLegacyWriteFreezeCode =
    'cloud_sync_legacy_original_wire_unproven';

bool cloudSyncLegacyWriteFreezeScope(CloudSyncScope scope) =>
    scope.container == 'com.apple.messages.cloud' &&
    scope.database == 'private' &&
    scope.streamKind == CloudSyncStreamKind.messages &&
    scope.schemaVersion == 2 &&
    scope.persistenceLane == CloudSyncPersistenceLane.semantic &&
    const {
      'chatManateeZone',
      'messageManateeZone',
      'attachmentManateeZone',
    }.contains(scope.zone);

/// Implementations inspect durable source ownership, never a caller flag or
/// a new payload version. Evidence access remains separate from eligibility.
abstract interface class CloudSyncLegacyWriteEligibilityStore {
  Future<void> requireLegacyWriteEligibility(CloudSyncScope scope);
}

Never cloudSyncRefuseUnprovenLegacyWrite() =>
    throw StateError(cloudSyncLegacyWriteFreezeCode);
