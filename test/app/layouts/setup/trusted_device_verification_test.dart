import 'dart:async';

import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_common.dart';
import 'package:flutter_test/flutter_test.dart';

class _Handle implements RustOpaqueInterface {
  int disposeCount = 0;
  @override
  bool get isDisposed => disposeCount != 0;
  @override
  void dispose() => disposeCount++;
}

class _Account extends _Handle
    implements ArcMutexAppleAccountDefaultAnisetteProvider {}

class _Anisette extends _Handle
    implements ArcAnisetteClientDefaultAnisetteProvider {}

class _Config extends _Handle implements api.JoinedOsConfig {}

class _User extends _Handle implements api.IdsUser {}

class _Connection extends _Handle implements ApsConnection {}

class _Circle extends _Handle
    implements api.CircleClientSessionDefaultAnisetteProvider {}

class _Receiver extends _Handle implements api.ReceiverApsMessage {}

class _Listener extends _Handle implements ArcIdmsAuthListener {}

class _VerifyBody extends _Handle implements api.VerifyBody {}

class _PushService implements RustPushService {
  @override
  String statePath = 'synthetic-no-account-profile';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected push service operation: ${invocation.memberName}',
  );
}

// Keep this test at code submission and result ownership. Registration after
// successful verification is covered by the existing completion-seam tests.
class _Controller extends SetupViewController {
  int continuationCount = 0;
  @override
  Future<api.LoginState> updateLoginState(
    api.LoginState ret, {
    int? attempt,
  }) async {
    continuationCount++;
    return ret;
  }
}

class _Bridge implements RustLibApi {
  final calls = <String>[];
  late Future<(api.LoginState, api.IdsUser?)> Function() verify;
  late Future<api.IdsUser?> Function() completeLogin;
  late Future<(ArcMutexAppleAccountDefaultAnisetteProvider, api.LoginState)>
  Function()
  authenticate;

  @override
  Future<(ArcMutexAppleAccountDefaultAnisetteProvider, api.LoginState)>
  crateApiApiTryAuth({
    required String path,
    required api.JoinedOsConfig conf,
    required ApsConnection conn,
    required ArcAnisetteClientDefaultAnisetteProvider anisette,
    (String, String)? creds,
  }) {
    calls.add('authenticate');
    return authenticate();
  }

  @override
  Future<api.IdsUser?> crateApiApiTryIcloudLogin({
    required String path,
    required api.JoinedOsConfig conf,
    required ArcMutexAppleAccountDefaultAnisetteProvider account,
  }) {
    calls.add('complete-login');
    return completeLogin();
  }

  @override
  Future<(api.LoginState, api.IdsUser?)> crateApiApiVerify2FaDirect({
    required String path,
    required ArcMutexAppleAccountDefaultAnisetteProvider account,
    required api.JoinedOsConfig osConfig,
    required String code,
  }) {
    calls.add('direct');
    return verify();
  }

