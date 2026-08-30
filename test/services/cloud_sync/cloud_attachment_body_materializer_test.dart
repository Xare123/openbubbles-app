import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_body_materializer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_materialization_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  final scope = CloudSyncScope(
    accountFingerprint: testAccountFingerprintA,
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'attachmentManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semanticV2,
  );
  final source = _source(scope);
  final auth = _auth();
  final pauseToken = BigInt.from(7);
  const logicalHash = 'LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL';
  const expectedCanonicalGuidSha256 =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test(
    'native success advances only through the durable materialization states',
    () async {
      final store = _MemoryStore();
      final native = _Native(
        const CloudAttachmentBodyNativeResult.completed(12),
      );
      final materializer = _materializer(
        store: store,
        native: native,
        readAuth: () async => auth,
      );

      final result = await materializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: 'C:/private-storage',
        applicationDocumentsDirectory: 'C:/private-documents',
        source: source,
        logicalEntityKeyHash: logicalHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: 12,
      );

      expect(result.verifiedBytes, 12);
      expect(result.alreadyReferenced, isFalse);
      expect(native.calls, 1);
      expect(native.lastRequest!.nativeWriterPauseToken, pauseToken);
      expect(
        native.lastRequest!.applicationDocumentsDirectory,
        'C:/private-documents',
      );
      final state = store.onlyValue!;
      expect(state.stage, CloudAttachmentMaterializationStage.referenced);
      expect(state.verifiedBytes, 12);
      expect(
        state.protectedFinalReference,
        source.change.encryptedPayloadReference,
      );
    },
  );

  test(
    'rejects a non-applied attachment source without native access',
    () async {
      final store = _MemoryStore();
      final native = _Native(
        const CloudAttachmentBodyNativeResult.completed(12),
      );
      final materializer = _materializer(
        store: store,
        native: native,
        readAuth: () async => auth,
      );
      final pending = source.copyWith(status: CloudInboxStatus.pending);

      await expectLater(
        materializer.materialize(
          authSnapshot: auth,
          nativeWriterPauseToken: pauseToken,
          storageDirectory: 'C:/private-storage',
          applicationDocumentsDirectory: 'C:/private-documents',
          source: pending,
          logicalEntityKeyHash: logicalHash,
          expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
          expectedBytes: 12,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_attachment_source_invalid',
          ),
        ),
      );
      expect(native.calls, 0);
      expect(store.onlyValue, isNull);
    },
  );

  test('rejects a legacy sync lane without native access', () async {
    final store = _MemoryStore();
    final native = _Native(const CloudAttachmentBodyNativeResult.completed(12));
    final materializer = _materializer(
      store: store,
      native: native,
      readAuth: () async => auth,
    );
    final legacySource = _source(
      CloudSyncScope(
        accountFingerprint: testAccountFingerprintA,
        container: 'com.apple.messages.cloud',
        database: 'private',
        zone: 'attachmentManateeZone',
      ),
    );

    await expectLater(
      materializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: 'C:/private-storage',
        applicationDocumentsDirectory: 'C:/private-documents',
        source: legacySource,
        logicalEntityKeyHash: logicalHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: 12,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_attachment_source_invalid',
        ),
      ),
    );
    expect(native.calls, 0);
    expect(store.onlyValue, isNull);
  });

  test(
    'native size failure leaves the durable state at temp streaming',
    () async {
      final store = _MemoryStore();
      final native = _Native(
        const CloudAttachmentBodyNativeResult.failed(
          CloudAttachmentBodyNativeFailure.sizeMismatch,
        ),
      );
      final materializer = _materializer(
        store: store,
        native: native,
        readAuth: () async => auth,
      );

      await expectLater(
        materializer.materialize(
          authSnapshot: auth,
          nativeWriterPauseToken: pauseToken,
          storageDirectory: 'C:/private-storage',
          applicationDocumentsDirectory: 'C:/private-documents',
          source: source,
          logicalEntityKeyHash: logicalHash,
          expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
          expectedBytes: 12,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_attachment_size_mismatch',
          ),
        ),
      );
      expect(
        store.onlyValue!.stage,
        CloudAttachmentMaterializationStage.tempStreaming,
      );
      expect(store.onlyValue!.verifiedBytes, 0);
    },
  );

  test(
    'identity drift after native success cannot mark the body placed',
    () async {
      final store = _MemoryStore();
      final native = _Native(
        const CloudAttachmentBodyNativeResult.completed(12),
      );
      final changed = CloudSyncNativeAuthSnapshot.fromNative(
        nativeSessionId: 'new-session',
        accountFingerprint: testAccountFingerprintA,
        protectedStoreIdentity: testProtectedReference(
          'S',
        ).replaceFirst('obcs2.ref.', 'obcs2.store.'),
        cloudMessagesClient: Object(),
      );
      final materializer = _materializer(
        store: store,
        native: native,
        readAuth: () async => changed,
      );

      await expectLater(
        materializer.materialize(
          authSnapshot: auth,
          nativeWriterPauseToken: pauseToken,
          storageDirectory: 'C:/private-storage',
          applicationDocumentsDirectory: 'C:/private-documents',
          source: source,
          logicalEntityKeyHash: logicalHash,
          expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
          expectedBytes: 12,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_attachment_account_changed',
          ),
        ),
      );
      expect(
        store.onlyValue!.stage,
        CloudAttachmentMaterializationStage.tempStreaming,
      );
    },
  );

  test(
    'a transient compare-and-swap loss re-reads without downgrading state',
    () async {
      final store = _MemoryStore(failNextCompareAndSwap: true);
      final native = _Native(
        const CloudAttachmentBodyNativeResult.completed(12),
      );
      final materializer = _materializer(
        store: store,
        native: native,
        readAuth: () async => auth,
      );

      await materializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: 'C:/private-storage',
        applicationDocumentsDirectory: 'C:/private-documents',
        source: source,
        logicalEntityKeyHash: logicalHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: 12,
      );

      expect(
        store.onlyValue!.stage,
        CloudAttachmentMaterializationStage.referenced,
      );
      expect(store.compareAndSwapCalls, greaterThan(4));
    },
  );

  test('a raced state cannot substitute another protected source', () async {
    final store = _MemoryStore(
      failNextCompareAndSwap: true,
      replaceOnFailedCompareAndSwap: (expected) => expected.beginStreaming(
        activeGeneration: expected.generation,
        protectedTempReference: testProtectedReference('Q'),
        protectedResumeManifestReference: testProtectedReference('Q'),
        now: DateTime.utc(2026, 8, 29),
      ),
    );
    final native = _Native(const CloudAttachmentBodyNativeResult.completed(12));
    final materializer = _materializer(
      store: store,
      native: native,
      readAuth: () async => auth,
    );

    await expectLater(
      materializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: 'C:/private-storage',
        applicationDocumentsDirectory: 'C:/private-documents',
        source: source,
        logicalEntityKeyHash: logicalHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: 12,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_attachment_source_conflict',
        ),
      ),
    );
    expect(native.calls, 0);
  });

  test(
    'an already referenced body is reverified by native cache integrity',
    () async {
      final store = _MemoryStore();
      final native = _Native(
        const CloudAttachmentBodyNativeResult.completed(12),
      );
      final materializer = _materializer(
        store: store,
        native: native,
        readAuth: () async => auth,
      );
      await materializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: 'C:/private-storage',
        applicationDocumentsDirectory: 'C:/private-documents',
        source: source,
        logicalEntityKeyHash: logicalHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: 12,
      );
      final result = await materializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: 'C:/private-storage',
        applicationDocumentsDirectory: 'C:/private-documents',
        source: source,
        logicalEntityKeyHash: logicalHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: 12,
      );

      expect(result.alreadyReferenced, isTrue);
      expect(native.calls, 2);
    },
  );

  test('rejects a source without an etag fence before native access', () async {
    final store = _MemoryStore();
    final native = _Native(const CloudAttachmentBodyNativeResult.completed(12));
    final materializer = _materializer(
      store: store,
      native: native,
      readAuth: () async => auth,
    );
    final unfenced = _source(scope, includeEtag: false);

    await expectLater(
      materializer.materialize(
        authSnapshot: auth,
        nativeWriterPauseToken: pauseToken,
        storageDirectory: 'C:/private-storage',
        applicationDocumentsDirectory: 'C:/private-documents',
        source: unfenced,
        logicalEntityKeyHash: logicalHash,
        expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
        expectedBytes: 12,
      ),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'cloud_attachment_source_invalid',
        ),
      ),
    );
    expect(native.calls, 0);
  });

  test(
    'rejects a missing native writer-pause token before native access',
    () async {
      final store = _MemoryStore();
      final native = _Native(
        const CloudAttachmentBodyNativeResult.completed(12),
      );
      final materializer = _materializer(
        store: store,
        native: native,
        readAuth: () async => auth,
      );

      await expectLater(
        materializer.materialize(
          authSnapshot: auth,
          nativeWriterPauseToken: BigInt.zero,
          storageDirectory: 'C:/private-storage',
          applicationDocumentsDirectory: 'C:/private-documents',
          source: source,
          logicalEntityKeyHash: logicalHash,
          expectedCanonicalGuidSha256: expectedCanonicalGuidSha256,
          expectedBytes: 12,
        ),
        throwsA(
          isA<CloudSyncFailure>().having(
            (failure) => failure.safeCode,
            'safeCode',
            'cloud_attachment_source_invalid',
          ),
        ),
      );
      expect(native.calls, 0);
    },
  );
}

