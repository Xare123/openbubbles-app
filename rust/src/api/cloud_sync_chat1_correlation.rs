//! Test-host-only correlation between unresolved Message chat routes and
//! protected Chat1 records. Clear identifiers and raw envelopes never cross
//! Flutter Rust Bridge. The optional PCS path is lookup-only and this module
//! cannot fetch record pages, project, admit, or write.

use std::{
    collections::HashSet,
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::Arc,
};

use flutter_rust_bridge::frb;
use prost::Message as _;
use rustpush::{
    cloud_messages::{CloudChat, CloudMessagesClient, MESSAGES_SERVICE},
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
    AccountChanged,
}

/// Aggregate-only result. A match means byte-exact equality between a decoded
/// Message chat route and a verified Chat1 record name; it does not authorize
/// Chat admission or prove deletion/absence when zero.
#[derive(Debug)]
pub struct CloudSyncChat1CorrelationResult {
    pub completed: bool,
    pub message_sources: u32,
    pub decoded_message_routes: u32,
    pub distinct_message_routes: u32,
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
    pub chat_identifier_match_pairs: u32,
    pub group_id_match_pairs: u32,
    pub original_group_id_match_pairs: u32,
    pub guid_match_pairs: u32,
    pub semantic_match_pairs: u32,
    pub matched_semantic_message_routes: u32,
    pub matched_semantic_chat1_records: u32,
    pub failure_code: Option<CloudSyncChat1CorrelationFailureCode>,
}

fn failure(code: CloudSyncChat1CorrelationFailureCode) -> CloudSyncChat1CorrelationResult {
    CloudSyncChat1CorrelationResult {
        completed: false,
        message_sources: 0,
        decoded_message_routes: 0,
        distinct_message_routes: 0,
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
        chat_identifier_match_pairs: 0,
        group_id_match_pairs: 0,
        original_group_id_match_pairs: 0,
        guid_match_pairs: 0,
        semantic_match_pairs: 0,
        matched_semantic_message_routes: 0,
        matched_semantic_chat1_records: 0,
        failure_code: Some(code),
    }
}

fn semantic_failure(code: CloudSyncChat1CorrelationFailureCode) -> CloudSyncChat1CorrelationResult {
    let mut result = failure(code);
    result.semantic_correlation_requested = true;
    result.pcs_lookup_attempted = true;
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
    Ok(VerifiedChat1Record {
        record_id_hash,
        record_name: record_name.to_owned(),
        record_type: record_type.to_owned(),
        raw: retain_raw.then(|| envelope.raw().expect("raw checked above").to_vec()),
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
    let record = Record::decode(raw).map_err(|_| ())?;
    if record_identifier_name(&record).is_some_and(|value| value != source.record_name)
        || record_type_name(&record).is_some_and(|value| value != source.record_type)
    {
        return Err(());
    }
    Ok(record)
}

fn encrypted_string_field(
    record: &Record,
    key: &PCSEncryptor,
    name: &str,
) -> Result<Option<String>, ()> {
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
        return Err(());
    }
    let value: &Value = field.value.as_ref().ok_or(())?;
    if value.r#type != Some(FieldValueType::StringType as i32)
        || value.is_encrypted == Some(false)
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
        return Err(());
    }
    let ciphertext = value
        .bytes_value
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or(())?;
    key.validate_ciphertext_key(ciphertext).map_err(|_| ())?;
    let plaintext = key.decrypt_data_checked(ciphertext, name).map_err(|_| ())?;
    if plaintext.len() > MAX_CHAT1_ROUTE_FIELD_BYTES {
        return Err(());
    }
    let decoded = EncryptedValue::decode(plaintext.as_slice()).map_err(|_| ())?;
    if decoded.signed_value.is_some() || decoded.date_value.is_some() {
        return Err(());
    }
    Ok(decoded.string_value)
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
                mask | (1u8 << index)
            } else {
                mask
            }
        })
}

#[frb(ignore)]
#[derive(Default)]
struct RouteFieldMatches {
    chat_identifier: u8,
    group_id: u8,
    original_group_id: u8,
    guid: u8,
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
}

