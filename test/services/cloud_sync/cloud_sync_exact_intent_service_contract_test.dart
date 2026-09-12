import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// These are composition checks, not substitutes for the exact-selection
// behavioral tests, native validation, or a real device roundtrip.
void main() {
  final source = File(
    'lib/services/rustpush/rustpush_service.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final panel = File(
    'lib/app/layouts/settings/pages/misc/troubleshoot_panel.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test(
    'manual selection reads only the newest current-owner journal origin',
    () {
      final start = source.indexOf('selectCloudSyncV2ExactIntent({');
      final end = source.indexOf('runCloudSyncV2ExactIntentConfirmed(', start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final select = source.substring(start, end);
      final normalized = select
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(' .', '.');
      expect(normalized, contains('CloudSyncDevGate.localSendRuntimeEnabled'));
      expect(normalized, contains('box<CloudSyncLocalSendIntentEntity>()'));
      expect(normalized, isNot(contains('box<Message>()')));
      expect(
        normalized,
        contains('accountFingerprint.equals(auth.accountFingerprint)'),
      );
      expect(
        normalized,
        matches(RegExp(r'writerEpoch\.equals\(\s*owner\.epoch\s*,?\s*\)')),
      );
      expect(normalized, contains('createdAtMs, flags: Order.descending'));
      expect(normalized, contains('..limit = 1'));
      expect(normalized, contains('journal.readExactIntent('));
      expect(normalized, contains('adapter.runExactIntent('));
      expect(normalized, contains('expectedSourceSha256: source.sourceSha256'));
      expect(normalized, isNot(contains('admitMessage(')));
    },
  );

  test('exact writer releases its pass gate before semantic readback', () {
    final start = source.indexOf('runCloudSyncV2ExactIntentConfirmed(');
    final end = source.indexOf(
      'Future<List<String>> _readCloudSyncV2ActiveHandles',
      start,
    );
    final run = source.substring(start, end);
    final consumed = run.indexOf('selection._consumed = true');
    final first = run.indexOf('await _cloudSyncV2AttachmentGate.run(');
    final read = run.indexOf(
      'await runCloudSyncV2ManualSemanticPullConfirmed(',
    );
    final next = run.indexOf('return _cloudSyncV2AttachmentGate.run(', read);
    expect(consumed, greaterThan(0));
    expect(first, greaterThan(consumed));
    expect(read, greaterThan(first));
    expect(next, greaterThan(read));
    final readback = run.substring(read, next);
    expect(readback, contains('maximumPasses: 1,'));
    expect(readback, contains('resumeAutomaticUploads: false,'));
    expect(run, isNot(contains('_queueCloudSyncV2LocalSends')));
    expect(
      run,
      contains(
        'if (!first.chatReadbackPending || first.outboxBlocked) return first;',
      ),
    );
    expect(run, contains('_cloudSyncV2OutboundInFlight = future;'));
    expect(run, contains('identical(_cloudSyncV2OutboundInFlight, future)'));
    expect(run, isNot(contains('Timer(')));
  });

  test(
    'developer control requires two confirmations and does not enable automatic uploads',
    () {
      final start = panel.indexOf(
        'Future<void> _runCloudSyncV2ExactIntentCanary()',
      );
      final end = panel.indexOf(
        'Future<void> _runCloudSyncV2OutboundCanary()',
        start,
      );
      final flow = panel.substring(start, end);
      expect('_confirmCloudSyncV2Outbound('.allMatches(flow).length, 2);
      expect(
        flow.indexOf('prepareCloudSyncV2OutboundWriter()'),
        lessThan(flow.indexOf('selectCloudSyncV2ExactIntent(')),
      );
      expect(
        flow.indexOf('selectCloudSyncV2ExactIntent('),
        lessThan(flow.indexOf('runCloudSyncV2ExactIntentConfirmed(selection)')),
      );
      expect(flow, contains('CloudSyncDevGate.localSendRuntimeEnabled'));
      expect(flow, isNot(contains('_queueCloudSyncV2LocalSends')));
      expect(
        flow,
        contains('A completed pass alone does not prove cross-device sync.'),
      );
    },
  );
}
