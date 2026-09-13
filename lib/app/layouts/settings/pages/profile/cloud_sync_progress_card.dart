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
  });
  final CloudSyncProgress progress;
  final bool Function() isAvailable;
  final Future<void> Function(CloudSyncSpeed) onStart;

  @override
  State<CloudSyncProgressCard> createState() => _CloudSyncProgressCardState();
}

class _CloudSyncProgressCardState extends State<CloudSyncProgressCard> {
  CloudSyncSpeed speed = CloudSyncSpeed.regular;

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
          'Turbo can slow your phone, make it hot, and drain the battery. '
          'It allows up to 16 foreground batches instead of 8. Each batch keeps the same safe limits. '
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
    if (mounted && accepted == true && !widget.progress.active) {
      setState(() => speed = CloudSyncSpeed.turbo);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.progress,
    builder: (context, _) {
      final p = widget.progress;
      final available = widget.isAvailable();
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
            Semantics(liveRegion: true, child: Text(p.title)),
            if (p.active) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: p.fraction,
                semanticsLabel: 'History total unknown',
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${p.pages} pages journaled, ${p.fetched} new journal records, ${p.batches} batches finished',
            ),
            const SizedBox(height: 8),
            Text(
              p.mediaActive > 0
                  ? 'Materializing media: ${p.mediaActive} active'
                  : 'Media downloads on demand',
            ),
            if (p.safeFailure != null)
              Text(
                p.restartRequired
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
            const Text(
              'Prepares iCloud encryption, then resumes saved checkpoints. '
              'Apple may ask you to verify a device password. After an app restart, tap Start / resume.',
            ),
            if (!available && !p.active)
              const Text(
                'Unavailable: requires the authorized Canary build, Developer Mode, '
                'an iCloud account, and no other sync in progress.',
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Turbo'),
              subtitle: const Text(
                'Regular is the default. Turbo can slow, heat, and drain your phone.',
              ),
              value: p.active
                  ? p.speed == CloudSyncSpeed.turbo
                  : speed == CloudSyncSpeed.turbo,
              onChanged: p.active ? null : selectTurbo,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!p.active)
                  FilledButton.icon(
                    onPressed: available && !p.restartRequired
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
                'Pause cancels this catch-up at a safe boundary, not existing downloads or background sync.',
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Sync details'),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
