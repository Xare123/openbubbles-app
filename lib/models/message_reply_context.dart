import 'package:flutter/foundation.dart';
import 'package:bluebubbles/database/models.dart';

@immutable
class MessageReplyContext {
  final Message message;
  final int partIndex;

  const MessageReplyContext(this.message, this.partIndex);
}
