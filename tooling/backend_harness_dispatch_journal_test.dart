import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'backend_harness_dispatch_journal.dart';

const _source = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _package = 'com.bluebubbles.messaging.backendtest';
const _owner = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
TypeMatcher<BackendHarnessDispatchJournalFailure> failure(String code) =>
    isA<BackendHarnessDispatchJournalFailure>().having((e) => e.code, 'code', code);

// Keep the spawned closure outside the test's scope: open handles in that
// scope must never become part of an isolate message's captured context.
Future<String> _compete(String directory) => Isolate.run(() {
  try {
    final other = BackendHarnessDispatchJournal.open(evidenceDirectory: directory,
        expectedSource: _source, expectedPackage: _package, runOwner: _owner);
    other.close();
    return 'unexpected-owner';
  } on BackendHarnessDispatchJournalFailure catch (error) { return error.code; }
});

void main() {
  late Directory root;
  final owned = <BackendHarnessDispatchJournal>[];
  BackendHarnessDispatchJournal open({String? source, String? package, String? owner}) {
    final journal = BackendHarnessDispatchJournal.open(evidenceDirectory: root.path,
        expectedSource: source ?? _source, expectedPackage: package ?? _package,
        runOwner: owner ?? _owner);
    owned.add(journal);
    return journal;
  }
  File file() => File(p.join(root.path, backendHarnessJournalFileName));
  void admit(BackendHarnessDispatchJournal journal, [String id = 'write-one']) =>
      journal.admit(expectedSource: _source, expectedPackage: _package,
          requestId: id, action: 'fixture.send');

  setUp(() { root = Directory.systemTemp.createTempSync('backend-harness-journal-'); });
  tearDown(() {
    for (final journal in owned) { journal.close(); }
    owned.clear();
    final canonical = root.resolveSymbolicLinksSync();
    expect(p.equals(p.dirname(canonical), Directory.systemTemp.resolveSymbolicLinksSync()), true);
    expect(p.basename(canonical).startsWith('backend-harness-journal-'), true);
    expect(p.equals(p.normalize(root.absolute.path), canonical), true);
    root.deleteSync(recursive: true); // Only this test's verified, owned fixture.
  });

  test('header binds exact source package and run owner without replacing bytes', () {
    open().close();
    final initial = file().readAsBytesSync();
    for (final change in [
      () => open(source: 'cccccccccccccccccccccccccccccccccccccccc'),
      () => open(package: 'other.package'),
      () => open(owner: 'cccccccccccccccccccccccccccccccc'),
    ]) {
      expect(change, throwsA(isA<BackendHarnessDispatchJournalFailure>()));
      expect(file().readAsBytesSync(), initial);
    }
    expect(jsonDecode(utf8.decode(initial)), {
      'type': 'header', 'version': 1, 'source': _source,
      'package': _package, 'runOwner': _owner,
    });
  });

  test('admission alone consumes ID across reopen including a different action', () {
    final first = open();
    admit(first);
    first.close(); // Models a crash after flushed admission, before any outcome.
    final prefix = file().readAsBytesSync();
    final resumed = open();
    expect(() => admit(resumed), throwsA(failure('backend_request_reused')));
    expect(() => resumed.admit(expectedSource: _source, expectedPackage: _package,
        requestId: 'write-one', action: 'fixture.edit'),
        throwsA(failure('backend_request_reused')));
    resumed.admit(expectedSource: _source, expectedPackage: _package,
        requestId: 'observe-new', action: 'job.status', jobId: _owner);
    resumed.recordResult(requestId: 'observe-new', action: 'job.status',
        jobId: _owner, code: 'backend_job_running', state: 'running', outcomeUncertain: false);
    resumed.close();
    expect(file().readAsBytesSync().take(prefix.length), prefix);
  });

  test('empty, truncated, invalid UTF8 or malformed tails fail closed unchanged', () {
    open().close();
    final header = file().readAsBytesSync();
    final valid = utf8.encode('${jsonEncode({
      'type': 'admit', 'requestId': 'unknown-write', 'action': 'fixture.send',
      'jobId': null, 'code': 'backend_job_unknown', 'state': 'unknown',
      'outcomeUncertain': true,
    })}\n');
    for (final broken in <List<int>>[
      [], header.take(header.length - 1).toList(),
      [...header, ...valid.take(valid.length - 1)],
      [...header, ...utf8.encode('{"type":"admit","requestId":"unknown')],
      [...header, 255, 10], [...header, ...utf8.encode('{}\n')],
      utf8.encode('${jsonEncode({...jsonDecode(utf8.decode(header)) as Map, 'version': 1.0})}\n'),
    ]) {
      file().writeAsBytesSync(broken); // Synthetic corruption, never a real journal.
      expect(open, throwsA(failure('backend_not_ready')));
      expect(file().readAsBytesSync(), broken);
    }
  });

  test('closed keys and types reject arbitrary fields codes exceptions and native IDs', () {
    final journal = open();
    for (final invalid in [
      () => journal.admit(expectedSource: _source, expectedPackage: _package,
          requestId: 'one', action: 'evaluate'),
      () => journal.admit(expectedSource: _source, expectedPackage: _package,
          requestId: 'secret with spaces', action: 'fixture.send'),
      () => journal.admit(expectedSource: _source, expectedPackage: _package,
          requestId: 'one', action: 'job.status', jobId: 'native-id'),
    ]) {
      expect(invalid, throwsA(failure('backend_invalid_request')));
    }
    admit(journal);
    expect(() => journal.recordResult(requestId: 'write-one', action: 'fixture.send',
        code: 'private exception', state: 'failed', outcomeUncertain: true),
        throwsA(failure('backend_invalid_request')));
    journal.close();
    final text = file().readAsStringSync();
    expect(text, isNot(contains('private exception')));
    expect(text.trim().split('\n').length, 2);
    file().writeAsStringSync('$text${jsonEncode({
      'type': 'result', 'requestId': 'write-one', 'action': 'fixture.send',
      'jobId': null, 'code': 'backend_ready', 'state': 'completed',
      'outcomeUncertain': false, 'arguments': {'password': 'synthetic-secret'},
    })}\n');
    expect(open, throwsA(failure('backend_not_ready')));
  });

  test('result cannot precede admission, retarget action, or overwrite a prior result', () {
    final journal = open();
    void result(String action) => journal.recordResult(requestId: 'write-one', action: action,
        code: 'backend_job_unknown', state: 'blocked', outcomeUncertain: true);
    expect(() => result('fixture.send'), throwsA(failure('backend_invalid_request')));
    admit(journal);
    expect(() => result('fixture.edit'), throwsA(failure('backend_invalid_request')));
    result('fixture.send');
    expect(() => result('fixture.send'), throwsA(failure('backend_invalid_request')));
    journal.close();
    final resumed = open();
    expect(() => admit(resumed), throwsA(failure('backend_request_reused')));
  });

  test('exclusive owner rejects a concurrent handle then allows sequential continuation', () {
    final first = open();
    expect(open, throwsA(failure('backend_not_ready')));
    admit(first); // The failed contender must not release this owner's lock.
    expect(open, throwsA(failure('backend_not_ready')));
    first.close();
    final resumed = open();
    expect(() => admit(resumed), throwsA(failure('backend_request_reused')));
  });

  test('exclusive owner also rejects another isolate without releasing its lock', () async {
    final first = open();
    final directory = root.path;
    expect(await _compete(directory), 'backend_not_ready');
    admit(first);
    expect(await _compete(directory), 'backend_not_ready');
  });

  test('paths must name an existing local directory and never create missing parents', () {
    for (final invalid in ['relative', p.join(root.path, 'missing'),
      '${root.path}${p.separator}..${p.separator}escape',
      if (Platform.isWindows) r'\\server\share\private',
    ]) {
      expect(() => BackendHarnessDispatchJournal.open(evidenceDirectory: invalid,
          expectedSource: _source, expectedPackage: _package, runOwner: _owner),
          throwsA(isA<BackendHarnessDispatchJournalFailure>()));
    }
    expect(Directory(p.join(root.path, 'missing')).existsSync(), false);
    expect(file().existsSync(), false);
  });

  test('process exit without close leaves a flushed consumed ID and releases OS ownership', () async {
    // The probe is a pure-Dart filesystem fixture, not a Flutter test run with
    // plain Dart. It exits immediately without closing the admitted journal.
    final configFile = File('.dart_tool/package_config.json').absolute;
    final packages = (jsonDecode(configFile.readAsStringSync()) as Map)['packages'] as List;
    final flutterTest = packages.cast<Map>().singleWhere((entry) => entry['name'] == 'flutter_test');
    final flutterRoot = Directory.fromUri(configFile.uri.resolve(
        flutterTest['rootUri'] as String)).parent.parent;
    final dart = p.join(flutterRoot.path, 'bin', 'cache', 'dart-sdk', 'bin',
        Platform.isWindows ? 'dart.exe' : 'dart');
    final config = configFile.path;
    final library = File('tooling/backend_harness_dispatch_journal.dart').absolute.uri;
    final probe = File(p.join(root.path, 'ownership_probe.dart'))..writeAsStringSync('''
import 'dart:io';
import '$library';
void main(List<String> args) {
  try {
    final journal = BackendHarnessDispatchJournal.open(evidenceDirectory: args[0],
        expectedSource: '$_source', expectedPackage: '$_package', runOwner: '$_owner');
    if (args[1] == 'crash') {
      journal.admit(expectedSource: '$_source', expectedPackage: '$_package',
          requestId: 'crashed-write', action: 'fixture.send');
      exit(0);
    }
    journal.close();
    stdout.write('owned');
  } on BackendHarnessDispatchJournalFailure {
    stdout.write('blocked');
    exitCode = 2;
  }
}
''');
    Future<ProcessResult> run(String mode) => Process.run(dart,
        ['--packages=$config', probe.path, root.path, mode]);
    final first = open();
    final competing = await run('probe');
    expect(competing.exitCode, 2);
    expect(competing.stdout, 'blocked');
    first.close();
    final crashed = await run('crash');
    expect(crashed.exitCode, 0);
    expect(crashed.stderr, isEmpty);
    final resumed = open();
    expect(() => admit(resumed, 'crashed-write'), throwsA(failure('backend_request_reused')));
  });
}
