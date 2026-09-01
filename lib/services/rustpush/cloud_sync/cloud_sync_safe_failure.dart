import 'cloud_sync_shadow_report_file.dart';
import 'cloud_sync_models.dart';
import 'cloud_sync_semantic_pull_report_file.dart';
import 'cloudkit_operation_interlock.dart';
import 'cloudkit_writer_authority.dart';

abstract final class CloudSyncV2DecoderSafeFailureCodes {
  static const attachmentShapeUnsupported =
      'decoder_attachment_shape_unsupported';
  static const chatShapeInvalid = 'decoder_chat_shape_invalid';
  static const messageChatReferenceInvalid =
      'decoder_message_chat_reference_invalid';
  static const messageShapeUnsupported = 'decoder_message_shape_unsupported';
  static const payloadLaneCountInvalid = 'decoder_payload_lane_count_invalid';
  static const reactionShapeUnsupported = 'decoder_reaction_shape_unsupported';
  static const textRunAttachmentShapeInvalid =
      'decoder_text_run_attachment_shape_invalid';

  static const all = <String>{
    attachmentShapeUnsupported,
    chatShapeInvalid,
    messageChatReferenceInvalid,
    messageShapeUnsupported,
    payloadLaneCountInvalid,
    reactionShapeUnsupported,
    textRunAttachmentShapeInvalid,
  };

  static const readOnlyCanaryRetainableDependencies = <String>{
    attachmentShapeUnsupported,
    messageShapeUnsupported,
    reactionShapeUnsupported,
  };
}

/// Fixed failures for the typed out-of-scope disposition and its fenced
/// retained-row reclassification. Diagnostic-only counters remain in the
/// semantic diagnostic vocabulary and are not admitted here.
abstract final class CloudSyncV2OutOfScopeServiceSafeFailureCodes {
  static const semanticSmsFamily = 'semantic_out_of_scope_sms_family';
  static const semanticRcs = 'semantic_out_of_scope_rcs';
  static const dispositionInvalid = 'out_of_scope_service_disposition_invalid';
  static const retainedEntryInvalid =
      'retained_projection_out_of_scope_entry_invalid';
  static const retainedRowInvalid =
      'retained_projection_out_of_scope_row_invalid';
  static const retainedRecordFailed =
      'retained_projection_out_of_scope_record_failed';

  static const all = <String>{
    semanticSmsFamily,
    semanticRcs,
    dispositionInvalid,
    retainedEntryInvalid,
    retainedRowInvalid,
    retainedRecordFailed,
  };
}

/// Fixed, content-free codes emitted by the protected native transport.
///
/// The transport and persisted-report allowlist share this vocabulary so a
/// reviewed native failure cannot be silently rewritten to the generic unknown
/// code at the Dart reporting boundary.
abstract final class CloudSyncV2ProtectedTransportSafeFailureCodes {
  static const invalidScope = 'invalid_scope';
  static const invalidRequest = 'invalid_request';
  static const invalidCheckpoint = 'invalid_checkpoint';
  static const checkpointContextMismatch = 'checkpoint_context_mismatch';
  static const oversizedPage = 'oversized_page';
  static const oversizedRecord = 'oversized_record';
  static const protectionFailed = 'protection_failed';
  static const localStoreFailed = 'local_store_failed';
  static const fetchDeadline = 'fetch_deadline';
  static const network = 'network';
  static const cloudKitThrottled = 'cloudkit_throttled';
  static const cloudKitServer = 'cloudkit_server';
  static const cloudKitAuthorization = 'cloudkit_authorization';
  static const cloudKitConflict = 'cloudkit_conflict';
  static const cloudKitResetRequired = 'cloudkit_reset_required';
  static const cloudKitPermanent = 'cloudkit_permanent';
  static const cloudKitUnknown = 'cloudkit_unknown';
  static const httpAuthorization = 'http_authorization';
  static const httpTimeout = 'http_timeout';
  static const httpThrottled = 'http_throttled';
  static const httpServer = 'http_server';
  static const httpUnknown = 'http_unknown';
  static const pcsUnavailable = 'pcs_unavailable';
  static const malformedResponse = 'malformed_response';
  static const continuationNoProgress = 'continuation_no_progress';
  static const readAuthenticationScope = 'read_authentication_scope';
  static const nativeAuthUnavailable = 'native_auth_unavailable';
  static const unknown = 'unknown';

