import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get_utils/src/extensions/context_extensions.dart';

import 'backup_restore_types.dart';

class BackupRestoreDialogs {
  static Future<BackupDestination?> showBackupDestinationDialog(BuildContext context) async {
    return showDialog<BackupDestination>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
          title: Text(
            "Choose Backup Location",
            style: Theme.of(ctx).textTheme.titleLarge,
          ),
          content: Text(
            "Local - Save a backup to this device.\nCloud - Save a backup to the server for use across all your devices.",
            style: Theme.of(ctx).textTheme.bodyLarge,
          ),
          actions: [
            TextButton(
              child: Text("Local",
                  style: Theme.of(ctx).textTheme.bodyLarge!.copyWith(color: Theme.of(ctx).colorScheme.primary)),
              onPressed: () => Navigator.of(ctx).pop(BackupDestination.local),
            ),
            TextButton(
              child: Text("Cloud",
                  style: Theme.of(ctx).textTheme.bodyLarge!.copyWith(color: Theme.of(ctx).colorScheme.primary)),
              onPressed: () => Navigator.of(ctx).pop(BackupDestination.cloud),
            ),
          ],
        );
      },
    );
  }

  static Future<void> showConfirmation({
    required BuildContext context,
    required String title,
    required Widget content,
    required VoidCallback onYes,
    VoidCallback? onNo,
  }) async {
    await showDialog(
      context: context,
      builder: (ctx) => areYouSure(
        ctx,
        title: title,
        content: content,
        onNo: onNo ?? () => Navigator.of(ctx).pop(),
        onYes: onYes,
      ),
    );
  }

  static Future<void> showJsonData({
    required BuildContext context,
    required String title,
    required String jsonText,
  }) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: Theme.of(ctx).textTheme.titleLarge,
        ),
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
        content: SizedBox(
          width: NavigationSvc.width(ctx) * 3 / 5,
          height: ctx.height * 1 / 4,
          child: Container(
            padding: const EdgeInsets.all(10.0),
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.surface,
              borderRadius: const BorderRadius.all(Radius.circular(10)),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                jsonText,
                style: Theme.of(ctx).textTheme.bodyLarge,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            child: Text(
              "Close",
              style: Theme.of(ctx).textTheme.bodyLarge!.copyWith(color: Theme.of(ctx).colorScheme.primary),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }
}
