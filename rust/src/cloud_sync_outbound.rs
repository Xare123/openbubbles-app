//! Native-only protected outbound message boundary for Cloud Sync V2.
//!
//! Dart may supply a transient `CloudMessage`, but the durable representation
//! is a versioned protobuf protected under the `outboundMessage` purpose. Raw
//! message content and CloudKit record names never cross the bridge again.

use std::{path::PathBuf, time::UNIX_EPOCH};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use hmac::{Hmac, Mac};
use prost::Message;
use rustpush::cloud_messages::{
    cloudmessagesp::{MessageProto, MessageProto2, MessageProto3, MessageProto4},
    CloudMessage, GZipWrapper, MessageFlags,
};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::cloud_sync_attachment_parent::project_parent_attributed_body;
use crate::cloud_sync_canonical_dto::{
    parse_associated_parent, CloudCanonicalChatPayload, CloudCanonicalChatStyle,
    CloudCanonicalEntityKind, CloudCanonicalReactionKind, CloudCanonicalService,
};
use crate::cloud_sync_ids_attachment_source::DecodedIdsAttachmentSource;

use crate::cloud_sync_native_fetch::{
    cloud_sync_open_protected_outbound_message, cloud_sync_stage_protected_outbound_envelope,
};

mod wire {
    include!(concat!(
        env!("OUT_DIR"),
        "/openbubbles.cloudsync.outbound.rs"
    ));
}

use wire::CloudSyncOutboundMessageV1;

// Version 1 staged random UUID record names and is permanently ineligible for
// replay. Version 2 binds the protected envelope to Apple's deterministic
// container-user-ID/GUID HMAC record identity.
const OUTBOUND_SCHEMA_VERSION: u32 = 2;
const OUTBOUND_PERSISTENCE_LANE: &str = "semantic";
const MAX_OUTBOUND_ENVELOPE_BYTES: usize = 2 * 1024 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 4 * 1024;
const MAX_PROTO_BYTES: usize = 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024;
const MAX_ATTRIBUTED_BODY_BYTES: usize = 1024 * 1024;
// This is the exact ordinary sent-from-me shape emitted by Message.toCloud.
// Delivered/read/forward are ordinary optional state; every other bit is
// outside the first plain-text V2 canary.
const ORDINARY_OUTBOUND_FLAG_BITS: i64 = MessageFlags::IS_FINISHED.bits()
    | MessageFlags::IS_FROM_ME.bits()
    | MessageFlags::IS_DELIVERED.bits()
    | MessageFlags::IS_READ.bits()
    | MessageFlags::IS_SENT.bits()
    | MessageFlags::IS_FORWARD.bits()
    | MessageFlags::WAS_DATA_DETECTED.bits();
const CLOUD_SYNC_SCOPE_SEPARATOR: char = '\u{001f}';

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub(crate) enum CloudSyncOutboundFailure {
    #[error("outbound message is unsupported")]
    UnsupportedMessage,
    #[error("outbound message is malformed")]
    MalformedMessage,
    #[error("outbound message is oversized")]
    OversizedMessage,
    #[error("outbound protected storage failed")]
    ProtectedStorage,
    #[error("outbound protected binding failed")]
    BindingMismatch,
}

/// Dart-safe stage metadata. Every reference is an opaque protected-store
/// capability; both hashes are keyed/content-only diagnostics.
pub(crate) struct NativeProtectedOutboundStage {
    pub(crate) logical_entity_key_hash: String,
    pub(crate) protected_payload_reference: String,
    pub(crate) payload_sha256: String,
    pub(crate) payload_length: u64,
    pub(crate) protected_server_record_reference: String,
    pub(crate) server_record_id_hash: String,
    pub(crate) lease_reference: String,
}

