import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'windows_backend_live_host_test.dart' show WindowsBackendHostFiles;

void main() {
  late Directory fixture;
  late String resolved;
  late Directory selected;
  late WindowsBackendHostFiles controls;
  final launch = List.filled(32, 'a').join();
  final source = List.filled(40, 'b').join();
  File control(String suffix) =>
      File(path.join(fixture.path, 'backend-host-$launch.$suffix'));

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('openbubbles-host-files-');
    resolved = fixture.resolveSymbolicLinksSync();
    selected = fixture;
    controls = WindowsBackendHostFiles(() => selected, launch);
  });
  tearDown(() {
    expect(fixture.resolveSymbolicLinksSync(), resolved);
    expect(path.basename(fixture.path), startsWith('openbubbles-host-files-'));
    expect(
      FileSystemEntity.typeSync(fixture.path, followLinks: false),
      FileSystemEntityType.directory,
    );
    fixture.deleteSync(recursive: true);
  });

  test('fresh private endpoint cannot overwrite or reuse a launch', () {
    controls.requireFreshLaunch();
    controls.publishReady(
      Uri.parse('ws://127.0.0.1:1234/synthetic-token/ws'),
      source,
      42,
    );
    final saved = jsonDecode(control('json').readAsStringSync()) as Map;
    expect(saved['launchId'], launch);
    expect(saved['source'], source);
    expect(saved['pid'], 42);
    expect(
      () => controls.publishReady(
        Uri.parse('ws://127.0.0.1:1234/replacement/ws'),
        source,
        42,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(() => controls.requireFreshLaunch(), throwsStateError);
    expect(jsonDecode(control('json').readAsStringSync()), saved);
  });

  test('stop must bind the exact current owner', () {
    expect(controls.stopRequested(), isFalse);
    control('stop').writeAsStringSync(List.filled(32, 'c').join());
    expect(() => controls.stopRequested(), throwsStateError);
    control('stop').writeAsStringSync('$launch\n');
    expect(() => controls.stopRequested(), throwsStateError);
    control('stop').writeAsStringSync(launch);
    expect(controls.stopRequested(), isTrue);
  });

  Map<String, Object?> sourceRequest() => {
    'schema': 1, 'launchId': launch, 'source': source, 'pid': 42,
    'rowId': 4, 'generation': 1, 'sequence': 4,
    'changeIdHash': List.filled(43, 'c').join(),
    'recordIdHash': List.filled(43, 'd').join(), 'etagHash': null,
    'payloadSha256': List.filled(64, 'e').join(),
    'referenceSha256': List.filled(64, 'f').join(),
  };

  test('source inspection consumes once under the exact live owner', () {
    controls.publishReady(Uri.parse('ws://127.0.0.1:1234/token/ws'), source, 42);
    expect(controls.takeChatSourceInspection(source, 42), isNull);
    control('chat-source.json').writeAsStringSync(jsonEncode(sourceRequest()));
    expect(controls.takeChatSourceInspection(source, 42), sourceRequest());
    expect(control('chat-source-started.json').existsSync(), isTrue);
    expect(controls.takeChatSourceInspection(source, 42), isNull);
    controls.publishChatSourceInspection(source, 42, {'completed': true});
    expect(() => controls.publishChatSourceInspection(source, 42, {'completed': true}),
      throwsA(isA<FileSystemException>()));
  });

  test('source inspection rejects stale owner, extra fields and preseeded launch', () {
    controls.publishReady(Uri.parse('ws://127.0.0.1:1234/token/ws'), source, 42);
    for (final bad in [
      {...sourceRequest(), 'pid': 43},
      {...sourceRequest(), 'launchId': List.filled(32, 'd').join()},
      {...sourceRequest(), 'rawPayload': 'not accepted'},
      {...sourceRequest(), 'rowId': 0},
      {...sourceRequest(), 'referenceSha256': 'not-a-digest'},
    ]) {
      control('chat-source.json').writeAsStringSync(jsonEncode(bad));
      expect(() => controls.takeChatSourceInspection(source, 42), throwsStateError);
      expect(control('chat-source-started.json').existsSync(), isFalse);
    }
    control('json').deleteSync();
    control('chat-source.json').writeAsStringSync(jsonEncode(sourceRequest()));
    expect(() => controls.requireFreshLaunch(), throwsStateError);
  });

  test('endpoint refuses nonlocal and unauthenticated VM services', () {
    for (final endpoint in [
      'ws://example.com:1234/token/ws',
      'ws://127.0.0.1:1234/ws',
      'http://127.0.0.1:1234/token/ws',
      'ws://user@127.0.0.1:1234/token/ws',
      'ws://127.0.0.1:1234/token/ws?alternate=1',
    ]) {
      expect(
        () => controls.publishReady(Uri.parse(endpoint), source, 42),
        throwsStateError,
      );
      expect(control('json').existsSync(), isFalse);
    }
  });

  test(
    'partial stop publication waits briefly then requires the same owner',
    () {
      var elapsed = 100;
      controls = WindowsBackendHostFiles(
        () => selected,
        launch,
        elapsedMilliseconds: () => elapsed,
      );
      control('stop').createSync();
      expect(controls.stopRequested(), isFalse);
      elapsed = 500;
      control('stop').writeAsStringSync(launch.substring(0, 12));
      expect(controls.stopRequested(), isFalse);
      elapsed = 2099;
      control('stop').writeAsStringSync(launch);
      expect(controls.stopRequested(), isTrue);
    },
  );

  test('unfinished stop publication refuses at its bounded deadline', () {
    var elapsed = 100;
    controls = WindowsBackendHostFiles(
      () => selected,
      launch,
      elapsedMilliseconds: () => elapsed,
    );
    control('stop').createSync();
    expect(controls.stopRequested(), isFalse);
    elapsed = 2100;
    expect(() => controls.stopRequested(), throwsStateError);
    control('stop').writeAsStringSync(launch);
    expect(() => controls.stopRequested(), throwsStateError);
  });

  test('changed root cannot steer path or stop access', () {
    final other = Directory(path.join(fixture.path, 'other'))..createSync();
    selected = other;
    expect(() => controls.stopRequested(), throwsStateError);
    expect(
      () => controls.publishReady(
        Uri.parse('ws://127.0.0.1:1234/token/ws'),
        source,
        42,
      ),
      throwsStateError,
    );
    expect(other.listSync(), isEmpty);
  });

  test('closed receipt refuses a different ready owner', () {
    controls.publishReady(
      Uri.parse('ws://127.0.0.1:1234/token/ws'),
      source,
      42,
    );
    expect(() => controls.publishClosed(source, 43), throwsStateError);
    expect(control('json').existsSync(), isTrue);
    expect(control('closed.json').existsSync(), isFalse);
    controls.publishClosed(source, 42);
    final closed = jsonDecode(control('closed.json').readAsStringSync()) as Map;
    expect(control('json').existsSync(), isFalse);
    for (final field in [
      'protectedWorkDrained',
      'nativeHandlesReleased',
      'storeClosed',
      'rustDisposed',
    ]) {
      expect(closed[field], isTrue);
    }
    expect(() => controls.requireFreshLaunch(), throwsStateError);
  });
}
