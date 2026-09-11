import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_upload_adapters.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_send_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_sampler.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bridge = _Bridge();
  final client = _Client();
  final adapter = FrbCloudSyncAttachmentPlanSource(
    storageDirectory: 'synthetic-store',
  );
  final source = CloudSyncLocalSendSourceBinding(
    accountFingerprint: 'A' * 43,
    protectedStoreIdentity: 'obcs2.store.${'S' * 43}',
    messageGuidHash: 'a' * 64,
    sourceSha256: 'b' * 64,
    protectedReference: 'obcs2.ref.${'P' * 43}',
    leaseReference: 'obcs2.lease.${'c' * 32}',
    payloadSha256: 'd' * 64,
    payloadLength: 40,
  );
  CloudSyncNativeAuthSnapshot auth({
    String? account,
    String? store,
    Object? active,
  }) => CloudSyncNativeAuthSnapshot.fromNative(
    nativeSessionId: 'native-session',
    accountFingerprint: account ?? source.accountFingerprint,
    protectedStoreIdentity: store ?? source.protectedStoreIdentity,
    cloudMessagesClient: active ?? client,
  );
  setUpAll(() => RustLib.initMock(api: bridge));
  tearDownAll(RustLib.dispose);
  setUp(() {
    bridge.calls = 0;
    bridge.inventoryFailure = null;
    bridge.stageFailure = null;
  });

  test(
    'inventory crosses the real generated call with pinned context',
    () async {
      final entries = await adapter.inspect(source, auth());
      expect(entries.single.originalAttachmentGuid, 'LOCAL-A');
      expect(entries.single.reflectedAttachmentGuid, 'message_2');
      expect(entries.single.logicalEntityKeyHash, 'K' * 43);
      expect(bridge.client, same(client));
      final context = bridge.context!;
      expect(context.storageDirectory, 'synthetic-store');
      expect(context.nativeSessionId, 'native-session');
      expect(context.guidHash, source.messageGuidHash);
      expect(context.accountFingerprint, source.accountFingerprint);
      expect(context.protectedStoreIdentity, source.protectedStoreIdentity);
      expect(
        context.sourceBinding!.protectedReference,
        source.protectedReference,
      );
      expect(context.sourceBinding!.leaseReference, source.leaseReference);
      expect(context.sourceBinding!.sourceSha256, source.sourceSha256);
      expect(context.sourceBinding!.payloadSha256, source.payloadSha256);
      expect(context.sourceBinding!.payloadLength, BigInt.from(40));
      expect(() => entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'plan stage uses original GUID and preserves returned plan identity',
    () async {
      final entry = (await adapter.inspect(source, auth())).single;
      final result = await adapter.stage(
        entry,
        source,
        auth(),
        sourcePath: 'synthetic-file',
        startDateNanoseconds: 123,
        createdDateNanoseconds: 456,
      );
      expect(bridge.originalGuid, 'LOCAL-A');
      expect(bridge.sourcePath, 'synthetic-file');
      expect(bridge.times, [123, 456]);
      expect(result.logicalEntityKeyHash, 'K' * 43);
      expect(result.protectedEnvelopeReference, 'obcs2.ref.${'E' * 43}');
      expect(result.payloadSha256, 'e' * 64);
      expect(result.serverRecordIdHash, 'R' * 43);
      expect(result.leaseReference, 'obcs2.lease.${'f' * 32}');
    },
  );

  test(
    'account, store and client mismatch never invoke native inventory',
    () async {
      for (final invalid in [
        auth(account: 'B' * 43),
        auth(store: 'obcs2.store.${'T' * 43}'),
        auth(active: Object()),
      ]) {
        await expectLater(adapter.inspect(source, invalid), throwsStateError);
      }
      expect(bridge.calls, 0);
    },
  );

  test(
    'native stage errors expose exact reviewed codes without retry',
    () async {
      final entry = (await adapter.inspect(source, auth())).single;
      const cases = {
        'attachment source preparation unavailable':
            'cloud_sync_attachment_preparation_unavailable',
        'attachment source unavailable or does not match original IDS bytes':
            'cloud_sync_attachment_source_mismatch',
        'attachment upload source invalid':
            'cloud_sync_attachment_source_invalid',
        'cloud_sync_attachment_preparation_auth_unavailable':
            'cloud_sync_attachment_preparation_auth_unavailable',
        'cloud_sync_native_attachment_source_unavailable':
            'cloud_sync_native_attachment_source_unavailable',
        'private-server-response':
            'cloud_sync_attachment_plan_native_stage_failed',
        'cloud_sync_attachment_preparation_auth_unavailable secret':
            'cloud_sync_attachment_plan_native_stage_failed',
        'attachment source preparation unavailable\nprivate-token':
            'cloud_sync_attachment_plan_native_stage_failed',
      };
      for (final item in cases.entries) {
        bridge.stageFailure = AnyhowException(item.key);
        final before = bridge.calls;
        await expectLater(
          adapter.stage(
            entry,
            source,
            auth(),
            sourcePath: 'synthetic-file',
            startDateNanoseconds: 123,
            createdDateNanoseconds: 456,
          ),
          throwsA(
            isA<StateError>().having(
              cloudSyncV2SafeFailureCode,
              'safe code',
              item.value,
            ),
          ),
        );
        expect(bridge.calls, before + 1);
      }
    },
  );

  test(
    'inventory failure identifies boundary without raw native text',
    () async {
      bridge.inventoryFailure = AnyhowException('private-path secret');
      await expectLater(
        adapter.inspect(source, auth()),
        throwsA(
          isA<StateError>().having(
            cloudSyncV2SafeFailureCode,
            'safe code',
            'cloud_sync_attachment_plan_inventory_failed',
          ),
        ),
      );
      expect(bridge.calls, 1);
    },
  );

  test('non-native exception remains unchanged', () async {
    final failure = StateError('synthetic-local-failure');
    bridge.inventoryFailure = failure;
    await expectLater(adapter.inspect(source, auth()), throwsA(same(failure)));
    expect(bridge.calls, 1);
  });
}

class _Bridge implements RustLibApi {
  int calls = 0;
  Object? inventoryFailure;
  Object? stageFailure;
  native.ArcCloudMessagesClientDefaultAnisetteProvider? client;
  api.CloudSyncNativeSendReceiptContext? context;
  String? originalGuid;
  String? sourcePath;
  List<int>? times;

  @override
  Future<List<api.CloudSyncAttachmentSourceEntry>>
  crateApiApiCloudSyncInspectAttachmentSources({
    required native.ArcCloudMessagesClientDefaultAnisetteProvider
    cloudMessagesClient,
    required api.CloudSyncNativeSendReceiptContext context,
  }) async {
    calls++;
    if (inventoryFailure != null) throw inventoryFailure!;
    client = cloudMessagesClient;
    this.context = context;
    return [
      api.CloudSyncAttachmentSourceEntry(
        originalAttachmentGuid: 'LOCAL-A',
        reflectedAttachmentGuid: 'message_2',
        logicalEntityKeyHash: 'K' * 43,
      ),
    ];
  }

  @override
  Future<api.CloudSyncAttachmentUploadPlanResult>
  crateApiApiCloudSyncStageAttachmentUploadPlan({
    required native.ArcCloudMessagesClientDefaultAnisetteProvider
    cloudMessagesClient,
    required api.CloudSyncNativeSendReceiptContext context,
    required String originalAttachmentGuid,
    required String sourcePath,
    required int startDateNs,
    required int createdDateNs,
  }) async {
    calls++;
    if (stageFailure != null) throw stageFailure!;
    client = cloudMessagesClient;
    this.context = context;
    originalGuid = originalAttachmentGuid;
    this.sourcePath = sourcePath;
    times = [startDateNs, createdDateNs];
    return api.CloudSyncAttachmentUploadPlanResult(
      uploadAttemptId: '11111111-1111-4111-8111-111111111111',
      stage: api.CloudSyncProtectedOutboundStage(
        logicalEntityKeyHash: 'K' * 43,
        protectedPayloadReference: 'obcs2.ref.${'E' * 43}',
        payloadSha256: 'e' * 64,
        payloadLength: BigInt.from(80),
        protectedServerRecordReference: 'obcs2.ref.${'E' * 43}',
        serverRecordIdHash: 'R' * 43,
        leaseReference: 'obcs2.lease.${'f' * 32}',
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements native.ArcCloudMessagesClientDefaultAnisetteProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
