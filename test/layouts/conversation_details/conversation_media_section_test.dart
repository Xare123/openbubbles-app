import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_details/widgets/conversation_media_section.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/media/conversation_media_pager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment photo(int id) {
  return Attachment(
      guid: 'photo-$id',
      mimeType: 'image/jpeg',
      transferName: '$id.jpg',
    )
    ..message.target = Message(
      id: id,
      guid: 'message-$id',
      dateCreated: DateTime.fromMillisecondsSinceEpoch(id * 1000),
    );
}

Widget tile(BuildContext context, Attachment attachment) =>
    Center(child: Text(attachment.guid!));

void main() {
  testWidgets(
    'full gallery builds only nearby tiles, even with a long history',
    (tester) async {
      var requests = 0;
      final built = <String>{};
      final pager =
          ConversationMediaPager(
            chat: Chat(id: 1, guid: 'chat'),
            loader: ({required direction, cursor, required limit}) async {
              requests++;
              return ChatMediaPage.empty;
            },
          )..seed(
            List.generate(500, (index) => photo(500 - index)),
            hasNewer: false,
          );
      addTearDown(pager.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationMediaGallery(
            pager: pager,
            itemBuilder: (context, attachment) {
              built.add(attachment.guid!);
              return tile(context, attachment);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(built, isNotEmpty);
      expect(built.length, lessThan(25));
      expect(requests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview stays at six newest items and documents stay reachable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var seeAll = 0;
      final items = List.generate(500, (index) => photo(500 - index));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                ConversationMediaPreview(
                  items: items,
                  hasOlder: true,
                  onSeeAll: () => seeAll++,
                  itemBuilder: tile,
                ),
                const SliverToBoxAdapter(child: Text('Documents & files')),
              ],
            ),
          ),
        ),
      );

      for (var id = 495; id <= 500; id++) {
        expect(find.text('photo-$id'), findsOneWidget);
      }
      expect(find.text('photo-494'), findsNothing);
      expect(
        tester.getBottomLeft(find.text('Documents & files')).dy,
        lessThan(900),
      );
      await tester.tap(find.text('See all'));
      expect(seeAll, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short complete gallery needs no see-all button; older pages do',
    (tester) async {
      Future<void> show(bool hasOlder) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                ConversationMediaPreview(
                  items: [photo(1)],
                  hasOlder: hasOlder,
                  onSeeAll: () {},
                  itemBuilder: tile,
                ),
              ],
            ),
          ),
        ),
      );
      await show(false);
      expect(find.text('See all'), findsNothing);
      await show(true);
      expect(find.text('See all'), findsOneWidget);
    },
  );

  testWidgets('empty preview leaves the document section visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ConversationMediaPreview(
                items: const [],
                hasOlder: false,
                onSeeAll: () {},
                itemBuilder: tile,
              ),
              const SliverToBoxAdapter(child: Text('Documents & files')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('IMAGES & VIDEOS'), findsNothing);
    expect(find.text('Documents & files'), findsOneWidget);
  });

  testWidgets(
    'see all opens the full paged gallery, back restores compact preview',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var requests = 0;
      final pager = ConversationMediaPager(
        chat: Chat(id: 1, guid: 'chat'),
        loader: ({required direction, cursor, required limit}) async {
          requests++;
          return ChatMediaPage(
            items: [photo(1)],
            nextCursor: null,
            hasMore: false,
          );
        },
      )..seed(List.generate(8, (index) => photo(9 - index)), hasNewer: false);
      addTearDown(pager.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: AnimatedBuilder(
                  animation: pager,
                  builder: (context, _) => CustomScrollView(
                    slivers: [
                      ConversationMediaPreview(
                        items: pager.items,
                        hasOlder: pager.hasOlder,
                        itemBuilder: tile,
                        onSeeAll: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ConversationMediaGallery(
                              pager: pager,
                              itemBuilder: tile,
                            ),
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(
                        child: Text('Documents & files'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        requests,
        0,
        reason: 'The compact profile must not fetch older photos',
      );
      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationMediaGallery), findsOneWidget);
      expect(requests, 1);
      expect(pager.items.length, 9);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ConversationMediaGallery), findsNothing);
      expect(find.text('photo-3'), findsNothing);
      expect(find.text('Documents & files'), findsOneWidget);
      expect(requests, 1);
    },
  );

  testWidgets(
    'full gallery coalesces edge requests and offers explicit retry on failure',
    (tester) async {
      var requests = 0;
      final response = Completer<ChatMediaPage>();
      final pager = ConversationMediaPager(
        chat: Chat(id: 1, guid: 'chat'),
        loader: ({required direction, cursor, required limit}) {
          requests++;
          if (requests == 1) return response.future;
          return Future.value(
            ChatMediaPage(items: [photo(1)], nextCursor: null, hasMore: false),
          );
        },
      )..seed([photo(4), photo(3), photo(2)], hasNewer: false);
      addTearDown(pager.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationMediaGallery(pager: pager, itemBuilder: tile),
        ),
      );
      await tester.pump();
      expect(requests, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      response.completeError(StateError('synthetic page failure'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(
        requests,
        1,
        reason: 'A failed page must not become an automatic retry loop',
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(pager.items.map((item) => item.guid), [
        'photo-4',
        'photo-3',
        'photo-2',
        'photo-1',
      ]);
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
