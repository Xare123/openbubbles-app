import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class DeliveredIndicator extends StatefulWidget {
  const DeliveredIndicator({
    super.key,
    required this.forceShow,
  });

  final bool forceShow;

  @override
  State<StatefulWidget> createState() => _DeliveredIndicatorState();
}

class _DeliveredIndicatorState extends State<DeliveredIndicator> with ThemeHelpers {
  late MessageState controller;
  late final bool _isGroup;
  Message get message => controller.message;
  bool get showAvatar => _isGroup;

  @override
  void initState() {
    super.initState();
    controller = MessageStateScope.readStateOnce(context);
    final fallbackChat = ChatStateScope.maybeReadChatOnce(context);
    _isGroup = controller.cvController?.chat.isGroup ?? fallbackChat?.isGroup ?? false;
  }

  bool get shouldShow {
    if (controller.audioWasKept.value != null) return true;
    final isTempMessage = controller.isSending.value;
    if (widget.forceShow || isTempMessage) return true;
    if ((!message.isFromMe! && iOS) || (controller.parts.lastOrNull?.isUnsent ?? false)) return false;

    // Visibility for "last delivered/read/sent" is computed by
    // MessagesService._recomputeDeliveredIndicators and stored reactively on
    // the MessageState — each tier is independent.
    return controller.showReadIndicator.value || controller.showDeliveredIndicator.value;
  }

  List<InlineSpan> buildTwoPiece(String action, String? date) {
    return [
      TextSpan(
        text: "$action ",
        style: context.theme.textTheme.labelSmall!
            .copyWith(fontWeight: FontWeight.w600, color: context.theme.colorScheme.outline),
      ),
      if (date != null)
        TextSpan(
            text: date,
            style: context.theme.textTheme.labelSmall!
                .copyWith(color: context.theme.colorScheme.outline, fontWeight: FontWeight.normal))
    ];
  }

  List<InlineSpan> getText() {
    // Use reactive MessageState fields for Obx subscription
    final dateRead = controller.dateRead.value ?? message.dateRead;
    final dateDelivered = controller.dateDelivered.value ?? message.dateDelivered;
    final wasDeliveredQuietly = controller.wasDeliveredQuietly.value;
    final didNotifyRecipient = controller.didNotifyRecipient.value;

    if (controller.audioWasKept.value != null) {
      return buildTwoPiece("Kept", buildDate(controller.audioWasKept.value!));
    } else if (!(message.isFromMe ?? false)) {
      return buildTwoPiece("Received", buildDate(message.dateCreated));
    } else if (dateRead != null) {
      return buildTwoPiece("Read", buildDate(dateRead));
    } else if (dateDelivered != null) {
      return buildTwoPiece(
          "Delivered${wasDeliveredQuietly && !didNotifyRecipient ? " Quietly" : ""}",
          SettingsSvc.settings.showDeliveryTimestamps.value || !iOS || widget.forceShow
              ? buildDate(dateDelivered)
              : null);
    } else if (message.isDelivered) {
      return buildTwoPiece("Delivered", null);
    } else if (controller.isSending.value && !(controller.cvController?.chat.isGroup ?? _isGroup) && !iOS) {
      return buildTwoPiece("Sending...", "");
    } else if (widget.forceShow) {
      if (message.dateScheduled != null) {
        return buildTwoPiece("Scheduled", buildDate(message.dateScheduled));
      }
      return buildTwoPiece("Sent", buildDate(message.dateCreated));
    }

    return [];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      curve: Curves.easeInOut,
      alignment: Alignment.bottomCenter,
      duration: const Duration(milliseconds: 250),
      child: Obx(() {
        // Observe the fields that affect both shouldShow and getText.
        controller.showReadIndicator.value;
        controller.showDeliveredIndicator.value;
        controller.audioWasKept.value;
        controller.isSending.value;
        controller.dateDelivered.value;
        controller.dateRead.value;
        return shouldShow && getText().isNotEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15).add(
                    EdgeInsets.only(top: 3, left: showAvatar || SettingsSvc.settings.alwaysShowAvatars.value ? 35 : 0)),
                child: Text.rich(TextSpan(
                  children: getText(),
                )),
              )
            : const SizedBox.shrink();
      }),
    );
  }
}
