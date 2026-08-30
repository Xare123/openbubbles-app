import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cloud_attachment_materialization.dart';
import 'cloud_attachment_materialization_store.dart';
import 'cloud_sync_manual_shadow_sampler.dart';
import 'cloud_sync_models.dart';

/// Opaque request to the native attachment downloader.
///
/// It contains only authenticated journal metadata and a protected raw-record
/// capability. It deliberately has no CloudKit record ID, PCS key, MMCS asset
/// descriptor, authorization token, or final native cache path. The private
/// application-support root is reused to open the account-bound native store.
/// The separate app-documents root is the existing trusted attachment root;
/// Android does not guarantee these two path-provider locations are equal.
final class CloudAttachmentBodyNativeRequest {
  const CloudAttachmentBodyNativeRequest({
    required this.authSnapshot,
    required this.nativeWriterPauseToken,
    required this.storageDirectory,
    required this.applicationDocumentsDirectory,
    required this.source,
    required this.logicalEntityKeyHash,
    required this.expectedCanonicalGuidSha256,
    required this.expectedBytes,
  });

  final CloudSyncNativeAuthSnapshot authSnapshot;
  final BigInt nativeWriterPauseToken;
  final String storageDirectory;
  final String applicationDocumentsDirectory;
  final CloudInboxEntry source;
  final String logicalEntityKeyHash;
  final String expectedCanonicalGuidSha256;
  final int expectedBytes;
}

enum CloudAttachmentBodyNativeFailure {
  invalidRequest,
  readAuthenticationScope,
  activeAccountMismatch,
  storeIdentityMismatch,
  protectedReferenceMismatch,
  sourceUnusable,
  pcsUnavailable,
  retryableUpstream,
  localStorage,
  sizeMismatch,
  integrityMismatch,
  decoderFailure,
}

/// Content-free result from native Rust. A completed result conveys only an
/// exact byte count after Rust has atomically placed its private cache file.
final class CloudAttachmentBodyNativeResult {
  const CloudAttachmentBodyNativeResult.completed(int verifiedBytes)
    : this._(true, verifiedBytes, null);

  const CloudAttachmentBodyNativeResult.failed(
    CloudAttachmentBodyNativeFailure failure,
  ) : this._(false, 0, failure);

  const CloudAttachmentBodyNativeResult._(
    this.completed,
    this.verifiedBytes,
    this.failure,
  ) : assert(
        (completed && verifiedBytes >= 0 && failure == null) ||
            (!completed && verifiedBytes == 0 && failure != null),
      );

  final bool completed;
  final int verifiedBytes;
  final CloudAttachmentBodyNativeFailure? failure;
}

abstract interface class CloudAttachmentBodyNativeBindings {
  Future<CloudAttachmentBodyNativeResult> materialize(
    CloudAttachmentBodyNativeRequest request,
  );
}

final class CloudAttachmentBodyMaterializationResult {
  const CloudAttachmentBodyMaterializationResult({
    required this.verifiedBytes,
    required this.alreadyReferenced,
  });

  final int verifiedBytes;
  final bool alreadyReferenced;
}

/// Coordinates durable state around one native, download-only body transfer.
///
/// Rust verifies the body in its private cache and then links it into the
/// existing app-documents attachment path. This class never receives either
/// final path.
final class CloudAttachmentBodyMaterializer {
  CloudAttachmentBodyMaterializer({
    required CloudAttachmentMaterializationStore store,
    required CloudAttachmentBodyNativeBindings nativeBindings,
    required CloudSyncNativeAuthSnapshotReader readAuthSnapshot,
    DateTime Function()? clock,
  }) : this._(store, nativeBindings, readAuthSnapshot, clock ?? DateTime.now);

  CloudAttachmentBodyMaterializer._(
    this._store,
    this._nativeBindings,
    this._readAuthSnapshot,
    this._clock,
  );

  static const int _maximumCasAttempts = 4;
  static final RegExp _canonicalHash = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _sha256Hash = RegExp(r'^[0-9a-f]{64}$');

  final CloudAttachmentMaterializationStore _store;
  final CloudAttachmentBodyNativeBindings _nativeBindings;
  final CloudSyncNativeAuthSnapshotReader _readAuthSnapshot;
  final DateTime Function() _clock;

