//! Test-host-only correlation between unresolved Message chat routes and
//! protected Chat1 records. Clear identifiers and raw envelopes never cross
//! Flutter Rust Bridge. The optional PCS path is lookup-only; its separately
//! gated paged lane can perform bounded in-memory reads but cannot persist a
//! cursor, project, admit, or write.

use std::{
    collections::{HashMap, HashSet},
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::Arc,
};

use flutter_rust_bridge::frb;
use prost::Message as _;
use rustpush::{
    cloud_messages::{
        CloudChat, CloudMessageRecordKind, CloudMessagesClient, CloudParticipant, CloudProp,
        MESSAGES_SERVICE,
    },
    cloudkit::pcs_keys_for_record,
    cloudkit_operation_gate::acquire_cloudkit_read_authentication,
    cloudkit_proto::{
        record::field::{value::Type as FieldValueType, EncryptedValue, Value},
        CloudKitRecord, Record,
    },
    pcs::PCSEncryptor,
    DefaultAnisetteProvider,
};

use super::api::{
    cloud_sync_auth_identity_remains_exact, cloud_sync_capture_auth_snapshot,
    is_cloud_sync_windows_dev_profile,
};
use crate::{
    cloud_sync_canonical_dto::CloudCanonicalPayload,
    cloud_sync_chat_identity::{identifier, normalized_chat_identity_variants, participant},
    cloud_sync_native_fetch::{
        cloud_sync_unprotect_raw_envelope, CloudNativeProtectionScope, CloudNativeRawEnvelopeKind,
        CloudNativeStream,
    },
    cloud_sync_protector,
    cloud_sync_semantic_identity::CloudSemanticIdentifierHasher,
    cloud_sync_transient_bridge::{
        cloud_sync_decode_transient_record_cached_only, preflight_record_wire_budget,
        CloudTransientDecodeOutcome, CloudTransientDecodeRequest, CloudTransientExpectedChangeKind,
    },
};

const MAX_MESSAGE_SOURCES: usize = 8;
const MAX_ANCHOR_MESSAGE_SOURCES: usize = 2048;
const MAX_CHAT1_SOURCES: usize = 50;
const MAX_CHAT1_ROUTE_FIELD_BYTES: usize = 64 * 1024;
const MAX_CHAT1_SCAN_PAGES: usize = 20;
const MAX_CHAT1_CHANGES_PER_PAGE: u32 = 50;
const MAX_CHAT1_PARTICIPANTS: usize = 32;
const MAX_CHAT1_LEGACY_IDENTIFIERS: usize = 32;
const MAX_CHAT1_SELECTIVE_STRING_BYTES: usize = 4096;
const MAX_CHAT1_PROP_BYTES: usize = 16 * 1024;
const MAX_CHAT1_PARTICIPANT_PLAINTEXT_BYTES: usize = 4 * 1024;
const CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA: u32 = 2;
const CHAT1_ROUTE_FAILURE_FIELD_COUNT: usize = 11;
const CHAT1_ROUTE_FAILURE_KIND_COUNT: usize = 8;
const CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN: usize =
    CHAT1_ROUTE_FAILURE_FIELD_COUNT * CHAT1_ROUTE_FAILURE_KIND_COUNT;
const CHAT1_ROUTE_FAILURE_DETAIL_COUNT: usize = 17;
const CHAT1_ROUTE_FAILURE_MATRIX_LEN: usize =
    CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN + CHAT1_ROUTE_FAILURE_DETAIL_COUNT;

/// Stable row order for the aggregate-only route-field failure matrix. The
/// order is schema, not user data, and must only change with a schema bump.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(usize)]
enum Chat1RouteFailureField {
    RecordKey = 0,
    Cid = 1,
    Gid = 2,
    Ogid = 3,
    Guid = 4,
    Lah = 5,
    Svc = 6,
    Stl = 7,
    Ptcpts = 8,
    Prop = 9,
    CrossField = 10,
}

/// Stable column order for the aggregate-only route-field failure matrix.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(usize)]
enum Chat1RouteFailureKind {
    MissingValue = 0,
    WireShape = 1,
    KeySelection = 2,
    CiphertextKey = 3,
    Decrypt = 4,
    PayloadDecode = 5,
    Validation = 6,
    Cap = 7,
}

/// Schema-v2 detail counters appended after the frozen 88-cell schema-v1
/// matrix. These counters contain classifications only, never field values,
/// record identifiers, exact lengths, hashes, or per-record ordering.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(usize)]
enum Chat1RouteFailureDetail {
    LahStringValueAbsent = 0,
    LahEmpty = 1,
    LahTooLong = 2,
    LahTrimMismatch = 3,
    LahControl = 4,
    LahOther = 5,
    PtcptsDuplicate = 6,
    PtcptsOuterEmptyList = 7,
    PtcptsOuterType = 8,
    PtcptsOuterFlagAbsent = 9,
    PtcptsOuterFlagTrue = 10,
    PtcptsOuterPayload = 11,
    PtcptsEntryType = 12,
    PtcptsEntryFlagAbsent = 13,
    PtcptsEntryFlagFalse = 14,
    PtcptsEntryPayload = 15,
    PtcptsOther = 16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Chat1RouteFieldFailure {
    field: Chat1RouteFailureField,
    kind: Chat1RouteFailureKind,
    detail: Option<Chat1RouteFailureDetail>,
}

impl Chat1RouteFieldFailure {
    const fn new(field: Chat1RouteFailureField, kind: Chat1RouteFailureKind) -> Self {
        Self {
            field,
            kind,
            detail: None,
        }
    }

    const fn with_detail(
        field: Chat1RouteFailureField,
        kind: Chat1RouteFailureKind,
        detail: Chat1RouteFailureDetail,
    ) -> Self {
        Self {
            field,
            kind,
            detail: Some(detail),
        }
    }

    const fn matrix_index(self) -> usize {
        self.field as usize * CHAT1_ROUTE_FAILURE_KIND_COUNT + self.kind as usize
    }
}

/// Exact opaque metadata copied from one already-adopted journal row. No raw
/// record name, route, field value, Apple token, or message body is present.
#[derive(Clone)]
pub struct CloudSyncChat1CorrelationSourceInput {
    pub change_id_hash: String,
    pub record_id_hash: String,
    pub etag_hash: Option<String>,
    pub payload_sha256: String,
    pub payload_length: Option<u64>,
    pub server_modified_at_millis: Option<i64>,
    pub protected_raw_envelope_reference: String,
}

impl std::fmt::Debug for CloudSyncChat1CorrelationSourceInput {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CloudSyncChat1CorrelationSourceInput(redacted)")
    }
}

/// Fixed failure vocabulary. No wrapped native error or account data leaves
/// this diagnostic boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudSyncChat1CorrelationFailureCode {
    TestHostRequired,
    InvalidRequest,
    ReadAuthenticationScope,
    ActiveAccountMismatch,
    ProtectorUnavailable,
    MessageSourceMismatch,
    MessageDecodeFailed,
    Chat1SourceMismatch,
    Chat1PcsLookupFailed,
    Chat1PagedFetchFailed,
    AccountChanged,
}

/// Aggregate-only result. Exact-match fields compare a decoded Message route
/// with a verified Chat1 record name. Semantic-match fields compare its HMAC
/// with four decrypted Chat1 routing fields. Selective fields additionally
/// compare route targets with participant URIs, legacy identifiers and
/// last-addressed handle; msgProto4 group targets with cid/gid/ogid/guid and
/// legacy; and sender targets with participants and last-addressed handle.
/// Service and style are counted only as presence aggregates. Neither result
/// authorizes Chat admission, and zero never proves deletion or absence.
#[derive(Debug)]
pub struct CloudSyncChat1CorrelationResult {
    /// True when the requested bounded diagnostic returned normally. For a
    /// paged request this does not mean the whole zone was exhausted; callers
    /// must also inspect `paged_terminal_reached` and `paged_budget_exhausted`.
    pub completed: bool,
    pub message_sources: u32,
    pub decoded_message_routes: u32,
    pub distinct_message_routes: u32,
    pub message_group_id_sources: u32,
    pub message_sender_sources: u32,
    pub anchor_message_sources: u32,
    pub decoded_anchor_messages: u32,
    pub skipped_anchor_messages: u32,
    pub distinct_anchor_message_guids: u32,
    pub conflicting_anchor_message_guids: u32,
    pub chat1_sources: u32,
    pub verified_chat1_records: u32,
    pub exact_match_pairs: u32,
    pub matched_message_routes: u32,
    pub matched_chat1_records: u32,
    pub semantic_correlation_requested: bool,
    pub pcs_lookup_attempted: bool,
    pub chat_record_type_records: u32,
    pub other_record_type_records: u32,
    pub decoded_route_records: u32,
    pub record_decode_failures: u32,
    pub route_field_decode_failures: u32,
    /// Versioned, row-major aggregate counters. Rows are record_key, cid,
    /// gid, ogid, guid, lah, svc, stl, ptcpts, prop and cross_field. Columns
    /// are missing_value, wire_shape, key_selection, ciphertext_key, decrypt,
    /// payload_decode, validation and cap. Schema 2 preserves those first 88
    /// cells exactly, then appends the fixed LAH-validation and PTCPTS-shape
    /// detail taxonomy declared by `Chat1RouteFailureDetail`.
    pub route_field_failure_matrix_schema: u32,
    pub route_field_failure_matrix: Vec<u32>,
    pub chat_identifier_match_pairs: u32,
    pub group_id_match_pairs: u32,
    pub original_group_id_match_pairs: u32,
    pub guid_match_pairs: u32,
    pub semantic_match_pairs: u32,
    pub matched_semantic_message_routes: u32,
    pub matched_semantic_chat1_records: u32,
    pub route_participant_match_pairs: u32,
    pub route_legacy_match_pairs: u32,
    pub route_lah_match_pairs: u32,
    pub msgproto_chat_identifier_match_pairs: u32,
    pub msgproto_group_id_match_pairs: u32,
    pub msgproto_original_group_id_match_pairs: u32,
    pub msgproto_guid_match_pairs: u32,
    pub msgproto_legacy_match_pairs: u32,
    pub sender_participant_match_pairs: u32,
    pub sender_lah_match_pairs: u32,
    pub matched_route_extra_message_routes: u32,
    pub matched_route_extra_chat1_records: u32,
    pub matched_msgproto_targets: u32,
    pub matched_msgproto_chat1_records: u32,
    pub matched_sender_targets: u32,
    pub matched_sender_chat1_records: u32,
    pub participant_present_records: u32,
    pub legacy_present_records: u32,
    pub lah_present_records: u32,
    pub service_present_records: u32,
    pub imessage_service_records: u32,
    pub other_service_records: u32,
    pub style_group_records: u32,
    pub style_direct_records: u32,
    pub style_other_records: u32,
    pub paged_correlation_requested: bool,
    pub paged_pages_scanned: u32,
    pub paged_changes_scanned: u32,
    pub paged_chat_records: u32,
    pub paged_other_records: u32,
    pub paged_tombstones: u32,
    pub paged_record_decode_failures: u32,
    pub paged_route_field_decode_failures: u32,
    pub paged_route_field_failure_matrix: Vec<u32>,
    pub paged_semantic_match_pairs: u32,
    pub paged_matched_message_routes: u32,
    pub paged_matched_chat1_records: u32,
    pub paged_route_participant_match_pairs: u32,
    pub paged_route_legacy_match_pairs: u32,
    pub paged_route_lah_match_pairs: u32,
    pub paged_msgproto_chat_identifier_match_pairs: u32,
    pub paged_msgproto_group_id_match_pairs: u32,
    pub paged_msgproto_original_group_id_match_pairs: u32,
    pub paged_msgproto_guid_match_pairs: u32,
    pub paged_msgproto_legacy_match_pairs: u32,
    pub paged_sender_participant_match_pairs: u32,
    pub paged_sender_lah_match_pairs: u32,
    pub paged_matched_route_extra_message_routes: u32,
    pub paged_matched_route_extra_chat1_records: u32,
    pub paged_matched_msgproto_targets: u32,
    pub paged_matched_msgproto_chat1_records: u32,
    pub paged_matched_sender_targets: u32,
    pub paged_matched_sender_chat1_records: u32,
    pub paged_participant_present_records: u32,
    pub paged_legacy_present_records: u32,
    pub paged_lah_present_records: u32,
    pub paged_service_present_records: u32,
    pub paged_imessage_service_records: u32,
    pub paged_other_service_records: u32,
    pub paged_style_group_records: u32,
    pub paged_style_direct_records: u32,
    pub paged_style_other_records: u32,
    pub paged_normalized_chat_identifier_match_pairs: u32,
    pub paged_normalized_group_id_match_pairs: u32,
    pub paged_normalized_original_group_id_match_pairs: u32,
    pub paged_normalized_guid_match_pairs: u32,
    pub paged_normalized_semantic_match_pairs: u32,
    pub paged_normalized_matched_message_routes: u32,
    pub paged_normalized_matched_chat1_records: u32,
    pub paged_normalized_route_participant_match_pairs: u32,
    pub paged_normalized_route_legacy_match_pairs: u32,
    pub paged_normalized_route_lah_match_pairs: u32,
    pub paged_normalized_msgproto_chat_identifier_match_pairs: u32,
    pub paged_normalized_msgproto_group_id_match_pairs: u32,
    pub paged_normalized_msgproto_original_group_id_match_pairs: u32,
    pub paged_normalized_msgproto_guid_match_pairs: u32,
    pub paged_normalized_msgproto_legacy_match_pairs: u32,
    pub paged_normalized_sender_participant_match_pairs: u32,
    pub paged_normalized_sender_lah_match_pairs: u32,
    pub paged_normalized_matched_route_extra_message_routes: u32,
    pub paged_normalized_matched_route_extra_chat1_records: u32,
    pub paged_normalized_matched_msgproto_targets: u32,
    pub paged_normalized_matched_msgproto_chat1_records: u32,
    pub paged_normalized_matched_sender_targets: u32,
    pub paged_normalized_matched_sender_chat1_records: u32,
    pub paged_last_seen_message_guid_present_records: u32,
    pub paged_last_seen_target_message_match_pairs: u32,
    pub paged_matched_last_seen_target_messages: u32,
    pub paged_matched_last_seen_target_chat1_records: u32,
    pub paged_last_seen_anchor_exact_match_pairs: u32,
    pub paged_matched_anchor_exact_targets: u32,
    pub paged_matched_anchor_exact_chat1_records: u32,
    pub paged_last_seen_anchor_normalized_match_pairs: u32,
    pub paged_matched_anchor_normalized_targets: u32,
    pub paged_matched_anchor_normalized_chat1_records: u32,
    pub paged_sender_service_style_match_pairs: u32,
    pub paged_matched_sender_service_style_targets: u32,
    pub paged_matched_sender_service_style_chat1_records: u32,
    pub paged_sender_service_style_zero_candidate_targets: u32,
    pub paged_sender_service_style_unique_candidate_targets: u32,
    pub paged_sender_service_style_multiple_candidate_targets: u32,
    pub paged_last_seen_target_zero_candidate_targets: u32,
    pub paged_last_seen_target_unique_candidate_targets: u32,
    pub paged_last_seen_target_multiple_candidate_targets: u32,
    pub paged_anchor_exact_zero_candidate_targets: u32,
    pub paged_anchor_exact_unique_candidate_targets: u32,
    pub paged_anchor_exact_multiple_candidate_targets: u32,
    pub paged_anchor_normalized_zero_candidate_targets: u32,
    pub paged_anchor_normalized_unique_candidate_targets: u32,
    pub paged_anchor_normalized_multiple_candidate_targets: u32,
    pub paged_terminal_reached: bool,
    pub paged_budget_exhausted: bool,
    pub failure_code: Option<CloudSyncChat1CorrelationFailureCode>,
}

fn failure(code: CloudSyncChat1CorrelationFailureCode) -> CloudSyncChat1CorrelationResult {
    CloudSyncChat1CorrelationResult {
        completed: false,
        message_sources: 0,
        decoded_message_routes: 0,
        distinct_message_routes: 0,
        message_group_id_sources: 0,
        message_sender_sources: 0,
        anchor_message_sources: 0,
        decoded_anchor_messages: 0,
        skipped_anchor_messages: 0,
        distinct_anchor_message_guids: 0,
        conflicting_anchor_message_guids: 0,
        chat1_sources: 0,
        verified_chat1_records: 0,
        exact_match_pairs: 0,
        matched_message_routes: 0,
        matched_chat1_records: 0,
        semantic_correlation_requested: false,
        pcs_lookup_attempted: false,
        chat_record_type_records: 0,
        other_record_type_records: 0,
        decoded_route_records: 0,
        record_decode_failures: 0,
        route_field_decode_failures: 0,
        route_field_failure_matrix_schema: CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA,
        route_field_failure_matrix: vec![0; CHAT1_ROUTE_FAILURE_MATRIX_LEN],
        chat_identifier_match_pairs: 0,
        group_id_match_pairs: 0,
        original_group_id_match_pairs: 0,
        guid_match_pairs: 0,
        semantic_match_pairs: 0,
        matched_semantic_message_routes: 0,
        matched_semantic_chat1_records: 0,
        route_participant_match_pairs: 0,
        route_legacy_match_pairs: 0,
        route_lah_match_pairs: 0,
        msgproto_chat_identifier_match_pairs: 0,
        msgproto_group_id_match_pairs: 0,
        msgproto_original_group_id_match_pairs: 0,
        msgproto_guid_match_pairs: 0,
        msgproto_legacy_match_pairs: 0,
        sender_participant_match_pairs: 0,
        sender_lah_match_pairs: 0,
        matched_route_extra_message_routes: 0,
        matched_route_extra_chat1_records: 0,
        matched_msgproto_targets: 0,
        matched_msgproto_chat1_records: 0,
        matched_sender_targets: 0,
        matched_sender_chat1_records: 0,
        participant_present_records: 0,
        legacy_present_records: 0,
        lah_present_records: 0,
        service_present_records: 0,
        imessage_service_records: 0,
        other_service_records: 0,
        style_group_records: 0,
        style_direct_records: 0,
        style_other_records: 0,
        paged_correlation_requested: false,
        paged_pages_scanned: 0,
        paged_changes_scanned: 0,
        paged_chat_records: 0,
        paged_other_records: 0,
        paged_tombstones: 0,
        paged_record_decode_failures: 0,
        paged_route_field_decode_failures: 0,
        paged_route_field_failure_matrix: vec![0; CHAT1_ROUTE_FAILURE_MATRIX_LEN],
        paged_semantic_match_pairs: 0,
        paged_matched_message_routes: 0,
        paged_matched_chat1_records: 0,
        paged_route_participant_match_pairs: 0,
        paged_route_legacy_match_pairs: 0,
        paged_route_lah_match_pairs: 0,
        paged_msgproto_chat_identifier_match_pairs: 0,
        paged_msgproto_group_id_match_pairs: 0,
        paged_msgproto_original_group_id_match_pairs: 0,
        paged_msgproto_guid_match_pairs: 0,
        paged_msgproto_legacy_match_pairs: 0,
        paged_sender_participant_match_pairs: 0,
        paged_sender_lah_match_pairs: 0,
        paged_matched_route_extra_message_routes: 0,
        paged_matched_route_extra_chat1_records: 0,
        paged_matched_msgproto_targets: 0,
        paged_matched_msgproto_chat1_records: 0,
        paged_matched_sender_targets: 0,
        paged_matched_sender_chat1_records: 0,
        paged_participant_present_records: 0,
        paged_legacy_present_records: 0,
        paged_lah_present_records: 0,
        paged_service_present_records: 0,
        paged_imessage_service_records: 0,
        paged_other_service_records: 0,
        paged_style_group_records: 0,
        paged_style_direct_records: 0,
        paged_style_other_records: 0,
        paged_normalized_chat_identifier_match_pairs: 0,
        paged_normalized_group_id_match_pairs: 0,
        paged_normalized_original_group_id_match_pairs: 0,
        paged_normalized_guid_match_pairs: 0,
        paged_normalized_semantic_match_pairs: 0,
        paged_normalized_matched_message_routes: 0,
        paged_normalized_matched_chat1_records: 0,
        paged_normalized_route_participant_match_pairs: 0,
        paged_normalized_route_legacy_match_pairs: 0,
        paged_normalized_route_lah_match_pairs: 0,
        paged_normalized_msgproto_chat_identifier_match_pairs: 0,
        paged_normalized_msgproto_group_id_match_pairs: 0,
        paged_normalized_msgproto_original_group_id_match_pairs: 0,
        paged_normalized_msgproto_guid_match_pairs: 0,
        paged_normalized_msgproto_legacy_match_pairs: 0,
        paged_normalized_sender_participant_match_pairs: 0,
        paged_normalized_sender_lah_match_pairs: 0,
        paged_normalized_matched_route_extra_message_routes: 0,
        paged_normalized_matched_route_extra_chat1_records: 0,
        paged_normalized_matched_msgproto_targets: 0,
        paged_normalized_matched_msgproto_chat1_records: 0,
        paged_normalized_matched_sender_targets: 0,
        paged_normalized_matched_sender_chat1_records: 0,
        paged_last_seen_message_guid_present_records: 0,
        paged_last_seen_target_message_match_pairs: 0,
        paged_matched_last_seen_target_messages: 0,
        paged_matched_last_seen_target_chat1_records: 0,
        paged_last_seen_anchor_exact_match_pairs: 0,
        paged_matched_anchor_exact_targets: 0,
        paged_matched_anchor_exact_chat1_records: 0,
        paged_last_seen_anchor_normalized_match_pairs: 0,
        paged_matched_anchor_normalized_targets: 0,
        paged_matched_anchor_normalized_chat1_records: 0,
        paged_sender_service_style_match_pairs: 0,
        paged_matched_sender_service_style_targets: 0,
        paged_matched_sender_service_style_chat1_records: 0,
        paged_sender_service_style_zero_candidate_targets: 0,
        paged_sender_service_style_unique_candidate_targets: 0,
        paged_sender_service_style_multiple_candidate_targets: 0,
        paged_last_seen_target_zero_candidate_targets: 0,
        paged_last_seen_target_unique_candidate_targets: 0,
        paged_last_seen_target_multiple_candidate_targets: 0,
        paged_anchor_exact_zero_candidate_targets: 0,
        paged_anchor_exact_unique_candidate_targets: 0,
        paged_anchor_exact_multiple_candidate_targets: 0,
        paged_anchor_normalized_zero_candidate_targets: 0,
        paged_anchor_normalized_unique_candidate_targets: 0,
        paged_anchor_normalized_multiple_candidate_targets: 0,
        paged_terminal_reached: false,
        paged_budget_exhausted: false,
        failure_code: Some(code),
    }
}

fn semantic_failure(code: CloudSyncChat1CorrelationFailureCode) -> CloudSyncChat1CorrelationResult {
    let mut result = failure(code);
    result.semantic_correlation_requested = true;
    result.pcs_lookup_attempted = true;
    result
}

fn paged_semantic_failure(
    code: CloudSyncChat1CorrelationFailureCode,
) -> CloudSyncChat1CorrelationResult {
    let mut result = semantic_failure(code);
    result.paged_correlation_requested = true;
    result
}

