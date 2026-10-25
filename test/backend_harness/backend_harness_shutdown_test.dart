import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'windows_backend_live_host_test.dart'
    show WindowsBackendHostFiles, shutdownWindowsBackendHost,
        requireWindowsBackendNativeSendCompletion;

Map<String, Object?> request(
  String id,
  String action, [
  Map<String, Object?> arguments = const {},
]) => {
  'protocol': 1,
  'requestId': id,
  'action': action,
  'arguments': arguments,
};

BackendHarnessEngine runner(Map<String, BackendHarnessOperation> operations) =>
    BackendHarnessEngine(
      enabled: true,
      source: List.filled(40, 'a').join(),
      package: 'com.bluebubbles.cloudsync.testhost',
      platform: 'windows',
      operations: operations,
    );

void main() {
  test(
    'shutdown retains an entered foreground call and refuses later handlers',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      var calls = 0;
      final engine = runner({
        'status': BackendHarnessOperation(
          validate: (args) => args.isEmpty,
          handler: (_) {
            calls++;
            return completion.future;
          },
        ),
      });
      final entered = engine.execute(request('first', 'status'));
      var drained = false;
      final drain = engine.closeAdmissionAndDrain()
        ..then((_) => drained = true);
      expect(identical(drain, engine.closeAdmissionAndDrain()), isTrue);
      expect(
        (await engine.execute(request('later', 'status')))['code'],
        'backend_busy',
      );
      expect((await engine.execute(request('observe', 'hello')))['ok'], isTrue);
      expect(calls, 1);
      expect(drained, isFalse);
      completion.complete(const BackendHarnessPayload());
      expect((await entered)['ok'], isTrue);
      await drain;
      expect(drained, isTrue);
    },
  );

  test(
    'shutdown retains accepted background work and its terminal receipt',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      var calls = 0;
      final engine = runner({
        'fixture.send': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: (_) {
            calls++;
            return completion.future;
          },
        ),
      });
      final accepted = await engine.execute(
        request('original', 'fixture.send'),
      );
      var drained = false;
      final drain = engine.closeAdmissionAndDrain()
        ..then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(drained, isFalse);
      expect(
        (await engine.execute(request('replacement', 'fixture.send')))['code'],
        'backend_busy',
      );
      completion.complete(
        const BackendHarnessPayload(flags: {'setup_finished': true}),
      );
      await drain;
      final receipt = await engine.execute(
        request('receipt', 'job.status', {'jobId': accepted['jobId']}),
      );
      expect(receipt['state'], 'completed');
      expect(
        ((receipt['data'] as Map)['flags'] as Map)['setup_finished'],
        isTrue,
      );
      expect(engine.hasUncertainJobs, isFalse);
      expect(calls, 1);
    },
  );

  test(
    'drained failure retains uncertainty instead of proving release is safe',
    () async {
      final engine = runner({
        'fixture.send': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (args) => args.isEmpty,
          handler: (_) async => throw StateError('synthetic_unknown_outcome'),
        ),
      });
      final accepted = await engine.execute(
        request('original', 'fixture.send'),
      );
      await engine.closeAdmissionAndDrain();
      expect(engine.hasUncertainJobs, isTrue);
      final receipt = await engine.execute(
        request('receipt', 'job.status', {'jobId': accepted['jobId']}),
      );
      expect(receipt['state'], 'failed');
      expect(
        ((receipt['data'] as Map)['flags'] as Map)['outcome_uncertain'],
        isTrue,
      );
    },
  );

  const fixtureId = '01234567-89AB-4DEF-8123-456789ABCDEF';
  const recoveryOwner = '11234567-89ab-4def-8123-456789abcdef';
  final correlation = <String, Object?>{
    'fixtureId': fixtureId,
    'retainedRecoveryOwner': recoveryOwner,
    'body': 'never persist this body',
    'recipients': ['private-recipient'],
  };

  test(
    'recovery snapshot requires closed admission and a completed drain',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      final engine = runner({
        'fixture.send': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (_) => true,
          handler: (_) => completion.future,
        ),
      });
      expect(engine.drainedRecoverySnapshot, throwsStateError);
      await engine.execute(request('original', 'fixture.send', correlation));
      final drain = engine.closeAdmissionAndDrain();
      expect(engine.drainedRecoverySnapshot, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      completion.completeError(StateError('synthetic outcome unknown'));
      await drain;
      final snapshot = engine.drainedRecoverySnapshot();
      expect(snapshot['sessionId'], engine.sessionId);
      final job = (snapshot['jobs'] as List).single as Map;
      (job['flags'] as Map)['outcome_uncertain'] = false;
      expect(engine.hasUncertainJobs, true);
      expect(
        ((engine.drainedRecoverySnapshot()['jobs'] as List).single
            as Map)['flags'],
        containsPair('outcome_uncertain', true),
      );
    },
  );

  test(
    'recovery omits credentials, challenges and arbitrary original arguments',
    () async {
      final engine = runner({
        'auth.login': BackendHarnessOperation(
          background: true,
          uncertainOnFailure: true,
          validate: (_) => true,
          handler: (_) async => throw StateError('private-password'),
        ),
      });
      await engine.execute(
        request('original', 'auth.login', {
          'password': 'private-password',
          'account': 'private-account',
        }),
      );
      await engine.closeAdmissionAndDrain();
      final saved = jsonEncode(engine.drainedRecoverySnapshot());
      expect(saved, isNot(contains('private-password')));
      expect(saved, isNot(contains('private-account')));
      expect(saved, isNot(contains('arguments')));
      expect(saved, isNot(contains('challenge')));
      expect(saved, contains('auth.login'));
    },
  );

  group('retained Windows shutdown handoff', () {
    late Directory directory;
    late Directory selected;
    late WindowsBackendHostFiles files;
    final launch = 'a' * 32;
    final source = 'a' * 40;
    File control(String suffix) =>
        File('${directory.path}/backend-host-$launch.$suffix');
    setUp(() {
      directory = Directory.systemTemp.createTempSync('backend-shutdown-');
      selected = directory;
      files = WindowsBackendHostFiles(() => selected, launch);
      files.publishReady(
        Uri.parse('ws://127.0.0.1:1234/private-vm-token/ws'),
        source,
        42,
      );
    });
    tearDown(() => directory.deleteSync(recursive: true));

    Future<void> close(
      BackendHarnessEngine engine,
      Future<void> Function() native, {
      String owner = recoveryOwner,
    }) => shutdownWindowsBackendHost(
      engine: engine,
      files: files,
      source: source,
      ownerPid: 42,
      recoveryOwner: owner,
      pause: () {},
      closeNative: native,
    );
    BackendHarnessEngine failing() => runner({
      'fixture.send': BackendHarnessOperation(
        background: true,
        uncertainOnFailure: true,
        validate: (_) => true,
        handler: (_) async => throw StateError('unknown IDS result'),
      ),
    });

    test(
      'pending work blocks handoff and native close; failed terminal outcome survives both',
      () async {
        final operation = Completer<BackendHarnessPayload>();
        final native = Completer<void>();
        var calls = 0;
        var closing = false;
        final engine = runner({
          'fixture.send': BackendHarnessOperation(
            background: true,
            uncertainOnFailure: true,
            validate: (_) => true,
            handler: (_) {
              calls++;
              return operation.future;
            },
          ),
        });
        final accepted = await engine.execute(
          request('original', 'fixture.send', correlation),
        );
        final shutdown = close(engine, () async {
          closing = true;
          final saved =
              jsonDecode(control('recovery.json').readAsStringSync()) as Map;
          expect(saved['source'], source);
          expect(saved['launchId'], launch);
          expect(saved['sessionId'], engine.sessionId);
          expect(saved['recoveryOwner'], recoveryOwner);
          expect(saved['outcome_uncertain'], true);
          final job = (saved['recovery']['jobs'] as List).single as Map;
          expect(job['jobId'], accepted['jobId']);
          expect(job['requestId'], 'original');
          expect(job['action'], 'fixture.send');
          expect(job['state'], 'failed');
          expect(job['flags']['outcome_uncertain'], true);
          expect(job['correlation'], {
            'fixtureId': fixtureId,
            'retainedRecoveryOwner': recoveryOwner,
          });
          expect(jsonEncode(saved), isNot(contains('private-vm-token')));
          expect(jsonEncode(saved), isNot(contains('never persist this body')));
          expect(jsonEncode(saved), isNot(contains('private-recipient')));
          await native.future;
          files.publishClosed(source, 42);
        });
        await Future<void>.delayed(Duration.zero);
        expect(calls, 1);
        expect(closing, false);
        expect(control('recovery.json').existsSync(), false);
        operation.completeError(StateError('resource or registration failure'));
        await Future<void>.delayed(Duration.zero);
        expect(closing, true);
        expect(control('closed.json').existsSync(), false);
        final before = control('recovery.json').readAsBytesSync();
        for (final id in ['original', 'replacement']) {
          expect(
            (await engine.execute(
              request(id, 'fixture.send', correlation),
            ))['code'],
            'backend_busy',
          );
        }
        expect(calls, 1);
        native.complete();
        await shutdown;
        expect(control('closed.json').existsSync(), true);
        expect(control('recovery.json').readAsBytesSync(), before);
        expect(engine.hasUncertainJobs, true);
        final receipt = await engine.execute(
          request('observation', 'job.status', {'jobId': accepted['jobId']}),
        );
        expect((receipt['data'] as Map)['flags']['outcome_uncertain'], true);
      },
    );

    test(
      'exclusive save failure preserves hold without native or successful close',
      () async {
        final engine = failing();
        await engine.execute(request('original', 'fixture.send', correlation));
        control(
          'recovery.json',
        ).writeAsStringSync('corrupted existing handoff', flush: true);
        var nativeCalls = 0;
        await expectLater(
          close(engine, () async {
            nativeCalls++;
            files.publishClosed(source, 42);
          }),
          throwsA(isA<FileSystemException>()),
        );
        expect(nativeCalls, 0);
        expect(
          control('recovery.json').readAsStringSync(),
          'corrupted existing handoff',
        );
        expect(control('closed.json').existsSync(), false);
        expect(control('json').existsSync(), true);
        expect(engine.hasUncertainJobs, true);
      },
    );

    test(
      'native close failure retains durable uncertainty and no closed claim',
      () async {
        final engine = failing();
        await engine.execute(request('original', 'fixture.send', correlation));
        await expectLater(
          close(engine, () async => throw StateError('native still active')),
          throwsStateError,
        );
        expect(control('recovery.json').existsSync(), true);
        expect(control('closed.json').existsSync(), false);
        expect(control('json').existsSync(), true);
        expect(engine.hasUncertainJobs, true);
      },
    );

    test(
      'current-service pending native send retains ownership despite terminal job',
      () async {
        final store = await openStore(
          directory: '${directory.path}/synthetic-store',
        );
        try {
          final engine = failing();
          await engine.execute(
            request('original', 'fixture.send', correlation),
          );
          final message = Message(
            guid: fixtureId,
            isFromMe: true,
            sendingServiceId: 'current',
          );
          store.box<Message>().put(message);
          var nativeCalls = 0;
          await expectLater(
            close(engine, () async {
              requireWindowsBackendNativeSendCompletion(
                engine,
                store,
                'current',
              );
              nativeCalls++;
              files.publishClosed(source, 42);
            }),
            throwsStateError,
          );
          expect(nativeCalls, 0);
          expect(control('recovery.json').existsSync(), true);
          expect(control('closed.json').existsSync(), false);
          expect(
            store.box<Message>().get(message.id!)!.sendingServiceId,
            'current',
          );
          // Only the ordinary SendConfirm path may clear this in production.
          // Emulate its terminal observation in the disposable store.
          message.sendingServiceId = null;
          store.box<Message>().put(message);
          expect(
            () => requireWindowsBackendNativeSendCompletion(
              engine,
              store,
              'current',
            ),
            returnsNormally,
          );
        } finally {
          store.close();
        }
      },
    );

    test(
      'unknown mutation completion cannot be replaced by a persisted handoff',
      () async {
        final store = await openStore(
          directory: '${directory.path}/synthetic-store',
        );
        try {
          final engine = runner({
            'fixture.edit': BackendHarnessOperation(
              background: true,
              uncertainOnFailure: true,
              validate: (_) => true,
              handler: (_) async => throw StateError('unknown mutation'),
            ),
          });
          await engine.execute(
            request('original', 'fixture.edit', {
              ...correlation,
              'messageGuid': '21234567-89AB-4DEF-8123-456789ABCDEF',
            }),
          );
          await expectLater(
            close(engine, () async {
              requireWindowsBackendNativeSendCompletion(
                engine,
                store,
                'current',
              );
              files.publishClosed(source, 42);
            }),
            throwsStateError,
          );
          expect(control('recovery.json').existsSync(), true);
          expect(control('closed.json').existsSync(), false);
        } finally {
          store.close();
        }
      },
    );

    test(
      'changed handoff is refused before publishing successful close',
      () async {
        final engine = failing();
        await engine.execute(request('original', 'fixture.send', correlation));
        await expectLater(
          close(engine, () async {
            control('recovery.json').writeAsStringSync('{}', flush: true);
            files.publishClosed(source, 42);
          }),
          throwsStateError,
        );
        expect(control('closed.json').existsSync(), false);
        expect(control('json').existsSync(), true);
      },
    );

    for (final fault in ['owner', 'source', 'root', 'correlation']) {
      test('handoff refuses changed $fault before native close', () async {
        final engine = failing();
        await engine.execute(
          request(
            'original',
            'fixture.send',
            fault == 'correlation' ? {'fixtureId': 'invalid'} : correlation,
          ),
        );
        if (fault == 'source') {
          final ready = jsonDecode(control('json').readAsStringSync()) as Map;
          ready['source'] = 'b' * 40;
          control('json').writeAsStringSync(jsonEncode(ready));
        }
        if (fault == 'root') {
          final other = Directory('${directory.path}/other')..createSync();
          selected = other;
        }
        var nativeCalls = 0;
        await expectLater(
          close(
            engine,
            () async {
              nativeCalls++;
            },
            owner: fault == 'owner'
                ? '21234567-89ab-4def-8123-456789abcdef'
                : recoveryOwner,
          ),
          throwsStateError,
        );
        expect(nativeCalls, 0);
        expect(control('closed.json').existsSync(), false);
        expect(engine.hasUncertainJobs, true);
      });
    }

    test(
      'ordinary successful drained shutdown needs no handoff or recovery owner',
      () async {
        final engine = runner({
          'status': BackendHarnessOperation(
            validate: (_) => true,
            handler: (_) async => const BackendHarnessPayload(),
          ),
        });
        await engine.execute(request('ordinary', 'status'));
        var nativeCalls = 0;
        await close(engine, () async {
          nativeCalls++;
          files.publishClosed(source, 42);
        }, owner: '');
        expect(nativeCalls, 1);
        expect(control('recovery.json').existsSync(), false);
        expect(control('closed.json').existsSync(), true);
        expect(engine.drainedRecoverySnapshot()['jobs'], isEmpty);
      },
    );
  });
}
