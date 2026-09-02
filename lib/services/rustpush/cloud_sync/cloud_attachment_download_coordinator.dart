import 'dart:convert';

import 'package:bluebubbles/database/io/cloud_sync_records.dart';
import 'package:crypto/crypto.dart';

import 'cloud_attachment_body_materializer.dart';
import 'cloud_attachment_source_resolver.dart';
import 'cloud_sync_manual_semantic_pull_sampler.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';
import 'cloudkit_operation_interlock.dart';

typedef CloudAttachmentActiveGenerationReader =
    Future<int> Function(CloudSyncScope scope);

typedef CloudAttachmentSourceResolverCall =
    CloudAttachmentSource Function({
      required CloudSyncScope scope,
      required int generation,
      required String canonicalGuid,
    });

/// A typed result for an on-demand attachment download.
sealed class CloudAttachmentDownloadResult {
  const CloudAttachmentDownloadResult();
}

final class CloudAttachmentDownloadMaterialized
    extends CloudAttachmentDownloadResult {
  const CloudAttachmentDownloadMaterialized({
    required this.source,
    required this.body,
  });

  final CloudInboxEntry source;
  final CloudAttachmentBodyMaterializationResult body;
}

final class CloudAttachmentDownloadUnavailable
    extends CloudAttachmentDownloadResult {
  factory CloudAttachmentDownloadUnavailable(
    CloudAttachmentSourceResolutionCode code,
  ) {
    if (!CloudAttachmentDownloadCoordinator._isLegacyFallbackCode(code)) {
      throw ArgumentError.value(code, 'code');
    }
    return CloudAttachmentDownloadUnavailable._(code);
  }

  const CloudAttachmentDownloadUnavailable._(this.code);

  final CloudAttachmentSourceResolutionCode code;
}

/// Process-wide safety state shared by every attachment coordinator.
///
/// If a native writer pause or resume becomes uncertain, this latch remains
/// closed until process restart; constructing a new coordinator cannot bypass
/// it.
final class _CloudAttachmentDownloadSafetyLatch {
  bool _active = false;
  bool _uncertain = false;

  void _acquire() {
    if (_active || _uncertain) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'cloud_attachment_state_contention',
      );
    }
    _active = true;
  }

  void _complete({
    required bool pauseEstablishedOrUncertain,
    required bool resumeConfirmed,
  }) {
    if (pauseEstablishedOrUncertain && !resumeConfirmed) {
      _uncertain = true;
    }
    _active = false;
  }
}

/// Coordinates one read-only CloudKit V2 attachment body transfer.
///
/// All side effects and platform boundaries are injected. The resolver is a
/// synchronous ObjectBox read-only callback, while the materializer owns the
/// durable local download state and native body transfer. This coordinator
/// never performs an ObjectBox write or exposes a raw identifier.
final class CloudAttachmentDownloadCoordinator {
  CloudAttachmentDownloadCoordinator({
    required this._operationExclusion,
    required this._nativeWriterPause,
    required this._ensureAuthSnapshot,
    required this._prepareAuthUnderPause,
    required this._readAuthSnapshot,
    required this._readActiveGeneration,
    required this._resolveSource,
    required this._bodyMaterializer,
    required this._storageDirectory,
    required this._applicationDocumentsDirectory,
  });

  static const String container = 'com.apple.messages.cloud';
  static const String database = 'private';
  static const String zone = 'attachmentManateeZone';
  static const int maximumExpectedBytes = 512 * 1024 * 1024;
  static _CloudAttachmentDownloadSafetyLatch _processSafetyLatch =
      _CloudAttachmentDownloadSafetyLatch();

  /// Resets process safety state only in assertion-enabled test builds.
  ///
  /// A release build cannot use this escape hatch. Production recovery from
  /// an uncertain native pause still requires a process restart.
  static void debugResetProcessSafetyLatchForTesting() {
    var reset = false;
    assert(() {
      _processSafetyLatch = _CloudAttachmentDownloadSafetyLatch();
      reset = true;
      return true;
    }());
    if (!reset) {
      throw UnsupportedError('cloud_attachment_safety_latch_reset_disabled');
    }
  }

