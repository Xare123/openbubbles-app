import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final gate = File(
    'tooling/pixel_cloudkit_write_gate.ps1',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final trigger = File(
    'tooling/vm_trigger_cloudkit_write.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final uploadMode = File(
    'tooling/vm_read_canary_upload_mode.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('write gate has separate prepare run and verify phases', () {
    expect(gate, contains("ValidateSet('prepare', 'run', 'verify')"));
    expect(gate, contains("if (\$Mode -eq 'prepare')"));
    expect(gate, contains("if (\$Mode -eq 'verify'"));
    expect(gate, contains('expected_guid_hash_required'));
    expect(gate, contains('evidence_directory_not_empty'));
    expect(gate, contains('source_commit_mismatch'));
  });

  test('write gate requires manual writer and automatic worker off', () {
    expect(gate, contains('--expect-manual-writer'));
    expect(gate, contains('automaticUploads = \$false'));
    expect(gate, contains('manual_writer_mode_failed'));
    expect(uploadMode, contains('--expect-manual-writer'));
    expect(
      uploadMode,
      contains("only['manualOutboundCanaryEnabled'] != manualWriterExpected"),
    );
    expect(uploadMode, contains("only['localSendRuntimeEnabled'] != false"));
    expect(uploadMode, contains("only['automaticWorkerCreated'] != false"));
    expect(trigger, contains('prepareCloudSyncV2OutboundWriter()'));
    expect(trigger, contains('selectCloudSyncV2ExactIntent('));
    expect(trigger, contains('runCloudSyncV2ExactIntentConfirmed(selected)'));
    expect(trigger, isNot(contains('_queueCloudSyncV2LocalSends')));
  });

  test('recipient is environment-only and content-free evidence is pinned', () {
    expect(gate, contains('OPENBUBBLES_CANARY_RECIPIENT'));
    expect(gate, contains('recipient_hash_mismatch'));
    expect(gate, contains('ExpectedVmWriteSha256'));
    expect(gate, contains('ExpectedVmReadUploadModeSha256'));
    expect(gate, isNot(contains('ExpectedRecipient =')));
    expect(trigger, contains('recipientSha256'));
    expect(trigger, isNot(contains("'recipient': recipient")));
  });

  test('device gate preserves app data and never targets Alpha', () {
    expect(gate, contains("'am', 'force-stop', \$CanaryPackage"));
    expect(gate, isNot(contains("'uninstall'")));
    expect(gate, isNot(contains("'pm', 'clear'")));
    expect(gate, isNot(contains('run-as rm')));
    expect(gate, isNot(contains('com.bluebubbles.messaging\'')));
    expect(gate, isNot(contains('deleteSync')));
  });

  test('timeout is unresolved and no phase auto-retries a write', () {
    expect(gate, contains('child_timeout_unresolved'));
    expect(trigger, contains('cloud_sync_write_operation_still_running'));
    expect('runCloudSyncV2ExactIntentConfirmed('.allMatches(trigger).length, 1);
    expect(gate, isNot(contains('while (\$true)')));
  });
}
