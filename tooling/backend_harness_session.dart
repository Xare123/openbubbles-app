// Private, newline-framed host transport. Configuration has no acknowledgement;
// the caller sends hello as its first ordinary request. No implicit polling,
// reconnect, retry, cancellation or app operation is added by this transport.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:vm_service/vm_service.dart' as vm;

import 'vm_backend_harness.dart';

const backendHarnessSessionLimit = Duration(minutes: 25);
const _endOfInput = Object();

BackendHarnessPrivateInput validateBackendHarnessSessionConfig(Object? raw) {
  if (raw is! Map || raw.length != 4 || !const {
    'uri', 'expected_source', 'expected_package', 'dispatch_journal',
  }.containsAll(raw.keys)) {
    throw const BackendHarnessHostFailure('backend_invalid_request');
  }
  final input = validateBackendHarnessInput({...raw, 'request': {
    'protocol': backendHarnessProtocol, 'requestId': 'host_config_hello',
    'action': 'hello', 'arguments': <String, Object?>{},
  }});
  if (input.dispatchJournal == null) {
    throw const BackendHarnessHostFailure('backend_invalid_request');
  }
  return input;
}

/// Byte framing precedes UTF8/JSON decoding. The retained line never exceeds
/// 64 KiB; StreamIterator pauses upstream between chunks and request execution.
/// LF is excluded from the byte count. A final JSON frame may end at EOF.
final class _Frames {
  _Frames(Stream<List<int>> input) : _input = StreamIterator(input);
  final StreamIterator<List<int>> _input;
  List<int> _chunk = const [];
  int _offset = 0;
  bool _eof = false;

  Object? _decode(BytesBuilder bytes) {
    try { return jsonDecode(utf8.decode(bytes.takeBytes())); }
    on FormatException {
      throw const BackendHarnessHostFailure('backend_invalid_request');
    }
  }

  Future<Object?> next() async {
    final bytes = BytesBuilder(copy: false);
    while (true) {
      if (_offset == _chunk.length) {
        if (_eof || !await _input.moveNext()) {
          _eof = true;
          if (bytes.isEmpty) return _endOfInput;
          return _decode(bytes);
        }
        _chunk = _input.current;
        _offset = 0;
      }
      final start = _offset;
      while (_offset < _chunk.length && _chunk[_offset] != 10) {
        if (bytes.length + _offset - start == backendHarnessHostLimit) {
          throw const BackendHarnessHostFailure('backend_invalid_request');
        }
        _offset++;
      }
      bytes.add(_chunk.sublist(start, _offset));
      if (_offset < _chunk.length) {
        _offset++;
        return _decode(bytes);
      }
    }
  }

  Future<void> close() => _input.cancel();
}

