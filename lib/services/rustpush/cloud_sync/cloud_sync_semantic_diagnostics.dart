typedef CloudSyncSemanticDiagnosticRecorder = void Function(String safeCode);

/// Closed, content-free vocabulary accepted at the persisted report boundary.
///
/// Keep dynamic families bounded by typed enum/cardinality segments. A string
/// being syntactically tidy is not enough: account identifiers, GUIDs,
/// protected references, and arbitrary error text must fail closed here.
abstract final class CloudSyncSemanticDiagnosticCodes {
  // Persist only bounded, reviewed, content-free diagnostic vocabulary.
  static const _exact = <String>{
    'active_scope_changed',
    'active_scope_revalidation_failed',
    'apply_unknown',
    'canonical_attachment_owner_conflict',
    'canonical_attachment_owner_unavailable',
    'canonical_attachment_repair_owner_conflict',
    'canonical_attachment_repair_provenance_conflict',
    'canonical_attachment_repair_snapshot_mismatch',
    'canonical_attachment_repair_target_unavailable',
    'canonical_attachment_relation_conflict',
    'canonical_attachment_size_invalid',
    'canonical_chat_alias_conflict',
    'canonical_chat_alias_conflict_binding_owner',
    'canonical_chat_alias_conflict_binding_target',
    'canonical_chat_alias_conflict_duplicate_binding_rows',
    'canonical_chat_alias_conflict_duplicate_identifier_rows',
    'canonical_chat_alias_conflict_identifier_owner',
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
    'canonical_message_chat_candidate_bare_direct_service_identifier_agrees',
    'canonical_message_chat_candidate_bare_direct_service_identifier_disagrees',
    'canonical_message_chat_candidate_bare_direct_service_identifier_lookup_failed',
    'canonical_message_chat_candidate_bare_direct_service_identifier_style_45',
    'canonical_message_chat_candidate_bare_direct_service_identifier_wrong_style',
    'canonical_message_chat_candidate_opposite_group_id_lookup_failed',
    'canonical_message_chat_candidate_opposite_service_identifier_lookup_failed',
    'canonical_message_chat_conflict',
    'canonical_message_chat_exact_guid_unproven',
    'canonical_message_chat_reference_current_group_id',
    'canonical_message_chat_reference_cross_service_group_id',
    'canonical_message_chat_reference_exact_guid',
    'canonical_message_chat_reference_strong',
    'canonical_message_chat_reference_strong_service',
    'canonical_message_chat_reference_unavailable',
    'canonical_message_chat_reference_weak_evidence_only',
    'canonical_message_chat_reference_wrong_route_evidence_only',
    'canonical_message_chat_route_bare',
    'canonical_message_chat_route_direct',
    'canonical_message_chat_route_group',
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
    'canonical_preexisting_ownership_bootstrap',
    'canonical_reaction_created_at_conflict',
    'canonical_reaction_parent_conflict',
    'canonical_reaction_parent_unavailable',
    'canonical_reaction_sender_conflict',
    'canonical_reaction_shape_unsupported',
    'canonical_scope_fence_rejected',
    'canonical_tombstone_dto_incomplete',
    'cloud_sync_unknown_failure',
    'decoder_attachment_shape_unsupported',
    'decoder_chat_shape_invalid',
    'decoder_mutation_kind_mismatch',
    'decoder_message_chat_reference_invalid',
    'decoder_message_shape_unsupported',
    'decoder_native_result_envelope_mismatch',
    'decoder_out_of_scope_entry_mismatch',
    'decoder_payload_lane_count_invalid',
    'decoder_payload_identity_mismatch',
    'decoder_reaction_shape_unsupported',
    'decoder_ready',
    'decoder_text_run_attachment_shape_invalid',
    'diagnostic_code_invalid',
    'identity_registration_failed',
    'immutable_content_mismatch',
    'edit_revision_mismatch',
    'legacy_ownership_repair_candidate',
    'legacy_ownership_repair_decoded_shape_invalid',
    'legacy_ownership_repaired',
    'legacy_ownership_attachment_shape_invalid',
    'legacy_ownership_canonical_row_ambiguous',
    'legacy_ownership_canonical_row_mismatch',
    'legacy_ownership_canonical_shape_invalid',
    'legacy_ownership_chat_shape_invalid',
    'legacy_ownership_dependency_transient_owner_invalid',
    'legacy_ownership_message_shape_invalid',
    'legacy_ownership_reaction_shape_invalid',
    'legacy_ownership_transient_owner_invalid',
    'native_invalid_disposition_shape',
    'native_out_of_scope_rcs',
    'native_out_of_scope_sms_family',
    'native_ready',
    'projection_repair_active_scope_changed',
    'projection_repair_candidate_invalid',
    'projection_repair_decode_retryable',
    'projection_repair_decoded_shape_invalid',
    'projection_repaired_attachment_capability',
    'projection_repaired_chat_alias',
    'retained_backlog_blocking_saves',
    'retained_backlog_out_of_scope_services',
    'retained_backlog_saves',
    'retained_backlog_summary_mismatch',
    'retained_backlog_summary_ready',
    'retained_backlog_summary_unavailable',
    'retained_backlog_tombstones',
    'retained_backlog_total',
    'retained_backlog_unclassified',
    'retained_projection_active_scope_changed',
    'retained_projection_authorization_changed',
    'retained_projection_candidate_invalid',
    'retained_projection_decoded_shape_invalid',
    'retained_projection_examined',
    'retained_projection_has_remaining',
    'retained_projection_incomplete',
    'retained_projection_out_of_scope_previous_failure_rejected',
    'retained_projection_out_of_scope_service',
    'retained_projection_registrar_unavailable',
    'retained_projection_replay_exists',
    'retained_projection_reprojected',
    'retained_projection_retained',
    'retained_projection_scope_mismatch',
    'retained_projection_store_unavailable',
    'retained_projection_unknown',
    'retained_projection_window_has_more',
    'semantic_parent_missing',
    'semantic_conflict',
    'semantic_quarantine_after_mutation_forbidden',
    'semantic_replay_terminal_conflict',
    'semantic_out_of_scope_rcs',
    'semantic_out_of_scope_sms_family',
    'tombstone_read_only_acknowledged',
  };

