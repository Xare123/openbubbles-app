import 'dart:async';
import 'dart:math';

import 'package:animations/animations.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/other_file.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_holder.dart';
import 'package:bluebubbles/app/components/circle_progress_bar.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/attachment_mime_utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';
import 'package:video_player/video_player.dart';

class MediaGalleryCard extends StatefulWidget {
  MediaGalleryCard({super.key, required this.attachment, this.mediaPager});
  final Attachment attachment;
  final ConversationMediaPager? mediaPager;

  @override
  State<MediaGalleryCard> createState() => _MediaGalleryCardState();
}

class _MediaGalleryCardState extends OptimizedState<MediaGalleryCard> with AutomaticKeepAliveClientMixin {
  Uint8List? videoPreview;
  Duration? duration;
  AttachmentDownloadController? controller;
  AttachmentDownloadController? _subscribedController;
  bool localFileAvailable = false;
  String? galleryThumbnailPath;
  late final void Function(PlatformFile) _downloadComplete;
  late final void Function() _downloadFailed;
  late PlatformFile attachmentFile = PlatformFile(
    name: safeAttachmentTransferName(attachment),
    path: kIsWeb ? null : attachment.path,
    bytes: attachment.bytes,
    size: safeAttachmentTotalBytes(attachment),
  );

  Attachment get attachment => widget.attachment;

  String? get resolvedMimeType => resolveAttachmentMimeType(
    attachmentFile.name,
    attachmentFile.path,
    uti: attachment.uti,
    declaredMimeType: attachment.mimeType,
  );

  @override
  void initState() {
    super.initState();
    _downloadComplete = _handleDownloadComplete;
    _downloadFailed = _handleDownloadFailed;
    bool usableFile = false;
    try {
      usableFile = !kIsWeb && isUsableDownloadedAttachmentFile(attachment.path);
    } catch (_) {}
    localFileAvailable = (attachment.bytes?.isNotEmpty ?? false) || usableFile;

    // check active downloader otherwise check file exists
    if (attachmentDownloader.getController(attachment.guid) != null) {
      controller = attachmentDownloader.getController(attachment.guid);
      _subscribeTo(controller!);
    } else if (!kIsWeb) {
      getBytes();
    }
  }

  void _subscribeTo(AttachmentDownloadController target) {
    if (!identical(_subscribedController, target)) {
      _unsubscribe();
      _subscribedController = target;
    }
    if (!target.completeFuncs.contains(_downloadComplete)) {
      target.completeFuncs.add(_downloadComplete);
    }
    if (!target.errorFuncs.contains(_downloadFailed)) {
      target.errorFuncs.add(_downloadFailed);
    }
    updateKeepAlive();
  }