  Future<CloudAttachmentBodyMaterializationResult> materialize({
    required CloudSyncNativeAuthSnapshot authSnapshot,
    required BigInt nativeWriterPauseToken,
    required String storageDirectory,
    required String applicationDocumentsDirectory,
    required CloudInboxEntry source,
    required String logicalEntityKeyHash,
    required String expectedCanonicalGuidSha256,
    required int expectedBytes,
  }) async {
    _validateInput(
      authSnapshot: authSnapshot,
      nativeWriterPauseToken: nativeWriterPauseToken,
      storageDirectory: storageDirectory,
      applicationDocumentsDirectory: applicationDocumentsDirectory,
      source: source,
      logicalEntityKeyHash: logicalEntityKeyHash,
      expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
      expectedBytes: expectedBytes,
    );

    final expectedIntegrityTagHash = _integrityTagHash(
      source: source,
      logicalEntityKeyHash: logicalEntityKeyHash,
      expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
      expectedBytes: expectedBytes,
    );
    CloudAttachmentMaterialization state = await _loadOrCreate(
      source: source,
      logicalEntityKeyHash: logicalEntityKeyHash,
      expectedBytes: expectedBytes,
      expectedIntegrityTagHash: expectedIntegrityTagHash,
    );
    final alreadyReferenced =
        state.stage == CloudAttachmentMaterializationStage.referenced;

    state = await _ensureStreaming(
      state,
      source.change.encryptedPayloadReference!,
    );
    final nativeResult = await _nativeBindings.materialize(
      CloudAttachmentBodyNativeRequest(
        authSnapshot: authSnapshot,
        nativeWriterPauseToken: nativeWriterPauseToken,
        storageDirectory: storageDirectory,
        applicationDocumentsDirectory: applicationDocumentsDirectory,
        source: source,
        logicalEntityKeyHash: logicalEntityKeyHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: expectedBytes,
      ),
    );
    if (nativeResult.completed != (nativeResult.failure == null) ||
        (!nativeResult.completed && nativeResult.verifiedBytes != 0)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'cloud_attachment_native_result_invalid',
      );
    }
    if (!nativeResult.completed) {
      throw _nativeFailure(nativeResult.failure!);
    }
    if (nativeResult.verifiedBytes != expectedBytes) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'cloud_attachment_size_mismatch',
      );
    }

    // Native already rechecks the same account and protected store identity.
    // Recheck the application snapshot before committing a local completion so
    // a logout/account change cannot make a finished transfer look reusable.
    final currentAuth = await _readAuthSnapshot();
    if (!authSnapshot.sameIdentity(currentAuth)) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.authorization,
        safeCode: 'cloud_attachment_account_changed',
      );
    }

    state = await _advanceToReferenced(
      state,
      source.change.encryptedPayloadReference!,
    );
    return CloudAttachmentBodyMaterializationResult(
      verifiedBytes: state.verifiedBytes,
      alreadyReferenced: alreadyReferenced,
    );
  }

  Future<CloudAttachmentMaterialization> _loadOrCreate({
    required CloudInboxEntry source,
    required String logicalEntityKeyHash,
    required int expectedBytes,
    required String expectedIntegrityTagHash,
  }) async {
    for (var attempt = 0; attempt < _maximumCasAttempts; attempt++) {
      final existing = await _store.read(
        scope: source.scope,
        generation: source.generation,
        logicalEntityKeyHash: logicalEntityKeyHash,
      );
      if (existing != null) {
        if (existing.expectedBytes != expectedBytes ||
            existing.expectedIntegrityTagHash != expectedIntegrityTagHash) {
          throw CloudSyncFailure(
            category: CloudFailureCategory.conflict,
            safeCode: 'cloud_attachment_source_conflict',
          );
        }
        _requireSourceProvenance(
          existing,
          source.change.encryptedPayloadReference!,
        );
        return existing;
      }
      final initial = CloudAttachmentMaterialization.metadata(
        scope: source.scope,
        generation: source.generation,
        logicalEntityKeyHash: logicalEntityKeyHash,
        expectedBytes: expectedBytes,
        expectedIntegrityTagHash: expectedIntegrityTagHash,
        updatedAt: _clock().toUtc(),
      );
      if (await _store.create(initial)) return initial;
    }
    throw CloudSyncFailure(
      category: CloudFailureCategory.conflict,
      safeCode: 'cloud_attachment_state_contention',
    );
  }

  Future<CloudAttachmentMaterialization> _ensureStreaming(
    CloudAttachmentMaterialization state,
    String protectedSourceReference,
  ) async {
    if (state.stage != CloudAttachmentMaterializationStage.metadataReady) {
      _requireSourceProvenance(state, protectedSourceReference);
      return state;
    }
    final streaming = await _compareAndSwapUntilApplied(
      state,
      (current) => current.beginStreaming(
        activeGeneration: current.generation,
        protectedTempReference: protectedSourceReference,
        protectedResumeManifestReference: protectedSourceReference,
        now: _clock().toUtc(),
      ),
    );
    _requireSourceProvenance(streaming, protectedSourceReference);
    return streaming;
  }

  Future<CloudAttachmentMaterialization> _advanceToReferenced(
    CloudAttachmentMaterialization state,
    String protectedSourceReference,
  ) async {
    var current = state;
    if (current.stage == CloudAttachmentMaterializationStage.tempStreaming) {
      current = await _compareAndSwapUntilApplied(
        current,
        (value) => value.recordVerifiedBoundary(
          activeGeneration: value.generation,
          cumulativeVerifiedBytes: value.expectedBytes,
          protectedResumeManifestReference: protectedSourceReference,
          now: _clock().toUtc(),
        ),
      );
    }
    if (current.stage == CloudAttachmentMaterializationStage.tempStreaming) {
      current = await _compareAndSwapUntilApplied(
        current,
        (value) => value.markContentVerified(
          activeGeneration: value.generation,
          protectedContentVerificationReference: protectedSourceReference,
          now: _clock().toUtc(),
        ),
      );
    }
    if (current.stage == CloudAttachmentMaterializationStage.contentVerified) {
      current = await _compareAndSwapUntilApplied(
        current,
        (value) => value.markFilePlaced(
          activeGeneration: value.generation,
          protectedFinalReference: protectedSourceReference,
          now: _clock().toUtc(),
        ),
      );
    }
    if (current.stage == CloudAttachmentMaterializationStage.filePlaced) {
      current = await _compareAndSwapUntilApplied(
        current,
        (value) => value.markReferenced(
          activeGeneration: value.generation,
          now: _clock().toUtc(),
        ),
      );
    }
    if (current.stage != CloudAttachmentMaterializationStage.referenced) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'cloud_attachment_state_contention',
      );
    }
    _requireSourceProvenance(current, protectedSourceReference);
    return current;
  }

  Future<CloudAttachmentMaterialization> _compareAndSwapUntilApplied(
    CloudAttachmentMaterialization state,
    CloudAttachmentMaterialization Function(CloudAttachmentMaterialization)
    transition,
  ) async {
    var current = state;
    for (var attempt = 0; attempt < _maximumCasAttempts; attempt++) {
      final next = transition(current);
      if (await _store.compareAndSwap(expected: current, next: next)) {
        return next;
      }
      final reread = await _store.read(
        scope: current.scope,
        generation: current.generation,
        logicalEntityKeyHash: current.logicalEntityKeyHash,
      );
      if (reread == null ||
          reread.expectedBytes != current.expectedBytes ||
          reread.expectedIntegrityTagHash != current.expectedIntegrityTagHash) {
        throw CloudSyncFailure(
          category: CloudFailureCategory.conflict,
          safeCode: 'cloud_attachment_source_conflict',
        );
      }
      current = reread;
      if (current.stage.index >= transition(state).stage.index) return current;
    }
    throw CloudSyncFailure(
      category: CloudFailureCategory.conflict,
      safeCode: 'cloud_attachment_state_contention',
    );
  }

  void _validateInput({
    required CloudSyncNativeAuthSnapshot authSnapshot,
    required BigInt nativeWriterPauseToken,
    required String storageDirectory,
    required String applicationDocumentsDirectory,
    required CloudInboxEntry source,
    required String logicalEntityKeyHash,
    required String expectedCanonicalGuidSha256,
    required int expectedBytes,
  }) {
    final change = source.change;
    if (nativeWriterPauseToken <= BigInt.zero ||
        nativeWriterPauseToken.bitLength > 64 ||
        storageDirectory.trim().isEmpty ||
        applicationDocumentsDirectory.trim().isEmpty ||
        !_canonicalHash.hasMatch(logicalEntityKeyHash) ||
        !_sha256Hash.hasMatch(expectedCanonicalGuidSha256) ||
        expectedBytes < 0 ||
        source.status != CloudInboxStatus.applied ||
        source.scope.persistenceLane != CloudSyncPersistenceLane.semanticV2 ||
        source.scope.accountFingerprint != authSnapshot.accountFingerprint ||
        source.scope.zone != 'attachmentManateeZone' ||
        change.type != CloudChangeType.save ||
        change.isTombstone ||
        change.preflightFailure != null ||
        change.etagHash == null ||
        change.payloadSha256 == null ||
        change.encryptedPayloadReference == null) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.malformedRecord,
        safeCode: 'cloud_attachment_source_invalid',
      );
    }
  }

  String _integrityTagHash({
    required CloudInboxEntry source,
    required String logicalEntityKeyHash,
    required String expectedCanonicalGuidSha256,
    required int expectedBytes,
  }) => sha256
      .convert(
        utf8.encode(
          'cloud-attachment-v2\u001f${source.scope.storageKey}\u001f${source.generation}\u001f${source.change.changeId}\u001f${source.change.recordIdHash}\u001f${source.change.etagHash ?? ''}\u001f${source.change.payloadSha256}\u001f${source.change.encryptedPayloadReference}\u001f$logicalEntityKeyHash\u001f$expectedCanonicalGuidSha256\u001f$expectedBytes',
        ),
      )
      .toString();

  void _requireSourceProvenance(
    CloudAttachmentMaterialization state,
    String protectedSourceReference,
  ) {
    final references = <String?>[
      state.protectedTempReference,
      state.protectedResumeManifestReference,
      state.protectedContentVerificationReference,
      state.protectedFinalReference,
    ];
    if (references.any(
      (reference) => reference != null && reference != protectedSourceReference,
    )) {
      throw CloudSyncFailure(
        category: CloudFailureCategory.conflict,
        safeCode: 'cloud_attachment_source_conflict',
      );
    }
  }

  CloudSyncFailure _nativeFailure(CloudAttachmentBodyNativeFailure failure) {
    final (category, safeCode) = switch (failure) {
      CloudAttachmentBodyNativeFailure.invalidRequest ||
      CloudAttachmentBodyNativeFailure.sourceUnusable ||
      CloudAttachmentBodyNativeFailure.decoderFailure => (
        CloudFailureCategory.malformedRecord,
        'cloud_attachment_source_invalid',
      ),
      CloudAttachmentBodyNativeFailure.activeAccountMismatch ||
      CloudAttachmentBodyNativeFailure.readAuthenticationScope ||
      CloudAttachmentBodyNativeFailure.storeIdentityMismatch => (
        CloudFailureCategory.authorization,
        failure == CloudAttachmentBodyNativeFailure.readAuthenticationScope
            ? 'cloud_attachment_read_auth_scope_invalid'
            : 'cloud_attachment_account_changed',
      ),
      CloudAttachmentBodyNativeFailure.protectedReferenceMismatch ||
      CloudAttachmentBodyNativeFailure.integrityMismatch => (
        CloudFailureCategory.conflict,
        'cloud_attachment_integrity_mismatch',
      ),
      CloudAttachmentBodyNativeFailure.pcsUnavailable => (
        CloudFailureCategory.pcsUnavailable,
        'pcs-unavailable',
      ),
      CloudAttachmentBodyNativeFailure.retryableUpstream => (
        CloudFailureCategory.network,
        'network',
      ),
      CloudAttachmentBodyNativeFailure.localStorage => (
        CloudFailureCategory.localStorage,
        'local-storage',
      ),
      CloudAttachmentBodyNativeFailure.sizeMismatch => (
        CloudFailureCategory.malformedRecord,
        'cloud_attachment_size_mismatch',
      ),
    };
    return CloudSyncFailure(category: category, safeCode: safeCode);
  }
}
