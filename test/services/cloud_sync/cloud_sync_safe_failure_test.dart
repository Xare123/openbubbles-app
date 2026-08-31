import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_safe_failure.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_semantic_pull_report_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_shadow_report_file.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_operation_interlock.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloudkit_writer_authority.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposes only reviewed state failure codes', () {
    expect(
      cloudSyncV2SafeFailureCode(StateError('legacy_sync_active')),
      'legacy_sync_active',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('cloud_sync_canary_package_required'),
      ),
      'cloud_sync_canary_package_required',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('account-secret@example.com should never be shown'),
      ),
      'cloud_sync_unknown_failure',
    );
  });

  test('exposes reviewed report and interlock codes', () {
    expect(
      cloudSyncV2SafeFailureCode(
        const CloudSyncShadowReportFileException(
          'cloud_sync_report_retention_failed',
        ),
      ),
      'cloud_sync_report_retention_failed',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        const CloudKitOperationInterlockException('cloudkit_interlock_busy'),
      ),
      'cloudkit_interlock_busy',
    );
  });

  test('exposes every reviewed semantic report code', () {
    const codes = <String>{
      'cloud_sync_semantic_report_already_exists',
      'cloud_sync_semantic_report_directory_invalid',
      'cloud_sync_semantic_report_directory_unavailable',
      'cloud_sync_semantic_report_directory_untrusted',
      'cloud_sync_semantic_report_metadata_invalid',
      'cloud_sync_semantic_report_read_only_invariant_invalid',
      'cloud_sync_semantic_report_storage_unavailable',
      'cloud_sync_semantic_report_too_large',
      'cloud_sync_semantic_report_write_failed',
      'cloud_sync_semantic_report_zone_count_invalid',
      'cloud_sync_semantic_report_zone_invalid',
    };
    for (final code in codes) {
      expect(
        cloudSyncV2SafeFailureCode(
          CloudSyncSemanticPullReportFileException(code),
        ),
        code,
      );
    }
  });

  test('collapses an unreviewed semantic report code', () {
    expect(
      cloudSyncV2SafeFailureCode(
        const CloudSyncSemanticPullReportFileException(
          'cloud_sync_semantic_report_secret_path',
        ),
      ),
      'cloud_sync_unknown_failure',
    );
  });

  test('preserves a reviewed writer authority failure code', () {
    expect(
      cloudSyncV2SafeFailureCode(
        const CloudKitWriterAuthorityFailure(
          'cloudkit_writer_identity_changed',
        ),
      ),
      'cloudkit_writer_identity_changed',
    );
  });

  test('preserves reviewed outbound canary and candidate state codes', () {
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('cloud_sync_outbound_canary_recovery_invalid'),
      ),
      'cloud_sync_outbound_canary_recovery_invalid',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('cloud_sync_outbound_canary_unavailable'),
      ),
      'cloud_sync_outbound_canary_unavailable',
    );
    expect(
      cloudSyncV2SafeFailureCode(
        StateError('cloud_sync_outbound_candidate_selection_failed'),
      ),
      'cloud_sync_outbound_candidate_selection_failed',
    );
  });

  test('collapses arbitrary exception text', () {
    expect(
      cloudSyncV2SafeFailureCode(
        Exception('token=private-value account=user@example.com'),
      ),
      'cloud_sync_unknown_failure',
    );
  });

  test('exposes reviewed semantic barrier codes', () {
    const codes = <String>{
      ...CloudSyncV2DecoderSafeFailureCodes.all,
      'canonical_attachment_owner_unavailable',
      'canonical_chat_alias_owner_ambiguous',
      'canonical_chat_alias_conflict',
      'canonical_message_chat_alias_ambiguous',
      'canonical_message_chat_unavailable',
      'canonical_message_reply_parent_unavailable',
      'canonical_reaction_parent_unavailable',
      'checkpoint_pending_page_unresolved',
      'fetch_page_exceeds_requested_limit',
      'preflight_invalid_change_shape',
      'preflight_malformed_metadata',
      'preflight_oversized_record',
      'preflight_unknown',
      'preflight_unsupported_record_type',
      'retained_projection_incomplete',
      'retained_projection_authorization_changed',
      'retained_unprojected_backlog_read_failed',
      'retained_unprojected_backlog_store_unavailable',
      'messages_cloud_tombstone_projection_unavailable',
      'native_deferred_nested_presence_unavailable',
      'native_deferred_unproven_edit_timestamp',
      'native_deferred_unsupported_extension_payload',
      'native_deferred_unsupported_media_credentials',
      'native_deferred_unsupported_group_photo',
      'native_deferred_unsupported_sticker',
      'native_deferred_unsupported_scheduling',
      'native_deferred_unsupported_off_grid_metadata',
      'native_deferred_unsupported_negative_attachment_size',
      'semantic_parent_missing',
      'unsupported_semantic_cloud_zone',
      'unsupported_semantic_persistence_lane',
    };
    for (final code in codes) {
      expect(cloudSyncV2SafeFailureCodeForCandidate(code), code);
    }
  });

  test('decoder Canary-retainable codes are reviewed report codes', () {
    expect(
      CloudSyncV2DecoderSafeFailureCodes.all,
      containsAll(
        CloudSyncV2DecoderSafeFailureCodes.readOnlyCanaryRetainableDependencies,
      ),
    );
    for (final code
        in CloudSyncV2DecoderSafeFailureCodes
            .readOnlyCanaryRetainableDependencies) {
      expect(cloudSyncV2SafeFailureCodeForCandidate(code), code);
    }
  });

  test('exposes reviewed shadow stage codes', () {
    const codes = <String>{
      'cloud_sync_shadow_auth_prepare_failed',
      'cloud_sync_shadow_auth_revalidation_failed',
      'cloud_sync_shadow_cleanup_failed',
      'cloud_sync_shadow_observer_flush_failed',
      'cloud_sync_shadow_observer_open_failed',
      'cloud_sync_shadow_preflight_read_failed',
      'cloud_sync_shadow_quiescence_failed',
      'cloud_sync_shadow_store_open_failed',
      'cloud_sync_shadow_synchronize_failed',
      'cloud_sync_shadow_transport_open_failed',
    };
    for (final code in codes) {
      expect(cloudSyncV2SafeFailureCode(StateError(code)), code);
    }
  });

  test('exposes reviewed native auth codes', () {
    const codes = <String>{
      'cloud_sync_native_auth_account_fingerprint_failed',
      'cloud_sync_native_auth_account_changed',
      'cloud_sync_native_auth_account_unavailable',
      'cloud_sync_native_auth_bridge_failed',
      'cloud_sync_native_auth_client_type_invalid',
      'cloud_sync_native_auth_cloudkit_token_failed',
      'cloud_sync_native_auth_credentials_rejected',
      'cloud_sync_native_auth_credentials_unavailable',
      'cloud_sync_native_auth_identity_mismatch',
      'cloud_sync_native_auth_keychain_container_failed',
      'cloud_sync_native_auth_messages_container_failed',
      'cloud_sync_native_auth_pcs_zones_failed',
      'cloud_sync_native_auth_metadata_invalid',
      'cloud_sync_native_auth_refresh_credentials_rejected',
      'cloud_sync_native_auth_refresh_failed',
      'cloud_sync_native_auth_refresh_session_missing',
      'cloud_sync_native_auth_refresh_state_failed',
      'cloud_sync_native_auth_refresh_timeout',
      'cloud_sync_native_auth_refresh_transport_failed',
      'cloud_sync_native_auth_refresh_unsupported',
      'cloud_sync_native_auth_refresh_writer_busy',
      'cloud_sync_native_auth_security_container_failed',
      'cloud_sync_native_auth_session_fingerprint_failed',
      'cloud_sync_native_auth_storage_invalid',
      'cloud_sync_native_auth_store_identity_failed',
      'cloud_sync_native_auth_transport_failed',
      'cloud_sync_native_auth_warm_failed',
      'cloud_sync_native_auth_warm_timeout',
      'cloud_sync_native_auth_writer_pause_scope_failed',
      'cloud_sync_windows_dev_2fa_request_failed',
      'cloud_sync_windows_dev_2fa_session_missing',
      'cloud_sync_windows_dev_2fa_verification_failed',
      'cloud_sync_native_writer_pause_capability_required',
    };
    for (final code in codes) {
      expect(cloudSyncV2SafeFailureCode(StateError(code)), code);
    }
  });

  test('exposes every reviewed attachment materialization code', () {
    const codes = <String>{
      'cloud_attachment_account_changed',
      'cloud_attachment_integrity_mismatch',
      'cloud_attachment_native_result_invalid',
      'cloud_attachment_read_auth_scope_invalid',
      'cloud_attachment_size_mismatch',
      'cloud_attachment_source_conflict',
      'cloud_attachment_source_invalid',
      'cloud_attachment_state_contention',
    };
    for (final code in codes) {
      expect(cloudSyncV2SafeFailureCodeForCandidate(code), code);
    }
  });

  test('exposes reviewed protocol evidence codes', () {
    const codes = <String>{
      'cloud_sync_protocol_evidence_directory_unavailable',
      'cloud_sync_protocol_evidence_directory_unsafe',
      'cloud_sync_protocol_evidence_owned_file_invalid',
      'cloud_sync_protocol_evidence_path_escape',
      'cloud_sync_protocol_evidence_trigger_invalid',
      'cloud_sync_protocol_evidence_trusted_root_invalid',
      'cloud_sync_protocol_evidence_write_failed',
    };
    for (final code in codes) {
      expect(cloudSyncV2SafeFailureCode(StateError(code)), code);
    }
  });
}
