// Private stdin transport for the compiled backend extension. Accepted jobs
// return immediately; job.status requires a separate explicit request. Never
// retry a timed-out submission, including with a new requestId.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

import 'backend_harness_dispatch_journal.dart';
export 'backend_harness_dispatch_journal.dart';

const backendHarnessHostLimit = 65536;
final _token = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _session = RegExp(r'^[0-9a-f]{32}$');
final _source = RegExp(r'^[0-9a-f]{40}$');

/// Only closed protocol codes cross the host error boundary. An RPC timeout
/// leaves its underlying call alone and may mean the command is still running.
final class BackendHarnessHostFailure implements Exception {
  const BackendHarnessHostFailure(this.code, {this.outcomeUncertain = false});
  final String code;
  final bool outcomeUncertain;
  @override
  String toString() => 'BackendHarnessHostFailure($code)';
}

Never _reject([String code = 'backend_invalid_request']) =>
    throw BackendHarnessHostFailure(code);

bool _keys(Map value, Set<String> keys) =>
    value.length == keys.length && keys.containsAll(value.keys);

bool _bounded(Object? value, [int depth = 0]) {
  if (depth > 8) return false;
  if (value == null || value is String || value is bool || value is int) {
    return true;
  }
  if (value is List) {
    return value.length <= 128 && value.every((v) => _bounded(v, depth + 1));
  }
  if (value is Map) {
    return value.length <= 32 && value.entries.every(
      (e) => e.key is String && _bounded(e.value, depth + 1),
    );
  }
  return false;
}

