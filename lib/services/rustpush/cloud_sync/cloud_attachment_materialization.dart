import 'cloud_sync_models.dart';

enum CloudAttachmentMaterializationStage {
  metadataReady,
  tempStreaming,
  contentVerified,
  filePlaced,
  referenced,
}

enum CloudAttachmentRecoveryAction {
  startFromZero,
  resumeFromVerifiedBoundary,
  verifyThenPlace,
  referencePlacedFile,
  complete,
}

enum CloudAttachmentMaterializationFailureCode {
  invalidTransition,
  invalidBoundary,
  sizeMismatch,
  generationMismatch,
  protectedReferenceMismatch,
}

/// Typed, content-free attachment state failure.
///
/// It deliberately exposes only an allowlisted code. Paths, CloudKit record
/// identifiers, MMCS tokens, signatures, and attachment names must not enter
/// diagnostics through this exception.
final class CloudAttachmentMaterializationFailure implements Exception {
  const CloudAttachmentMaterializationFailure(this.code);

  final CloudAttachmentMaterializationFailureCode code;

  @override
  String toString() =>
      'CloudAttachmentMaterializationFailure(${code.name}, redacted)';
}

/// Restart plan derived without touching the filesystem.
///
/// The caller must validate or truncate the actual temporary file before
/// resuming. A verified byte offset is useful only together with the protected
/// native resume manifest referenced by the snapshot.
final class CloudAttachmentRecoveryPlan {
  const CloudAttachmentRecoveryPlan({
    required this.action,
    required this.resumeOffset,
    this.truncateTempToBytes,
  });

  final CloudAttachmentRecoveryAction action;
  final int resumeOffset;
  final int? truncateTempToBytes;
}

/// Durable, content-free state for one incoming Cloud Sync attachment.
///
/// Raw filesystem paths and native MMCS metadata are represented only by
/// protected references. The verified prefix is always contiguous, so a crash
/// can resume from a complete native-verified chunk boundary without trusting
/// an arbitrary partial tail.
final class CloudAttachmentMaterialization {
  CloudAttachmentMaterialization.metadata({
    required this.scope,
    required this.generation,
    required this.logicalEntityKeyHash,
    required this.expectedBytes,
    required this.expectedIntegrityTagHash,
    required this.updatedAt,
  }) : stage = CloudAttachmentMaterializationStage.metadataReady,
       verifiedBytes = 0,
       protectedTempReference = null,
       protectedResumeManifestReference = null,
       protectedContentVerificationReference = null,
       protectedFinalReference = null {
    _validateBase();
  }

  factory CloudAttachmentMaterialization.restore({
    required CloudSyncScope scope,
    required int generation,
    required String logicalEntityKeyHash,
    required int expectedBytes,
    required String expectedIntegrityTagHash,
    required CloudAttachmentMaterializationStage stage,
    required int verifiedBytes,
    required DateTime updatedAt,
    String? protectedTempReference,
    String? protectedResumeManifestReference,
    String? protectedContentVerificationReference,
    String? protectedFinalReference,
  }) {
    final value = CloudAttachmentMaterialization._(
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: logicalEntityKeyHash,
      expectedBytes: expectedBytes,
      expectedIntegrityTagHash: expectedIntegrityTagHash,
      stage: stage,
      verifiedBytes: verifiedBytes,
      protectedTempReference: protectedTempReference,
      protectedResumeManifestReference: protectedResumeManifestReference,
      protectedContentVerificationReference:
          protectedContentVerificationReference,
      protectedFinalReference: protectedFinalReference,
      updatedAt: updatedAt,
    );
    value._validateRestored();
    return value;
  }

  const CloudAttachmentMaterialization._({
    required this.scope,
    required this.generation,
    required this.logicalEntityKeyHash,
    required this.expectedBytes,
    required this.expectedIntegrityTagHash,
    required this.stage,
    required this.verifiedBytes,
    required this.updatedAt,
    this.protectedTempReference,
    this.protectedResumeManifestReference,
    this.protectedContentVerificationReference,
    this.protectedFinalReference,
  });

  final CloudSyncScope scope;
  final int generation;
  final String logicalEntityKeyHash;
  final int expectedBytes;

  /// Keyed digest of the native integrity tag, never the MMCS signature itself.
  final String expectedIntegrityTagHash;
  final CloudAttachmentMaterializationStage stage;

  /// Contiguous bytes verified by native MMCS chunk validation.
  final int verifiedBytes;
  final String? protectedTempReference;
  final String? protectedResumeManifestReference;
  final String? protectedContentVerificationReference;
  final String? protectedFinalReference;
  final DateTime updatedAt;

