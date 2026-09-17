import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_diagnostics.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('group route conflicts report no raw routing identifier', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();
    diagnostics.record('canonical_chat_group_route_conflict');
    diagnostics.record('canonical_chat_group_route_conflict:private-group');
    expect(diagnostics.snapshot(), {
      'canonical_chat_group_route_conflict': 1,
      'diagnostic_code_invalid': 1,
    });
  });

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

  test('existing Chat history causes are a closed content-free vocabulary', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final code in const <String>[
      'outbound_chat_existing_history_local_chat_match',
      'outbound_chat_existing_history_snapshot_match',
      'outbound_chat_existing_history_alias_match',
      'outbound_chat_existing_history_prior_outbound_origin_match',
      'outbound_chat_existing_history_record_map_conflict',
      'outbound_chat_existing_history_tombstone_conflict',
    ]) {
      diagnostics.record(code);
    }
    diagnostics.record(
      'outbound_chat_existing_history_local_chat_match:private-identifier',
    );

    expect(diagnostics.snapshot(), <String, int>{
      'diagnostic_code_invalid': 1,
      'outbound_chat_existing_history_alias_match': 1,
      'outbound_chat_existing_history_local_chat_match': 1,
      'outbound_chat_existing_history_prior_outbound_origin_match': 1,
      'outbound_chat_existing_history_record_map_conflict': 1,
      'outbound_chat_existing_history_snapshot_match': 1,
      'outbound_chat_existing_history_tombstone_conflict': 1,
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

  test('recognizes closed native attachment quarantine detail', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final code in const <String>[
      'native_attachment_metadata_absent',
      'native_attachment_metadata_too_many_fields',
      'native_attachment_metadata_malformed_field_identifier',
      'native_attachment_metadata_duplicate_field_identifier',
      'native_attachment_metadata_field_not_present',
      'native_attachment_metadata_nested_payload_too_large',
      'native_attachment_metadata_malformed_nested_plist',
      'native_attachment_metadata_nested_plist_not_dictionary',
      'native_attachment_metadata_explicit_clear_without_presence',
      'native_attachment_conversion_content_field',
      'native_attachment_conversion_guid_presence',
      'native_attachment_conversion_empty_guid',
      'native_attachment_conversion_user_info_empty',
      'native_attachment_conversion_user_info_mixed_modes',
      'native_attachment_conversion_inline_marker',
      'native_attachment_conversion_inline_part',
      'native_attachment_conversion_mmcs_signature',
      'native_attachment_conversion_mmcs_owner',
      'native_attachment_conversion_mmcs_url',
      'native_attachment_conversion_mmcs_key',
      'native_attachment_conversion_owner',
      'native_attachment_conversion_logical_identity',
      'native_attachment_conversion_uti_field',
      'native_attachment_conversion_mime_field',
      'native_attachment_conversion_transfer_name_field',
      'native_attachment_conversion_total_bytes_field',
      'native_attachment_conversion_outgoing_field',
      'native_attachment_conversion_canonical_payload',
      'native_attachment_conversion_created_date',
      'native_attachment_conversion_canonical_build',
    ]) {
      diagnostics.record(code);
    }

    expect(diagnostics.snapshot(), <String, int>{
      'native_attachment_conversion_canonical_build': 1,
      'native_attachment_conversion_canonical_payload': 1,
      'native_attachment_conversion_content_field': 1,
      'native_attachment_conversion_created_date': 1,
      'native_attachment_conversion_empty_guid': 1,
      'native_attachment_conversion_guid_presence': 1,
      'native_attachment_conversion_inline_marker': 1,
      'native_attachment_conversion_inline_part': 1,
      'native_attachment_conversion_logical_identity': 1,
      'native_attachment_conversion_mime_field': 1,
      'native_attachment_conversion_mmcs_key': 1,
      'native_attachment_conversion_mmcs_owner': 1,
      'native_attachment_conversion_mmcs_signature': 1,
      'native_attachment_conversion_mmcs_url': 1,
      'native_attachment_conversion_outgoing_field': 1,
      'native_attachment_conversion_owner': 1,
      'native_attachment_conversion_total_bytes_field': 1,
      'native_attachment_conversion_transfer_name_field': 1,
      'native_attachment_conversion_user_info_empty': 1,
      'native_attachment_conversion_user_info_mixed_modes': 1,
      'native_attachment_conversion_uti_field': 1,
      'native_attachment_metadata_absent': 1,
      'native_attachment_metadata_duplicate_field_identifier': 1,
      'native_attachment_metadata_explicit_clear_without_presence': 1,
      'native_attachment_metadata_field_not_present': 1,
      'native_attachment_metadata_malformed_field_identifier': 1,
      'native_attachment_metadata_malformed_nested_plist': 1,
      'native_attachment_metadata_nested_payload_too_large': 1,
      'native_attachment_metadata_nested_plist_not_dictionary': 1,
      'native_attachment_metadata_too_many_fields': 1,
    });
  });

  test('rejects unreviewed native attachment detail suffixes', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final candidate in const <String>[
      'native_attachment_metadata_private_value',
      'native_attachment_metadata_server_body',
      'native_attachment_metadata_record_identifier',
      'native_attachment_metadata_malformed_nested_plist_shape_gzip',
      'native_attachment_metadata_too_many_fields_extra',
      'native_attachment_metadata_absent_extra',
      'native_attachment_metadata_absent:private-identifier',
      'native_attachment_conversion_future_unreviewed_branch',
      'native_attachment_conversion_private_value',
      'native_attachment_conversion_content_field_extra',
      'native_attachment_conversion_',
      'native_attachment_metadata_',
      'native_attachment_unknown_detail',
    ]) {
      diagnostics.record(candidate);
    }

    expect(diagnostics.snapshot(), <String, int>{'diagnostic_code_invalid': 13});
  });

  test('native attachment detail leaves existing diagnostic vocabulary unchanged', () {
    final diagnostics = CloudSyncSemanticDiagnosticCollector();

    for (final code in const <String>[
      'apply_dependency',
      'decoder_malformed_record',
      'retained_backlog_failure_dependency',
      'retained_projection_window_has_more',
      'retained_projection_retained',
      'native_failure_retryable_upstream',
      'native_quarantined_malformed_record',
      'native_chat_conversion_missing_group_identifier_field',
    ]) {
      diagnostics.record(code);
    }
    for (final candidate in const <String>[
      'apply_record_identifier',
      'retained_backlog_failure_record_identifier',
      'retained_projection_private_value',
      'native_failure_private_value',
      'native_quarantined_private_value',
    ]) {
      diagnostics.record(candidate);
    }

    expect(diagnostics.snapshot(), <String, int>{
      'apply_dependency': 1,
      'decoder_malformed_record': 1,
      'diagnostic_code_invalid': 5,
      'native_chat_conversion_missing_group_identifier_field': 1,
      'native_failure_retryable_upstream': 1,
      'native_quarantined_malformed_record': 1,
      'retained_backlog_failure_dependency': 1,
      'retained_projection_retained': 1,
      'retained_projection_window_has_more': 1,
    });

    // Secondary attachment detail must not become a primary safe code,
    // nor a read-only canary retainable dependency.
    for (final code in const <String>[
      'native_attachment_metadata_absent',
      'native_attachment_metadata_too_many_fields',
      'native_attachment_metadata_malformed_field_identifier',
      'native_attachment_metadata_duplicate_field_identifier',
      'native_attachment_metadata_field_not_present',
      'native_attachment_metadata_nested_payload_too_large',
      'native_attachment_metadata_malformed_nested_plist',
      'native_attachment_metadata_nested_plist_not_dictionary',
      'native_attachment_metadata_explicit_clear_without_presence',
      'native_attachment_conversion_content_field',
      'native_attachment_conversion_guid_presence',
      'native_attachment_conversion_empty_guid',
      'native_attachment_conversion_user_info_empty',
      'native_attachment_conversion_user_info_mixed_modes',
      'native_attachment_conversion_inline_marker',
      'native_attachment_conversion_inline_part',
      'native_attachment_conversion_mmcs_signature',
      'native_attachment_conversion_mmcs_owner',
      'native_attachment_conversion_mmcs_url',
      'native_attachment_conversion_mmcs_key',
      'native_attachment_conversion_owner',
      'native_attachment_conversion_logical_identity',
      'native_attachment_conversion_uti_field',
      'native_attachment_conversion_mime_field',
      'native_attachment_conversion_transfer_name_field',
      'native_attachment_conversion_total_bytes_field',
      'native_attachment_conversion_outgoing_field',
      'native_attachment_conversion_canonical_payload',
      'native_attachment_conversion_created_date',
      'native_attachment_conversion_canonical_build',
    ]) {
      expect(
        cloudSyncV2SafeFailureCodeForCandidate(code),
        'cloud_sync_unknown_failure',
        reason: code,
      );
      expect(
        CloudSyncV2DecoderSafeFailureCodes.readOnlyCanaryRetainableDependencies
            .contains(code),
        isFalse,
        reason: code,
      );
    }
  });
}
