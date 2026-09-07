import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_local_write.dart';
import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

void main() {
  test('registration diagnostics expose fixed causes, never raw server data', () {
    expect(cloudSyncWindowsWriteFailureCode(AnyhowException(
      'Registration Error An alias was just removed from your account. Try again. (5052)')),
      'cloud_sync_windows_sender_alias_changed');
    expect(cloudSyncWindowsWriteFailureCode(AnyhowException(
      'Registration Error Bad authentication. (6005)')),
      'cloud_sync_windows_sender_bad_authentication');
    expect(cloudSyncWindowsWriteFailureCode(AnyhowException('secret raw server data')),
      'cloud_sync_unknown_failure');
    expect(cloudSyncWindowsWriteFailureCode(AnyhowException('cloud_sync_windows_sender_auth_required')),
      'cloud_sync_windows_sender_auth_required');
  });
  Map<String, dynamic> request() => {
    'version': 1, 'id': 'qualification-1', 'allowSend': true,
    'recipient': '+15555550100', 'sender': 'sender@example.com', 'text': 'Test',
  };
  test('writer mode is explicit and exclusive', () {
    expect(CloudSyncV2WindowsHarnessOperation.parse([
      'local-write', '--launch-id=0123456789abcdef0123456789abcdef',
    ]), CloudSyncV2WindowsHarnessOperation.localWrite);
    expect(() => CloudSyncV2WindowsHarnessOperation.parse([
      'local-write', 'run-once', '--launch-id=0123456789abcdef0123456789abcdef',
    ]), throwsStateError);
  });
  test('request requires explicit authorization and bounded input', () {
    for (final changes in [
      {'allowSend': false}, {'version': 2}, {'id': '../escape'},
      {'recipient': 'someone@example.com'}, {'sender': 'mailto:sender@example.com'},
      {'text': ''}, {'text': 'x' * 513},
    ]) {
      expect(() => CloudSyncWindowsWriteRequest.fromJson({...request(), ...changes}),
        throwsStateError);
    }
  });
  test('replay binds request id, body, recipient and sender', () {
    final original = CloudSyncWindowsWriteRequest.fromJson(request());
    expect(original.binding, CloudSyncWindowsWriteRequest.fromJson(request()).binding);
    for (final changes in [
      {'id': 'qualification-2'}, {'text': 'Changed'},
      {'sender': 'changed@example.com'}, {'recipient': '+15555550101'},
    ]) {
      expect(original.binding,
        isNot(CloudSyncWindowsWriteRequest.fromJson({...request(), ...changes}).binding));
    }
  });
  test('Windows composition uses production gates and no blanket runtime', () {
    final source = File('lib/cloud_sync_v2_windows_local_write.dart').readAsStringSync();
    expect(source, contains('initialOwnerOnly: true'));
    expect(source, contains('runExactIntent('));
    expect(source, isNot(contains('.forTest(')));
    expect(source.indexOf('claim.create(exclusive: true)'),
      lessThan(source.indexOf('await sendConfirmed(wire)')));
    expect(source.indexOf('journal.saveSubmission('),
      lessThan(source.indexOf('await sendConfirmed(wire)')));
    expect(source.indexOf('await sendConfirmed(wire)'),
      lessThan(source.indexOf('journal.recordNativeSendConfirmation(')));
    final launcher = File('tooling/windows/run_cloud_sync_v2_dev.ps1').readAsStringSync();
    expect(launcher, contains(r'if ($LocalWrite)'));
    expect(launcher, isNot(contains('OPENBUBBLES_CLOUD_SYNC_V2_LOCAL_SEND_RUNTIME=true')));
  });
}