  static const _failureCategorySegments = <String>{
    'network',
    'throttled',
    'server',
    'authorization',
    'pcs_unavailable',
    'malformed_record',
    'conflict',
    'dependency',
    'local_storage',
    'cancelled',
    'unknown',
    'unsupported_service',
    'out_of_scope_service',
  };

  static const _failureCategoryPrefixes = <String>{
    'apply_',
    'decoder_',
    'legacy_ownership_repair_decoder_',
    'projection_repair_decoder_',
    'retained_backlog_failure_',
    'retained_projection_',
    'retained_projection_decoder_',
  };

  static const _nativeDeferredSegments = <String>{
    'nested_presence_unavailable',
    'unproven_edit_timestamp',
    'unsupported_extension_payload',
    'unsupported_media_credentials',
    'unsupported_group_photo',
    'unsupported_sticker',
    'unsupported_scheduling',
    'unsupported_off_grid_metadata',
    'unsupported_negative_attachment_size',
  };

  static const _nativeQuarantineSegments = <String>{
    'malformed_required_identity',
    'field_presence_mismatch',
    'unsupported_service',
    'unsupported_chat_style',
    'unsupported_message_type',
    'unsupported_association_type',
    'malformed_parent',
    'ambiguous_reply',
    'malformed_attributed_body',
    'malformed_message_summary',
    'conflicting_edit_and_retraction',
    'oversized_content',
    'invalid_canonical_payload',
    'malformed_record',
  };

