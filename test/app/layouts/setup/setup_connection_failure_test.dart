import 'dart:async';
import 'dart:typed_data';

import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

class _Connection implements ApsConnection {
  int disposeCount = 0;
  @override
  bool get isDisposed => disposeCount != 0;
  @override
  void dispose() => disposeCount++;
}

class _Anisette implements ArcAnisetteClientDefaultAnisetteProvider {
  int disposeCount = 0;
  @override
  bool get isDisposed => disposeCount != 0;
  @override
  void dispose() => disposeCount++;
}

class _PushError implements api.PushError {
  int disposeCount = 0;
  @override
  bool get isDisposed => disposeCount != 0;
  @override
  void dispose() => disposeCount++;
}

class _Identity implements api.IdsngmIdentity {
  bool isDisposed = false;
  @override
  void dispose() => isDisposed = true;
}

class _Config implements api.JoinedOsConfig {
  bool isDisposed = false;
  @override
  void dispose() => isDisposed = true;
}

class _PushState implements ApsState {
  bool isDisposed = false;
  @override
  void dispose() => isDisposed = true;
}

class _User implements api.IdsUser {
  bool isDisposed = false;
  @override
  void dispose() => isDisposed = true;
}

class _SavedHardware implements api.SavedHardwareState {
  _SavedHardware({
    required this.identity,
    required this.osConfig,
    required this.push,
  });

  @override
  Uint8List identity;
  @override
  api.JoinedOsConfig osConfig;
  @override
  ApsState push;
  bool isDisposed = false;

  @override
  void dispose() => isDisposed = true;
}

