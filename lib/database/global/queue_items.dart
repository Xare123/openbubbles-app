import 'dart:async';

import 'package:bluebubbles/database/models.dart';

enum QueueType { newMessage, updatedMessage, sendMessage, sendReaction, sendAttachment, sendMultipart }

abstract class QueueItem {
  QueueType type;
  Completer<void>? completer;

  QueueItem({required this.type, this.completer});
}

class IncomingItem extends QueueItem {
  Chat chat;
  Message message;
  String? tempGuid;

  IncomingItem({
    required super.type,
    super.completer,
    required this.chat,
    required this.message,
    this.tempGuid,
  });

  factory IncomingItem.fromMap(QueueType t, Map<String, dynamic> m, [Completer<void>? c]) {
    return IncomingItem(
      type: t,
      completer: c,
      chat: Chat.fromMap(m['chats'].first.cast<String, Object>()),
      message: Message.fromMap(m),
      tempGuid: m['tempGuid'],
    );
  }
}

class OutgoingItem extends QueueItem {
  Chat chat;
  Message message;
  Message? selected;
  String? reaction;
  Map<String, dynamic>? customArgs;

  OutgoingItem({
    required super.type,
    super.completer,
    required this.chat,
    required this.message,
    this.selected,
    this.reaction,
    this.customArgs,
  });
}

abstract class OutgoingQueueItem extends QueueItem {
  Chat chat;
  Message message;

  OutgoingQueueItem({
    required super.type,
    super.completer,
    required this.chat,
    required this.message,
  });
}

class OutgoingMessage extends OutgoingQueueItem {
  bool isRetry;
  bool clearNotificationsIfFromMe;

  OutgoingMessage({
    super.completer,
    required super.chat,
    required super.message,
    this.isRetry = false,
    this.clearNotificationsIfFromMe = true,
  }) : super(type: QueueType.sendMessage);
}

class OutgoingReaction extends OutgoingQueueItem {
  Message selectedMessage;
  String reaction;
  bool isRetry;
  bool clearNotificationsIfFromMe;

  OutgoingReaction({
    super.completer,
    required super.chat,
    required super.message,
    required this.selectedMessage,
    required this.reaction,
    this.isRetry = false,
    this.clearNotificationsIfFromMe = true,
  }) : super(type: QueueType.sendReaction);
}

class OutgoingAttachment extends OutgoingQueueItem {
  Attachment attachment;
  bool isAudioMessage;
  bool isRetry;

  OutgoingAttachment({
    super.completer,
    required super.chat,
    required super.message,
    required this.attachment,
    this.isAudioMessage = false,
    this.isRetry = false,
  }) : super(type: QueueType.sendAttachment);
}

class OutgoingMultipartMessage extends OutgoingQueueItem {
  bool isRetry;
  bool clearNotificationsIfFromMe;

  OutgoingMultipartMessage({
    super.completer,
    required super.chat,
    required super.message,
    this.isRetry = false,
    this.clearNotificationsIfFromMe = true,
  }) : super(type: QueueType.sendMultipart);
}
