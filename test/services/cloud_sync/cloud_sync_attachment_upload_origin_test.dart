import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_origin.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_protected_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final auth = api.CloudSyncNativeAuthMetadata(accountFingerprint: 'A' * 43,
      protectedStoreIdentity: 'obcs2.store.${'S' * 43}', nativeSessionId: 'session');
  CloudSyncHistoricalProtectedSourceBinding historical({String snapshot = 'a'}) =>
      CloudSyncHistoricalProtectedSourceBinding(
        accountFingerprint: auth.accountFingerprint,
        protectedStoreIdentity: auth.protectedStoreIdentity,
        snapshotSha256: snapshot * 64, messageGuidHash: 'b' * 64,
        sourceSha256: 'c' * 64, protectedReference: 'obcs2.ref.${'H' * 43}',
        leaseReference: 'obcs2.lease.${'d' * 32}', payloadSha256: 'e' * 64,
        payloadLength: 128);
  final local = CloudSyncLocalSendSourceBinding(
    accountFingerprint: auth.accountFingerprint,
    protectedStoreIdentity: auth.protectedStoreIdentity,
    messageGuidHash: 'b' * 64, sourceSha256: 'c' * 64,
    protectedReference: 'obcs2.ref.${'L' * 43}',
    leaseReference: 'obcs2.lease.${'d' * 32}', payloadSha256: 'e' * 64, payloadLength: 128);

  test('local context keeps the existing IDS source without a historical claim', () {
    final origin = CloudSyncAttachmentUploadOrigin.local(local);
    final context = origin.localContext(storageDirectory: 'private', auth: auth);
    expect(origin.isHistorical, isFalse);
    expect(origin.encoded, local.encode());
    expect(context.guidHash, local.messageGuidHash);
    expect(context.nativeSessionId, auth.nativeSessionId);
    expect(context.sourceBinding!.payloadLength, BigInt.from(128));
    expect(context.sourceBinding!.protectedReference, local.protectedReference);
    expect(() => origin.historicalContext(storageDirectory: 'private', auth: auth),
        throwsA(isA<StateError>()));
  });

  test('historical context retains all source fields and cannot masquerade as IDS', () {
    final source = historical();
    final origin = CloudSyncAttachmentUploadOrigin.historical(source);
    final context = origin.historicalContext(storageDirectory: 'private', auth: auth);
    expect(origin.isHistorical, isTrue);
    expect(origin.encoded, source.encode());
    expect(context.storageDirectory, 'private');
    expect(context.expectedAuth, auth);
    expect(CloudSyncHistoricalProtectedSourceBinding.fromNative(context.source).encode(), source.encode());
    expect(() => origin.localContext(storageDirectory: 'private', auth: auth),
        throwsA(isA<StateError>()));
  });

  test('both origins reject foreign account and protected store', () {
    for (final origin in [CloudSyncAttachmentUploadOrigin.local(local),
      CloudSyncAttachmentUploadOrigin.historical(historical())]) {
      for (final changed in [
        api.CloudSyncNativeAuthMetadata(accountFingerprint: 'B' * 43,
          protectedStoreIdentity: auth.protectedStoreIdentity, nativeSessionId: 'session'),
        api.CloudSyncNativeAuthMetadata(accountFingerprint: auth.accountFingerprint,
          protectedStoreIdentity: 'obcs2.store.${'T' * 43}', nativeSessionId: 'session'),
      ]) {
        expect(() => origin.isHistorical
            ? origin.historicalContext(storageDirectory: 'private', auth: changed)
            : origin.localContext(storageDirectory: 'private', auth: changed),
            throwsA(isA<StateError>()));
      }
    }
  });

  test('historical source pin includes snapshot identity and diagnostics stay redacted', () {
    final origin = CloudSyncAttachmentUploadOrigin.historical(historical());
    final other = CloudSyncAttachmentUploadOrigin.historical(historical(snapshot: 'f'));
    expect(origin.encoded, isNot(other.encoded));
    expect(origin.toString(), 'CloudSyncAttachmentUploadOrigin(redacted)');
    expect(origin.toString(), isNot(contains('obcs2.ref')));
  });
}
