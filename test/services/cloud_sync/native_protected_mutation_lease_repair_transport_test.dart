import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_local_mutation_source_binding.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/native_protected_cloud_sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _account = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _identity = 'obcs2.store.$_account';

CloudProtectedMutationLeaseRepairClaim _claim({String store = _identity}) =>
    CloudProtectedMutationLeaseRepairClaim(
      source: CloudSyncLocalMutationSourceBinding(
        accountFingerprint: _account,
        protectedStoreIdentity: store,
        mutationGuidHash: 'a' * 64,
        targetGuidHash: 'b' * 64,
        targetPart: 7,
        sourceSha256: 'c' * 64,
        protectedReference: 'obcs2.ref.${'D' * 43}',
        leaseReference: 'obcs2.lease.${'e' * 32}',
        payloadSha256: 'f' * 64,
        payloadLength: 123,
      ),
    );

NativeProtectedCloudSyncTransport _transport(
  NativeProtectedCloudSyncBindings bindings,
) => NativeProtectedCloudSyncTransport(
  cloudMessagesClient: Object(),
  storageDirectory: r'C:\private\cloud-sync-v2',
  protectedStoreIdentity: _identity,
  bindings: bindings,
);

final _localFailure = throwsA(
  isA<CloudSyncFailure>().having(
    (failure) => failure.safeCode,
    'safeCode',
    startsWith('protected_mutation_lease_repair_'),
  ),
);

void main() {
  test('forwards every immutable source binding field exactly once', () async {
    final bindings = _RepairBindings();
    await _transport(bindings).repairProtectedMutationLeaseReceipt(_claim());

    expect(bindings.calls, 1);
    expect(bindings.values, {
      'storageDirectory': r'C:\private\cloud-sync-v2',
      'accountFingerprint': _account,
      'protectedStoreIdentity': _identity,
      'mutationGuidHash': 'a' * 64,
      'targetGuidHash': 'b' * 64,
      'targetPart': 7,
      'sourceSha256': 'c' * 64,
      'protectedReference': 'obcs2.ref.${'D' * 43}',
      'leaseReference': 'obcs2.lease.${'e' * 32}',
      'payloadSha256': 'f' * 64,
      'payloadLength': 123,
    });
  });

  test('wrong protected store is rejected before the binding', () async {
    final bindings = _RepairBindings();
    await expectLater(
      _transport(bindings).repairProtectedMutationLeaseReceipt(
        _claim(store: 'obcs2.store.${'B' * 43}'),
      ),
      _localFailure,
    );
    expect(bindings.calls, 0);
  });

  test('missing optional native binding fails closed', () async {
    await expectLater(
      _transport(
        _ReadOnlyBindings(),
      ).repairProtectedMutationLeaseReceipt(_claim()),
      _localFailure,
    );
  });

  test('native failure is mapped without retry', () async {
    final bindings = _RepairBindings()
      ..result = const NativeProtectedLeaseResult(
        failure: NativeProtectedFailure(
          category: NativeProtectedFailureCategory.localStorage,
          safeCode: 'invalid_reference',
        ),
      );
    await expectLater(
      _transport(bindings).repairProtectedMutationLeaseReceipt(_claim()),
      throwsA(
        isA<CloudSyncFailure>().having(
          (failure) => failure.safeCode,
          'safeCode',
          'invalid_reference',
        ),
      ),
    );
    expect(bindings.calls, 1);
  });
}

final class _ReadOnlyBindings implements NativeProtectedCloudSyncBindings {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RepairBindings
    implements
        NativeProtectedCloudSyncBindings,
        NativeProtectedMutationLeaseRepairBindings {
  int calls = 0;
  Map<String, Object>? values;
  NativeProtectedLeaseResult result = const NativeProtectedLeaseResult();

  @override
  Future<NativeProtectedLeaseResult> repairProtectedMutationLeaseReceipt({
    required String storageDirectory,
    required String accountFingerprint,
    required String protectedStoreIdentity,
    required String mutationGuidHash,
    required String targetGuidHash,
    required int targetPart,
    required String sourceSha256,
    required String protectedReference,
    required String leaseReference,
    required String payloadSha256,
    required int payloadLength,
  }) async {
    calls++;
    values = {
      'storageDirectory': storageDirectory,
      'accountFingerprint': accountFingerprint,
      'protectedStoreIdentity': protectedStoreIdentity,
      'mutationGuidHash': mutationGuidHash,
      'targetGuidHash': targetGuidHash,
      'targetPart': targetPart,
      'sourceSha256': sourceSha256,
      'protectedReference': protectedReference,
      'leaseReference': leaseReference,
      'payloadSha256': payloadSha256,
      'payloadLength': payloadLength,
    };
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
