import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/cupertino_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/messages_view_components.dart';
import 'package:bluebubbles/app/layouts/settings/pages/profile/posterkit.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
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

  // Cached stable widget subtrees. ConversationView.build() runs on every keyboard
  // animation frame because Scaffold/SafeArea subscribe to MediaQuery. Flutter
  // checks widget identity (child.widget == newWidget) before calling update() on
  // a child element — passing the same object instance skips the State rebuild
  // entirely, so MessagesView, GradientBackground, ConversationTextField, and the
  // header widgets will not rebuild on keyboard frames.
  late final Widget _bodyContent;
  // The header child (CupertinoHeader/MaterialHeader) is cached here so it keeps a
  // stable identity across rebuilds; the PreferredSize wrapper is rebuilt reactively
  // in build() because its height depends on the suggested-contact/share banner.
  late final Widget _header;

  Chat get chat => widget.chat;

  void _onPanUpdate(DragUpdateDetails details) {
    if (!mounted) return;
    if (SettingsSvc.settings.swipeToCloseKeyboard.value && details.delta.dy > 0 && controller.keyboardOpen) {
      controller.focusNode.unfocus();
      controller.subjectFocusNode.unfocus();
    } else if (SettingsSvc.settings.swipeToOpenKeyboard.value && details.delta.dy < 0 && !controller.keyboardOpen) {
      controller.focusNode.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    controller.fromChatCreator = widget.fromChatCreator;
    controller.fromSearchResult = widget.initialScrollToGuid != null;
    ChatsSvc.setActiveChatSync(chat);
    ChatsSvc.activeChat?.controller = controller;
    Logger.debug("Conversation View initialized for ${chat.guid}");

    controller.loadReplyToMessageState(); // P224b

    // Build actions map once
    _buildActionsMap();

    // Cache the stable header and body subtrees. See field comments above.
    _header = iOS ? CupertinoHeader(controller: controller) : MaterialHeader(controller: controller);
    _bodyContent = _buildBodyContent();
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: Size(
        double.infinity, // width is ignored by Scaffold
        (kIsDesktop ? (!iOS ? 25 : 5) : 0) +
            90 * (iOS ? SettingsSvc.settings.avatarScale.value : 0) +
            (!iOS ? kToolbarHeight : 0) +
            (controller.suggestedContact.value != null || controller.suggestShare.value ? 68 : 0),
      ),
      child: _header,
    );
  }

  Widget _buildBodyContent() {
    return GradientBackground(
      controller: controller,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Obx(() => controller.backgroundPoster.value != null
              ? ImagePoster(poster: controller.backgroundPoster.value!.poster, images: controller.images)
              : const SizedBox.shrink()),
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
                    ScrollDownButton(controller: controller),
                  ],
                ),
              ),
              GestureDetector(
                onPanUpdate: _onPanUpdate,
                child: ConversationTextField(
                  parentController: controller,
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
    final bubbleColor = colorScheme.bubble(context, chat.isIMessage);
    final onBubbleColor = colorScheme.onBubble(context, chat.isIMessage);

    final chatState = ChatsSvc.getOrCreateChatState(chat);
    return ChatStateScope(
      chatState: chatState,
      child: Obx(() => Theme(
          data: theme.copyWith(
            // Override primary color with our custom bubble color.
            primaryColor: bubbleColor,
            colorScheme: colorScheme.copyWith(
              primary: bubbleColor,
              onPrimary: onBubbleColor,
              outline: controller.backgroundPoster.value != null ? Colors.white : null,
            ),
          ),
          child: PopScope(
            canPop: false,
            onPopInvokedWithResult: <T>(bool didPop, T? result) async {
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
            child: BBScaffold(
              backgroundColor: windowEffect != WindowEffect.disabled ? Colors.transparent : colorScheme.surface,
              extendBodyBehindAppBar: true,
              appBar: _buildAppBar(),
              body: Actions(
                actions: _actionsMap,
                child: _bodyContent,
              ),
            ),
          ))),
    );
  }
}
