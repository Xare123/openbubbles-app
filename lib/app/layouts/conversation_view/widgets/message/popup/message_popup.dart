import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/timeframe_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/details_menu_action.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/reaction_picker_clipper.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/components/custom/custom_cupertino_alert_dialog.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_pin_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_clipper.dart';
import 'package:bluebubbles/app/wrappers/bb_annotated_region.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/wrappers/titlebar_wrapper.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:collection/collection.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart' as picker;
import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide BackButton;
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart' hide Response, FormData, MultipartFile;
import 'package:intl/intl.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' hide context;
import 'package:permission_handler/permission_handler.dart';
import 'package:sprung/sprung.dart';
import 'package:dio/dio.dart';
import 'package:bluebubbles/models/models.dart' show MessageReplyContext;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:universal_io/io.dart';

class MessagePopupServerDetails {
  final bool minSierra;
  final bool minBigSur;
  final bool supportsOriginalDownload;
  const MessagePopupServerDetails(
      {required this.minSierra, required this.minBigSur, required this.supportsOriginalDownload});
}

class MessagePopup extends StatefulWidget {
  final Offset childPosition;
  final Size size;
  final Widget child;
  final MessagePart part;
  final MessageState controller;
  final ConversationViewController cvController;
  final MessagePopupServerDetails serverDetails;
  final Function([String? type, String? emoji, int? part]) sendTapback;
  final BuildContext? Function() widthContext;

  const MessagePopup({
    super.key,
    required this.childPosition,
    required this.size,
    required this.child,
    required this.part,
    required this.controller,
    required this.cvController,
    required this.serverDetails,
    required this.sendTapback,
    required this.widthContext,
  });

  @override
  State<StatefulWidget> createState() => _MessagePopupState();
}

