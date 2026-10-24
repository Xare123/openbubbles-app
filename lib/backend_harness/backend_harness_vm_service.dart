import 'dart:convert';
import 'dart:developer' as developer;

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
  developer.registerExtension(backendHarnessExtension, (_, parameters) async {
    final result = await handleBackendHarnessExtension(engine, parameters);
    return developer.ServiceExtensionResponse.result(jsonEncode(result));
  });
  _registered = true;
  return true;
}

@visibleForTesting
Future<Map<String, Object?>> handleBackendHarnessExtension(
  BackendHarnessEngine engine,
  Map<String, String> parameters,
) async {
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
  return {
    'protocol': 1,
    'requestId': 'invalid',
    'action': 'hello',
    'ok': false,
    'code': 'backend_invalid_request',
    'state': 'blocked',
    'jobId': null,
    'data': <String, Object>{},
  };
}
