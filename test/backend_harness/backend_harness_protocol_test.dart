import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_vm_service.dart';
import 'package:flutter_test/flutter_test.dart';

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

BackendHarnessEngine engine(
  Map<String, BackendHarnessOperation> operations, {
  int maximumJobs = 128,
  String? source,
}) => BackendHarnessEngine(
  enabled: true,
  source: source ?? List.filled(40, 'a').join(),
  package: 'com.bluebubbles.messaging.backendtest',
  platform: 'android',
  operations: operations,
  maximumJobs: maximumJobs,
  random: Random(7),
);

BackendHarnessOperation operation(
  BackendHarnessHandler handler, {
  bool background = true,
}) => BackendHarnessOperation(
  handler: handler,
  validate: (_) => true,
  background: background,
);

void main() {
  test('VM routing metadata must match and cannot replace the boot session', () async {
    var calls = 0;
    final runner = engine({
      'status': operation((_) async {
        calls++;
        return const BackendHarnessPayload();
      }, background: false),
    });
    const isolate = 'isolates/synthetic';
    final hello = jsonEncode(request('routed_hello', 'hello'));
    expect((await handleBackendHarnessExtension(runner, {
      'isolateId': isolate,
      'request': hello,
    }, expectedIsolateId: isolate))['ok'], true);
    for (final parameters in [
      {'isolateId': 'isolates/foreign', 'request': hello},
      {'isolateId': isolate, 'request': hello, 'extra': 'unknown'},
      {'isolateId': isolate, 'request': jsonEncode(request('missing_session', 'status'))},
    ]) {
      expect((await handleBackendHarnessExtension(runner, parameters,
        expectedIsolateId: isolate))['code'], 'backend_invalid_request');
    }
    expect((await handleBackendHarnessExtension(runner, {
      'isolateId': isolate,
      'request': jsonEncode(request('unbound_isolate', 'hello')),
    }))['code'], 'backend_invalid_request');
    expect(calls, 0);
    expect((await handleBackendHarnessExtension(runner, {
      'isolateId': isolate,
      'sessionId': List.filled(32, '0').join(),
      'request': jsonEncode(request('stale_routed_session', 'status')),
    }, expectedIsolateId: isolate))['code'], 'backend_stale_session');
    expect(calls, 0);
    expect((await handleBackendHarnessExtension(runner, {
      'isolateId': isolate,
      'sessionId': runner.sessionId,
      'request': jsonEncode(request('valid_routed_status', 'status')),
    }, expectedIsolateId: isolate))['ok'], true);
    expect(calls, 1);
  });

  test(
    'compiled extension accepts only the single bounded request parameter',
    () async {
      final runner = engine({});
      final reply = await handleBackendHarnessExtension(runner, {
        'request': jsonEncode(request('hello1', 'hello')),
      });
      expect(reply['code'], 'backend_ready');
      for (final parameters in [
        <String, String>{},
        {'request': jsonEncode(request('hello1', 'hello')), 'extra': 'private'},
        {'request': 'account@example.com not json'},
        {'request': List.filled(65537, 'x').join()},
      ]) {
        final rejected = await handleBackendHarnessExtension(
          runner,
          parameters,
        );
        expect(rejected['code'], 'backend_invalid_request');
        expect(jsonEncode(rejected), isNot(contains('account@example.com')));
      }
    },
  );

  test('the normal test build does not register an agent extension', () {
    expect(BackendHarnessGate.compiledIn, false);
    expect(registerBackendHarnessExtension(engine({})), false);
  });

  test(
    'compiled commands reject a stale boot before any backend invocation',
    () async {
      var calls = 0;
      final runner = engine({
        'status': operation((_) async {
          calls++;
          return const BackendHarnessPayload();
        }, background: false),
      });
      final wire = jsonEncode(request('observe', 'status'));
      expect(
        (await handleBackendHarnessExtension(runner, {
          'request': wire,
        }))['code'],
        'backend_invalid_request',
      );
      expect(
        (await handleBackendHarnessExtension(runner, {
          'request': wire,
          'sessionId': List.filled(32, '0').join(),
        }))['code'],
        'backend_stale_session',
      );
      expect(calls, 0);
      expect(
        (await handleBackendHarnessExtension(runner, {
          'request': wire,
          'sessionId': runner.sessionId,
        }))['code'],
        'backend_ready',
      );
      expect(calls, 1);
    },
  );

  test('debug build and runtime identity both gate the backend app', () {
    for (final compiled in [false, true]) {
      for (final debug in [false, true]) {
        expect(
          BackendHarnessGate.allowed(
            compiled: compiled,
            debug: debug,
            platform: 'android',
            package: 'com.bluebubbles.messaging.backendtest',
          ),
          compiled && debug,
        );
      }
    }
    expect(
      BackendHarnessGate.allowed(
        compiled: true,
        debug: true,
        platform: 'android',
        package: 'com.openbubbles.messaging',
      ),
      false,
    );
    expect(
      BackendHarnessGate.allowed(
        compiled: true,
        debug: true,
        platform: 'windows',
        package: 'any',
      ),
      false,
    );
    expect(
      BackendHarnessGate.allowed(
        compiled: true,
        debug: true,
        platform: 'windows',
        package: 'any',
        isolatedWindowsProfile: true,
      ),
      true,
    );
  });

  test(
    'hello advertises only implemented handlers and an actual build stamp',
    () async {
      final runner = engine({
        'status': operation(
          (_) async => const BackendHarnessPayload(),
          background: false,
        ),
      });
      final hello = await runner.execute(request('hello1', 'hello'));
      expect(hello['code'], 'backend_ready');
      final data = hello['data']! as Map;
      expect(data['actions'], ['hello', 'job.status', 'status']);
      expect(data['source'], List.filled(40, 'a').join());
      expect(data['sessionId'], matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(
        (await runner.execute(request('missing', 'auth.login')))['code'],
        'backend_not_supported',
      );
      final unqualified = engine({}, source: 'unqualified');
      expect(
        (await unqualified.execute(request('a', 'hello')))['code'],
        'backend_source_mismatch',
      );
    },
  );

  test(
    'job acceptance is immediate; duplicate canonical inputs run once',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      var calls = 0;
      final runner = engine({
        'sync.start': operation((_) {
          calls++;
          return completion.future;
        }),
      });
      final accepted = await runner.execute(
        request('once', 'sync.start', {'b': 2, 'a': 1}),
      );
      expect(accepted['state'], 'accepted');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      final repeated = await runner.execute(
        request('once', 'sync.start', {'a': 1, 'b': 2}),
      );
      expect(repeated['jobId'], accepted['jobId']);
      expect(repeated['state'], 'running');
      expect(calls, 1);
      completion.complete(
        const BackendHarnessPayload(
          phase: BackendHarnessPhase.paused,
          counts: {'pages': 2},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final finalState = await runner.execute(
        request('poll', 'job.status', {'jobId': accepted['jobId']}),
      );
      expect(finalState['state'], 'completed');
      expect(((finalState['data']! as Map)['counts'] as Map)['pages'], 2);
      expect(calls, 1);
    },
  );

  test(
    'retargeting an accepted request cannot launch a second operation',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      var calls = 0;
      final runner = engine({
        'sync.start': operation((_) {
          calls++;
          return completion.future;
        }),
      });
      await runner.execute(request('once', 'sync.start', {'maximumPasses': 1}));
      expect(
        (await runner.execute(
          request('once', 'sync.start', {'maximumPasses': 2}),
        ))['code'],
        'backend_request_reused',
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      completion.complete(const BackendHarnessPayload());
    },
  );

  test(
    'busy admission still permits observation and explicit pause control',
    () async {
      final completion = Completer<BackendHarnessPayload>();
      var starts = 0;
      var pauses = 0;
      final runner = engine({
        'sync.start': operation((_) {
          starts++;
          return completion.future;
        }),
        'sync.pause': operation((_) async {
          pauses++;
          return const BackendHarnessPayload(
            phase: BackendHarnessPhase.pausing,
          );
        }, background: false),
      });
      final accepted = await runner.execute(request('first', 'sync.start'));
      expect(
        (await runner.execute(request('second', 'sync.start')))['code'],
        'backend_busy',
      );
      expect(
        (await runner.execute(request('pause', 'sync.pause')))['ok'],
        true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(starts, 1);
      expect(pauses, 1);
      expect(
        (await runner.execute(
          request('poll', 'job.status', {'jobId': accepted['jobId']}),
        ))['state'],
        'running',
      );
      completion.complete(const BackendHarnessPayload());
    },
  );

  test(
    'entered writer faults preserve uncertainty and never repeat the effect',
    () async {
      for (final error in [
        StateError('private writer error'),
        BackendHarnessFailure('backend_job_failed'),
      ]) {
        var effects = 0;
        final runner = engine({
          'fixture.send': BackendHarnessOperation(
            background: true,
            uncertainOnFailure: true,
            validate: (_) => true,
            handler: (_) async {
              effects++;
              throw error;
            },
          ),
        });
        final original = request('writer', 'fixture.send');
        final accepted = await runner.execute(original);
        await Future<void>.delayed(Duration.zero);
        final result = await runner.execute(
          request('poll', 'job.status', {'jobId': accepted['jobId']}),
        );
        expect((result['data'] as Map)['flags'], {
          'outcome_uncertain': true,
        });
        expect(jsonEncode(result), isNot(contains('private writer')));
        final duplicate = await runner.execute(original);
        expect(duplicate['jobId'], accepted['jobId']);
        expect((duplicate['data'] as Map)['flags'], {
          'outcome_uncertain': true,
        });
        expect(effects, 1);
      }
    },
  );

  test('typed preflight refusal is certain but remains consumed', () async {
    var calls = 0;
    final runner = engine({
      'fixture.send': BackendHarnessOperation(
        background: true,
        uncertainOnFailure: true,
        validate: (_) => true,
        handler: (_) async {
          calls++;
          throw BackendHarnessFailure('backend_not_ready', effectNotEntered: true);
        },
      ),
    });
    final original = request('preflight', 'fixture.send');
    final accepted = await runner.execute(original);
    await Future<void>.delayed(Duration.zero);
    final result = await runner.execute(
      request('preflight-poll', 'job.status', {'jobId': accepted['jobId']}),
    );
    expect(result['state'], 'blocked');
    expect(result['code'], 'backend_not_ready');
    expect((result['data'] as Map)['flags'], {'outcome_uncertain': false});
    final repeated = await runner.execute(original);
    expect(repeated['jobId'], accepted['jobId']);
    expect(repeated['state'], 'blocked');
    expect(calls, 1);
  });

  test('fixed group readiness refusals serialize as certain consumed results', () async {
    for (final code in const [
      'backend_group_context_not_ready', 'backend_group_parent_not_ready',
      'backend_group_sender_not_ready', 'backend_group_route_not_ready',
      'backend_group_dependency_not_ready', 'backend_group_route_ambiguous',
      'backend_group_targets_not_ready',
    ]) {
      var calls = 0;
      final runner = engine({'fixture.route': BackendHarnessOperation(
        background: true, uncertainOnFailure: true, validate: (_) => true,
        handler: (_) async {
          calls++;
          throw BackendHarnessFailure(code, effectNotEntered: true);
        },
      )});
      final original = request('fixed-stage', 'fixture.route');
      final accepted = await runner.execute(original);
      await Future<void>.delayed(Duration.zero);
      final result = await runner.execute(request('fixed-stage-poll', 'job.status', {'jobId': accepted['jobId']}));
      expect(result['state'], 'blocked');
      expect(result['code'], code);
      expect((result['data'] as Map)['flags'], {'outcome_uncertain': false});
      expect(jsonDecode(jsonEncode(result))['code'], code);
      expect((await runner.execute(original))['jobId'], accepted['jobId']);
      expect(calls, 1);
    }
  });

  test(
    'exceptions and arbitrary payload keys never leak into receipts',
    () async {
      final runner = engine({
        'sync.start': operation((_) async {
          throw StateError('private account@example.com message and token');
        }),
      });
      final accepted = await runner.execute(request('first', 'sync.start'));
      await Future<void>.delayed(Duration.zero);
      final result = await runner.execute(
        request('poll', 'job.status', {'jobId': accepted['jobId']}),
      );
      expect(result['code'], 'backend_job_failed');
      expect(jsonEncode(result), isNot(contains('account@example.com')));
      expect(
        () => const BackendHarnessPayload(flags: {'secret': true}).toJson(),
        throwsFormatException,
      );
      expect(
        () => const BackendHarnessPayload(counts: {'pages': -1}).toJson(),
        throwsFormatException,
      );
    },
  );

  test(
    'missing jobs after a new boot are unknown and never restarted',
    () async {
      var calls = 0;
      final runner = engine({
        'sync.start': operation((_) async {
          calls++;
          return const BackendHarnessPayload();
        }),
      });
      expect(
        (await runner.execute(
          request('poll', 'job.status', {'jobId': 'previous-boot-job'}),
        ))['code'],
        'backend_job_unknown',
      );
      expect(calls, 0);
    },
  );

  test(
    'history ceiling preserves finished receipts instead of evicting them',
    () async {
      final runner = engine({
        'sync.start': operation((_) async => const BackendHarnessPayload()),
      }, maximumJobs: 1);
      final accepted = await runner.execute(request('first', 'sync.start'));
      await Future<void>.delayed(Duration.zero);
      expect(
        (await runner.execute(request('second', 'sync.start')))['code'],
        'backend_job_limit',
      );
      expect(
        (await runner.execute(
          request('poll', 'job.status', {'jobId': accepted['jobId']}),
        ))['state'],
        'completed',
      );
    },
  );

  test(
    'unknown fields, actions, version and excess nesting are refused',
    () async {
      final runner = engine({});
      expect(
        (await runner.execute({
          ...request('a', 'hello'),
          'extra': true,
        }))['code'],
        'backend_invalid_request',
      );
      for (final version in <Object>[2, 1.0, true, '1']) {
        expect(
          (await runner.execute({
            ...request('a', 'hello'),
            'protocol': version,
          }))['code'],
          'backend_invalid_request',
        );
      }
      expect(
        (await runner.execute(request('a', 'arbitrary.invoke')))['code'],
        'backend_invalid_action',
      );
      expect(
        (await runner.execute(
          request('a', 'hello', {'extra': 'private'}),
        ))['code'],
        'backend_invalid_arguments',
      );
      Object? nested = 1;
      for (var index = 0; index < 10; index++) {
        nested = [nested];
      }
      expect(
        (await runner.execute(
          request('a', 'hello', {'nested': nested}),
        ))['code'],
        'backend_invalid_arguments',
      );
    },
  );
}
