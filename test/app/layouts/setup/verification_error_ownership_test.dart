import 'dart:async';

import 'package:bluebubbles/app/layouts/setup/pages/rustpush/appleid_2fa.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart';

class _Controller extends SetupViewController {
  final response = Completer<api.LoginState>();
  final errors = <String>[];

  @override
  Future<api.LoginState> updateLoginState(
    api.LoginState state, {
    int? attempt,
  }) => response.future;

  @override
  Future<api.LoginState> submitCode(String code, {int? attempt}) =>
      response.future;

  @override
  void updateConnectError(String newError) {
    errors.add(newError);
    error = newError;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Use a bundled app font instead of the square test font. These checks
    // exercise async ownership, not typography or a screenshot baseline.
    final loader = FontLoader('Inter')
      ..addFont(
        rootBundle.load('assets/fonts/Inter-VariableFont_opsz,wght.ttf'),
      );
    await loader.load();
  });
  for (final requestSms in [true, false]) {
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
        final assertion = expectLater(pending, throwsA(same(failure)));
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
