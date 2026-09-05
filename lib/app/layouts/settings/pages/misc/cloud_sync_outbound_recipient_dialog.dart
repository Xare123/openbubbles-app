import 'package:flutter/material.dart';

/// Own the controller for the route's full lifetime, including reverse
/// transitions after Navigator.pop has completed the showDialog Future.
class CloudSyncOutboundRecipientDialog extends StatefulWidget {
  const CloudSyncOutboundRecipientDialog({super.key, this.backgroundColor});

  final Color? backgroundColor;

  @override
  State<CloudSyncOutboundRecipientDialog> createState() =>
      _CloudSyncOutboundRecipientDialogState();
}

class _CloudSyncOutboundRecipientDialogState
    extends State<CloudSyncOutboundRecipientDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: widget.backgroundColor,
      title: Text(
        'Enter the exact test recipient',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      content: TextField(
        controller: _controller,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(
          hintText: 'Apple email or phone number',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final recipient = _controller.text.trim();
            if (recipient.isNotEmpty) {
              Navigator.of(context).pop(recipient);
            }
          },
          child: const Text('Use Exact Recipient'),
        ),
      ],
    );
  }
}