  static const _nativeFailureSegments = <String>{
    'invalid_request',
    'read_authentication_scope',
    'active_account_mismatch',
    'warm_authentication_required',
    'scope_mismatch',
    'generation_mismatch',
    'store_identity_mismatch',
    'protected_reference_mismatch',
    'malformed_record',
    'oversized_record',
    'pcs_unavailable',
    'retryable_upstream',
    'decoder_failure',
  };

  static const _chatCardinalityPrefixes = <String>{
    'canonical_message_chat_exact_guid_',
    'canonical_message_chat_candidate_service_identifier_',
    'canonical_message_chat_candidate_group_id_',
    'canonical_message_chat_candidate_original_group_id_',
    'canonical_message_chat_candidate_legacy_group_identifier_',
    'canonical_message_chat_candidate_bare_direct_service_identifier_',
    'canonical_message_chat_candidate_opposite_group_id_',
    'canonical_message_chat_candidate_opposite_service_identifier_',
    'canonical_message_chat_candidate_union_',
    'canonical_message_chat_group_corroborator_',
  };

  static const _cardinalitySegments = <String>{'none', 'unique', 'multiple'};

  static const _oppositeGroupStylePrefixes = <String>{
    'canonical_message_chat_candidate_opposite_group_id_unique_style_',
  };

  static const _chatStyleSegments = <String>{
    'group',
    'direct',
    'unknown',
    'other',
  };

  static bool isReviewed(String code) {
    if (_exact.contains(code)) return true;
    if (_matchesAnyPrefix(
      code,
      _failureCategoryPrefixes,
      _failureCategorySegments,
    )) {
      return true;
    }
    if (_matchesPrefix(code, 'native_deferred_', _nativeDeferredSegments) ||
        _matchesPrefix(
          code,
          'native_quarantined_',
          _nativeQuarantineSegments,
        ) ||
        _matchesPrefix(code, 'native_failure_', _nativeFailureSegments)) {
      return true;
    }
    return _matchesAnyPrefix(
          code,
          _chatCardinalityPrefixes,
          _cardinalitySegments,
        ) ||
        _matchesAnyPrefix(
          code,
          _oppositeGroupStylePrefixes,
          _chatStyleSegments,
        );
  }

  static bool _matchesAnyPrefix(
    String value,
    Set<String> prefixes,
    Set<String> segments,
  ) {
    for (final prefix in prefixes) {
      if (_matchesPrefix(value, prefix, segments)) return true;
    }
    return false;
  }

  static bool _matchesPrefix(
    String value,
    String prefix,
    Set<String> segments,
  ) =>
      value.startsWith(prefix) &&
      segments.contains(value.substring(prefix.length));
}

/// Content-free counters for semantic decode and local projection stages.
///
/// Values are bounded safe codes only. Record identifiers, account data,
/// message contents, and protected references must never be passed here.
final class CloudSyncSemanticDiagnosticCollector {
  static final RegExp _safeCodePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$');

  final Map<String, int> _counts = <String, int>{};

  void record(String safeCode) {
    // Diagnostics must never change projection behavior. Collapse malformed or
    // unexpectedly sensitive-looking values into one bounded code instead of
    // throwing from an error-reporting path.
    final boundedCode =
        _safeCodePattern.hasMatch(safeCode) &&
            CloudSyncSemanticDiagnosticCodes.isReviewed(safeCode)
        ? safeCode
        : 'diagnostic_code_invalid';
    _counts.update(boundedCode, (count) => count + 1, ifAbsent: () => 1);
  }

  Map<String, int> snapshot() => validatedSnapshot(_counts);

  static Map<String, int> validatedSnapshot(Map<String, int> source) {
    final keys = source.keys.toList(growable: false)..sort();
    final result = <String, int>{};
    for (final key in keys) {
      final count = source[key];
      if (!_safeCodePattern.hasMatch(key) ||
          !CloudSyncSemanticDiagnosticCodes.isReviewed(key) ||
          count == null ||
          count <= 0) {
        throw ArgumentError('cloud_sync_semantic_diagnostics_invalid');
      }
      result[key] = count;
    }
    return Map<String, int>.unmodifiable(result);
  }
}