  void _unsubscribe() {
    _subscribedController?.completeFuncs.remove(_downloadComplete);
    _subscribedController?.errorFuncs.remove(_downloadFailed);
    _subscribedController = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _handleDownloadComplete(PlatformFile file) {
    if (!mounted) return;
    setState(() {
      controller = null;
      attachmentFile = file;
      localFileAvailable = isUsableDownloadedPlatformFile(file);
    });
    updateKeepAlive();
    if (attachment.mimeType?.contains("video") ?? false) {
      getVideoPreview(file);
    } else if (attachment.mimeStart == 'image') {
      getBytes();
    }
  }

  void _handleDownloadFailed() {
    if (!mounted) return;
    setState(() {
      controller = null;
    });
    updateKeepAlive();
    showSnackbar("Error", "Failed to download attachment!");
  }

  void downloadAttachment() {
    if (controller?.error.value ?? false) {
      controller = null;
      Get.delete<AttachmentDownloadController>(tag: attachment.guid);
    }
    final next = attachmentDownloader.getOrStartDownload(
      attachment,
      onComplete: _downloadComplete,
      onError: _downloadFailed,
      prioritized: true,
    );
    setState(() {
      controller = next;
    });
    _subscribeTo(next);
  }

  Future<void> getBytes() async {
    final String pathName;
    try {
      pathName = attachment.path;
    } catch (_) {
      return;
    }
    if (isUsableDownloadedAttachmentFile(pathName) && mounted) {
      if (attachment.mimeStart == 'image') {
        final thumbnail = await as.getImageGalleryThumbnail(pathName);
        if (!mounted) return;
        setState(() {
          attachmentFile = PlatformFile(
            name: safeAttachmentTransferName(attachment),
            path: pathName,
            size: safeAttachmentTotalBytes(attachment),
          );
          galleryThumbnailPath = thumbnail;
          localFileAvailable = true;
        });
        return;
      }
      if (attachment.mimeStart == 'video') {
        setState(() {
          attachmentFile = PlatformFile(
            name: safeAttachmentTransferName(attachment),
            path: pathName,
            size: safeAttachmentTotalBytes(attachment),
          );
          localFileAvailable = true;
        });
        if (attachment.mimeStart == 'video') {
          getVideoPreview(attachmentFile);
        }
        return;
      }
      setState(() {
        attachmentFile = PlatformFile(
          name: safeAttachmentTransferName(attachment),
          path: pathName,
          size: safeAttachmentTotalBytes(attachment),
        );
        localFileAvailable = true;
      });
      if (attachment.mimeType?.contains("video") ?? false) {
        getVideoPreview(attachmentFile);
      }
    }
  }

  Future<void> getVideoPreview(PlatformFile file) async {
    if (videoPreview != null || file.path == null) return;
    if (attachment.metadata?['thumbnail_status'] == 'error') {
      return;
    }

    VideoPlayerController? tempController;
    try {
      videoPreview = await as.getVideoThumbnail(file.path!);
      tempController = VideoPlayerController.file(File(file.path!));
      await tempController.initialize();
      duration = tempController.value.duration;
    } catch (_) {
      // If an error occurs, set the thumbnail to the cached no preview image
      videoPreview = fs.noVideoPreviewIcon;

      if (attachment.metadata?['thumbnail_status'] != 'error') {
        attachment.metadata ??= {};
        attachment.metadata!['thumbnail_status'] = 'error';
        attachment.save(null);
      }
    } finally {
      await tempController?.dispose();
    }

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final bool hideAttachments = ss.settings.redactedMode.value && ss.settings.hideAttachments.value;

    late Widget child;
    bool addPadding = true;

    if (hideAttachments) {
      child = Text(
        resolvedMimeType ?? "Unknown",
        textAlign: TextAlign.center,
      );
    } else if (controller != null) {
      child = SizedBox(
        height: 40,
        width: 40,
        child: Obx(() => CircleProgressBar(
            foregroundColor: context.theme.colorScheme.primary,
            backgroundColor: context.theme.colorScheme.outline,
            value: controller!.progress.value?.toDouble() ?? 0)),
      );
    } else if (!localFileAvailable) {
      child = InkWell(
        onTap: downloadAttachment,
        child: resolvedMimeType?.split('/').first == 'image' ||
                resolvedMimeType?.split('/').first == 'video'
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.getFriendlySize(),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 5),
                  Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.cloud_download : Icons.cloud_download,
                      size: 28.0, color: context.theme.colorScheme.properOnSurface),
                  const SizedBox(height: 5),
                  Text(
                    attachment.mimeType ?? "Unknown File Type",
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            : DocumentDownloadPrompt(
                name: attachmentFile.name,
                typeLabel: conciseAttachmentTypeLabel(attachmentFile.name, resolvedMimeType),
                sizeLabel: attachment.getFriendlySize(),
              ),
      );
    } else if (attachment.mimeType?.startsWith("image") ?? false) {
      child = ImageDisplay(
        attachment: attachment,
        image: attachmentFile.bytes,
        path: galleryThumbnailPath ?? (attachmentFile.bytes == null ? attachmentFile.path : null),
        mediaPager: widget.mediaPager,
      );
      addPadding = false;
    } else if ((attachment.mimeType?.startsWith("video") ?? false) && !kIsDesktop && !kIsWeb) {
      if (videoPreview != null) {
        child = ImageDisplay(
          attachment: attachment,
          image: videoPreview!,
          duration: duration,
          mediaPager: widget.mediaPager,
        );
        addPadding = false;
      } else {
        child = const Text(
          "Loading video preview...",
          textAlign: TextAlign.center,
        );
      }
    } else {
      child = buildOtherFileIfAvailable(
        file: attachmentFile,
        attachment: attachment,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      clipBehavior: Clip.antiAlias,
      child: Container(
        alignment: Alignment.center,
        color: context.theme.colorScheme.properSurface,
        padding: addPadding ? const EdgeInsets.all(10) : null,
        child: child,
      ),
    );
  }

  @override
  bool get wantKeepAlive => controller != null;
}

class ImageDisplay extends StatelessWidget {
  const ImageDisplay({
    super.key,
    required this.attachment,
    this.image,
    this.path,
    this.duration,
    this.mediaPager,
  });

  final Attachment attachment;
  final Uint8List? image;
  final String? path;
  final Duration? duration;
  final ConversationMediaPager? mediaPager;

  @override
  Widget build(BuildContext context) {
    final columns = max(2, ns.width(context) ~/ 200);
    final logicalWidth = ns.width(context) / columns;
    final cacheWidth = (logicalWidth * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(256, 1024);
    return OpenContainer(
      openBuilder: (_, closeContainer) {
        return FullscreenMediaHolder(
          attachment: attachment,
          mediaPager: mediaPager,
          showInteractions: true,
        );
      },
      closedBuilder: (_, openContainer) {
        return InkWell(
          onTap: () {
            openContainer();
          },
          child: SizedBox(
            width: ns.width(context) / max(2, ns.width(context) ~/ 200),
            height: ns.width(context) / max(2, ns.width(context) ~/ 200),
            child: Stack(
              children: [
                if (path != null && !kIsWeb)
                  Image.file(
                    File(path!),
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    cacheWidth: cacheWidth,
                    width: logicalWidth,
                    height: logicalWidth,
                  )
                else
                  Image.memory(
                    image!,
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    cacheWidth: cacheWidth,
                    width: logicalWidth,
                    height: logicalWidth,
                  ),
                if ((attachment.mimeType?.contains("video") ?? false) && duration != null)
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: Text(
                      duration
                          .toString()
                          .split('.')
                          .first
                          .padLeft(8, "0")
                          .padLeft(9, "a")
                          .replaceFirst("a00:", "")
                          .replaceFirst("a", ""),
                      style: context.theme.textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                if (!(attachment.message.target?.isFromMe ?? true) &&
                    attachment.message.target?.handle != null &&
                    ss.settings.skin.value == Skins.iOS)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: ContactAvatarWidget(handle: attachment.message.target?.handle),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
