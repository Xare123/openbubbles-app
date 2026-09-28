import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as native;
import 'package:bluebubbles/src/rust/frb_generated.dart' as frb;
import 'package:flutter_test/flutter_test.dart';

/// Pure routing tests for historical attachment record binding: the facade
/// routes to historical native APIs for a validated context, preserves the
/// ordinary APIs for null, and fails closed on drift. No ObjectBox, account,
/// network, or native execution.
const _accountA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _storeA = 'obcs2.store.SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS';
const _accountB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _storeB = 'obcs2.store.TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT';

api.CloudSyncNativeAuthMetadata _auth({String? account, String? store}) =>
    api.CloudSyncNativeAuthMetadata(
      nativeSessionId: 'session',
      accountFingerprint: account ?? _accountA,
      protectedStoreIdentity: store ?? _storeA,
    );

api.CloudSyncNativeHistoricalArchiveSourceBinding _source({
  String? account,
  String? store,
  String? sha,
}) => api.CloudSyncNativeHistoricalArchiveSourceBinding(
  accountFingerprint: account ?? _accountA,
  protectedStoreIdentity: store ?? _storeA,
  snapshotSha256: 'a' * 64,
  messageGuidHash: 'b' * 64,
  sourceSha256: sha ?? 'c' * 64,
  protectedReference: 'obcs2.ref.${'H' * 43}',
  leaseReference: 'obcs2.lease.${'a' * 32}',
  payloadSha256: 'd' * 64,
  payloadLength: 128,
);

api.CloudSyncHistoricalAttachmentContext _context({
  String? account,
  String? store,
  String? sha,
}) => api.CloudSyncHistoricalAttachmentContext(
  storageDirectory: 'store-dir',
  expectedAuth: _auth(account: account, store: store),
  source: _source(account: account, store: store, sha: sha),
);

api.CloudSyncPreparedMessageCreateInput _input() =>
    api.CloudSyncPreparedMessageCreateInput(
      localOperationId: 'op1:${'e' * 64}',
      logicalEntityKeyHash: 'L' * 43,
      protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
      protectedPayloadReference: 'obcs2.ref.${'V' * 43}',
      payloadSha256: 'e' * 64,
      protectedServerRecordReference: 'obcs2.ref.${'V' * 43}',
      serverRecordIdHash: 'M' * 43,
      appleOperationUuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
    );

