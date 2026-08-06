import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_runtime.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  CloudSyncEngine engineFor({
    required String zone,
    required FakeCloudSyncTransport transport,
    CloudSyncFeatureFlags flags = const CloudSyncFeatureFlags(),
    Duration? fetchDelay,
  }) {
    final baseScope = testScope();
    final scope = CloudSyncScope(
      accountFingerprint: baseScope.accountFingerprint,
      container: baseScope.container,
      database: baseScope.database,
      zone: zone,
      streamKind: baseScope.streamKind,
      schemaVersion: baseScope.schemaVersion,
    );
    final scoped = CloudSyncEngine(
      scope: scope,
      coordinatorId: 'runtime-test-$zone',
      store: InMemoryCloudSyncStore(),
      transport: transport,
      inboxApplier: FakeCloudInboxApplier(),
      config: CloudSyncEngineConfig(flags: flags),
    );
    if (fetchDelay != null) {
      transport.fetchHandler = (scope, previousToken, generation, limit) async {
        await Future<void>.delayed(fetchDelay);
        return emptyBatch(scope, previousToken);
      };
    }
    return scoped;
  }

  test(
    'runs each read-only scope sequentially and exposes bounded results',
    () async {
      final first = FakeCloudSyncTransport();
      final second = FakeCloudSyncTransport();
      final runtime = CloudSyncShadowRuntime(
        engines: [
          engineFor(zone: 'chat-zone', transport: first),
          engineFor(zone: 'message-zone', transport: second),
        ],
        debounce: Duration.zero,
      );

      final results = await runtime.synchronizeNow();

      expect(results, hasLength(2));
      expect(first.fetchCallCount, 1);
      expect(second.fetchCallCount, 1);
      expect(runtime.lastResults, hasLength(2));
      expect(runtime.isRunning, isFalse);
      await runtime.dispose();
    },
  );

  test('coalesces reconnect bursts into one shadow pass', () async {
    final transport = FakeCloudSyncTransport();
    final runtime = CloudSyncShadowRuntime(
      engines: [engineFor(zone: 'message-zone', transport: transport)],
      debounce: const Duration(milliseconds: 20),
      automaticTriggersEnabled: true,
    );

    runtime.onStartup();
    runtime.onNetworkReconnect();
    runtime.onIdsReconnect();
    await runtime.waitUntilIdle();

    expect(transport.fetchCallCount, 1);
    await runtime.dispose();
  });

  test('automatic triggers stay dormant by default', () async {
    final transport = FakeCloudSyncTransport();
    final runtime = CloudSyncShadowRuntime(
      engines: [engineFor(zone: 'message-zone', transport: transport)],
      debounce: Duration.zero,
    );

    runtime.onStartup();
    runtime.onNetworkReconnect();
    runtime.onIdsReconnect();
    runtime.onDetectedGap();
    await runtime.waitUntilIdle();

    expect(runtime.automaticTriggersEnabled, isFalse);
    expect(transport.fetchCallCount, 0);

    await runtime.synchronizeNow();
    expect(transport.fetchCallCount, 1);
    await runtime.dispose();
  });

  test('rejects any engine capable of mutating local or CloudKit state', () {
    final dangerousFlags = [
      const CloudSyncFeatureFlags(readOnlyFetch: false),
      const CloudSyncFeatureFlags(semanticApply: true),
      const CloudSyncFeatureFlags(saves: true),
      const CloudSyncFeatureFlags(deletions: true),
      const CloudSyncFeatureFlags(profiles: true),
      const CloudSyncFeatureFlags(notificationHints: true),
    ];

    for (final flags in dangerousFlags) {
      expect(
        () => CloudSyncShadowRuntime(
          engines: [
            engineFor(
              zone: 'message-zone',
              transport: FakeCloudSyncTransport(),
              flags: flags,
            ),
          ],
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'dispose cancels the active scope and suppresses queued scopes',
    () async {
      final first = FakeCloudSyncTransport();
      final second = FakeCloudSyncTransport();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      first.fetchHandler = (scope, previousToken, generation, limit) async {
        firstStarted.complete();
        await releaseFirst.future;
        return emptyBatch(scope, previousToken);
      };
      final runtime = CloudSyncShadowRuntime(
        engines: [
          engineFor(zone: 'chat-zone', transport: first),
          engineFor(zone: 'message-zone', transport: second),
        ],
        debounce: Duration.zero,
        automaticTriggersEnabled: true,
      );

      runtime.onStartup();
      await firstStarted.future;
      final firstDispose = runtime.dispose();
      final repeatedDispose = runtime.dispose();

      expect(identical(firstDispose, repeatedDispose), isTrue);
      expect(runtime.isRunning, isTrue);
      releaseFirst.complete();
      await repeatedDispose;

      expect(first.fetchCallCount, 1);
      expect(second.fetchCallCount, 0);
      expect(runtime.isDisposed, isTrue);
      expect(runtime.isRunning, isFalse);
      expect(runtime.hasPendingWork, isFalse);
    },
  );
}

CloudFetchBatch emptyBatch(CloudSyncScope scope, String? token) {
  return CloudFetchBatch(
    scope: scope,
    changes: const [],
    batchId: 'runtime-empty-${scope.zone}',
    generation: 1,
    nextToken: token,
    hasMore: false,
  );
}
