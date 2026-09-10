import 'dart:async';
import 'dart:io';

// Synthetic VM-service target. No app, account, database or network client.
class FixtureService {
  FixtureService(this.mode);
  final String mode;

  Future<void> runCloudSyncV2ManualSemanticPullConfirmed() async {
    if (mode == 'failure') throw StateError('cloud_sync_fixture_failure');
    if (mode == 'private') throw StateError('synthetic non-exportable detail');
    if (mode == 'pending') await Completer<void>().future;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> runCloudSyncV2ManualSemanticCatchUpConfirmed() =>
      runCloudSyncV2ManualSemanticPullConfirmed();

  Future<void> prepareCloudSyncV2OutboundWriter() async {
    if (mode == 'write-private') {
      throw StateError('private recipient and message detail');
    }
    if (mode == 'write-failure') {
      throw StateError('cloud_sync_fixture_write_failure');
    }
    if (mode == 'write-pending') await Completer<void>().future;
  }

  Future<FixtureSelection?> selectCloudSyncV2ExactIntent({
    required String expectedRecipient,
  }) async {
    if (mode == 'write-none') return null;
    if (expectedRecipient != '+15555550123') {
      throw StateError('cloud_sync_fixture_recipient_mismatch');
    }
    return FixtureSelection(
      mode == 'write-changed' ? 'ffffffffffffffff' : '0123456789abcdef',
      DateTime.utc(2026, 9, 10, 1, 2, 3),
      slowFields: mode == 'write-slow-fields',
    );
  }

  Future<FixtureWriteResult> runCloudSyncV2ExactIntentConfirmed(
    FixtureSelection selection,
  ) async {
    if (mode == 'write-run-private') {
      throw StateError('private payload detail');
    }
    if (mode == 'write-run-failure') {
      throw StateError('cloud_sync_fixture_run_failure');
    }
    if (mode == 'write-run-pending') await Completer<void>().future;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return FixtureWriteResult(
      admitted: mode == 'write-verify' ? 0 : 1,
      deferred: 0,
      outboxBlocked: false,
      chatReadbackPending: false,
      candidateLimitReached: false,
    );
  }
}

final class FixtureSelection {
  const FixtureSelection(
    this.guidHash,
    this._createdAtUtc, {
    this.slowFields = false,
  });
  final String guidHash;
  final DateTime _createdAtUtc;
  final bool slowFields;
  DateTime get createdAtUtc {
    if (slowFields) {
      // Let VM-service polling interrupt between result-field evaluations.
      // The old mutable observer exposed a GUID while its state was pending.
      final watch = Stopwatch()..start();
      while (watch.elapsedMilliseconds < 300) {}
    }
    return _createdAtUtc;
  }
}

final class FixtureWriteResult {
  const FixtureWriteResult({
    required this.admitted,
    required this.deferred,
    required this.outboxBlocked,
    required this.chatReadbackPending,
    required this.candidateLimitReached,
  });
  final int admitted;
  final int deferred;
  final bool outboxBlocked;
  final bool chatReadbackPending;
  final bool candidateLimitReached;
}

Future<void> main() async {
  // Keep the class reachable, including in the VM expression compiler.
  FixtureService('success');
  print('fixture-ready');
  await stdin.drain<void>();
}
