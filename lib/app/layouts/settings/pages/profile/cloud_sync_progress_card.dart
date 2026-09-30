import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_status.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_user_copy.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_upload_retry_action.dart';

/// iCloud sync status card. Uses the account settings' inherited colors and
/// typography, so the existing iOS-style settings theme is preserved. No app
/// globals, so accessibility and lifecycle behavior can be tested without
/// native auth.
///
/// Plain-language status comes from the progress user notice. Raw diagnostic
/// codes and journal/replay vocabulary stay inside Sync details.
class CloudSyncProgressCard extends StatefulWidget {
  const CloudSyncProgressCard({
    super.key,
    required this.progress,
    required this.isAvailable,
    required this.onStart,
    this.showTitle = true,
    this.isReading,
    this.backgroundStatus,
    this.unavailableMessage,
    this.canCheckPreviousUpload,
    this.isCheckingPreviousUpload,
    this.onCheckPreviousUpload,
    this.canRetryPendingUpload,
    this.onPrepareUploadRetry,
  });
  final CloudSyncProgress progress;
  final bool Function() isAvailable;
  final Future<void> Function(CloudSyncSpeed) onStart;
  final bool showTitle;
  final bool Function()? isReading;
  final CloudSyncBackgroundStatus? Function()? backgroundStatus;

  /// Optional exact readiness reason wired by the parent service seam.
  /// Falls back to a generic checklist when null or empty.
  final String? Function()? unavailableMessage;
  final bool Function()? canCheckPreviousUpload;
  final bool Function()? isCheckingPreviousUpload;
  final Future<String> Function()? onCheckPreviousUpload;
  final bool Function()? canRetryPendingUpload;
  final Future<CloudSyncUploadRetryAction> Function()? onPrepareUploadRetry;

  @override
  State<CloudSyncProgressCard> createState() => _CloudSyncProgressCardState();
}

class _CloudSyncProgressCardState extends State<CloudSyncProgressCard> {
  CloudSyncSpeed speed = CloudSyncSpeed.regular;
  Timer? _refreshTimer;
  bool _lastAvailable = false;
  bool _lastReading = false;
  String _lastBlockerKey = '';
  String _lastBackgroundKey = '';
  String _backgroundKey() {
    final snapshot = widget.backgroundStatus?.call();
    if (snapshot == null || !snapshot.active) return '';
    return '${backgroundStatusHeadline(snapshot)}|'
        '${backgroundStatusDetail(snapshot) ?? ''}|'
        '${backgroundStatusRecency(snapshot, DateTime.now()) ?? ''}';
  }
  bool _requestingReceiptCheck = false;
  bool _receiptDialogOpen = false;
  String? _receiptResult;
  bool _preparingRetry = false;
  bool _submittingRetry = false;
  CloudSyncUploadRetryAction? _retryAction;
  bool get retryBusy => _preparingRetry || _submittingRetry;
  bool get checkingReceipt => _requestingReceiptCheck ||
      (widget.isCheckingPreviousUpload?.call() ?? false);
  String _blockerKey() =>
      '${widget.isAvailable()}|${widget.unavailableMessage?.call() ?? ''}|'
      '${widget.canCheckPreviousUpload?.call()}|$checkingReceipt|'
      '${widget.canRetryPendingUpload?.call()}|$retryBusy';

  bool get readingElsewhere =>
      !widget.progress.active && (widget.isReading?.call() ?? false);

  @override
  void initState() {
    super.initState();
    _lastAvailable = widget.isAvailable();
    _lastReading = readingElsewhere;
    _lastBlockerKey = _blockerKey();
    _lastBackgroundKey = _backgroundKey();
    // Only the mounted status card ticks. Service counters and sync ownership
    // survive page navigation; this timer never starts or cancels any work.
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final available = widget.isAvailable();
      final reading = readingElsewhere;
      final blockerKey = _blockerKey();
      final backgroundKey = _backgroundKey();
      if (widget.progress.active ||
          reading != _lastReading ||
          available != _lastAvailable ||
          blockerKey != _lastBlockerKey ||
          backgroundKey != _lastBackgroundKey) {
        setState(() {});
      }
      _lastAvailable = available;
      _lastReading = reading;
      _lastBlockerKey = blockerKey;
      _lastBackgroundKey = backgroundKey;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _retryAction?.cancel();
    super.dispose();
  }

  String elapsedLabel(Duration elapsed) {
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${minutes}m ${seconds}s';
  }

