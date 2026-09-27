import 'package:flutter/material.dart';

/// No retry or deletion controls while a native submission is retained or its
/// durable status cannot be checked. Does not claim successful delivery.
class SendRecoveryDialog extends StatelessWidget {
  const SendRecoveryDialog({super.key, this.statusUnavailable = false});

  final bool statusUnavailable;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      statusUnavailable
          ? 'Send status unavailable'
          : 'Send confirmation needed',
    ),
    content: Text(
      statusUnavailable
          ? 'The app could not check this saved send. Keep the message and try '
                'checking its status again after reopening the app. Nothing was resent '
                'or removed.'
          : 'This message may already have been sent. Its saved send record is '
                'being kept, so Retry and Remove are unavailable here. Wait for '
                'confirmation or check with the recipient before composing a new '
                'message, which could create a duplicate. Nothing was resent or removed.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}
