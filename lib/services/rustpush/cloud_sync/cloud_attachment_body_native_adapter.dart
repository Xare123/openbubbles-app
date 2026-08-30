import 'package:bluebubbles/src/rust/api/api.dart' as frb_api;
import 'package:bluebubbles/src/rust/frb_generated.dart' as frb_generated;
import 'package:bluebubbles/src/rust/lib.dart' as frb_lib;

import 'cloud_attachment_body_materializer.dart';

/// Production FRB boundary for the cached-source attachment materializer.
///
/// The bridge receives only the authenticated, hashed journal evidence already
/// carried by [CloudAttachmentBodyNativeRequest]. Raw CloudKit identifiers,
/// MMCS authorization, keys, and destination paths remain inside Rust.
final class FrbCloudAttachmentBodyNativeBindings
    implements CloudAttachmentBodyNativeBindings {
  FrbCloudAttachmentBodyNativeBindings({frb_generated.RustLibApi? api})
    : _apiOverride = api;

  final frb_generated.RustLibApi? _apiOverride;

  @override
  Future<CloudAttachmentBodyNativeResult> materialize(
    CloudAttachmentBodyNativeRequest request,
  ) async {
    final client = request.authSnapshot.cloudMessagesClient;
    if (client is! frb_lib.ArcCloudMessagesClientDefaultAnisetteProvider) {
      throw StateError('cloud_attachment_native_client_type_invalid');
    }

    final source = request.source;
    final change = source.change;
    final etagHash = change.etagHash;
    final payloadSha256 = change.payloadSha256;
    final protectedReference = change.encryptedPayloadReference;
    if (etagHash == null ||
        payloadSha256 == null ||
        protectedReference == null) {
      return const CloudAttachmentBodyNativeResult.failed(
        CloudAttachmentBodyNativeFailure.sourceUnusable,
      );
    }

    // ignore: invalid_use_of_internal_member
    final api = _apiOverride ?? frb_generated.RustLib.instance.api;
    final result = await api.crateApiApiCloudSyncMaterializeAttachmentBody(
      cloudMessagesClient: client,
      nativeWriterPauseToken: request.nativeWriterPauseToken,
      storageDirectory: request.storageDirectory,
      applicationDocumentsDirectory: request.applicationDocumentsDirectory,
      expectedAccountFingerprint: request.authSnapshot.accountFingerprint,
      expectedProtectedStoreIdentity:
          request.authSnapshot.protectedStoreIdentity,
      generation: BigInt.from(source.generation),
      expectedChangeId: change.changeId,
      expectedRecordIdHash: change.recordIdHash,
      expectedEtagHash: etagHash,
      expectedPayloadSha256: payloadSha256,
      expectedServerModifiedAtMillis: change.serverModifiedAt
          ?.toUtc()
          .millisecondsSinceEpoch,
      protectedRawEnvelopeReference: protectedReference,
      logicalEntityKeyHash: request.logicalEntityKeyHash,
      expectedCanonicalGuidSha256: request.expectedCanonicalGuidSha256,
      expectedBytes: BigInt.from(request.expectedBytes),
    );
    return cloudAttachmentBodyNativeResultFromFrb(result);
  }
}

/// Maps only the fixed generated result vocabulary. Malformed bridge results
/// fail closed without exposing exception text or native values.
CloudAttachmentBodyNativeResult cloudAttachmentBodyNativeResultFromFrb(
  frb_api.CloudSyncAttachmentMaterializationResult result,
) {
  if (result.completed &&
      result.failure == null &&
      result.verifiedBytes >= BigInt.zero &&
      result.verifiedBytes <= BigInt.from(0x7fffffffffffffff)) {
    return CloudAttachmentBodyNativeResult.completed(
      result.verifiedBytes.toInt(),
    );
  }
  if (!result.completed &&
      result.verifiedBytes == BigInt.zero &&
      result.failure != null) {
    return CloudAttachmentBodyNativeResult.failed(
      _cloudAttachmentBodyNativeFailureFromFrb(result.failure!),
    );
  }
  return const CloudAttachmentBodyNativeResult.failed(
    CloudAttachmentBodyNativeFailure.decoderFailure,
  );
}

CloudAttachmentBodyNativeFailure _cloudAttachmentBodyNativeFailureFromFrb(
  frb_api.CloudSyncAttachmentMaterializationFailureCode failure,
) => switch (failure) {
  frb_api.CloudSyncAttachmentMaterializationFailureCode.invalidRequest =>
    CloudAttachmentBodyNativeFailure.invalidRequest,
  frb_api
      .CloudSyncAttachmentMaterializationFailureCode
      .readAuthenticationScope =>
    CloudAttachmentBodyNativeFailure.readAuthenticationScope,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.activeAccountMismatch =>
    CloudAttachmentBodyNativeFailure.activeAccountMismatch,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.storeIdentityMismatch =>
    CloudAttachmentBodyNativeFailure.storeIdentityMismatch,
  frb_api
      .CloudSyncAttachmentMaterializationFailureCode
      .protectedReferenceMismatch =>
    CloudAttachmentBodyNativeFailure.protectedReferenceMismatch,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.sourceUnusable =>
    CloudAttachmentBodyNativeFailure.sourceUnusable,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.pcsUnavailable =>
    CloudAttachmentBodyNativeFailure.pcsUnavailable,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.retryableUpstream =>
    CloudAttachmentBodyNativeFailure.retryableUpstream,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.localStorage =>
    CloudAttachmentBodyNativeFailure.localStorage,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.sizeMismatch =>
    CloudAttachmentBodyNativeFailure.sizeMismatch,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.integrityMismatch =>
    CloudAttachmentBodyNativeFailure.integrityMismatch,
  frb_api.CloudSyncAttachmentMaterializationFailureCode.decoderFailure =>
    CloudAttachmentBodyNativeFailure.decoderFailure,
};
