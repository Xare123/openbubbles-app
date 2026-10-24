import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' as vm;

import 'backend_harness_session.dart';
import 'vm_backend_harness.dart';

const _source = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _package = 'com.bluebubbles.messaging.backendtest';
const _session = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fixture = {
  'fixtureId': '12345678-1234-4234-8234-123456789abc',
  'messageGuid': '87654321-4321-4321-8321-cba987654321',
  'visibleTextSha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
};
Map<String, Object?> _request(String action, [String id = 'one']) => {
  'protocol': backendHarnessProtocol, 'requestId': id, 'action': action, 'arguments': {},
};
Map<String, Object?> _reply(Map<String, Object?> request, {
  String code = 'backend_ready', String state = 'completed', String? jobId,
  Map<String, Object?>? data,
}) => {
  'protocol': backendHarnessProtocol, 'requestId': request['requestId'],
  'action': request['action'], 'ok': !{'blocked', 'failed'}.contains(state),
  'code': code, 'state': state, 'jobId': jobId,
  'data': data ?? {'phase': 'idle', 'flags': {}, 'counts': {}},
};
List<int> _line(Object? value) => utf8.encode('${jsonEncode(value)}\n');
bool _uncertain(Map reply) => ((reply['data'] as Map)['flags'] as Map)['outcome_uncertain'] == true;

final class _Service extends Fake implements vm.VmService {
  final calls = <Map<String, Object?>>[];
  final parameters = <Map<String, dynamic>>[];
  int vmReads = 0;
  int disposals = 0;
  String source = _source;
  String package = _package;
  String session = _session;
  Future<Map<String, Object?>> Function(Map<String, Object?>)? respond;
  Future<void> Function()? beforeHello;

  @override
  Future<vm.VM> getVM() async {
    vmReads++;
    return vm.VM(isolates: [vm.IsolateRef(id: 'isolate/one')]);
  }
  @override
  Future<vm.Isolate> getIsolate(String isolateId) async =>
      vm.Isolate(id: isolateId, extensionRPCs: [backendHarnessExtension]);
  @override
  Future<void> dispose() async { disposals++; }
  @override
  Future<vm.Response> callServiceExtension(String method, {
    String? isolateId, Map<String, dynamic>? args,
  }) async {
    expect(method, backendHarnessExtension);
    expect(isolateId, 'isolate/one');
    final request = Map<String, Object?>.from(jsonDecode(args!['request'] as String) as Map);
    calls.add(request);
    parameters.add(Map<String, dynamic>.from(args));
    Map<String, Object?> reply;
    if (request['action'] == 'hello') {
      expect(args.keys, ['request']);
      await beforeHello?.call();
      reply = _reply(request, data: {
        'source': source, 'package': package, 'platform': 'android',
        'sessionId': session, 'mode': 'backend', 'actions': [
          'hello', 'job.status', 'status', 'fixture.send', 'sync.start',
        ],
      });
    } else {
      expect(args.keys.toSet(), {'request', 'sessionId'});
      expect(args['sessionId'], _session);
      reply = await (respond?.call(request) ?? Future.value(_reply(request)));
    }
    return vm.Response()..json = Map<String, dynamic>.from(reply);
  }
}

// Observe how far the framer reads an oversized chunk. No huge backing buffer
// is allocated by this fixture, and the parser must stop at the byte limit.
final class _OversizedBytes extends ListBase<int> {
  int reads = 0;
  @override
  int get length => backendHarnessHostLimit * 10;
  @override
  set length(int _) => throw UnsupportedError('fixture');
  @override
  int operator [](int _) { reads++; return 120; }
  @override
  void operator []=(int _, int __) => throw UnsupportedError('fixture');
}

