//! Test-host-only correlation between unresolved Message chat routes and
//! protected Chat1 records. Clear identifiers and raw envelopes never cross
//! Flutter Rust Bridge. The optional PCS path is lookup-only; its separately
//! gated paged lane can perform bounded in-memory reads but cannot persist a
//! cursor, project, admit, or write.

use std::{
    collections::HashSet,
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
        Record,
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
const MAX_CHAT1_SOURCES: usize = 50;
const MAX_CHAT1_ROUTE_FIELD_BYTES: usize = 64 * 1024;
const MAX_CHAT1_SCAN_PAGES: usize = 20;
const MAX_CHAT1_CHANGES_PER_PAGE: u32 = 50;
const MAX_CHAT1_PARTICIPANTS: usize = 32;
const MAX_CHAT1_LEGACY_IDENTIFIERS: usize = 32;
const MAX_CHAT1_SELECTIVE_STRING_BYTES: usize = 4096;
const MAX_CHAT1_PROP_BYTES: usize = 16 * 1024;
const MAX_CHAT1_PARTICIPANT_PLAINTEXT_BYTES: usize = 4 * 1024;
const CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA: u32 = 1;
const CHAT1_ROUTE_FAILURE_FIELD_COUNT: usize = 11;
const CHAT1_ROUTE_FAILURE_KIND_COUNT: usize = 8;
const CHAT1_ROUTE_FAILURE_MATRIX_LEN: usize =
    CHAT1_ROUTE_FAILURE_FIELD_COUNT * CHAT1_ROUTE_FAILURE_KIND_COUNT;

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Chat1RouteFieldFailure {
    field: Chat1RouteFailureField,
    kind: Chat1RouteFailureKind,
}

impl Chat1RouteFieldFailure {
    const fn new(field: Chat1RouteFailureField, kind: Chat1RouteFailureKind) -> Self {
        Self { field, kind }
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
    /// payload_decode, validation and cap.
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
    identifier(&decoded).ok_or(Chat1RouteFailureKind::Validation)?;
    Ok(Some(decoded))
}

fn unique_field_value(
    record: &Record,
    name: &str,
) -> Result<Option<Value>, Chat1RouteFailureKind> {
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
        || value.is_encrypted != Some(false)
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
            || entry.is_encrypted != Some(true)
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

fn encrypted_legacy_identifiers(
    record: &Record,
    key: &PCSEncryptor,
) -> Result<Vec<String>, Chat1RouteFailureKind> {
    let Some(value) = unique_field_value(record, "prop")? else {
        return Ok(Vec::new());
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
        return Ok(Vec::new());
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
        return Ok(Vec::new());
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
    Ok(properties.legacy_group_identifiers)
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
    has_participants: bool,
    has_legacy: bool,
    has_lah: bool,
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
    let map_failure = |field: Chat1RouteFailureField| {
        move |kind: Chat1RouteFailureKind| Chat1RouteFieldFailure::new(field, kind)
    };
    let chat_identifier = encrypted_string_field(record, &record_key, "cid")
        .map_err(map_failure(Chat1RouteFailureField::Cid))?;
    let group_id = encrypted_string_field(record, &record_key, "gid")
        .map_err(map_failure(Chat1RouteFailureField::Gid))?;
    let original_group_id = encrypted_string_field(record, &record_key, "ogid")
        .map_err(map_failure(Chat1RouteFailureField::Ogid))?;
    let guid = encrypted_string_field(record, &record_key, "guid")
        .map_err(map_failure(Chat1RouteFailureField::Guid))?;
    let last_addressed_handle = encrypted_string_field(record, &record_key, "lah")
        .map_err(map_failure(Chat1RouteFailureField::Lah))?;
    let service_name = encrypted_string_field(record, &record_key, "svc")
        .map_err(map_failure(Chat1RouteFailureField::Svc))?;
    let style = encrypted_i64_field(record, &record_key, "stl")
        .map_err(map_failure(Chat1RouteFailureField::Stl))?;
    let participants = encrypted_participant_uris(record, &record_key)
        .map_err(map_failure(Chat1RouteFailureField::Ptcpts))?;
    let legacy_identifiers = encrypted_legacy_identifiers(record, &record_key)
        .map_err(map_failure(Chat1RouteFailureField::Prop))?;
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
        route_legacy: multi_target_mask(&legacy_identifiers, targets, hasher),
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
        msgproto_legacy: multi_optional_target_mask(&legacy_identifiers, msgproto_targets, hasher),
        sender_participants: multi_optional_target_mask(&participants, sender_targets, hasher),
        sender_lah: optional_target_mask(last_addressed_handle.as_deref(), sender_targets, hasher),
        normalized_route_participants: multi_normalized_target_mask(
            &participants,
            normalized_targets,
            hasher,
        ),
        normalized_route_legacy: multi_normalized_target_mask(
            &legacy_identifiers,
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
            &legacy_identifiers,
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
        has_participants: !participants.is_empty(),
        has_legacy: !legacy_identifiers.is_empty(),
        has_lah: last_addressed_handle
            .as_deref()
            .is_some_and(|value| !value.is_empty()),
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
    }

    fn route_field_failure_matrix_snapshot(&self) -> Vec<u32> {
        let mut snapshot = self.route_field_failure_matrix.clone();
        snapshot.resize(CHAT1_ROUTE_FAILURE_MATRIX_LEN, 0);
        snapshot.truncate(CHAT1_ROUTE_FAILURE_MATRIX_LEN);
        snapshot
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
    }
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
/// participant URIs plus prop legacy identifiers). Neither path persists a
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
        || message_generation == 0
        || chat1_generation == 0
        || !valid_sources(&message_sources, MAX_MESSAGE_SOURCES)
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
        let (route, msgproto_group_id, sender_handle) = match mutation.payload() {
            Some(CloudCanonicalPayload::Message(payload)) => (
                payload.chat_identifier().to_owned(),
                payload.msg_proto_4_group_id().map(str::to_owned),
                payload.sender_handle().to_owned(),
            ),
            _ => return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed),
        };
        if identifier(&route).is_none() {
            return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed);
        }
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
        paged_terminal_reached: paged_counts.terminal_reached,
        paged_budget_exhausted: paged_counts.budget_exhausted,
        failure_code: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustpush::cloudkit_proto::{
        record::{field, Field, Type as RecordType},
        Identifier, RecordIdentifier,
    };

    fn record_field(name: &str, value: Value) -> Field {
        Field {
            identifier: Some(field::Identifier {
                name: Some(name.to_owned()),
            }),
            value: Some(value),
        }
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
        let mut seen = [false; CHAT1_ROUTE_FAILURE_MATRIX_LEN];
        let mut counts = SemanticMatchCounts::default();
        for field in fields {
            for kind in kinds {
                let failure = Chat1RouteFieldFailure::new(field, kind);
                let index = failure.matrix_index();
                assert!(index < CHAT1_ROUTE_FAILURE_MATRIX_LEN);
                assert!(!seen[index]);
                seen[index] = true;
                counts.observe_route_field_failure(failure);
            }
        }
        assert!(seen.into_iter().all(|value| value));
        assert_eq!(
            counts.route_field_decode_failures as usize,
            CHAT1_ROUTE_FAILURE_MATRIX_LEN
        );
        assert_eq!(
            counts.route_field_failure_matrix.iter().sum::<u32>(),
            counts.route_field_decode_failures
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
}
