/// Plain-language copy for the iCloud sync progress card.
///
/// Presentation only. Nothing here starts, pauses, cancels, budgets, or
/// otherwise controls a sync run. Engine and control semantics live in
/// CloudSyncProgress and the owning service; this file only maps the
/// existing phase plus the safe diagnostic code to a headline, an
/// explanation, and a next action a normal user can follow.
///
/// Rules honored here:
/// - Raw diagnostic codes and journal/replay vocabulary stay in Sync
///   details. This file never prints a raw code.
/// - An unknown total is never rendered as a percentage. The card keeps an
///   indeterminate bar (see `CloudSyncProgress.fraction`).
/// - Reaching the newest iCloud change is never described as everything
///   being restored or every photo being downloaded.
/// - A canceled preparation (`cloud_sync_semantic_drain_cancelled`) is a
///   calm paused state, never an error.
/// - Auth and offline copy use short exact code lists, never substring
///   inference. Account-change, structural-integrity, unknown-outcome, and
///   timeout/transport codes stay generic: they are not sign-in prompts and
///   timed-out work may still be running.
/// - Restart and settling beat the running-elsewhere headline so a safety
///   or wait state is never hidden behind it.
library;

import 'cloud_sync_observability.dart';

/// User-visible sync situations, in the order the card checks them.
enum CloudSyncUserState {
  ready,
  waitingWindow,
  checkingSignIn,
  preparingEncryption,
  downloading,
  organizing,
  pausing,
  paused,
  pausedAtLimit,
  caughtUp,
  caughtUpOrganizing,
  runningElsewhere,
  settling,
  needsAuth,
  relayUnavailable,
  offlineRetry,
  needsRestart,
  needsAttention,
}

/// One screen of user copy: what is happening and what to do next.
class CloudSyncUserNotice {
  const CloudSyncUserNotice({
    required this.state,
    required this.headline,
    required this.body,
    this.action,
    required this.canStart,
  });

  final CloudSyncUserState state;
  final String headline;
  final String body;
  final String? action;
  final bool canStart;
}

const _cancelledCode = 'cloud_sync_semantic_drain_cancelled';
const _restartRequiredCode = 'cloud_sync_v2_pcs_restart_required';
const _relayUnavailableCode =
    'cloud_sync_native_auth_refresh_relay_unavailable';

/// A user cancellation is a paused state, not proof that no work occurred.
bool cloudSyncUserCodeIsCancelled(String? code) => code == _cancelledCode;

/// Restart blocks resume even though setup may still be running natively.
bool cloudSyncUserCodeNeedsRestart(String? code, bool restartRequired) =>
    restartRequired || code == _restartRequiredCode;

/// The saved relay cannot be reached. Recovery is checking the relay, not
/// the account.
bool cloudSyncUserCodeIsRelay(String? code) => code == _relayUnavailableCode;

/// A previous sync task has not finished yet. The user waits, then retries.
bool cloudSyncUserCodeIsBusy(String? code) => const {
  'cloud_sync_v2_pcs_preparation_active',
  'cloud_sync_native_auth_refresh_writer_busy',
  'cloud_sync_semantic_drain_controller_active',
  'coordinator_active',
  'cloud_sync_local_send_consumer_busy',
  'cloudkit_interlock_busy',
}.contains(code);

/// Settling states. Work may still be running, so this never claims the run
/// stopped and never asks for an account fix.
bool cloudSyncUserCodeIsSettling(String? code) => const {
  'cloud_sync_v2_pcs_preparation_quiescing',
  'cloud_sync_v2_pcs_preparation_quiescence_timeout',
  'cloud_sync_outbound_canary_quiescing',
  'cloud_sync_outbound_quiescence_timeout',
  'cloud_sync_outbound_provisioning_quiescence_timeout',
  'cloud_sync_semantic_pull_quiescing',
  'cloud_sync_semantic_pull_quiescence_timeout',
  'cloud_sync_shadow_quiescence_failed',
  'cloud_sync_shadow_owner_quiescing',
}.contains(code);

