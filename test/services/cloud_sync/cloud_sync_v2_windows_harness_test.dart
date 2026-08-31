import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const launchId = '0123456789abcdef0123456789abcdef';

  test('parses interactive, run-once, and drain with one exact launch id', () {
    expect(
      CloudSyncV2WindowsHarnessLaunch.parse(const [
        '--launch-id=$launchId',
      ]).operation,
      CloudSyncV2WindowsHarnessOperation.interactive,
    );
    expect(
      CloudSyncV2WindowsHarnessLaunch.parse(const [
        'run-once',
        '--launch-id=$launchId',
      ]).operation,
      CloudSyncV2WindowsHarnessOperation.runOnce,
    );
    expect(
      CloudSyncV2WindowsHarnessLaunch.parse(const [
        '--launch-id=$launchId',
        'drain',
      ]).operation,
      CloudSyncV2WindowsHarnessOperation.drain,
    );
  });

  test('rejects missing, malformed, duplicate, and ambiguous launch input', () {
    final candidates = <List<String>>[
      const [],
      const ['drain'],
      const ['--launch-id=not-hex'],
      const ['--launch-id=$launchId', '--launch-id=$launchId'],
      const ['run-once', 'drain', '--launch-id=$launchId'],
    ];

    for (final candidate in candidates) {
      expect(
        () => CloudSyncV2WindowsHarnessLaunch.parse(candidate),
        throwsStateError,
        reason: candidate.toString(),
      );
    }
  });

  test('status payload binds every record to the launch id and Dart pid', () {
    final payload = cloudSyncV2WindowsHarnessStatusPayload(
      launchId: launchId,
      processId: 4242,
      state: 'running',
      stage: 'semantic-drain',
      updatedUtc: DateTime.utc(2026, 8, 31, 12),
    );

    expect(payload['version'], 'cloud-sync-v2-windows-harness-status-v2');
    expect(payload['launch_id'], launchId);
    expect(payload['process_id'], 4242);
    expect(payload['state'], 'running');
    expect(payload['stage'], 'semantic-drain');
  });

  test(
    'pass limit is resumable while remote-drained outcomes are finished',
    () {
      final passLimit = cloudSyncV2WindowsHarnessDrainTerminalStatus(
        reachedPassLimit: true,
        projectionComplete: true,
      );
      expect(passLimit.state, 'resumable');
      expect(passLimit.stage, 'semantic-drain-pass-limit');

      final complete = cloudSyncV2WindowsHarnessDrainTerminalStatus(
        reachedPassLimit: false,
        projectionComplete: true,
      );
      expect(complete.state, 'finished');
      expect(complete.stage, 'semantic-drain-complete');

      final projectionPartial = cloudSyncV2WindowsHarnessDrainTerminalStatus(
        reachedPassLimit: false,
        projectionComplete: false,
      );
      expect(projectionPartial.state, 'finished');
      expect(
        projectionPartial.stage,
        'semantic-drain-remote-complete-projection-partial',
      );
    },
  );

  test('cold read authentication starts one fresh login only', () {
    expect(
      cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication(
        safeCode: 'cloud_sync_native_auth_refresh_session_missing',
        alreadyAttempted: false,
      ),
      isTrue,
    );
    expect(
      cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication(
        safeCode: 'cloud_sync_native_auth_refresh_session_missing',
        alreadyAttempted: true,
      ),
      isFalse,
    );
    expect(
      cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication(
        safeCode: 'cloud_sync_native_auth_refresh_transport_failed',
        alreadyAttempted: false,
      ),
      isFalse,
    );
  });

  test(
    'fresh login state selects only an explicit authenticated or 2FA lane',
    () {
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.loggedIn(),
        ),
        CloudSyncV2WindowsReadAuthAction.activate,
      );
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.needsSms2Fa(),
        ),
        CloudSyncV2WindowsReadAuthAction.requestSmsTwoFactor,
      );
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.needsDevice2Fa(),
        ),
        CloudSyncV2WindowsReadAuthAction.requestSmsTwoFactor,
      );
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.needsLogin(),
        ),
        CloudSyncV2WindowsReadAuthAction.reject,
      );
    },
  );
}