  CloudAttachmentMaterialization beginStreaming({
    required int activeGeneration,
    required String protectedTempReference,
    required String protectedResumeManifestReference,
    required DateTime now,
  }) {
    _requireGeneration(activeGeneration);
    _requireProtectedReference(protectedTempReference);
    _requireProtectedReference(protectedResumeManifestReference);
    if (stage == CloudAttachmentMaterializationStage.tempStreaming) {
      if (this.protectedTempReference == protectedTempReference &&
          this.protectedResumeManifestReference ==
              protectedResumeManifestReference &&
          verifiedBytes == 0) {
        return this;
      }
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.protectedReferenceMismatch,
      );
    }
    _requireStage(CloudAttachmentMaterializationStage.metadataReady);
    return _copy(
      stage: CloudAttachmentMaterializationStage.tempStreaming,
      protectedTempReference: protectedTempReference,
      protectedResumeManifestReference: protectedResumeManifestReference,
      updatedAt: now,
    );
  }

  CloudAttachmentMaterialization recordVerifiedBoundary({
    required int activeGeneration,
    required int cumulativeVerifiedBytes,
    required String protectedResumeManifestReference,
    required DateTime now,
  }) {
    _requireGeneration(activeGeneration);
    _requireStage(CloudAttachmentMaterializationStage.tempStreaming);
    _requireProtectedReference(protectedResumeManifestReference);
    if (cumulativeVerifiedBytes == verifiedBytes) {
      if (this.protectedResumeManifestReference ==
          protectedResumeManifestReference) {
        return this;
      }
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.protectedReferenceMismatch,
      );
    }
    if (cumulativeVerifiedBytes <= verifiedBytes ||
        cumulativeVerifiedBytes > expectedBytes) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.invalidBoundary,
      );
    }
    return _copy(
      verifiedBytes: cumulativeVerifiedBytes,
      protectedResumeManifestReference: protectedResumeManifestReference,
      updatedAt: now,
    );
  }

  CloudAttachmentMaterialization markContentVerified({
    required int activeGeneration,
    required String protectedContentVerificationReference,
    required DateTime now,
  }) {
    _requireGeneration(activeGeneration);
    _requireProtectedReference(protectedContentVerificationReference);
    if (stage == CloudAttachmentMaterializationStage.contentVerified) {
      if (this.protectedContentVerificationReference ==
          protectedContentVerificationReference) {
        return this;
      }
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.protectedReferenceMismatch,
      );
    }
    _requireStage(CloudAttachmentMaterializationStage.tempStreaming);
    if (verifiedBytes != expectedBytes) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.sizeMismatch,
      );
    }
    return _copy(
      stage: CloudAttachmentMaterializationStage.contentVerified,
      protectedContentVerificationReference:
          protectedContentVerificationReference,
      updatedAt: now,
    );
  }

  CloudAttachmentMaterialization markFilePlaced({
    required int activeGeneration,
    required String protectedFinalReference,
    required DateTime now,
  }) {
    _requireGeneration(activeGeneration);
    _requireProtectedReference(protectedFinalReference);
    if (stage == CloudAttachmentMaterializationStage.filePlaced) {
      if (this.protectedFinalReference == protectedFinalReference) return this;
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.protectedReferenceMismatch,
      );
    }
    _requireStage(CloudAttachmentMaterializationStage.contentVerified);
    return _copy(
      stage: CloudAttachmentMaterializationStage.filePlaced,
      protectedFinalReference: protectedFinalReference,
      updatedAt: now,
    );
  }

  CloudAttachmentMaterialization markReferenced({
    required int activeGeneration,
    required DateTime now,
  }) {
    _requireGeneration(activeGeneration);
    if (stage == CloudAttachmentMaterializationStage.referenced) return this;
    _requireStage(CloudAttachmentMaterializationStage.filePlaced);
    return _copy(
      stage: CloudAttachmentMaterializationStage.referenced,
      updatedAt: now,
    );
  }

  CloudAttachmentRecoveryPlan recoveryPlan({
    required int activeGeneration,
    required int? temporaryFileBytes,
    required bool finalFileExists,
  }) {
    _requireGeneration(activeGeneration);
    if (temporaryFileBytes != null && temporaryFileBytes < 0) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.sizeMismatch,
      );
    }
    return switch (stage) {
      CloudAttachmentMaterializationStage.metadataReady =>
        const CloudAttachmentRecoveryPlan(
          action: CloudAttachmentRecoveryAction.startFromZero,
          resumeOffset: 0,
        ),
      CloudAttachmentMaterializationStage.tempStreaming => _streamingRecovery(
        temporaryFileBytes,
      ),
      CloudAttachmentMaterializationStage.contentVerified =>
        temporaryFileBytes == expectedBytes
            ? CloudAttachmentRecoveryPlan(
                action: CloudAttachmentRecoveryAction.verifyThenPlace,
                resumeOffset: expectedBytes,
              )
            : const CloudAttachmentRecoveryPlan(
                action: CloudAttachmentRecoveryAction.startFromZero,
                resumeOffset: 0,
                truncateTempToBytes: 0,
              ),
      CloudAttachmentMaterializationStage.filePlaced =>
        finalFileExists
            ? CloudAttachmentRecoveryPlan(
                action: CloudAttachmentRecoveryAction.referencePlacedFile,
                resumeOffset: expectedBytes,
              )
            : temporaryFileBytes == expectedBytes
            ? CloudAttachmentRecoveryPlan(
                action: CloudAttachmentRecoveryAction.verifyThenPlace,
                resumeOffset: expectedBytes,
              )
            : const CloudAttachmentRecoveryPlan(
                action: CloudAttachmentRecoveryAction.startFromZero,
                resumeOffset: 0,
                truncateTempToBytes: 0,
              ),
      CloudAttachmentMaterializationStage.referenced =>
        CloudAttachmentRecoveryPlan(
          action: CloudAttachmentRecoveryAction.complete,
          resumeOffset: expectedBytes,
        ),
    };
  }

  CloudAttachmentRecoveryPlan _streamingRecovery(int? temporaryFileBytes) {
    if (temporaryFileBytes == null || temporaryFileBytes < verifiedBytes) {
      return const CloudAttachmentRecoveryPlan(
        action: CloudAttachmentRecoveryAction.startFromZero,
        resumeOffset: 0,
        truncateTempToBytes: 0,
      );
    }
    return CloudAttachmentRecoveryPlan(
      action: CloudAttachmentRecoveryAction.resumeFromVerifiedBoundary,
      resumeOffset: verifiedBytes,
      truncateTempToBytes: temporaryFileBytes == verifiedBytes
          ? null
          : verifiedBytes,
    );
  }

  CloudAttachmentMaterialization _copy({
    CloudAttachmentMaterializationStage? stage,
    int? verifiedBytes,
    String? protectedTempReference,
    String? protectedResumeManifestReference,
    String? protectedContentVerificationReference,
    String? protectedFinalReference,
    required DateTime updatedAt,
  }) {
    return CloudAttachmentMaterialization._(
      scope: scope,
      generation: generation,
      logicalEntityKeyHash: logicalEntityKeyHash,
      expectedBytes: expectedBytes,
      expectedIntegrityTagHash: expectedIntegrityTagHash,
      stage: stage ?? this.stage,
      verifiedBytes: verifiedBytes ?? this.verifiedBytes,
      protectedTempReference:
          protectedTempReference ?? this.protectedTempReference,
      protectedResumeManifestReference:
          protectedResumeManifestReference ??
          this.protectedResumeManifestReference,
      protectedContentVerificationReference:
          protectedContentVerificationReference ??
          this.protectedContentVerificationReference,
      protectedFinalReference:
          protectedFinalReference ?? this.protectedFinalReference,
      updatedAt: updatedAt,
    );
  }

  void _validateBase() {
    if (generation <= 0 ||
        logicalEntityKeyHash.isEmpty ||
        expectedBytes < 0 ||
        expectedIntegrityTagHash.isEmpty) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.invalidTransition,
      );
    }
  }

  void _validateRestored() {
    _validateBase();
    if (verifiedBytes < 0 || verifiedBytes > expectedBytes) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.invalidBoundary,
      );
    }
    switch (stage) {
      case CloudAttachmentMaterializationStage.metadataReady:
        if (verifiedBytes != 0 ||
            protectedTempReference != null ||
            protectedResumeManifestReference != null ||
            protectedContentVerificationReference != null ||
            protectedFinalReference != null) {
          throw const CloudAttachmentMaterializationFailure(
            CloudAttachmentMaterializationFailureCode.invalidTransition,
          );
        }
      case CloudAttachmentMaterializationStage.tempStreaming:
        _requireProtectedReference(protectedTempReference ?? '');
        _requireProtectedReference(protectedResumeManifestReference ?? '');
        if (protectedContentVerificationReference != null ||
            protectedFinalReference != null) {
          throw const CloudAttachmentMaterializationFailure(
            CloudAttachmentMaterializationFailureCode.invalidTransition,
          );
        }
      case CloudAttachmentMaterializationStage.contentVerified:
        _requireProtectedReference(protectedTempReference ?? '');
        _requireProtectedReference(protectedResumeManifestReference ?? '');
        _requireProtectedReference(protectedContentVerificationReference ?? '');
        if (verifiedBytes != expectedBytes || protectedFinalReference != null) {
          throw const CloudAttachmentMaterializationFailure(
            CloudAttachmentMaterializationFailureCode.invalidTransition,
          );
        }
      case CloudAttachmentMaterializationStage.filePlaced:
      case CloudAttachmentMaterializationStage.referenced:
        _requireProtectedReference(protectedTempReference ?? '');
        _requireProtectedReference(protectedResumeManifestReference ?? '');
        _requireProtectedReference(protectedContentVerificationReference ?? '');
        _requireProtectedReference(protectedFinalReference ?? '');
        if (verifiedBytes != expectedBytes) {
          throw const CloudAttachmentMaterializationFailure(
            CloudAttachmentMaterializationFailureCode.invalidTransition,
          );
        }
    }
  }

  void _requireGeneration(int activeGeneration) {
    if (activeGeneration != generation) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.generationMismatch,
      );
    }
  }

  void _requireStage(CloudAttachmentMaterializationStage expected) {
    if (stage != expected) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.invalidTransition,
      );
    }
  }

  void _requireProtectedReference(String value) {
    if (value.trim().isEmpty) {
      throw const CloudAttachmentMaterializationFailure(
        CloudAttachmentMaterializationFailureCode.protectedReferenceMismatch,
      );
    }
  }

  @override
  String toString() =>
      'CloudAttachmentMaterialization(${stage.name}, redacted)';
}
