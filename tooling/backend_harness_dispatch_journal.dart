// Host-only, append-only dispatch ownership. The caller supplies an existing
// private local directory and keeps its ACLs and contents under its control.
// An admission is consumed even if the process dies before sending the RPC.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

const backendHarnessJournalFileName = 'backend_harness_dispatch.journal.jsonl';
const _journalLimit = 8 * 1024 * 1024;
final _requestId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _hex32 = RegExp(r'^[0-9a-f]{32}$');
final _source = RegExp(r'^[0-9a-f]{40}$');
final _package = RegExp(r'^[A-Za-z0-9_.-]{1,200}$');
const _states = {'accepted', 'running', 'completed', 'blocked', 'failed'};

// A closed observation allowlist fails closed for new commands. These future
// writers do not become callable here until the compiled protocol exposes them.
const backendHarnessFutureWriterActions = {
  'fixture.send', 'fixture.edit', 'fixture.unsend',
};
bool backendHarnessActionRequiresJournal(String action) =>
    backendHarnessFutureWriterActions.contains(action) || !const {
      'hello', 'status', 'job.status', 'auth.status', 'pcs.devices',
      'archive.status', 'fixture.inspect', 'report.snapshot',
    }.contains(action);

final class BackendHarnessDispatchJournalFailure implements Exception {
  const BackendHarnessDispatchJournalFailure(this.code);
  final String code;
  @override
  String toString() => 'BackendHarnessDispatchJournalFailure($code)';
}

Never _fail([String code = 'backend_not_ready']) =>
    throw BackendHarnessDispatchJournalFailure(code);

bool _keys(Map value, Set<String> keys) =>
    value.length == keys.length && keys.containsAll(value.keys);

