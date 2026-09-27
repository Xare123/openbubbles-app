import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_status.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('background headline names owner and stage without totals', () {
    const status = CloudSyncBackgroundStatus(active: true, owner: CloudSyncBackgroundOwner.historyCatchUp, stage: CloudSyncBackgroundStage.downloading, recordsProcessed: 42);
    expect(backgroundStatusHeadline(status), 'Background history sync is downloading');
    expect(backgroundStatusDetail(status), '42 records processed');
    expect(backgroundStatusHeadline(status), isNot(contains('%')));
  });
  test('unknown detail is omitted, never invented', () {
    const status = CloudSyncBackgroundStatus(active: true);
    expect(backgroundStatusHeadline(status), 'Background sync is active');
    expect(backgroundStatusDetail(status), isNull);
    expect(backgroundStatusRecency(status, DateTime.utc(2026, 9, 26, 12, 0)), isNull);
  });
  test('recency renders just now, minutes and hour cap', () {
    final now = DateTime.utc(2026, 9, 26, 12, 0);
    final recent = CloudSyncBackgroundStatus(active: true, lastProgressAt: now.subtract(const Duration(seconds: 30)));
    expect(backgroundStatusRecency(recent, now), 'Active just now');
    final minutes = CloudSyncBackgroundStatus(active: true, lastProgressAt: now.subtract(const Duration(minutes: 5)));
    expect(backgroundStatusRecency(minutes, now), 'Last activity 5 min ago');
    final old = CloudSyncBackgroundStatus(active: true, lastProgressAt: now.subtract(const Duration(hours: 2)));
    expect(backgroundStatusRecency(old, now), 'Last activity over an hour ago');
    final future = CloudSyncBackgroundStatus(active: true, lastProgressAt: now.add(const Duration(minutes: 1)));
    expect(backgroundStatusRecency(future, now), isNull);
  });
  test('receipt follow-up distinguishes busy, idle and blocked', () {
    expect(receiptFollowUpCopy(backgroundBusy: true, canStartNow: false), 'Background sync is active.');
    expect(receiptFollowUpCopy(backgroundBusy: false, canStartNow: true), 'Sync is idle. You can start or resume.');
    expect(receiptFollowUpCopy(backgroundBusy: false, canStartNow: false), isNull);
  });
}
