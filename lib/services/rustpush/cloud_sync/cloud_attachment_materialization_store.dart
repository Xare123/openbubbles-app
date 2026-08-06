import 'dart:convert';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:crypto/crypto.dart';

import 'cloud_attachment_materialization.dart';
import 'cloud_sync_models.dart';

abstract interface class CloudAttachmentMaterializationStore {
  Future<CloudAttachmentMaterialization?> read({
    required CloudSyncScope scope,
    required int generation,
    required String logicalEntityKeyHash,
  });

  /// Creates [initial] if absent. Returns false when an entry already exists.
  Future<bool> create(CloudAttachmentMaterialization initial);

  /// Atomically replaces [expected] with [next].
  ///
  /// Returns false when another process or isolate has already advanced the
  /// entry. Callers must reread and derive a new recovery plan.
  Future<bool> compareAndSwap({
    required CloudAttachmentMaterialization expected,
    required CloudAttachmentMaterialization next,
  });
}

final class ObjectBoxCloudAttachmentMaterializationStore
    implements CloudAttachmentMaterializationStore {
  ObjectBoxCloudAttachmentMaterializationStore({required Store store})
    : _store = store,
      _box = store.box<CloudAttachmentMaterializationEntity>();

  factory ObjectBoxCloudAttachmentMaterializationStore.fromDatabase() =>
      ObjectBoxCloudAttachmentMaterializationStore(store: Database.store);

  final Store _store;
  final Box<CloudAttachmentMaterializationEntity> _box;

  @override
  Future<CloudAttachmentMaterialization?> read({
    required CloudSyncScope scope,
    required int generation,
    required String logicalEntityKeyHash,
  }) async {
    return _store.runInTransaction(TxMode.read, () {
      final entity = _findLocked(
        scope: scope,
        logicalEntityKeyHash: logicalEntityKeyHash,
      );
      if (entity == null || entity.generation != generation) return null;
      return _fromEntity(scope, entity);
    });
  }

  @override
  Future<bool> create(CloudAttachmentMaterialization initial) async {
    return _store.runInTransaction(TxMode.write, () {
      if (_findLocked(
            scope: initial.scope,
            logicalEntityKeyHash: initial.logicalEntityKeyHash,
          ) !=
          null) {
        return false;
      }
      if (initial.stage != CloudAttachmentMaterializationStage.metadataReady) {
        throw const CloudAttachmentMaterializationFailure(
          CloudAttachmentMaterializationFailureCode.invalidTransition,
        );
      }
      _box.put(_toEntity(initial));
      return true;
    });
  }

  @override
  Future<bool> compareAndSwap({
    required CloudAttachmentMaterialization expected,
    required CloudAttachmentMaterialization next,
  }) async {
    _validateSameIdentity(expected, next);
    return _store.runInTransaction(TxMode.write, () {
      final entity = _findLocked(
        scope: expected.scope,
        logicalEntityKeyHash: expected.logicalEntityKeyHash,
      );
      if (entity == null || !_matches(entity, expected)) return false;
      if (next.stage.index < expected.stage.index ||
          next.verifiedBytes < expected.verifiedBytes) {
        throw const CloudAttachmentMaterializationFailure(
          CloudAttachmentMaterializationFailureCode.invalidTransition,
        );
      }
      final replacement = _toEntity(next)..id = entity.id;
      _box.put(replacement, mode: PutMode.update);
      return true;
    });
  }

  CloudAttachmentMaterializationEntity? _findLocked({
    required CloudSyncScope scope,
    required String logicalEntityKeyHash,
  }) {
    final query = _box
        .query(
          CloudAttachmentMaterializationEntity_.transferKey.equals(
            _transferKey(scope, logicalEntityKeyHash),
          ),
        )
        .build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  CloudAttachmentMaterialization _fromEntity(
    CloudSyncScope scope,
    CloudAttachmentMaterializationEntity entity,
  ) {
    if (entity.scopeKey != _scopeKey(scope) ||
        entity.accountFingerprint != scope.accountFingerprint ||
        entity.zone != scope.zone ||
        entity.stage < 0 ||
        entity.stage >= CloudAttachmentMaterializationStage.values.length) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.invalidTransition,
      );
    }
    return CloudAttachmentMaterialization.restore(
      scope: scope,
      generation: entity.generation,
      logicalEntityKeyHash: entity.logicalEntityKeyHash,
      expectedBytes: entity.expectedBytes,
      expectedIntegrityTagHash: entity.expectedIntegrityTagHash,
      stage: CloudAttachmentMaterializationStage.values[entity.stage],
      verifiedBytes: entity.verifiedBytes,
      protectedTempReference: entity.protectedTempReference,
      protectedResumeManifestReference: entity.protectedResumeManifestReference,
      protectedContentVerificationReference:
          entity.protectedContentVerificationReference,
      protectedFinalReference: entity.protectedFinalReference,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        entity.updatedAtMs,
        isUtc: true,
      ),
    );
  }

  CloudAttachmentMaterializationEntity _toEntity(
    CloudAttachmentMaterialization value,
  ) {
    return CloudAttachmentMaterializationEntity(
      transferKey: _transferKey(value.scope, value.logicalEntityKeyHash),
      scopeKey: _scopeKey(value.scope),
      accountFingerprint: value.scope.accountFingerprint,
      zone: value.scope.zone,
      generation: value.generation,
      logicalEntityKeyHash: value.logicalEntityKeyHash,
      expectedBytes: value.expectedBytes,
      expectedIntegrityTagHash: value.expectedIntegrityTagHash,
      stage: value.stage.index,
      verifiedBytes: value.verifiedBytes,
      protectedTempReference: value.protectedTempReference,
      protectedResumeManifestReference: value.protectedResumeManifestReference,
      protectedContentVerificationReference:
          value.protectedContentVerificationReference,
      protectedFinalReference: value.protectedFinalReference,
      updatedAtMs: value.updatedAt.toUtc().millisecondsSinceEpoch,
    );
  }

  bool _matches(
    CloudAttachmentMaterializationEntity entity,
    CloudAttachmentMaterialization expected,
  ) {
    return entity.scopeKey == _scopeKey(expected.scope) &&
        entity.generation == expected.generation &&
        entity.logicalEntityKeyHash == expected.logicalEntityKeyHash &&
        entity.expectedBytes == expected.expectedBytes &&
        entity.expectedIntegrityTagHash == expected.expectedIntegrityTagHash &&
        entity.stage == expected.stage.index &&
        entity.verifiedBytes == expected.verifiedBytes &&
        entity.protectedTempReference == expected.protectedTempReference &&
        entity.protectedResumeManifestReference ==
            expected.protectedResumeManifestReference &&
        entity.protectedContentVerificationReference ==
            expected.protectedContentVerificationReference &&
        entity.protectedFinalReference == expected.protectedFinalReference &&
        entity.updatedAtMs == expected.updatedAt.toUtc().millisecondsSinceEpoch;
  }

  void _validateSameIdentity(
    CloudAttachmentMaterialization expected,
    CloudAttachmentMaterialization next,
  ) {
    if (expected.scope != next.scope ||
        expected.generation != next.generation ||
        expected.logicalEntityKeyHash != next.logicalEntityKeyHash ||
        expected.expectedBytes != next.expectedBytes ||
        expected.expectedIntegrityTagHash != next.expectedIntegrityTagHash) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.generationMismatch,
      );
    }
  }

  String _scopeKey(CloudSyncScope scope) => sha256
      .convert(utf8.encode('cloud-sync-scope\u001f${scope.storageKey}'))
      .toString();

  String _transferKey(
    CloudSyncScope scope,
    String logicalEntityKeyHash,
  ) => sha256
      .convert(
        utf8.encode(
          'cloud-sync-attachment-transfer\u001f${scope.storageKey}\u001f$logicalEntityKeyHash',
        ),
      )
      .toString();
}
