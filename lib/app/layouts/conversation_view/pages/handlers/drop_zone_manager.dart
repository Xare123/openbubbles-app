import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/global/platform_file.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' hide context;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:universal_io/io.dart';

/// Manages drag-and-drop file operations on the message list.
///
/// Responsibilities:
/// - Track drag state (files over the drop zone)
/// - Validate dropped files
/// - Convert dropped files to PlatformFile objects
/// - Add files to the attachment picker
class DropZoneManager {
  final ConversationViewController controller;

  /// Whether files are currently being dragged over the drop zone
  final RxBool dragging = false.obs;

  /// Number of valid files in the current drag session
  final RxInt numFiles = 0.obs;

  DropZoneManager({required this.controller});

  /// Check if drop is allowed (only copy operations with file format items)
  DropOperation onDropOver(DropOverEvent event) {
    if (!event.session.allowedOperations.contains(DropOperation.copy)) {
      dragging.value = false;
      return DropOperation.forbidden;
    }

    // Count files that can be provided in standard formats
    numFiles.value = event.session.items
        .where((item) => Formats.standardFormats.whereType<FileFormat>().any((f) => item.canProvide(f)))
        .length;

    if (numFiles.value > 0) {
      dragging.value = true;
      return DropOperation.copy;
    }

    dragging.value = false;
    return DropOperation.forbidden;
  }

  /// Handle drag leaving the drop zone
  void onDropLeave(DropEvent event) {
    dragging.value = false;
  }

  /// Process dropped files and add them to attachments
  Future<void> onPerformDrop(
    PerformDropEvent event,
    ConversationViewController controller,
  ) async {
    for (DropItem item in event.session.items) {
      final reader = item.dataReader!;
      FileFormat? format = reader.getFormats(Formats.standardFormats).whereType<FileFormat>().firstOrNull;

      if (format == null) continue;

      await reader.getFile(format, (file) async {
        Uint8List bytes = await file.readAll();
        String filePath = file.fileName ?? "";
        String fileName = file.fileName ?? "";

        // On Linux, the file path is encoded as UTF-8 bytes
        if (Platform.isLinux) {
          filePath = String.fromCharCodes(bytes);
          File linuxFile = File(filePath);
          bytes = await linuxFile.readAsBytes();
          fileName = basename(filePath);
        }

        // Fallback names if not provided
        if (filePath.isEmpty) {
          filePath = "Dragged_File_${controller.pickedAttachments.length + 1}";
        }
        if (fileName.isEmpty) {
          fileName = "Dragged_File_${controller.pickedAttachments.length + 1}";
        }

        // Add to attachments
        controller.pickedAttachments.add(PlatformFile(
          path: filePath,
          name: fileName,
          size: bytes.length,
          bytes: bytes,
        ));
      });
    }

    dragging.value = false;
  }
}
