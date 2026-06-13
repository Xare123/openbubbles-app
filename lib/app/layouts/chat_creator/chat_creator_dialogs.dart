import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Response;

class ChatCreatorDialogs {
  static Future<void> showGroupChatCreationDialog(BuildContext context) {
    return showDialog(
      barrierDismissible: false,
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          "Group Chat Creation",
          style: ctx.theme.textTheme.titleLarge,
        ),
        content: Text(
          "Creating group chats from BlueBubbles is not possible on macOS 11 (Big Sur) and later due to limitations from Apple. You must setup the Private API to gain this feature.",
          style: ctx.theme.textTheme.bodyLarge,
        ),
        backgroundColor: ctx.theme.colorScheme.surfaceContainerHighest,
        actions: <Widget>[
          TextButton(
            child: Text("Close", style: ctx.theme.textTheme.bodyLarge!.copyWith(color: ctx.theme.colorScheme.primary)),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }

  static Future<void> showCannotForwardAttachmentDialog(BuildContext context) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.theme.colorScheme.surfaceContainerHighest,
        title: Text(
          "Cannot Forward Attachment",
          style: ctx.theme.textTheme.titleLarge,
        ),
        content: Text(
          "Attachments cannot be forwarded to a new conversation. Please select an existing contact.",
          style: ctx.theme.textTheme.bodyLarge,
        ),
        actions: [
          TextButton(
            child: Text("OK", style: ctx.theme.textTheme.bodyLarge!.copyWith(color: ctx.theme.colorScheme.primary)),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }

  static Widget buildCreatingChatDialog(BuildContext context, String method) {
    return AlertDialog(
      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      title: Text(
        "Creating a new $method chat...",
        style: context.theme.textTheme.titleLarge,
      ),
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
  }

  static Widget buildCreateChatErrorDialog(BuildContext context, Object error) {
    return AlertDialog(
      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      title: Text(
        "Failed to create chat!",
        style: context.theme.textTheme.titleLarge,
      ),
      content: Text(
        error is Response
            ? "Reason: (${error.data["error"]["type"]}) -> ${error.data["error"]["message"]}"
            : error.toString(),
        style: context.theme.textTheme.bodyLarge,
      ),
      actions: [
        TextButton(
          child: Text("OK",
              style: context.theme.textTheme.bodyLarge!.copyWith(color: Get.context!.theme.colorScheme.primary)),
          onPressed: () => Navigator.of(context).pop(),
        )
      ],
    );
  }
}