  Future<void> selectTurbo(bool enabled) async {
    if (!enabled) {
      setState(() => speed = CloudSyncSpeed.regular);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use Turbo sync?'),
        content: const Text(
          'Turbo uses larger chunks and can slow your phone, make it hot, and drain the battery. '
          'Regular uses smaller chunks with more frequent opportunities for other work. '
          'Background sync and media downloads are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep Regular'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Use Turbo'),
          ),
        ],
      ),
    );
    if (mounted &&
        accepted == true &&
        !widget.progress.active &&
        !readingElsewhere && !checkingReceipt && !retryBusy) {
      setState(() => speed = CloudSyncSpeed.turbo);
    }
  }

  Future<void> checkPreviousUpload() async {
    if (checkingReceipt || retryBusy || _receiptDialogOpen || widget.progress.active || readingElsewhere ||
        !(widget.canCheckPreviousUpload?.call() ?? false)) {
      return;
    }
    final check = widget.onCheckPreviousUpload;
    if (check == null) return;
    setState(() { _receiptDialogOpen = true; _receiptResult = null; });
    try {
      final accepted = await showDialog<bool>(context: context,
        builder: (context) => AlertDialog(
          title: const Text('Check the previous upload?'),
          content: const Text('Check whether iCloud saved the previous upload and '
              'finish its local confirmation if possible. This does not resend '
              'messages, enable uploads, or erase history.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Check upload')),
          ]));
      if (!mounted || accepted != true) {
        return;
      }
      // Read availability again after the dialog; it is not an authorization.
      if (!(widget.canCheckPreviousUpload?.call() ?? false)) {
        return;
      }
      setState(() { _requestingReceiptCheck = true; _receiptDialogOpen = false; });
      final result = await check();
      if (mounted) {
        setState(() => _receiptResult = result);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _receiptResult =
            'The upload could not be confirmed. Your saved history is kept. Do not resend it.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _requestingReceiptCheck = false;
          _receiptDialogOpen = false;
        });
      }
    }
  }

  Future<void> retryPendingUpload() async {
    final prepare = widget.onPrepareUploadRetry;
    if (prepare == null || retryBusy || checkingReceipt || _receiptDialogOpen ||
        widget.progress.active || readingElsewhere ||
        !(widget.canRetryPendingUpload?.call() ?? false)) {
      return;
    }
    setState(() { _preparingRetry = true; _receiptResult = null; });
    CloudSyncUploadRetryAction? action;
    try {
      action = await prepare();
      if (!mounted) {
        return;
      }
      _retryAction = action;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Retry queued upload?'),
          content: const Text('Upload the original queued message to your iCloud history, '
              'then check that iCloud saved it. This does not send a new iMessage, '
              'enable automatic uploads, or erase history.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Retry queued upload')),
          ],
        ),
      );
      if (!mounted || accepted != true) {
        return;
      }
      setState(() { _preparingRetry = false; _submittingRetry = true; });
      // The service revalidates the pinned operation/account at confirmation
      // and native submission. Display availability is not authority to write.
      final result = await action.confirm();
      if (mounted) {
        setState(() => _receiptResult = result);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _receiptResult = _submittingRetry
            ? 'The retry could not finish safely. Wait, then check the previous upload. Do not resend the message.'
            : 'A queued upload could not be selected safely. Nothing was submitted. Check the previous upload first.');
      }
    } finally {
      action?.cancel();
      _retryAction = null;
      if (mounted) setState(() { _preparingRetry = false; _submittingRetry = false; });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.progress,
    builder: (context, _) {
      final p = widget.progress;
      final available = widget.isAvailable();
      final elsewhere = readingElsewhere;
      final checking = checkingReceipt;
      final busy = p.active || elsewhere || checking || retryBusy;
      final notice = p.userNotice(readingElsewhere: elsewhere);
      final blocked = !available && !busy;
      final readyWhileBlocked =
          blocked && notice.state == CloudSyncUserState.ready;
      final unavailableReason = widget.unavailableMessage?.call();
      const blockedFallback = 'Sync is not available right now. Check back shortly.';
      final blockerText = (unavailableReason?.isNotEmpty ?? false)
          ? unavailableReason!
          : blockedFallback;
      final displayHeadline = retryBusy
          ? (_submittingRetry ? 'Retrying the queued upload' : 'Preparing the queued upload')
          : checking ? 'Checking the previous upload'
          : readyWhileBlocked
          ? 'Sync is not available right now'
          : notice.headline;
      final displayBody = retryBusy
          ? (_submittingRetry ? 'Uploading the original message and checking iCloud confirmation.'
              : 'Checking the saved upload before asking you to confirm.')
          : checking
          ? 'Checking iCloud confirmation without sending the message again.'
          : readyWhileBlocked ? blockerText : notice.body;
      final displayAction =
          checking || retryBusy || (blocked && notice.canStart) ? null : notice.action;
      final background = widget.backgroundStatus?.call();
      final showBackgroundDetail = elsewhere && (background?.active ?? false);
      final receiptFollowUp = _receiptResult != null
          ? receiptFollowUpCopy(backgroundBusy: elsewhere, canStartNow: available && !busy)
          : null;
      final showBlockerText = blocked && !readyWhileBlocked;
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showTitle) ...[
              Text(
                'iCloud Message Sync',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
            ],
            Semantics(liveRegion: true, child: Text(displayHeadline)),
            const SizedBox(height: 4),
            Text(displayBody),
            if (displayAction != null) ...[
              const SizedBox(height: 4),
              Text(displayAction),
            ],
            if (showBackgroundDetail) ...[
              const SizedBox(height: 4),
              Text(backgroundStatusHeadline(background!)),
              if (backgroundStatusDetail(background) case final detail?)
                Text(detail),
              if (backgroundStatusRecency(background, DateTime.now()) case final recency?)
                Text(recency),
            ],
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: checking || retryBusy ? null : p.fraction,
                semanticsLabel: retryBusy ? displayHeadline : checking ? 'Checking upload confirmation' : 'Syncing, total size unknown',
              ),
            ],
            const SizedBox(height: 8),
            if (!elsewhere && !checking && !retryBusy)
              Text(
                '${p.fetched} downloaded, ${p.reprojected} restored to your chats',
              ),
            if (!elsewhere && !checking && !retryBusy && p.projectionExamined > 0)
              Text(
                '${p.projectionExamined} checks of saved items (may include repeat checks)',
              ),
            if (p.hasStarted && !elsewhere && !checking && !retryBusy)
              Text('Elapsed ${elapsedLabel(p.elapsed)}'),
            const SizedBox(height: 8),
            Text(
              p.mediaActive > 0
                  ? 'Downloading photos and files: ${p.mediaActive} active'
                  : 'Photos and files download when you open them',
            ),
            if (p.refreshFailed)
              const Text(
                'History was saved, but the chat list could not refresh. Restart OpenBubbles to refresh it.',
              ),
            const SizedBox(height: 8),
            if (showBlockerText) Text(blockerText),
            if (_receiptResult != null)
              Semantics(liveRegion: true, child: Text(_receiptResult!)),
            if (receiptFollowUp != null) Text(receiptFollowUp),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Turbo'),
              subtitle: const Text(
                'Regular leaves more room for using your phone. Turbo uses larger batches.',
              ),
              value: p.active
                  ? p.speed == CloudSyncSpeed.turbo
                  : speed == CloudSyncSpeed.turbo,
              onChanged: busy ? null : selectTurbo,
            ),
            if (busy)
              const Text(
                'Turbo is unavailable while sync work runs. Availability is checked again afterward.',
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!p.active)
                  FilledButton.icon(
                    onPressed: available && !busy && notice.canStart
                        ? () => widget.onStart(speed)
                        : null,
                    icon: const Icon(Icons.sync),
                    label: const Text('Start / resume'),
                  ),
                if (!p.active && elsewhere)
                  const Text('Start is unavailable while background sync runs. Availability is checked again when it finishes.'),
                if (p.active)
                  OutlinedButton.icon(
                    onPressed: p.pauseRequested ? null : p.pause,
                    icon: const Icon(Icons.pause),
                    label: Text(
                      p.pauseRequested ? 'Pausing...' : 'Pause catch-up',
                    ),
                  ),
                if (widget.onCheckPreviousUpload != null &&
                    (checking || (widget.canCheckPreviousUpload?.call() ?? false)))
                  OutlinedButton.icon(
                    onPressed: busy ? null : checkPreviousUpload,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Check previous upload'),
                  ),
                if (widget.onPrepareUploadRetry != null &&
                    (retryBusy || (widget.canRetryPendingUpload?.call() ?? false)))
                  OutlinedButton.icon(
                    onPressed: busy ? null : retryPendingUpload,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Retry queued upload'),
                  ),
              ],
            ),
            if (p.active)
              const Text(
                'Pauses only the foreground catch-up after protected work finishes. It does not disable independently configured background sync or message delivery.',
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Sync details'),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p.safeFailure != null)
                  Text('Diagnostic code: ${p.safeFailure}'),
                Text(
                  '${p.pages} pages journaled, ${p.batches} batches finished',
                ),
                const Text(
                  'Average rates include authentication and waiting time.',
                ),
                if (elsewhere)
                  const Text(
                    'Counters below describe the last run on this screen, not the active sync.',
                  ),
                if (p.fetchedPerSecond case final rate?)
                  Text('Average: ${rate.toStringAsFixed(1)} new records/s'),
                if (p.replayVisitsPerSecond case final rate?)
                  Text(
                    'Average: ${rate.toStringAsFixed(1)} retained row visits/s',
                  ),
                for (final zone in p.zonePages.keys)
                  Text(
                    '$zone: ${p.zonePages[zone]} pages, ${p.zoneFetched[zone]} new journal records',
                  ),
                Text(
                  'Retained replay: ${p.projectionExamined} row visits, ${p.reprojected} projected. Rows may be revisited.',
                ),
                Text(
                  p.hasReport
                      ? 'Last saved report: ${p.retained} retained, ${p.deferred} deferred, ${p.quarantined} quarantined.'
                      : 'No saved report in this session yet.',
                ),
                const SizedBox(height: 8),
                Text(
                  '${p.mediaCompleted} completed, ${p.mediaFailed} failed download attempts this app session. '
                  'Reaching the newest iCloud change does not mean every photo is downloaded.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'No history is skipped or reset. Leaving this page does not stop sync. '
                  'If the app goes to the background, catch-up pauses at a safe point. '
                  'Only the existing opt-in Android worker does background reads; this screen does not enable it or keep the app alive. '
                  'Session counters restart at zero after an app restart. '
                  'Downloads and opted-in background work are separate.',
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