  static const all = <String>{
    invalidScope,
    invalidRequest,
    invalidCheckpoint,
    checkpointContextMismatch,
    oversizedPage,
    oversizedRecord,
    protectionFailed,
    localStoreFailed,
    fetchDeadline,
    network,
    cloudKitThrottled,
    cloudKitServer,
    cloudKitAuthorization,
    cloudKitConflict,
    cloudKitResetRequired,
    cloudKitPermanent,
    cloudKitUnknown,
    httpAuthorization,
    httpTimeout,
    httpThrottled,
    httpServer,
    httpUnknown,
    pcsUnavailable,
    malformedResponse,
    continuationNoProgress,
    readAuthenticationScope,
    nativeAuthUnavailable,
    unknown,
  };
}

/// Fixed, content-free failures emitted by the canonical ObjectBox projector.
///
/// Retained replay must preserve these exact branches. Collapsing one to the
/// generic unknown code hides whether the blocker is identity ownership,
/// parent ordering, an immutable-field conflict, or an unsupported shape.
abstract final class CloudSyncV2CanonicalProjectionSafeFailureCodes {
  static const all = <String>{
    'canonical_attachment_owner_conflict',
    'canonical_attachment_owner_unavailable',
    'canonical_attachment_relation_conflict',
    'canonical_attachment_size_invalid',
    'canonical_chat_alias_conflict',
    'canonical_chat_alias_unproven',
    'canonical_chat_apply_disabled',
    'canonical_chat_creation_unavailable',
    'canonical_chat_display_name_clear_unverified',
    'canonical_chat_participant_invalid',
    'canonical_chat_relation_unavailable',
    'canonical_chat_repair_shape_invalid',
    'canonical_chat_repair_snapshot_mismatch',
    'canonical_chat_repair_target_unavailable',
    'canonical_chat_service_conflict',
    'canonical_chat_shape_invalid',
    'canonical_chat_style_conflict',
    'canonical_dependency_scope_conflict',
    'canonical_dependency_scope_stale',
    'canonical_identity_guid_invalid',
    'canonical_identity_mismatch',
    'canonical_identity_owner_conflict',
    'canonical_identity_owner_unproven',
    'canonical_identity_unavailable',
    'canonical_message_chat_alias_ambiguous',
    'canonical_message_chat_alias_invalid',
    'canonical_message_chat_alias_unproven',
    'canonical_message_chat_conflict',
    'canonical_message_chat_route_invalid',
    'canonical_message_chat_unavailable',
    'canonical_message_created_at_conflict',
    'canonical_message_extension_decode_required',
    'canonical_message_reply_parent_unavailable',
    'canonical_message_sender_conflict',
    'canonical_message_sender_invalid',
    'canonical_message_shape_unsupported',
    'canonical_message_text_range_invalid',
    'canonical_payload_dto_incomplete',
    'canonical_payload_snapshot_mismatch',
    'canonical_reaction_created_at_conflict',
    'canonical_reaction_parent_conflict',
    'canonical_reaction_parent_unavailable',
    'canonical_reaction_sender_conflict',
    'canonical_reaction_shape_unsupported',
    'canonical_scope_fence_rejected',
    'canonical_tombstone_dto_incomplete',
  };
}

