import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_profile_readiness.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_production_preflight.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncProfileReadiness readiness({
  bool featureAvailable = true,
  bool platformSupported = true,
  bool restartNeeded = false,
  bool accountReady = true,
  bool foreground = true,
  bool legacyEnabledOrRunning = false,
  bool operationActive = false,
  bool localStateReady = true,
  bool coordinatorActive = false,
  bool outboxSettled = true,
}) => CloudSyncProfileReadiness.evaluate(
  featureAvailable: featureAvailable,
  platformSupported: platformSupported,
  restartNeeded: restartNeeded,
  accountReady: accountReady,
  foreground: foreground,
  legacyEnabledOrRunning: legacyEnabledOrRunning,
  operationActive: operationActive,
  localStateReady: localStateReady,
  coordinatorActive: coordinatorActive,
  outboxSettled: outboxSettled,
);

void main() {
  test('Profile receipt check uses the existing shutdown future and fresh admission', () {
    final source = File('lib/services/rustpush/rustpush_service.dart').readAsStringSync();
    final begin = source.indexOf('Future<String> checkCloudSyncV2PreviousUpload()');
    final end = source.indexOf('Future<void> startCloudSyncV2Progress(', begin);
    final check = source.substring(begin, end);
    expect(check, contains('ffi.Abi.current() != ffi.Abi.androidArm64'));
    expect(check, contains('_readCloudSyncV2ProfileReadiness(fresh: true)'));
    expect(check, contains('CloudSyncProfileReadiness.unfinishedUploads'));
    expect(check, contains('_cloudSyncV2OutboundInFlight = future'));
    expect(check, contains('identical(_cloudSyncV2OutboundInFlight, future)'));
    expect(check, contains('checkPreviousUploadReceipt()'));
    expect(check, isNot(contains('runDoubleConfirmed(')));
    expect(check, isNot(contains('startCloudSyncV2Progress(')));
    expect(check, isNot(contains('ensureWriterOwned(')));
    expect(check, isNot(contains('cloudSyncingEnabled.value =')));
    final reset = source.substring(source.indexOf('Future reset(bool hw'));
    expect(reset, contains('_cloudSyncV2OutboundInFlight'));
  });

  test('receipt composition has readback and local finalization but no submission engine', () {
    final source = File('lib/services/rustpush/cloud_sync/cloud_sync_production_sampler_adapter.dart')
        .readAsStringSync();
    final begin = source.indexOf('Future<CloudSyncPreviousUploadResult> checkCloudSyncPreviousMessageUpload(');
    final end = source.indexOf('typedef _CanaryOutboxRead', begin);
    final check = source.substring(begin, end);
    expect(check, contains('verifyConfirmedMessageCreateNoSave('));
    expect(check, contains('commitConfirmedMessageCreateReadback('));
    expect(check, contains('finalizeMessageCreateReadbackLeases('));
    expect(check, contains('settledOutboxFingerprint == null'));
    expect(check, contains('auth.sameIdentity(await readAuth())'));
    expect(check, contains('transport.quiesceNativeOperations()'));
    expect(check, contains('interlock.poisonUntilProcessRestart()'));
    for (final forbidden in ['CloudSyncEngine(', '.flush', '.synchronize(',
      '.prepareMessageCreate(', '.consumeMessageCreate(', '.saveRecords(',
      '.deleteRecords(', '.enqueueOutbox(', '.ensureV2Owned(']) {
      expect(check, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  const clear = CloudSyncLocalPreflightState(
    objectBoxReady: true,
    coordinatorLeaseActive: false,
    outboxCount: 0,
  );
  test('display reads are bounded but admission is always fresh', () {
    var now = DateTime.utc(2026, 9, 15);
    final cache = CloudSyncProfilePreflightCache(clock: () => now);
    final client = Object();
    final store = Object();
    var reads = 0;
    var next = clear;
    CloudSyncLocalPreflightState read() {
      reads++;
      return next;
    }

    for (var i = 0; i < 10; i++) {
      expect(
        cache.readForDisplay(
          client: client,
          store: store,
          storage: 'one',
          read: read,
        ),
        same(clear),
      );
    }
    expect(reads, 1);
    next = const CloudSyncLocalPreflightState.blocked();
    expect(
      cache
          .readFresh(client: client, store: store, storage: 'one', read: read)
          .objectBoxReady,
      isFalse,
    );
    expect(reads, 2);
    now = now.add(const Duration(seconds: 5));
    cache.readForDisplay(
      client: client,
      store: store,
      storage: 'one',
      read: read,
    );
    expect(reads, 3);
  });

  test(
    'account store storage and clock changes invalidate displayed state',
    () {
      var now = DateTime.utc(2026, 9, 15);
      final cache = CloudSyncProfilePreflightCache(clock: () => now);
      var client = Object();
      var store = Object();
      var storage = 'one';
      var reads = 0;
      void check() {
        cache.readForDisplay(
          client: client,
          store: store,
          storage: storage,
          read: () {
            reads++;
            return clear;
          },
        );
      }

      check();
      client = Object();
      check();
      store = Object();
      check();
      storage = 'two';
      check();
      now = now.subtract(const Duration(seconds: 1));
      check();
      expect(reads, 5);
      final failed = cache.readFresh(
        client: client,
        store: store,
        storage: storage,
        read: () => throw StateError('private detail'),
      );
      expect(failed.objectBoxReady, isFalse);
      expect(failed.coordinatorLeaseActive, isTrue);
      expect(failed.settledOutboxFingerprint, isNull);
    },
  );
  test('ordinary Profile readiness has no Developer Mode prerequisite', () {
    expect(readiness(), CloudSyncProfileReadiness.ready);
    expect(readiness().message, isNull);
  });

  test(
    'all build identity lifecycle and durable-state blockers remain closed',
    () {
      final blocked = <CloudSyncProfileReadiness, CloudSyncProfileReadiness>{
        readiness(featureAvailable: false):
            CloudSyncProfileReadiness.buildUnavailable,
        readiness(platformSupported: false):
            CloudSyncProfileReadiness.platformUnsupported,
        readiness(restartNeeded: true):
            CloudSyncProfileReadiness.restartRequired,
        readiness(accountReady: false):
            CloudSyncProfileReadiness.accountRequired,
        readiness(foreground: false):
            CloudSyncProfileReadiness.foregroundRequired,
        readiness(legacyEnabledOrRunning: true):
            CloudSyncProfileReadiness.legacySyncActive,
        readiness(operationActive: true):
            CloudSyncProfileReadiness.anotherOperation,
        readiness(localStateReady: false):
            CloudSyncProfileReadiness.localStateUnavailable,
        readiness(outboxSettled: false):
            CloudSyncProfileReadiness.unfinishedUploads,
      };
      for (final entry in blocked.entries) {
        expect(entry.key, entry.value);
        expect(entry.key.message, isNotEmpty);
        expect(
          cloudSyncV2SafeFailureCode(StateError(entry.key.safeCode)),
          entry.key.safeCode,
        );
      }
      expect(
        readiness(coordinatorActive: true),
        CloudSyncProfileReadiness.anotherOperation,
      );
    },
  );

  test('restart and account blockers are not described as a harmless wait', () {
    expect(
      readiness(restartNeeded: true, operationActive: true),
      CloudSyncProfileReadiness.restartRequired,
    );
    expect(
      readiness(accountReady: false, coordinatorActive: true),
      CloudSyncProfileReadiness.accountRequired,
    );
    expect(
      readiness(legacyEnabledOrRunning: true, coordinatorActive: true),
      CloudSyncProfileReadiness.legacySyncActive,
    );
  });

  test(
    'Profile calls private shared preparation/read while diagnostic APIs stay guarded',
    () {
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<void> startCloudSyncV2Progress(');
      final end = source.indexOf('/// Content-free lifecycle state', start);
      final profile = source.substring(start, end);
      expect(profile, contains('_prepareCloudSyncV2ProfilePcs('));
      expect(profile, contains('_runCloudSyncV2ProfileCatchUpReadOnly('));
      expect(profile, contains('readiness != CloudSyncProfileReadiness.ready'));
      expect(
        profile,
        contains('_readCloudSyncV2ProfileReadiness(fresh: true)'),
      );
      expect(profile, contains('_validateCloudSyncV2QueuedRead('));
      expect(profile, isNot(contains('_cloudSyncV2DeveloperRuntimeAllowed')));
      expect(profile, isNot(contains('cloudSyncingEnabled.value =')));
      expect(profile, isNot(contains('_queueCloudSyncV2LocalSends(')));
      for (final pair in [
        ('prepareCloudSyncV2PcsConfirmed({', '_prepareCloudSyncV2ProfilePcs('),
        (
          'runCloudSyncV2AutomaticSemanticCatchUpReadOnly({',
          '_runCloudSyncV2ProfileCatchUpReadOnly(',
        ),
      ]) {
        final begin = source.indexOf(pair.$1);
        final stop = source.indexOf(pair.$2, begin);
        final wrapper = source.substring(begin, stop);
        expect(wrapper, contains('_cloudSyncV2DeveloperRuntimeAllowed'));
        expect(wrapper, contains('cloud_sync_developer_mode_required'));
      }
    },
  );
}
