import 'dart:async';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_historical_import_controller.dart';
import 'package:flutter/material.dart';

/// Optional upgrade-history action within Profile, using its inherited theme.
/// The service owns the work after confirmation; this widget only owns its
/// unconsumed preview. Navigation never deletes history or aborts a network call.
class CloudSyncHistoricalImportCard extends StatefulWidget {
  const CloudSyncHistoricalImportCard({
    super.key,
    required this.controller,
    required this.isAvailable,
    required this.onPrepare,
    required this.onConfirm,
  });

  final CloudSyncHistoricalImportController controller;
  final bool Function() isAvailable;
  final Future<CloudSyncHistoricalImportConfirmation> Function() onPrepare;
  final Future<void> Function(CloudSyncHistoricalImportConfirmation) onConfirm;

  @override
  State<CloudSyncHistoricalImportCard> createState() =>
      _HistoricalImportCardState();
}

class _HistoricalImportCardState extends State<CloudSyncHistoricalImportCard> {
  bool _requesting = false;
  bool _available = false;
  String? _error;
  Timer? _refresh;
  CloudSyncHistoricalImportConfirmation? _preview;
  CloudSyncHistoricalImportController? _previewOwner;

  @override
  void initState() {
    super.initState();
    _available = widget.isAvailable();
    // Readiness may change outside the controller. A mounted-only display tick
    // never starts account work or replays an import.
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      final available = widget.isAvailable();
      if (available != _available) setState(() => _available = available);
    });
  }

  void _cancelPreview() {
    final preview = _preview;
    if (preview != null) _previewOwner?.cancel(preview);
    _preview = null;
    _previewOwner = null;
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _cancelPreview();
    super.dispose();
  }

  static String _failure(Object? error) {
    final code = error is StateError ? error.message : error;
    return switch (code) {
      'cloud_sync_historical_import_confirmation_expired' ||
      'cloud_sync_historical_import_identity_changed' =>
        'The account or confirmation changed. Review the destination again before continuing.',
      'cloud_sync_historical_import_owner_required' =>
        'History uploads are not enabled for this account yet. No messages were submitted.',
      'cloud_sync_historical_import_source_invalid' ||
      'cloud_sync_historical_import_source_changed' =>
        'The selected history does not match its saved snapshot. Review the source again. Existing messages and saved uploads are preserved.',
      'cloud_sync_historical_import_reader_pending' =>
        'Downloaded history still needs processing. Let normal sync finish, then review this import again.',
      'cloud_sync_historical_archive_confirmation_pending' =>
        'iCloud has not confirmed the current upload. Its saved operation will be checked when you resume. Do not resend the message.',
      'cloud_sync_historical_import_busy' ||
      'cloud_sync_historical_import_unavailable' =>
        'Sync is busy or its setup is unavailable. Finish setup or wait for the current work, then try again.',
      'cloud_sync_historical_snapshot_empty' =>
        'There are no local messages to import.',
      'cloud_sync_historical_snapshot_limit' =>
        'This history exceeds the current import limit. Nothing was truncated or uploaded.',
      'cloud_sync_historical_snapshot_storage_unavailable' =>
        'The private history snapshot could not be saved. Check available storage, then try again.',
      _ =>
        'History import stopped safely. Saved messages and pending work are retained. Try again, or share diagnostics if it keeps stopping.',
    };
  }

  Future<void> _start() async {
    if (_requesting || widget.controller.active || !widget.isAvailable()) {
      return;
    }
    setState(() {
      _requesting = true;
      _error = null;
    });
    final owner = widget.controller;
    try {
      final preview = await widget.onPrepare();
      if (!mounted || !identical(owner, widget.controller)) {
        owner.cancel(preview);
        return;
      }
      _preview = preview;
      _previewOwner = owner;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            preview.retryingMissingAttachments
                ? 'Recheck messages with missing attachments?'
                : 'Upload existing messages?',
          ),
          scrollable: true,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Destination Apple Account'),
              Text(
                preview.accountLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(preview.sourceLabel),
              Text(
                '${preview.messageCount} local messages captured on '
                '${MaterialLocalizations.of(context).formatMediumDate(preview.capturedAt)}.',
              ),
              const SizedBox(height: 12),
              if (preview.retryingMissingAttachments)
                const Text(
                  'Recheck attachment messages retained from the same snapshot. '
                  'Confirmed messages are not uploaded again. '
                  'Messages whose files are still missing remain pending. '
                  'This does not recover missing files or turn on automatic uploads.',
                )
              else
                const Text(
                  'Add these messages to this account\'s iCloud history. '
                  'They will not be sent again to anyone. '
                  'Older messages can remain after signing out, so check the account above. '
                  'You can pause and resume. Messages that cannot be uploaded stay on this device. '
                  'This does not turn on automatic uploads.',
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                preview.retryingMissingAttachments
                    ? 'Recheck attachments'
                    : 'Upload messages',
              ),
            ),
          ],
        ),
      );
      if (!mounted ||
          accepted != true ||
          !identical(owner, widget.controller)) {
        return;
      }
      if (!widget.isAvailable()) {
        setState(
          () => _error = _failure('cloud_sync_historical_import_unavailable'),
        );
        return;
      }
      // Keep the preview until confirm consumes it, so an exception before the
      // service accepts ownership still cancels the unused permission below.
      await widget.onConfirm(preview);
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    } finally {
      _cancelPreview();
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final headline = switch (c.phase) {
        CloudSyncHistoricalImportPhase.idle => 'Messages on this device',
        CloudSyncHistoricalImportPhase.preparing =>
          'Preparing your messages for review',
        CloudSyncHistoricalImportPhase.awaitingConfirmation =>
          'Waiting for your confirmation',
        CloudSyncHistoricalImportPhase.running => 'Uploading existing messages',
        CloudSyncHistoricalImportPhase.pausing =>
          'Finishing the current message before pausing',
        CloudSyncHistoricalImportPhase.paused => 'Upload paused',
        CloudSyncHistoricalImportPhase.scanComplete =>
          'Existing messages checked',
        CloudSyncHistoricalImportPhase.needsAttention =>
          'History import needs attention',
      };
      final unsupported = c.ineligibleByReason.values.fold<int>(
        0,
        (a, b) => a + b,
      );
      final error =
          _error ?? (c.failureCode == null ? null : _failure(c.failureCode));
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                headline,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Upload messages already on this device to iCloud. '
              'They will not be sent again to anyone.',
            ),
            if (c.active) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(
                semanticsLabel:
                    'Processing local history; total upload count unknown',
              ),
            ],
            if (c.sourceRows > 0) ...[
              const SizedBox(height: 8),
              Text(
                'This session: ${c.assessed} reviewed, ${c.confirmedCreates} confirmed in iCloud.',
              ),
              Text(
                '${c.readerHandoffs} found in iCloud and handed to sync; '
                '${c.skippedOwned} managed by existing sync.',
              ),
              if (c.deferredMissingMetadata > 0)
                Text(
                  '${c.deferredMissingMetadata} older messages need additional address information before uploading. '
                  'Their protected copies remain saved; other supported messages can continue.',
                ),
              if (c.deferredMissingAttachments > 0)
                Text(
                  '${c.deferredMissingAttachments} messages were kept because an original attachment file is missing from this device. '
                  'The messages remain saved for a later attempt. Missing files have not been backed up.',
                ),
              if (unsupported > 0 || c.retainedConflicts > 0)
                Text(
                  'Not imported: $unsupported unsupported, ${c.retainedConflicts} conflicts. Originals remain local.',
                ),
              if (c.scanComplete)
                const Text(
                  'A finished scan does not mean every message was uploaded. '
                  'Counts above cover this session only; earlier confirmations remain saved.',
                ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(error)),
            ],
            const SizedBox(height: 8),
            if (c.active)
              OutlinedButton.icon(
                onPressed: c.phase == CloudSyncHistoricalImportPhase.pausing
                    ? null
                    : c.pause,
                icon: const Icon(Icons.pause),
                label: const Text('Pause upload'),
              )
            else if (c.phase != CloudSyncHistoricalImportPhase.scanComplete)
              OutlinedButton.icon(
                onPressed: !_requesting && widget.isAvailable() ? _start : null,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(
                  c.phase == CloudSyncHistoricalImportPhase.idle
                      ? 'Upload existing messages'
                      : 'Resume upload',
                ),
              ),
            if (!c.active && !_requesting && !widget.isAvailable())
              const Text(
                'Available when iCloud setup is ready and other sync work is idle.',
              ),
          ],
        ),
      );
    },
  );
}
