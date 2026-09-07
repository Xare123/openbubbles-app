import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_feed_probe.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('probe requires one retained snapshot basename', () {
    expect(
      cloudSyncWindowsFeedProbeSnapshot({
        'version': 1,
        'snapshot': 'windows-write-before-fixture-01',
      }),
      'windows-write-before-fixture-01',
    );
    for (final name in [
      '',
      '../alpha',
      r'..\alpha',
      'C:\\alpha',
      'windows-write-before-../alpha',
      'windows-write-before-a/b',
      'windows-write-before-a\\b',
      'windows-write-before-${'a' * 65}',
    ]) {
      expect(
        () =>
            cloudSyncWindowsFeedProbeSnapshot({'version': 1, 'snapshot': name}),
        throwsStateError,
      );
    }
    expect(
      () => cloudSyncWindowsFeedProbeSnapshot({
        'version': 2,
        'snapshot': 'windows-write-before-fixture',
      }),
      throwsStateError,
    );
    expect(() => cloudSyncWindowsFeedProbeSnapshot(null), throwsStateError);
  });

  test('probe is an explicit exclusive read operation', () {
    expect(
      CloudSyncV2WindowsHarnessOperation.parse([
        'probe-message-feed',
        '--launch-id=0123456789abcdef0123456789abcdef',
      ]),
      CloudSyncV2WindowsHarnessOperation.messageFeedProbe,
    );
    expect(
      () => CloudSyncV2WindowsHarnessOperation.parse([
        'probe-message-feed',
        'local-write',
      ]),
      throwsStateError,
    );
  });
  test(
    'version two binds snapshot to exact write request, not newest outbox',
    () {
      final request = {
        'version': 2,
        'writeRequestId': 'fixture-02',
        'snapshot': 'windows-write-before-fixture-02',
      };
      expect(cloudSyncWindowsFeedProbeSnapshot(request), request['snapshot']);
      for (final id in ['../alpha', '', 'fixture-01']) {
        expect(
          () => cloudSyncWindowsFeedProbeSnapshot({
            ...request,
            'writeRequestId': id,
          }),
          throwsStateError,
        );
      }
    },
  );

  test('probe cannot commit, project, send or change a checkpoint', () {
    final source = File(
      'lib/cloud_sync_v2_windows_feed_probe.dart',
    ).readAsStringSync();
    for (final forbidden in [
      'journalFetchedBatch(',
      'cloudSyncCommitProtectedPageLease(',
      'sendConfirmed(',
      'runExactIntent(',
      '.put(',
      'readCheckpoint(',
    ]) {
      expect(source, isNot(contains(forbidden)));
    }
    expect(source, contains('cloudSyncFetchProtectedPageUnderWriterPause('));
    expect(source, contains('cloudSyncRollbackProtectedPageLease('));
    expect(
      source,
      matches(
        RegExp(r'finally\s*\{\s*await pause\.resume\(pauseToken\);\s*\}'),
      ),
    );
    expect(
      source,
      contains('cloud_sync_windows_feed_probe_checkpoint_changed'),
    );
  });
}
