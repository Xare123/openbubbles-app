import 'dart:io';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/dialogs/attachment_info_summary.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
/// Shared production conversion for the ordinary file-information UI.
///
/// Accepts the full [Attachment] so nested descriptors, keys, URLs, and
/// identifiers can never reach the rendered rows: only the allowlisted
/// summary fields are derived here. Callers may pass verified on-disk
/// bytes and an already-resolved message date; nothing here reads globals.
List<Widget> buildAttachmentInfoRows(
  Attachment attachment,
  BuildContext context, {
  int? localBytes,
  DateTime? dateCreated,
}) {
  final summary = summarizeAttachment(
    transferName: attachment.transferName,
    mimeType: attachment.mimeType,
    uti: attachment.uti,
    advertisedBytes: attachment.totalBytes,
    localBytes: localBytes,
    width: attachment.width,
    height: attachment.height,
    dateCreated: dateCreated,
  );
  List<Widget> metaWidgets = [];
  for (final entry in attachmentInfoRows(summary)) {
    metaWidgets.add(RichText(
      text: TextSpan(
        children: [
          TextSpan(text: "${entry.key}: ", style: context.theme.textTheme.bodyLarge!.apply(fontWeightDelta: 2)),
          TextSpan(text: entry.value, style: context.theme.textTheme.bodyLarge)
        ],
      ),
    ));
  }
  return metaWidgets;
}
void showMetadataDialog(Attachment a, BuildContext context) {
  int? localBytes;
  try {
    final file = File(a.path);
    if (file.existsSync()) {
      localBytes = file.lengthSync();
    }
  } catch (_) {
    localBytes = null;
  }
  DateTime? messageDate;
  try {
    messageDate = a.message.target?.dateCreated;
  } catch (_) {
    messageDate = null;
  }
  List<Widget> metaWidgets =
      buildAttachmentInfoRows(a, context, localBytes: localBytes, dateCreated: messageDate);
  if (metaWidgets.isEmpty) {
    metaWidgets.add(Text(
      "No metadata available",
      style: context.theme.textTheme.bodyLarge,
      textAlign: TextAlign.center,
    ));
  }

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        "Metadata",
        style: context.theme.textTheme.titleLarge,
      ),
      backgroundColor: context.theme.colorScheme.properSurface,
      content: SizedBox(
        width: ns.width(context) * 3 / 5,
        height: context.height * 1 / 4,
        child: Container(
          padding: const EdgeInsets.all(10.0),
          decoration: BoxDecoration(
            color: context.theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10)
          ),
          child: ListView(
            physics: ThemeSwitcher.getScrollPhysics(),
            children: metaWidgets,
          ),
        ),
      ),
      actions: [
        TextButton(
          child: Text(
            "Close",
            style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}