/// One connection, journal and compiled client for the entire pipe lifetime.
/// The embedding caller must provide private pipes. No full reply is emitted
/// unless outputIsPipe is true. Durations are fixed host constraints, not wire
/// commands; the CLI uses 15 seconds / 25 minutes / the client's 20-second RPCs.
Future<int> runBackendHarnessSession({
  required Stream<List<int>> input,
  required Future<void> Function(Map<String, Object?>) writeReply,
  required bool inputIsPipe,
  required bool outputIsPipe,
  List<String> arguments = const [],
  Future<vm.VmService> Function(String)? connectionFactory,
  Duration firstFrameTimeout = const Duration(seconds: 15),
  Duration sessionTimeout = backendHarnessSessionLimit,
  Duration rpcTimeout = const Duration(seconds: 20),
}) {
  final finished = Completer<int>();
  final interrupted = Completer<BackendHarnessHostFailure>();
  var inFlight = false;
  void interrupt(BackendHarnessHostFailure failure) {
    if (!interrupted.isCompleted) interrupted.complete(failure);
  }

  // Socket-stream errors outside an awaited RPC are also contained. They end
  // the session through the same closed failure path, without native strings.
  runZonedGuarded(() async {
    final watch = Stopwatch()..start();
    vm.VmService? service;
    BackendHarnessDispatchJournal? journal;
    _Frames? frames;
    Map<String, Object?>? request;
    var writable = outputIsPipe;
    var replied = false;
    var status = 0;
    Timer? deadline;
    Duration remaining([Duration? cap]) {
      final left = sessionTimeout - watch.elapsed;
      if (left <= Duration.zero) return Duration.zero;
      return cap != null && cap < left ? cap : left;
    }

    Future<T> bounded<T>(Future<T> work) => Future.any([
      work, interrupted.future.then<T>((failure) => throw failure),
    ]);

    Future<void> emit(Map<String, Object?> reply) async {
      final validated = validateBackendHarnessReply(reply,
          requestId: reply['requestId'] as String, action: reply['action'] as String);
      try {
        await writeReply(validated).timeout(remaining());
        replied = true;
      } catch (_) {
        writable = false; // Never attempt a second line after a partial write.
        rethrow;
      }
    }

    Map<String, Object?> failureReply(Object error) {
      final closed = error is TimeoutException
          ? BackendHarnessHostFailure('backend_job_unknown', outcomeUncertain: inFlight)
          : error is BackendHarnessHostFailure || error is BackendHarnessDispatchJournalFailure
              ? error
              : BackendHarnessHostFailure('backend_internal_error', outcomeUncertain: inFlight);
      final reply = backendHarnessFailureReceipt(closed);
      if (request != null) {
        reply['requestId'] = request['requestId'];
        reply['action'] = request['action'];
      }
      return reply;
    }

    Future<void> quiet(Future<void> Function() close) async {
      try { await close().timeout(remaining(const Duration(seconds: 5))); }
      catch (_) { /* Only this host transport is closed; no native cancellation. */ }
    }

    try {
      if (!inputIsPipe || !outputIsPipe || arguments.isNotEmpty ||
          firstFrameTimeout <= Duration.zero || firstFrameTimeout > const Duration(seconds: 15) ||
          sessionTimeout <= Duration.zero || sessionTimeout > backendHarnessSessionLimit ||
          rpcTimeout <= Duration.zero || rpcTimeout > const Duration(seconds: 20)) {
        throw const BackendHarnessHostFailure('backend_invalid_request');
      }
      deadline = Timer(sessionTimeout, () => interrupt(BackendHarnessHostFailure(
          'backend_job_unknown', outcomeUncertain: inFlight)));
      frames = _Frames(input);
      final config = await bounded(frames.next().timeout(firstFrameTimeout));
      if (identical(config, _endOfInput)) {
        throw const BackendHarnessHostFailure('backend_invalid_request');
      }
      final claim = validateBackendHarnessSessionConfig(config);
      final owner = claim.dispatchJournal!;
      journal = BackendHarnessDispatchJournal.open(evidenceDirectory: owner['directory']!,
          expectedSource: claim.source, expectedPackage: claim.package, runOwner: owner['run_owner']!);
      // The existing helper owns late connections. Do not wrap it in a second
      // abandoned future: its own deadline is capped by the session lifetime.
      service = await connectBackendHarness(claim, connectionFactory: connectionFactory,
          timeout: remaining(const Duration(seconds: 15)));
      if (interrupted.isCompleted) throw await interrupted.future;
      final client = BackendHarnessVmClient(service, expectedSource: claim.source,
          expectedPackage: claim.package, dispatchJournal: journal, timeout: rpcTimeout);
      while (true) {
        request = null;
        replied = false;
        final raw = await bounded(frames.next());
        if (identical(raw, _endOfInput)) break;
        request = validateBackendHarnessRequest(raw); // Invalid frames end the session.
        inFlight = true;
        Map<String, Object?> reply;
        try {
          reply = await bounded(client.execute(request));
        } on BackendHarnessHostFailure catch (error) {
          if (interrupted.isCompleted) rethrow;
          reply = failureReply(error);
        } finally {
          // On a global timeout the outer failure retains its explicit true
          // uncertainty. The still-pending client future is never resubmitted.
          inFlight = false;
        }
        await emit(reply); // Full typed hello/fixture metadata stays private.
        if (const {'backend_source_mismatch', 'backend_identity_changed',
          'backend_stale_session'}.contains(reply['code'])) {
          status = 1;
          break;
        }
      }
    } catch (error) {
      status = 1;
      // This is a dispatch barrier for a late handshake before disposing the
      // connection. It never cancels or rolls back any remote/native job.
      try { journal?.close(); } catch (_) { /* Keep failures closed. */ }
      if (writable && !replied) {
        try { await emit(failureReply(error)); } catch (_) { /* Broken private pipe. */ }
      }
    } finally {
      try { journal?.close(); } catch (_) { status = 1; }
      await Future.wait([
        if (service != null) quiet(service.dispose),
        if (frames != null) quiet(frames.close),
      ]);
      deadline?.cancel();
      finished.complete(status);
    }
  }, (Object _, StackTrace __) {
    interrupt(BackendHarnessHostFailure('backend_internal_error', outcomeUncertain: inFlight));
  }, zoneSpecification: ZoneSpecification(print: (_, __, ___, ____) {
    // No incidental VM/library print may contaminate the private frame stream.
  }));
  return finished.future;
}

Future<void> main(List<String> args) async {
  try {
    // Consume sink errors as well as awaited flush failures; never print them.
    unawaited(stdout.done.catchError((Object _) {}));
    exitCode = await runBackendHarnessSession(input: stdin,
        inputIsPipe: stdioType(stdin) == StdioType.pipe,
        outputIsPipe: stdioType(stdout) == StdioType.pipe, arguments: args,
        writeReply: (reply) async {
          stdout.add(utf8.encode('${jsonEncode(reply)}\n'));
          await stdout.flush();
        });
  } catch (_) { exitCode = 1; }
}
