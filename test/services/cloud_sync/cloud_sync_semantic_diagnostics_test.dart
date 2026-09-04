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
      'edit_revision_mismatch',
      'immutable_content_mismatch',
      'legacy_ownership_repair_candidate',
      'legacy_ownership_repair_decoder_conflict',
      'legacy_ownership_repair_decoder_unknown',
      'legacy_ownership_repair_decoded_shape_invalid',
      'legacy_ownership_repaired',
      'native_chat_conversion_missing_group_identifier_field',
      'native_chat_envelope_malformed_metadata',
      'native_chat_property_presence_malformed_nested_plist',
      'native_chat_raw_presence_duplicate_field_identifier',
      'native_quarantined_malformed_record',
      'projection_repaired_attachment_capability',
      'retained_backlog_failure_dependency',
      'retained_projection_window_has_more',
      'semantic_conflict',
      'semantic_quarantine_after_mutation_forbidden',
      'semantic_replay_terminal_conflict',
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
      'edit_revision_mismatch',
      'immutable_content_mismatch',
      'legacy_ownership_repair_candidate',
      'legacy_ownership_repair_decoded_shape_invalid',
      'legacy_ownership_repair_decoder_conflict',
      'legacy_ownership_repair_decoder_unknown',
      'legacy_ownership_repaired',
      'native_chat_conversion_missing_group_identifier_field',
      'native_chat_envelope_malformed_metadata',
      'native_chat_property_presence_malformed_nested_plist',
      'native_chat_raw_presence_duplicate_field_identifier',
      'native_quarantined_malformed_record',
      'projection_repaired_attachment_capability',
      'retained_backlog_failure_dependency',
      'retained_projection_window_has_more',
      'semantic_conflict',
      'semantic_quarantine_after_mutation_forbidden',
      'semantic_replay_terminal_conflict',
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

  test('rejects unbounded legacy ownership decoder suffixes', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    diagnostics.record('legacy_ownership_repair_decoder_record_identifier');

    expect(diagnostics.snapshot(), <String, int>{'diagnostic_code_invalid': 1});
  });

  test('rejects unreviewed native chat diagnostic suffixes', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final candidate in const <String>[
      'native_chat_envelope_record_identifier',
      'native_chat_raw_presence_private_value',
      'native_chat_property_presence_server_body',
      'native_chat_conversion_future_unreviewed_branch',
    ]) {
      diagnostics.record(candidate);
    }

    expect(diagnostics.snapshot(), <String, int>{'diagnostic_code_invalid': 4});
  });

  test('accepts only bounded native chat property shape classes', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final shape in const <String>[
      'empty',
      'gzip',
      'zlib',
      'binary_plist',
      'xml_plist',
      'unknown',
    ]) {
      diagnostics.record(
        'native_chat_property_presence_malformed_nested_plist_shape_$shape',
      );
    }
    diagnostics.record(
      'native_chat_property_presence_malformed_nested_plist_shape_private',
    );

    expect(diagnostics.snapshot(), <String, int>{
      'diagnostic_code_invalid': 1,
      'native_chat_property_presence_malformed_nested_plist_shape_binary_plist': 1,
      'native_chat_property_presence_malformed_nested_plist_shape_empty': 1,
      'native_chat_property_presence_malformed_nested_plist_shape_gzip': 1,
      'native_chat_property_presence_malformed_nested_plist_shape_unknown': 1,
      'native_chat_property_presence_malformed_nested_plist_shape_xml_plist': 1,
      'native_chat_property_presence_malformed_nested_plist_shape_zlib': 1,
    });
  });
}
