import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('records sorted bounded content-free diagnostic counts', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    diagnostics.record('native_ready');
    diagnostics.record('apply_dependency');
    diagnostics.record('native_ready');

    expect(diagnostics.snapshot(), <String, int>{
      'apply_dependency': 1,
      'native_ready': 2,
    });
  });

  test('invalid diagnostic input cannot interrupt semantic projection', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final candidate in const <String>[
      'message body or identifier',
      '1234567890',
      'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      'protected_reference_not_reviewed',
    ]) {
      diagnostics.record(candidate);
    }

    expect(diagnostics.snapshot(), <String, int>{'diagnostic_code_invalid': 4});
  });

  test('accepts only reviewed fixed and typed diagnostic families', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final code in const <String>[
      'canonical_identity_guid_invalid',
      'canonical_message_chat_candidate_original_group_id_unique',
      'decoder_malformed_record',
      'native_quarantined_malformed_record',
      'retained_backlog_failure_dependency',
    ]) {
      diagnostics.record(code);
    }

    expect(diagnostics.snapshot().keys, <String>[
      'canonical_identity_guid_invalid',
      'canonical_message_chat_candidate_original_group_id_unique',
      'decoder_malformed_record',
      'native_quarantined_malformed_record',
      'retained_backlog_failure_dependency',
    ]);
  });

  test('persisted snapshots reject syntactically valid unreviewed keys', () {
    expect(
      () => CloudSyncSemanticDiagnosticCollector.validatedSnapshot(const {
        'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee': 1,
      }),
      throwsArgumentError,
    );
  });
}