void main() {
  late Directory fixtureRoot;
  late Directory directory;
  var caseNumber = 0;
  setUpAll(() {
    fixtureRoot = Directory.systemTemp.createTempSync('backend-harness-session-');
    final canonical = fixtureRoot.resolveSymbolicLinksSync();
    expect(p.equals(p.dirname(canonical), Directory.systemTemp.resolveSymbolicLinksSync()), true);
    expect(p.basename(canonical).startsWith('backend-harness-session-'), true);
    expect(p.equals(p.normalize(fixtureRoot.absolute.path), canonical), true);
    // Preserve these synthetic journals/fixtures for parent provenance. No
    // recursive delete or real evidence-directory access occurs in this test.
    print('Preserved session fixtures: $canonical');
  });
  setUp(() {
    directory = Directory(p.join(fixtureRoot.path, 'case-${caseNumber++}'))..createSync();
    expect(p.isWithin(fixtureRoot.resolveSymbolicLinksSync(), directory.resolveSymbolicLinksSync()), true);
  });

  Map<String, Object?> config([Directory? target]) => {
    'uri': 'ws://127.0.0.1:1234/synthetic-private-token=/ws',
    'expected_source': _source, 'expected_package': _package,
    'dispatch_journal': {'directory': (target ?? directory).path, 'run_owner': _session},
  };
  BackendHarnessDispatchJournal reopen() => BackendHarnessDispatchJournal.open(
      evidenceDirectory: directory.path, expectedSource: _source,
      expectedPackage: _package, runOwner: _session);
  final replies = <Map<String, Object?>>[];
  setUp(replies.clear);
  Future<int> run(Stream<List<int>> input, _Service service, {
    Duration sessionTimeout = const Duration(seconds: 3),
    Duration firstFrameTimeout = const Duration(seconds: 1),
    Duration rpcTimeout = const Duration(seconds: 1),
    bool inputIsPipe = true, bool outputIsPipe = true,
    List<String> arguments = const [],
    Future<void> Function(Map<String, Object?>)? write,
    Future<vm.VmService> Function(String)? connect,
  }) => runBackendHarnessSession(input: input, inputIsPipe: inputIsPipe,
      outputIsPipe: outputIsPipe, arguments: arguments,
      sessionTimeout: sessionTimeout, firstFrameTimeout: firstFrameTimeout,
      rpcTimeout: rpcTimeout, connectionFactory: connect ?? (_) async => service,
      writeReply: write ?? (reply) async { replies.add(reply); });
  Stream<List<int>> frames(Iterable<Object?> values) => Stream.fromIterable(values.map(_line));

  test('config is exact and reuses private input validation with a synthetic hello', () {
    final valid = validateBackendHarnessSessionConfig(config());
    expect(valid.request['action'], 'hello');
    expect(valid.source, _source);
    expect(valid.dispatchJournal!['directory'], directory.path);
    for (final value in [
      null, {...config()}..remove('dispatch_journal'),
      {...config(), 'request': _request('hello')},
      {...config(), 'extra': 'synthetic-secret'},
      {...config(), 'dispatch_journal': null},
      {...config(), 'expected_source': 'wrong'},
      {...config(), 'expected_package': ''},
      {...config(), 'uri': 'ws://remote.invalid:1234/token/ws'},
    ]) {
      expect(() => validateBackendHarnessSessionConfig(value),
          throwsA(isA<BackendHarnessHostFailure>()));
    }
  });

  test('config has no ack; one connection/client preserves hello and request IDs', () async {
    final service = _Service();
    var connects = 0;
    final status = await run(frames([config(), _request('hello', 'hello-one'),
      _request('status', 'status-one'), _request('status', 'status-one')]), service,
      connect: (_) async { connects++; return service; });
    expect(status, 0);
    expect(connects, 1);
    expect(service.vmReads, 1);
    expect(service.disposals, 1);
    expect(replies.length, 3);
    expect(replies.first['requestId'], 'hello-one');
    expect((replies.first['data'] as Map)['source'], _source);
    expect((replies.first['data'] as Map)['sessionId'], _session);
    expect(replies.last['code'], 'backend_request_reused');
    expect(service.calls.map((r) => r['action']), ['hello', 'hello', 'status']);
    reopen().close();
  });

  test('accepted jobs are not polled; only explicit fresh-ID job.status executes', () async {
    final service = _Service()..respond = (r) async => _reply(r, jobId: _session,
        code: r['action'] == 'job.status' ? 'backend_job_running' : 'backend_job_accepted',
        state: r['action'] == 'job.status' ? 'running' : 'accepted', data: {});
    final status = await run(frames([config(), _request('fixture.send'),
      {..._request('job.status', 'explicit-poll'), 'arguments': {'jobId': _session}}]), service);
    expect(status, 0);
    expect(replies.map((r) => r['state']), ['accepted', 'running']);
    expect(service.calls.where((r) => r['action'] != 'hello').map((r) => r['action']),
        ['fixture.send', 'job.status']);
    expect(service.disposals, 1); // Transport only; no cancellation RPC exists.
  });

  test('full validated private fixture/challenge receipts are preserved', () async {
    final service = _Service()..respond = (r) async => _reply(r,
        code: 'backend_job_completed', jobId: _session, data: {
          'phase': 'idle', 'flags': {'fixture_matches': true}, 'counts': {'messages': 1},
          'fixture': _fixture, 'challenge': {'id': _session, 'kind': 'pin', 'options': 0},
        });
    expect(await run(frames([config(), _request('fixture.send')]), service), 0);
    expect((replies.single['data'] as Map)['fixture'], _fixture);
    expect((replies.single['data'] as Map)['challenge'], {'id': _session, 'kind': 'pin', 'options': 0});
    final journal = File(p.join(directory.path, backendHarnessJournalFileName)).readAsStringSync();
    expect(journal, isNot(contains(_fixture['messageGuid'])));
    expect(journal, isNot(contains('synthetic-private-token')));
  });

  test('invalid exact request ends session with one synthetic failure and no forwarding', () async {
    final service = _Service();
    expect(await run(frames([config(), {..._request('status'), 'password': 'synthetic-secret'},
      _request('fixture.send', 'never-forward')]), service), 1);
    expect(service.calls, isEmpty);
    expect(replies.length, 1);
    expect(replies.single['requestId'], 'host_failure');
    expect(replies.single['code'], 'backend_invalid_request');
    expect(jsonEncode(replies), isNot(contains('synthetic-secret')));
  });

  test('JSON null is invalid rather than EOF; empty/malformed UTF8 frames are redacted', () async {
    for (final bad in <List<int>>[_line(null), [10], [255, 10], utf8.encode('{bad-secret}\n')]) {
      final child = Directory(p.join(directory.path, 'invalid-${bad.first}'))..createSync();
      final service = _Service();
      replies.clear();
      expect(await run(Stream.fromIterable([_line(config(child)), bad]), service), 1);
      expect(service.calls, isEmpty);
      expect(replies.single['code'], 'backend_invalid_request');
      expect(jsonEncode(replies), isNot(contains('bad-secret')));
    }
  });

  test('byte framing accepts 64KiB, fragmented UTF8, CRLF and a final frame at EOF', () async {
    final service = _Service();
    final padded = '${jsonEncode(_request('status')).padRight(backendHarnessHostLimit)}\n';
    expect(await run(Stream.fromIterable([_line(config()), utf8.encode(padded),
      ...utf8.encode('${jsonEncode(_request('hello', 'two'))}\r\n').map((byte) => [byte]),
      utf8.encode(jsonEncode(_request('status', 'three'))),
    ]), service), 0);
    expect(replies.map((r) => r['requestId']), ['one', 'two', 'three']);
    final child = Directory(p.join(directory.path, 'utf8'))..createSync();
    replies.clear();
    final bytes = utf8.encode('${jsonEncode({..._request('status'),
      'arguments': {'synthetic': 'é'}})}\n');
    expect(await run(Stream.fromIterable([_line(config(child)), ...bytes.map((b) => [b])]), _Service()), 0);
    expect(jsonEncode(replies), isNot(contains('é')));
  });

  test('oversized input stops at the byte cap before an unbounded allocation', () async {
    final oversized = _OversizedBytes();
    final service = _Service();
    expect(await run(Stream.fromIterable([_line(config()), oversized]), service), 1);
    expect(oversized.reads, lessThanOrEqualTo(backendHarnessHostLimit + 1));
    expect(replies.single['code'], 'backend_invalid_request');
    expect(service.calls, isEmpty);
  });

  test('first-frame timeout is closed and never opens or connects', () async {
    final input = StreamController<List<int>>();
    var connects = 0;
    try {
      expect(await run(input.stream, _Service(), firstFrameTimeout: const Duration(milliseconds: 25),
          connect: (_) async { connects++; return _Service(); }), 1);
      expect(replies.single['code'], 'backend_job_unknown');
      expect(_uncertain(replies.single), false);
      expect(connects, 0);
      expect(File(p.join(directory.path, backendHarnessJournalFileName)).existsSync(), false);
    } finally { await input.close(); }
  });

  test('idle total deadline releases journal/connection with a synthetic timeout', () async {
    final input = StreamController<List<int>>()..add(_line(config()));
    final service = _Service();
    try {
      expect(await run(input.stream, service, sessionTimeout: const Duration(milliseconds: 75)), 1);
      expect(replies.single['requestId'], 'host_failure');
      expect(replies.single['code'], 'backend_job_unknown');
      expect(service.calls, isEmpty);
      expect(service.disposals, 1);
      reopen().close();
    } finally { await input.close(); }
  });

  test('total deadline during a command stays uncertain and never resends', () async {
    final pending = Completer<Map<String, Object?>>();
    final service = _Service()..respond = (_) => pending.future;
    expect(await run(frames([config(), _request('fixture.send')]), service,
        sessionTimeout: const Duration(milliseconds: 100)), 1);
    expect(replies.single['code'], 'backend_job_unknown');
    expect(_uncertain(replies.single), true);
    expect(service.calls.where((r) => r['action'] == 'fixture.send').length, 1);
    expect(service.disposals, 1);
    pending.complete(_reply(_request('fixture.send'), code: 'backend_job_accepted',
        state: 'accepted', jobId: _session, data: {}));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final resumed = reopen();
    expect(() => resumed.admit(expectedSource: _source, expectedPackage: _package,
        requestId: 'one', action: 'fixture.send'),
        throwsA(isA<BackendHarnessDispatchJournalFailure>()));
    resumed.close();
  });

  test('a handshake completing after total deadline cannot dispatch its command', () async {
    final hello = Completer<void>();
    final service = _Service()..beforeHello = () => hello.future;
    expect(await run(frames([config(), _request('fixture.send')]), service,
        sessionTimeout: const Duration(milliseconds: 75)), 1);
    expect(_uncertain(replies.single), true);
    hello.complete();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(service.calls.map((r) => r['action']), ['hello']);
    expect(service.disposals, 1);
  });

  test('an RPC timeout allows only subsequent explicit observation with a new ID', () async {
    final pending = Completer<Map<String, Object?>>();
    final service = _Service()..respond = (r) => r['action'] == 'fixture.send'
        ? pending.future : Future.value(_reply(r));
    expect(await run(frames([config(), _request('fixture.send'), _request('status', 'observe')]),
        service, rpcTimeout: const Duration(milliseconds: 20)), 0);
    expect(replies.first['code'], 'backend_job_unknown');
    expect(_uncertain(replies.first), true);
    expect(replies.last['code'], 'backend_ready');
    expect(service.calls.where((r) => r['action'] != 'hello').map((r) => r['action']),
        ['fixture.send', 'status']);
    pending.complete(_reply(_request('fixture.send'), code: 'backend_job_accepted',
        state: 'accepted', jobId: _session, data: {}));
  });

  test('returned writer uncertainty survives the private reply and durable result without retry', () async {
    final service = _Service()..respond = (r) async => _reply(r,
        code: 'backend_job_failed', state: 'failed', jobId: _session, data: {
          'phase': 'error', 'flags': {'outcome_uncertain': true}, 'counts': {},
        });
    expect(await run(frames([config(), _request('fixture.send'),
      _request('fixture.send')]), service), 0);
    expect(replies.first['code'], 'backend_job_failed');
    expect(replies.first['state'], 'failed');
    expect(_uncertain(replies.first), true);
    expect(replies.last['code'], 'backend_request_reused');
    expect(service.calls.where((r) => r['action'] == 'fixture.send').length, 1);
    final entries = File(p.join(directory.path, backendHarnessJournalFileName))
        .readAsLinesSync().map((line) => jsonDecode(line) as Map).toList();
    expect(entries.where((r) => r['type'] == 'result').single['outcomeUncertain'], true);
  });

  test('uncaught transport error is closed and fences a late handshake', () async {
    final service = _Service()..beforeHello = () async {
      scheduleMicrotask(() { throw StateError('synthetic-private-socket-error'); });
      await Future<void>.delayed(const Duration(milliseconds: 5));
    };
    expect(await run(frames([config(), _request('fixture.send')]), service), 1);
    expect(replies.single['code'], 'backend_internal_error');
    expect(_uncertain(replies.single), true);
    expect(jsonEncode(replies), isNot(contains('synthetic-private-socket-error')));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(service.calls.map((r) => r['action']), ['hello']);
    expect(service.disposals, 1);
  });

  test('source/package/session changes end the same pinned client before a writer', () async {
    for (final change in ['source', 'package', 'session']) {
      final target = Directory(p.join(directory.path, change))..createSync();
      final service = _Service();
      service.respond = (r) async {
        if (change == 'source') service.source = 'cccccccccccccccccccccccccccccccccccccccc';
        if (change == 'package') service.package = 'other.package';
        if (change == 'session') service.session = 'cccccccccccccccccccccccccccccccc';
        return _reply(r);
      };
      replies.clear();
      expect(await run(frames([config(target), _request('status'),
        _request('fixture.send', 'must-block'), _request('status', 'never-forward')]), service), 1);
      expect(replies.length, 2);
      expect(replies.last['code'], change == 'source' ? 'backend_source_mismatch'
          : change == 'package' ? 'backend_identity_changed' : 'backend_stale_session');
      expect(service.calls.where((r) => r['action'] != 'hello').map((r) => r['action']), ['status']);
    }
  });

  test('EOF closes an accepted job transport without additional RPC or cancellation', () async {
    final service = _Service()..respond = (r) async => _reply(r,
        code: 'backend_job_accepted', state: 'accepted', jobId: _session, data: {});
    expect(await run(frames([config(), _request('fixture.send')]), service), 0);
    expect(replies.single['state'], 'accepted');
    expect(service.calls.map((r) => r['action']), ['hello', 'fixture.send']);
    expect(service.disposals, 1);
    reopen().close();
  });

  test('config/open/connect failures are one host_failure, never private errors', () async {
    final service = _Service();
    expect(await run(frames([config()]), service, connect: (_) async =>
        throw StateError('ws://synthetic-secret/password')), 1);
    expect(replies.single['requestId'], 'host_failure');
    expect(replies.single['code'], 'backend_not_ready');
    expect(jsonEncode(replies), isNot(contains('synthetic-secret')));
    expect(service.calls, isEmpty);
    reopen().close();
    replies.clear();
    expect(await run(frames([{...config(), 'dispatch_journal': {
      'directory': p.join(directory.path, 'absent'), 'run_owner': _session,
    }}]), service), 1);
    expect(replies.single['requestId'], 'host_failure');
    expect(service.calls, isEmpty);
  });

  test('pipe/argument/deadline guards reject before reading and suppress public output', () async {
    var listened = false;
    final input = StreamController<List<int>>(onListen: () { listened = true; });
    final service = _Service();
    try {
      expect(await run(input.stream, service, inputIsPipe: false), 1);
      expect(listened, false);
      expect(replies.single['code'], 'backend_invalid_request');
      replies.clear();
      expect(await run(input.stream, service, outputIsPipe: false), 1);
      expect(replies, isEmpty);
      expect(await run(input.stream, service, arguments: ['synthetic-secret']), 1);
      expect(jsonEncode(replies), isNot(contains('synthetic-secret')));
      replies.clear();
      expect(await run(input.stream, service, sessionTimeout: const Duration(minutes: 26)), 1);
      expect(replies.single['code'], 'backend_invalid_request');
      expect(listened, false);
      expect(service.calls, isEmpty);
    } finally {
      // No subscription was made; cancelling an unlistened controller is not
      // necessary and awaiting its close would wait for a nonexistent listener.
      unawaited(input.close());
    }
  });

  test('a failed private output write ends once and releases ownership', () async {
    final service = _Service();
    var writes = 0;
    expect(await run(frames([config(), _request('hello'), _request('fixture.send', 'never')]),
        service, write: (_) async { writes++; throw StateError('synthetic-secret'); }), 1);
    expect(writes, 1);
    expect(service.calls.map((r) => r['action']), ['hello']);
    expect(service.disposals, 1);
    reopen().close();
  });

  test('actual CLI subprocess uses pipes and redacts malformed config without VM access', () async {
    final configFile = File('.dart_tool/package_config.json').absolute;
    final packages = (jsonDecode(configFile.readAsStringSync()) as Map)['packages'] as List;
    final flutterTest = packages.cast<Map>().singleWhere((entry) => entry['name'] == 'flutter_test');
    final flutterRoot = Directory.fromUri(configFile.uri.resolve(
        flutterTest['rootUri'] as String)).parent.parent;
    final dart = p.join(flutterRoot.path, 'bin', 'cache', 'dart-sdk', 'bin',
        Platform.isWindows ? 'dart.exe' : 'dart');
    final process = await Process.start(dart, ['--packages=${configFile.path}',
      File('tooling/backend_harness_session.dart').absolute.path]);
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    process.stdin.add(_line({...config(), 'expected_source': 'synthetic-secret'}));
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 15)), 1);
    final text = await out;
    expect(text.endsWith('\n'), true);
    final lines = text.trim().split('\n');
    expect(lines.length, 1);
    final reply = jsonDecode(lines.single) as Map;
    expect(reply['requestId'], 'host_failure');
    expect(reply['code'], 'backend_invalid_request');
    for (final secret in ['synthetic-secret', 'synthetic-private-token', directory.path]) {
      expect(text, isNot(contains(secret)));
    }
    expect(await err, isEmpty);
  });
}
