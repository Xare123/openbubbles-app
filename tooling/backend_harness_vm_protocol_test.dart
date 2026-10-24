import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' as vm;

import 'vm_backend_harness.dart';

final source = List.filled(40, 'a').join();
final session = List.filled(32, 'b').join();
const package = 'com.bluebubbles.messaging.backendtest';
Map<String, Object?> request([String action = 'status', String id = 'one']) => {
  'protocol': 1, 'requestId': id, 'action': action, 'arguments': <String, Object?>{},
};
Map<String, Object?> input() => {
  'uri': 'ws://127.0.0.1:1234/private-token=/ws',
  'expected_source': source, 'expected_package': package, 'request': request(),
};
Map<String, Object?> frame(String id, String action, {Map<String, Object?>? data,
    String code = 'backend_ready', String state = 'completed', String? job}) => {
  'protocol': 1, 'requestId': id, 'action': action,
  'ok': !{'blocked', 'failed'}.contains(state), 'code': code,
  'state': state, 'jobId': job,
  'data': data ?? {'phase': 'idle', 'flags': <String, bool>{}, 'counts': <String, int>{}},
};
Map<String, Object?> hello(String id, {
  String runtimePackage = package, String platform = 'android',
}) => frame(id, 'hello', data: {
  'source': source, 'package': runtimePackage, 'platform': platform,
  'sessionId': session, 'mode': 'backend', 'actions': ['hello', 'job.status', 'status', 'sync.start'],
});

class MockService extends Fake implements vm.VmService {
  List<List<String>> extensions = [[backendHarnessExtension], []];
  final calls = <Map<String, Object?>>[];
  final parameters = <Map<String, dynamic>>[];
  String remoteSession = session;
  bool rebootBeforeCommand = false;
  int backendInvocations = 0;
  int disposalCount = 0;
  bool failDisposal = false;
  Map<String, Object?> Function(String)? makeHello;
  Future<Map<String, Object?>> Function(Map<String, Object?>)? respond;
  @override
  Future<vm.VM> getVM() async => vm.VM(isolates: [
    for (var i = 0; i < extensions.length; i++) vm.IsolateRef(id: 'isolates/$i'),
  ]);
  @override
  Future<vm.Isolate> getIsolate(String isolateId) async => vm.Isolate(
      id: isolateId, extensionRPCs: extensions[int.parse(isolateId.split('/').last)]);
  @override
  Future<void> dispose() async {
    disposalCount++;
    if (failDisposal) throw StateError('private transport disposal failure');
  }
  @override
  Future<vm.Response> callServiceExtension(String method, {
    String? isolateId, Map<String, dynamic>? args,
  }) async {
    expect(method, backendHarnessExtension);
    expect(isolateId, 'isolates/0');
    expect(args, isNotNull);
    parameters.add(Map<String, dynamic>.from(args!));
    final r = Map<String, Object?>.from(jsonDecode(args['request'] as String) as Map);
    expect(r.keys.toSet(), {'protocol', 'requestId', 'action', 'arguments'});
    expect(args.keys.toSet(), r['action'] == 'hello'
        ? {'request'} : {'request', 'sessionId'});
    calls.add(r);
    late final Map<String, Object?> reply;
    if (r['action'] == 'hello') {
      reply = (makeHello ?? hello)(r['requestId'] as String);
      if (makeHello == null) (reply['data'] as Map)['sessionId'] = remoteSession;
    } else {
      if (rebootBeforeCommand) {
        remoteSession = List.filled(32, 'd').join();
        rebootBeforeCommand = false;
      }
      if (args['sessionId'] != remoteSession) {
        reply = frame(r['requestId'] as String, r['action'] as String,
            state: 'blocked', code: 'backend_stale_session', data: {});
      } else {
        backendInvocations++;
        reply = await (respond?.call(r) ??
            Future.value(frame(r['requestId'] as String, r['action'] as String)));
      }
    }
    return vm.Response()..json = Map<String, dynamic>.from(reply);
  }
}

BackendHarnessVmClient client(MockService service, {
  Duration? timeout, String expectedPackage = package,
  BackendHarnessDispatchJournal? journal,
}) =>
    BackendHarnessVmClient(service, expectedSource: source,
        expectedPackage: expectedPackage, dispatchJournal: journal,
        timeout: timeout ?? const Duration(seconds: 1));
