import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const _lease = 'obcs2.lease.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _storeIdentity =
    'obcs2.store.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  late _MaintenanceStore store;
  late _MaintenanceTransport transport;
  late CloudProtectedPageLeaseLifecycle lifecycle;
  late _Admission admission;
  late CloudProtectedPageLeaseMaintenanceCaller caller;

  setUp(() {
    CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests();
    store = _MaintenanceStore();
    transport = _MaintenanceTransport();
    lifecycle = CloudProtectedPageLeaseLifecycle(
      store: store,
      transport: transport,
    );
    admission = _Admission();
    caller = CloudProtectedPageLeaseMaintenanceCaller(
      lifecycle: lifecycle,
      admission: admission,
    );
  });

  tearDown(CloudProtectedPageLeaseLifecycle.resetRecoveryStateForTests);

  test('active lease admission rejects before native collection', () async {
    admission.failure = StateError('cloud_sync_maintenance_active');

    await expectLater(
      caller.collectOneAfterRun(),
      throwsA(isA<StateError>()),
    );

    expect(transport.garbageCollectionCalls, 0);
    expect(admission.actionCalls, 1);
  });

  test('quiescing or account transition admission rejects fail closed',
      () async {
    admission.failure = StateError('cloud_sync_maintenance_transition');

    await expectLater(
      caller.collectOneAfterRun(),
      throwsA(isA<StateError>()),
    );

    expect(transport.garbageCollectionCalls, 0);
  });

  test('concurrent after-run requests coalesce to one bounded page', () async {
    final first = caller.collectOneAfterRun();
    final second = caller.collectOneAfterRun();

    expect(identical(first, second), isTrue);
    final result = await first;

    expect(result.scannedCount, 1);
    expect(transport.garbageCollectionCalls, 1);
    expect(admission.actionCalls, 1);
  });

  test('a later explicit call remains idempotent and makes one page at a time',
      () async {
    await caller.collectOneAfterRun();
    await caller.collectOneAfterRun();

    expect(transport.garbageCollectionCalls, 2);
    expect(transport.maxCallsAtOnce, 1);
  });
}

final class _Admission
    implements CloudProtectedPageLeaseMaintenanceAdmission {
  Object? failure;
  int actionCalls = 0;
  int _activeActions = 0;
  int maxCallsAtOnce = 0;

  @override
  Future<T> runWhenIdle<T>(CloudProtectedPageLeaseMaintenanceBody<T> action) {
    actionCalls++;
    final failure = this.failure;
    if (failure != null) return Future<T>.error(failure!);
    _activeActions++;
    if (_activeActions > maxCallsAtOnce) maxCallsAtOnce = _activeActions;
    return Future<T>.sync(action).whenComplete(() => _activeActions--);
  }
}

final class _MaintenanceStore implements CloudProtectedPageLeaseAdoptionStore {
  @override
  Future<Set<String>> readAdoptedProtectedPageLeaseReferences({
    required int maximumCount,
  }) async => {_lease};

  @override
  Future<CloudProtectedReferenceSnapshot> readLiveProtectedReferences({
    required int maximumCount,
  }) async => CloudProtectedReferenceSnapshot(
    references: const {},
    isComplete: true,
  );

  @override
  Future<void> releaseAdoptedProtectedPageLeaseReferences(
    Iterable<String> leaseReferences,
  ) async {}
}

final class _MaintenanceTransport implements CloudProtectedPageLeaseTransport {
  int garbageCollectionCalls = 0;
  int _activeCalls = 0;
  int maxCallsAtOnce = 0;

  @override
  String get protectedPageLeaseRecoveryIdentity => _storeIdentity;

  @override
  Future<T> runProtectedStoreExclusive<T>(Future<T> Function() action) =>
      Future<T>.sync(action);

  @override
  Future<CloudProtectedPageLeaseRecoveryResult> recoverProtectedPageLeases(
    Set<String> adoptedLeaseReferences,
    CloudProtectedReferenceSnapshot liveReferences,
  ) async => CloudProtectedPageLeaseRecoveryResult(
    finalizedAdoptedLeaseReferences: adoptedLeaseReferences,
    hasMore: false,
  );

  @override
  Future<void> commitProtectedPageLease(
    String leaseReference,
    Set<String> retainedReferences,
  ) async {}

  @override
  Future<void> acknowledgeCommittedPageLease(String leaseReference) async {}

  @override
  Future<void> rollbackProtectedPageLease(String leaseReference) async {}

  @override
  Future<int> retireProtectedReferences(Set<String> references) async =>
      references.length;

  @override
  Future<CloudProtectedGarbageCollectionResult> collectProtectedGarbage(
    CloudProtectedReferenceSnapshot liveReferences,
  ) async {
    garbageCollectionCalls++;
    _activeCalls++;
    if (_activeCalls > maxCallsAtOnce) maxCallsAtOnce = _activeCalls;
    await Future<void>.delayed(Duration.zero);
    _activeCalls--;
    return const CloudProtectedGarbageCollectionResult(
      scannedCount: 1,
      firstObservedCount: 1,
      deletedCount: 0,
      preservedLiveCount: 0,
      preservedActiveLeaseCount: 0,
      hasMore: false,
    );
  }
}
