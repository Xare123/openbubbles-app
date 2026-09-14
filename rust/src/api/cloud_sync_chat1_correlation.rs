//! Test-host-only, cached correlation between unresolved Message chat routes
//! and protected Chat1 record names. Clear identifiers and raw envelopes never
//! cross Flutter Rust Bridge, and this module cannot fetch, project, or write.

use std::{collections::HashSet, path::PathBuf, sync::Arc};

use rustpush::{
    cloud_messages::CloudMessagesClient,
    cloudkit_operation_gate::acquire_cloudkit_read_authentication, DefaultAnisetteProvider,
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
        cloud_sync_decode_transient_record_cached_only, CloudTransientDecodeOutcome,
        CloudTransientDecodeRequest, CloudTransientExpectedChangeKind,
    },
};

const MAX_MESSAGE_SOURCES: usize = 8;
const MAX_CHAT1_SOURCES: usize = 50;

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
        failure_code: Some(code),
    }
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

fn verified_chat1_record_hash(
    storage_directory: &str,
    scope: &CloudNativeProtectionScope,
    generation: u64,
    source: &CloudSyncChat1CorrelationSourceInput,
    hasher: &CloudSemanticIdentifierHasher,
) -> Result<String, ()> {
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
    Ok(record_id_hash)
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

/// Performs one bounded cached-only comparison under the exact active native
/// writer pause. The Message decoder may use already-warmed PCS state but this
/// function performs no CloudKit request, token persistence, projection,
/// admission, save, delete, keychain synchronization, or identity repair.
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
    let mut chat1_record_hashes = Vec::with_capacity(chat1_sources.len());
    for source in &chat1_sources {
        match verified_chat1_record_hash(
            &storage_directory,
            &chat1_scope,
            chat1_generation,
            source,
            &hasher,
        ) {
            Ok(record_hash) => chat1_record_hashes.push(record_hash),
            Err(()) => return failure(CloudSyncChat1CorrelationFailureCode::Chat1SourceMismatch),
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
        assert_eq!(
            result.failure_code,
            Some(CloudSyncChat1CorrelationFailureCode::Chat1SourceMismatch)
        );
    }
}