CloudAttachmentBodyMaterializer _materializer({
  required _MemoryStore store,
  required _Native native,
  required CloudSyncNativeAuthSnapshotReader readAuth,
}) => CloudAttachmentBodyMaterializer(
  store: store,
  nativeBindings: native,
  readAuthSnapshot: readAuth,
  clock: () => DateTime.utc(2026, 8, 29),
);

CloudInboxEntry _source(CloudSyncScope scope, {bool includeEtag = true}) =>
    CloudInboxEntry(
      scope: scope,
      sequence: 1,
      generation: 4,
      status: CloudInboxStatus.applied,
      attemptCount: 0,
      createdAt: testEpoch,
      batchId: 'batch-attachment',
      change: CloudFetchedChange(
        changeId: List.filled(43, 'C').join(),
        recordIdHash: List.filled(43, 'R').join(),
        etagHash: includeEtag ? List.filled(43, 'E').join() : null,
        type: CloudChangeType.save,
        encryptedPayloadReference: testProtectedReference('P'),
        payloadSha256: testSha256('a'),
      ),
    );

CloudSyncNativeAuthSnapshot _auth() => CloudSyncNativeAuthSnapshot.fromNative(
  nativeSessionId: 'stable-session',
  accountFingerprint: testAccountFingerprintA,
  protectedStoreIdentity: testProtectedReference(
    'S',
  ).replaceFirst('obcs2.ref.', 'obcs2.store.'),
  cloudMessagesClient: Object(),
);

