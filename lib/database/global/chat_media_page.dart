import 'package:bluebubbles/database/io/attachment.dart'
    if (dart.library.html) 'package:bluebubbles/database/html/attachment.dart';

enum ChatMediaDirection {
  older,
  newer,
}

class ChatMediaCursor {
  const ChatMediaCursor({
    required this.dateMilliseconds,
    required this.messageId,
  });

  final int dateMilliseconds;
  final int messageId;

  List<int> toParameters() => [dateMilliseconds, messageId];
}

class ChatMediaPage {
  const ChatMediaPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<Attachment> items;
  final ChatMediaCursor? nextCursor;
  final bool hasMore;

  static const empty = ChatMediaPage(
    items: <Attachment>[],
    nextCursor: null,
    hasMore: false,
  );
}

class ChatAttachmentOverview {
  const ChatAttachmentOverview({
    required this.documents,
    required this.locations,
  });

  final List<Attachment> documents;
  final List<Attachment> locations;

  static const empty = ChatAttachmentOverview(
    documents: <Attachment>[],
    locations: <Attachment>[],
  );
}
