import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  tearDown(() async {
    if (Get.isSnackbarOpen) Get.closeAllSnackbars();
    Get.rootController.scaffoldMessengerKey.currentState?.clearSnackBars();
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('shows a snackbar when resumed with a root overlay', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.binding.lifecycleState, AppLifecycleState.resumed);
    expect(Get.key, same(navigatorKey));
    expect(Get.key.currentState?.overlay, isNotNull);

    showSnackbar('Visible title', 'Visible message', durationMs: 1000);
    await tester.pump();

    expect(find.text('Visible title'), findsOneWidget);
    expect(find.text('Visible message'), findsOneWidget);
  });

  testWidgets('skips a snackbar while the app is backgrounded', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    for (final state in <AppLifecycleState>[
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      showSnackbar('Hidden title', 'Hidden message');
      await tester.pump();

      expect(find.text('Hidden title'), findsNothing);
      expect(find.text('Hidden message'), findsNothing);
      expect(Get.isSnackbarOpen, isFalse);
    }
  });

  testWidgets('skips a snackbar when the root overlay is unavailable', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    showSnackbar('Unavailable title', 'Unavailable message');
    await tester.pump();

    expect(find.text('Unavailable title'), findsNothing);
    expect(find.text('Unavailable message'), findsNothing);
    expect(Get.isSnackbarOpen, isFalse);
  });
}
