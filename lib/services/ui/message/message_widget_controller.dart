import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/message_properties.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/timestamp/delivered_indicator.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

MessageWidgetController mwc(Message message) => Get.isRegistered<MessageWidgetController>(tag: message.guid)
    ? Get.find<MessageWidgetController>(tag: message.guid)
    : Get.put(MessageWidgetController(message), tag: message.guid);

MessageWidgetController? getActiveMwc(String guid) =>
    Get.isRegistered<MessageWidgetController>(tag: guid) ? Get.find<MessageWidgetController>(tag: guid) : null;

/// Returns the stable portion of a message that affects its rendered content.
///
/// CloudKit projection can fill these fields after a message widget has already
/// been mounted. This deliberately excludes delivery/read timestamps and
/// [Message.dateEdited], because those are lifecycle metadata rather than a
/// reliable indication that the rendered content changed.
String messagePresentationSignature(Message message) {
  final attachments = <Attachment?>[
    ...message.dbAttachments,
    ...message.attachments,
  ];
  final attachmentPresentation = attachments
      .map((attachment) => attachment == null
          ? 'null'
          : jsonEncode(_canonicalizePresentationValue(<String, dynamic>{
              'guid': attachment.guid ?? 'id:${attachment.id ?? 'null'}',
              'uti': attachment.uti,
              'mimeType': attachment.mimeType,
              'isOutgoing': attachment.isOutgoing,
              'transferName': attachment.transferName,
              'totalBytes': attachment.totalBytes,
              'height': attachment.height,
              'width': attachment.width,
              'webUrl': attachment.webUrl,
              'hasLivePhoto': attachment.hasLivePhoto,
              'byteLength': attachment.bytes?.length,
            })))
      .toSet()
      .toList()
    ..sort();

  final value = <String, dynamic>{
    'text': message.text,
    'subject': message.subject,
    'attributedBody': message.attributedBody.map((body) => body.toMap()).toList(),
    'messageSummaryInfo': message.messageSummaryInfo.map((summary) => summary.toJson()).toList(),
    'hasAttachments': message.hasAttachments,
    'attachmentPresentation': attachmentPresentation,
  };

  return jsonEncode(_canonicalizePresentationValue(value));
}

dynamic _canonicalizePresentationValue(dynamic value) {
  if (value is Map) {
    final entries = value.entries
        .map((entry) => MapEntry(entry.key.toString(), _canonicalizePresentationValue(entry.value)))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return <String, dynamic>{for (final entry in entries) entry.key: entry.value};
  }
  if (value is Iterable) {
    return value.map(_canonicalizePresentationValue).toList();
  }
  return value;
}

class MessageWidgetController extends StatefulController with GetSingleTickerProviderStateMixin {
  final RxBool showEdits = false.obs;
  final Rxn<DateTime> audioWasKept = Rxn<DateTime>(null);

  List<MessagePart> parts = [];
  Message message;
  String? oldMessageGuid;
  String? newMessageGuid;
  ConversationViewController? cvController;
  late final String tag;
  StreamSubscription? sub;
  bool built = false;

  static const maxBubbleSizeFactor = 0.75;

  MessageWidgetController(this.message) {
    tag = message.guid!;
  }

  Message? get newMessage =>
      newMessageGuid == null ? null : ms(cvController!.chat.guid).struct.getMessage(newMessageGuid!);
  Message? get oldMessage =>
      oldMessageGuid == null ? null : ms(cvController!.chat.guid).struct.getMessage(oldMessageGuid!);

