import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_background_read_preference.dart';
import 'package:flutter/material.dart';

/// An explicit read-only scheduling preference. Opening Profile never opts in.
class CloudSyncBackgroundReadCard extends StatefulWidget {
  const CloudSyncBackgroundReadCard({
    super.key,
    required this.onLoad,
    required this.onChanged,
  });

  final Future<CloudSyncBackgroundReadPreference> Function() onLoad;
  final Future<CloudSyncBackgroundReadPreference> Function(
    CloudSyncBackgroundReadPreference,
    bool,
  )
  onChanged;

  @override
  State<CloudSyncBackgroundReadCard> createState() =>
      _CloudSyncBackgroundReadCardState();
}

class _CloudSyncBackgroundReadCardState
    extends State<CloudSyncBackgroundReadCard> {
  CloudSyncBackgroundReadPreference? _preference;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preference = await widget.onLoad();
      if (mounted) setState(() => _preference = preference);
    } catch (_) {
      if (mounted) {
        setState(() {
          _preference = null;
          _error =
              'Background sync settings are unavailable. Finish iCloud setup, then try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(bool enabled) async {
    final preference = _preference;
    if (_busy || preference == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.onChanged(preference, enabled);
      if (mounted) setState(() => _preference = saved);
    } catch (error) {
      if (mounted) {
        setState(() {
          // A failed/replaced context must be freshly read before another edit.
          _preference = null;
          _error =
              error is StateError &&
                  error.message ==
                      'cloud_sync_background_preference_schedule_pending'
              ? 'Your choice was saved, but background sync could not be scheduled. Tap Start / resume to try again.'
              : error is StateError && error.message ==
                  'cloud_sync_background_preference_notifications_pending'
              ? 'Your choice was saved and local sync is scheduled. Cloud update notifications are not ready yet; setup will retry. Tap Start / resume to check for updates now.'
              : 'The setting could not be confirmed. Reload it before trying again. Saved messages are kept.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Background history sync',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Semantics(
              label: 'Background history sync',
              child: Switch.adaptive(
                value: _preference?.enabled ?? false,
                onChanged: _busy || _preference == null ? null : _change,
              ),
            ),
          ],
        ),
        Text(
          'Allow this account to download history updates when Android schedules them. '
          'This does not enable uploads or automatically download attachments.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Turning this off stops new background reads. A batch already running may finish. '
          'Start / resume still works here.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(
            semanticsLabel: 'Updating background sync setting',
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: Theme.of(context).textTheme.bodyMedium),
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Reload setting'),
          ),
        ],
      ],
    ),
  );
}
