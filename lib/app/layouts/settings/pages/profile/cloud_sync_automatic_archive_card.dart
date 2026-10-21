import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:flutter/material.dart';

/// Explicit opt-in for automatic archival of sent messages. Opening Profile
/// never enables anything: every enable passes a scrollable confirmation
/// with an unchecked acknowledgment of pending uploads first. Available
/// received-message support requires a separate, explicit scope selection.
class CloudSyncAutomaticArchiveCard extends StatefulWidget {
  const CloudSyncAutomaticArchiveCard({
    super.key,
    required this.onLoad,
    required this.onChanged,
    this.receivedArchiveAvailable = false,
    this.receivedMediaArchiveAvailable = false,
    this.onChangedWithMedia,
  });

  final Future<CloudSyncAutomaticArchivePreference> Function() onLoad;
  final Future<CloudSyncAutomaticArchivePreference> Function(
    CloudSyncAutomaticArchivePreference,
    bool, {
    required bool acknowledgeQueuedUploads,
    bool includeReceived,
  })
  onChanged;

  /// Optional until the caller wires the media-aware preference and worker gates.
  /// The original callback remains usable for existing sent/text-only callers.
  final Future<CloudSyncAutomaticArchivePreference> Function(
    CloudSyncAutomaticArchivePreference,
    bool, {
    required bool acknowledgeQueuedUploads,
    bool includeReceived,
    bool includeReceivedMedia,
  })?
  onChangedWithMedia;

  final bool receivedArchiveAvailable;
  final bool receivedMediaArchiveAvailable;

  @override
  State<CloudSyncAutomaticArchiveCard> createState() =>
      _CloudSyncAutomaticArchiveCardState();
}

