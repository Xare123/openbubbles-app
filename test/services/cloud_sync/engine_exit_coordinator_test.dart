import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/services/backend/lifecycle/engine_exit_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Completer<void> work;
  late EngineExitCoordinator coordinator;
  late bool detachedAndIdle;
  late int drains;
  late int resumes;
  late int releases;
  late List<Object> errors;

  setUp(() {
    work = Completer<void>();
    detachedAndIdle = true;
    drains = resumes = releases = 0;
    errors = [];
    coordinator = EngineExitCoordinator(
      canExit: () => detachedAndIdle,
      drain: () {
        drains++;
        return work.future;
      },
      resumeAdmission: () {
        resumes++;
      },
      releaseEngine: () async {
        releases++;
      },
      onError: errors.add,
    );
  });

  test(
    'simultaneous exits share one actual drain and native release',
    () async {
      final first = coordinator.request();
      final second = coordinator.request();
      expect(identical(first, second), isTrue);
      expect(drains, 1);
      expect(releases, 0);
      work.complete();
      await Future.wait([first, second]);
      expect(releases, 1);
      expect(errors, isEmpty);
    },
  );

  test('attached or queued work does not close admission', () async {
    detachedAndIdle = false;
    await coordinator.request();
    expect(drains, 0);
    expect(releases, 0);
  });

  test(
    'a direct mutation retains its receipt tail before lock admission closes',
    () async {
      final receipt = Completer<void>();
      final mutation = coordinator.retain(() => receipt.future);
      final exit = coordinator.request();
      await Future<void>.delayed(Duration.zero);
      expect(drains, 0);
      expect(releases, 0);
      await expectLater(
        coordinator.retain(() async {}),
        throwsA(isA<CloudKitOperationInterlockException>()),
      );
      receipt.complete();
      await mutation;
      await Future<void>.delayed(Duration.zero);
      expect(drains, 1);
      work.complete();
      await exit;
      expect(releases, 1);
    },
  );

  test(
    'failed mutation still allows a safe drain after its tail ends',
    () async {
      final receipt = Completer<void>();
      final mutation = coordinator.retain(() => receipt.future);
      final failed = expectLater(mutation, throwsStateError);
      final exit = coordinator.request();
      receipt.completeError(StateError('test receipt failed'));
      await failed;
      work.complete();
      await exit;
      expect(releases, 1);
    },
  );

  test('resume invalidates an old drain, no late native release', () async {
    final exit = coordinator.request();
    detachedAndIdle = false;
    coordinator.cancel();
    work.complete();
    await exit;
    expect(resumes, 1);
    expect(releases, 0);
  });

  test('queue activity is checked again after the drain', () async {
    final exit = coordinator.request();
    detachedAndIdle = false;
    work.complete();
    await exit;
    expect(releases, 0);
  });

  test('redetach after resume takes a fresh barrier', () async {
    final exit = coordinator.request();
    coordinator.cancel();
    final laterWork = Completer<void>();
    final oldWork = work;
    work = laterWork;
    oldWork.complete();
    await exit;
    expect(drains, 2);
    expect(releases, 0);
    laterWork.complete();
    await coordinator.request();
    expect(releases, 1);
  });

  test(
    'drain failure retains the engine without retrying or releasing',
    () async {
      final exit = coordinator.request();
      work.completeError(StateError('synthetic failure'));
      await exit;
      expect(errors, hasLength(1));
      expect(releases, 0);
      expect(drains, 1);
    },
  );

  test('stalled diagnostic never authorizes release of pending work', () async {
    final stalled = Completer<void>();
    final exit = EngineExitCoordinator(
      canExit: () => true,
      drain: () => work.future,
      resumeAdmission: () {},
      releaseEngine: () async {
        releases++;
      },
      onError: errors.add,
      onStalled: stalled.complete,
      stallAfter: Duration.zero,
    ).request();
    await stalled.future;
    expect(releases, 0);
    work.complete();
    await exit;
    expect(releases, 1);
    expect(errors, isEmpty);
  });

  test('native host and both Dart exit paths use the same real drain', () {
    final lifecycle = File(
      'lib/services/backend/lifecycle/lifecycle_service.dart',
    ).readAsStringSync();
    final queue = File(
      'lib/services/backend/queue/queue_impl.dart',
    ).readAsStringSync();
    final channel = File(
      'lib/services/backend/java_dart_interop/method_channel_service.dart',
    ).readAsStringSync();
    final host = File(
      'android/app/src/main/kotlin/com/bluebubbles/messaging/MainActivity.kt',
    ).readAsStringSync();
    expect(
      lifecycle,
      contains('drain: CloudKitOperationInterlock.drainForEngineExit'),
    );
    expect(lifecycle, contains('_nativeHostDetached &&'));
    expect(
      lifecycle,
      contains('if (!isUiThread || _nativeHostDetached) return'),
    );
    expect(queue, contains('ls.requestEngineExit()'));
    expect(queue, isNot(contains('"engine-done"')));
    expect(channel, contains("case 'engine-host-detached':"));
    expect(host, contains('CloudKitOwnedFlutterFragment().apply'));
    expect(
      host,
      contains('override fun shouldDestroyEngineWithHost(): Boolean = false'),
    );
    expect(
      host,
      contains('DartWorker.retireMainEngineWhenIdle(flutterEngine)'),
    );
    expect(host, contains('if (call.method == "ready" && hostDetached)'));
  });
}
