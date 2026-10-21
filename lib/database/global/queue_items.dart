import 'dart:async';

import 'package:bluebubbles/database/models.dart';

enum QueueType {newMessage, updatedMessage, sendMessage, sendAttachment, sendMultipart}

/// Optional live-receive persistence seam. Historical/fromMap queue entries do
/// not carry it. The callback receives the final resolved Chat and Message.
typedef IncomingMessagePersistence = Future<Message> Function(
    Chat chat, Message message, Message Function() persistMessage);

abstract class QueueItem {
  QueueType type;
  Completer<void>? completer;

  QueueItem({required this.type, this.completer});
}

class IncomingItem extends QueueItem {
  Chat chat;
  Message message;
  String? tempGuid;

  IncomingMessagePersistence? persistReceivedMessage;

  IncomingItem({
    required super.type,
    super.completer,
    required this.chat,
    required this.message,
    this.tempGuid,
    this.persistReceivedMessage,
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

/// Live native mutation work retained before reflection. It uses the existing
/// incoming queue, but cannot masquerade as a newly created Message row.
class IncomingReceivedMutationItem extends QueueItem {
  IncomingReceivedMutationItem({required this.process, super.completer})
      : super(type: QueueType.updatedMessage);
  final Future<void> Function() process;
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
