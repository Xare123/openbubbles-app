import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'cloud_sync_observability.dart';
import 'cloud_sync_read_budget.dart';
import 'cloud_sync_safe_failure.dart';
import 'cloud_sync_semantic_drain_controller.dart';
import 'cloud_sync_semantic_pull_report.dart';

export 'cloud_sync_observability.dart' show CloudSyncProgressPhase;

enum CloudSyncSpeed { regular, turbo }

extension CloudSyncSpeedBudget on CloudSyncSpeed {
  // Foreground work sizing only. Lease, retry and worker limits stay unchanged.
  CloudSyncReadBudget get readBudget => this == CloudSyncSpeed.regular
      ? CloudSyncReadBudget.regular
      : CloudSyncReadBudget.standard;

  int get passesPerBatch => this == CloudSyncSpeed.regular ? 1 : 16;

  // Preserve the per-zone fresh-record caps despite smaller Regular sessions.
  int get maximumBatches => this == CloudSyncSpeed.regular ? 512 : 16;

  Duration get pauseBetweenBatches => this == CloudSyncSpeed.regular
      ? const Duration(milliseconds: 250)
      : const Duration(milliseconds: 1);
}

/// In-memory presentation only. Durable checkpoints, never these counters, own resume.
/// Owned by the service so navigating away does not cancel or duplicate a run.
class CloudSyncProgress extends ChangeNotifier
    implements CloudSyncProgressSink {
  CloudSyncProgressPhase phase = CloudSyncProgressPhase.idle;
  CloudSyncSpeed speed = CloudSyncSpeed.regular;
  bool active = false;
  bool pauseRequested = false;
  bool restartRequired = false;
  String? zone;
  String? safeFailure;
  int batches = 0;
  int pages = 0;
  int fetched = 0;
  int projectionExamined = 0;
  int reprojected = 0;
  int retained = 0;
  int deferred = 0;
  int quarantined = 0;
  bool projectionComplete = false;
  bool hasReport = false;
  bool refreshFailed = false;
  final Map<String, int> zonePages = {};
  final Map<String, int> zoneFetched = {};
  int mediaActive = 0;
  int mediaCompleted = 0;
  int mediaFailed = 0;
  Future<void>? _operation;
  void Function()? cancelWindow;

  static String zoneLabel(String value) => switch (value) {
    'chatManateeZone' => 'Chats',
    'messageManateeZone' => 'Messages',
    'attachmentManateeZone' => 'Attachments',
    _ => 'History',
  };

  /// All history totals are unknown. A configured cap is not a denominator.
  double? get fraction => null;

  String get title => switch (phase) {
    CloudSyncProgressPhase.idle => 'Ready to sync',
    CloudSyncProgressPhase.waiting => 'Waiting for a safe sync window',
    CloudSyncProgressPhase.authentication => 'Checking iCloud authentication',
    CloudSyncProgressPhase.pcs => 'Preparing encrypted history access (PCS)',
    CloudSyncProgressPhase.fetching => 'Fetching ${zone ?? 'history'}',
    CloudSyncProgressPhase.replaying =>
      'Replaying retained dependencies: ${zone ?? 'history'}',
    CloudSyncProgressPhase.pausing => 'Pausing after protected work finishes',
    CloudSyncProgressPhase.paused =>
      pauseRequested ? 'Paused' : 'Paused at the foreground safety limit',
    CloudSyncProgressPhase.remoteHead =>
      projectionComplete
          ? 'Remote history head reached'
          : 'Remote head reached; local dependencies remain',
    CloudSyncProgressPhase.error => 'Sync needs attention',
  };

  @override
  void activity(CloudSyncProgressPhase next, [String? zoneName]) {
    if (!active || pauseRequested) return;
    phase = next;
    zone = zoneName == null ? null : zoneLabel(zoneName);
    notifyListeners();
  }

  void event(String zoneName, CloudSyncEvent event) {
    if (!active) return;
    if (event.type == CloudSyncEventType.fetchCompleted) {
      pages++;
      fetched += event.count;
      final label = zoneLabel(zoneName);
      zonePages.update(label, (n) => n + 1, ifAbsent: () => 1);
      zoneFetched.update(
        label,
        (n) => n + event.count,
        ifAbsent: () => event.count,
      );
    }
    if (event.type == CloudSyncEventType.fetchStarted) {
      activity(CloudSyncProgressPhase.fetching, zoneName);
    } else if (event.type == CloudSyncEventType.inboxApplyStarted) {
      activity(CloudSyncProgressPhase.replaying, zoneName);
    } else {
      notifyListeners();
    }
  }

  @override
  void projectionWindow(int examined, int applied) {
    if (!active) return;
    projectionExamined += examined;
    reprojected += applied;
    notifyListeners();
  }

  void report(CloudSyncSemanticPullReport report) {
    if (!active) return;
    hasReport = true;
    retained = report.zones.fold(0, (n, z) => n + z.retainedUnprojected);
    deferred = report.zones.fold(0, (n, z) => n + z.deferred);
    quarantined = report.zones.fold(0, (n, z) => n + z.quarantined);
    notifyListeners();
  }

  void pause() {
    if (!active || pauseRequested) return;
    pauseRequested = true;
    phase = CloudSyncProgressPhase.pausing;
    cancelWindow?.call();
    notifyListeners();
  }

  void checkPause() {
    if (pauseRequested) throw StateError('cloud_sync_semantic_drain_cancelled');
  }

  /// Page navigation is intentionally not a lifecycle signal. Backgrounding
  /// pauses this foreground session; only the existing Android worker owns
  /// background execution. Resuming the app never silently restarts Turbo.
  void onAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      pause();
    }
  }

  Future<void> startPrepared(
    CloudSyncSpeed selected, {
    required void Function() validate,
    required Future<bool> Function() preparePcs,
    required Future<CloudSyncSemanticDrainResult> Function() readOnlyCatchUp,
  }) => start(selected, () async {
    validate();
    checkPause();
    activity(CloudSyncProgressPhase.pcs);
    final prepared = await preparePcs();
    // Revalidate the same account/lifecycle after any password prompt or IO.
    validate();
    if (!prepared) pause();
    checkPause();
    return readOnlyCatchUp();
  });

  Future<void> start(
    CloudSyncSpeed selected,
    Future<CloudSyncSemanticDrainResult> Function() run,
  ) {
    final existing = _operation;
    if (existing != null) return existing;
    if (restartRequired) return Future<void>.value();
    active = true;
    pauseRequested = false;
    safeFailure = null;
    speed = selected;
    batches = pages = fetched = projectionExamined = reprojected = 0;
    retained = deferred = quarantined = 0;
    projectionComplete = false;
    hasReport = refreshFailed = false;
    zonePages.clear();
    zoneFetched.clear();
    zone = null;
    phase = CloudSyncProgressPhase.waiting;
    // Install ownership before notifying UI or calling an injected runner.
    final operation = Future<void>.microtask(() async {
      try {
        checkPause();
        final result = await run();
        report(result.lastReport);
        projectionComplete =
            result.projectionComplete && result.retainedSaveProjectionComplete;
        phase = pauseRequested
            ? CloudSyncProgressPhase.paused
            : result.remoteDrained
            ? CloudSyncProgressPhase.remoteHead
            : CloudSyncProgressPhase.paused;
      } catch (error) {
        final code = cloudSyncV2SafeFailureCode(error);
        if (code == 'cloud_sync_v2_pcs_restart_required') {
          restartRequired = true;
        }
        // A pause request must never conceal an unrelated safety failure.
        if (pauseRequested && code == 'cloud_sync_semantic_drain_cancelled') {
          phase = CloudSyncProgressPhase.paused;
        } else {
          safeFailure = code;
          phase = CloudSyncProgressPhase.error;
        }
      } finally {
        cancelWindow = null;
        active = false;
        _operation = null;
        notifyListeners();
      }
    });
    _operation = operation;
    notifyListeners();
    return operation;
  }

  Future<T> materialize<T>(Future<T> Function() action) async {
    mediaActive++;
    notifyListeners();
    try {
      final result = await action();
      mediaCompleted++;
      return result;
    } catch (_) {
      mediaFailed++;
      rethrow;
    } finally {
      mediaActive--;
      notifyListeners();
    }
  }
}

/// Preserve evidence observer behavior, including flush failures, unchanged.
class CloudSyncProgressObserver implements FlushableCloudSyncObserver {
  CloudSyncProgressObserver(this.progress, this.zone, this.delegate);
  final CloudSyncProgress progress;
  final String zone;
  final CloudSyncObserver delegate;
  @override
  void onEvent(CloudSyncEvent event) {
    delegate.onEvent(event);
    progress.event(zone, event);
  }

  @override
  Future<void> flush() async {
    if (delegate case FlushableCloudSyncObserver flushable) {
      await flushable.flush();
    }
  }
}