fn is_bare_digest(value: &str) -> bool {
    value.len() == 43
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn is_hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn is_protected_reference(value: &str) -> bool {
    value.strip_prefix("obcs2.ref.").is_some_and(is_bare_digest)
}

fn is_protected_store_identity(value: &str) -> bool {
    value
        .strip_prefix("obcs2.store.")
        .is_some_and(is_bare_digest)
}

fn valid_source(source: &CloudSyncChat1CorrelationSourceInput) -> bool {
    is_bare_digest(&source.change_id_hash)
        && is_bare_digest(&source.record_id_hash)
        && source.etag_hash.as_deref().is_none_or(is_bare_digest)
        && is_hex_digest(&source.payload_sha256)
        && is_protected_reference(&source.protected_raw_envelope_reference)
}

fn valid_sources(sources: &[CloudSyncChat1CorrelationSourceInput], maximum: usize) -> bool {
    if sources.is_empty() || sources.len() > maximum || !sources.iter().all(valid_source) {
        return false;
    }
    let record_ids = sources
        .iter()
        .map(|source| source.record_id_hash.as_str())
        .collect::<HashSet<_>>();
    let references = sources
        .iter()
        .map(|source| source.protected_raw_envelope_reference.as_str())
        .collect::<HashSet<_>>();
    record_ids.len() == sources.len() && references.len() == sources.len()
}

fn message_decode_request(
    storage_directory: &str,
    expected_account_fingerprint: &str,
    expected_protected_store_identity: &str,
    generation: u64,
    source: &CloudSyncChat1CorrelationSourceInput,
) -> Result<CloudTransientDecodeRequest, ()> {
    CloudTransientDecodeRequest::new(
        PathBuf::from(storage_directory),
        expected_account_fingerprint.to_owned(),
        expected_protected_store_identity.to_owned(),
        "com.apple.messages.cloud".to_owned(),
        "private".to_owned(),
        "messageManateeZone".to_owned(),
        "messages".to_owned(),
        2,
        CloudNativeStream::Messages,
        generation,
        CloudTransientExpectedChangeKind::Save,
        source.change_id_hash.clone(),
        source.record_id_hash.clone(),
        source.etag_hash.clone(),
        source.payload_sha256.clone(),
        source.payload_length,
        source.server_modified_at_millis,
        source.protected_raw_envelope_reference.clone(),
        None,
    )
    .map_err(|_| ())
}

struct VerifiedChat1Record {
    record_id_hash: String,
    record_name: String,
    record_type: String,
    raw: Option<Vec<u8>>,
}

fn verified_chat1_record(
    storage_directory: &str,
    scope: &CloudNativeProtectionScope,
    generation: u64,
    source: &CloudSyncChat1CorrelationSourceInput,
    hasher: &CloudSemanticIdentifierHasher,
    retain_raw: bool,
) -> Result<VerifiedChat1Record, ()> {
    let envelope = cloud_sync_unprotect_raw_envelope(
        PathBuf::from(storage_directory),
        scope,
        CloudNativeStream::Chat1,
        generation,
        &source.protected_raw_envelope_reference,
    )
    .map_err(|_| ())?;
    if envelope.generation() != generation
        || envelope.stream() != CloudNativeStream::Chat1
        || envelope.kind() != CloudNativeRawEnvelopeKind::UnsupportedRecordType
        || envelope.record_type().is_none_or(str::is_empty)
        || envelope.raw().is_none()
        || envelope.raw_digest_hex() != source.payload_sha256
        || source
            .payload_length
            .is_some_and(|length| length != envelope.raw_length())
        || envelope.server_modified_at_millis() != source.server_modified_at_millis
    {
        return Err(());
    }
    let record_name = envelope
        .record_name()
        .filter(|value| !value.is_empty())
        .ok_or(())?;
    let record_type = envelope
        .record_type()
        .filter(|value| !value.is_empty())
        .ok_or(())?;
    let record_id_hash = hasher.server_record_id_hash(record_name);
    let etag_hash = envelope
        .etag()
        .filter(|value| !value.is_empty())
        .map(|etag| {
            hasher
                .canonical_etag_hash(etag)
                .map(|value| value.value().to_owned())
        })
        .transpose()
        .map_err(|_| ())?;
    if record_id_hash != source.record_id_hash || etag_hash != source.etag_hash {
        return Err(());
    }
    let change_material = format!(
        "{}\u{1f}{}\u{1f}3\u{1f}{}\u{1f}{}\u{1f}{}",
        generation,
        record_id_hash,
        envelope.change_type().unwrap_or_default(),
        source.etag_hash.as_deref().unwrap_or("none"),
        source.payload_sha256,
    );
    let change_id_hash = hasher
        .canonical_change_id_hash(&change_material)
        .map_err(|_| ())?;
    if change_id_hash.value() != source.change_id_hash {
        return Err(());
    }
    let retained_raw = if retain_raw {
        Some(envelope.raw().ok_or(())?.to_vec())
    } else {
        None
    };
    Ok(VerifiedChat1Record {
        record_id_hash,
        record_name: record_name.to_owned(),
        record_type: record_type.to_owned(),
        raw: retained_raw,
    })
}

fn record_identifier_name(record: &Record) -> Option<&str> {
    record
        .record_identifier
        .as_ref()?
        .value
        .as_ref()?
        .name
        .as_deref()
        .filter(|value| !value.is_empty())
}

fn record_type_name(record: &Record) -> Option<&str> {
    record
        .r#type
        .as_ref()?
        .name
        .as_deref()
        .filter(|value| !value.is_empty())
}

fn decode_verified_chat1_record(source: &VerifiedChat1Record) -> Result<Record, ()> {
    let raw = source.raw.as_deref().ok_or(())?;
    preflight_record_wire_budget(raw).map_err(|_| ())?;
    let record = match catch_unwind(AssertUnwindSafe(|| Record::decode(raw))) {
        Ok(Ok(value)) => value,
        _ => return Err(()),
    };
    if record_identifier_name(&record) != Some(source.record_name.as_str())
        || record_type_name(&record) != Some(source.record_type.as_str())
    {
        return Err(());
    }
    Ok(record)
}

fn encrypted_string_field(
    record: &Record,
    key: &PCSEncryptor,
    name: &str,
) -> Result<Option<String>, Chat1RouteFailureKind> {
    encrypted_string_field_with_empty_policy(record, key, name, false)
}

fn encrypted_string_field_with_empty_policy(
    record: &Record,
    key: &PCSEncryptor,
    name: &str,
    empty_is_absent: bool,
) -> Result<Option<String>, Chat1RouteFailureKind> {
    let Some(value) = unique_field_value(record, name)? else {
        return Ok(None);
    };
    if value.r#type != Some(FieldValueType::StringType as i32)
        || value.is_encrypted != Some(true)
        || value.signed_value.is_some()
        || value.double_value.is_some()
        || value.date_value.is_some()
        || value.string_value.is_some()
        || value.location_value.is_some()
        || value.reference_value.is_some()
        || value.asset_value.is_some()
        || !value.list_values.is_empty()
        || value.package_value.is_some()
    {
        return Err(Chat1RouteFailureKind::WireShape);
    }
    let ciphertext = value
        .bytes_value
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or(Chat1RouteFailureKind::MissingValue)?;
    key.validate_ciphertext_key(ciphertext)
        .map_err(|_| Chat1RouteFailureKind::CiphertextKey)?;
    let plaintext = key
        .decrypt_data_checked(ciphertext, name)
        .map_err(|_| Chat1RouteFailureKind::Decrypt)?;
    if plaintext.len() > MAX_CHAT1_ROUTE_FIELD_BYTES {
        return Err(Chat1RouteFailureKind::Cap);
    }
    let decoded = match catch_unwind(AssertUnwindSafe(|| {
        EncryptedValue::decode(plaintext.as_slice())
    })) {
        Ok(Ok(value)) => value,
        _ => return Err(Chat1RouteFailureKind::PayloadDecode),
    };
    if decoded.signed_value.is_some() || decoded.date_value.is_some() {
        return Err(Chat1RouteFailureKind::PayloadDecode);
    }
    let decoded = decoded
        .string_value
        .ok_or(Chat1RouteFailureKind::Validation)?;
    if decoded.is_empty() && empty_is_absent {
        return Ok(None);
    }
    identifier(&decoded).ok_or(Chat1RouteFailureKind::Validation)?;
    Ok(Some(decoded))
}

fn encrypted_last_addressed_handle(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<Option<String>, Chat1RouteFailureKind> {
    // Live Chat1 records prove Apple emits an encrypted empty string for `lah`.
    // `lah` is corroboration only, never an ownership/admission signal, so an
    // empty value is equivalent to absence. Keep every other scalar strict.
    encrypted_string_field_with_empty_policy(record, key, "lah", true)
}

fn classify_lah_validation_detail(record: &Record, key: &PCSEncryptor) -> Chat1RouteFailureDetail {
    let value = match unique_field_value(record, "lah") {
        Ok(Some(value)) => value,
        _ => return Chat1RouteFailureDetail::LahOther,
    };
    let Some(ciphertext) = value
        .bytes_value
        .as_deref()
        .filter(|value| !value.is_empty())
    else {
        return Chat1RouteFailureDetail::LahOther;
    };
    let plaintext = match key.decrypt_data_checked(ciphertext, "lah") {
        Ok(value) => value,
        Err(_) => return Chat1RouteFailureDetail::LahOther,
    };
    let decoded = match catch_unwind(AssertUnwindSafe(|| {
        EncryptedValue::decode(plaintext.as_slice())
    })) {
        Ok(Ok(value)) => value,
        _ => return Chat1RouteFailureDetail::LahOther,
    };
    let Some(value) = decoded.string_value else {
        return Chat1RouteFailureDetail::LahStringValueAbsent;
    };
    if value.is_empty() {
        Chat1RouteFailureDetail::LahEmpty
    } else if value.len() > MAX_CHAT1_SELECTIVE_STRING_BYTES {
        Chat1RouteFailureDetail::LahTooLong
    } else if value.trim() != value {
        Chat1RouteFailureDetail::LahTrimMismatch
    } else if value.chars().any(char::is_control) {
        Chat1RouteFailureDetail::LahControl
    } else {
        Chat1RouteFailureDetail::LahOther
    }
}

fn unique_field_value(record: &Record, name: &str) -> Result<Option<Value>, Chat1RouteFailureKind> {
    let mut matching = record.record_field.iter().filter(|field| {
        field
            .identifier
            .as_ref()
            .and_then(|identifier| identifier.name.as_deref())
            == Some(name)
    });
    let Some(field) = matching.next() else {
        return Ok(None);
    };
    if matching.next().is_some() {
        return Err(Chat1RouteFailureKind::WireShape);
    }
    field
        .value
        .clone()
        .ok_or(Chat1RouteFailureKind::MissingValue)
        .map(Some)
}

fn encrypted_i64_field(
    record: &Record,
    key: &PCSEncryptor,
    name: &str,
) -> Result<Option<i64>, Chat1RouteFailureKind> {
    let Some(value) = unique_field_value(record, name)? else {
        return Ok(None);
    };
    if value.r#type != Some(FieldValueType::Int64Type as i32)
        || value.is_encrypted != Some(true)
        || value.signed_value.is_some()
        || value.double_value.is_some()
        || value.date_value.is_some()
        || value.string_value.is_some()
        || value.location_value.is_some()
        || value.reference_value.is_some()
        || value.asset_value.is_some()
        || !value.list_values.is_empty()
        || value.package_value.is_some()
    {
        return Err(Chat1RouteFailureKind::WireShape);
    }
    let ciphertext = value
        .bytes_value
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or(Chat1RouteFailureKind::MissingValue)?;
    key.validate_ciphertext_key(ciphertext)
        .map_err(|_| Chat1RouteFailureKind::CiphertextKey)?;
    let plaintext = key
        .decrypt_data_checked(ciphertext, name)
        .map_err(|_| Chat1RouteFailureKind::Decrypt)?;
    if plaintext.is_empty() {
        return Err(Chat1RouteFailureKind::MissingValue);
    }
    if plaintext.len() > MAX_CHAT1_ROUTE_FIELD_BYTES {
        return Err(Chat1RouteFailureKind::Cap);
    }
    let decoded = match catch_unwind(AssertUnwindSafe(|| {
        EncryptedValue::decode(plaintext.as_slice())
    })) {
        Ok(Ok(value)) => value,
        _ => return Err(Chat1RouteFailureKind::PayloadDecode),
    };
    if decoded.string_value.is_some() || decoded.date_value.is_some() {
        return Err(Chat1RouteFailureKind::PayloadDecode);
    }
    decoded
        .signed_value
        .map(Some)
        .ok_or(Chat1RouteFailureKind::Validation)
}

fn encrypted_participant_uris(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<Vec<String>, Chat1RouteFailureKind> {
    let Some(value) = unique_field_value(record, "ptcpts")? else {
        return Ok(Vec::new());
    };
    if value.r#type != Some(FieldValueType::EncryptedBytesListType as i32)
        || value.is_encrypted == Some(true)
        || value.bytes_value.is_some()
        || value.signed_value.is_some()
        || value.double_value.is_some()
        || value.date_value.is_some()
        || value.string_value.is_some()
        || value.location_value.is_some()
        || value.reference_value.is_some()
        || value.asset_value.is_some()
        || value.package_value.is_some()
    {
        return Err(Chat1RouteFailureKind::WireShape);
    }
    if value.list_values.len() > MAX_CHAT1_PARTICIPANTS {
        return Err(Chat1RouteFailureKind::Cap);
    }
    let mut uris = Vec::with_capacity(value.list_values.len());
    for entry in &value.list_values {
        if entry.r#type != Some(FieldValueType::EncryptedBytesType as i32)
            || entry.is_encrypted == Some(false)
            || entry.signed_value.is_some()
            || entry.double_value.is_some()
            || entry.date_value.is_some()
            || entry.string_value.is_some()
            || entry.location_value.is_some()
            || entry.reference_value.is_some()
            || entry.asset_value.is_some()
            || !entry.list_values.is_empty()
            || entry.package_value.is_some()
        {
            return Err(Chat1RouteFailureKind::WireShape);
        }
        let ciphertext = entry
            .bytes_value
            .as_deref()
            .filter(|value| !value.is_empty())
            .ok_or(Chat1RouteFailureKind::MissingValue)?;
        key.validate_ciphertext_key(ciphertext)
            .map_err(|_| Chat1RouteFailureKind::CiphertextKey)?;
        let plaintext = key
            .decrypt_data_checked(ciphertext, "ptcpts")
            .map_err(|_| Chat1RouteFailureKind::Decrypt)?;
        if plaintext.is_empty() {
            return Err(Chat1RouteFailureKind::MissingValue);
        }
        if plaintext.len() > MAX_CHAT1_PARTICIPANT_PLAINTEXT_BYTES {
            return Err(Chat1RouteFailureKind::Cap);
        }
        let decoded_participant: CloudParticipant = match catch_unwind(AssertUnwindSafe(|| {
            plist::from_bytes::<CloudParticipant>(&plaintext)
        })) {
            Ok(Ok(value)) => value,
            _ => return Err(Chat1RouteFailureKind::PayloadDecode),
        };
        if decoded_participant.uri.len() > MAX_CHAT1_SELECTIVE_STRING_BYTES {
            return Err(Chat1RouteFailureKind::Cap);
        }
        if participant(&decoded_participant.uri).is_none() {
            return Err(Chat1RouteFailureKind::Validation);
        }
        uris.push(decoded_participant.uri);
    }
    Ok(uris)
}

fn classify_ptcpts_wire_shape_detail(record: &Record) -> Chat1RouteFailureDetail {
    let mut matching = record.record_field.iter().filter(|field| {
        field
            .identifier
            .as_ref()
            .and_then(|identifier| identifier.name.as_deref())
            == Some("ptcpts")
    });
    let Some(field) = matching.next() else {
        return Chat1RouteFailureDetail::PtcptsOther;
    };
    if matching.next().is_some() {
        return Chat1RouteFailureDetail::PtcptsDuplicate;
    }
    let Some(value) = field.value.as_ref() else {
        return Chat1RouteFailureDetail::PtcptsOther;
    };
    if value.r#type == Some(FieldValueType::EmptyList as i32) {
        return Chat1RouteFailureDetail::PtcptsOuterEmptyList;
    }
    if value.r#type != Some(FieldValueType::EncryptedBytesListType as i32) {
        return Chat1RouteFailureDetail::PtcptsOuterType;
    }
    if value.is_encrypted == Some(true) {
        return Chat1RouteFailureDetail::PtcptsOuterFlagTrue;
    }
    if value.bytes_value.is_some()
        || value.signed_value.is_some()
        || value.double_value.is_some()
        || value.date_value.is_some()
        || value.string_value.is_some()
        || value.location_value.is_some()
        || value.reference_value.is_some()
        || value.asset_value.is_some()
        || value.package_value.is_some()
    {
        return Chat1RouteFailureDetail::PtcptsOuterPayload;
    }
    for entry in &value.list_values {
        if entry.r#type != Some(FieldValueType::EncryptedBytesType as i32) {
            return Chat1RouteFailureDetail::PtcptsEntryType;
        }
        if entry.is_encrypted == Some(false) {
            return Chat1RouteFailureDetail::PtcptsEntryFlagFalse;
        }
        if entry.signed_value.is_some()
            || entry.double_value.is_some()
            || entry.date_value.is_some()
            || entry.string_value.is_some()
            || entry.location_value.is_some()
            || entry.reference_value.is_some()
            || entry.asset_value.is_some()
            || !entry.list_values.is_empty()
            || entry.package_value.is_some()
        {
            return Chat1RouteFailureDetail::PtcptsEntryPayload;
        }
    }
    Chat1RouteFailureDetail::PtcptsOther
}

#[derive(Default)]
#[frb(ignore)]
struct SelectiveChatProperties {
    legacy_identifiers: Vec<String>,
    last_seen_message_guid: Option<String>,
}

fn encrypted_chat_properties(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<SelectiveChatProperties, Chat1RouteFailureKind> {
    let Some(value) = unique_field_value(record, "prop")? else {
        return Ok(SelectiveChatProperties::default());
    };
    if value.r#type == Some(FieldValueType::EmptyList as i32) {
        if value.is_encrypted == Some(true)
            || value.bytes_value.is_some()
            || value.signed_value.is_some()
            || value.double_value.is_some()
            || value.date_value.is_some()
            || value.string_value.is_some()
            || value.location_value.is_some()
            || value.reference_value.is_some()
            || value.asset_value.is_some()
            || !value.list_values.is_empty()
            || value.package_value.is_some()
        {
            return Err(Chat1RouteFailureKind::WireShape);
        }
        return Ok(SelectiveChatProperties::default());
    }
    if value.r#type != Some(FieldValueType::EncryptedBytesType as i32)
        || value.is_encrypted != Some(true)
        || value.signed_value.is_some()
        || value.double_value.is_some()
        || value.date_value.is_some()
        || value.string_value.is_some()
        || value.location_value.is_some()
        || value.reference_value.is_some()
        || value.asset_value.is_some()
        || !value.list_values.is_empty()
        || value.package_value.is_some()
    {
        return Err(Chat1RouteFailureKind::WireShape);
    }
    let ciphertext = value
        .bytes_value
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or(Chat1RouteFailureKind::MissingValue)?;
    key.validate_ciphertext_key(ciphertext)
        .map_err(|_| Chat1RouteFailureKind::CiphertextKey)?;
    let plaintext = key
        .decrypt_data_checked(ciphertext, "prop")
        .map_err(|_| Chat1RouteFailureKind::Decrypt)?;
    if plaintext.is_empty() {
        return Ok(SelectiveChatProperties::default());
    }
    if plaintext.len() > MAX_CHAT1_PROP_BYTES {
        return Err(Chat1RouteFailureKind::Cap);
    }
    let properties: CloudProp = match catch_unwind(AssertUnwindSafe(|| {
        plist::from_bytes::<CloudProp>(&plaintext)
    })) {
        Ok(Ok(value)) => value,
        _ => return Err(Chat1RouteFailureKind::PayloadDecode),
    };
    if properties.legacy_group_identifiers.len() > MAX_CHAT1_LEGACY_IDENTIFIERS {
        return Err(Chat1RouteFailureKind::Cap);
    }
    for identifier in &properties.legacy_group_identifiers {
        if identifier.len() > MAX_CHAT1_SELECTIVE_STRING_BYTES {
            return Err(Chat1RouteFailureKind::Cap);
        }
        if crate::cloud_sync_chat_identity::identifier(identifier).is_none() {
            return Err(Chat1RouteFailureKind::Validation);
        }
    }
    let last_seen_message_guid = match properties.last_seen_message_guid {
        // This is optional reference evidence. An encrypted empty value cannot
        // prove a relation, so the diagnostic treats it as absent without
        // weakening validation of any non-empty identifier.
        Some(value) if value.is_empty() => None,
        Some(value) => {
            if value.len() > MAX_CHAT1_SELECTIVE_STRING_BYTES || identifier(&value).is_none() {
                return Err(Chat1RouteFailureKind::Validation);
            }
            Some(value)
        }
        None => None,
    };
    Ok(SelectiveChatProperties {
        legacy_identifiers: properties.legacy_group_identifiers,
        last_seen_message_guid,
    })
}

