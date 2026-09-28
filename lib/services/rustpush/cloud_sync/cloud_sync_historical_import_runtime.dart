import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as rustlib;

import 'cloud_sync_historical_archive_coordinator.dart';
import 'cloud_sync_historical_archive_journal.dart';
import 'cloud_sync_historical_archive_request.dart';
import 'cloud_sync_historical_archive_staging.dart';
import 'cloud_sync_historical_cursor_file.dart';
import 'cloud_sync_historical_import_controller.dart';
import 'cloud_sync_historical_import_source.dart';
import 'cloud_sync_historical_ownership.dart';
import 'cloud_sync_historical_protected_source_binding.dart';
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

// Bump after a reviewed change expands historical eligibility/projection. This
// replays the same retained snapshot, not its exact already-owned operations.
// Old progress, pending writes and confirmations remain intact in their journals.
const _historicalArchivePolicyRevision = 1;

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
  CloudSyncHistoricalImportSource? source,
}) async {
  final client = state.icloudServices?.cloudMessagesClient;
  if (client == null || store.isClosed() || !stillCurrent()) {
    throw StateError('cloud_sync_historical_import_identity_changed');
  }
  return _prepareHistoricalImport(
    client: client,
    store: store,
    storageDirectory: storageDirectory,
    accountLabel: accountLabel,
    stillCurrent: stillCurrent,
    settleReader: settleReader,
    source: source,
    captureIdentity: () => api.cloudSyncCaptureReceivedIdentity(state: state),
    stageNative: (auth, request, bytes) =>
        api.cloudSyncStageHistoricalArchiveSource(
          state: state,
          expectedAuth: auth,
          snapshotSha256: request.snapshotSha256,
          expectedSourceSha256: request.sourceSha256,
          sourceBytes: bytes,
        ),
    captureLocal: (account, validate) async {
      final handles = await api.getHandles(state: state.client);
      await validate();
      // Never borrow a chat's mutable selected address for an older message.
      final bareHandles = handles
          .map((h) => h.replaceFirst(RegExp(r'^(mailto:|tel:)'), ''))
          .toSet()
          .toList(growable: false);
      return CloudSyncHistoricalSnapshot.captureAsync(
        store: store,
        account: account,
        accountHandles: bareHandles,
        capturedAtMs: DateTime.now().millisecondsSinceEpoch,
        validateSource: validate,
        stillCurrent: stillCurrent,
      );
    },
  );
}

/// Uses the same archival engine for a separately qualified Windows source.
/// No SharedPushState, IDS registration, or global messaging services are
/// restored. The caller owns its isolated profile and exclusive relay window.
Future<CloudSyncHistoricalImportPlan>
prepareCloudSyncHistoricalImportPlanForClient({
  required rustlib.ArcCloudMessagesClientDefaultAnisetteProvider client,
  required Store store,
  required String storageDirectory,
  required String accountLabel,
  required CloudSyncHistoricalImportSource source,
  required bool Function() stillCurrent,
  required Future<void> Function() settleReader,
}) => _prepareHistoricalImport(
  client: client,
  store: store,
  storageDirectory: storageDirectory,
  accountLabel: accountLabel,
  stillCurrent: stillCurrent,
  settleReader: settleReader,
  source: source,
  captureIdentity: () => api.cloudSyncCaptureAuthSnapshot(
    cloudMessagesClient: client,
    storageDirectory: storageDirectory,
  ),
  stageNative: (auth, request, bytes) =>
      api.cloudSyncStageHistoricalArchiveSourceForClient(
        cloudMessagesClient: client,
        storageDirectory: storageDirectory,
        expectedAuth: auth,
        snapshotSha256: request.snapshotSha256,
        expectedSourceSha256: request.sourceSha256,
        sourceBytes: bytes,
      ),
  // Required source means this fallback must never be used by the Windows path.
  captureLocal: (_, _) =>
      throw StateError('cloud_sync_historical_import_source_invalid'),
);

Future<CloudSyncHistoricalImportPlan> _prepareHistoricalImport({
  required rustlib.ArcCloudMessagesClientDefaultAnisetteProvider client,
  required Store store,
  required String storageDirectory,
  required String accountLabel,
  required bool Function() stillCurrent,
  required Future<void> Function() settleReader,
  required Future<api.CloudSyncNativeAuthMetadata> Function() captureIdentity,
  required Future<api.CloudSyncNativeHistoricalArchiveSourceBinding> Function(
    api.CloudSyncNativeAuthMetadata,
    CloudSyncHistoricalArchiveRequest,
    List<int>,
  )
  stageNative,
  required Future<CloudSyncHistoricalSnapshot> Function(
    CloudSyncHistoricalAccountBinding,
    Future<void> Function(),
  )
  captureLocal,
  CloudSyncHistoricalImportSource? source,
}) async {
  if (store.isClosed() || !stillCurrent()) {
    throw StateError('cloud_sync_historical_import_identity_changed');
  }
  final metadata = await captureIdentity();
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
    final latest = await captureIdentity();
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
  source?.requireDestination(account);
  final transport = NativeProtectedCloudSyncTransport(
    cloudMessagesClient: client,
    storageDirectory: storageDirectory,
    protectedStoreIdentity: auth.protectedStoreIdentity,
  );
  final protector = RustCloudSyncProtector(storageDirectory: storageDirectory);
  final file = CloudSyncHistoricalSnapshotFile(
    privateStorageDirectory: storageDirectory,
    account: account,
    sourceIdentitySha256: source?.identitySha256,
    protector: protector,
    transport: transport,
    validateIdentity: validate,
    stillCurrent: stillCurrent,
  );
  final CloudSyncHistoricalSnapshot snapshot;
  try {
    final retained = await file.load();
    if (retained != null) {
      source?.requireSameSnapshot(retained);
      snapshot = retained;
    } else {
      snapshot = source?.snapshot ?? await captureLocal(account, validate);
      await validate();
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
    staging: CloudSyncHistoricalStageAdapter(
      stageNative: (request, bytes) async =>
          CloudSyncHistoricalProtectedSourceBinding.fromNative(
            await stageNative(metadata, request, bytes),
          ),
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
    sourceLabel: source?.label ?? 'Messages on this device',
    archiveCursors: CloudSyncHistoricalCursorFile(
      privateStorageDirectory: storageDirectory,
      manifest: snapshot.manifest,
      account: account,
      transport: transport,
      stillCurrent: stillCurrent,
      mode: CloudSyncHistoricalCursorMode.archive,
      archiveRevision: _historicalArchivePolicyRevision,
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
