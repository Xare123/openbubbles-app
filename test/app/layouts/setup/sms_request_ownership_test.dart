import 'dart:async';

import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_common.dart';
import 'package:flutter_test/flutter_test.dart';

class _Handle implements RustOpaqueInterface {
  int disposals = 0;
  @override
  bool get isDisposed => disposals > 0;
  @override
  void dispose() => disposals++;
}

class _Account extends _Handle
    implements ArcMutexAppleAccountDefaultAnisetteProvider {}

class _Circle extends _Handle
    implements api.CircleClientSessionDefaultAnisetteProvider {}

class _Body extends _Handle implements api.VerifyBody {}

class _NativeUi implements MethodChannelService {
  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) async {
    expect(method, 'circle-proximity-session');
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected platform call: ${invocation.memberName}');
}

const _phone = api.TrustedPhoneNumber(
  numberWithDialCode: '***01',
  lastTwoDigits: '01',
  pushMode: 'sms',
  id: 7,
);

class _Bridge implements RustLibApi {
  final calls = <String>[];
  late Future<(List<api.TrustedPhoneNumber>, api.LoginState?)> Function()
  options;
  late Future<api.LoginState> Function() send;
  Completer<void>? sendEntered;

  @override
  Future<(List<api.TrustedPhoneNumber>, api.LoginState?)>
  crateApiApiGet2FaSmsOpts({
    required ArcMutexAppleAccountDefaultAnisetteProvider state,
  }) {
    calls.add('options');
    return options();
  }