class _CloudSyncAutomaticArchiveCardState
    extends State<CloudSyncAutomaticArchiveCard> {
  static const _receivedCoverageNote =
      'Attachments, replies, reactions, edits, and other message changes are not '
      'newly covered by this opt-in. Existing iCloud restores can still include '
      'media already archived by Apple.';
  static const _receivedMediaCoverageNote =
      'Only supported received and mirrored attachments are covered. Replies, '
      'reactions, edits, and other message changes are not newly covered by this '
      'opt-in. Existing iCloud restores can still include media already archived '
      'by Apple.';
  static const _receivedRecoveryNote =
      'Messages saved locally remain here if secure iCloud capture is unavailable. '
      'A receive that fails before protected capture has no saved automatic '
      'archive retry. Finish setup for future archival. '
      '"Upload existing messages" checks its reviewed snapshot only, not later '
      'arrivals, and does not guarantee recovery of missed messages, edits, or undos.';

  CloudSyncAutomaticArchivePreference? _preference;
  bool _busy = true;
  bool _confirming = false;
  String? _error;

  bool get _receivedMediaAvailable =>
      widget.receivedArchiveAvailable &&
      widget.receivedMediaArchiveAvailable &&
      widget.onChangedWithMedia != null;

  bool get _scopeChangeAvailable =>
      widget.receivedArchiveAvailable &&
      (!(_preference?.includesReceivedMedia ?? false) ||
          _receivedMediaAvailable);

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
    bool includeReceived = false,
    bool includeReceivedMedia = false,
  }) async {
    final preference = _preference;
    if (_busy ||
        preference == null ||
        (enabled && includeReceived && !widget.receivedArchiveAvailable) ||
        (enabled && includeReceivedMedia && !_receivedMediaAvailable)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mediaChanged = widget.onChangedWithMedia;
      final saved = mediaChanged != null
          ? await mediaChanged(
              preference,
              enabled,
              acknowledgeQueuedUploads: acknowledgeQueuedUploads,
              includeReceived: includeReceived,
              includeReceivedMedia: includeReceivedMedia,
            )
          : await widget.onChanged(
              preference,
              enabled,
              acknowledgeQueuedUploads: acknowledgeQueuedUploads,
              includeReceived: includeReceived,
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

  Future<void> _confirmEnable({bool changeScope = false}) async {
    if (_busy ||
        _confirming ||
        _preference == null ||
        (changeScope && !_scopeChangeAvailable)) {
      return;
    }
    setState(() => _confirming = true);
    var acknowledged = false;
    var includeReceived =
        widget.receivedArchiveAvailable && _preference!.includesReceived;
    var includeReceivedMedia =
        _receivedMediaAvailable && _preference!.includesReceivedMedia;
    bool? accepted;
    try {
      accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(
              changeScope
                  ? 'Change archival scope?'
                  : 'Enable automatic archival?',
            ),
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
                if (widget.receivedArchiveAvailable) ...[
                  CheckboxListTile(
                    key: const ValueKey('automaticArchiveIncludeReceived'),
                    value: includeReceived,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Include supported received text'),
                    subtitle: const Text(
                      'Also archive queued and future supported received text in '
                      'direct and group chats, including supported mirrored plain '
                      'text and queued uploads found during recovery.',
                    ),
                    onChanged: (value) => setDialogState(() {
                      includeReceived = value ?? false;
                      if (!includeReceived) includeReceivedMedia = false;
                      acknowledged = false;
                    }),
                  ),
                  if (_receivedMediaAvailable)
                    CheckboxListTile(
                      key: const ValueKey(
                        'automaticArchiveIncludeReceivedMedia',
                      ),
                      value: includeReceivedMedia,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Include supported received media'),
                      subtitle: const Text(
                        'Also archive queued and future supported received attachments '
                        'in direct and group chats, including supported mirrored media '
                        'and queued uploads found during recovery.',
                      ),
                      onChanged: includeReceived
                          ? (value) => setDialogState(() {
                              includeReceivedMedia = value ?? false;
                              acknowledged = false;
                            })
                          : null,
                    ),
                  Text(
                    includeReceivedMedia
                        ? _receivedMediaCoverageNote
                        : _receivedCoverageNote,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    _receivedRecoveryNote,
                    key: ValueKey(
                      'automaticArchiveReceiveRecoveryConfirmation',
                    ),
                  ),
                ],
                CheckboxListTile(
                  key: const ValueKey('automaticArchiveQueuedAcknowledgment'),
                  value: acknowledged,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    includeReceivedMedia
                        ? 'I understand queued uploads and future sends, received text, '
                              'and received media will be archived.'
                        : 'I understand queued uploads will be archived.',
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
                child: Text(
                  changeScope
                      ? 'Save archival scope'
                      : 'Enable automatic archival',
                ),
              ),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (accepted == true && mounted) {
      await _change(
        true,
        acknowledgeQueuedUploads: true,
        includeReceived: includeReceived,
        includeReceivedMedia: includeReceivedMedia,
      );
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

  bool get _receivedEnabled =>
      widget.receivedArchiveAvailable &&
      (_preference?.includesReceived ?? false);

  bool get _receivedMediaEnabled =>
      _receivedMediaAvailable && (_preference?.includesReceivedMedia ?? false);

  String get _title => _receivedMediaEnabled
      ? 'Archive sent messages and supported received text and media to iCloud'
      : (_receivedEnabled
            ? 'Archive sent messages and supported received text to iCloud'
            : 'Archive sent messages to iCloud');

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
                _title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Semantics(
              label: _title,
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
          _receivedMediaEnabled
              ? 'Archive sent messages after sending is confirmed, plus supported '
                    'received text and attachments, including mirrored text and media, '
                    'in direct and group chats to iCloud automatically.'
              : _receivedEnabled
              ? 'Archive sent messages after sending is confirmed, plus supported '
                    'received text, including mirrored plain text, in direct and '
                    'group chats to iCloud automatically.'
              : 'Archive messages you send to iCloud automatically after sending is confirmed.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (_receivedEnabled) ...[
          const SizedBox(height: 8),
          Text(
            (_preference?.includesReceivedMedia ?? false)
                ? _receivedMediaCoverageNote
                : _receivedCoverageNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (widget.receivedArchiveAvailable) ...[
          const SizedBox(height: 8),
          Text(
            _receivedRecoveryNote,
            key: const ValueKey('automaticArchiveReceiveRecovery'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (_scopeChangeAvailable && (_preference?.enabled ?? false))
          TextButton(
            onPressed: _busy || _confirming
                ? null
                : () => unawaited(_confirmEnable(changeScope: true)),
            child: const Text('Change archival scope'),
          ),
        if (!widget.receivedArchiveAvailable &&
            (_preference?.includesReceived ?? false)) ...[
          const SizedBox(height: 8),
          Text(
            'Supported received and mirrored text archival is unavailable in this build. '
            'Your saved archival scope is kept.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        if (!_receivedMediaAvailable &&
            (_preference?.includesReceivedMedia ?? false)) ...[
          const SizedBox(height: 8),
          Text(
            'Supported received and mirrored media archival is unavailable in this '
            'build. Your saved archival scope is kept.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Turning this off stops new automatic archival. A batch already running may finish. '
          'Saved messages stay available, and already submitted uploads can still be checked.',
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
