import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'backend_harness_protocol.dart';

bool _registered = false;

/// Registration is absent from normal builds. No arbitrary expressions,
/// filesystem paths, shell commands or native method names are accepted.
bool registerBackendHarnessExtension(
  BackendHarnessEngine engine, {
  bool isolatedWindowsProfile = false,
}) {
  if (!BackendHarnessGate.allowed(
        compiled: BackendHarnessGate.compiledIn,
        debug: kDebugMode,
        platform: engine.platform,
        package: engine.package,
        isolatedWindowsProfile: isolatedWindowsProfile,
      ) ||
      !engine.enabled ||
      _registered) {
    return false;
  }
  final isolateId = developer.Service.getIsolateId(Isolate.current);
  if (isolateId == null) return false;
  developer.registerExtension(backendHarnessExtension, (_, parameters) async {
    final result = await handleBackendHarnessExtension(
      engine,
      parameters,
      expectedIsolateId: isolateId,
    );
    return developer.ServiceExtensionResponse.result(jsonEncode(result));
  });
  _registered = true;
  return true;
}

@visibleForTesting
Future<Map<String, Object?>> handleBackendHarnessExtension(
  BackendHarnessEngine engine,
  Map<String, String> parameters, {
  String? expectedIsolateId,
}) async {
  if (parameters.containsKey('isolateId')) {
    if (expectedIsolateId == null ||
        parameters['isolateId'] != expectedIsolateId) {
      return _invalidRequest();
    }
    parameters = Map<String, String>.of(parameters)..remove('isolateId');
  }
  if (parameters.containsKey('request') && parameters.length <= 2) {
    final encoded = parameters['request']!;
    if (encoded.length <= 65536) {
      try {
        final request = jsonDecode(encoded);
        final hello = request is Map && request['action'] == 'hello';
        if (hello && parameters.length == 1) {
          return await engine.execute(request);
        }
        final session = parameters['sessionId'];
        if (!hello &&
            parameters.length == 2 &&
            session != null &&
            RegExp(r'^[a-f0-9]{32}$').hasMatch(session)) {
          return await engine.execute(request, expectedSessionId: session);
        }
      } catch (_) {
        // Never serialize a decoder, VM, account or backend exception.
      }
    }
  }
  return _invalidRequest();
}

Map<String, Object?> _invalidRequest() => {
  'protocol': 1,
  'requestId': 'invalid',
  'action': 'hello',
  'ok': false,
  'code': 'backend_invalid_request',
  'state': 'blocked',
  'jobId': null,
  'data': <String, Object>{},
};