  @override
  Future<api.LoginState> crateApiApiSend2FaSms({
    api.CircleClientSessionDefaultAnisetteProvider? locked,
    required ArcMutexAppleAccountDefaultAnisetteProvider account,
    required int phoneId,
  }) {
    calls.add('sms:$phoneId');
    sendEntered?.complete();
    return send();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

SetupViewController _controller() => SetupViewController()
  ..state = const api.LoginState.needs2FaVerification()
  ..currentAppleAccount = _Account()
  ..circleSession = _Circle();

void main() {
  final bridge = _Bridge();
  setUpAll(() {
    RustLib.initMock(api: bridge);
    mcs = _NativeUi();
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    bridge.calls.clear();
    bridge.sendEntered = null;
    bridge.options = () async => ([_phone], null);
    bridge.send = () async => api.LoginState.needsSms2FaVerification(_Body());
  });

  test('rejected phone options do not send or claim SMS delivery', () async {
    final controller = _controller();
    final account = controller.currentAppleAccount;
    final circle = controller.circleSession;
    bridge.options = () async => throw StateError('synthetic HTTP 403');
    await expectLater(
      controller.updateLoginState(
        const api.LoginState.needsSms2Fa(),
        attempt: controller.beginLoginAttempt(),
      ),
      throwsStateError,
    );
    expect(bridge.calls, ['options']);
    expect(controller.currentAppleAccount, same(account));
    expect(controller.circleSession, same(circle));
    expect(controller.isSms.value, isFalse);
    expect(controller.state, isA<api.LoginState_Needs2FAVerification>());
  });

  test(
    'already-issued SMS enters verification without a duplicate send',
    () async {
      final controller = _controller();
      final issued = api.LoginState.needsSms2FaVerification(_Body());
      bridge.options = () async => ([_phone], issued);
      await controller.updateLoginState(
        const api.LoginState.needsSms2Fa(),
        attempt: controller.beginLoginAttempt(),
      );
      expect(bridge.calls, ['options']);
      expect(controller.state, same(issued));
      expect(controller.isSms.value, isTrue);
    },
  );

  test(
    'current request uses the returned phone ID and publishes one challenge',
    () async {
      final controller = _controller();
      final body = _Body();
      final issued = api.LoginState.needsSms2FaVerification(body);
      bridge.send = () async => issued;
      await controller.updateLoginState(
        const api.LoginState.needsSms2Fa(),
        attempt: controller.beginLoginAttempt(),
      );
      expect(bridge.calls, ['options', 'sms:7']);
      expect(controller.state, same(issued));
      expect(controller.isSms.value, isTrue);
      expect(controller.circleSession, isNull);
      expect(body.disposals, 0);
    },
  );

  for (final multipleNumbers in [false, true]) {
    test(
      'late ${multipleNumbers ? 'multiple' : 'single'} phone options never request a code or show a dialog',
      () async {
        final controller = _controller();
        final options =
            Completer<(List<api.TrustedPhoneNumber>, api.LoginState?)>();
        bridge.options = () => options.future;
        final pending = controller.updateLoginState(
          const api.LoginState.needsSms2Fa(),
          attempt: controller.beginLoginAttempt(),
        );
        controller.cancelLoginAttempt();
        controller.beginLoginAttempt();
        final newerAccount = _Account();
        controller.currentAppleAccount = newerAccount;
        options.complete((
          [
            _phone,
            if (multipleNumbers)
              const api.TrustedPhoneNumber(
                numberWithDialCode: '***02',
                lastTwoDigits: '02',
                pushMode: 'sms',
                id: 8,
              ),
          ],
          null,
        ));
        // There is intentionally no dialog context in this unit fixture.
        await pending;
        expect(bridge.calls, ['options']);
        expect(controller.currentAppleAccount, same(newerAccount));
        expect(controller.isSms.value, isFalse);
        expect(controller.state, isA<api.LoginState_Needs2FAVerification>());
      },
    );
  }

  test('late options cannot change the channel of a newer login', () async {
    final controller = _controller();
    final options =
        Completer<(List<api.TrustedPhoneNumber>, api.LoginState?)>();
    bridge.options = () => options.future;
    final pending = controller.updateLoginState(
      const api.LoginState.needsSms2Fa(),
      attempt: controller.beginLoginAttempt(),
    );
    controller.cancelLoginAttempt();
    controller.beginLoginAttempt();
    final newerAccount = _Account();
    final newerCircle = _Circle();
    controller.currentAppleAccount = newerAccount;
    controller.circleSession = newerCircle;
    final staleBody = _Body();
    options.complete((
      [_phone],
      api.LoginState.needsSms2FaVerification(staleBody),
    ));
    await pending;
    expect(bridge.calls, ['options']);
    expect(controller.currentAppleAccount, same(newerAccount));
    expect(controller.circleSession, same(newerCircle));
    expect(controller.isSms.value, isFalse);
    expect(controller.state, isA<api.LoginState_Needs2FAVerification>());
    expect(staleBody.disposals, 1);
    expect(newerAccount.disposals, 0);
    expect(newerCircle.disposals, 0);
  });

  test(
    'late SMS completion cannot discard a newer verification session',
    () async {
      final controller = _controller();
      final oldAccount = controller.currentAppleAccount! as _Account;
      final oldCircle = controller.circleSession! as _Circle;
      final send = Completer<api.LoginState>();
      bridge.sendEntered = Completer<void>();
      bridge.send = () => send.future;
      final pending = controller.updateLoginState(
        const api.LoginState.needsSms2Fa(),
        attempt: controller.beginLoginAttempt(),
      );
      await bridge.sendEntered!.future;
      controller.cancelLoginAttempt();
      controller.beginLoginAttempt();
      final newerAccount = _Account();
      final newerCircle = _Circle();
      controller.currentAppleAccount = newerAccount;
      controller.circleSession = newerCircle;
      final staleBody = _Body();
      send.complete(api.LoginState.needsSms2FaVerification(staleBody));
      await pending;
      expect(bridge.calls, ['options', 'sms:7']);
      expect(controller.currentAppleAccount, same(newerAccount));
      expect(controller.circleSession, same(newerCircle));
      expect(controller.isSms.value, isFalse);
      expect(controller.state, isA<api.LoginState_Needs2FAVerification>());
      expect(staleBody.disposals, 1);
      expect(oldAccount.disposals, 1);
      expect(oldCircle.disposals, 1);
      expect(newerAccount.disposals, 0);
      expect(newerCircle.disposals, 0);
    },
  );
}
