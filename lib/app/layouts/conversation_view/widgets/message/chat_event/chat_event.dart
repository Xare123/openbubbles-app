import 'dart:convert';

import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

class ChatEvent extends StatelessWidget {
  const ChatEvent({
    super.key,
    required this.part,
  });

  final MessagePart part;

  @override
  Widget build(BuildContext context) {
    final message = MessageStateScope.messageOf(context);
    final state = MessageStateScope.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
        child: GestureDetector(
          onLongPress: () {
            const encoder = JsonEncoder.withIndent("     ");
            Map map = message.toMap();
            if (map["dateCreated"] is int) {
              map["dateCreated"] =
                  DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateCreated"]));
            }
            if (map["dateDelivered"] is int) {
              map["dateDelivered"] = DateFormat("MMMM d, yyyy h:mm:ss a")
                  .format(DateTime.fromMillisecondsSinceEpoch(map["dateDelivered"]));
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
                  width: NavigationSvc.width(context) * 3 / 5,
                  height: context.height * 1 / 4,
                  child: Container(
                    padding: const EdgeInsets.all(10.0),
                    decoration: BoxDecoration(
                        color: context.theme.colorScheme.surface,
                        borderRadius: const BorderRadius.all(Radius.circular(10))),
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
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            );
          },
          child: Obx(() {
            final senderName = state.senderDisplayName;
            final text = part.isUnsent
                ? (message.isFromMe!
                    ? "You unsent a message. Others may still see the message on devices where the software hasn't been updated"
                    : "$senderName unsent a message")
                : message.buildGroupEventText(senderName);
            return Text(
              text,
              style: context.theme.textTheme.bodySmall!.copyWith(color: context.theme.colorScheme.outline),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              textAlign: TextAlign.center,
            );
          }),
        ),
      ),
    );
  }
}