/// Fixed, content-free failures emitted by the same-session remote-head proof
/// and sequence-bounded local projection sweep.
abstract final class CloudSyncV2ProjectionSweepSafeFailureCodes {
  static const all = <String>{
    'cloud_sync_remote_head_proof_unavailable',
    'cloud_sync_remote_head_checkpoint_unstable',
    'cloud_sync_projection_sweep_proof_invalid',
    'cloud_sync_projection_sweep_bound_missing',
    'cloud_sync_projection_sweep_applier_unavailable',
    'cloud_sync_projection_sweep_lease_unavailable',
    'cloud_sync_projection_sweep_batch_limit',
    'cloud_sync_projection_sweep_lease_lost',
    'cloud_sync_projection_sweep_result_invalid',
    'cloud_sync_projection_sweep_checkpoint_changed',
    'cloud_sync_projection_sweep_unsafe_report',
    'cloud_sync_semantic_remote_pass_limit_unreachable',
  };
}

/// Carries only a reviewed, content-free failure code from a persisted unsafe
/// semantic-drain report to the outer diagnostic boundary.
final class CloudSyncSemanticDrainUnsafeReportException implements Exception {
  const CloudSyncSemanticDrainUnsafeReportException(this.safeCode);

  final String safeCode;
}

const _cloudSyncV2SafeFailureCodes = <String>{
  ...CloudSyncV2DecoderSafeFailureCodes.all,
  ...CloudSyncV2OutOfScopeServiceSafeFailureCodes.all,
  ...CloudSyncV2ProtectedTransportSafeFailureCodes.all,
  ...CloudSyncV2CanonicalProjectionSafeFailureCodes.all,
  ...CloudSyncV2ProjectionSweepSafeFailureCodes.all,
  'cloud_sync_unknown_failure',
  'apply_network',
  'apply_throttled',
  'apply_server',
  'apply_authorization',
  'apply_pcs_unavailable',
  'apply_malformed_record',
  'apply_conflict',
  'apply_dependency',
  'apply_local_storage',
  'apply_cancelled',
  'apply_unknown',
  'apply_unsupported_service',
  'decoder_network',
  'decoder_throttled',
  'decoder_server',
  'decoder_authorization',
  'decoder_pcs_unavailable',
  'decoder_malformed_record',
  'decoder_conflict',
  'decoder_dependency',
  'decoder_local_storage',
  'decoder_cancelled',
  'decoder_unknown',
  'decoder_unsupported_service',
  'cloud_attachment_account_changed',
  'cloud_attachment_integrity_mismatch',
  'cloud_attachment_native_result_invalid',
  'cloud_attachment_read_auth_scope_invalid',
  'cloud_attachment_size_mismatch',
  'cloud_attachment_source_conflict',
  'cloud_attachment_source_invalid',
  'cloud_attachment_state_contention',
  'account_changed',
  'account_unavailable',
  'cloud_sync_outbound_canary_active',
  'cloud_sync_outbound_canary_admission_invalid',
  'cloud_sync_outbound_canary_already_armed',
  'cloud_sync_outbound_canary_confirmation_expired',
  'cloud_sync_outbound_canary_confirmation_invalid',
  'cloud_sync_outbound_canary_disabled',
  'cloud_sync_outbound_canary_message_time_invalid',
  'cloud_sync_outbound_canary_outbox_invalid',
  'cloud_sync_outbound_canary_postflight_invalid',
  'cloud_sync_outbound_canary_quiescing',
  'cloud_sync_outbound_canary_recovery_invalid',
  'cloud_sync_outbound_canary_tripwire',
  'cloud_sync_outbound_canary_unavailable',
  'cloud_sync_outbound_canary_writer_disabled',
  'cloud_sync_outbound_canary_replay_invalid',
  'cloud_sync_outbound_candidate_selection_failed',
  'cloud_sync_outbound_candidate_changed',
  'cloud_sync_outbound_active_handles_unavailable',
  'cloud_sync_outbound_canary_operation_changed',
  'cloud_sync_outbound_quiescence_timeout',
  'cloud_sync_outbound_provisioning_quiescence_timeout',
  'cloud_sync_outbound_replay_operation_invalid',
  'cloud_sync_outbound_replay_envelope_invalid',
  'cloud_sync_outbound_replay_record_missing',
  'cloud_sync_outbound_replay_conflict',
  'cloud_sync_outbound_replay_unresolved',
  'cloud_sync_developer_mode_required',
  'cloud_sync_canary_package_required',
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
  'cloud_sync_native_writer_pause_already_active',
  'cloud_sync_native_writer_pause_bridge_failed',
  'cloud_sync_native_writer_pause_capability_required',
  'cloud_sync_native_writer_pause_failed',
  'cloud_sync_native_writer_pause_timeout',
  'cloud_sync_native_writer_pause_token_invalid',
  'cloud_sync_native_writer_resume_failed',
  'cloud_sync_native_writer_resume_token_invalid',
  'cloud_sync_private_storage_unavailable',
  'cloud_sync_protocol_evidence_architecture_invalid',
  'cloud_sync_protocol_evidence_attempt_invalid',
  'cloud_sync_protocol_evidence_build_commit_invalid',
  'cloud_sync_protocol_evidence_count_invalid',
  'cloud_sync_protocol_evidence_directory_unavailable',
  'cloud_sync_protocol_evidence_directory_unsafe',
  'cloud_sync_protocol_evidence_elapsed_ms_invalid',
  'cloud_sync_protocol_evidence_estimated_bytes_invalid',
  'cloud_sync_protocol_evidence_event_invalid',
  'cloud_sync_protocol_evidence_event_type_invalid',
  'cloud_sync_protocol_evidence_failure_invalid',
  'cloud_sync_protocol_evidence_file_corrupt',
  'cloud_sync_protocol_evidence_journal_block_invalid',
  'cloud_sync_protocol_evidence_line_too_large',
  'cloud_sync_protocol_evidence_owned_file_invalid',
  'cloud_sync_protocol_evidence_path_escape',
  'cloud_sync_protocol_evidence_platform_invalid',
  'cloud_sync_protocol_evidence_retention_failed',
  'cloud_sync_protocol_evidence_skip_invalid',
  'cloud_sync_protocol_evidence_stream_invalid',
  'cloud_sync_protocol_evidence_timestamp_invalid',
  'cloud_sync_protocol_evidence_trigger_invalid',
  'cloud_sync_protocol_evidence_trusted_root_invalid',
  'cloud_sync_protocol_evidence_unknown_failure',
  'cloud_sync_protocol_evidence_write_failed',
  'cloud_sync_protocol_evidence_zone_invalid',
  'cloud_sync_report_already_exists',
  'cloud_sync_report_contract_invalid',
  'cloud_sync_report_directory_changed',
  'cloud_sync_report_directory_unavailable',
  'cloud_sync_report_directory_unsafe',
  'cloud_sync_report_path_invalid',
  'cloud_sync_report_retention_failed',
  'cloud_sync_report_run_id_invalid',
  'cloud_sync_report_metadata_invalid',
  'cloud_sync_report_read_only_invariant_invalid',
  'cloud_sync_report_storage_unavailable',
  'cloud_sync_report_too_large',
  'cloud_sync_report_write_failed',
  'cloud_sync_report_zone_bytes_invalid',
  'cloud_sync_report_zone_count_invalid',
  'cloud_sync_report_zone_counter_invalid',
  'cloud_sync_report_zone_elapsed_invalid',
  'cloud_sync_report_zone_label_invalid',
  'cloud_sync_sampler_active',
  'cloud_sync_sampler_disabled',
  'cloud_sync_semantic_pull_active',
  'cloud_sync_semantic_pull_disabled',
  'cloud_sync_semantic_pull_quiescing',
  'cloud_sync_semantic_pull_quiescence_timeout',
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
  'cloud_sync_semantic_drain_unsafe_report',
  'cloud_sync_semantic_remote_write_tripwire',
  'cloudkit-authorization',
  'cloudkit-change-token-expired',
  'cloudkit-conflict',
  'cloudkit-continuation-no-progress',
  'cloudkit-permanent',
  'cloudkit-reset-required',
  'cloudkit-server',
  'cloudkit-throttled',
  'cloudkit-unknown',
  'cloud_sync_shadow_controller_active',
  'cloud_sync_shadow_controller_disposed',
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
  'cloud_sync_shadow_owner_disposed',
  'cloud_sync_shadow_owner_quiescing',
  'cloud_sync_shadow_owner_superseded',
  'cloud_sync_shadow_write_tripwire',
  'cloudkit_interlock_busy',
  'cloudkit_interlock_fence_lost',
  'cloudkit_interlock_mode_violation',
  'cloudkit_interlock_profile_mismatch',
  'cloudkit_interlock_required',
  'cloudkit_interlock_storage_unavailable',
  'cloudkit_interlock_unavailable',
  'canonical_chat_alias_owner_ambiguous',
  'checkpoint_pending_page_unresolved',
  'fetch_page_exceeds_requested_limit',
  'fetch_timeout',
  'generation_mismatch',
  'http-authorization',
  'http-server',
  'http-throttled',
  'http-timeout',
  'http-unknown',
  'cloudkit_writer_authority_requires_manual_recovery',
  'cloudkit_writer_build_owner_mismatch',
  'cloudkit_writer_identity_changed',
  'cloudkit_writer_identity_revalidation_failed',
  'cloudkit_writer_legacy_queue_quarantine_failed',
  'cloudkit_writer_migration_commit_precondition_failed',
  'cloudkit_writer_provisioning_measurements_invalid',
  'cloudkit_writer_provisioning_probe_failed',
  'cloudkit_writer_transition_evidence_incomplete',
  'cloudkit_writer_transition_evidence_untrusted',
  'cloudkit_writer_transition_precondition_failed',
  'cloudkit_writer_v2_readback_failed',
  'cloudkit_writer_v2_restore_precondition_failed',
  'coordinator_active',
  'legacy_sync_active',
  'legacy_cloudkit_blocked_by_v2_writer',
  'logout_active',
  'not_ui_isolate',
  'objectbox_not_ready',
  'outbox_not_empty',
  'local-storage',
  'malformed-response',
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
  'pcs-unavailable',
  'protector_unavailable',
  'preflight_invalid_change_shape',
  'preflight_malformed_metadata',
  'preflight_oversized_record',
  'preflight_unknown',
  'preflight_unsupported_record_type',
  'retained_projection_authorization_changed',
  'retained_projection_incomplete',
  'retained_projection_registrar_unavailable',
  'retained_projection_store_unavailable',
  'retained_unprojected_backlog_read_failed',
  'retained_unprojected_backlog_store_unavailable',
  'rustpush_not_ready',
  'semantic_parent_missing',
  'storage_unavailable',
  'unsupported_cloud_zone',
  'unsupported_semantic_cloud_zone',
  'unsupported_semantic_persistence_lane',
  'unsupported_platform',
};

/// Returns only a fixed diagnostic code safe for logs and user-visible copy.
///
/// Exception text is never forwarded. Unknown or newly introduced failures
/// collapse to one generic code until they receive an explicit review.
String cloudSyncV2SafeFailureCode(Object error) {
  final String? candidate = switch (error) {
    CloudSyncShadowReportFileException() => error.safeCode,
    CloudSyncSemanticPullReportFileException() => error.safeCode,
    CloudSyncSemanticDrainUnsafeReportException() => error.safeCode,
    CloudSyncFailure() => error.safeCode,
    CloudKitOperationInterlockException() => error.safeCode,
    CloudKitWriterAuthorityFailure() => error.safeCode,
    StateError() => error.message.toString(),
    _ => null,
  };
  return cloudSyncV2SafeFailureCodeForCandidate(candidate);
}

/// Returns an allowlisted diagnostic code for a known failure value.
///
/// This is intentionally closed: a syntactically valid string is not enough
/// to reach a persisted report, log, or user-visible surface.
String cloudSyncV2SafeFailureCodeForCandidate(String? candidate) =>
    _cloudSyncV2SafeFailureCodes.contains(candidate)
    ? candidate!
    : 'cloud_sync_unknown_failure';
