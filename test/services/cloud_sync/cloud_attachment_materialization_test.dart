import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'attachmentManateeZone',
  );
  final now = DateTime.utc(2026, 8, 1);

  CloudAttachmentMaterialization metadata({int expectedBytes = 10}) =>
      CloudAttachmentMaterialization.metadata(
        scope: scope,
        generation: 4,
        logicalEntityKeyHash: 'attachment-key-hash',
        expectedBytes: expectedBytes,
        expectedIntegrityTagHash: 'integrity-tag-hash',
        updatedAt: now,
      );

  CloudAttachmentMaterialization streaming({int expectedBytes = 10}) =>
      metadata(expectedBytes: expectedBytes).beginStreaming(
        activeGeneration: 4,
        protectedTempReference: 'protected-temp',
        protectedResumeManifestReference: 'protected-manifest-0',
        now: now,
      );

  test('rejects generation zero before any durable state is created', () {
    expect(
      () => CloudAttachmentMaterialization.metadata(
        scope: scope,
        generation: 0,
        logicalEntityKeyHash: 'attachment-key-hash',
        expectedBytes: 10,
        expectedIntegrityTagHash: 'integrity-tag-hash',
        updatedAt: now,
      ),
      throwsA(isA<CloudAttachmentMaterializationFailure>()),
    );
  });

  test('advances only through verified placement and reference stages', () {
    final chunkOne = streaming().recordVerifiedBoundary(
      activeGeneration: 4,
      cumulativeVerifiedBytes: 4,
      protectedResumeManifestReference: 'protected-manifest-1',
      now: now,
    );
    final chunkTwo = chunkOne.recordVerifiedBoundary(
      activeGeneration: 4,
      cumulativeVerifiedBytes: 10,
      protectedResumeManifestReference: 'protected-manifest-2',
      now: now,
    );
    final verified = chunkTwo.markContentVerified(
      activeGeneration: 4,
      protectedContentVerificationReference: 'protected-verification',
      now: now,
    );
    final placed = verified.markFilePlaced(
      activeGeneration: 4,
      protectedFinalReference: 'protected-final',
      now: now,
    );
    final referenced = placed.markReferenced(activeGeneration: 4, now: now);

    expect(referenced.stage, CloudAttachmentMaterializationStage.referenced);
    expect(referenced.verifiedBytes, 10);
    expect(referenced.toString(), contains('redacted'));
    expect(referenced.toString(), isNot(contains('attachment-key-hash')));
  });

  test('cannot verify content before every expected byte is verified', () {
    final partial = streaming().recordVerifiedBoundary(
      activeGeneration: 4,
      cumulativeVerifiedBytes: 9,
      protectedResumeManifestReference: 'protected-manifest-1',
      now: now,
    );

    expect(
      () => partial.markContentVerified(
        activeGeneration: 4,
        protectedContentVerificationReference: 'protected-verification',
        now: now,
      ),
      throwsA(
        isA<CloudAttachmentMaterializationFailure>().having(
          (error) => error.code,
          'code',
          CloudAttachmentMaterializationFailureCode.sizeMismatch,
        ),
      ),
    );
  });

  test('verified offsets are contiguous monotonic boundaries', () {
    final first = streaming().recordVerifiedBoundary(
      activeGeneration: 4,
      cumulativeVerifiedBytes: 6,
      protectedResumeManifestReference: 'protected-manifest-1',
      now: now,
    );

    expect(
      () => first.recordVerifiedBoundary(
        activeGeneration: 4,
        cumulativeVerifiedBytes: 5,
        protectedResumeManifestReference: 'protected-manifest-2',
        now: now,
      ),
      throwsA(
        isA<CloudAttachmentMaterializationFailure>().having(
          (error) => error.code,
          'code',
          CloudAttachmentMaterializationFailureCode.invalidBoundary,
        ),
      ),
    );
  });

  test('idempotent repeats require exactly the same protected reference', () {
    final first = streaming().recordVerifiedBoundary(
      activeGeneration: 4,
      cumulativeVerifiedBytes: 6,
      protectedResumeManifestReference: 'protected-manifest-1',
      now: now,
    );

    expect(
      first.recordVerifiedBoundary(
        activeGeneration: 4,
        cumulativeVerifiedBytes: 6,
        protectedResumeManifestReference: 'protected-manifest-1',
        now: now,
      ),
      same(first),
    );
    expect(
      () => first.recordVerifiedBoundary(
        activeGeneration: 4,
        cumulativeVerifiedBytes: 6,
        protectedResumeManifestReference: 'different-manifest',
        now: now,
      ),
      throwsA(isA<CloudAttachmentMaterializationFailure>()),
    );
  });

  test('crash tail is truncated to the last verified boundary', () {
    final partial = streaming().recordVerifiedBoundary(
      activeGeneration: 4,
      cumulativeVerifiedBytes: 6,
      protectedResumeManifestReference: 'protected-manifest-1',
      now: now,
    );
    final plan = partial.recoveryPlan(
      activeGeneration: 4,
      temporaryFileBytes: 8,
      finalFileExists: false,
    );

    expect(
      plan.action,
      CloudAttachmentRecoveryAction.resumeFromVerifiedBoundary,
    );
    expect(plan.resumeOffset, 6);
    expect(plan.truncateTempToBytes, 6);
  });

  test('missing verified prefix restarts instead of trusting a short file', () {
    final partial = streaming().recordVerifiedBoundary(
      activeGeneration: 4,
      cumulativeVerifiedBytes: 6,
      protectedResumeManifestReference: 'protected-manifest-1',
      now: now,
    );
    final plan = partial.recoveryPlan(
      activeGeneration: 4,
      temporaryFileBytes: 5,
      finalFileExists: false,
    );

    expect(plan.action, CloudAttachmentRecoveryAction.startFromZero);
    expect(plan.resumeOffset, 0);
    expect(plan.truncateTempToBytes, 0);
  });

  test('placed file is referenced only after filesystem confirmation', () {
    final placed = streaming(expectedBytes: 0)
        .markContentVerified(
          activeGeneration: 4,
          protectedContentVerificationReference: 'protected-verification',
          now: now,
        )
        .markFilePlaced(
          activeGeneration: 4,
          protectedFinalReference: 'protected-final',
          now: now,
        );

    final missingPlan = placed.recoveryPlan(
      activeGeneration: 4,
      temporaryFileBytes: 0,
      finalFileExists: false,
    );
    final presentPlan = placed.recoveryPlan(
      activeGeneration: 4,
      temporaryFileBytes: null,
      finalFileExists: true,
    );

    expect(missingPlan.action, CloudAttachmentRecoveryAction.verifyThenPlace);
    expect(
      presentPlan.action,
      CloudAttachmentRecoveryAction.referencePlacedFile,
    );
  });

  test('generation mismatch fails every recovery or transition closed', () {
    final state = streaming();

    expect(
      () => state.recoveryPlan(
        activeGeneration: 5,
        temporaryFileBytes: 0,
        finalFileExists: false,
      ),
      throwsA(
        isA<CloudAttachmentMaterializationFailure>().having(
          (error) => error.code,
          'code',
          CloudAttachmentMaterializationFailureCode.generationMismatch,
        ),
      ),
    );
  });
}
