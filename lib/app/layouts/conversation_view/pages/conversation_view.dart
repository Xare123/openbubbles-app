import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/cupertino_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/messages_view_components.dart';
import 'package:bluebubbles/app/layouts/settings/pages/profile/posterkit.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_annotated_region.dart';
import 'package:bluebubbles/app/wrappers/gradient_background_wrapper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/messages_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/effects/screen_effects_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/window_effect.dart';
import 'package:get/get.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.chat,
    this.customService,
    this.initialScrollToGuid,
    this.fromChatCreator = false,
  });

  final Chat chat;
  final MessagesService? customService;
  final String? initialScrollToGuid;
  final bool fromChatCreator;

  @override
  ConversationViewState createState() => ConversationViewState();
}

class ConversationViewState extends State<ConversationView> with ThemeHelpers<ConversationView>, RouteAware {
  late final ConversationViewController controller = cvc(chat, tag: widget.customService?.tag);

  // Cache actions map to avoid rebuilding on every frame
  late final Map<Type, Action<Intent>> _actionsMap;

  Chat get chat => widget.chat;

  @override
  void initState() {
    super.initState();

    Logger.debug("Initializing Conversation View for ${chat.guid}");
    controller.fromChatCreator = widget.fromChatCreator;
    controller.fromSearchResult = widget.initialScrollToGuid != null;
    ChatsSvc.setActiveChatSync(chat);
    ChatsSvc.activeChat!.controller = controller;
    Logger.debug("Conversation View initialized for ${chat.guid}");

    controller.loadReplyToMessageState(); // P224b

    // Build actions map once
    _buildActionsMap();
  }

  void _buildActionsMap() {
    _actionsMap = {
      OpenChatDetailsIntent: OpenChatDetailsAction(context, widget.chat.guid),
    };

    if (SettingsSvc.settings.enablePrivateAPI.value) {
      _actionsMap.addAll({
        ReplyRecentIntent: ReplyRecentAction(widget.chat.guid),
        HeartRecentIntent: HeartRecentAction(widget.chat.guid),
        LikeRecentIntent: LikeRecentAction(widget.chat.guid),
        DislikeRecentIntent: DislikeRecentAction(widget.chat.guid),
        LaughRecentIntent: LaughRecentAction(widget.chat.guid),
        EmphasizeRecentIntent: EmphasizeRecentAction(widget.chat.guid),
        QuestionRecentIntent: QuestionRecentAction(widget.chat.guid),
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // A route was pushed on top of the conversation view (e.g. ConversationDetails).
    controller.showingSubRoute = true;
  }

  @override
  void didPopNext() {
    // The route above was popped — conversation view is visible again.
    controller.showingSubRoute = false;
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    controller.saveReplyToMessageState(); // P8bda
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Cache theme values to avoid repeated lookups
    final theme = context.theme;
    final colorScheme = theme.colorScheme;
    final windowEffect = SettingsSvc.settings.windowEffect.value;
    final avatarScale = SettingsSvc.settings.avatarScale.value;
    final bubbleColor = colorScheme.bubble(context, chat.isIMessage);
    final onBubbleColor = colorScheme.onBubble(context, chat.isIMessage);

    final chatState = ChatsSvc.getOrCreateChatState(chat);
    return ChatStateScope(
      chatState: chatState,
      child: BBAnnotatedRegion(
        child: Obx(() => Theme(
            data: theme.copyWith(
              // in case some components still use legacy theming
              primaryColor: bubbleColor,
              colorScheme: colorScheme.copyWith(
                primary: bubbleColor,
                onPrimary: onBubbleColor,
                outline: controller.backgroundPoster.value != null ? Colors.white : null,
              ),
            ),
            child: PopScope(
              canPop: false,
              onPopInvoked: (didPop) async {
                if (didPop) return;
                if (controller.inSelectMode.value) {
                  controller.inSelectMode.value = false;
                  controller.selected.clear();
                  return;
                }
                if (controller.showAttachmentPicker) {
                  controller.showAttachmentPicker = false;
                  controller.updateWidgets<ConversationTextField>(null);
                  return;
                }
                if (LifecycleSvc.isBubble) {
                  SystemNavigator.pop();
                }
                controller.close();
                if (LifecycleSvc.isBubble) return;
                return Navigator.of(context).pop();
              },
              child: SafeArea(
                top: false,
                bottom: false,
                child: Scaffold(
                  backgroundColor: windowEffect != WindowEffect.disabled ? Colors.transparent : colorScheme.surface,
                  extendBodyBehindAppBar: true,
                  // Disable Scaffold's built-in keyboard resize. The body uses a
                  // fixed-height SizedBox (MediaQuery.sizeOf) that does not rebuild
                  // on keyboard inset frames — letting Scaffold shrink the body
                  // each frame fights that fixed size and forces a full Column
                  // relayout on every animation tick, causing visible stutter.
                  // ConversationTextField pads itself by viewInsets.bottom instead,
                  // so only the text field tracks the keyboard — not the whole tree.
                  resizeToAvoidBottomInset: false,
                  appBar: PreferredSize(
                      preferredSize: Size(
                          double.infinity, // width is ignored by Scaffold; avoid MediaQuery.of subscription
                          (kIsDesktop ? (!iOS ? 25 : 5) : 0) +
                              90 * (iOS ? avatarScale : 0) +
                              (!iOS ? kToolbarHeight : 0) +
                              (controller.suggestedContact.value != null || controller.suggestShare.value ? 68 : 0)),
                      child: iOS
                          ? CupertinoHeader(controller: controller)
                          : MaterialHeader(controller: controller) as PreferredSizeWidget),
                  body: Actions(
                    actions: _actionsMap,
                    child: GradientBackground(
                      controller: controller,
                      child: SizedBox(
                        // sizeOf only rebuilds on screen size changes (rotation), not on
                        // keyboard viewInsets animation frames which change viewInsets.bottom
                        height: MediaQuery.sizeOf(context).height,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            if (controller.backgroundPoster.value != null)
                              ImagePoster(poster: controller.backgroundPoster.value!.poster, images: controller.images),
                            const Positioned.fill(child: ScreenEffectsWidget()),
                            Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Stack(
                                    children: [
                                      MessagesView(
                                        key: Key(chat.guid),
                                        customService: widget.customService,
                                        initialScrollToGuid: widget.initialScrollToGuid,
                                        controller: controller,
                                      ),
                                      ScrollDownButton(controller: controller)
                                    ],
                                  ),
                                ),
                                Stack(children: [
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: GestureDetector(
                                      onPanUpdate: (details) {
                                        if (!mounted) return;
                                        if (SettingsSvc.settings.swipeToCloseKeyboard.value &&
                                            details.delta.dy > 0 &&
                                            controller.keyboardOpen) {
                                          controller.focusNode.unfocus();
                                          controller.subjectFocusNode.unfocus();
                                        } else if (SettingsSvc.settings.swipeToOpenKeyboard.value &&
                                            details.delta.dy < 0 &&
                                            !controller.keyboardOpen) {
                                          controller.focusNode.requestFocus();
                                        }
                                      },
                                      child: ConversationTextField(
                                        parentController: controller,
                                      ),
                                    ),
                                  )
                                ]),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ))),
      ),
    );
  }
}
