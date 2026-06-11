import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/interactive/interactive_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reply/reply_thread_popup.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class ReplyBubble extends StatefulWidget {
  const ReplyBubble({
    super.key,
    required this.part,
    required this.showAvatar,
    required this.cvController,
  });

  final int part;
  final bool showAvatar;
  final ConversationViewController cvController;

  @override
  State<StatefulWidget> createState() => _ReplyBubbleState();
}

class _ReplyBubbleState extends State<ReplyBubble> with ThemeHelpers {
  late MessageState _ms;
  MessageState get controller => _ms;

  MessagePart get part => controller.parts[widget.part];
  Message get message => controller.message;

  @override
  void initState() {
    super.initState();
    _ms = MessageStateScope.readStateOnce(context);
  }

  Color getBubbleColor() {
    Color bubbleColor = (context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor ??
        context.theme.colorScheme.surfaceContainerHighest;
    if (SettingsSvc.settings.colorfulBubbles.value && !message.isFromMe!) {
      final colorStr = controller.sender?.color.value;
      final address = controller.sender?.handle.address;
      if (colorStr == null) {
        bubbleColor = toColorGradient(address).first;
      } else {
        bubbleColor = HexColor(colorStr);
      }
    }
    return bubbleColor;
  }

  @override
  Widget build(BuildContext context) {
    final chatGuid = controller.cvController?.chat.guid ?? ChatStateScope.chatOf(context).guid;
    if (!iOS) {
      // Use MessageState if available for reactive text content
      final messageText = controller.text.value;
      String text = Message(text: messageText, subject: controller.subject.value).getNotificationText();
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor - 30,
            minHeight: 30,
          ),
          child: GestureDetector(
            onTap: () {
              showReplyThread(context, message, part, MessagesSvc(chatGuid), widget.cvController);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: controller.senderDisplayName,
                    style: context.textTheme.bodyMedium!
                        .copyWith(fontWeight: FontWeight.w400, color: context.theme.colorScheme.outline),
                  ),
                  const TextSpan(text: "\n"),
                  TextSpan(
                    text: text,
                    style: context.textTheme.bodyMedium!.apply(fontSizeFactor: 1.15),
                  ),
                ]),
                style: context.textTheme.labelLarge!.copyWith(color: context.theme.colorScheme.onSurface),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
    }

    return Opacity(
        opacity: 0.6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 5.0),
          child: SizeTransition(
            sizeFactor: const AlwaysStoppedAnimation<double>(0.8),
            axisAlignment: 0,
            child: Align(
              alignment: message.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
              child: Transform.scale(
                scale: 0.8,
                alignment: message.isFromMe! ? Alignment.centerRight : Alignment.centerLeft,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      showReplyThread(context, message, part, MessagesSvc(chatGuid), widget.cvController);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: IgnorePointer(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (widget.showAvatar)
                            ContactAvatarWidget(
                              handle: message.handleRelation.target,
                              size: 30,
                              fontSize: context.theme.textTheme.bodyLarge!.fontSize!,
                              borderThickness: 0.1,
                            ),
                          ClipPath(
                            clipper: TailClipper(
                              isFromMe: message.isFromMe!,
                              showTail: true,
                              connectUpper: false,
                              connectLower: false,
                            ),
                            child: controller.parts.length <= widget.part
                                ? Container(
                                    constraints: BoxConstraints(
                                      maxWidth: NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor - 30,
                                      minHeight: 30,
                                    ),
                                    child: CustomPaint(
                                      painter: TailPainter(
                                        isFromMe: message.isFromMe!,
                                        showTail: true,
                                        color: context.theme.colorScheme.errorContainer,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15).add(
                                            EdgeInsets.only(
                                                left: message.isFromMe! ? 0 : 10, right: message.isFromMe! ? 10 : 0)),
                                        child: Text(
                                          "Failed to parse thread parts!",
                                          style: (context.theme.extensions[BubbleText] as BubbleText).bubbleText.apply(
                                                color: context.theme.colorScheme.onErrorContainer,
                                              ),
                                        ),
                                      ),
                                    ),
                                  )
                                : message.hasApplePayloadData || message.isLegacyUrlPreview || message.isInteractive
                                    ? ConstrainedBox(
                                        constraints: const BoxConstraints(maxHeight: 100),
                                        child: ReplyScope(
                                          child: InteractiveHolder(
                                            message: part,
                                          ),
                                        ),
                                      )
                                    : part.attachments.isEmpty
                                        ? Container(
                                            constraints: BoxConstraints(
                                              maxWidth:
                                                  NavigationSvc.width(context) * MessageState.maxBubbleSizeFactor - 30,
                                              minHeight: 30,
                                            ),
                                            child: CustomPaint(
                                              painter: TailPainter(
                                                isFromMe: message.isFromMe!,
                                                showTail: true,
                                                color: message.isFromMe!
                                                    ? context.theme.colorScheme.primary
                                                    : getBubbleColor(),
                                              ),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15).add(
                                                    EdgeInsets.only(
                                                        left: message.isFromMe! ? 0 : 10,
                                                        right: message.isFromMe! ? 10 : 0)),
                                                child: FutureBuilder<List<InlineSpan>>(
                                                    future: buildEnrichedMessageSpans(
                                                      context,
                                                      part,
                                                      message,
                                                      colorOverride: (message.isFromMe!
                                                              ? context.theme.colorScheme.primary
                                                              : getBubbleColor())
                                                          .themeLightenOrDarken(context, 30),
                                                    ),
                                                    initialData: buildMessageSpans(
                                                      context,
                                                      part,
                                                      message,
                                                      colorOverride: (message.isFromMe!
                                                              ? context.theme.colorScheme.primary
                                                              : getBubbleColor())
                                                          .themeLightenOrDarken(context, 30),
                                                    ),
                                                    builder: (context, snapshot) {
                                                      if (snapshot.data != null) {
                                                        return RichText(
                                                          text: TextSpan(
                                                            children: snapshot.data!,
                                                          ),
                                                        );
                                                      }
                                                      return const SizedBox.shrink();
                                                    }),
                                              ),
                                            ),
                                          )
                                        : ConstrainedBox(
                                            constraints: const BoxConstraints(maxHeight: 100),
                                            child: ReplyScope(
                                              child: AttachmentHolder(
                                                message: part,
                                              ),
                                            ),
                                          ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
  }
}

class ReplyScope extends InheritedWidget {
  const ReplyScope({
    super.key,
    required super.child,
  });

  static ReplyScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ReplyScope>();
  }

  static ReplyScope of(BuildContext context) {
    final ReplyScope? result = maybeOf(context);
    assert(result != null, 'No ReplyScope found in context');
    return result!;
  }

  @override
  bool updateShouldNotify(ReplyScope oldWidget) => true;
}
