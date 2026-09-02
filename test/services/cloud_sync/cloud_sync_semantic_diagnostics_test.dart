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
      'canonical_message_chat_candidate_opposite_group_id_unique_style_direct',
      'canonical_message_chat_candidate_original_group_id_unique',
      'canonical_message_chat_candidate_opposite_service_identifier_unique',
      'canonical_message_chat_reference_cross_service_group_id',
      'canonical_preexisting_ownership_bootstrap',
      'decoder_malformed_record',
      'native_quarantined_malformed_record',
      'projection_repaired_attachment_capability',
      'retained_backlog_failure_dependency',
      'retained_projection_window_has_more',
    ]) {
      diagnostics.record(code);
    }

    expect(diagnostics.snapshot().keys, <String>[
      'canonical_identity_guid_invalid',
      'canonical_message_chat_candidate_opposite_group_id_unique_style_direct',
      'canonical_message_chat_candidate_opposite_service_identifier_unique',
      'canonical_message_chat_candidate_original_group_id_unique',
      'canonical_message_chat_reference_cross_service_group_id',
      'canonical_preexisting_ownership_bootstrap',
      'decoder_malformed_record',
      'native_quarantined_malformed_record',
      'projection_repaired_attachment_capability',
      'retained_backlog_failure_dependency',
      'retained_projection_window_has_more',
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

  test('rejects unbounded raw chat styles from persisted diagnostics', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    diagnostics.record(
      'canonical_message_chat_candidate_opposite_group_id_unique_style_45',
    );

    expect(diagnostics.snapshot(), <String, int>{'diagnostic_code_invalid': 1});
  });
}
