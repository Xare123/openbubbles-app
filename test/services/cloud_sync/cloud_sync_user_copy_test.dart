import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_observability.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_user_copy.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncUserNotice noticeFor({
  CloudSyncProgressPhase phase = CloudSyncProgressPhase.idle,
  String? safeFailure,
  bool restartRequired = false,
  bool pauseRequested = false,
  bool readingElsewhere = false,
  bool projectionComplete = false,
}) => describeCloudSyncUserNotice(
  phase: phase,
  safeFailure: safeFailure,
  restartRequired: restartRequired,
  pauseRequested: pauseRequested,
  readingElsewhere: readingElsewhere,
  projectionComplete: projectionComplete,
);

void main() {
  test(
    'legacy conflict explains the existing mode without a permanent retry lock',
    () {
      final notice = noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'legacy_sync_active',
      );
      expect(notice.headline, 'Existing iCloud sync is enabled');
      expect(notice.canStart, isTrue);
      expect(notice.body, isNot(contains('Wait a moment')));
    },
  );
  test('ready state invites start and mentions the trusted-device prompt', () {
    final notice = noticeFor();
    expect(notice.state, CloudSyncUserState.ready);
    expect(notice.headline, 'Ready to sync');
    expect(notice.body, contains('trusted Apple device'));
    expect(notice.canStart, isTrue);
  });

  test('running phases never offer start', () {
    for (final phase in [
      CloudSyncProgressPhase.waiting,
      CloudSyncProgressPhase.authentication,
      CloudSyncProgressPhase.pcs,
      CloudSyncProgressPhase.fetching,
      CloudSyncProgressPhase.replaying,
      CloudSyncProgressPhase.pausing,
    ]) {
      expect(noticeFor(phase: phase).canStart, isFalse, reason: phase.name);
    }
    expect(
      noticeFor(phase: CloudSyncProgressPhase.pcs).headline,
      'Getting encryption ready',
    );
    expect(
      noticeFor(phase: CloudSyncProgressPhase.authentication).headline,
      'Checking your iCloud sign-in',
    );
  });

  test('paused variants offer resume with a clear action', () {
    final user = noticeFor(
      phase: CloudSyncProgressPhase.paused,
      pauseRequested: true,
    );
    expect(user.state, CloudSyncUserState.paused);
    expect(user.headline, 'Paused');
    expect(user.action, contains('Start / resume'));
    expect(user.canStart, isTrue);
    final limit = noticeFor(phase: CloudSyncProgressPhase.paused);
    expect(limit.state, CloudSyncUserState.pausedAtLimit);
    expect(limit.canStart, isTrue);
  });

  test('remote head never promises restored media', () {
    final done = noticeFor(
      phase: CloudSyncProgressPhase.remoteHead,
      projectionComplete: true,
    );
    expect(done.state, CloudSyncUserState.caughtUp);
    expect(done.body, contains('Photos and files download when you open them'));
    expect(done.body, contains('does not mean everything is on the phone yet'));
    final organizing = noticeFor(phase: CloudSyncProgressPhase.remoteHead);
    expect(organizing.state, CloudSyncUserState.caughtUpOrganizing);
    expect(organizing.canStart, isTrue);
  });

  test('another sync finishing beats local copy and blocks a second start', () {
    final notice = noticeFor(
      phase: CloudSyncProgressPhase.error,
      safeFailure: 'network',
      readingElsewhere: true,
    );
    expect(notice.state, CloudSyncUserState.runningElsewhere);
    expect(notice.canStart, isFalse);
  });

  test('failure codes map to auth, relay, offline, restart, or generic', () {
    expect(
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_native_auth_credentials_rejected',
      ).state,
      CloudSyncUserState.needsAuth,
    );
    expect(
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_native_auth_refresh_relay_unavailable',
      ).state,
      CloudSyncUserState.relayUnavailable,
    );
    expect(
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'network',
      ).state,
      CloudSyncUserState.offlineRetry,
    );
    expect(
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_v2_pcs_restart_required',
      ).state,
      CloudSyncUserState.needsRestart,
    );
    final restart = noticeFor(
      phase: CloudSyncProgressPhase.error,
      safeFailure: 'cloud_sync_v2_pcs_restart_required',
    );
    expect(restart.canStart, isFalse);
    expect(restart.action, contains('Fully close and restart'));
    expect(
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_unknown_failure',
      ).state,
      CloudSyncUserState.needsAttention,
    );
  });

  test('canceled preparation is paused, never an error', () {
    final notice = noticeFor(
      phase: CloudSyncProgressPhase.error,
      safeFailure: 'cloud_sync_semantic_drain_cancelled',
      pauseRequested: true,
    );
    expect(notice.state, CloudSyncUserState.paused);
    expect(notice.canStart, isTrue);
    expect(
      cloudSyncUserCodeIsCancelled('cloud_sync_semantic_drain_cancelled'),
      isTrue,
    );
  });

  test('busy codes ask for a wait, not an account fix', () {
    final notice = noticeFor(
      phase: CloudSyncProgressPhase.error,
      safeFailure: 'cloud_sync_native_auth_refresh_writer_busy',
    );
    expect(notice.state, CloudSyncUserState.runningElsewhere);
    expect(notice.headline, 'Another sync task is finishing');
    expect(
      cloudSyncUserCodeIsAuth('cloud_sync_native_auth_refresh_writer_busy'),
      isFalse,
    );
    expect(
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloudkit_interlock_busy',
      ).state,
      CloudSyncUserState.runningElsewhere,
    );
  });

  test('account-change, unknown-outcome, and timeout codes stay generic', () {
    for (final code in [
      'cloud_sync_native_auth_account_changed',
      'cloud_sync_v2_pcs_account_changed',
      'cloud_sync_native_auth_identity_mismatch',
      'cloud_sync_v2_pcs_join_unverified',
      'cloud_sync_v2_pcs_join_outcome_unknown',
      'cloud_sync_native_auth_refresh_timeout',
      'cloud_sync_native_auth_refresh_transport_failed',
      'cloud_sync_native_auth_warm_timeout',
      'continuation_no_progress',
    ]) {
      expect(
        noticeFor(phase: CloudSyncProgressPhase.error, safeFailure: code).state,
        CloudSyncUserState.needsAttention,
        reason: code,
      );
      expect(cloudSyncUserCodeIsAuth(code), isFalse, reason: code);
      expect(cloudSyncUserCodeIsOffline(code), isFalse, reason: code);
    }
  });

  test('settling beats running-elsewhere and never claims a stop', () {
    final notice = noticeFor(
      phase: CloudSyncProgressPhase.error,
      safeFailure: 'cloud_sync_v2_pcs_preparation_quiescing',
      readingElsewhere: true,
    );
    expect(notice.state, CloudSyncUserState.settling);
    expect(notice.headline, 'Sync is still settling');
    expect(notice.body, contains('may still be running'));
    expect(notice.canStart, isTrue);
  });

  test('user copy never leaks raw codes or em dashes', () {
    final samples = [
      noticeFor(),
      noticeFor(phase: CloudSyncProgressPhase.waiting),
      noticeFor(phase: CloudSyncProgressPhase.authentication),
      noticeFor(phase: CloudSyncProgressPhase.pcs),
      noticeFor(phase: CloudSyncProgressPhase.fetching),
      noticeFor(phase: CloudSyncProgressPhase.replaying),
      noticeFor(phase: CloudSyncProgressPhase.pausing),
      noticeFor(phase: CloudSyncProgressPhase.paused, pauseRequested: true),
      noticeFor(phase: CloudSyncProgressPhase.paused),
      noticeFor(
        phase: CloudSyncProgressPhase.remoteHead,
        projectionComplete: true,
      ),
      noticeFor(phase: CloudSyncProgressPhase.remoteHead),
      noticeFor(readingElsewhere: true),
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_native_auth_credentials_rejected',
      ),
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_native_auth_refresh_relay_unavailable',
      ),
      noticeFor(phase: CloudSyncProgressPhase.error, safeFailure: 'network'),
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_v2_pcs_restart_required',
      ),
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_unknown_failure',
      ),
      noticeFor(
        phase: CloudSyncProgressPhase.error,
        safeFailure: 'cloud_sync_v2_pcs_preparation_quiescing',
      ),
    ];
    for (final notice in samples) {
      for (final text in [notice.headline, notice.body, notice.action]) {
        if (text == null) continue;
        expect(text, isNot(contains('cloud_sync_')), reason: notice.state.name);
        expect(text, isNot(contains('decoder_')), reason: notice.state.name);
        expect(
          text,
          isNot(contains('pages journaled')),
          reason: notice.state.name,
        );
        expect(text, isNot(contains('row visits')), reason: notice.state.name);
        expect(text, isNot(contains('\u2014')), reason: notice.state.name);
      }
    }
  });
}
