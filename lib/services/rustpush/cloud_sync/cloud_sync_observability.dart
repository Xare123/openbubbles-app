import 'cloud_shadow_journal_budget.dart';
import 'cloud_sync_models.dart';

enum CloudSyncEventType {
  runStarted,
  runSkipped,
  fetchCompleted,
  inboxApplied,
  outboxFlushed,
  authenticationRefreshed,
  pcsRefreshed,
  serverConflictReconciled,
  backoffScheduled,
  shadowJournalBlocked,
  inboxAppliedFloorStalled,
  runCompleted,
  runFailed,
  runCancelled,
}

enum CloudSyncTrigger {
  startup,
  networkReconnect,
  localOutbox,
  idsReconnect,
  detectedGap,
  manual,
  notificationHint,
}

enum CloudSyncSkipReason {
  localRunActive,
  coordinatorLeaseUnavailable,
  pullBackoffActive,
  featureDisabled,
}

enum CloudSyncAppliedFloorBlockReason { pending, quarantined }

/// Redacted, bounded event. It has no arbitrary message field by design.
class CloudSyncEvent {
  const CloudSyncEvent({
    required this.type,
    required this.scopeDiagnosticKey,
    required this.at,
    this.trigger,
    this.failureCategory,
    this.skipReason,
    this.shadowJournalBlockReason,
    this.appliedFloorBlockReason,
    this.count = 0,
    this.estimatedBytes = 0,
    this.attempt = 0,
    this.elapsed = Duration.zero,
  });

  final CloudSyncEventType type;
  final String scopeDiagnosticKey;
  final DateTime at;
  final CloudSyncTrigger? trigger;
  final CloudFailureCategory? failureCategory;
  final CloudSyncSkipReason? skipReason;
  final CloudShadowJournalBlockReason? shadowJournalBlockReason;
  final CloudSyncAppliedFloorBlockReason? appliedFloorBlockReason;
  final int count;
  final int estimatedBytes;
  final int attempt;
  final Duration elapsed;

  @override
  String toString() {
    return 'CloudSyncEvent('
        'type=${type.name}, '
        'scope=$scopeDiagnosticKey, '
        'trigger=${trigger?.name ?? 'none'}, '
        'failure=${failureCategory?.name ?? 'none'}, '
        'skip=${skipReason?.name ?? 'none'}, '
        'journalBlock=${shadowJournalBlockReason?.name ?? 'none'}, '
        'floorBlock=${appliedFloorBlockReason?.name ?? 'none'}, '
        'count=$count, estimatedBytes=$estimatedBytes, attempt=$attempt, '
        'elapsedMs=${elapsed.inMilliseconds})';
  }
}

abstract interface class CloudSyncObserver {
  void onEvent(CloudSyncEvent event);
}

class NoopCloudSyncObserver implements CloudSyncObserver {
  const NoopCloudSyncObserver();

  @override
  void onEvent(CloudSyncEvent event) {}
}

class MemoryCloudSyncObserver implements CloudSyncObserver {
  static const int maximumAllowedEvents = 4096;

  MemoryCloudSyncObserver({this.maximumEvents = 256}) {
    if (maximumEvents <= 0 || maximumEvents > maximumAllowedEvents) {
      throw ArgumentError('cloud_sync_observer_capacity_invalid');
    }
  }

  final int maximumEvents;
  final List<CloudSyncEvent> _events = [];

  List<CloudSyncEvent> get events => List.unmodifiable(_events);

  @override
  void onEvent(CloudSyncEvent event) {
    if (_events.length == maximumEvents) {
      _events.removeAt(0);
    }
    _events.add(event);
  }
}
