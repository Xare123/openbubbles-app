import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_discovery_reader_adoption.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_production_sampler_adapter.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_write_chat_identity_session.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_cloud_sync_store.dart';

/// The stable selection remains the same across its one-way reader adoption.
/// Validate the exact adopted version afterwards, not the old unadopted state.
void validateCloudSyncHistoricalDiscoverySelection({
  required CloudSyncHistoricalArchiveJournal journal,
  required CloudSyncHistoricalArchiveIntent intent,
  required CloudSyncNativeAuthSnapshot auth,
  required int generation,
  api.CloudSyncReceivedFoundProjection? adopted,
}) {
  final source = intent.source;
  source.requireOrigin(
    accountFingerprint: auth.accountFingerprint,
    protectedStoreIdentity: auth.protectedStoreIdentity,
    snapshotSha256: journal.snapshotSha256,
    messageGuidHash: source.messageGuidHash,
    sourceSha256: source.sourceSha256,
  );
  final current = journal.read(
    messageGuidHash: source.messageGuidHash,
    sourceSha256: source.sourceSha256,
  );
  if (current == null ||
      current.id != intent.id ||
      !current.sourceLeaseCommitted ||
      current.admittedOperationId != null ||
      current.source.encode() != source.encode() ||
      current.readerChangeId !=
          (adopted?.change.changeId ?? intent.readerChangeId)) {
    throw StateError('cloud_sync_historical_reader_source_changed');
  }
  if (adopted != null) {
    if (adopted.messageGuidHash != source.messageGuidHash ||
        adopted.sourceSha256 != source.sourceSha256 ||
        adopted.generation.toInt() != generation) {
      throw StateError('cloud_sync_historical_reader_record_mismatch');
    }
    journal.validateDiscoveryRetained(
      intentId: intent.id,
      source: source,
      currentAuth: auth,
      changeId: adopted.change.changeId,
      recordIdHash: adopted.change.recordIdHash,
      etagHash: adopted.change.etagHash,
      payloadSha256: adopted.change.payloadSha256,
      generation: generation,
    );
  }
}

Future<bool> adoptCloudSyncHistoricalDiscoveryStage({
  required api.CloudSyncReceivedFoundProjection result,
  required CloudSyncHistoricalArchiveIntent intent,
  required CloudSyncHistoricalArchiveJournal journal,
  required CloudSyncNativeAuthSnapshot auth,
  required int generation,
  required CloudSyncScope scope,
  required CloudCoordinatorLeaseFence coordinator,
  required ObjectBoxCloudSyncStore durable,
  required Future<void> Function() validate,
  required bool Function() stillCurrent,
  required CloudProtectedPageLeaseLifecycle lifecycle,
  required CloudProtectedPageLeaseTransport transport,
}) => adoptCloudSyncExactDiscoveryStage(
  result: result,
  messageGuidHash: intent.source.messageGuidHash,
  sourceSha256: intent.source.sourceSha256,
  checkpointGeneration: generation,
  scope: scope,
  mismatchCode: 'cloud_sync_historical_reader_record_mismatch',
  validate: validate,
  journalChange: (change) => durable.journalHistoricalDiscoveredFound(
    scope: scope,
    change: change,
    generation: generation,
    batchId: result.batchId,
    leaseReference: result.leaseReference,
    leaseFence: coordinator,
    journal: journal,
    intentId: intent.id,
    source: intent.source,
    currentAuth: auth,
    stillCurrent: stillCurrent,
  ),
  lifecycle: lifecycle,
);