void main() {
  test('initial restore failure cannot replace the newer relay status', () async {
    final controller = SetupViewController();
    final newerConfig = _Config();
    final newerIdentity = _Identity();
    await controller.restoreSavedHardware(
      _SavedHardware(identity: Uint8List.fromList([1]), osConfig: _Config(), push: _PushState()),
      decodeIdentity: (_) => _Identity(),
      setupConnectionOverride: () async {
        controller.config = newerConfig;
        controller.identity = newerIdentity;
        controller.error = 'newer-synthetic-status';
        throw AnyhowException('old-synthetic-failure');
      },
    );
    expect(controller.config, same(newerConfig));
    expect(controller.identity, same(newerIdentity));
    expect(controller.error, 'newer-synthetic-status');
  });

  test('initial restore success cannot clear a newer identity recovery requirement', () async {
    final controller = SetupViewController();
    await controller.restoreSavedHardware(
      _SavedHardware(identity: Uint8List.fromList([1]), osConfig: _Config(), push: _PushState()),
      decodeIdentity: (_) => _Identity(),
      setupConnectionOverride: () async {
        controller.config = _Config();
        controller.identity = _Identity();
        controller.restoredConfigNeedsFreshIdentity = true;
      },
    );
    expect(controller.restoredConfigNeedsFreshIdentity, isTrue);
  });

  test('initial setup cannot overwrite a newer connection completed while push was pending', () async {
    final controller = SetupViewController();
    final started = Completer<void>();
    final finishPush = Completer<(ApsConnection, api.PushError?)>();
    final oldCandidate = _Connection();
    final oldProvider = _Anisette();
    final pending = controller.setupConnection(
      createPush: () { started.complete(); return finishPush.future; },
      prepareAnisette: (_) async => oldProvider,
    );
    await started.future;
    final newer = _Connection();
    final newerProvider = _Anisette();
    controller.connection = newer;
    controller.anisette = newerProvider;
    finishPush.complete((oldCandidate, null));
    await expectLater(pending, throwsA(isA<AnyhowException>()));
    expect(controller.connection, same(newer));
    expect(controller.anisette, same(newerProvider));
    expect(newer.disposeCount, 0);
    expect(newerProvider.disposeCount, 0);
    expect(oldCandidate.disposeCount, 1);
  });

  test('initial setup rejects a changed identity while provider preparation was pending', () async {
    final controller = SetupViewController();
    controller.config = _Config();
    controller.identity = _Identity();
    final started = Completer<void>();
    final finishProvider = Completer<ArcAnisetteClientDefaultAnisetteProvider>();
    final candidate = _Connection();
    final candidateState = _PushState();
    final candidateProvider = _Anisette();
    final pending = controller.setupConnection(
      createPush: () async => (candidate, null),
      captureState: (_) async => candidateState,
      prepareAnisette: (_) { started.complete(); return finishProvider.future; },
    );
    await started.future;
    final newerConfig = _Config();
    final newerIdentity = _Identity();
    controller.config = newerConfig;
    controller.identity = newerIdentity;
    finishProvider.complete(candidateProvider);
    await expectLater(pending, throwsA(isA<AnyhowException>()));
    expect(controller.config, same(newerConfig));
    expect(controller.identity, same(newerIdentity));
    expect(controller.connection, isNull);
    expect(candidate.disposeCount, 1);
    expect(candidateProvider.disposeCount, 1);
    expect(candidateState.isDisposed, isTrue);
  });

  test('unmatched relay leaves the existing setup untouched', () async {
    final controller = SetupViewController();
    final config = _Config();
    final identity = _Identity();
    final connection = _Connection();
    final provider = _Anisette();
    final state = _PushState();
    controller.config = config;
    controller.identity = identity;
    controller.connection = connection;
    controller.anisette = provider;
    controller.cachedState = state;
    expect(await controller.reuseNativeRelaySetup(_Config(),
      prepareReuse: () async => null), isFalse);
    expect(controller.config, same(config));
    expect(controller.identity, same(identity));
    expect(controller.connection, same(connection));
    expect(controller.anisette, same(provider));
    expect(controller.cachedState, same(state));
    expect(connection.disposeCount, 0);
    expect(provider.disposeCount, 0);
    expect(identity.isDisposed, isFalse);
    expect(config.isDisposed, isFalse);
  });

  test('same-phone relay replacement swaps resources and preserves phone users', () async {
    final controller = SetupViewController();
    final config = _Config();
    final identity = _Identity();
    final connection = _Connection();
    final provider = _Anisette();
    final state = _PushState();
    controller.config = config;
    controller.identity = identity;
    controller.connection = connection;
    controller.anisette = provider;
    controller.cachedState = state;
    final phone = _User();
    controller.currentPhoneUsers[1] = phone;
    final prepared = (_Connection(), _PushState(), _Config(), _Identity(), _Anisette());
    expect(await controller.reuseNativeRelaySetup(_Config(),
      prepareReuse: () async => prepared), isTrue);
    expect(controller.connection, same(prepared.$1));
    expect(controller.cachedState, same(prepared.$2));
    expect(controller.config, same(prepared.$3));
    expect(controller.identity, same(prepared.$4));
    expect(controller.anisette, same(prepared.$5));
    expect(controller.currentPhoneUsers[1], same(phone));
    expect(phone.isDisposed, isFalse);
    expect(controller.restoredConfigNeedsFreshIdentity, isFalse);
    expect(connection.disposeCount, 1);
    expect(provider.disposeCount, 1);
    expect(state.isDisposed, isTrue);
    expect(identity.isDisposed, isTrue);
    expect(config.isDisposed, isTrue);
  });

  test('relay restoration failure does not clear the existing resources', () async {
    final controller = SetupViewController();
    final connection = _Connection();
    final config = _Config();
    controller.connection = connection;
    controller.config = config;
    await expectLater(controller.reuseNativeRelaySetup(_Config(),
      prepareReuse: () async => throw AnyhowException('synthetic push failure')),
      throwsA(isA<AnyhowException>()));
    expect(controller.connection, same(connection));
    expect(controller.config, same(config));
    expect(connection.disposeCount, 0);
    expect(config.isDisposed, isFalse);
  });

  test('stale relay replacement disposes only its candidate resources', () async {
    final controller = SetupViewController();
    final old = _Connection();
    controller.connection = old;
    final newer = _Connection();
    final newerConfig = _Config();
    final prepared = (_Connection(), _PushState(), _Config(), _Identity(), _Anisette());
    await expectLater(controller.reuseNativeRelaySetup(_Config(),
      prepareReuse: () async {
        controller.connection = newer;
        controller.config = newerConfig;
        return prepared;
      }), throwsA(isA<AnyhowException>()));
    expect(controller.connection, same(newer));
    expect(controller.config, same(newerConfig));
    expect(newer.disposeCount, 0);
    expect(old.disposeCount, 0);
    expect(prepared.$1.disposeCount, 1);
    expect(prepared.$2.isDisposed, isTrue);
    expect(prepared.$3.isDisposed, isTrue);
    expect(prepared.$4.isDisposed, isTrue);
    expect(prepared.$5.disposeCount, 1);
  });

  test('saved hardware decode failure keeps the documented fresh-identity recovery', () async {
    final controller = SetupViewController();
    final config = _Config();
    final push = _PushState();
    var setupCalled = false;

    await controller.restoreSavedHardware(
      _SavedHardware(identity: Uint8List.fromList([1]), osConfig: config, push: push),
      decodeIdentity: (_) => throw StateError('synthetic decode failure'),
      setupConnectionOverride: () async => setupCalled = true,
    );

    expect(setupCalled, isFalse);
    expect(controller.config, same(config));
    expect(controller.identity, isNull);
    expect(controller.cachedState, isNull);
    expect(controller.restoredConfigNeedsFreshIdentity, isTrue);
    expect(controller.error, contains('Saved device credentials could not be restored'));
  });

  test('saved hardware transient push failure preserves decoded restore state', () async {
    final controller = SetupViewController();
    final config = _Config();
    final push = _PushState();
    final identity = _Identity();

    await controller.restoreSavedHardware(
      _SavedHardware(identity: Uint8List.fromList([1]), osConfig: config, push: push),
      decodeIdentity: (_) => identity,
      setupConnectionOverride: () async => throw AnyhowException('synthetic push failure'),
    );

    expect(controller.config, same(config));
    expect(controller.identity, same(identity));
    expect(controller.cachedState, same(push));
    expect(controller.restoredConfigNeedsFreshIdentity, isFalse);
    expect(controller.error, contains('Saved device details were kept'));
    expect(controller.error, isNot(contains('synthetic push failure')));
  });

  test('saved hardware transient provider failure preserves decoded restore state', () async {
    final controller = SetupViewController();
    final config = _Config();
    final push = _PushState();
    final identity = _Identity();

    await controller.restoreSavedHardware(
      _SavedHardware(identity: Uint8List.fromList([1]), osConfig: config, push: push),
      decodeIdentity: (_) => identity,
      setupConnectionOverride: () async => throw StateError('synthetic provider failure'),
    );

    expect(controller.config, same(config));
    expect(controller.identity, same(identity));
    expect(controller.cachedState, same(push));
    expect(controller.restoredConfigNeedsFreshIdentity, isFalse);
    expect(controller.error, contains('Saved device details were kept'));
    expect(controller.error, isNot(contains('synthetic provider failure')));
  });

  test('saved hardware restore success keeps the decoded state and marks it reusable', () async {
    final controller = SetupViewController();
    final config = _Config();
    final push = _PushState();
    final identity = _Identity();
    final connection = _Connection();

    await controller.restoreSavedHardware(
      _SavedHardware(identity: Uint8List.fromList([1]), osConfig: config, push: push),
      decodeIdentity: (_) => identity,
      setupConnectionOverride: () async => controller.connection = connection,
    );

    expect(controller.config, same(config));
    expect(controller.identity, same(identity));
    expect(controller.cachedState, same(push));
    expect(controller.connection, same(connection));
    expect(controller.restoredConfigNeedsFreshIdentity, isFalse);
  });

  test('cached phone validation is untouched when no push connection is available', () async {
    final controller = SetupViewController();
    var restored = false;
    final saved = {'sms-auth-1': 'saved-user'};

    await controller.restoreCachedPhoneUsers(
      cachedCodes: saved.entries,
      restoreAndValidate: (_, __) async => restored = true,
    );

    expect(restored, isFalse);
    expect(saved, {'sms-auth-1': 'saved-user'});
  });

  test('temporary phone validation failure keeps saved verification for retry', () async {
    final controller = SetupViewController();
    controller.connection = _Connection();
    final saved = {'sms-auth-1': 'saved-user', 'other': 'unrelated'};
    var attempts = 0;
    await controller.restoreCachedPhoneUsers(
      cachedCodes: saved.entries,
      restoreAndValidate: (_, __) async {
        attempts++;
        throw AnyhowException('synthetic network failure');
      },
    );
    expect(attempts, 1);
    expect(saved, {'sms-auth-1': 'saved-user', 'other': 'unrelated'});
    expect(controller.currentPhoneUsers, isEmpty);
    expect(controller.phoneValidating.value, isFalse);
  });

  test('native identity failure stops before preparing or publishing resources', () async {
    final controller = SetupViewController();
    var prepared = false;
    await expectLater(controller.setupConnection(
      createPush: () async => throw AnyhowException('synthetic preserved-key failure'),
      prepareAnisette: (_) async { prepared = true; return _Anisette(); },
    ), throwsA(isA<AnyhowException>()));
    expect(prepared, isFalse);
    expect(controller.connection, isNull);
    expect(controller.anisette, isNull);
  });

  test('push failure is surfaced and rejected handles are released', () async {
    final controller = SetupViewController();
    final connection = _Connection();
    final error = _PushError();
    var prepared = false;
    await expectLater(controller.setupConnection(
      createPush: () async => (connection, error),
      prepareAnisette: (_) async { prepared = true; return _Anisette(); },
    ), throwsA(isA<AnyhowException>().having((e) => e.message, 'safe message', contains('Apple Push'))));
    expect(prepared, isFalse);
    expect(connection.disposeCount, 1);
    expect(error.disposeCount, 1);
    expect(controller.connection, isNull);
  });

  test('provider failure releases candidate without disposing previous provider', () async {
    final controller = SetupViewController();
    final prior = _Anisette();
    controller.anisette = prior;
    final connection = _Connection();
    await expectLater(controller.setupConnection(
      createPush: () async => (connection, null),
      prepareAnisette: (_) async => throw StateError('synthetic provider failure'),
    ), throwsStateError);
    expect(connection.disposeCount, 1);
    expect(controller.connection, isNull);
    expect(controller.anisette, same(prior));
    expect(prior.disposeCount, 0);
  });

  test('retry publishes only the ready candidate and releases old provider once', () async {
    final controller = SetupViewController();
    final prior = _Anisette();
    controller.anisette = prior;
    final connection = _Connection();
    final next = _Anisette();
    await controller.setupConnection(
      createPush: () async => (connection, null),
      prepareAnisette: (candidate) async {
        expect(candidate, same(connection));
        expect(controller.connection, isNull);
        expect(controller.anisette, same(prior));
        return next;
      },
    );
    expect(controller.connection, same(connection));
    expect(controller.anisette, same(next));
    expect(prior.disposeCount, 1);
    expect(connection.disposeCount, 0);
    expect(next.disposeCount, 0);
  });

  test('phone registration refresh without a connection fails before opening a candidate', () async {
    final controller = SetupViewController();
    var opened = false;
    await expectLater(controller.refreshPhoneRegistrationConnection(
      createPush: () async {
        opened = true;
        return (_Connection(), null);
      },
    ), throwsA(isA<AnyhowException>()));
    expect(opened, isFalse);
    expect(controller.connection, isNull);
  });

  test('phone registration refresh push failure keeps the old connection usable', () async {
    final controller = SetupViewController();
    final oldConnection = _Connection();
    final oldAnisette = _Anisette();
    controller.connection = oldConnection;
    controller.anisette = oldAnisette;
    final candidate = _Connection();
    final error = _PushError();

    await expectLater(controller.refreshPhoneRegistrationConnection(
      createPush: () async => (candidate, error),
      prepareAnisette: (_) async => throw StateError('must not prepare a failed push candidate'),
    ), throwsA(isA<AnyhowException>()));

    expect(controller.connection, same(oldConnection));
    expect(controller.anisette, same(oldAnisette));
    expect(oldConnection.disposeCount, 0);
    expect(oldAnisette.disposeCount, 0);
    expect(candidate.disposeCount, 1);
    expect(error.disposeCount, 1);
  });

  test('phone registration refresh provider failure keeps the old connection usable', () async {
    final controller = SetupViewController();
    final oldConnection = _Connection();
    final oldAnisette = _Anisette();
    controller.connection = oldConnection;
    controller.anisette = oldAnisette;
    final candidate = _Connection();
    final previousState = _PushState();
    final candidateState = _PushState();
    controller.cachedState = previousState;

    await expectLater(controller.refreshPhoneRegistrationConnection(
      createPush: () async => (candidate, null),
      captureState: (_) async => candidateState,
      prepareAnisette: (_) async => throw StateError('synthetic provider failure'),
    ), throwsStateError);

    expect(controller.connection, same(oldConnection));
    expect(controller.anisette, same(oldAnisette));
    expect(controller.cachedState, same(previousState));
    expect(candidateState.isDisposed, isTrue);
    expect(previousState.isDisposed, isFalse);
    expect(oldConnection.disposeCount, 0);
    expect(oldAnisette.disposeCount, 0);
    expect(candidate.disposeCount, 1);
  });

  test('phone registration refresh swaps and releases the old resources exactly once', () async {
    final controller = SetupViewController();
    final oldConnection = _Connection();
    final oldAnisette = _Anisette();
    controller.connection = oldConnection;
    controller.anisette = oldAnisette;
    final candidate = _Connection();
    final nextAnisette = _Anisette();
    final oldState = _PushState();
    final freshState = _PushState();
    controller.cachedState = oldState;

    await controller.refreshPhoneRegistrationConnection(
      createPush: () async => (candidate, null),
      captureState: (prepared) async {
        expect(prepared, same(candidate));
        expect(controller.cachedState, same(oldState));
        return freshState;
      },
      prepareAnisette: (prepared) async {
        expect(prepared, same(candidate));
        expect(controller.connection, same(oldConnection));
        expect(controller.anisette, same(oldAnisette));
        return nextAnisette;
      },
    );

    expect(controller.connection, same(candidate));
    expect(controller.cachedState, same(freshState));
    expect(freshState.isDisposed, isFalse);
    expect(controller.anisette, same(nextAnisette));
    expect(oldConnection.disposeCount, 1);
    expect(oldAnisette.disposeCount, 1);
    expect(candidate.disposeCount, 0);
    expect(nextAnisette.disposeCount, 0);
  });

  test('retry snapshot failure preserves previous state and skips provider preparation', () async {
    final controller = SetupViewController();
    final previous = _Connection();
    final previousState = _PushState();
    final candidate = _Connection();
    controller.connection = previous;
    controller.cachedState = previousState;
    var prepared = false;
    await expectLater(controller.refreshPhoneRegistrationConnection(
      createPush: () async => (candidate, null),
      captureState: (_) async => throw AnyhowException('synthetic snapshot failure'),
      prepareAnisette: (_) async { prepared = true; return _Anisette(); },
    ), throwsA(isA<AnyhowException>()));
    expect(prepared, isFalse);
    expect(controller.connection, same(previous));
    expect(controller.cachedState, same(previousState));
    expect(previous.disposeCount, 0);
    expect(previousState.isDisposed, isFalse);
    expect(candidate.disposeCount, 1);
  });

  test('stale snapshot cannot publish cached state or start provider preparation', () async {
    final controller = SetupViewController();
    final previous = _Connection();
    final newer = _Connection();
    final newerState = _PushState();
    final candidate = _Connection();
    final candidateState = _PushState();
    controller.connection = previous;
    var prepared = false;
    await expectLater(controller.refreshPhoneRegistrationConnection(
      createPush: () async => (candidate, null),
      captureState: (_) async {
        controller.connection = newer;
        controller.cachedState = newerState;
        return candidateState;
      },
      prepareAnisette: (_) async { prepared = true; return _Anisette(); },
    ), throwsA(isA<AnyhowException>()));
    expect(prepared, isFalse);
    expect(controller.connection, same(newer));
    expect(controller.cachedState, same(newerState));
    expect(newerState.isDisposed, isFalse);
    expect(candidateState.isDisposed, isTrue);
    expect(candidate.disposeCount, 1);
    expect(previous.disposeCount, 0);
    expect(newer.disposeCount, 0);
  });

  test('stale phone registration refresh completion is not published', () async {
    final controller = SetupViewController();
    final oldConnection = _Connection();
    final oldAnisette = _Anisette();
    controller.connection = oldConnection;
    controller.anisette = oldAnisette;
    final candidate = _Connection();
    final nextAnisette = _Anisette();
    final preparationStarted = Completer<void>();
    final finishPreparation = Completer<ArcAnisetteClientDefaultAnisetteProvider>();

    final refresh = controller.refreshPhoneRegistrationConnection(
      createPush: () async => (candidate, null),
      prepareAnisette: (_) async {
        preparationStarted.complete();
        return finishPreparation.future;
      },
    );
    await preparationStarted.future;

    final newerConnection = _Connection();
    final newerAnisette = _Anisette();
    controller.connection = newerConnection;
    controller.anisette = newerAnisette;
    finishPreparation.complete(nextAnisette);
    await expectLater(refresh, throwsA(isA<AnyhowException>()));

    expect(controller.connection, same(newerConnection));
    expect(controller.anisette, same(newerAnisette));
    expect(candidate.disposeCount, 1);
    expect(nextAnisette.disposeCount, 1);
    expect(oldConnection.disposeCount, 0);
    expect(oldAnisette.disposeCount, 0);
    expect(newerConnection.disposeCount, 0);
    expect(newerAnisette.disposeCount, 0);
  });

  test('stale phone registration refresh is rejected before provider preparation', () async {
    final controller = SetupViewController();
    final oldConnection = _Connection();
    final oldAnisette = _Anisette();
    controller.connection = oldConnection;
    controller.anisette = oldAnisette;
    final candidate = _Connection();
    final newerConnection = _Connection();
    final newerAnisette = _Anisette();
    var prepared = false;

    await expectLater(controller.refreshPhoneRegistrationConnection(
      createPush: () async {
        controller.connection = newerConnection;
        controller.anisette = newerAnisette;
        return (candidate, null);
      },
      prepareAnisette: (_) async {
        prepared = true;
        return _Anisette();
      },
    ), throwsA(isA<AnyhowException>()));

    expect(prepared, isFalse);
    expect(controller.connection, same(newerConnection));
    expect(controller.anisette, same(newerAnisette));
    expect(candidate.disposeCount, 1);
    expect(oldConnection.disposeCount, 0);
    expect(oldAnisette.disposeCount, 0);
    expect(newerConnection.disposeCount, 0);
    expect(newerAnisette.disposeCount, 0);
  });
}
