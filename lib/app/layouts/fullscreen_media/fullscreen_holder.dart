import 'package:bluebubbles/app/components/circle_progress_bar.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_image.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_media_list.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_media_operation_gate.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_video.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_video_page_swipe.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import "package:flutter/material.dart";
import 'package:flutter/services.dart';
import 'package:gesture_x_detector/gesture_x_detector.dart';
import 'package:get/get.dart';
import 'package:photo_view/photo_view.dart' show PhotoViewGestureDetectorScope;

class FullscreenMediaHolder extends StatefulWidget {
  FullscreenMediaHolder(
      {super.key,
      required this.attachment,
      required this.showInteractions,
      this.currentChat,
      this.mediaPager,
      this.videoController,
      this.mute});

  final ChatLifecycleManager? currentChat;
  final Attachment attachment;
  final ConversationMediaPager? mediaPager;
  final bool showInteractions;
  final VideoController? videoController;
  final RxBool? mute;

  @override
  FullscreenMediaHolderState createState() => FullscreenMediaHolderState();
}

class FullscreenMediaHolderState extends OptimizedState<FullscreenMediaHolder> {
  final focusNode = FocusNode();
  final Map<String, FullscreenMediaOperationGate> _downloadGates = {};
  late final PageController controller;
  late final messageService =
      widget.currentChat == null ? null : ms(widget.currentChat!.chat.guid);
  late List<Attachment> attachments;
  ConversationMediaPager? mediaPager;
  bool ownsMediaPager = false;

  int currentIndex = 0;
  ScrollPhysics? physics;
  Attachment get attachment => widget.attachment;
  bool showAppBar = true;

  bool _isCurrentAttachment(Attachment candidate) {
    if (attachments.isEmpty ||
        currentIndex < 0 ||
        currentIndex >= attachments.length) return false;
    final current = attachments[currentIndex];
    if (candidate.guid != null && current.guid != null) {
      return candidate.guid == current.guid;
    }
    return identical(candidate, current);
  }

