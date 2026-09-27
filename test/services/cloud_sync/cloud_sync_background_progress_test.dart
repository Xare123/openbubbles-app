import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_status.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncEvent event(CloudSyncEventType type, {int count = 0}) =>
    CloudSyncEvent(
      type: type,
      count: count,
      scopeDiagnosticKey: 'must-not-appear-in-presentation',
      at: DateTime.utc(2099),
    );

class Evidence implements FlushableCloudSyncObserver {
  final events = <CloudSyncEvent>[];
  bool failEvent = false;
  bool failFlush = false;
  int flushes = 0;

  @override
  void onEvent(CloudSyncEvent value) {
    if (failEvent) throw StateError('evidence failed');
    events.add(value);
  }

  @override
  Future<void> flush() async {
    flushes++;
    if (failFlush) throw StateError('flush failed');
  }
}

void main() {
  test('background display separates downloads and applied records', () {
    var now = DateTime.utc(2026, 9, 27);
    final progress = CloudSyncBackgroundProgress(clock: () => now);
    expect(progress.snapshot.active, isTrue);
    expect(progress.snapshot.lastProgressAt, isNull);
    progress.activity(CloudSyncProgressPhase.authentication, 'private-zone');
    expect(progress.snapshot.stage, CloudSyncBackgroundStage.checking);
    now = now.add(const Duration(seconds: 1));
    progress.event(event(CloudSyncEventType.fetchStarted));
    progress.event(event(CloudSyncEventType.fetchCompleted, count: 6));
    expect(progress.snapshot.stage, CloudSyncBackgroundStage.downloading);
    progress.event(event(CloudSyncEventType.inboxApplyStarted));
    progress.event(event(CloudSyncEventType.inboxApplied, count: 3));
    progress.projectionWindow(40, 4);
    expect(progress.snapshot.stage, CloudSyncBackgroundStage.organizing);
    expect(progress.snapshot.downloaded, 6);
    expect(progress.snapshot.restored, 7);
    expect(progress.snapshot.lastProgressAt, now);
    expect(
      backgroundStatusDetail(progress.snapshot),
      'This batch: 6 downloaded, 7 restored',
    );
    expect(
      backgroundStatusHeadline(progress.snapshot),
      isNot(contains('private-zone')),
    );
  });

  test(
    'ended batches cannot receive late updates and new batches start empty',
    () {
      final progress = CloudSyncBackgroundProgress();
      progress.event(event(CloudSyncEventType.fetchCompleted, count: 5));
      progress.finish();
      final endedAt = progress.snapshot.lastProgressAt;
      progress.event(event(CloudSyncEventType.fetchCompleted, count: 11));
      progress.projectionWindow(12, 6);
      progress.activity(CloudSyncProgressPhase.pcs);
      expect(progress.snapshot.active, isFalse);
      expect(progress.snapshot.downloaded, 5);
      expect(progress.snapshot.restored, 0);
      expect(progress.snapshot.lastProgressAt, endedAt);
      final next = CloudSyncBackgroundProgress();
      expect(next.snapshot.downloaded, 0);
      expect(next.snapshot.restored, 0);
      expect(next.snapshot.lastProgressAt, isNull);
    },
  );

  test('invalid counts cannot reduce or invent successful work', () {
    final progress = CloudSyncBackgroundProgress();
    progress.event(event(CloudSyncEventType.fetchCompleted, count: -1));
    progress.event(event(CloudSyncEventType.inboxApplied, count: -3));
    progress.projectionWindow(1, 2);
    progress.projectionWindow(1, -1);
    expect(progress.snapshot.downloaded, 0);
    expect(progress.snapshot.restored, 0);
  });

  test('observer preserves evidence identity and flush failures', () async {
    final evidence = Evidence();
    final progress = CloudSyncBackgroundProgress();
    final observer = CloudSyncBackgroundProgressObserver(progress, evidence);
    final value = event(CloudSyncEventType.fetchCompleted, count: 8);
    observer.onEvent(value);
    expect(identical(evidence.events.single, value), isTrue);
    expect(progress.snapshot.downloaded, 8);
    await observer.flush();
    expect(evidence.flushes, 1);
    evidence.failFlush = true;
    await expectLater(observer.flush(), throwsStateError);
    evidence.failEvent = true;
    expect(() => observer.onEvent(value), throwsStateError);
    expect(progress.snapshot.downloaded, 8);
  });

  test('service wires presentation only without changing reader policy', () {
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final start = service.indexOf(
      '_runCloudSyncV2ManualSemanticPullWithScheduledSessions({',
    );
    final end = service.indexOf(
      'bool get cloudSyncV2ManualOutboundAvailable',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final read = service.substring(start, end);
    expect(read, contains('progress: progress ?? backgroundProgress'));
    expect(
      read,
      contains(
        'readBudget: progress?.speed.readBudget ?? CloudSyncReadBudget.standard',
      ),
    );
    expect(read, contains('finishActiveRemotePassOnCancel: progress != null'));
    expect(
      read,
      contains(
        'sweepRetainedAtHead: sweepRetainedAtHead && !allowAndroidBackgroundIsolate',
      ),
    );
    expect(read, contains('backgroundProgress?.finish()'));
    expect(
      read,
      contains('identical(_cloudSyncV2BackgroundProgress, backgroundProgress)'),
    );
    final getterStart = service.indexOf(
      'CloudSyncBackgroundStatus? get cloudSyncV2BackgroundStatus',
    );
    final getterEnd = service.indexOf(
      'bool get cloudSyncV2ReceiptCheckActive',
      getterStart,
    );
    final getter = service.substring(getterStart, getterEnd);
    expect(
      getter,
      contains('!cloudSyncV2HistoryReadActive || cloudSyncV2Progress.active'),
    );
    for (final forbidden in [
      'File(',
      'Directory(',
      'api.',
      'await ',
      'readAs',
    ]) {
      expect(getter, isNot(contains(forbidden)));
    }
    final panel = File(
      'lib/app/layouts/settings/pages/profile/profile_panel.dart',
    ).readAsStringSync();
    expect(
      panel,
      contains(
        'backgroundStatus: () => pushService.cloudSyncV2BackgroundStatus',
      ),
    );
  });

  test('settled receipt text does not promise the reader can start', () {
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    expect(service, contains('The queued upload is confirmed in iCloud. '));
    expect(service, contains('The previous upload is confirmed. '));
    expect(service, isNot(contains('You can start or resume history sync.')));
  });
}
