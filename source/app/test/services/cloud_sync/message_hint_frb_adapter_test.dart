import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as frb;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Message hint generated loader retains application-relative release path', () {
    expect(RustLib.kDefaultExternalLibraryLoaderConfig.ioDirectory, 'rust/target/release/');
    expect(RustLib.kDefaultExternalLibraryLoaderConfig.stem, 'rust_lib_bluebubbles');
    expect(RustLib.kDefaultExternalLibraryLoaderConfig.webPrefix, 'pkg/');
  });
  test('Message hint FRB adapter maps exact descriptors and both maintenance calls', () async {
    final api = _MaintenanceApi();
    final adapter = FrbNativeProtectedCloudSyncBindings(api: api);
    final roots = [CloudProtectedMessageSourceRootHint(
      rawReference: 'obcs2.ref.${'a' * 43}',
      accountFingerprint: 'b' * 43, generation: 9007199254740993,
    )];
    final recovery = await adapter.recoverWithMessageSourceRoots(
      storageDirectory: 'synthetic-only', adoptedLeaseReferences: const [],
      liveReferences: [roots.single.rawReference],
      liveReferenceEnumerationComplete: true, messageSourceRoots: roots);
    final collection = await adapter.collectWithMessageSourceRoots(
      storageDirectory: 'synthetic-only', liveReferences: [roots.single.rawReference],
      liveReferenceEnumerationComplete: true, messageSourceRoots: roots);
    expect(recovery.recovery!.rolledBackCount, 2);
    expect(collection.collection!.preservedLiveCount, 3);
    expect(api.calls.length, 2);
    for (final call in api.calls) {
      final mapped = call.namedArguments[#messageRoots] as List<frb.CloudSyncMessageSourceRootHint>;
      expect(mapped.single.rawReference, roots.single.rawReference);
      expect(mapped.single.accountFingerprint, roots.single.accountFingerprint);
      expect(mapped.single.generation, BigInt.parse('9007199254740993'));
      expect(call.namedArguments[#liveReferenceEnumerationComplete], isTrue);
      expect(call.namedArguments[#storageDirectory], 'synthetic-only');
    }
  });
}

class _MaintenanceApi implements RustLibApi {
  final calls = <Invocation>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    if (invocation.memberName == #crateApiApiCloudSyncRecoverAbandonedPageLeasesWithMessageSourceRoots) {
      return const frb.CloudSyncProtectedRecoveryResult(recovery: frb.CloudSyncProtectedRecovery(
        finalizedAdoptedLeaseReferences: [], absentAdoptedLeaseReferences: [],
        rolledBackCount: 2, removedTemporaryFilesCount: 0, hasMore: false));
    }
    if (invocation.memberName == #crateApiApiCloudSyncCollectProtectedGarbageWithMessageSourceRoots) {
      return const frb.CloudSyncProtectedGarbageCollectionResult(collection: frb.CloudSyncProtectedGarbageCollection(
        scannedCount: 3, firstObservedCount: 0, deletedCount: 0, preservedLiveCount: 3,
        preservedActiveLeaseCount: 0, hasMore: false));
    }
    return super.noSuchMethod(invocation);
  }
}
