import 'package:bluebubbles/cloud_sync_v2_windows_auth_probe.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const launchId = '0123456789abcdef0123456789abcdef';

  test('accepts one exact cryptographic launch identifier', () {
    expect(
      CloudSyncV2WindowsAuthProbeLaunch.parse(const [
        '--launch-id=$launchId',
      ]).launchId,
      launchId,
    );
    for (final candidate in <List<String>>[
      const [],
      const ['--launch-id=not-hex'],
      const ['extra', '--launch-id=$launchId'],
    ]) {
      expect(
        () => CloudSyncV2WindowsAuthProbeLaunch.parse(candidate),
        throwsStateError,
      );
    }
  });

  test('separates authenticated, explicit 2FA, and rejected states', () {
    expect(
      cloudSyncV2WindowsAuthProbeOutcome(const api.LoginState.loggedIn()),
      CloudSyncV2WindowsAuthProbeOutcome.admitted,
    );
    expect(
      cloudSyncV2WindowsAuthProbeOutcome(const api.LoginState.needsSms2Fa()),
      CloudSyncV2WindowsAuthProbeOutcome.twoFactorRequired,
    );
    expect(
      cloudSyncV2WindowsAuthProbeOutcome(const api.LoginState.needsDevice2Fa()),
      CloudSyncV2WindowsAuthProbeOutcome.twoFactorRequired,
    );
    expect(
      cloudSyncV2WindowsAuthProbeOutcome(const api.LoginState.needsLogin()),
      CloudSyncV2WindowsAuthProbeOutcome.rejected,
    );
  });

  test('status schema contains only allowlisted content-free fields', () {
    final payload = cloudSyncV2WindowsAuthProbeStatusPayload(
      launchId: launchId,
      processId: 4242,
      state: 'finished',
      stage: 'auth-admitted',
      safeCode: 'none',
      updatedUtc: DateTime.utc(2026, 8, 31, 12),
    );

    expect(payload.keys.toSet(), <String>{
      'version',
      'launch_id',
      'process_id',
      'state',
      'stage',
      'safe_code',
      'updated_utc',
    });
    expect(payload['version'], cloudSyncV2WindowsAuthProbeStatusVersion);
    expect(payload['stage'], 'auth-admitted');
  });

  test('failure codes are stage-only and never reflect error text', () {
    for (final stage in <String>[
      'process-entry',
      'binding-ready',
      'profile-compile-gate',
      'profile-directory-check',
      'profile-canonical-check',
      'profile-marker-check',
      'profile-preflight-ready',
      'filesystem-service-configure',
      'profile-configured',
      'rust-ready',
      'probe-profile-prepared',
    ]) {
      expect(
        cloudSyncV2WindowsAuthProbeSafeCode(stage),
        'cloud_sync_windows_auth_probe_profile_failed',
      );
    }
    expect(
      cloudSyncV2WindowsAuthProbeSafeCode('auth-login'),
      'cloud_sync_windows_auth_probe_login_failed',
    );
    expect(
      cloudSyncV2WindowsAuthProbeSafeCode('auth-two-factor-required'),
      'cloud_sync_windows_auth_probe_status_failed',
    );
    expect(
      cloudSyncV2WindowsAuthProbeSafeCode('auth-admitted'),
      'cloud_sync_windows_auth_probe_status_failed',
    );
  });

  test('earliest status path is fixed beneath the isolated profile', () {
    final statusFile = cloudSyncV2WindowsAuthProbeStatusFile(
      environment: const <String, String>{
        'APPDATA': r'C:\AuthProbeRoot',
      },
    );

    expect(
      statusFile.path.toLowerCase(),
      endsWith(
        r'\openbubbles\cloudkit-v2-dev\cloud-sync-v2-windows-auth-probe-status.json',
      ),
    );
  });

  test('2FA is a non-success terminal challenge state', () {
    final payload = cloudSyncV2WindowsAuthProbeStatusPayload(
      launchId: launchId,
      processId: 4242,
      state: 'challenge-required',
      stage: 'auth-two-factor-required',
      safeCode: 'cloud_sync_windows_auth_probe_two_factor_required',
      updatedUtc: DateTime.utc(2026, 8, 31, 12),
    );

    expect(payload['state'], 'challenge-required');
    expect(
      payload['safe_code'],
      'cloud_sync_windows_auth_probe_two_factor_required',
    );
  });
}
