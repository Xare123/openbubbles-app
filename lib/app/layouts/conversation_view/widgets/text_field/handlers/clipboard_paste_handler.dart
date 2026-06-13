import 'package:bluebubbles/database/global/platform_file.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' hide context;
import 'package:universal_io/io.dart';

/// Handles clipboard paste operations (Ctrl+V or Cmd+V).
///
/// Supports:
/// - Pasting files from clipboard (desktop)
/// - Pasting images from clipboard
/// - Pasting text from clipboard (fallback)
class ClipboardPasteHandler {
  final ConversationViewController controller;

  ClipboardPasteHandler({
    required this.controller,
  });

  /// Handle Ctrl+V (or Cmd+V) paste key event.
  /// Returns true if the event was handled.
  Future<bool> handlePasteEvent() async {
    try {
      // Try to get files first (desktop: file picker simulation)
      if (kIsDesktop) {
        final files = await Pasteboard.files();
        if (files.isNotEmpty) {
          for (final String path in files) {
            final String name = basename(path);
            final File file = File(path);
            controller.pickedAttachments.add(PlatformFile(
              name: name,
              path: path,
              bytes: file.readAsBytesSync(),
              size: file.lengthSync(),
            ));
          }
          return true;
        }
      }

      // Try to get image from clipboard
      final image = await Pasteboard.image;
      if (image != null) {
        controller.pickedAttachments.add(PlatformFile(
          name: "image-${controller.pickedAttachments.length + 1}.png",
          bytes: image,
          size: image.length,
        ));
        return true;
      }

      // Fallback to text paste (handled by OS keyboard)
      return false;
    } catch (e) {
      // Silently fail and let OS handle text paste
      return false;
    }
  }

  /// Handle content insertion from keyboard (e.g., pasted images on mobile).
  /// This is called via ContentInsertionConfiguration.onContentInserted.
  void handleKeyboardInsertedContent(KeyboardInsertedContent content) async {
    // Parse filename from URI
    String filename = FilesystemSvc.uriToFilename(content.uri, content.mimeType);

    // Save data to attachments if available
    if (content.hasData) {
      controller.pickedAttachments.add(PlatformFile(
        name: filename,
        size: content.data!.length,
        bytes: content.data,
      ));
    }
  }
}
