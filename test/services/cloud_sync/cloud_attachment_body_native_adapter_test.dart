import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_body_materializer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_body_native_adapter.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps every fixed native attachment failure without exception text', () {
    final expected =
        <
          frb_api.CloudSyncAttachmentMaterializationFailureCode,
          CloudAttachmentBodyNativeFailure
        >{
          frb_api.CloudSyncAttachmentMaterializationFailureCode.invalidRequest:
              CloudAttachmentBodyNativeFailure.invalidRequest,
          frb_api
                  .CloudSyncAttachmentMaterializationFailureCode
                  .readAuthenticationScope:
              CloudAttachmentBodyNativeFailure.readAuthenticationScope,
          frb_api
                  .CloudSyncAttachmentMaterializationFailureCode
                  .activeAccountMismatch:
              CloudAttachmentBodyNativeFailure.activeAccountMismatch,
          frb_api
                  .CloudSyncAttachmentMaterializationFailureCode
                  .storeIdentityMismatch:
              CloudAttachmentBodyNativeFailure.storeIdentityMismatch,
          frb_api
                  .CloudSyncAttachmentMaterializationFailureCode
                  .protectedReferenceMismatch:
              CloudAttachmentBodyNativeFailure.protectedReferenceMismatch,
          frb_api.CloudSyncAttachmentMaterializationFailureCode.sourceUnusable:
              CloudAttachmentBodyNativeFailure.sourceUnusable,
          frb_api.CloudSyncAttachmentMaterializationFailureCode.pcsUnavailable:
              CloudAttachmentBodyNativeFailure.pcsUnavailable,
          frb_api
                  .CloudSyncAttachmentMaterializationFailureCode
                  .retryableUpstream:
              CloudAttachmentBodyNativeFailure.retryableUpstream,
          frb_api.CloudSyncAttachmentMaterializationFailureCode.localStorage:
              CloudAttachmentBodyNativeFailure.localStorage,
          frb_api.CloudSyncAttachmentMaterializationFailureCode.sizeMismatch:
              CloudAttachmentBodyNativeFailure.sizeMismatch,
          frb_api
                  .CloudSyncAttachmentMaterializationFailureCode
                  .integrityMismatch:
              CloudAttachmentBodyNativeFailure.integrityMismatch,
          frb_api.CloudSyncAttachmentMaterializationFailureCode.decoderFailure:
              CloudAttachmentBodyNativeFailure.decoderFailure,
        };

    for (final entry in expected.entries) {
      final mapped = cloudAttachmentBodyNativeResultFromFrb(
        frb_api.CloudSyncAttachmentMaterializationResult(
          completed: false,
          verifiedBytes: BigInt.zero,
          failure: entry.key,
        ),
      );
      expect(mapped.completed, isFalse);
      expect(mapped.verifiedBytes, 0);
      expect(mapped.failure, entry.value);
    }
  });

  test('maps one completed verified-byte result', () {
    final mapped = cloudAttachmentBodyNativeResultFromFrb(
      frb_api.CloudSyncAttachmentMaterializationResult(
        completed: true,
        verifiedBytes: BigInt.from(42),
      ),
    );

    expect(mapped.completed, isTrue);
    expect(mapped.verifiedBytes, 42);
    expect(mapped.failure, isNull);
  });

  test('malformed generated results fail closed as decoder failures', () {
    final malformed = <frb_api.CloudSyncAttachmentMaterializationResult>[
      frb_api.CloudSyncAttachmentMaterializationResult(
        completed: true,
        verifiedBytes: BigInt.one,
        failure: frb_api
            .CloudSyncAttachmentMaterializationFailureCode
            .integrityMismatch,
      ),
      frb_api.CloudSyncAttachmentMaterializationResult(
        completed: false,
        verifiedBytes: BigInt.one,
      ),
      frb_api.CloudSyncAttachmentMaterializationResult(
        completed: true,
        verifiedBytes: -BigInt.one,
      ),
      frb_api.CloudSyncAttachmentMaterializationResult(
        completed: true,
        verifiedBytes: BigInt.one << 64,
      ),
    ];

    for (final result in malformed) {
      final mapped = cloudAttachmentBodyNativeResultFromFrb(result);
      expect(mapped.completed, isFalse);
      expect(mapped.verifiedBytes, 0);
      expect(mapped.failure, CloudAttachmentBodyNativeFailure.decoderFailure);
    }
  });

  test(
    'rejects a non-FRB client before resolving the native library',
    () async {
      final bindings = FrbCloudAttachmentBodyNativeBindings();

      await expectLater(
        bindings.materialize(_requestWithClient(Object())),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_attachment_native_client_type_invalid',
          ),
        ),
      );
    },
  );
}

CloudAttachmentBodyNativeRequest _requestWithClient(Object client) {
  final scope = CloudSyncScope(
    accountFingerprint: _repeat('a', 43),
    container: 'com.apple.messages.cloud',
    database: 'private',
    zone: 'attachmentManateeZone',
    persistenceLane: CloudSyncPersistenceLane.semanticV2,
  );
  final source = CloudInboxEntry(
    scope: scope,
    sequence: 1,
    change: CloudFetchedChange(
      changeId: _repeat('b', 43),
      recordIdHash: _repeat('c', 43),
      type: CloudChangeType.save,
      etagHash: _repeat('d', 43),
      encryptedPayloadReference: 'obcs2.ref.${_repeat('e', 43)}',
      payloadSha256: _repeat('f', 64),
    ),
    status: CloudInboxStatus.applied,
    attemptCount: 0,
    createdAt: DateTime.utc(2026),
    batchId: 'batch',
    generation: 1,
  );
  return CloudAttachmentBodyNativeRequest(
    authSnapshot: CloudSyncNativeAuthSnapshot.fromNative(
      nativeSessionId: 'session',
      accountFingerprint: _repeat('a', 43),
      protectedStoreIdentity: 'obcs2.store.${_repeat('g', 43)}',
      cloudMessagesClient: client,
    ),
    nativeWriterPauseToken: BigInt.one,
    storageDirectory: 'private-storage',
    applicationDocumentsDirectory: 'documents',
    source: source,
    logicalEntityKeyHash: _repeat('h', 43),
    expectedCanonicalGuidSha256: _repeat('i', 64),
    expectedBytes: 1,
  );
}

String _repeat(String value, int count) => List.filled(count, value).join();