Map<String, Object?> _copy(Map value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

Map<String, Object?> validateBackendHarnessRequest(Object? raw) {
  if (raw is! Map ||
      !_keys(raw, {'protocol', 'requestId', 'action', 'arguments'}) ||
      raw['protocol'] is! int || raw['protocol'] != backendHarnessProtocol ||
      raw['requestId'] is! String || !_token.hasMatch(raw['requestId']) ||
      !backendHarnessActions.contains(raw['action']) ||
      raw['arguments'] is! Map || !_bounded(raw['arguments'])) {
    _reject();
  }
  if (utf8.encode(jsonEncode(raw)).length > backendHarnessHostLimit) _reject();
  final arguments = raw['arguments'] as Map;
  if (raw['action'] == 'hello' && arguments.isNotEmpty) _reject();
  if (raw['action'] == 'job.status' &&
      (!_keys(arguments, {'jobId'}) || arguments['jobId'] is! String ||
       !_session.hasMatch(arguments['jobId']))) {
    _reject();
  }
  return _copy(raw);
}

final class BackendHarnessPrivateInput {
  BackendHarnessPrivateInput._(this.uri, this.source, this.package, this.request,
      this.dispatchJournal);
  final Uri uri;
  final String source;
  final String package;
  final Map<String, Object?> request;
  // Optional private host admission metadata; never passed to the extension.
  final Map<String, String>? dispatchJournal;
  @override
  String toString() => 'BackendHarnessPrivateInput(redacted)';
}

BackendHarnessPrivateInput validateBackendHarnessInput(Object? raw) {
  if (raw is! Map ||
      !(_keys(raw, {'uri', 'expected_source', 'expected_package', 'request'}) ||
        _keys(raw, {'uri', 'expected_source', 'expected_package', 'request',
          'dispatch_journal'})) ||
      raw['uri'] is! String || raw['expected_source'] is! String ||
      !_source.hasMatch(raw['expected_source']) ||
      raw['expected_package'] is! String ||
      !RegExp(r'^[A-Za-z0-9_.-]{1,200}$').hasMatch(raw['expected_package']) ||
      !_bounded(raw) ||
      utf8.encode(jsonEncode(raw)).length > backendHarnessHostLimit) {
    _reject();
  }
  Map<String, String>? journal;
  if (raw.containsKey('dispatch_journal')) {
    final claim = raw['dispatch_journal'];
    if (claim is! Map || !_keys(claim, {'directory', 'run_owner'}) ||
        claim['directory'] is! String || (claim['directory'] as String).isEmpty ||
        (claim['directory'] as String).length > 4096 ||
        claim['run_owner'] is! String || !_session.hasMatch(claim['run_owner'])) {
      _reject();
    }
    journal = Map<String, String>.unmodifiable(Map<String, String>.from(claim));
  }
  final uri = Uri.tryParse(raw['uri']);
  if (uri == null || uri.scheme != 'ws' ||
      !{'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
      !uri.hasPort || uri.port <= 0 || uri.port > 65535 || uri.port == 5037 ||
      uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
      !RegExp(r'^/[A-Za-z0-9_=-]+/ws$').hasMatch(uri.path)) {
    _reject();
  }
  return BackendHarnessPrivateInput._(uri, raw['expected_source'],
      raw['expected_package'], validateBackendHarnessRequest(raw['request']), journal);
}

void _payload(Map data) {
  if (!data.keys.toSet().containsAll({'phase', 'flags', 'counts'}) ||
      !const {'phase', 'flags', 'counts', 'challenge', 'fixture'}.containsAll(data.keys) ||
      !BackendHarnessPhase.values.any((p) => p.name == data['phase']) ||
      data['flags'] is! Map || data['counts'] is! Map) {
    _reject();
  }
  final flags = data['flags'] as Map;
  final counts = data['counts'] as Map;
  if (!BackendHarnessPayload.flagNames.containsAll(flags.keys) ||
      flags.values.any((v) => v is! bool) ||
      !BackendHarnessPayload.countNames.containsAll(counts.keys) ||
      counts.values.any((v) => v is! int || v < 0 || v > 1000000000)) {
    _reject();
  }
  if (data.containsKey('challenge')) {
    final c = data['challenge'];
    if (c is! Map || !_keys(c, {'id', 'kind', 'options'}) ||
        c['id'] is! String || !_session.hasMatch(c['id']) ||
        !BackendHarnessChallengeKind.values.any((k) => k.name == c['kind']) ||
        c['options'] is! int ||
        (const {'trustedDevice', 'smsDestination'}.contains(c['kind'])
            ? c['options'] < 1 || c['options'] > 64 : c['options'] != 0)) {
      _reject();
    }
  }
  if (data.containsKey('fixture') && !BackendHarnessFixtureReceipt.validJson(data['fixture'])) {
    _reject();
  }
}

/// The full validated reply is private API output. CLI projection below omits
/// even valid hello source/package/session/manifest metadata.
Map<String, Object?> validateBackendHarnessReply(Object? raw, {
  required String requestId, required String action,
}) {
  if (raw is! Map || !_keys(raw, {
        'protocol', 'requestId', 'action', 'ok', 'code', 'state', 'jobId', 'data',
      }) || raw['protocol'] is! int || raw['protocol'] != backendHarnessProtocol ||
      raw['requestId'] != requestId || raw['action'] != action ||
      !_token.hasMatch(requestId) || !backendHarnessActions.contains(action) ||
      !backendHarnessCodes.contains(raw['code']) || raw['ok'] is! bool ||
      !{'accepted', 'running', 'completed', 'blocked', 'failed'}.contains(raw['state']) ||
      raw['ok'] != !{'blocked', 'failed'}.contains(raw['state']) ||
      (raw['jobId'] != null &&
       (raw['jobId'] is! String || !_session.hasMatch(raw['jobId']))) ||
      raw['data'] is! Map || !_bounded(raw) ||
      utf8.encode(jsonEncode(raw)).length > backendHarnessHostLimit) {
    _reject();
  }
  final data = raw['data'] as Map;
  final state = raw['state'];
  final code = raw['code'];
  if ((state == 'accepted' || state == 'running') &&
      (raw['jobId'] == null || !{'backend_job_accepted', 'backend_job_running',
        'backend_auth_challenge'}.contains(code))) {
    _reject();
  }
  if (code == 'backend_job_completed' &&
      (state != 'completed' || raw['jobId'] == null)) {
    _reject();
  }
  if (state == 'completed' &&
      !((code == 'backend_ready' && raw['jobId'] == null) ||
        (code == 'backend_job_completed' && raw['jobId'] != null))) {
    _reject();
  }
  if (action == 'hello' && raw['ok'] == true) {
    if (state != 'completed' || code != 'backend_ready' || raw['jobId'] != null ||
        !_keys(data, {'source', 'package', 'platform', 'sessionId', 'mode', 'actions'}) ||
        data['source'] is! String || !_source.hasMatch(data['source']) ||
        data['package'] is! String ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,200}$').hasMatch(data['package']) ||
        !{'android', 'windows'}.contains(data['platform']) ||
        data['sessionId'] is! String || !_session.hasMatch(data['sessionId']) ||
        data['mode'] != 'backend' || data['actions'] is! List) {
      _reject();
    }
    final actions = (data['actions'] as List).toSet();
    if (actions.length != (data['actions'] as List).length ||
        !backendHarnessActions.containsAll(actions) ||
        !actions.containsAll({'hello', 'job.status'})) {
      _reject();
    }
  } else if (data.isNotEmpty) {
    _payload(data);
  } else if (state == 'completed' && raw['ok'] == true) {
    _reject();
  }
  return _copy(raw);
}

Map<String, Object?> backendHarnessPublicReceipt(Map<String, Object?> reply) {
  final value = validateBackendHarnessReply(reply,
      requestId: reply['requestId'] as String, action: reply['action'] as String);
  if (value['action'] == 'hello' && value['ok'] == true) {
    value['data'] = <String, Object?>{};
  } else {
    (value['data'] as Map).remove('fixture');
  }
  return value;
}

final class BackendHarnessVmClient {
  BackendHarnessVmClient(this.service, {
    required this.expectedSource, required this.expectedPackage,
    this.timeout = const Duration(seconds: 20),
    this.dispatchJournal,
  });
  final vm.VmService service;
  final String expectedSource;
  // Exact caller/runtime metadata pin on both platforms. The compiled app's
  // registration gate owns Android flavor and isolated Windows admission;
  // this client never substitutes a personal Canary or Windows package name.
  final String expectedPackage;
  final Duration timeout;
  final BackendHarnessDispatchJournal? dispatchJournal;
  String? _isolateId;
  String? _sessionId;
  final _requestIds = <String>{};

  Future<T> _rpc<T>(Future<T> Function() action, {bool submitted = false}) async {
    try {
      return await action().timeout(timeout);
    } on TimeoutException {
      throw BackendHarnessHostFailure('backend_job_unknown', outcomeUncertain: submitted);
    } catch (_) {
      throw BackendHarnessHostFailure('backend_internal_error', outcomeUncertain: submitted);
    }
  }

  Future<String> _select() async {
    if (_isolateId != null) return _isolateId!;
    final machine = await _rpc(service.getVM);
    final refs = machine.isolates;
    if (refs == null || refs.length > 64) _reject('backend_not_ready');
    final matches = <String>{};
    for (final ref in refs) {
      if (ref.id == null) _reject('backend_not_ready');
      final isolate = await _rpc(() => service.getIsolate(ref.id!));
      if (isolate.extensionRPCs?.contains(backendHarnessExtension) == true) {
        matches.add(ref.id!);
      }
    }
    if (matches.length != 1) _reject('backend_not_ready');
    return _isolateId = matches.single;
  }

  Future<Map<String, Object?>> _call(String isolate, Map<String, Object?> request,
      {bool submitted = false, String? expectedSessionId}) async {
    final hello = request['action'] == 'hello';
    if (hello ? expectedSessionId != null :
        expectedSessionId == null || !_session.hasMatch(expectedSessionId)) {
      _reject('backend_stale_session');
    }
    dispatchJournal?.assertOwned();
    final result = await _rpc(() => service.callServiceExtension(
        backendHarnessExtension, isolateId: isolate,
        args: {'request': jsonEncode(request),
          if (!hello) 'sessionId': expectedSessionId!}), submitted: submitted);
    try {
      return validateBackendHarnessReply(result.json,
          requestId: request['requestId'] as String, action: request['action'] as String);
    } catch (_) {
      throw BackendHarnessHostFailure('backend_invalid_request', outcomeUncertain: submitted);
    }
  }

  /// One command submission. A second call with that requestId is refused,
  /// including after an uncertain RPC timeout. Explicit job.status uses a new
  /// requestId and the accepted jobId; there is no automatic poll or retry.
  Future<Map<String, Object?>> execute(Object? raw) async {
    if (!_source.hasMatch(expectedSource) || expectedPackage.isEmpty ||
        timeout <= Duration.zero) {
      _reject();
    }
    final request = validateBackendHarnessRequest(raw);
    if (!_requestIds.add(request['requestId'] as String)) {
      _reject('backend_request_reused');
    }
    final recorder = dispatchJournal;
    final id = request['requestId'] as String;
    final action = request['action'] as String;
    if (recorder == null && backendHarnessActionRequiresJournal(action)) {
      _reject('backend_not_ready');
    }
    final requestedJob = action == 'job.status'
        ? (request['arguments'] as Map)['jobId'] as String : null;
    try {
      recorder?.admit(expectedSource: expectedSource, expectedPackage: expectedPackage,
          requestId: id, action: action, jobId: requestedJob);
    } on BackendHarnessDispatchJournalFailure catch (error) {
      throw BackendHarnessHostFailure(error.code);
    }
    var submitted = false;
    var recordingResult = false;
    try {
      final isolate = await _select();
      final hello = await _call(isolate, {
        'protocol': backendHarnessProtocol,
        'requestId': action == 'hello' ? id : 'host_hello',
        'action': 'hello', 'arguments': <String, Object?>{},
      });
      if (hello['ok'] != true) _reject(hello['code'] as String);
      final data = hello['data'] as Map;
      if (data['source'] != expectedSource) _reject('backend_source_mismatch');
      if (data['package'] != expectedPackage) _reject('backend_identity_changed');
      if (_sessionId != null && _sessionId != data['sessionId']) {
        _reject('backend_stale_session');
      }
      final pinnedSession = data['sessionId'] as String;
      _sessionId = pinnedSession;
      Map<String, Object?> reply = hello;
      if (action != 'hello') {
        if (!(data['actions'] as List).contains(action)) {
          _reject('backend_not_supported');
        }
        submitted = true;
        reply = await _call(isolate, request, submitted: true,
            expectedSessionId: pinnedSession);
        if (action == 'job.status' && reply['jobId'] != null &&
            reply['jobId'] != requestedJob) {
          _reject();
        }
      }
      recordingResult = true;
      recorder?.recordResult(requestId: id, action: action,
          code: reply['code'] as String, state: reply['state'] as String,
          jobId: reply['jobId'] as String?, outcomeUncertain:
              ((reply['data'] as Map)['flags'] as Map?)?['outcome_uncertain'] == true);
      return reply;
    } catch (error) {
      final failure = BackendHarnessHostFailure(
          error is BackendHarnessHostFailure ? error.code : 'backend_internal_error',
          outcomeUncertain: submitted ||
              (error is BackendHarnessHostFailure && error.outcomeUncertain));
      if (!recordingResult) {
        try {
          recorder?.recordResult(requestId: id, action: action, code: failure.code,
              state: 'blocked', jobId: requestedJob,
              outcomeUncertain: failure.outcomeUncertain);
        } catch (_) {
          throw BackendHarnessHostFailure('backend_not_ready',
              outcomeUncertain: failure.outcomeUncertain);
        }
      }
      throw failure;
    }
  }
}

Future<BackendHarnessPrivateInput> readBackendHarnessInput(Stream<List<int>> input) async {
  final bytes = BytesBuilder(copy: false);
  final iterator = StreamIterator(input);
  final watch = Stopwatch()..start();
  try {
    while (true) {
      final remaining = const Duration(seconds: 15) - watch.elapsed;
      if (remaining <= Duration.zero) _reject();
      if (!await iterator.moveNext().timeout(remaining)) break;
      final chunk = iterator.current;
      if (bytes.length + chunk.length > backendHarnessHostLimit) _reject();
      bytes.add(chunk);
    }
    return validateBackendHarnessInput(jsonDecode(utf8.decode(bytes.takeBytes())));
  } catch (_) {
    _reject();
  } finally {
    try { await iterator.cancel().timeout(const Duration(seconds: 1)); }
    catch (_) { /* Input cleanup cannot expose a private stream error. */ }
  }
}

Future<void> _disposeBackendHarnessConnection(vm.VmService service) async {
  try { await service.dispose().timeout(const Duration(seconds: 5)); }
  catch (_) { /* Closing this transport never cancels a backend job. */ }
}

/// Ownership stays attached to the original connection future after a timeout.
/// A late success is disposed, never used to submit or retry a command.
Future<vm.VmService> connectBackendHarness(BackendHarnessPrivateInput input, {
  Future<vm.VmService> Function(String)? connectionFactory,
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (timeout <= Duration.zero) _reject();
  var abandoned = false;
  vm.VmService? acquired;
  try {
    final pending = (connectionFactory ?? vmServiceConnectUri)(input.uri.toString());
    unawaited(pending.then<void>((connected) {
      acquired = connected;
      if (abandoned) unawaited(_disposeBackendHarnessConnection(connected));
    }, onError: (Object _, StackTrace __) {
      // The timed-out future may fail later; no private transport error escapes.
    }));
    return await pending.timeout(timeout);
  } catch (_) {
    abandoned = true;
    final connected = acquired;
    if (connected != null) await _disposeBackendHarnessConnection(connected);
    _reject('backend_not_ready');
  }
}

/// Closed CLI projection. False preserves the host's known uncertainty state;
/// it must not be interpreted as proof that no remote operation ever occurred.
Map<String, Object?> backendHarnessFailureReceipt(Object error, {
  BackendHarnessPrivateInput? input,
}) {
  final candidate = error is BackendHarnessHostFailure ? error.code :
      error is BackendHarnessDispatchJournalFailure ? error.code : null;
  final code = backendHarnessCodes.contains(candidate) ? candidate : 'backend_internal_error';
  final id = input?.request['requestId'];
  final action = input?.request['action'];
  return {
    'protocol': backendHarnessProtocol,
    'requestId': id is String && _token.hasMatch(id) ? id : 'host_failure',
    'action': backendHarnessActions.contains(action) ? action : 'hello',
    'ok': false, 'code': code, 'state': 'blocked', 'jobId': null,
    'data': BackendHarnessPayload(phase: BackendHarnessPhase.error, flags: {
      'outcome_uncertain': error is BackendHarnessHostFailure && error.outcomeUncertain,
    }).toJson(),
  };
}

Future<void> main(List<String> args) async {
  vm.VmService? service;
  BackendHarnessDispatchJournal? journal;
  BackendHarnessPrivateInput? input;
  try {
    if (args.isNotEmpty || stdin.hasTerminal || stdout.hasTerminal) _reject();
    input = await readBackendHarnessInput(stdin);
    final claim = input.dispatchJournal;
    if (claim != null) {
      journal = BackendHarnessDispatchJournal.open(evidenceDirectory: claim['directory']!,
          expectedSource: input.source, expectedPackage: input.package,
          runOwner: claim['run_owner']!);
    }
    service = await connectBackendHarness(input);
    final reply = await BackendHarnessVmClient(service,
        expectedSource: input.source, expectedPackage: input.package,
        dispatchJournal: journal).execute(input.request);
    stdout.writeln(jsonEncode(backendHarnessPublicReceipt(reply)));
    if (reply['ok'] != true) exitCode = 1;
  } catch (error) {
    stdout.writeln(jsonEncode(backendHarnessFailureReceipt(error, input: input)));
    exitCode = 1;
  } finally {
    if (service != null) await _disposeBackendHarnessConnection(service);
    try { journal?.close(); } catch (_) { exitCode = 1; }
  }
}
