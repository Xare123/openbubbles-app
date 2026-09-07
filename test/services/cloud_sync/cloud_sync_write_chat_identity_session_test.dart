import 'dart:async';
import 'dart:io';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_semantic_pull_sampler.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_write_chat_identity_session.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/in_memory_cloud_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late CloudKitOperationInterlock interlock;
  late _Pause pause;
  late List<String> events;
  late CloudSyncWriteChatIdentitySession session;
  var valid = true;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('chat-write-session-');
    interlock = CloudKitOperationInterlock(
      privateStorageDirectory: directory.path,
      fenceStore: InMemoryCloudSyncStore(),
    );
    events = [];
    pause = _Pause(events);
    valid = true;
    session = CloudSyncWriteChatIdentitySession(
      exclusion: interlock,
      nativePause: pause,
      validate: () async {
        events.add('validate');
        if (!valid) throw StateError('identity changed');
      },
      ensureReadAuthentication: () async {
        expect(pause.active, isFalse);
        events.add('ensure');
      },
      warmReadAuthentication: (token) async {
        expect(token, BigInt.one);
        expect(pause.active, isTrue);
        events.add('warm');
      },
    );
  });
  tearDown(() async {
    await CloudKitOperationInterlock.debugResetPoisonedLocksForTesting();
    directory.deleteSync(recursive: true);
  });

  Future<T> run<T>(Future<T> Function(BigInt) observe) =>
      interlock.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () => session.run(observe),
      );

  test(
    'ordered scoped read under writer owner releases before returning evidence',
    () async {
      final result = await run((token) async {
        expect(pause.active, isTrue);
        events.add('observe');
        return 'evidence';
      });
      expect(result, 'evidence');
      expect(pause.active, isFalse);
      expect(events, [
        'validate',
        'ensure',
        'validate',
        'pause',
        'validate',
        'warm',
        'validate',
        'observe',
        'validate',
        'resume',
        'validate',
      ]);
    },
  );

  test('no interlock never opens read authentication', () async {
    await expectLater(
      session.run((_) async => fail('observed')),
      throwsA(isA<CloudKitOperationInterlockException>()),
    );
    expect(events, isEmpty);
  });

  test('cold lookup preparation releases before stage then observes under a new pause', () async {
    await interlock.runExclusive(kind: CloudKitOperationKind.v2ReadWrite, action: () async {
      await session.run<void>((_) async {});
      expect(events, contains('warm'));
      expect(pause.active, isFalse);
      events.add('stage');
      await session.run((_) async {
        expect(pause.active, isTrue);
        events.add('observe');
      });
    });
    expect(events.where((e) => ['warm', 'resume', 'stage', 'observe'].contains(e)),
      ['warm', 'resume', 'stage', 'warm', 'observe', 'resume']);
    expect(pause.active, isFalse);
  });

  test('semantic read mode cannot nest a queued-write observation', () async {
    await expectLater(
      interlock.runExclusive(
        kind: CloudKitOperationKind.v2SemanticRead,
        action: () => session.run((_) async => fail('observed')),
      ),
      throwsA(isA<CloudKitOperationInterlockException>()),
    );
    expect(events, isEmpty);
  });

  test('changed selection before pause never observes', () async {
    valid = false;
    await expectLater(run((_) async => fail('observed')), throwsStateError);
    expect(events, ['validate']);
  });

  test('changed identity after pause releases and cannot observe', () async {
    pause.afterPause = () => valid = false;
    await expectLater(run((_) async => fail('observed')), throwsStateError);
    expect(events, contains('resume'));
    expect(events, isNot(contains('warm')));
    expect(pause.active, isFalse);
  });

  test(
    'changed identity while observing discards proof and releases',
    () async {
      await expectLater(
        run((_) async {
          valid = false;
          return 'stale';
        }),
        throwsStateError,
      );
      expect(pause.active, isFalse);
      expect(events.last, 'resume');
    },
  );

  test('changed identity while resuming discards proof', () async {
    pause.afterResume = () => valid = false;
    await expectLater(run((_) async => 'stale'), throwsStateError);
    expect(pause.active, isFalse);
  });

  test('observation exception releases without poisoning', () async {
    await expectLater(
      run((_) async => throw StateError('decode failed')),
      throwsStateError,
    );
    expect(pause.active, isFalse);
    expect(await run((_) async => 'retry'), 'retry');
  });

  test('release failure retains exclusion, never returns evidence', () async {
    pause.failResume = true;
    await expectLater(run((_) async => 'never returned'), throwsStateError);
    expect(pause.active, isTrue);
    await expectLater(
      run((_) async => fail('entered poisoned session')),
      throwsA(isA<CloudKitOperationInterlockException>()),
    );
  });

  test('ambiguous acquisition poisons rather than allowing writes', () async {
    pause.uncertain = true;
    await expectLater(
      run((_) async => fail('observed')),
      throwsA(isA<CloudSyncNativeWriterPauseUncertain>()),
    );
    expect(events, isNot(contains('warm')));
    await expectLater(
      run((_) async => fail('entered poisoned session')),
      throwsA(isA<CloudKitOperationInterlockException>()),
    );
  });

  test(
    'caught pause failure cannot reenter a writer before the outer session exits',
    () async {
      pause.uncertain = true;
      await interlock.runExclusive(
        kind: CloudKitOperationKind.v2ReadWrite,
        action: () async {
          await expectLater(
            session.run((_) async => fail('observed')),
            throwsA(isA<CloudSyncNativeWriterPauseUncertain>()),
          );
          expect(
            () => CloudKitOperationInterlock.requireActive(
              CloudKitOperationKind.v2ReadWrite,
            ),
            throwsA(isA<CloudKitOperationInterlockException>()),
          );
          await expectLater(
            interlock.runExclusive(
              kind: CloudKitOperationKind.v2ReadWrite,
              action: () async => fail('write after uncertain pause'),
            ),
            throwsA(isA<CloudKitOperationInterlockException>()),
          );
        },
      );
    },
  );

  test('invalid pause token releases before rejecting', () async {
    pause.token = BigInt.zero;
    await expectLater(run((_) async => fail('observed')), throwsStateError);
    expect(pause.active, isFalse);
    expect(events, contains('resume'));
  });

  test('awaits native observation before release', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    final running = run((_) async {
      started.complete();
      await finish.future;
    });
    await started.future;
    expect(pause.active, isTrue);
    expect(events, isNot(contains('resume')));
    finish.complete();
    await running;
    expect(pause.active, isFalse);
  });
}

final class _Pause implements CloudSyncNativeWriterPause {
  _Pause(this.events);
  final List<String> events;
  bool active = false;
  bool uncertain = false;
  bool failResume = false;
  BigInt token = BigInt.one;
  void Function()? afterPause;
  void Function()? afterResume;
  @override
  Future<Object> pause() async {
    events.add('pause');
    active = true;
    if (uncertain) throw const CloudSyncNativeWriterPauseUncertain();
    afterPause?.call();
    return token;
  }

  @override
  Future<void> resume(Object value) async {
    events.add('resume');
    expect(value, token);
    if (failResume) throw StateError('resume failed');
    active = false;
    afterResume?.call();
  }
}
