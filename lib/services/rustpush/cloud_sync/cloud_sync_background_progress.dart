import 'cloud_sync_background_status.dart';
import 'cloud_sync_observability.dart';

/// Content-free, in-memory display of one background read batch. This object
/// has no pause, scheduler, authentication, persistence or upload capability.
/// A fresh instance per batch prevents stale reports from looking like live work.
class CloudSyncBackgroundProgress implements CloudSyncProgressSink {
  CloudSyncBackgroundProgress({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  bool _active = true;
  CloudSyncBackgroundStage _stage = CloudSyncBackgroundStage.checking;
  DateTime? _lastProgressAt;
  int _downloaded = 0;
  int _restored = 0;

  CloudSyncBackgroundStatus get snapshot => CloudSyncBackgroundStatus(
    active: _active,
    owner: CloudSyncBackgroundOwner.historyCatchUp,
    stage: _stage,
    downloaded: _downloaded,
    restored: _restored,
    lastProgressAt: _lastProgressAt,
  );

  @override
  void activity(CloudSyncProgressPhase phase, [String? zone]) {
    if (!_active) return;
    _stage = switch (phase) {
      CloudSyncProgressPhase.fetching => CloudSyncBackgroundStage.downloading,
      CloudSyncProgressPhase.replaying => CloudSyncBackgroundStage.organizing,
      CloudSyncProgressPhase.pausing ||
      CloudSyncProgressPhase.remoteHead => CloudSyncBackgroundStage.settling,
      _ => CloudSyncBackgroundStage.checking,
    };
    _lastProgressAt = _clock();
  }

  void event(CloudSyncEvent event) {
    if (!_active) return;
    switch (event.type) {
      case CloudSyncEventType.fetchStarted:
        activity(CloudSyncProgressPhase.fetching);
      case CloudSyncEventType.inboxApplyStarted:
        activity(CloudSyncProgressPhase.replaying);
      case CloudSyncEventType.fetchCompleted:
        if (event.count >= 0) _downloaded += event.count;
      case CloudSyncEventType.inboxApplied:
        if (event.count >= 0) _restored += event.count;
      default:
        break;
    }
    // Use receipt time, not an untrusted/raw event value or scope identifier.
    _lastProgressAt = _clock();
  }

  @override
  void projectionWindow(int examined, int applied) {
    if (!_active) return;
    if (applied >= 0 && examined >= applied) _restored += applied;
    activity(CloudSyncProgressPhase.replaying);
  }

  void finish() => _active = false;
}

/// Existing evidence remains authoritative: preserve its events and flush
/// failures. The display only observes their fixed counts and event kinds.
class CloudSyncBackgroundProgressObserver
    implements FlushableCloudSyncObserver {
  CloudSyncBackgroundProgressObserver(this.progress, this.delegate);

  final CloudSyncBackgroundProgress progress;
  final CloudSyncObserver delegate;

  @override
  void onEvent(CloudSyncEvent event) {
    delegate.onEvent(event);
    progress.event(event);
  }

  @override
  Future<void> flush() async {
    if (delegate case FlushableCloudSyncObserver flushable) {
      await flushable.flush();
    }
  }
}