/// Exact codes where Apple must verify the device or account. Deliberately
/// short: account-change, structural-integrity, unknown-outcome, and
/// timeout/transport codes stay generic because they are not sign-in prompts
/// and timed-out work may still be running.
bool cloudSyncUserCodeIsAuth(String? code) => const {
  'cloud_sync_native_auth_credentials_rejected',
  'cloud_sync_native_auth_credentials_unavailable',
  'cloud_sync_native_auth_refresh_credentials_rejected',
  'cloudkit_authorization',
  'http_authorization',
  'apply_authorization',
  'decoder_authorization',
}.contains(code);

/// Exact codes that are unambiguously connection or server trouble.
/// Transport and timeout codes stay generic: a failure after submission can
/// be ambiguous and timed-out work may still be running.
bool cloudSyncUserCodeIsOffline(String? code) => const {
  'network',
  'fetch_deadline',
  'cloudkit_throttled',
  'cloudkit_server',
  'http_timeout',
  'http_throttled',
  'http_server',
  'apply_network',
  'apply_throttled',
  'decoder_network',
  'decoder_throttled',
}.contains(code);

/// Shared fallback. Unknown codes stay generic here with the raw code kept
/// in Sync details.
const _genericAttention = CloudSyncUserNotice(
  state: CloudSyncUserState.needsAttention,
  headline: 'Sync needs attention',
  body:
      'Something needs attention before resuming. Your downloaded items are still saved.',
  action:
      'Tap Start / resume to try again. If it keeps happening, open Sync details and share the diagnostic code.',
  canStart: true,
);