// Dart's POSIX FileLock is process-scoped: closing a second handle can drop
// another isolate's lock. Linux flock instead owns an open file description,
// so competing processes AND isolates cannot acquire this journal together.
// Windows FileLock already binds ownership to the individual open handle.
typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _Open = int Function(Pointer<Utf8>, int);
typedef _FlockNative = Int32 Function(Int32, Int32);
typedef _Flock = int Function(int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _Close = int Function(int);

final class _LinuxLock {
  _LinuxLock(String path) {
    final library = DynamicLibrary.process();
    final open = library.lookupFunction<_OpenNative, _Open>('open');
    _flock = library.lookupFunction<_FlockNative, _Flock>('flock');
    _close = library.lookupFunction<_CloseNative, _Close>('close');
    final name = path.toNativeUtf8();
    try { _fd = open(name, 2); } // O_RDWR; never create/truncate through libc.
    finally { malloc.free(name); }
    if (_fd < 0) _fail();
    if (_flock(_fd, 2 | 4) != 0) { // LOCK_EX | LOCK_NB, never wait/retry.
      _close(_fd);
      _fd = -1;
      _fail();
    }
  }
  int _fd = -1;
  late final _Flock _flock;
  late final _Close _close;
  void close() {
    if (_fd >= 0) {
      _flock(_fd, 8); // LOCK_UN; close also releases the OS-owned lock.
      _close(_fd);
      _fd = -1;
    }
  }
}

/// Holds one nonblocking OS lock until close/process exit. No reset, repair,
/// rotation, deletion, retry or native cancellation is provided. Incomplete or
/// invalid tails block ALL further admission while preserving every byte.
final class BackendHarnessDispatchJournal {
  BackendHarnessDispatchJournal._(this._file, this._linuxLock,
      this.source, this.package, this.runOwner);
  final RandomAccessFile _file;
  final _LinuxLock? _linuxLock;
  final String source;
  final String package;
  final String runOwner;
  final _admitted = <String, String>{};
  final _observed = <String>{};
  int _length = 0;
  bool _closed = false;
  bool _failed = false;

  static BackendHarnessDispatchJournal open({
    required String evidenceDirectory,
    required String expectedSource,
    required String expectedPackage,
    required String runOwner,
  }) {
    if (!_source.hasMatch(expectedSource) || !_package.hasMatch(expectedPackage) ||
        !_hex32.hasMatch(runOwner) || !p.isAbsolute(evidenceDirectory) ||
        p.split(evidenceDirectory).contains('..') ||
        (Platform.isWindows && evidenceDirectory.startsWith(r'\\')) ||
        !(Platform.isWindows || Platform.isLinux)) {
      _fail('backend_invalid_request');
    }
    RandomAccessFile? file;
    _LinuxLock? linuxLock;
    try {
      final directory = Directory(evidenceDirectory);
      final canonical = directory.resolveSymbolicLinksSync();
      if (!p.equals(p.normalize(evidenceDirectory), canonical) ||
          FileSystemEntity.typeSync(evidenceDirectory, followLinks: false) !=
              FileSystemEntityType.directory) {
        _fail();
      }
      final target = File(p.join(canonical, backendHarnessJournalFileName));
      var created = false;
      if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        // Exclusive creation cannot overwrite a racing owner's file. An empty
        // file left by a crash is deliberately not initialized on reopening.
        target.createSync(exclusive: true);
        created = true;
      }
      if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
          FileSystemEntityType.file) {
        _fail();
      }
      if (Platform.isLinux) linuxLock = _LinuxLock(target.path);
      file = target.openSync(mode: FileMode.append);
      if (Platform.isWindows) file.lockSync(FileLock.exclusive);
      final journal = BackendHarnessDispatchJournal._(
          file, linuxLock, expectedSource, expectedPackage, runOwner);
      if (created) {
        if (file.lengthSync() != 0) _fail();
        journal._append({
          'type': 'header', 'version': 1, 'source': expectedSource,
          'package': expectedPackage, 'runOwner': runOwner,
        });
      } else {
        journal._read();
      }
      return journal;
    } catch (error) {
      try { file?.closeSync(); } catch (_) { /* Keep failure private. */ }
      linuxLock?.close();
      if (error is BackendHarnessDispatchJournalFailure) rethrow;
      _fail();
    }
  }

  void _read() {
    _length = _file.lengthSync();
    if (_length == 0 || _length > _journalLimit) _fail();
    _file.setPositionSync(0);
    final bytes = _file.readSync(_length);
    if (bytes.length != _length || bytes.last != 10) _fail();
    final lines = utf8.decode(bytes).split('\n')..removeLast();
    final header = jsonDecode(lines.first);
    if (header is! Map || !_keys(header, {
      'type', 'version', 'source', 'package', 'runOwner',
    }) || header['type'] != 'header' || header['version'] is! int || header['version'] != 1) {
      _fail();
    }
    if (header['source'] != source) _fail('backend_source_mismatch');
    if (header['package'] != package || header['runOwner'] != runOwner) {
      _fail('backend_identity_changed');
    }
    for (final line in lines.skip(1)) {
      final entry = jsonDecode(line);
      if (entry is! Map || !_validEntry(entry)) _fail();
      final id = entry['requestId'] as String;
      final action = entry['action'] as String;
      if (entry['type'] == 'admit') {
        if (_admitted.containsKey(id)) _fail();
        _admitted[id] = action;
      } else if (_admitted[id] != action || !_observed.add(id)) {
        _fail();
      }
    }
  }

  static bool _validEntry(Map entry) => _keys(entry, {
    'type', 'requestId', 'action', 'jobId', 'code', 'state', 'outcomeUncertain',
  }) && _requestId.hasMatch(entry['requestId'] is String ? entry['requestId'] : '') &&
      backendHarnessActions.contains(entry['action']) &&
      (entry['jobId'] == null ||
          (entry['jobId'] is String && _hex32.hasMatch(entry['jobId']))) &&
      entry['outcomeUncertain'] is bool &&
      (entry['type'] == 'admit'
          ? entry['code'] == 'backend_job_unknown' && entry['state'] == 'unknown' &&
              entry['outcomeUncertain'] == true
          : entry['type'] == 'result' && backendHarnessCodes.contains(entry['code']) &&
              _states.contains(entry['state']));

  void _append(Map<String, Object?> entry) {
    if (_closed || _failed) _fail();
    try {
      final bytes = utf8.encode('${jsonEncode(entry)}\n');
      if (_file.lengthSync() != _length || _length + bytes.length > _journalLimit) {
        _fail();
      }
      _file.setPositionSync(_length);
      _file.writeFromSync(bytes);
      _file.flushSync(); // Must finish before the client can enter any RPC.
      _length += bytes.length;
    } catch (_) {
      _failed = true;
      _fail();
    }
  }

  void assertOwned() {
    if (_closed || _failed) _fail();
    try {
      if (_file.lengthSync() != _length) _fail();
    } catch (_) {
      _failed = true;
      _fail();
    }
  }

  /// Contains no arguments or session/native identity. An existing ID can never
  /// be admitted again, even for another action, a new client, or a new app boot.
  void admit({required String expectedSource, required String expectedPackage,
    required String requestId, required String action, String? jobId,
  }) {
    if (_closed || _failed) _fail();
    if (expectedSource != source) _fail('backend_source_mismatch');
    if (expectedPackage != package) _fail('backend_identity_changed');
    if (_admitted.containsKey(requestId)) _fail('backend_request_reused');
    final entry = <String, Object?>{
      'type': 'admit', 'requestId': requestId, 'action': action, 'jobId': jobId,
      'code': 'backend_job_unknown', 'state': 'unknown', 'outcomeUncertain': true,
    };
    if (!_validEntry(entry)) _fail('backend_invalid_request');
    _append(entry);
    _admitted[requestId] = action;
  }

  void recordResult({required String requestId, required String action,
    required String code, required String state, required bool outcomeUncertain,
    String? jobId,
  }) {
    final entry = <String, Object?>{
      'type': 'result', 'requestId': requestId, 'action': action, 'jobId': jobId,
      'code': code, 'state': state, 'outcomeUncertain': outcomeUncertain,
    };
    if (!_validEntry(entry) || _admitted[requestId] != action ||
        _observed.contains(requestId)) {
      _fail('backend_invalid_request');
    }
    _append(entry);
    _observed.add(requestId);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try { _file.closeSync(); }
    catch (_) { _fail(); }
    finally { _linuxLock?.close(); }
  }
}
