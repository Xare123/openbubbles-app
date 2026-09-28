import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

import 'cloud_sync_historical_archive_coordinator.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_archive_staging.dart';
import 'cloud_sync_historical_cursor_file.dart';
import 'cloud_sync_historical_import_controller.dart';
import 'cloud_sync_historical_ownership.dart';
import 'cloud_sync_historical_snapshot.dart';
import 'cloud_sync_historical_snapshot_file.dart';
import 'cloud_sync_historical_stage_adapter.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_protector.dart';
import 'cloudkit_writer_authority.dart';
import 'cloudkit_writer_ownership.dart';
import 'native_protected_cloud_sync_transport.dart';
import 'objectbox_cloud_sync_store.dart';

/// Production composition for one explicit historical import. Preparing only
/// reopens/captures a private encrypted snapshot, never calls archive or sends an
/// iMessage. The controller consumes exact source/destination consent later.
/// The service retains the engine and owns scheduling, foreground pause and
/// identity teardown throughout each call. No globals or automatic opt-in here.
Future<CloudSyncHistoricalImportPlan> prepareCloudSyncHistoricalImportPlan({
  required api.SharedPushState state,
  required Store store,
  required String storageDirectory,
  required String accountLabel,
  required bool Function() stillCurrent,
  required Future<void> Function() settleReader,
}) async {
  final client = state.icloudServices?.cloudMessagesClient;
  if (client == null || store.isClosed() || !stillCurrent()) {
    throw StateError('cloud_sync_historical_import_identity_changed');
  }
  final metadata = await api.cloudSyncCaptureReceivedIdentity(state: state);
  if (!stillCurrent()) {
    throw StateError('cloud_sync_historical_import_identity_changed');
  }
  final auth = CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: metadata.nativeSessionId,
    accountFingerprint: metadata.accountFingerprint,
    protectedStoreIdentity: metadata.protectedStoreIdentity,
    cloudMessagesClient: client,
  );
  final account = CloudSyncHistoricalAccountBinding(
    accountFingerprint: auth.accountFingerprint,
    protectedStoreIdentity: auth.protectedStoreIdentity,
  );
  Future<void> validate() async {
    if (store.isClosed() || !stillCurrent()) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
    final latest = await api.cloudSyncCaptureReceivedIdentity(state: state);
    if (store.isClosed() ||
        !stillCurrent() ||
        latest.nativeSessionId != metadata.nativeSessionId ||
        latest.accountFingerprint != metadata.accountFingerprint ||
        latest.protectedStoreIdentity != metadata.protectedStoreIdentity) {
      throw StateError('cloud_sync_historical_import_identity_changed');
    }
    final owner = ObjectBoxCloudKitWriterAuthority(
      store: store,
    ).read(CloudKitWriterScope(accountFingerprint: auth.accountFingerprint));
    if (owner == null || owner.owner != CloudKitWriterOwner.v2) {
      throw StateError('cloud_sync_historical_import_owner_required');
    }
  }

  await validate();
  final transport = NativeProtectedCloudSyncTransport(
    cloudMessagesClient: client,
    storageDirectory: storageDirectory,
    protectedStoreIdentity: auth.protectedStoreIdentity,
  );
  final protector = RustCloudSyncProtector(storageDirectory: storageDirectory);
  final file = CloudSyncHistoricalSnapshotFile(
    privateStorageDirectory: storageDirectory,
    account: account,
    protector: protector,
    transport: transport,
    validateIdentity: validate,
    stillCurrent: stillCurrent,
  );
  final CloudSyncHistoricalSnapshot snapshot;
  try {
    final retained = await file.load();
    if (retained != null) {
      snapshot = retained;
    } else {
      final handles = await api.getHandles(state: state.client);
      await validate();
      // The stored row mapper uses bare mail/telephone identifiers too. Do not
      // borrow a chat's mutable selected sending address for older messages.
      final bareHandles = handles
          .map((h) => h.replaceFirst(RegExp(r'^(mailto:|tel:)'), ''))
          .toSet()
          .toList(growable: false);
      snapshot = await CloudSyncHistoricalSnapshot.captureAsync(
        store: store,
        account: account,
        accountHandles: bareHandles,
        capturedAtMs: DateTime.now().millisecondsSinceEpoch,
        validateSource: validate,
        stillCurrent: stillCurrent,
      );
      await file.save(snapshot);
    }
    await validate();
  } finally {
    await transport.quiesceNativeOperations();
  }
  final journal = CloudSyncHistoricalArchiveJournal(
    store: store,
    accountFingerprint: auth.accountFingerprint,
    protectedStoreIdentity: auth.protectedStoreIdentity,
    snapshotSha256: snapshot.manifest.snapshotSha256,
  );
  final durable = ObjectBoxCloudSyncStore(store: store, protector: protector);
  final scope = CloudSyncScope(
    accountFingerprint: auth.accountFingerprint,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'messageManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semantic,
  );
  Future<void> settlePendingReader() async {
    await validate();
    var checkpoint = await durable.readCheckpoint(scope);
    await validate();
    if (!checkpoint.hasUnmarkedPendingInbox &&
        checkpoint.pendingBatchId == null) {
      return;
    }
    // Restart can leave a reader-owned record between handoff and projection.
    // Its ordinary reader must settle before the next exact discovery. Never
    // erase a pending row or call this a confirmed new upload.
    await settleReader();
    await validate();
    checkpoint = await durable.readCheckpoint(scope);
    await validate();
    if (checkpoint.hasUnmarkedPendingInbox ||
        checkpoint.pendingBatchId != null) {
      throw StateError('cloud_sync_historical_import_reader_pending');
    }
  }

  CloudSyncHistoricalArchiveDisposition? disposition;
  final coordinator = CloudSyncHistoricalArchiveCoordinator.production(
    store: store,
    staging: CloudSyncHistoricalStageAdapter.production(
      state: state,
      staging: CloudSyncHistoricalArchiveStaging(
        journal: journal,
        transport: transport,
        capturedIdentity: auth,
        validateCurrentIdentity: validate,
        stillCurrent: stillCurrent,
      ),
    ),
    durable: durable,
    privateStorageDirectory: storageDirectory,
    readActiveClient: () => stillCurrent() ? client : null,
    stillCurrent: stillCurrent,
    validate: validate,
    onDisposition: (value) => disposition = value,
  );
  return CloudSyncHistoricalImportPlan(
    snapshot: snapshot,
    accountLabel: accountLabel,
    archiveCursors: CloudSyncHistoricalCursorFile(
      privateStorageDirectory: storageDirectory,
      manifest: snapshot.manifest,
      account: account,
      transport: transport,
      stillCurrent: stillCurrent,
      mode: CloudSyncHistoricalCursorMode.archive,
    ),
    registry: ObjectBoxHistoricalOwnership(store: store, journal: journal),
    stillCurrent: stillCurrent,
    validateIdentity: validate,
    archive: (request, bytes) async {
      try {
        await settlePendingReader();
        disposition = null;
        final source = await coordinator(request, bytes);
        final result = disposition;
        if (result == null) {
          throw StateError('cloud_sync_historical_import_failed');
        }
        if (result == CloudSyncHistoricalArchiveDisposition.retainedByReader) {
          await settlePendingReader();
        }
        return (source: source, disposition: result);
      } finally {
        await transport.quiesceNativeOperations();
      }
    },
  );
}
