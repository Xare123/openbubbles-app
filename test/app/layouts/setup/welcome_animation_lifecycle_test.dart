import 'package:bluebubbles/app/layouts/setup/pages/welcome/welcome_page.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/global/settings.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

// Regression coverage for the WelcomePage animation lifecycle crashes.
//
// 1. OptimizedState used to call ModalRoute.of(context) inside its route
//    animation status listener. When the widget was disposed before the route
//    transition finished, that lookup ran on a deactivated State and threw.
//    The fix captures the route animation once while mounted and never
//    touches context from the listener.
// 2. WelcomePage staggers two AnimationController forwards 500ms apart from
//    an async post-frame callback. Disposing the page mid-delay used to
//    resume into forward() on a disposed controller. The fix guards both
//    forwards with mounted checks while preserving the 500ms stagger.
//    Pinned below by pumping the real WelcomePage with minimal fakes
//    (Settings defaults, a light-mode theme service, and a real
//    SetupViewController) rather than a mirrored probe.

class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe();

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends OptimizedState<_LifecycleProbe> {
  bool get animationGateCompleted => animCompleted.isCompleted;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _TestThemesService extends ThemesService {
  @override
  bool inDarkMode(BuildContext context) => false;
}

Future<void> _pumpWelcomePage(WidgetTester tester) async {
  Get.testMode = true;
  final previousTs = ts;
  ts = _TestThemesService();
  ss.settings = Settings();
  Get.put(SetupViewController());
  addTearDown(() {
    ts = previousTs;
    if (Get.isRegistered<SetupViewController>()) {
      Get.delete<SetupViewController>(force: true);
    }
  });
  await tester.pumpWidget(MaterialApp(home: WelcomePage()));
  await tester.pump();
}

void main() {
  testWidgets(
    'route animation completing after dispose does not touch a deactivated context',
    (tester) async {
      final showProbe = ValueNotifier<bool>(true);
      addTearDown(showProbe.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ValueListenableBuilder<bool>(
                        valueListenable: showProbe,
                        builder: (_, show, __) => show
                            ? const _LifecycleProbe()
                            : const SizedBox.shrink(),
                      ),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('go'));
      await tester.pump();
      // Mid-transition: the probe has registered its route-animation listener.
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(_LifecycleProbe), findsOneWidget);

      // Dispose the probe while the route transition is still running.
      showProbe.value = false;
      await tester.pump();
      expect(find.byType(_LifecycleProbe), findsNothing);

      // Let the abandoned transition finish. The stale listener must not
      // throw via ModalRoute.of on the deactivated probe context.
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('animation gate completes once the route settles', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _LifecycleProbe()));
    await tester.pumpAndSettle();
    final state = tester.state<_LifecycleProbeState>(
      find.byType(_LifecycleProbe),
    );
    expect(state.animationGateCompleted, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposing WelcomePage mid-stagger never forwards a disposed controller',
    (tester) async {
      await _pumpWelcomePage(tester);
      expect(find.byType(WelcomePage), findsOneWidget);
      expect(find.text('Welcome to OpenBubbles'), findsOneWidget);
      // Still inside the 500ms stagger window: tear the page down.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      // Run past the stagger delay; the resumed production callback must bail via mounted.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'WelcomePage stagger still delays the subtitle forward by 500ms',
    (tester) async {
      await _pumpWelcomePage(tester);
      expect(find.text('Welcome to OpenBubbles'), findsOneWidget);

      final dynamic welcomeState = tester.state(find.byType(WelcomePage));
      final Animation<double> titleOpacity =
          welcomeState.opacityTitle as Animation<double>;
      final Animation<double> subtitleOpacity =
          welcomeState.opacitySubtitle as Animation<double>;

      // 400ms in: title fade running, subtitle fade untouched.
      await tester.pump(const Duration(milliseconds: 400));
      expect(titleOpacity.value, greaterThan(0));
      expect(subtitleOpacity.value, 0);

      // Cross the 500ms stagger: the subtitle forward has just started, so its
      // value is still 0 until the ticker gets another frame.
      await tester.pump(const Duration(milliseconds: 200));
      expect(titleOpacity.value, greaterThan(0));
      expect(subtitleOpacity.value, 0);

      // Extra frame advances the newly-started subtitle ticker.
      await tester.pump(const Duration(milliseconds: 200));
      expect(titleOpacity.value, greaterThan(0));
      expect(subtitleOpacity.value, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
}