/// Maps the existing phase plus the safe code to plain-language copy.
/// Restart and settling beat [readingElsewhere] so a safety or wait state is
/// never hidden behind it; otherwise the other sync owns the headline and
/// local counters still describe the last run on this screen.
CloudSyncUserNotice describeCloudSyncUserNotice({
  required CloudSyncProgressPhase phase,
  String? safeFailure,
  required bool restartRequired,
  required bool pauseRequested,
  required bool readingElsewhere,
  required bool projectionComplete,
}) {
  if (cloudSyncUserCodeNeedsRestart(safeFailure, restartRequired)) {
    return const CloudSyncUserNotice(
      state: CloudSyncUserState.needsRestart,
      headline: 'Restart needed before resuming',
      body:
          'Encryption setup timed out and follow-up work is blocked for safety, '
          'even though setup may still be running in the background.',
      action: 'Fully close and restart OpenBubbles, then tap Start / resume.',
      canStart: false,
    );
  }
  if (cloudSyncUserCodeIsSettling(safeFailure)) {
    return const CloudSyncUserNotice(
      state: CloudSyncUserState.settling,
      headline: 'Sync is still settling',
      body:
          'Sync is waiting for background work to settle. Work may still be running. '
          'Your downloaded items are still saved.',
      action: 'Wait a moment, then tap Start / resume to try again.',
      canStart: true,
    );
  }
  if (readingElsewhere) {
    return const CloudSyncUserNotice(
      state: CloudSyncUserState.runningElsewhere,
      headline: 'Sync is already running',
      body: 'Another sync is finishing. Your progress is safe.',
      action: 'Start / resume unlocks when it is done.',
      canStart: false,
    );
  }
  if (phase == CloudSyncProgressPhase.error || safeFailure != null) {
    if (safeFailure == 'legacy_sync_active') {
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.needsAttention,
        headline: 'Existing iCloud sync is enabled',
        body:
            'Keep using the existing sync controls below. Your sync method '
            'will not be switched or reset automatically.',
        // The current availability callback keeps legacy-on blocked. A stale
        // error must not disable resume after the user has resolved it.
        canStart: true,
      );
    }
    if (cloudSyncUserCodeIsCancelled(safeFailure)) {
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.paused,
        headline: 'Paused',
        body: 'Downloaded history is kept.',
        action: 'Tap Start / resume to continue.',
        canStart: true,
      );
    }
    if (cloudSyncUserCodeIsRelay(safeFailure)) {
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.relayUnavailable,
        headline: 'Relay unavailable',
        body:
            'Your saved relay is unavailable. Check its connection or update its pairing code. '
            'Your downloaded items are still saved.',
        action: 'Then tap Start / resume to try again.',
        canStart: true,
      );
    }
    if (cloudSyncUserCodeIsBusy(safeFailure)) {
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.runningElsewhere,
        headline: 'Another sync task is finishing',
        body:
            'A previous sync task has not finished yet. Wait a moment. Your progress is safe.',
        action: 'Then tap Start / resume to try again.',
        canStart: true,
      );
    }
    if (cloudSyncUserCodeIsOffline(safeFailure)) {
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.offlineRetry,
        headline: 'Connection issue, try again',
        body:
            'This looks like a connection or server hiccup. Check that you are online. '
            'Your downloaded items are still saved.',
        action: 'Then tap Start / resume to try again.',
        canStart: true,
      );
    }
    if (cloudSyncUserCodeIsAuth(safeFailure)) {
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.needsAuth,
        headline: 'Sign-in or device check needed',
        body:
            'Apple needs to verify this device or account. The app may ask you to choose '
            'a trusted Apple device and enter that device\'s passcode. '
            'Your downloaded items are still saved.',
        action: 'Then tap Start / resume to try again.',
        canStart: true,
      );
    }
    return _genericAttention;
  }
  switch (phase) {
    case CloudSyncProgressPhase.idle:
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.ready,
        headline: 'Ready to sync',
        body:
            'Start gets encryption ready on this phone, then picks up where it left off. '
            'The app may ask for the passcode or password of a trusted Apple device. '
            'After an app restart, tap Start / resume to continue.',
        canStart: true,
      );
    case CloudSyncProgressPhase.waiting:
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.waitingWindow,
        headline: 'Waiting for a safe moment',
        body:
            'Waiting for other iCloud work to finish. Leave OpenBubbles open.',
        canStart: false,
      );
    case CloudSyncProgressPhase.authentication:
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.checkingSignIn,
        headline: 'Checking your iCloud sign-in',
        body:
            'Confirming the signed-in iCloud account. The app may ask you to choose '
            'a trusted Apple device and enter that device\'s passcode.',
        canStart: false,
      );
    case CloudSyncProgressPhase.pcs:
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.preparingEncryption,
        headline: 'Getting encryption ready',
        body:
            'Preparing encrypted access to your message history. The app may ask you to choose '
            'a trusted Apple device and enter that device\'s passcode. '
            'Complete it, then wait for the download to begin.',
        canStart: false,
      );
    case CloudSyncProgressPhase.fetching:
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.downloading,
        headline: 'Downloading your messages',
        body:
            'Downloading in small safe batches. The bar keeps moving without a percentage because the total is unknown.',
        canStart: false,
      );
    case CloudSyncProgressPhase.replaying:
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.organizing,
        headline: 'Organizing saved messages',
        body:
            'Putting downloaded items into your chats. Items can be revisited, so counts may move without new downloads.',
        canStart: false,
      );
    case CloudSyncProgressPhase.pausing:
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.pausing,
        headline: 'Pausing safely',
        body:
            'Finishing protected work first, then pausing. Your progress is saved.',
        canStart: false,
      );
    case CloudSyncProgressPhase.paused:
      if (pauseRequested) {
        return const CloudSyncUserNotice(
          state: CloudSyncUserState.paused,
          headline: 'Paused',
          body: 'Your progress is saved.',
          action: 'Tap Start / resume to continue.',
          canStart: true,
        );
      }
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.pausedAtLimit,
        headline: 'Paused at a safe stopping point',
        body: 'Sync stopped at a safe boundary with your progress saved.',
        action: 'Tap Start / resume to continue.',
        canStart: true,
      );
    case CloudSyncProgressPhase.remoteHead:
      if (projectionComplete) {
        return const CloudSyncUserNotice(
          state: CloudSyncUserState.caughtUp,
          headline: 'Caught up to the newest iCloud change',
          body:
              'The restore pass finished. Photos and files download when you '
              'open them, so this does not mean everything is on the phone yet.',
          action: 'Tap Start / resume to check for newer changes.',
          canStart: true,
        );
      }
      return const CloudSyncUserNotice(
        state: CloudSyncUserState.caughtUpOrganizing,
        headline: 'History downloaded; some items need attention',
        body:
            'Some saved items could not be restored yet. They are kept for '
            'recovery. Photos and files download when you open them.',
        action: 'Tap Start / resume to continue.',
        canStart: true,
      );
    case CloudSyncProgressPhase.error:
      return _genericAttention;
  }
}
