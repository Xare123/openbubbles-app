import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'cloud_sync_dev_gate.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_outbound_chat_binding.dart';
import 'cloud_sync_production_sampler_adapter.dart';
import 'cloud_sync_protector.dart';
import 'cloud_sync_received_archive_journal.dart';
import 'cloud_sync_received_inspection.dart';
import 'cloud_sync_received_record_observation.dart';
import 'cloud_sync_write_chat_identity_session.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_cloud_sync_store.dart';

/// Explicit exact-intent inspection. Does not schedule itself, save to Apple,
/// adopt a Message mapping or invent a fresh origin from historical Messages.
Future<CloudSyncReceivedRecordObservation> inspectCloudSyncReceivedIntent({
  required int intentId,
  required String privateStorageDirectory,
  required Object? Function() readActiveClient,
  required bool Function() stillCurrent,
}) async {
  if (!CloudSyncDevGate.receivedArchiveCaptureEnabled ||
      !CloudSyncDevGate.receivedArchiveInspectionEnabled ||
      !CloudKitWriterOwnership.v2MutationsEnabled) {
    throw StateError('cloud_sync_received_archive_inspection_disabled');
  }
  final store = Database.store;
  final client = readActiveClient();
  if (client is! native.ArcCloudMessagesClientDefaultAnisetteProvider ||
      !stillCurrent()) {
    throw StateError('cloud_sync_received_archive_identity_unavailable');
  }
  final durable = ObjectBoxCloudSyncStore(
    store: store,
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
      final authority = ObjectBoxCloudKitWriterAuthority(store: store);
      final owner = authority.read(
        CloudKitWriterScope(accountFingerprint: auth.accountFingerprint),
      );
      if (owner == null || owner.owner != CloudKitWriterOwner.v2) {
        throw StateError('cloud_sync_received_archive_owner_changed');
      }
      final journal = CloudSyncReceivedArchiveJournal(
        store: store,
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
      final checkpoint = await durable.readCheckpoint(scope);
      final (origin, message, source) = journal.readMaterializedForInspection(
        intentId: intentId,
        currentAuth: auth,
      );
      final parent = requireCloudSyncRestoredDirectChatProof(
        store: store,
        messageScope: scope,
        message: message,
      );
      void validateParent() {
        final (nowOrigin, nowMessage, nowSource) = journal
            .readMaterializedForInspection(
              intentId: intentId,
              currentAuth: auth,
            );
        final nowParent = requireCloudSyncRestoredDirectChatProof(
          store: store,
          messageScope: scope,
          message: nowMessage,
        );
        if (nowOrigin.localMessageId != origin.localMessageId ||
            nowSource.encode() != source.encode() ||
            nowParent.binding != parent.binding ||
            nowParent.generation != parent.generation ||
            nowParent.source != parent.source) {
          throw StateError('cloud_sync_received_archive_parent_changed');
        }
      }

      Future<void> validate() async {
        if (!stillCurrent() ||
            store.isClosed() ||
            !identical(store, Database.store)) {
          throw StateError('cloud_sync_received_archive_identity_changed');
        }
        final currentAuth = await provider.capture();
        final currentCheckpoint = await durable.readCheckpoint(scope);
        // Async auth/token reads are not a synchronous ownership fence. Check
        // active client/store/settings again after the final await.
        if (!stillCurrent() ||
            store.isClosed() ||
            !identical(store, Database.store) ||
            !identical(client, readActiveClient()) ||
            !auth.sameIdentity(currentAuth) ||
            authority.read(owner.scope)?.epoch != owner.epoch ||
            authority.read(owner.scope)?.owner != CloudKitWriterOwner.v2 ||
            currentCheckpoint.generation != checkpoint.generation) {
          throw StateError('cloud_sync_received_archive_identity_changed');
        }
        validateParent();
      }

      final transport = NativeProtectedCloudSyncTransport(
        cloudMessagesClient: client,
        storageDirectory: privateStorageDirectory,
        protectedStoreIdentity: auth.protectedStoreIdentity,
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
      try {
        return await session.run((token) async {
          api.CloudSyncPreparedReceivedInspection? prepared;
          try {
            return await CloudSyncReceivedInspectionCoordinator(
              journal: journal,
              transport: transport,
              auth: auth,
              validate: validate,
              stillCurrent: stillCurrent,
            ).inspect(
              intentId: intentId,
              validateParent: validateParent,
              expectedGeneration: checkpoint.generation,
              expectedParentBinding: parent.binding,
              prepareNative: (exact) async {
                final value = await api
                    .cloudSyncPrepareReceivedArchiveInspection(
                      cloudMessagesClient: client,
                      nativeWriterPauseToken: token,
                      storageDirectory: privateStorageDirectory,
                      expectedAuth: api.CloudSyncNativeAuthMetadata(
                        nativeSessionId: auth.nativeSessionId,
                        accountFingerprint: auth.accountFingerprint,
                        protectedStoreIdentity: auth.protectedStoreIdentity,
                      ),
                      receivedSource:
                          api.CloudSyncNativeReceivedArchiveSourceBinding(
                            accountFingerprint: exact.accountFingerprint,
                            protectedStoreIdentity:
                                exact.protectedStoreIdentity,
                            messageGuidHash: exact.messageGuidHash,
                            sourceSha256: exact.sourceSha256,
                            protectedReference: exact.protectedReference,
                            leaseReference: exact.leaseReference,
                            payloadSha256: exact.payloadSha256,
                            payloadLength: exact.payloadLength,
                          ),
                      chatGeneration: BigInt.from(parent.generation),
                      messageGeneration: BigInt.from(checkpoint.generation),
                      chatLogicalEntityKeyHash: parent.logicalEntityKeyHash,
                      chatSource: parent.source,
                    );
                prepared = value;
                return value;
              },
              stageNative: (exact) async {
                final value = await api.cloudSyncStageReceivedArchiveInspection(
                  prepared: exact,
                  nativeWriterPauseToken: token,
                );
                try {
                  return CloudSyncReceivedRecordObservation.fromNative(
                    value,
                    source: source,
                    parentBinding: parent.binding,
                    now: DateTime.now(),
                  );
                } catch (_) {
                  final lease = value.protectedRawRecordLeaseReference;
                  if (lease != null) {
                    try {
                      await transport.rollbackProtectedPageLease(lease);
                    } catch (_) {}
                  }
                  rethrow;
                }
              },
            );
          } finally {
            final handle = prepared;
            if (handle != null) {
              await api.cloudSyncDiscardReceivedArchiveInspection(
                prepared: handle,
              );
            }
          }
        });
      } finally {
        await transport.quiesceNativeOperations();
      }
    },
  );
}
