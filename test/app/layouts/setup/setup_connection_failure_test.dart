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

void main() {
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
}
