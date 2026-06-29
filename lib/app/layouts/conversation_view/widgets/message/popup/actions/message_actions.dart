import 'dart:convert';

import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_details/dialogs/timeframe_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';

Future<void> remindLater(MessagePopupActionContext ctx) async {
  if (Platform.isAndroid) {
    final bool denied = await Permission.scheduleExactAlarm.isDenied;
    final bool permanentlyDenied = await Permission.scheduleExactAlarm.isPermanentlyDenied;
    if (denied && !permanentlyDenied) {
      await Permission.scheduleExactAlarm.request();
    } else if (permanentlyDenied) {
      ctx.showSnack("Error", "You must enable the manage alarm permission to use this feature");
      return;
    }
  }

  final finalDate = await showTimeframePicker(
    "Select Reminder Time",
    ctx.context,
    presetsAhead: true,
    additionalTimeframes: {"3 Hours": 3, "6 Hours": 6},
    useTodayYesterday: true,
  );
  if (finalDate != null) {
    if (!finalDate.isAfter(DateTime.now().toLocal())) {
      ctx.showSnack("Error", "Select a date in the future");
      return;
    }
    await NotificationsSvc.createReminder(ctx.chat, ctx.message, finalDate);
    ctx.popDetails();
    ctx.showSnack("Notice", "Scheduled reminder for ${buildDate(finalDate)}");
  }
}

Future<void> createContact(MessagePopupActionContext ctx) async {
  ctx.popDetails();
  await MethodChannelSvc.actions.openContactForm(
    address: ctx.message.handleRelation.target!.address,
    isEmail: ctx.message.handleRelation.target!.address.isEmail,
  );
}

Future<void> unsend(MessagePopupActionContext ctx) async {
  ctx.popDetails();
  await MessagesSvc(ctx.chat.guid).unsendMessage(ctx.message, ctx.part);
}

void edit(MessagePopupActionContext ctx) {
  ctx.popDetails();
  final FocusNode? node = kIsDesktop || kIsWeb ? FocusNode() : null;
  ctx.cvController.editing.add(
    MessageEditEntry(
      message: ctx.message,
      part: ctx.part,
      controller: MentionTextEditingController(
        text: ctx.part.text!,
        focusNode: node,
      )..annotations = List<Annotation>.from(ctx.part.annotations),
    ),
  );
}

void delete(MessagePopupActionContext ctx) {
  ctx.service.removeMessage(ctx.message);
  Message.delete(ctx.message.guid!);
  ctx.popDetails();
}

void selectMultiple(MessagePopupActionContext ctx) {
  ctx.cvController.inSelectMode.toggle();
  if (SettingsSvc.settings.skin.value == Skins.iOS) {
    ctx.cvController.selected.add(ctx.message);
  }
  ctx.popDetails(returnVal: false);
}

void toggleBookmark(MessagePopupActionContext ctx) {
  MessagesSvc(ctx.cvController.chat.guid).toggleBookmark(ctx.message);
  ctx.popDetails();
}

void messageInfo(MessagePopupActionContext ctx) {
  const encoder = JsonEncoder.withIndent("     ");
  final Map map = ctx.message.toMap();
  if (map["dateCreated"] is int) {
    map["dateCreated"] =
        DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateCreated"]));
  }
  if (map["dateDelivered"] is int) {
    map["dateDelivered"] =
        DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateDelivered"]));
  }
  if (map["dateRead"] is int) {
    map["dateRead"] = DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateRead"]));
  }
  if (map["dateEdited"] is int) {
    map["dateEdited"] =
        DateFormat("MMMM d, yyyy h:mm:ss a").format(DateTime.fromMillisecondsSinceEpoch(map["dateEdited"]));
  }
  map["chat"] = ctx.chat.toMap();
  final String str = encoder.convert(map);
  showDialog(
    context: ctx.context,
    builder: (context) => AlertDialog(
      title: Text("Message Info", style: context.theme.textTheme.titleLarge),
      backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      content: SizedBox(
        width: NavigationSvc.width(ctx.widthContext) * 3 / 5,
        height: context.height * 1 / 4,
        child: Container(
          padding: const EdgeInsets.all(10.0),
          decoration: BoxDecoration(
            color: context.theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(10)),
          ),
          child: SingleChildScrollView(
            child: SelectableText(str, style: context.theme.textTheme.bodyLarge),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            "Close",
            style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary),
          ),
        ),
      ],
    ),
  );
}
