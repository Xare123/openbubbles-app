import 'dart:convert';

import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_holder.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/attachment_mime_utils.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' show basename, join;
import 'package:path_provider/path_provider.dart';
import 'package:universal_html/html.dart' as html;
import 'package:universal_io/io.dart';
import 'package:url_launcher/url_launcher.dart';

bool isOtherFileAvailable(PlatformFile file) => isUsableDownloadedPlatformFile(file);

Widget buildOtherFileIfAvailable({
  required PlatformFile file,
  required Attachment attachment,
}) {
  if (!isOtherFileAvailable(file)) return const SizedBox.shrink();
  return OtherFile(file: file, attachment: attachment);
}

class DocumentDownloadPrompt extends StatelessWidget {
  const DocumentDownloadPrompt({
    super.key,
    required this.name,
    required this.typeLabel,
    required this.sizeLabel,
  });

  final String name;
  final String typeLabel;
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.cloud_download : Icons.cloud_download,
            size: 28.0, color: context.theme.colorScheme.properOnSurface),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.theme.textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                '$typeLabel • $sizeLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class OtherFile extends StatelessWidget {
  OtherFile({
    super.key,
    required this.attachment,
    required this.file,
  });
  final Attachment attachment;
  final PlatformFile file;

  @override
  Widget build(BuildContext context) {
    final resolvedMimeType = resolveAttachmentMimeType(
      file.name,
      file.path,
      uti: attachment.uti,
      declaredMimeType: attachment.mimeType,
    );
    final fileTypeLabel = conciseAttachmentTypeLabel(file.name, resolvedMimeType);

    return InkWell(
      onTap: () async {
        if (!isOtherFileAvailable(file)) {
          showSnackbar(
            'Not Found',
            'This file is no longer available. Download it again.',
          );
          return;
        }
        if (attachment.mimeStart == "image" || (attachment.mimeStart == "video" && !isSnap)) {
          Navigator.of(Get.context!).push(
            ThemeSwitcher.buildPageRoute(
              builder: (context) => FullscreenMediaHolder(
                currentChat: cm.activeChat,
                attachment: attachment,
                showInteractions: true,
              ),
            ),
          );
          return;
        }
        if (kIsWeb || file.path == null) {
          final content = base64.encode(file.bytes!);
          html.AnchorElement(
              href: "data:application/octet-stream;charset=utf-16le;base64,$content")
            ..setAttribute("download", file.name)
            ..click();
        } else if (kIsDesktop) {
          File _file = File(join((await getTemporaryDirectory()).path, "BlueBubbles", "attachments", attachment.guid, basename(file.path!)));
          if (!_file.existsSync()) {
            _file.createSync(recursive: true);
            File(file.path!).copySync(_file.path);
          }
          launchUrl(Uri.file(_file.path));
        } else {
          try {
            final res = await OpenFilex.open(
              file.path!,
              type: resolvedMimeType ?? "application/octet-stream",
            );
            if (res.type == ResultType.noAppToOpen) {
              showSnackbar('Error', "No handler for this file type! Using share menu instead.");
              await Future.delayed(const Duration(seconds: 1));
              Share.file(file.name, file.path!);
            } else if (res.type == ResultType.error) {
              showSnackbar('Error', res.message);
            } else if (res.type == ResultType.fileNotFound) {
              showSnackbar('Not Found', "File not found at path: ${file.path}");
            } else if (res.type == ResultType.permissionDenied) {
              showSnackbar('Permission Denied', "BlueBubbles does not have access to this file! Using share menu instead.");
              await Future.delayed(const Duration(seconds: 1));
              Share.file(file.name, file.path!);
            }
          } catch (ex) {
            Logger.error("Error opening file: ${file.path}", error: ex);
            showSnackbar('Error', "No handler for this file type!");
          }
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              getAttachmentIcon(resolvedMimeType ?? ""),
              color: context.theme.colorScheme.properOnSurface,
              size: 35,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.theme.textTheme.bodyMedium!.apply(fontWeightDelta: 2),
                  ),
                  const SizedBox(height: 2.5),
                  Text(
                    "$fileTypeLabel • ${file.size.toDouble().getFriendlySize()}",
                    style: context.theme.textTheme.labelMedium!.copyWith(fontWeight: FontWeight.normal, color: context.theme.colorScheme.outline),
                    overflow: TextOverflow.clip,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
