import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:flutter/material.dart';

/// Explicit opt-in for automatic archival of sent messages. Opening Profile
/// never enables anything: every enable passes a scrollable confirmation
/// with an unchecked acknowledgment of pending uploads first.
class CloudSyncAutomaticArchiveCard extends StatefulWidget {
  const CloudSyncAutomaticArchiveCard({
    super.key,
    required this.onLoad,
    required this.onChanged,
  });

  final Future<CloudSyncAutomaticArchivePreference> Function() onLoad;
  final Future<CloudSyncAutomaticArchivePreference> Function(
    CloudSyncAutomaticArchivePreference,
    bool, {
    required bool acknowledgeQueuedUploads,
  })
  onChanged;

  @override
  State<CloudSyncAutomaticArchiveCard> createState() =>
      _CloudSyncAutomaticArchiveCardState();
}

class _CloudSyncAutomaticArchiveCardState
    extends State<CloudSyncAutomaticArchiveCard> {
  CloudSyncAutomaticArchivePreference? _preference;
  bool _busy = true;
  bool _confirming = false;
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
              'Automatic archival settings are unavailable. Finish iCloud setup, then try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(
    bool enabled, {
    required bool acknowledgeQueuedUploads,
  }) async {
    final preference = _preference;
    if (_busy || preference == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.onChanged(
        preference,
        enabled,
        acknowledgeQueuedUploads: acknowledgeQueuedUploads,
      );
      if (mounted) setState(() => _preference = saved);
    } catch (_) {
      if (mounted) {
        setState(() {
          _preference = null;
          _error =
              'The setting could not be confirmed. Reload it before trying again. Saved messages are kept.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmEnable() async {
    if (_busy || _confirming || _preference == null) return;
    setState(() => _confirming = true);
    var acknowledged = false;
    bool? accepted;
    try {
      accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Enable automatic archival?'),
            scrollable: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'This archives sent messages to iCloud automatically, including '
                  'queued uploads already on this device and ones found during '
                  'recovery, as well as future sends. Messages are not sent again '
                  'as iMessages. This does not import all older chats; that is a '
                  'separate history action. Uncertain uploads still require the '
                  'existing confirmation checks.',
                ),
                CheckboxListTile(
                  value: acknowledged,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'I understand queued uploads will be archived.',
                  ),
                  onChanged: (value) =>
                      setDialogState(() => acknowledged = value ?? false),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: acknowledged
                    ? () => Navigator.pop(context, true)
                    : null,
                child: const Text('Enable automatic archival'),
              ),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (accepted == true && mounted) {
      await _change(true, acknowledgeQueuedUploads: true);
    }
  }

  void _onSwitch(bool enabled) {
    if (_busy || _confirming || _preference == null) return;
    if (enabled) {
      unawaited(_confirmEnable());
      return;
    }
    unawaited(_change(false, acknowledgeQueuedUploads: false));
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
                'Archive sent messages to iCloud',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Semantics(
              label: 'Archive sent messages to iCloud',
              child: Switch.adaptive(
                value: _preference?.enabled ?? false,
                onChanged: _busy || _confirming || _preference == null
                    ? null
                    : _onSwitch,
              ),
            ),
          ],
        ),
        Text(
          'Archive messages you send to iCloud automatically after sending is confirmed.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Turning this off stops new automatic archival. A batch already running may finish.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(
            semanticsLabel: 'Updating automatic archival setting',
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
