import 'dart:async';

import 'package:bluebubbles/app/layouts/setup/pages/rustpush/appleid_login.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class _Handle implements RustOpaqueInterface {
  @override
  bool isDisposed = false;
  @override
  void dispose() => isDisposed = true;
}

class _Config extends _Handle implements api.JoinedOsConfig {}

class _Connection extends _Handle implements ApsConnection {}

class _Anisette extends _Handle
    implements ArcAnisetteClientDefaultAnisetteProvider {}

class _PushService implements RustPushService {
  @override
  String statePath = 'synthetic-no-account-profile';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected service call');
}

class _Controller extends SetupViewController {
  @override
  void updateConnectError(String newError) {
    error = newError;
    updateWidgets<ErrorText>(newError);
  }
}

class _Bridge implements RustLibApi {
  final calls = <String>[];
  late String error;
  Completer<(ArcMutexAppleAccountDefaultAnisetteProvider, api.LoginState)>?
      pending;
  @override
  String? crateApiApiGetAvailableUser({required String path}) => null;
  @override
  Future<(ArcMutexAppleAccountDefaultAnisetteProvider, api.LoginState)>
  crateApiApiTryAuth({
    required String path,
    required api.JoinedOsConfig conf,
    required ApsConnection conn,
    required ArcAnisetteClientDefaultAnisetteProvider anisette,
    (String, String)? creds,
  }) async {
    calls.add('authenticate');
    if (pending != null) return pending!.future;
    throw AnyhowException(error);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bridge = _Bridge();
  setUpAll(() async {
    RustLib.initMock(api: bridge);
    pushService = _PushService();
    final font = FontLoader('Inter')
      ..addFont(
        rootBundle.load('assets/fonts/Inter-VariableFont_opsz,wght.ttf'),
      );
    await font.load();
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    bridge.calls.clear();
    bridge.pending = null;
  });

  Future<(_Controller, dynamic)> mountLogin(WidgetTester tester) async {
    final controller = _Controller()
      ..config = _Config()
      ..connection = _Connection()
      ..anisette = _Anisette();
    Get.put<SetupViewController>(controller);
    addTearDown(Get.reset);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(fontFamily: 'Inter', platform: TargetPlatform.android),
        home: Scaffold(body: AppleIdLogin()),
      ),
    );
    final dynamic page = tester.state(find.byType(AppleIdLogin));
    page.appleIdController.text = 'synthetic@example.test';
    page.passwordController.text = 'synthetic-password';
    await tester.pump();
    return (controller, page);
  }

  for (final closePage in [false, true]) {
    testWidgets(
      'late password failure is ignored after ${closePage ? 'page removal' : 'attempt cancellation'}',
      (tester) async {
        final (controller, page) = await mountLogin(tester);
        bridge.pending = Completer();
        final Future<void> request =
            page.connect('synthetic@example.test', 'synthetic-password');
        final assertion = expectLater(request, completes);
        if (closePage) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          controller.cancelLoginAttempt();
          controller.beginLoginAttempt();
        }
        controller.updateConnectError('new login state');
        bridge.pending!.completeError(AnyhowException('late server failure'));
        await assertion;
        await tester.pump();
        expect(controller.error, 'new login state');
        expect(bridge.calls, ['authenticate']);
        expect(controller.currentAppleAccount, isNull);
        expect(controller.currentAppleUser, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('pending password submission cannot start another sign-in',
      (tester) async {
    final (_, page) = await mountLogin(tester);
    bridge.pending = Completer();
    final Future<void> first =
        page.connect('synthetic@example.test', 'synthetic-password');
    final failure = AnyhowException('synthetic server failure');
    final firstAssertion = expectLater(first, completes);
    final Future<void> second =
        page.connect('synthetic@example.test', 'synthetic-password');
    final secondAssertion = expectLater(second, completes);
    // Resolve both futures even on the old implementation, so a failed
    // assertion cannot leave a pending login or create a real network retry.
    bridge.pending!.completeError(failure);
    await firstAssertion;
    await secondAssertion;
    await tester.pumpAndSettle();
    expect(bridge.calls, ['authenticate']);
    expect(page.loading, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keyboard sign-in handles a displayed service error without an uncaught future',
      (tester) async {
    final (_, page) = await mountLogin(tester);
    bridge.error = 'Apple sign-in service is temporarily unavailable';
    await tester.showKeyboard(find.byType(TextField).last);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(bridge.calls, ['authenticate']);
    expect(find.text(bridge.error), findsOneWidget);
    expect(page.loading, isFalse);
    expect(page.obscureText, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final error in [
    "Apple's sign-in service returned a server error (HTTP 503). Please try again later. This error does not require resetting your activation details.",
    'Apple is limiting sign-in requests (HTTP 429). Please wait before trying again.',
  ]) {
    testWidgets(
      'login shows service error and releases spinner without erasing input: $error',
      (tester) async {
        bridge.calls.clear();
        bridge.error = error;
        final config = _Config();
        final connection = _Connection();
        final anisette = _Anisette();
        final controller = _Controller()
          ..config = config
          ..connection = connection
          ..anisette = anisette;
        Get.put<SetupViewController>(controller);
        addTearDown(Get.reset);
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          GetMaterialApp(
            theme: ThemeData(
              fontFamily: 'Inter',
              platform: TargetPlatform.android,
            ),
            home: Scaffold(body: AppleIdLogin()),
          ),
        );
        final dynamic page = tester.state(find.byType(AppleIdLogin));
        page.appleIdController.text = 'synthetic@example.test';
        page.passwordController.text = 'synthetic-password';
        await tester.pump();
        await expectLater(
          page.connect('synthetic@example.test', 'synthetic-password'),
          completes,
        );
        await tester.pumpAndSettle();
        expect(find.text(error), findsOneWidget);
        expect(page.loading, isFalse);
        expect(page.appleIdController.text, 'synthetic@example.test');
        expect(page.passwordController.text, 'synthetic-password');
        expect(page.obscureText, isTrue);
        expect(controller.config, same(config));
        expect(controller.connection, same(connection));
        expect(controller.anisette, same(anisette));
        expect(bridge.calls, ['authenticate']);
        expect(controller.currentAppleAccount, isNull);
        expect(controller.currentAppleUser, isNull);
        expect(tester.takeException(), isNull);
        for (final resource in [config, connection, anisette]) {
          expect(resource.isDisposed, isFalse);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
