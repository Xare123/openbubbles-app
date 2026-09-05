import 'package:flutter/material.dart';

Future<void> confirmRegistrationRepair(
  BuildContext context, {
  required Future<void> Function() repair,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Repair iMessage registration?'),
      content: const Text(
        'Reopen Apple Account sign-in using your existing device identity. '
        'Your saved chats and downloaded media stay on this device. '
        'This does not sign out your other Apple devices. '
        'If CloudKit is busy, repair may wait or ask you to try again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Repair registration'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) await repair();
}