class _MessagePopupState extends State<MessagePopup> with SingleTickerProviderStateMixin, ThemeHelpers {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    animationBehavior: AnimationBehavior.preserve,
  );
  final double itemHeight = kIsDesktop || kIsWeb ? 56 : 48;

  List<Message> reactions = [];
  late double messageOffset = Get.height - widget.childPosition.dy - widget.size.height;
  late double materialOffset = widget.childPosition.dy +
      EdgeInsets.fromViewPadding(
        View.of(context).viewInsets,
        View.of(context).devicePixelRatio,
      ).bottom;
  late int numberToShow = 5;
  late Chat? dmChat = ChatsSvc.allChats.firstWhereOrNull((chat) =>
      !chat.isGroup &&
      chat.handles.firstWhereOrNull((handle) => handle.address == message.handleRelation.target?.address) != null);
  String? selfReaction;
  String? currentlySelectedReaction = "init";

  ConversationViewController get cvController => widget.cvController;

  MessagesService get service => MessagesSvc(chat.guid);

  Chat get chat => widget.cvController.chat;

  MessagePart get part => widget.part;

  Message get message => widget.controller.message;

  bool get isSent {
    final isSending = widget.controller.isSending.value;
    final hasError = widget.controller.hasError.value;
    return !isSending && !hasError;
  }

  bool get showDownload =>
      (isSent &&
          part.attachments.isNotEmpty &&
          part.attachments.where((element) => AttachmentsSvc.getContent(element) is PlatformFile).isNotEmpty) ||
      isEmbeddedMedia;

  late bool isEmbeddedMedia = (message.balloonBundleId == "com.apple.Handwriting.HandwritingProvider" ||
          message.balloonBundleId == "com.apple.DigitalTouchBalloonProvider") &&
      File(message.interactiveMediaPath!).existsSync();

  bool get minSierra => widget.serverDetails.minSierra;

  bool get minBigSur => widget.serverDetails.minBigSur;

  bool get supportsOriginalDownload => widget.serverDetails.supportsOriginalDownload;

  BuildContext get widthContext => widget.widthContext.call() ?? context;

  List<String> reactOptions = ReactionTypes.toList();
  Map<String, Emoji> emojiMap = {};
  static const double iosSize = 50;
  int emojiMode = 1;
  int emojiPickerSize = 325;

  @override
  void initState() {
    super.initState();
    controller.forward();
    if (iOS) {
      final remainingHeight = max(Get.height - Get.statusBarHeight - 135 - widget.size.height, itemHeight);
      numberToShow = min(remainingHeight ~/ itemHeight, 5);
    } else {
      // Potentially make this dynamic in the future
      numberToShow = 5;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      currentlySelectedReaction = null;
      reactions = getUniqueReactionMessages(message.associatedMessages
          .where((e) =>
              ReactionTypes.toList().contains(e.associatedMessageType?.replaceAll("-", "")) &&
              (e.associatedMessagePart ?? 0) == part.part)
          .toList());
      final selfMessage = reactions.firstWhereOrNull((e) => e.isFromMe!);
      final self = selfMessage?.associatedMessageType == ReactionTypes.EMOJI
          ? selfMessage?.associatedMessageEmoji
          : selfMessage?.associatedMessageType;
      if (!(self?.contains("-") ?? true)) {
        selfReaction = self;
        currentlySelectedReaction = selfReaction;
      }
      unawaited(() async {
        final reactions = await getReactionList();
        if (!mounted) return;
        setState(() {
          reactOptions = reactions;
          if (reactions.length == 6) {
            emojiMode = 0;
            emojiPickerSize = iOS ? 280 : 286;
          } else if (reactions.length == 7) {
            emojiMode = 1;
            emojiPickerSize = iOS ? 325 : 331;
          } else {
            emojiMode = 2;
            emojiPickerSize = iOS ? 350 : 356;
          }
        });
      }());
      setState(() {
        if (iOS) messageOffset = itemHeight * numberToShow + 40;
      });
    });
  }

  Future<List<String>> getReactionList() async {
    final recentEmojis = await EmojiPickerUtils().getRecentEmojis();
    final reactions = ReactionTypes.toList().where((i) => ReactionTypes.reactionToEmoji.containsKey(i)).toList();

    if (currentlySelectedReaction != "init" &&
        currentlySelectedReaction != null &&
        !reactions.contains(currentlySelectedReaction)) {
      reactions.add(currentlySelectedReaction!);
    }

    for (final emoji in recentEmojis.take(10)) {
      if (reactions.contains(emoji.emoji.emoji)) continue;
      reactions.add(emoji.emoji.emoji);
      emojiMap[emoji.emoji.emoji] = emoji.emoji;
    }

    final defaults = ["❤️", "😍", "😒", "👌", "☺️", "😊", "😘", "😭", "😩", "💕"];
    while (reactions.length < 16 && defaults.isNotEmpty) {
      final emoji = defaults.removeAt(0);
      if (reactions.contains(emoji)) continue;
      reactions.add(emoji);
    }

    return reactions;
  }

  void reactEmoji(String emoji) {
    HapticFeedback.lightImpact();
    widget.sendTapback(selfReaction == emoji ? "-${ReactionTypes.EMOJI}" : ReactionTypes.EMOJI, emoji, part.part);
    popDetails();
  }

  void popDetails({bool returnVal = true}) {
    Navigator.of(context).pop(returnVal);
  }

  @override
  Widget build(BuildContext context) {
    double narrowWidth = message.isFromMe! || !SettingsSvc.settings.alwaysShowAvatars.value ? 330 : 360;
    bool narrowScreen = NavigationSvc.width(widthContext) < narrowWidth;

    return BBAnnotatedRegion(
      child: Theme(
        data: context.theme.copyWith(
          // in case some components still use legacy theming
          primaryColor: context.theme.colorScheme.bubble(context, chat.isIMessage),
          colorScheme: context.theme.colorScheme.copyWith(
            primary: context.theme.colorScheme.bubble(context, chat.isIMessage),
            onPrimary: context.theme.colorScheme.onBubble(context, chat.isIMessage),
            surface: SettingsSvc.settings.monetTheming.value == Monet.full
                ? null
                : (context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor,
            onSurface: SettingsSvc.settings.monetTheming.value == Monet.full
                ? null
                : (context.theme.extensions[BubbleColors] as BubbleColors?)?.onReceivedBubbleColor,
          ),
        ),
        child: TitleBarWrapper(
            child: Scaffold(
                extendBodyBehindAppBar: true,
                backgroundColor: kIsDesktop && iOS && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
                    ? context.theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
                    : Colors.transparent,
                appBar: iOS
                    ? null
                    : AppBar(
                        backgroundColor: context.theme.colorScheme.surface.oppositeLightenOrDarken(5),
                        systemOverlayStyle: context.theme.colorScheme.brightness == Brightness.dark
                            ? SystemUiOverlayStyle.light
                            : SystemUiOverlayStyle.dark,
                        automaticallyImplyLeading: false,
                        leadingWidth: 40,
                        toolbarHeight: kIsDesktop ? 80 : null,
                        leading: Padding(
                          padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0, left: 10.0),
                          child: BackButton(
                            color: context.theme.colorScheme.onSurface,
                            onPressed: () {
                              popDetails();
                              return true;
                            },
                          ),
                        ),
                        actions: buildMaterialDetailsMenu(context),
                      ),
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onTap: popDetails,
                      child: iOS
                          ? (SettingsSvc.settings.highPerfMode.value
                              ? Container(color: context.theme.colorScheme.surface.withValues(alpha: 0.5))
                              : BackdropFilter(
                                  filter: ImageFilter.blur(
                                      sigmaX:
                                          kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
                                              ? 10
                                              : 30,
                                      sigmaY:
                                          kIsDesktop && SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
                                              ? 10
                                              : 30),
                                  child: Container(
                                    color: context.theme.colorScheme.surface.withValues(alpha: 0.5).darkenAmount(0.2),
                                  ),
                                ))
                          : null,
                    ),
                    if (iOS)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutBack,
                        left: widget.childPosition.dx,
                        bottom: messageOffset,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0.8, end: 1),
                          curve: Curves.easeOutBack,
                          duration: const Duration(milliseconds: 500),
                          child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: widget.size.width),
                              child: MessageStateScope(
                                messageState: widget.controller,
                                child: widget.child,
                              )),
                          builder: (context, size, child) {
                            return Transform.scale(
                              scale: size.clamp(1, double.infinity),
                              alignment: message.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
                              child: child,
                            );
                          },
                        ),
                      ),
                    if (iOS)
                      Positioned(
                        top: 40,
                        left: 15,
                        right: 15,
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 500),
                          curve: Sprung.underDamped,
                          alignment: Alignment.center,
                          child: reactions.isNotEmpty ? ReactionDetails(reactions: reactions) : const SizedBox.shrink(),
                        ),
                      ),
                    if (SettingsSvc.settings.enablePrivateAPI.value && isSent && minSierra && chat.isIMessage)
                      Positioned(
                        bottom: (iOS
                                ? itemHeight * numberToShow + 35 + widget.size.height
                                : context.height - materialOffset)
                            .clamp(0, context.height - (narrowScreen ? 200 : 125)),
                        right: message.isFromMe! ? max(15, widget.size.width - emojiPickerSize + 65) : null,
                        left: !message.isFromMe!
                            ? max(widget.childPosition.dx + 10,
                                widget.childPosition.dx + widget.size.width - emojiPickerSize + 65)
                            : null,
                        child: AnimatedSize(
                          curve: Curves.easeInOut,
                          alignment: message.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
                          duration: const Duration(milliseconds: 250),
                          child: currentlySelectedReaction == "init"
                              ? const SizedBox(height: 80)
                              : ClipShadowPath(
                                  shadow: iOS
                                      ? BoxShadow(
                                          color: context.theme.colorScheme.surfaceContainerHighest
                                              .withAlpha(iOS ? 150 : 255)
                                              .lightenOrDarken(iOS ? 0 : 10))
                                      : BoxShadow(
                                          color: context.theme.colorScheme.shadow,
                                          blurRadius: 2,
                                        ),
                                  clipper: ReactionPickerClipper(
                                    messageSize: widget.size,
                                    isFromMe: message.isFromMe!,
                                  ),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                                    child: Container(
                                      padding: const EdgeInsets.all(5).add(const EdgeInsets.only(bottom: 15)),
                                      color: context.theme.colorScheme.surfaceContainerHighest
                                          .withAlpha(iOS ? 150 : 255)
                                          .lightenOrDarken(iOS ? 0 : 10),
                                      width: emojiPickerSize.toDouble(),
                                      child: ShaderMask(
                                        shaderCallback: (Rect rect) {
                                          return LinearGradient(
                                            begin: Alignment.centerLeft,
                                            end: Alignment.centerRight,
                                            colors: [
                                              Colors.transparent,
                                              emojiMode == 2 ? Colors.purple : Colors.transparent
                                            ],
                                            stops: const [0.9, 1.0],
                                          ).createShader(rect);
                                        },
                                        blendMode: BlendMode.dstOut,
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          padding: emojiMode == 2 ? const EdgeInsets.only(right: 25) : EdgeInsets.zero,
                                          child: Row(
                                            children: reactOptions.map((e) {
                                              final isBuiltInReaction = ReactionTypes.toList().contains(e);
                                              return Padding(
                                                padding: iOS
                                                    ? const EdgeInsets.all(5.0)
                                                    : const EdgeInsets.symmetric(horizontal: 5),
                                                child: Material(
                                                  color: currentlySelectedReaction == e
                                                      ? context.theme.colorScheme.primary
                                                      : Colors.transparent,
                                                  borderRadius: BorderRadius.circular(20),
                                                  child: SizedBox(
                                                    width: iOS ? 35 : null,
                                                    height: iOS ? 35 : null,
                                                    child: InkWell(
                                                      borderRadius: BorderRadius.circular(20),
                                                      onTap: () {
                                                        currentlySelectedReaction =
                                                            currentlySelectedReaction == e ? null : e;
                                                        setState(() {});
                                                        if (isBuiltInReaction) {
                                                          HapticFeedback.lightImpact();
                                                          widget.sendTapback(
                                                              selfReaction == e ? "-$e" : e, null, part.part);
                                                          popDetails();
                                                          return;
                                                        }
                                                        if (selfReaction != e) {
                                                          unawaited(() async {
                                                            Emoji? emoji = emojiMap[e];
                                                            if (emoji == null) {
                                                              outerLoop:
                                                              for (final category in defaultEmojiSet) {
                                                                for (final candidate in category.emoji) {
                                                                  if (candidate.emoji == e) {
                                                                    emojiMap[e] = candidate;
                                                                    emoji = candidate;
                                                                    break outerLoop;
                                                                  }
                                                                }
                                                              }
                                                            }
                                                            if (emoji != null) {
                                                              await EmojiPickerUtils().addEmojiToRecentlyUsed(
                                                                  key: GlobalKey(), emoji: emoji!);
                                                            }
                                                          }());
                                                        }
                                                        reactEmoji(e);
                                                      },
                                                      child: Padding(
                                                        padding: EdgeInsets.symmetric(
                                                                horizontal: 6.5, vertical: iOS ? 4.5 : 6.5)
                                                            .add(EdgeInsets.only(right: e == "emphasize" ? 2.5 : 0)),
                                                        child: Center(
                                                          child: Builder(builder: (context) {
                                                            final text = Text(
                                                              ReactionTypes.reactionToEmoji[e] ?? e,
                                                              style: const TextStyle(
                                                                  fontSize: 18, fontFamily: 'Apple Color Emoji'),
                                                              textAlign: TextAlign.center,
                                                            );
                                                            if (e == "dislike") {
                                                              return Transform(
                                                                transform: Matrix4.identity()..rotateY(pi),
                                                                alignment: FractionalOffset.center,
                                                                child: text,
                                                              );
                                                            }
                                                            return text;
                                                          }),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }).toList(),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    if (SettingsSvc.settings.enablePrivateAPI.value && isSent && minSierra && chat.isIMessage)
                      Positioned(
                        bottom: (iOS
                                ? itemHeight * numberToShow + 5 + widget.size.height
                                : context.height - materialOffset - 30)
                            .clamp(0, context.height - (narrowScreen ? 200 : 125)),
                        right: message.isFromMe! ? widget.size.width + 10 + (iOS ? 0 : 60) : null,
                        left: !message.isFromMe!
                            ? widget.childPosition.dx + widget.size.width + 10 + (iOS ? 0 : 60)
                            : null,
                        child: AnimatedSize(
                          curve: Curves.easeInOut,
                          alignment: message.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
                          duration: const Duration(milliseconds: 100),
                          child: currentlySelectedReaction == "init"
                              ? const SizedBox(height: 80)
                              : ClipPath(
                                  clipper: ReactionClipper(
                                    tailDirection:
                                        message.isFromMe! ? ReactionTailDirection.left : ReactionTailDirection.right,
                                  ),
                                  child: Material(
                                    color: context.theme.colorScheme.surfaceContainerHighest,
                                    child: Container(
                                      width: iosSize,
                                      height: iosSize,
                                      alignment: message.isFromMe! ? Alignment.topRight : Alignment.topLeft,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(20),
                                        onTap: () {
                                          final content = SizedBox(
                                            width: 512,
                                            child: Theme(
                                              data: context.theme.copyWith(canvasColor: Colors.transparent),
                                              child: EmojiPicker(
                                                scrollController: ScrollController(),
                                                config: Config(
                                                  height: 512,
                                                  checkPlatformCompatibility: true,
                                                  emojiViewConfig: EmojiViewConfig(
                                                    emojiSizeMax: 28,
                                                    backgroundColor: Colors.transparent,
                                                    columns: min(NavigationSvc.width(context), 512) ~/ 56,
                                                    noRecents: Text(
                                                      "No Recents",
                                                      style: context.textTheme.headlineMedium!
                                                          .copyWith(color: context.theme.colorScheme.outline),
                                                    ),
                                                  ),
                                                  skinToneConfig: const SkinToneConfig(enabled: false),
                                                  categoryViewConfig: const CategoryViewConfig(
                                                    backgroundColor: Colors.transparent,
                                                    dividerColor: Colors.transparent,
                                                  ),
                                                  bottomActionBarConfig: BottomActionBarConfig(
                                                    customBottomActionBar: (Config config, EmojiViewState state,
                                                        VoidCallback showSearchView) {
                                                      return Container(
                                                        margin: const EdgeInsets.only(top: 10),
                                                        child: Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            const SizedBox(width: 8),
                                                            Expanded(
                                                              child: Material(
                                                                child: InkWell(
                                                                  onTap: showSearchView,
                                                                  child: Padding(
                                                                    padding: const EdgeInsets.all(12),
                                                                    child: Row(children: [
                                                                      Icon(
                                                                        iOS
                                                                            ? cupertino.CupertinoIcons.search
                                                                            : Icons.search,
                                                                        color: context.theme.colorScheme.outline,
                                                                      ),
                                                                      const SizedBox(width: 8),
                                                                      Expanded(
                                                                        child: Text(
                                                                          "Search...",
                                                                          style: context.theme.textTheme.bodyLarge!
                                                                              .copyWith(
                                                                            color: context.theme.colorScheme.outline,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ]),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            Padding(
                                                              padding: const EdgeInsets.all(12),
                                                              child: IconButton(
                                                                icon: Icon(
                                                                  iOS ? cupertino.CupertinoIcons.xmark : Icons.close,
                                                                  color: context.theme.colorScheme.outline,
                                                                ),
                                                                onPressed: () {
                                                                  Navigator.of(context, rootNavigator: true).pop();
                                                                },
                                                              ),
                                                            ),
                                                            const SizedBox(width: 8),
                                                          ],
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                  searchViewConfig: SearchViewConfig(
                                                    backgroundColor: Colors.transparent,
                                                    buttonIconColor: context.theme.colorScheme.outline,
                                                  ),
                                                ),
                                                onEmojiSelected: (cat, emoji) {
                                                  Navigator.of(context, rootNavigator: true).pop();
                                                  reactEmoji(emoji.emoji);
                                                },
                                              ),
                                            ),
                                          );
                                          Get.dialog(
                                            AlertDialog(
                                              backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                                              content: content,
                                            ),
                                            name: 'Popup Menu',
                                          );
                                        },
                                        child: const SizedBox(
                                          width: iosSize * 0.8,
                                          height: iosSize * 0.8,
                                          child: Icon(
                                            cupertino.CupertinoIcons.smiley,
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    if (iOS)
                      Positioned(
                        right: message.isFromMe! ? 15 : null,
                        left: !message.isFromMe! ? widget.childPosition.dx + 10 : null,
                        bottom: 30,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0.8, end: 1),
                          curve: Curves.easeOutBack,
                          duration: const Duration(milliseconds: 400),
                          child: FadeTransition(
                            opacity: CurvedAnimation(
                              parent: controller,
                              curve: const Interval(0.0, .9, curve: Curves.ease),
                              reverseCurve: Curves.easeInCubic,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 5),
                                buildDetailsMenu(context),
                              ],
                            ),
                          ),
                          builder: (context, size, child) {
                            return Transform.scale(
                              scale: size,
                              child: child,
                            );
                          },
                        ),
                      ),
                    if (!iOS && SettingsSvc.settings.enablePrivateAPI.value && minBigSur && chat.isIMessage && isSent)
                      Positioned(
                        left: !message.isFromMe!
                            ? widget.childPosition.dx + widget.size.width + (reactions.isNotEmpty ? 20 : 5)
                            : widget.childPosition.dx - 55,
                        top: materialOffset,
                        child: Material(
                          color: context.theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(20),
                          child: SizedBox(
                            width: 35,
                            height: 35,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: reply,
                              child: const Center(child: Icon(Icons.reply, size: 20)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ))),
      ),
    );
  }

  void reply() {
    popDetails();
    cvController.replyToMessage = MessageReplyContext(message, part.part);
  }

  Future<void> download() async {
    try {
      dynamic content;
      if (isEmbeddedMedia) {
        content = PlatformFile(
          name: basename(message.interactiveMediaPath!),
          path: message.interactiveMediaPath,
          size: 0,
        );
      } else {
        content = AttachmentsSvc.getContent(part.attachments.first);
      }
      if (content is PlatformFile) {
        popDetails();
        await AttachmentsSvc.saveToDisk(content,
            isDocument: part.attachments.first.mimeStart != "image" && part.attachments.first.mimeStart != "video");
      }
    } catch (ex, trace) {
      Logger.error("Error downloading attachment: ${ex.toString()}", error: ex, trace: trace);
      showSnackbar("Save Error", ex.toString());
    }
  }

  void openLink() {
    String? url = part.url;
    MethodChannelSvc.invokeMethod("open-browser", {"link": url ?? part.text});
    popDetails();
  }

  Future<void> openAttachmentWeb() async {
    await launchUrlString("${part.attachments.first.webUrl!}?guid=${SettingsSvc.settings.guidAuthKey}");
    popDetails();
  }

  void copyText() {
    Clipboard.setData(ClipboardData(text: part.fullText));
    popDetails();
    if (!Platform.isAndroid || (FilesystemSvc.androidInfo?.version.sdkInt ?? 0) < 33) {
      showSnackbar("Copied", "Copied to clipboard!");
    }
  }

  void copyAttachment() {
    if (part.attachments.length == 1 && part.attachments.first.mimeStart == "image") {
      Uint8List bytes = File(part.attachments.first.path).readAsBytesSync();
      Pasteboard.writeImage(bytes).then((_) {
        popDetails();
      }).catchError((e) {
        Logger.error("Failed to copy image!", error: e);
        showSnackbar("Copy Error", "Failed to copy image!");
      });
      return;
    }
    Pasteboard.writeFiles(part.attachments.map((element) => element.path).toList()).then((_) {
      popDetails();
    }).catchError((e) {
      Logger.error("Failed to copy attachment(s)!", error: e);
      showSnackbar("Copy Error", "Failed to copy attachment(s)!");
    });
  }

  void copySelection() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Copy Selection", style: context.theme.textTheme.titleLarge),
        content: SelectableText(part.fullText, style: context.theme.extension<BubbleText>()!.bubbleText),
      ),
    );
  }

  Future<void> downloadOriginal() async {
    final RxBool downloadingAttachments = true.obs;
    final RxnDouble progress = RxnDouble();
    final Rxn<Attachment> attachmentObs = Rxn<Attachment>();
    final toDownload = part.attachments.where((element) =>
        (element.uti?.contains("heic") ?? false) ||
        (element.uti?.contains("heif") ?? false) ||
        (element.uti?.contains("quicktime") ?? false) ||
        (element.uti?.contains("coreaudio") ?? false) ||
        (element.uti?.contains("tiff") ?? false));
    final length = toDownload.length;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Downloading attachment${length > 1 ? "s" : ""}...", style: context.theme.textTheme.titleLarge),
        content: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: <Widget>[
          Obx(
            () => Text(
                '${progress.value != null && attachmentObs.value != null ? (progress.value! * attachmentObs.value!.totalBytes!).getFriendlySize() : ""} / ${(attachmentObs.value!.totalBytes!.toDouble()).getFriendlySize()} (${((progress.value ?? 0) * 100).floor()}%)',
                style: context.theme.textTheme.bodyLarge),
          ),
          const SizedBox(height: 10.0),
          Obx(
            () => ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: LinearProgressIndicator(
                backgroundColor: context.theme.colorScheme.outline,
                valueColor: AlwaysStoppedAnimation<Color>(Get.context!.theme.colorScheme.primary),
                value: progress.value,
                minHeight: 5,
              ),
            ),
          ),
          const SizedBox(
            height: 15.0,
          ),
          Obx(() => Text(
                progress.value == 1
                    ? "Download Complete!"
                    : "You can close this dialog. The attachment(s) will continue to download in the background.",
                maxLines: 2,
                textAlign: TextAlign.center,
                style: context.theme.textTheme.bodyLarge,
              )),
        ]),
        actions: [
          Obx(
            () => downloadingAttachments.value
                ? const SizedBox(height: 0, width: 0)
                : TextButton(
                    child: Text("Close",
                        style:
                            context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary)),
                    onPressed: () async {
                      Get.closeAllSnackbars();
                      Navigator.of(context, rootNavigator: true).pop();
                      popDetails();
                    },
                  ),
          ),
        ],
      ),
    );
    try {
      for (Attachment? element in toDownload) {
        attachmentObs.value = element;
        final file = await BackendSvc.downloadAttachment(element!,
            original: true,
            onReceiveProgress: (count, total) =>
                progress.value = kIsWeb ? (count / total) : (count / element.totalBytes!));

        await AttachmentsSvc.saveToDisk(file, isDocument: element.mimeStart != "image" && element.mimeStart != "video");
      }
      progress.value = 1;
      downloadingAttachments.value = false;
    } catch (ex, trace) {
      Logger.error("Failed to download original attachment!", error: ex, trace: trace);
      showSnackbar("Download Error", ex.toString());
    }
  }

  Future<void> downloadLivePhoto() async {
    final RxBool downloadingAttachments = true.obs;
    final RxnInt progress = RxnInt();
    final Rxn<Attachment> attachmentObs = Rxn<Attachment>();
    final toDownload = part.attachments.where((element) => element.hasLivePhoto);
    final length = toDownload.length;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        title: Text("Downloading live photo${length > 1 ? "s" : ""}...", style: context.theme.textTheme.titleLarge),
        content: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: <Widget>[
          Obx(
            () => Text(
              progress.value?.toDouble().getFriendlySize() ?? "",
              style: context.theme.textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 10.0),
          Obx(
            () => ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: LinearProgressIndicator(
                backgroundColor: context.theme.colorScheme.outline,
                valueColor: AlwaysStoppedAnimation<Color>(Get.context!.theme.colorScheme.primary),
                value: downloadingAttachments.value ? null : 1,
                minHeight: 5,
              ),
            ),
          ),
          const SizedBox(
            height: 15.0,
          ),
          Obx(() => Text(
                !downloadingAttachments.value
                    ? "Download Complete!"
                    : "You can close this dialog. The live photo(s) will continue to download in the background.",
                maxLines: 2,
                textAlign: TextAlign.center,
                style: context.theme.textTheme.bodyLarge,
              )),
        ]),
        actions: [
          Obx(
            () => downloadingAttachments.value
                ? const SizedBox(height: 0, width: 0)
                : TextButton(
                    child: Text("Close",
                        style:
                            context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary)),
                    onPressed: () async {
                      Get.closeAllSnackbars();
                      Navigator.of(context, rootNavigator: true).pop();
                      popDetails();
                    },
                  ),
          ),
        ],
      ),
    );
    try {
      for (Attachment? element in toDownload) {
        attachmentObs.value = element;
        final nameSplit = element!.transferName!.split(".");
        await BackendSvc.downloadLivePhoto(
          element,
          "${nameSplit.take(nameSplit.length - 1).join(".")}.mov",
          onReceiveProgress: (count, total) => progress.value = count,
        );
      }
      downloadingAttachments.value = false;
    } catch (ex, trace) {
      Logger.error("Failed to download live photo!", error: ex, trace: trace);
      showSnackbar("Download Error", ex.toString());
    }
  }

  void openDm() {
    popDetails();
    Navigator.pushReplacement(
      context,
      cupertino.CupertinoPageRoute(
        builder: (BuildContext context) {
          return ConversationView(
            chat: dmChat!,
          );
        },
      ),
    );
  }

  void createContact() async {
    popDetails();
    await MethodChannelSvc.invokeMethod("open-contact-form", {
      'address': message.handleRelation.target!.address,
      'address_type': message.handleRelation.target!.address.isEmail ? 'email' : 'phone'
    });
  }

  void showThread() {
    popDetails();
    if (message.threadOriginatorGuid != null) {
      final mwc = service.getMessageStateIfExists(message.threadOriginatorGuid!);
      if (mwc == null) return showSnackbar("Error", "Failed to find thread!");
      showReplyThread(context, mwc.message, mwc.parts[message.normalizedThreadPart], service, cvController);
    } else {
      showReplyThread(context, message, part, service, cvController);
    }
  }

  void newConvo() {
    Handle? handle = message.handleRelation.target;
    if (handle == null) return;
    popDetails();
    NavigationSvc.pushAndRemoveUntil(
      context,
      NewChatCreator(initialSelected: [SelectedContact(displayName: handle.displayName, address: handle.address)]),
      (route) => route.isFirst,
    );
  }

  void forward() async {
    popDetails();
    List<PlatformFile> attachments = [];
    final _attachments = message.dbAttachments
        .where((e) => AttachmentsSvc.getContent(e, autoDownload: false) is PlatformFile)
        .map((e) => AttachmentsSvc.getContent(e, autoDownload: false) as PlatformFile);
    for (PlatformFile a in _attachments) {
      Uint8List? bytes = a.bytes;
      bytes ??= await File(a.path!).readAsBytes();
      attachments.add(PlatformFile(
        name: a.name,
        path: a.path,
        size: bytes.length,
        bytes: bytes,
      ));
    }
    if (attachments.isNotEmpty || !isNullOrEmpty(message.text)) {
      NavigationSvc.pushAndRemoveUntil(
        context,
        NewChatCreator(
          initialText: message.text,
          initialAttachments: attachments,
        ),
        (route) => route.isFirst,
      );
    }
  }

  void redownload() {
    if (isEmbeddedMedia) {
      popDetails();
      service.getMessageStateIfExists(message.guid!)?.embeddedMediaRefreshKey.value++;
    } else {
      final msgGuid = message.guid;
      if (msgGuid != null) {
        for (Attachment? element in part.attachments) {
          if (element != null) {
            unawaited(service.redownloadAttachment(msgGuid, element));
          }
        }
      }
      popDetails();
    }
  }

  void share() {
    if (part.attachments.isNotEmpty && !message.isLegacyUrlPreview && !kIsWeb && !kIsDesktop) {
      Share.files(part.attachments.map((a) => a.path).nonNulls.toList());
    } else if (part.text!.isNotEmpty) {
      Share.text(part.text!);
    }
    popDetails();
  }

  Future<void> remindLater() async {
    if (Platform.isAndroid) {
      bool denied = await Permission.scheduleExactAlarm.isDenied;
      bool permanentlyDenied = await Permission.scheduleExactAlarm.isPermanentlyDenied;
      if (denied && !permanentlyDenied) {
        await Permission.scheduleExactAlarm.request();
      } else if (permanentlyDenied) {
        showSnackbar("Error", "You must enable the manage alarm permission to use this feature");
        return;
      }
    }

    final finalDate = await showTimeframePicker("Select Reminder Time", context,
        presetsAhead: true, additionalTimeframes: {"3 Hours": 3, "6 Hours": 6}, useTodayYesterday: true);
    if (finalDate != null) {
      if (!finalDate.isAfter(DateTime.now().toLocal())) {
        showSnackbar("Error", "Select a date in the future");
        return;
      }
      await NotificationsSvc.createReminder(chat, message, finalDate);
      popDetails();
      showSnackbar("Notice", "Scheduled reminder for ${buildDate(finalDate)}");
    }
  }

  void unsend() async {
    popDetails();
    await MessagesSvc(chat.guid).unsendMessage(message, part);
  }

  void edit() {
    popDetails();
    final FocusNode? node = kIsDesktop || kIsWeb ? FocusNode() : null;
    final controller = MentionTextEditingController(text: "", focusNode: node);
    controller.importMessagePart(part);
    cvController.editing.add(MessageEditEntry(message: message, part: part, controller: controller));
  }

  void delete() {
    service.removeMessage(message);
    Message.softDelete(message.guid!);
    popDetails();
  }

  void selectMultiple() {
    cvController.inSelectMode.toggle();
    if (iOS) {
      cvController.selected.add(message);
    }
    popDetails(returnVal: false);
  }

  void toggleBookmark() {
    // Toggle bookmark through service to update both DB and MessageState
    MessagesSvc(cvController.chat.guid).toggleBookmark(message);
    popDetails();
  }

  void messageInfo() {
    const encoder = JsonEncoder.withIndent("     ");
    Map map = message.toMap();
    if (map["dateCreated"] is int) {
      map["dateCreated"] =
          DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateCreated"]));
    }
    if (map["dateDelivered"] is int) {
      map["dateDelivered"] =
          DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateDelivered"]));
    }
    if (map["dateRead"] is int) {
      map["dateRead"] =
          DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateRead"]));
    }
    if (map["dateEdited"] is int) {
      map["dateEdited"] =
          DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateEdited"]));
    }
    String str = encoder.convert(map);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          "Message Info",
          style: context.theme.textTheme.titleLarge,
        ),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        content: SizedBox(
          width: NavigationSvc.width(widthContext) * 3 / 5,
          height: context.height * 1 / 4,
          child: Container(
            padding: const EdgeInsets.all(10.0),
            decoration: BoxDecoration(
                color: context.theme.colorScheme.surface, borderRadius: const BorderRadius.all(Radius.circular(10))),
            child: SingleChildScrollView(
              child: SelectableText(
                str,
                style: context.theme.textTheme.bodyLarge,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            child: Text("Close",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          ),
        ],
      ),
    );
  }

  Future<void> uploadAttachment() async {
    PushSvc.uploadAttachment(message);
  }

  Future<void> reportIssue() async {
    final TextEditingController participantController = TextEditingController();
    Uint8List? attachment;
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          actions: [
            TextButton(
              child: Text("Cancel",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            ),
            TextButton(
              child: Text("Screenshot",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
              onPressed: () async {
                final res = await picker.FilePicker.platform.pickFiles(
                  withData: true,
                  type: picker.FileType.custom,
                  allowedExtensions: ['png', 'jpg', 'jpeg'],
                );
                if (res == null || res.count == 0) return;
                attachment = await File(res.files[0].path!).readAsBytes();
                showSnackbar("Notice", "Screenshot added");
              },
            ),
            TextButton(
              child: Text("OK",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
              onPressed: () async {
                if (participantController.text.isEmpty) return;

                showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                      title: Text("Uploading log...", style: context.theme.textTheme.titleLarge),
                      content: SizedBox(
                        height: 70,
                        child: Center(
                          child: CircularProgressIndicator(
                            backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                            valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                          ),
                        ),
                      ),
                    );
                  },
                );

                final file = Directory(Platform.isAndroid
                    ? "${FilesystemSvc.appDocDir.path}/../files/logs"
                    : "${FilesystemSvc.appDocDir.path}/logs");
                final entities = await file.list().toList();
                final current = entities.indexWhere((element) => element.path.endsWith("CURRENT.log"));
                final item = entities.removeAt(current);
                final end = await File(item.path).readAsBytes();
                final bytes = BytesBuilder();
                if (entities.isNotEmpty) {
                  final next = await File(entities.first.path).readAsBytes();
                  bytes.add(next);
                }
                bytes.add(end);
                final total = bytes.toBytes();

                final encoder = const JsonEncoder.withIndent("     ");
                final messageMeta = encoder.convert(message.toMap());
                final chatMeta = encoder.convert(chat.toMap());
                final url = dotenv.get('REPORT_ISSUE_WEBHOOK');

                try {
                  final response = await HttpSvc.dio.post(
                    url,
                    data: FormData.fromMap({
                      "content":
                          "Handle: ${(await api.getHandles(state: PushSvc.state!.client)).first} \nDesc: ${participantController.text}",
                      "username": SettingsSvc.settings.userName.value,
                      "files[0]": MultipartFile.fromBytes(total, filename: "rustpush-logs.log"),
                      "files[1]": MultipartFile.fromString(messageMeta, filename: "message.json"),
                      "files[2]": MultipartFile.fromString(chatMeta, filename: "chat.json"),
                      if (attachment != null)
                        "files[3]": MultipartFile.fromBytes(attachment!, filename: "screenshot.png"),
                    }),
                  );

                  if (response.statusCode == 200) {
                    Navigator.of(context, rootNavigator: true).pop();
                    Navigator.of(context, rootNavigator: true).pop();
                    showSnackbar("Notice", "Logs sent! Thank you!");
                  } else {
                    Navigator.of(context, rootNavigator: true).pop();
                    Logger.error(response.toString());
                    showSnackbar("Error", "There was an issue sending logs");
                  }
                } catch (e, s) {
                  Navigator.of(context, rootNavigator: true).pop();
                  Logger.error("failed", error: e, trace: s);
                  showSnackbar("Error", "There was an issue sending logs $e");
                }
              },
            ),
          ],
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                  "Logs will be sent to developer for review. Logs contain personal identifiers and 48 hours of message and chat history. Do not submit logs containing sensitive chats or messages. Your logs will be shared with Discord for storage subject to their Privacy Policy. We may contact you on iMessage for further information."),
              const SizedBox(height: 16),
              TextField(
                controller: participantController,
                decoration: const InputDecoration(
                  labelText: "Description",
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.multiline,
                maxLines: null,
              ),
            ],
          ),
          title: Text("Report issue", style: context.theme.textTheme.titleLarge),
          backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        );
      },
    );
  }

  get _allActions {
    final canEdit = (message.dateCreated?.toUtc().isWithin(DateTime.now().toUtc(), minutes: 15) ?? false) ||
        (message.dateCreated?.toUtc().isAfter(DateTime.now().toUtc()) ?? false);
    final canUnsend = (message.dateCreated?.toUtc().isWithin(DateTime.now().toUtc(), minutes: 2) ?? false);
    return [
      if (SettingsSvc.settings.enablePrivateAPI.value && minBigSur && chat.isIMessage && isSent)
        DetailsMenuActionWidget(
          onTap: reply,
          action: DetailsMenuAction.Reply,
        ),
      if (showDownload)
        DetailsMenuActionWidget(
          onTap: download,
          action: DetailsMenuAction.Save,
        ),
      if ((part.text?.hasUrl ?? false) && !kIsWeb && !kIsDesktop && !LifecycleSvc.isBubble)
        DetailsMenuActionWidget(
          onTap: openLink,
          action: DetailsMenuAction.OpenInBrowser,
        ),
      if (showDownload && kIsWeb && part.attachments.firstOrNull?.webUrl != null)
        DetailsMenuActionWidget(
          onTap: openAttachmentWeb,
          action: DetailsMenuAction.OpenInNewTab,
        ),
      if (!isNullOrEmptyString(part.fullText))
        DetailsMenuActionWidget(
          onTap: copyText,
          action: DetailsMenuAction.CopyText,
        ),
      if (showDownload && kIsDesktop)
        DetailsMenuActionWidget(
          onTap: copyAttachment,
          action: DetailsMenuAction.CopyAttachment,
        ),
      if (showDownload &&
          supportsOriginalDownload &&
          part.attachments
              .where((element) =>
                  (element.uti?.contains("heic") ?? false) ||
                  (element.uti?.contains("heif") ?? false) ||
                  (element.uti?.contains("quicktime") ?? false) ||
                  (element.uti?.contains("coreaudio") ?? false) ||
                  (element.uti?.contains("tiff") ?? false))
              .isNotEmpty)
        DetailsMenuActionWidget(
          onTap: downloadOriginal,
          action: DetailsMenuAction.SaveOriginal,
        ),
      if (showDownload && part.attachments.where((e) => e.hasLivePhoto).isNotEmpty)
        DetailsMenuActionWidget(
          onTap: downloadLivePhoto,
          action: DetailsMenuAction.SaveLivePhoto,
        ),
      if (chat.isGroup && !message.isFromMe! && dmChat != null && !LifecycleSvc.isBubble)
        DetailsMenuActionWidget(
          onTap: openDm,
          action: DetailsMenuAction.OpenDirectMessage,
        ),
      if (message.threadOriginatorGuid != null ||
          service.struct.threads(message.guid!, part.part, returnOriginator: false).isNotEmpty)
        DetailsMenuActionWidget(
          onTap: showThread,
          action: DetailsMenuAction.ViewThread,
        ),
      if ((part.attachments.isNotEmpty && !kIsWeb && !(kIsDesktop && Platform.isLinux)) ||
          (!kIsWeb && !(kIsDesktop && Platform.isLinux) && !isNullOrEmpty(part.text)))
        DetailsMenuActionWidget(
          onTap: share,
          action: DetailsMenuAction.Share,
        ),
      if (showDownload)
        DetailsMenuActionWidget(
          onTap: redownload,
          action: DetailsMenuAction.ReDownloadFromServer,
        ),
      if (!kIsWeb && !kIsDesktop)
        DetailsMenuActionWidget(
          onTap: remindLater,
          action: DetailsMenuAction.RemindLater,
        ),
      if (!kIsWeb && !kIsDesktop)
        DetailsMenuActionWidget(
          onTap: reportIssue,
          action: DetailsMenuAction.ReportIssue,
        ),
      if (message.attachments.isNotEmpty && SettingsSvc.settings.cloudSyncingEnabled.value)
        DetailsMenuActionWidget(
          onTap: uploadAttachment,
          action: DetailsMenuAction.UploadAttachment,
        ),
      if (!kIsWeb &&
          !kIsDesktop &&
          !message.isFromMe! &&
          message.handleRelation.target != null &&
          message.handleRelation.target!.contactsV2.isEmpty)
        DetailsMenuActionWidget(
          onTap: createContact,
          action: DetailsMenuAction.CreateContact,
        ),
      if (BackendSvc.canEditUnsend() &&
          message.isFromMe! &&
          !widget.controller.isSending.value &&
          message.dateScheduled == null)
        DetailsMenuActionWidget(
          onTap: unsend,
          customTitle: canUnsend ? 'Undo Send' : 'Undo Send (too old)',
          shouldDisableBtn: !canUnsend,
          action: DetailsMenuAction.UndoSend,
        ),
      if (BackendSvc.canEditUnsend() &&
          message.isFromMe! &&
          !widget.controller.isSending.value &&
          message.dateScheduled == null &&
          (part.text?.isNotEmpty ?? false))
        DetailsMenuActionWidget(
          onTap: edit,
          customTitle: canEdit ? 'Edit' : 'Edit (too old)',
          shouldDisableBtn: !canEdit,
          action: DetailsMenuAction.Edit,
        ),
      if (!LifecycleSvc.isBubble && !message.isInteractive)
        DetailsMenuActionWidget(
          onTap: forward,
          action: DetailsMenuAction.Forward,
        ),
      if (chat.isGroup && !message.isFromMe! && dmChat == null && !LifecycleSvc.isBubble)
        DetailsMenuActionWidget(
          onTap: newConvo,
          action: DetailsMenuAction.StartConversation,
        ),
      if (!isNullOrEmptyString(part.fullText) && (kIsDesktop || kIsWeb))
        DetailsMenuActionWidget(
          onTap: copySelection,
          action: DetailsMenuAction.CopySelection,
        ),
      DetailsMenuActionWidget(
        onTap: delete,
        action: DetailsMenuAction.Delete,
      ),
      DetailsMenuActionWidget(
        onTap: toggleBookmark,
        action: DetailsMenuAction.Bookmark,
        customTitle: message.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
      ),
      DetailsMenuActionWidget(
        onTap: selectMultiple,
        action: DetailsMenuAction.SelectMultiple,
      ),
      DetailsMenuActionWidget(
        onTap: messageInfo,
        action: DetailsMenuAction.MessageInfo,
      ),
    ].sorted((a, b) => SettingsSvc.settings.detailsMenuActions
        .indexOf(a.action)
        .compareTo(SettingsSvc.settings.detailsMenuActions.indexOf(b.action)));
  }

  Widget buildDetailsMenu(BuildContext context) {
    double maxMenuWidth =
        min(max(NavigationSvc.width(widthContext) * 3 / 5, 200), NavigationSvc.width(widthContext) * 4 / 5);

    List<DetailsMenuActionWidget> allActions = _allActions;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          color: context.theme.colorScheme.surfaceContainerHighest.withAlpha(150),
          width: maxMenuWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: allActions.cast<CustomDetailsMenuActionWidget>().sublist(0, numberToShow - 1)
              ..add(
                CustomDetailsMenuActionWidget(
                  onTap: () async {
                    Widget content = Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: allActions.sublist(numberToShow - 1),
                    );
                    Get.dialog(
                        SettingsSvc.settings.skin.value == Skins.iOS
                            ? CupertinoAlertDialog(
                                backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                                content: content,
                              )
                            : AlertDialog(
                                backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                                content: content,
                              ),
                        navigatorKey: NavigationSvc.key,
                        name: 'Popup Menu');
                  },
                  title: 'More...',
                  iosIcon: cupertino.CupertinoIcons.ellipsis,
                  nonIosIcon: Icons.more_vert,
                ),
              ),
          ),
        ),
      ),
    );
  }

  List<Widget> buildMaterialDetailsMenu(BuildContext context) {
    List<DetailsMenuActionWidget> allActions = _allActions;

    return [
      ...allActions.slice(0, numberToShow - 1).map((action) {
        bool isDisabled = false;
        if (action.action == DetailsMenuAction.Edit) {
          isDisabled = !((message.dateCreated?.toUtc().isWithin(DateTime.now().toUtc(), minutes: 15) ?? false));
        }

        Color color = isDisabled
            ? context.theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
            : context.theme.colorScheme.onSurfaceVariant;
        return Padding(
            padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
            child: IconButton(
              icon: Icon(action.nonIosIcon, color: color),
              onPressed: isDisabled ? null : action.onTap,
              tooltip: action.title,
            ));
      }),
      Padding(
          padding: EdgeInsets.only(top: kIsDesktop ? 20 : 0),
          child: PopupMenuButton<int>(
              color: context.theme.colorScheme.surfaceContainerHighest,
              shape: SettingsSvc.settings.skin.value != Skins.Material
                  ? const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(20.0)),
                    )
                  : null,
              onSelected: (int value) {
                allActions[value + numberToShow - 1].onTap?.call();
              },
              itemBuilder: (context) {
                return allActions.slice(numberToShow - 1).mapIndexed((index, action) {
                  return PopupMenuItem(
                    value: index,
                    child: Text(
                      action.title,
                      style: context.textTheme.bodyLarge!.apply(color: context.theme.colorScheme.onSurfaceVariant),
                    ),
                  );
                }).toList();
              }))
    ];
  }
}