  final CloudKitOperationExclusion _operationExclusion;
  final CloudSyncNativeWriterPause _nativeWriterPause;
  final CloudSyncEnsuredAuthSnapshotReader _ensureAuthSnapshot;
  final CloudSyncSemanticPausedPreparedAuthSnapshotReader
  _prepareAuthUnderPause;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final CloudAttachmentActiveGenerationReader _readActiveGeneration;
  final CloudAttachmentSourceResolverCall _resolveSource;
  final CloudAttachmentBodyMaterializer _bodyMaterializer;
  final String _storageDirectory;
  final String _applicationDocumentsDirectory;

  Future<CloudAttachmentDownloadResult> download({
    required String canonicalGuid,
    required int expectedBytes,
  }) async {
    _validateRequest(
      canonicalGuid: canonicalGuid,
      expectedBytes: expectedBytes,
    );
    _processSafetyLatch._acquire();
    var pauseEstablishedOrUncertain = false;
    var resumeConfirmed = false;
    try {
      return await _operationExclusion.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: () async {
          final ensuredAuth = await _ensureAuthentication();
          late final Object pauseToken;
          try {
            pauseToken = await _nativeWriterPause.pause();
            pauseEstablishedOrUncertain = true;
          } on CloudSyncNativeWriterPauseUncertain {
            pauseEstablishedOrUncertain = true;
            _operationExclusion.poisonUntilProcessRestart();
            rethrow;
          }
          try {
            _validatePauseToken(pauseToken);

            final auth = await _prepareAuthentication(pauseToken, ensuredAuth);
            if (!ensuredAuth.sameIdentity(auth)) {
              throw _authorizationFailure();
            }
            await _requireUnchangedAuth(auth);
            final scope = _attachmentScope(auth);
            final generation = await _readActiveGenerationFor(scope);

            late final CloudAttachmentSource resolved;
            try {
              resolved = _resolveValidatedSource(
                scope: scope,
                generation: generation,
                canonicalGuid: canonicalGuid,
              );
            } on CloudAttachmentDownloadUnavailable catch (unavailable) {
              return unavailable;
            }
            final entry = _entryFromValidatedEntity(
              scope: scope,
              entity: resolved.inboxChange,
            );

            final body = await _materializeBody(
              auth: auth,
              pauseToken: pauseToken,
              source: entry,
              logicalEntityKeyHash: resolved.logicalEntityKeyHash,
              expectedCanonicalGuidSha256: resolved.expectedCanonicalGuidSha256,
              expectedBytes: expectedBytes,
            );
            return CloudAttachmentDownloadMaterialized(
              source: entry,
              body: body,
            );
          } finally {
            try {
              await _resumeWriter(pauseToken);
              resumeConfirmed = true;
            } catch (_) {
              _operationExclusion.poisonUntilProcessRestart();
              rethrow;
            }
          }
        },
      );
    } finally {
      _processSafetyLatch._complete(
        pauseEstablishedOrUncertain: pauseEstablishedOrUncertain,
        resumeConfirmed: resumeConfirmed,
      );
    }
  }

  Future<CloudSyncNativeAuthSnapshot> _ensureAuthentication() async {
    try {
      final auth = await _ensureAuthSnapshot();
      if (auth == null) throw _authorizationFailure();
      return auth;
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw _authorizationFailure();
    }
  }

  Future<CloudSyncNativeAuthSnapshot> _prepareAuthentication(
    Object pauseToken,
    CloudSyncNativeAuthSnapshot expectedAuth,
  ) async {
    try {
      final auth = await _prepareAuthUnderPause(pauseToken, expectedAuth);
      if (auth == null) throw _authorizationFailure();
      return auth;
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw _authorizationFailure();
    }
  }

  CloudSyncScope _attachmentScope(CloudSyncNativeAuthSnapshot auth) {
    try {
      return CloudSyncScope(
        accountFingerprint: auth.accountFingerprint,
        container: container,
        database: database,
        zone: zone,
        streamKind: CloudSyncStreamKind.messages,
        schemaVersion: 2,
        persistenceLane: CloudSyncPersistenceLane.semanticV2,
      );
    } catch (_) {
      throw _authorizationFailure();
    }
  }

  Future<void> _requireUnchangedAuth(
    CloudSyncNativeAuthSnapshot expected,
  ) async {
    try {
      final current = await _readAuthSnapshot();
      if (!expected.sameIdentity(current)) throw _authorizationFailure();
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw _authorizationFailure();
    }
  }

  Future<int> _readActiveGenerationFor(CloudSyncScope scope) async {
    try {
      final generation = await _readActiveGeneration(scope);
      if (generation <= 0) throw _sourceInvalidFailure();
      return generation;
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw _sourceInvalidFailure();
    }
  }

  CloudAttachmentSource _resolveValidatedSource({
    required CloudSyncScope scope,
    required int generation,
    required String canonicalGuid,
  }) {
    try {
      return _resolveSource(
        scope: scope,
        generation: generation,
        canonicalGuid: canonicalGuid,
      );
    } on CloudAttachmentSourceResolutionFailure catch (failure) {
      switch (failure.code) {
        case CloudAttachmentSourceResolutionCode.missingIdentity:
        case CloudAttachmentSourceResolutionCode.missingSource:
        case CloudAttachmentSourceResolutionCode.pendingSource:
        case CloudAttachmentSourceResolutionCode.quarantinedSource:
          throw CloudAttachmentDownloadUnavailable(failure.code);
        case CloudAttachmentSourceResolutionCode.invalidRequest:
        case CloudAttachmentSourceResolutionCode.ambiguousIdentity:
        case CloudAttachmentSourceResolutionCode.staleIdentity:
        case CloudAttachmentSourceResolutionCode.ambiguousSource:
        case CloudAttachmentSourceResolutionCode.wrongScope:
        case CloudAttachmentSourceResolutionCode.wrongGeneration:
        case CloudAttachmentSourceResolutionCode.invalidSource:
          throw _resolutionFailure(failure.code);
      }
    } catch (_) {
      throw _sourceInvalidFailure();
    }
  }

  CloudInboxEntry _entryFromValidatedEntity({
    required CloudSyncScope scope,
    required CloudInboxChangeEntity entity,
  }) {
    try {
      if (entity.scopeKey != _scopeKey(scope) ||
          entity.accountFingerprint != scope.accountFingerprint ||
          entity.zone != scope.zone ||
          entity.generation <= 0 ||
          entity.fetchSequence <= 0) {
        throw _sourceInvalidFailure();
      }

      final changeType = switch (entity.changeType) {
        'save' => CloudChangeType.save,
        'delete' => CloudChangeType.delete,
        _ => throw _sourceInvalidFailure(),
      };
      final status = CloudInboxStatus.values[entity.status];
      return CloudInboxEntry(
        scope: scope,
        sequence: entity.fetchSequence,
        change: CloudFetchedChange(
          changeId: entity.changeIdHash,
          recordIdHash: entity.serverRecordIdHash,
          etagHash: entity.etagHash,
          type: changeType,
          encryptedServerRecordId: entity.encryptedServerRecordId,
          protectedSystemFieldsReference: entity.protectedSystemFieldsRef,
          encryptedPayloadReference: entity.encryptedPayloadRef,
          payloadSha256: entity.payloadSha256,
          isTombstone: entity.isTombstone,
          serverModifiedAt: _dateOrNull(entity.serverModifiedAtMs),
          preflightFailure: _failureOrNull(
            entity.preflightCategory ??
                (entity.retryCount == 0 ? entity.failureCategory : null),
          ),
          preflightCode: _preflightCodeOrNull(entity.preflightCode),
        ),
        status: status,
        attemptCount: entity.retryCount,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          entity.createdAtMs,
          isUtc: true,
        ),
        batchId: entity.batchId,
        generation: entity.generation,
        nextEligibleAt: _dateOrNull(entity.nextEligibleAtMs),
        lastFailure: _failureOrNull(entity.failureCategory),
        completedAt: _dateOrNull(entity.completedAtMs),
      );
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw _sourceInvalidFailure();
    }
  }

  Future<CloudAttachmentBodyMaterializationResult> _materializeBody({
    required CloudSyncNativeAuthSnapshot auth,
    required Object pauseToken,
    required CloudInboxEntry source,
    required String logicalEntityKeyHash,
    required String expectedCanonicalGuidSha256,
    required int expectedBytes,
  }) async {
    try {
      if (pauseToken is! BigInt) throw _pauseTokenFailure();
      return await _bodyMaterializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: _storageDirectory,
        applicationDocumentsDirectory: _applicationDocumentsDirectory,
        source: source,
        logicalEntityKeyHash: logicalEntityKeyHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: expectedBytes,
      );
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw _sourceInvalidFailure();
    }
  }

  Future<void> _resumeWriter(Object pauseToken) async {
    try {
      await _nativeWriterPause.resume(pauseToken);
    } on CloudSyncFailure {
      rethrow;
    } catch (_) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.dependency,
        safeCode: 'cloud_sync_native_writer_resume_failed',
      );
    }
  }

  static void _validateRequest({
    required String canonicalGuid,
    required int expectedBytes,
  }) {
    if (canonicalGuid.trim().isEmpty ||
        expectedBytes <= 0 ||
        expectedBytes > maximumExpectedBytes) {
      throw _sourceInvalidFailure();
    }
  }

  static void _validatePauseToken(Object pauseToken) {
    if (pauseToken is! BigInt ||
        pauseToken <= BigInt.zero ||
        pauseToken.bitLength > 64) {
      throw _pauseTokenFailure();
    }
  }

  static bool _isLegacyFallbackCode(CloudAttachmentSourceResolutionCode code) =>
      code == CloudAttachmentSourceResolutionCode.missingIdentity ||
      code == CloudAttachmentSourceResolutionCode.missingSource ||
      code == CloudAttachmentSourceResolutionCode.pendingSource ||
      code == CloudAttachmentSourceResolutionCode.quarantinedSource;

  static CloudSyncFailure _authorizationFailure() => CloudSyncFailure(
    category: CloudFailureCategory.authorization,
    safeCode: 'cloud_attachment_account_changed',
  );

  static CloudSyncFailure _pauseTokenFailure() => CloudSyncFailure(
    category: CloudFailureCategory.malformedRecord,
    safeCode: 'cloud_sync_native_writer_pause_token_invalid',
  );

  static CloudSyncFailure _sourceInvalidFailure() => CloudSyncFailure(
    category: CloudFailureCategory.malformedRecord,
    safeCode: 'cloud_attachment_source_invalid',
  );

  static CloudSyncFailure _resolutionFailure(
    CloudAttachmentSourceResolutionCode code,
  ) {
    final category = switch (code) {
      CloudAttachmentSourceResolutionCode.invalidRequest ||
      CloudAttachmentSourceResolutionCode.invalidSource =>
        CloudFailureCategory.malformedRecord,
      _ => CloudFailureCategory.conflict,
    };
    final safeCode = category == CloudFailureCategory.conflict
        ? 'cloud_attachment_source_conflict'
        : 'cloud_attachment_source_invalid';
    return CloudSyncFailure(category: category, safeCode: safeCode);
  }

  static String _scopeKey(CloudSyncScope scope) =>
      'scope2:${_digest(scope.storageKey)}';

  static DateTime? _dateOrNull(int milliseconds) => milliseconds == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);

  static CloudFailureCategory? _failureOrNull(String? value) {
    if (value == null) return null;
    return CloudFailureCategory.values.byName(value);
  }

  static CloudPreflightCode? _preflightCodeOrNull(String? value) {
    if (value == null) return null;
    return CloudPreflightCode.values.byName(value);
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}