#[cfg(test)]
fn encrypted_legacy_identifiers(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<Vec<String>, Chat1RouteFailureKind> {
    encrypted_chat_properties(record, key).map(|value| value.legacy_identifiers)
}

fn target_mask(
    value: Option<&str>,
    targets: &[String],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    let Some(value) = value.filter(|value| !value.is_empty()) else {
        return 0;
    };
    let hashed = hasher.server_record_id_hash(value);
    targets
        .iter()
        .enumerate()
        .fold(0u8, |mask, (index, target)| {
            if hashed == *target {
                mask | 1u8.checked_shl(index as u32).unwrap_or(0)
            } else {
                mask
            }
        })
}

#[frb(ignore)]
struct NormalizedRouteTarget {
    variant_hashes: HashSet<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[frb(ignore)]
enum MessageRouteKind {
    Direct,
    Group,
    Bare,
}

fn message_route_kind(value: &str) -> Result<MessageRouteKind, ()> {
    let mut parts = value.splitn(3, ';');
    let Some(service) = parts.next() else {
        return Err(());
    };
    let Some(marker) = parts.next() else {
        return Ok(MessageRouteKind::Bare);
    };
    let Some(target) = parts.next() else {
        return Err(());
    };
    if !matches!(service, "iMessage" | "SMS") || target.is_empty() {
        return Err(());
    }
    match marker {
        "-" => Ok(MessageRouteKind::Direct),
        "+" => Ok(MessageRouteKind::Group),
        _ => Err(()),
    }
}

#[frb(ignore)]
struct MessageRouteAnchor {
    route_hash: String,
    normalized_route: NormalizedRouteTarget,
}

#[derive(Default)]
#[frb(ignore)]
struct MessageAnchorIndex {
    routes_by_guid_hash: HashMap<String, MessageRouteAnchor>,
    conflicting_guid_hashes: HashSet<String>,
    decoded_sources: u32,
    skipped_sources: u32,
}

impl MessageAnchorIndex {
    fn observe_decoded_source(
        &mut self,
        guid: &str,
        route: &str,
        hasher: &CloudSemanticIdentifierHasher,
    ) -> Result<(), ()> {
        if identifier(guid).is_none() || identifier(route).is_none() {
            return Err(());
        }
        let normalized_route = normalized_route_target(route, hasher)?;
        self.decoded_sources = self.decoded_sources.saturating_add(1);
        let guid_hash = hasher.server_record_id_hash(guid);
        let route_hash = hasher.server_record_id_hash(route);
        if self.conflicting_guid_hashes.contains(&guid_hash) {
            return Ok(());
        }
        if let Some(existing) = self.routes_by_guid_hash.get(&guid_hash) {
            if existing.route_hash != route_hash {
                self.routes_by_guid_hash.remove(&guid_hash);
                self.conflicting_guid_hashes.insert(guid_hash);
            }
            return Ok(());
        }
        self.routes_by_guid_hash.insert(
            guid_hash,
            MessageRouteAnchor {
                route_hash,
                normalized_route,
            },
        );
        Ok(())
    }
}

fn hashed_target_mask(value_hash: &str, targets: &[String]) -> u8 {
    targets
        .iter()
        .enumerate()
        .fold(0u8, |mask, (index, target)| {
            if value_hash == target {
                mask | 1u8.checked_shl(index as u32).unwrap_or(0)
            } else {
                mask
            }
        })
}

fn normalized_anchor_target_mask(
    anchor: &NormalizedRouteTarget,
    targets: &[NormalizedRouteTarget],
) -> u8 {
    targets
        .iter()
        .enumerate()
        .fold(0u8, |mask, (index, target)| {
            if anchor
                .variant_hashes
                .iter()
                .any(|hash| target.variant_hashes.contains(hash))
            {
                mask | 1u8.checked_shl(index as u32).unwrap_or(0)
            } else {
                mask
            }
        })
}

fn service_style_compatible_mask(
    mask: u8,
    service: Option<&str>,
    style: Option<i64>,
    route_kinds: &[MessageRouteKind],
) -> u8 {
    // A conversation can currently route over SMS while still owning older
    // iMessages. Both services therefore remain eligible parent metadata;
    // unsupported RCS/iMessageLite records cannot narrow an iMessage target.
    if !matches!(service, Some("iMessage") | Some("SMS")) {
        return 0;
    }
    route_kinds
        .iter()
        .enumerate()
        .fold(0u8, |compatible, (index, kind)| {
            let bit = 1u8.checked_shl(index as u32).unwrap_or(0);
            let style_matches = match kind {
                MessageRouteKind::Direct => style == Some(45),
                MessageRouteKind::Group => style == Some(43),
                MessageRouteKind::Bare => matches!(style, Some(43) | Some(45)),
            };
            if mask & bit != 0 && style_matches {
                compatible | bit
            } else {
                compatible
            }
        })
}

fn normalized_route_target(
    value: &str,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<NormalizedRouteTarget, ()> {
    let variant_hashes = normalized_chat_identity_variants(value)
        .ok_or(())?
        .into_iter()
        .map(|variant| hasher.server_record_id_hash(&variant))
        .collect::<HashSet<_>>();
    if variant_hashes.is_empty() {
        return Err(());
    }
    Ok(NormalizedRouteTarget { variant_hashes })
}

fn normalized_target_mask(
    value: Option<&str>,
    targets: &[NormalizedRouteTarget],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    let Some(variants) = value.and_then(normalized_chat_identity_variants) else {
        return 0;
    };
    let field_hashes = variants
        .into_iter()
        .map(|variant| hasher.server_record_id_hash(&variant))
        .collect::<HashSet<_>>();
    targets
        .iter()
        .enumerate()
        .fold(0u8, |mask, (index, target)| {
            if field_hashes
                .iter()
                .any(|hash| target.variant_hashes.contains(hash))
            {
                mask | 1u8.checked_shl(index as u32).unwrap_or(0)
            } else {
                mask
            }
        })
}

fn optional_target_mask(
    value: Option<&str>,
    targets: &[Option<String>],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    let Some(value) = value.filter(|value| !value.is_empty()) else {
        return 0;
    };
    let hashed = hasher.server_record_id_hash(value);
    targets
        .iter()
        .enumerate()
        .fold(0u8, |mask, (index, target)| {
            if target.as_deref().is_some_and(|target| hashed == *target) {
                mask | 1u8.checked_shl(index as u32).unwrap_or(0)
            } else {
                mask
            }
        })
}

fn normalized_optional_target_mask(
    value: Option<&str>,
    targets: &[Option<NormalizedRouteTarget>],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    let Some(variants) = value.and_then(normalized_chat_identity_variants) else {
        return 0;
    };
    let field_hashes = variants
        .into_iter()
        .map(|variant| hasher.server_record_id_hash(&variant))
        .collect::<HashSet<_>>();
    targets
        .iter()
        .enumerate()
        .fold(0u8, |mask, (index, target)| {
            let matched = target.as_ref().is_some_and(|target| {
                field_hashes
                    .iter()
                    .any(|hash| target.variant_hashes.contains(hash))
            });
            if matched {
                mask | 1u8.checked_shl(index as u32).unwrap_or(0)
            } else {
                mask
            }
        })
}

fn multi_target_mask(
    values: &[String],
    targets: &[String],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    values.iter().fold(0u8, |mask, value| {
        mask | target_mask(Some(value), targets, hasher)
    })
}

fn multi_normalized_target_mask(
    values: &[String],
    targets: &[NormalizedRouteTarget],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    values.iter().fold(0u8, |mask, value| {
        mask | normalized_target_mask(Some(value), targets, hasher)
    })
}

fn multi_optional_target_mask(
    values: &[String],
    targets: &[Option<String>],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    values.iter().fold(0u8, |mask, value| {
        mask | optional_target_mask(Some(value), targets, hasher)
    })
}

fn multi_normalized_optional_target_mask(
    values: &[String],
    targets: &[Option<NormalizedRouteTarget>],
    hasher: &CloudSemanticIdentifierHasher,
) -> u8 {
    values.iter().fold(0u8, |mask, value| {
        mask | normalized_optional_target_mask(Some(value), targets, hasher)
    })
}

#[frb(ignore)]
#[derive(Default)]
struct RouteFieldMatches {
    chat_identifier: u8,
    group_id: u8,
    original_group_id: u8,
    guid: u8,
    normalized_chat_identifier: u8,
    normalized_group_id: u8,
    normalized_original_group_id: u8,
    normalized_guid: u8,
    route_participants: u8,
    route_legacy: u8,
    route_lah: u8,
    msgproto_chat_identifier: u8,
    msgproto_group_id: u8,
    msgproto_original_group_id: u8,
    msgproto_guid: u8,
    msgproto_legacy: u8,
    sender_participants: u8,
    sender_lah: u8,
    normalized_route_participants: u8,
    normalized_route_legacy: u8,
    normalized_route_lah: u8,
    normalized_msgproto_chat_identifier: u8,
    normalized_msgproto_group_id: u8,
    normalized_msgproto_original_group_id: u8,
    normalized_msgproto_guid: u8,
    normalized_msgproto_legacy: u8,
    normalized_sender_participants: u8,
    normalized_sender_lah: u8,
    last_seen_target_message: u8,
    last_seen_anchor_exact: u8,
    last_seen_anchor_normalized: u8,
    sender_service_style: u8,
    has_participants: bool,
    has_legacy: bool,
    has_lah: bool,
    has_last_seen_message_guid: bool,
    has_service: bool,
    service_imessage: bool,
    service_other: bool,
    style_group: bool,
    style_direct: bool,
    style_other: bool,
}

impl RouteFieldMatches {
    fn combined(&self) -> u8 {
        self.chat_identifier | self.group_id | self.original_group_id | self.guid
    }

    fn pairs(&self) -> u32 {
        self.chat_identifier.count_ones()
            + self.group_id.count_ones()
            + self.original_group_id.count_ones()
            + self.guid.count_ones()
    }

    fn normalized_combined(&self) -> u8 {
        self.normalized_chat_identifier
            | self.normalized_group_id
            | self.normalized_original_group_id
            | self.normalized_guid
    }

    fn normalized_pairs(&self) -> u32 {
        self.normalized_chat_identifier.count_ones()
            + self.normalized_group_id.count_ones()
            + self.normalized_original_group_id.count_ones()
            + self.normalized_guid.count_ones()
    }

    fn route_extra_combined(&self) -> u8 {
        self.route_participants | self.route_legacy
    }

    fn route_extra_pairs(&self) -> u32 {
        self.route_participants.count_ones()
            + self.route_legacy.count_ones()
            + self.route_lah.count_ones()
    }

    fn normalized_route_extra_combined(&self) -> u8 {
        self.normalized_route_participants | self.normalized_route_legacy
    }

    fn normalized_route_extra_pairs(&self) -> u32 {
        self.normalized_route_participants.count_ones()
            + self.normalized_route_legacy.count_ones()
            + self.normalized_route_lah.count_ones()
    }

    fn msgproto_combined(&self) -> u8 {
        self.msgproto_chat_identifier
            | self.msgproto_group_id
            | self.msgproto_original_group_id
            | self.msgproto_guid
            | self.msgproto_legacy
    }

    fn msgproto_pairs(&self) -> u32 {
        self.msgproto_chat_identifier.count_ones()
            + self.msgproto_group_id.count_ones()
            + self.msgproto_original_group_id.count_ones()
            + self.msgproto_guid.count_ones()
            + self.msgproto_legacy.count_ones()
    }

    fn normalized_msgproto_combined(&self) -> u8 {
        self.normalized_msgproto_chat_identifier
            | self.normalized_msgproto_group_id
            | self.normalized_msgproto_original_group_id
            | self.normalized_msgproto_guid
            | self.normalized_msgproto_legacy
    }

    fn normalized_msgproto_pairs(&self) -> u32 {
        self.normalized_msgproto_chat_identifier.count_ones()
            + self.normalized_msgproto_group_id.count_ones()
            + self.normalized_msgproto_original_group_id.count_ones()
            + self.normalized_msgproto_guid.count_ones()
            + self.normalized_msgproto_legacy.count_ones()
    }

    fn sender_combined(&self) -> u8 {
        self.sender_participants
    }

    fn sender_pairs(&self) -> u32 {
        self.sender_participants.count_ones() + self.sender_lah.count_ones()
    }

    fn normalized_sender_combined(&self) -> u8 {
        self.normalized_sender_participants
    }

    fn normalized_sender_pairs(&self) -> u32 {
        self.normalized_sender_participants.count_ones() + self.normalized_sender_lah.count_ones()
    }
}

fn inspect_chat1_route_fields(
    record: &Record,
    zone_key: &rustpush::cloudkit::PCSZoneConfig,
    targets: &[String],
    normalized_targets: &[NormalizedRouteTarget],
    msgproto_targets: &[Option<String>],
    normalized_msgproto_targets: &[Option<NormalizedRouteTarget>],
    sender_targets: &[Option<String>],
    normalized_sender_targets: &[Option<NormalizedRouteTarget>],
    message_guid_targets: &[String],
    message_route_kinds: &[MessageRouteKind],
    anchor_index: &MessageAnchorIndex,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<RouteFieldMatches, Chat1RouteFieldFailure> {
    let record_key = match catch_unwind(AssertUnwindSafe(|| pcs_keys_for_record(record, zone_key)))
    {
        Ok(Ok(value)) => value,
        _ => {
            return Err(Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::RecordKey,
                Chat1RouteFailureKind::KeySelection,
            ))
        }
    };
    inspect_chat1_route_fields_with_key(
        record,
        &record_key,
        targets,
        normalized_targets,
        msgproto_targets,
        normalized_msgproto_targets,
        sender_targets,
        normalized_sender_targets,
        message_guid_targets,
        message_route_kinds,
        anchor_index,
        hasher,
    )
}

fn inspect_chat1_route_fields_with_key(
    record: &Record,
    record_key: &PCSEncryptor,
    targets: &[String],
    normalized_targets: &[NormalizedRouteTarget],
    msgproto_targets: &[Option<String>],
    normalized_msgproto_targets: &[Option<NormalizedRouteTarget>],
    sender_targets: &[Option<String>],
    normalized_sender_targets: &[Option<NormalizedRouteTarget>],
    message_guid_targets: &[String],
    message_route_kinds: &[MessageRouteKind],
    anchor_index: &MessageAnchorIndex,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<RouteFieldMatches, Chat1RouteFieldFailure> {
    let map_failure = |field: Chat1RouteFailureField| {
        move |kind: Chat1RouteFailureKind| Chat1RouteFieldFailure::new(field, kind)
    };
    let chat_identifier = encrypted_string_field(record, record_key, "cid")
        .map_err(map_failure(Chat1RouteFailureField::Cid))?;
    let group_id = encrypted_string_field(record, record_key, "gid")
        .map_err(map_failure(Chat1RouteFailureField::Gid))?;
    let original_group_id = encrypted_string_field(record, record_key, "ogid")
        .map_err(map_failure(Chat1RouteFailureField::Ogid))?;
    let guid = encrypted_string_field(record, record_key, "guid")
        .map_err(map_failure(Chat1RouteFailureField::Guid))?;
    let last_addressed_handle =
        encrypted_last_addressed_handle(record, record_key).map_err(|kind| {
            if kind == Chat1RouteFailureKind::Validation {
                Chat1RouteFieldFailure::with_detail(
                    Chat1RouteFailureField::Lah,
                    kind,
                    classify_lah_validation_detail(record, record_key),
                )
            } else {
                Chat1RouteFieldFailure::new(Chat1RouteFailureField::Lah, kind)
            }
        })?;
    let service_name = encrypted_string_field(record, record_key, "svc")
        .map_err(map_failure(Chat1RouteFailureField::Svc))?;
    let style = encrypted_i64_field(record, record_key, "stl")
        .map_err(map_failure(Chat1RouteFailureField::Stl))?;
    let participants = encrypted_participant_uris(record, record_key).map_err(|kind| {
        if kind == Chat1RouteFailureKind::WireShape {
            Chat1RouteFieldFailure::with_detail(
                Chat1RouteFailureField::Ptcpts,
                kind,
                classify_ptcpts_wire_shape_detail(record),
            )
        } else {
            Chat1RouteFieldFailure::new(Chat1RouteFailureField::Ptcpts, kind)
        }
    })?;
    let properties = encrypted_chat_properties(record, record_key)
        .map_err(map_failure(Chat1RouteFailureField::Prop))?;
    let legacy_identifiers = &properties.legacy_identifiers;
    let last_seen_message_guid = properties.last_seen_message_guid.as_deref();
    for value in participants
        .iter()
        .chain(legacy_identifiers.iter())
        .chain(last_addressed_handle.iter())
        .chain(service_name.iter())
    {
        if value.len() > MAX_CHAT1_SELECTIVE_STRING_BYTES {
            return Err(Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::CrossField,
                Chat1RouteFailureKind::Cap,
            ));
        }
    }
    let sender_participants = multi_optional_target_mask(&participants, sender_targets, hasher);
    let last_seen_target_message =
        target_mask(last_seen_message_guid, message_guid_targets, hasher);
    let (last_seen_anchor_exact, last_seen_anchor_normalized) = last_seen_message_guid
        .map(|guid| hasher.server_record_id_hash(guid))
        .and_then(|guid_hash| anchor_index.routes_by_guid_hash.get(&guid_hash))
        .map(|anchor| {
            (
                hashed_target_mask(&anchor.route_hash, targets),
                normalized_anchor_target_mask(&anchor.normalized_route, normalized_targets),
            )
        })
        .unwrap_or((0, 0));
    let sender_service_style = service_style_compatible_mask(
        sender_participants,
        service_name.as_deref(),
        style,
        message_route_kinds,
    );
    let last_seen_target_message = service_style_compatible_mask(
        last_seen_target_message,
        service_name.as_deref(),
        style,
        message_route_kinds,
    );
    let last_seen_anchor_exact = service_style_compatible_mask(
        last_seen_anchor_exact,
        service_name.as_deref(),
        style,
        message_route_kinds,
    );
    let last_seen_anchor_normalized = service_style_compatible_mask(
        last_seen_anchor_normalized,
        service_name.as_deref(),
        style,
        message_route_kinds,
    );
    Ok(RouteFieldMatches {
        chat_identifier: target_mask(chat_identifier.as_deref(), targets, hasher),
        group_id: target_mask(group_id.as_deref(), targets, hasher),
        original_group_id: target_mask(original_group_id.as_deref(), targets, hasher),
        guid: target_mask(guid.as_deref(), targets, hasher),
        normalized_chat_identifier: normalized_target_mask(
            chat_identifier.as_deref(),
            normalized_targets,
            hasher,
        ),
        normalized_group_id: normalized_target_mask(
            group_id.as_deref(),
            normalized_targets,
            hasher,
        ),
        normalized_original_group_id: normalized_target_mask(
            original_group_id.as_deref(),
            normalized_targets,
            hasher,
        ),
        normalized_guid: normalized_target_mask(guid.as_deref(), normalized_targets, hasher),
        route_participants: multi_target_mask(&participants, targets, hasher),
        route_legacy: multi_target_mask(legacy_identifiers, targets, hasher),
        route_lah: target_mask(last_addressed_handle.as_deref(), targets, hasher),
        msgproto_chat_identifier: optional_target_mask(
            chat_identifier.as_deref(),
            msgproto_targets,
            hasher,
        ),
        msgproto_group_id: optional_target_mask(group_id.as_deref(), msgproto_targets, hasher),
        msgproto_original_group_id: optional_target_mask(
            original_group_id.as_deref(),
            msgproto_targets,
            hasher,
        ),
        msgproto_guid: optional_target_mask(guid.as_deref(), msgproto_targets, hasher),
        msgproto_legacy: multi_optional_target_mask(legacy_identifiers, msgproto_targets, hasher),
        sender_participants,
        sender_lah: optional_target_mask(last_addressed_handle.as_deref(), sender_targets, hasher),
        normalized_route_participants: multi_normalized_target_mask(
            &participants,
            normalized_targets,
            hasher,
        ),
        normalized_route_legacy: multi_normalized_target_mask(
            legacy_identifiers,
            normalized_targets,
            hasher,
        ),
        normalized_route_lah: normalized_target_mask(
            last_addressed_handle.as_deref(),
            normalized_targets,
            hasher,
        ),
        normalized_msgproto_chat_identifier: normalized_optional_target_mask(
            chat_identifier.as_deref(),
            normalized_msgproto_targets,
            hasher,
        ),
        normalized_msgproto_group_id: normalized_optional_target_mask(
            group_id.as_deref(),
            normalized_msgproto_targets,
            hasher,
        ),
        normalized_msgproto_original_group_id: normalized_optional_target_mask(
            original_group_id.as_deref(),
            normalized_msgproto_targets,
            hasher,
        ),
        normalized_msgproto_guid: normalized_optional_target_mask(
            guid.as_deref(),
            normalized_msgproto_targets,
            hasher,
        ),
        normalized_msgproto_legacy: multi_normalized_optional_target_mask(
            legacy_identifiers,
            normalized_msgproto_targets,
            hasher,
        ),
        normalized_sender_participants: multi_normalized_optional_target_mask(
            &participants,
            normalized_sender_targets,
            hasher,
        ),
        normalized_sender_lah: normalized_optional_target_mask(
            last_addressed_handle.as_deref(),
            normalized_sender_targets,
            hasher,
        ),
        last_seen_target_message,
        last_seen_anchor_exact,
        last_seen_anchor_normalized,
        sender_service_style,
        has_participants: !participants.is_empty(),
        has_legacy: !legacy_identifiers.is_empty(),
        has_lah: last_addressed_handle
            .as_deref()
            .is_some_and(|value| !value.is_empty()),
        has_last_seen_message_guid: last_seen_message_guid.is_some(),
        has_service: service_name
            .as_deref()
            .is_some_and(|value| !value.is_empty()),
        service_imessage: service_name.as_deref() == Some("iMessage"),
        service_other: service_name
            .as_deref()
            .is_some_and(|value| !value.is_empty() && value != "iMessage"),
        style_group: style == Some(43),
        style_direct: style == Some(45),
        style_other: style.is_some_and(|value| value != 43 && value != 45),
    })
}

#[frb(ignore)]
#[derive(Default)]
struct SemanticMatchCounts {
    chat_record_type_records: u32,
    other_record_type_records: u32,
    decoded_route_records: u32,
    record_decode_failures: u32,
    route_field_decode_failures: u32,
    // Vec avoids exposing a const-sized internal array to the pinned FRB 2.3
    // parser. Snapshots below always normalize it to the schema length.
    route_field_failure_matrix: Vec<u32>,
    chat_identifier_match_pairs: u32,
    group_id_match_pairs: u32,
    original_group_id_match_pairs: u32,
    guid_match_pairs: u32,
    semantic_match_pairs: u32,
    matched_message_route_mask: u8,
    matched_chat1_records: u32,
    normalized_chat_identifier_match_pairs: u32,
    normalized_group_id_match_pairs: u32,
    normalized_original_group_id_match_pairs: u32,
    normalized_guid_match_pairs: u32,
    normalized_semantic_match_pairs: u32,
    normalized_matched_message_route_mask: u8,
    normalized_matched_chat1_records: u32,
    route_participant_match_pairs: u32,
    route_legacy_match_pairs: u32,
    route_lah_match_pairs: u32,
    msgproto_chat_identifier_match_pairs: u32,
    msgproto_group_id_match_pairs: u32,
    msgproto_original_group_id_match_pairs: u32,
    msgproto_guid_match_pairs: u32,
    msgproto_legacy_match_pairs: u32,
    sender_participant_match_pairs: u32,
    sender_lah_match_pairs: u32,
    matched_route_extra_mask: u8,
    matched_route_extra_chat1_records: u32,
    matched_msgproto_mask: u8,
    matched_msgproto_chat1_records: u32,
    matched_sender_mask: u8,
    matched_sender_chat1_records: u32,
    normalized_route_participant_match_pairs: u32,
    normalized_route_legacy_match_pairs: u32,
    normalized_route_lah_match_pairs: u32,
    normalized_msgproto_chat_identifier_match_pairs: u32,
    normalized_msgproto_group_id_match_pairs: u32,
    normalized_msgproto_original_group_id_match_pairs: u32,
    normalized_msgproto_guid_match_pairs: u32,
    normalized_msgproto_legacy_match_pairs: u32,
    normalized_sender_participant_match_pairs: u32,
    normalized_sender_lah_match_pairs: u32,
    normalized_matched_route_extra_mask: u8,
    normalized_matched_route_extra_chat1_records: u32,
    normalized_matched_msgproto_mask: u8,
    normalized_matched_msgproto_chat1_records: u32,
    normalized_matched_sender_mask: u8,
    normalized_matched_sender_chat1_records: u32,
    participant_present_records: u32,
    legacy_present_records: u32,
    lah_present_records: u32,
    service_present_records: u32,
    imessage_service_records: u32,
    other_service_records: u32,
    style_group_records: u32,
    style_direct_records: u32,
    style_other_records: u32,
    last_seen_message_guid_present_records: u32,
    last_seen_target_message_match_pairs: u32,
    matched_last_seen_target_message_mask: u8,
    matched_last_seen_target_chat1_records: u32,
    last_seen_anchor_exact_match_pairs: u32,
    matched_anchor_exact_mask: u8,
    matched_anchor_exact_chat1_records: u32,
    last_seen_anchor_normalized_match_pairs: u32,
    matched_anchor_normalized_mask: u8,
    matched_anchor_normalized_chat1_records: u32,
    sender_service_style_match_pairs: u32,
    matched_sender_service_style_mask: u8,
    matched_sender_service_style_chat1_records: u32,
    sender_service_style_candidate_counts: Vec<u16>,
    last_seen_target_candidate_counts: Vec<u16>,
    anchor_exact_candidate_counts: Vec<u16>,
    anchor_normalized_candidate_counts: Vec<u16>,
}

impl SemanticMatchCounts {
    fn observe_route_field_failure(&mut self, failure: Chat1RouteFieldFailure) {
        self.route_field_decode_failures = self.route_field_decode_failures.saturating_add(1);
        if self.route_field_failure_matrix.len() != CHAT1_ROUTE_FAILURE_MATRIX_LEN {
            self.route_field_failure_matrix
                .resize(CHAT1_ROUTE_FAILURE_MATRIX_LEN, 0);
        }
        let slot = self
            .route_field_failure_matrix
            .get_mut(failure.matrix_index())
            .expect("route-field failure matrix index must match schema");
        *slot = slot.saturating_add(1);
        let detail = failure
            .detail
            .or_else(|| match (failure.field, failure.kind) {
                (Chat1RouteFailureField::Lah, Chat1RouteFailureKind::Validation) => {
                    Some(Chat1RouteFailureDetail::LahOther)
                }
                (Chat1RouteFailureField::Ptcpts, Chat1RouteFailureKind::WireShape) => {
                    Some(Chat1RouteFailureDetail::PtcptsOther)
                }
                _ => None,
            });
        if let Some(index) =
            detail.map(|value| CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN + value as usize)
        {
            let detail_slot = self
                .route_field_failure_matrix
                .get_mut(index)
                .expect("route-field failure detail index must match schema");
            *detail_slot = detail_slot.saturating_add(1);
        }
    }

    fn route_field_failure_matrix_snapshot(&self) -> Vec<u32> {
        let mut snapshot = self.route_field_failure_matrix.clone();
        snapshot.resize(CHAT1_ROUTE_FAILURE_MATRIX_LEN, 0);
        snapshot.truncate(CHAT1_ROUTE_FAILURE_MATRIX_LEN);
        snapshot
    }

    fn observe_candidate_mask(counts: &mut Vec<u16>, mask: u8) {
        counts.resize(MAX_MESSAGE_SOURCES, 0);
        counts.truncate(MAX_MESSAGE_SOURCES);
        for (index, count) in counts.iter_mut().enumerate() {
            if mask & (1u8 << index) != 0 {
                *count = count.saturating_add(1);
            }
        }
    }

    fn candidate_cardinality(counts: &[u16]) -> CandidateCardinality {
        (0..MAX_MESSAGE_SOURCES).fold(
            CandidateCardinality::default(),
            |mut cardinality, index| {
                let count = counts.get(index).copied().unwrap_or(0);
                match count {
                    0 => cardinality.zero += 1,
                    1 => cardinality.unique += 1,
                    _ => cardinality.multiple += 1,
                }
                cardinality
            },
        )
    }

    fn observe(&mut self, fields: &RouteFieldMatches) {
        self.decoded_route_records += 1;
        self.chat_identifier_match_pairs += fields.chat_identifier.count_ones();
        self.group_id_match_pairs += fields.group_id.count_ones();
        self.original_group_id_match_pairs += fields.original_group_id.count_ones();
        self.guid_match_pairs += fields.guid.count_ones();
        self.semantic_match_pairs += fields.pairs();
        let combined = fields.combined();
        self.matched_message_route_mask |= combined;
        if combined != 0 {
            self.matched_chat1_records += 1;
        }
        self.normalized_chat_identifier_match_pairs +=
            fields.normalized_chat_identifier.count_ones();
        self.normalized_group_id_match_pairs += fields.normalized_group_id.count_ones();
        self.normalized_original_group_id_match_pairs +=
            fields.normalized_original_group_id.count_ones();
        self.normalized_guid_match_pairs += fields.normalized_guid.count_ones();
        self.normalized_semantic_match_pairs += fields.normalized_pairs();
        let normalized_combined = fields.normalized_combined();
        self.normalized_matched_message_route_mask |= normalized_combined;
        if normalized_combined != 0 {
            self.normalized_matched_chat1_records += 1;
        }
        self.route_participant_match_pairs += fields.route_participants.count_ones();
        self.route_legacy_match_pairs += fields.route_legacy.count_ones();
        self.route_lah_match_pairs += fields.route_lah.count_ones();
        self.msgproto_chat_identifier_match_pairs += fields.msgproto_chat_identifier.count_ones();
        self.msgproto_group_id_match_pairs += fields.msgproto_group_id.count_ones();
        self.msgproto_original_group_id_match_pairs +=
            fields.msgproto_original_group_id.count_ones();
        self.msgproto_guid_match_pairs += fields.msgproto_guid.count_ones();
        self.msgproto_legacy_match_pairs += fields.msgproto_legacy.count_ones();
        self.sender_participant_match_pairs += fields.sender_participants.count_ones();
        self.sender_lah_match_pairs += fields.sender_lah.count_ones();
        let route_extra = fields.route_extra_combined();
        self.matched_route_extra_mask |= route_extra;
        if route_extra != 0 {
            self.matched_route_extra_chat1_records += 1;
        }
        let msgproto = fields.msgproto_combined();
        self.matched_msgproto_mask |= msgproto;
        if msgproto != 0 {
            self.matched_msgproto_chat1_records += 1;
        }
        let sender = fields.sender_combined();
        self.matched_sender_mask |= sender;
        if sender != 0 {
            self.matched_sender_chat1_records += 1;
        }
        self.normalized_route_participant_match_pairs +=
            fields.normalized_route_participants.count_ones();
        self.normalized_route_legacy_match_pairs += fields.normalized_route_legacy.count_ones();
        self.normalized_route_lah_match_pairs += fields.normalized_route_lah.count_ones();
        self.normalized_msgproto_chat_identifier_match_pairs +=
            fields.normalized_msgproto_chat_identifier.count_ones();
        self.normalized_msgproto_group_id_match_pairs +=
            fields.normalized_msgproto_group_id.count_ones();
        self.normalized_msgproto_original_group_id_match_pairs +=
            fields.normalized_msgproto_original_group_id.count_ones();
        self.normalized_msgproto_guid_match_pairs += fields.normalized_msgproto_guid.count_ones();
        self.normalized_msgproto_legacy_match_pairs +=
            fields.normalized_msgproto_legacy.count_ones();
        self.normalized_sender_participant_match_pairs +=
            fields.normalized_sender_participants.count_ones();
        self.normalized_sender_lah_match_pairs += fields.normalized_sender_lah.count_ones();
        let normalized_route_extra = fields.normalized_route_extra_combined();
        self.normalized_matched_route_extra_mask |= normalized_route_extra;
        if normalized_route_extra != 0 {
            self.normalized_matched_route_extra_chat1_records += 1;
        }
        let normalized_msgproto = fields.normalized_msgproto_combined();
        self.normalized_matched_msgproto_mask |= normalized_msgproto;
        if normalized_msgproto != 0 {
            self.normalized_matched_msgproto_chat1_records += 1;
        }
        let normalized_sender = fields.normalized_sender_combined();
        self.normalized_matched_sender_mask |= normalized_sender;
        if normalized_sender != 0 {
            self.normalized_matched_sender_chat1_records += 1;
        }
        if fields.has_participants {
            self.participant_present_records += 1;
        }
        if fields.has_legacy {
            self.legacy_present_records += 1;
        }
        if fields.has_lah {
            self.lah_present_records += 1;
        }
        if fields.has_service {
            self.service_present_records += 1;
        }
        if fields.service_imessage {
            self.imessage_service_records += 1;
        } else if fields.service_other {
            self.other_service_records += 1;
        }
        if fields.style_group {
            self.style_group_records += 1;
        } else if fields.style_direct {
            self.style_direct_records += 1;
        } else if fields.style_other {
            self.style_other_records += 1;
        }
        if fields.has_last_seen_message_guid {
            self.last_seen_message_guid_present_records += 1;
        }
        self.last_seen_target_message_match_pairs += fields.last_seen_target_message.count_ones();
        self.matched_last_seen_target_message_mask |= fields.last_seen_target_message;
        if fields.last_seen_target_message != 0 {
            self.matched_last_seen_target_chat1_records += 1;
        }
        self.last_seen_anchor_exact_match_pairs += fields.last_seen_anchor_exact.count_ones();
        self.matched_anchor_exact_mask |= fields.last_seen_anchor_exact;
        if fields.last_seen_anchor_exact != 0 {
            self.matched_anchor_exact_chat1_records += 1;
        }
        self.last_seen_anchor_normalized_match_pairs +=
            fields.last_seen_anchor_normalized.count_ones();
        self.matched_anchor_normalized_mask |= fields.last_seen_anchor_normalized;
        if fields.last_seen_anchor_normalized != 0 {
            self.matched_anchor_normalized_chat1_records += 1;
        }
        self.sender_service_style_match_pairs += fields.sender_service_style.count_ones();
        self.matched_sender_service_style_mask |= fields.sender_service_style;
        if fields.sender_service_style != 0 {
            self.matched_sender_service_style_chat1_records += 1;
        }
        Self::observe_candidate_mask(
            &mut self.sender_service_style_candidate_counts,
            fields.sender_service_style,
        );
        Self::observe_candidate_mask(
            &mut self.last_seen_target_candidate_counts,
            fields.last_seen_target_message,
        );
        Self::observe_candidate_mask(
            &mut self.anchor_exact_candidate_counts,
            fields.last_seen_anchor_exact,
        );
        Self::observe_candidate_mask(
            &mut self.anchor_normalized_candidate_counts,
            fields.last_seen_anchor_normalized,
        );
    }
}

#[derive(Default)]
#[frb(ignore)]
struct CandidateCardinality {
    zero: u32,
    unique: u32,
    multiple: u32,
}

#[frb(ignore)]
#[derive(Default)]
struct PagedSemanticCounts {
    pages_scanned: u32,
    changes_scanned: u32,
    tombstones: u32,
    terminal_reached: bool,
    budget_exhausted: bool,
    semantic: SemanticMatchCounts,
}

#[derive(Debug, Eq, PartialEq)]
struct MatchCounts {
    distinct_message_routes: usize,
    exact_match_pairs: usize,
    matched_message_routes: usize,
    matched_chat1_records: usize,
}

fn exact_match_counts(message_routes: &[String], chat1_records: &[String]) -> MatchCounts {
    let distinct_message_routes = message_routes.iter().collect::<HashSet<_>>();
    let chat1_record_set = chat1_records.iter().collect::<HashSet<_>>();
    MatchCounts {
        distinct_message_routes: distinct_message_routes.len(),
        exact_match_pairs: message_routes
            .iter()
            .map(|route| {
                chat1_records
                    .iter()
                    .filter(|record| *record == route)
                    .count()
            })
            .sum(),
        matched_message_routes: distinct_message_routes
            .iter()
            .filter(|route| chat1_record_set.contains(*route))
            .count(),
        matched_chat1_records: chat1_record_set
            .iter()
            .filter(|record| distinct_message_routes.contains(*record))
            .count(),
    }
}

async fn scan_chat1_route_pages(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    permit: &rustpush::cloudkit_operation_gate::CloudKitReadAuthenticationPermit<'_>,
    zone_key: &rustpush::cloudkit::PCSZoneConfig,
    targets: &[String],
    normalized_targets: &[NormalizedRouteTarget],
    msgproto_targets: &[Option<String>],
    normalized_msgproto_targets: &[Option<NormalizedRouteTarget>],
    sender_targets: &[Option<String>],
    normalized_sender_targets: &[Option<NormalizedRouteTarget>],
    message_guid_targets: &[String],
    message_route_kinds: &[MessageRouteKind],
    anchor_index: &MessageAnchorIndex,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<PagedSemanticCounts, ()> {
    let mut counts = PagedSemanticCounts::default();
    let mut continuation_token = None;
    for page_index in 0..MAX_CHAT1_SCAN_PAGES {
        let page = cloud_messages_client
            .sync_chat1_discovery_page_for_read_authentication(
                permit,
                continuation_token.take(),
                Some(MAX_CHAT1_CHANGES_PER_PAGE),
            )
            .await
            .map_err(|_| ())?;
        if page.changes.len() > MAX_CHAT1_CHANGES_PER_PAGE as usize {
            return Err(());
        }
        let page_complete = page.is_complete();
        let next_token = page.next_token;
        counts.pages_scanned = counts.pages_scanned.checked_add(1).ok_or(())?;
        counts.changes_scanned = counts
            .changes_scanned
            .checked_add(u32::try_from(page.changes.len()).map_err(|_| ())?)
            .ok_or(())?;
        for change in page.changes {
            match change.kind {
                CloudMessageRecordKind::Tombstone => {
                    counts.tombstones += 1;
                }
                CloudMessageRecordKind::UnsupportedRecordType => {
                    if change.record_type.as_deref() != Some(CloudChat::record_type()) {
                        counts.semantic.other_record_type_records += 1;
                        continue;
                    }
                    counts.semantic.chat_record_type_records += 1;
                    if change
                        .record_name
                        .as_deref()
                        .filter(|value| !value.is_empty())
                        .is_none()
                    {
                        counts.semantic.record_decode_failures += 1;
                        continue;
                    }
                    let Some(raw) = change.encrypted_record else {
                        counts.semantic.record_decode_failures += 1;
                        continue;
                    };
                    if preflight_record_wire_budget(&raw).is_err() {
                        counts.semantic.record_decode_failures += 1;
                        continue;
                    }
                    let record =
                        match catch_unwind(AssertUnwindSafe(|| Record::decode(raw.as_slice()))) {
                            Ok(Ok(record)) => record,
                            _ => {
                                counts.semantic.record_decode_failures += 1;
                                continue;
                            }
                        };
                    if record_identifier_name(&record) != change.record_name.as_deref()
                        || record_type_name(&record) != change.record_type.as_deref()
                    {
                        counts.semantic.record_decode_failures += 1;
                        continue;
                    }
                    match inspect_chat1_route_fields(
                        &record,
                        zone_key,
                        targets,
                        normalized_targets,
                        msgproto_targets,
                        normalized_msgproto_targets,
                        sender_targets,
                        normalized_sender_targets,
                        message_guid_targets,
                        message_route_kinds,
                        anchor_index,
                        hasher,
                    ) {
                        Ok(fields) => counts.semantic.observe(&fields),
                        Err(failure) => counts.semantic.observe_route_field_failure(failure),
                    }
                }
                CloudMessageRecordKind::EncryptedUpsert
                | CloudMessageRecordKind::MalformedMetadata => {
                    counts.semantic.record_decode_failures += 1;
                }
            }
        }
        if page_complete {
            counts.terminal_reached = true;
            break;
        }
        continuation_token = next_token;
        if continuation_token.is_none() {
            return Err(());
        }
        if page_index + 1 == MAX_CHAT1_SCAN_PAGES {
            counts.budget_exhausted = true;
        }
    }
    Ok(counts)
}

/// Performs one bounded comparison under the exact active native writer pause.
/// The default path is cached-only. A separately gated semantic diagnostic may
/// resolve the existing Chat1 PCS configuration with lookup-only reads, then
/// decrypt only selective routing strings (cid/gid/ogid/guid/lah/svc/stl and
/// participant URIs plus prop legacy identifiers and lastSeenMessageGuid).
/// The optional anchor set is decoded only from already-protected local
/// Message rows and leaves only aggregate cardinalities. Neither path persists a
/// token, projects, admits, saves, deletes, synchronizes keychain state, or
/// repairs identity.
#[allow(clippy::too_many_arguments)]
pub async fn cloud_sync_inspect_chat1_record_name_correlation_under_writer_pause(
    cloud_messages_client: &Arc<CloudMessagesClient<DefaultAnisetteProvider>>,
    native_writer_pause_token: u64,
    storage_directory: String,
    expected_account_fingerprint: String,
    expected_protected_store_identity: String,
    message_generation: u64,
    message_sources: Vec<CloudSyncChat1CorrelationSourceInput>,
    anchor_message_sources: Vec<CloudSyncChat1CorrelationSourceInput>,
    chat1_generation: u64,
    chat1_sources: Vec<CloudSyncChat1CorrelationSourceInput>,
) -> CloudSyncChat1CorrelationResult {
    let semantic_correlation =
        std::env::var("OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION").as_deref() == Ok("1");
    let paged_correlation =
        std::env::var("OPENBUBBLES_INSPECT_CHAT1_PAGED_CORRELATION").as_deref() == Ok("1");
    if std::env::var("OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST").as_deref() != Ok("1")
        || std::env::var("OPENBUBBLES_INSPECT_CHAT1_CORRELATION").as_deref() != Ok("1")
        || !is_cloud_sync_windows_dev_profile(&storage_directory)
    {
        return failure(CloudSyncChat1CorrelationFailureCode::TestHostRequired);
    }
    if (paged_correlation && !semantic_correlation)
        || !is_bare_digest(&expected_account_fingerprint)
        || !is_protected_store_identity(&expected_protected_store_identity)
        || message_generation == 0
        || chat1_generation == 0
        || message_sources.len() != MAX_MESSAGE_SOURCES
        || !valid_sources(&message_sources, MAX_MESSAGE_SOURCES)
        || !valid_sources(&anchor_message_sources, MAX_ANCHOR_MESSAGE_SOURCES)
        || !valid_sources(&chat1_sources, MAX_CHAT1_SOURCES)
    {
        return failure(CloudSyncChat1CorrelationFailureCode::InvalidRequest);
    }
    let permit = match acquire_cloudkit_read_authentication(native_writer_pause_token) {
        Ok(permit) => permit,
        Err(_) => return failure(CloudSyncChat1CorrelationFailureCode::ReadAuthenticationScope),
    };
    let before =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth)
                if auth.account_fingerprint == expected_account_fingerprint
                    && auth.protected_store_identity == expected_protected_store_identity =>
            {
                auth
            }
            _ => return failure(CloudSyncChat1CorrelationFailureCode::ActiveAccountMismatch),
        };
    let hasher = match cloud_sync_protector::semantic_identifier_hasher(storage_directory.clone()) {
        Ok(hasher) => hasher,
        Err(_) => return failure(CloudSyncChat1CorrelationFailureCode::ProtectorUnavailable),
    };

    let mut message_route_hashes = Vec::with_capacity(message_sources.len());
    let mut normalized_message_targets = Vec::with_capacity(message_sources.len());
    let mut message_msgproto_hashes: Vec<Option<String>> =
        Vec::with_capacity(message_sources.len());
    let mut normalized_msgproto_targets: Vec<Option<NormalizedRouteTarget>> =
        Vec::with_capacity(message_sources.len());
    let mut message_sender_hashes: Vec<Option<String>> = Vec::with_capacity(message_sources.len());
    let mut normalized_sender_targets: Vec<Option<NormalizedRouteTarget>> =
        Vec::with_capacity(message_sources.len());
    let mut message_guid_hashes = Vec::with_capacity(message_sources.len());
    let mut message_route_kinds = Vec::with_capacity(message_sources.len());
    for source in &message_sources {
        let request = match message_decode_request(
            &storage_directory,
            &expected_account_fingerprint,
            &expected_protected_store_identity,
            message_generation,
            source,
        ) {
            Ok(request) => request,
            Err(()) => return failure(CloudSyncChat1CorrelationFailureCode::MessageSourceMismatch),
        };
        let mutation = match cloud_sync_decode_transient_record_cached_only(
            cloud_messages_client,
            &permit,
            request,
        )
        .await
        {
            CloudTransientDecodeOutcome::Ready(mutation) => mutation,
            _ => return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed),
        };
        let (guid, route, msgproto_group_id, sender_handle) = match mutation.payload() {
            Some(CloudCanonicalPayload::Message(payload)) => (
                payload.guid().to_owned(),
                payload.chat_identifier().to_owned(),
                payload.msg_proto_4_group_id().map(str::to_owned),
                payload.sender_handle().to_owned(),
            ),
            _ => return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed),
        };
        if identifier(&guid).is_none() || identifier(&route).is_none() {
            return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed);
        }
        message_guid_hashes.push(hasher.server_record_id_hash(&guid));
        message_route_kinds.push(match message_route_kind(&route) {
            Ok(value) => value,
            Err(()) => return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed),
        });
        message_route_hashes.push(hasher.server_record_id_hash(&route));
        let normalized_target = match normalized_route_target(&route, &hasher) {
            Ok(value) => value,
            Err(()) => return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed),
        };
        normalized_message_targets.push(normalized_target);
        match msgproto_group_id
            .as_deref()
            .filter(|value| !value.is_empty())
        {
            Some(group_id) => {
                if identifier(group_id).is_none() {
                    return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed);
                }
                message_msgproto_hashes.push(Some(hasher.server_record_id_hash(group_id)));
                match normalized_route_target(group_id, &hasher) {
                    Ok(value) => normalized_msgproto_targets.push(Some(value)),
                    Err(()) => {
                        return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed)
                    }
                }
            }
            None => {
                message_msgproto_hashes.push(None);
                normalized_msgproto_targets.push(None);
            }
        }
        if sender_handle.is_empty() {
            message_sender_hashes.push(None);
            normalized_sender_targets.push(None);
        } else {
            if participant(&sender_handle).is_none() {
                return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed);
            }
            message_sender_hashes.push(Some(hasher.server_record_id_hash(&sender_handle)));
            match normalized_route_target(&sender_handle, &hasher) {
                Ok(value) => normalized_sender_targets.push(Some(value)),
                Err(()) => {
                    return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed)
                }
            }
        }
    }

    let mut anchor_index = MessageAnchorIndex::default();
    for source in &anchor_message_sources {
        let request = match message_decode_request(
            &storage_directory,
            &expected_account_fingerprint,
            &expected_protected_store_identity,
            message_generation,
            source,
        ) {
            Ok(request) => request,
            Err(()) => {
                anchor_index.skipped_sources = anchor_index.skipped_sources.saturating_add(1);
                continue;
            }
        };
        let mutation = match cloud_sync_decode_transient_record_cached_only(
            cloud_messages_client,
            &permit,
            request,
        )
        .await
        {
            CloudTransientDecodeOutcome::Ready(mutation) => mutation,
            _ => {
                anchor_index.skipped_sources = anchor_index.skipped_sources.saturating_add(1);
                continue;
            }
        };
        let (guid, route) = match mutation.payload() {
            Some(CloudCanonicalPayload::Message(payload)) => (
                payload.guid().to_owned(),
                payload.chat_identifier().to_owned(),
            ),
            _ => {
                anchor_index.skipped_sources = anchor_index.skipped_sources.saturating_add(1);
                continue;
            }
        };
        if anchor_index
            .observe_decoded_source(&guid, &route, &hasher)
            .is_err()
        {
            anchor_index.skipped_sources = anchor_index.skipped_sources.saturating_add(1);
        }
    }

    let chat1_scope = match CloudNativeProtectionScope::new(
        expected_account_fingerprint.clone(),
        CloudNativeStream::Chat1,
    ) {
        Ok(scope) => scope,
        Err(_) => return failure(CloudSyncChat1CorrelationFailureCode::InvalidRequest),
    };
    let chat1_zone_key = if semantic_correlation {
        let container = match cloud_messages_client
            .get_cached_container_for_read_authentication(&permit)
            .await
        {
            Ok(value) => value,
            Err(_) => {
                return semantic_failure(CloudSyncChat1CorrelationFailureCode::Chat1PcsLookupFailed)
            }
        };
        let zone = container.private_zone("chat1ManateeZone".to_owned());
        match container
            .get_zone_encryption_config_lookup_only(
                &zone,
                &cloud_messages_client.keychain,
                &MESSAGES_SERVICE,
            )
            .await
        {
            Ok(value) => Some(value),
            Err(_) => {
                return semantic_failure(CloudSyncChat1CorrelationFailureCode::Chat1PcsLookupFailed)
            }
        }
    } else {
        None
    };
    let mut chat1_record_hashes = Vec::with_capacity(chat1_sources.len());
    let mut semantic_counts = SemanticMatchCounts::default();
    for source in &chat1_sources {
        let verified = match verified_chat1_record(
            &storage_directory,
            &chat1_scope,
            chat1_generation,
            source,
            &hasher,
            semantic_correlation,
        ) {
            Ok(value) => value,
            Err(()) => return failure(CloudSyncChat1CorrelationFailureCode::Chat1SourceMismatch),
        };
        chat1_record_hashes.push(verified.record_id_hash.clone());
        if !semantic_correlation {
            continue;
        }
        if verified.record_type != CloudChat::record_type() {
            semantic_counts.other_record_type_records += 1;
            continue;
        }
        semantic_counts.chat_record_type_records += 1;
        let record = match decode_verified_chat1_record(&verified) {
            Ok(value) => value,
            Err(()) => {
                semantic_counts.record_decode_failures += 1;
                continue;
            }
        };
        let Some(zone_key) = chat1_zone_key.as_ref() else {
            return semantic_failure(CloudSyncChat1CorrelationFailureCode::Chat1PcsLookupFailed);
        };
        let fields = match inspect_chat1_route_fields(
            &record,
            zone_key,
            &message_route_hashes,
            &normalized_message_targets,
            &message_msgproto_hashes,
            &normalized_msgproto_targets,
            &message_sender_hashes,
            &normalized_sender_targets,
            &message_guid_hashes,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        ) {
            Ok(value) => value,
            Err(failure) => {
                semantic_counts.observe_route_field_failure(failure);
                continue;
            }
        };
        semantic_counts.observe(&fields);
    }

    let paged_counts = if paged_correlation {
        let Some(zone_key) = chat1_zone_key.as_ref() else {
            return paged_semantic_failure(
                CloudSyncChat1CorrelationFailureCode::Chat1PcsLookupFailed,
            );
        };
        match scan_chat1_route_pages(
            cloud_messages_client,
            &permit,
            zone_key,
            &message_route_hashes,
            &normalized_message_targets,
            &message_msgproto_hashes,
            &normalized_msgproto_targets,
            &message_sender_hashes,
            &normalized_sender_targets,
            &message_guid_hashes,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        )
        .await
        {
            Ok(value) => value,
            Err(()) => {
                return paged_semantic_failure(
                    CloudSyncChat1CorrelationFailureCode::Chat1PagedFetchFailed,
                )
            }
        }
    } else {
        PagedSemanticCounts::default()
    };

    let after =
        match cloud_sync_capture_auth_snapshot(cloud_messages_client, storage_directory.clone())
            .await
        {
            Ok(auth) => auth,
            Err(_) => return failure(CloudSyncChat1CorrelationFailureCode::AccountChanged),
        };
    if !cloud_sync_auth_identity_remains_exact(
        &before,
        &after,
        &expected_account_fingerprint,
        &expected_protected_store_identity,
    ) {
        return failure(CloudSyncChat1CorrelationFailureCode::AccountChanged);
    }
    let counts = exact_match_counts(&message_route_hashes, &chat1_record_hashes);
    let sender_service_style_cardinality = if paged_correlation {
        SemanticMatchCounts::candidate_cardinality(
            &paged_counts.semantic.sender_service_style_candidate_counts,
        )
    } else {
        CandidateCardinality::default()
    };
    let last_seen_target_cardinality = if paged_correlation {
        SemanticMatchCounts::candidate_cardinality(
            &paged_counts.semantic.last_seen_target_candidate_counts,
        )
    } else {
        CandidateCardinality::default()
    };
    let anchor_exact_cardinality = if paged_correlation {
        SemanticMatchCounts::candidate_cardinality(
            &paged_counts.semantic.anchor_exact_candidate_counts,
        )
    } else {
        CandidateCardinality::default()
    };
    let anchor_normalized_cardinality = if paged_correlation {
        SemanticMatchCounts::candidate_cardinality(
            &paged_counts.semantic.anchor_normalized_candidate_counts,
        )
    } else {
        CandidateCardinality::default()
    };
    CloudSyncChat1CorrelationResult {
        completed: true,
        message_sources: message_sources.len() as u32,
        decoded_message_routes: message_route_hashes.len() as u32,
        distinct_message_routes: counts.distinct_message_routes as u32,
        message_group_id_sources: message_msgproto_hashes
            .iter()
            .filter(|value| value.is_some())
            .count() as u32,
        message_sender_sources: message_sender_hashes
            .iter()
            .filter(|value| value.is_some())
            .count() as u32,
        anchor_message_sources: anchor_message_sources.len() as u32,
        decoded_anchor_messages: anchor_index.decoded_sources,
        skipped_anchor_messages: anchor_index.skipped_sources,
        distinct_anchor_message_guids: anchor_index.routes_by_guid_hash.len() as u32,
        conflicting_anchor_message_guids: anchor_index.conflicting_guid_hashes.len() as u32,
        chat1_sources: chat1_sources.len() as u32,
        verified_chat1_records: chat1_record_hashes.len() as u32,
        exact_match_pairs: counts.exact_match_pairs as u32,
        matched_message_routes: counts.matched_message_routes as u32,
        matched_chat1_records: counts.matched_chat1_records as u32,
        semantic_correlation_requested: semantic_correlation,
        pcs_lookup_attempted: semantic_correlation,
        chat_record_type_records: semantic_counts.chat_record_type_records,
        other_record_type_records: semantic_counts.other_record_type_records,
        decoded_route_records: semantic_counts.decoded_route_records,
        record_decode_failures: semantic_counts.record_decode_failures,
        route_field_decode_failures: semantic_counts.route_field_decode_failures,
        route_field_failure_matrix_schema: CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA,
        route_field_failure_matrix: semantic_counts.route_field_failure_matrix_snapshot(),
        chat_identifier_match_pairs: semantic_counts.chat_identifier_match_pairs,
        group_id_match_pairs: semantic_counts.group_id_match_pairs,
        original_group_id_match_pairs: semantic_counts.original_group_id_match_pairs,
        guid_match_pairs: semantic_counts.guid_match_pairs,
        semantic_match_pairs: semantic_counts.semantic_match_pairs,
        matched_semantic_message_routes: semantic_counts.matched_message_route_mask.count_ones(),
        matched_semantic_chat1_records: semantic_counts.matched_chat1_records,
        route_participant_match_pairs: semantic_counts.route_participant_match_pairs,
        route_legacy_match_pairs: semantic_counts.route_legacy_match_pairs,
        route_lah_match_pairs: semantic_counts.route_lah_match_pairs,
        msgproto_chat_identifier_match_pairs: semantic_counts.msgproto_chat_identifier_match_pairs,
        msgproto_group_id_match_pairs: semantic_counts.msgproto_group_id_match_pairs,
        msgproto_original_group_id_match_pairs: semantic_counts
            .msgproto_original_group_id_match_pairs,
        msgproto_guid_match_pairs: semantic_counts.msgproto_guid_match_pairs,
        msgproto_legacy_match_pairs: semantic_counts.msgproto_legacy_match_pairs,
        sender_participant_match_pairs: semantic_counts.sender_participant_match_pairs,
        sender_lah_match_pairs: semantic_counts.sender_lah_match_pairs,
        matched_route_extra_message_routes: semantic_counts.matched_route_extra_mask.count_ones(),
        matched_route_extra_chat1_records: semantic_counts.matched_route_extra_chat1_records,
        matched_msgproto_targets: semantic_counts.matched_msgproto_mask.count_ones(),
        matched_msgproto_chat1_records: semantic_counts.matched_msgproto_chat1_records,
        matched_sender_targets: semantic_counts.matched_sender_mask.count_ones(),
        matched_sender_chat1_records: semantic_counts.matched_sender_chat1_records,
        participant_present_records: semantic_counts.participant_present_records,
        legacy_present_records: semantic_counts.legacy_present_records,
        lah_present_records: semantic_counts.lah_present_records,
        service_present_records: semantic_counts.service_present_records,
        imessage_service_records: semantic_counts.imessage_service_records,
        other_service_records: semantic_counts.other_service_records,
        style_group_records: semantic_counts.style_group_records,
        style_direct_records: semantic_counts.style_direct_records,
        style_other_records: semantic_counts.style_other_records,
        paged_correlation_requested: paged_correlation,
        paged_pages_scanned: paged_counts.pages_scanned,
        paged_changes_scanned: paged_counts.changes_scanned,
        paged_chat_records: paged_counts.semantic.chat_record_type_records,
        paged_other_records: paged_counts.semantic.other_record_type_records,
        paged_tombstones: paged_counts.tombstones,
        paged_record_decode_failures: paged_counts.semantic.record_decode_failures,
        paged_route_field_decode_failures: paged_counts.semantic.route_field_decode_failures,
        paged_route_field_failure_matrix: paged_counts
            .semantic
            .route_field_failure_matrix_snapshot(),
        paged_semantic_match_pairs: paged_counts.semantic.semantic_match_pairs,
        paged_matched_message_routes: paged_counts
            .semantic
            .matched_message_route_mask
            .count_ones(),
        paged_matched_chat1_records: paged_counts.semantic.matched_chat1_records,
        paged_route_participant_match_pairs: paged_counts.semantic.route_participant_match_pairs,
        paged_route_legacy_match_pairs: paged_counts.semantic.route_legacy_match_pairs,
        paged_route_lah_match_pairs: paged_counts.semantic.route_lah_match_pairs,
        paged_msgproto_chat_identifier_match_pairs: paged_counts
            .semantic
            .msgproto_chat_identifier_match_pairs,
        paged_msgproto_group_id_match_pairs: paged_counts.semantic.msgproto_group_id_match_pairs,
        paged_msgproto_original_group_id_match_pairs: paged_counts
            .semantic
            .msgproto_original_group_id_match_pairs,
        paged_msgproto_guid_match_pairs: paged_counts.semantic.msgproto_guid_match_pairs,
        paged_msgproto_legacy_match_pairs: paged_counts.semantic.msgproto_legacy_match_pairs,
        paged_sender_participant_match_pairs: paged_counts.semantic.sender_participant_match_pairs,
        paged_sender_lah_match_pairs: paged_counts.semantic.sender_lah_match_pairs,
        paged_matched_route_extra_message_routes: paged_counts
            .semantic
            .matched_route_extra_mask
            .count_ones(),
        paged_matched_route_extra_chat1_records: paged_counts
            .semantic
            .matched_route_extra_chat1_records,
        paged_matched_msgproto_targets: paged_counts.semantic.matched_msgproto_mask.count_ones(),
        paged_matched_msgproto_chat1_records: paged_counts.semantic.matched_msgproto_chat1_records,
        paged_matched_sender_targets: paged_counts.semantic.matched_sender_mask.count_ones(),
        paged_matched_sender_chat1_records: paged_counts.semantic.matched_sender_chat1_records,
        paged_participant_present_records: paged_counts.semantic.participant_present_records,
        paged_legacy_present_records: paged_counts.semantic.legacy_present_records,
        paged_lah_present_records: paged_counts.semantic.lah_present_records,
        paged_service_present_records: paged_counts.semantic.service_present_records,
        paged_imessage_service_records: paged_counts.semantic.imessage_service_records,
        paged_other_service_records: paged_counts.semantic.other_service_records,
        paged_style_group_records: paged_counts.semantic.style_group_records,
        paged_style_direct_records: paged_counts.semantic.style_direct_records,
        paged_style_other_records: paged_counts.semantic.style_other_records,
        paged_normalized_chat_identifier_match_pairs: paged_counts
            .semantic
            .normalized_chat_identifier_match_pairs,
        paged_normalized_group_id_match_pairs: paged_counts
            .semantic
            .normalized_group_id_match_pairs,
        paged_normalized_original_group_id_match_pairs: paged_counts
            .semantic
            .normalized_original_group_id_match_pairs,
        paged_normalized_guid_match_pairs: paged_counts.semantic.normalized_guid_match_pairs,
        paged_normalized_semantic_match_pairs: paged_counts
            .semantic
            .normalized_semantic_match_pairs,
        paged_normalized_matched_message_routes: paged_counts
            .semantic
            .normalized_matched_message_route_mask
            .count_ones(),
        paged_normalized_matched_chat1_records: paged_counts
            .semantic
            .normalized_matched_chat1_records,
        paged_normalized_route_participant_match_pairs: paged_counts
            .semantic
            .normalized_route_participant_match_pairs,
        paged_normalized_route_legacy_match_pairs: paged_counts
            .semantic
            .normalized_route_legacy_match_pairs,
        paged_normalized_route_lah_match_pairs: paged_counts
            .semantic
            .normalized_route_lah_match_pairs,
        paged_normalized_msgproto_chat_identifier_match_pairs: paged_counts
            .semantic
            .normalized_msgproto_chat_identifier_match_pairs,
        paged_normalized_msgproto_group_id_match_pairs: paged_counts
            .semantic
            .normalized_msgproto_group_id_match_pairs,
        paged_normalized_msgproto_original_group_id_match_pairs: paged_counts
            .semantic
            .normalized_msgproto_original_group_id_match_pairs,
        paged_normalized_msgproto_guid_match_pairs: paged_counts
            .semantic
            .normalized_msgproto_guid_match_pairs,
        paged_normalized_msgproto_legacy_match_pairs: paged_counts
            .semantic
            .normalized_msgproto_legacy_match_pairs,
        paged_normalized_sender_participant_match_pairs: paged_counts
            .semantic
            .normalized_sender_participant_match_pairs,
        paged_normalized_sender_lah_match_pairs: paged_counts
            .semantic
            .normalized_sender_lah_match_pairs,
        paged_normalized_matched_route_extra_message_routes: paged_counts
            .semantic
            .normalized_matched_route_extra_mask
            .count_ones(),
        paged_normalized_matched_route_extra_chat1_records: paged_counts
            .semantic
            .normalized_matched_route_extra_chat1_records,
        paged_normalized_matched_msgproto_targets: paged_counts
            .semantic
            .normalized_matched_msgproto_mask
            .count_ones(),
        paged_normalized_matched_msgproto_chat1_records: paged_counts
            .semantic
            .normalized_matched_msgproto_chat1_records,
        paged_normalized_matched_sender_targets: paged_counts
            .semantic
            .normalized_matched_sender_mask
            .count_ones(),
        paged_normalized_matched_sender_chat1_records: paged_counts
            .semantic
            .normalized_matched_sender_chat1_records,
        paged_last_seen_message_guid_present_records: paged_counts
            .semantic
            .last_seen_message_guid_present_records,
        paged_last_seen_target_message_match_pairs: paged_counts
            .semantic
            .last_seen_target_message_match_pairs,
        paged_matched_last_seen_target_messages: paged_counts
            .semantic
            .matched_last_seen_target_message_mask
            .count_ones(),
        paged_matched_last_seen_target_chat1_records: paged_counts
            .semantic
            .matched_last_seen_target_chat1_records,
        paged_last_seen_anchor_exact_match_pairs: paged_counts
            .semantic
            .last_seen_anchor_exact_match_pairs,
        paged_matched_anchor_exact_targets: paged_counts
            .semantic
            .matched_anchor_exact_mask
            .count_ones(),
        paged_matched_anchor_exact_chat1_records: paged_counts
            .semantic
            .matched_anchor_exact_chat1_records,
        paged_last_seen_anchor_normalized_match_pairs: paged_counts
            .semantic
            .last_seen_anchor_normalized_match_pairs,
        paged_matched_anchor_normalized_targets: paged_counts
            .semantic
            .matched_anchor_normalized_mask
            .count_ones(),
        paged_matched_anchor_normalized_chat1_records: paged_counts
            .semantic
            .matched_anchor_normalized_chat1_records,
        paged_sender_service_style_match_pairs: paged_counts
            .semantic
            .sender_service_style_match_pairs,
        paged_matched_sender_service_style_targets: paged_counts
            .semantic
            .matched_sender_service_style_mask
            .count_ones(),
        paged_matched_sender_service_style_chat1_records: paged_counts
            .semantic
            .matched_sender_service_style_chat1_records,
        paged_sender_service_style_zero_candidate_targets: sender_service_style_cardinality.zero,
        paged_sender_service_style_unique_candidate_targets: sender_service_style_cardinality
            .unique,
        paged_sender_service_style_multiple_candidate_targets: sender_service_style_cardinality
            .multiple,
        paged_last_seen_target_zero_candidate_targets: last_seen_target_cardinality.zero,
        paged_last_seen_target_unique_candidate_targets: last_seen_target_cardinality.unique,
        paged_last_seen_target_multiple_candidate_targets: last_seen_target_cardinality.multiple,
        paged_anchor_exact_zero_candidate_targets: anchor_exact_cardinality.zero,
        paged_anchor_exact_unique_candidate_targets: anchor_exact_cardinality.unique,
        paged_anchor_exact_multiple_candidate_targets: anchor_exact_cardinality.multiple,
        paged_anchor_normalized_zero_candidate_targets: anchor_normalized_cardinality.zero,
        paged_anchor_normalized_unique_candidate_targets: anchor_normalized_cardinality.unique,
        paged_anchor_normalized_multiple_candidate_targets: anchor_normalized_cardinality.multiple,
        paged_terminal_reached: paged_counts.terminal_reached,
        paged_budget_exhausted: paged_counts.budget_exhausted,
        failure_code: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message as _;
    use rustpush::cloudkit_proto::{
        record::{field, Field, Type as RecordType},
        CloudKitEncryptedValue, CloudKitEncryptor as _, Identifier, RecordIdentifier,
        RecordZoneIdentifier,
    };
    use rustpush::pcs::PCSKey;

    fn record_field(name: &str, value: Value) -> Field {
        Field {
            identifier: Some(field::Identifier {
                name: Some(name.to_owned()),
            }),
            value: Some(value),
        }
    }

    fn oracle_record_id(record_name: &str) -> RecordIdentifier {
        RecordIdentifier {
            value: Some(Identifier {
                name: Some(record_name.to_owned()),
                ..Default::default()
            }),
            zone_identifier: Some(RecordZoneIdentifier {
                value: Some(Identifier {
                    name: Some("chat1ManateeZone".to_owned()),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn oracle_encryptor(record_name: &str) -> PCSEncryptor {
        PCSEncryptor {
            keys: vec![PCSKey::random()],
            record_id: oracle_record_id(record_name),
        }
    }

    fn oracle_chat() -> CloudChat {
        CloudChat {
            style: 43,
            successful_query: 1,
            state: 3,
            chat_identifier: "chat-user@example.invalid".to_owned(),
            group_id: "group-chat@example.invalid".to_owned(),
            original_group_id: "original-group@example.invalid".to_owned(),
            guid: "iMessage;-;chat-user@example.invalid".to_owned(),
            service_name: "iMessage".to_owned(),
            last_addressed_handle: "sender@example.invalid".to_owned(),
            last_read_message_timestamp: 0,
            is_filtered: 0,
            participants: vec![
                CloudParticipant {
                    uri: "member-a@example.invalid".to_owned(),
                },
                CloudParticipant {
                    uri: "member-b@example.invalid".to_owned(),
                },
            ],
            properties: Some(CloudProp {
                legacy_group_identifiers: vec!["legacy-group@example.invalid".to_owned()],
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn oracle_record(chat: &CloudChat, encryptor: &PCSEncryptor) -> Record {
        Record {
            record_identifier: Some(encryptor.record_id.clone()),
            r#type: Some(RecordType {
                name: Some(CloudChat::record_type().to_owned()),
            }),
            record_field: chat.to_record_encrypted(Some(encryptor)),
            ..Default::default()
        }
    }

    fn replace_record_field(record: &Record, name: &str, value: Value) -> Record {
        let mut out = record.clone();
        for field in &mut out.record_field {
            if field
                .identifier
                .as_ref()
                .and_then(|identifier| identifier.name.as_deref())
                == Some(name)
            {
                field.value = Some(value.clone());
            }
        }
        out
    }

    fn corrupt_field_ciphertext(record: &Record, name: &str) -> Record {
        let mut out = record.clone();
        for field in &mut out.record_field {
            if field
                .identifier
                .as_ref()
                .and_then(|identifier| identifier.name.as_deref())
                != Some(name)
            {
                continue;
            }
            let Some(value) = field.value.as_mut() else {
                continue;
            };
            if name == "ptcpts" {
                if let Some(entry) = value.list_values.first_mut() {
                    if let Some(bytes) = entry.bytes_value.as_mut() {
                        if let Some(last) = bytes.last_mut() {
                            *last ^= 0x01;
                        }
                    }
                }
            } else if let Some(bytes) = value.bytes_value.as_mut() {
                if let Some(last) = bytes.last_mut() {
                    *last ^= 0x01;
                }
            }
        }
        out
    }

    fn dummy_pcs_key() -> PCSEncryptor {
        PCSEncryptor {
            keys: Vec::new(),
            record_id: RecordIdentifier::default(),
        }
    }

    fn identified_record(name: &str, record_type: &str) -> Record {
        Record {
            record_identifier: Some(RecordIdentifier {
                value: Some(Identifier {
                    name: Some(name.to_owned()),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            r#type: Some(RecordType {
                name: Some(record_type.to_owned()),
            }),
            ..Default::default()
        }
    }

    fn verified_record(
        record_name: &str,
        record_type: &str,
        raw: Option<Vec<u8>>,
    ) -> VerifiedChat1Record {
        VerifiedChat1Record {
            record_id_hash: "R".repeat(43),
            record_name: record_name.to_owned(),
            record_type: record_type.to_owned(),
            raw,
        }
    }

    fn source(record: char, reference: char) -> CloudSyncChat1CorrelationSourceInput {
        CloudSyncChat1CorrelationSourceInput {
            change_id_hash: "C".repeat(43),
            record_id_hash: record.to_string().repeat(43),
            etag_hash: Some("E".repeat(43)),
            payload_sha256: "a".repeat(64),
            payload_length: Some(9),
            server_modified_at_millis: Some(11),
            protected_raw_envelope_reference: format!(
                "obcs2.ref.{}",
                reference.to_string().repeat(43)
            ),
        }
    }

    #[test]
    fn exact_match_counts_are_bounded_and_distinguish_routes_records_and_pairs() {
        let counts = exact_match_counts(
            &["A".into(), "B".into(), "B".into(), "D".into()],
            &["B".into(), "C".into(), "D".into()],
        );
        assert_eq!(
            counts,
            MatchCounts {
                distinct_message_routes: 3,
                exact_match_pairs: 3,
                matched_message_routes: 2,
                matched_chat1_records: 2,
            }
        );
    }

    #[test]
    fn semantic_route_masks_distinguish_pairs_routes_and_records() {
        let fields = RouteFieldMatches {
            chat_identifier: 0b0000_0001,
            group_id: 0b0000_0010,
            original_group_id: 0b0000_0001,
            guid: 0,
            normalized_chat_identifier: 0b0000_0100,
            normalized_group_id: 0b0000_1000,
            normalized_original_group_id: 0b0000_0100,
            normalized_guid: 0,
            ..Default::default()
        };
        assert_eq!(fields.pairs(), 3);
        assert_eq!(fields.combined(), 0b0000_0011);
        assert_eq!(fields.combined().count_ones(), 2);
        assert_eq!(fields.normalized_pairs(), 3);
        assert_eq!(fields.normalized_combined(), 0b0000_1100);
        let mut counts = SemanticMatchCounts::default();
        counts.observe(&fields);
        counts.observe(&RouteFieldMatches {
            chat_identifier: 0,
            group_id: 0b0000_0100,
            original_group_id: 0,
            guid: 0,
            normalized_guid: 0b0001_0000,
            ..Default::default()
        });
        assert_eq!(counts.decoded_route_records, 2);
        assert_eq!(counts.semantic_match_pairs, 4);
        assert_eq!(counts.matched_message_route_mask, 0b0000_0111);
        assert_eq!(counts.matched_chat1_records, 2);
        assert_eq!(counts.normalized_semantic_match_pairs, 4);
        assert_eq!(counts.normalized_matched_message_route_mask, 0b0001_1100);
        assert_eq!(counts.normalized_matched_chat1_records, 2);
    }

    #[test]
    fn selective_masks_compare_routes_to_participants_legacy_and_lah() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let route_targets = ["route-a", "route-b"]
            .iter()
            .map(|value| hasher.server_record_id_hash(value))
            .collect::<Vec<_>>();
        let normalized_targets = ["route-a", "route-b"]
            .iter()
            .map(|value| normalized_route_target(value, &hasher).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            multi_target_mask(&["route-a".to_owned()], &route_targets, &hasher),
            0b0000_0001
        );
        assert_eq!(
            multi_target_mask(
                &["route-a".to_owned(), "route-b".to_owned()],
                &route_targets,
                &hasher,
            ),
            0b0000_0011
        );
        assert_eq!(
            multi_target_mask(&["unrelated".to_owned()], &route_targets, &hasher),
            0
        );
        assert_eq!(
            multi_normalized_target_mask(
                &["mailto:route-a".to_owned()],
                &normalized_targets,
                &hasher,
            ),
            0b0000_0001
        );
        assert_eq!(target_mask(Some(""), &route_targets, &hasher), 0);
        assert_eq!(target_mask(None, &route_targets, &hasher), 0);
    }

    #[test]
    fn optional_masks_compare_msgproto_and_sender_targets_without_overlap() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let msgproto_targets = [
            Some(hasher.server_record_id_hash("group-a")),
            None,
            Some(hasher.server_record_id_hash("group-b")),
        ];
        assert_eq!(
            optional_target_mask(Some("group-a"), &msgproto_targets, &hasher),
            0b0000_0001
        );
        assert_eq!(
            optional_target_mask(Some("group-b"), &msgproto_targets, &hasher),
            0b0000_0100
        );
        assert_eq!(
            optional_target_mask(Some("group-c"), &msgproto_targets, &hasher),
            0
        );
        assert_eq!(optional_target_mask(None, &msgproto_targets, &hasher), 0);
        assert_eq!(
            optional_target_mask(Some(""), &msgproto_targets, &hasher),
            0
        );
        let sender_targets = [
            Some(hasher.server_record_id_hash("sender-a")),
            Some(hasher.server_record_id_hash("sender-b")),
        ];
        assert_eq!(
            multi_optional_target_mask(
                &["sender-a".to_owned(), "unrelated".to_owned()],
                &sender_targets,
                &hasher,
            ),
            0b0000_0001
        );
        assert_eq!(
            multi_optional_target_mask(&[] as &[String], &sender_targets, &hasher),
            0
        );
        let empty_targets: [Option<String>; 0] = [];
        assert_eq!(
            optional_target_mask(Some("group-a"), &empty_targets, &hasher),
            0
        );
    }

    #[test]
    fn normalized_optional_masks_fold_known_wrappers_for_selective_targets() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let targets = [
            Some(normalized_route_target("iMessage;-;User@Example.INVALID", &hasher).unwrap()),
            None,
        ];
        assert_eq!(
            normalized_optional_target_mask(Some("mailto:user@example.invalid"), &targets, &hasher,),
            0b0000_0001
        );
        assert_eq!(
            normalized_optional_target_mask(Some("future:user@example.invalid"), &targets, &hasher,),
            0
        );
        assert_eq!(normalized_optional_target_mask(None, &targets, &hasher), 0);
    }

    #[test]
    fn selective_observe_tracks_extra_sender_and_presence_aggregates() {
        let fields = RouteFieldMatches {
            route_participants: 0b0000_0001,
            route_legacy: 0b0000_0010,
            route_lah: 0,
            msgproto_chat_identifier: 0b0000_0001,
            msgproto_legacy: 0b0000_0100,
            sender_participants: 0b0000_0010,
            sender_lah: 0b0000_0001,
            normalized_route_participants: 0b0000_1000,
            normalized_msgproto_guid: 0b0001_0000,
            normalized_sender_lah: 0b0010_0000,
            has_participants: true,
            has_legacy: true,
            has_lah: false,
            has_service: true,
            style_group: true,
            ..Default::default()
        };
        assert_eq!(fields.route_extra_pairs(), 2);
        assert_eq!(fields.route_extra_combined(), 0b0000_0011);
        assert_eq!(fields.msgproto_pairs(), 2);
        assert_eq!(fields.sender_pairs(), 2);
        assert_eq!(fields.normalized_route_extra_pairs(), 1);
        let mut counts = SemanticMatchCounts::default();
        counts.observe(&fields);
        assert_eq!(counts.decoded_route_records, 1);
        assert_eq!(counts.route_participant_match_pairs, 1);
        assert_eq!(counts.route_legacy_match_pairs, 1);
        assert_eq!(counts.route_lah_match_pairs, 0);
        assert_eq!(counts.msgproto_chat_identifier_match_pairs, 1);
        assert_eq!(counts.msgproto_legacy_match_pairs, 1);
        assert_eq!(counts.sender_participant_match_pairs, 1);
        assert_eq!(counts.sender_lah_match_pairs, 1);
        assert_eq!(counts.matched_route_extra_mask, 0b0000_0011);
        assert_eq!(counts.matched_route_extra_chat1_records, 1);
        assert_eq!(counts.matched_msgproto_mask, 0b0000_0101);
        assert_eq!(counts.matched_msgproto_chat1_records, 1);
        // `lah` is diagnostic corroboration only; it must not admit an owner.
        assert_eq!(counts.matched_sender_mask, 0b0000_0010);
        assert_eq!(counts.matched_sender_chat1_records, 1);
        assert_eq!(counts.participant_present_records, 1);
        assert_eq!(counts.legacy_present_records, 1);
        assert_eq!(counts.lah_present_records, 0);
        assert_eq!(counts.service_present_records, 1);
        assert_eq!(counts.style_group_records, 1);
        assert_eq!(counts.style_direct_records, 0);
        assert_eq!(counts.style_other_records, 0);
        assert_eq!(counts.normalized_route_participant_match_pairs, 1);
        assert_eq!(counts.normalized_msgproto_guid_match_pairs, 1);
        assert_eq!(counts.normalized_sender_lah_match_pairs, 1);
        assert_eq!(counts.normalized_matched_route_extra_mask, 0b0000_1000);
        assert_eq!(counts.normalized_matched_msgproto_mask, 0b0001_0000);
        assert_eq!(counts.normalized_matched_sender_mask, 0);
    }

    #[test]
    fn masks_stay_within_eight_sources() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let targets = (0..8)
            .map(|index| hasher.server_record_id_hash(&format!("route-{index}")))
            .collect::<Vec<_>>();
        assert_eq!(target_mask(Some("route-7"), &targets, &hasher), 0b1000_0000);
        let optional_targets = targets.iter().cloned().map(Some).collect::<Vec<_>>();
        assert_eq!(
            optional_target_mask(Some("route-0"), &optional_targets, &hasher),
            0b0000_0001
        );
        assert_eq!(
            optional_target_mask(Some("route-7"), &optional_targets, &hasher),
            0b1000_0000
        );
    }

    #[test]
    fn source_masks_ignore_targets_beyond_the_eight_source_contract() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let targets = (0..9)
            .map(|index| hasher.server_record_id_hash(&format!("route-{index}")))
            .collect::<Vec<_>>();
        assert_eq!(target_mask(Some("route-8"), &targets, &hasher), 0);
        assert_eq!(
            multi_target_mask(
                &(0..8)
                    .map(|index| format!("route-{index}"))
                    .collect::<Vec<_>>(),
                &targets,
                &hasher,
            ),
            u8::MAX
        );
    }

    #[test]
    fn encrypted_scalar_fields_reject_duplicate_or_ambiguous_wire_shapes() {
        let key = dummy_pcs_key();
        let valid_outer_shape = Value {
            r#type: Some(FieldValueType::StringType as i32),
            bytes_value: Some(vec![1]),
            is_encrypted: Some(true),
            ..Default::default()
        };
        let duplicate = Record {
            record_field: vec![
                record_field("cid", valid_outer_shape.clone()),
                record_field("cid", valid_outer_shape.clone()),
            ],
            ..Default::default()
        };
        assert!(unique_field_value(&duplicate, "cid").is_err());
        assert!(encrypted_string_field(&duplicate, &key, "cid").is_err());

        for malformed in [
            Value {
                is_encrypted: None,
                ..valid_outer_shape.clone()
            },
            Value {
                is_encrypted: Some(false),
                ..valid_outer_shape.clone()
            },
            Value {
                r#type: Some(FieldValueType::Int64Type as i32),
                ..valid_outer_shape.clone()
            },
            Value {
                signed_value: Some(7),
                ..valid_outer_shape.clone()
            },
            Value {
                bytes_value: None,
                ..valid_outer_shape.clone()
            },
        ] {
            let record = Record {
                record_field: vec![record_field("cid", malformed)],
                ..Default::default()
            };
            assert!(encrypted_string_field(&record, &key, "cid").is_err());
        }

        let malformed_integer = Record {
            record_field: vec![record_field(
                "stl",
                Value {
                    r#type: Some(FieldValueType::Int64Type as i32),
                    bytes_value: Some(vec![1]),
                    is_encrypted: Some(true),
                    string_value: Some("unexpected".to_owned()),
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert!(encrypted_i64_field(&malformed_integer, &key, "stl").is_err());
    }

    #[test]
    fn route_field_failure_matrix_has_stable_unique_slots_and_exact_totals() {
        let fields = [
            Chat1RouteFailureField::RecordKey,
            Chat1RouteFailureField::Cid,
            Chat1RouteFailureField::Gid,
            Chat1RouteFailureField::Ogid,
            Chat1RouteFailureField::Guid,
            Chat1RouteFailureField::Lah,
            Chat1RouteFailureField::Svc,
            Chat1RouteFailureField::Stl,
            Chat1RouteFailureField::Ptcpts,
            Chat1RouteFailureField::Prop,
            Chat1RouteFailureField::CrossField,
        ];
        let kinds = [
            Chat1RouteFailureKind::MissingValue,
            Chat1RouteFailureKind::WireShape,
            Chat1RouteFailureKind::KeySelection,
            Chat1RouteFailureKind::CiphertextKey,
            Chat1RouteFailureKind::Decrypt,
            Chat1RouteFailureKind::PayloadDecode,
            Chat1RouteFailureKind::Validation,
            Chat1RouteFailureKind::Cap,
        ];
        assert_eq!(CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA, 2);
        assert_eq!(CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN, 88);
        assert_eq!(CHAT1_ROUTE_FAILURE_MATRIX_LEN, 105);
        let mut seen = [false; CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN];
        let mut counts = SemanticMatchCounts::default();
        for field in fields {
            for kind in kinds {
                let failure = Chat1RouteFieldFailure::new(field, kind);
                let index = failure.matrix_index();
                assert!(index < CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN);
                assert!(!seen[index]);
                seen[index] = true;
                counts.observe_route_field_failure(failure);
            }
        }
        assert!(seen.into_iter().all(|value| value));
        assert_eq!(
            counts.route_field_decode_failures as usize,
            CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN
        );
        assert_eq!(
            counts.route_field_failure_matrix[..CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN]
                .iter()
                .sum::<u32>(),
            counts.route_field_decode_failures
        );
        assert_eq!(
            counts.route_field_failure_matrix[CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN..]
                .iter()
                .sum::<u32>(),
            2
        );
        assert_eq!(
            counts.route_field_failure_matrix
                [CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN + Chat1RouteFailureDetail::LahOther as usize],
            1
        );
        assert_eq!(
            counts.route_field_failure_matrix[CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN
                + Chat1RouteFailureDetail::PtcptsOther as usize],
            1
        );
    }

    #[test]
    fn route_field_failure_details_partition_live_blockers_without_content() {
        let key = oracle_encryptor("detail-fixture.invalid");
        let lah_cases = [
            (None, Chat1RouteFailureDetail::LahStringValueAbsent),
            (Some(String::new()), Chat1RouteFailureDetail::LahEmpty),
            (
                Some("x".repeat(MAX_CHAT1_SELECTIVE_STRING_BYTES + 1)),
                Chat1RouteFailureDetail::LahTooLong,
            ),
            (
                Some(" padded ".to_owned()),
                Chat1RouteFailureDetail::LahTrimMismatch,
            ),
            (
                Some("control\nvalue".to_owned()),
                Chat1RouteFailureDetail::LahControl,
            ),
        ];
        let mut counts = SemanticMatchCounts::default();
        for (string_value, expected) in lah_cases {
            let plaintext = EncryptedValue {
                string_value,
                ..Default::default()
            }
            .encode_to_vec();
            let record = Record {
                record_field: vec![record_field(
                    "lah",
                    Value {
                        r#type: Some(FieldValueType::StringType as i32),
                        bytes_value: Some(key.encrypt_data(&plaintext, "lah")),
                        is_encrypted: Some(true),
                        ..Default::default()
                    },
                )],
                ..Default::default()
            };
            assert_eq!(classify_lah_validation_detail(&record, &key), expected);
            counts.observe_route_field_failure(Chat1RouteFieldFailure::with_detail(
                Chat1RouteFailureField::Lah,
                Chat1RouteFailureKind::Validation,
                expected,
            ));
        }

        let outer = |value: Value| Record {
            record_field: vec![record_field("ptcpts", value)],
            ..Default::default()
        };
        let list = |flag: Option<bool>, entries: Vec<Value>| Value {
            r#type: Some(FieldValueType::EncryptedBytesListType as i32),
            is_encrypted: flag,
            list_values: entries,
            ..Default::default()
        };
        let entry = |r#type: FieldValueType, flag: Option<bool>| Value {
            r#type: Some(r#type as i32),
            is_encrypted: flag,
            bytes_value: Some(vec![1]),
            ..Default::default()
        };
        let duplicate = Record {
            record_field: vec![
                record_field("ptcpts", list(Some(false), Vec::new())),
                record_field("ptcpts", list(Some(false), Vec::new())),
            ],
            ..Default::default()
        };
        let ptcpts_cases = vec![
            (duplicate, Chat1RouteFailureDetail::PtcptsDuplicate),
            (
                outer(Value {
                    r#type: Some(FieldValueType::EmptyList as i32),
                    ..Default::default()
                }),
                Chat1RouteFailureDetail::PtcptsOuterEmptyList,
            ),
            (
                outer(Value {
                    r#type: Some(FieldValueType::StringType as i32),
                    is_encrypted: Some(false),
                    ..Default::default()
                }),
                Chat1RouteFailureDetail::PtcptsOuterType,
            ),
            (
                outer(list(Some(true), Vec::new())),
                Chat1RouteFailureDetail::PtcptsOuterFlagTrue,
            ),
            (
                outer(Value {
                    string_value: Some("present".to_owned()),
                    ..list(Some(false), Vec::new())
                }),
                Chat1RouteFailureDetail::PtcptsOuterPayload,
            ),
            (
                outer(list(
                    Some(false),
                    vec![entry(FieldValueType::StringType, Some(true))],
                )),
                Chat1RouteFailureDetail::PtcptsEntryType,
            ),
            (
                outer(list(
                    Some(false),
                    vec![entry(FieldValueType::EncryptedBytesType, Some(false))],
                )),
                Chat1RouteFailureDetail::PtcptsEntryFlagFalse,
            ),
            (
                outer(list(
                    Some(false),
                    vec![Value {
                        string_value: Some("present".to_owned()),
                        ..entry(FieldValueType::EncryptedBytesType, Some(true))
                    }],
                )),
                Chat1RouteFailureDetail::PtcptsEntryPayload,
            ),
        ];
        assert_eq!(
            classify_ptcpts_wire_shape_detail(&outer(list(None, Vec::new()))),
            Chat1RouteFailureDetail::PtcptsOther,
            "an omitted outer flag is now a valid live wire shape"
        );
        assert_eq!(
            classify_ptcpts_wire_shape_detail(&outer(list(
                Some(false),
                vec![entry(FieldValueType::EncryptedBytesType, None)],
            ))),
            Chat1RouteFailureDetail::PtcptsOther,
            "an omitted entry flag is now a valid production-preflight shape"
        );
        for (record, expected) in &ptcpts_cases {
            assert_eq!(classify_ptcpts_wire_shape_detail(record), *expected);
            counts.observe_route_field_failure(Chat1RouteFieldFailure::with_detail(
                Chat1RouteFailureField::Ptcpts,
                Chat1RouteFailureKind::WireShape,
                *expected,
            ));
        }

        let lah_base_index = Chat1RouteFieldFailure::new(
            Chat1RouteFailureField::Lah,
            Chat1RouteFailureKind::Validation,
        )
        .matrix_index();
        let ptcpts_base_index = Chat1RouteFieldFailure::new(
            Chat1RouteFailureField::Ptcpts,
            Chat1RouteFailureKind::WireShape,
        )
        .matrix_index();
        assert_eq!(lah_base_index, 46);
        assert_eq!(ptcpts_base_index, 65);
        assert_eq!(counts.route_field_failure_matrix[lah_base_index], 5);
        assert_eq!(counts.route_field_failure_matrix[ptcpts_base_index], 8);
        assert_eq!(counts.route_field_decode_failures, 13);
        assert_eq!(
            counts.route_field_failure_matrix[..CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN]
                .iter()
                .sum::<u32>(),
            counts.route_field_decode_failures
        );
        assert_eq!(
            counts.route_field_failure_matrix[CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN..]
                .iter()
                .sum::<u32>(),
            counts.route_field_failure_matrix[lah_base_index]
                + counts.route_field_failure_matrix[ptcpts_base_index]
        );
        assert_eq!(
            counts.route_field_failure_matrix
                [CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN + Chat1RouteFailureDetail::LahOther as usize],
            0
        );
        assert_eq!(
            counts.route_field_failure_matrix[CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN
                + Chat1RouteFailureDetail::PtcptsOther as usize],
            0
        );

        let wire_shape_record = outer(list(Some(true), Vec::new()));
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let (
            targets,
            normalized_targets,
            msgproto_targets,
            normalized_msgproto_targets,
            sender_targets,
            normalized_sender_targets,
            message_guid_targets,
            message_route_kinds,
            anchor_index,
        ) = empty_inspect_context();
        let failure = match inspect_chat1_route_fields_with_key(
            &wire_shape_record,
            &key,
            &targets,
            &normalized_targets,
            &msgproto_targets,
            &normalized_msgproto_targets,
            &sender_targets,
            &normalized_sender_targets,
            &message_guid_targets,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        ) {
            Err(failure) => failure,
            Ok(_) => panic!("expected detailed ptcpts wire-shape failure"),
        };
        assert_eq!(
            failure,
            Chat1RouteFieldFailure::with_detail(
                Chat1RouteFailureField::Ptcpts,
                Chat1RouteFailureKind::WireShape,
                Chat1RouteFailureDetail::PtcptsOuterFlagTrue,
            )
        );
    }

    #[test]
    fn route_field_failures_classify_shape_missing_key_and_cap_without_content() {
        let key = dummy_pcs_key();
        let duplicate = Record {
            record_field: vec![
                record_field("cid", Value::default()),
                record_field("cid", Value::default()),
            ],
            ..Default::default()
        };
        assert_eq!(
            encrypted_string_field(&duplicate, &key, "cid"),
            Err(Chat1RouteFailureKind::WireShape)
        );

        let missing_value = Record {
            record_field: vec![Field {
                identifier: Some(field::Identifier {
                    name: Some("cid".to_owned()),
                }),
                value: None,
            }],
            ..Default::default()
        };
        assert_eq!(
            encrypted_string_field(&missing_value, &key, "cid"),
            Err(Chat1RouteFailureKind::MissingValue)
        );

        let well_shaped_but_unkeyed = Record {
            record_field: vec![record_field(
                "cid",
                Value {
                    r#type: Some(FieldValueType::StringType as i32),
                    bytes_value: Some(vec![1]),
                    is_encrypted: Some(true),
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert_eq!(
            encrypted_string_field(&well_shaped_but_unkeyed, &key, "cid"),
            Err(Chat1RouteFailureKind::CiphertextKey)
        );

        let oversized_participants = Record {
            record_field: vec![record_field(
                "ptcpts",
                Value {
                    r#type: Some(FieldValueType::EncryptedBytesListType as i32),
                    is_encrypted: Some(false),
                    list_values: vec![Value::default(); MAX_CHAT1_PARTICIPANTS + 1],
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert_eq!(
            encrypted_participant_uris(&oversized_participants, &key),
            Err(Chat1RouteFailureKind::Cap)
        );
    }

    #[test]
    fn participant_and_prop_shapes_enforce_caps_and_empty_list_contract() {
        let key = dummy_pcs_key();
        let oversized_participants = Record {
            record_field: vec![record_field(
                "ptcpts",
                Value {
                    r#type: Some(FieldValueType::EncryptedBytesListType as i32),
                    is_encrypted: Some(false),
                    list_values: vec![Value::default(); MAX_CHAT1_PARTICIPANTS + 1],
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert!(encrypted_participant_uris(&oversized_participants, &key).is_err());

        let malformed_entry = Record {
            record_field: vec![record_field(
                "ptcpts",
                Value {
                    r#type: Some(FieldValueType::EncryptedBytesListType as i32),
                    is_encrypted: Some(false),
                    list_values: vec![Value {
                        r#type: Some(FieldValueType::StringType as i32),
                        is_encrypted: Some(true),
                        bytes_value: Some(vec![1]),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert!(encrypted_participant_uris(&malformed_entry, &key).is_err());

        let empty_prop = Record {
            record_field: vec![record_field(
                "prop",
                Value {
                    r#type: Some(FieldValueType::EmptyList as i32),
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert_eq!(
            encrypted_legacy_identifiers(&empty_prop, &key),
            Ok(Vec::new())
        );

        let malformed_empty_prop = Record {
            record_field: vec![record_field(
                "prop",
                Value {
                    r#type: Some(FieldValueType::EmptyList as i32),
                    is_encrypted: Some(true),
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert!(encrypted_legacy_identifiers(&malformed_empty_prop, &key).is_err());
    }

    #[test]
    fn verified_chat1_wire_requires_exact_identity_and_type() {
        let record = identified_record("record-name", CloudChat::record_type());
        let raw = record.encode_to_vec();
        assert!(decode_verified_chat1_record(&verified_record(
            "record-name",
            CloudChat::record_type(),
            Some(raw.clone()),
        ))
        .is_ok());
        assert!(decode_verified_chat1_record(&verified_record(
            "different-name",
            CloudChat::record_type(),
            Some(raw.clone()),
        ))
        .is_err());
        assert!(decode_verified_chat1_record(&verified_record(
            "record-name",
            "different-type",
            Some(raw),
        ))
        .is_err());

        let missing_identity = Record {
            r#type: Some(RecordType {
                name: Some(CloudChat::record_type().to_owned()),
            }),
            ..Default::default()
        };
        assert!(decode_verified_chat1_record(&verified_record(
            "record-name",
            CloudChat::record_type(),
            Some(missing_identity.encode_to_vec()),
        ))
        .is_err());
    }

    #[test]
    fn malformed_verified_chat1_wire_is_rejected_without_panicking() {
        assert!(decode_verified_chat1_record(&verified_record(
            "record-name",
            CloudChat::record_type(),
            None,
        ))
        .is_err());
        assert!(decode_verified_chat1_record(&verified_record(
            "record-name",
            CloudChat::record_type(),
            Some(vec![0x3a, 0x80]),
        ))
        .is_err());
    }

    #[test]
    fn normalized_target_masks_fold_known_wrappers_without_guessing_future_schemes() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let targets = [
            normalized_route_target("iMessage;-;User@Example.INVALID", &hasher).unwrap(),
            normalized_route_target("iMessage;-;+15555550101", &hasher).unwrap(),
            normalized_route_target("iMessage;+;AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", &hasher)
                .unwrap(),
        ];
        assert_eq!(
            normalized_target_mask(Some("mailto:user@example.invalid"), &targets, &hasher),
            0b0000_0001
        );
        assert_eq!(
            normalized_target_mask(Some("TEL:+15555550101"), &targets, &hasher),
            0b0000_0010
        );
        assert_eq!(
            normalized_target_mask(
                Some("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                &targets,
                &hasher,
            ),
            0b0000_0100
        );
        assert_eq!(
            normalized_target_mask(Some("future:user@example.invalid"), &targets, &hasher),
            0
        );
    }

    #[test]
    fn source_validation_rejects_duplicates_malformed_values_and_unbounded_sets() {
        let first = source('R', 'P');
        assert!(valid_sources(std::slice::from_ref(&first), 1));
        assert!(!valid_sources(&[], 1));
        assert!(!valid_sources(&[first.clone(), first.clone()], 2));
        assert!(!valid_sources(&[first.clone(), source('S', 'P')], 2));
        assert!(!valid_sources(&[first.clone(), source('S', 'Q')], 1));
        for field in 0..5 {
            let mut invalid = first.clone();
            match field {
                0 => invalid.change_id_hash.clear(),
                1 => invalid.record_id_hash = "!".repeat(43),
                2 => invalid.etag_hash = Some("e".repeat(42)),
                3 => invalid.payload_sha256 = "A".repeat(64),
                _ => invalid.protected_raw_envelope_reference = "raw".into(),
            }
            assert!(!valid_source(&invalid));
        }
    }

    #[test]
    fn protected_store_identity_uses_the_protector_wire_grammar() {
        let digest = "A".repeat(43);
        assert!(is_protected_store_identity(&format!(
            "obcs2.store.{digest}"
        )));
        assert!(!is_protected_store_identity(&digest));
        assert!(!is_protected_store_identity(&format!("obcs2.ref.{digest}")));
        assert!(!is_protected_store_identity(&format!(
            "obcs2.store.{}",
            "A".repeat(42)
        )));
    }

    #[test]
    fn failure_result_never_contains_partial_observation() {
        let result = failure(CloudSyncChat1CorrelationFailureCode::Chat1SourceMismatch);
        assert!(!result.completed);
        assert_eq!(result.message_sources, 0);
        assert_eq!(result.decoded_message_routes, 0);
        assert_eq!(result.distinct_message_routes, 0);
        assert_eq!(result.chat1_sources, 0);
        assert_eq!(result.verified_chat1_records, 0);
        assert_eq!(result.exact_match_pairs, 0);
        assert_eq!(result.matched_message_routes, 0);
        assert_eq!(result.matched_chat1_records, 0);
        assert!(!result.semantic_correlation_requested);
        assert!(!result.pcs_lookup_attempted);
        assert_eq!(result.chat_record_type_records, 0);
        assert_eq!(result.other_record_type_records, 0);
        assert_eq!(result.decoded_route_records, 0);
        assert_eq!(result.record_decode_failures, 0);
        assert_eq!(result.route_field_decode_failures, 0);
        assert_eq!(
            result.route_field_failure_matrix_schema,
            CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA
        );
        assert_eq!(
            result.route_field_failure_matrix,
            vec![0; CHAT1_ROUTE_FAILURE_MATRIX_LEN]
        );
        assert_eq!(
            result.paged_route_field_failure_matrix,
            vec![0; CHAT1_ROUTE_FAILURE_MATRIX_LEN]
        );
        assert_eq!(result.chat_identifier_match_pairs, 0);
        assert_eq!(result.group_id_match_pairs, 0);
        assert_eq!(result.original_group_id_match_pairs, 0);
        assert_eq!(result.guid_match_pairs, 0);
        assert_eq!(result.semantic_match_pairs, 0);
        assert_eq!(result.matched_semantic_message_routes, 0);
        assert_eq!(result.matched_semantic_chat1_records, 0);
        assert_eq!(result.route_participant_match_pairs, 0);
        assert_eq!(result.route_legacy_match_pairs, 0);
        assert_eq!(result.route_lah_match_pairs, 0);
        assert_eq!(result.msgproto_chat_identifier_match_pairs, 0);
        assert_eq!(result.msgproto_legacy_match_pairs, 0);
        assert_eq!(result.sender_participant_match_pairs, 0);
        assert_eq!(result.sender_lah_match_pairs, 0);
        assert_eq!(result.matched_route_extra_message_routes, 0);
        assert_eq!(result.matched_msgproto_targets, 0);
        assert_eq!(result.matched_sender_targets, 0);
        assert_eq!(result.participant_present_records, 0);
        assert_eq!(result.service_present_records, 0);
        assert_eq!(result.style_group_records, 0);
        assert!(!result.paged_correlation_requested);
        assert_eq!(result.paged_pages_scanned, 0);
        assert_eq!(result.paged_changes_scanned, 0);
        assert_eq!(result.paged_semantic_match_pairs, 0);
        assert_eq!(result.paged_normalized_semantic_match_pairs, 0);
        assert_eq!(result.paged_normalized_matched_message_routes, 0);
        assert_eq!(result.paged_normalized_matched_chat1_records, 0);
        assert_eq!(result.paged_route_participant_match_pairs, 0);
        assert_eq!(result.paged_msgproto_legacy_match_pairs, 0);
        assert_eq!(result.paged_sender_lah_match_pairs, 0);
        assert_eq!(result.paged_matched_msgproto_targets, 0);
        assert_eq!(result.paged_normalized_route_participant_match_pairs, 0);
        assert_eq!(result.paged_normalized_msgproto_legacy_match_pairs, 0);
        assert_eq!(result.paged_normalized_sender_lah_match_pairs, 0);
        assert_eq!(result.paged_normalized_matched_msgproto_targets, 0);
        assert!(!result.paged_terminal_reached);
        assert!(!result.paged_budget_exhausted);
        assert_eq!(
            result.failure_code,
            Some(CloudSyncChat1CorrelationFailureCode::Chat1SourceMismatch)
        );
    }

    #[test]
    fn semantic_failure_never_contains_partial_observation() {
        let result = semantic_failure(CloudSyncChat1CorrelationFailureCode::Chat1PcsLookupFailed);
        assert!(!result.completed);
        assert!(result.semantic_correlation_requested);
        assert!(result.pcs_lookup_attempted);
        assert_eq!(result.semantic_match_pairs, 0);
        assert_eq!(result.matched_semantic_message_routes, 0);
        assert_eq!(result.matched_semantic_chat1_records, 0);
        assert_eq!(
            result.failure_code,
            Some(CloudSyncChat1CorrelationFailureCode::Chat1PcsLookupFailed)
        );
    }

    #[test]
    fn paged_failure_marks_the_explicit_lane_without_partial_observation() {
        let result =
            paged_semantic_failure(CloudSyncChat1CorrelationFailureCode::Chat1PagedFetchFailed);
        assert!(!result.completed);
        assert!(result.semantic_correlation_requested);
        assert!(result.pcs_lookup_attempted);
        assert!(result.paged_correlation_requested);
        assert_eq!(result.paged_pages_scanned, 0);
        assert_eq!(result.paged_changes_scanned, 0);
        assert_eq!(result.paged_semantic_match_pairs, 0);
        assert_eq!(result.paged_matched_message_routes, 0);
        assert_eq!(result.paged_matched_chat1_records, 0);
        assert_eq!(result.paged_normalized_chat_identifier_match_pairs, 0);
        assert_eq!(result.paged_normalized_group_id_match_pairs, 0);
        assert_eq!(result.paged_normalized_original_group_id_match_pairs, 0);
        assert_eq!(result.paged_normalized_guid_match_pairs, 0);
        assert_eq!(result.paged_normalized_semantic_match_pairs, 0);
        assert_eq!(result.paged_normalized_matched_message_routes, 0);
        assert_eq!(result.paged_normalized_matched_chat1_records, 0);
        assert_eq!(result.paged_normalized_route_participant_match_pairs, 0);
        assert_eq!(result.paged_normalized_msgproto_legacy_match_pairs, 0);
        assert_eq!(result.paged_normalized_sender_lah_match_pairs, 0);
        assert_eq!(
            result.paged_normalized_matched_route_extra_message_routes,
            0
        );
        assert_eq!(result.paged_normalized_matched_msgproto_targets, 0);
        assert_eq!(result.paged_normalized_matched_sender_targets, 0);
        assert!(!result.paged_terminal_reached);
        assert!(!result.paged_budget_exhausted);
        assert_eq!(
            result.failure_code,
            Some(CloudSyncChat1CorrelationFailureCode::Chat1PagedFetchFailed)
        );
    }

    #[test]
    fn encrypted_chat1_route_oracle_matches_all_supported_fields() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let record_name = "oracle-record.invalid";
        let encryptor = oracle_encryptor(record_name);
        let chat = oracle_chat();
        let record = oracle_record(&chat, &encryptor);
        let route_values = [
            chat.chat_identifier.clone(),
            chat.group_id.clone(),
            chat.original_group_id.clone(),
            chat.guid.clone(),
            "member-a@example.invalid".to_owned(),
            "member-b@example.invalid".to_owned(),
            "legacy-group@example.invalid".to_owned(),
            chat.last_addressed_handle.clone(),
        ];
        let targets = route_values
            .iter()
            .map(|value| hasher.server_record_id_hash(value))
            .collect::<Vec<_>>();
        let normalized_targets = route_values
            .iter()
            .map(|value| normalized_route_target(value, &hasher).unwrap())
            .collect::<Vec<_>>();
        let msgproto_targets = [
            Some(hasher.server_record_id_hash(&chat.chat_identifier)),
            Some(hasher.server_record_id_hash("legacy-group@example.invalid")),
            None,
        ];
        let normalized_msgproto_targets = [
            Some(normalized_route_target(&chat.chat_identifier, &hasher).unwrap()),
            Some(normalized_route_target("legacy-group@example.invalid", &hasher).unwrap()),
            None,
        ];
        let sender_targets = [
            Some(hasher.server_record_id_hash("member-a@example.invalid")),
            Some(hasher.server_record_id_hash(&chat.last_addressed_handle)),
        ];
        let normalized_sender_targets = [
            Some(normalized_route_target("member-a@example.invalid", &hasher).unwrap()),
            Some(normalized_route_target(&chat.last_addressed_handle, &hasher).unwrap()),
        ];
        let message_guid_targets = vec![String::new(); targets.len()];
        let message_route_kinds = vec![MessageRouteKind::Bare; targets.len()];
        let anchor_index = MessageAnchorIndex::default();
        let fields = inspect_chat1_route_fields_with_key(
            &record,
            &encryptor,
            &targets,
            &normalized_targets,
            &msgproto_targets,
            &normalized_msgproto_targets,
            &sender_targets,
            &normalized_sender_targets,
            &message_guid_targets,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        )
        .expect("ephemeral oracle record must decode");
        assert_ne!(fields.chat_identifier, 0);
        assert_ne!(fields.group_id, 0);
        assert_ne!(fields.original_group_id, 0);
        assert_ne!(fields.guid, 0);
        assert_eq!(fields.route_participants.count_ones(), 2);
        assert_ne!(fields.route_legacy, 0);
        assert_ne!(fields.route_lah, 0);
        assert_ne!(fields.msgproto_chat_identifier, 0);
        assert_ne!(fields.msgproto_legacy, 0);
        assert_ne!(fields.sender_participants, 0);
        assert_ne!(fields.sender_lah, 0);
        assert_ne!(fields.normalized_chat_identifier, 0);
        assert_ne!(fields.normalized_route_participants, 0);
        assert_ne!(fields.normalized_route_legacy, 0);
        assert!(fields.has_participants);
        assert!(fields.has_legacy);
        assert!(fields.has_lah);
        assert!(fields.has_service);
        assert!(fields.service_imessage);
        assert!(!fields.service_other);
        assert!(fields.style_group);
        assert!(!fields.style_direct);
        assert!(!fields.style_other);
    }

    #[test]
    fn message_anchor_index_rejects_ambiguous_guid_routes() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let guid = "p:0/anchor-message.invalid";
        let direct = "iMessage;-;member-a@example.invalid";
        let group = "iMessage;+;group-chat@example.invalid";
        let mut index = MessageAnchorIndex::default();

        index
            .observe_decoded_source(guid, direct, &hasher)
            .expect("first anchor must be accepted");
        index
            .observe_decoded_source(guid, direct, &hasher)
            .expect("an identical duplicate must remain unambiguous");
        assert_eq!(index.decoded_sources, 2);
        assert_eq!(index.routes_by_guid_hash.len(), 1);
        assert!(index.conflicting_guid_hashes.is_empty());

        index
            .observe_decoded_source(guid, group, &hasher)
            .expect("a conflicting source is observed but cannot be used");
        assert_eq!(index.decoded_sources, 3);
        assert!(index.routes_by_guid_hash.is_empty());
        assert_eq!(index.conflicting_guid_hashes.len(), 1);

        index
            .observe_decoded_source(guid, direct, &hasher)
            .expect("later duplicates cannot revive a conflicting GUID");
        assert_eq!(index.decoded_sources, 4);
        assert!(index.routes_by_guid_hash.is_empty());
        assert!(index.observe_decoded_source("", direct, &hasher).is_err());
        assert_eq!(index.decoded_sources, 4);
    }

    #[test]
    fn message_route_kind_accepts_supported_current_routes_only() {
        assert_eq!(
            message_route_kind("iMessage;-;member@example.invalid"),
            Ok(MessageRouteKind::Direct)
        );
        assert_eq!(
            message_route_kind("SMS;+;group.invalid"),
            Ok(MessageRouteKind::Group)
        );
        assert_eq!(
            message_route_kind("opaque-bare-route"),
            Ok(MessageRouteKind::Bare)
        );
        assert_eq!(message_route_kind("RCS;-;member@example.invalid"), Err(()));
        assert_eq!(
            message_route_kind("iMessage;?;member@example.invalid"),
            Err(())
        );
    }

    #[test]
    fn last_seen_anchor_and_service_style_filters_are_selective() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let record_name = "oracle-anchor.invalid";
        let encryptor = oracle_encryptor(record_name);
        let last_seen_guid = "p:0/anchor-message.invalid";
        let target_route = "iMessage;+;group-chat@example.invalid";
        let mut chat = oracle_chat();
        chat.properties
            .as_mut()
            .expect("oracle properties")
            .last_seen_message_guid = Some(last_seen_guid.to_owned());
        let targets = vec![hasher.server_record_id_hash(target_route)];
        let normalized_targets = vec![normalized_route_target(target_route, &hasher).unwrap()];
        let message_guid_targets = vec![hasher.server_record_id_hash(last_seen_guid)];
        let message_route_kinds = vec![MessageRouteKind::Group];
        let sender_targets = vec![Some(
            hasher.server_record_id_hash("member-a@example.invalid"),
        )];
        let normalized_sender_targets = vec![Some(
            normalized_route_target("member-a@example.invalid", &hasher).unwrap(),
        )];
        let empty_optional = vec![None];
        let empty_normalized_optional = vec![None];
        let mut anchor_index = MessageAnchorIndex::default();
        anchor_index
            .observe_decoded_source(last_seen_guid, target_route, &hasher)
            .expect("anchor fixture must be valid");

        let inspect = |chat: &CloudChat| {
            let record = oracle_record(chat, &encryptor);
            inspect_chat1_route_fields_with_key(
                &record,
                &encryptor,
                &targets,
                &normalized_targets,
                &empty_optional,
                &empty_normalized_optional,
                &sender_targets,
                &normalized_sender_targets,
                &message_guid_targets,
                &message_route_kinds,
                &anchor_index,
                &hasher,
            )
            .expect("anchor oracle must decode")
        };

        let fields = inspect(&chat);
        assert!(fields.has_last_seen_message_guid);
        assert_eq!(fields.last_seen_target_message, 1);
        assert_eq!(fields.last_seen_anchor_exact, 1);
        assert_eq!(fields.last_seen_anchor_normalized, 1);
        assert_eq!(fields.sender_service_style, 1);

        let mut wrong_style = chat.clone();
        wrong_style.style = 45;
        let fields = inspect(&wrong_style);
        assert_eq!(fields.last_seen_target_message, 0);
        assert_eq!(fields.last_seen_anchor_exact, 0);
        assert_eq!(fields.last_seen_anchor_normalized, 0);
        assert_eq!(fields.sender_service_style, 0);

        let mut sms_route = chat.clone();
        sms_route.service_name = "SMS".to_owned();
        let fields = inspect(&sms_route);
        assert_eq!(fields.last_seen_target_message, 1);
        assert_eq!(fields.last_seen_anchor_exact, 1);
        assert_eq!(fields.last_seen_anchor_normalized, 1);
        assert_eq!(fields.sender_service_style, 1);

        let mut wrong_service = chat;
        wrong_service.service_name = "RCS".to_owned();
        let fields = inspect(&wrong_service);
        assert_eq!(fields.last_seen_target_message, 0);
        assert_eq!(fields.last_seen_anchor_exact, 0);
        assert_eq!(fields.last_seen_anchor_normalized, 0);
        assert_eq!(fields.sender_service_style, 0);
    }

    #[test]
    fn candidate_cardinality_reports_zero_unique_and_multiple_per_target() {
        let mut counts = SemanticMatchCounts::default();
        counts.sender_service_style_candidate_counts = vec![0, 1, 2, 3, 1, 0, 7, 1];
        let cardinality = SemanticMatchCounts::candidate_cardinality(
            &counts.sender_service_style_candidate_counts,
        );
        assert_eq!(cardinality.zero, 2);
        assert_eq!(cardinality.unique, 3);
        assert_eq!(cardinality.multiple, 3);
    }

    #[test]
    fn encrypted_chat1_route_oracle_table_covers_key_decrypt_validation() {
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let record_name = "oracle-failure.invalid";
        let encryptor = oracle_encryptor(record_name);
        let bad_encryptor = PCSEncryptor {
            keys: vec![PCSKey::random()],
            record_id: oracle_record_id(record_name),
        };
        let chat = oracle_chat();
        let base = oracle_record(&chat, &encryptor);
        let empty_targets: Vec<String> = Vec::new();
        let empty_normalized: Vec<NormalizedRouteTarget> = Vec::new();
        let empty_optional: Vec<Option<String>> = Vec::new();
        let empty_normalized_optional: Vec<Option<NormalizedRouteTarget>> = Vec::new();
        let empty_route_kinds: Vec<MessageRouteKind> = Vec::new();
        let empty_anchor_index = MessageAnchorIndex::default();
        let check = |record: &Record, key: &PCSEncryptor| match inspect_chat1_route_fields_with_key(
            record,
            key,
            &empty_targets,
            &empty_normalized,
            &empty_optional,
            &empty_normalized_optional,
            &empty_optional,
            &empty_normalized_optional,
            &empty_targets,
            &empty_route_kinds,
            &empty_anchor_index,
            &hasher,
        ) {
            Err(failure) => failure,
            Ok(_) => panic!("expected route-field failure"),
        };
        let scalar_cases: [(&str, Chat1RouteFailureField, String); 6] = [
            (
                "cid",
                Chat1RouteFailureField::Cid,
                chat.chat_identifier.clone(),
            ),
            ("gid", Chat1RouteFailureField::Gid, chat.group_id.clone()),
            (
                "ogid",
                Chat1RouteFailureField::Ogid,
                chat.original_group_id.clone(),
            ),
            ("guid", Chat1RouteFailureField::Guid, chat.guid.clone()),
            (
                "lah",
                Chat1RouteFailureField::Lah,
                chat.last_addressed_handle.clone(),
            ),
            (
                "svc",
                Chat1RouteFailureField::Svc,
                chat.service_name.clone(),
            ),
        ];
        let mut cases = 0u32;
        for (name, field, value) in scalar_cases {
            let bad_value = value
                .to_value_encrypted(&bad_encryptor, name)
                .expect("bad-key value must encode");
            let mutated = replace_record_field(&base, name, bad_value);
            assert_eq!(
                check(&mutated, &encryptor),
                Chat1RouteFieldFailure::new(field, Chat1RouteFailureKind::CiphertextKey),
                "key mismatch for {name}"
            );
            cases += 1;
            let wrong_aad = if name == "cid" { "gid" } else { "cid" };
            let aad_value = value
                .to_value_encrypted(&encryptor, wrong_aad)
                .expect("wrong-aad value must encode");
            let mutated = replace_record_field(&base, name, aad_value);
            assert_eq!(
                check(&mutated, &encryptor),
                Chat1RouteFieldFailure::new(field, Chat1RouteFailureKind::Decrypt),
                "aad mismatch for {name}"
            );
            cases += 1;
            let invalid_value = "   "
                .to_owned()
                .to_value_encrypted(&encryptor, name)
                .expect("invalid value must encode");
            let mutated = replace_record_field(&base, name, invalid_value);
            let expected = if field == Chat1RouteFailureField::Lah {
                Chat1RouteFieldFailure::with_detail(
                    field,
                    Chat1RouteFailureKind::Validation,
                    Chat1RouteFailureDetail::LahTrimMismatch,
                )
            } else {
                Chat1RouteFieldFailure::new(field, Chat1RouteFailureKind::Validation)
            };
            assert_eq!(
                check(&mutated, &encryptor),
                expected,
                "validation for {name}"
            );
            cases += 1;
        }
        let bad_style = 43i64
            .to_value_encrypted(&bad_encryptor, "stl")
            .expect("bad-key style must encode");
        assert_eq!(
            check(&replace_record_field(&base, "stl", bad_style), &encryptor),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Stl,
                Chat1RouteFailureKind::CiphertextKey
            ),
            "key mismatch for stl"
        );
        cases += 1;
        let aad_style = 43i64
            .to_value_encrypted(&encryptor, "cid")
            .expect("wrong-aad style must encode");
        assert_eq!(
            check(&replace_record_field(&base, "stl", aad_style), &encryptor),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Stl,
                Chat1RouteFailureKind::Decrypt
            ),
            "aad mismatch for stl"
        );
        cases += 1;
        let empty_payload = EncryptedValue {
            ..Default::default()
        }
        .encode_to_vec();
        let empty_ciphertext = encryptor.encrypt_data(&empty_payload, "stl");
        let empty_style = Value {
            r#type: Some(FieldValueType::Int64Type as i32),
            bytes_value: Some(empty_ciphertext),
            is_encrypted: Some(true),
            ..Default::default()
        };
        assert_eq!(
            check(&replace_record_field(&base, "stl", empty_style), &encryptor),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Stl,
                Chat1RouteFailureKind::MissingValue
            ),
            "empty payload for stl"
        );
        cases += 1;
        let bad_participants = vec![
            CloudParticipant {
                uri: "member-a@example.invalid".to_owned(),
            },
            CloudParticipant {
                uri: "member-b@example.invalid".to_owned(),
            },
        ]
        .to_value_encrypted(&bad_encryptor, "ptcpts")
        .expect("bad-key participants must encode");
        assert_eq!(
            check(
                &replace_record_field(&base, "ptcpts", bad_participants),
                &encryptor
            ),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Ptcpts,
                Chat1RouteFailureKind::CiphertextKey
            ),
            "key mismatch for ptcpts"
        );
        cases += 1;
        let aad_participants = vec![
            CloudParticipant {
                uri: "member-a@example.invalid".to_owned(),
            },
            CloudParticipant {
                uri: "member-b@example.invalid".to_owned(),
            },
        ]
        .to_value_encrypted(&encryptor, "cid")
        .expect("wrong-aad participants must encode");
        assert_eq!(
            check(
                &replace_record_field(&base, "ptcpts", aad_participants),
                &encryptor
            ),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Ptcpts,
                Chat1RouteFailureKind::Decrypt
            ),
            "aad mismatch for ptcpts"
        );
        cases += 1;
        let invalid_participants = vec![CloudParticipant {
            uri: "not-a-participant.invalid".to_owned(),
        }]
        .to_value_encrypted(&encryptor, "ptcpts")
        .expect("invalid participants must encode");
        assert_eq!(
            check(
                &replace_record_field(&base, "ptcpts", invalid_participants),
                &encryptor
            ),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Ptcpts,
                Chat1RouteFailureKind::Validation
            ),
            "validation for ptcpts"
        );
        cases += 1;
        let bad_prop = CloudProp {
            legacy_group_identifiers: vec!["legacy-group@example.invalid".to_owned()],
            ..Default::default()
        }
        .to_value_encrypted(&bad_encryptor, "prop")
        .expect("bad-key prop must encode");
        assert_eq!(
            check(&replace_record_field(&base, "prop", bad_prop), &encryptor),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Prop,
                Chat1RouteFailureKind::CiphertextKey
            ),
            "key mismatch for prop"
        );
        cases += 1;
        let aad_prop = CloudProp {
            legacy_group_identifiers: vec!["legacy-group@example.invalid".to_owned()],
            ..Default::default()
        }
        .to_value_encrypted(&encryptor, "cid")
        .expect("wrong-aad prop must encode");
        assert_eq!(
            check(&replace_record_field(&base, "prop", aad_prop), &encryptor),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Prop,
                Chat1RouteFailureKind::Decrypt
            ),
            "aad mismatch for prop"
        );
        cases += 1;
        let invalid_prop = CloudProp {
            legacy_group_identifiers: vec!["   ".to_owned()],
            ..Default::default()
        }
        .to_value_encrypted(&encryptor, "prop")
        .expect("invalid prop must encode");
        assert_eq!(
            check(
                &replace_record_field(&base, "prop", invalid_prop),
                &encryptor
            ),
            Chat1RouteFieldFailure::new(
                Chat1RouteFailureField::Prop,
                Chat1RouteFailureKind::Validation
            ),
            "validation for prop"
        );
        cases += 1;
        for name in ["cid", "stl", "ptcpts", "prop"] {
            let (field, kind) = match name {
                "cid" => (Chat1RouteFailureField::Cid, Chat1RouteFailureKind::Decrypt),
                "stl" => (Chat1RouteFailureField::Stl, Chat1RouteFailureKind::Decrypt),
                "ptcpts" => (
                    Chat1RouteFailureField::Ptcpts,
                    Chat1RouteFailureKind::Decrypt,
                ),
                _ => (Chat1RouteFailureField::Prop, Chat1RouteFailureKind::Decrypt),
            };
            let mutated = corrupt_field_ciphertext(&base, name);
            assert_eq!(
                check(&mutated, &encryptor),
                Chat1RouteFieldFailure::new(field, kind),
                "tampered ciphertext for {name}"
            );
            cases += 1;
        }
        assert_eq!(cases, 31, "table must run all deterministic oracle cases");
    }

    fn remove_record_field(record: &Record, name: &str) -> Record {
        let mut out = record.clone();
        out.record_field.retain(|field| {
            field
                .identifier
                .as_ref()
                .and_then(|identifier| identifier.name.as_deref())
                != Some(name)
        });
        out
    }

    fn empty_inspect_context() -> (
        Vec<String>,
        Vec<NormalizedRouteTarget>,
        Vec<Option<String>>,
        Vec<Option<NormalizedRouteTarget>>,
        Vec<Option<String>>,
        Vec<Option<NormalizedRouteTarget>>,
        Vec<String>,
        Vec<MessageRouteKind>,
        MessageAnchorIndex,
    ) {
        (
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            MessageAnchorIndex::default(),
        )
    }

    #[test]
    fn missing_scalar_route_fields_freeze_absent_ok_contract() {
        // Fixture semantics: CloudChat declares cid/gid/ogid/guid/lah/svc as
        // required (non-Option) strings, so the oracle encoder always emits
        // them. Whether Apple ever omits them on the wire is unproved here.
        // This test only freezes the current decoder contract: absence is
        // Ok(None), never MissingValue, and inspection stays Ok.
        let record_name = "absence-scalar.invalid";
        let encryptor = oracle_encryptor(record_name);
        let chat = oracle_chat();
        let base = oracle_record(&chat, &encryptor);
        for name in ["cid", "gid", "ogid", "guid", "lah", "svc"] {
            let missing = remove_record_field(&base, name);
            assert_eq!(
                encrypted_string_field(&missing, &encryptor, name),
                Ok(None),
                "missing scalar {name} currently decodes to absent, not failure"
            );
        }
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let missing_cid = remove_record_field(&base, "cid");
        let (
            targets,
            normalized_targets,
            msgproto_targets,
            normalized_msgproto_targets,
            sender_targets,
            normalized_sender_targets,
            message_guid_targets,
            message_route_kinds,
            anchor_index,
        ) = empty_inspect_context();
        let fields = inspect_chat1_route_fields_with_key(
            &missing_cid,
            &encryptor,
            &targets,
            &normalized_targets,
            &msgproto_targets,
            &normalized_msgproto_targets,
            &sender_targets,
            &normalized_sender_targets,
            &message_guid_targets,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        )
        .expect("missing cid currently inspects Ok");
        assert_eq!(fields.chat_identifier, 0);
    }

    #[test]
    fn missing_stl_freezes_absent_ok_contract() {
        // Fixture semantics: style (stl) is a required i64 on CloudChat, so the
        // oracle always emits it. Apple wire optionality is unproved; freeze
        // only the current Ok(None) contract.
        let record_name = "absence-stl.invalid";
        let encryptor = oracle_encryptor(record_name);
        let chat = oracle_chat();
        let base = oracle_record(&chat, &encryptor);
        let missing = remove_record_field(&base, "stl");
        assert_eq!(
            encrypted_i64_field(&missing, &encryptor, "stl"),
            Ok(None),
            "missing stl currently decodes to absent, not failure"
        );
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let (
            targets,
            normalized_targets,
            msgproto_targets,
            normalized_msgproto_targets,
            sender_targets,
            normalized_sender_targets,
            message_guid_targets,
            message_route_kinds,
            anchor_index,
        ) = empty_inspect_context();
        let fields = inspect_chat1_route_fields_with_key(
            &missing,
            &encryptor,
            &targets,
            &normalized_targets,
            &msgproto_targets,
            &normalized_msgproto_targets,
            &sender_targets,
            &normalized_sender_targets,
            &message_guid_targets,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        )
        .expect("missing stl currently inspects Ok");
        assert!(!fields.style_group);
        assert!(!fields.style_direct);
        assert!(!fields.style_other);
    }

    #[test]
    fn missing_ptcpts_freezes_empty_ok_contract() {
        // Fixture semantics: participants is Vec (can be empty), so an absent
        // ptcpts field is plausibly legitimate. Freeze the current Ok(empty)
        // contract without endorsing it for other fields.
        let record_name = "absence-ptcpts.invalid";
        let encryptor = oracle_encryptor(record_name);
        let chat = oracle_chat();
        let base = oracle_record(&chat, &encryptor);
        let missing = remove_record_field(&base, "ptcpts");
        assert_eq!(
            encrypted_participant_uris(&missing, &encryptor),
            Ok(Vec::new()),
            "missing ptcpts currently decodes to empty, not failure"
        );
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let (
            targets,
            normalized_targets,
            msgproto_targets,
            normalized_msgproto_targets,
            sender_targets,
            normalized_sender_targets,
            message_guid_targets,
            message_route_kinds,
            anchor_index,
        ) = empty_inspect_context();
        let fields = inspect_chat1_route_fields_with_key(
            &missing,
            &encryptor,
            &targets,
            &normalized_targets,
            &msgproto_targets,
            &normalized_msgproto_targets,
            &sender_targets,
            &normalized_sender_targets,
            &message_guid_targets,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        )
        .expect("missing ptcpts currently inspects Ok");
        assert!(!fields.has_participants);
    }

    #[test]
    fn missing_prop_freezes_empty_ok_contract() {
        // Fixture semantics: properties is Option<CloudProp>, so an absent
        // prop field is plausibly legitimate. Freeze the current Ok(empty)
        // contract without endorsing it for scalar fields.
        let record_name = "absence-prop.invalid";
        let encryptor = oracle_encryptor(record_name);
        let chat = oracle_chat();
        let base = oracle_record(&chat, &encryptor);
        let missing = remove_record_field(&base, "prop");
        assert_eq!(
            encrypted_legacy_identifiers(&missing, &encryptor),
            Ok(Vec::new()),
            "missing prop currently decodes to empty, not failure"
        );
        let hasher = CloudSemanticIdentifierHasher::new(b"fixture-key").unwrap();
        let (
            targets,
            normalized_targets,
            msgproto_targets,
            normalized_msgproto_targets,
            sender_targets,
            normalized_sender_targets,
            message_guid_targets,
            message_route_kinds,
            anchor_index,
        ) = empty_inspect_context();
        let fields = inspect_chat1_route_fields_with_key(
            &missing,
            &encryptor,
            &targets,
            &normalized_targets,
            &msgproto_targets,
            &normalized_msgproto_targets,
            &sender_targets,
            &normalized_sender_targets,
            &message_guid_targets,
            &message_route_kinds,
            &anchor_index,
            &hasher,
        )
        .expect("missing prop currently inspects Ok");
        assert!(!fields.has_legacy);
    }

    #[test]
    fn zero_length_decrypted_prop_freezes_empty_ok_contract() {
        // Current production code maps an empty prop plaintext to Ok(empty),
        // unlike empty ptcpts/stl plaintext which is MissingValue. Freeze that
        // asymmetry without changing it.
        let record_name = "zero-prop.invalid";
        let encryptor = oracle_encryptor(record_name);
        let empty_ciphertext = encryptor.encrypt_data(&[], "prop");
        let record = Record {
            record_field: vec![record_field(
                "prop",
                Value {
                    r#type: Some(FieldValueType::EncryptedBytesType as i32),
                    bytes_value: Some(empty_ciphertext),
                    is_encrypted: Some(true),
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert_eq!(
            encrypted_legacy_identifiers(&record, &encryptor),
            Ok(Vec::new()),
            "zero-length decrypted prop currently decodes to empty"
        );
    }

    #[test]
    fn prop_empty_list_flag_freezes_none_and_false_ok_contract() {
        // Current production code rejects only is_encrypted == Some(true) for
        // EmptyList prop, so None and Some(false) are both Ok(empty). Freeze
        // that boundary; the None-accepted case is the inconsistency to decide
        // later (ptcpts outer requires explicit Some(false)).
        let key = dummy_pcs_key();
        for flag in [None, Some(false)] {
            let record = Record {
                record_field: vec![record_field(
                    "prop",
                    Value {
                        r#type: Some(FieldValueType::EmptyList as i32),
                        is_encrypted: flag,
                        ..Default::default()
                    },
                )],
                ..Default::default()
            };
            assert_eq!(
                encrypted_legacy_identifiers(&record, &key),
                Ok(Vec::new()),
                "EmptyList prop with flag {flag:?} currently decodes to empty"
            );
        }
        let rejected = Record {
            record_field: vec![record_field(
                "prop",
                Value {
                    r#type: Some(FieldValueType::EmptyList as i32),
                    is_encrypted: Some(true),
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        assert_eq!(
            encrypted_legacy_identifiers(&rejected, &key),
            Err(Chat1RouteFailureKind::WireShape),
            "EmptyList prop with Some(true) stays WireShape"
        );
    }

    #[test]
    fn ptcpts_outer_flag_matches_live_optional_encryption_contract() {
        // Production preflight rejects only Some(true), and the terminal live
        // Chat1 walk observed the omitted outer flag on 147 of 165 records.
        let key = dummy_pcs_key();
        let build = |flag: Option<bool>| Record {
            record_field: vec![record_field(
                "ptcpts",
                Value {
                    r#type: Some(FieldValueType::EncryptedBytesListType as i32),
                    is_encrypted: flag,
                    list_values: Vec::new(),
                    ..Default::default()
                },
            )],
            ..Default::default()
        };
        for flag in [None, Some(false)] {
            assert_eq!(
                encrypted_participant_uris(&build(flag), &key),
                Ok(Vec::new()),
                "ptcpts outer flag {flag:?} is valid for an empty list"
            );
        }
        assert_eq!(
            encrypted_participant_uris(&build(Some(true)), &key),
            Err(Chat1RouteFailureKind::WireShape),
            "ptcpts outer flag Some(true) stays WireShape"
        );
    }

    #[test]
    fn ptcpts_entry_flag_matches_production_preflight_contract() {
        let encryptor = oracle_encryptor("ptcpts-entry-flag.invalid");
        let encoded = vec![CloudParticipant {
            uri: "member@example.invalid".to_owned(),
        }]
        .to_value_encrypted(&encryptor, "ptcpts")
        .expect("participant fixture must encode");

        for flag in [None, Some(true)] {
            let mut value = encoded.clone();
            value.is_encrypted = Some(false);
            value.list_values[0].is_encrypted = flag;
            let record = Record {
                record_field: vec![record_field("ptcpts", value)],
                ..Default::default()
            };
            assert_eq!(
                encrypted_participant_uris(&record, &encryptor),
                Ok(vec!["member@example.invalid".to_owned()]),
                "ptcpts entry flag {flag:?} is accepted after full decryption and validation"
            );
        }

        let mut rejected = encoded;
        rejected.is_encrypted = Some(false);
        rejected.list_values[0].is_encrypted = Some(false);
        let record = Record {
            record_field: vec![record_field("ptcpts", rejected)],
            ..Default::default()
        };
        assert_eq!(
            encrypted_participant_uris(&record, &encryptor),
            Err(Chat1RouteFailureKind::WireShape)
        );
    }

    #[test]
    fn encrypted_empty_lah_is_absent_without_weakening_other_strings() {
        let encryptor = oracle_encryptor("empty-lah.invalid");
        let empty_lah = String::new()
            .to_value_encrypted(&encryptor, "lah")
            .expect("empty lah fixture must encode");
        let record =
            replace_record_field(&oracle_record(&oracle_chat(), &encryptor), "lah", empty_lah);

        assert_eq!(
            encrypted_string_field(&record, &encryptor, "lah"),
            Err(Chat1RouteFailureKind::Validation),
            "generic encrypted strings remain strict"
        );
        assert_eq!(
            encrypted_last_addressed_handle(&record, &encryptor),
            Ok(None),
            "empty lah is diagnostic absence"
        );

        let empty_cid = String::new()
            .to_value_encrypted(&encryptor, "cid")
            .expect("empty cid fixture must encode");
        let empty_cid_record = replace_record_field(&record, "cid", empty_cid);
        assert_eq!(
            encrypted_string_field(&empty_cid_record, &encryptor, "cid"),
            Err(Chat1RouteFailureKind::Validation),
            "cid must not inherit the lah exception"
        );

        assert_eq!(
            encrypted_last_addressed_handle(&oracle_record(&oracle_chat(), &encryptor), &encryptor,),
            Ok(Some("sender@example.invalid".to_owned()))
        );
    }

    #[test]
    fn standalone_live_path_refreshes_read_authentication_before_writer_pause() {
        let source = include_str!("cloud_sync_chat1_correlation.rs");
        let test_start = source
            .rfind("async fn current_rust_correlates_exported_chat1_inputs_read_only()")
            .expect("standalone live test");
        let body = &source[test_start..];
        let refresh = body
            .find("api::cloud_sync_ensure_read_authentication")
            .expect("explicit read-authentication refresh");
        let pause = body
            .find("api::cloud_sync_pause_password_cloudkit_writers")
            .expect("writer pause");
        let warm = body
            .find("api::cloud_sync_warm_read_authentication_under_writer_pause")
            .expect("container warmup");

        assert!(refresh < pause && pause < warm);
    }
}

#[cfg(all(test, target_os = "windows"))]
mod windows_standalone_live_tests {
    use super::*;
    use crate::api::api;
    use serde::Deserialize;
    use std::{fs, path::PathBuf};

    const LIVE_ENABLE: &str = "OPENBUBBLES_RUN_CHAT1_STANDALONE_LIVE";
    const MANIFEST_RELATIVE_PATH: &[&str] = &[
        "cloud-sync-v2",
        "diagnostics",
        "chat1-correlation-input-v1.json",
    ];

    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct LiveManifestSource {
        change_id_hash: String,
        record_id_hash: String,
        etag_hash: Option<String>,
        payload_sha256: String,
        payload_length: Option<u64>,
        server_modified_at_millis: Option<i64>,
        protected_raw_envelope_reference: String,
    }

    impl From<LiveManifestSource> for CloudSyncChat1CorrelationSourceInput {
        fn from(value: LiveManifestSource) -> Self {
            Self {
                change_id_hash: value.change_id_hash,
                record_id_hash: value.record_id_hash,
                etag_hash: value.etag_hash,
                payload_sha256: value.payload_sha256,
                payload_length: value.payload_length,
                server_modified_at_millis: value.server_modified_at_millis,
                protected_raw_envelope_reference: value.protected_raw_envelope_reference,
            }
        }
    }

    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct LiveManifest {
        schema: u32,
        content_exposed: bool,
        account_fingerprint: String,
        protected_store_identity: String,
        message_generation: u64,
        message_sources: Vec<LiveManifestSource>,
        anchor_message_sources: Vec<LiveManifestSource>,
        chat1_generation: u64,
        chat1_sources: Vec<LiveManifestSource>,
    }

    fn required_live_environment() {
        for name in [
            LIVE_ENABLE,
            "OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST",
            "OPENBUBBLES_INSPECT_CHAT1_CORRELATION",
            "OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION",
            "OPENBUBBLES_INSPECT_CHAT1_PAGED_CORRELATION",
        ] {
            assert_eq!(
                std::env::var(name).as_deref(),
                Ok("1"),
                "chat1_standalone_live_enable_required"
            );
        }
        for name in [
            "OPENBUBBLES_CLOUD_SYNC_V2_OUTBOUND_CANARY",
            "OPENBUBBLES_CLOUDKIT_WRITER_OWNER",
            "OPENBUBBLES_CLOUD_SYNC_V2_WINDOWS_REPLAY_EXCLUDED_CHATS",
            "OPENBUBBLES_VERIFY_EDIT_CLAIM",
            "OPENBUBBLES_VERIFY_CHAIN_UNSEND",
        ] {
            assert!(
                std::env::var_os(name).is_none(),
                "chat1_standalone_writer_environment_rejected"
            );
        }
    }

    fn live_profile() -> PathBuf {
        let mut profile =
            PathBuf::from(std::env::var_os("APPDATA").expect("chat1_standalone_appdata_required"));
        profile.push("OpenBubbles");
        profile.push("cloudkit-v2-dev");
        let marker = fs::read_to_string(profile.join(".openbubbles-cloud-sync-v2-windows-dev"))
            .expect("chat1_standalone_profile_marker_required");
        assert_eq!(
            marker, "openbubbles-cloud-sync-v2-windows-dev-profile:v1",
            "chat1_standalone_profile_marker_rejected"
        );
        profile
    }

    fn read_manifest(profile: &PathBuf) -> LiveManifest {
        let mut path = profile.clone();
        for part in MANIFEST_RELATIVE_PATH {
            path.push(part);
        }
        let metadata = fs::metadata(&path).expect("chat1_standalone_manifest_required");
        assert!(
            metadata.is_file() && metadata.len() <= 4 * 1024 * 1024,
            "chat1_standalone_manifest_rejected"
        );
        let bytes = fs::read(path).expect("chat1_standalone_manifest_read_failed");
        serde_json::from_slice(&bytes).expect("chat1_standalone_manifest_decode_failed")
    }

    fn read_authentication_failure_marker(error: &anyhow::Error) -> &'static str {
        match error.to_string().as_str() {
            "cloud_sync_native_auth_refresh_writer_busy" => {
                "chat1_standalone_read_authentication_refresh_writer_busy"
            }
            "cloud_sync_native_auth_refresh_session_missing" => {
                "chat1_standalone_read_authentication_refresh_session_missing"
            }
            "cloud_sync_native_auth_refresh_relay_unavailable" => {
                "chat1_standalone_read_authentication_refresh_relay_unavailable"
            }
            "cloud_sync_native_auth_refresh_credentials_rejected" => {
                "chat1_standalone_read_authentication_refresh_credentials_rejected"
            }
            "cloud_sync_native_auth_refresh_transport_failed" => {
                "chat1_standalone_read_authentication_refresh_transport_failed"
            }
            "cloud_sync_native_auth_refresh_state_failed" => {
                "chat1_standalone_read_authentication_refresh_state_failed"
            }
            "cloud_sync_native_auth_refresh_timeout" => {
                "chat1_standalone_read_authentication_refresh_timeout"
            }
            "cloud_sync_native_auth_refresh_failed" => {
                "chat1_standalone_read_authentication_refresh_failed"
            }
            "cloud_sync_native_auth_account_changed" => {
                "chat1_standalone_read_authentication_account_changed"
            }
            "cloud_sync_native_auth_identity_mismatch" => {
                "chat1_standalone_read_authentication_identity_mismatch"
            }
            _ => "chat1_standalone_read_authentication_refresh_unclassified",
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    #[ignore = "requires the explicit isolated Windows profile and live Apple services"]
    async fn current_rust_correlates_exported_chat1_inputs_read_only() {
        required_live_environment();
        let profile = live_profile();
        let manifest = read_manifest(&profile);
        assert_eq!(manifest.schema, 1, "chat1_standalone_manifest_schema");
        assert!(
            !manifest.content_exposed,
            "chat1_standalone_content_rejected"
        );
        assert!(
            is_bare_digest(&manifest.account_fingerprint)
                && is_protected_store_identity(&manifest.protected_store_identity),
            "chat1_standalone_manifest_identity_rejected"
        );

        let message_sources = manifest
            .message_sources
            .into_iter()
            .map(Into::into)
            .collect::<Vec<_>>();
        let anchor_message_sources = manifest
            .anchor_message_sources
            .into_iter()
            .map(Into::into)
            .collect::<Vec<_>>();
        let chat1_sources = manifest
            .chat1_sources
            .into_iter()
            .map(Into::into)
            .collect::<Vec<_>>();
        assert!(
            manifest.message_generation > 0
                && manifest.chat1_generation > 0
                && message_sources.len() == MAX_MESSAGE_SOURCES
                && (MAX_MESSAGE_SOURCES..=MAX_ANCHOR_MESSAGE_SOURCES)
                    .contains(&anchor_message_sources.len())
                && chat1_sources.len() == MAX_CHAT1_SOURCES
                && valid_sources(&message_sources, MAX_MESSAGE_SOURCES)
                && valid_sources(&anchor_message_sources, MAX_ANCHOR_MESSAGE_SOURCES)
                && valid_sources(&chat1_sources, MAX_CHAT1_SOURCES),
            "chat1_standalone_manifest_sources_rejected"
        );

        let profile_string = profile.to_string_lossy().into_owned();
        api::do_first_time_init(profile_string.clone());
        let hardware = api::read_hardware(profile_string.clone())
            .expect("chat1_standalone_hardware_restore_failed");
        let identity = api::decode_identity(&hardware.identity)
            .expect("chat1_standalone_identity_restore_failed");
        let config = hardware.os_config.clone();
        let (connection, push_error) = api::setup_push(
            &config,
            &identity,
            Some(hardware.push.clone()),
            profile_string.clone(),
        )
        .await;
        assert!(push_error.is_none(), "chat1_standalone_aps_setup_failed");
        let anisette = api::make_anisette(profile_string.clone(), &config, &connection).await;
        let account = api::restore_account(profile_string.clone(), &anisette, &config, &connection)
            .await
            .expect("chat1_standalone_account_restore_failed");
        let token_provider = api::make_token_provider(&account, &config);
        let cloudkit =
            api::make_cloudkit(profile_string.clone(), &anisette, &config, &token_provider)
                .await
                .expect("chat1_standalone_cloudkit_restore_failed");
        let keychain = api::make_keychain(
            profile_string.clone(),
            &cloudkit,
            &anisette,
            &config,
            &token_provider,
        )
        .expect("chat1_standalone_keychain_restore_failed");
        let client = api::make_cloud_messages_client(&cloudkit, &keychain);

        if let Err(error) =
            api::cloud_sync_ensure_read_authentication(&client, profile_string.clone()).await
        {
            panic!("{}", read_authentication_failure_marker(&error));
        }

        let mut pause_token = rand::random::<u64>();
        if pause_token == 0 {
            pause_token = 1;
        }
        let acquired = api::cloud_sync_pause_password_cloudkit_writers(pause_token)
            .await
            .expect("chat1_standalone_writer_pause_failed");
        assert_eq!(
            acquired, pause_token,
            "chat1_standalone_writer_pause_mismatch"
        );
        let warm =
            api::cloud_sync_warm_read_authentication_under_writer_pause(&client, pause_token).await;
        let result = if warm.is_ok() {
            Some(
                cloud_sync_inspect_chat1_record_name_correlation_under_writer_pause(
                    &client,
                    pause_token,
                    profile_string,
                    manifest.account_fingerprint,
                    manifest.protected_store_identity,
                    manifest.message_generation,
                    message_sources,
                    anchor_message_sources,
                    manifest.chat1_generation,
                    chat1_sources,
                )
                .await,
            )
        } else {
            None
        };
        api::cloud_sync_resume_password_cloudkit_writers(pause_token)
            .await
            .expect("chat1_standalone_writer_resume_failed");
        assert!(warm.is_ok(), "chat1_standalone_read_authentication_failed");
        let result = result.expect("chat1_standalone_result_missing");

        let report = serde_json::json!({
            "completed": result.completed,
            "failure_code": result.failure_code.map(|value| format!("{value:?}")),
            "message_sources": result.message_sources,
            "decoded_message_routes": result.decoded_message_routes,
            "anchor_message_sources": result.anchor_message_sources,
            "decoded_anchor_messages": result.decoded_anchor_messages,
            "skipped_anchor_messages": result.skipped_anchor_messages,
            "distinct_anchor_message_guids": result.distinct_anchor_message_guids,
            "conflicting_anchor_message_guids": result.conflicting_anchor_message_guids,
            "paged_pages_scanned": result.paged_pages_scanned,
            "paged_changes_scanned": result.paged_changes_scanned,
            "paged_chat_records": result.paged_chat_records,
            "paged_record_decode_failures": result.paged_record_decode_failures,
            "paged_route_field_decode_failures": result.paged_route_field_decode_failures,
            "paged_route_field_failure_matrix": result.paged_route_field_failure_matrix,
            "paged_semantic_match_pairs": result.paged_semantic_match_pairs,
            "paged_normalized_semantic_match_pairs": result.paged_normalized_semantic_match_pairs,
            "paged_matched_message_routes": result.paged_matched_message_routes,
            "paged_normalized_matched_message_routes": result.paged_normalized_matched_message_routes,
            "paged_last_seen_target_message_match_pairs": result.paged_last_seen_target_message_match_pairs,
            "paged_last_seen_anchor_exact_match_pairs": result.paged_last_seen_anchor_exact_match_pairs,
            "paged_last_seen_anchor_normalized_match_pairs": result.paged_last_seen_anchor_normalized_match_pairs,
            "paged_sender_service_style_match_pairs": result.paged_sender_service_style_match_pairs,
            "paged_sender_service_style_zero_candidate_targets": result.paged_sender_service_style_zero_candidate_targets,
            "paged_sender_service_style_unique_candidate_targets": result.paged_sender_service_style_unique_candidate_targets,
            "paged_sender_service_style_multiple_candidate_targets": result.paged_sender_service_style_multiple_candidate_targets,
            "paged_last_seen_target_zero_candidate_targets": result.paged_last_seen_target_zero_candidate_targets,
            "paged_last_seen_target_unique_candidate_targets": result.paged_last_seen_target_unique_candidate_targets,
            "paged_last_seen_target_multiple_candidate_targets": result.paged_last_seen_target_multiple_candidate_targets,
            "paged_anchor_exact_zero_candidate_targets": result.paged_anchor_exact_zero_candidate_targets,
            "paged_anchor_exact_unique_candidate_targets": result.paged_anchor_exact_unique_candidate_targets,
            "paged_anchor_exact_multiple_candidate_targets": result.paged_anchor_exact_multiple_candidate_targets,
            "paged_anchor_normalized_zero_candidate_targets": result.paged_anchor_normalized_zero_candidate_targets,
            "paged_anchor_normalized_unique_candidate_targets": result.paged_anchor_normalized_unique_candidate_targets,
            "paged_anchor_normalized_multiple_candidate_targets": result.paged_anchor_normalized_multiple_candidate_targets,
            "paged_terminal_reached": result.paged_terminal_reached,
            "paged_budget_exhausted": result.paged_budget_exhausted,
        });
        println!("OPENBUBBLES_CHAT1_STANDALONE_AGGREGATE={report}");
        assert!(result.completed, "chat1_standalone_correlation_failed");
        assert!(
            result.failure_code.is_none(),
            "chat1_standalone_correlation_failed"
        );
    }
}
