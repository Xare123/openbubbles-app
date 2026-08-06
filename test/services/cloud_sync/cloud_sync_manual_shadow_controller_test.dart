import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_shadow_controller.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudSyncShadowReport report() => CloudSyncShadowReport(
    runId: 'shadow-test',
    correlationTag: 'ephemeral',
    timestampUtc: DateTime.utc(2026, 8, 2),
    platform: 'android',
    architecture: 'arm64',
    buildCommit: 'test',
    legacySyncEnabled: false,
    pageLimit: 1,
    changeLimit: 50,
    tripwiresArmed: true,
    outboxCountBefore: 0,
    outboxCountAfter: 0,
    zones: const [
      CloudSyncShadowZoneReport(
        zoneLabel: 'messages',
        status: CloudSyncRunStatus.completed,
        fetched: 0,
        journaled: 0,
        rejected: 0,
        estimatedBytes: 0,
        elapsedMilliseconds: 1,
      ),
    ],
  );

  test('returns only after the redacted report is persisted', () async {
    final events = <String>[];
    final controller = CloudSyncManualShadowController(
      runConfirmed: () async {
        events.add('run');
        return report();
      },
      persistReport: (value) async {
        events.add('persist:${value.runId}');
        return Object();
      },
    );

    expect((await controller.runConfirmedAndPersist()).runId, 'shadow-test');
    expect(events, ['run', 'persist:shadow-test']);
    expect(controller.isActive, isFalse);
  });

  test('rejects concurrent manual runs', () async {
    final release = Completer<void>();
    final controller = CloudSyncManualShadowController(
      runConfirmed: () async {
        await release.future;
        return report();
      },
      persistReport: (_) async => Object(),
    );

    final first = controller.runConfirmedAndPersist();
    expect(
      controller.runConfirmedAndPersist,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_shadow_controller_active',
        ),
      ),
    );
    release.complete();
    await first;
  });

  test('dispose closes admission and waits for the current run', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final controller = CloudSyncManualShadowController(
      runConfirmed: () async {
        entered.complete();
        await release.future;
        return report();
      },
      persistReport: (_) async => Object(),
    );

    final running = controller.runConfirmedAndPersist();
    await entered.future;
    var disposed = false;
    final disposal = controller.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    expect(controller.isDisposed, isTrue);
    expect(
      controller.runConfirmedAndPersist,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'cloud_sync_shadow_controller_disposed',
        ),
      ),
    );

    release.complete();
    await running;
    await disposal;
    expect(disposed, isTrue);
  });

  test('dispose is idempotent and absorbs an in-flight failure', () async {
    final controller = CloudSyncManualShadowController(
      runConfirmed: () async => throw StateError('expected-run-failure'),
      persistReport: (_) async => Object(),
    );

    final running = controller.runConfirmedAndPersist();
    final first = controller.dispose();
    final second = controller.dispose();
    await expectLater(running, throwsStateError);
    await first;
    await second;
  });
}