/// Exact historical-source lookup followed by ordinary durable reader ingress.
/// True means the reader owns the record, not that it finished projection.
/// False is fresh absence, never create authority or permission to overwrite.
/// The source remains historical; no IDS receipt or receiving alias is invented.
/// This explicit experimental entry point does not start an upload worker.
Future<bool> retainCloudSyncDiscoveredHistoricalFound({
  required CloudSyncHistoricalArchiveIntent intent,
  required String privateStorageDirectory,
  required Object? Function() readActiveClient,
  required bool Function() stillCurrent,
}) async {
  if (!CloudSyncDevGate.manualSemanticPullEnabled ||
      !CloudSyncDevGate.manualOutboundCanaryEnabled ||
      !CloudKitWriterOwnership.v2MutationsEnabled) {
    throw StateError('cloud_sync_historical_discovery_disabled');
  }
  final objectBox = Database.store;
  final client = readActiveClient();
  if (client is! native.ArcCloudMessagesClientDefaultAnisetteProvider ||
      !stillCurrent()) {
    throw StateError('cloud_sync_historical_identity_unavailable');
  }
  final durable = ObjectBoxCloudSyncStore(
    store: objectBox,
    protector: RustCloudSyncProtector(
      storageDirectory: privateStorageDirectory,
    ),
  );
  final interlock = CloudKitOperationInterlock(
    privateStorageDirectory: privateStorageDirectory,
    fenceStore: durable,
  );
  return interlock.runExclusive(
    kind: CloudKitOperationKind.v2ReadWrite,
    action: () async {
      final binding = FrbCloudSyncNativeAuthBinding();
      await binding.ensureReadAuthentication(
        cloudMessagesClient: client,
        privateStorageDirectory: privateStorageDirectory,
      );
      final provider = CloudSyncProductionAuthSnapshotProvider(
        readActiveClient: readActiveClient,
        nativeAuthBinding: binding,
        privateStorageDirectory: privateStorageDirectory,
      );
      final auth = await provider.capture();
      if (auth == null ||
          !stillCurrent() ||
          !identical(client, readActiveClient())) {
        throw StateError('cloud_sync_historical_identity_changed');
      }
      final authority = ObjectBoxCloudKitWriterAuthority(store: objectBox);
      final owner = authority.read(
        CloudKitWriterScope(accountFingerprint: auth.accountFingerprint),
      );
      if (owner == null || owner.owner != CloudKitWriterOwner.v2) {
        throw StateError('cloud_sync_historical_owner_changed');
      }
      final journal = CloudSyncHistoricalArchiveJournal(
        store: objectBox,
        accountFingerprint: auth.accountFingerprint,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        snapshotSha256: intent.source.snapshotSha256,
      );
      final scope = CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final checkpoint = await durable.readCheckpoint(scope);
      api.CloudSyncReceivedFoundProjection? adoptedResult;
      Future<void> validate() async {
        if (!stillCurrent() ||
            objectBox.isClosed() ||
            !identical(objectBox, Database.store)) {
          throw StateError('cloud_sync_historical_identity_changed');
        }
        final latest = await provider.capture();
        final currentCheckpoint = await durable.readCheckpoint(scope);
        final currentOwner = authority.read(owner.scope);
        if (!stillCurrent() ||
            objectBox.isClosed() ||
            !identical(objectBox, Database.store) ||
            !identical(client, readActiveClient()) ||
            !auth.sameIdentity(latest) ||
            currentOwner?.epoch != owner.epoch ||
            currentOwner?.owner != CloudKitWriterOwner.v2 ||
            currentCheckpoint.generation != checkpoint.generation) {
          throw StateError('cloud_sync_historical_identity_changed');
        }
        validateCloudSyncHistoricalDiscoverySelection(
          journal: journal,
          intent: intent,
          auth: latest!,
          generation: checkpoint.generation,
          adopted: adoptedResult,
        );
      }

      await validate();
      final transport = NativeProtectedCloudSyncTransport(
        cloudMessagesClient: client,
        storageDirectory: privateStorageDirectory,
        protectedStoreIdentity: auth.protectedStoreIdentity,
      );
      final lifecycle = CloudProtectedPageLeaseLifecycle(
        store: durable,
        transport: transport,
      );
      final session = CloudSyncWriteChatIdentitySession(
        exclusion: interlock,
        nativePause: FrbCloudSyncNativeWriterPause(),
        validate: validate,
        ensureReadAuthentication: () => binding.ensureReadAuthentication(
          cloudMessagesClient: client,
          privateStorageDirectory: privateStorageDirectory,
        ),
        warmReadAuthentication: (token) =>
            binding.warmReadAuthenticationUnderWriterPause(
              cloudMessagesClient: client,
              pauseToken: token,
            ),
      );
      CloudCoordinatorLeaseFence? coordinator;
      try {
        await lifecycle.ensureRecoveredBeforeFetch();
        await validate();
        // Restart after durable adoption needs lease recovery, not a second
        // native lookup or a duplicate reader row. The original marker remains.
        if (intent.readerChangeId != null) return true;
        coordinator = await durable.tryAcquireCoordinatorLease(
          scope,
          ownerId: 'historical-discovery-${auth.nativeSessionId}',
          now: DateTime.now().toUtc(),
          leaseDuration: const Duration(minutes: 3),
        );
        if (coordinator == null) {
          throw StateError('cloud_sync_historical_reader_busy');
        }
        return await session.run((token) async {
          final source = intent.source;
          final prepared = await api.cloudSyncDiscoverHistoricalRecordExact(
            cloudMessagesClient: client,
            nativeWriterPauseToken: token,
            storageDirectory: privateStorageDirectory,
            expectedAuth: api.CloudSyncNativeAuthMetadata(
              nativeSessionId: auth.nativeSessionId,
              accountFingerprint: auth.accountFingerprint,
              protectedStoreIdentity: auth.protectedStoreIdentity,
            ),
            historicalSource: api.CloudSyncNativeHistoricalArchiveSourceBinding(
              accountFingerprint: source.accountFingerprint,
              protectedStoreIdentity: source.protectedStoreIdentity,
              snapshotSha256: source.snapshotSha256,
              messageGuidHash: source.messageGuidHash,
              sourceSha256: source.sourceSha256,
              protectedReference: source.protectedReference,
              leaseReference: source.leaseReference,
              payloadSha256: source.payloadSha256,
              payloadLength: source.payloadLength,
            ),
            messageGeneration: BigInt.from(checkpoint.generation),
          );
          try {
            return await transport.runProtectedStoreExclusive(
              () => transport.runLocalProtectedStoreExclusive(() async {
                await validate();
                final result = await api
                    .cloudSyncStageDiscoveredHistoricalRecord(
                      prepared: prepared,
                      nativeWriterPauseToken: token,
                    );
                if (result == null) return false;
                final retained = await adoptCloudSyncHistoricalDiscoveryStage(
                  result: result,
                  intent: intent,
                  journal: journal,
                  auth: auth,
                  generation: checkpoint.generation,
                  scope: scope,
                  coordinator: coordinator!,
                  durable: durable,
                  validate: validate,
                  stillCurrent: stillCurrent,
                  lifecycle: lifecycle,
                  transport: transport,
                );
                adoptedResult = result;
                return retained;
              }),
            );
          } finally {
            await api.cloudSyncDiscardHistoricalDiscovery(prepared: prepared);
          }
        });
      } finally {
        try {
          await transport.quiesceNativeOperations();
        } finally {
          if (coordinator != null) {
            await durable.releaseCoordinatorLease(
              scope,
              leaseFence: coordinator,
            );
          }
        }
      }
    },
  );
}
