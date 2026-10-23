import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_store.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

final class _RouteRecoveryApplier extends FakeCloudInboxApplier
    implements CloudChatServiceRouteBarrierRecovery {
  _RouteRecoveryApplier({required this.transport, this.recoveryResult = true});

  final FakeCloudSyncTransport transport;
  bool recoveryResult;
  int recoveryCalls = 0;
  CloudSyncScope? recoveryScope;
  final List<CloudCoordinatorLeaseFence> recoveryFences = [];
  int fetchCallsAtRecovery = -1;
  int appliedAtRecovery = -1;

  @override
  Future<bool> requeueChatServiceRouteBarrier(
    CloudSyncScope scope, {
    required CloudCoordinatorLeaseFence leaseFence,
  }) async {
    recoveryCalls++;
    recoveryScope = scope;
    recoveryFences.add(leaseFence);
    fetchCallsAtRecovery = transport.fetchCallCount;
    appliedAtRecovery = appliedSequences.length;
    return recoveryResult;
  }
}

CloudSyncEngine _routeEngine({
  required CloudSyncScope scope,
  required InMemoryCloudSyncStore store,
  required FakeCloudSyncTransport transport,
  required FakeCloudInboxApplier applier,
  required MutableTestClock clock,
  required bool semanticApply,
}) {
  return CloudSyncEngine(
    scope: scope,
    coordinatorId: 'route-recovery-coordinator',
    store: store,
    transport: transport,
    inboxApplier: applier,
    clock: clock.call,
    config: CloudSyncEngineConfig(
      flags: CloudSyncFeatureFlags(
        readOnlyFetch: true,
        semanticApply: semanticApply,
      ),
    ),
  );
}

void main() {
  late CloudSyncScope scope;
  late InMemoryCloudSyncStore store;
  late FakeCloudSyncTransport transport;
  late MutableTestClock clock;

  setUp(() {
    scope = testScope();
    store = InMemoryCloudSyncStore();
    transport = FakeCloudSyncTransport();
    clock = MutableTestClock(testEpoch);
  });

  test('semantic run recovers route barrier once before fetch and apply',
      () async {
    final applier = _RouteRecoveryApplier(transport: transport);
    transport.enqueueFetchBatch(
      CloudFetchBatch(
        scope: scope,
        changes: [testChange(1)],
        batchId: 'route-barrier-page',
        generation: 1,
        nextToken: 'route-token',
        hasMore: false,
      ),
    );
    final result = await _routeEngine(
      scope: scope,
      store: store,
      transport: transport,
      applier: applier,
      clock: clock,
      semanticApply: true,
    ).synchronize(trigger: CloudSyncTrigger.manual);
    expect(result.status, CloudSyncRunStatus.completed);
    expect(applier.recoveryCalls, 1);
    expect(applier.recoveryScope, same(scope));
    expect(applier.recoveryFences, hasLength(1));
    expect(applier.fetchCallsAtRecovery, 0);
    expect(applier.appliedAtRecovery, 0);
    expect(
      applier.recoveryFences.single,
      same(applier.appliedLeaseFences.first),
    );
    expect(transport.fetchCallCount, 1);
    expect(applier.appliedSequences, [1]);
    expect(result.counters.fetched, 1);
    expect(result.counters.applied, 1);
    expect(transport.pushCallCount, 0);
  });

  test('false route recovery fabricates no applied count or save', () async {
    final applier =
        _RouteRecoveryApplier(transport: transport, recoveryResult: false);
    final result = await _routeEngine(
      scope: scope,
      store: store,
      transport: transport,
      applier: applier,
      clock: clock,
      semanticApply: true,
    ).synchronize(trigger: CloudSyncTrigger.manual);
    expect(result.status, CloudSyncRunStatus.completed);
    expect(applier.recoveryCalls, 1);
    expect(result.counters.applied, 0);
    expect(result.counters.fetched, 0);
    expect(applier.appliedSequences, isEmpty);
    expect(transport.pushCallCount, 0);
    expect(transport.prepareSubmissionCallCount, 0);
  });

  test('shadow run never invokes route recovery', () async {
    final applier = _RouteRecoveryApplier(transport: transport);
    final result = await _routeEngine(
      scope: scope,
      store: store,
      transport: transport,
      applier: applier,
      clock: clock,
      semanticApply: false,
    ).synchronize(trigger: CloudSyncTrigger.manual);
    expect(result.status, CloudSyncRunStatus.completed);
    expect(applier.recoveryCalls, 0);
    expect(applier.appliedSequences, isEmpty);
    expect(transport.pushCallCount, 0);
  });
}
