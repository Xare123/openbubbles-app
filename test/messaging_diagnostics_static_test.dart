import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  const root = '.';
  final smsReceiver = source('$root/android/app/src/main/java/com/bluebubbles/messaging/SMSReceiver.kt');
  final pduReceiver = source('$root/android/app/src/main/java/com/bluebubbles/messaging/PDUReceiver.kt');
  final smsLessAuth = source('$root/android/app/src/main/kotlin/com/bluebubbles/messaging/services/rustpush/SMSLessAuthGateway.kt');
  final actionHandler = source('$root/lib/services/backend/action_handler.dart');
  final dartDiagnostics = source('$root/lib/utils/diagnostics/messaging_diagnostics.dart');
  final androidDiagnostics = source('$root/android/app/src/main/kotlin/com/bluebubbles/messaging/diagnostics/MessagingDiagnostics.kt');

  test('telephony receivers do not log message contents or PDU bytes', () {
    expect(smsReceiver, isNot(contains('Log.')));
    expect(pduReceiver, isNot(contains('Base64')));
    expect(pduReceiver, isNot(contains('Log.')));
    expect(pduReceiver, isNot(contains('"PDU:')));
    expect(pduReceiver, isNot(contains('\\n$e')));
  });

  test('carrier authentication does not log subscriber or device identifiers', () {
    expect(smsLessAuth, isNot(contains('Log.')));
    expect(smsLessAuth, contains('MessagingDiagnostics.event'));
  });

  test('action handler does not log message text, chat GUIDs, or raw send errors', () {
    for (final forbidden in <String>[
      'New message: [\${m.text}]',
      'Updated message: [\${m.text}]',
      'for chat [\${c.guid}]',
      'GUID \${m.guid}',
      'Logger.error(\'Failed to send message!\'',
    ]) {
      expect(actionHandler, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(actionHandler, contains('MessagingDiagnostics.event'));
    expect(actionHandler, contains("'fallback_selected'"));
  });

  test('diagnostics use the fixed prefix, schema, and future-safe transport/provider enums', () {
    for (final diagnosticSource in <String>[dartDiagnostics, androidDiagnostics]) {
      expect(diagnosticSource, contains('openbubbles.messaging.diag.v1'));
      expect(diagnosticSource, contains('[MessagingDiag]'));
      expect(diagnosticSource, contains('operation_id'));
      expect(diagnosticSource, contains('run_id'));
      expect(diagnosticSource, contains('rcs'));
      expect(diagnosticSource, contains('gmessages_companion'));
    }
  });
}