/// Reproduces Apple's `CKRecordUtilities.recordNameUsingSalt:guid:`.
///
/// The GUID is the HMAC data, the Messages container-scoped CloudKit user ID
/// is the key, and the complete SHA-256 result is lowercase hexadecimal. The
/// inputs are consumed exactly as UTF-8; no case folding, normalization,
/// delimiter, prefix, or truncation is applied.
pub(crate) fn deterministic_message_record_name(
    guid: &str,
    container_scoped_user_id: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    validate_identifier(guid)?;
    validate_identifier(container_scoped_user_id)?;
    let mut mac = HmacSha256::new_from_slice(container_scoped_user_id.as_bytes())
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    mac.update(guid.as_bytes());
    Ok(mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub(crate) fn verify_deterministic_message_record_name(
    guid: &str,
    container_scoped_user_id: &str,
    server_record_name: &str,
) -> Result<(), CloudSyncOutboundFailure> {
    let expected = deterministic_message_record_name(guid, container_scoped_user_id)?;
    if expected != server_record_name {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    Ok(())
}

pub(crate) fn stage_outbound_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    container_scoped_user_id: String,
    message: CloudMessage,
) -> Result<NativeProtectedOutboundStage, CloudSyncOutboundFailure> {
    let entity_kind = outbound_entity_kind(&message)?;
    let logical_message_guid = message.guid.clone();
    let record_name =
        deterministic_message_record_name(&logical_message_guid, &container_scoped_user_id)?;
    let encoded = encode_outbound_message(message, &record_name)?;
    stage_encoded_message(
        storage_directory,
        account_fingerprint,
        entity_kind,
        &logical_message_guid,
        &record_name,
        encoded,
    )
}

fn stage_encoded_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    entity_kind: CloudCanonicalEntityKind,
    logical_message_guid: &str,
    record_name: &str,
    encoded: Vec<u8>,
) -> Result<NativeProtectedOutboundStage, CloudSyncOutboundFailure> {
    let payload_sha256 = sha256_hex(&encoded);
    let payload_length =
        u64::try_from(encoded.len()).map_err(|_| CloudSyncOutboundFailure::OversizedMessage)?;
    let protected_envelope = URL_SAFE_NO_PAD.encode(&encoded);
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    let logical_entity_key_hash = hasher
        .canonical_entity_key_hash(entity_kind, &logical_message_guid)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?
        .value()
        .to_owned();
    let server_record_id_hash = hasher.server_record_id_hash(&record_name);

    let staged = cloud_sync_stage_protected_outbound_envelope(
        storage_directory,
        account_fingerprint,
        protected_envelope,
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;

    Ok(NativeProtectedOutboundStage {
        logical_entity_key_hash,
        protected_payload_reference: staged.protected_envelope_reference.clone(),
        payload_sha256,
        payload_length,
        protected_server_record_reference: staged.protected_envelope_reference,
        server_record_id_hash,
        lease_reference: staged.lease_reference,
    })
}

pub(crate) fn open_staged_outbound_message(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
) -> Result<CloudMessage, CloudSyncOutboundFailure> {
    let protected_payload = cloud_sync_open_protected_outbound_message(
        storage_directory,
        account_fingerprint,
        protected_payload_reference,
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    let encoded = URL_SAFE_NO_PAD
        .decode(protected_payload)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    if encoded.len() > MAX_OUTBOUND_ENVELOPE_BYTES
        || sha256_hex(&encoded) != expected_payload_sha256
    {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    decode_outbound_envelope(&encoded).map(|(message, _)| message)
}

/// Source-validated parent plus ORIGINAL protected envelope bytes. No mutable
/// access: readback must compare the original payload, not a fresh projection.
/// This is native-only and deliberately has no content-bearing Debug impl.
pub(crate) struct NativeOpenedAttachmentParent {
    message: CloudMessage,
    server_record_name: String,
    encoded: Vec<u8>,
    group: Option<CloudCanonicalChatPayload>,
}

impl NativeOpenedAttachmentParent {
    pub(crate) fn message(&self) -> &CloudMessage {
        &self.message
    }
    pub(crate) fn server_record_name(&self) -> &str {
        &self.server_record_name
    }
}

/// API opens the committed IDS source under its exact context/auth interlock.
/// This function neither opens nor commits that source lease. The caller must
/// retain it for all prepares/reconciliations and enforce child dependencies.
pub(crate) fn stage_outbound_attachment_parent(
    storage_directory: PathBuf,
    account_fingerprint: String,
    container_scoped_user_id: String,
    message_headers: CloudMessage,
    source: &DecodedIdsAttachmentSource,
) -> Result<NativeProtectedOutboundStage, CloudSyncOutboundFailure> {
    stage_outbound_attachment_parent_with_group(
        storage_directory,
        account_fingerprint,
        container_scoped_user_id,
        message_headers,
        source,
        None,
    )
}

pub(crate) fn stage_outbound_attachment_parent_with_group(
    storage_directory: PathBuf,
    account_fingerprint: String,
    container_scoped_user_id: String,
    message_headers: CloudMessage,
    source: &DecodedIdsAttachmentSource,
    group: Option<&CloudCanonicalChatPayload>,
) -> Result<NativeProtectedOutboundStage, CloudSyncOutboundFailure> {
    let guid = message_headers.guid.clone();
    let record_name = deterministic_message_record_name(&guid, &container_scoped_user_id)?;
    let encoded =
        encode_outbound_attachment_parent_with_group(message_headers, &record_name, source, group)?;
    stage_encoded_message(
        storage_directory,
        account_fingerprint,
        CloudCanonicalEntityKind::Message,
        &guid,
        &record_name,
        encoded,
    )
}

/// No caller-authored body is accepted, including an empty attributed archive.
/// Record identity remains the existing V2 Message identity, not an attachment
/// identity. The storage entry point derives the record name from native salt.
pub(crate) fn encode_outbound_attachment_parent(
    message_headers: CloudMessage,
    server_record_name: &str,
    source: &DecodedIdsAttachmentSource,
) -> Result<Vec<u8>, CloudSyncOutboundFailure> {
    encode_outbound_attachment_parent_with_group(message_headers, server_record_name, source, None)
}

pub(crate) fn encode_outbound_attachment_parent_with_group(
    mut message_headers: CloudMessage,
    server_record_name: &str,
    source: &DecodedIdsAttachmentSource,
    group: Option<&CloudCanonicalChatPayload>,
) -> Result<Vec<u8>, CloudSyncOutboundFailure> {
    if message_headers
        .msg_proto
        .0
        .text
        .as_deref()
        .is_some_and(|v| !v.is_empty())
        || message_headers.msg_proto.0.attributed_body.is_some()
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    validate_attachment_parent_headers(&message_headers, source, group)?;
    let projection = project_parent_attributed_body(source)?;
    message_headers.msg_proto.0.text = Some(projection.text);
    message_headers.msg_proto.0.attributed_body = Some(projection.encoded_body);
    validate_common_outbound_sizes(&message_headers)?;
    encode_message_fields(message_headers, server_record_name)
}

/// No schema change: the journal supplies the retained source binding on each
/// open. A bare V2 envelope is still rejected by the ordinary plaintext path.
pub(crate) fn decode_outbound_attachment_parent(
    encoded: &[u8],
    source: &DecodedIdsAttachmentSource,
) -> Result<NativeOpenedAttachmentParent, CloudSyncOutboundFailure> {
    decode_outbound_attachment_parent_with_group(encoded, source, None)
}

pub(crate) fn decode_outbound_attachment_parent_with_group(
    encoded: &[u8],
    source: &DecodedIdsAttachmentSource,
    group: Option<&CloudCanonicalChatPayload>,
) -> Result<NativeOpenedAttachmentParent, CloudSyncOutboundFailure> {
    let (message, server_record_name) = decode_message_fields(encoded)?;
    validate_attachment_parent_headers(&message, source, group)?;
    let projection = project_parent_attributed_body(source)?;
    if message.msg_proto.0.text.as_deref() != Some(projection.text.as_str()) {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    projection.validate_encoded_body(
        message
            .msg_proto
            .0
            .attributed_body
            .as_deref()
            .ok_or(CloudSyncOutboundFailure::MalformedMessage)?,
    )?;
    // Reject unknown/duplicate/noncanonical envelope or nested proto fields:
    // do not discard them and later mistake a different re-encoding for the
    // persisted payload. The attributed bytes themselves are kept unchanged.
    if encode_message_fields(message.clone(), &server_record_name)? != encoded {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    Ok(NativeOpenedAttachmentParent {
        message,
        server_record_name,
        encoded: encoded.to_vec(),
        group: group.cloned(),
    })
}

pub(crate) fn open_staged_outbound_attachment_parent(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
    source: &DecodedIdsAttachmentSource,
) -> Result<NativeOpenedAttachmentParent, CloudSyncOutboundFailure> {
    open_staged_outbound_attachment_parent_with_group(
        storage_directory,
        account_fingerprint,
        protected_payload_reference,
        expected_payload_sha256,
        source,
        None,
    )
}

pub(crate) fn open_staged_outbound_attachment_parent_with_group(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_payload_reference: &str,
    expected_payload_sha256: &str,
    source: &DecodedIdsAttachmentSource,
    group: Option<&CloudCanonicalChatPayload>,
) -> Result<NativeOpenedAttachmentParent, CloudSyncOutboundFailure> {
    let protected = cloud_sync_open_protected_outbound_message(
        storage_directory,
        account_fingerprint,
        protected_payload_reference,
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    if protected.len() > MAX_OUTBOUND_ENVELOPE_BYTES.div_ceil(3) * 4 {
        return Err(CloudSyncOutboundFailure::OversizedMessage);
    }
    let encoded = URL_SAFE_NO_PAD
        .decode(protected)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    if sha256_hex(&encoded) != expected_payload_sha256 {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    decode_outbound_attachment_parent_with_group(&encoded, source, group)
}

/// Same exact CloudKit Date roundtrip exception as plaintext readback. Every
/// other field, including the archived body, must equal the ORIGINAL stage.
/// A semantically equivalent fresh archive is not permission to rewrite it.
pub(crate) fn verify_attachment_parent_readback(
    mut actual: CloudMessage,
    expected: &NativeOpenedAttachmentParent,
    expected_payload_sha256: &str,
    source: &DecodedIdsAttachmentSource,
) -> Result<String, CloudSyncOutboundFailure> {
    use rustpush::cloudkit_proto::CloudKitValue;
    use std::time::{Duration, SystemTime};

    let digest = sha256_hex(&expected.encoded);
    if digest != expected_payload_sha256 {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    let reopened = decode_outbound_attachment_parent_with_group(
        &expected.encoded,
        source,
        expected.group.as_ref(),
    )?;
    if actual.utm != reopened.message.utm {
        let value = reopened
            .message
            .utm
            .ok_or(CloudSyncOutboundFailure::BindingMismatch)?;
        if value < UNIX_EPOCH + Duration::from_secs(978307200) {
            return Err(CloudSyncOutboundFailure::MalformedMessage);
        }
        let wire = value
            .to_value()
            .ok_or(CloudSyncOutboundFailure::MalformedMessage)?;
        if actual.utm != SystemTime::from_value(&wire) {
            return Err(CloudSyncOutboundFailure::BindingMismatch);
        }
        actual.utm = reopened.message.utm;
    }
    if !message_readback_differences(&reopened.message, &actual).is_empty() {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    Ok(digest)
}

fn source_bare_handle(value: &str) -> Result<&str, CloudSyncOutboundFailure> {
    let bare = value
        .strip_prefix("mailto:")
        .or_else(|| value.strip_prefix("tel:"))
        .unwrap_or(value);
    validate_identifier(bare)?;
    if bare.chars().any(char::is_control) || bare.contains(';') || bare.contains(':') {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    Ok(bare)
}

fn validate_attachment_parent_headers(
    message: &CloudMessage,
    source: &DecodedIdsAttachmentSource,
    group: Option<&CloudCanonicalChatPayload>,
) -> Result<(), CloudSyncOutboundFailure> {
    validate_common_outbound_sizes(message)?;
    // Apply the unchanged plaintext validator to the headers with a local
    // sentinel body. Never pass this temporary value to serialization/storage.
    let mut headers = message.clone();
    headers.msg_proto.0.attributed_body = None;
    headers.msg_proto.0.text = Some("source-bound-parent".to_owned());
    validate_cloud_message(&headers)?;
    if message.r#type != 1 || message.guid != source.message_guid {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    if let Some(group) = group {
        return validate_attachment_parent_group_route(message, source, group);
    }
    if message.destination_caller_id != source_bare_handle(&source.sender)? {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    let sender = source_bare_handle(&source.sender)?;
    let mut peers = Vec::new();
    for participant in &source.participants {
        let peer = source_bare_handle(participant)?;
        if peer != sender {
            peers.push(peer);
        }
    }
    // The pre-send source does not bind a restored group's opaque CloudKit
    // chat ID to its local GUID. Do not invent that mapping or accept an
    // arbitrary header. Group parents need separately verified chat evidence.
    if peers.len() != 1
        || source
            .sender_guid
            .as_deref()
            .is_some_and(|v| v.starts_with("iMessage;+;"))
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    let chat_id = format!("iMessage;-;{}", peers[0]);
    if message.chat_id != chat_id
        || message
            .msg_proto_4
            .as_ref()
            .and_then(|v| v.0.group_id.as_deref())
            .is_some_and(|v| v != chat_id)
    {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    // prepare_send rewrites sent_timestamp even when nonzero; that pre-send
    // value is NOT proof of reflected CloudKit dateCreated. Keep the ordinary
    // positive-time gate; the API/journal owns the authoritative header binding.
    // send_delivered requests a receipt; it does not assert delivery/read
    // state. Keep the ordinary flags/receipt contract rather than inventing
    // zero receipt values from a pre-send source. Journal admission binds
    // those headers, and protected replay/readback keeps their exact values.
    Ok(())
}

// `group` comes only from cached-only protected Chat decoding in the API.
// GUID and opaque CloudKit chat_id are distinct identities. Never derive one
// from the other, or accept caller participants as the retained Chat route.
fn validate_attachment_parent_group_route(
    message: &CloudMessage,
    source: &DecodedIdsAttachmentSource,
    group: &CloudCanonicalChatPayload,
) -> Result<(), CloudSyncOutboundFailure> {
    if group.service() != CloudCanonicalService::IMessage
        || group.style() != CloudCanonicalChatStyle::Group
        || group.guid() != format!("iMessage;+;{}", group.chat_identifier())
        || source.sender_guid.as_deref() != Some(group.guid())
        || message
            .msg_proto_4
            .as_ref()
            .and_then(|v| v.0.group_id.as_deref())
            != Some(group.guid())
        || message.chat_id != group.group_id()
    {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    let sender = group_bare_handle(&source.sender)?;
    if message.destination_caller_id != sender {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    let mut members = group
        .participant_handles()
        .iter()
        .map(|v| group_member_identity(v))
        .collect::<Result<Vec<_>, _>>()?;
    members.sort_unstable();
    if members.is_empty() || members.contains(&sender) || members.windows(2).any(|v| v[0] == v[1]) {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    members.push(sender);
    members.sort_unstable();
    let mut original = source
        .participants
        .iter()
        .map(|v| group_member_identity(v))
        .collect::<Result<Vec<_>, _>>()?;
    original.sort_unstable();
    if original != members {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    Ok(())
}

fn group_bare_handle(value: &str) -> Result<&str, CloudSyncOutboundFailure> {
    let bare = if value
        .get(..7)
        .is_some_and(|v| v.eq_ignore_ascii_case("mailto:"))
    {
        &value[7..]
    } else if value
        .get(..4)
        .is_some_and(|v| v.eq_ignore_ascii_case("tel:"))
    {
        &value[4..]
    } else {
        value
    };
    validate_identifier(bare)?;
    if bare.trim() != bare
        || bare.chars().any(char::is_control)
        || bare.contains(';')
        || bare.contains(':')
    {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    Ok(bare)
}

fn group_member_identity(value: &str) -> Result<&str, CloudSyncOutboundFailure> {
    // Same opaque business-member form admitted by GroupSendRoute.matchesWire.
    // Do not normalize UUID case or use it as a caller/sender handle.
    if let Some(uuid) = value.strip_prefix("urn:biz:") {
        if uuid.len() == 36
            && [8, 13, 18, 23].iter().all(|i| uuid.as_bytes()[*i] == b'-')
            && uuid::Uuid::parse_str(uuid).is_ok()
        {
            return Ok(value);
        }
    }
    group_bare_handle(value)
}

pub(crate) fn open_staged_server_record_name(
    storage_directory: PathBuf,
    account_fingerprint: String,
    protected_server_record_reference: &str,
    expected_server_record_id_hash: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    let protected_envelope = cloud_sync_open_protected_outbound_message(
        storage_directory.clone(),
        account_fingerprint,
        protected_server_record_reference,
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    let encoded = URL_SAFE_NO_PAD
        .decode(protected_envelope)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    let (_, record_name) = decode_outbound_envelope(&encoded)?;
    let hasher = crate::cloud_sync_protector::semantic_identifier_hasher(
        storage_directory.to_string_lossy().into_owned(),
    )
    .map_err(|_| CloudSyncOutboundFailure::ProtectedStorage)?;
    if hasher.server_record_id_hash(&record_name) != expected_server_record_id_hash {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    Ok(record_name)
}

/// Re-encodes a fetched message with the stable record name so ambiguous-write
/// reconciliation can compare it with the exact protected envelope staged
/// before submission. Any CloudKit normalization becomes an explicit
/// divergence rather than an unsafe automatic replay.
pub(crate) fn outbound_message_payload_sha256(
    message: CloudMessage,
    server_record_name: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    encode_outbound_message(message, server_record_name).map(|encoded| sha256_hex(&encoded))
}

/// The durable envelope stores a nanosecond SystemTime, while the unencrypted
/// CloudKit Date field uses f64 seconds since Apple's epoch. Compare its exact
/// wire roundtrip, not an arbitrary time tolerance. Every other field and the
/// original protected payload digest remain byte-exact. Never rewrite the
/// durable envelope, identity, or remote record to accommodate transport loss.
pub(crate) fn verify_message_readback(
    mut actual: CloudMessage,
    expected: &CloudMessage,
    server_record_name: &str,
    expected_payload_sha256: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    use rustpush::cloudkit_proto::CloudKitValue;
    use std::time::{Duration, SystemTime};

    let expected_digest = outbound_message_payload_sha256(expected.clone(), server_record_name)?;
    if expected_digest != expected_payload_sha256 {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    if actual.utm != expected.utm {
        let value = expected
            .utm
            .ok_or(CloudSyncOutboundFailure::BindingMismatch)?;
        if value < UNIX_EPOCH + Duration::from_secs(978307200) {
            return Err(CloudSyncOutboundFailure::MalformedMessage);
        }
        let wire = value
            .to_value()
            .ok_or(CloudSyncOutboundFailure::MalformedMessage)?;
        if actual.utm != SystemTime::from_value(&wire) {
            return Err(CloudSyncOutboundFailure::BindingMismatch);
        }
        actual.utm = expected.utm;
    }
    let actual_digest = outbound_message_payload_sha256(actual, server_record_name)?;
    if actual_digest != expected_digest {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    Ok(expected_digest)
}

/// Closed-set mismatch labels only. No values, hashes, record names or text.
pub(crate) fn message_readback_differences(
    expected: &CloudMessage,
    actual: &CloudMessage,
) -> Vec<&'static str> {
    let mut fields = Vec::new();
    macro_rules! check {
        ($($field:ident),+ $(,)?) => { $(if expected.$field != actual.$field { fields.push(stringify!($field)); })+ };
    }
    check!(
        utm,
        error,
        chat_id,
        sender,
        time,
        destination_caller_id,
        guid,
        service
    );
    if expected.flags.bits() != actual.flags.bits() {
        fields.push("flags");
    }
    if expected.r#type != actual.r#type {
        fields.push("message_type");
    }
    if expected.msg_proto.0 != actual.msg_proto.0 {
        fields.push("msg_proto");
    }
    if expected.msg_proto_2.as_ref().map(|p| &p.0) != actual.msg_proto_2.as_ref().map(|p| &p.0) {
        fields.push("msg_proto_2");
    }
    if expected.msg_proto_3.as_ref().map(|p| &p.0) != actual.msg_proto_3.as_ref().map(|p| &p.0) {
        fields.push("msg_proto_3");
    }
    if expected.msg_proto_4.as_ref().map(|p| &p.0) != actual.msg_proto_4.as_ref().map(|p| &p.0) {
        fields.push("msg_proto_4");
    }
    fields
}

/// Recomputes the Dart `CloudOperationIdentity.forInitialCreate` value for
/// the one currently supported outbound scope. Keeping this check native
/// prevents a well-formed but unrelated local ID from being paired with a
/// protected envelope at prepare or reconciliation time.
pub(crate) fn initial_message_create_operation_id(
    account_fingerprint: &str,
    logical_entity_key_hash: &str,
) -> Result<String, CloudSyncOutboundFailure> {
    if account_fingerprint.len() != 43
        || logical_entity_key_hash.len() != 43
        || !account_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        || !logical_entity_key_hash
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(CloudSyncOutboundFailure::BindingMismatch);
    }
    let storage_key = [
        account_fingerprint,
        "com.apple.messages.cloud",
        "private",
        "messageManateeZone",
        "messages",
        "2",
        OUTBOUND_PERSISTENCE_LANE,
    ]
    .join(&CLOUD_SYNC_SCOPE_SEPARATOR.to_string());
    let payload_version = OUTBOUND_SCHEMA_VERSION.to_string();
    let canonical = [
        "cloud-sync-initial-create-v1",
        storage_key.as_str(),
        logical_entity_key_hash,
        "save",
        payload_version.as_str(),
    ]
    .join(&CLOUD_SYNC_SCOPE_SEPARATOR.to_string());
    Ok(format!("op1:{}", sha256_hex(canonical.as_bytes())))
}

fn encode_outbound_message(
    message: CloudMessage,
    server_record_name: &str,
) -> Result<Vec<u8>, CloudSyncOutboundFailure> {
    validate_cloud_message(&message)?;
    encode_message_fields(message, server_record_name)
}

// Serialization only. Both callers must apply their own closed-set validator.
fn encode_message_fields(
    message: CloudMessage,
    server_record_name: &str,
) -> Result<Vec<u8>, CloudSyncOutboundFailure> {
    validate_identifier(server_record_name)?;
    let (has_utm, utm_seconds, utm_nanos) = match message.utm {
        Some(value) => {
            let duration = value
                .duration_since(UNIX_EPOCH)
                .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
            (
                true,
                i64::try_from(duration.as_secs())
                    .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?,
                duration.subsec_nanos(),
            )
        }
        None => (false, 0, 0),
    };
    let envelope = CloudSyncOutboundMessageV1 {
        schema_version: OUTBOUND_SCHEMA_VERSION,
        has_utm,
        utm_seconds,
        utm_nanos,
        message_type: message.r#type,
        error: message.error,
        chat_id: message.chat_id,
        sender: message.sender,
        time: message.time,
        msg_proto_2: message.msg_proto_2.map(|value| value.0.encode_to_vec()),
        destination_caller_id: message.destination_caller_id,
        msg_proto: message.msg_proto.0.encode_to_vec(),
        flags: message.flags.bits(),
        guid: message.guid,
        msg_proto_3: message.msg_proto_3.map(|value| value.0.encode_to_vec()),
        service: message.service,
        msg_proto_4: message.msg_proto_4.map(|value| value.0.encode_to_vec()),
        server_record_name: server_record_name.to_owned(),
    };
    let encoded_len = envelope.encoded_len();
    if encoded_len == 0 || encoded_len > MAX_OUTBOUND_ENVELOPE_BYTES {
        return Err(CloudSyncOutboundFailure::OversizedMessage);
    }
    let encoded = envelope.encode_to_vec();
    Ok(encoded)
}

fn decode_outbound_envelope(
    encoded: &[u8],
) -> Result<(CloudMessage, String), CloudSyncOutboundFailure> {
    let (message, record_name) = decode_message_fields(encoded)?;
    validate_cloud_message(&message)?;
    Ok((message, record_name))
}

// Parsing only, private so callers cannot accidentally bypass authorization.
fn decode_message_fields(
    encoded: &[u8],
) -> Result<(CloudMessage, String), CloudSyncOutboundFailure> {
    if encoded.is_empty() || encoded.len() > MAX_OUTBOUND_ENVELOPE_BYTES {
        return Err(CloudSyncOutboundFailure::OversizedMessage);
    }
    let envelope = CloudSyncOutboundMessageV1::decode(encoded)
        .map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    if envelope.schema_version != OUTBOUND_SCHEMA_VERSION || envelope.utm_nanos >= 1_000_000_000 {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    let utm = if envelope.has_utm {
        if envelope.utm_seconds < 0 {
            return Err(CloudSyncOutboundFailure::MalformedMessage);
        }
        Some(UNIX_EPOCH + std::time::Duration::new(envelope.utm_seconds as u64, envelope.utm_nanos))
    } else {
        if envelope.utm_seconds != 0 || envelope.utm_nanos != 0 {
            return Err(CloudSyncOutboundFailure::MalformedMessage);
        }
        None
    };
    validate_identifier(&envelope.server_record_name)?;
    let server_record_name = envelope.server_record_name.clone();
    let message = CloudMessage {
        utm,
        r#type: envelope.message_type,
        error: envelope.error,
        chat_id: envelope.chat_id,
        sender: envelope.sender,
        time: envelope.time,
        msg_proto_2: decode_optional_proto::<MessageProto2>(envelope.msg_proto_2)?.map(GZipWrapper),
        destination_caller_id: envelope.destination_caller_id,
        msg_proto: GZipWrapper(decode_required_proto::<MessageProto>(envelope.msg_proto)?),
        flags: MessageFlags::from_bits_retain(envelope.flags),
        guid: envelope.guid,
        msg_proto_3: decode_optional_proto::<MessageProto3>(envelope.msg_proto_3)?.map(GZipWrapper),
        service: envelope.service,
        msg_proto_4: decode_optional_proto::<MessageProto4>(envelope.msg_proto_4)?.map(GZipWrapper),
    };
    Ok((message, server_record_name))
}

fn validate_identifier(value: &str) -> Result<(), CloudSyncOutboundFailure> {
    if value.is_empty() || value.len() > MAX_IDENTIFIER_BYTES || value.contains('\0') {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    Ok(())
}

fn decode_required_proto<T: Message + Default>(
    encoded: Vec<u8>,
) -> Result<T, CloudSyncOutboundFailure> {
    if encoded.is_empty() || encoded.len() > MAX_PROTO_BYTES {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    T::decode(encoded.as_slice()).map_err(|_| CloudSyncOutboundFailure::MalformedMessage)
}

fn decode_optional_proto<T: Message + Default>(
    encoded: Option<Vec<u8>>,
) -> Result<Option<T>, CloudSyncOutboundFailure> {
    encoded
        .map(|encoded| {
            if encoded.len() > MAX_PROTO_BYTES {
                return Err(CloudSyncOutboundFailure::OversizedMessage);
            }
            T::decode(encoded.as_slice()).map_err(|_| CloudSyncOutboundFailure::MalformedMessage)
        })
        .transpose()
}

// Shared outbound shape checks used by both the live plaintext gate and the
// gated reaction candidate. Extracted verbatim from validate_cloud_message;
// behavior and error kinds are unchanged for the type-1 path.
fn validate_common_outbound_route(message: &CloudMessage) -> Result<(), CloudSyncOutboundFailure> {
    if message.chat_id.is_empty()
        || message.destination_caller_id.is_empty()
        || message.guid.is_empty()
        || message.time <= 0
        || !message.sender.is_empty()
        || !message.flags.contains(MessageFlags::IS_FINISHED)
        || !message.flags.contains(MessageFlags::IS_FROM_ME)
        || !message.flags.contains(MessageFlags::IS_SENT)
        || !message.flags.contains(MessageFlags::WAS_DATA_DETECTED)
        || message.error != 0
    {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    if (message.flags.bits() & !ORDINARY_OUTBOUND_FLAG_BITS) != 0 {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    Ok(())
}

fn validate_common_outbound_sizes(message: &CloudMessage) -> Result<(), CloudSyncOutboundFailure> {
    let nul = char::from(0);
    for value in [
        message.chat_id.as_str(),
        message.destination_caller_id.as_str(),
        message.guid.as_str(),
        message.service.as_str(),
    ] {
        if value.len() > MAX_IDENTIFIER_BYTES || value.contains(nul) {
            return Err(CloudSyncOutboundFailure::OversizedMessage);
        }
    }
    let proto = &message.msg_proto.0;
    if proto.encoded_len() > MAX_PROTO_BYTES
        || message
            .msg_proto_2
            .as_ref()
            .is_some_and(|value| value.0.encoded_len() > MAX_PROTO_BYTES)
        || message
            .msg_proto_3
            .as_ref()
            .is_some_and(|value| value.0.encoded_len() > MAX_PROTO_BYTES)
        || message
            .msg_proto_4
            .as_ref()
            .is_some_and(|value| value.0.encoded_len() > MAX_PROTO_BYTES)
        || proto
            .text
            .as_ref()
            .is_some_and(|value| value.len() > MAX_TEXT_BYTES)
        || proto
            .attributed_body
            .as_ref()
            .is_some_and(|value| value.len() > MAX_ATTRIBUTED_BODY_BYTES)
    {
        return Err(CloudSyncOutboundFailure::OversizedMessage);
    }
    Ok(())
}

fn validate_shared_outbound_extension_metadata(
    message: &CloudMessage,
) -> Result<(), CloudSyncOutboundFailure> {
    if message
        .msg_proto_2
        .as_ref()
        .is_some_and(|value| value.0.reply.is_some())
        || message.msg_proto_3.as_ref().is_some_and(|value| {
            value.0.unk2.is_some_and(|field| field != 0)
                || value.0.unk3.is_some_and(|field| field != 0)
        })
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    if let Some(proto4) = message.msg_proto_4.as_ref().map(|value| &value.0) {
        if proto4.associated_message_emoji.is_some()
            || proto4.schedule_type.is_some_and(|value| value != 0)
            || proto4.schedule_state.is_some_and(|value| value != 0)
            || proto4
                .sent_or_received_off_grid
                .is_some_and(|value| value != 0)
            || proto4
                .service
                .as_deref()
                .is_some_and(|value| value != "iMessage")
        {
            return Err(CloudSyncOutboundFailure::UnsupportedMessage);
        }
        if let Some(group_id) = proto4.group_id.as_deref() {
            validate_identifier(group_id)?;
        }
    }
    Ok(())
}

/// Use the same canonical kind for staging, preparation and reconciliation.
/// The parent is a Message key; the reaction's own GUID is a Reaction key.
/// This validates wire shape only, not local origin or parent readiness.
pub(crate) fn outbound_entity_kind(
    message: &CloudMessage,
) -> Result<CloudCanonicalEntityKind, CloudSyncOutboundFailure> {
    validate_cloud_message(message)?;
    Ok(if message.r#type == 2 {
        CloudCanonicalEntityKind::Reaction
    } else {
        CloudCanonicalEntityKind::Message
    })
}

fn validate_cloud_message(message: &CloudMessage) -> Result<(), CloudSyncOutboundFailure> {
    if message.r#type == 2 {
        return validate_candidate_reaction_message(message).map(|_| ());
    }
    // The first production gate is intentionally one ordinary, outgoing
    // iMessage text record. Edits, app balloons, attachments, SMS,
    // and scheduled messages remain disabled until their own fixtures pass.
    if message.r#type != 1 || message.service != "iMessage" {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    validate_common_outbound_route(message)?;
    validate_common_outbound_sizes(message)?;
    let proto = &message.msg_proto.0;
    // The first canary is plain text only. An attributed body is a separate
    // NSKeyedArchiver/styling payload and must not enter this encoder yet.
    if proto
        .attributed_body
        .as_ref()
        .is_some_and(|value| !value.is_empty())
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    if proto.unk1 != 1
        || proto.unk10.is_some_and(|value| value != 0)
        || proto.unk11.is_some_and(|value| value != 0)
        || proto.unk14.is_some_and(|value| value != 0)
        || proto.subject.is_some()
        || proto.effect.is_some()
        || proto.balloon_bundle_id.is_some()
        || proto.payload_data.is_some()
        || proto.message_summary_info.is_some()
        || proto.associated_message_type.is_some()
        || proto.associated_message_guid.is_some()
        || proto.associated_message_range_location.is_some()
        || proto.associated_message_range_length.is_some()
        || (proto.text.as_deref().unwrap_or_default().is_empty()
            && proto
                .attributed_body
                .as_deref()
                .unwrap_or_default()
                .is_empty())
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    validate_shared_outbound_extension_metadata(message)?;
    Ok(())
}

// Outbound wire contract for the standard six tapbacks only (indices 0-5).
// Emoji and sticker reactions remain unsupported. The existing protected
// envelope retains the exact parent wire, and all native stages use the
// canonical Reaction kind. Admission separately proves local submission and
// the current CloudKit parent dependency; wire validity is not that proof.

// Validated reaction coordinates. parent_part preserves the exact wire:
// None for a bare GUID (whole-message target) versus Some(0) for an
// explicit part-zero wire. Never inferred from the range.
#[derive(Clone, Eq, PartialEq)]
pub(crate) struct CandidateReactionDescriptor {
    kind: CloudCanonicalReactionKind,
    remove: bool,
    parent_guid: String,
    parent_part: Option<u32>,
    range_location: Option<u32>,
    range_length: Option<u32>,
}

#[cfg(test)]
impl CandidateReactionDescriptor {
    pub(crate) fn kind(&self) -> CloudCanonicalReactionKind {
        self.kind
    }
    pub(crate) fn is_remove(&self) -> bool {
        self.remove
    }
    pub(crate) fn parent_guid(&self) -> &str {
        &self.parent_guid
    }
    pub(crate) fn parent_part(&self) -> Option<u32> {
        self.parent_part
    }
    pub(crate) fn range_location(&self) -> Option<u32> {
        self.range_location
    }
    pub(crate) fn range_length(&self) -> Option<u32> {
        self.range_length
    }
}

impl std::fmt::Debug for CandidateReactionDescriptor {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("CandidateReactionDescriptor(redacted)")
    }
}

// Canonical association owns the Reaction vocabulary. Parent dependency and
// durable local-origin proof are enforced by admission, not inferred here.
pub(crate) fn validate_candidate_reaction_message(
    message: &CloudMessage,
) -> Result<CandidateReactionDescriptor, CloudSyncOutboundFailure> {
    // Proposed minimal reaction encoding only: outbound reactions are always
    // the explicit type-2 record. Outer 0/1 are not inferred from the
    // permissive inbound family, and nothing here claims Apple acceptance.
    if message.r#type != 2 || message.service != "iMessage" {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    validate_common_outbound_route(message)?;
    validate_common_outbound_sizes(message)?;
    let proto = &message.msg_proto.0;
    if proto.text.as_deref().is_some_and(|v| !v.is_empty())
        || proto
            .attributed_body
            .as_ref()
            .is_some_and(|v| !v.is_empty())
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    if proto.unk1 != 1
        || proto.unk10.is_some_and(|v| v != 0)
        || proto.unk11.is_some_and(|v| v != 0)
        || proto.unk14.is_some_and(|v| v != 0)
        || proto.subject.is_some()
        || proto.effect.is_some()
        || proto.balloon_bundle_id.is_some()
        || proto.payload_data.is_some()
        || proto.message_summary_info.is_some()
    {
        return Err(CloudSyncOutboundFailure::UnsupportedMessage);
    }
    let atype = proto
        .associated_message_type
        .ok_or(CloudSyncOutboundFailure::UnsupportedMessage)?;
    let (remove, index) = match atype {
        2000..=2005 => (false, atype - 2000),
        3000..=3005 => (true, atype - 3000),
        _ => return Err(CloudSyncOutboundFailure::UnsupportedMessage),
    };
    let kind = match index {
        0 => CloudCanonicalReactionKind::Heart,
        1 => CloudCanonicalReactionKind::Like,
        2 => CloudCanonicalReactionKind::Dislike,
        3 => CloudCanonicalReactionKind::Laugh,
        4 => CloudCanonicalReactionKind::Emphasize,
        5 => CloudCanonicalReactionKind::Question,
        _ => return Err(CloudSyncOutboundFailure::UnsupportedMessage),
    };
    let wire = proto
        .associated_message_guid
        .as_deref()
        .ok_or(CloudSyncOutboundFailure::MalformedMessage)?;
    let parsed =
        parse_associated_parent(wire).map_err(|_| CloudSyncOutboundFailure::MalformedMessage)?;
    validate_identifier(parsed.parent_guid())?;
    if parsed.parent_guid() == message.guid {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    let (rloc, rlen) = (
        proto.associated_message_range_location,
        proto.associated_message_range_length,
    );
    if rloc.is_some() != rlen.is_some() {
        return Err(CloudSyncOutboundFailure::MalformedMessage);
    }
    if let (Some(s), Some(l)) = (rloc, rlen) {
        if s.checked_add(l).is_none() {
            return Err(CloudSyncOutboundFailure::MalformedMessage);
        }
    }
    // A future envelope must hash the parent GUID only for the parent
    // logical key; the optional part is separate target semantics.
    validate_shared_outbound_extension_metadata(message)?;
    Ok(CandidateReactionDescriptor {
        kind,
        remove,
        parent_guid: parsed.parent_guid().to_owned(),
        parent_part: parsed.parent_part(),
        range_location: rloc,
        range_length: rlen,
    })
}

// Parent parsing reuses parse_associated_parent from the canonical DTO so the
// candidate never drifts from the inbound wire vocabulary.

// Exact candidate readback labels: base message fields plus association fields.
#[cfg(test)]
pub(crate) fn candidate_reaction_readback_differences(
    expected: &CloudMessage,
    actual: &CloudMessage,
) -> Vec<&'static str> {
    let mut fields = message_readback_differences(expected, actual);
    let pe = &expected.msg_proto.0;
    let pa = &actual.msg_proto.0;
    if pe.associated_message_type != pa.associated_message_type {
        fields.push("associated_message_type");
    }
    if pe.associated_message_guid != pa.associated_message_guid {
        fields.push("associated_message_guid");
    }
    if pe.associated_message_range_location != pa.associated_message_range_location {
        fields.push("associated_message_range_location");
    }
    if pe.associated_message_range_length != pa.associated_message_range_length {
        fields.push("associated_message_range_length");
    }
    if expected
        .msg_proto_4
        .as_ref()
        .map(|v| &v.0.associated_message_emoji)
        != actual
            .msg_proto_4
            .as_ref()
            .map(|v| &v.0.associated_message_emoji)
    {
        fields.push("associated_message_emoji");
    }
    fields
}

fn sha256_hex(value: &[u8]) -> String {
    Sha256::digest(value)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
pub(crate) mod attachment_parent_test_support {
    use super::*;
    use crate::cloud_sync_ids_attachment_source::{DecodedAttachment, DecodedPart};

    pub(crate) fn group() -> CloudCanonicalChatPayload {
        use crate::cloud_sync_canonical_dto::CloudCanonicalField;
        CloudCanonicalChatPayload::new(
            "iMessage;+;restored-chat".into(),
            "restored-chat".into(),
            "opaque-CloudKit-chat-id".into(),
            "original-group-id".into(),
            CloudCanonicalService::IMessage,
            CloudCanonicalChatStyle::Group,
            vec![
                "mailto:peer@example.invalid".into(),
                "tel:+15555550100".into(),
            ],
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
            CloudCanonicalField::Value(9),
            CloudCanonicalField::Absent,
            CloudCanonicalField::Absent,
        )
        .unwrap()
    }

    pub(crate) fn group_source() -> DecodedIdsAttachmentSource {
        let mut value = source();
        value.sender_guid = Some(group().guid().to_owned());
        value
            .participants
            .push("mailto:sender@example.invalid".into());
        value.participants.push("tel:+15555550100".into());
        value
    }

    pub(crate) fn group_headers() -> CloudMessage {
        let mut value = headers();
        value.chat_id = group().group_id().to_owned();
        value.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
            group_id: Some(group().guid().to_owned()),
            ..Default::default()
        }));
        value
    }

    pub(crate) fn source() -> DecodedIdsAttachmentSource {
        let attachment = |guid: &str, part: u64, idx: u64| {
            DecodedPart::Attachment(DecodedAttachment {
                guid: guid.to_owned(),
                part,
                idx: Some(idx),
                uti_type: "public.jpeg".to_owned(),
                mime: "image/jpeg".to_owned(),
                name: "synthetic.jpg".to_owned(),
                iris: false,
                key: vec![7; 32],
                signature: vec![9; 21],
                object: "synthetic-object".to_owned(),
                url: "https://example.invalid/asset".to_owned(),
                size: 123,
            })
        };
        DecodedIdsAttachmentSource {
            message_guid: "parent-fixture-guid".to_owned(),
            sender: "mailto:sender@example.invalid".to_owned(),
            sent_timestamp: 0,
            send_delivered: false,
            participants: vec!["mailto:peer@example.invalid".to_owned()],
            cv_name: None,
            sender_guid: None,
            after_guid: None,
            embedded_profile: None,
            attachment_guids: vec!["original-A".to_owned(), "original-B".to_owned()],
            parts: vec![
                DecodedPart::Text {
                    text: "A😀".to_owned(),
                    idx: None,
                },
                attachment("original-A", 0, 1),
                DecodedPart::Text {
                    text: "B".to_owned(),
                    idx: Some(1),
                },
                attachment("original-B", 1, 7),
            ],
        }
    }

    pub(crate) fn headers() -> CloudMessage {
        CloudMessage {
            utm: Some(UNIX_EPOCH + std::time::Duration::new(1_720_000_000, 123)),
            r#type: 1,
            error: 0,
            chat_id: "iMessage;-;peer@example.invalid".to_owned(),
            sender: String::new(),
            time: 741_692_800_000_000_000,
            msg_proto_2: None,
            destination_caller_id: "sender@example.invalid".to_owned(),
            msg_proto: GZipWrapper(MessageProto {
                unk1: 1,
                ..Default::default()
            }),
            flags: MessageFlags::IS_FINISHED
                | MessageFlags::IS_FROM_ME
                | MessageFlags::IS_SENT
                | MessageFlags::WAS_DATA_DETECTED,
            guid: "parent-fixture-guid".to_owned(),
            msg_proto_3: None,
            service: "iMessage".to_owned(),
            msg_proto_4: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_attachment_parent_retains_opaque_chat_identity_body_and_child_identity() {
        use super::attachment_parent_test_support::{group, group_headers, group_source, source};
        let route = group();
        let original = group_source();
        let name =
            deterministic_message_record_name(&original.message_guid, "container-user").unwrap();
        let bytes = encode_outbound_attachment_parent_with_group(
            group_headers(),
            &name,
            &original,
            Some(&route),
        )
        .unwrap();
        let opened =
            decode_outbound_attachment_parent_with_group(&bytes, &original, Some(&route)).unwrap();
        assert_eq!(opened.message().chat_id, "opaque-CloudKit-chat-id");
        assert_eq!(
            opened
                .message()
                .msg_proto_4
                .as_ref()
                .unwrap()
                .0
                .group_id
                .as_deref(),
            Some("iMessage;+;restored-chat")
        );
        assert_eq!(opened.message().msg_proto.0.text.as_deref(), Some("A😀 B "));
        assert_eq!(opened.encoded, bytes);
        assert_eq!(
            verify_attachment_parent_readback(
                opened.message().clone(),
                &opened,
                &sha256_hex(&bytes),
                &original
            )
            .unwrap(),
            sha256_hex(&bytes)
        );
        // NSDictionary key order is intentionally not a byte-level identity.
        let again = encode_outbound_attachment_parent_with_group(
            group_headers(),
            &name,
            &original,
            Some(&route),
        )
        .unwrap();
        assert_eq!(
            decode_outbound_attachment_parent_with_group(&again, &original, Some(&route))
                .unwrap()
                .server_record_name(),
            name
        );
        let projection = project_parent_attributed_body(&source()).unwrap();
        projection
            .validate_encoded_body(
                opened
                    .message()
                    .msg_proto
                    .0
                    .attributed_body
                    .as_deref()
                    .unwrap(),
            )
            .unwrap();
        let links = |value: crate::cloud_sync_attachment_parent::ParentAttributedProjection| {
            value
                .links
                .into_iter()
                .map(|v| {
                    (
                        v.original_guid,
                        v.apple_guid,
                        v.local_guid,
                        v.canonical_guid,
                        v.field_idx,
                        v.start_utf16,
                        v.length_utf16,
                    )
                })
                .collect::<Vec<_>>()
        };
        assert_eq!(
            links(project_parent_attributed_body(&original).unwrap()),
            links(projection)
        );
        assert_eq!(
            name,
            deterministic_message_record_name(&source().message_guid, "container-user").unwrap()
        );
        let directory = tempfile::tempdir().unwrap();
        let stage = stage_outbound_attachment_parent_with_group(
            directory.path().into(),
            "A".repeat(43),
            "container-user".into(),
            group_headers(),
            &original,
            Some(&route),
        )
        .unwrap();
        crate::cloud_sync_native_fetch::cloud_sync_commit_protected_page_lease(
            directory.path().into(),
            &stage.lease_reference,
            std::slice::from_ref(&stage.protected_payload_reference),
        )
        .unwrap();
        let protected = open_staged_outbound_attachment_parent_with_group(
            directory.path().into(),
            "A".repeat(43),
            &stage.protected_payload_reference,
            &stage.payload_sha256,
            &original,
            Some(&route),
        )
        .unwrap();
        assert_eq!(protected.server_record_name(), name);
        assert_eq!(
            verify_attachment_parent_readback(
                protected.message().clone(),
                &protected,
                &stage.payload_sha256,
                &original
            )
            .unwrap(),
            stage.payload_sha256
        );
        assert!(open_staged_outbound_attachment_parent(
            directory.path().into(),
            "A".repeat(43),
            &stage.protected_payload_reference,
            &stage.payload_sha256,
            &original
        )
        .is_err());
        // Neither source-only nor ordinary plaintext decoding can reopen this route.
        assert!(decode_outbound_attachment_parent(&bytes, &original).is_err());
        assert!(decode_outbound_envelope(&bytes).is_err());
    }

    #[test]
    fn group_attachment_parent_rejects_guid_opaque_id_and_participant_substitution() {
        use super::attachment_parent_test_support::{
            group, group_headers, group_source, headers, source,
        };
        let route = group();
        let original = group_source();
        for case in 0..9 {
            let mut msg = group_headers();
            let mut changed = group_source();
            match case {
                0 => msg.chat_id = route.guid().into(), // GUID is not the opaque ID.
                1 => msg.msg_proto_4.as_mut().unwrap().0.group_id = Some(route.group_id().into()),
                2 => changed.sender_guid = Some(route.group_id().into()),
                3 => {
                    changed.participants.pop();
                }
                4 => changed.participants.push(changed.participants[0].clone()),
                5 => changed.participants[0] = "other@example.invalid".into(),
                6 => changed.message_guid = "other-message".into(),
                7 => msg.destination_caller_id = "other-sender@example.invalid".into(),
                _ => changed.sender_guid = None,
            }
            assert!(
                encode_outbound_attachment_parent_with_group(msg, "record", &changed, Some(&route))
                    .is_err(),
                "case {case}"
            );
        }
        assert!(encode_outbound_attachment_parent_with_group(
            headers(),
            "record",
            &source(),
            Some(&route)
        )
        .is_err());
        let bytes = encode_outbound_attachment_parent_with_group(
            group_headers(),
            "record",
            &original,
            Some(&route),
        )
        .unwrap();
        let opened =
            decode_outbound_attachment_parent_with_group(&bytes, &original, Some(&route)).unwrap();
        let mut tampered = opened.message().clone();
        tampered.msg_proto.0.attributed_body = Some(vec![1, 2, 3]);
        assert!(decode_outbound_attachment_parent_with_group(
            &encode_message_fields(tampered.clone(), "record").unwrap(),
            &original,
            Some(&route)
        )
        .is_err());
        assert!(verify_attachment_parent_readback(
            tampered,
            &opened,
            &sha256_hex(&bytes),
            &original
        )
        .is_err());
        assert!(encode_outbound_attachment_parent_with_group(
            opened.message().clone(),
            "record",
            &original,
            Some(&route)
        )
        .is_err());
        let mut changed = group_source();
        changed.sender_guid = Some("iMessage;+;different-group".into());
        assert!(verify_attachment_parent_readback(
            opened.message().clone(),
            &opened,
            &sha256_hex(&bytes),
            &changed
        )
        .is_err());
    }

    #[test]
    fn group_attachment_members_keep_existing_business_identity_without_sender_authority() {
        let business = "urn:biz:AAAAAAAA-BBBB-4CCC-8DDD-000000000001";
        assert_eq!(group_member_identity(business).unwrap(), business);
        assert!(group_bare_handle(business).is_err());
        assert!(group_member_identity("urn:biz:AAAAAAAABBBB4CCC8DDD000000000001").is_err());
        assert!(group_member_identity("mailto:tel:peer@example.invalid").is_err());
    }

    #[test]
    fn attachment_parent_roundtrip_is_source_bound_and_preserves_original_bytes() {
        use super::attachment_parent_test_support::{headers, source};
        let source = source();
        let name =
            deterministic_message_record_name(&source.message_guid, "container-user").unwrap();
        let bytes = encode_outbound_attachment_parent(headers(), &name, &source).unwrap();
        let opened = decode_outbound_attachment_parent(&bytes, &source).unwrap();
        assert_eq!(opened.message().msg_proto.0.text.as_deref(), Some("A😀 B "));
        assert_eq!(opened.encoded, bytes);
        assert_eq!(opened.server_record_name(), name);
        assert!(decode_outbound_envelope(&bytes).is_err());
        assert!(outbound_entity_kind(opened.message()).is_err());
        assert!(encode_outbound_message(opened.message().clone(), &name).is_err());
        let digest = sha256_hex(&bytes);
        assert_eq!(
            verify_attachment_parent_readback(opened.message().clone(), &opened, &digest, &source)
                .unwrap(),
            digest
        );
        let roundtrip = cloudkit_roundtrip(opened.message());
        assert_eq!(
            verify_attachment_parent_readback(roundtrip, &opened, &digest, &source).unwrap(),
            digest
        );
    }

    #[test]
    fn attachment_parent_rejects_caller_body_and_source_guid_mismatch() {
        use super::attachment_parent_test_support::{headers, source};
        let source = source();
        for body in [
            Vec::new(),
            vec![0x80, 0x01],
            project_parent_attributed_body(&source)
                .unwrap()
                .encoded_body,
        ] {
            let mut supplied = headers();
            supplied.msg_proto.0.attributed_body = Some(body);
            assert!(encode_outbound_attachment_parent(supplied, "record", &source).is_err());
        }
        let mut text = headers();
        text.msg_proto.0.text = Some("injected".to_owned());
        assert!(encode_outbound_attachment_parent(text, "record", &source).is_err());
        let mut wrong = headers();
        wrong.guid = "other-parent".to_owned();
        assert_eq!(
            encode_outbound_attachment_parent(wrong, "record", &source),
            Err(CloudSyncOutboundFailure::BindingMismatch)
        );
        let bytes = encode_outbound_attachment_parent(headers(), "record", &source).unwrap();
        let mut changed = source;
        changed.message_guid = "other-parent".to_owned();
        assert!(decode_outbound_attachment_parent(&bytes, &changed).is_err());
    }

    #[test]
    fn attachment_parent_rejects_header_injection_and_unproven_group_route() {
        use super::attachment_parent_test_support::{headers, source};
        let source = source();
        let mutations: Vec<Box<dyn Fn(&mut CloudMessage)>> = vec![
            Box::new(|m| m.chat_id.push('x')),
            Box::new(|m| m.destination_caller_id.push('x')),
            Box::new(|m| m.time = 0),
            Box::new(|m| m.sender = "other".to_owned()),
            Box::new(|m| m.flags |= MessageFlags::IS_AUDIO_MESSAGE),
            Box::new(|m| m.flags |= MessageFlags::IS_SYSTEM_MESSAGE),
            Box::new(|m| m.msg_proto.0.payload_data = Some(vec![1])),
            Box::new(|m| m.msg_proto.0.associated_message_type = Some(2000)),
            Box::new(|m| m.r#type = 2),
            Box::new(|m| m.service = "SMS".to_owned()),
            Box::new(|m| {
                m.msg_proto_4 = Some(GZipWrapper(MessageProto4 {
                    group_id: Some("other-route".to_owned()),
                    ..Default::default()
                }))
            }),
        ];
        for mutate in mutations {
            let mut candidate = headers();
            mutate(&mut candidate);
            assert!(encode_outbound_attachment_parent(candidate, "record", &source).is_err());
        }
        let mut group = source;
        group
            .participants
            .push("mailto:third@example.invalid".to_owned());
        assert!(encode_outbound_attachment_parent(headers(), "record", &group).is_err());
    }

    #[test]
    fn attachment_parent_presend_time_is_not_reflection_time_and_identity_is_stable() {
        use super::attachment_parent_test_support::{headers, source};
        let mut source = source();
        source.sent_timestamp = 1_720_000_000_000;
        assert!(encode_outbound_attachment_parent(headers(), "record", &source).is_ok());
        let mut reflected_time = headers();
        reflected_time.time += 1_000_000;
        reflected_time.flags |= MessageFlags::IS_DELIVERED | MessageFlags::IS_READ;
        reflected_time.msg_proto.0.date_delivered = Some(741_692_800_001_000_000);
        reflected_time.msg_proto.0.date_read = Some(741_692_800_002_000_000);
        assert!(encode_outbound_attachment_parent(reflected_time, "record", &source).is_ok());
        let name = deterministic_message_record_name(&source.message_guid, "user").unwrap();
        let first = encode_outbound_attachment_parent(headers(), &name, &source).unwrap();
        let second = encode_outbound_attachment_parent(headers(), &name, &source).unwrap();
        assert_eq!(
            decode_outbound_attachment_parent(&first, &source)
                .unwrap()
                .server_record_name(),
            decode_outbound_attachment_parent(&second, &source)
                .unwrap()
                .server_record_name()
        );
        let hasher = crate::cloud_sync_semantic_decoder::CloudSemanticIdentifierHasher::new(
            b"test-only-key",
        )
        .unwrap();
        let parent_key = hasher
            .canonical_entity_key_hash(CloudCanonicalEntityKind::Message, &source.message_guid)
            .unwrap();
        let first_links = project_parent_attributed_body(&source).unwrap().links;
        let second_links = project_parent_attributed_body(&source).unwrap().links;
        for (a, b) in first_links.iter().zip(&second_links) {
            let child = hasher.canonical_attachment_key_hash(&a.apple_guid).unwrap();
            assert_eq!(
                child,
                hasher.canonical_attachment_key_hash(&b.apple_guid).unwrap()
            );
            assert_eq!(
                child,
                hasher
                    .canonical_owned_attachment_key_hash(&source.message_guid, a.field_idx)
                    .unwrap()
            );
            assert_ne!(child, parent_key);
            assert_eq!(a.original_guid, b.original_guid);
            assert_eq!(a.local_guid, b.canonical_guid);
        }
    }

    #[test]
    fn attachment_parent_reopen_and_readback_reject_tampering() {
        use super::attachment_parent_test_support::{headers, source};
        let source = source();
        let bytes = encode_outbound_attachment_parent(headers(), "record", &source).unwrap();
        let opened = decode_outbound_attachment_parent(&bytes, &source).unwrap();
        let mut wrong_body = opened.message().clone();
        wrong_body.msg_proto.0.attributed_body = Some(vec![4, 11, 255]);
        assert!(decode_outbound_attachment_parent(
            &encode_message_fields(wrong_body, "record").unwrap(),
            &source
        )
        .is_err());
        let mut wrong_text = opened.message().clone();
        wrong_text.msg_proto.0.text = Some("tampered".to_owned());
        assert!(decode_outbound_attachment_parent(
            &encode_message_fields(wrong_text.clone(), "record").unwrap(),
            &source
        )
        .is_err());
        assert!(verify_attachment_parent_readback(
            wrong_text,
            &opened,
            &sha256_hex(&bytes),
            &source
        )
        .is_err());
        assert!(verify_attachment_parent_readback(
            opened.message().clone(),
            &opened,
            &"0".repeat(64),
            &source
        )
        .is_err());
        let mut wrong_utm = opened.message().clone();
        wrong_utm.utm = wrong_utm
            .utm
            .map(|t| t + std::time::Duration::from_millis(1));
        assert!(verify_attachment_parent_readback(
            wrong_utm,
            &opened,
            &sha256_hex(&bytes),
            &source
        )
        .is_err());
        let mut extra = bytes;
        extra.extend_from_slice(&[0x98, 0x06, 0x01]); // unknown field 99
        assert!(decode_outbound_attachment_parent(&extra, &source).is_err());
    }

    fn fixture() -> CloudMessage {
        CloudMessage {
            utm: Some(UNIX_EPOCH + std::time::Duration::new(1_700_000_000, 123)),
            r#type: 1,
            error: 0,
            chat_id: "iMessage;-;fixture@example.com".to_owned(),
            sender: String::new(),
            time: 123_456_789,
            msg_proto_2: None,
            destination_caller_id: "sender@example.com".to_owned(),
            msg_proto: GZipWrapper(MessageProto {
                unk1: 1,
                text: Some("fixture".to_owned()),
                ..Default::default()
            }),
            flags: MessageFlags::IS_FINISHED
                | MessageFlags::IS_FROM_ME
                | MessageFlags::IS_SENT
                | MessageFlags::WAS_DATA_DETECTED,
            guid: "fixture-guid".to_owned(),
            msg_proto_3: Some(GZipWrapper(MessageProto3::default())),
            service: "iMessage".to_owned(),
            msg_proto_4: Some(GZipWrapper(MessageProto4 {
                service: Some("iMessage".to_owned()),
                ..Default::default()
            })),
        }
    }

    #[test]
    fn deterministic_message_record_name_matches_apple_hmac_fixture() {
        assert_eq!(
            deterministic_message_record_name("g", "s").unwrap(),
            "87b9a0ff78dc9814142bc0cac043d115d5d33f400a09096c6b347f94cba58073"
        );
        assert_eq!(
            deterministic_message_record_name("G", "s").unwrap(),
            "e6aa3d01b90420f8b0e7a70604239ed1a5c7a92ee1461a36622314df8f63283c"
        );
        assert_eq!(
            deterministic_message_record_name("g", "S").unwrap(),
            "da032b0e5ccac56cd97518b25698239a875843c9f0a1885c140f8929f23ee661"
        );
    }

    #[test]
    fn deterministic_message_record_name_rejects_missing_inputs() {
        assert_eq!(
            deterministic_message_record_name("", "salt"),
            Err(CloudSyncOutboundFailure::MalformedMessage)
        );
        assert_eq!(
            deterministic_message_record_name("guid", ""),
            Err(CloudSyncOutboundFailure::MalformedMessage)
        );
    }

    #[test]
    fn deterministic_message_record_binding_requires_exact_guid_salt_and_name() {
        let expected = deterministic_message_record_name("g", "s").unwrap();
        assert_eq!(
            verify_deterministic_message_record_name("g", "s", &expected),
            Ok(())
        );
        for (guid, salt, record_name) in [
            ("G", "s", expected.as_str()),
            ("g", "S", expected.as_str()),
            ("g", "s", "different-record-name"),
        ] {
            assert_eq!(
                verify_deterministic_message_record_name(guid, salt, record_name),
                Err(CloudSyncOutboundFailure::BindingMismatch)
            );
        }
    }

    #[test]
    fn schema_version_one_cannot_be_decoded_or_reconstructed() {
        let record_name =
            deterministic_message_record_name("fixture-guid", "container-user-fixture").unwrap();
        let encoded = encode_outbound_message(fixture(), &record_name).expect("version two encode");
        let mut legacy = CloudSyncOutboundMessageV1::decode(encoded.as_slice()).unwrap();
        assert_eq!(legacy.schema_version, OUTBOUND_SCHEMA_VERSION);

        legacy.schema_version = 1;
        assert_eq!(
            decode_outbound_envelope(&legacy.encode_to_vec()).unwrap_err(),
            CloudSyncOutboundFailure::MalformedMessage
        );
    }

    #[test]
    fn schema_version_two_reconstructs_deterministic_identity_control() {
        let container_scoped_user_id = "container-user-fixture";
        let expected_record_name =
            deterministic_message_record_name("fixture-guid", container_scoped_user_id).unwrap();
        let encoded =
            encode_outbound_message(fixture(), &expected_record_name).expect("version two encode");
        let envelope = CloudSyncOutboundMessageV1::decode(encoded.as_slice()).unwrap();
        assert_eq!(envelope.schema_version, 2);

        let (reconstructed, record_name) =
            decode_outbound_envelope(&encoded).expect("version two reconstruction");
        assert_eq!(reconstructed.guid, "fixture-guid");
        assert_eq!(record_name, expected_record_name);
        assert_eq!(
            verify_deterministic_message_record_name(
                &reconstructed.guid,
                container_scoped_user_id,
                &record_name,
            ),
            Ok(())
        );
    }

    #[test]
    fn outbound_production_source_has_no_content_or_credential_logging_surface() {
        let source = include_str!("cloud_sync_outbound.rs");
        let production = source
            .split("#[cfg(test)]")
            .next()
            .expect("production source");
        for forbidden in [
            "log::",
            "tracing::",
            "slog::",
            "trace!(",
            "debug!(",
            "info!(",
            "warn!(",
            "error!(",
            "print!(",
            "println!(",
            "eprint!(",
            "eprintln!(",
            "dbg!(",
        ] {
            assert!(
                !production.contains(forbidden),
                "outbound production source must not contain logging surface {forbidden}"
            );
        }
    }

    #[test]
    fn outbound_envelope_round_trips_without_losing_presence_or_flags() {
        let original = fixture();
        let encoded = encode_outbound_message(original, "SERVER-RECORD").expect("encode");
        let (decoded, record_name) = decode_outbound_envelope(&encoded).expect("decode");
        assert_eq!(decoded.chat_id, "iMessage;-;fixture@example.com");
        assert_eq!(decoded.msg_proto.text.as_deref(), Some("fixture"));
        assert!(decoded.msg_proto_2.is_none());
        assert!(decoded.msg_proto_3.is_some());
        assert!(decoded.flags.contains(MessageFlags::IS_FROM_ME));
        assert!(decoded.flags.contains(MessageFlags::IS_SENT));
        assert_eq!(record_name, "SERVER-RECORD");
    }

    #[test]
    fn reconciliation_digest_binds_message_and_stable_record_name() {
        let expected = outbound_message_payload_sha256(fixture(), "SERVER-RECORD").unwrap();
        assert_eq!(
            outbound_message_payload_sha256(fixture(), "SERVER-RECORD").unwrap(),
            expected
        );
        assert_ne!(
            outbound_message_payload_sha256(fixture(), "OTHER-RECORD").unwrap(),
            expected
        );
        let mut changed = fixture();
        changed.msg_proto.0.text = Some("different".to_owned());
        assert_ne!(
            outbound_message_payload_sha256(changed, "SERVER-RECORD").unwrap(),
            expected
        );
    }

    struct IdentityEncryptor;

    impl rustpush::cloudkit_proto::CloudKitEncryptor for IdentityEncryptor {
        fn encrypt_data(&self, data: &[u8], _: &str) -> Vec<u8> {
            data.to_vec()
        }
        fn decrypt_data(&self, data: &[u8], _: &str) -> Vec<u8> {
            data.to_vec()
        }
    }

    fn cloudkit_roundtrip(message: &CloudMessage) -> CloudMessage {
        use rustpush::cloudkit_proto::CloudKitRecord;
        CloudMessage::from_record_encrypted(
            &message.to_record_encrypted(Some(&IdentityEncryptor)),
            Some(&IdentityEncryptor),
        )
    }

    fn readback_fixture() -> CloudMessage {
        let mut message = fixture();
        // Windows SystemTime resolution is 100ns. This value changes after
        // CloudKit's f64 roundtrip even on that platform (unlike 123ns).
        message.utm = Some(UNIX_EPOCH + std::time::Duration::new(1_788_000_000, 500));
        message
    }

    #[test]
    fn message_readback_uses_the_exact_cloudkit_date_roundtrip() {
        let expected = readback_fixture();
        let actual = cloudkit_roundtrip(&expected);
        let digest = outbound_message_payload_sha256(expected.clone(), "RECORD").unwrap();
        // Reproduces the old false conflict through the real record serializer.
        assert_ne!(expected.utm, actual.utm);
        assert_eq!(message_readback_differences(&expected, &actual), ["utm"]);
        assert_ne!(
            outbound_message_payload_sha256(actual.clone(), "RECORD").unwrap(),
            digest
        );
        assert_eq!(
            verify_message_readback(actual, &expected, "RECORD", &digest).unwrap(),
            digest
        );
        assert_eq!(
            verify_message_readback(expected.clone(), &expected, "RECORD", &digest).unwrap(),
            digest
        );
    }

    #[test]
    fn message_readback_does_not_use_a_time_tolerance_or_ignore_presence() {
        use std::time::Duration;
        let expected = readback_fixture();
        let actual = cloudkit_roundtrip(&expected);
        let digest = outbound_message_payload_sha256(expected.clone(), "RECORD").unwrap();
        for utm in [
            None,
            actual.utm.map(|time| time - Duration::from_nanos(100)),
            actual.utm.map(|time| time + Duration::from_millis(1)),
        ] {
            let mut changed = actual.clone();
            changed.utm = utm;
            assert_eq!(
                verify_message_readback(changed, &expected, "RECORD", &digest),
                Err(CloudSyncOutboundFailure::BindingMismatch)
            );
        }
        let mut missing_expected = expected.clone();
        missing_expected.utm = None;
        let missing_digest =
            outbound_message_payload_sha256(missing_expected.clone(), "RECORD").unwrap();
        assert_eq!(
            verify_message_readback(actual, &missing_expected, "RECORD", &missing_digest),
            Err(CloudSyncOutboundFailure::BindingMismatch)
        );
    }

    #[test]
    fn message_readback_still_binds_every_content_and_route_field() {
        let expected = readback_fixture();
        let actual = cloudkit_roundtrip(&expected);
        let digest = outbound_message_payload_sha256(expected.clone(), "RECORD").unwrap();
        let mutations: Vec<Box<dyn Fn(&mut CloudMessage)>> = vec![
            Box::new(|m| m.chat_id.push('x')),
            Box::new(|m| m.guid.push('x')),
            Box::new(|m| m.time += 1),
            Box::new(|m| m.destination_caller_id.push('x')),
            Box::new(|m| m.flags |= MessageFlags::IS_READ),
            Box::new(|m| m.msg_proto.0.text = Some("different".to_owned())),
            Box::new(|m| m.msg_proto.0.date_read = Some(123)),
            Box::new(|m| m.msg_proto_3 = None),
            Box::new(|m| m.msg_proto_4.as_mut().unwrap().0.group_id = Some("other".to_owned())),
        ];
        for mutate in mutations {
            let mut changed = actual.clone();
            mutate(&mut changed);
            assert_eq!(
                verify_message_readback(changed, &expected, "RECORD", &digest),
                Err(CloudSyncOutboundFailure::BindingMismatch)
            );
        }
        assert_eq!(
            verify_message_readback(actual.clone(), &expected, "OTHER", &digest),
            Err(CloudSyncOutboundFailure::BindingMismatch)
        );
        assert_eq!(
            verify_message_readback(actual, &expected, "RECORD", &"0".repeat(64)),
            Err(CloudSyncOutboundFailure::BindingMismatch)
        );
    }

    #[test]
    fn initial_create_operation_identity_matches_the_dart_cross_language_fixture() {
        assert_eq!(
            initial_message_create_operation_id(&"A".repeat(43), &"L".repeat(43)).unwrap(),
            "op1:8751798749a671ef818533ff539e4aa2467dcde96d85831453ff06e651ba4d02"
        );
        assert_ne!(
            initial_message_create_operation_id(&"B".repeat(43), &"L".repeat(43)).unwrap(),
            initial_message_create_operation_id(&"A".repeat(43), &"L".repeat(43)).unwrap()
        );
        assert_ne!(
            initial_message_create_operation_id(&"A".repeat(43), &"M".repeat(43)).unwrap(),
            initial_message_create_operation_id(&"A".repeat(43), &"L".repeat(43)).unwrap()
        );
    }

    #[test]
    fn initial_create_operation_identity_rejects_noncanonical_hash_inputs() {
        for invalid in ["short".to_owned(), "!".repeat(43), "A".repeat(44)] {
            assert_eq!(
                initial_message_create_operation_id(&invalid, &"L".repeat(43)).unwrap_err(),
                CloudSyncOutboundFailure::BindingMismatch
            );
            assert_eq!(
                initial_message_create_operation_id(&"A".repeat(43), &invalid).unwrap_err(),
                CloudSyncOutboundFailure::BindingMismatch
            );
        }
    }

    #[test]
    fn outbound_gate_rejects_reactions_extensions_and_sms() {
        let mut reaction = fixture();
        reaction.r#type = 2;
        assert_eq!(
            encode_outbound_message(reaction, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );

        let mut extension = fixture();
        extension.msg_proto.0.payload_data = Some(vec![1]);
        assert_eq!(
            encode_outbound_message(extension, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );

        let mut sms = fixture();
        sms.service = "SMS".to_owned();
        assert_eq!(
            encode_outbound_message(sms, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );
    }

    #[test]
    fn outbound_gate_rejects_nonempty_attributed_body() {
        let mut styled = fixture();
        styled.msg_proto.0.attributed_body = Some(vec![0x80, 0x01]);
        assert_eq!(
            encode_outbound_message(styled, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );
    }

    #[test]
    fn outbound_gate_rejects_unsupported_and_unknown_flag_bits() {
        for flag in [
            MessageFlags::IS_AUDIO_MESSAGE,
            MessageFlags::IS_SYSTEM_MESSAGE,
            MessageFlags::IS_DELAYED,
        ] {
            let mut unsupported = fixture();
            unsupported.flags |= flag;
            assert_eq!(
                encode_outbound_message(unsupported, "SERVER-RECORD").unwrap_err(),
                CloudSyncOutboundFailure::UnsupportedMessage
            );
        }

        let mut unknown = fixture();
        unknown.flags = MessageFlags::from_bits_retain(unknown.flags.bits() | (1_i64 << 62));
        assert_eq!(
            encode_outbound_message(unknown, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );
    }

    #[test]
    fn outbound_gate_keeps_group_id_contract_explicitly_unresolved() {
        // Message.toCloud emits groupId for current DM records. This test
        // deliberately documents acceptance, not a group-chat classification
        // rule, until the V2 one-to-one wire contract has a real fixture.
        let mut message = fixture();
        message.msg_proto_4.as_mut().unwrap().0.group_id = Some("dm-wire-id".to_owned());
        assert!(encode_outbound_message(message, "SERVER-RECORD").is_ok());
    }

    #[test]
    fn envelope_rejects_version_and_digest_tampering() {
        let encoded = encode_outbound_message(fixture(), "SERVER-RECORD").expect("encode");
        let mut envelope = CloudSyncOutboundMessageV1::decode(encoded.as_slice()).unwrap();
        envelope.schema_version += 1;
        assert_eq!(
            decode_outbound_envelope(&envelope.encode_to_vec()).unwrap_err(),
            CloudSyncOutboundFailure::MalformedMessage
        );
    }

    #[test]
    fn outbound_gate_rejects_reply_and_scheduled_metadata() {
        let mut reply = fixture();
        reply.msg_proto_2 = Some(GZipWrapper(MessageProto2 {
            reply: Some("reply-guid".to_owned()),
        }));
        assert_eq!(
            encode_outbound_message(reply, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );

        let mut scheduled = fixture();
        scheduled.msg_proto_4.as_mut().unwrap().0.schedule_type = Some(1);
        assert_eq!(
            encode_outbound_message(scheduled, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage
        );
    }

    #[test]
    fn outbound_gate_rejects_oversized_text_before_envelope_encoding() {
        let mut oversized = fixture();
        oversized.msg_proto.0.text = Some("x".repeat(MAX_TEXT_BYTES + 1));
        assert_eq!(
            encode_outbound_message(oversized, "SERVER-RECORD").unwrap_err(),
            CloudSyncOutboundFailure::OversizedMessage
        );
    }

    // Proposed minimal reaction encoding for tests only: explicit type-2, no
    // body, association wire under test. Not a claim of Apple acceptance.
    fn candidate_fixture(associated_type: u32, parent_wire: &str) -> CloudMessage {
        let mut message = fixture();
        message.r#type = 2;
        message.guid = "reaction-guid".to_owned();
        message.msg_proto.0.text = None;
        message.msg_proto.0.attributed_body = None;
        message.msg_proto.0.associated_message_type = Some(associated_type);
        message.msg_proto.0.associated_message_guid = Some(parent_wire.to_owned());
        message.msg_proto.0.associated_message_range_location = Some(0);
        message.msg_proto.0.associated_message_range_length = Some(4);
        message
    }

    #[test]
    fn candidate_validator_accepts_six_tapbacks_add_and_remove() {
        let kinds = [
            (2000, CloudCanonicalReactionKind::Heart),
            (2001, CloudCanonicalReactionKind::Like),
            (2002, CloudCanonicalReactionKind::Dislike),
            (2003, CloudCanonicalReactionKind::Laugh),
            (2004, CloudCanonicalReactionKind::Emphasize),
            (2005, CloudCanonicalReactionKind::Question),
        ];
        for (atype, kind) in kinds {
            let d =
                validate_candidate_reaction_message(&candidate_fixture(atype, "p:0/parent-guid"))
                    .expect("tapback add");
            assert_eq!(d.kind(), kind);
            assert!(!d.is_remove());
            assert_eq!(d.parent_guid(), "parent-guid");
            assert_eq!(d.parent_part(), Some(0));
            assert_eq!(d.range_location(), Some(0));
            assert_eq!(d.range_length(), Some(4));
            // No extra entity-kind surface: the canonical association already owns the Reaction mapping.
        }
        for atype in 3000..=3005 {
            let d =
                validate_candidate_reaction_message(&candidate_fixture(atype, "p:0/parent-guid"))
                    .expect("tapback remove");
            assert!(d.is_remove());
        }
    }

    #[test]
    fn candidate_validator_rejects_emoji_sticker_and_unknown_types() {
        for atype in [0, 2, 9999, 2006, 2007, 3006, 3007, 4000] {
            assert_eq!(
                validate_candidate_reaction_message(&candidate_fixture(atype, "p:0/parent-guid"))
                    .unwrap_err(),
                CloudSyncOutboundFailure::UnsupportedMessage,
            );
        }
        let mut missing = candidate_fixture(2000, "p:0/parent-guid");
        missing.msg_proto.0.associated_message_type = None;
        assert_eq!(
            validate_candidate_reaction_message(&missing).unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage,
        );
    }

    #[test]
    fn candidate_validator_keeps_bare_partless_distinct_from_part_zero() {
        let bare = validate_candidate_reaction_message(&candidate_fixture(2001, "parent-guid"))
            .expect("bare");
        assert_eq!(bare.parent_part(), None);
        let zero = validate_candidate_reaction_message(&candidate_fixture(2001, "p:0/parent-guid"))
            .expect("part zero");
        assert_eq!(zero.parent_part(), Some(0));
        assert_eq!(bare.parent_guid(), zero.parent_guid());
        assert_ne!(bare.parent_part(), zero.parent_part());
        let bubble =
            validate_candidate_reaction_message(&candidate_fixture(2001, "bp:2/parent-guid"))
                .expect("bubble part");
        assert_eq!(bubble.parent_part(), Some(2));
    }

    #[test]
    fn candidate_validator_rejects_malformed_parents_and_self_parent() {
        for wire in [
            "bpdi:0/parent-guid",
            "p:/parent-guid",
            "p:01/parent-guid",
            "p:0/",
            "p:0/a/b",
            "x/y",
            "r:0:parent-guid",
        ] {
            assert_eq!(
                validate_candidate_reaction_message(&candidate_fixture(2000, wire)).unwrap_err(),
                CloudSyncOutboundFailure::MalformedMessage,
            );
        }
        let mut missing = candidate_fixture(2000, "p:0/parent-guid");
        missing.msg_proto.0.associated_message_guid = None;
        assert_eq!(
            validate_candidate_reaction_message(&missing).unwrap_err(),
            CloudSyncOutboundFailure::MalformedMessage,
        );
        assert_eq!(
            validate_candidate_reaction_message(&candidate_fixture(2000, "p:0/reaction-guid"))
                .unwrap_err(),
            CloudSyncOutboundFailure::MalformedMessage,
        );
    }

    #[test]
    fn candidate_validator_requires_complete_range_without_overflow() {
        let mut partial = candidate_fixture(2000, "p:0/parent-guid");
        partial.msg_proto.0.associated_message_range_length = None;
        assert_eq!(
            validate_candidate_reaction_message(&partial).unwrap_err(),
            CloudSyncOutboundFailure::MalformedMessage,
        );
        let mut overflow = candidate_fixture(2000, "p:0/parent-guid");
        overflow.msg_proto.0.associated_message_range_location = Some(u32::MAX);
        overflow.msg_proto.0.associated_message_range_length = Some(1);
        assert_eq!(
            validate_candidate_reaction_message(&overflow).unwrap_err(),
            CloudSyncOutboundFailure::MalformedMessage,
        );
        let mut absent = candidate_fixture(2000, "parent-guid");
        absent.msg_proto.0.associated_message_range_location = None;
        absent.msg_proto.0.associated_message_range_length = None;
        let d = validate_candidate_reaction_message(&absent).expect("rangeless");
        assert_eq!(d.range_location(), None);
        assert_eq!(d.parent_part(), None);
    }

    #[test]
    fn candidate_validator_rejects_body_and_emoji_payload() {
        let mut bodied = candidate_fixture(2000, "p:0/parent-guid");
        bodied.msg_proto.0.text = Some("tapback".to_owned());
        assert_eq!(
            validate_candidate_reaction_message(&bodied).unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage,
        );
        let mut emoji = candidate_fixture(2000, "p:0/parent-guid");
        emoji
            .msg_proto_4
            .as_mut()
            .unwrap()
            .0
            .associated_message_emoji = Some("grin".to_owned());
        assert_eq!(
            validate_candidate_reaction_message(&emoji).unwrap_err(),
            CloudSyncOutboundFailure::UnsupportedMessage,
        );
    }

    #[test]
    fn reaction_envelope_roundtrip_preserves_kind_and_target() {
        for atype in (2000..=2005).chain(3000..=3005) {
            for parent in ["parent-guid", "p:0/parent-guid", "bp:2/parent-guid"] {
                let mut expected = candidate_fixture(atype, parent);
                expected.msg_proto.0.associated_message_range_location = None;
                expected.msg_proto.0.associated_message_range_length = None;
                let bytes = encode_outbound_message(expected.clone(), "SERVER-RECORD").unwrap();
                let (actual, record) = decode_outbound_envelope(&bytes).unwrap();
                assert_eq!(record, "SERVER-RECORD");
                assert_eq!(
                    outbound_entity_kind(&actual).unwrap(),
                    CloudCanonicalEntityKind::Reaction
                );
                assert!(message_readback_differences(&expected, &actual).is_empty());
                let descriptor = validate_candidate_reaction_message(&actual).unwrap();
                assert_eq!(descriptor.is_remove(), atype >= 3000);
                assert_eq!(descriptor.parent_guid(), "parent-guid");
                assert_eq!(
                    descriptor.parent_part(),
                    if parent.starts_with("p:") {
                        Some(0)
                    } else if parent.starts_with("bp:") {
                        Some(2)
                    } else {
                        None
                    }
                );
            }
        }
        assert_eq!(
            outbound_entity_kind(&fixture()).unwrap(),
            CloudCanonicalEntityKind::Message
        );
    }

    #[test]
    fn malformed_reaction_never_gets_a_valid_outbound_kind() {
        for atype in [1999, 2006, 2007, 2999, 3006, 3007] {
            let message = candidate_fixture(atype, "parent-guid");
            assert_eq!(
                outbound_entity_kind(&message).unwrap_err(),
                CloudSyncOutboundFailure::UnsupportedMessage
            );
            assert!(encode_outbound_message(message, "SERVER-RECORD").is_err());
        }
    }

    #[test]
    fn candidate_readback_reports_exact_association_drift() {
        let expected = candidate_fixture(2001, "p:0/parent-guid");
        assert!(candidate_reaction_readback_differences(&expected, &expected).is_empty());
        let mut t = expected.clone();
        t.msg_proto.0.associated_message_type = Some(2002);
        assert!(candidate_reaction_readback_differences(&expected, &t)
            .contains(&"associated_message_type"));
        let mut g = expected.clone();
        g.msg_proto.0.associated_message_guid = Some("p:0/other-guid".to_owned());
        assert!(candidate_reaction_readback_differences(&expected, &g)
            .contains(&"associated_message_guid"));
        let mut r = expected.clone();
        r.msg_proto.0.associated_message_range_length = Some(5);
        assert!(candidate_reaction_readback_differences(&expected, &r)
            .contains(&"associated_message_range_length"));
        let mut e = expected.clone();
        e.msg_proto_4.as_mut().unwrap().0.associated_message_emoji = Some("grin".to_owned());
        assert!(candidate_reaction_readback_differences(&expected, &e)
            .contains(&"associated_message_emoji"));
    }
}
