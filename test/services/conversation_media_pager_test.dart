import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/media/conversation_media_pager.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment media(
  String guid,
  int messageId,
  int milliseconds, {
  String mimeType = 'image/jpeg',
}) {
  final attachment = Attachment(
    guid: guid,
    mimeType: mimeType,
    transferName: '$guid.dat',
    totalBytes: 1,
  );
  attachment.message.target = Message(
    id: messageId,
    guid: 'message-$messageId',
    dateCreated: DateTime.fromMillisecondsSinceEpoch(milliseconds),
  );
  return attachment;
}

void main() {
  late List<({ChatMediaDirection direction, ChatMediaCursor? cursor})> calls;
  late Map<ChatMediaDirection, List<ChatMediaPage>> responses;
  late ConversationMediaPager pager;

  setUp(() {
    calls = [];
    responses = {
      ChatMediaDirection.older: [],
      ChatMediaDirection.newer: [],
    };
    pager = ConversationMediaPager(
      chat: Chat(id: 1, guid: 'chat'),
      pageSize: 2,
      loader: ({
        required ChatMediaDirection direction,
        ChatMediaCursor? cursor,
        required int limit,
      }) async {
        calls.add((direction: direction, cursor: cursor));
        return responses[direction]!.removeAt(0);
      },
    );
  });

  tearDown(() => pager.dispose());

  test('loads a bounded initial page and exposes its older cursor', () async {
    responses[ChatMediaDirection.older]!.add(
      ChatMediaPage(
        items: [media('new', 20, 2000), media('old', 10, 1000)],
        nextCursor: const ChatMediaCursor(dateMilliseconds: 1000, messageId: 10),
        hasMore: true,
      ),
    );

    await pager.loadInitial();

    expect(pager.items.map((item) => item.guid), ['new', 'old']);
    expect(pager.hasOlder, isTrue);
    expect(pager.hasNewer, isFalse);
    expect(calls.single.cursor, isNull);
  });

  test('appends older media, prepends newer media, and removes duplicates', () async {
    final middle = media('middle', 20, 2000);
    pager.seed([middle], hasNewer: true, hasOlder: true);
    responses[ChatMediaDirection.older]!.add(
      ChatMediaPage(
        items: [middle, media('old', 10, 1000)],
        nextCursor: const ChatMediaCursor(dateMilliseconds: 1000, messageId: 10),
        hasMore: false,
      ),
    );
    responses[ChatMediaDirection.newer]!.add(
      ChatMediaPage(
        items: [media('new', 30, 3000), middle],
        nextCursor: const ChatMediaCursor(dateMilliseconds: 3000, messageId: 30),
        hasMore: false,
      ),
    );

    await pager.loadOlder();
    await pager.loadNewer();

    expect(pager.items.map((item) => item.guid), ['new', 'middle', 'old']);
    expect(calls.first.cursor?.messageId, 20);
    expect(calls.last.cursor?.messageId, 20);
  });

  test('filters non-media and keeps a selected item outside the seed', () {
    final image = media('image', 20, 2000);
    final document = media('document', 15, 1500, mimeType: 'application/pdf');
    final selected = media('selected', 10, 1000);

    pager.seed([image, document], selected: selected);

    expect(pager.items.map((item) => item.guid), ['image', 'selected']);
  });

  test('retains loaded data when a later page fails', () async {
    final image = media('image', 20, 2000);
    pager.dispose();
    pager = ConversationMediaPager(
      chat: Chat(id: 1, guid: 'chat'),
      loader: ({
        required ChatMediaDirection direction,
        ChatMediaCursor? cursor,
        required int limit,
      }) async {
        throw StateError('query failed');
      },
    )..seed([image], hasOlder: true);

    await pager.loadOlder();

    expect(pager.items, [image]);
    expect(pager.lastError, isA<StateError>());
  });

  test('skips bounded text-only scans until older media is found', () async {
    pager.seed([media('new', 30, 3000)], hasOlder: true);
    responses[ChatMediaDirection.older]!.addAll([
      const ChatMediaPage(
        items: <Attachment>[],
        nextCursor: ChatMediaCursor(dateMilliseconds: 2000, messageId: 20),
        hasMore: true,
      ),
      ChatMediaPage(
        items: [media('old', 10, 1000)],
        nextCursor: const ChatMediaCursor(dateMilliseconds: 1000, messageId: 10),
        hasMore: false,
      ),
    ]);

    await pager.loadOlder();

    expect(pager.items.map((item) => item.guid), ['new', 'old']);
    expect(calls, hasLength(2));
    expect(calls.last.cursor?.messageId, 20);
    expect(pager.hasOlder, isFalse);
  });

  test('orders an unsorted seed newest first before deriving cursors', () {
    pager.seed([
      media('old', 10, 1000),
      media('new', 30, 3000),
      media('middle', 20, 2000),
    ]);

    expect(
      pager.items.map((item) => item.guid),
      ['new', 'middle', 'old'],
    );
  });
}
