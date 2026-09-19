import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_received_archive_source_binding.dart';
import 'cloud_sync_transport.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_production_sampler_adapter.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_received_archive_journal.dart';
import 'cloud_sync_store.dart';
import 'cloud_sync_write_chat_identity_session.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_cloud_sync_store.dart';

/// Production post-stage discovery pipeline over injected collaborators: no
/// native calls here except lease rollback/commit through the passed
/// lifecycle and transport. Verifies the staged result, builds the change,
/// revalidates, adopts through the durable journal, and commits. The staged
/// lease rolls back exactly when nothing was adopted; adopted work is never
/// rolled back on a lost commit response. Returns true when this attempt
/// adopted the lease or the change was already owned (duplicate).
Future<bool> adoptCloudSyncDiscoveredStage({
  required api.CloudSyncReceivedFoundProjection result,
  required CloudSyncReceivedArchiveSourceBinding source,
  required int checkpointGeneration,
  required Future<void> Function() validate,
  required ObjectBoxCloudSyncStore durable,
  required CloudSyncReceivedArchiveJournal journal,
  required CloudSyncScope scope,
  required int intentId,
  required CloudSyncNativeAuthSnapshot auth,
  required CloudCoordinatorLeaseFence coordinator,
  required bool Function() stillCurrent,
  required CloudProtectedPageLeaseLifecycle lifecycle,
  required CloudProtectedPageLeaseTransport transport,
}) async {
  var adopted = false;
  try {
    final raw = result.change;
    if (result.messageGuidHash != source.messageGuidHash ||
        result.sourceSha256 != source.sourceSha256 ||
        result.generation.toInt() != checkpointGeneration ||
        raw.kind != api.CloudSyncProtectedChangeKind.save ||
        raw.preflightCode != null ||
        raw.isTombstone) {
      throw StateError(
        'cloud_sync_received_archive_record_mismatch',
      );
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
    final owned = durable.journalDiscoveredFound(
      scope: scope,
      change: change,
      generation: checkpointGeneration,
      batchId: result.batchId,
      leaseReference: result.leaseReference,
      leaseFence: coordinator,
      journal: journal,
      intentId: intentId,
      source: source,
      currentAuth: auth,
      stillCurrent: stillCurrent,
    );
    adopted = true;
    if (!owned) {
      await transport.rollbackProtectedPageLease(
        result.leaseReference,
      );
      return true; // Exact reader change already owned before this attempt.
    }
    final batch = CloudFetchBatch(
      scope: scope,
      changes: [change],
      batchId: result.batchId,
      generation: checkpointGeneration,
      nextToken: null,
      hasMore: false,
      protectedPageLeaseReference: result.leaseReference,
    );
    // A lost commit response after adoption reconciles through the catch
    // below: adopted work is never rolled back, and the next attempt replays
    // onto the already-owned change.
    await lifecycle.commitJournaledPage(
      batch,
      previousCheckpointReference: null,
    );
    return true;
  } catch (_) {
    if (!adopted) {
      try {
        await transport.rollbackProtectedPageLease(
          result.leaseReference,
        );
      } catch (_) {}
    }
    rethrow;
  }
}

/// Parentless discovery find becomes owned reader work WITHOUT parent proof.
/// This mirrors the parent-bound reader handoff through staging, change
/// verification, durable inbox adoption, and lease commit, but never requires
/// or invents a parent: the adopted pending row stays retained until the
/// ordinary reader projects it under a proven parent. Absent records return
/// false with nothing staged. Transport and verification failures throw for
/// retry; unadopted leases roll back, while adopted work is never rolled back
/// on a lost commit response. Every attempt uses a fresh lookup. Called from
/// the gated received worker after the ordinary found pass, bounded to one
/// candidate per pass.
Future<bool> retainCloudSyncDiscoveredReceivedFound({
  required int intentId,
  required String privateStorageDirectory,
  required Object? Function() readActiveClient,
  required bool Function() stillCurrent,
}) async {
  if (!CloudSyncDevGate.receivedArchiveCaptureEnabled ||
      !CloudSyncDevGate.receivedArchiveInspectionEnabled ||
      !CloudSyncDevGate.manualSemanticPullEnabled ||
      !CloudSyncDevGate.receivedArchiveDiscoveryEnabled ||
      !CloudKitWriterOwnership.v2MutationsEnabled) {
    throw StateError('cloud_sync_received_archive_inspection_disabled');
  }
  final objectBox = Database.store;
  final client = readActiveClient();
  if (client is! native.ArcCloudMessagesClientDefaultAnisetteProvider ||
      !stillCurrent()) {
    throw StateError('cloud_sync_received_archive_identity_unavailable');
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
        throw StateError('cloud_sync_received_archive_identity_changed');
      }
      final authority = ObjectBoxCloudKitWriterAuthority(store: objectBox);
      final owner = authority.read(
        CloudKitWriterScope(accountFingerprint: auth.accountFingerprint),
      );
      if (owner == null || owner.owner != CloudKitWriterOwner.v2) {
        throw StateError('cloud_sync_received_archive_owner_changed');
      }
      final journal = CloudSyncReceivedArchiveJournal(
        store: objectBox,
        authority: authority,
        authoritySnapshot: owner,
      );
      final scope = CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'messageManateeZone',
        persistenceLane: CloudSyncPersistenceLane.semantic,
      );
      final (intent, _, source) = journal.readMaterializedForInspection(
        intentId: intentId,
        currentAuth: auth,
      );
      // State 1 (captured, never inspected) is eligible here: discovery is the
      // first inspection for sources with no prior parent-bound observation.
      if ((intent.state != 1 && intent.state != 2) ||
          intent.admittedOperationId != null ||
          intent.readerChangeId != null) {
        throw StateError('cloud_sync_received_archive_found_projection_not_ready');
      }
      final checkpoint = await durable.readCheckpoint(scope);
      Future<void> validate() async {
        if (!stillCurrent() ||
            objectBox.isClosed() ||
            !identical(objectBox, Database.store)) {
          throw StateError('cloud_sync_received_archive_identity_changed');
        }
        final latest = await provider.capture();
        final currentCheckpoint = await durable.readCheckpoint(scope);
        if (!stillCurrent() ||
            !identical(client, readActiveClient()) ||
            objectBox.isClosed() ||
            !identical(objectBox, Database.store) ||
            !auth.sameIdentity(latest) ||
            authority.read(owner.scope)?.epoch != owner.epoch ||
            authority.read(owner.scope)?.owner != CloudKitWriterOwner.v2 ||
            currentCheckpoint.generation != checkpoint.generation) {
          throw StateError('cloud_sync_received_archive_identity_changed');
        }
        final (nowIntent, _, nowSource) =
            journal.readMaterializedForInspection(
          intentId: intentId,
          currentAuth: latest!,
        );
        if (nowIntent.state != intent.state ||
            nowSource.encode() != source.encode() ||
            nowIntent.admittedOperationId != null ||
            nowIntent.readerChangeId != null) {
          throw StateError('cloud_sync_received_archive_admission_changed');
        }
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
      CloudCoordinatorLeaseFence? coordinator;
      coordinator = await durable.tryAcquireCoordinatorLease(
        scope,
        ownerId: 'received-discovery-${auth.nativeSessionId}',
        now: DateTime.now().toUtc(),
        leaseDuration: const Duration(minutes: 3),
      );
      if (coordinator == null) {
        throw StateError('cloud_sync_received_archive_reader_busy');
      }
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
      try {
        return await session.run((token) async {
          final prepared =
              await api.cloudSyncDiscoverReceivedRecordExact(
            cloudMessagesClient: client,
            nativeWriterPauseToken: token,
            storageDirectory: privateStorageDirectory,
            expectedAuth: api.CloudSyncNativeAuthMetadata(
              nativeSessionId: auth.nativeSessionId,
              accountFingerprint: auth.accountFingerprint,
              protectedStoreIdentity: auth.protectedStoreIdentity,
            ),
            receivedSource: api.CloudSyncNativeReceivedArchiveSourceBinding(
              accountFingerprint: source.accountFingerprint,
              protectedStoreIdentity: source.protectedStoreIdentity,
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
                final result =
                await api.cloudSyncStageDiscoveredReceivedRecord(
              prepared: prepared,
              nativeWriterPauseToken: token,
            );
            if (result == null) {
              return false;
            }
            return await adoptCloudSyncDiscoveredStage(
              result: result,
              source: source,
              checkpointGeneration: checkpoint.generation,
              validate: validate,
              durable: durable,
              journal: journal,
              scope: scope,
              intentId: intentId,
              auth: auth,
              coordinator: coordinator!,
              stillCurrent: stillCurrent,
              lifecycle: lifecycle,
              transport: transport,
            );
              }),
            );
          } finally {
            await api.cloudSyncDiscardReceivedDiscovery(
              prepared: prepared,
            );
          }
        });
      } finally {
        try {
          await transport.quiesceNativeOperations();
        } finally {
          await durable.releaseCoordinatorLease(
            scope,
            leaseFence: coordinator,
          );
        }
      }
    },
  );
}
