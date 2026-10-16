import 'dart:async';

import 'package:bluebubbles/app/layouts/setup/pages/rustpush/appleid_2fa.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart';

class _Controller extends SetupViewController {
  var response = Completer<api.LoginState>();
  final errors = <String>[];
  final calls = <String>[];

  @override
  Future<api.LoginState> updateLoginState(
    api.LoginState state, {
    int? attempt,
  }) {
    calls.add('sms');
    return response.future;
  }

  @override
  Future<api.LoginState> submitCode(String code, {int? attempt}) {
    calls.add('verify');
    return response.future;
  }

  @override
  void updateConnectError(String newError) {
    errors.add(newError);
    error = newError;
    updateWidgets<ErrorText>(newError);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // The real pending-code screen renders the app's skin-aware spinner.
    // Supply in-memory settings only; do not initialize any user profile.
    ss.settings = Settings();
    // Use a bundled app font instead of the square test font. These checks
    // exercise async ownership, not typography or a screenshot baseline.
    final loader = FontLoader('Inter')
      ..addFont(
        rootBundle.load('assets/fonts/Inter-VariableFont_opsz,wght.ttf'),
      );
    await loader.load();
  });
  for (final firstSms in [true, false]) {
    for (final secondSms in [true, false]) {
      testWidgets(
        'overlapping verification actions keep ${firstSms ? 'SMS' : 'code'} exclusive against ${secondSms ? 'SMS' : 'code'}',
        (tester) async {
          final controller = _Controller()..goingTo2fa = false;
          Get.put<SetupViewController>(controller);
          addTearDown(Get.reset);
          tester.view.physicalSize = const Size(1000, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            GetMaterialApp(
              theme: ThemeData(fontFamily: 'Inter'),
              home: Scaffold(body: AppleId2FA()),
            ),
          );
          final dynamic page = tester.state(find.byType(AppleId2FA));
          // No frame between calls: the real page must reserve the operation
          // before OptimizedState's potentially deferred setState callback.
          final Future<void> first = firstSms
              ? page.appleHelp()
              : page.connect('123456');
          final Future<void> second = secondSms
              ? page.appleHelp()
              : page.connect('123456');
          controller.response.complete(
            const api.LoginState.needs2FaVerification(),
          );
          await Future.wait([first, second]);
          await tester.pumpAndSettle();
          expect(controller.calls, [firstSms ? 'sms' : 'verify']);
          expect(page.loading, isFalse);
          expect(page.appleHelping, isFalse);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
  for (final requestSms in [true, false]) {
    testWidgets(
      '${requestSms ? 'resend button' : 'automatic code entry'} handles a native error and permits an explicit retry',
      (tester) async {
        final controller = _Controller()..goingTo2fa = false;
        Get.put<SetupViewController>(controller);
        addTearDown(Get.reset);
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          GetMaterialApp(
            theme: ThemeData(fontFamily: 'Inter'),
            home: Scaffold(body: AppleId2FA()),
          ),
        );
        final dynamic page = tester.state(find.byType(AppleId2FA));
        final resend = find.widgetWithText(TextButton, 'Resend to Phone #');
        Future<void> act() async {
          if (requestSms) {
            await tester.tap(resend);
          } else {
            await tester.enterText(find.byType(TextField), '123456');
          }
        }

        await act();
        await tester.pump();
        expect(controller.calls, [requestSms ? 'sms' : 'verify']);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        expect(tester.widget<TextButton>(resend).onPressed, isNull);
        final signIn = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Sign In'),
        );
        expect(signIn.onPressed, isNull);
        expect(signIn.onLongPress, isNull);
        controller.response.completeError(
          AnyhowException('Synthetic service unavailable'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(controller.error, contains('Synthetic service unavailable'));
        expect(
          find.textContaining('Synthetic service unavailable'),
          findsOneWidget,
        );
        expect(page.isBusy, isFalse);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isTrue,
        );
        controller.response = Completer<api.LoginState>();
        if (!requestSms) {
          await tester.enterText(find.byType(TextField), '');
        }
        await act();
        controller.response.complete(
          const api.LoginState.needs2FaVerification(),
        );
        await tester.pumpAndSettle();
        expect(controller.calls, List.filled(2, requestSms ? 'sms' : 'verify'));
        expect(controller.error, isEmpty);
        expect(page.isBusy, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'late ${requestSms ? 'SMS request' : 'verification'} failure cannot overwrite a newer login error',
      (tester) async {
        final controller = _Controller()..goingTo2fa = false;
        Get.put<SetupViewController>(controller);
        addTearDown(Get.reset);
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          GetMaterialApp(
            theme: ThemeData(fontFamily: 'Inter'),
            home: Scaffold(body: AppleId2FA()),
          ),
        );
        final dynamic page = tester.state(find.byType(AppleId2FA));
        final Future<void> pending = requestSms
            ? page.appleHelp()
            : page.connect('123456');
        controller.cancelLoginAttempt();
        controller.beginLoginAttempt();
        controller.updateConnectError('new login state');
        final assertion = expectLater(pending, completes);
        controller.response.completeError(StateError('late previous failure'));
        await assertion;
        await tester.pump();
        expect(controller.error, 'new login state');
        expect(
          controller.errors,
          isNot(contains('Bad state: late previous failure')),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'current ${requestSms ? 'SMS request' : 'verification'} failure is still reported',
      (tester) async {
        final controller = _Controller()..goingTo2fa = false;
        Get.put<SetupViewController>(controller);
        addTearDown(Get.reset);
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          GetMaterialApp(
            theme: ThemeData(fontFamily: 'Inter'),
            home: Scaffold(body: AppleId2FA()),
          ),
        );
        final dynamic page = tester.state(find.byType(AppleId2FA));
        final Future<void> pending = requestSms
            ? page.appleHelp()
            : page.connect('123456');
        final failure = AnyhowException('SMS could not be requested');
        final assertion = expectLater(pending, completes);
        controller.response.completeError(failure);
        await assertion;
        await tester.pump();
        expect(controller.error, contains('SMS could not be requested'));
        expect(controller.errors.last, contains('SMS could not be requested'));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