  @override
  void onInit() {
    super.onInit();
    buildMessageParts();
    if (!kIsWeb && message.id != null) {
      print("listening ${message.id}");
      final messageQuery = Database.messages.query(Message_.id.equals(message.id!)).watch();
      sub = messageQuery.listen((Query<Message> query) async {
        if (message.id == null) return;
        final _message = await runAsync(() {
          return Database.messages.get(message.id!);
        });
        if (_message != null) {
          if (_message.hasAttachments) {
            _message.attachments = List<Attachment>.from(_message.dbAttachments);
          }
          _message.associatedMessages = message.associatedMessages;
          _message.handle = _message.getHandle();
          updateMessage(_message);
        }
      });
    } else if (kIsWeb) {
      sub = WebListeners.messageUpdate.listen((tuple) {
        final _message = tuple.item1;
        final tempGuid = tuple.item2;
        if (_message.guid == message.guid || tempGuid == message.guid) {
          updateMessage(_message);
        }
      });
    }
  }

  @override
  void onClose() {
    sub?.cancel();
    super.onClose();
  }

  void close() {
    Get.delete<MessageWidgetController>(tag: tag);
  }

  void buildMessageParts() {
    parts = message.buildMessageParts();
  }



  void updateMessage(Message newItem) {
    final chat = message.chat.target?.guid ?? cvController?.chat.guid ?? cm.activeChat!.chat.guid;
    final oldGuid = message.guid;
    final previousPresentationSignature = messagePresentationSignature(message);
    if (newItem.guid != oldGuid && oldGuid!.contains("temp")) {
      message = Message.merge(newItem, message);
      _refreshPresentationIfNeeded(previousPresentationSignature);
      ms(chat).updateMessage(message, oldGuid: oldGuid);
      updateWidgets<MessageHolder>(null);
      // mark this for the new guid
      Get.put(this, tag: newItem.guid);
      if (message.isFromMe! && message.attachments.isNotEmpty) {
        updateWidgets<AttachmentHolder>(null);
      }
    } else if (newItem.dateDelivered != message.dateDelivered ||
        newItem.dateRead != message.dateRead ||
        newItem.didNotifyRecipient != message.didNotifyRecipient) {
      final dateEditedChanged = newItem.dateEdited != message.dateEdited;
      message = Message.merge(newItem, message);
      final presentationChanged = _refreshPresentationIfNeeded(previousPresentationSignature);
      ms(chat).updateMessage(message);
      // update the latest 2 messages in case their indicators need to go away
      final messages = ms(chat)
          .struct
          .messages
          .where((e) => e.isFromMe! && (e.dateDelivered != null || e.dateRead != null))
          .toList()
        ..sort(Message.sort);
      for (Message m in messages.take(2)) {
        getActiveMwc(m.guid!)?.updateWidgets<DeliveredIndicator>(null);
      }
      if (dateEditedChanged && !presentationChanged) {
        // Preserve the existing edit lifecycle notification even when the
        // payload did not change enough to require rebuilding message parts.
        updateWidgets<MessageHolder>(null);
      }
      updateWidgets<DeliveredIndicator>(null);
    } else if (newItem.dateEdited != message.dateEdited ||
        message.dateScheduled != null ||
        newItem.error != message.error ||
        previousPresentationSignature != messagePresentationSignature(newItem)) {
      message = Message.merge(newItem, message);
      _refreshPresentationIfNeeded(previousPresentationSignature);
      ms(chat).updateMessage(message);
      updateWidgets<MessageHolder>(null);
    }
  }

  bool _refreshPresentationIfNeeded(String previousSignature) {
    if (previousSignature == messagePresentationSignature(message)) return false;
    parts.clear();
    buildMessageParts();
    updateWidgets<MessageHolder>(null);
    return true;
  }

  void updateThreadOriginator(Message newItem) {
    updateWidgets<MessageProperties>(null);
  }

  void updateAssociatedMessage(Message newItem, {bool updateHolder = true}) {
    final index = message.associatedMessages.indexWhere((e) => e.id == newItem.id);
    if (index >= 0) {
      message.associatedMessages[index] = newItem;
    } else {
      message.associatedMessages.add(newItem);
    }
    if (updateHolder) {
      updateWidgets<MessageHolder>(null);
    }
  }

  void removeAssociatedMessage(Message toRemove) {
    message.associatedMessages.removeWhere((e) => e.id == toRemove.id);
    updateWidgets<MessageHolder>(null);
  }
}
