import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_windows_writer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> selector() => {'operationId': 'op1:${'a' * 64}',
    'chatId': 3, 'intentId': 2,
    'retainedRecoveryOwner': '11111111-2222-4333-8444-555555555555'};

  test('Message recovery selects one exact existing owner and accepts no write overrides', () {
    expect(backendHarnessValidMessageArchiveRecovery(selector()), isTrue);
    for (final key in selector().keys) {
      expect(backendHarnessValidMessageArchiveRecovery(selector()..remove(key)), isFalse);
    }
    for (final extra in ['resend', 'clearQuarantine', 'send', 'save', 'newLease', 'reset']) {
      expect(backendHarnessValidMessageArchiveRecovery({...selector(), extra: true}), isFalse);
    }
    for (final bad in [0, -1, '2', true, null]) {
      expect(backendHarnessValidMessageArchiveRecovery({...selector(), 'intentId': bad}), isFalse);
    }
  });

  test('handoff status claims neither a save nor readback or enabled scope', () {
    expect(backendHarnessActions, contains('archive.recover-message'));
    final result = const BackendHarnessPayload(flags: {
      'message_recovery_ready': true, 'message_recovery_record_retained': true,
    }).toJson();
    expect((result['flags'] as Map).keys, unorderedEquals([
      'message_recovery_ready', 'message_recovery_record_retained']));
    expect(result.toString(), isNot(contains('operationId')));
  });

  test('known failure classes stay closed and unknown errors remain redacted', () {
    for (final entry in {
      'protected_outbound_lease_missing': 'backend_message_recovery_receipt_missing',
      'cloud_sync_message_archive_recovery_changed': 'backend_message_recovery_binding_changed',
      'cloud_sync_message_archive_recovery_origin_invalid': 'backend_message_recovery_ineligible',
      'cloud_sync_local_send_identity_changed': 'backend_message_recovery_auth_unavailable',
    }.entries) {
      expect(backendHarnessMessageArchiveRecoveryFailureCode(StateError(entry.key)), entry.value);
      expect(backendHarnessMessageArchiveRecoveryFailureCode(CloudSyncFailure(
        category: CloudFailureCategory.localStorage, safeCode: entry.key)), entry.value);
      expect(() => BackendHarnessFailure(entry.value), returnsNormally);
    }
    expect(backendHarnessMessageArchiveRecoveryFailureCode(StateError('private account and native payload')),
      'backend_job_failed');
  });
}