void main() {
  late _Bridge bridge;
  late _Client client;

  FrbNativeProtectedCloudSyncBindings bindings({
    FutureOr<api.CloudSyncHistoricalAttachmentContext?> Function(
      api.CloudSyncPreparedMessageCreateInput,
    )?
    context,
  }) => FrbNativeProtectedCloudSyncBindings(
    api: bridge,
    readHistoricalAttachmentContext: context == null
        ? null
        : (input) async => context(input),
  );

  setUp(() {
    bridge = _Bridge();
    client = _Client();
  });

  Future<api.CloudSyncPreparedMessageCreateResult> prepare(
    FrbNativeProtectedCloudSyncBindings bindings,
  ) => bindings.prepareAttachmentCreate(
    cloudMessagesClient: client,
    storageDirectory: 'store-dir',
    expectedAccountFingerprint: _accountA,
    expectedProtectedStoreIdentity: _storeA,
    requestUuid: 'req-uuid',
    requestTimeout: const Duration(seconds: 30),
    inputs: [_input()],
  );

  Future<api.CloudSyncOutboundReconcileResult> reconcile(
    FrbNativeProtectedCloudSyncBindings bindings,
  ) => bindings.reconcileAttachmentCreate(
    cloudMessagesClient: client,
    storageDirectory: 'store-dir',
    expectedAccountFingerprint: _accountA,
    expectedProtectedStoreIdentity: _storeA,
    requestUuid: 'req-uuid',
    input: _input(),
  );

  test('prepare routes to the historical API with full context', () async {
    final context = _context();
    api.CloudSyncPreparedMessageCreateInput? seen;
    await prepare(
      bindings(
        context: (input) {
          seen = input;
          return context;
        },
      ),
    );
    expect(bridge.historicalPrepareCalls, 1);
    expect(bridge.ordinaryPrepareCalls, 0);
    expect(bridge.prepareContext, same(context));
    expect(bridge.prepareInputs, hasLength(1));
    expect(bridge.prepareRequestUuid, 'req-uuid');
    expect(bridge.prepareTimeoutSeconds, BigInt.from(30));
    expect(seen?.logicalEntityKeyHash, 'L' * 43);
  });

  test('prepare preserves the ordinary API for a null context', () async {
    await prepare(bindings(context: (_) => null));
    expect(bridge.ordinaryPrepareCalls, 1);
    expect(bridge.historicalPrepareCalls, 0);
    await prepare(FrbNativeProtectedCloudSyncBindings(api: bridge));
    expect(bridge.ordinaryPrepareCalls, 2);
    expect(bridge.historicalPrepareCalls, 0);
  });

  test('reconcile routes to the historical API with full forwarding', () async {
    final context = _context();
    await reconcile(bindings(context: (_) => context));
    expect(bridge.historicalReconcileCalls, 1);
    expect(bridge.ordinaryReconcileCalls, 0);
    expect(bridge.reconcileContext, same(context));
    expect(bridge.reconcileInput?.logicalEntityKeyHash, 'L' * 43);
    expect(bridge.reconcileRequestUuid, 'req-uuid');
  });

  test('ordinary attachment batches retain their existing input contract', () async {
    final batch = [_input(), _input()];
    await FrbNativeProtectedCloudSyncBindings(api: bridge).prepareAttachmentCreate(
      cloudMessagesClient: client, storageDirectory: 'store-dir',
      expectedAccountFingerprint: _accountA, expectedProtectedStoreIdentity: _storeA,
      requestUuid: 'req-uuid', requestTimeout: const Duration(seconds: 30), inputs: batch);
    expect(bridge.ordinaryPrepareCalls, 1);
    expect(bridge.historicalPrepareCalls, 0);
    expect(bridge.prepareInputs, same(batch));
    await expectLater(bindings(context: (_) => _context()).prepareAttachmentCreate(
      cloudMessagesClient: client, storageDirectory: 'store-dir',
      expectedAccountFingerprint: _accountA, expectedProtectedStoreIdentity: _storeA,
      requestUuid: 'req-uuid', requestTimeout: const Duration(seconds: 30), inputs: batch),
      throwsA(isA<StateError>()));
    expect(bridge.totalCalls, 1);
  });

  test('reconcile preserves the ordinary API for a null context', () async {
    await reconcile(bindings(context: (_) => null));
    expect(bridge.ordinaryReconcileCalls, 1);
    expect(bridge.historicalReconcileCalls, 0);
  });

  test('cross-account and cross-store contexts fail without native calls', () async {
    for (final mismatched in [
      _context(account: _accountB),
      _context(store: _storeB),
      _context(account: _accountB, store: _storeB),
    ]) {
      final before = bridge.totalCalls;
      await expectLater(
        prepare(bindings(context: (_) => mismatched)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_attachment_owner_changed',
          ),
        ),
      );
      await expectLater(
        reconcile(bindings(context: (_) => mismatched)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_attachment_owner_changed',
          ),
        ),
      );
      expect(bridge.totalCalls, before);
    }
  });

  test('competing proofs in the input fail without native calls', () async {
    final context = _context();
    for (final input in [_withParentContext(), _withChatSource()]) {
      final before = bridge.totalCalls;
      await expectLater(
        bindings(
          context: (_) => context,
        ).prepareAttachmentCreate(
          cloudMessagesClient: client,
          storageDirectory: 'store-dir',
          expectedAccountFingerprint: _accountA,
          expectedProtectedStoreIdentity: _storeA,
          requestUuid: 'req-uuid',
          requestTimeout: const Duration(seconds: 30),
          inputs: [input],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cloud_sync_attachment_owner_changed',
          ),
        ),
      );
      expect(bridge.totalCalls, before);
    }
  });

  test('changed context after prepare releases the handle', () async {
    var calls = 0;
    final bindingsWithDrift = bindings(
      context: (_) async => ++calls == 1 ? _context() : _context(sha: 'd' * 64),
    );
    bridge.prepareResult = api.CloudSyncPreparedMessageCreateResult(
      handle: _Handle(),
      handleBindingSha256: 'h' * 64,
    );
    await expectLater(
      prepare(bindingsWithDrift),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_attachment_owner_changed',
        ),
      ),
    );
    expect(bridge.releasedHandles, hasLength(1));
  });

  test('historical failure never falls back to the ordinary API', () async {
    final failure = StateError('synthetic-native-failure');
    bridge.historicalFailure = failure;
    await expectLater(
      prepare(bindings(context: (_) => _context())),
      throwsA(same(failure)),
    );
    expect(bridge.ordinaryPrepareCalls, 0);
    var calls = 0;
    await expectLater(
      reconcile(
        bindings(
          context: (_) async =>
              ++calls == 1 ? _context() : _context(sha: 'd' * 64),
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_attachment_owner_changed',
        ),
      ),
    );
    expect(bridge.ordinaryReconcileCalls, 0);
  });
}

api.CloudSyncPreparedMessageCreateInput _withParentContext() =>
    api.CloudSyncPreparedMessageCreateInput(
      localOperationId: 'op1:${'e' * 64}',
      logicalEntityKeyHash: 'L' * 43,
      protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
      protectedPayloadReference: 'obcs2.ref.${'V' * 43}',
      payloadSha256: 'e' * 64,
      protectedServerRecordReference: 'obcs2.ref.${'V' * 43}',
      serverRecordIdHash: 'M' * 43,
      appleOperationUuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      attachmentParentContext: api.CloudSyncNativeSendReceiptContext(
        storageDirectory: 'store-dir',
        accountFingerprint: _accountA,
        protectedStoreIdentity: _storeA,
        nativeSessionId: 'session',
        guidHash: 'g' * 64,
        sourceBinding: api.CloudSyncNativeSendSourceBinding(
          protectedReference: 'obcs2.ref.${'P' * 43}',
          leaseReference: 'obcs2.lease.${'c' * 32}',
          payloadSha256: 'e' * 64,
          sourceSha256: 's' * 64,
          payloadLength: BigInt.from(40),
        ),
      ),
    );