final class _Native implements CloudAttachmentBodyNativeBindings {
  _Native(this.result);

  final CloudAttachmentBodyNativeResult result;
  int calls = 0;
  CloudAttachmentBodyNativeRequest? lastRequest;

  @override
  Future<CloudAttachmentBodyNativeResult> materialize(
    CloudAttachmentBodyNativeRequest request,
  ) async {
    calls += 1;
    lastRequest = request;
    return result;
  }
}

final class _MemoryStore implements CloudAttachmentMaterializationStore {
  _MemoryStore({
    this.failNextCompareAndSwap = false,
    this.replaceOnFailedCompareAndSwap,
  });

  CloudAttachmentMaterialization? onlyValue;
  bool failNextCompareAndSwap;
  final CloudAttachmentMaterialization Function(
    CloudAttachmentMaterialization expected,
  )?
  replaceOnFailedCompareAndSwap;
  int compareAndSwapCalls = 0;

  @override
  Future<bool> compareAndSwap({
    required CloudAttachmentMaterialization expected,
    required CloudAttachmentMaterialization next,
  }) async {
    compareAndSwapCalls += 1;
    if (failNextCompareAndSwap) {
      failNextCompareAndSwap = false;
      onlyValue = replaceOnFailedCompareAndSwap?.call(expected) ?? onlyValue;
      return false;
    }
    if (!_same(onlyValue, expected)) return false;
    onlyValue = next;
    return true;
  }

  @override
  Future<bool> create(CloudAttachmentMaterialization initial) async {
    if (onlyValue != null) return false;
    onlyValue = initial;
    return true;
  }

  @override
  Future<CloudAttachmentMaterialization?> read({
    required CloudSyncScope scope,
    required int generation,
    required String logicalEntityKeyHash,
  }) async =>
      onlyValue?.scope == scope &&
          onlyValue?.generation == generation &&
          onlyValue?.logicalEntityKeyHash == logicalEntityKeyHash
      ? onlyValue
      : null;

  bool _same(
    CloudAttachmentMaterialization? left,
    CloudAttachmentMaterialization right,
  ) =>
      left?.scope == right.scope &&
      left?.generation == right.generation &&
      left?.logicalEntityKeyHash == right.logicalEntityKeyHash &&
      left?.expectedBytes == right.expectedBytes &&
      left?.expectedIntegrityTagHash == right.expectedIntegrityTagHash &&
      left?.stage == right.stage &&
      left?.verifiedBytes == right.verifiedBytes &&
      left?.protectedTempReference == right.protectedTempReference &&
      left?.protectedResumeManifestReference ==
          right.protectedResumeManifestReference &&
      left?.protectedContentVerificationReference ==
          right.protectedContentVerificationReference &&
      left?.protectedFinalReference == right.protectedFinalReference &&
      left?.updatedAt == right.updatedAt;
}