class ReactionDetails extends StatelessWidget {
  const ReactionDetails({
    super.key,
    required this.reactions,
  });

  final List<Message> reactions;

  @override
  Widget build(BuildContext context) {
    return Obx(() => Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              alignment: Alignment.center,
              height: 120,
              color: context.theme.colorScheme.surfaceContainerHighest
                  .withAlpha(SettingsSvc.settings.skin.value == Skins.iOS ? 150 : 255),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10.0),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: ThemeSwitcher.getScrollPhysics(),
                  scrollDirection: Axis.horizontal,
                  findChildIndexCallback: (key) => findChildIndexByKey(reactions, key, (item) => item.guid),
                  separatorBuilder: (context, index) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final message = reactions[index];
                    final handle = message.handleRelation.target;
                    String? reactionName;
                    if (!SettingsSvc.settings.hideNamesForReactions.value) {
                      if (message.isFromMe!) {
                        reactionName = SettingsSvc.settings.userName.value;
                      } else if (handle != null) {
                        reactionName = HandleSvc.getOrCreateHandleState(handle).reactionDisplayName.value;
                      }
                    }
                    return Column(
                      key: ValueKey(message.guid!),
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 25.0, vertical: 10),
                          child: ContactAvatarWidget(
                            handle: handle,
                            borderThickness: 0.1,
                            editable: false,
                            fontSize: 22,
                          ),
                        ),
                        if (reactionName != null && reactionName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Text(
                              reactionName,
                              style: context.theme.textTheme.bodySmall!
                                  .copyWith(color: context.theme.colorScheme.onSurfaceVariant),
                            ),
                          )
                        else
                          const SizedBox(height: 8),
                        Container(
                          height: 28,
                          width: 28,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(100),
                            color: message.isFromMe!
                                ? context.theme.colorScheme.primary
                                : context.theme.colorScheme.surfaceContainerHighest,
                            boxShadow: [
                              BoxShadow(
                                blurRadius: 1.0,
                                color: context.theme.colorScheme.outline,
                              )
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: Center(
                              child: Builder(builder: (context) {
                                if (message.associatedMessageType == ReactionTypes.STICKERBACK) {
                                  final image = cvc(message.chat.target!)
                                      .stickerData[message.guid]?[message.attachments[0]?.guid]
                                      ?.$1;
                                  return image != null
                                      ? Padding(
                                          padding: const EdgeInsets.all(5),
                                          child: Image.memory(
                                            image,
                                            gaplessPlayback: true,
                                            cacheHeight: 200,
                                            filterQuality: FilterQuality.none,
                                          ),
                                        )
                                      : const SizedBox.shrink();
                                }
                                final text = Text(
                                  ReactionTypes.reactionToEmoji[message.associatedMessageType] ??
                                      message.associatedMessageEmoji ??
                                      "X",
                                  style: const TextStyle(fontSize: 18, fontFamily: 'Apple Color Emoji'),
                                  textAlign: TextAlign.center,
                                );
                                if (message.associatedMessageType == "dislike") {
                                  return Transform(
                                    transform: Matrix4.identity()..rotateY(pi),
                                    alignment: FractionalOffset.center,
                                    child: text,
                                  );
                                }
                                return text;
                              }),
                            ),
                          ),
                        )
                      ],
                    );
                  },
                  itemCount: reactions.length,
                ),
              ),
            ),
          ),
        )); // end Obx
  }
}
