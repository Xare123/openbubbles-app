import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_platform.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_runtime.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_testing.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test_helpers.dart';

void main() {
  CloudSyncPlatformContext context({
    String account = testAccountFingerprintA,
    String storage = r'C:\private\openbubbles',
  }) {
    return CloudSyncPlatformContext(
      platform: CloudSyncPlatformKind.windows,
      architecture: CloudSyncArchitecture.arm64,
      accountFingerprint: account,
      privateStorageDirectory: storage,
    );
  }

  (CloudSyncPlatformAdapter, FakeCloudSyncTransport) adapterFor(
    CloudSyncPlatformContext platformContext, {
    bool manualSamplerEnabled = false,
    CloudSyncPlatformTriggerPolicy triggerPolicy =
        const CloudSyncPlatformTriggerPolicy(),
    bool automaticTriggerRolloutEnabled = false,
  }) {
    final transport = FakeCloudSyncTransport();
    final scope = testScope(account: platformContext.accountFingerprint);
    final engine = CloudSyncEngine(
      scope: scope,
      coordinatorId: 'platform-${platformContext.accountFingerprint}',
      store: InMemoryCloudSyncStore(),
      transport: transport,
      inboxApplier: FakeCloudInboxApplier(),
      config: CloudSyncEngineConfig(
        flags: const CloudSyncFeatureFlags(
          readOnlyFetch: true,
          semanticApply: false,
          saves: false,
          deletions: false,
          profiles: false,
          notificationHints: false,
        ),
      ),
    );
    return (
      CloudSyncPlatformAdapter(
        context: platformContext,
        runtime: CloudSyncShadowRuntime(
          engines: [engine],
          debounce: Duration.zero,
          automaticTriggersEnabled: false,
        ),
        triggerPolicy: triggerPolicy,
        manualSamplerEnabled: manualSamplerEnabled,
        automaticTriggerRolloutEnabled: automaticTriggerRolloutEnabled,
      ),
      transport,
    );
  }

  test('validates account and private storage boundaries', () {
    expect(() => context(account: ' '), throwsArgumentError);
    expect(() => context(storage: r'C:\'), throwsArgumentError);
    expect(() => context(storage: 'relative/path'), throwsArgumentError);
    expect(
      context(storage: '/data/user/0/app/files').privateStorageDirectory,
      '/data/user/0/app/files',
    );
  });

  test('all future platform wake sources remain inert by default', () async {
    final (adapter, transport) = adapterFor(context());

    adapter.onAndroidApnsWake();
    adapter.onAndroidWorkManagerWake();
    adapter.onWindowsStartup();
    adapter.onWindowsResume();
    adapter.onNetworkReconnect();
    await Future<void>.delayed(Duration.zero);

    expect(transport.fetchCallCount, 0);
    await adapter.dispose();
  });

  test(
    'automatic wake stays inert even when source policy is staged',
    () async {
      final (adapter, transport) = adapterFor(
        context(),
        triggerPolicy: const CloudSyncPlatformTriggerPolicy(
          androidApnsWake: true,
          androidWorkManagerWake: true,
          windowsStartup: true,
          windowsResume: true,
          networkReconnect: true,
        ),
        automaticTriggerRolloutEnabled: true,
      );

      adapter.onAndroidApnsWake();
      adapter.onAndroidWorkManagerWake();
      adapter.onWindowsStartup();
      adapter.onWindowsResume();
      adapter.onNetworkReconnect();
      await Future<void>.delayed(Duration.zero);

      // The owned shadow runtime is also required to remain dormant.
      expect(transport.fetchCallCount, 0);
      await adapter.dispose();
    },
  );

  test('manual sampler requires an explicit composition gate', () async {
    final (disabled, disabledTransport) = adapterFor(context());
    expect(disabled.synchronizeNow, throwsStateError);
    expect(disabledTransport.fetchCallCount, 0);
    await disabled.dispose();

    final (enabled, enabledTransport) = adapterFor(
      context(),
      manualSamplerEnabled: true,
    );
    final results = await enabled.synchronizeNow();
    expect(results, hasLength(1));
    expect(enabledTransport.fetchCallCount, 1);
    await enabled.dispose();
  });

  test(
    'account switch disposes old runtime before installing new one',
    () async {
      final host = CloudSyncPlatformHost();
      final firstContext = context(account: testAccountFingerprintA);
      final secondContext = context(account: testAccountFingerprintB);
      final (first, _) = adapterFor(firstContext);
      final (second, _) = adapterFor(secondContext);

      await host.activate(context: firstContext, build: (_) async => first);
      await host.activate(context: secondContext, build: (_) async => second);

      expect(first.isDisposed, isTrue);
      expect(host.active, same(second));
      expect(host.active!.context.accountFingerprint, testAccountFingerprintB);
      await host.dispose();
      expect(second.isDisposed, isTrue);
    },
  );

  test('rejects a builder that returns another account context', () async {
    final host = CloudSyncPlatformHost();
    final requested = context(account: testAccountFingerprintA);
    final (wrong, _) = adapterFor(context(account: testAccountFingerprintB));

    await expectLater(
      host.activate(context: requested, build: (_) async => wrong),
      throwsStateError,
    );
    expect(wrong.isDisposed, isTrue);
    expect(host.active, isNull);
  });

  test('a newer activation supersedes and disposes a delayed build', () async {
    final host = CloudSyncPlatformHost();
    final firstContext = context(account: testAccountFingerprintA);
    final secondContext = context(account: testAccountFingerprintB);
    final (first, _) = adapterFor(firstContext);
    final (second, _) = adapterFor(secondContext);
    final releaseFirst = Completer<void>();

    final delayed = host.activate(
      context: firstContext,
      build: (_) async {
        await releaseFirst.future;
        return first;
      },
    );
    await host.activate(context: secondContext, build: (_) async => second);
    releaseFirst.complete();

    await expectLater(delayed, throwsStateError);
    expect(first.isDisposed, isTrue);
    expect(host.active, same(second));
    await host.dispose();
  });
}
