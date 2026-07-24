import 'dart:convert';

import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:uuid/uuid.dart';

/// Privacy-safe diagnostics for the current SMS/MMS forwarding paths.
///
/// The transport enum reserves `rcs` so captures remain forward-compatible,
/// but this app does not emit RCS events until it has a real RCS implementation.
abstract final class MessagingDiagnostics {
  static const String schema = 'openbubbles.messaging.diag.v1';
  static const String prefix = '[MessagingDiag]';
  static final String _runId = const Uuid().v4();

  static void event(
    String eventName, {
    String transport = 'unknown',
    String provider = 'openbubbles',
    String outcome = 'observed',
    String? code,
    int? durationMs,
  }) {
    final normalizedTransport = <String>{'sms', 'mms', 'rcs', 'unknown'}.contains(transport)
        ? transport
        : 'unknown';
    final normalizedProvider = <String>{'openbubbles', 'gmessages_companion', 'unknown'}.contains(provider)
        ? provider
        : 'unknown';
    final payload = <String, Object>{
      'schema': schema,
      'event': eventName,
      'run_id': _runId,
      'operation_id': const Uuid().v4(),
      'transport': normalizedTransport,
      'provider': normalizedProvider,
      'outcome': outcome,
    };
    if (code != null) payload['code'] = code;
    if (durationMs != null) payload['duration_ms'] = durationMs;
    Logger.info('$prefix${jsonEncode(payload)}', tag: 'MessagingDiag');
  }

  static void failure(
    String eventName, {
    required String transport,
    required Object error,
    String provider = 'openbubbles',
    int? durationMs,
  }) {
    event(
      eventName,
      transport: transport,
      provider: provider,
      outcome: 'failure',
      code: error.runtimeType.toString(),
      durationMs: durationMs,
    );
  }
}
