// ignore_for_file: prefer_initializing_formals

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';

import 'cloud_attachment_body_materializer.dart';
import 'cloud_attachment_body_native_adapter.dart';
import 'cloud_attachment_download_coordinator.dart';
import 'cloud_attachment_materialization_store.dart';
import 'cloud_attachment_source_resolver.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_persistent_keys.dart';
import 'cloud_sync_production_sampler_adapter.dart';
import 'cloud_sync_protector.dart';
import 'cloudkit_operation_interlock.dart';
import 'objectbox_cloud_sync_store.dart';

typedef CloudAttachmentCoordinatorDownload =
    Future<CloudAttachmentDownloadResult> Function({
      required String canonicalGuid,
      required int expectedBytes,
    });

typedef CloudAttachmentOptionalGenerationReader =
    Future<int?> Function(CloudSyncScope scope);

/// Production composition for one on-demand CloudKit V2 attachment body.
///
/// [downloadIfAvailable] performs a local, read-only evidence probe before it
/// pauses native writers or warms CloudKit authentication. A conclusive absent
/// or pending source permits the caller to use its existing legacy path. Any
/// ambiguous or malformed evidence is deliberately re-evaluated by the full
/// coordinator and therefore fails closed instead of falling back.
final class CloudAttachmentProductionAdapter {
  CloudAttachmentProductionAdapter({
    required CloudSyncNativeAuthSnapshotReader readAuthSnapshot,
    required CloudAttachmentOptionalGenerationReader readActiveGeneration,
    required CloudAttachmentSourceResolverCall resolveSource,
    required CloudAttachmentCoordinatorDownload download,
  }) : _readAuthSnapshot = readAuthSnapshot,
       _readActiveGeneration = readActiveGeneration,
       _resolveSource = resolveSource,
       _download = download;

  factory CloudAttachmentProductionAdapter.fromDatabase({
    required ActiveCloudMessagesClientReader readActiveClient,
    required String privateStorageDirectory,
    required String applicationDocumentsDirectory,
    CloudSyncNativeAuthBinding? nativeAuthBinding,
    CloudAttachmentBodyNativeBindings? nativeBodyBindings,
  }) {
    final authProvider = CloudSyncProductionAuthSnapshotProvider(
      readActiveClient: readActiveClient,
      nativeAuthBinding: nativeAuthBinding ?? FrbCloudSyncNativeAuthBinding(),
      privateStorageDirectory: privateStorageDirectory,
    );
    final generationReader = ObjectBoxCloudAttachmentGenerationReader(
      store: Database.store,
    );
    final sourceResolver = CloudAttachmentSourceResolver(store: Database.store);
    final durableStore = ObjectBoxCloudSyncStore.fromDatabase(
      protector: RustCloudSyncProtector(
        storageDirectory: privateStorageDirectory,
      ),
    );
    final bodyMaterializer = CloudAttachmentBodyMaterializer(
      store: ObjectBoxCloudAttachmentMaterializationStore.fromDatabase(),
      nativeBindings:
          nativeBodyBindings ?? FrbCloudAttachmentBodyNativeBindings(),
      readAuthSnapshot: authProvider.capture,
    );
    final coordinator = CloudAttachmentDownloadCoordinator(
      operationExclusion: CloudKitOperationInterlock(
        privateStorageDirectory: privateStorageDirectory,
        fenceStore: durableStore,
      ),
      nativeWriterPause: FrbCloudSyncNativeWriterPause(),
      prepareAuthUnderPause:
          authProvider.prepareReadAuthenticationUnderNativeWriterPause,
      readAuthSnapshot: authProvider.capture,
      readActiveGeneration: generationReader.readRequired,
      resolveSource: sourceResolver.resolve,
      bodyMaterializer: bodyMaterializer,
      storageDirectory: privateStorageDirectory,
      applicationDocumentsDirectory: applicationDocumentsDirectory,
    );
    return CloudAttachmentProductionAdapter(
      readAuthSnapshot: authProvider.capture,
      readActiveGeneration: generationReader.readIfPresent,
      resolveSource: sourceResolver.resolve,
      download: coordinator.download,
    );
  }

  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudAttachmentOptionalGenerationReader _readActiveGeneration;
  final CloudAttachmentSourceResolverCall _resolveSource;
  final CloudAttachmentCoordinatorDownload _download;

