import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';

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
    this.unavailableMessage,
  });
  final CloudSyncProgress progress;
  final bool Function() isAvailable;
  final Future<void> Function(CloudSyncSpeed) onStart;
  final bool showTitle;
  final bool Function()? isReading;

  /// Optional exact readiness reason wired by the parent service seam.
  /// Falls back to a generic checklist when null or empty.
  final String? Function()? unavailableMessage;

  @override
  State<CloudSyncProgressCard> createState() => _CloudSyncProgressCardState();
}

class _CloudSyncProgressCardState extends State<CloudSyncProgressCard> {
  CloudSyncSpeed speed = CloudSyncSpeed.regular;
  Timer? _refreshTimer;
  bool _lastAvailable = false;
  bool _lastReading = false;

  bool get readingElsewhere =>
      !widget.progress.active && (widget.isReading?.call() ?? false);

  @override
  void initState() {
    super.initState();
    _lastAvailable = widget.isAvailable();
    _lastReading = readingElsewhere;
    // Only the mounted status card ticks. Service counters and sync ownership
    // survive page navigation; this timer never starts or cancels any work.
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final available = widget.isAvailable();
      final reading = readingElsewhere;
      if (widget.progress.active ||
          reading != _lastReading ||
          available != _lastAvailable) {
        setState(() {});
      }
      _lastAvailable = available;
      _lastReading = reading;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
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
        !readingElsewhere) {
      setState(() => speed = CloudSyncSpeed.turbo);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.progress,
    builder: (context, _) {
      final p = widget.progress;
      final available = widget.isAvailable();
      final elsewhere = readingElsewhere;
      final busy = p.active || elsewhere;
      final notice = p.userNotice(readingElsewhere: elsewhere);
      final unavailableReason = widget.unavailableMessage?.call();
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
            Semantics(liveRegion: true, child: Text(notice.headline)),
            const SizedBox(height: 4),
            Text(notice.body),
            if (notice.action != null) ...[
              const SizedBox(height: 4),
              Text(notice.action!),
            ],
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: p.fraction,
                semanticsLabel: 'Syncing, total size unknown',
              ),
            ],
            const SizedBox(height: 8),
            if (!elsewhere)
              Text(
                '${p.fetched} downloaded, ${p.reprojected} restored to your chats',
              ),
            if (p.hasStarted && !elsewhere)
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
            if (!available && !busy)
              Text(
                (unavailableReason?.isNotEmpty ?? false)
                    ? unavailableReason!
                    : 'Not available right now. This needs the authorized test build, '
                          'your iCloud account signed in, no other sync running, '
                          'and the older sync method switched off.',
              ),
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
                if (p.active)
                  OutlinedButton.icon(
                    onPressed: p.pauseRequested ? null : p.pause,
                    icon: const Icon(Icons.pause),
                    label: Text(
                      p.pauseRequested ? 'Pausing...' : 'Pause catch-up',
                    ),
                  ),
              ],
            ),
            if (p.active)
              const Text(
                'Pauses catch-up safely after protected work finishes.',
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