fn inspect_chat1_route_fields(
    record: &Record,
    zone_key: &rustpush::cloudkit::PCSZoneConfig,
    targets: &[String],
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<RouteFieldMatches, ()> {
    let record_key = match catch_unwind(AssertUnwindSafe(|| pcs_keys_for_record(record, zone_key)))
    {
        Ok(Ok(value)) => value,
        _ => return Err(()),
    };
    let chat_identifier = encrypted_string_field(record, &record_key, "cid")?;
    let group_id = encrypted_string_field(record, &record_key, "gid")?;
    let original_group_id = encrypted_string_field(record, &record_key, "ogid")?;
    let guid = encrypted_string_field(record, &record_key, "guid")?;
    Ok(RouteFieldMatches {
        chat_identifier: target_mask(chat_identifier.as_deref(), targets, hasher),
        group_id: target_mask(group_id.as_deref(), targets, hasher),
        original_group_id: target_mask(original_group_id.as_deref(), targets, hasher),
        guid: target_mask(guid.as_deref(), targets, hasher),
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
    chat_identifier_match_pairs: u32,
    group_id_match_pairs: u32,
    original_group_id_match_pairs: u32,
    guid_match_pairs: u32,
    semantic_match_pairs: u32,
    matched_message_route_mask: u8,
    matched_chat1_records: u32,
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

/// Performs one bounded comparison under the exact active native writer pause.
/// The default path is cached-only. A separately gated semantic diagnostic may
/// resolve the existing Chat1 PCS configuration with lookup-only reads, then
/// decrypt only four routing strings. Neither path persists a token, projects,
/// admits, saves, deletes, synchronizes keychain state, or repairs identity.
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
    if std::env::var("OPENBUBBLES_CLOUD_SYNC_V2_TEST_HOST").as_deref() != Ok("1")
        || std::env::var("OPENBUBBLES_INSPECT_CHAT1_CORRELATION").as_deref() != Ok("1")
        || !is_cloud_sync_windows_dev_profile(&storage_directory)
    {
        return failure(CloudSyncChat1CorrelationFailureCode::TestHostRequired);
    }
    if message_generation == 0
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
        let route = match mutation.payload() {
            Some(CloudCanonicalPayload::Message(payload)) => payload.chat_identifier(),
            _ => return failure(CloudSyncChat1CorrelationFailureCode::MessageDecodeFailed),
        };
        message_route_hashes.push(hasher.server_record_id_hash(route));
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
        let fields = match inspect_chat1_route_fields(
            &record,
            chat1_zone_key.as_ref().expect("semantic lookup completed"),
            &message_route_hashes,
            &hasher,
        ) {
            Ok(value) => value,
            Err(()) => {
                semantic_counts.route_field_decode_failures += 1;
                continue;
            }
        };
        semantic_counts.decoded_route_records += 1;
        semantic_counts.chat_identifier_match_pairs += fields.chat_identifier.count_ones();
        semantic_counts.group_id_match_pairs += fields.group_id.count_ones();
        semantic_counts.original_group_id_match_pairs += fields.original_group_id.count_ones();
        semantic_counts.guid_match_pairs += fields.guid.count_ones();
        semantic_counts.semantic_match_pairs += fields.pairs();
        let combined = fields.combined();
        semantic_counts.matched_message_route_mask |= combined;
        if combined != 0 {
            semantic_counts.matched_chat1_records += 1;
        }
    }

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
        chat_identifier_match_pairs: semantic_counts.chat_identifier_match_pairs,
        group_id_match_pairs: semantic_counts.group_id_match_pairs,
        original_group_id_match_pairs: semantic_counts.original_group_id_match_pairs,
        guid_match_pairs: semantic_counts.guid_match_pairs,
        semantic_match_pairs: semantic_counts.semantic_match_pairs,
        matched_semantic_message_routes: semantic_counts.matched_message_route_mask.count_ones(),
        matched_semantic_chat1_records: semantic_counts.matched_chat1_records,
        failure_code: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        };
        assert_eq!(fields.pairs(), 3);
        assert_eq!(fields.combined(), 0b0000_0011);
        assert_eq!(fields.combined().count_ones(), 2);
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
        assert_eq!(result.chat_identifier_match_pairs, 0);
        assert_eq!(result.group_id_match_pairs, 0);
        assert_eq!(result.original_group_id_match_pairs, 0);
        assert_eq!(result.guid_match_pairs, 0);
        assert_eq!(result.semantic_match_pairs, 0);
        assert_eq!(result.matched_semantic_message_routes, 0);
        assert_eq!(result.matched_semantic_chat1_records, 0);
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
}