TypeMatcher<BackendHarnessHostFailure> failure(String code) => isA<BackendHarnessHostFailure>()
    .having((e) => e.code, 'code', code);

void main() {
  late Directory ownedRoot;
  final journals = <BackendHarnessDispatchJournal>[];
  BackendHarnessDispatchJournal ownedJournal() {
    final directory = Directory(p.join(ownedRoot.path, 'journal-${journals.length}'))..createSync();
    final journal = BackendHarnessDispatchJournal.open(evidenceDirectory: directory.path,
        expectedSource: source, expectedPackage: package, runOwner: session);
    journals.add(journal);
    return journal;
  }
  setUp(() {
    ownedRoot = Directory.systemTemp.createTempSync('backend-harness-host-');
  });
  tearDown(() {
    for (final journal in journals) { journal.close(); }
    journals.clear();
    final canonical = ownedRoot.resolveSymbolicLinksSync();
    // Delete only this test's freshly-created child of the real temp directory.
    expect(p.equals(p.dirname(canonical), Directory.systemTemp.resolveSymbolicLinksSync()), true);
    expect(p.basename(canonical).startsWith('backend-harness-host-'), true);
    expect(p.equals(p.normalize(ownedRoot.absolute.path), canonical), true);
    ownedRoot.deleteSync(recursive: true);
  });
  test('private exact input and bounded request', () {
    expect(validateBackendHarnessInput(input()).source, source);
    for (final change in <Map<String, Object?>>[
      {'expected_source': 'bad'}, {'expected_package': ''}, {'extra': 'secret'},
      {'uri': 'ws://remote.example:1234/token/ws'},
      {'uri': 'ws://127.0.0.1:1234/ws'},
      {'uri': 'ws://127.0.0.1:1234/token/ws?secret=1'},
      {'uri': 'ws://127.0.0.1:1234/token/ws#secret'},
      {'uri': 'ws://user:secret@127.0.0.1:1234/token/ws'},
      {'uri': 'ws://127.0.0.1:5037/token/ws'},
      {'request': {...request(), 'arguments': {'secret': List.filled(65536, 'x').join()}}},
    ]) {
      expect(() => validateBackendHarnessInput({...input(), ...change}), throwsA(failure('backend_invalid_request')));
    }
    expect(() => validateBackendHarnessRequest({...request(), 'action': 'evaluate'}), throwsA(failure('backend_invalid_request')));
    expect(() => validateBackendHarnessRequest({...request(), 'arguments': {'a': 1.5}}), throwsA(failure('backend_invalid_request')));
  });

  test('stream byte limit and malformed UTF8 are private failures', () async {
    await expectLater(readBackendHarnessInput(Stream.value(List.filled(65537, 120))), throwsA(failure('backend_invalid_request')));
    await expectLater(readBackendHarnessInput(Stream.value([255])), throwsA(failure('backend_invalid_request')));
    expect((await readBackendHarnessInput(Stream.value(utf8.encode(jsonEncode(input()))))).package, package);
  });

  test('only the unique extension isolate and hello precede command', () async {
    final mock = MockService();
    final result = await client(mock).execute(request());
    expect(result['code'], 'backend_ready');
    expect(mock.calls.map((r) => r['action']), ['hello', 'status']);
    for (final extensionLists in <List<List<String>>>[
      [[], []], [[backendHarnessExtension], [backendHarnessExtension]],
    ]) {
      final invalid = MockService()..extensions = extensionLists;
      await expectLater(client(invalid).execute(request()), throwsA(failure('backend_not_ready')));
      expect(invalid.calls, isEmpty);
    }
  });

  test('source package and actual manifest gate dispatch', () async {
    for (final entry in <String, Object>{'source': List.filled(40, 'c').join(),
      'package': 'wrong.package', 'actions': ['hello', 'job.status']}.entries) {
      final mock = MockService()..makeHello = (id) {
        final h = hello(id);
        (h['data'] as Map)[entry.key] = entry.value;
        return h;
      };
      await expectLater(client(mock).execute(request()), throwsA(failure(
        entry.key == 'source' ? 'backend_source_mismatch' :
        entry.key == 'package' ? 'backend_identity_changed' : 'backend_not_supported')));
      expect(mock.calls.length, 1);
    }
  });

  test('Android dedicated package pin rejects Canary and production substitution', () async {
    for (final candidate in [
      'com.bluebubbles.messaging.cloudkitcanary',
      'com.openbubbles.messaging',
    ]) {
      final mock = MockService()..makeHello = (id) => hello(id, runtimePackage: candidate);
      await expectLater(client(mock).execute(request()),
          throwsA(failure('backend_identity_changed')));
      expect(mock.calls.map((r) => r['action']), ['hello']);
    }
  });

  test('Windows uses exact caller metadata, with no Android package substitution', () async {
    // Synthetic metadata: the parent supplies the real isolated-profile pin.
    const windowsPackage = 'windows.isolated.profile.fixture';
    final claim = validateBackendHarnessInput({...input(), 'expected_package': windowsPackage});
    final mock = MockService()..makeHello = (id) =>
        hello(id, runtimePackage: windowsPackage, platform: 'windows');
    expect((await client(mock, expectedPackage: claim.package).execute(request()))['ok'], true);
    await expectLater(client(mock, expectedPackage: 'windows.other.profile').execute(request()),
        throwsA(failure('backend_identity_changed')));
    expect(mock.calls.where((r) => r['action'] == 'status').length, 1);
  });

  test('production mode is rejected even with an exact package and source pin', () async {
    for (final platform in ['android', 'windows']) {
      final mock = MockService()..makeHello = (id) {
        final h = hello(id, platform: platform);
        (h['data'] as Map)['mode'] = 'prod';
        return h;
      };
      await expectLater(client(mock).execute(request()),
          throwsA(failure('backend_invalid_request')));
      expect(mock.calls.map((r) => r['action']), ['hello']);
    }
  });

  test('session change blocks subsequent submission', () async {
    final mock = MockService();
    final c = client(mock, journal: ownedJournal());
    await c.execute(request());
    mock.makeHello = (id) {
      final h = hello(id);
      (h['data'] as Map)['sessionId'] = List.filled(32, 'c').join();
      return h;
    };
    await expectLater(c.execute(request('sync.start', 'two')), throwsA(failure('backend_stale_session')));
    expect(mock.calls.where((r) => r['action'] == 'sync.start'), isEmpty);
  });

  test('wire hello is unbound and command carries the captured hello session', () async {
    final mock = MockService()..remoteSession = List.filled(32, 'e').join();
    await client(mock).execute(request());
    expect(mock.parameters[0].keys, ['request']);
    expect(mock.parameters[1].keys.toSet(), {'request', 'sessionId'});
    expect(mock.parameters[1]['sessionId'], mock.remoteSession);
    expect(jsonDecode(mock.parameters[1]['request'] as String), request());
    expect(mock.backendInvocations, 1);
  });

  test('boot change between hello and command returns stale without retry', () async {
    final mock = MockService()..rebootBeforeCommand = true;
    final c = client(mock, journal: ownedJournal());
    final result = await c.execute(request('sync.start'));
    expect(result['code'], 'backend_stale_session');
    expect(result['state'], 'blocked');
    expect(result['ok'], false);
    expect(mock.parameters[1]['sessionId'], session);
    expect(mock.backendInvocations, 0);
    await expectLater(c.execute(request('sync.start')),
        throwsA(failure('backend_request_reused')));
    expect(mock.calls.map((r) => r['action']), ['hello', 'sync.start']);
  });

  test('frame rejects injected data, bad counts flags phase and correlations', () {
    for (final change in <Map<String, Object?>>[
      {'requestId': 'wrong'}, {'action': 'sync.start'}, {'protocol': 2},
      {'ok': false}, {'code': 'private error'}, {'extra': 'secret'},
      {'code': 'backend_job_accepted'},
      {'data': {'phase': 'native_secret', 'flags': {}, 'counts': {}}},
      {'data': {'phase': 'idle', 'flags': {'secret': true}, 'counts': {}}},
      {'data': {'phase': 'idle', 'flags': {'auth_ready': 'true'}, 'counts': {}}},
      {'data': {'phase': 'idle', 'flags': {}, 'counts': {'pages': -1}}},
      {'data': {'phase': 'idle', 'flags': {}, 'counts': {'pages': 1000000001}}},
      {'data': {'phase': 'idle', 'flags': {}, 'counts': {}, 'message': 'secret'}},
    ]) {
      expect(() => validateBackendHarnessReply({...frame('one', 'status'), ...change},
        requestId: 'one', action: 'status'), throwsA(failure('backend_invalid_request')));
    }
  });

  test('typed live challenges preserve accepted/running state and redact hello', () {
    for (final kind in ['trustedDevice', 'smsDestination', 'verificationCode', 'archiveConsent', 'passcode', 'pin']) {
      final reply = frame('one', 'sync.start', state: 'running',
        code: 'backend_auth_challenge', job: session, data: {
          'phase': 'needs_passcode', 'flags': {}, 'counts': {},
          'challenge': {'id': session, 'kind': kind, 'options': const {'trustedDevice', 'smsDestination'}.contains(kind) ? 2 : 0},
        });
      final receipt = backendHarnessPublicReceipt(reply);
      expect(receipt['state'], 'running');
      expect(receipt['code'], 'backend_auth_challenge');
      expect((receipt['data'] as Map)['challenge'], (reply['data'] as Map)['challenge']);
    }
    expect(backendHarnessPublicReceipt(hello('one'))['data'], isEmpty);
    for (final challenge in [
      {'id': session, 'kind': 'pin', 'options': 1},
      {'id': session, 'kind': 'trustedDevice', 'options': 0},
      {'id': session, 'kind': 'trustedDevice', 'options': 65},
      {'id': session, 'kind': 'unknown', 'options': 0},
      {'id': session.toUpperCase(), 'kind': 'pin', 'options': 0},
      {'id': session, 'kind': 'pin', 'options': 0, 'device': 'secret'},
    ]) {
      expect(() => validateBackendHarnessReply(frame('one', 'status', data: {
        'phase': 'needs_passcode', 'flags': {}, 'counts': {}, 'challenge': challenge,
      }), requestId: 'one', action: 'status'), throwsA(failure('backend_invalid_request')));
    }
  });

  test('accepted job returns once without automatic polling or resubmission', () async {
    final mock = MockService()..respond = (r) async => frame(r['requestId'] as String,
      r['action'] as String, code: 'backend_job_accepted', state: 'accepted', job: session, data: {});
    final c = client(mock, journal: ownedJournal());
    expect((await c.execute(request('sync.start')))['state'], 'accepted');
    await expectLater(c.execute(request('sync.start')), throwsA(failure('backend_request_reused')));
    expect(mock.calls.map((r) => r['action']), ['hello', 'sync.start']);
  });

  test('explicit job.status binds the returned job to the requested handle', () async {
    final mock = MockService()..respond = (r) async => frame(
      r['requestId'] as String, 'job.status', state: 'running',
      code: 'backend_job_running', job: session, data: {});
    final poll = {...request('job.status', 'poll'), 'arguments': {'jobId': session}};
    expect((await client(mock).execute(poll))['jobId'], session);
    mock.respond = (r) async => frame(r['requestId'] as String, 'job.status',
      state: 'running', code: 'backend_job_running',
      job: List.filled(32, 'c').join(), data: {});
    await expectLater(client(mock).execute(poll), throwsA(failure('backend_invalid_request')));
  });

  test('timeout leaves one outstanding submission and forbids request reuse', () async {
    final pending = Completer<Map<String, Object?>>();
    final mock = MockService()..respond = (_) => pending.future;
    final c = client(mock, journal: ownedJournal(), timeout: const Duration(milliseconds: 10));
    await expectLater(c.execute(request('sync.start')), throwsA(
      failure('backend_job_unknown').having((e) => e.outcomeUncertain, 'uncertain', true)));
    await expectLater(c.execute(request('sync.start')), throwsA(failure('backend_request_reused')));
    expect(mock.calls.where((r) => r['action'] == 'sync.start').length, 1);
    pending.complete(frame('one', 'sync.start', code: 'backend_job_accepted',
      state: 'accepted', job: session, data: {}));
  });

  test('CLI failure receipt preserves timeout uncertainty without private data', () async {
    final pending = Completer<Map<String, Object?>>();
    final mock = MockService()..respond = (_) => pending.future;
    final claim = validateBackendHarnessInput({...input(), 'request': request('sync.start')});
    try {
      await client(mock, journal: ownedJournal(),
          timeout: const Duration(milliseconds: 10)).execute(claim.request);
      fail('expected uncertain timeout');
    } on BackendHarnessHostFailure catch (error) {
      final receipt = backendHarnessFailureReceipt(error, input: claim);
      expect(receipt['code'], 'backend_job_unknown');
      expect(receipt['data'], {
        'phase': 'error', 'flags': {'outcome_uncertain': true}, 'counts': {},
      });
      expect(backendHarnessPublicReceipt(receipt), receipt);
      expect(jsonEncode(receipt), isNot(contains('private-token')));
    }
    expect(mock.backendInvocations, 1);
    pending.complete(frame('one', 'sync.start', code: 'backend_job_accepted',
        state: 'accepted', job: session, data: {}));
  });

  test('CLI failure receipt redacts arbitrary errors and keeps a typed false flag', () {
    final receipt = backendHarnessFailureReceipt(StateError('ws://secret/password'));
    expect(receipt['code'], 'backend_internal_error');
    expect((receipt['data'] as Map)['flags'], {'outcome_uncertain': false});
    expect(jsonEncode(receipt), isNot(contains('secret')));
    expect(backendHarnessPublicReceipt(receipt), receipt);
  });

  test('connection completing after timeout is disposed exactly once without RPCs', () async {
    for (final failDisposal in [false, true]) {
      final pending = Completer<vm.VmService>();
      final owned = MockService()..failDisposal = failDisposal;
      var connects = 0;
      final future = connectBackendHarness(validateBackendHarnessInput(input()),
        timeout: const Duration(milliseconds: 10), connectionFactory: (_) {
          connects++;
          return pending.future;
        });
      await expectLater(future, throwsA(failure('backend_not_ready')));
      expect(owned.disposalCount, 0);
      pending.complete(owned);
      await Future<void>.delayed(Duration.zero);
      expect(owned.disposalCount, 1);
      expect(connects, 1);
      expect(owned.calls, isEmpty);
      expect(owned.backendInvocations, 0);
    }
  });

  test('successful connection ownership transfers to caller without early disposal', () async {
    final owned = MockService();
    final connected = await connectBackendHarness(validateBackendHarnessInput(input()),
        connectionFactory: (_) async => owned);
    expect(identical(connected, owned), true);
    expect(owned.disposalCount, 0);
    await connected.dispose();
    expect(owned.disposalCount, 1);
    expect(owned.calls, isEmpty);
  });

  test('immediate and late connection errors stay redacted and never reconnect', () async {
    var connects = 0;
    await expectLater(connectBackendHarness(validateBackendHarnessInput(input()),
      connectionFactory: (_) {
        connects++;
        throw StateError('ws://secret/password');
      }), throwsA(failure('backend_not_ready').having((e) => e.toString(),
          'redacted', isNot(contains('secret')))));
    final pending = Completer<vm.VmService>();
    await expectLater(connectBackendHarness(validateBackendHarnessInput(input()),
      timeout: const Duration(milliseconds: 10), connectionFactory: (_) {
        connects++;
        return pending.future;
      }), throwsA(failure('backend_not_ready')));
    pending.completeError(StateError('ws://secret/late-error'));
    await Future<void>.delayed(Duration.zero);
    expect(connects, 2);
  });

  test('RPC errors and private arguments do not escape failure or receipt', () async {
    final mock = MockService()..respond = (_) async => throw StateError('ws://secret/password');
    try {
      await client(mock, journal: ownedJournal()).execute(
          {...request('auth.login'), 'arguments': {'password': 'private'}});
      fail('expected manifest rejection');
    } on BackendHarnessHostFailure catch (e) {
      expect(e.toString(), isNot(contains('private')));
    }
    mock.makeHello = (id) {
      final h = hello(id);
      ((h['data'] as Map)['actions'] as List).add('auth.login');
      return h;
    };
    await expectLater(client(mock, journal: ownedJournal()).execute(
        {...request('auth.login'), 'arguments': {'password': 'private'}}),
      throwsA(failure('backend_internal_error').having((e) => e.toString(), 'redacted', isNot(contains('secret')))));
  });

  test('optional private journal shape is exact and backwards compatible', () {
    expect(validateBackendHarnessInput(input()).dispatchJournal, isNull);
    final claim = {'directory': ownedRoot.path, 'run_owner': session};
    final parsed = validateBackendHarnessInput({...input(), 'dispatch_journal': claim});
    expect(parsed.dispatchJournal, claim);
    expect(parsed.toString(), isNot(contains(ownedRoot.path)));
    for (final invalid in [null, {'directory': ownedRoot.path},
      {...claim, 'secret': 'password'}, {...claim, 'run_owner': 'bad'},
      {...claim, 'directory': 1}]) {
      expect(() => validateBackendHarnessInput({...input(), 'dispatch_journal': invalid}),
          throwsA(failure('backend_invalid_request')));
    }
  });

  test('all state changes and future fixture writers require durable admission', () async {
    for (final action in backendHarnessActions) {
      final requires = backendHarnessActionRequiresJournal(action);
      if (!requires) continue;
      final mock = MockService();
      await expectLater(client(mock).execute(request(action)),
          throwsA(failure('backend_not_ready')));
      expect(mock.calls, isEmpty);
      expect(mock.backendInvocations, 0);
    }
    for (final action in backendHarnessFutureWriterActions) {
      expect(backendHarnessActionRequiresJournal(action), true);
    }
    expect(backendHarnessActionRequiresJournal('future.unknown'), true);
    expect(backendHarnessActionRequiresJournal('fixture.inspect'), false);
    expect(backendHarnessActionRequiresJournal('fixture.materialize'), true);
  });

  test('closed recorder or binding mismatch prevents even a hello RPC', () async {
    final closed = ownedJournal()..close();
    final mock = MockService();
    await expectLater(client(mock, journal: closed).execute(request('sync.start')),
        throwsA(failure('backend_not_ready')));
    final mismatched = client(mock, journal: ownedJournal(), expectedPackage: 'other.package');
    await expectLater(mismatched.execute(request('sync.start')),
        throwsA(failure('backend_identity_changed')));
    expect(mock.calls, isEmpty);
  });

  test('ownership released during hello cannot dispatch the admitted command', () async {
    final journal = ownedJournal();
    final mock = MockService()..makeHello = (id) {
      journal.close();
      return hello(id);
    };
    await expectLater(client(mock, journal: journal).execute(request('sync.start')),
        throwsA(isA<BackendHarnessHostFailure>()));
    expect(mock.calls.map((r) => r['action']), ['hello']);
    expect(mock.backendInvocations, 0);
  });

  test('failure to record an accepted result stays uncertain and cannot repeat', () async {
    final directory = Directory(p.join(ownedRoot.path, 'lost-result'))..createSync();
    BackendHarnessDispatchJournal open() => BackendHarnessDispatchJournal.open(
        evidenceDirectory: directory.path, expectedSource: source,
        expectedPackage: package, runOwner: session);
    final journal = open();
    final mock = MockService()..respond = (r) async {
      journal.close(); // Simulates loss of the recorder after dispatch.
      return frame(r['requestId'] as String, 'sync.start', state: 'accepted',
          code: 'backend_job_accepted', job: session, data: {});
    };
    await expectLater(client(mock, journal: journal).execute(request('sync.start')),
        throwsA(failure('backend_internal_error').having(
          (e) => e.outcomeUncertain, 'uncertain', true)));
    final resumed = open();
    journals.add(resumed);
    await expectLater(client(mock, journal: resumed).execute(request('sync.start')),
        throwsA(failure('backend_request_reused')));
    expect(mock.calls.map((r) => r['action']), ['hello', 'sync.start']);
    expect(mock.backendInvocations, 1);
  });

  test('flushed admission survives a new host and app boot, observations use new IDs', () async {
    final directory = Directory(p.join(ownedRoot.path, 'restart'))..createSync();
    BackendHarnessDispatchJournal open() => BackendHarnessDispatchJournal.open(
        evidenceDirectory: directory.path, expectedSource: source,
        expectedPackage: package, runOwner: session);
    final first = open();
    final mock = MockService()..respond = (r) async {
      // Reopening while the command is in flight must fail: ownership is held.
      expect(open, throwsA(isA<BackendHarnessDispatchJournalFailure>()));
      return frame(r['requestId'] as String, r['action'] as String,
          state: 'accepted', code: 'backend_job_accepted', job: session, data: {});
    };
    try {
      await client(mock, journal: first).execute(request('sync.start'));
    } finally { first.close(); }
    final lines = File(p.join(directory.path, backendHarnessJournalFileName)).readAsLinesSync();
    expect(jsonDecode(lines[1]), containsPair('type', 'admit'));
    expect(jsonDecode(lines[2]), containsPair('jobId', session));
    final resumed = open();
    journals.add(resumed);
    mock.remoteSession = List.filled(32, 'c').join();
    final c = client(mock, journal: resumed);
    final before = mock.calls.length;
    await expectLater(c.execute(request('sync.start')), throwsA(failure('backend_request_reused')));
    expect(mock.calls.length, before);
    mock.respond = (r) async => frame(r['requestId'] as String, 'job.status',
        state: 'running', code: 'backend_job_running', job: session, data: {});
    expect((await c.execute({...request('job.status', 'fresh-observation'),
      'arguments': {'jobId': session}}))['state'], 'running');
    expect(mock.calls.where((r) => r['action'] == 'sync.start').length, 1);
  });

  test('RPC secrets never enter the dispatch journal', () async {
    final directory = Directory(p.join(ownedRoot.path, 'secrets'))..createSync();
    final journal = BackendHarnessDispatchJournal.open(evidenceDirectory: directory.path,
        expectedSource: source, expectedPackage: package, runOwner: session);
    final mock = MockService()..makeHello = (id) {
      final h = hello(id);
      ((h['data'] as Map)['actions'] as List).add('auth.login');
      return h;
    };
    mock.respond = (_) async => throw StateError('ws://private-endpoint/private-password');
    try {
      await expectLater(client(mock, journal: journal).execute({
        ...request('auth.login'), 'arguments': {'password': 'private-password', 'otp': '654321'},
      }), throwsA(failure('backend_internal_error')));
    } finally { journal.close(); }
    final text = File(p.join(directory.path, backendHarnessJournalFileName)).readAsStringSync();
    for (final secret in ['arguments', 'private-password', '654321', 'private-endpoint', 'sessionId']) {
      expect(text, isNot(contains(secret)));
    }
    final result = jsonDecode(text.trim().split('\n').last) as Map;
    expect(result['outcomeUncertain'], true);
    expect(mock.backendInvocations, 1);
  });

  test('typed optional fixture and challenge survive private validation only', () {
    const fixture = {'fixtureId': '12345678-1234-4234-8234-123456789abc',
      'messageGuid': '87654321-4321-4321-8321-cba987654321',
      'visibleTextSha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'participantsSha256': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'editHistorySha256': 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'};
    final reply = frame('one', 'fixture.send', data: {
      'phase': 'idle', 'flags': {}, 'counts': {}, 'fixture': fixture,
      'challenge': {'id': session, 'kind': 'pin', 'options': 0},
    });
    final private = validateBackendHarnessReply(reply, requestId: 'one', action: 'fixture.send');
    expect((private['data'] as Map)['fixture'], fixture);
    final receipt = backendHarnessPublicReceipt(private);
    expect((receipt['data'] as Map).containsKey('fixture'), false);
    expect((receipt['data'] as Map)['challenge'], (private['data'] as Map)['challenge']);
    expect((private['data'] as Map)['fixture'], fixture);
    for (final bad in [null, {...fixture, 'body': 'secret'},
      {...fixture, 'messageGuid': 'native-id'}, {...fixture, 'visibleTextSha256': 'bad'},
      {...fixture, 'editHistorySha256': 'bad'}]) {
      expect(() => validateBackendHarnessReply(frame('one', 'status', data: {
        'phase': 'idle', 'flags': {}, 'counts': {}, 'fixture': bad,
      }), requestId: 'one', action: 'status'), throwsA(failure('backend_invalid_request')));
    }
  });
}
