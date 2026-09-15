import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_progress.dart';

/// Uses the account settings' inherited colors and typography. No app globals,
/// so accessibility and lifecycle behavior can be tested without native auth.
class CloudSyncProgressCard extends StatefulWidget {
  const CloudSyncProgressCard({
    super.key,
    required this.progress,
    required this.isAvailable,
    required this.onStart,
    this.isReading,
  });
  final CloudSyncProgress progress;
  final bool Function() isAvailable;
  final Future<void> Function(CloudSyncSpeed) onStart;
  final bool Function()? isReading;

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
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'iCloud history sync',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(elsewhere ? 'History sync is running' : p.title),
            ),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: p.fraction,
                semanticsLabel: 'History total unknown',
              ),
            ],
            const SizedBox(height: 8),
            if (elsewhere)
              const Text(
                'Another history sync is active. Start / resume becomes available when it finishes.',
              ),
            if (!elsewhere)
              Text(
                '${p.fetched} records downloaded, ${p.reprojected} saved records restored',
              ),
            if (p.hasStarted && !elsewhere)
              Text('Elapsed ${elapsedLabel(p.elapsed)}'),
            const SizedBox(height: 8),
            Text(
              p.mediaActive > 0
                  ? 'Materializing media: ${p.mediaActive} active'
                  : 'Media downloads on demand',
            ),
            if (p.safeFailure != null)
              Text(
                p.safeFailure ==
                        'cloud_sync_native_auth_refresh_relay_unavailable'
                    ? 'Your saved relay is unavailable. Check its connection or update its pairing code, then tap Start / resume. '
                          'Your downloaded history is still saved.'
                    : p.restartRequired
                    ? 'iCloud encryption preparation timed out. Native work may still be running. '
                          'Further sync and account teardown are blocked for safety. '
                          'Fully close and restart OpenBubbles before resuming.'
                    : 'Diagnostic code: ${p.safeFailure}. Resolve the cause before resuming. '
                          'If native pause release is unconfirmed, restart OpenBubbles.',
              ),
            if (p.refreshFailed)
              const Text(
                'History was saved, but the chat list could not refresh. Restart OpenBubbles to refresh it.',
              ),
            const SizedBox(height: 8),
            if (!busy)
              const Text(
                'Prepares iCloud encryption, then resumes saved checkpoints. '
                'Apple may ask you to verify a device password. After an app restart, tap Start / resume.',
              ),
            if (!available && !busy)
              const Text(
                'Unavailable: requires the authorized Canary build, Developer Mode, '
                'an iCloud account, and no other sync in progress.',
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
                    onPressed: available && !busy && !p.restartRequired
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
                Text(
                  '${p.pages} pages journaled, ${p.batches} batches finished',
                ),
                const Text(
                  'Average rates include authentication and waiting time.',
                ),
                if (elsewhere)
                  const Text(
                    'Counters below describe the last foreground run, not the active background reader.',
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
                  'Remote head does not mean all media is downloaded.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'No history is skipped or reset. Leaving this page does not stop sync. '
                  'Backgrounding the app pauses foreground catch-up at a safe boundary. '
                  'Only the existing opted-in Android worker runs background reads; this screen does not enable it or keep the app alive. '
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