  @override
  Future<(api.LoginState, api.IdsUser?)> crateApiApiVerify2Fa({
    required String path,
    required api.CircleClientSessionDefaultAnisetteProvider client,
    required ArcAnisetteClientDefaultAnisetteProvider anisette,
    required api.JoinedOsConfig osConfig,
    required ArcMutexAppleAccountDefaultAnisetteProvider account,
    required api.ReceiverApsMessage watcher,
    required ArcIdmsAuthListener idms,
    required String code,
  }) {
    calls.add('circle');
    return verify();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation: ${invocation.memberName}');
}

_Controller _controller({bool circle = false}) {
  final controller = _Controller()
    ..state = const api.LoginState.needs2FaVerification()
    ..currentAppleAccount = _Account()
    ..anisette = _Anisette()
    ..config = _Config();
  if (circle) {
    controller
      ..connection = _Connection()
      ..circleSession = _Circle()
      ..connReceiver = _Receiver()
      ..connListener = _Listener();
  }
  return controller;
}

void main() {
  final bridge = _Bridge();
  setUpAll(() {
    RustLib.initMock(api: bridge);
    pushService = _PushService();
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    bridge.calls.clear();
    bridge.verify = () async => (const api.LoginState.loggedIn(), _User());
    bridge.completeLogin = () async => _User();
    bridge.authenticate = () async =>
        (_Account(), const api.LoginState.needs2FaVerification());
  });

  final pendingStates = <String, api.LoginState>{
    'needs login': const api.LoginState.needsLogin(),
    'needs trusted device': const api.LoginState.needsDevice2Fa(),
    'awaits trusted code': const api.LoginState.needs2FaVerification(),
    'needs SMS': const api.LoginState.needsSms2Fa(),
    'awaits SMS code': api.LoginState.needsSms2FaVerification(_VerifyBody()),
    'needs extra step': const api.LoginState.needsExtraStep('synthetic'),
  };
  for (final entry in pendingStates.entries) {
    test('${entry.key} never attempts account registration', () async {
      final controller = _controller();
      controller.currentAppleUser = _User();
      final attempt = controller.beginLoginAttempt();
      await controller.completeAuthenticatedAppleLogin(
        entry.value,
        controller.currentAppleAccount!,
        attempt: attempt,
      );
      expect(bridge.calls, isEmpty);
      expect(controller.currentAppleUser, isNull);
    });
  }

  test(
    'explicit logged-in response completes account registration once',
    () async {
      final controller = _controller();
      final user = _User();
      bridge.completeLogin = () async => user;
      await controller.completeAuthenticatedAppleLogin(
        const api.LoginState.loggedIn(),
        controller.currentAppleAccount!,
        attempt: controller.beginLoginAttempt(),
      );
      expect(bridge.calls, ['complete-login']);
      expect(controller.currentAppleUser, same(user));
      expect(user.disposeCount, 0);
    },
  );

  test('stale registration result cannot replace a newer user', () async {
    final controller = _controller();
    final account = controller.currentAppleAccount! as _Account;
    final completion = Completer<api.IdsUser?>();
    bridge.completeLogin = () => completion.future;
    final pending = controller.completeAuthenticatedAppleLogin(
      const api.LoginState.loggedIn(),
      account,
      attempt: controller.beginLoginAttempt(),
    );
    controller.cancelLoginAttempt();
    expect(account.disposeCount, 0);
    final newerUser = _User();
    controller.currentAppleUser = newerUser;
    final staleUser = _User();
    completion.complete(staleUser);
    await pending;
    expect(bridge.calls, ['complete-login']);
    expect(staleUser.disposeCount, 1);
    expect(account.disposeCount, 1);
    expect(newerUser.disposeCount, 0);
    expect(controller.currentAppleUser, same(newerUser));
  });

  test(
    'registration failure is surfaced without retry or user publication',
    () async {
      final controller = _controller();
      bridge.completeLogin = () async =>
          throw StateError('synthetic registration failure');
      await expectLater(
        controller.completeAuthenticatedAppleLogin(
          const api.LoginState.loggedIn(),
          controller.currentAppleAccount!,
          attempt: controller.beginLoginAttempt(),
        ),
        throwsStateError,
      );
      expect(bridge.calls, ['complete-login']);
      expect(controller.currentAppleUser, isNull);
    },
  );

  test(
    'password retry awaiting a code does not enter account registration',
    () async {
      final controller = SetupViewController()
        ..config = _Config()
        ..connection = _Connection()
        ..anisette = _Anisette();
      final result = await controller.updateLoginState(
        const api.LoginState.needsLogin(),
        attempt: controller.beginLoginAttempt(),
      );
      expect(result, isA<api.LoginState_Needs2FAVerification>());
      expect(controller.state, isA<api.LoginState_Needs2FAVerification>());
      expect(controller.currentAppleUser, isNull);
      expect(bridge.calls, ['authenticate']);
    },
  );

  test(
    'already-issued challenge opens code entry without another native call',
    () async {
      final controller = SetupViewController();
      controller.isSms.value = true;
      final result = await controller.updateLoginState(
        const api.LoginState.needs2FaVerification(),
      );
      expect(result, isA<api.LoginState_Needs2FAVerification>());
      expect(controller.isSms.value, isFalse);
      expect(controller.circleSession, isNull);
      expect(bridge.calls, isEmpty);
    },
  );

  test(
    'missing circle uses direct verification and publishes its result',
    () async {
      final controller = _controller();
      final user = _User();
      bridge.verify = () async => (const api.LoginState.loggedIn(), user);
      final result = await controller.submitCode('123456');
      expect(bridge.calls, ['direct']);
      expect(result, isA<api.LoginState_LoggedIn>());
      expect(controller.currentAppleUser, same(user));
      expect(user.disposeCount, 0);
      expect(controller.continuationCount, 1);
    },
  );

  test(
    'live circle retains the existing proximity verification route',
    () async {
      final controller = _controller(circle: true);
      await controller.submitCode('123456');
      expect(bridge.calls, ['circle']);
      expect(controller.continuationCount, 1);
      expect(controller.circleSession!.isDisposed, isFalse);
    },
  );

  test(
    'direct verification does not retain disposed unused circle resources',
    () async {
      final controller = _controller(circle: true);
      controller.circleSession!.dispose();
      controller.connReceiver!.dispose();
      await controller.submitCode('123456');
      expect(bridge.calls, ['direct']);
      expect(controller.continuationCount, 1);
    },
  );

  for (final circle in [false, true]) {
    test(
      'stale ${circle ? 'circle' : 'direct'} result releases only its returned user',
      () async {
        final controller = _controller(circle: circle);
        final account = controller.currentAppleAccount! as _Account;
        final result = Completer<(api.LoginState, api.IdsUser?)>();
        bridge.verify = () => result.future;
        final pending = controller.submitCode('123456');
        expect(bridge.calls, [circle ? 'circle' : 'direct']);
        controller.cancelLoginAttempt();
        expect(account.disposeCount, 0);
        controller.beginLoginAttempt();
        final newerUser = _User();
        controller.currentAppleUser = newerUser;
        controller.state = const api.LoginState.needsLogin();
        final staleUser = _User();
        result.complete((const api.LoginState.loggedIn(), staleUser));
        expect(await pending, isA<api.LoginState_NeedsLogin>());
        expect(staleUser.disposeCount, 1);
        expect(account.disposeCount, 1);
        expect(newerUser.disposeCount, 0);
        expect(controller.currentAppleUser, same(newerUser));
        expect(controller.continuationCount, 0);
      },
    );
  }

  test(
    'verification rejection is surfaced once without publishing or retrying',
    () async {
      final controller = _controller();
      bridge.verify = () async => throw StateError('synthetic code rejection');
      await expectLater(controller.submitCode('123456'), throwsStateError);
      expect(bridge.calls, ['direct']);
      expect(controller.state, isA<api.LoginState_Needs2FAVerification>());
      expect(controller.currentAppleUser, isNull);
      expect(controller.continuationCount, 0);
    },
  );

  test('already-stale submission does not call the native bridge', () async {
    final controller = _controller();
    final attempt = controller.beginLoginAttempt();
    controller.cancelLoginAttempt();
    await controller.submitCode('123456', attempt: attempt);
    expect(bridge.calls, isEmpty);
  });
}
