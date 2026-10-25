import 'dart:async';

import 'package:bluebubbles/backend_harness/backend_harness_archive.dart';
import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tooling/vm_backend_harness.dart';

Map<String, Object?> command(String id, String action,
    [Map<String, Object?> arguments = const {}]) => {
  'protocol': 1, 'requestId': id, 'action': action, 'arguments': arguments,
};

BackendHarnessEngine engine(BackendHarnessOperation operation, String action) =>
    BackendHarnessEngine(enabled: true, source: 'a' * 40,
      package: 'com.bluebubbles.cloudsync.testhost', platform: 'windows',
      operations: {action: operation});

void main() {
  test('completed archive preparation preserves consent with a valid terminal reply', () async {
    final archive = BackendHarnessArchive(
      read: () async => CloudSyncAutomaticArchivePreference(
        identity: CloudSyncAutomaticArchiveIdentity(accountFingerprint: 'a' * 43,
          protectedStoreIdentity: 'obcs2.store.${'b' * 43}', ownershipEpoch: 7),
        storedValue: null),
      write: (_, __, ___, ____, _____) => throw StateError('unexpected write'),
    );
    final runner = engine(BackendHarnessOperation(background: true,
      validate: (args) => args.isEmpty, handler: (_) => archive.prepare()), 'archive.prepare');
    final accepted = await runner.execute(command('prepare', 'archive.prepare'));
    await Future<void>.delayed(Duration.zero);
    final observed = await runner.execute(command('observe', 'job.status',
      {'jobId': accepted['jobId']}));
    expect(observed['state'], 'completed');
    expect(observed['code'], 'backend_job_completed');
    final validated = validateBackendHarnessReply(observed,
      requestId: 'observe', action: 'job.status');
    expect(((validated['data'] as Map)['challenge'] as Map)['kind'], 'archiveConsent');
    expect(validated['jobId'], accepted['jobId']);
    expect(runner.hasUncertainJobs, isFalse);
  });

  test('running input challenge keeps its nonterminal reply code', () async {
    final completion = Completer<BackendHarnessPayload>();
    final runner = engine(BackendHarnessOperation(background: true,
      validate: (args) => args.isEmpty, handler: (_) => completion.future,
      snapshot: () => BackendHarnessPayload(phase: BackendHarnessPhase.needs_passcode,
        challenge: BackendHarnessChallenge('b' * 32, BackendHarnessChallengeKind.passcode))),
      'sync.start');
    final accepted = await runner.execute(command('read', 'sync.start'));
    expect(accepted['code'], 'backend_auth_challenge');
    validateBackendHarnessReply(accepted, requestId: 'read', action: 'sync.start');
    completion.complete(const BackendHarnessPayload());
    await Future<void>.delayed(Duration.zero);
    final observed = await runner.execute(command('done', 'job.status',
      {'jobId': accepted['jobId']}));
    expect(observed['code'], 'backend_job_completed');
    validateBackendHarnessReply(observed, requestId: 'done', action: 'job.status');
  });
}
