import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/src/rust/lib.dart';
import 'package:flutter_test/flutter_test.dart';

class _Handle extends Fake
    implements
        api.JoinedOsConfig,
        api.IdsngmIdentity,
        api.ReceiverApsMessage,
        ApsConnection,
        api.IdsUser,
        ArcIdmsAuthListener,
        ArcImClient {
  @override
  bool isDisposed = false;
  @override
  void dispose() => isDisposed = true;
}

class _Service extends Fake implements RustPushService {
  @override
  String get statePath => 'synthetic-no-account';
}

class _Controller extends SetupViewController {
  int? watcherAttempt;
  @override
  Future<bool> ensureWatcher({int? attempt}) async {
    watcherAttempt = attempt;
    // A canceled/superseded watcher may not provision a daemon or complete UI.
    return false;
  }
}

class _Bridge extends Fake implements RustLibApi {
  final user = _Handle();
  final calls = <String>[];

  @override
  api.IdsUser crateApiApiDuplicateUser({required api.IdsUser user}) => user;

  @override
  api.ReceiverApsMessage crateApiApiSubscribeConn({
    required ApsConnection conn,
  }) {
    calls.add('subscribe');
    return _Handle();
  }

  @override
  Future<ArcIdmsAuthListener> crateApiApiMakeIdms({
    required ApsConnection conn,
  }) async {
    calls.add('listener');
    return _Handle();
  }

  @override
  Future<(List<api.IdsUser>?, api.SupportAlert?)> crateApiApiRegisterIds({
    required String path,
    required ApsConnection aps,
    required api.IdsngmIdentity identity,
    required api.JoinedOsConfig config,
    required List<api.IdsUser> users,
  }) async {
    calls.add('register');
    return ([user], null);
  }

  @override
  Future<ArcImClient> crateApiApiMakeImclient({
    required String path,
    required ApsConnection conn,
    required List<api.IdsUser> users,
    required api.IdsngmIdentity identity,
  }) async {
    calls.add('client');
    return _Handle();
  }
}

void main() {
  final bridge = _Bridge();
  setUpAll(() {
    RustLib.initMock(api: bridge);
    // Assign before the global's lazy initializer can start real app services.
    pushService = _Service();
  });
  tearDownAll(RustLib.dispose);
  setUp(bridge.calls.clear);

  test(
    'registration preserves its attempt and stops on a stale watcher',
    () async {
      final controller = _Controller()
        ..config = _Handle()
        ..identity = _Handle()
        ..connection = _Handle()
        ..currentAppleUser = bridge.user;
      final attempt = controller.beginLoginAttempt();
      await controller.doRegister(attempt: attempt);
      expect(controller.watcherAttempt, attempt);
      expect(controller.isLoginAttemptCurrent(attempt), isTrue);
      expect(controller.success, isFalse);
      expect(bridge.calls, ['register']);
    },
  );

  test('creating a fresh watcher retains the caller login attempt', () async {
    final controller = SetupViewController()..connection = _Handle();
    final attempt = controller.beginLoginAttempt();

    expect(await controller.ensureWatcher(attempt: attempt), isTrue);

    expect(controller.isLoginAttemptCurrent(attempt), isTrue);
    expect(controller.connReceiver, isNotNull);
    expect(controller.connListener, isNotNull);
    expect(bridge.calls, ['subscribe', 'listener']);
  });
}
