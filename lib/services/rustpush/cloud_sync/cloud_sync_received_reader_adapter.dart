import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;

import 'cloud_protected_page_lease_lifecycle.dart';
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_binding.dart';
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

/// Retained Found -> ordinary semantic inbox. The regular reader owns decode,
/// edit/retraction merge and UI projection; this path never writes Message.text
/// or invents an Apple continuation token. Every attempt uses a fresh lookup.
Future<bool> handoffCloudSyncReceivedFound({
  required int intentId,
  required String privateStorageDirectory,
  required Object? Function() readActiveClient,
  required bool Function() stillCurrent,
}) async {
  if (!CloudSyncDevGate.receivedArchiveCaptureEnabled ||
      !CloudSyncDevGate.receivedArchiveInspectionEnabled ||
      !CloudSyncDevGate.manualSemanticPullEnabled ||
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
      final source = journal.readForReader(
        intentId: intentId,
        currentAuth: auth,
      );
      final parent = requireCloudSyncRestoredDirectChatProofForId(
        store: objectBox,
        messageScope: scope,
        chatId: source.localChatId,
      );
      final checkpoint = await durable.readCheckpoint(scope);
      if (checkpoint.generation != source.observation.generation) {
        throw StateError('cloud_sync_received_archive_admission_changed');
      }
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
        final currentParent = requireCloudSyncRestoredDirectChatProofForId(
          store: objectBox,
          messageScope: scope,
          chatId: source.localChatId,
        );
        if (currentParent.binding != parent.binding ||
            currentParent.generation != parent.generation ||
            currentParent.source != parent.source) {
          throw StateError('cloud_sync_received_archive_parent_changed');
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
        coordinator = await durable.tryAcquireCoordinatorLease(
          scope,
          ownerId: 'received-found-${auth.nativeSessionId}',
          now: DateTime.now().toUtc(),
          leaseDuration: const Duration(minutes: 3),
        );
        if (coordinator == null) {
          throw StateError('cloud_sync_received_archive_reader_busy');
        }
        return await session.run((token) async {
          final prepared = await api.cloudSyncPrepareReceivedArchiveInspection(
            cloudMessagesClient: client,
            nativeWriterPauseToken: token,
            storageDirectory: privateStorageDirectory,
            expectedAuth: api.CloudSyncNativeAuthMetadata(
              nativeSessionId: auth.nativeSessionId,
              accountFingerprint: auth.accountFingerprint,
              protectedStoreIdentity: auth.protectedStoreIdentity,
            ),
            receivedSource: api.CloudSyncNativeReceivedArchiveSourceBinding(
              accountFingerprint: source.source.accountFingerprint,
              protectedStoreIdentity: source.source.protectedStoreIdentity,
              messageGuidHash: source.source.messageGuidHash,
              sourceSha256: source.source.sourceSha256,
              protectedReference: source.source.protectedReference,
              leaseReference: source.source.leaseReference,
              payloadSha256: source.source.payloadSha256,
              payloadLength: source.source.payloadLength,
            ),
            chatGeneration: BigInt.from(parent.generation),
            messageGeneration: BigInt.from(checkpoint.generation),
            chatLogicalEntityKeyHash: parent.logicalEntityKeyHash,
            chatSource: parent.source,
          );
          try {
            return await transport.runProtectedStoreExclusive(
              () => transport.runLocalProtectedStoreExclusive(() async {
                await validate();
                journal.validateReaderAdmission(
                  transactionStore: objectBox,
                  scope: scope,
                  expected: source,
                  currentAuth: auth,
                  stillCurrent: stillCurrent,
                );
                final result = await api.cloudSyncStageReceivedFoundProjection(
                  prepared: prepared,
                  nativeWriterPauseToken: token,
                );
                var owned = false;
                try {
                  final raw = result.change;
                  if (result.messageGuidHash != source.source.messageGuidHash ||
                      result.sourceSha256 != source.source.sourceSha256 ||
                      result.generation.toInt() != checkpoint.generation ||
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
                    encryptedServerRecordId:
                        raw.protectedRecordIdentityReference,
                    encryptedPayloadReference:
                        raw.protectedRawEnvelopeReference,
                    payloadSha256: raw.payloadSha256,
                    serverModifiedAt: raw.serverModifiedAtMillis == null
                        ? null
                        : DateTime.fromMillisecondsSinceEpoch(
                            raw.serverModifiedAtMillis!.toInt(),
                            isUtc: true,
                          ),
                  );
                  await validate();
                  owned = durable.journalReceivedFound(
                    scope: scope,
                    change: change,
                    generation: checkpoint.generation,
                    batchId: result.batchId,
                    leaseReference: result.leaseReference,
                    leaseFence: coordinator!,
                    journal: journal,
                    source: source,
                    currentAuth: auth,
                    stillCurrent: stillCurrent,
                  );
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
                    generation: checkpoint.generation,
                    nextToken: null,
                    hasMore: false,
                    protectedPageLeaseReference: result.leaseReference,
                  );
                  await lifecycle.commitJournaledPage(
                    batch,
                    previousCheckpointReference: null,
                  );
                  await validate();
                  return true;
                } catch (_) {
                  if (!owned) {
                    try {
                      await transport.rollbackProtectedPageLease(
                        result.leaseReference,
                      );
                    } catch (_) {}
                  }
                  rethrow;
                }
              }),
            );
          } finally {
            await api.cloudSyncDiscardReceivedArchiveInspection(
              prepared: prepared,
            );
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