api.CloudSyncPreparedMessageCreateInput _withChatSource() =>
    api.CloudSyncPreparedMessageCreateInput(
      localOperationId: 'op1:${'e' * 64}',
      logicalEntityKeyHash: 'L' * 43,
      protectedLeaseReference: 'obcs2.lease.${'f' * 32}',
      protectedPayloadReference: 'obcs2.ref.${'V' * 43}',
      payloadSha256: 'e' * 64,
      protectedServerRecordReference: 'obcs2.ref.${'V' * 43}',
      serverRecordIdHash: 'M' * 43,
      appleOperationUuid: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
      historicalChatSource: api.CloudSyncNativeHistoricalArchiveSourceBinding(
        accountFingerprint: _accountA,
        protectedStoreIdentity: _storeA,
        snapshotSha256: 'a' * 64,
        messageGuidHash: 'b' * 64,
        sourceSha256: 'c' * 64,
        protectedReference: 'obcs2.ref.${'H' * 43}',
        leaseReference: 'obcs2.lease.${'a' * 32}',
        payloadSha256: 'd' * 64,
        payloadLength: 128,
      ),
    );

class _Bridge implements frb.RustLibApi {
  int ordinaryPrepareCalls = 0;
  int historicalPrepareCalls = 0;
  int ordinaryReconcileCalls = 0;
  int historicalReconcileCalls = 0;
  int get totalCalls =>
      ordinaryPrepareCalls +
      historicalPrepareCalls +
      ordinaryReconcileCalls +
      historicalReconcileCalls;
  api.CloudSyncHistoricalAttachmentContext? prepareContext;
  List<api.CloudSyncPreparedMessageCreateInput>? prepareInputs;
  String? prepareRequestUuid;
  BigInt? prepareTimeoutSeconds;
  api.CloudSyncHistoricalAttachmentContext? reconcileContext;
  api.CloudSyncPreparedMessageCreateInput? reconcileInput;
  String? reconcileRequestUuid;
  final List<api.CloudSyncPreparedMessageCreateHandle> releasedHandles = [];
  api.CloudSyncPreparedMessageCreateResult prepareResult =
      const api.CloudSyncPreparedMessageCreateResult();
  Object? historicalFailure;

  @override
  Future<api.CloudSyncPreparedMessageCreateResult>
  crateApiApiCloudSyncPrepareAttachmentCreate({
    required native.ArcCloudMessagesClientDefaultAnisetteProvider
    cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required BigInt requestTimeoutSeconds,
    required List<api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    ordinaryPrepareCalls++;
    prepareInputs = inputs;
    return const api.CloudSyncPreparedMessageCreateResult();
  }

  @override
  Future<api.CloudSyncPreparedMessageCreateResult>
  crateApiApiCloudSyncPrepareHistoricalAttachmentCreate({
    required native.ArcCloudMessagesClientDefaultAnisetteProvider
    cloudMessagesClient,
    required api.CloudSyncHistoricalAttachmentContext context,
    required String requestUuid,
    required BigInt requestTimeoutSeconds,
    required List<api.CloudSyncPreparedMessageCreateInput> inputs,
  }) async {
    historicalPrepareCalls++;
    if (historicalFailure != null) throw historicalFailure!;
    prepareContext = context;
    prepareInputs = inputs;
    prepareRequestUuid = requestUuid;
    prepareTimeoutSeconds = requestTimeoutSeconds;
    return prepareResult;
  }

  @override
  Future<api.CloudSyncOutboundReconcileResult>
  crateApiApiCloudSyncReconcileAttachmentCreate({
    required native.ArcCloudMessagesClientDefaultAnisetteProvider
    cloudMessagesClient,
    required String storageDirectory,
    required String expectedAccountFingerprint,
    required String expectedProtectedStoreIdentity,
    required String requestUuid,
    required api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    ordinaryReconcileCalls++;
    return const api.CloudSyncOutboundReconcileResult();
  }

  @override
  Future<api.CloudSyncOutboundReconcileResult>
  crateApiApiCloudSyncReconcileHistoricalAttachmentCreate({
    required native.ArcCloudMessagesClientDefaultAnisetteProvider
    cloudMessagesClient,
    required api.CloudSyncHistoricalAttachmentContext context,
    required String requestUuid,
    required api.CloudSyncPreparedMessageCreateInput input,
  }) async {
    historicalReconcileCalls++;
    reconcileContext = context;
    reconcileInput = input;
    reconcileRequestUuid = requestUuid;
    return const api.CloudSyncOutboundReconcileResult();
  }

  @override
  Future<bool> crateApiApiCloudSyncReleasePreparedMessageCreate({
    required api.CloudSyncPreparedMessageCreateHandle handle,
  }) async {
    releasedHandles.add(handle);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client
    implements native.ArcCloudMessagesClientDefaultAnisetteProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Handle implements api.CloudSyncPreparedMessageCreateHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
