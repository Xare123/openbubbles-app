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
}

Future<void> main() async {
  // Keep the class reachable, including in the VM expression compiler.
  FixtureService('success');
  print('fixture-ready');
  await stdin.drain<void>();
}