  Future<CloudAttachmentDownloadResult> downloadIfAvailable({
    required String canonicalGuid,
    required int expectedBytes,
  }) async {
    final auth = await _readAuthSnapshot();
    if (auth == null) {
      return CloudAttachmentDownloadUnavailable(
        CloudAttachmentSourceResolutionCode.missingIdentity,
      );
    }
    final scope = CloudSyncScope(
      accountFingerprint: auth.accountFingerprint,
      container: CloudAttachmentDownloadCoordinator.container,
      database: CloudAttachmentDownloadCoordinator.database,
      zone: CloudAttachmentDownloadCoordinator.zone,
      persistenceLane: CloudSyncPersistenceLane.semanticV2,
    );

    late final int? generation;
    try {
      generation = await _readActiveGeneration(scope);
    } catch (_) {
      return _download(
        canonicalGuid: canonicalGuid,
        expectedBytes: expectedBytes,
      );
    }
    if (generation == null) {
      return CloudAttachmentDownloadUnavailable(
        CloudAttachmentSourceResolutionCode.missingSource,
      );
    }

    try {
      _resolveSource(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      );
    } on CloudAttachmentSourceResolutionFailure catch (failure) {
      if (_isLegacyFallbackCode(failure.code)) {
        return CloudAttachmentDownloadUnavailable(failure.code);
      }
      return _download(
        canonicalGuid: canonicalGuid,
        expectedBytes: expectedBytes,
      );
    } catch (_) {
      return _download(
        canonicalGuid: canonicalGuid,
        expectedBytes: expectedBytes,
      );
    }

    return _download(
      canonicalGuid: canonicalGuid,
      expectedBytes: expectedBytes,
    );
  }

  static bool _isLegacyFallbackCode(CloudAttachmentSourceResolutionCode code) =>
      code == CloudAttachmentSourceResolutionCode.missingIdentity ||
      code == CloudAttachmentSourceResolutionCode.missingSource ||
      code == CloudAttachmentSourceResolutionCode.pendingSource ||
      code == CloudAttachmentSourceResolutionCode.quarantinedSource;
}

/// Exact, read-only checkpoint-generation lookup for attachment downloads.
/// It never calls `readCheckpoint`, because that API creates missing state.
final class ObjectBoxCloudAttachmentGenerationReader {
  ObjectBoxCloudAttachmentGenerationReader({required Store store})
    : _store = store,
      _checkpoints = store.box<CloudSyncCheckpointEntity>();

  final Store _store;
  final Box<CloudSyncCheckpointEntity> _checkpoints;

  Future<int?> readIfPresent(CloudSyncScope scope) async {
    return _store.runInTransaction(TxMode.read, () {
      final query =
          _checkpoints
              .query(
                CloudSyncCheckpointEntity_.checkpointKey.equals(
                  cloudSyncPersistentScopeKey(scope),
                ),
              )
              .build()
            ..limit = 2;
      late final List<CloudSyncCheckpointEntity> rows;
      try {
        rows = query.find();
      } finally {
        query.close();
      }
      if (rows.isEmpty) return null;
      if (rows.length != 1) {
        throw StateError('cloud_attachment_checkpoint_ambiguous');
      }
      final checkpoint = rows.single;
      if (checkpoint.checkpointKey != cloudSyncPersistentScopeKey(scope) ||
          checkpoint.accountFingerprint != scope.accountFingerprint ||
          checkpoint.container != scope.container ||
          checkpoint.database != scope.database ||
          checkpoint.zone != scope.zone ||
          checkpoint.streamKind != scope.streamKind.name ||
          checkpoint.schemaVersion != scope.schemaVersion ||
          checkpoint.persistenceLane != scope.persistenceLane.name ||
          checkpoint.generation <= 0) {
        throw StateError('cloud_attachment_checkpoint_invalid');
      }
      return checkpoint.generation;
    });
  }

  Future<int> readRequired(CloudSyncScope scope) async {
    final generation = await readIfPresent(scope);
    if (generation == null) {
      throw StateError('cloud_attachment_checkpoint_missing');
    }
    return generation;
  }
}
