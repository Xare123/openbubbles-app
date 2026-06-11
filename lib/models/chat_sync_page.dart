import 'package:flutter/foundation.dart';
import 'package:bluebubbles/database/models.dart';

@immutable
class ChatSyncPage {
  final double progress;
  final List<Chat> chats;
  final int filteredCount;

  const ChatSyncPage(this.progress, this.chats, [this.filteredCount = 0]);
}

@immutable
class MessageSyncPage {
  final double progress;
  final List<Message> messages;

  const MessageSyncPage(this.progress, this.messages);
}
