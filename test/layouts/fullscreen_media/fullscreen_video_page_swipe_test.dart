import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_video_page_swipe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget harness({
  required ValueChanged<FullscreenVideoPageSwipeDirection> onPageSwipe,
  ValueChanged<DragUpdateDetails>? onChildDrag,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          key: const Key('surface'),
          width: 320,
          height: 500,
          child: FullscreenVideoPageSwipeSurface(
            onPageSwipe: onPageSwipe,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: onChildDrag ?? (_) {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('maps physical swipes through the configured PageView direction', () {
    expect(
      fullscreenVideoPageDelta(
        FullscreenVideoPageSwipeDirection.left,
        reverse: false,
      ),
      1,
    );
    expect(
      fullscreenVideoPageDelta(
        FullscreenVideoPageSwipeDirection.right,
        reverse: false,
      ),
      -1,
    );
    expect(
      fullscreenVideoPageDelta(
        FullscreenVideoPageSwipeDirection.left,
        reverse: true,
      ),
      -1,
    );
    expect(
      fullscreenVideoPageDelta(
        FullscreenVideoPageSwipeDirection.right,
        reverse: true,
      ),
      1,
    );
  });

  testWidgets(
      'reports a page swipe even when video controls own horizontal drag',
      (tester) async {
    final swipes = <FullscreenVideoPageSwipeDirection>[];
    var childDragUpdates = 0;
    await tester.pumpWidget(
      harness(
        onPageSwipe: swipes.add,
        onChildDrag: (_) => childDragUpdates++,
      ),
    );

    final rect = tester.getRect(find.byKey(const Key('surface')));
    await tester.dragFrom(
      Offset(rect.right - 30, rect.center.dy),
      const Offset(-180, 0),
    );
    await tester.pump();

    expect(swipes, [FullscreenVideoPageSwipeDirection.left]);
    expect(childDragUpdates, greaterThan(0));
  });

  testWidgets('keeps the bottom transport and seek controls exclusive',
      (tester) async {
    final swipes = <FullscreenVideoPageSwipeDirection>[];
    var childDragUpdates = 0;
    await tester.pumpWidget(
      harness(
        onPageSwipe: swipes.add,
        onChildDrag: (_) => childDragUpdates++,
      ),
    );

    final rect = tester.getRect(find.byKey(const Key('surface')));
    await tester.dragFrom(
      Offset(rect.right - 30, rect.bottom - 20),
      const Offset(-180, 0),
    );
    await tester.pump();

    expect(swipes, isEmpty);
    expect(childDragUpdates, greaterThan(0));
  });

  testWidgets('exclusive video paging advances exactly one media item',
      (tester) async {
    final controller = PageController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: controller,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              FullscreenVideoPageSwipeSurface(
                onPageSwipe: (_) {
                  controller.animateToPage(
                    1,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                  );
                },
                child: const ColoredBox(
                  key: Key('video-page'),
                  color: Colors.black,
                ),
              ),
              const ColoredBox(key: Key('next-page'), color: Colors.blue),
              const ColoredBox(key: Key('skipped-page'), color: Colors.red),
            ],
          ),
        ),
      ),
    );

    final rect = tester.getRect(find.byKey(const Key('video-page')));
    await tester.dragFrom(
      Offset(rect.right - 30, rect.center.dy),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();

    expect(controller.page, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('does not turn a vertical controls gesture into paging',
      (tester) async {
    final swipes = <FullscreenVideoPageSwipeDirection>[];
    await tester.pumpWidget(harness(onPageSwipe: swipes.add));

    final rect = tester.getRect(find.byKey(const Key('surface')));
    await tester.dragFrom(
      Offset(rect.center.dx, rect.center.dy - 80),
      const Offset(20, 180),
    );
    await tester.pump();

    expect(swipes, isEmpty);
  });

  testWidgets('canceled pointer sequences cannot page after disposal',
      (tester) async {
    final swipes = <FullscreenVideoPageSwipeDirection>[];
    await tester.pumpWidget(harness(onPageSwipe: swipes.add));

    final rect = tester.getRect(find.byKey(const Key('surface')));
    final gesture =
        await tester.startGesture(Offset(rect.right - 30, rect.center.dy));
    await gesture.moveBy(const Offset(-180, 0));
    await gesture.cancel();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(swipes, isEmpty);
  });
}
