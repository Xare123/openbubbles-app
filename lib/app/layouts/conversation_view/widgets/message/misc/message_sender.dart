import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MessageSender extends StatelessWidget {
  const MessageSender({super.key, required this.olderMessage});

  final Message? olderMessage;

  @override
  Widget build(BuildContext context) {
    final state = MessageStateScope.maybeOf(context);
    if (state == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25).add(const EdgeInsets.only(bottom: 3)),
      // Obx makes the sender name reactive: updates when contact data syncs.
      child: Obx(() => Text(
            state.sender?.displayName.value ?? state.message.handleRelation.target?.displayName ?? "",
            style: context.theme.textTheme.labelMedium!
                .copyWith(color: context.theme.colorScheme.outline, fontWeight: FontWeight.normal),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )),
    );
  }
}