  AttachmentDownloadController _startDownload(Attachment target) {
    final gate = _downloadGates.putIfAbsent(
      target.guid!,
      FullscreenMediaOperationGate.new,
    );
    final generation = gate.begin();
    return attachmentDownloader.startDownload(target, onComplete: (_) {
      if (!mounted ||
          !gate.isCurrent(generation) ||
          !_isCurrentAttachment(target)) return;
      setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    mediaPager = widget.mediaPager;
    if (mediaPager == null && !kIsWeb && widget.currentChat != null) {
      mediaPager = ConversationMediaPager(chat: widget.currentChat!.chat);
      ownsMediaPager = true;
      mediaPager!.seed(
        buildFullscreenMediaList(
          messageService!.struct.attachments,
          attachment,
        ),
        selected: attachment,
      );
    }
    attachments = mediaPager?.items ??
        buildFullscreenMediaList(<Attachment>[], attachment);
    mediaPager?.addListener(_onMediaChanged);

    if (kIsWeb || !widget.showInteractions) {
      controller = PageController(initialPage: 0);
    } else {
      if (widget.currentChat != null || mediaPager != null) {
        currentIndex = attachments.indexWhere((e) => e.guid == attachment.guid);
        if (currentIndex == -1) {
          attachments = <Attachment>[...attachments, attachment];
          currentIndex = attachments.length - 1;
        }
      }
      controller = PageController(initialPage: currentIndex);
      physics = _pagePhysicsFor(currentIndex);
    }
    if (ownsMediaPager) {
      mediaPager!.primeAroundSelection();
    }
  }

  void _onMediaChanged() {
    if (!mounted || mediaPager == null) return;
    final currentGuid = attachments.isEmpty
        ? attachment.guid
        : attachments[currentIndex.clamp(0, attachments.length - 1)].guid;
    final updated = mediaPager!.items;
    final updatedIndex = updated.indexWhere((item) =>
        item.guid == currentGuid ||
        (currentGuid == null && identical(item, attachment)));
    if (updatedIndex < 0) return;

    setState(() {
      attachments = updated;
      currentIndex = updatedIndex;
      physics = _pagePhysicsFor(updatedIndex);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && controller.hasClients) {
        controller.jumpToPage(updatedIndex);
      }
    });
  }

  void _onVideoPageSwipe(FullscreenVideoPageSwipeDirection direction) {
    if (!mounted || !controller.hasClients || attachments.length < 2) return;

    final reverse =
        ss.settings.fullscreenViewerSwipeDir.value == SwipeDirection.RIGHT;
    final indexDelta = fullscreenVideoPageDelta(direction, reverse: reverse);
    final target = currentIndex + indexDelta;
    if (target < 0 || target >= attachments.length) return;

    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  ScrollPhysics _pagePhysicsFor(int index) {
    if (attachments.length < 2) {
      return const NeverScrollableScrollPhysics();
    }
    if (!kIsWeb &&
        !kIsDesktop &&
        index >= 0 &&
        index < attachments.length &&
        attachments[index].mimeStart == "video") {
      // Video controls also observe horizontal drags. Disable the PageView's
      // competing recognizer while a video is active so the raw video swipe
      // surface is the single owner of page navigation.
      return const NeverScrollableScrollPhysics();
    }
    return ThemeSwitcher.getScrollPhysics();
  }

  @override
  void dispose() {
    for (final gate in _downloadGates.values) {
      gate.dispose();
    }
    mediaPager?.removeListener(_onMediaChanged);
    if (ownsMediaPager) mediaPager?.dispose();
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TitleBarWrapper(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: ss.settings.immersiveMode.value
              ? Colors.transparent
              : context.theme.colorScheme.surface, // navigation bar color
          systemNavigationBarIconBrightness:
              context.theme.colorScheme.brightness.opposite,
          statusBarColor: Colors.transparent, // status bar color
          statusBarIconBrightness: ss.settings.skin.value != Skins.iOS
              ? Brightness.light
              : context.theme.colorScheme.brightness.opposite,
        ),
        child: Actions(
          actions: {
            GoBackIntent: GoBackAction(context),
          },
          child: Scaffold(
            appBar: !iOS || !showAppBar
                // AppBar placeholder to prevent shifting of content when toggling the app bar
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(56),
                    child: Container())
                : AppBar(
                    leading: XGestureDetector(
                      supportTouch: true,
                      onTap: !kIsDesktop
                          ? null
                          : (details) {
                              Navigator.of(context).pop();
                            },
                      child: TextButton(
                        child: Text("Done",
                            style: context.theme.textTheme.bodyLarge!.copyWith(
                                color: context.theme.colorScheme.primary)),
                        onPressed: () {
                          if (kIsDesktop) return;
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
                    leadingWidth: 75,
                    title: Text(
                        kIsWeb ||
                                !widget.showInteractions ||
                                attachments.length == 1
                            ? "Media"
                            : "${currentIndex + 1} of ${attachments.length}",
                        style: context.theme.textTheme.titleLarge!.copyWith(
                            color: context.theme.colorScheme.properOnSurface)),
                    centerTitle: iOS,
                    iconTheme:
                        IconThemeData(color: context.theme.colorScheme.primary),
                    backgroundColor: context.theme.colorScheme.properSurface,
                    systemOverlayStyle:
                        context.theme.colorScheme.brightness == Brightness.dark
                            ? SystemUiOverlayStyle.light
                            : SystemUiOverlayStyle.dark,
                  ),
            backgroundColor: Colors.black,
            body: FocusScope(
              child: Focus(
                focusNode: focusNode,
                autofocus: true,
                onKeyEvent: (node, event) {
                  Logger.info(
                      "Got device label ${event.deviceType.label}, physical key ${event.physicalKey.toString()}, logical key ${event.logicalKey.toString()}",
                      tag: "RawKeyboardListener");
                  if (event.physicalKey.debugName == "Arrow Right") {
                    if (ss.settings.fullscreenViewerSwipeDir.value ==
                        SwipeDirection.RIGHT) {
                      controller.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeIn);
                    } else {
                      controller.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeIn);
                    }
                  } else if (event.physicalKey.debugName == "Arrow Left") {
                    if (ss.settings.fullscreenViewerSwipeDir.value ==
                        SwipeDirection.LEFT) {
                      controller.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeIn);
                    } else {
                      controller.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeIn);
                    }
                  } else if (event.physicalKey.debugName == "Escape") {
                    Navigator.of(context).pop();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: PhotoViewGestureDetectorScope(
                  // Lets a contained image yield horizontal drags to the
                  // PageView. A zoomed image keeps its own pan gesture, and
                  // FullscreenImage disables this PageView while zoomed.
                  axis: Axis.horizontal,
                  child: PageView.builder(
                    physics: physics ??
                        (attachments.length == 1
                            ? const NeverScrollableScrollPhysics()
                            : ThemeSwitcher.getScrollPhysics()),
                    reverse: ss.settings.fullscreenViewerSwipeDir.value ==
                        SwipeDirection.RIGHT,
                    itemCount: attachments.length,
                    onPageChanged: (int val) {
                      widget.videoController?.player.pause();
                      setState(() {
                        currentIndex = val;
                        physics = _pagePhysicsFor(val);
                      });
                      if (val <= 2) {
                        mediaPager?.loadNewer();
                      }
                      if (val >= attachments.length - 3) {
                        mediaPager?.loadOlder();
                      }
                    },
                    controller: controller,
                    itemBuilder: (BuildContext context, int index) {
                      final attachment = attachments[index];
                      final content = as.getContent(attachment,
                          path: attachment.guid == null
                              ? attachment.sourcePath
                              : null);
                      final key = attachment.guid ??
                          attachment.transferName ??
                          randomString(8);

                      if (content is PlatformFile) {
                        if (attachment.mimeStart == "image") {
                          return FullscreenImage(
                            key: Key(key),
                            attachment: attachment,
                            file: content,
                            showInteractions: widget.showInteractions,
                            updatePhysics: (ScrollPhysics p) {
                              if (!mounted ||
                                  !_isCurrentAttachment(attachment)) {
                                return;
                              }
                              if (physics != p) {
                                setState(() {
                                  physics = p;
                                });
                              }
                            },
                            onOverlayToggle: (show) {
                              if (!mounted ||
                                  !_isCurrentAttachment(attachment)) {
                                return;
                              }
                              if (showAppBar != show) {
                                setState(() {
                                  showAppBar = show;
                                });
                              }
                            },
                          );
                        } else if (attachment.mimeStart == "video") {
                          return FullscreenVideo(
                            key: Key(key),
                            file: content,
                            attachment: attachment,
                            showInteractions: widget.showInteractions,
                            isActive: index == currentIndex,
                            onPageSwipe: attachments.length < 2
                                ? null
                                : _onVideoPageSwipe,
                            videoController: widget.videoController,
                            mute: widget.mute,
                          );
                        } else {
                          return const SizedBox.shrink();
                        }
                      } else if (content is Attachment) {
                        final Attachment _content = content;
                        return InkWell(
                          onTap: () {
                            _startDownload(_content);
                            setState(() {});
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              SizedBox(
                                height: 40,
                                width: 40,
                                child: Center(
                                    child: Icon(
                                        iOS
                                            ? CupertinoIcons.cloud_download
                                            : Icons.cloud_download_outlined,
                                        size: 30)),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                (_content.mimeType ?? ""),
                                style: context.theme.textTheme.bodyLarge!
                                    .copyWith(
                                        color: context
                                            .theme.colorScheme.properOnSurface),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _content.getFriendlySize(),
                                style: context.theme.textTheme.bodyMedium!
                                    .copyWith(
                                        color: context
                                            .theme.colorScheme.properOnSurface),
                                maxLines: 1,
                              ),
                            ],
                          ),
                        );
                      } else if (content is AttachmentDownloadController) {
                        final AttachmentDownloadController _content = content;
                        return InkWell(
                          onTap: () {
                            final AttachmentDownloadController _content =
                                content;
                            if (!_content.error.value) return;
                            Get.delete<AttachmentDownloadController>(
                                tag: _content.attachment.guid);
                            _startDownload(_content.attachment);
                            setState(() {});
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(20.0),
                            child: Obx(() {
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  SizedBox(
                                    height: 40,
                                    width: 40,
                                    child: Center(
                                      child: _content.error.value
                                          ? Icon(
                                              iOS
                                                  ? CupertinoIcons
                                                      .arrow_clockwise
                                                  : Icons.refresh,
                                              size: 30)
                                          : CircleProgressBar(
                                              value: _content.progress.value
                                                      ?.toDouble() ??
                                                  0,
                                              backgroundColor: context
                                                  .theme.colorScheme.outline,
                                              foregroundColor: context.theme
                                                  .colorScheme.properOnSurface,
                                            ),
                                    ),
                                  ),
                                  _content.error.value
                                      ? const SizedBox(height: 10)
                                      : const SizedBox(height: 5),
                                  Text(
                                    _content.error.value
                                        ? "Failed to download!"
                                        : (_content.attachment.mimeType ?? ""),
                                    style: context.theme.textTheme.bodyLarge!
                                        .copyWith(
                                            color: context.theme.colorScheme
                                                .properOnSurface),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                ],
                              );
                            }),
                          ),
                        );
                      } else {
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              "Error loading attachment",
                              style: context.theme.textTheme.bodyLarge,
                            ),
                          ],
                        );
                      }
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
